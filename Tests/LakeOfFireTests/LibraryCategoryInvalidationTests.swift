import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@MainActor
final class LibraryCategoryInvalidationTests: XCTestCase {
    func testBackgroundCommandsIgnorePhysicallyDeletedCategoryBeforeReadingItsID() async throws {
        let configuration = makeConfiguration()
        let manager = LibraryDataManager(observesChanges: false)
        try await Task { @RealmBackgroundActor in
            let realm = try await Realm.open(configuration: configuration, actor: RealmBackgroundActor.shared)
            let category = FeedCategory()
            try realm.write { realm.add(category) }
            try realm.write { realm.delete(category) }
            XCTAssertTrue(category.isInvalidated)

            try await manager.deleteCategory(category)
            try await manager.restoreCategory(category)

            XCTAssertTrue(realm.objects(FeedCategory.self).isEmpty)
            XCTAssertTrue(realm.objects(LibraryConfiguration.self).isEmpty)
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        }.value
    }

    func testMainActorCommandsIgnorePhysicallyDeletedCategoryBeforeCapturingItsID() async throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let category = FeedCategory()
        try realm.write { realm.add(category) }
        try realm.write { realm.delete(category) }
        let model = LibraryCategoriesViewModel(observesRealm: false, realmConfiguration: configuration)

        try await model.deleteCategory(category)
        try await model.restoreCategory(category)

        XCTAssertTrue(realm.objects(LibraryConfiguration.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testOffsetDeletionSkipsStaleRowsAndOutOfRangeOffsets() async throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let category = FeedCategory()
        try realm.write { realm.add(category) }
        let model = LibraryCategoriesViewModel(observesRealm: false, realmConfiguration: configuration)
        model.userLibraryCategories = [category]
        try realm.write { realm.delete(category) }

        try await model.deleteCategory(at: IndexSet([0, 7])).value

        XCTAssertTrue(realm.objects(LibraryConfiguration.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testReorderRejectsInvalidatedVisibleCategoryBeforeReadingIDs() throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let library = LibraryConfiguration()
        let category = FeedCategory()
        let categoryID = category.id
        library.categoryIDs.append(categoryID)
        try realm.write { realm.add(library); realm.add(category) }
        let model = LibraryCategoriesViewModel(observesRealm: false, realmConfiguration: configuration)
        model.libraryConfiguration = library
        model.userLibraryCategories = [category]
        try realm.write { realm.delete(category) }

        XCTAssertNil(model.moveCategories(fromOffsets: IndexSet(integer: 0), toOffset: 1))
        XCTAssertEqual(Array(library.categoryIDs), [categoryID])
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testReorderRejectsInvalidatedLibraryBeforeReadingRelationships() throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let library = LibraryConfiguration()
        let category = FeedCategory()
        try realm.write { realm.add(library); realm.add(category) }
        let model = LibraryCategoriesViewModel(observesRealm: false, realmConfiguration: configuration)
        model.libraryConfiguration = library
        model.userLibraryCategories = [category]
        try realm.write { realm.delete(library) }

        XCTAssertNil(model.moveCategories(fromOffsets: IndexSet(integer: 0), toOffset: 1))
        XCTAssertFalse(category.isArchived)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testNonObservingManagerStillArchivesAndRestoresLiveCategoryInExplicitRealm() async throws {
        let configuration = makeConfiguration()
        let manager = LibraryDataManager(observesChanges: false)
        try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let library = LibraryConfiguration()
            let category = FeedCategory()
            library.categoryIDs.append(category.id)
            try realm.write { realm.add(library); realm.add(category) }

            try await manager.deleteCategory(category)
            XCTAssertTrue(category.isArchived)
            XCTAssertFalse(library.categoryIDs.contains(category.id))

            try await manager.restoreCategory(category)
            XCTAssertFalse(category.isArchived)
            XCTAssertFalse(category.isDeleted)
            XCTAssertEqual(Array(library.categoryIDs), [category.id])
        }.value
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [LibraryConfiguration.self, FeedCategory.self, UserScript.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let capturedConfiguration = configuration
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: capturedConfiguration)
        }
        return configuration
    }
}
