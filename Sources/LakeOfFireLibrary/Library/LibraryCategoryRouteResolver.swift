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

