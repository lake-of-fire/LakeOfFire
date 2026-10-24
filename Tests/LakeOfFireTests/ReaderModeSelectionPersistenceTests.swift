import BigSyncKit
import RealmSwift
import SwiftUIWebView
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader
@testable import RealmSwiftGaps

private enum ReaderModeSelectionFixtureError: Error {
    case stopAfterPrimaryPersistence
}

@MainActor
private final class ReaderModeSelectionTaskReceipt {
    var task: Task<Void, Never>?
}

private actor ReaderModeSelectionDiscoveryGate {
    private var released = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

final class ReaderModeSelectionPersistenceTests: XCTestCase {
    private typealias Context = ReaderContentLoader.ReaderModePropagationContext
    private static let html = "<article><p>Selected Reader content.</p></article>"
    private static let seedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private struct JournalState: Equatable, Sendable {
        let generation: String
        let changedAt: Date
        let modifiedAt: Date
        let explicitlyModifiedAt: Date?
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, HistoryRecord.self, ContentFile.self, Feed.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let captured = configuration
        addTeardownBlock {
            let removed = await RealmBackgroundActor.shared.removeCachedRealm(for: captured)
            // A case that never used the writer has no cached Realm to remove.
            if !removed {
                await Self.assertFixtureHasNoOpenWrite(owner: RealmBackgroundActor.shared, configuration: captured)
            }
        }
        return configuration
    }

    private static func assertFixtureHasNoOpenWrite(
        owner: isolated RealmBackgroundActor, configuration: Realm.Configuration
    ) {
        let key = owner.realmCacheKey(for: configuration)
        XCTAssertFalse(owner.cachedRealms[key]?.isInWriteTransaction ?? false)
    }

    private static func cancelFixtureWrite(
        owner: isolated RealmBackgroundActor, configuration: Realm.Configuration
    ) {
        // Only this test owns this unique fixture's held transaction. Join the
        // queued operation before releasing the fixture, never its active task.
        let key = owner.realmCacheKey(for: configuration)
        if let realm = owner.cachedRealms[key], realm.isInWriteTransaction { realm.cancelWrite() }
    }

    private func track<Result: Sendable>(_ task: Task<Result, Error>, configuration: Realm.Configuration) {
        addTeardownBlock {
            task.cancel()
            _ = await task.result
            await Self.cancelFixtureWrite(owner: RealmBackgroundActor.shared, configuration: configuration)
        }
    }

    private func install(_ configuration: Realm.Configuration) -> () -> Void {
        let bookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let history = ReaderContentLoader.historyRealmConfiguration
        let feed = ReaderContentLoader.feedEntryRealmConfiguration
        let providers = ReaderContentLoader.additionalContentProviders
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        ReaderContentLoader.additionalContentProviders = []
        return {
            ReaderContentLoader.bookmarkRealmConfiguration = bookmark
            ReaderContentLoader.historyRealmConfiguration = history
            ReaderContentLoader.feedEntryRealmConfiguration = feed
            ReaderContentLoader.additionalContentProviders = providers
        }
    }

    private func configured<T: Bookmark>(_ record: T, url: URL) -> T {
        record.url = url
        record.createdAt = Self.seedDate
        record.isReaderModeAvailable = true
        record.isReaderModeOfferHidden = true
        record.updateCompoundKey()
        return record
    }

    private func seed(_ records: [Bookmark], in realm: Realm) throws {
        try realm.write {
            for record in records {
                realm.add(record)
                record.refreshChangeMetadata(explicitlyModified: true, at: Self.seedDate)
            }
        }
    }

    private static func journalState(for record: Object & ChangeMetadataRecordable, in realm: Realm) throws -> JournalState {
        let keyName = try XCTUnwrap(record.objectSchema.primaryKeyProperty?.name)
        let key = String(describing: try XCTUnwrap(record[keyName]))
        let pending = try XCTUnwrap(realm.object(ofType: BigSyncPendingMutation.self,
            forPrimaryKey: record.objectSchema.className + "." + key))
        XCTAssertFalse(pending.generation.isEmpty)
        XCTAssertEqual(pending.changedAt, record.modifiedAt)
        XCTAssertEqual(pending.changedAt, record.explicitlyModifiedAt)
        return JournalState(generation: pending.generation, changedAt: pending.changedAt,
            modifiedAt: record.modifiedAt, explicitlyModifiedAt: record.explicitlyModifiedAt)
    }

    @MainActor
    private func select(_ record: any ReaderContentProtocol, in reader: ReaderContent) -> Context {
        reader.replaceSelection(with: record)
        reader.pageURL = record.url
        return Context(primaryContent: record,
            permitsCommit: reader.makeSelectionCommitFence(requiring: reader.currentSelectionID))
    }

    @RealmBackgroundActor
    private static func beginFixtureWrite(_ configuration: Realm.Configuration) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        XCTAssertFalse(realm.isInWriteTransaction)
        try realm.beginWrite()
    }

    @RealmBackgroundActor
    private static func commitFixtureWrite(_ configuration: Realm.Configuration) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        XCTAssertTrue(realm.isInWriteTransaction)
        guard realm.isInWriteTransaction else { return }
        try realm.commitWrite()
    }

    private func queuedPrimary(_ context: Context, submitted: XCTestExpectation) -> Task<Bool, Error> {
        Task { @RealmBackgroundActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await ReaderContentLoader.persistPrimaryReaderModeDefaults(
                    context: context, readabilityHTML: Self.html, resolvedTitle: "Reader title"
                )
            }
        }
    }

    @MainActor
    func testQueuedPrimaryRejectsRetirementAndSameURLReturnButAcceptsTheNewSelection() async throws {
        for returnsToOriginal in [false, true] {
            let configuration = makeConfiguration()
            let restore = install(configuration)
            defer { restore() }
            let realm = try Realm(configuration: configuration)
            let a = configured(Bookmark(), url: URL(string: "https://example.com/primary-a/\(UUID().uuidString)")!)
            let b = configured(Bookmark(), url: URL(string: "https://example.com/primary-b/\(UUID().uuidString)")!)
            try seed([a, b], in: realm)
            let seeded = try Self.journalState(for: a, in: realm)
            let reader = ReaderContent()
            defer { withExtendedLifetime(reader) {} }
            let context = select(a, in: reader)
            try await Self.beginFixtureWrite(configuration)
            let submitted = expectation(description: "primary submitted its own queued write ticket")
            let write = queuedPrimary(context, submitted: submitted)
            track(write, configuration: configuration)
            await fulfillment(of: [submitted], timeout: 2)

            var current = select(b, in: reader)
            if returnsToOriginal { current = select(a, in: reader) }
            try await Self.commitFixtureWrite(configuration)
            do {
                _ = try await write.value
                XCTFail("A retired selection must not commit even after returning to its URL")
            } catch is CancellationError { }
            await realm.asyncRefresh()
            XCTAssertNil(a.html)
            XCTAssertEqual(a.title, "")
            XCTAssertFalse(a.isReaderModeByDefault)
            XCTAssertTrue(a.isReaderModeAvailable)
            XCTAssertTrue(a.isReaderModeOfferHidden)
            XCTAssertEqual(try Self.journalState(for: a, in: realm), seeded)

            let changed = try await ReaderContentLoader.persistPrimaryReaderModeDefaults(
                context: current, readabilityHTML: Self.html, resolvedTitle: "Current title"
            )
            XCTAssertTrue(changed, "The same real writer must work for the newly admitted selection")
            await realm.asyncRefresh()
            let selected = returnsToOriginal ? a : b
            XCTAssertEqual(selected.html, Self.html)
            XCTAssertEqual(selected.title, "Current title")
            XCTAssertTrue(selected.isReaderModeByDefault)
            XCTAssertFalse(selected.isReaderModeAvailable)
            XCTAssertFalse(selected.isReaderModeOfferHidden)
            let settled = try Self.journalState(for: selected, in: realm)
            let repeated = try await ReaderContentLoader.persistPrimaryReaderModeDefaults(
                context: current, readabilityHTML: Self.html, resolvedTitle: "Current title"
            )
            XCTAssertFalse(repeated)
            await realm.asyncRefresh()
            XCTAssertEqual(try Self.journalState(for: selected, in: realm), settled)
        }
    }

    @MainActor
    func testRelatedDiscoveryCannotCommitAfterItsActualReaderSelectionRetires() async throws {
        let configuration = makeConfiguration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try Realm(configuration: configuration)
        let url = URL(string: "https://example.com/related-selection/\(UUID().uuidString)")!
        let primary = configured(HistoryRecord(), url: url)
        let peer = configured(Bookmark(), url: url)
        let successor = configured(Bookmark(), url: url.appendingPathComponent("successor"))
        try seed([primary, peer, successor], in: realm)
        let seeded = try Self.journalState(for: peer, in: realm)
        let entered = expectation(description: "captured discovery reached its actual provider")
        entered.assertForOverFulfill = false
        let gate = ReaderModeSelectionDiscoveryGate()
        ReaderContentLoader.additionalContentProviders = [.init(id: "held-selection-provider") { _ in
            entered.fulfill()
            await gate.wait()
            return []
        }]
        let reader = ReaderContent()
        defer { withExtendedLifetime(reader) {} }
        let context = select(primary, in: reader)
        let propagation = Task { @RealmBackgroundActor in
            try await ReaderContentLoader.propagateReaderModeDefaults(
                for: url, context: context, readabilityHTML: Self.html, resolvedTitle: "Obsolete title"
            )
        }
        addTeardownBlock {
            propagation.cancel()
            await gate.release()
            _ = await propagation.result
        }
        await fulfillment(of: [entered], timeout: 2)
        _ = select(successor, in: reader)
        await gate.release()
        do {
            _ = try await propagation.value
            XCTFail("A withdrawn ReaderContent permit must fence related writes after discovery")
        } catch is CancellationError { }
        await realm.asyncRefresh()
        XCTAssertNil(peer.html)
        XCTAssertEqual(peer.title, "")
        XCTAssertEqual(try Self.journalState(for: peer, in: realm), seeded)

        let current = select(primary, in: reader)
        let changed = try await ReaderContentLoader.propagateReaderModeDefaults(
            for: url, context: current, readabilityHTML: Self.html, resolvedTitle: "Current title"
        )
        XCTAssertEqual(changed, 1)
        await realm.asyncRefresh()
        XCTAssertEqual(peer.html, Self.html)
        XCTAssertNotEqual(try Self.journalState(for: peer, in: realm).generation, seeded.generation)
    }

    @MainActor
    func testQueuedPrimaryRejectsRecreatedOrRetargetedRows() async throws {
        for recreate in [false, true] {
            let configuration = makeConfiguration()
            let restore = install(configuration)
            defer { restore() }
            let realm = try Realm(configuration: configuration)
            let url = URL(string: "https://example.com/primary-identity/\(UUID().uuidString)")!
            let primary = configured(Bookmark(), url: url)
            try seed([primary], in: realm)
            let key = primary.compoundKey
            let reader = ReaderContent()
            defer { withExtendedLifetime(reader) {} }
            let context = select(primary, in: reader)
            try await Self.beginFixtureWrite(configuration)
            let submitted = expectation(description: "identity test reached queued admission")
            let write = queuedPrimary(context, submitted: submitted)
            track(write, configuration: configuration)
            await fulfillment(of: [submitted], timeout: 2)
            let intervening = try await { @RealmBackgroundActor in
                let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                XCTAssertTrue(writer.isInWriteTransaction)
                let record = try XCTUnwrap(writer.object(ofType: Bookmark.self, forPrimaryKey: key))
                let changedRecord: Bookmark
                if recreate {
                    writer.delete(record)
                    let replacement = Bookmark()
                    replacement.compoundKey = key
                    replacement.url = url
                    replacement.createdAt = Self.seedDate.addingTimeInterval(1)
                    replacement.title = "Replacement"
                    writer.add(replacement)
                    replacement.refreshChangeMetadata(explicitlyModified: true)
                    changedRecord = replacement
                } else {
                    record.url = url.appendingPathComponent("retargeted")
                    record.title = "Retargeted"
                    record.refreshChangeMetadata(explicitlyModified: true)
                    changedRecord = record
                }
                let recorded = try Self.journalState(for: changedRecord, in: writer)
                try writer.commitWrite()
                return recorded
            }()
            let changed = try await write.value
            XCTAssertFalse(changed)
            await realm.asyncRefresh()
            let current = try XCTUnwrap(realm.object(ofType: Bookmark.self, forPrimaryKey: key))
            XCTAssertEqual(current.title, recreate ? "Replacement" : "Retargeted")
            XCTAssertNil(current.html)
            XCTAssertFalse(current.isReaderModeByDefault)
            let settled = try Self.journalState(for: current, in: realm)
            XCTAssertEqual(settled, intervening, "Rejected work must preserve the replacement's full journal")
            let repeated = try await ReaderContentLoader.persistPrimaryReaderModeDefaults(
                context: context, readabilityHTML: Self.html, resolvedTitle: "Obsolete title"
            )
            XCTAssertFalse(repeated)
            await realm.asyncRefresh()
            XCTAssertEqual(try Self.journalState(for: current, in: realm), settled)
        }
    }

    @MainActor
    func testPrimaryRechecksLiveBodyAndTitleAndUsesItsAdmittedTimestamp() async throws {
        let configuration = makeConfiguration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try Realm(configuration: configuration)
        let primary = configured(Bookmark(), url: URL(string: "https://example.com/live-primary/\(UUID().uuidString)")!)
        try seed([primary], in: realm)
        let key = primary.compoundKey
        let reader = ReaderContent()
        defer { withExtendedLifetime(reader) {} }
        let context = select(primary, in: reader)
        try await Self.beginFixtureWrite(configuration)
        let submitted = expectation(description: "primary queued before a fresh authoritative edit")
        let write = queuedPrimary(context, submitted: submitted)
        track(write, configuration: configuration)
        await fulfillment(of: [submitted], timeout: 2)
        let interveningTime = Date()
        let freshHTML = "<article><p>Newly captured full content.</p></article>"
        try await { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let record = try XCTUnwrap(writer.object(ofType: Bookmark.self, forPrimaryKey: key))
            record.title = "Fresh authoritative title"
            record.html = freshHTML
            record.refreshChangeMetadata(explicitlyModified: true, at: interveningTime)
            try writer.commitWrite()
        }()
        let changed = try await write.value
        XCTAssertTrue(changed, "Mode defaults still change while the later body/title are retained")
        await realm.asyncRefresh()
        XCTAssertEqual(primary.html, freshHTML)
        XCTAssertEqual(primary.title, "Fresh authoritative title")
        XCTAssertTrue(primary.isReaderModeByDefault)
        XCTAssertFalse(primary.isReaderModeAvailable)
        XCTAssertFalse(primary.isReaderModeOfferHidden)
        let settled = try Self.journalState(for: primary, in: realm)
        XCTAssertGreaterThanOrEqual(settled.changedAt, interveningTime)
        let repeated = try await ReaderContentLoader.persistPrimaryReaderModeDefaults(
            context: context, readabilityHTML: Self.html, resolvedTitle: "Obsolete title"
        )
        XCTAssertFalse(repeated)
        await realm.asyncRefresh()
        XCTAssertEqual(try Self.journalState(for: primary, in: realm), settled)
    }

    @MainActor
    func testCancelledPrimaryLeavesTheOtherOwnersTransactionIntact() async throws {
        let configuration = makeConfiguration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try Realm(configuration: configuration)
        let primary = configured(Bookmark(), url: URL(string: "https://example.com/cancel-primary/\(UUID().uuidString)")!)
        let other = configured(Bookmark(), url: primary.url.appendingPathComponent("other"))
        try seed([primary, other], in: realm)
        let seeded = try Self.journalState(for: primary, in: realm)
        let otherKey = other.compoundKey
        let reader = ReaderContent()
        defer { withExtendedLifetime(reader) {} }
        let context = select(primary, in: reader)
        try await Self.beginFixtureWrite(configuration)
        try await { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            writer.object(ofType: Bookmark.self, forPrimaryKey: otherKey)?.title = "Owned pending edit"
        }()
        let submitted = expectation(description: "cancelled primary submitted its independent ticket")
        let write = queuedPrimary(context, submitted: submitted)
        track(write, configuration: configuration)
        await fulfillment(of: [submitted], timeout: 2)
        write.cancel()
        do {
            _ = try await write.value
            XCTFail("Cancellation before admission must reject the primary writer")
        } catch is CancellationError { }
        try await { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            XCTAssertTrue(writer.isInWriteTransaction)
            guard writer.isInWriteTransaction else { return }
            let record = try XCTUnwrap(writer.object(ofType: Bookmark.self, forPrimaryKey: otherKey))
            XCTAssertEqual(record.title, "Owned pending edit")
            record.refreshChangeMetadata(explicitlyModified: true)
            try writer.commitWrite()
        }()
        await realm.asyncRefresh()
        XCTAssertEqual(other.title, "Owned pending edit")
        XCTAssertNil(primary.html)
        XCTAssertEqual(primary.title, "")
        XCTAssertEqual(try Self.journalState(for: primary, in: realm), seeded)
    }

    @MainActor
    func testPrimaryFeedEntryJournalsOnlyItsChangedOwners() async throws {
        for preference in [false, true] {
            for entryComplete in [false, true] {
                for feedComplete in [false, true] {
                    let configuration = makeConfiguration()
                    let restore = install(configuration)
                    defer { restore() }
                    let realm = try Realm(configuration: configuration)
                    let feed = Feed()
                    feed.rssUrl = URL(string: "https://example.com/primary-feed/\(UUID().uuidString).rss")!
                    feed.isReaderModeByDefault = preference
                    feed.rssContainsFullContent = feedComplete
                    let entry = FeedEntry()
                    entry.feedID = feed.id
                    entry.url = feed.rssUrl.deletingPathExtension()
                    entry.title = entryComplete ? "Existing title" : ""
                    if entryComplete { entry.html = Self.html }
                    entry.updateCompoundKey()
                    try realm.write {
                        realm.add(feed)
                        realm.add(entry)
                        feed.refreshChangeMetadata(explicitlyModified: true, at: Self.seedDate)
                        entry.refreshChangeMetadata(explicitlyModified: true, at: Self.seedDate)
                    }
                    let beforeFeed = try Self.journalState(for: feed, in: realm)
                    let beforeEntry = try Self.journalState(for: entry, in: realm)
                    let reader = ReaderContent()
                    defer { withExtendedLifetime(reader) {} }
                    let context = select(entry, in: reader)
                    let changed = try await ReaderContentLoader.persistPrimaryReaderModeDefaults(
                        context: context, readabilityHTML: Self.html, resolvedTitle: "Reader title"
                    )
                    XCTAssertEqual(changed, !entryComplete || !feedComplete)
                    await realm.asyncRefresh()
                    XCTAssertEqual(entry.title, entryComplete ? "Existing title" : "Reader title")
                    XCTAssertEqual(entry.html, Self.html)
                    XCTAssertEqual(feed.isReaderModeByDefault, preference)
                    XCTAssertEqual(entry.isReaderModeByDefault, preference)
                    XCTAssertEqual(entry.isReaderModeAvailable, preference)
                    XCTAssertTrue(feed.rssContainsFullContent)
                    let afterFeed = try Self.journalState(for: feed, in: realm)
                    let afterEntry = try Self.journalState(for: entry, in: realm)
                    if feedComplete { XCTAssertEqual(afterFeed, beforeFeed) }
                    else { XCTAssertNotEqual(afterFeed.generation, beforeFeed.generation) }
                    if entryComplete { XCTAssertEqual(afterEntry, beforeEntry) }
                    else { XCTAssertNotEqual(afterEntry.generation, beforeEntry.generation) }
                    if !entryComplete && !feedComplete { XCTAssertEqual(afterEntry.changedAt, afterFeed.changedAt) }
                    let repeated = try await ReaderContentLoader.persistPrimaryReaderModeDefaults(
                        context: context, readabilityHTML: Self.html, resolvedTitle: "Reader title"
                    )
                    XCTAssertFalse(repeated)
                    await realm.asyncRefresh()
                    XCTAssertEqual(try Self.journalState(for: feed, in: realm), afterFeed)
                    XCTAssertEqual(try Self.journalState(for: entry, in: realm), afterEntry)
                }
            }
        }
    }

    @MainActor
    func testPrimaryFeedEntryPreservesMissingAndDeletedOwners() async throws {
        for hasDeletedFeed in [false, true] {
            let configuration = makeConfiguration()
            let restore = install(configuration)
            defer { restore() }
            let realm = try Realm(configuration: configuration)
            let feed = Feed()
            feed.isDeleted = true
            let entry = FeedEntry()
            entry.feedID = feed.id
            entry.url = URL(string: "https://example.com/missing-primary-feed/\(UUID().uuidString)")!
            entry.title = "Existing title"
            entry.html = Self.html
            entry.updateCompoundKey()
            try realm.write {
                if hasDeletedFeed {
                    realm.add(feed)
                    feed.refreshChangeMetadata(explicitlyModified: true, at: Self.seedDate)
                }
                realm.add(entry)
                entry.refreshChangeMetadata(explicitlyModified: true, at: Self.seedDate)
            }
            let beforeEntry = try Self.journalState(for: entry, in: realm)
            let beforeFeed: JournalState?
            if hasDeletedFeed { beforeFeed = try Self.journalState(for: feed, in: realm) }
            else { beforeFeed = nil }
            let reader = ReaderContent()
            defer { withExtendedLifetime(reader) {} }
            let context = select(entry, in: reader)
            let changed = try await ReaderContentLoader.persistPrimaryReaderModeDefaults(
                context: context, readabilityHTML: Self.html, resolvedTitle: "Reader title"
            )
            XCTAssertFalse(changed)
            await realm.asyncRefresh()
            XCTAssertEqual(try Self.journalState(for: entry, in: realm), beforeEntry)
            if let beforeFeed {
                XCTAssertTrue(feed.isDeleted)
                XCTAssertFalse(feed.rssContainsFullContent)
                XCTAssertEqual(try Self.journalState(for: feed, in: realm), beforeFeed)
            }
        }
    }

    @MainActor
    func testUnmanagedPrimaryCannotNominateTheConfiguredDurableStore() async throws {
        let configuration = makeConfiguration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try Realm(configuration: configuration)
        let url = URL(string: "https://example.com/unmanaged-primary/\(UUID().uuidString)")!
        let durable = configured(Bookmark(), url: url)
        try seed([durable], in: realm)
        let before = try Self.journalState(for: durable, in: realm)
        let unmanaged = configured(Bookmark(), url: url)
        XCTAssertEqual(unmanaged.compoundKey, durable.compoundKey)
        let reader = ReaderContent()
        defer { withExtendedLifetime(reader) {} }
        let context = select(unmanaged, in: reader)
        let changed = try await ReaderContentLoader.persistPrimaryReaderModeDefaults(
            context: context, readabilityHTML: Self.html, resolvedTitle: "Unmanaged title"
        )
        XCTAssertFalse(changed)
        XCTAssertNil(durable.html)
        XCTAssertEqual(durable.title, "")
        XCTAssertEqual(try Self.journalState(for: durable, in: realm), before)
    }

    @MainActor
    func testShowReaderViewRetainsItsOriginatingSelectionAcrossPreparationAndSameURLReturn() async throws {
        for replacesWhilePreparing in [false, true] {
            let configuration = makeConfiguration()
            let restore = install(configuration)
            defer { restore() }
            let realm = try Realm(configuration: configuration)
            let url = URL(string: "https://example.com/caller-preparation/\(UUID().uuidString)")!
            let primary = configured(Bookmark(), url: url)
            let related = configured(HistoryRecord(), url: url)
            let other = configured(Bookmark(), url: url.appendingPathComponent("other"))
            try seed([primary, related, other], in: realm)
            let primaryBefore = try Self.journalState(for: primary, in: realm)
            let relatedBefore = try Self.journalState(for: related, in: realm)
            let reader = ReaderContent()
            defer { withExtendedLifetime(reader) {} }
            _ = select(primary, in: reader)
            let preparedHTML = """
            <html><body class="readability-mode"><h1 id="reader-title">Prepared title</h1>
            <main id="reader-content"><p>Obsolete prepared content.</p></main></body></html>
            """
            let mode = ReaderModeViewModel()
            mode.readabilityContent = preparedHTML
            // The real primary writer runs before this injected processor. Stop
            // there so this persistence fixture never dispatches a WebKit load.
            mode.processReadabilityContent = { _, _, _, _, _, _, _ in
                throw ReaderModeSelectionFixtureError.stopAfterPrimaryPersistence
            }
            let caller = WebViewScriptCaller()
            let preparing = expectation(description: "actual render is awaiting publication-date preparation")
            preparing.assertForOverFulfill = false
            let gate = ReaderModeSelectionDiscoveryGate()
            ReaderContentLoader.additionalContentProviders = [.init(id: "held-render-preparation") { _ in
                preparing.fulfill()
                await gate.wait()
                return []
            }]

            mode.showReaderView(readerContent: reader, scriptCaller: caller)
            let render = try XCTUnwrap(mode.activeRenderTask(for: url))
            let originalGeneration = mode.currentRenderGenerationDescription(for: url)
            XCTAssertNotEqual(originalGeneration, "nil")
            addTeardownBlock {
                render.cancel()
                await gate.release()
                await render.value
            }
            await fulfillment(of: [preparing], timeout: 2)
            mode.showReaderView(readerContent: reader, scriptCaller: caller)
            XCTAssertEqual(mode.currentRenderGenerationDescription(for: url), originalGeneration,
                "The same selection still coalesces its active render")
            _ = select(other, in: reader)
            _ = select(primary, in: reader)
            if !replacesWhilePreparing {
                await gate.release()
                await render.value
            }
            await realm.asyncRefresh()
            XCTAssertNil(primary.html)
            XCTAssertEqual(primary.title, "")
            XCTAssertFalse(primary.isReaderModeByDefault)
            XCTAssertTrue(primary.isReaderModeOfferHidden)
            XCTAssertNil(related.html)
            XCTAssertEqual(try Self.journalState(for: primary, in: realm), primaryBefore)
            XCTAssertEqual(try Self.journalState(for: related, in: realm), relatedBefore)

            // Supply the current render's date directly, so it can proceed
            // while the retired render remains at the real provider boundary.
            mode.readabilityContent = """
            <html><body class="readability-mode"><h1 id="reader-title">Current title</h1>
            <span id="reader-publication-date">Current date</span>
            <main id="reader-content"><p>Current selection content.</p></main></body></html>
            """
            let currentProcessing = replacesWhilePreparing
                ? expectation(description: "current selection reached processing after persistence") : nil
            let currentGate = ReaderModeSelectionDiscoveryGate()
            if let currentProcessing {
                mode.processReadabilityContent = { _, _, _, _, _, _, _ in
                    currentProcessing.fulfill()
                    await currentGate.wait()
                    throw ReaderModeSelectionFixtureError.stopAfterPrimaryPersistence
                }
            }
            mode.showReaderView(readerContent: reader, scriptCaller: caller)
            let currentGeneration = mode.currentRenderGenerationDescription(for: url)
            guard currentGeneration != originalGeneration else {
                await gate.release()
                await render.value
                XCTFail("A retired selection must not retain the same-URL single-flight slot")
                return
            }
            let currentRender = try XCTUnwrap(mode.activeRenderTask(for: url))
            addTeardownBlock {
                currentRender.cancel()
                await currentGate.release()
                await currentRender.value
            }
            if let currentProcessing {
                await fulfillment(of: [currentProcessing], timeout: 2)
                await realm.asyncRefresh()
                let admittedJournal = try Self.journalState(for: primary, in: realm)
                await gate.release()
                await render.value
                XCTAssertEqual(mode.currentRenderGenerationDescription(for: url), currentGeneration)
                XCTAssertTrue(mode.isReadabilityRenderInFlight(for: url))
                XCTAssertTrue(mode.isReaderModeLoading, "Retired completion must not clear the successor's busy state")
                await realm.asyncRefresh()
                XCTAssertEqual(try Self.journalState(for: primary, in: realm), admittedJournal)
                await currentGate.release()
            }
            await currentRender.value
            await realm.asyncRefresh()
            XCTAssertTrue(primary.html?.contains("Current selection content.") == true)
            XCTAssertFalse(primary.html?.contains("Obsolete prepared content.") == true)
            XCTAssertFalse(primary.title.isEmpty)
            XCTAssertTrue(primary.isReaderModeByDefault)
            XCTAssertFalse(primary.isReaderModeOfferHidden)
            XCTAssertNotEqual(try Self.journalState(for: primary, in: realm).generation, primaryBefore.generation)
            XCTAssertEqual(try Self.journalState(for: related, in: realm), relatedBefore)
        }
    }

    @MainActor
    func testShowReadabilityContentCarriesItsSelectionIntoTheQueuedPrimaryWriter() async throws {
        let configuration = makeConfiguration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try Realm(configuration: configuration)
        let url = URL(string: "https://example.com/caller-admission/\(UUID().uuidString)")!
        let primary = configured(Bookmark(), url: url)
        let related = configured(HistoryRecord(), url: url)
        let other = configured(Bookmark(), url: url.appendingPathComponent("other"))
        try seed([primary, related, other], in: realm)
        let primaryBefore = try Self.journalState(for: primary, in: realm)
        let relatedBefore = try Self.journalState(for: related, in: realm)
        let reader = ReaderContent()
        defer { withExtendedLifetime(reader) {} }
        _ = select(primary, in: reader)
        let mode = ReaderModeViewModel()
        let caller = WebViewScriptCaller()
        let selectionIsCurrent = reader.makeSelectionCommitFence(requiring: reader.currentSelectionID)
        let submitted = expectation(description: "actual Reader-mode caller submitted its primary write")
        try await Self.beginFixtureWrite(configuration)
        let started = RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
            mode.startRenderTaskIfNeeded(
                for: url, reason: "selection-persistence-fixture", selectionIsCurrent: selectionIsCurrent
            ) { generation in
                do {
                    try await mode.showReadabilityContent(
                        readerContent: reader, readabilityContent: Self.html,
                        renderToSelector: nil, in: nil, scriptCaller: caller,
                        renderURL: url, renderGeneration: generation
                    )
                    XCTFail("The retired caller must fail its queued primary admission")
                } catch is CancellationError {
                } catch {
                    XCTFail("Unexpected Reader-mode persistence error: \(error)")
                }
            }
        }
        XCTAssertTrue(started)
        let render = try XCTUnwrap(mode.activeRenderTask(for: url))
        addTeardownBlock {
            render.cancel()
            await render.value
            await Self.cancelFixtureWrite(owner: RealmBackgroundActor.shared, configuration: configuration)
        }
        await fulfillment(of: [submitted], timeout: 2)
        _ = select(other, in: reader)
        _ = select(primary, in: reader)
        try await Self.commitFixtureWrite(configuration)
        await render.value
        await realm.asyncRefresh()
        XCTAssertNil(primary.html)
        XCTAssertNil(related.html)
        XCTAssertFalse(primary.isReaderModeByDefault)
        XCTAssertTrue(primary.isReaderModeAvailable)
        XCTAssertTrue(primary.isReaderModeOfferHidden)
        XCTAssertEqual(try Self.journalState(for: primary, in: realm), primaryBefore)
        XCTAssertEqual(try Self.journalState(for: related, in: realm), relatedBefore)
    }

    @MainActor
    func testRetiredRenderDetachesBeforeItsCancellationHandlerStartsTheCurrentSelection() async throws {
        let url = URL(string: "https://example.com/reentrant-selection/\(UUID().uuidString)")!
        let primary = configured(Bookmark(), url: url)
        let other = configured(Bookmark(), url: url.appendingPathComponent("other"))
        let reader = ReaderContent()
        defer { withExtendedLifetime(reader) {} }
        reader.replaceSelection(with: primary)
        reader.pageURL = url
        let originalFence = reader.makeSelectionCommitFence(requiring: reader.currentSelectionID)
        let mode = ReaderModeViewModel()
        let entered = expectation(description: "actual render installed its cancellation handler")
        let originalGate = ReaderModeSelectionDiscoveryGate()
        let successorGate = ReaderModeSelectionDiscoveryGate()
        let receipt = ReaderModeSelectionTaskReceipt()
        let started = mode.startRenderTaskIfNeeded(
            for: url, reason: "reentry-original", selectionIsCurrent: originalFence
        ) { _ in
            // Registration also belongs to MainActor: an already-cancelled
            // task invokes onCancel immediately when the handler is installed.
            await { @MainActor in
                await withTaskCancellationHandler {
                    entered.fulfill()
                    await originalGate.wait()
                } onCancel: {
                    // All fixture cancellation calls use MainActor-owned APIs.
                    MainActor.assumeIsolated {
                        guard !originalFence(), reader.content != nil else { return }
                        let fence = reader.makeSelectionCommitFence(requiring: reader.currentSelectionID)
                        XCTAssertTrue(mode.startRenderTaskIfNeeded(
                            for: url, reason: "reentry-successor", selectionIsCurrent: fence
                        ) { _ in await successorGate.wait() })
                        receipt.task = mode.activeRenderTask(for: url)
                    }
                }
            }()
        }
        XCTAssertTrue(started)
        let originalTask = try XCTUnwrap(mode.activeRenderTask(for: url))
        let originalGeneration = mode.currentRenderGenerationDescription(for: url)
        addTeardownBlock {
            let tasks = await MainActor.run {
                reader.replaceSelection(with: nil)
                let active = mode.activeRenderTask(for: url)
                mode.cancelReaderModeLoad(for: url, reason: "reentry-fixture-cleanup")
                originalTask.cancel()
                return [active, receipt.task].compactMap { $0 }
            }
            await originalGate.release()
            await successorGate.release()
            await originalTask.value
            for task in tasks { await task.value }
        }
        await fulfillment(of: [entered], timeout: 2)
        reader.replaceSelection(with: other)
        reader.replaceSelection(with: primary)
        let currentFence = reader.makeSelectionCommitFence(requiring: reader.currentSelectionID)
        let outerStarted = mode.startRenderTaskIfNeeded(
            for: url, reason: "reentry-outer", selectionIsCurrent: currentFence
        ) { _ in
            XCTFail("The outer start must coalesce the successor created during cancellation")
        }
        XCTAssertFalse(outerStarted)
        let successor = try XCTUnwrap(receipt.task)
        let currentGeneration = mode.currentRenderGenerationDescription(for: url)
        XCTAssertNotEqual(currentGeneration, originalGeneration)
        XCTAssertNotEqual(currentGeneration, "nil")
        await originalGate.release()
        await originalTask.value
        XCTAssertEqual(mode.currentRenderGenerationDescription(for: url), currentGeneration)
        XCTAssertTrue(mode.isReadabilityRenderInFlight(for: url))
        await successorGate.release()
        await successor.value
        XCTAssertNil(mode.activeRenderTask(for: url))
    }
}
