import BigSyncKit
import RealmSwift
import XCTest
@testable import RealmSwiftGaps
@testable import LakeOfFireContent

final class ReaderHistoryInvalidationTests: XCTestCase {
    @MainActor
    func testDeletedBookmarkIsIgnoredBeforeDeletionReadsURL() async throws {
        let realm = try Realm(configuration: Self.makeConfiguration())
        let bookmark = Bookmark()
        bookmark.url = URL(string: "https://example.com/retired-bookmark")!
        bookmark.updateCompoundKey()
        try realm.write { realm.add(bookmark) }
        try realm.write { realm.delete(bookmark) }
        XCTAssertTrue(bookmark.isInvalidated)

        try await bookmark.delete()

        XCTAssertTrue(realm.objects(Bookmark.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @MainActor
    func testDeletedHistoryIsIgnoredBeforeDeletionReadsURL() async throws {
        let realm = try Realm(configuration: Self.makeConfiguration())
        let record = HistoryRecord()
        record.url = URL(string: "https://example.com/retired-history")!
        record.updateCompoundKey()
        try realm.write { realm.add(record) }
        try realm.write { realm.delete(record) }
        XCTAssertTrue(record.isInvalidated)

        try await record.delete()

        XCTAssertTrue(realm.objects(HistoryRecord.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @RealmBackgroundActor
    func testDeletedHistoryIsIgnoredBeforeDemotionReadsPersistedState() async throws {
        let realm = try await Realm(
            configuration: Self.makeConfiguration(), actor: RealmBackgroundActor.shared
        )
        let record = Self.makeHistory()
        try realm.write { realm.add(record) }
        try realm.write { realm.delete(record) }
        XCTAssertTrue(record.isInvalidated)

        try await record.refreshDemotedStatus()
        try await record.refreshDemotedStatus(skipPreviouslyDemoted: false)

        XCTAssertTrue(realm.objects(HistoryRecord.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @RealmBackgroundActor
    func testLiveHistoryUpdatesDemotionAndJournalsOnlyOnce() async throws {
        let realm = try await Realm(
            configuration: Self.makeConfiguration(), actor: RealmBackgroundActor.shared
        )
        let record = Self.makeHistory()
        record.isReaderModeAvailable = true
        try realm.write { realm.add(record) }

        try await record.refreshDemotedStatus()

        XCTAssertEqual(record.isDemoted, false)
        let changedAt = try XCTUnwrap(record.explicitlyModifiedAt)
        let mutation = try XCTUnwrap(realm.objects(BigSyncPendingMutation.self).first)
        let generation = mutation.generation
        XCTAssertEqual(mutation.changedAt, changedAt)

        try await record.refreshDemotedStatus(skipPreviouslyDemoted: false)

        XCTAssertEqual(record.explicitlyModifiedAt, changedAt)
        XCTAssertEqual(mutation.generation, generation)
    }

    @RealmBackgroundActor
    func testDemotionPreservesDeletedHistoryTombstone() async throws {
        let realm = try await Realm(
            configuration: Self.makeConfiguration(), actor: RealmBackgroundActor.shared
        )
        let record = Self.makeHistory()
        try realm.write {
            realm.add(record)
            record.isDeleted = true
            record.refreshChangeMetadata(explicitlyModified: true)
        }
        let changedAt = record.explicitlyModifiedAt
        let mutation = try XCTUnwrap(realm.objects(BigSyncPendingMutation.self).first)
        let generation = mutation.generation

        try await record.refreshDemotedStatus(skipPreviouslyDemoted: false)

        XCTAssertTrue(record.isDeleted)
        XCTAssertNil(record.isDemoted)
        XCTAssertEqual(record.explicitlyModifiedAt, changedAt)
        XCTAssertEqual(mutation.generation, generation)
    }

    @RealmBackgroundActor
    func testQueuedDemotionIgnoresDeletedAccessorAndPreservesReplacement() async throws {
        let realm = try await Realm(
            configuration: Self.makeConfiguration(), actor: RealmBackgroundActor.shared
        )
        let record = Self.makeHistory()
        let key = record.compoundKey
        try realm.write { realm.add(record) }
        try realm.beginWrite()

        let submitted = XCTestExpectation(description: "Demotion write submitted")
        let refresh = queuedRefresh(of: record, submitted: submitted)
        cleanUpQueuedWrite(refresh, in: realm)
        await fulfillment(of: [submitted], timeout: 5)

        realm.delete(record)
        let replacement = Self.makeHistory()
        replacement.compoundKey = key
        realm.add(replacement)
        try realm.commitWrite()
        try await refresh.value

        XCTAssertTrue(record.isInvalidated)
        XCTAssertNil(replacement.isDemoted)
        XCTAssertNil(replacement.explicitlyModifiedAt)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @RealmBackgroundActor
    func testQueuedDemotionUsesInputsChangedBeforeAdmission() async throws {
        let realm = try await Realm(
            configuration: Self.makeConfiguration(), actor: RealmBackgroundActor.shared
        )
        let record = Self.makeHistory()
        try realm.write { realm.add(record) }
        try realm.beginWrite()

        let submitted = XCTestExpectation(description: "Demotion write submitted")
        let refresh = queuedRefresh(of: record, submitted: submitted)
        cleanUpQueuedWrite(refresh, in: realm)
        await fulfillment(of: [submitted], timeout: 5)

        record.isReaderModeAvailable = true
        try realm.commitWrite()
        try await refresh.value

        XCTAssertEqual(record.isDemoted, false)
        XCTAssertNotNil(record.explicitlyModifiedAt)
        XCTAssertFalse(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @RealmBackgroundActor
    func testQueuedDemotionPreservesTombstoneWrittenBeforeAdmission() async throws {
        let realm = try await Realm(
            configuration: Self.makeConfiguration(), actor: RealmBackgroundActor.shared
        )
        let record = Self.makeHistory()
        try realm.write { realm.add(record) }
        try realm.beginWrite()

        let submitted = XCTestExpectation(description: "Demotion write submitted")
        let refresh = queuedRefresh(of: record, submitted: submitted)
        cleanUpQueuedWrite(refresh, in: realm)
        await fulfillment(of: [submitted], timeout: 5)

        record.isDeleted = true
        record.refreshChangeMetadata(explicitlyModified: true)
        let changedAt = record.explicitlyModifiedAt
        let mutation = try XCTUnwrap(realm.objects(BigSyncPendingMutation.self).first)
        let generation = mutation.generation
        try realm.commitWrite()
        try await refresh.value

        XCTAssertTrue(record.isDeleted)
        XCTAssertNil(record.isDemoted)
        XCTAssertEqual(record.explicitlyModifiedAt, changedAt)
        XCTAssertEqual(mutation.generation, generation)
    }

    @RealmBackgroundActor
    func testQueuedDemotionDoesNotAcceptAnotherWritersTentativeNoop() async throws {
        let realm = try await Realm(
            configuration: Self.makeConfiguration(), actor: RealmBackgroundActor.shared
        )
        let record = Self.makeHistory()
        try realm.write { realm.add(record) }
        try realm.beginWrite()
        record.isDemoted = false

        let submitted = XCTestExpectation(description: "Demotion write submitted")
        let refresh = queuedRefresh(of: record, submitted: submitted)
        cleanUpQueuedWrite(refresh, in: realm)
        await fulfillment(of: [submitted], timeout: 5)

        realm.cancelWrite()
        try await refresh.value

        XCTAssertEqual(record.isDemoted, true)
        XCTAssertNotNil(record.explicitlyModifiedAt)
        XCTAssertFalse(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @RealmBackgroundActor
    func testCancelledQueuedDemotionLeavesOtherWritersTransactionOpen() async throws {
        let realm = try await Realm(
            configuration: Self.makeConfiguration(), actor: RealmBackgroundActor.shared
        )
        let record = Self.makeHistory()
        try realm.write { realm.add(record) }
        try realm.beginWrite()

        let submitted = XCTestExpectation(description: "Demotion write submitted")
        let refresh = queuedRefresh(of: record, submitted: submitted)
        cleanUpQueuedWrite(refresh, in: realm)
        await fulfillment(of: [submitted], timeout: 5)
        refresh.cancel()

        switch await refresh.result {
        case .success:
            XCTFail("A cancelled queued refresh must not succeed")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(realm.isInWriteTransaction)
        record.title = "Owner still owns its write"
        try realm.commitWrite()
        XCTAssertNil(record.isDemoted)
        XCTAssertNil(record.explicitlyModifiedAt)
        XCTAssertEqual(record.title, "Owner still owns its write")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @RealmBackgroundActor
    func testQueuedBookmarkDeletionIgnoresRetiredResolvedAccessor() async throws {
        let configuration = Self.makeConfiguration()
        let realm = try await Realm(configuration: configuration, actor: RealmBackgroundActor.shared)
        let bookmark = Bookmark()
        bookmark.url = URL(string: "https://example.com/queued-bookmark")!
        bookmark.updateCompoundKey()
        let key = bookmark.compoundKey
        try realm.write { realm.add(bookmark) }
        try realm.beginWrite()

        let submitted = XCTestExpectation(description: "Bookmark deletion submitted")
        let deletion = Task { @MainActor in
            let viewRealm = try Realm(configuration: configuration)
            let displayed = try XCTUnwrap(viewRealm.object(ofType: Bookmark.self, forPrimaryKey: key))
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await displayed.delete()
            }
        }
        cleanUpQueuedWrite(deletion, in: realm)
        await fulfillment(of: [submitted], timeout: 5)

        realm.delete(bookmark)
        let replacement = Bookmark()
        replacement.compoundKey = key
        replacement.url = URL(string: "https://example.com/queued-bookmark")!
        realm.add(replacement)
        try realm.commitWrite()
        try await deletion.value

        XCTAssertTrue(bookmark.isInvalidated)
        XCTAssertFalse(replacement.isDeleted)
        XCTAssertNil(replacement.explicitlyModifiedAt)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @RealmBackgroundActor
    func testCancelledQueuedHistoryDeletionLeavesOtherWritersTransactionOpen() async throws {
        let configuration = Self.makeConfiguration()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        addTeardownBlock { @RealmBackgroundActor in Self.releaseCache(configuration) }
        let record = Self.makeHistory()
        let key = record.compoundKey
        try realm.write { realm.add(record) }
        try realm.beginWrite()

        let submitted = XCTestExpectation(description: "History deletion submitted")
        let deletion = Task { @MainActor in
            let viewRealm = try Realm(configuration: configuration)
            let displayed = try XCTUnwrap(viewRealm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await displayed.delete()
            }
        }
        cleanUpQueuedWrite(deletion, in: realm)
        await fulfillment(of: [submitted], timeout: 5)
        deletion.cancel()

        switch await deletion.result {
        case .success:
            XCTFail("A cancelled queued deletion must not succeed")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(realm.isInWriteTransaction)
        record.title = "Owner still owns its write"
        try realm.commitWrite()
        XCTAssertFalse(record.isDeleted)
        XCTAssertNil(record.explicitlyModifiedAt)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @RealmBackgroundActor
    private func queuedRefresh(
        of record: HistoryRecord,
        submitted: XCTestExpectation
    ) -> Task<Void, Error> {
        Task { @RealmBackgroundActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await record.refreshDemotedStatus()
            }
        }
    }

    @RealmBackgroundActor
    private func cleanUpQueuedWrite(_ task: Task<Void, Error>, in realm: Realm) {
        addTeardownBlock { @RealmBackgroundActor in
            task.cancel()
            if realm.isInWriteTransaction { realm.cancelWrite() }
            _ = await task.result
        }
    }

    private static func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, HistoryRecord.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

    private static func makeHistory() -> HistoryRecord {
        let record = HistoryRecord()
        record.url = URL(string: "https://example.com/history")!
        record.updateCompoundKey()
        return record
    }

    @RealmBackgroundActor
    private static func releaseCache(_ configuration: Realm.Configuration) {
        let actor = RealmBackgroundActor.shared
        let keys = actor.cachedRealms.keys.filter {
            actor.cachedRealms[$0]?.configuration.inMemoryIdentifier == configuration.inMemoryIdentifier
        }
        for key in keys {
            guard actor.cachedRealms[key]?.isInWriteTransaction == false else { continue }
            actor.cachedRealms.removeValue(forKey: key)?.invalidate()
        }
    }
}
