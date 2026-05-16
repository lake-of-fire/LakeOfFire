import XCTest
@testable import LakeOfFireContent

final class FeedFollowingEditListBuilderTests: XCTestCase {
    func testDedupesFollowedFeedURLsAndHidesThemFromCategories() throws {
        let unfollowedDuplicate = editFeed(
            id: "unfollowed-duplicate",
            rssURL: "https://EXAMPLE.com:443/feed.xml#fragment"
        )
        let followedDuplicate = editFeed(
            id: "followed-duplicate",
            rssURL: "https://example.com/feed.xml",
            isFollowed: true
        )
        let other = editFeed(id: "other", rssURL: "https://example.com/other.xml")

        let list = FeedFollowingEditListBuilder.makeList(
            allFeeds: [unfollowedDuplicate, followedDuplicate, other],
            categories: [
                editCategory(id: "category", title: "Category", feeds: [unfollowedDuplicate, followedDuplicate, other]),
            ]
        )

        XCTAssertEqual(list.followingFeeds.map(\.id), ["followed-duplicate"])
        XCTAssertEqual(list.otherFeedCategories.map(\.title), ["Category"])
        XCTAssertEqual(list.otherFeedCategories.flatMap { $0.feeds.map(\.id) }, ["other"])
    }

    func testShowsDuplicateFeedURLInFirstEligibleCategoryOnly() throws {
        let first = editFeed(id: "first", rssURL: "https://example.com/feed.xml")
        let duplicate = editFeed(id: "duplicate", rssURL: "https://EXAMPLE.com:443/feed.xml#fragment")
        let second = editFeed(id: "second", rssURL: "https://example.com/second.xml")

        let list = FeedFollowingEditListBuilder.makeList(
            allFeeds: [first, duplicate, second],
            categories: [
                editCategory(id: "library", title: "Library", feeds: [first]),
                editCategory(id: "editors", title: "Editors", feeds: [duplicate, second]),
            ]
        )

        XCTAssertEqual(list.followingFeeds, [])
        XCTAssertEqual(list.otherFeedCategories.map(\.title), ["Library", "Editors"])
        XCTAssertEqual(list.otherFeedCategories.map { $0.feeds.map(\.id) }, [["first"], ["second"]])
    }

    func testIgnoresCategoryFeedsOutsideVisibleFeedUniverse() throws {
        let visible = editFeed(id: "visible", rssURL: "https://example.com/visible.xml")
        let hidden = editFeed(id: "hidden", rssURL: "https://example.com/hidden.xml")

        let list = FeedFollowingEditListBuilder.makeList(
            allFeeds: [visible],
            categories: [
                editCategory(id: "category", title: "Category", feeds: [hidden]),
            ]
        )

        XCTAssertTrue(list.followingFeeds.isEmpty)
        XCTAssertTrue(list.otherFeedCategories.isEmpty)
    }

    func testUsesVisibleRepresentativeForCategoryDuplicateFeedURLs() throws {
        let visible = editFeed(id: "visible", rssURL: "https://example.com/feed.xml")
        let categoryDuplicate = editFeed(id: "category-duplicate", rssURL: "https://EXAMPLE.com:443/feed.xml#fragment")

        let list = FeedFollowingEditListBuilder.makeList(
            allFeeds: [visible],
            categories: [
                editCategory(id: "category", title: "Category", feeds: [categoryDuplicate]),
            ]
        )

        XCTAssertEqual(list.followingFeeds, [])
        XCTAssertEqual(list.otherFeedCategories.map(\.title), ["Category"])
        XCTAssertEqual(list.otherFeedCategories.flatMap { $0.feeds.map(\.id) }, ["visible"])
    }

    func testFollowingStatusPlanUpdatesDuplicateURLGroupTogetherAndAssignsOrdinal() throws {
        let firstID = UUID()
        let duplicateID = UUID()
        let otherID = UUID()

        let plan = FeedFollowingStatusUpdatePlanBuilder.makePlan(
            allFeeds: [
                statusFeed(id: firstID, canonicalFeedURLKey: "https://example.com/feed.xml"),
                statusFeed(id: duplicateID, canonicalFeedURLKey: "https://example.com/feed.xml"),
                statusFeed(id: otherID, canonicalFeedURLKey: "https://example.com/other.xml", followingOrdinal: 4),
            ],
            canonicalFeedURLKey: "https://example.com/feed.xml",
            isFollowed: true
        )

        XCTAssertEqual(plan.feedIDs, [firstID, duplicateID])
        XCTAssertTrue(plan.isFollowed)
        XCTAssertEqual(plan.followingOrdinal, 5)
    }

    func testFollowingStatusPlanPreservesDuplicateURLGroupOrdinalWhenUnfollowing() throws {
        let firstID = UUID()
        let duplicateID = UUID()

        let plan = FeedFollowingStatusUpdatePlanBuilder.makePlan(
            allFeeds: [
                statusFeed(id: firstID, canonicalFeedURLKey: "https://example.com/feed.xml", followingOrdinal: 7),
                statusFeed(id: duplicateID, canonicalFeedURLKey: "https://example.com/feed.xml", followingOrdinal: 3),
                statusFeed(id: UUID(), canonicalFeedURLKey: "https://example.com/other.xml", followingOrdinal: 1),
            ],
            canonicalFeedURLKey: "https://example.com/feed.xml",
            isFollowed: false
        )

        XCTAssertEqual(plan.feedIDs, [firstID, duplicateID])
        XCTAssertFalse(plan.isFollowed)
        XCTAssertEqual(plan.followingOrdinal, 3)
    }

    private func editFeed(
        id: String,
        rssURL: String,
        isFollowed: Bool = false
    ) -> FeedFollowingEditListFeedSnapshot {
        FeedFollowingEditListFeedSnapshot(
            id: id,
            rssURL: URL(string: rssURL)!,
            isFollowed: isFollowed
        )
    }

    private func editCategory(
        id: String,
        title: String,
        feeds: [FeedFollowingEditListFeedSnapshot]
    ) -> FeedFollowingEditListCategorySnapshot {
        FeedFollowingEditListCategorySnapshot(id: id, title: title, feeds: feeds)
    }

    private func statusFeed(
        id: UUID,
        canonicalFeedURLKey: String,
        followingOrdinal: Int? = nil
    ) -> FeedFollowingStatusFeedSnapshot {
        FeedFollowingStatusFeedSnapshot(
            id: id,
            canonicalFeedURLKey: canonicalFeedURLKey,
            followingOrdinal: followingOrdinal
        )
    }
}
