import Foundation
import RealmSwift
import LakeOfFireContent

/// Resolve routes in the library's existing Realm. Archived and unlinked rows
/// remain valid destinations even though they are absent from categoryIDs.
@MainActor
enum LibraryCategoryRouteResolver {
    static func category(id: UUID, in library: LibraryConfiguration) -> FeedCategory? {
        guard !library.isInvalidated, !library.isDeleted,
              let category = library.realm?.object(ofType: FeedCategory.self, forPrimaryKey: id),
              !category.isDeleted else { return nil }
        return category
    }
}


struct LibraryCategoryEditorIdentity: Hashable {
    let category: LibraryCategoryFieldIdentity
    let libraryID: UUID
    let libraryCreatedAt: Date

    @MainActor
    init?(category: FeedCategory, library: LibraryConfiguration) {
        guard !library.isInvalidated,
              let owner = LibraryCategoryFieldOwner(
                category: category, realmConfiguration: library.realm?.configuration
              ) else { return nil }
        self.category = LibraryCategoryFieldIdentity(owner: owner)
        libraryID = library.id
        libraryCreatedAt = library.createdAt
    }
}
