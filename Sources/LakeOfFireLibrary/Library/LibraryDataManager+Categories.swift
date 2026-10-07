import LakeOfFireWeb
import SwiftUI
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireReader
import LakeOfFireContent
import LakeOfFireCore
import RealmSwift
import RealmSwiftGaps

public extension LibraryDataManager {
    @RealmBackgroundActor
    func deleteCategory(_ category: FeedCategory) async throws {
        let realmConfiguration = category.realm?.configuration ?? LibraryDataManager.realmConfiguration
        try await deleteCategory(categoryID: category.id, realmConfiguration: realmConfiguration)
    }

    @RealmBackgroundActor
    func deleteCategory(
        categoryID: UUID,
        realmConfiguration: Realm.Configuration
    ) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
        guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
              category.isUserEditable,
              !category.isDeleted else { return }
        let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate(
            realmConfiguration: realmConfiguration
        )

        await realm.asyncRefresh()
        let configurationID = libraryConfiguration.id
        try await realm.asyncWritePreservingOwnership {
            guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
                  category.isUserEditable, !category.isDeleted,
                  let libraryConfiguration = realm.object(
                    ofType: LibraryConfiguration.self, forPrimaryKey: configurationID
                  ), !libraryConfiguration.isDeleted else { return }
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
        let realmConfiguration = category.realm?.configuration ?? LibraryDataManager.realmConfiguration
        try await restoreCategory(categoryID: category.id, realmConfiguration: realmConfiguration)
    }

    @RealmBackgroundActor
    func restoreCategory(
        categoryID: UUID,
        realmConfiguration: Realm.Configuration
    ) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
        guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
              category.isUserEditable else { return }
        let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate(
            realmConfiguration: realmConfiguration
        )

        await realm.asyncRefresh()
        let configurationID = libraryConfiguration.id
        try await realm.asyncWritePreservingOwnership {
            guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
                  category.isUserEditable,
                  let libraryConfiguration = realm.object(
                    ofType: LibraryConfiguration.self, forPrimaryKey: configurationID
                  ), !libraryConfiguration.isDeleted else { return }
            if category.isArchived || category.isDeleted {
                category.isArchived = false
                category.isDeleted = false
                category.refreshChangeMetadata(explicitlyModified: true)
            }
            if !libraryConfiguration.categoryIDs.contains(category.id) {
                libraryConfiguration.categoryIDs.append(category.id)
                libraryConfiguration.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }
}
