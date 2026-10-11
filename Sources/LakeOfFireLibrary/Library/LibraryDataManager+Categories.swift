import SwiftUI
import RealmSwift
import RealmSwiftGaps
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

public struct LibraryCategoryDeletionTarget: Sendable, Equatable {
    public let categoryID: UUID
    public let createdAt: Date

    public init(categoryID: UUID, createdAt: Date) {
        self.categoryID = categoryID
        self.createdAt = createdAt
    }
}

public struct LibraryCategoryDeletionResult: Sendable, Equatable {
    public let archivedCategoryIDs: [UUID]
    public let deletedCategoryIDs: [UUID]
    public let changedAt: Date

    public init(
        archivedCategoryIDs: [UUID],
        deletedCategoryIDs: [UUID],
        changedAt: Date
    ) {
        self.archivedCategoryIDs = archivedCategoryIDs
        self.deletedCategoryIDs = deletedCategoryIDs
        self.changedAt = changedAt
    }
}

public extension LibraryDataManager {
    @RealmBackgroundActor
    func deleteCategory(
        _ category: FeedCategory,
        realmConfiguration: Realm.Configuration = LibraryDataManager.realmConfiguration
    ) async throws {
        _ = try await deleteCategories(
            targets: [
                LibraryCategoryDeletionTarget(
                    categoryID: category.id,
                    createdAt: category.createdAt
                ),
            ],
            realmConfiguration: realmConfiguration
        )
    }

    @RealmBackgroundActor
    func deleteCategories(
        targets: [LibraryCategoryDeletionTarget],
        realmConfiguration: Realm.Configuration = LibraryDataManager.realmConfiguration
    ) async throws -> LibraryCategoryDeletionResult {
        try Task.checkCancellation()
        var seenCategoryIDs = Set<UUID>()
        let targets = targets.filter { seenCategoryIDs.insert($0.categoryID).inserted }
        let changedAt = Date()
        guard !targets.isEmpty else {
            return LibraryCategoryDeletionResult(
                archivedCategoryIDs: [],
                deletedCategoryIDs: [],
                changedAt: changedAt
            )
        }

        let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate(
            realmConfiguration: realmConfiguration
        )
        let configurationID = libraryConfiguration.id
        let configurationCreatedAt = libraryConfiguration.createdAt
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration
        )
        var archivedCategoryIDs = [UUID]()
        var deletedCategoryIDs = [UUID]()
        try await realm.asyncWrite {
            try Task.checkCancellation()
            guard let libraryConfiguration = realm.object(
                ofType: LibraryConfiguration.self,
                forPrimaryKey: configurationID
            ), !libraryConfiguration.isDeleted,
            libraryConfiguration.createdAt == configurationCreatedAt else {
                throw RealmBackgroundActorError.unableToResolveObject
            }

            let categories = try targets.map { target in
                guard let category = realm.object(
                    ofType: FeedCategory.self,
                    forPrimaryKey: target.categoryID
                ), !category.isDeleted,
                category.createdAt == target.createdAt,
                category.isUserEditable,
                !(category.isArchived && category.opmlURL != nil) else {
                    throw RealmBackgroundActorError.unableToResolveObject
                }
                return category
            }

            let targetIDs = Set(targets.map(\.categoryID))
            let retainedIDs = Array(libraryConfiguration.categoryIDs).filter {
                !targetIDs.contains($0)
            }
            if retainedIDs.count != libraryConfiguration.categoryIDs.count {
                libraryConfiguration.categoryIDs.removeAll()
                libraryConfiguration.categoryIDs.append(objectsIn: retainedIDs)
                libraryConfiguration.refreshChangeMetadata(
                    explicitlyModified: true,
                    at: changedAt
                )
            }

            for category in categories {
                if category.isArchived {
                    category.isDeleted = true
                    deletedCategoryIDs.append(category.id)
                } else {
                    category.isArchived = true
                    archivedCategoryIDs.append(category.id)
                }
                category.refreshChangeMetadata(
                    explicitlyModified: true,
                    at: changedAt
                )
            }
        }
        return LibraryCategoryDeletionResult(
            archivedCategoryIDs: archivedCategoryIDs,
            deletedCategoryIDs: deletedCategoryIDs,
            changedAt: changedAt
        )
    }
    
    @RealmBackgroundActor
    func restoreCategory(
        _ category: FeedCategory,
        realmConfiguration: Realm.Configuration = LibraryDataManager.realmConfiguration
    ) async throws {
        guard category.realm != nil else {
            throw LibraryMutationError.categoryNotFound
        }
        _ = try await restoreCategory(
            categoryID: category.id,
            realmConfiguration: realmConfiguration
        )
    }
}
