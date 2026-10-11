import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

final class LibraryConsolidationAdmissionContinuationTests: XCTestCase {
    func testNewRelationshipsIgnoreDuplicateListOrderAndModificationDates() async throws {
        try await verifyImmutableAdmission()
    }

    func testUnresolvedRelationshipTiesPreserveSourceOrderAndExcludeRetiredTargets() async throws {
        try await verifyUnresolvedRelationshipAdmission()
    }

    @RealmBackgroundActor
    private func verifyUnresolvedRelationshipAdmission() async throws {
        let existingMissingID = UUID()
        let firstMissingID = UUID()
        let secondMissingID = UUID()
        let thirdMissingID = UUID()
        let resolvedID = UUID()
        for reverseArrival in [false, true] {
            var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
            configuration.objectTypes = [
                LibraryConfiguration.self, FeedCategory.self, Feed.self, FeedEntry.self,
                FeedDirectory.self, UserScript.self, UserScriptAllowedDomain.self,
            ]
            configureLakeOfFireMutationTrackingForTesting(&configuration)
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let primary = LibraryConfiguration()
            primary.createdAt = Date(timeIntervalSinceReferenceDate: 0)
            primary.categoryIDs.append(existingMissingID)
            let firstDuplicate = LibraryConfiguration()
            firstDuplicate.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            firstDuplicate.createdAt = Date(timeIntervalSinceReferenceDate: 100)
            let secondDuplicate = LibraryConfiguration()
            secondDuplicate.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            secondDuplicate.createdAt = firstDuplicate.createdAt
            let resolved = FeedCategory()
            resolved.id = resolvedID
            resolved.createdAt = firstDuplicate.createdAt
            let deleted = FeedCategory()
            deleted.isDeleted = true
            let archived = FeedCategory()
            archived.isArchived = true
            firstDuplicate.categoryIDs.append(objectsIn: [firstMissingID, secondMissingID, deleted.id])
            secondDuplicate.categoryIDs.append(objectsIn: [thirdMissingID, secondMissingID, resolvedID, archived.id])
            try realm.write {
                realm.add([resolved, deleted, archived])
                realm.add(reverseArrival ? [secondDuplicate, firstDuplicate, primary]
                                         : [primary, firstDuplicate, secondDuplicate])
            }
            let consolidated = try await LibraryConfiguration.getConsolidatedOrCreate(
                realmConfiguration: configuration
            )
            XCTAssertEqual(consolidated.id, primary.id)
            XCTAssertEqual(Array(consolidated.categoryIDs),
                           [existingMissingID, resolvedID, firstMissingID, secondMissingID, thirdMissingID])
            XCTAssertTrue(firstDuplicate.isDeleted)
            XCTAssertTrue(secondDuplicate.isDeleted)
            let generations = Dictionary(uniqueKeysWithValues:
                realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
            )
            _ = try await LibraryConfiguration.getConsolidatedOrCreate(realmConfiguration: configuration)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues:
                realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
            ), generations)
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
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
    func testDisabledDuplicateScriptRetainsImmutableAdmissionAndSettles() async throws {
        try await verifyDisabledDuplicateAdmission()
    }

    @RealmBackgroundActor
    private func verifyDisabledDuplicateAdmission() async throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, Feed.self, FeedEntry.self,
            FeedDirectory.self, UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let retained = UserScript()
        retained.isArchived = true
        let disabled = UserScript()
        disabled.isArchived = true
        disabled.createdAt = Date(timeIntervalSinceReferenceDate: 10)
        let active = UserScript()
        active.createdAt = Date(timeIntervalSinceReferenceDate: 20)
        let deleted = UserScript()
        deleted.isDeleted = true
        let primary = LibraryConfiguration()
        primary.createdAt = Date(timeIntervalSinceReferenceDate: 100)
        primary.userScriptIDs.append(objectsIn: [retained.id, deleted.id])
        let duplicate = LibraryConfiguration()
        duplicate.createdAt = Date(timeIntervalSinceReferenceDate: 200)
        // Reverse the immutable arrival order, including a retired target.
        duplicate.userScriptIDs.append(objectsIn: [active.id, deleted.id, disabled.id])
        try realm.write {
            realm.add([retained, disabled, active, deleted])
            realm.add([primary, duplicate])
        }
        let result = try await LibraryConfiguration.getConsolidatedOrCreate(
            realmConfiguration: configuration
        )
        XCTAssertEqual(Array(result.userScriptIDs), [retained.id, disabled.id, active.id])
        XCTAssertTrue(duplicate.isDeleted)
        let generations = Dictionary(uniqueKeysWithValues:
            realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
        )
        _ = try await LibraryConfiguration.getConsolidatedOrCreate(realmConfiguration: configuration)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues:
            realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
        ), generations)
        try realm.write { disabled.isArchived = false }
        let afterEnableGenerations = Dictionary(uniqueKeysWithValues:
            realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
        )
        _ = try await LibraryConfiguration.getConsolidatedOrCreate(realmConfiguration: configuration)
        XCTAssertEqual(Array(result.userScriptIDs), [retained.id, disabled.id, active.id])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues:
            realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
        ), afterEnableGenerations)
        await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
    }

}
