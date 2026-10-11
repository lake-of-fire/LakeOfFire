import Foundation
import RealmSwift
import RealmSwiftGaps

public struct LibraryFeedDeletionReceipt: Equatable, Sendable {
    public let categoryID: UUID
    public let requestedFeedIDs: [UUID]
    public let deletedFeedIDs: [UUID]
    public let unavailableFeedIDs: [UUID]
    public let deletedAt: Date
}

public struct LibraryFeedDeletionTarget: Equatable, Hashable, Sendable {
    public let feedID: UUID
    public let createdAt: Date

    public init(feedID: UUID, createdAt: Date) {
        self.feedID = feedID
        self.createdAt = createdAt
    }
}

public enum LibraryFeedDeletionCommandError: LocalizedError {
    case categoryUnavailable
    case conflictingTargetIdentity

    public var errorDescription: String? {
        switch self {
        case .categoryUnavailable:
            "This category changed before the feeds could be deleted."
        case .conflictingTargetIdentity:
            "A selected feed changed before deletion began. Refresh the list and try again."
        }
    }
}

public enum LibraryFeedDeletionCommand {
    public static func perform(
        categoryID: UUID,
        categoryCreatedAt: Date,
        targets: [LibraryFeedDeletionTarget],
        configuration: Realm.Configuration,
        deletedAt: Date = Date()
    ) async throws -> LibraryFeedDeletionReceipt {
        var targetsByID = [UUID: LibraryFeedDeletionTarget]()
        for target in targets {
            if let existing = targetsByID[target.feedID], existing.createdAt != target.createdAt {
                throw LibraryFeedDeletionCommandError.conflictingTargetIdentity
            }
            targetsByID[target.feedID] = target
        }
        let targets: [LibraryFeedDeletionTarget] = targetsByID.values.sorted {
            $0.feedID.uuidString < $1.feedID.uuidString
        }
        let requestedFeedIDs = targets.map { $0.feedID }
        return try await { @RealmBackgroundActor in
            try Task.checkCancellation()
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try Task.checkCancellation()
            var receipt: LibraryFeedDeletionReceipt?
            try await realm.asyncWrite {
                try Task.checkCancellation()
                guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
                      !category.isInvalidated,
                      !category.isDeleted,
                      category.createdAt == categoryCreatedAt,
                      category.isUserEditable else {
                    throw LibraryFeedDeletionCommandError.categoryUnavailable
                }

                var deletedFeedIDs = [UUID]()
                var unavailableFeedIDs = [UUID]()
                for target in targets {
                    guard let feed = realm.object(ofType: Feed.self, forPrimaryKey: target.feedID),
                          !feed.isInvalidated,
                          !feed.isDeleted,
                          feed.createdAt == target.createdAt,
                          feed.categoryID == categoryID,
                          feed.isUserEditable() else {
                        unavailableFeedIDs.append(target.feedID)
                        continue
                    }
                    feed.isDeleted = true
                    feed.refreshChangeMetadata(explicitlyModified: true, at: deletedAt)
                    deletedFeedIDs.append(target.feedID)
                }
                receipt = LibraryFeedDeletionReceipt(
                    categoryID: categoryID,
                    requestedFeedIDs: requestedFeedIDs,
                    deletedFeedIDs: deletedFeedIDs,
                    unavailableFeedIDs: unavailableFeedIDs,
                    deletedAt: deletedAt
                )
            }
            guard let receipt else {
                throw LibraryFeedDeletionCommandError.categoryUnavailable
            }
            return receipt
        }()
    }
}

