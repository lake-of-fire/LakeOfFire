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

        await realm.asyncRefresh()
        try await realm.asyncWrite {
            category.isArchived = false
            if !libraryConfiguration.categoryIDs.contains(category.id) {
                libraryConfiguration.categoryIDs.append(category.id)
                libraryConfiguration.modifiedAt = Date()
            }
        }
    }
}
