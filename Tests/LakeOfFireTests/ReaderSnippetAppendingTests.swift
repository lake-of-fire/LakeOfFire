import BigSyncKit
import Foundation
import RealmSwift
import XCTest
@testable import LakeOfFireContent
@testable import RealmSwiftGaps

private actor SnippetAppendProviderGate {
    private var arrivals = 0
    private var released = false
    private var arrivalWaiters = [(Int, CheckedContinuation<Void, Never>)]()
    private var releaseWaiters = [CheckedContinuation<Void, Never>]()

    func pause() async {
        arrivals += 1
        let ready = arrivalWaiters.filter { arrivals >= $0.0 }
        arrivalWaiters.removeAll { arrivals >= $0.0 }
        ready.forEach { $0.1.resume() }
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }

    func waitForArrivals(_ count: Int) async -> Bool {
        if arrivals < count && !released {
            await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
        }
        return arrivals >= count
    }

    func hasArrivals(_ count: Int) -> Bool { arrivals >= count }

    func release() {
        released = true
        let arrivals = arrivalWaiters
        let releases = releaseWaiters
        arrivalWaiters.removeAll()
        releaseWaiters.removeAll()
        arrivals.forEach { $0.1.resume() }
        releases.forEach { $0.resume() }
    }
}

private final class SnippetAppendAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    private var mutationCount = 0

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

    func recordMutation() -> Int {
        lock.lock()
        defer { lock.unlock() }
        mutationCount += 1
        return mutationCount
    }

    func mutations() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return mutationCount
    }
}

private enum SnippetAppendFixtureError: Error {
    case providerFailed
    case mutationFailed
    case missingHeldWrite
}

private actor SnippetAppendRetryingProvider {
    private var calls = 0

    func load() throws -> [ReaderContentLoader.ContentReference] {
        calls += 1
        if calls == 1 { throw SnippetAppendFixtureError.providerFailed }
        return []
    }

    func callCount() -> Int { calls }
}

@RealmBackgroundActor
private final class SnippetAppendFixtureWrite {
    private var heldRealm: Realm?

    func begin(_ configuration: Realm.Configuration) async throws {
        XCTAssertNil(heldRealm)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        XCTAssertFalse(realm.isInWriteTransaction)
        realm.beginWrite()
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
        if realm.isInWriteTransaction { realm.cancelWrite() }
    }
}

@MainActor
private final class SnippetAppendSettlement {
    var result: Result<ReaderContentLoader.SnippetAppendResult, Error>?
}

@MainActor
final class ReaderSnippetAppendingTests: XCTestCase {
    private static let seedDate = Date(timeIntervalSince1970: 1_700_000_000)
    private typealias AppendTask = Task<ReaderContentLoader.SnippetAppendResult, Error>

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
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: captured) }
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
        _ record: T, url: URL? = nil, title: String = "Custom title", html: String = "<p>Original body</p>"
    ) -> T {
        record.url = url ?? ReaderContentLoader.snippetURL(key: UUID().uuidString)!
        record.title = title
        record.html = ReaderContentLoader.snippetHTML(fromHTML: html)
        record.createdAt = Self.seedDate
        record.rssContainsFullContent = true
        record.isReaderModeByDefault = true
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
        XCTAssertEqual(record.modifiedAt, pending.changedAt)
        XCTAssertEqual(record.explicitlyModifiedAt, pending.changedAt)
        return JournalState(generation: pending.generation, modifiedAt: record.modifiedAt,
            explicitlyModifiedAt: record.explicitlyModifiedAt, changedAt: pending.changedAt)
    }

    private func capture(_ content: any ReaderContentProtocol) throws -> ReaderContentLoader.SnippetAppendTarget {
        try XCTUnwrap(ReaderContentLoader.captureSnippetAppendTarget(for: content))
    }

    private func pauseDiscovery() -> SnippetAppendProviderGate {
        let gate = SnippetAppendProviderGate()
        ReaderContentLoader.additionalContentProviders = [.init(id: "held-snippet-append") { _ in
            await gate.pause()
            return []
        }]
        return gate
    }

    private func track<Value: Sendable>(
        _ task: Task<Value, Error>, gate: SnippetAppendProviderGate? = nil,
        fixture: SnippetAppendFixtureWrite? = nil
    ) {
        addTeardownBlock {
            task.cancel()
            await gate?.release()
            await fixture?.cancelOwnedWrite()
            _ = await task.result
        }
    }

    private func awaitProvider(_ gate: SnippetAppendProviderGate, count: Int = 1) async -> Bool {
        let entered = expectation(description: "actual append reached its captured provider")
        let observer = Task {
            if await gate.waitForArrivals(count) { entered.fulfill() }
        }
        addTeardownBlock {
            await gate.release()
            await observer.value
        }
        await fulfillment(of: [entered], timeout: 2)
        return await gate.hasArrivals(count)
    }

    private func queued(
        target: ReaderContentLoader.SnippetAppendTarget, html: String,
        submitted: XCTestExpectation, permitsCommit: @escaping @Sendable () -> Bool = { true }
    ) -> AppendTask {
        submitted.assertForOverFulfill = false
        return Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await ReaderContentLoader.appendSnippetHTML(html, to: target, permitsCommit: permitsCommit)
            }
        }
    }

    private func settlement(of task: AppendTask, fixture: SnippetAppendFixtureWrite) async -> Result<ReaderContentLoader.SnippetAppendResult, Error> {
        let completed = expectation(description: "append settles without cancelling another owner's transaction")
        let observation = SnippetAppendSettlement()
        let observer = Task { @MainActor in
            observation.result = await task.result
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        if observation.result == nil {
            task.cancel()
            await fixture.cancelOwnedWrite()
        }
        let result = await task.result
        await observer.value
        return result
    }

    func testLegacyEntryPointAppendsAndJournalsTheOriginalManagedRecord() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        primary.rssContainsFullContent = false
        primary.isReaderModeByDefault = false
        try seed([primary], in: realm)
        let before = try journal(primary, in: realm)
        let visited = primary.lastVisitedAt

        let result = try await ReaderContentLoader.appendSnippetHTML("<p>Accepted tail</p>", to: primary)

        XCTAssertTrue(result === primary)
        XCTAssertTrue(primary.html?.contains("Original body") == true)
        XCTAssertTrue(primary.html?.contains("Accepted tail") == true)
        XCTAssertEqual(primary.title, "Custom title")
        XCTAssertTrue(primary.rssContainsFullContent)
        XCTAssertTrue(primary.isReaderModeByDefault)
        XCTAssertEqual(primary.lastVisitedAt, visited, "Appending is not a new history visit")
        XCTAssertNotEqual(try journal(primary, in: realm).generation, before.generation)
    }

    func testRelatedRepresentationsUseTheirOwnBodiesAndOneGroupTimestamp() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord(), html: "<p>History body</p>")
        let related = record(Bookmark(), url: primary.url, html: "<p>Bookmark body</p>")
        try seed([primary, related], in: realm)
        let primaryBefore = try journal(primary, in: realm)
        let relatedBefore = try journal(related, in: realm)

        let result = try await ReaderContentLoader.appendSnippetHTML("<p>Shared tail</p>",
            to: capture(primary), permitsCommit: { true })

        XCTAssertTrue(result.didChange)
        await realm.asyncRefresh()
        XCTAssertTrue(primary.html?.contains("History body") == true)
        XCTAssertFalse(primary.html?.contains("Bookmark body") == true)
        XCTAssertTrue(related.html?.contains("Bookmark body") == true)
        XCTAssertFalse(related.html?.contains("History body") == true)
        XCTAssertTrue(primary.html?.contains("Shared tail") == true)
        XCTAssertTrue(related.html?.contains("Shared tail") == true)
        let primaryAfter = try journal(primary, in: realm)
        let relatedAfter = try journal(related, in: realm)
        XCTAssertNotEqual(primaryAfter.generation, primaryBefore.generation)
        XCTAssertNotEqual(relatedAfter.generation, relatedBefore.generation)
        XCTAssertEqual(primaryAfter.changedAt, relatedAfter.changedAt)
    }

    func testEmptyAppendWithEqualStatePreservesEveryJournalField() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        try seed([primary], in: realm)
        let before = try journal(primary, in: realm)
        let htmlBefore = primary.html

        let result = try await ReaderContentLoader.appendSnippetHTML("<html><body> </body></html>",
            to: capture(primary), permitsCommit: { true })

        XCTAssertFalse(result.didChange)
        XCTAssertTrue(result.content === primary)
        XCTAssertEqual(primary.html, htmlBefore)
        XCTAssertEqual(try journal(primary, in: realm), before)
    }

    func testTwoAcceptedPasteTargetsBothAppendTheSamePayload() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        try seed([primary], in: realm)
        let gate = pauseDiscovery()
        let firstTarget = try capture(primary)
        let secondTarget = try capture(primary)
        let first = Task { try await ReaderContentLoader.appendSnippetHTML("<p>Accepted twice</p>", to: firstTarget, permitsCommit: { true }) }
        let second = Task { try await ReaderContentLoader.appendSnippetHTML("<p>Accepted twice</p>", to: secondTarget, permitsCommit: { true }) }
        track(first, gate: gate)
        track(second, gate: gate)
        guard await awaitProvider(gate, count: 2) else { return }
        await gate.release()

        let firstResult = try await first.value
        let secondResult = try await second.value

        XCTAssertTrue(firstResult.didChange)
        XCTAssertTrue(secondResult.didChange)
        await realm.asyncRefresh()
        XCTAssertEqual(primary.html?.components(separatedBy: "Accepted twice").count, 3,
            "Both accepted additive intents survive; neither replaces the other")
    }

    func testCaptureKeepsOriginalStoresAndProviderRegistrations() async throws {
        let originalConfiguration = configuration()
        let replacementConfiguration = configuration()
        let restore = install(originalConfiguration)
        defer { restore() }
        let originalRealm = try await Realm(configuration: originalConfiguration)
        let replacementRealm = try await Realm(configuration: replacementConfiguration)
        let original = record(HistoryRecord())
        let replacement = record(HistoryRecord(), url: original.url, html: "<p>Replacement store</p>")
        try seed([original], in: originalRealm)
        try seed([replacement], in: replacementRealm)
        let replacementBefore = try journal(replacement, in: replacementRealm)
        let gate = pauseDiscovery()
        let target = try capture(original)
        _ = install(replacementConfiguration)
        ReaderContentLoader.additionalContentProviders = [.init(id: "replacement-provider") { _ in
            throw SnippetAppendFixtureError.providerFailed
        }]
        let append = Task { try await ReaderContentLoader.appendSnippetHTML("<p>Original destination</p>", to: target, permitsCommit: { true }) }
        track(append, gate: gate)
        guard await awaitProvider(gate) else { return }
        await gate.release()

        let result = try await append.value

        XCTAssertTrue(result.didChange)
        XCTAssertTrue(result.content === original)
        await replacementRealm.asyncRefresh()
        XCTAssertTrue(original.html?.contains("Original destination") == true)
        XCTAssertFalse(replacement.html?.contains("Original destination") == true)
        XCTAssertEqual(try journal(replacement, in: replacementRealm), replacementBefore)
    }

    func testProviderFailureBeforeWriteAllowsAnExplicitSingleApplicationRetry() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        try seed([primary], in: realm)
        let before = try journal(primary, in: realm)
        let provider = SnippetAppendRetryingProvider()
        ReaderContentLoader.additionalContentProviders = [.init(id: "retrying-append-provider") { _ in
            try await provider.load()
        }]
        let target = try capture(primary)
        do {
            _ = try await ReaderContentLoader.appendSnippetHTML("<p>Applied once</p>", to: target, permitsCommit: { true })
            XCTFail("The controlled provider failure must propagate before any write")
        } catch SnippetAppendFixtureError.providerFailed { }
        await realm.asyncRefresh()
        XCTAssertFalse(primary.html?.contains("Applied once") == true)
        XCTAssertEqual(try journal(primary, in: realm), before)
        let firstCalls = await provider.callCount()
        XCTAssertEqual(firstCalls, 1, "The operation must not retry persistence automatically")

        let retried = try await ReaderContentLoader.appendSnippetHTML("<p>Applied once</p>", to: target, permitsCommit: { true })

        XCTAssertTrue(retried.didChange)
        XCTAssertEqual(primary.html?.components(separatedBy: "Applied once").count, 2)
        let finalCalls = await provider.callCount()
        XCTAssertEqual(finalCalls, 2)
    }

    func testQueuedWriteUsesInterveningAuthoritativeBodyAndTitle() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        try seed([primary], in: realm)
        let key = primary.compoundKey
        let gate = pauseDiscovery()
        let target = try capture(primary)
        let fixture = await SnippetAppendFixtureWrite()
        let submitted = expectation(description: "append queued behind the fixture's write")
        let append = queued(target: target, html: "<p>New tail</p>", submitted: submitted)
        track(append, gate: gate, fixture: fixture)
        guard await awaitProvider(gate) else { return }
        try await fixture.begin(configuration)
        try await { @RealmBackgroundActor in
            let owner = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let record = try XCTUnwrap(owner.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            record.html = ReaderContentLoader.snippetHTML(fromHTML: "<p>Intervening body</p>")
            record.title = "Intervening custom title"
            record.isTitlePrefixOfContent = false
            record.refreshChangeMetadata(explicitlyModified: true)
        }()
        await gate.release()
        await fulfillment(of: [submitted], timeout: 2)
        try await fixture.commit()

        let result = try await append.value

        XCTAssertTrue(result.didChange)
        XCTAssertTrue(primary.html?.contains("Intervening body") == true)
        XCTAssertTrue(primary.html?.contains("New tail") == true)
        XCTAssertFalse(primary.html?.contains("Original body") == true)
        XCTAssertEqual(primary.title, "Intervening custom title")
        XCTAssertFalse(primary.isTitlePrefixOfContent)
    }

    func testRetiredPrimaryCannotAuthorizeItsRelatedRecords() async throws {
        for retirement in ["tombstone", "recreated", "retargeted"] {
            let configuration = configuration()
            let restore = install(configuration)
            defer { restore() }
            let realm = try await Realm(configuration: configuration)
            let primary = record(HistoryRecord())
            let related = record(Bookmark(), url: primary.url)
            try seed([primary, related], in: realm)
            let relatedBefore = try journal(related, in: realm)
            let originalURL = primary.url
            let originalKey = primary.compoundKey
            let gate = pauseDiscovery()
            let target = try capture(primary)
            let append = Task { try await ReaderContentLoader.appendSnippetHTML("<p>Retired payload</p>", to: target, permitsCommit: { true }) }
            track(append, gate: gate)
            guard await awaitProvider(gate) else { return }
            var replacement: HistoryRecord?
            try realm.write {
                if retirement == "recreated" {
                    // Models an external rebuild; this is not a production
                    // deletion path or permission to remove sync tombstones.
                    realm.delete(primary)
                    let successor = record(HistoryRecord(), url: originalURL)
                    successor.compoundKey = originalKey
                    successor.createdAt = Self.seedDate.addingTimeInterval(1)
                    realm.add(successor)
                    successor.refreshChangeMetadata(explicitlyModified: true)
                    replacement = successor
                } else {
                    if retirement == "tombstone" { primary.isDeleted = true }
                    else { primary.url = ReaderContentLoader.snippetURL(key: UUID().uuidString)! }
                    primary.refreshChangeMetadata(explicitlyModified: true)
                }
            }
            let successorBefore = try replacement.map { try journal($0, in: realm) }
            await gate.release()

            let result = try await append.value

            XCTAssertFalse(result.didChange)
            XCTAssertNil(result.content)
            await realm.asyncRefresh()
            XCTAssertFalse(related.html?.contains("Retired payload") == true)
            XCTAssertEqual(try journal(related, in: realm), relatedBefore)
            if let replacement {
                XCTAssertFalse(replacement.html?.contains("Retired payload") == true)
                XCTAssertEqual(try journal(replacement, in: realm), successorBefore)
            }
        }
    }

    func testProviderReferenceCannotAdoptARecreatedRecord() async throws {
        let primaryConfiguration = configuration()
        let providerConfiguration = configuration()
        let restore = install(primaryConfiguration)
        defer { restore() }
        let primaryRealm = try await Realm(configuration: primaryConfiguration)
        let providerRealm = try await Realm(configuration: providerConfiguration)
        let primary = record(HistoryRecord())
        let related = record(Bookmark(), url: primary.url)
        try seed([primary], in: primaryRealm)
        try seed([related], in: providerRealm)
        let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: related))
        let relatedKey = related.compoundKey
        let gate = SnippetAppendProviderGate()
        ReaderContentLoader.additionalContentProviders = [.init(id: "recreated-provider-record") { _ in
            await gate.pause()
            return [reference]
        }]
        let target = try capture(primary)
        let append = Task {
            try await ReaderContentLoader.appendSnippetHTML("<p>Accepted original target</p>",
                to: target, permitsCommit: { true })
        }
        track(append, gate: gate)
        guard await awaitProvider(gate) else { return }
        let successor = record(Bookmark(), url: primary.url, html: "<p>Successor body</p>")
        successor.compoundKey = relatedKey
        successor.createdAt = Self.seedDate.addingTimeInterval(1)
        try providerRealm.write {
            // Models an external rebuild, not a production deletion policy.
            providerRealm.delete(related)
            providerRealm.add(successor)
            successor.refreshChangeMetadata(explicitlyModified: true)
        }
        let successorBefore = try journal(successor, in: providerRealm)
        await gate.release()

        let result = try await append.value

        XCTAssertTrue(result.didChange, "The original primary still accepts its append")
        XCTAssertTrue(result.content === primary)
        XCTAssertTrue(primary.html?.contains("Accepted original target") == true)
        await providerRealm.asyncRefresh()
        XCTAssertFalse(successor.html?.contains("Accepted original target") == true)
        XCTAssertEqual(try journal(successor, in: providerRealm), successorBefore)
    }

    func testQueuedAppendRejectsEqualFieldsPhysicalPrimaryReplacement() async throws {
        try await assertQueuedEqualFieldsReplacement(frozen: false, replacesPrimary: true)
    }

    func testQueuedFrozenAppendRejectsEqualFieldsPhysicalPrimaryReplacement() async throws {
        try await assertQueuedEqualFieldsReplacement(frozen: true, replacesPrimary: true)
    }

    func testQueuedAppendSkipsEqualFieldsPhysicalRelatedReplacement() async throws {
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
        let relatedHTML = related.html
        let replaced: Bookmark = replacesPrimary ? primary : related
        let originalID = replaced.id
        let primaryID = primary.id
        let key = replaced.compoundKey
        let url = replaced.url
        let creationDate = replaced.createdAt
        let replacementDate = Self.seedDate.addingTimeInterval(2)
        let source = frozen ? primary.freeze() : primary
        let sourceHTML = source.html
        XCTAssertEqual(source.id, primaryID)
        let gate = pauseDiscovery()
        let target = try capture(source)
        let fixture = await SnippetAppendFixtureWrite()
        let submitted = expectation(description: "append queued before equal-fields physical replacement")
        let append = queued(target: target, html: "<p>Captured append</p>", submitted: submitted)
        track(append, gate: gate, fixture: fixture)
        guard await awaitProvider(gate) else { return }
        try await fixture.begin(configuration)
        await gate.release()
        await fulfillment(of: [submitted], timeout: 2)

        let replacementState = try await { @RealmBackgroundActor in
            let owner = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            guard owner.isInWriteTransaction else { throw SnippetAppendFixtureError.missingHeldWrite }
            let old: Bookmark
            if replacesPrimary {
                old = try XCTUnwrap(owner.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            } else {
                old = try XCTUnwrap(owner.object(ofType: Bookmark.self, forPrimaryKey: key))
            }
            XCTAssertEqual(old.id, originalID)
            owner.delete(old) // Fixture-only recreation; production retains deletion tombstones.
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

        let result = try await append.value

        XCTAssertEqual(result.didChange, !replacesPrimary)
        if replacesPrimary {
            XCTAssertNil(result.content)
        } else {
            XCTAssertTrue(result.content === primary)
        }
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
            XCTAssertEqual(related.html, relatedHTML)
            XCTAssertEqual(related.title, "Related original")
            XCTAssertEqual(try journal(related, in: realm), relatedBefore)
        } else {
            XCTAssertEqual(primary.id, primaryID)
            XCTAssertTrue(primary.html?.contains("Captured append") == true)
            XCTAssertEqual(primary.title, "Custom title")
            XCTAssertNotEqual(try journal(primary, in: realm).generation, primaryBefore.generation)
        }
        if frozen {
            XCTAssertFalse(source.isInvalidated)
            XCTAssertEqual(source.id, primaryID)
            XCTAssertEqual(source.html, sourceHTML)
            XCTAssertFalse(target.matchesPresentationContent(source))
        }
    }

    func testProviderReferenceSkipsEqualFieldsPhysicalReplacement() async throws {
        let primaryConfiguration = configuration()
        let providerConfiguration = configuration()
        let restore = install(primaryConfiguration)
        defer { restore() }
        let primaryRealm = try await Realm(configuration: primaryConfiguration)
        let providerRealm = try await Realm(configuration: providerConfiguration)
        let primary = record(HistoryRecord())
        let related = record(Bookmark(), url: primary.url)
        try seed([primary], in: primaryRealm)
        try seed([related], in: providerRealm)
        let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: related))
        let originalID = related.id
        let relatedKey = related.compoundKey
        let creationDate = related.createdAt
        let gate = SnippetAppendProviderGate()
        ReaderContentLoader.additionalContentProviders = [.init(id: "physical-provider-replacement") { _ in
            await gate.pause()
            return [reference]
        }]
        let target = try capture(primary)
        let append = Task {
            try await ReaderContentLoader.appendSnippetHTML("<p>Accepted primary</p>",
                to: target, permitsCommit: { true })
        }
        track(append, gate: gate)
        guard await awaitProvider(gate) else { return }
        let successor = record(Bookmark(), url: primary.url, title: "Successor", html: "<p>Successor body</p>")
        successor.compoundKey = relatedKey
        successor.createdAt = creationDate
        successor.author = "Successor author"
        try providerRealm.write {
            providerRealm.delete(related) // Fixture-only same-fields physical recreation.
            providerRealm.add(successor)
            successor.refreshChangeMetadata(explicitlyModified: true)
        }
        XCTAssertNotEqual(successor.id, originalID)
        let successorHTML = successor.html
        let successorBefore = try journal(successor, in: providerRealm)
        await gate.release()

        let result = try await append.value

        XCTAssertTrue(result.didChange)
        XCTAssertTrue(result.content === primary)
        XCTAssertTrue(primary.html?.contains("Accepted primary") == true)
        await providerRealm.asyncRefresh()
        XCTAssertNotEqual(successor.id, originalID)
        XCTAssertEqual(successor.compoundKey, relatedKey)
        XCTAssertEqual(successor.createdAt, creationDate)
        XCTAssertEqual(successor.url, primary.url)
        XCTAssertEqual(successor.title, "Successor")
        XCTAssertEqual(successor.author, "Successor author")
        XCTAssertEqual(successor.html, successorHTML)
        XCTAssertEqual(try journal(successor, in: providerRealm), successorBefore)
    }

    func testFrozenCaptureCommitsWithoutRefreshingOrPublishingItsSnapshot() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        try seed([primary], in: realm)
        let before = try journal(primary, in: realm)
        let source = primary.freeze()
        let sourceHTML = source.html
        let target = try capture(source)
        XCTAssertTrue(source.isFrozen)
        XCTAssertFalse(target.matchesPresentationContent(source))

        let result = try await ReaderContentLoader.appendSnippetHTML("<p>Frozen captured intent</p>",
            to: target, permitsCommit: { true })

        XCTAssertTrue(result.didChange)
        XCTAssertNil(result.content, "A frozen snapshot cannot provide refreshed presentation")
        await realm.asyncRefresh()
        XCTAssertEqual(primary.id, source.id)
        XCTAssertTrue(primary.html?.contains("Frozen captured intent") == true)
        XCTAssertNotEqual(try journal(primary, in: realm).generation, before.generation)
        XCTAssertFalse(source.isInvalidated)
        XCTAssertEqual(source.html, sourceHTML)
        XCTAssertFalse(source.html?.contains("Frozen captured intent") == true)
    }

    func testSameRealmAdmissionWithdrawalRollsBackActualMutationAndJournals() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        let related = record(Bookmark(), url: primary.url)
        try seed([primary, related], in: realm)
        let primaryHTML = primary.html
        let relatedHTML = related.html
        let primaryBefore = try journal(primary, in: realm)
        let relatedBefore = try journal(related, in: realm)
        let target = try capture(primary)
        let admission = SnippetAppendAdmission()
        let payload = ReaderContentLoader.snippetHTML(fromHTML: "<p>Rolled back tail</p>")

        do {
            _ = try await ReaderContentLoader.updateCapturedSnippetRecords(
                target: target, permitsCommit: { admission.permitsCommit() }
            ) { object in
                XCTAssertTrue(object.realm?.isInWriteTransaction == true)
                let changed = ReaderContentLoader.applySnippetAppend(payload, to: object)
                XCTAssertTrue(changed)
                XCTAssertTrue(object.html?.contains("Rolled back tail") == true)
                _ = admission.recordMutation()
                admission.withdraw()
                return changed
            }
            XCTFail("Withdrawal after an actual field mutation must roll back the owned group")
        } catch is CancellationError { }

        await realm.asyncRefresh()
        XCTAssertEqual(admission.mutations(), 1)
        XCTAssertEqual(primary.html, primaryHTML)
        XCTAssertEqual(related.html, relatedHTML)
        XCTAssertEqual(try journal(primary, in: realm), primaryBefore)
        XCTAssertEqual(try journal(related, in: realm), relatedBefore)
    }

    func testSameRealmOrdinaryFailureRollsBackBothRowsAndMetadata() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        let related = record(Bookmark(), url: primary.url)
        try seed([primary, related], in: realm)
        let primaryHTML = primary.html
        let relatedHTML = related.html
        let primaryBefore = try journal(primary, in: realm)
        let relatedBefore = try journal(related, in: realm)
        let target = try capture(primary)
        let probe = SnippetAppendAdmission()
        let payload = ReaderContentLoader.snippetHTML(fromHTML: "<p>Atomic tail</p>")

        do {
            _ = try await ReaderContentLoader.updateCapturedSnippetRecords(
                target: target, permitsCommit: { true }
            ) { object in
                XCTAssertTrue(object.realm?.isInWriteTransaction == true)
                let changed = ReaderContentLoader.applySnippetAppend(payload, to: object)
                if probe.recordMutation() == 2 { throw SnippetAppendFixtureError.mutationFailed }
                return changed
            }
            XCTFail("The injected second-row error must escape after rolling back the real group")
        } catch SnippetAppendFixtureError.mutationFailed { }

        await realm.asyncRefresh()
        XCTAssertEqual(probe.mutations(), 2)
        XCTAssertEqual(primary.html, primaryHTML)
        XCTAssertEqual(related.html, relatedHTML)
        XCTAssertEqual(try journal(primary, in: realm), primaryBefore)
        XCTAssertEqual(try journal(related, in: realm), relatedBefore)
    }

    func testLaterRealmFailureReportsPartialCommitWithoutAutomaticReapplication() async throws {
        let primaryConfiguration = configuration()
        let secondaryConfiguration = configuration()
        let restore = install(primaryConfiguration)
        defer { restore() }
        let primaryRealm = try await Realm(configuration: primaryConfiguration)
        let secondaryRealm = try await Realm(configuration: secondaryConfiguration)
        let primary = record(HistoryRecord())
        let secondary = record(Bookmark(), url: primary.url, html: "<p>Secondary body</p>")
        try seed([primary], in: primaryRealm)
        try seed([secondary], in: secondaryRealm)
        let primaryBefore = try journal(primary, in: primaryRealm)
        let secondaryBefore = try journal(secondary, in: secondaryRealm)
        let secondaryHTML = secondary.html
        let secondaryID = secondaryConfiguration.inMemoryIdentifier
        let secondaryReference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: secondary))
        ReaderContentLoader.additionalContentProviders = [.init(id: "second-append-store") { _ in
            [secondaryReference]
        }]
        let target = try capture(primary)
        let probe = SnippetAppendAdmission()
        let payload = ReaderContentLoader.snippetHTML(fromHTML: "<p>One accepted append</p>")

        do {
            _ = try await ReaderContentLoader.updateCapturedSnippetRecords(
                target: target, permitsCommit: { true }
            ) { object in
                XCTAssertTrue(object.realm?.isInWriteTransaction == true)
                let changed = ReaderContentLoader.applySnippetAppend(payload, to: object)
                _ = probe.recordMutation()
                if object.realm?.configuration.inMemoryIdentifier == secondaryID {
                    throw SnippetAppendFixtureError.mutationFailed
                }
                return changed
            }
            XCTFail("A later store's ordinary failure must preserve explicit partial-commit truth")
        } catch let error as ReaderContentLoader.SnippetAppendPartialCommitError {
            XCTAssertTrue(error.didChange)
            guard case SnippetAppendFixtureError.mutationFailed = error.underlyingError else {
                XCTFail("The original controlled Swift failure must remain available")
                return
            }
        }

        await primaryRealm.asyncRefresh()
        await secondaryRealm.asyncRefresh()
        XCTAssertEqual(primary.html?.components(separatedBy: "One accepted append").count, 2)
        XCTAssertNotEqual(try journal(primary, in: primaryRealm).generation, primaryBefore.generation)
        XCTAssertEqual(secondary.html, secondaryHTML)
        XCTAssertEqual(try journal(secondary, in: secondaryRealm), secondaryBefore)
        XCTAssertEqual(probe.mutations(), 2, "No automatic retry may reapply the payload to the committed store")
    }

    func testQueuedCancellationPreservesTheOtherOwnersPendingTransaction() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(HistoryRecord())
        try seed([primary], in: realm)
        let key = primary.compoundKey
        let gate = pauseDiscovery()
        let target = try capture(primary)
        let fixture = await SnippetAppendFixtureWrite()
        let submitted = expectation(description: "cancelled append submitted its own queued ticket")
        let append = queued(target: target, html: "<p>Cancelled tail</p>", submitted: submitted)
        track(append, gate: gate, fixture: fixture)
        guard await awaitProvider(gate) else { return }
        try await fixture.begin(configuration)
        try await { @RealmBackgroundActor in
            let owner = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            owner.object(ofType: HistoryRecord.self, forPrimaryKey: key)?.title = "Other owner's pending title"
        }()
        await gate.release()
        await fulfillment(of: [submitted], timeout: 2)
        append.cancel()

        do {
            let result = await settlement(of: append, fixture: fixture)
            _ = try result.get()
            XCTFail("Cancellation before the first commit must throw")
        } catch is CancellationError { }

        try await { @RealmBackgroundActor in
            let owner = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            XCTAssertTrue(owner.isInWriteTransaction)
            let record = try XCTUnwrap(owner.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            XCTAssertEqual(record.title, "Other owner's pending title")
            XCTAssertFalse(record.html?.contains("Cancelled tail") == true)
            guard owner.isInWriteTransaction else { return }
            record.refreshChangeMetadata(explicitlyModified: true)
            try fixture.commit()
        }()
        await realm.asyncRefresh()
        XCTAssertEqual(primary.title, "Other owner's pending title")
        XCTAssertFalse(primary.html?.contains("Cancelled tail") == true)
    }

    func testLaterRealmCancellationRetainsEarlierCommitAndSuppressesPresentation() async throws {
        let primaryConfiguration = configuration()
        let secondaryConfiguration = configuration()
        let restore = install(primaryConfiguration)
        defer { restore() }
        let primaryRealm = try await Realm(configuration: primaryConfiguration)
        let secondaryRealm = try await Realm(configuration: secondaryConfiguration)
        let primary = record(HistoryRecord())
        let secondary = record(Bookmark(), url: primary.url)
        try seed([primary], in: primaryRealm)
        try seed([secondary], in: secondaryRealm)
        let primaryBefore = try journal(primary, in: primaryRealm)
        let secondaryBefore = try journal(secondary, in: secondaryRealm)
        let secondaryKey = secondary.compoundKey
        let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: secondary))
        ReaderContentLoader.additionalContentProviders = [.init(id: "held-secondary-append") { _ in [reference] }]
        let target = try capture(primary)
        let fixture = await SnippetAppendFixtureWrite()
        try await fixture.begin(secondaryConfiguration)
        let submitted = expectation(description: "primary settled before the secondary ticket queued")
        submitted.expectedFulfillmentCount = 2
        let append = queued(target: target, html: "<p>Settled tail</p>", submitted: submitted)
        track(append, fixture: fixture)
        await fulfillment(of: [submitted], timeout: 2)
        append.cancel()

        let outcome = await settlement(of: append, fixture: fixture)
        let result = try outcome.get()

        XCTAssertTrue(result.didChange)
        XCTAssertNil(result.content, "Cancellation must not publish the optional original record")
        await primaryRealm.asyncRefresh()
        XCTAssertTrue(primary.html?.contains("Settled tail") == true)
        XCTAssertNotEqual(try journal(primary, in: primaryRealm).generation, primaryBefore.generation)
        try await { @RealmBackgroundActor in
            let owner = try await RealmBackgroundActor.shared.cachedRealm(for: secondaryConfiguration)
            XCTAssertTrue(owner.isInWriteTransaction)
            let record = try XCTUnwrap(owner.object(ofType: Bookmark.self, forPrimaryKey: secondaryKey))
            XCTAssertFalse(record.html?.contains("Settled tail") == true)
            guard owner.isInWriteTransaction else { return }
            try fixture.commit()
        }()
        await secondaryRealm.asyncRefresh()
        XCTAssertEqual(try journal(secondary, in: secondaryRealm), secondaryBefore)
    }

    func testUnmanagedAppendStaysLocalDespiteAManagedURLMatch() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let local = record(HistoryRecord())
        let managed = record(HistoryRecord(), url: local.url, html: "<p>Managed body</p>")
        try seed([managed], in: realm)
        let before = try journal(managed, in: realm)
        ReaderContentLoader.additionalContentProviders = [.init(id: "must-not-load-for-local") { _ in
            throw SnippetAppendFixtureError.providerFailed
        }]
        let target = try capture(local)

        let result = try await ReaderContentLoader.appendSnippetHTML("<p>Local tail</p>", to: target, permitsCommit: { true })

        XCTAssertTrue(result.didChange)
        XCTAssertTrue(result.content === local)
        XCTAssertNil(local.realm)
        XCTAssertTrue(local.html?.contains("Local tail") == true)
        XCTAssertTrue(target.matchesPresentationContent(local))
        XCTAssertFalse(target.matchesPresentationContent(managed))
        await realm.asyncRefresh()
        XCTAssertFalse(managed.html?.contains("Local tail") == true)
        XCTAssertEqual(try journal(managed, in: realm), before)
    }

    func testUnmanagedCaptureCannotAcquireDurableAuthorityAfterPromotion() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let original = record(HistoryRecord())
        let target = try capture(original)
        try seed([original], in: realm)
        let before = try journal(original, in: realm)

        let result = try await ReaderContentLoader.appendSnippetHTML("<p>Unauthorized promotion</p>", to: target, permitsCommit: { true })

        XCTAssertFalse(result.didChange)
        XCTAssertNil(result.content)
        XCTAssertFalse(target.matchesPresentationContent(original))
        XCTAssertFalse(original.html?.contains("Unauthorized promotion") == true)
        XCTAssertEqual(try journal(original, in: realm), before)
    }

    func testReleasedLocalOriginCannotAdoptAnotherObjectWithEqualFields() async throws {
        var original: HistoryRecord? = record(HistoryRecord())
        let url = try XCTUnwrap(original).url
        let target = try capture(XCTUnwrap(original))
        weak var weakOriginal = original
        original = nil
        XCTAssertNil(weakOriginal, "Captured targets must not retain a managed or local UI record")
        let replacement = record(HistoryRecord(), url: url)

        let result = try await ReaderContentLoader.appendSnippetHTML("<p>Unavailable destination</p>", to: target, permitsCommit: { true })

        XCTAssertFalse(result.didChange)
        XCTAssertNil(result.content)
        XCTAssertFalse(target.matchesPresentationContent(replacement))
        XCTAssertFalse(replacement.html?.contains("Unavailable destination") == true)
    }

    func testCanonicalHistoryDiscoveryDoesNotExpandIntoOlderVisits() async throws {
        let configuration = configuration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await Realm(configuration: configuration)
        let primary = record(Bookmark())
        let canonical = record(HistoryRecord(), url: primary.url, html: "<p>Latest history</p>")
        let older = record(HistoryRecord(), url: primary.url, html: "<p>Older history</p>")
        older.compoundKey += "-older-visit"
        canonical.lastVisitedAt = Self.seedDate.addingTimeInterval(10)
        older.lastVisitedAt = Self.seedDate
        try seed([primary, canonical, older], in: realm)
        let olderBefore = try journal(older, in: realm)

        let result = try await ReaderContentLoader.appendSnippetHTML("<p>Current append</p>",
            to: capture(primary), permitsCommit: { true })

        XCTAssertTrue(result.didChange)
        await realm.asyncRefresh()
        XCTAssertTrue(primary.html?.contains("Current append") == true)
        XCTAssertTrue(canonical.html?.contains("Current append") == true)
        XCTAssertFalse(older.html?.contains("Current append") == true)
        XCTAssertEqual(try journal(older, in: realm), olderBefore)
    }
}
