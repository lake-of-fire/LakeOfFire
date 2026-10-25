import Foundation
import RealmSwift
import RealmSwiftGaps
import LakeOfFireContent
import LakeOfFireReader

/// Retained appearances share the captured owner, not a one-shot reference.
/// Feed is store-owned CloudKit data, not a Manabi-account-owned record.
@MainActor
struct FeedViewCommandSource {
    fileprivate let feed: Feed
    fileprivate let owner: FeedViewCommand.Owner

    init?(feed: Feed) {
        guard !feed.isInvalidated, !feed.isDeleted, let realm = feed.realm else { return nil }
        self.feed = feed.freeze()
        let configuration = realm.configuration
        owner = FeedViewCommand.Owner(
            feedID: feed.id, createdAt: feed.createdAt,
            canonicalFeedURLKey: feed.canonicalFollowingFeedURLKey,
            configuration: configuration,
            storageAdmission: RealmBackgroundActor.shared.captureStorageAdmission(for: configuration)
        )
    }

    func markingViewed() -> FeedViewCommand? {
        guard !feed.isInvalidated, feed.shouldMarkAsViewedOnAppear else { return nil }
        return FeedViewCommand(source: self, action: .viewed)
    }
}

/// One UI action owns its source store, row and intent before scheduling a task.
struct FeedViewCommand: Sendable {
    fileprivate enum Action: Sendable {
        case following(Bool)
        case viewed
        case allEntriesSeen
    }

    fileprivate struct Owner: Sendable {
        let feedID: UUID
        let createdAt: Date
        let canonicalFeedURLKey: String
        let configuration: Realm.Configuration
        let storageAdmission: RealmStorageAdmission

        var isCurrentStorage: Bool {
            storageAdmission.matchesCurrentStorageIdentity {
                RealmBackgroundActor.shared.realmCacheKey(for: configuration)
            }
        }
    }

    private let action: Action
    private let owner: Owner
    private let reference: ThreadSafeReference<Feed>

    @MainActor
    fileprivate init(source: FeedViewCommandSource, action: Action) {
        self.action = action
        owner = source.owner
        reference = ThreadSafeReference(to: source.feed)
    }

    @MainActor
    static func following(_ isFollowed: Bool, feed: Feed) -> Self? {
        guard !feed.isInvalidated, feed.entryContentKind != .contentListing,
              let source = FeedViewCommandSource(feed: feed) else { return nil }
        return Self(source: source, action: .following(isFollowed))
    }

    @MainActor
    static func markingViewed(feed: Feed) -> Self? {
        FeedViewCommandSource(feed: feed)?.markingViewed()
    }

    @MainActor
    static func markingAllEntriesSeen(feed: Feed, hasEntries: Bool) -> Self? {
        guard !feed.isInvalidated, feed.showsUnseenBadge, hasEntries,
              let source = FeedViewCommandSource(feed: feed) else { return nil }
        return Self(source: source, action: .allEntriesSeen)
    }

    @RealmBackgroundActor
    func write(
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: owner.configuration, storageAdmission: owner.storageAdmission
        )

        // A cached Realm can be in a peer's suspended transaction. Resolve the
        // one-shot reference only outside a write. The owned helper queues its
        // own ticket; neither this barrier nor cancellation settles the peer.
        // A commit notification may open another write before we resume.
        while realm.isInWriteTransaction {
            try await realm.asyncWritePreservingOwnership { }
            try Task.checkCancellation()
        }
        guard owner.isCurrentStorage, !reference.isInvalidated,
              let original = realm.resolve(reference) else { return }

        try await beforeWrite?()
        try Task.checkCancellation()
        try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            guard owner.isCurrentStorage, !original.isInvalidated,
                  let feed = realm.object(ofType: Feed.self, forPrimaryKey: owner.feedID),
                  original.isSameObject(as: feed), feed.createdAt == owner.createdAt,
                  !feed.isDeleted, feed.canonicalFollowingFeedURLKey == owner.canonicalFeedURLKey else { return }

            switch action {
            case .following(let isFollowed):
                guard feed.entryContentKind != .contentListing else { return }
                Feed.setFollowingStatusForFeedGroup(
                    canonicalFeedURLKey: owner.canonicalFeedURLKey,
                    isFollowed: isFollowed,
                    in: realm
                )
            case .viewed:
                // These two fields are intentionally excluded from sync.
                // Keep their existing source eligibility and write-time date.
                feed.lastViewedAt = Date()
            case .allEntriesSeen:
                guard feed.showsUnseenBadge else { return }
                feed.lastSeenFeedEntriesAt = Date()
            }
        }
    }
}
