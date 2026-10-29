import XCTest
import RealmSwift
import RealmSwiftGaps
@testable import LakeOfFireContent

final class ReaderContentAuthorityTests: XCTestCase {
    @MainActor
    func testCachedFeedGeometryReadEnrichesARestoredCaptureWithoutChangingStoredContent() async throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let storage = ReaderContentLoader.DiscoveryStorage(bookmarkConfiguration: configuration,
            historyConfiguration: configuration, feedConfiguration: configuration)
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let sourceURL = URL(string: "https://publisher.example/article")!
        let imageURL = URL(string: "https://images.example/a.jpg?sig=x%2Fy")!
        let geometry = try XCTUnwrap(ReaderImageGeometry(url: imageURL, width: 640, height: 480))
        let feed = FeedEntry()
        feed.url = sourceURL; feed.imageUrl = imageURL; feed.updateCompoundKey()
        feed.html = geometry.addingToFeedHTML("<p>Cached summary</p>", sourceURL: sourceURL)
        feed.createdAt = Date(timeIntervalSince1970: 100)
        let capture = HistoryRecord()
        capture.url = sourceURL; capture.imageUrl = imageURL; capture.updateCompoundKey()
        let body = "<body><article>Captured 𠮷 &amp; text<img src='\(imageURL.absoluteString)'></article></body></html>"
        capture.html = "<html><head><title>Capture</title></head>" + body
        capture.rssContainsFullContent = true
        capture.lastVisitedAt = Date(timeIntervalSince1970: 200)
        try realm.write { realm.add([feed, capture]) }
        let original = capture.content
        let originalDate = capture.modifiedAt
        let feedContent = feed.content
        let result = try await ReaderContentLoader.cachedFeedImageGeometry(
            sourceURL: sourceURL, imageURL: imageURL, storage: storage)
        XCTAssertEqual(result, geometry)
        await realm.asyncRefresh()
        XCTAssertEqual(capture.content, original, "Read-only restoration discovery must not queue a writer")
        XCTAssertEqual(capture.modifiedAt, originalDate)
        XCTAssertEqual(feed.content, feedContent)
        let presentationHTML = try XCTUnwrap(result).mergingIntoDocumentHead(
            try XCTUnwrap(capture.html), sourceURL: sourceURL)
        XCTAssertEqual(Data(presentationHTML.utf8).suffix(body.utf8.count), Data(body.utf8))
        XCTAssertEqual(ReaderImageGeometry.metadata(inHTML: presentationHTML,
            matchingURL: imageURL, sourceURL: sourceURL), geometry)
    }

    @MainActor
    func testCachedFeedGeometryRequiresExactArticleImageAndLiveEntry() async throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let storage = ReaderContentLoader.DiscoveryStorage(bookmarkConfiguration: configuration,
            historyConfiguration: configuration, feedConfiguration: configuration)
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let sourceURL = URL(string: "https://publisher.example/article")!
        let imageURL = URL(string: "https://images.example/a.jpg?sig=one")!
        let otherImage = URL(string: "https://images.example/a.jpg?sig=two")!
        let geometry = try XCTUnwrap(ReaderImageGeometry(url: imageURL, width: 640, height: 480))
        let entry = FeedEntry()
        entry.url = sourceURL; entry.imageUrl = imageURL; entry.updateCompoundKey()
        entry.html = geometry.addingToFeedHTML("<p>Cached summary</p>", sourceURL: sourceURL)
        try realm.write { realm.add(entry) }
        for scenario in ["deleted", "different-article", "different-image", "mismatched-metadata", "http-identity"] {
            try realm.write {
                entry.isDeleted = scenario == "deleted"
                entry.url = scenario == "different-article" ? URL(string: "https://publisher.example/other")!
                    : scenario == "http-identity" ? URL(string: "http://publisher.example/article")! : sourceURL
                entry.imageUrl = scenario == "different-image" ? otherImage : imageURL
                let metadata = scenario == "mismatched-metadata"
                    ? ReaderImageGeometry(url: otherImage, width: 20, height: 10)! : geometry
                entry.html = metadata.addingToFeedHTML("<p>Cached summary</p>", sourceURL: entry.url)
            }
            let result = try await ReaderContentLoader.cachedFeedImageGeometry(
                sourceURL: sourceURL, imageURL: imageURL, storage: storage)
            XCTAssertEqual(result, scenario == "http-identity" ? geometry : nil, scenario)
        }
    }

    func testSummaryRefreshEnrichesCapturedImagesWithoutChangingBodyAndIsANoopOnRepeat() throws {
        let sourceURL = URL(string: "https://publisher.example/article")!
        let imageURL = URL(string: "https://images.example/a%2Fb.jpg?signature=x%2Fy&literal=%252F")!
        let geometry = try XCTUnwrap(ReaderImageGeometry(url: imageURL, width: 640, height: 480))
        let body = "<body class='readability-mode'><article id='reader-content'>𠮷 e\u{301} &amp; 本文<img src='\(imageURL.absoluteString)'></article></body></html>"
        let captured = "<!doctype html><html><head><title>Captured</title></head>" + body
        let incoming = FeedEntry()
        incoming.url = sourceURL
        incoming.imageUrl = imageURL
        incoming.html = geometry.addingToFeedHTML("<p>Updated summary.</p>", sourceURL: sourceURL)
        let payload = FeedEntryPayload(entry: incoming, containsFullContent: false)

        let mirrors: [any ReaderContentProtocol] = [Bookmark(), HistoryRecord()]
        for content in mirrors {
            content.url = sourceURL
            content.html = captured
            content.rssContainsFullContent = true
            XCTAssertTrue(applyPayload(payload, to: content))
            let enriched = try XCTUnwrap(content.html)
            XCTAssertEqual(Data(enriched.utf8).suffix(body.utf8.count), Data(body.utf8))
            XCTAssertEqual(ReaderImageGeometry.metadata(inHTML: enriched,
                matchingURL: imageURL, sourceURL: sourceURL), geometry)
            XCTAssertTrue(content.rssContainsFullContent)
            let stored = content.content
            XCTAssertFalse(applyPayload(payload, to: content))
            XCTAssertEqual(content.content, stored, "Repeated metadata must not rewrite or recompress the capture")

            // History/bookmark import uses the same merge outside feed refresh.
            content.html = captured
            XCTAssertTrue(applyFeedBody(from: incoming, containsFullContent: false, to: content))
            XCTAssertEqual(ReaderImageGeometry.metadata(inHTML: content.html,
                matchingURL: imageURL, sourceURL: sourceURL), geometry)
            XCTAssertEqual(Data(try XCTUnwrap(content.html).utf8).suffix(body.utf8.count), Data(body.utf8))
        }
    }

    func testSummaryImageURLChangeReplacesOnlyMatchingHeadMetadata() throws {
        let sourceURL = URL(string: "https://publisher.example/article")!
        let oldURL = URL(string: "https://images.example/old.jpg")!
        let newURL = URL(string: "https://images.example/new.jpg")!
        let old = try XCTUnwrap(ReaderImageGeometry(url: oldURL, width: 640, height: 480))
        let new = try XCTUnwrap(ReaderImageGeometry(url: newURL, width: 900, height: 600))
        let body = "<body><article>Captured text<img src='\(oldURL.absoluteString)'></article></body></html>"
        let content = HistoryRecord()
        content.url = sourceURL
        content.imageUrl = oldURL
        content.html = old.mergingIntoDocumentHead("<html><head></head>" + body, sourceURL: sourceURL)
        content.rssContainsFullContent = true
        let incoming = FeedEntry()
        incoming.url = sourceURL
        incoming.imageUrl = newURL
        incoming.html = new.addingToFeedHTML("<p>Different summary.</p>", sourceURL: sourceURL)
        XCTAssertTrue(applyPayload(FeedEntryPayload(entry: incoming, containsFullContent: false), to: content))
        XCTAssertEqual(content.imageUrl, newURL)
        XCTAssertEqual(ReaderImageGeometry.metadata(inHTML: content.html,
            matchingURL: newURL, sourceURL: sourceURL), new)
        XCTAssertNil(ReaderImageGeometry.metadata(inHTML: content.html,
            matchingURL: oldURL, sourceURL: sourceURL))
        XCTAssertEqual(Data(try XCTUnwrap(content.html).utf8).suffix(body.utf8.count), Data(body.utf8))
    }

    func testSummaryWithoutMatchingGeometryDoesNotRewriteCapturedHTML() throws {
        let sourceURL = URL(string: "https://publisher.example/article")!
        let imageURL = URL(string: "https://images.example/current.jpg")!
        let unrelated = try XCTUnwrap(ReaderImageGeometry(
            url: URL(string: "https://images.example/unrelated.jpg")!, width: 10, height: 20))
        let content = Bookmark()
        content.url = sourceURL
        content.imageUrl = imageURL
        content.html = "<html><head><title>Captured</title></head><body>Complete article.</body></html>"
        content.rssContainsFullContent = true
        let captured = content.content
        for summary in [nil, "<p>No dimensions.</p>",
                        unrelated.addingToFeedHTML("<p>Wrong image.</p>", sourceURL: sourceURL)] {
            let incoming = FeedEntry()
            incoming.url = sourceURL
            incoming.imageUrl = imageURL
            incoming.html = summary
            XCTAssertFalse(applyFeedBody(from: incoming, containsFullContent: false, to: content))
            _ = applyPayload(FeedEntryPayload(entry: incoming, containsFullContent: false), to: content)
            XCTAssertEqual(content.content, captured)
            XCTAssertTrue(content.rssContainsFullContent)
        }
    }

    @RealmBackgroundActor
    func testHistoryVisitSnapshotEnrichesExistingCaptureWithoutReplacingIt() async throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let sourceURL = URL(string: "https://publisher.example/\(UUID().uuidString)")!
        let imageURL = URL(string: "https://images.example/photo.jpg")!
        let geometry = try XCTUnwrap(ReaderImageGeometry(url: imageURL, width: 640, height: 480))
        let source = FeedEntry()
        source.url = sourceURL
        source.imageUrl = imageURL
        source.html = "<p>Initial summary.</p>"
        let first = try await source.addHistoryRecord(realmConfiguration: configuration,
            pageURL: sourceURL, bookmarkRealmConfiguration: configuration)
        let key = first.compoundKey
        let body = "<body><article>Captured complete article.</article></body></html>"
        let realm = try XCTUnwrap(first.realm)
        try realm.write {
            first.html = "<html><head></head>" + body
            first.rssContainsFullContent = true
            first.refreshChangeMetadata(explicitlyModified: true)
        }
        source.html = geometry.addingToFeedHTML("<p>New summary.</p>", sourceURL: sourceURL)
        let second = try await source.addHistoryRecord(realmConfiguration: configuration,
            pageURL: sourceURL, bookmarkRealmConfiguration: configuration)
        XCTAssertEqual(second.compoundKey, key)
        XCTAssertEqual(second.url, sourceURL)
        XCTAssertTrue(second.rssContainsFullContent)
        XCTAssertEqual(ReaderImageGeometry.metadata(inHTML: second.html,
            matchingURL: imageURL, sourceURL: sourceURL), geometry)
        XCTAssertEqual(Data(try XCTUnwrap(second.html).utf8).suffix(body.utf8.count), Data(body.utf8))
        let enriched = second.content
        _ = try await source.addHistoryRecord(realmConfiguration: configuration,
            pageURL: sourceURL, bookmarkRealmConfiguration: configuration)
        XCTAssertEqual(second.content, enriched)
    }

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
