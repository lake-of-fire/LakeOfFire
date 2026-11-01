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

    func testNewConfigurationAdmitsActiveOrphansDeterministicallyAndRetainsArchivedObjects() async throws {
        try await verifyNewConfigurationAdmitsActiveOrphansDeterministicallyAndRetainsArchivedObjects()
    }

    @RealmBackgroundActor
    private func verifyNewConfigurationAdmitsActiveOrphansDeterministicallyAndRetainsArchivedObjects() async throws {
        let (configuration, realm) = try await makeRealm()
        let scripts = (1...3).map { index -> UserScript in
            let script = UserScript()
            script.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
            script.createdAt = Date(timeIntervalSinceReferenceDate: index == 3 ? 2_000 : 1_000)
            return script
        }
        let categories = (1...3).map { index -> FeedCategory in
            let category = FeedCategory()
            category.id = scripts[index - 1].id
            category.createdAt = scripts[index - 1].createdAt
            return category
        }
        let archivedScript = UserScript()
        archivedScript.isArchived = true
        archivedScript.script = "Retain archived source"
        let archivedCategory = FeedCategory()
        archivedCategory.isArchived = true
        let deletedScript = UserScript()
        deletedScript.isDeleted = true
        try realm.write {
            // Reverse delivery order; creation must use the same admission keys
            // as consolidation of an already-existing configuration.
            realm.add(Array(scripts.reversed()))
            realm.add(Array(categories.reversed()))
            realm.add([archivedScript, deletedScript])
            realm.add(archivedCategory)
        }

        let primary = try await LibraryConfiguration.getConsolidatedOrCreate(
            realmConfiguration: configuration
        )

        XCTAssertEqual(Array(primary.userScriptIDs), scripts.map(\.id))
        XCTAssertEqual(Array(primary.categoryIDs), categories.map(\.id))
        XCTAssertEqual(realm.objects(LibraryConfiguration.self).count, 1)
        XCTAssertNotNil(primary.realm)
        let mutation = try XCTUnwrap(pendingMutation(for: primary, in: realm))
        XCTAssertEqual(mutation.changedAt, primary.modifiedAt)
        XCTAssertEqual(primary.explicitlyModifiedAt, primary.modifiedAt)
        XCTAssertEqual(realm.object(ofType: UserScript.self, forPrimaryKey: archivedScript.id)?.script,
                       "Retain archived source")
        XCTAssertTrue(archivedScript.isArchived)
        XCTAssertFalse(archivedScript.isDeleted)
        XCTAssertTrue(archivedCategory.isArchived)
        XCTAssertFalse(archivedCategory.isDeleted)
        XCTAssertTrue(deletedScript.isDeleted)
        XCTAssertNil(pendingMutation(for: archivedScript, in: realm))
        XCTAssertNil(pendingMutation(for: archivedCategory, in: realm))
    }

    func testRepeatedConsolidationPreservesStableJournalAndMetadata() async throws {
        try await verifyRepeatedConsolidationPreservesStableJournalAndMetadata()
    }

    @RealmBackgroundActor
    private func verifyRepeatedConsolidationPreservesStableJournalAndMetadata() async throws {
        let (configuration, realm) = try await makeRealm()
        let script = UserScript()
        let archived = UserScript()
        archived.isArchived = true
        let unresolvedID = UUID()
        let primary = LibraryConfiguration()
        primary.userScriptIDs.append(objectsIn: [unresolvedID, archived.id])
        try realm.write {
            realm.add([script, archived])
            realm.add(primary)
        }
        _ = try await LibraryConfiguration.getConsolidatedOrCreate(realmConfiguration: configuration)
        let mutation = try XCTUnwrap(pendingMutation(for: primary, in: realm))
        let generation = mutation.generation
        let changedAt = mutation.changedAt
        let modifiedAt = primary.modifiedAt
        let explicitlyModifiedAt = primary.explicitlyModifiedAt

        for _ in 0..<3 {
            let result = try await LibraryConfiguration.getConsolidatedOrCreate(
                realmConfiguration: configuration
            )
            XCTAssertEqual(result.id, primary.id)
            XCTAssertEqual(Array(result.userScriptIDs), [unresolvedID, script.id])
            XCTAssertEqual(result.modifiedAt, modifiedAt)
            XCTAssertEqual(result.explicitlyModifiedAt, explicitlyModifiedAt)
            XCTAssertEqual(pendingMutation(for: result, in: realm)?.generation, generation)
            XCTAssertEqual(pendingMutation(for: result, in: realm)?.changedAt, changedAt)
        }
        XCTAssertTrue(archived.isArchived)
        XCTAssertFalse(archived.isDeleted)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
    }

    func testCreateEmptyScriptWithExistingConfigurationAdmitsOnceAndPreservesOrder() async throws {
        try await verifyCreateEmptyScriptAdmitsOnce(preexistingConfiguration: true)
    }

    func testCreateEmptyScriptWithoutConfigurationAdmitsOnceAndJournalsCreation() async throws {
        try await verifyCreateEmptyScriptAdmitsOnce(preexistingConfiguration: false)
    }

    @RealmBackgroundActor
    private func verifyCreateEmptyScriptAdmitsOnce(preexistingConfiguration: Bool) async throws {
        let (configuration, realm) = try await makeRealm()
        let earlier = UserScript()
        earlier.createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let later = UserScript()
        later.createdAt = Date(timeIntervalSinceReferenceDate: 2_000)
        let unresolvedID = UUID()
        let existing = LibraryConfiguration()
        existing.userScriptIDs.append(objectsIn: [later.id, unresolvedID, earlier.id])
        try realm.write {
            realm.add([later, earlier])
            if preexistingConfiguration { realm.add(existing) }
        }

        let scriptID = try await LibraryDataManager.shared.createEmptyScript(
            addToLibrary: true, realmConfiguration: configuration
        )
        let primary = try XCTUnwrap(realm.objects(LibraryConfiguration.self).where { !$0.isDeleted }.first)
        let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: scriptID))
        let expectedPrefix = preexistingConfiguration
            ? [later.id, unresolvedID, earlier.id] : [earlier.id, later.id]
        XCTAssertEqual(Array(primary.userScriptIDs), expectedPrefix + [scriptID])
        XCTAssertEqual(primary.userScriptIDs.filter { $0 == scriptID }.count, 1)
        if preexistingConfiguration { XCTAssertEqual(primary.id, existing.id) }
        XCTAssertEqual(realm.objects(LibraryConfiguration.self).count, 1)
        let libraryMutation = try XCTUnwrap(pendingMutation(for: primary, in: realm))
        let scriptMutation = try XCTUnwrap(pendingMutation(for: script, in: realm))
        XCTAssertEqual(libraryMutation.changedAt, primary.modifiedAt)
        XCTAssertEqual(scriptMutation.changedAt, script.modifiedAt)
        XCTAssertEqual(script.explicitlyModifiedAt, script.modifiedAt)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 2)
        let libraryGeneration = libraryMutation.generation
        let scriptGeneration = scriptMutation.generation
        let modifiedAt = primary.modifiedAt

        _ = try await LibraryConfiguration.getConsolidatedOrCreate(realmConfiguration: configuration)
        XCTAssertEqual(Array(primary.userScriptIDs), expectedPrefix + [scriptID])
        XCTAssertEqual(primary.modifiedAt, modifiedAt)
        XCTAssertEqual(pendingMutation(for: primary, in: realm)?.generation, libraryGeneration)
        XCTAssertEqual(pendingMutation(for: script, in: realm)?.generation, scriptGeneration)
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
