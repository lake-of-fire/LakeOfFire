import BigSyncKit
import Combine
import RealmSwift
import XCTest
@testable import LakeOfFireContent
@testable import RealmSwiftGaps

private actor TitleEditProviderGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseWaiters = [CheckedContinuation<Void, Never>]()

    func pause() async {
        arrived = true
        let pending = arrivalWaiters
        arrivalWaiters.removeAll()
        pending.forEach { $0.resume() }
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }

    func waitForArrival() async -> Bool {
        if !arrived && !released {
            await withCheckedContinuation { arrivalWaiters.append($0) }
        }
        return arrived
    }

    func release() {
        released = true
        let pending = arrivalWaiters + releaseWaiters
        arrivalWaiters.removeAll()
        releaseWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func hasArrived() -> Bool { arrived }
}

private final class TitleEditAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true

    func permitsCommit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowed
    }

    func withdraw() {
        lock.lock()
        allowed = false
        lock.unlock()
    }
}

private enum TitleEditFixtureError: Error {
    case providerFailed
    case missingHeldWrite
}

private actor TitleEditRetryingProvider {
    private var shouldFail = true

    func load() throws -> [ReaderContentLoader.ContentReference] {
        if shouldFail {
            shouldFail = false
            throw TitleEditFixtureError.providerFailed
        }
        return []
    }
}

@RealmBackgroundActor
private final class TitleEditFixtureWrite {
    private var heldRealm: Realm?

    func begin(_ configuration: Realm.Configuration) async throws {
        XCTAssertNil(heldRealm)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        XCTAssertFalse(realm.isInWriteTransaction)
        try realm.beginWrite()
        heldRealm = realm
    }

    func commit() throws {
        guard let realm = heldRealm else {
            XCTFail("Only the fixture's still-owned write may be committed")
            return
        }
        heldRealm = nil
        XCTAssertTrue(realm.isInWriteTransaction)
        guard realm.isInWriteTransaction else { return }
        do {
            try realm.commitWrite()
        } catch {
            if realm.isInWriteTransaction { realm.cancelWrite() }
            throw error
        }
    }

    func cancelOwnedWrite() {
        guard let realm = heldRealm else { return }
        heldRealm = nil
        // No cache lookup or reopened Realm: normal fixture commit retires
        // the only admitted transaction this holder may release.
        if realm.isInWriteTransaction { realm.cancelWrite() }
    }
}

@MainActor
private final class TitleEditSettlement {
    var result: Result<Bool, Error>?
}

@MainActor
final class ReaderContentTitleEditingTests: XCTestCase {
    private static let seedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private struct JournalState: Equatable, Sendable {
        let generation: String
        let modifiedAt: Date
        let explicitlyModifiedAt: Date?
        let changedAt: Date
    }

    private func configuration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, HistoryRecord.self, ContentFile.self, Feed.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let captured = configuration
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: captured)
        }
        return configuration
    }

    private func install(_ configuration: Realm.Configuration) -> @MainActor () -> Void {
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

    private func record<T: Bookmark>(
        _ record: T, url: URL? = nil, title: String = "Original", html: String = "<p>Alpha</p>"
    ) -> T {
        record.url = url ?? ReaderContentLoader.snippetURL(key: UUID().uuidString)!
        record.title = title
        record.html = html
        record.createdAt = Self.seedDate
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

    private func journal(_ record: Object & ChangeMetadataRecordable, in realm: Realm) throws -> JournalState {
        let keyName = try XCTUnwrap(record.objectSchema.primaryKeyProperty?.name)
        let key = String(describing: try XCTUnwrap(record[keyName]))
        let pending = try XCTUnwrap(realm.object(ofType: BigSyncPendingMutation.self,
            forPrimaryKey: record.objectSchema.className + "." + key))
        XCTAssertFalse(pending.generation.isEmpty)
        XCTAssertEqual(record.modifiedAt, pending.changedAt)
        XCTAssertEqual(record.explicitlyModifiedAt, pending.changedAt)
        return JournalState(generation: pending.generation, modifiedAt: record.modifiedAt,
            explicitlyModifiedAt: record.explicitlyModifiedAt, changedAt: pending.changedAt)
    }

    private func select(_ content: any ReaderContentProtocol, in reader: ReaderContent) throws -> ReaderContent.TitleEditTarget {
        reader.pageURL = content.url
        reader.replaceSelection(with: content)
        return try XCTUnwrap(reader.captureTitleEditTarget())
    }

    private func pauseDiscovery() -> TitleEditProviderGate {
        let gate = TitleEditProviderGate()
        ReaderContentLoader.additionalContentProviders = [.init(id: "held-title-provider") { _ in
            await gate.pause()
            return []
        }]
        return gate
    }

    private func awaitProvider(
        _ gate: TitleEditProviderGate, task: Task<Bool, Error>, fixture: TitleEditFixtureWrite? = nil
    ) async -> Bool {
        track(task, fixture: fixture, gate: gate)
        let entered = expectation(description: "actual title writer reached its captured provider")
        let arrival = Task {
            if await gate.waitForArrival() { entered.fulfill() }
        }
        addTeardownBlock {
            await gate.release()
            await arrival.value
        }
        await fulfillment(of: [entered], timeout: 2)
        return await gate.hasArrived()
    }

    private func queued(
        reader: ReaderContent, target: ReaderContent.TitleEditTarget,
        title: String, submitted: XCTestExpectation,
        permitsCommit: @escaping @Sendable () -> Bool = { true }
    ) -> Task<Bool, Error> {
        submitted.assertForOverFulfill = false
        return Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await reader.updateContentTitle(title, target: target, permitsCommit: permitsCommit)
            }
        }
    }

    private func track(
        _ task: Task<Bool, Error>, fixture: TitleEditFixtureWrite? = nil, gate: TitleEditProviderGate? = nil
    ) {
        addTeardownBlock {
            task.cancel()
            await gate?.release()
            // Release only the fixture-owned blocker before joining. Joining
            // first would hang on the cancellation regression under test.
            await fixture?.cancelOwnedWrite()
            _ = await task.result
        }
    }

    private func settlement(
        of task: Task<Bool, Error>, fixture: TitleEditFixtureWrite
    ) async -> Result<Bool, Error> {
        let completed = expectation(description: "queued title edit settled without taking the fixture's write")
        let observation = TitleEditSettlement()
        let observer = Task { @MainActor in
            observation.result = await task.result
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        if observation.result == nil {
            // XCTest recorded the bounded failure. Unblock only our held
            // transaction before joining the production task for cleanup.
            task.cancel()
            await fixture.cancelOwnedWrite()
        }
        let result = await task.result
        await observer.value
        return result
    }

    func testLegacyManagedCallerJournalsTitleAndPrefixWithoutOutOfWriteMutation() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let content = record(HistoryRecord())
        try seed([content], in: realm)
        let before = try journal(content, in: realm)
        let reader = ReaderContent()
        _ = try select(content, in: reader)

        await reader.updateContentTitle("  Alpha \n")

        await realm.asyncRefresh()
        XCTAssertEqual(content.title, "Alpha")
        XCTAssertTrue(content.isTitlePrefixOfContent)
        XCTAssertEqual(reader.contentTitle, "Alpha")
        XCTAssertTrue(reader.snippetTitleIsGeneratedFromPrefix)
        XCTAssertNotEqual(try journal(content, in: realm).generation, before.generation)
    }

    func testEmptyInputAndRepeatedEqualStateDoNotJournalButEqualTitleRepairsPrefix() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let content = record(Bookmark(), title: "Alpha")
        content.isTitlePrefixOfContent = false
        try seed([content], in: realm)
        let reader = ReaderContent()
        let target = try select(content, in: reader)
        let before = try journal(content, in: realm)

        let empty = try await reader.updateContentTitle(" \n ", target: target, permitsCommit: { true })
        XCTAssertFalse(empty)
        XCTAssertEqual(try journal(content, in: realm), before)

        let repaired = try await reader.updateContentTitle("Alpha", target: target, permitsCommit: { true })
        XCTAssertTrue(repaired)
        await realm.asyncRefresh()
        XCTAssertTrue(content.isTitlePrefixOfContent)
        let repairedJournal = try journal(content, in: realm)
        XCTAssertNotEqual(repairedJournal.generation, before.generation)

        let repeated = try await reader.updateContentTitle(" Alpha ", target: target, permitsCommit: { true })
        XCTAssertFalse(repeated)
        await realm.asyncRefresh()
        XCTAssertEqual(try journal(content, in: realm), repairedJournal)
    }

    func testRelatedRepresentationsUseTheirOwnBodiesAndOneTransactionTimestamp() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        let related = record(Bookmark(), url: primary.url, html: "<p>Beta</p>")
        try seed([primary, related], in: realm)
        XCTAssertEqual(primary.compoundKey, related.compoundKey)
        let reader = ReaderContent()
        let target = try select(primary, in: reader)

        let changed = try await reader.updateContentTitle("Alpha", target: target, permitsCommit: { true })

        XCTAssertTrue(changed)
        await realm.asyncRefresh()
        XCTAssertEqual(primary.title, "Alpha")
        XCTAssertEqual(related.title, "Alpha")
        XCTAssertTrue(primary.isTitlePrefixOfContent)
        XCTAssertFalse(related.isTitlePrefixOfContent)
        XCTAssertEqual(try journal(primary, in: realm).changedAt, try journal(related, in: realm).changedAt)
    }

    func testCaptureKeepsOriginalStoresAndProvidersWhenDefaultsChange() async throws {
        let original = configuration()
        let replacement = configuration()
        let restore = install(original)
        defer { restore() }
        let originalRealm = try await Realm(configuration: original)
        let replacementRealm = try await Realm(configuration: replacement)
        let primary = record(HistoryRecord())
        let otherAccount = record(HistoryRecord(), url: primary.url, title: "Other account")
        try seed([primary], in: originalRealm)
        try seed([otherAccount], in: replacementRealm)
        let otherBefore = try journal(otherAccount, in: replacementRealm)
        let reader = ReaderContent()
        let target = try select(primary, in: reader)
        ReaderContentLoader.historyRealmConfiguration = replacement
        ReaderContentLoader.feedEntryRealmConfiguration = replacement
        ReaderContentLoader.bookmarkRealmConfiguration = replacement
        ReaderContentLoader.additionalContentProviders = [.init(id: "replacement-provider") { _ in
            XCTFail("A captured edit must not discover through a later provider registration")
            return []
        }]

        let changed = try await reader.updateContentTitle("Captured account title", target: target, permitsCommit: { true })

        XCTAssertTrue(changed)
        await originalRealm.asyncRefresh()
        await replacementRealm.asyncRefresh()
        XCTAssertEqual(primary.title, "Captured account title")
        XCTAssertEqual(otherAccount.title, "Other account")
        XCTAssertEqual(try journal(otherAccount, in: replacementRealm), otherBefore)
    }

    func testProviderFailureDoesNotOptimisticallyChangeTitleAndSameTargetCanRetry() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        try seed([primary], in: realm)
        let before = try journal(primary, in: realm)
        let provider = TitleEditRetryingProvider()
        ReaderContentLoader.additionalContentProviders = [.init(id: "retrying-title-provider") { _ in
            try await provider.load()
        }]
        let reader = ReaderContent()
        let target = try select(primary, in: reader)

        do {
            _ = try await reader.updateContentTitle("Retry title", target: target, permitsCommit: { true })
            XCTFail("The captured provider should fail its first discovery")
        } catch TitleEditFixtureError.providerFailed { }
        XCTAssertEqual(primary.title, "Original")
        XCTAssertEqual(reader.contentTitle, "Original")
        XCTAssertEqual(try journal(primary, in: realm), before)

        let changed = try await reader.updateContentTitle("Retry title", target: target, permitsCommit: { true })
        XCTAssertTrue(changed)
        await realm.asyncRefresh()
        XCTAssertEqual(primary.title, "Retry title")
        XCTAssertEqual(reader.contentTitle, "Retry title")
    }

    func testQueuedWriteDerivesPrefixFromInterveningBodyAndPreservesNewerFields() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        try seed([primary], in: realm)
        let key = primary.compoundKey
        let gate = pauseDiscovery()
        let reader = ReaderContent()
        let target = try select(primary, in: reader)
        let fixture = await TitleEditFixtureWrite()
        let submitted = expectation(description: "title writer queued its own SDK ticket")
        let write = queued(reader: reader, target: target, title: "Alpha", submitted: submitted)
        guard await awaitProvider(gate, task: write, fixture: fixture) else { return }
        try await fixture.begin(configuration)
        await gate.release()
        await fulfillment(of: [submitted], timeout: 2)
        let interveningTime = Date()
        try await { @RealmBackgroundActor in
            let owner = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            XCTAssertTrue(owner.isInWriteTransaction)
            guard owner.isInWriteTransaction else { return }
            let record = try XCTUnwrap(owner.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            record.html = "<p>Beta</p>"
            record.author = "Intervening author"
            record.refreshChangeMetadata(explicitlyModified: true, at: interveningTime)
            try fixture.commit()
        }()

        let changed = try await write.value

        XCTAssertTrue(changed)
        await realm.asyncRefresh()
        XCTAssertEqual(primary.title, "Alpha")
        XCTAssertFalse(primary.isTitlePrefixOfContent, "Prefix must come from Beta inside the admitted write")
        XCTAssertEqual(primary.html, "<p>Beta</p>")
        XCTAssertEqual(primary.author, "Intervening author")
        XCTAssertGreaterThanOrEqual(try journal(primary, in: realm).changedAt, interveningTime)
    }

    func testTombstoneOrSameKeyReplacementCannotAcquireCapturedPrimaryAuthority() async throws {
        for replace in [false, true] {
            let configuration = configuration()
            let restore = install(configuration)
            defer { restore() }
            let realm = try await Realm(configuration: configuration)
            let primary = record(HistoryRecord())
            let related = record(Bookmark(), url: primary.url)
            try seed([primary, related], in: realm)
            let key = primary.compoundKey
            let url = primary.url
            let relatedBefore = try journal(related, in: realm)
            let gate = pauseDiscovery()
            let reader = ReaderContent()
            let target = try select(primary, in: reader)
            let write = Task { try await reader.updateContentTitle("Retired title", target: target, permitsCommit: { true }) }
            guard await awaitProvider(gate, task: write) else { return }

            try await { @RealmBackgroundActor in
                let owner = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                try await owner.asyncWritePreservingOwnership {
                    let old = try XCTUnwrap(owner.object(ofType: HistoryRecord.self, forPrimaryKey: key))
                    if replace {
                        let replacement = HistoryRecord()
                        replacement.url = url
                        replacement.title = "Successor"
                        replacement.createdAt = old.createdAt.addingTimeInterval(1)
                        replacement.updateCompoundKey()
                        XCTAssertEqual(replacement.compoundKey, key)
                        owner.delete(old) // Fixture-only same-key recreation; production preserves tombstones.
                        owner.add(replacement)
                        replacement.refreshChangeMetadata(explicitlyModified: true)
                    } else {
                        old.isDeleted = true
                        old.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            }()
            await realm.asyncRefresh()
            let current = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            let retiredBefore = try journal(current, in: realm)
            await gate.release()

            let changed = try await write.value

            XCTAssertFalse(changed)
            await realm.asyncRefresh()
            XCTAssertEqual(current.title, replace ? "Successor" : "Original")
            XCTAssertEqual(current.isDeleted, !replace)
            XCTAssertEqual(try journal(current, in: realm), retiredBefore)
            XCTAssertEqual(related.title, "Original")
            XCTAssertEqual(try journal(related, in: realm), relatedBefore)
        }
    }

    func testQueuedTitleRejectsEqualFieldsPhysicalPrimaryReplacement() async throws {
        try await assertQueuedEqualFieldsReplacement(frozen: false, replacesPrimary: true)
    }

    func testQueuedFrozenTitleRejectsEqualFieldsPhysicalPrimaryReplacement() async throws {
        try await assertQueuedEqualFieldsReplacement(frozen: true, replacesPrimary: true)
    }

    func testQueuedTitleSkipsEqualFieldsPhysicalRelatedReplacement() async throws {
        try await assertQueuedEqualFieldsReplacement(frozen: false, replacesPrimary: false)
    }

    private func assertQueuedEqualFieldsReplacement(frozen: Bool, replacesPrimary: Bool) async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        let related = record(Bookmark(), url: primary.url, title: "Related original", html: "<p>Related body</p>")
        try seed([primary, related], in: realm)
        let primaryBefore = try journal(primary, in: realm)
        let relatedBefore = try journal(related, in: realm)
        let replaced: Bookmark = replacesPrimary ? primary : related
        let originalID = replaced.id
        let primaryID = primary.id
        let key = replaced.compoundKey
        let url = replaced.url
        let creationDate = replaced.createdAt
        let replacementDate = Self.seedDate.addingTimeInterval(2)
        let source = frozen ? primary.freeze() : primary
        XCTAssertEqual(source.id, primaryID)
        let gate = pauseDiscovery()
        let reader = ReaderContent()
        let target = try select(source, in: reader)
        let fixture = await TitleEditFixtureWrite()
        let submitted = expectation(description: "captured title queued before equal-fields physical replacement")
        let write = queued(reader: reader, target: target, title: "Alpha", submitted: submitted)
        guard await awaitProvider(gate, task: write, fixture: fixture) else { return }
        try await fixture.begin(configuration)
        await gate.release()
        await fulfillment(of: [submitted], timeout: 2)
        if frozen {
            // The explicit target survives navigation. Keep this fixture about
            // durable admission, without trying to refresh a frozen presentation.
            reader.replaceSelection(with: nil)
        }

        let replacementState = try await { @RealmBackgroundActor in
            let owner = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            guard owner.isInWriteTransaction else { throw TitleEditFixtureError.missingHeldWrite }
            let old: Bookmark
            if replacesPrimary {
                old = try XCTUnwrap(owner.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            } else {
                old = try XCTUnwrap(owner.object(ofType: Bookmark.self, forPrimaryKey: key))
            }
            XCTAssertEqual(old.id, originalID)
            owner.delete(old) // Fixture-only physical recreation; production keeps deletion tombstones.
            let replacement: Bookmark = replacesPrimary ? HistoryRecord() : Bookmark()
            replacement.compoundKey = key
            replacement.url = url
            replacement.createdAt = creationDate
            replacement.title = "Replacement"
            replacement.author = "Replacement author"
            replacement.html = "<p>Replacement body</p>"
            replacement.isTitlePrefixOfContent = true
            owner.add(replacement)
            XCTAssertNotEqual(replacement.id, originalID)
            replacement.refreshChangeMetadata(explicitlyModified: true, at: replacementDate)
            let pending = try XCTUnwrap(owner.object(ofType: BigSyncPendingMutation.self,
                forPrimaryKey: replacement.objectSchema.className + "." + key))
            let state = (id: replacement.id, title: replacement.title, author: replacement.author,
                         html: replacement.html, prefix: replacement.isTitlePrefixOfContent,
                         generation: pending.generation, modifiedAt: replacement.modifiedAt,
                         explicitlyModifiedAt: replacement.explicitlyModifiedAt, changedAt: pending.changedAt)
            try fixture.commit()
            return state
        }()

        let changed = try await write.value
        XCTAssertEqual(changed, !replacesPrimary)
        await realm.asyncRefresh()
        let replacement: Bookmark
        if replacesPrimary {
            replacement = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
        } else {
            replacement = try XCTUnwrap(realm.object(ofType: Bookmark.self, forPrimaryKey: key))
        }
        XCTAssertEqual(replacement.id, replacementState.id)
        XCTAssertNotEqual(replacement.id, originalID)
        XCTAssertEqual(replacement.compoundKey, key)
        XCTAssertEqual(replacement.createdAt, creationDate)
        XCTAssertEqual(replacement.url, url)
        XCTAssertEqual(replacement.title, replacementState.title)
        XCTAssertEqual(replacement.author, replacementState.author)
        XCTAssertEqual(replacement.html, replacementState.html)
        XCTAssertEqual(replacement.isTitlePrefixOfContent, replacementState.prefix)
        XCTAssertEqual(try journal(replacement, in: realm), JournalState(
            generation: replacementState.generation, modifiedAt: replacementState.modifiedAt,
            explicitlyModifiedAt: replacementState.explicitlyModifiedAt, changedAt: replacementState.changedAt))
        if replacesPrimary {
            XCTAssertEqual(related.title, "Related original")
            XCTAssertFalse(related.isTitlePrefixOfContent)
            XCTAssertEqual(try journal(related, in: realm), relatedBefore)
        } else {
            XCTAssertEqual(primary.id, primaryID)
            XCTAssertEqual(primary.title, "Alpha")
            XCTAssertTrue(primary.isTitlePrefixOfContent)
            XCTAssertNotEqual(try journal(primary, in: realm).generation, primaryBefore.generation)
        }
        if frozen {
            XCTAssertFalse(source.isInvalidated)
            XCTAssertEqual(source.id, primaryID)
            XCTAssertEqual(source.title, "Original")
        }
    }

    func testQueuedCancellationLeavesTheOtherOwnersPendingWriteIntact() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        try seed([primary], in: realm)
        let key = primary.compoundKey
        let gate = pauseDiscovery()
        let reader = ReaderContent()
        let target = try select(primary, in: reader)
        let fixture = await TitleEditFixtureWrite()
        let submitted = expectation(description: "cancelled edit submitted its independent ticket")
        let write = queued(reader: reader, target: target, title: "Cancelled title", submitted: submitted)
        guard await awaitProvider(gate, task: write, fixture: fixture) else { return }
        try await fixture.begin(configuration)
        try await { @RealmBackgroundActor in
            let owner = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            owner.object(ofType: HistoryRecord.self, forPrimaryKey: key)?.title = "Other owner's pending edit"
        }()
        await gate.release()
        await fulfillment(of: [submitted], timeout: 2)

        write.cancel()
        do {
            let result = await settlement(of: write, fixture: fixture)
            _ = try result.get()
            XCTFail("Cancellation before title admission must throw")
        } catch is CancellationError { }

        try await { @RealmBackgroundActor in
            let owner = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            XCTAssertTrue(owner.isInWriteTransaction)
            let record = try XCTUnwrap(owner.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            XCTAssertEqual(record.title, "Other owner's pending edit")
            guard owner.isInWriteTransaction else { return }
            record.refreshChangeMetadata(explicitlyModified: true)
            try fixture.commit()
        }()
        await realm.asyncRefresh()
        XCTAssertEqual(primary.title, "Other owner's pending edit")
    }

    func testQueuedAdmissionWithdrawalPreservesJournalAndAllowsCurrentRetry() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        try seed([primary], in: realm)
        let before = try journal(primary, in: realm)
        let gate = pauseDiscovery()
        let admission = TitleEditAdmission()
        let reader = ReaderContent()
        let target = try select(primary, in: reader)
        let fixture = await TitleEditFixtureWrite()
        let submitted = expectation(description: "withdrawn edit submitted its independent ticket")
        let write = queued(reader: reader, target: target, title: "Obsolete title", submitted: submitted,
                           permitsCommit: { admission.permitsCommit() })
        guard await awaitProvider(gate, task: write, fixture: fixture) else { return }
        try await fixture.begin(configuration)
        await gate.release()
        await fulfillment(of: [submitted], timeout: 2)
        admission.withdraw()
        try await fixture.commit()

        do {
            _ = try await write.value
            XCTFail("Withdrawn account/edit admission must not commit")
        } catch is CancellationError { }
        await realm.asyncRefresh()
        XCTAssertEqual(primary.title, "Original")
        XCTAssertEqual(try journal(primary, in: realm), before)

        let retried = try await reader.updateContentTitle("Current title", target: target, permitsCommit: { true })
        XCTAssertTrue(retried)
        await realm.asyncRefresh()
        XCTAssertEqual(primary.title, "Current title")
    }

    func testCapturedExplicitRenamePersistsOriginalWithoutPublishingIntoReplacementSelection() async throws {
        for returnToOriginal in [false, true] {
            let configuration = configuration()
            let restore = install(configuration)
            defer { restore() }
            let realm = try await Realm(configuration: configuration)
            let primary = record(HistoryRecord())
            let replacement = record(HistoryRecord(), title: "Replacement selection")
            try seed([primary, replacement], in: realm)
            let gate = pauseDiscovery()
            let reader = ReaderContent()
            let target = try select(primary, in: reader)
            let write = Task { try await reader.updateContentTitle("Original renamed", target: target, permitsCommit: { true }) }
            guard await awaitProvider(gate, task: write) else { return }
            _ = try select(replacement, in: reader)
            if returnToOriginal { _ = try select(primary, in: reader) }
            let selectedTitle = reader.contentTitle
            var publishedTitles = [String]()
            let subscription = reader.contentTitleSubject.sink { publishedTitles.append($0) }
            defer { withExtendedLifetime(subscription) {} }
            await gate.release()

            let changed = try await write.value

            XCTAssertTrue(changed)
            await realm.asyncRefresh()
            XCTAssertEqual(primary.title, "Original renamed")
            XCTAssertEqual(replacement.title, "Replacement selection")
            XCTAssertEqual(reader.contentTitle, selectedTitle)
            XCTAssertTrue(publishedTitles.isEmpty)
            XCTAssertTrue(reader.content === (returnToOriginal ? primary : replacement))
        }
    }

    func testTargetCannotBeAppliedThroughAnotherReaderOwner() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        try seed([primary], in: realm)
        let before = try journal(primary, in: realm)
        var original: ReaderContent? = ReaderContent()
        let target = try select(primary, in: XCTUnwrap(original))
        let other = ReaderContent()
        _ = try select(primary, in: other)

        let wrongOwner = try await other.updateContentTitle("Wrong owner", target: target, permitsCommit: { true })
        XCTAssertFalse(wrongOwner)
        weak var weakOriginal = original
        original = nil
        XCTAssertNil(weakOriginal, "The captured target must not retain its presentation owner")
        let retiredOwner = try await other.updateContentTitle("Retired owner", target: target, permitsCommit: { true })
        XCTAssertFalse(retiredOwner)
        XCTAssertEqual(primary.title, "Original")
        XCTAssertEqual(try journal(primary, in: realm), before)
    }


    func testLaterStoreCancellationReportsEarlierCommitAndPreservesTheQueuedOwnersWrite() async throws {
        let primaryConfiguration = configuration()
        let secondaryConfiguration = configuration()
        let restore = install(primaryConfiguration)
        defer { restore() }
        let primaryRealm = try await Realm(configuration: primaryConfiguration)
        let secondaryRealm = try await Realm(configuration: secondaryConfiguration)
        let primary = record(HistoryRecord())
        let secondary = record(Bookmark(), url: primary.url, title: "Secondary original")
        try seed([primary], in: primaryRealm)
        try seed([secondary], in: secondaryRealm)
        let primaryBefore = try journal(primary, in: primaryRealm)
        let secondaryBefore = try journal(secondary, in: secondaryRealm)
        let secondaryKey = secondary.compoundKey
        let secondaryReference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: secondary))
        ReaderContentLoader.additionalContentProviders = [.init(id: "separate-title-store") { _ in
            [secondaryReference]
        }]
        let reader = ReaderContent()
        let target = try select(primary, in: reader)
        let fixture = await TitleEditFixtureWrite()
        try await fixture.begin(secondaryConfiguration)
        let submitted = expectation(description: "primary committed, then secondary queued its owned ticket")
        submitted.expectedFulfillmentCount = 2
        let write = queued(reader: reader, target: target, title: "Primary committed", submitted: submitted)
        track(write, fixture: fixture)
        await fulfillment(of: [submitted], timeout: 2)

        write.cancel()
        let result = await settlement(of: write, fixture: fixture)
        let changed = try result.get()

        XCTAssertTrue(changed, "A settled primary commit remains true after secondary cancellation")
        await primaryRealm.asyncRefresh()
        XCTAssertEqual(primary.title, "Primary committed")
        XCTAssertNotEqual(try journal(primary, in: primaryRealm).generation, primaryBefore.generation)
        XCTAssertEqual(reader.contentTitle, "Original", "Cancellation suppresses presentation after durable settlement")
        try await { @RealmBackgroundActor in
            let owner = try await RealmBackgroundActor.shared.cachedRealm(for: secondaryConfiguration)
            XCTAssertTrue(owner.isInWriteTransaction)
            let record = try XCTUnwrap(owner.object(ofType: Bookmark.self, forPrimaryKey: secondaryKey))
            XCTAssertEqual(record.title, "Secondary original")
            guard owner.isInWriteTransaction else { return }
            try fixture.commit()
        }()
        await secondaryRealm.asyncRefresh()
        XCTAssertEqual(secondary.title, "Secondary original")
        XCTAssertEqual(try journal(secondary, in: secondaryRealm), secondaryBefore)
    }


    func testManagedTargetIdentityIsStableAcrossOwnersAndTitleChanges() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        try seed([primary], in: realm)
        let firstReader = ReaderContent()
        let first = try select(primary, in: firstReader)
        let secondReader = ReaderContent()
        let second = try select(primary, in: secondReader)
        XCTAssertEqual(first.identity, second.identity)
        XCTAssertEqual(Set([first.identity, second.identity]).count, 1)

        _ = try await firstReader.updateContentTitle("Changed title", target: first, permitsCommit: { true })
        let afterTitleChange = try XCTUnwrap(firstReader.captureTitleEditTarget())

        XCTAssertEqual(first.identity, afterTitleChange.identity)
        XCTAssertNotEqual(first.initialTitle, afterTitleChange.initialTitle)
    }

    func testManagedTargetIdentitySeparatesEqualFieldsPhysicalReplacement() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        try seed([primary], in: realm)
        let originalID = primary.id
        let key = primary.compoundKey
        let url = primary.url
        let creationDate = primary.createdAt
        let reader = ReaderContent()
        let original = try select(primary, in: reader)
        let otherReader = ReaderContent()
        let sameRow = try select(try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: key)),
                                 in: otherReader)
        let frozenReader = ReaderContent()
        let frozen = try select(primary.freeze(), in: frozenReader)
        XCTAssertEqual(original.identity, sameRow.identity)
        XCTAssertEqual(original.identity, frozen.identity)

        let replacement = record(HistoryRecord(), url: url, title: "Replacement")
        replacement.createdAt = creationDate
        XCTAssertEqual(replacement.compoundKey, key)
        try realm.write {
            realm.delete(primary) // Fixture-only same-fields physical recreation.
            realm.add(replacement)
            replacement.refreshChangeMetadata(explicitlyModified: true)
        }
        let recreated = try select(replacement, in: reader)

        XCTAssertNotEqual(replacement.id, originalID)
        XCTAssertEqual(replacement.createdAt, creationDate)
        XCTAssertEqual(replacement.url, url)
        XCTAssertNotEqual(original.identity, recreated.identity)
        XCTAssertEqual(Set([original.identity, sameRow.identity, frozen.identity, recreated.identity]).count, 2)
    }

    func testManagedTargetIdentitySeparatesStoresAndRecreatedIncarnations() async throws {
        let configuration = configuration()
        let otherConfiguration = self.configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let otherRealm = try await Realm(configuration: otherConfiguration)
        let primary = record(HistoryRecord())
        let otherStore = record(HistoryRecord(), url: primary.url)
        try seed([primary], in: realm)
        try seed([otherStore], in: otherRealm)
        XCTAssertEqual(primary.compoundKey, otherStore.compoundKey)
        XCTAssertEqual(primary.createdAt, otherStore.createdAt)
        let reader = ReaderContent()
        let original = try select(primary, in: reader)
        let otherReader = ReaderContent()
        let other = try select(otherStore, in: otherReader)
        XCTAssertNotEqual(original.identity, other.identity)

        let replacement = record(HistoryRecord(), url: primary.url)
        replacement.createdAt = primary.createdAt.addingTimeInterval(1)
        try realm.write {
            realm.delete(primary) // Fixture-only recreation of the same key.
            realm.add(replacement)
            replacement.refreshChangeMetadata(explicitlyModified: true)
        }
        let recreated = try select(replacement, in: reader)
        XCTAssertNotEqual(original.identity, recreated.identity)
        XCTAssertEqual(Set([original.identity, other.identity, recreated.identity]).count, 3)
    }

    func testUnmanagedTargetIdentityTracksOriginalObjectAndDoesNotSurvivePromotion() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let original = record(Bookmark())
        let sameValues = record(Bookmark(), url: original.url)
        let reader = ReaderContent()
        let local = try select(original, in: reader)
        let repeated = try XCTUnwrap(reader.captureTitleEditTarget())
        XCTAssertEqual(local.identity, repeated.identity)
        let otherReader = ReaderContent()
        let distinctObject = try select(sameValues, in: otherReader)
        XCTAssertNotEqual(local.identity, distinctObject.identity)

        try seed([original], in: realm)
        let promoted = try XCTUnwrap(reader.captureTitleEditTarget())

        XCTAssertNotEqual(local.identity, promoted.identity)
        XCTAssertEqual(Set([local.identity, distinctObject.identity, promoted.identity]).count, 3)
    }

    func testUnmanagedLegacyContentStaysLocalAndUpdatesItsCurrentPresentation() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        ReaderContentLoader.additionalContentProviders = [.init(id: "unavailable-unmanaged-provider") { _ in
            XCTFail("An unmanaged local edit must not acquire managed authority through discovery")
            throw TitleEditFixtureError.providerFailed
        }]
        let primary = record(Bookmark())
        let reader = ReaderContent()
        _ = try select(primary, in: reader)

        await reader.updateContentTitle("Alpha")

        XCTAssertNil(primary.realm)
        XCTAssertEqual(primary.title, "Alpha")
        XCTAssertTrue(primary.isTitlePrefixOfContent)
        XCTAssertEqual(reader.contentTitle, "Alpha")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testUnmanagedCaptureThatBecomesManagedCannotUseTheLocalFallback() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(Bookmark())
        let reader = ReaderContent()
        let target = try select(primary, in: reader)
        try seed([primary], in: realm)
        let inserted = try journal(primary, in: realm)

        let changed = try await reader.updateContentTitle("Late local edit", target: target, permitsCommit: { true })

        XCTAssertFalse(changed)
        XCTAssertNotNil(primary.realm)
        XCTAssertEqual(primary.title, "Original")
        XCTAssertEqual(try journal(primary, in: realm), inserted)
        XCTAssertEqual(reader.contentTitle, "Original")
    }
}
