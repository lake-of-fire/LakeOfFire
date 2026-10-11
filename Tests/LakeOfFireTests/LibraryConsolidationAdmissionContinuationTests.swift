import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

final class LibraryConsolidationAdmissionContinuationTests: XCTestCase {
    func testNewRelationshipsIgnoreDuplicateListOrderAndModificationDates() async throws {
        try await verifyImmutableAdmission()
    }

    @RealmBackgroundActor
    private func verifyImmutableAdmission() async throws {
        let existingID = UUID()
        let earlierID = UUID()
        let laterID = UUID()
        let earlierScriptID = UUID()
        let laterScriptID = UUID()
        var results: [[UUID]] = []
        for reversed in [false, true] {
            var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
            configuration.objectTypes = [
                LibraryConfiguration.self, FeedCategory.self, Feed.self, FeedEntry.self,
                FeedDirectory.self, UserScript.self, UserScriptAllowedDomain.self,
            ]
            configureLakeOfFireMutationTrackingForTesting(&configuration)
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let existing = FeedCategory()
            existing.id = existingID
            let earlier = FeedCategory()
            earlier.id = earlierID
            earlier.createdAt = Date(timeIntervalSinceReferenceDate: 10)
            earlier.modifiedAt = Date(timeIntervalSinceReferenceDate: reversed ? 9_000 : 1)
            let later = FeedCategory()
            later.id = laterID
            later.createdAt = Date(timeIntervalSinceReferenceDate: 20)
            later.modifiedAt = Date(timeIntervalSinceReferenceDate: reversed ? 1 : 9_000)
            let earlierScript = UserScript()
            earlierScript.id = earlierScriptID
            earlierScript.createdAt = Date(timeIntervalSinceReferenceDate: 10)
            let laterScript = UserScript()
            laterScript.id = laterScriptID
            laterScript.createdAt = Date(timeIntervalSinceReferenceDate: 20)
            let primary = LibraryConfiguration()
            primary.createdAt = Date(timeIntervalSinceReferenceDate: 100)
            primary.categoryIDs.append(existingID)
            let duplicate = LibraryConfiguration()
            duplicate.createdAt = Date(timeIntervalSinceReferenceDate: 200)
            duplicate.categoryIDs.append(objectsIn: reversed ? [earlierID, laterID] : [laterID, earlierID])
            duplicate.userScriptIDs.append(objectsIn:
                reversed ? [earlierScriptID, laterScriptID] : [laterScriptID, earlierScriptID]
            )
            try realm.write {
                realm.add([existing, earlier, later])
                realm.add([earlierScript, laterScript])
                realm.add([duplicate, primary])
            }
            let consolidated = try await LibraryConfiguration.getConsolidatedOrCreate(
                realmConfiguration: configuration
            )
            XCTAssertEqual(consolidated.id, primary.id)
            XCTAssertEqual(Array(consolidated.categoryIDs), [existingID, earlierID, laterID])
            XCTAssertEqual(Array(consolidated.userScriptIDs), [earlierScriptID, laterScriptID])
            XCTAssertTrue(duplicate.isDeleted)
            results.append(Array(consolidated.categoryIDs))
            let generations = Dictionary(uniqueKeysWithValues:
                realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
            )
            _ = try await LibraryConfiguration.getConsolidatedOrCreate(realmConfiguration: configuration)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues:
                realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
            ), generations)
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
        XCTAssertEqual(results[0], results[1])
    }
}
