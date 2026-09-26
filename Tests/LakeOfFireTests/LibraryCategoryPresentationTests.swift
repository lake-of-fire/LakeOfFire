import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@MainActor
final class LibraryCategoryPresentationTests: XCTestCase {
    func testDisplayedUserAndArchiveDeletionSelectsTheirOwnRows() async throws {
        let (realm, restoreConfiguration) = try makeRealm()
        defer { restoreConfiguration() }
        let first = category("First")
        let second = category("Second")
        let archived = category("Archived")
        archived.isArchived = true
        let configuration = LibraryConfiguration()
        configuration.categoryIDs.append(objectsIn: [first.id, second.id])
        try realm.write { realm.add([first, second, archived]); realm.add(configuration) }

        let model = LibraryCategoriesViewModel(observesRealm: false)
        model.libraryConfiguration = configuration
        model.userLibraryCategories = [second, first]
        model.archivedCategories = [archived]

        try await model.deleteCategory(at: IndexSet(integer: 0), from: model.userLibraryCategories).value
        realm.refresh()
        XCTAssertTrue(second.isArchived)
        XCTAssertFalse(first.isArchived)
        XCTAssertEqual(Array(configuration.categoryIDs), [first.id])
        XCTAssertNotNil(journal(for: second, in: realm))
        XCTAssertNotNil(journal(for: configuration, in: realm))

        try await model.deleteCategory(at: IndexSet(integer: 0), from: model.archivedCategories).value
        realm.refresh()
        XCTAssertTrue(archived.isDeleted)
        XCTAssertNotNil(journal(for: archived, in: realm))
        XCTAssertFalse(first.isDeleted)
    }

    func testReorderPreservesHiddenIDsAndStaleOrNoOpCommandsDoNotJournal() async throws {
        let (realm, restoreConfiguration) = try makeRealm()
        defer { restoreConfiguration() }
        let first = category("First")
        let hidden = category("Managed")
        hidden.opmlURL = URL(string: "https://example.com/managed.opml")
        let second = category("Second")
        let late = category("Late")
        let configuration = LibraryConfiguration()
        configuration.categoryIDs.append(objectsIn: [first.id, hidden.id, second.id])
        try realm.write { realm.add([first, hidden, second, late]); realm.add(configuration) }

        let model = LibraryCategoriesViewModel(observesRealm: false)
        model.libraryConfiguration = configuration
        model.userLibraryCategories = [first, second]
        let before = journalGenerations(in: realm)
        XCTAssertNil(model.moveCategories(fromOffsets: IndexSet(integer: 0), toOffset: 0))
        XCTAssertEqual(journalGenerations(in: realm), before)

        let moved = try XCTUnwrap(model.moveCategories(fromOffsets: IndexSet(integer: 1), toOffset: 0))
        try await moved.value
        realm.refresh()
        XCTAssertEqual(Array(configuration.categoryIDs), [second.id, hidden.id, first.id])
        XCTAssertNotNil(journal(for: configuration, in: realm))

        model.userLibraryCategories = [second, first]
        let stale = try XCTUnwrap(model.moveCategories(fromOffsets: IndexSet(integer: 1), toOffset: 0))
        try realm.write {
            configuration.categoryIDs.append(late.id)
            configuration.refreshChangeMetadata(explicitlyModified: true)
        }
        let afterNewerWrite = journalGenerations(in: realm)
        try await stale.value
        realm.refresh()
        XCTAssertEqual(Array(configuration.categoryIDs), [second.id, hidden.id, first.id, late.id])
        XCTAssertEqual(journalGenerations(in: realm), afterNewerWrite)
    }

    private func makeRealm() throws -> (Realm, () -> Void) {
        let previous = LibraryDataManager.realmConfiguration
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, Feed.self,
            FeedDirectory.self, UserScript.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        LibraryDataManager.realmConfiguration = configuration
        return (try Realm(configuration: configuration), {
            LibraryDataManager.realmConfiguration = previous
        })
    }

    private func category(_ title: String) -> FeedCategory {
        let result = FeedCategory()
        result.title = title
        result.backgroundImageUrl = URL(string: "https://example.com/category.png")!
        return result
    }

    private func journal(for object: Object, in realm: Realm) -> BigSyncPendingMutation? {
        let primaryKey = object.objectSchema.primaryKeyProperty!.name
        let identifier = String(describing: object[primaryKey]!)
        return realm.object(
            ofType: BigSyncPendingMutation.self,
            forPrimaryKey: object.objectSchema.className + "." + identifier
        )
    }

    private func journalGenerations(in realm: Realm) -> [String: String] {
        Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self).map {
            ($0.recordName, $0.generation)
        })
    }
}
