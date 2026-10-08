import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

final class LibraryConfigurationConsolidationTests: XCTestCase {
    func testConsolidationDoesNotAppendTheSameCategoryOrScriptFromMultipleDuplicates() async throws {
        try await verifyConsolidationDoesNotAppendTheSameCategoryOrScriptFromMultipleDuplicates()
    }

    @RealmBackgroundActor
    private func verifyConsolidationDoesNotAppendTheSameCategoryOrScriptFromMultipleDuplicates() async throws {
        let (configuration, realm) = try await makeRealm()
        let sharedCategory = FeedCategory()
        sharedCategory.title = "Shared category"
        let sharedScript = UserScript()
        sharedScript.title = "Shared script"

        let primary = LibraryConfiguration()
        primary.createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let firstDuplicate = LibraryConfiguration()
        firstDuplicate.createdAt = Date(timeIntervalSinceReferenceDate: 2_000)
        firstDuplicate.categoryIDs.append(sharedCategory.id)
        firstDuplicate.userScriptIDs.append(sharedScript.id)
        let secondDuplicate = LibraryConfiguration()
        secondDuplicate.createdAt = Date(timeIntervalSinceReferenceDate: 3_000)
        secondDuplicate.categoryIDs.append(sharedCategory.id)
        secondDuplicate.userScriptIDs.append(sharedScript.id)

        try realm.write {
            realm.add(sharedCategory)
            realm.add(sharedScript)
            realm.add([primary, firstDuplicate, secondDuplicate])
        }

        let consolidated = try await LibraryConfiguration.getConsolidatedOrCreate(
            realmConfiguration: configuration
        )

        XCTAssertEqual(consolidated.id, primary.id)
        XCTAssertEqual(
            consolidated.categoryIDs.filter { $0 == sharedCategory.id }.count,
            1
        )
        XCTAssertEqual(
            consolidated.userScriptIDs.filter { $0 == sharedScript.id }.count,
            1
        )
        XCTAssertTrue(firstDuplicate.isDeleted)
        XCTAssertTrue(secondDuplicate.isDeleted)
        XCTAssertNotNil(pendingMutation(for: primary, in: realm))
        XCTAssertNotNil(pendingMutation(for: firstDuplicate, in: realm))
        XCTAssertNotNil(pendingMutation(for: secondDuplicate, in: realm))
    }

    func testConsolidationDoesNotJournalUnchangedPrimaryConfiguration() async throws {
        try await verifyConsolidationDoesNotJournalUnchangedPrimaryConfiguration()
    }

    @RealmBackgroundActor
    private func verifyConsolidationDoesNotJournalUnchangedPrimaryConfiguration() async throws {
        let (configuration, realm) = try await makeRealm()
        let category = FeedCategory()
        category.title = "Existing category"
        let primary = LibraryConfiguration()
        primary.createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
        primary.categoryIDs.append(category.id)
        let duplicate = LibraryConfiguration()
        duplicate.createdAt = Date(timeIntervalSinceReferenceDate: 2_000)
        duplicate.categoryIDs.append(category.id)
        try realm.write {
            realm.add(category)
            realm.add([primary, duplicate])
        }
        let originalPrimaryModifiedAt = primary.modifiedAt

        let consolidated = try await LibraryConfiguration.getConsolidatedOrCreate(
            realmConfiguration: configuration
        )

        XCTAssertEqual(consolidated.id, primary.id)
        XCTAssertEqual(Array(primary.categoryIDs), [category.id])
        XCTAssertEqual(primary.modifiedAt, originalPrimaryModifiedAt)
        XCTAssertNil(pendingMutation(for: primary, in: realm))
        XCTAssertTrue(duplicate.isDeleted)
        XCTAssertNotNil(pendingMutation(for: duplicate, in: realm))
    }

    func testConsolidationPreservesExistingPlacementRuleAndDeduplicatesIncomingIDs() async throws {
        try await verifyConsolidationPreservesExistingPlacementRuleAndDeduplicatesIncomingIDs()
    }

    @RealmBackgroundActor
    private func verifyConsolidationPreservesExistingPlacementRuleAndDeduplicatesIncomingIDs() async throws {
        let (configuration, realm) = try await makeRealm()
        let categories = (0..<4).map { index -> FeedCategory in
            let category = FeedCategory()
            category.title = "Category \(index)"
            return category
        }
        let scripts = (0..<4).map { index -> UserScript in
            let script = UserScript()
            script.title = "Script \(index)"
            return script
        }
        let primary = LibraryConfiguration()
        primary.createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
        primary.categoryIDs.append(objectsIn: [categories[0].id, categories[3].id])
        primary.userScriptIDs.append(objectsIn: [scripts[0].id, scripts[3].id])
        let duplicate = LibraryConfiguration()
        duplicate.createdAt = Date(timeIntervalSinceReferenceDate: 2_000)
        duplicate.categoryIDs.append(objectsIn: [
            categories[0].id,
            categories[1].id,
            categories[1].id,
            categories[2].id,
            categories[3].id,
            categories[2].id,
        ])
        duplicate.userScriptIDs.append(objectsIn: [
            scripts[0].id,
            scripts[1].id,
            scripts[1].id,
            scripts[2].id,
            scripts[3].id,
            scripts[2].id,
        ])
        try realm.write {
            realm.add(categories)
            realm.add(scripts)
            realm.add([primary, duplicate])
        }

        let consolidated = try await LibraryConfiguration.getConsolidatedOrCreate(
            realmConfiguration: configuration
        )

        XCTAssertEqual(
            Array(consolidated.categoryIDs),
            [categories[0].id, categories[3].id, categories[1].id, categories[2].id]
        )
        XCTAssertEqual(
            Array(consolidated.userScriptIDs),
            [scripts[0].id, scripts[3].id, scripts[1].id, scripts[2].id]
        )
    }

    func testConsolidationRepairsPreexistingDuplicateIDsWithoutAnotherConfiguration() async throws {
        try await verifyConsolidationRepairsPreexistingDuplicateIDsWithoutAnotherConfiguration()
    }

    @RealmBackgroundActor
    private func verifyConsolidationRepairsPreexistingDuplicateIDsWithoutAnotherConfiguration() async throws {
        let (configuration, realm) = try await makeRealm()
        let firstCategory = FeedCategory()
        let secondCategory = FeedCategory()
        let firstScript = UserScript()
        let secondScript = UserScript()
        let primary = LibraryConfiguration()
        primary.createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
        primary.categoryIDs.append(objectsIn: [
            firstCategory.id,
            firstCategory.id,
            secondCategory.id,
            firstCategory.id,
        ])
        primary.userScriptIDs.append(objectsIn: [
            firstScript.id,
            firstScript.id,
            secondScript.id,
        ])
        try realm.write {
            realm.add([firstCategory, secondCategory])
            realm.add([firstScript, secondScript])
            realm.add(primary)
        }

        let consolidated = try await LibraryConfiguration.getConsolidatedOrCreate(
            realmConfiguration: configuration
        )

        XCTAssertEqual(
            Array(consolidated.categoryIDs),
            [firstCategory.id, secondCategory.id]
        )
        XCTAssertEqual(
            Array(consolidated.userScriptIDs),
            [firstScript.id, secondScript.id]
        )
        XCTAssertNotNil(pendingMutation(for: primary, in: realm))
    }

    func testConsolidationPreservesReferencesWhoseRecordsHaveNotArrivedYet() async throws {
        try await verifyConsolidationPreservesReferencesWhoseRecordsHaveNotArrivedYet()
    }

    @RealmBackgroundActor
    private func verifyConsolidationPreservesReferencesWhoseRecordsHaveNotArrivedYet() async throws {
        let (configuration, realm) = try await makeRealm()
        let categoryID = UUID()
        let userScriptID = UUID()
        let primary = LibraryConfiguration()
        primary.createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let duplicate = LibraryConfiguration()
        duplicate.createdAt = Date(timeIntervalSinceReferenceDate: 2_000)
        duplicate.categoryIDs.append(categoryID)
        duplicate.userScriptIDs.append(userScriptID)
        try realm.write {
            realm.add([primary, duplicate])
        }

        let consolidated = try await LibraryConfiguration.getConsolidatedOrCreate(
            realmConfiguration: configuration
        )

        XCTAssertEqual(Array(consolidated.categoryIDs), [categoryID])
        XCTAssertEqual(Array(consolidated.userScriptIDs), [userScriptID])
        XCTAssertTrue(duplicate.isDeleted)

        let category = FeedCategory()
        category.id = categoryID
        let userScript = UserScript()
        userScript.id = userScriptID
        try realm.write {
            realm.add(category)
            realm.add(userScript)
        }

        XCTAssertEqual(consolidated.getCategories()?.map(\.id), [categoryID])
        XCTAssertEqual(consolidated.getUserScripts()?.map(\.id), [userScriptID])
    }


    func testConsolidationAdmitsActiveOrphanScriptsDeterministically() async throws {
        try await verifyConsolidationAdmitsActiveOrphanScriptsDeterministically()
    }

    @RealmBackgroundActor
    private func verifyConsolidationAdmitsActiveOrphanScriptsDeterministically() async throws {
        let (configuration, realm) = try await makeRealm()
        let first = UserScript()
        first.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        first.createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let second = UserScript()
        second.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        second.createdAt = first.createdAt
        let archived = UserScript()
        archived.createdAt = Date(timeIntervalSinceReferenceDate: 500)
        archived.isArchived = true
        let primary = LibraryConfiguration()
        primary.createdAt = Date(timeIntervalSinceReferenceDate: 100)
        try realm.write {
            realm.add([first, second, archived])
            realm.add(primary)
        }

        let consolidated = try await LibraryConfiguration.getConsolidatedOrCreate(
            realmConfiguration: configuration
        )

        XCTAssertEqual(
            Array(consolidated.userScriptIDs),
            [second.id, first.id]
        )
        XCTAssertFalse(consolidated.userScriptIDs.contains(archived.id))
    }

    func testOrderedMergeRetainsLegacyPlacementPolicy() {
        XCTAssertEqual(
            mergeLibraryConfigurationIdentifiers(
                primary: ["A", "B"],
                incoming: ["A", "X", "X", "Y", "B", "Y"]
            ),
            ["A", "B", "X", "Y"]
        )
        XCTAssertEqual(
            mergeLibraryConfigurationIdentifiers(
                primary: ["A", "B", "C"],
                incoming: ["B", "X", "A"]
            ),
            ["A", "B", "X", "C"]
        )
        XCTAssertEqual(
            mergeLibraryConfigurationIdentifiers(
                primary: ["A", "B"],
                incoming: ["X", "Y"]
            ),
            ["A", "B", "X", "Y"]
        )
    }

    func testOldestCreatedConfigurationSurvivesEvenAfterLaterModification() async throws {
        try await verifyOldestCreatedConfigurationSurvivesEvenAfterLaterModification()
    }

    @RealmBackgroundActor
    private func verifyOldestCreatedConfigurationSurvivesEvenAfterLaterModification() async throws {
        let (configuration, realm) = try await makeRealm()
        let olderCategory = FeedCategory()
        let newerCategory = FeedCategory()
        let olderConfiguration = LibraryConfiguration()
        olderConfiguration.createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
        olderConfiguration.modifiedAt = Date(timeIntervalSinceReferenceDate: 4_000)
        olderConfiguration.categoryIDs.append(olderCategory.id)
        let newerConfiguration = LibraryConfiguration()
        newerConfiguration.createdAt = Date(timeIntervalSinceReferenceDate: 2_000)
        newerConfiguration.modifiedAt = Date(timeIntervalSinceReferenceDate: 1_500)
        newerConfiguration.categoryIDs.append(newerCategory.id)

        try realm.write {
            realm.add([olderCategory, newerCategory])
            realm.add([newerConfiguration, olderConfiguration])
        }

        let consolidated = try await LibraryConfiguration.getConsolidatedOrCreate(
            realmConfiguration: configuration
        )

        XCTAssertEqual(consolidated.id, olderConfiguration.id)
        XCTAssertEqual(
            Array(consolidated.categoryIDs),
            [olderCategory.id, newerCategory.id]
        )
        XCTAssertTrue(newerConfiguration.isDeleted)
    }

    func testEqualCreatedAtUsesIdentifierTieBreak() async throws {
        try await verifyEqualCreatedAtUsesIdentifierTieBreak()
    }

    @RealmBackgroundActor
    private func verifyEqualCreatedAtUsesIdentifierTieBreak() async throws {
        let (configuration, realm) = try await makeRealm()
        let sharedCreatedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let lowerCategory = FeedCategory()
        let higherCategory = FeedCategory()
        let lowerConfiguration = LibraryConfiguration()
        lowerConfiguration.id = lowerID
        lowerConfiguration.createdAt = sharedCreatedAt
        lowerConfiguration.modifiedAt = Date(timeIntervalSinceReferenceDate: 3_000)
        lowerConfiguration.categoryIDs.append(lowerCategory.id)
        let higherConfiguration = LibraryConfiguration()
        higherConfiguration.id = higherID
        higherConfiguration.createdAt = sharedCreatedAt
        higherConfiguration.modifiedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        higherConfiguration.categoryIDs.append(higherCategory.id)

        try realm.write {
            // Reverse insertion order so Realm insertion order cannot decide.
            realm.add([higherCategory, lowerCategory])
            realm.add([higherConfiguration, lowerConfiguration])
        }

        let consolidated = try await LibraryConfiguration.getConsolidatedOrCreate(
            realmConfiguration: configuration
        )

        XCTAssertEqual(consolidated.id, lowerID)
        XCTAssertEqual(
            Array(consolidated.categoryIDs),
            [lowerCategory.id, higherCategory.id]
        )
        XCTAssertTrue(higherConfiguration.isDeleted)
    }

    @RealmBackgroundActor
    private func makeRealm() async throws -> (Realm.Configuration, Realm) {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: UUID().uuidString
        )
        configuration.objectTypes = [
            LibraryConfiguration.self,
            FeedCategory.self,
            UserScript.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let realm = try await Realm(
            configuration: configuration,
            actor: RealmBackgroundActor.shared
        )
        return (configuration, realm)
    }

    private func pendingMutation(
        for object: Object,
        in realm: Realm
    ) -> BigSyncPendingMutation? {
        let primaryKey = object.objectSchema.primaryKeyProperty!.name
        let objectIdentifier = String(describing: object[primaryKey]!)
        return realm.object(
            ofType: BigSyncPendingMutation.self,
            forPrimaryKey: object.objectSchema.className + "." + objectIdentifier
        )
    }
}
