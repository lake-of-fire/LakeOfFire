import SwiftUI
import RealmSwift
import RealmSwiftGaps

public extension LibraryDataManager {
    @RealmBackgroundActor
    func deleteCategory(_ category: FeedCategory) async throws {
        if !category.isUserEditable || (category.isArchived && category.opmlURL != nil) {
            return
        }
        
        let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate()
        guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) else { return }

        try await realm.asyncWrite {
            if let idx = libraryConfiguration.categories.firstIndex(of: category) {
                libraryConfiguration.categories.remove(at: idx)
                libraryConfiguration.modifiedAt = Date()
            }
            
            if category.isArchived && !LibraryConfiguration.opmlURLs.map({ $0 }).contains(category.opmlURL) {
                category.isDeleted = true
                category.modifiedAt = Date()
            } else if !category.isArchived {
                category.isArchived = true
                category.modifiedAt = Date()
            }
        }
    }
    
    @RealmBackgroundActor
    func restoreCategory(_ category: FeedCategory) async throws {
        let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate()
        guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) else { return }

        try await realm.asyncWrite {
            category.isArchived = false
            if !libraryConfiguration.categories.contains(category) {
                libraryConfiguration.categories.append(category)
                libraryConfiguration.modifiedAt = Date()
            }
        }
    }
}
