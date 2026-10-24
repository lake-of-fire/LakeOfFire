import Foundation
import RealmSwift
import RealmSwiftGaps
import LakeOfFireContent

/// Capture the rendered incarnation before a row action can suspend or reorder.
struct LibraryCategoryFeedSelection: Hashable, Sendable {
    let id: UUID
    let createdAt: Date

    init(id: UUID, createdAt: Date) {
        self.id = id
        self.createdAt = createdAt
    }

    @MainActor
    init?(feed: Feed) {
        guard !feed.isInvalidated else { return nil }
        id = feed.id
        createdAt = feed.createdAt
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
                      let feed = realm.object(ofType: Feed.self, forPrimaryKey: selection.id),
                      feed.createdAt == selection.createdAt,
                      !feed.isDeleted,
                      feed.categoryID == category.id,
                      feed.isUserEditable() else { continue }
                feed.isDeleted = true
                feed.refreshChangeMetadata(explicitlyModified: true, at: now)
            }
        }
    }
}
