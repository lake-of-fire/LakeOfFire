import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

final class ReaderHistoryInvalidationTests: XCTestCase {
    @MainActor
    func testDeletedHistoryIsIgnoredBeforeDeletionReadsURL() async throws {
        let realm = try await Realm(configuration: makeConfiguration(), actor: MainActor.shared)
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
            let realm = try await Realm(configuration: configuration, actor: RealmBackgroundActor.shared)
            let record = HistoryRecord()
            record.updateCompoundKey()
            try realm.write { realm.add(record) }
            try realm.write { realm.delete(record) }
            XCTAssertTrue(record.isInvalidated)

            try await record.refreshDemotedStatus(bookmarkRealmConfiguration: configuration)
            try await record.refreshDemotedStatus(bookmarkRealmConfiguration: configuration,
                                                  skipPreviouslyDemoted: false)

            XCTAssertTrue(realm.objects(HistoryRecord.self).isEmpty)
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
