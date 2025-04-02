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

        await realm.asyncRefresh()
        try await realm.asyncWrite {
            if let idx = libraryConfiguration.categoryIDs.firstIndex(of: category.id) {
                libraryConfiguration.categoryIDs.remove(at: idx)
                libraryConfiguration.refreshChangeMetadata(explicitlyModified: true)
            }
            
            if category.isArchived && !LibraryConfiguration.opmlURLs.map({ $0 }).contains(category.opmlURL) {
                category.isDeleted = true
                category.refreshChangeMetadata(explicitlyModified: true)
            } else if !category.isArchived {
                category.isArchived = true
                category.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }
    
    @RealmBackgroundActor
    func restoreCategory(_ category: FeedCategory) async throws {
        let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate()
        guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) else { return }

        await realm.asyncRefresh()
        try await realm.asyncWrite {
            category.isArchived = false
            if !libraryConfiguration.categoryIDs.contains(category.id) {
                libraryConfiguration.categoryIDs.append(category.id)
                libraryConfiguration.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }
}
