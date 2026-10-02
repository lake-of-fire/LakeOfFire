import SwiftUI
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@available(iOS 16.0, macOS 13.0, *)
@MainActor
final class LibraryViewCapturedRealmPortTests: XCTestCase {
    private var originalRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        originalRealmConfiguration = LibraryDataManager.realmConfiguration
    }

    override func tearDown() {
        LibraryDataManager.realmConfiguration = originalRealmConfiguration
        originalRealmConfiguration = nil
        super.tearDown()
    }

    func testCategoryReorderKeepsHiddenRawSlotInCapturedRealm() async throws {
        let captured = makeConfiguration()
        let replacement = makeConfiguration()
        let realm = try Realm(configuration: captured)

        let configuration = LibraryConfiguration()
        let first = FeedCategory()
        first.title = "First"
        let hidden = FeedCategory()
        hidden.title = "Managed"
        hidden.opmlURL = URL(string: "https://example.org/managed.opml")
        let second = FeedCategory()
        second.title = "Second"

        try realm.write {
            realm.add([configuration, first, hidden, second])
            configuration.categoryIDs.append(
                objectsIn: [first.id, hidden.id, second.id]
            )
        }

        let model = LibraryCategoriesViewModel(
            observesRealm: false,
            realmConfiguration: captured
        )
        model.libraryConfiguration = configuration
        model.userLibraryCategories = [first, second]

        LibraryDataManager.realmConfiguration = replacement

        let task = try XCTUnwrap(
            model.moveCategories(
                fromOffsets: IndexSet(integer: 0),
                toOffset: 2
            )
        )
        try await task.value
        _ = realm.refresh()

        XCTAssertEqual(
            Array(configuration.categoryIDs),
            [second.id, hidden.id, first.id]
        )

        let replacementRealm = try Realm(configuration: replacement)
        XCTAssertTrue(
            replacementRealm.objects(LibraryConfiguration.self).isEmpty
        )
        XCTAssertTrue(replacementRealm.objects(FeedCategory.self).isEmpty)
    }

    func testScriptReorderKeepsLockedSlotAndCapturedRealm() async throws {
        let captured = makeConfiguration()
        let replacement = makeConfiguration()
        let realm = try Realm(configuration: captured)

        let configuration = LibraryConfiguration()
        let first = UserScript()
        first.title = "First"
        let locked = UserScript()
        locked.title = "Managed"
        locked.opmlURL = URL(string: "https://example.org/managed.opml")
        let second = UserScript()
        second.title = "Second"

        try realm.write {
            realm.add([configuration, first, locked, second])
            configuration.userScriptIDs.append(
                objectsIn: [first.id, locked.id, second.id]
            )
        }

        let model = LibraryScriptsListViewModel(
            observesRealm: false,
            realmConfiguration: captured
        )
        model.libraryConfiguration = configuration
        model.userScripts = [first, locked, second]

        LibraryDataManager.realmConfiguration = replacement

        let task = try XCTUnwrap(
            model.moveScripts(
                fromOffsets: IndexSet(integer: 0),
                toOffset: 3
            )
        )
        try await task.value
        _ = realm.refresh()

        XCTAssertEqual(
            Array(configuration.userScriptIDs),
            [second.id, locked.id, first.id]
        )

        let replacementRealm = try Realm(configuration: replacement)
        XCTAssertTrue(
            replacementRealm.objects(LibraryConfiguration.self).isEmpty
        )
        XCTAssertTrue(replacementRealm.objects(UserScript.self).isEmpty)
    }

    func testDebouncedCategoryTitleWriteRevalidatesEditabilityAtCommit() async throws {
        let captured = makeConfiguration()
        let replacement = makeConfiguration()
        let realm = try Realm(configuration: captured)

        let configuration = LibraryConfiguration()
        let category = FeedCategory()
        category.title = "Original"
        try realm.write {
            realm.add([configuration, category])
            configuration.categoryIDs.append(category.id)
        }

        var selectedFeed: Feed?
        let model = LibraryCategoryViewModel(
            category: category,
            libraryConfiguration: configuration,
            selectedFeed: Binding(
                get: { selectedFeed },
                set: { selectedFeed = $0 }
            )
        )
        model.isEditing = true

        LibraryDataManager.realmConfiguration = replacement
        model.categoryTitle = "Stale queued edit"

        // Change authority before the debounced publication executes.
        try realm.write {
            category.opmlURL = URL(
                string: "https://example.org/managed-after-edit.opml"
            )
        }

        try await Task.sleep(nanoseconds: 650_000_000)
        _ = realm.refresh()

        XCTAssertEqual(category.title, "Original")
        XCTAssertFalse(category.isUserEditable)

        let replacementRealm = try Realm(configuration: replacement)
        XCTAssertTrue(replacementRealm.objects(FeedCategory.self).isEmpty)
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = DefaultRealmConfiguration.configuration
        configuration.fileURL = nil
        configuration.inMemoryIdentifier = UUID().uuidString
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }
}
