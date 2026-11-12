import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@MainActor
final class LibraryCategoryListSelectionTests: XCTestCase {
    func testDeletionUsesDisplayedIDsAfterModelOrderChanges() async throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let library = LibraryConfiguration()
        let first = FeedCategory()
        let second = FeedCategory()
        let displayedIDs = [first.id, second.id]
        library.categoryIDs.append(objectsIn: displayedIDs)
        try realm.write { realm.add(library); realm.add(first); realm.add(second) }
        let model = LibraryCategoriesViewModel(observesRealm: false, realmConfiguration: configuration)
        model.userLibraryCategories = [second, first]

        try await model.deleteCategory(at: IndexSet([0, 99]), fromCategoryIDs: displayedIDs).value

        realm.refresh()
        XCTAssertTrue(first.isArchived)
        XCTAssertFalse(second.isArchived)
        XCTAssertEqual(Array(library.categoryIDs), [second.id])
    }

    func testDisplayedDeletionStillRejectsNowNonEditableCategory() async throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let library = LibraryConfiguration()
        let category = FeedCategory()
        let displayedIDs = [category.id]
        library.categoryIDs.append(category.id)
        try realm.write { realm.add(library); realm.add(category) }
        try realm.write { category.opmlURL = URL(string: "https://example.com/managed.opml") }
        XCTAssertFalse(category.isUserEditable)
        let model = LibraryCategoriesViewModel(observesRealm: false, realmConfiguration: configuration)

        try await model.deleteCategory(at: IndexSet(integer: 0), fromCategoryIDs: displayedIDs).value

        realm.refresh()
        XCTAssertFalse(category.isArchived)
        XCTAssertFalse(category.isDeleted)
        XCTAssertEqual(Array(library.categoryIDs), displayedIDs)
    }

    func testReorderUsesDisplayedIDsAndPreservesHiddenSlots() async throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let library = LibraryConfiguration()
        let first = FeedCategory()
        let second = FeedCategory()
        let hiddenID = UUID()
        let displayedIDs = [first.id, second.id]
        library.categoryIDs.append(objectsIn: [first.id, hiddenID, second.id])
        try realm.write { realm.add(library); realm.add(first); realm.add(second) }
        let model = LibraryCategoriesViewModel(observesRealm: false, realmConfiguration: configuration)
        model.libraryConfiguration = library
        model.userLibraryCategories = [second, first]

        let task = try XCTUnwrap(model.moveCategories(
            fromOffsets: IndexSet(integer: 0), toOffset: 2, displayedCategoryIDs: displayedIDs
        ))
        try await task.value

        realm.refresh()
        XCTAssertEqual(Array(library.categoryIDs), [second.id, hiddenID, first.id])
    }

    func testReorderRejectsDisplayedOrderThatNoLongerMatchesStoredOrder() async throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let library = LibraryConfiguration()
        let first = FeedCategory()
        let second = FeedCategory()
        let displayedIDs = [first.id, second.id]
        library.categoryIDs.append(objectsIn: displayedIDs.reversed())
        try realm.write { realm.add(library); realm.add(first); realm.add(second) }
        let model = LibraryCategoriesViewModel(observesRealm: false, realmConfiguration: configuration)
        model.libraryConfiguration = library
        model.userLibraryCategories = [first, second]

        let task = try XCTUnwrap(model.moveCategories(
            fromOffsets: IndexSet(integer: 0), toOffset: 2, displayedCategoryIDs: displayedIDs
        ))
        try await task.value

        realm.refresh()
        XCTAssertEqual(Array(library.categoryIDs), Array(displayedIDs.reversed()))
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testMenuEligibilityDoesNotReadDeletedRealmProperties() throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let category = FeedCategory()
        try realm.write { realm.add(category) }
        try realm.write { realm.delete(category) }
        let model = LibraryCategoriesViewModel(observesRealm: false, realmConfiguration: configuration)

        XCTAssertFalse(model.showDeleteButton(category: category))
        XCTAssertFalse(model.showRestoreButton(category: category))
        XCTAssertEqual(model.deletionTitle(category: category), "Archive")
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
