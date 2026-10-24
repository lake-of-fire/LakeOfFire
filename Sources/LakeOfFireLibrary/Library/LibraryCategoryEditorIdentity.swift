import Foundation
import RealmSwift
import LakeOfFireContent

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
