import XCTest
import RealmSwift
@testable import LakeOfFireContent
@testable import LakeOfFireReader

final class FeedStateIndicatorTests: XCTestCase {
    private func makeConfiguration(identifier: String = UUID().uuidString) -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: identifier)
        configuration.objectTypes = [Feed.self, FeedEntry.self, Bookmark.self, HistoryRecord.self]
        return configuration
    }

    private func makeManagedFeed(
        entries: [(publicationDate: Date, createdAt: Date, hasAudio: Bool)],
        lastViewedAt: Date? = nil,
        identifier: String = UUID().uuidString
    ) throws -> Feed {
        let realm = try Realm(configuration: makeConfiguration(identifier: identifier))
        let feedURL = URL(string: "https://example.com/\(identifier).xml")!

        let feed = Feed()
        feed.title = "Feed \(identifier)"
        feed.rssUrl = feedURL
        feed.iconUrl = feedURL
        feed.lastViewedAt = lastViewedAt

        try realm.write {
            realm.add(feed)
            for (index, entryData) in entries.enumerated() {
                let entry = FeedEntry()
                entry.feedID = feed.id
                entry.url = URL(string: "https://example.com/articles/\(identifier)/\(index)")!
                entry.updateCompoundKey()
                entry.publicationDate = entryData.publicationDate
                entry.createdAt = entryData.createdAt
                if entryData.hasAudio {
                    entry.voiceAudioURL = URL(string: "https://example.com/audio/\(identifier)/\(index).mp3")!
                }
                realm.add(entry)
            }
        }

        return feed
    }

    private func withReaderContentLoaderConfigurations<T>(
        configuration: Realm.Configuration,
        body: () throws -> T
    ) rethrows -> T {
        let originalFeedEntryConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        let originalHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        defer {
            ReaderContentLoader.feedEntryRealmConfiguration = originalFeedEntryConfiguration
            ReaderContentLoader.historyRealmConfiguration = originalHistoryConfiguration
        }
        return try body()
    }

    func testFirstEntryHasAudioUsesOnlyFirstFeedEntry() throws {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let firstAudioFeed = try makeManagedFeed(
            entries: [
                (baseDate, baseDate, true),
                (baseDate.addingTimeInterval(60), baseDate.addingTimeInterval(60), false)
            ]
        )
        XCTAssertTrue(firstAudioFeed.firstEntryHasAudio)

        let laterAudioFeed = try makeManagedFeed(
            entries: [
                (baseDate, baseDate, false),
                (baseDate.addingTimeInterval(60), baseDate.addingTimeInterval(60), true)
            ]
        )
        XCTAssertFalse(laterAudioFeed.firstEntryHasAudio)
    }

    func testHasEntriesNewerThanLastViewedAtUsesCreatedAt() throws {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let feed = try makeManagedFeed(
            entries: [
                (baseDate, baseDate.addingTimeInterval(-60), false),
                (baseDate.addingTimeInterval(60), baseDate.addingTimeInterval(60), false)
            ],
            lastViewedAt: baseDate
        )

        XCTAssertTrue(feed.hasEntriesNewerThanLastViewedAt)
    }

    func testFollowingEntriesInterleavesOneNewEntryPerFollowedFeedByRound() throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let firstFeed = Feed()
        firstFeed.title = "First"
        firstFeed.rssUrl = URL(string: "https://example.com/first.xml")!
        firstFeed.iconUrl = firstFeed.rssUrl
        firstFeed.isFollowed = true

        let secondFeed = Feed()
        secondFeed.title = "Second"
        secondFeed.rssUrl = URL(string: "https://example.com/second.xml")!
        secondFeed.iconUrl = secondFeed.rssUrl
        secondFeed.isFollowed = true

        try realm.write {
            realm.add([firstFeed, secondFeed])
            realm.add(makeEntry(feed: firstFeed, suffix: "first-1", date: baseDate.addingTimeInterval(100)))
            realm.add(makeEntry(feed: firstFeed, suffix: "first-2", date: baseDate.addingTimeInterval(10)))
            realm.add(makeEntry(feed: secondFeed, suffix: "second-1", date: baseDate.addingTimeInterval(90)))
            realm.add(makeEntry(feed: secondFeed, suffix: "second-2", date: baseDate.addingTimeInterval(80)))
        }

        let followingEntries = Feed.followingEntries(from: [firstFeed, secondFeed])

        XCTAssertEqual(
            followingEntries.map(\.title),
            ["first-1", "second-1", "second-2", "first-2"]
        )
    }

    func testFollowingEntriesIgnoresUnfollowedAndHistorySeenEntries() throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let followedFeed = Feed()
        followedFeed.title = "Followed"
        followedFeed.rssUrl = URL(string: "https://example.com/followed.xml")!
        followedFeed.iconUrl = followedFeed.rssUrl
        followedFeed.isFollowed = true

        let unfollowedFeed = Feed()
        unfollowedFeed.title = "Unfollowed"
        unfollowedFeed.rssUrl = URL(string: "https://example.com/unfollowed.xml")!
        unfollowedFeed.iconUrl = unfollowedFeed.rssUrl

        let seenHistory = HistoryRecord()
        seenHistory.url = URL(string: "https://example.com/articles/\(followedFeed.id.uuidString)/seen")!
        seenHistory.updateCompoundKey()
        seenHistory.lastVisitedAt = baseDate.addingTimeInterval(50)

        try realm.write {
            realm.add([followedFeed, unfollowedFeed])
            realm.add(makeEntry(feed: followedFeed, suffix: "seen", date: baseDate.addingTimeInterval(40)))
            realm.add(makeEntry(feed: followedFeed, suffix: "new", date: baseDate.addingTimeInterval(60)))
            realm.add(makeEntry(feed: unfollowedFeed, suffix: "ignored", date: baseDate.addingTimeInterval(70)))
            realm.add(seenHistory)
        }

        let followingEntries = Feed.followingEntries(from: [followedFeed, unfollowedFeed], historyRealm: realm)

        XCTAssertEqual(followingEntries.map(\.title), ["new"])
    }

    func testFollowingEntriesDedupesDuplicateFeedURLsAndEntryURLs() throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let duplicateFeedURL = URL(string: "https://EXAMPLE.com:443/feed.xml#fragment")!
        let sharedEntryURL = URL(string: "https://example.com/articles/shared")!
        let duplicateSharedEntryURL = URL(string: "https://EXAMPLE.com:443/articles/shared#duplicate")!

        let followedFeed = Feed()
        followedFeed.title = "Followed"
        followedFeed.rssUrl = feedURL
        followedFeed.iconUrl = feedURL
        followedFeed.isFollowed = true

        let duplicateFeed = Feed()
        duplicateFeed.title = "Duplicate"
        duplicateFeed.rssUrl = duplicateFeedURL
        duplicateFeed.iconUrl = feedURL

        let otherFeed = Feed()
        otherFeed.title = "Other"
        otherFeed.rssUrl = URL(string: "https://example.com/other.xml")!
        otherFeed.iconUrl = otherFeed.rssUrl
        otherFeed.isFollowed = true

        try realm.write {
            realm.add([followedFeed, duplicateFeed, otherFeed])
            realm.add(makeEntry(feed: followedFeed, suffix: "shared-old", url: sharedEntryURL, date: baseDate.addingTimeInterval(10)))
            realm.add(makeEntry(feed: duplicateFeed, suffix: "shared-new", url: duplicateSharedEntryURL, date: baseDate.addingTimeInterval(100)))
            realm.add(makeEntry(feed: duplicateFeed, suffix: "duplicate-unique", date: baseDate.addingTimeInterval(80)))
            realm.add(makeEntry(feed: otherFeed, suffix: "other", date: baseDate.addingTimeInterval(90)))
        }

        let followingEntries = Feed.followingEntries(from: [followedFeed, duplicateFeed, otherFeed])

        XCTAssertEqual(
            followingEntries.map(\.title),
            ["shared-new", "other", "duplicate-unique"]
        )
    }

    func testFollowingEntriesDoesNotTreatMarkAllSeenAsArticleSeen() throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://example.com/feed.xml")!

        let followedFeed = Feed()
        followedFeed.title = "Followed"
        followedFeed.rssUrl = feedURL
        followedFeed.iconUrl = feedURL
        followedFeed.isFollowed = true
        followedFeed.lastSeenFeedEntriesAt = baseDate.addingTimeInterval(90)

        let duplicateFeed = Feed()
        duplicateFeed.title = "Duplicate"
        duplicateFeed.rssUrl = URL(string: "https://EXAMPLE.com:443/feed.xml#fragment")!
        duplicateFeed.iconUrl = feedURL

        try realm.write {
            realm.add([followedFeed, duplicateFeed])
            realm.add(makeEntry(feed: duplicateFeed, suffix: "seen-by-group", date: baseDate.addingTimeInterval(80)))
            realm.add(makeEntry(feed: duplicateFeed, suffix: "new-for-group", date: baseDate.addingTimeInterval(100)))
        }

        let followingEntries = Feed.followingEntries(from: [followedFeed, duplicateFeed])

        XCTAssertEqual(followingEntries.map(\.title), ["new-for-group", "seen-by-group"])
    }

    func testFollowingEntriesDoesNotTreatFeedViewAsArticleSeen() throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let followedFeed = Feed()
        followedFeed.title = "Followed"
        followedFeed.rssUrl = URL(string: "https://example.com/followed.xml")!
        followedFeed.iconUrl = followedFeed.rssUrl
        followedFeed.isFollowed = true
        followedFeed.lastViewedAt = baseDate.addingTimeInterval(120)

        try realm.write {
            realm.add(followedFeed)
            realm.add(makeEntry(feed: followedFeed, suffix: "unopened", date: baseDate.addingTimeInterval(60)))
        }

        let followingEntries = Feed.followingEntries(from: [followedFeed], historyRealm: realm)

        XCTAssertEqual(followingEntries.map(\.title), ["unopened"])
    }

    func testFollowingEntriesCanBeLimitedForPagedFollowingLists() throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let firstFeed = Feed()
        firstFeed.title = "First"
        firstFeed.rssUrl = URL(string: "https://example.com/first.xml")!
        firstFeed.iconUrl = firstFeed.rssUrl
        firstFeed.isFollowed = true

        let secondFeed = Feed()
        secondFeed.title = "Second"
        secondFeed.rssUrl = URL(string: "https://example.com/second.xml")!
        secondFeed.iconUrl = secondFeed.rssUrl
        secondFeed.isFollowed = true

        try realm.write {
            realm.add([firstFeed, secondFeed])
            realm.add(makeEntry(feed: firstFeed, suffix: "first-1", date: baseDate.addingTimeInterval(100)))
            realm.add(makeEntry(feed: firstFeed, suffix: "first-2", date: baseDate.addingTimeInterval(10)))
            realm.add(makeEntry(feed: secondFeed, suffix: "second-1", date: baseDate.addingTimeInterval(90)))
            realm.add(makeEntry(feed: secondFeed, suffix: "second-2", date: baseDate.addingTimeInterval(80)))
        }

        let followingEntries = Feed.followingEntries(from: [firstFeed, secondFeed], historyRealm: realm, limit: 2)

        XCTAssertEqual(followingEntries.map(\.title), ["first-1", "second-1"])
    }

    func testFollowingEntriesUsesCanonicalEntryURLForHistorySeenState() throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://example.com/feed.xml")!

        let followedFeed = Feed()
        followedFeed.title = "Followed"
        followedFeed.rssUrl = feedURL
        followedFeed.iconUrl = feedURL
        followedFeed.isFollowed = true

        let entryURL = URL(string: "https://EXAMPLE.com:443/articles/shared#fragment")!
        let historyURL = URL(string: "https://example.com/articles/shared")!

        let historyRecord = HistoryRecord()
        historyRecord.url = historyURL
        historyRecord.updateCompoundKey()
        historyRecord.lastVisitedAt = baseDate.addingTimeInterval(120)

        try realm.write {
            realm.add(followedFeed)
            realm.add(makeEntry(feed: followedFeed, suffix: "seen-canonical", url: entryURL, date: baseDate.addingTimeInterval(100)))
            realm.add(historyRecord)
        }

        let followingEntries = Feed.followingEntries(from: [followedFeed], historyRealm: realm)

        XCTAssertTrue(followingEntries.isEmpty)
    }

    func testUniqueFollowingFeedRepresentativesCollapseDuplicateFeedURLs() throws {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://example.com/feed.xml")!

        let firstFeed = Feed()
        firstFeed.title = "Unfollowed"
        firstFeed.rssUrl = URL(string: "https://EXAMPLE.com:443/feed.xml#fragment")!
        firstFeed.iconUrl = feedURL
        firstFeed.modifiedAt = baseDate.addingTimeInterval(100)

        let followedDuplicate = Feed()
        followedDuplicate.title = "Followed"
        followedDuplicate.rssUrl = feedURL
        followedDuplicate.iconUrl = feedURL
        followedDuplicate.isFollowed = true
        followedDuplicate.modifiedAt = baseDate

        let otherFeed = Feed()
        otherFeed.title = "Other"
        otherFeed.rssUrl = URL(string: "https://example.com/other.xml")!
        otherFeed.iconUrl = otherFeed.rssUrl

        let representatives = Feed.uniqueFollowingFeedRepresentatives(from: [firstFeed, followedDuplicate, otherFeed])

        XCTAssertEqual(representatives.map(\.title), ["Followed", "Other"])
    }

    private func makeEntry(feed: Feed, suffix: String, date: Date) -> FeedEntry {
        makeEntry(
            feed: feed,
            suffix: suffix,
            url: URL(string: "https://example.com/articles/\(feed.id.uuidString)/\(suffix)")!,
            date: date
        )
    }

    private func makeEntry(feed: Feed, suffix: String, url: URL, date: Date) -> FeedEntry {
        let entry = FeedEntry()
        entry.feedID = feed.id
        entry.title = suffix
        entry.url = url
        entry.updateCompoundKey()
        entry.publicationDate = date
        entry.createdAt = date
        return entry
    }

    func testShouldRefreshOnCategoryAppearReturnsTrueWhenFeedHasNoEntries() throws {
        let feed = try makeManagedFeed(entries: [])
        XCTAssertTrue(feed.shouldRefreshOnCategoryAppear)
    }

    func testShouldRefreshOnCategoryAppearReturnsTrueWhenLatestEntryPredatesLastViewedAt() throws {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let feed = try makeManagedFeed(
            entries: [
                (baseDate, baseDate.addingTimeInterval(-120), false),
                (baseDate.addingTimeInterval(60), baseDate.addingTimeInterval(-60), false)
            ],
            lastViewedAt: baseDate
        )

        XCTAssertTrue(feed.shouldRefreshOnCategoryAppear)
    }

    func testShouldRefreshOnCategoryAppearReturnsFalseWhenLatestEntryIsNewerThanLastViewedAt() throws {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let feed = try makeManagedFeed(
            entries: [
                (baseDate, baseDate.addingTimeInterval(-60), false),
                (baseDate.addingTimeInterval(60), baseDate.addingTimeInterval(60), false)
            ],
            lastViewedAt: baseDate
        )

        XCTAssertFalse(feed.shouldRefreshOnCategoryAppear)
    }

    func testShouldRefreshOnCategoryAppearReturnsFalseWhenRecentlyRefreshed() throws {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let feed = try makeManagedFeed(
            entries: [],
            lastViewedAt: baseDate
        )

        let realm = try XCTUnwrap(feed.realm)
        try realm.write {
            feed.lastRefreshedEntriesAt = Date().addingTimeInterval(-60)
        }

        XCTAssertFalse(feed.shouldRefreshOnCategoryAppear)
    }

    func testShouldRefreshAutomaticallyOnFeedAppearUsesRefreshTimestamp() throws {
        let feed = try makeManagedFeed(entries: [])
        XCTAssertTrue(feed.shouldRefreshAutomaticallyOnFeedAppear)

        let realm = try XCTUnwrap(feed.realm)
        try realm.write {
            feed.lastRefreshedEntriesAt = Date().addingTimeInterval(-60)
        }

        XCTAssertFalse(feed.shouldRefreshAutomaticallyOnFeedAppear)
    }

    func testHasEntriesNewerThanLastViewedAtRespectsFeedLevelSeenOverride() throws {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let feed = try makeManagedFeed(
            entries: [
                (baseDate, baseDate.addingTimeInterval(-60), false),
                (baseDate.addingTimeInterval(60), baseDate.addingTimeInterval(60), false)
            ],
            lastViewedAt: baseDate.addingTimeInterval(-120)
        )

        let realm = try XCTUnwrap(feed.realm)
        try realm.write {
            feed.lastSeenFeedEntriesAt = baseDate.addingTimeInterval(120)
        }

        XCTAssertFalse(feed.hasEntriesNewerThanLastViewedAt)
    }

    func testHasEntriesNewerThanLastViewedAtRespectsShowUnseenBadgeToggle() throws {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let feed = try makeManagedFeed(
            entries: [
                (baseDate, baseDate.addingTimeInterval(60), false)
            ],
            lastViewedAt: baseDate
        )

        let realm = try XCTUnwrap(feed.realm)
        try realm.write {
            feed.showsUnseenBadge = false
        }

        XCTAssertFalse(feed.hasEntriesNewerThanLastViewedAt)
    }

    func testHasUnseenEntriesUsesFeedLevelSeenOverrideUnlessHistoryIsNewer() throws {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let identifier = UUID().uuidString
        let feed = try makeManagedFeed(
            entries: [
                (baseDate, baseDate.addingTimeInterval(60), false)
            ],
            identifier: identifier
        )
        let entry = try XCTUnwrap(feed.getEntries()?.first)
        let realm = try XCTUnwrap(feed.realm)

        try realm.write {
            feed.lastSeenFeedEntriesAt = baseDate

            let historyRecord = HistoryRecord()
            historyRecord.url = entry.url
            historyRecord.updateCompoundKey()
            historyRecord.lastVisitedAt = baseDate.addingTimeInterval(120)
            realm.add(historyRecord)
        }

        try withReaderContentLoaderConfigurations(configuration: realm.configuration) {
            XCTAssertFalse(feed.hasUnseenEntries([entry]))
        }

        try realm.write {
            feed.lastSeenFeedEntriesAt = baseDate
            let historyRecord = realm.objects(HistoryRecord.self).first!
            historyRecord.lastVisitedAt = baseDate.addingTimeInterval(-120)
        }

        try withReaderContentLoaderConfigurations(configuration: realm.configuration) {
            XCTAssertTrue(feed.hasUnseenEntries([entry]))
        }
    }

    func testHasUnseenEntriesReturnsFalseWhenShowUnseenBadgeDisabled() throws {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let feed = try makeManagedFeed(
            entries: [
                (baseDate, baseDate.addingTimeInterval(60), false)
            ]
        )
        let entry = try XCTUnwrap(feed.getEntries()?.first)
        let realm = try XCTUnwrap(feed.realm)

        try realm.write {
            feed.showsUnseenBadge = false
        }

        try withReaderContentLoaderConfigurations(configuration: realm.configuration) {
            XCTAssertFalse(feed.hasUnseenEntries([entry]))
        }
    }

    func testHistoryRecordHasOpenedRecordIgnoresDeletedRecords() throws {
        let realm = try Realm(configuration: makeConfiguration())
        let targetURL = try XCTUnwrap(URL(string: "https://example.com/articles/target"))

        try realm.write {
            let deletedRecord = HistoryRecord()
            deletedRecord.url = targetURL
            deletedRecord.updateCompoundKey()
            deletedRecord.isDeleted = true
            realm.add(deletedRecord)

            let liveRecord = HistoryRecord()
            liveRecord.url = targetURL
            liveRecord.updateCompoundKey()
            realm.add(liveRecord)

            let otherRecord = HistoryRecord()
            otherRecord.url = URL(string: "https://example.com/articles/other")!
            otherRecord.updateCompoundKey()
            realm.add(otherRecord)
        }

        XCTAssertTrue(HistoryRecord.hasOpenedRecord(for: targetURL, in: realm))
        XCTAssertFalse(
            HistoryRecord.hasOpenedRecord(
                for: URL(string: "https://example.com/articles/missing")!,
                in: realm
            )
        )
    }

    func testHistoryRecordLatestLastVisitedAtReturnsNewestLiveRecord() throws {
        let realm = try Realm(configuration: makeConfiguration())
        let targetURL = try XCTUnwrap(URL(string: "https://example.com/articles/target"))
        let newerDate = Date(timeIntervalSince1970: 1_700_000_200)

        try realm.write {
            let olderRecord = HistoryRecord()
            olderRecord.url = targetURL
            olderRecord.updateCompoundKey()
            olderRecord.compoundKey += "-older"
            olderRecord.lastVisitedAt = Date(timeIntervalSince1970: 1_700_000_100)
            realm.add(olderRecord)

            let deletedNewerRecord = HistoryRecord()
            deletedNewerRecord.url = targetURL
            deletedNewerRecord.updateCompoundKey()
            deletedNewerRecord.compoundKey += "-deleted-newer"
            deletedNewerRecord.lastVisitedAt = Date(timeIntervalSince1970: 1_700_000_300)
            deletedNewerRecord.isDeleted = true
            realm.add(deletedNewerRecord)

            let liveNewerRecord = HistoryRecord()
            liveNewerRecord.url = targetURL
            liveNewerRecord.updateCompoundKey()
            liveNewerRecord.compoundKey += "-live-newer"
            liveNewerRecord.lastVisitedAt = newerDate
            realm.add(liveNewerRecord)
        }

        XCTAssertEqual(HistoryRecord.latestLastVisitedAt(for: targetURL, in: realm), newerDate)
    }
}
