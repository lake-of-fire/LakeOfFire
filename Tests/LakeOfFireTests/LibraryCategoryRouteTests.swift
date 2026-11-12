import RealmSwift
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@MainActor
final class LibraryCategoryRouteTests: XCTestCase {
    func testArchiveDestinationResolvesAfterRelationshipRemoval() throws {
        let realm = try makeRealm()
        let library = LibraryConfiguration()
        let category = FeedCategory()
        library.categoryIDs.append(category.id)
        try realm.write { realm.add(library); realm.add(category) }
        try realm.write {
            library.categoryIDs.removeAll()
            category.isArchived = true
        }

        XCTAssertTrue(library.getCategories()?.isEmpty == true)
        XCTAssertEqual(LibraryCategoryRouteResolver.category(id: category.id, in: library)?.id, category.id)
    }

    func testUnlinkedCategoryRemainsReachableFromArchive() throws {
        let realm = try makeRealm()
        let library = LibraryConfiguration()
        let category = FeedCategory()
        try realm.write { realm.add(library); realm.add(category) }

        XCTAssertEqual(LibraryCategoryRouteResolver.category(id: category.id, in: library)?.id, category.id)
    }

    func testMissingAndDeletedCategoryAreNotDestinations() throws {
        let realm = try makeRealm()
        let library = LibraryConfiguration()
        let category = FeedCategory()
        category.isDeleted = true
        try realm.write { realm.add(library); realm.add(category) }

        XCTAssertNil(LibraryCategoryRouteResolver.category(id: UUID(), in: library))
        XCTAssertNil(LibraryCategoryRouteResolver.category(id: category.id, in: library))
    }

    func testRetiredLibraryCannotResolveAnOtherwiseLiveCategory() throws {
        let realm = try makeRealm()
        let library = LibraryConfiguration()
        let category = FeedCategory()
        try realm.write { realm.add(library); realm.add(category) }
        try realm.write { library.isDeleted = true }
        XCTAssertNil(LibraryCategoryRouteResolver.category(id: category.id, in: library))

        try realm.write { realm.delete(library) }
        XCTAssertNil(LibraryCategoryRouteResolver.category(id: category.id, in: library))
    }

    func testSameIDResolvesWithinTheLibraryRealm() throws {
        let firstRealm = try makeRealm()
        let secondRealm = try makeRealm()
        let firstLibrary = LibraryConfiguration()
        let firstCategory = FeedCategory()
        let secondLibrary = LibraryConfiguration()
        secondLibrary.id = firstLibrary.id
        let secondCategory = FeedCategory()
        secondCategory.id = firstCategory.id
        secondCategory.title = "Second storage"
        try firstRealm.write { firstRealm.add(firstLibrary); firstRealm.add(firstCategory) }
        try secondRealm.write { secondRealm.add(secondLibrary); secondRealm.add(secondCategory) }

        XCTAssertEqual(
            LibraryCategoryRouteResolver.category(id: firstCategory.id, in: secondLibrary)?.title,
            "Second storage"
        )
    }

    private func makeRealm() throws -> Realm {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [LibraryConfiguration.self, FeedCategory.self, UserScript.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return try Realm(configuration: configuration)
    }
}
