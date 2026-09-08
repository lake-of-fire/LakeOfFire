import XCTest
import RealmSwift
import RealmSwiftGaps
@testable import LakeOfFireContent

final class ReaderContentAuthorityTests: XCTestCase {
    func testSummaryAndMissingFeedBodiesPreserveCapturedBookmarkAndHistory() {
        let fullBody = Data("<article>Captured full article.</article>".utf8)
        let mirrors: [any ReaderContentProtocol] = [Bookmark(), HistoryRecord()]
        for content in mirrors {
            content.content = fullBody
            content.rssContainsFullContent = true
            let incomingBodies: [Data?] = [Data("<p>Updated teaser.</p>".utf8), nil]
            for incomingBody in incomingBodies {
                let incoming = FeedEntry()
                incoming.title = incomingBody == nil ? "Metadata-only refresh" : "Updated title"
                incoming.content = incomingBody
                XCTAssertTrue(applyPayload(FeedEntryPayload(entry: incoming, containsFullContent: false), to: content))
                XCTAssertEqual(content.title, incoming.title)
                XCTAssertEqual(content.content, fullBody)
                XCTAssertTrue(content.rssContainsFullContent)
            }
        }
    }

    func testAuthoritativeFeedBodyPromotesSummaryAndNoBodyNeverClearsCapture() {
        let bookmark = Bookmark()
        let fullBody = Data("<article>Complete article.</article>".utf8)
        XCTAssertTrue(applyFeedBody(fullBody, containsFullContent: true, to: bookmark))
        XCTAssertEqual(bookmark.content, fullBody)
        XCTAssertTrue(bookmark.rssContainsFullContent)
        XCTAssertFalse(applyFeedBody(nil, containsFullContent: true, to: bookmark))
        XCTAssertFalse(applyFeedBody(Data(), containsFullContent: true, to: bookmark))
        XCTAssertFalse(applyFeedBody(fullBody, containsFullContent: true, to: bookmark))
        XCTAssertEqual(bookmark.content, fullBody)
    }

    @MainActor
    func testImmediateHistoryReloadPreservesCapturedFieldsAfterCachedMiss() async throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let previousBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistory = ReaderContentLoader.historyRealmConfiguration
        let previousFeed = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmark
            ReaderContentLoader.historyRealmConfiguration = previousHistory
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeed
        }
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        await ReaderContentLoader.resetTransientCachesForTesting()
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let url = URL(string: "https://example.com/\(UUID().uuidString)")!
        let missing = try await ReaderContentLoader.lookupStoredContent(url: url)
        XCTAssertNil(missing)
        let first = try await ReaderContentLoader.load(url: url, persist: true, countsAsHistoryVisit: true)
        let key = try XCTUnwrap(first?.compoundKey)
        await realm.asyncRefresh()
        let stored = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
        let fullBody = Data("<article>Captured full article.</article>".utf8)
        try realm.write {
            stored.title = "Captured title"
            stored.content = fullBody
            stored.rssContainsFullContent = true
            stored.isReaderModeByDefault = true
            stored.refreshChangeMetadata(explicitlyModified: true)
        }
        let second = try await ReaderContentLoader.load(url: url, persist: true, countsAsHistoryVisit: true)
        XCTAssertEqual(second?.compoundKey, key)
        XCTAssertEqual(second?.title, "Captured title")
        XCTAssertEqual(second?.content, fullBody)
        XCTAssertEqual(second?.rssContainsFullContent, true)
        XCTAssertEqual(second?.isReaderModeByDefault, true)
        let lookedUp = try await ReaderContentLoader.lookupStoredContent(url: url)
        XCTAssertEqual(lookedUp?.compoundKey, key)
        await realm.asyncRefresh()
        XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
        await ReaderContentLoader.resetTransientCachesForTesting()
    }
}
