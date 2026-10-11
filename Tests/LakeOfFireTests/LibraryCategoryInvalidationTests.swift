import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@MainActor
final class LibraryCategoryInvalidationTests: XCTestCase {
    private func configuration() -> Realm.Configuration {
        var result = Realm.Configuration(inMemoryIdentifier: UUID().uuidString,
            objectTypes: [FeedCategory.self, LibraryConfiguration.self, Feed.self,
                FeedDirectory.self, UserScript.self, UserScriptAllowedDomain.self])
        configureLakeOfFireMutationTrackingForTesting(&result)
        let captured = result
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: captured) }
        return result
    }

    private func generations(_ realm: Realm) -> [String: String] {
        Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self).map {
            ($0.recordName, $0.generation)
        })
    }

    func testBackgroundObjectCommandsIgnorePhysicallyDeletedCategory() async throws {
        let config = configuration()
        try await Task { @RealmBackgroundActor in
            let manager = LibraryDataManager(observesChanges: false)
            let realm = try await Realm.open(configuration: config, actor: RealmBackgroundActor.shared)
            let category = FeedCategory()
            try realm.write { realm.add(category) }
            try realm.write { realm.delete(category) }
            try await manager.deleteCategory(category)
            try await manager.restoreCategory(category)
            XCTAssertTrue(realm.objects(LibraryConfiguration.self).isEmpty)
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        }.value
    }

    func testListCommandsIgnoreInvalidCategoryWithoutJournaling() async throws {
        let config = configuration()
        let realm = try Realm(configuration: config)
        let category = FeedCategory()
        try realm.write { realm.add(category) }
        try realm.write { realm.delete(category) }
        let model = LibraryCategoriesViewModel(observesRealm: false, realmConfiguration: config)
        try await model.deleteCategory(category)
        try await model.restoreCategory(category)
        XCTAssertFalse(model.showDeleteButton(category: category))
        XCTAssertFalse(model.showRestoreButton(category: category))
        XCTAssertEqual(model.deletionTitle(category: category), "Archive")
        XCTAssertTrue(realm.objects(LibraryConfiguration.self).isEmpty)
        XCTAssertTrue(generations(realm).isEmpty)
    }

    func testEditorUICommandsIgnoreRetiredCategoryAndKeepStableTaskIdentity() async throws {
        let config = configuration()
        let realm = try Realm(configuration: config)
        let category = FeedCategory()
        let library = LibraryConfiguration()
        let id = category.id
        try realm.write { realm.add(category); realm.add(library) }
        let model = LibraryCategoryViewModel(category: category,
            libraryConfiguration: library, selectedFeed: .constant(nil))
        try realm.write { realm.delete(category) }
        let before = generations(realm)
        try await model.deleteCategory()
        try await model.restoreCategory()
        let newFeed = try await model.createFeed()
        XCTAssertNil(newFeed)
        XCTAssertEqual(model.categoryID, id)
        XCTAssertFalse(model.isUserEditable)
        XCTAssertFalse(model.showDeleteButton)
        XCTAssertFalse(model.showRestoreButton)
        XCTAssertEqual(model.deleteButtonTitle, "Archive")
        XCTAssertEqual(model.deleteButtonImageName, "archivebox")
        XCTAssertEqual(generations(realm), before)
        XCTAssertTrue(library.categoryIDs.isEmpty)
    }

    func testOffsetDeletionDoesNotShiftPastInvalidSnapshotMember() async throws {
        let config = configuration()
        let realm = try Realm(configuration: config)
        let stale = FeedCategory()
        let live = FeedCategory()
        let library = LibraryConfiguration()
        library.categoryIDs.append(objectsIn: [stale.id, live.id])
        try realm.write { realm.add([stale, live]); realm.add(library) }
        let model = LibraryCategoriesViewModel(observesRealm: false, realmConfiguration: config)
        model.userLibraryCategories = [stale, live]
        try realm.write { realm.delete(stale) }
        let before = generations(realm)
        try await model.deleteCategory(at: IndexSet([0, 7])).value
        realm.refresh()
        XCTAssertFalse(live.isArchived)
        XCTAssertEqual(generations(realm), before)
        try await model.deleteCategory(at: IndexSet(integer: 1)).value
        realm.refresh()
        XCTAssertTrue(live.isArchived)
        XCTAssertFalse(library.categoryIDs.contains(live.id))
        XCTAssertFalse(generations(realm).isEmpty)
    }

    func testReorderRejectsInvalidCategoryOrConfigurationWithoutJournaling() async throws {
        let config = configuration()
        let realm = try Realm(configuration: config)
        let stale = FeedCategory()
        let live = FeedCategory()
        let library = LibraryConfiguration()
        library.categoryIDs.append(objectsIn: [stale.id, live.id])
        let displayedIDs = Array(library.categoryIDs)
        try realm.write { realm.add([stale, live]); realm.add(library) }
        let model = LibraryCategoriesViewModel(observesRealm: false, realmConfiguration: config)
        model.libraryConfiguration = library
        model.userLibraryCategories = [stale, live]
        try realm.write { realm.delete(stale) }
        let before = generations(realm)
        XCTAssertNil(model.moveCategories(fromOffsets: IndexSet(integer: 0), toOffset: 2))
        XCTAssertEqual(Array(library.categoryIDs), displayedIDs)
        // The UI supplies detached IDs, so rejection must also happen inside
        // the real writer when a displayed category disappeared afterwards.
        let move = try XCTUnwrap(model.moveCategories(fromOffsets: IndexSet(integer: 0), toOffset: 2,
            displayedCategoryIDs: displayedIDs))
        try await move.value
        realm.refresh()
        XCTAssertEqual(Array(library.categoryIDs), displayedIDs)
        XCTAssertEqual(generations(realm), before)
        try realm.write { realm.delete(library) }
        XCTAssertNil(model.moveCategories(fromOffsets: IndexSet(integer: 0), toOffset: 2,
            displayedCategoryIDs: displayedIDs))
        XCTAssertEqual(generations(realm), before)
    }

    func testLiveArchiveRestoreAndRepeatedRestorePreserveJournalSemantics() async throws {
        let config = configuration()
        let realm = try Realm(configuration: config)
        let category = FeedCategory()
        let library = LibraryConfiguration()
        library.categoryIDs.append(category.id)
        try realm.write { realm.add(category); realm.add(library) }
        let model = LibraryCategoriesViewModel(observesRealm: false, realmConfiguration: config)
        try await model.deleteCategory(category)
        realm.refresh()
        XCTAssertTrue(category.isArchived)
        XCTAssertFalse(category.isDeleted)
        XCTAssertFalse(library.categoryIDs.contains(category.id))
        let archived = generations(realm)
        XCTAssertEqual(archived.count, 2)
        try await model.restoreCategory(category)
        realm.refresh()
        XCTAssertFalse(category.isArchived)
        XCTAssertEqual(Array(library.categoryIDs), [category.id])
        let restored = generations(realm)
        XCTAssertNotEqual(restored, archived)
        try await model.restoreCategory(category)
        realm.refresh()
        XCTAssertEqual(generations(realm), restored)
    }
}
