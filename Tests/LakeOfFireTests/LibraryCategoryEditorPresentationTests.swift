import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@MainActor
final class LibraryCategoryEditorPresentationTests: XCTestCase {
    func testRetiredEditorKeepsStableIdentityAndAvoidsManagedPresentationReads() throws {
        let (realm, category, library, model) = try fixture()
        let categoryID = category.id
        try realm.write { realm.delete(category); realm.delete(library) }

        XCTAssertEqual(model.categoryID, categoryID)
        XCTAssertFalse(model.isUserEditable)
        XCTAssertFalse(model.showDeleteButton)
        XCTAssertFalse(model.showRestoreButton)
        XCTAssertFalse(model.showMoreOptions)
        XCTAssertEqual(model.deleteButtonTitle, "Archive")
        XCTAssertEqual(model.deleteButtonImageName, "archivebox")
        XCTAssertNil(model.managedOPMLURL)
        XCTAssertTrue(model.visibleFeeds.isEmpty)
        XCTAssertTrue(model.duplicationCategories.isEmpty)
        XCTAssertEqual(model.categoryImageURL.absoluteString, "about:blank")
        model.categoryTitle = "Retained draft"
        model.refresh()
        XCTAssertEqual(model.categoryTitle, "Retained draft")
    }

    func testRetiredCategoryCommandsCannotMutateOrCreateLibraryState() async throws {
        let (realm, category, _, model) = try fixture()
        try realm.write { realm.delete(category) }

        let created = try await model.createFeed()
        XCTAssertNil(created)
        try await model.deleteCategory()
        try await model.restoreCategory()
        try await model.deleteFeed(at: IndexSet([0, 9]), fromFeedIDs: [UUID()]).value

        XCTAssertTrue(realm.objects(Feed.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testDisplayedFeedDeletionUsesCapturedIDsAfterRename() async throws {
        let (realm, category, _, model) = try fixture()
        let first = feed("A", categoryID: category.id)
        let second = feed("B", categoryID: category.id)
        let firstID = first.id
        let secondID = second.id
        try realm.write { realm.add([first, second]) }
        let displayedIDs = [firstID, secondID]
        try realm.write { first.title = "Z" }

        try await model.deleteFeed(at: IndexSet(integer: 0), fromFeedIDs: displayedIDs).value
        realm.refresh()

        XCTAssertTrue(first.isDeleted)
        XCTAssertFalse(second.isDeleted)
    }

    func testDisplayedFeedDeletionRejectsFeedMovedToAnotherCategory() async throws {
        let (realm, category, _, model) = try fixture()
        let other = FeedCategory()
        let item = feed("Moved", categoryID: category.id)
        let displayedIDs = [item.id]
        try realm.write { realm.add(other); realm.add(item) }
        try realm.write { item.categoryID = other.id }

        try await model.deleteFeed(at: IndexSet(integer: 0), fromFeedIDs: displayedIDs).value
        realm.refresh()

        XCTAssertFalse(item.isDeleted)
        XCTAssertEqual(item.categoryID, other.id)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testContextDeletionDoesNotReadRetiredFeedID() async throws {
        let (realm, category, _, model) = try fixture()
        let item = feed("Retired", categoryID: category.id)
        try realm.write { realm.add(item) }
        try realm.write { realm.delete(item) }

        try await model.deleteFeed(item)

        XCTAssertTrue(realm.objects(Feed.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    private func fixture() throws -> (Realm, FeedCategory, LibraryConfiguration, LibraryCategoryViewModel) {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, Feed.self,
            FeedDirectory.self, UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let capturedConfiguration = configuration
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: capturedConfiguration)
        }
        let realm = try Realm(configuration: configuration)
        let category = FeedCategory()
        category.title = "Category"
        category.backgroundImageUrl = URL(string: "https://example.com/category.png")!
        let library = LibraryConfiguration()
        library.categoryIDs.append(category.id)
        try realm.write { realm.add(category); realm.add(library) }
        let model = LibraryCategoryViewModel(
            category: category, libraryConfiguration: library, selectedFeed: .constant(nil)
        )
        return (realm, category, library, model)
    }

    private func feed(_ title: String, categoryID: UUID) -> Feed {
        let result = Feed()
        result.title = title
        result.categoryID = categoryID
        result.rssUrl = URL(string: "https://example.com/\(result.id).xml")!
        return result
    }
}
