import Foundation
import RealmSwift
import RealmSwiftGaps
import LakeOfFireContent

private func categoryFeedPhysicalRowID<T: ObjectKeyIdentifiable>(_ object: T) -> UInt64 { object.id }

/// Capture the rendered incarnation before a row action can suspend or reorder.
struct LibraryCategoryFeedSelection: Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let physicalRowID: UInt64?
    let storageIdentity: String?

    init(id: UUID, createdAt: Date) {
        self.id = id
        self.createdAt = createdAt
        physicalRowID = nil
        storageIdentity = nil
    }

    @MainActor
    init?(feed: Feed) {
        guard !feed.isInvalidated else { return nil }
        id = feed.id
        createdAt = feed.createdAt
        physicalRowID = feed.realm == nil ? nil : categoryFeedPhysicalRowID(feed)
        storageIdentity = feed.realm.map { RealmBackgroundActor.shared.captureStorageAdmission(for: $0.configuration).scopeIdentity }
    }
}

struct LibraryCategoryFeedDeleteCommand: Sendable {
    let owner: LibraryCategoryFieldOwner
    let selections: [LibraryCategoryFeedSelection]

    @RealmBackgroundActor
    func write(
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        guard !selections.isEmpty else { return }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: owner.realmConfiguration,
            storageAdmission: owner.storageAdmission
        )
        try await beforeWrite?()
        try Task.checkCancellation()
        try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            guard owner.isCurrentStorage else {
                throw RealmBackgroundActorError.realmFileChangedDuringOpen
            }
            guard let category = owner.resolve(in: realm) else { return }
            let now = Date()
            var visited = Set<LibraryCategoryFeedSelection>()
            for selection in selections {
                guard visited.insert(selection).inserted,
                      let physicalRowID = selection.physicalRowID,
                      selection.storageIdentity == owner.storageAdmission.scopeIdentity,
                      let feed = realm.object(ofType: Feed.self, forPrimaryKey: selection.id),
                      feed.createdAt == selection.createdAt,
                      categoryFeedPhysicalRowID(feed) == physicalRowID,
                      !feed.isDeleted,
                      feed.categoryID == category.id,
                      feed.isUserEditable() else { continue }
                feed.isDeleted = true
                feed.refreshChangeMetadata(explicitlyModified: true, at: now)
            }
            try Task.checkCancellation()
            guard owner.isCurrentStorage else {
                throw RealmBackgroundActorError.realmFileChangedDuringOpen
            }
        }
    }
}
