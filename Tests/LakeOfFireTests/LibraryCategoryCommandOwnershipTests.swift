import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@RealmBackgroundActor
final class LibraryCategoryCommandOwnershipTests: XCTestCase {
    func testCategoryFieldReplayPreservesTheJournalGeneration() async throws {
        let configuration = makeConfiguration()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let category = FeedCategory()
        category.title = "Original"
        try await realm.asyncWrite { realm.add(category) }
        let timestamp = Date(timeIntervalSinceReferenceDate: 97_000)

        let result = try await LibraryCategoryFieldCommand.setTitle(
            "Saved", categoryID: category.id, categoryCreatedAt: category.createdAt,
            configuration: configuration, at: timestamp
        )
        XCTAssertEqual(result, .changed(changedAt: timestamp))
        let generation = try XCTUnwrap(journal(for: category, in: realm)?.generation)
        let replay = try await LibraryCategoryFieldCommand.setTitle(
            "Saved", categoryID: category.id, categoryCreatedAt: category.createdAt,
            configuration: configuration, at: timestamp.addingTimeInterval(1)
        )
        XCTAssertEqual(replay, .unchanged)
        XCTAssertEqual(journal(for: category, in: realm)?.generation, generation)
        XCTAssertEqual(journal(for: category, in: realm)?.changedAt, timestamp)
    }

    func testCategoryBatchRejectsAStaleTargetBeforeMutatingMembership() async throws {
        let configuration = makeConfiguration()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let category = FeedCategory()
        let library = LibraryConfiguration()
        library.categoryIDs.append(category.id)
        try await realm.asyncWrite { realm.add([category, library]) }
        let staleTarget = LibraryCategoryDeletionTarget(
            categoryID: category.id, createdAt: category.createdAt.addingTimeInterval(-1)
        )

        do {
            _ = try await LibraryDataManager.shared.deleteCategories(
                targets: [staleTarget], realmConfiguration: configuration
            )
            XCTFail("The replacement check must reject the stale command")
        } catch RealmBackgroundActorError.unableToResolveObject {
        }

        XCTAssertEqual(Array(library.categoryIDs), [category.id])
        XCTAssertFalse(category.isArchived)
        XCTAssertFalse(category.isDeleted)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testCategoryBatchJournalsMembershipAndCategoryAtOneTimestamp() async throws {
        let configuration = makeConfiguration()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let category = FeedCategory()
        let library = LibraryConfiguration()
        library.categoryIDs.append(category.id)
        try await realm.asyncWrite { realm.add([category, library]) }

        let result = try await LibraryDataManager.shared.deleteCategories(
            targets: [LibraryCategoryDeletionTarget(categoryID: category.id, createdAt: category.createdAt)],
            realmConfiguration: configuration
        )

        XCTAssertEqual(result.archivedCategoryIDs, [category.id])
        XCTAssertTrue(result.deletedCategoryIDs.isEmpty)
        XCTAssertTrue(category.isArchived)
        XCTAssertTrue(library.categoryIDs.isEmpty)
        XCTAssertEqual(journal(for: category, in: realm)?.changedAt, result.changedAt)
        XCTAssertEqual(journal(for: library, in: realm)?.changedAt, result.changedAt)
    }

    private func journal(for object: Object, in realm: Realm) -> BigSyncPendingMutation? {
        let primaryKey = object.objectSchema.primaryKeyProperty!.name
        let key = object.objectSchema.className + "." + String(describing: object[primaryKey]!)
        return realm.object(ofType: BigSyncPendingMutation.self, forPrimaryKey: key)
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, FeedDirectory.self, Feed.self,
            UserScript.self, UserScriptAllowedDomain.self, BigSyncPendingMutation.self,
        ]
        BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
        return configuration
    }
}
