import XCTest
import RealmSwift
@testable import LakeOfFire

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
            olderRecord.lastVisitedAt = Date(timeIntervalSince1970: 1_700_000_100)
            realm.add(olderRecord)

            let deletedNewerRecord = HistoryRecord()
            deletedNewerRecord.url = targetURL
            deletedNewerRecord.updateCompoundKey()
            deletedNewerRecord.lastVisitedAt = Date(timeIntervalSince1970: 1_700_000_300)
            deletedNewerRecord.isDeleted = true
            realm.add(deletedNewerRecord)

            let liveNewerRecord = HistoryRecord()
            liveNewerRecord.url = targetURL
            liveNewerRecord.updateCompoundKey()
            liveNewerRecord.lastVisitedAt = newerDate
            realm.add(liveNewerRecord)
        }

        XCTAssertEqual(HistoryRecord.latestLastVisitedAt(for: targetURL, in: realm), newerDate)
    }
}
