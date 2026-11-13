import SwiftUI
import RealmSwift
import RealmSwiftGaps
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

private func categoryCommandPhysicalRowID<T: ObjectKeyIdentifiable>(_ object: T) -> UInt64 {
    object.id
}

public extension LibraryDataManager {
    @RealmBackgroundActor
    func deleteCategory(_ category: FeedCategory) async throws {
        guard let owner = LibraryCategoryFieldOwner(category: category) else { return }
        try await deleteCategory(owner: owner)
    }

    @RealmBackgroundActor
    func deleteCategory(categoryID: UUID, realmConfiguration: Realm.Configuration) async throws {
        try Task.checkCancellation()
        let admission = RealmBackgroundActor.shared.captureStorageAdmission(for: realmConfiguration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration, storageAdmission: admission)
        guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
              let owner = LibraryCategoryFieldOwner(category: category, realmConfiguration: realmConfiguration,
                                                    storageAdmission: admission) else { return }
        try await deleteCategory(owner: owner)
    }

    @RealmBackgroundActor
    func restoreCategory(_ category: FeedCategory) async throws {
        guard let owner = LibraryCategoryFieldOwner(category: category) else { return }
        try await restoreCategory(owner: owner)
    }

    @RealmBackgroundActor
    func restoreCategory(categoryID: UUID, realmConfiguration: Realm.Configuration) async throws {
        try Task.checkCancellation()
        let admission = RealmBackgroundActor.shared.captureStorageAdmission(for: realmConfiguration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration, storageAdmission: admission)
        guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
              let owner = LibraryCategoryFieldOwner(category: category, realmConfiguration: realmConfiguration,
                                                    storageAdmission: admission) else { return }
        try await restoreCategory(owner: owner)
    }
}

extension LibraryDataManager {
    @RealmBackgroundActor
    func deleteCategory(owner: LibraryCategoryFieldOwner, libraryIdentity: LibraryCategoryEditorIdentity? = nil) async throws {
        try await mutateCategory(owner: owner, restoring: false, libraryIdentity: libraryIdentity)
    }

    @RealmBackgroundActor
    func restoreCategory(owner: LibraryCategoryFieldOwner, libraryIdentity: LibraryCategoryEditorIdentity? = nil) async throws {
        try await mutateCategory(owner: owner, restoring: true, libraryIdentity: libraryIdentity)
    }

    @RealmBackgroundActor
    func mutateCategory(
        owner: LibraryCategoryFieldOwner,
        restoring: Bool,
        libraryIdentity: LibraryCategoryEditorIdentity? = nil,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        guard owner.physicalRowID != nil else { return }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: owner.realmConfiguration, storageAdmission: owner.storageAdmission)
        guard owner.isCurrentStorage else { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
        guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: owner.categoryID),
              owner.matches(category), category.isUserEditable, restoring || !category.isDeleted else { return }
        if let libraryIdentity {
            guard libraryIdentity.category == LibraryCategoryFieldIdentity(owner: owner),
                  let originalLibrary = realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryIdentity.libraryID),
                  libraryIdentity.matchesLibrary(originalLibrary) else { return }
        }
        let library = try await LibraryConfiguration.getConsolidatedOrCreate(
            realmConfiguration: owner.realmConfiguration, storageAdmission: owner.storageAdmission)
        if let libraryIdentity, !libraryIdentity.matchesLibrary(library) { return }
        let libraryID = library.id
        let libraryRowID = categoryCommandPhysicalRowID(library)
        try await beforeWrite?()
        try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            guard owner.isCurrentStorage else { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
            guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: owner.categoryID),
                  owner.matches(category), category.isUserEditable, restoring || !category.isDeleted,
                  let library = realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryID),
                  !library.isDeleted, categoryCommandPhysicalRowID(library) == libraryRowID else { return }
            let timestamp = Date()
            if restoring {
                if category.isArchived || category.isDeleted {
                    category.isArchived = false
                    category.isDeleted = false
                    category.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                }
                if !library.categoryIDs.contains(category.id) {
                    library.categoryIDs.append(category.id)
                    library.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                }
            } else {
                if let index = library.categoryIDs.firstIndex(of: category.id) {
                    library.categoryIDs.remove(at: index)
                    library.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                }
                if category.isArchived {
                    if category.opmlURL == nil || !LibraryConfiguration.opmlURLs.contains(category.opmlURL!) {
                        category.isDeleted = true
                        category.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                    }
                } else {
                    category.isArchived = true
                    category.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                }
            }
            try Task.checkCancellation()
            guard owner.isCurrentStorage else { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
        }
    }
}
