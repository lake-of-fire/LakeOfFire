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


private func categoryLibraryPhysicalRowID<T: ObjectKeyIdentifiable>(_ object: T) -> UInt64 { object.id }

struct LibraryCategoryEditorIdentity: Hashable, Sendable {
    let category: LibraryCategoryFieldIdentity
    let libraryID: UUID
    let libraryCreatedAt: Date
    let libraryPhysicalRowID: UInt64?

    init?(category: FeedCategory, library: LibraryConfiguration) {
        guard !library.isInvalidated,
              let owner = LibraryCategoryFieldOwner(
                category: category, realmConfiguration: library.realm?.configuration
              ) else { return nil }
        self.category = LibraryCategoryFieldIdentity(owner: owner)
        libraryID = library.id
        libraryCreatedAt = library.createdAt
        libraryPhysicalRowID = library.realm == nil ? nil : categoryLibraryPhysicalRowID(library)
    }

    func matchesLibrary(_ library: LibraryConfiguration) -> Bool {
        guard !library.isInvalidated, !library.isDeleted, let libraryPhysicalRowID, library.realm != nil else { return false }
        return library.id == libraryID && library.createdAt == libraryCreatedAt
            && categoryLibraryPhysicalRowID(library) == libraryPhysicalRowID
    }
}
