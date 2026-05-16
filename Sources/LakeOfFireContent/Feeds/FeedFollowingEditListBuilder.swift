import Foundation

public struct FeedFollowingEditListFeedSnapshot: Identifiable, Hashable, Sendable {
    public var id: String
    public var rssURL: URL
    public var isFollowed: Bool

    public init(
        id: String,
        rssURL: URL,
        isFollowed: Bool
    ) {
        self.id = id
        self.rssURL = rssURL
        self.isFollowed = isFollowed
    }

    public init(feed: Feed) {
        self.init(
            id: feed.id.uuidString,
            rssURL: feed.rssUrl,
            isFollowed: feed.isFollowed
        )
    }

    public var canonicalFeedURLKey: String {
        Feed.canonicalFollowingFeedURLKey(for: rssURL)
    }
}

public struct FeedFollowingEditListCategorySnapshot: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var feeds: [FeedFollowingEditListFeedSnapshot]

    public init(
        id: String,
        title: String,
        feeds: [FeedFollowingEditListFeedSnapshot]
    ) {
        self.id = id
        self.title = title
        self.feeds = feeds
    }
}

public struct FeedFollowingEditList: Hashable, Sendable {
    public var followingFeeds: [FeedFollowingEditListFeedSnapshot]
    public var otherFeedCategories: [FeedFollowingEditListCategorySnapshot]

    public init(
        followingFeeds: [FeedFollowingEditListFeedSnapshot],
        otherFeedCategories: [FeedFollowingEditListCategorySnapshot]
    ) {
        self.followingFeeds = followingFeeds
        self.otherFeedCategories = otherFeedCategories
    }
}

public enum FeedFollowingEditListBuilder {
    public static func makeList(
        allFeeds: [FeedFollowingEditListFeedSnapshot],
        categories: [FeedFollowingEditListCategorySnapshot]
    ) -> FeedFollowingEditList {
        let uniqueAllFeeds = uniqueFeeds(allFeeds)
        let allFeedsByURLKey = Dictionary(uniqueKeysWithValues: uniqueAllFeeds.map { feed in
            (feed.canonicalFeedURLKey, feed)
        })
        let followedFeedURLKeys = Set(
            uniqueAllFeeds
                .filter(\.isFollowed)
                .map(\.canonicalFeedURLKey)
        )
        let followingFeeds = uniqueAllFeeds.filter { feed in
            followedFeedURLKeys.contains(feed.canonicalFeedURLKey)
        }

        var usedFeedURLKeys = followedFeedURLKeys
        let otherFeedCategories = categories.compactMap { category -> FeedFollowingEditListCategorySnapshot? in
            var feeds = [FeedFollowingEditListFeedSnapshot]()
            for feed in uniqueFeeds(category.feeds) {
                let feedURLKey = feed.canonicalFeedURLKey
                guard let representative = allFeedsByURLKey[feedURLKey],
                      !usedFeedURLKeys.contains(feedURLKey)
                else {
                    continue
                }
                usedFeedURLKeys.insert(feedURLKey)
                feeds.append(representative)
            }
            guard !feeds.isEmpty else { return nil }
            return FeedFollowingEditListCategorySnapshot(
                id: category.id,
                title: category.title,
                feeds: feeds
            )
        }

        return FeedFollowingEditList(
            followingFeeds: followingFeeds,
            otherFeedCategories: otherFeedCategories
        )
    }

    private static func uniqueFeeds(
        _ feeds: [FeedFollowingEditListFeedSnapshot]
    ) -> [FeedFollowingEditListFeedSnapshot] {
        var orderedURLKeys = [String]()
        var feedsByURLKey = [String: FeedFollowingEditListFeedSnapshot]()

        for feed in feeds {
            let feedURLKey = feed.canonicalFeedURLKey
            if let current = feedsByURLKey[feedURLKey] {
                if feed.isFollowed, !current.isFollowed {
                    feedsByURLKey[feedURLKey] = feed
                }
            } else {
                orderedURLKeys.append(feedURLKey)
                feedsByURLKey[feedURLKey] = feed
            }
        }

        return orderedURLKeys.compactMap { feedsByURLKey[$0] }
    }
}

struct FeedFollowingStatusFeedSnapshot: Identifiable, Hashable, Sendable {
    var id: UUID
    var canonicalFeedURLKey: String
    var followingOrdinal: Int?

    init(
        id: UUID,
        canonicalFeedURLKey: String,
        followingOrdinal: Int?
    ) {
        self.id = id
        self.canonicalFeedURLKey = canonicalFeedURLKey
        self.followingOrdinal = followingOrdinal
    }
}

struct FeedFollowingStatusUpdatePlan: Hashable, Sendable {
    var feedIDs: [UUID]
    var isFollowed: Bool
    var followingOrdinal: Int?

    init(
        feedIDs: [UUID],
        isFollowed: Bool,
        followingOrdinal: Int?
    ) {
        self.feedIDs = feedIDs
        self.isFollowed = isFollowed
        self.followingOrdinal = followingOrdinal
    }
}

enum FeedFollowingStatusUpdatePlanBuilder {
    static func makePlan(
        allFeeds: [FeedFollowingStatusFeedSnapshot],
        canonicalFeedURLKey: String,
        isFollowed: Bool
    ) -> FeedFollowingStatusUpdatePlan {
        let matchingFeeds = allFeeds.filter { $0.canonicalFeedURLKey == canonicalFeedURLKey }
        let ordinal = matchingFeeds.compactMap(\.followingOrdinal).min()
            ?? (isFollowed ? ((allFeeds.compactMap(\.followingOrdinal).max() ?? -1) + 1) : nil)

        return FeedFollowingStatusUpdatePlan(
            feedIDs: matchingFeeds.map(\.id),
            isFollowed: isFollowed,
            followingOrdinal: ordinal
        )
    }
}
