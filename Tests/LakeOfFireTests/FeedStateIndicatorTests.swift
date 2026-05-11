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

    func testFollowingEntriesIgnoresUnfollowedAndSeenEntries() throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let followedFeed = Feed()
        followedFeed.title = "Followed"
        followedFeed.rssUrl = URL(string: "https://example.com/followed.xml")!
        followedFeed.iconUrl = followedFeed.rssUrl
        followedFeed.isFollowed = true
        followedFeed.lastSeenFeedEntriesAt = baseDate.addingTimeInterval(50)

        let unfollowedFeed = Feed()
        unfollowedFeed.title = "Unfollowed"
        unfollowedFeed.rssUrl = URL(string: "https://example.com/unfollowed.xml")!
        unfollowedFeed.iconUrl = unfollowedFeed.rssUrl

        try realm.write {
            realm.add([followedFeed, unfollowedFeed])
            realm.add(makeEntry(feed: followedFeed, suffix: "seen", date: baseDate.addingTimeInterval(40)))
            realm.add(makeEntry(feed: followedFeed, suffix: "new", date: baseDate.addingTimeInterval(60)))
            realm.add(makeEntry(feed: unfollowedFeed, suffix: "ignored", date: baseDate.addingTimeInterval(70)))
        }

        let followingEntries = Feed.followingEntries(from: [followedFeed, unfollowedFeed])

        XCTAssertEqual(followingEntries.map(\.title), ["new"])
    }

    private func makeEntry(feed: Feed, suffix: String, date: Date) -> FeedEntry {
        let entry = FeedEntry()
        entry.feedID = feed.id
        entry.title = suffix
        entry.url = URL(string: "https://example.com/articles/\(feed.id.uuidString)/\(suffix)")!
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

        try realm.write {
            let lookupRecord = HistoryRecord()
            lookupRecord.url = targetURL
            lookupRecord.updateCompoundKey()
            let liveRecord = realm.object(
                ofType: HistoryRecord.self,
                forPrimaryKey: lookupRecord.compoundKey
            )!
            liveRecord.isDeleted = true
        }
        XCTAssertFalse(HistoryRecord.hasOpenedRecord(for: targetURL, in: realm))
    }

    func testHistoryRecordLatestLastVisitedAtReturnsNewestLiveRecord() throws {
        let realm = try Realm(configuration: makeConfiguration())
        let targetURL = try XCTUnwrap(URL(string: "https://example.com/articles/target"))
        let newerDate = Date(timeIntervalSince1970: 1_700_000_200)

        try realm.write {
            let liveNewerRecord = HistoryRecord()
            liveNewerRecord.url = targetURL
            liveNewerRecord.updateCompoundKey()
            liveNewerRecord.lastVisitedAt = newerDate
            realm.add(liveNewerRecord)
        }

        XCTAssertEqual(HistoryRecord.latestLastVisitedAt(for: targetURL, in: realm), newerDate)

        try realm.write {
            let liveRecord = realm.objects(HistoryRecord.self).first!
            liveRecord.isDeleted = true
        }
        XCTAssertNil(HistoryRecord.latestLastVisitedAt(for: targetURL, in: realm))
    }
}
