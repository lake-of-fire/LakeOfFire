import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

@MainActor
final class ReaderHistoryInvalidationTests: XCTestCase {
    func testDeletedBookmarkIsIgnoredBeforeDeletionReadsURL() async throws {
        let realm = try Realm(configuration: makeConfiguration())
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

    func testDeletedHistoryIsIgnoredBeforeDeletionReadsURL() async throws {
        let realm = try Realm(configuration: makeConfiguration())
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

    func testDeletedHistoryIsIgnoredBeforeDemotionReadsPersistedState() async throws {
        let configuration = makeConfiguration()
        try await Task { @RealmBackgroundActor in
            let realm = try await Realm.open(configuration: configuration, actor: RealmBackgroundActor.shared)
            let record = HistoryRecord()
            record.updateCompoundKey()
            try realm.write { realm.add(record) }
            try realm.write { realm.delete(record) }
            XCTAssertTrue(record.isInvalidated)

            try await record.refreshDemotedStatus()
            try await record.refreshDemotedStatus(skipPreviouslyDemoted: false)

            XCTAssertTrue(realm.objects(HistoryRecord.self).isEmpty)
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        }.value
    }

    func testLiveHistoryStillUpdatesDemotionAndJournalsMutation() async throws {
        let configuration = makeConfiguration()
        try await Task { @RealmBackgroundActor in
            let realm = try await Realm.open(configuration: configuration, actor: RealmBackgroundActor.shared)
            let record = HistoryRecord()
            record.isReaderModeAvailable = true
            record.updateCompoundKey()
            try realm.write { realm.add(record) }

            try await record.refreshDemotedStatus()

            XCTAssertEqual(record.isDemoted, false)
            XCTAssertNotNil(record.explicitlyModifiedAt)
            XCTAssertFalse(realm.objects(BigSyncPendingMutation.self).isEmpty)
        }.value
    }

    func testRejectedDemotionAdmissionStillCancelsWithoutMutation() async throws {
        let configuration = makeConfiguration()
        try await Task { @RealmBackgroundActor in
            let realm = try await Realm.open(configuration: configuration, actor: RealmBackgroundActor.shared)
            let record = HistoryRecord()
            record.isReaderModeAvailable = true
            record.updateCompoundKey()
            try realm.write { realm.add(record) }

            do {
                try await record.refreshDemotedStatus(admittingMutation: { false })
                XCTFail("Expected rejected admission to cancel")
            } catch is CancellationError {
                // Existing owner admission must remain effective.
            }

            XCTAssertNil(record.isDemoted)
            XCTAssertNil(record.explicitlyModifiedAt)
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        }.value
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, HistoryRecord.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }
}
