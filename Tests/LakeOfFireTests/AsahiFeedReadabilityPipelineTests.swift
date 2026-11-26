import Foundation
import RealmSwift
import RealmSwiftGaps
import SwiftReadability
import SwiftSoup
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

final class AsahiFeedReadabilityPipelineTests: XCTestCase {
    @MainActor
    func testRefreshFallsBackFromUnsupportedHEADAndHonorsChangedETag() async throws {
        let configuration = makeRealmConfiguration()
        let originalLibrary = LibraryDataManager.realmConfiguration
        let originalBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let originalHistory = ReaderContentLoader.historyRealmConfiguration
        let originalEntry = ReaderContentLoader.feedEntryRealmConfiguration
        let originalSession = makeFeedSessionOverrideForTesting
        defer {
            LibraryDataManager.realmConfiguration = originalLibrary
            ReaderContentLoader.bookmarkRealmConfiguration = originalBookmark
            ReaderContentLoader.historyRealmConfiguration = originalHistory
            ReaderContentLoader.feedEntryRealmConfiguration = originalEntry
            makeFeedSessionOverrideForTesting = originalSession
            FeedURLProtocol.requestHandler = nil
        }
        LibraryDataManager.realmConfiguration = configuration
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        await ReaderContentLoader.resetTransientCachesForTesting()
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let feed = Feed()
        feed.rssUrl = URL(string: "https://example.com/regression.rss")!
        try realm.write { realm.add(feed) }
        makeFeedSessionOverrideForTesting = {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [FeedURLProtocol.self]
            return URLSession(configuration: config)
        }
        for (revision, headStatus) in [200, 405, 501, 200].enumerated() {
            let title = "Revision \(revision)"
            let data = Data("<rss version='2.0'><channel><title>Feed</title><item><guid>https://example.com/article</guid><link>https://example.com/article</link><title>\(title)</title><description>Body</description></item></channel></rss>".utf8)
            FeedURLProtocol.requestHandler = { request in
                let status = request.httpMethod == "HEAD" ? headStatus : 200
                return (status, ["ETag": "\"v\(revision)\"", "Last-Modified": "Mon, 07 Sep 2026 10:00:00 GMT", "Content-Type": "application/rss+xml"], data)
            }
            try await feed.freeze().fetch(realmConfiguration: configuration)
            await realm.asyncRefresh()
            XCTAssertEqual(realm.objects(FeedEntry.self).first?.title, title)
            XCTAssertEqual(feed.lastFetchedETag, "\"v\(revision)\"")
        }
        for headStatus in [405, 501] {
            FeedURLProtocol.requestHandler = { request in
                XCTAssertNotEqual(request.value(forHTTPHeaderField: "If-None-Match"), "error-page-tag")
                if request.httpMethod == "HEAD" {
                    return (headStatus, ["ETag": "error-page-tag", "Last-Modified": "Mon, 07 Sep 2026 10:00:00 GMT"], Data())
                }
                let data = Data("<rss version='2.0'><channel><title>Feed</title><item><guid>https://example.com/article</guid><link>https://example.com/article</link><title>No validators</title><description>Body</description></item></channel></rss>".utf8)
                return (200, ["Content-Type": "application/rss+xml"], data)
            }
            try await feed.freeze().fetch(realmConfiguration: configuration)
            await realm.asyncRefresh()
            XCTAssertEqual(realm.objects(FeedEntry.self).first?.title, "No validators")
            XCTAssertNotEqual(feed.lastFetchedETag, "error-page-tag")
        }
    }

    @MainActor
    func testAtomRefreshDistinguishesEmptyAndMissingLinkReferences() async throws {
        let feedURL = try XCTUnwrap(URL(string: "https://example.com/feeds/current.atom?revision=7"))
        let configuration = makeRealmConfiguration()
        let originalLibrary = LibraryDataManager.realmConfiguration
        let originalBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let originalHistory = ReaderContentLoader.historyRealmConfiguration
        let originalEntry = ReaderContentLoader.feedEntryRealmConfiguration
        let originalSession = makeFeedSessionOverrideForTesting
        let originalRequestHandler = FeedURLProtocol.requestHandler
        defer {
            LibraryDataManager.realmConfiguration = originalLibrary
            ReaderContentLoader.bookmarkRealmConfiguration = originalBookmark
            ReaderContentLoader.historyRealmConfiguration = originalHistory
            ReaderContentLoader.feedEntryRealmConfiguration = originalEntry
            makeFeedSessionOverrideForTesting = originalSession
            FeedURLProtocol.requestHandler = originalRequestHandler
        }
        LibraryDataManager.realmConfiguration = configuration
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        await ReaderContentLoader.resetTransientCachesForTesting()

        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let feed = Feed()
        feed.rssUrl = feedURL
        try realm.write {
            realm.add(feed)
            feed.refreshChangeMetadata(explicitlyModified: true)
        }

        let body = Data("""
            <feed xmlns="http://www.w3.org/2005/Atom">
              <id>urn:test:atom-feed</id>
              <title>Empty Atom link references</title>
              <updated>2026-11-06T00:00:00Z</updated>
              <author><name>Fixture Author</name></author>
              <entry>
                <id>urn:test:empty-href</id>
                <title>Empty href</title>
                <updated>2026-11-06T00:00:00Z</updated>
                <link type="text/html" href=""/>
              </entry>
              <entry>
                <id>urn:test:missing-href</id>
                <title>Missing href</title>
                <updated>2026-11-06T00:00:00Z</updated>
                <link type="text/html"/>
              </entry>
              <entry xml:base="articles/">
                <id>urn:test:empty-base</id>
                <title>Empty XML base</title>
                <updated>2026-11-06T00:00:00Z</updated>
                <link xml:base="" type="text/html" href="one.html"/>
              </entry>
              <entry xml:base="https://cdn.example/article?view=full%23quoted#toc">
                <id>urn:test:inherited-fragment</id>
                <title>Inherited fragment</title>
                <updated>2026-11-06T00:00:00Z</updated>
                <link type="text/html" href=""/>
              </entry>
              <entry xml:base="https://cdn.example/article?view=full%23quoted#toc">
                <id>urn:test:explicit-fragment</id>
                <title>Explicit fragment</title>
                <updated>2026-11-06T00:00:00Z</updated>
                <link type="text/html" href="#section"/>
              </entry>
            </feed>
            """.utf8)
        makeFeedSessionOverrideForTesting = {
            let session = URLSessionConfiguration.ephemeral
            session.protocolClasses = [FeedURLProtocol.self]
            return URLSession(configuration: session)
        }
        FeedURLProtocol.requestHandler = { _ in
            (200, ["Content-Type": "application/atom+xml"], body)
        }

        try await feed.freeze().fetch(realmConfiguration: configuration)
        await realm.asyncRefresh()

        let feedID = feed.id
        let entries = realm.objects(FeedEntry.self).where { $0.feedID == feedID && !$0.isDeleted }
        XCTAssertEqual(entries.count, 4)
        XCTAssertFalse(entries.contains { $0.title == "Missing href" })
        XCTAssertEqual(entries.first { $0.title == "Empty href" }?.url.absoluteString, feedURL.absoluteString)
        XCTAssertEqual(
            entries.first { $0.title == "Empty XML base" }?.url.absoluteString,
            "https://example.com/feeds/articles/one.html"
        )
        XCTAssertEqual(
            entries.first { $0.title == "Inherited fragment" }?.url.absoluteString,
            "https://cdn.example/article?view=full%23quoted"
        )
        XCTAssertEqual(
            entries.first { $0.title == "Explicit fragment" }?.url.absoluteString,
            "https://cdn.example/article?view=full%23quoted#section"
        )
    }

    @MainActor
    func testRSSRefreshResolvesItemMediaAgainstEffectiveDocumentURL() async throws {
        let feedURL = try XCTUnwrap(URL(string: "https://example.com/feed.xml"))
        let documentURL = try XCTUnwrap(URL(string: "https://feeds.example.com/editions/today/feed.xml"))
        let configuration = makeRealmConfiguration()
        let originalLibrary = LibraryDataManager.realmConfiguration
        let originalBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let originalHistory = ReaderContentLoader.historyRealmConfiguration
        let originalEntry = ReaderContentLoader.feedEntryRealmConfiguration
        let originalSession = makeFeedSessionOverrideForTesting
        let originalRequestHandler = FeedURLProtocol.requestHandler
        let originalResponseURL = FeedURLProtocol.responseURL
        defer {
            LibraryDataManager.realmConfiguration = originalLibrary
            ReaderContentLoader.bookmarkRealmConfiguration = originalBookmark
            ReaderContentLoader.historyRealmConfiguration = originalHistory
            ReaderContentLoader.feedEntryRealmConfiguration = originalEntry
            makeFeedSessionOverrideForTesting = originalSession
            FeedURLProtocol.requestHandler = originalRequestHandler
            FeedURLProtocol.responseURL = originalResponseURL
        }
        LibraryDataManager.realmConfiguration = configuration
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        await ReaderContentLoader.resetTransientCachesForTesting()

        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let feed = Feed()
        feed.rssUrl = feedURL
        try realm.write {
            realm.add(feed)
            feed.refreshChangeMetadata(explicitlyModified: true)
        }

        let body = Data("""
            <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
              <channel>
                <title>Relative item references</title>
                <link>https://example.com/</link>
                <description>RSS URL resolution fixture</description>
                <item>
                  <title>Enclosure image</title>
                  <link>articles/one.html</link>
                  <enclosure url="../images/one.jpg" length="1" type="image/jpeg"/>
                  <media:subTitle type="text/vtt" lang="en" href="captions/one.vtt"/>
                </item>
                <item>
                  <title>Media image</title>
                  <link>/articles/two.html</link>
                  <media:content url="images/two.png" type="image/png"/>
                </item>
              </channel>
            </rss>
            """.utf8)
        makeFeedSessionOverrideForTesting = {
            let session = URLSessionConfiguration.ephemeral
            session.protocolClasses = [FeedURLProtocol.self]
            return URLSession(configuration: session)
        }
        FeedURLProtocol.responseURL = documentURL
        FeedURLProtocol.requestHandler = { _ in
            (200, ["Content-Type": "application/rss+xml"], body)
        }

        try await feed.freeze().fetch(realmConfiguration: configuration)
        await realm.asyncRefresh()

        let feedID = feed.id
        let entries = realm.objects(FeedEntry.self).where { $0.feedID == feedID && !$0.isDeleted }
        XCTAssertEqual(entries.count, 2)
        let first = try XCTUnwrap(entries.first { $0.title == "Enclosure image" })
        XCTAssertEqual(first.url.absoluteString, "https://feeds.example.com/editions/today/articles/one.html")
        XCTAssertEqual(first.imageUrl?.absoluteString, "https://feeds.example.com/editions/images/one.jpg")
        XCTAssertEqual(first.audioSubtitlesURL?.absoluteString, "https://feeds.example.com/editions/today/captions/one.vtt")
        let second = try XCTUnwrap(entries.first { $0.title == "Media image" })
        XCTAssertEqual(second.url.absoluteString, "https://feeds.example.com/articles/two.html")
        XCTAssertEqual(second.imageUrl?.absoluteString, "https://feeds.example.com/editions/today/images/two.png")
    }

    private final class FeedURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responses = [URL: Data]()
        nonisolated(unsafe) static var responseURL: URL?
        nonisolated(unsafe) static var requestHandler:
            ((URLRequest) -> (statusCode: Int, headers: [String: String], data: Data))?

        override class func canInit(with request: URLRequest) -> Bool {
            requestHandler != nil
                || (request.url.map { responses[$0] != nil } ?? false)
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            let responsePayload: (
                statusCode: Int,
                headers: [String: String],
                data: Data
            )
            if let requestHandler = Self.requestHandler {
                responsePayload = requestHandler(request)
            } else if let data = Self.responses[url] {
                responsePayload = (
                    200,
                    [
                        "Content-Type":
                            "application/rdf+xml; charset=utf-8",
                        "Content-Length": String(data.count),
                    ],
                    data
                )
            } else {
                client?.urlProtocol(
                    self,
                    didFailWithError: URLError(.unsupportedURL)
                )
                return
            }
            let response = HTTPURLResponse(
                url: Self.responseURL ?? url,
                statusCode: responsePayload.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: responsePayload.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if request.httpMethod != "HEAD" {
                client?.urlProtocol(self, didLoad: responsePayload.data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeRealmConfiguration() -> Realm.Configuration {
        let realmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("realm")
        var configuration = DefaultRealmConfiguration.configuration
        configuration.inMemoryIdentifier = nil
        configuration.fileURL = realmURL
        configuration.objectTypes = (configuration.objectTypes ?? []) + [
            Bookmark.self,
            ContentFile.self,
            ContentPackageFile.self,
            HistoryRecord.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let fixtureConfiguration = configuration
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: fixtureConfiguration)
            let sidecarExtensions = ["realm", "realm.lock", "realm.management", "realm.note"]
            for ext in sidecarExtensions {
                try? FileManager.default.removeItem(
                    at: realmURL.deletingPathExtension().appendingPathExtension(ext)
                )
            }
        }
        return configuration
    }

    private func fixtureURL(_ fileName: String) throws -> URL {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        let candidates = [
            bundle.url(forResource: fileName, withExtension: nil),
            bundle.url(forResource: fileName, withExtension: nil, subdirectory: "Asahi"),
            bundle.url(forResource: fileName, withExtension: nil, subdirectory: "BEPAL"),
            bundle.url(forResource: fileName, withExtension: nil, subdirectory: "Fixtures/Asahi"),
            bundle.url(forResource: fileName, withExtension: nil, subdirectory: "Fixtures/BEPAL"),
        ]
        return try XCTUnwrap(candidates.compactMap { $0 }.first)
    }

    @MainActor
    func testFeedWithValidatorsButNoLocalEntriesRefetchesBody() async throws {
        let rssURL = try XCTUnwrap(URL(string: "https://example.com/feed.xml"))
        let entryURL = try XCTUnwrap(URL(string: "https://example.com/article"))
        let rssData = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0">
              <channel>
                <title>Recovery Feed</title>
                <link>https://example.com/</link>
                <description>Recovery test</description>
                <item>
                  <guid>recovered-entry</guid>
                  <title>Recovered Entry</title>
                  <link>\(entryURL.absoluteString)</link>
                  <description>Recovered body</description>
                </item>
              </channel>
            </rss>
            """.utf8
        )
        let configuration = makeRealmConfiguration()
        let originalLibraryConfiguration =
            LibraryDataManager.realmConfiguration
        let originalBookmarkConfiguration =
            ReaderContentLoader.bookmarkRealmConfiguration
        let originalHistoryConfiguration =
            ReaderContentLoader.historyRealmConfiguration
        let originalFeedEntryConfiguration =
            ReaderContentLoader.feedEntryRealmConfiguration
        let originalFeedSessionOverride = makeFeedSessionOverrideForTesting
        defer {
            LibraryDataManager.realmConfiguration =
                originalLibraryConfiguration
            ReaderContentLoader.bookmarkRealmConfiguration =
                originalBookmarkConfiguration
            ReaderContentLoader.historyRealmConfiguration =
                originalHistoryConfiguration
            ReaderContentLoader.feedEntryRealmConfiguration =
                originalFeedEntryConfiguration
            makeFeedSessionOverrideForTesting = originalFeedSessionOverride
            FeedURLProtocol.requestHandler = nil
        }
        LibraryDataManager.realmConfiguration = configuration
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        await ReaderContentLoader.resetTransientCachesForTesting()

        let realm = try await Realm(
            configuration: configuration,
            actor: MainActor.shared
        )
        let feed = Feed()
        feed.rssUrl = rssURL
        feed.lastFetchedRSSURL = rssURL
        feed.lastFetchedETag = "\"stale-validator\""
        try realm.write {
            realm.add(feed)
        }
        let frozenFeed = feed.freeze()

        var requests = [(method: String, validator: String?)]()
        FeedURLProtocol.requestHandler = { request in
            requests.append(
                (
                    request.httpMethod ?? "",
                    request.value(forHTTPHeaderField: "If-None-Match")
                )
            )
            if request.value(forHTTPHeaderField: "If-None-Match") != nil {
                return (304, ["ETag": "\"stale-validator\""], Data())
            }
            return (
                200,
                [
                    "Content-Type": "application/rss+xml; charset=utf-8",
                    "Content-Length": String(rssData.count),
                    "ETag": "\"fresh-validator\"",
                ],
                rssData
            )
        }
        makeFeedSessionOverrideForTesting = {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.requestCachePolicy =
                .reloadIgnoringLocalAndRemoteCacheData
            sessionConfiguration.protocolClasses = [FeedURLProtocol.self]
            return URLSession(configuration: sessionConfiguration)
        }

        try await frozenFeed.fetch(realmConfiguration: configuration)

        let refreshedRealm = try await Realm(
            configuration: configuration,
            actor: MainActor.shared
        )
        XCTAssertEqual(
            refreshedRealm.objects(FeedEntry.self)
                .where { !$0.isDeleted }
                .count,
            1
        )
        XCTAssertEqual(
            refreshedRealm.object(
                ofType: Feed.self,
                forPrimaryKey: feed.id
            )?.lastFetchedETag,
            "\"fresh-validator\""
        )
        XCTAssertEqual(
            requests.map(\.method),
            ["HEAD", "HEAD", "GET"]
        )
        XCTAssertEqual(
            requests.map(\.validator),
            ["\"stale-validator\"", nil, nil]
        )
    }

    @MainActor
    func testPartialFeedResponsesPreserveCachedEntriesAndValidators() async throws {
        let configuration = makeRealmConfiguration()
        let originalLibrary = LibraryDataManager.realmConfiguration
        let originalBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let originalHistory = ReaderContentLoader.historyRealmConfiguration
        let originalEntry = ReaderContentLoader.feedEntryRealmConfiguration
        let originalSession = makeFeedSessionOverrideForTesting
        let originalRequestHandler = FeedURLProtocol.requestHandler
        defer {
            LibraryDataManager.realmConfiguration = originalLibrary
            ReaderContentLoader.bookmarkRealmConfiguration = originalBookmark
            ReaderContentLoader.historyRealmConfiguration = originalHistory
            ReaderContentLoader.feedEntryRealmConfiguration = originalEntry
            makeFeedSessionOverrideForTesting = originalSession
            FeedURLProtocol.requestHandler = originalRequestHandler
        }
        LibraryDataManager.realmConfiguration = configuration
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        await ReaderContentLoader.resetTransientCachesForTesting()

        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let feed = Feed()
        let feedURL = try XCTUnwrap(URL(string: "https://example.com/partial-feed.xml"))
        feed.rssUrl = feedURL
        feed.deleteOrphans = true
        try realm.write {
            realm.add(feed)
            feed.refreshChangeMetadata(explicitlyModified: true)
        }
        makeFeedSessionOverrideForTesting = {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.protocolClasses = [FeedURLProtocol.self]
            return URLSession(configuration: sessionConfiguration)
        }

        func rssData(_ titles: [String]) -> Data {
            let items = titles.enumerated().map { index, title in
                """
                <item><guid>item-\(index)</guid><title>\(title)</title>
                <link>https://example.com/item-\(index)</link><description>Body</description></item>
                """
            }.joined()
            return Data("<rss version='2.0'><channel><title>Feed</title>\(items)</channel></rss>".utf8)
        }

        let cachedTitles = ["Cached First", "Cached Second"]
        let completeData = rssData(cachedTitles)
        let seedHeaders = [
            "Content-Type": "application/rss+xml",
            "ETag": "\"cached\"",
            "Last-Modified": "Mon, 07 Sep 2026 10:00:00 GMT",
        ]
        FeedURLProtocol.requestHandler = { _ in (200, seedHeaders, completeData) }
        try await feed.freeze().fetch(realmConfiguration: configuration)
        await realm.asyncRefresh()
        let activeEntries = realm.objects(FeedEntry.self).where { !$0.isDeleted }
        XCTAssertEqual(activeEntries.map(\.title).sorted(), cachedTitles)
        let cachedModified = try XCTUnwrap(feed.lastFetchedModifiedAt)
        let cachedRefresh = try XCTUnwrap(feed.lastRefreshedEntriesAt)

        // This is valid RSS that would replace one entry and orphan the other
        // if transport admitted it as the complete feed.
        let partialData = rssData(["Partial First"])
        let updatedHeaders = [
            "Content-Type": "application/rss+xml",
            "ETag": "\"updated\"",
            "Last-Modified": "Tue, 08 Sep 2026 10:00:00 GMT",
        ]
        let partialRange = "bytes 0-\(partialData.count - 1)/\(partialData.count + 100)"
        for partialMethod in ["GET", "HEAD"] {
            FeedURLProtocol.requestHandler = { request in
                if request.httpMethod == partialMethod {
                    // A matching HEAD validator cannot make a partial response authoritative.
                    var headers = partialMethod == "HEAD" ? seedHeaders : updatedHeaders
                    headers["Content-Range"] = partialRange
                    return (206, headers, partialData)
                }
                return (200, updatedHeaders, partialData)
            }
            do {
                try await feed.freeze().fetch(realmConfiguration: configuration)
                XCTFail("Expected a partial \(partialMethod) response to fail refresh")
            } catch FeedError.downloadFailed {
                // The response was rejected at the download boundary.
            }
            await realm.asyncRefresh()
            XCTAssertEqual(activeEntries.map(\.title).sorted(), cachedTitles)
            XCTAssertEqual(feed.lastFetchedETag, "\"cached\"")
            XCTAssertEqual(feed.lastFetchedModifiedAt, cachedModified)
            XCTAssertEqual(feed.lastRefreshedEntriesAt, cachedRefresh)
        }

        let updatedTitles = ["Updated First", "Updated Second"]
        let updatedData = rssData(updatedTitles)
        FeedURLProtocol.requestHandler = { _ in (200, updatedHeaders, updatedData) }
        try await feed.freeze().fetch(realmConfiguration: configuration)
        await realm.asyncRefresh()
        XCTAssertEqual(activeEntries.map(\.title).sorted(), updatedTitles)
        XCTAssertEqual(feed.lastFetchedETag, "\"updated\"")
    }

    @MainActor
    func testFeedResponseDoesNotPublishAfterURLChanges() async throws {
        let oldRSSURL = try XCTUnwrap(URL(string: "https://old.example/feed.xml"))
        let newRSSURL = try XCTUnwrap(URL(string: "https://new.example/feed.xml"))
        let rssData = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0"><channel>
              <title>Old Feed</title>
              <link>https://old.example/</link>
              <description>Old response</description>
              <item><guid>old-entry</guid><title>Old Entry</title>
                <link>https://old.example/article</link>
              </item>
            </channel></rss>
            """.utf8
        )
        let configuration = makeRealmConfiguration()
        let originalLibraryConfiguration = LibraryDataManager.realmConfiguration
        let originalBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        let originalHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        let originalFeedEntryConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        let originalFeedSessionOverride = makeFeedSessionOverrideForTesting
        defer {
            LibraryDataManager.realmConfiguration = originalLibraryConfiguration
            ReaderContentLoader.bookmarkRealmConfiguration = originalBookmarkConfiguration
            ReaderContentLoader.historyRealmConfiguration = originalHistoryConfiguration
            ReaderContentLoader.feedEntryRealmConfiguration = originalFeedEntryConfiguration
            makeFeedSessionOverrideForTesting = originalFeedSessionOverride
            FeedURLProtocol.requestHandler = nil
        }
        LibraryDataManager.realmConfiguration = configuration
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        await ReaderContentLoader.resetTransientCachesForTesting()

        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let feed = Feed()
        feed.rssUrl = oldRSSURL
        try realm.write { realm.add(feed) }
        let feedID = feed.id
        let frozenFeed = feed.freeze()

        FeedURLProtocol.requestHandler = { request in
            if request.httpMethod == "GET" {
                let backgroundRealm = try! Realm(configuration: configuration)
                try! backgroundRealm.write {
                    backgroundRealm.object(ofType: Feed.self, forPrimaryKey: feedID)?.rssUrl = newRSSURL
                }
            }
            return (
                200,
                [
                    "Content-Type": "application/rss+xml; charset=utf-8",
                    "Content-Length": String(rssData.count),
                    "ETag": "\"old-response\"",
                ],
                request.httpMethod == "HEAD" ? Data() : rssData
            )
        }
        makeFeedSessionOverrideForTesting = {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.protocolClasses = [FeedURLProtocol.self]
            return URLSession(configuration: sessionConfiguration)
        }

        do {
            try await frozenFeed.fetch(realmConfiguration: configuration)
        } catch is CancellationError {
            // URL replacement deliberately cancels publication of the old response.
        }

        await realm.asyncRefresh()
        XCTAssertEqual(realm.object(ofType: Feed.self, forPrimaryKey: feedID)?.rssUrl, newRSSURL)
        XCTAssertNil(realm.object(ofType: Feed.self, forPrimaryKey: feedID)?.lastFetchedETag)
        XCTAssertTrue(realm.objects(FeedEntry.self).where { !$0.isDeleted }.isEmpty)
    }

    func testLaterFeedRefreshLeaseSupersedesEarlierLeaseForSameFeed() {
        let registry = FeedRefreshRegistry()
        let feedID = UUID()
        let earlier = registry.begin(feedID: feedID)
        let later = registry.begin(feedID: feedID)

        XCTAssertFalse(registry.isCurrent(earlier))
        XCTAssertTrue(registry.isCurrent(later))
        registry.end(earlier)
        XCTAssertTrue(registry.isCurrent(later))
        registry.end(later)
        XCTAssertFalse(registry.isCurrent(later))
    }

    func testCanonicalReadabilityHTMLEscapesTextAndAttributes() throws {
        let contentURL = try XCTUnwrap(URL(string: "https://example.com/article?one=1&two=2"))
        let title = "A & <B> \"quoted\""
        let byline = "Author & <Editor> \"quoted\""
        let readerHTML = buildCanonicalReadabilityHTML(
            title: title,
            byline: byline,
            publishedTime: "2026 & later",
            content: "<p>Body</p>",
            contentURL: contentURL
        )

        let document = try SwiftSoup.parse(readerHTML)
        XCTAssertEqual(try document.getElementById("reader-title")?.text(), title)
        XCTAssertEqual(try document.getElementById("reader-byline")?.text(), byline)
        XCTAssertEqual(try document.getElementById("reader-publication-date")?.text(), "2026 & later")
        XCTAssertEqual(
            try document.select("a.reader-view-original").first()?.attr("href"),
            contentURL.absoluteString
        )
        XCTAssertEqual(
            try document.body()?.attr("data-mnb-reader-mode-available-for"),
            contentURL.absoluteString
        )
    }

    @MainActor
    func testAsahiOPMLFeedArticleReadabilityDoesNotRepeatTitleOrBylineInReaderContent() async throws {
        let opmlURL = try fixtureURL("asahi-defaults.opml")
        let rssURL = URL(string: "https://www.asahi.com/rss/asahi/newsheadlines.rdf")!
        let rssData = try Data(
            contentsOf: try fixtureURL("asahi-newsheadlines-land-cruiser.rdf")
        )
        let articleHTML = try String(
            contentsOf: try fixtureURL("asahi-land-cruiser-article.html"),
            encoding: .utf8
        )
        let configuration = makeRealmConfiguration()
        let originalLibraryConfiguration = LibraryDataManager.realmConfiguration
        let originalBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        let originalHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        let originalFeedEntryConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        let originalFeedSessionOverride = makeFeedSessionOverrideForTesting
        defer {
            LibraryDataManager.realmConfiguration = originalLibraryConfiguration
            ReaderContentLoader.bookmarkRealmConfiguration = originalBookmarkConfiguration
            ReaderContentLoader.historyRealmConfiguration = originalHistoryConfiguration
            ReaderContentLoader.feedEntryRealmConfiguration = originalFeedEntryConfiguration
            makeFeedSessionOverrideForTesting = originalFeedSessionOverride
        }
        LibraryDataManager.realmConfiguration = configuration
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        await ReaderContentLoader.resetTransientCachesForTesting()

        FeedURLProtocol.responses = [rssURL: rssData]
        makeFeedSessionOverrideForTesting = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.protocolClasses = [FeedURLProtocol.self]
            return URLSession(configuration: configuration)
        }
        defer {
            FeedURLProtocol.responses.removeAll()
        }

        let manager = LibraryDataManager()
        try await manager.importOPML(fileURL: opmlURL, realmConfiguration: configuration)

        let feed: Feed = try {
            let realm = try Realm(configuration: configuration)
            return try XCTUnwrap(
                realm.objects(Feed.self).first { $0.rssUrl == rssURL }
            ).freeze()
        }()

        XCTAssertTrue(feed.isReaderModeByDefault)
        XCTAssertFalse(feed.rssContainsFullContent)
        XCTAssertFalse(feed.injectEntryImageIntoHeader)
        XCTAssertEqual(feed.meaningfulContentMinLength, 0)

        try await feed.fetch(realmConfiguration: configuration)

        let entry = try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await realm.asyncRefresh()
            let entries = Array(realm.objects(FeedEntry.self))
            return try XCTUnwrap(
                entries.first {
                    $0.url.absoluteString.contains("ASV5C451NV5CUEFT01YM")
                },
                "Persisted feed entries: \(entries.count); urls: \(entries.map { $0.url.absoluteString }.joined(separator: ", "))"
            ).freeze()
        }()

        XCTAssertEqual(entry.title, "ランクルをバラバラに　コンテナ密輸、手口が巧妙化　迫る税関と警察")
        XCTAssertTrue(entry.isReaderModeByDefault)
        XCTAssertFalse(entry.rssContainsFullContent)

        let parser = SwiftReadability.Readability(
            html: articleHTML,
            url: entry.url,
            options: SwiftReadability.ReadabilityOptions(charThreshold: max(entry.meaningfulContentMinLength, 1))
        )
        let parsedArticle = try XCTUnwrap(parser.parse())
        let readerHTML = buildCanonicalReadabilityHTML(
            title: parsedArticle.title ?? "",
            byline: parsedArticle.byline ?? "",
            publishedTime: parsedArticle.publishedTime,
            content: parsedArticle.content,
            contentURL: entry.url
        )
        let doc = try SwiftSoup.parse(readerHTML)
        let readerTitle = try doc.getElementById("reader-title")?.text()
        let readerByline = try doc.getElementById("reader-byline")?.text()
        let readerContentText = try XCTUnwrap(doc.getElementById("reader-content")?.text())
        let readerContentHTML = try XCTUnwrap(doc.getElementById("reader-content")?.html())

        XCTAssertEqual(readerTitle, entry.title)
        XCTAssertEqual(readerByline, "朝日新聞")
        XCTAssertFalse(readerContentText.contains(entry.title))
        XCTAssertFalse(readerContentText.contains("朝日新聞"))
        XCTAssertFalse(readerContentText.contains("中嶋周平"))
        XCTAssertFalse(readerContentText.contains("奥田薫子"))
        XCTAssertTrue(readerContentHTML.contains("AS20260511003970.jpg"))
        XCTAssertTrue(
            readerContentText.contains("盗んだ高級車をバラバラにしてコンテナに入れ、中古車と偽って海外に密輸する手口が横行している")
        )
    }

    @MainActor
    func testBEPALFeedArticleReadabilityKeepsFullArticleBody() async throws {
        let opmlURL = try fixtureURL("bepal-defaults.opml")
        let rssURL = URL(string: "https://www.bepal.net/feed/")!
        let rssData = try Data(
            contentsOf: try fixtureURL("bepal-feed-674158.xml")
        )
        let articleHTML = try String(
            contentsOf: try fixtureURL("bepal-674158-article.html"),
            encoding: .utf8
        )
        let articleURL = URL(string: "https://www.bepal.net/archives/674158")!
        let configuration = makeRealmConfiguration()
        let originalLibraryConfiguration = LibraryDataManager.realmConfiguration
        let originalBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        let originalHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        let originalFeedEntryConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        let originalFeedSessionOverride = makeFeedSessionOverrideForTesting
        defer {
            LibraryDataManager.realmConfiguration = originalLibraryConfiguration
            ReaderContentLoader.bookmarkRealmConfiguration = originalBookmarkConfiguration
            ReaderContentLoader.historyRealmConfiguration = originalHistoryConfiguration
            ReaderContentLoader.feedEntryRealmConfiguration = originalFeedEntryConfiguration
            makeFeedSessionOverrideForTesting = originalFeedSessionOverride
        }
        LibraryDataManager.realmConfiguration = configuration
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        await ReaderContentLoader.resetTransientCachesForTesting()

        FeedURLProtocol.responses = [rssURL: rssData]
        makeFeedSessionOverrideForTesting = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.protocolClasses = [FeedURLProtocol.self]
            return URLSession(configuration: configuration)
        }
        defer {
            FeedURLProtocol.responses.removeAll()
        }

        let manager = LibraryDataManager()
        try await manager.importOPML(fileURL: opmlURL, realmConfiguration: configuration)

        let feed: Feed = try {
            let realm = try Realm(configuration: configuration)
            return try XCTUnwrap(
                realm.objects(Feed.self).first { $0.rssUrl == rssURL }
            ).freeze()
        }()

        XCTAssertTrue(feed.isReaderModeByDefault)
        XCTAssertFalse(feed.rssContainsFullContent)
        XCTAssertTrue(feed.extractImageFromContent)
        XCTAssertFalse(feed.injectEntryImageIntoHeader)
        XCTAssertEqual(feed.meaningfulContentMinLength, 0)

        try await feed.fetch(realmConfiguration: configuration)

        let entrySnapshot = try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await realm.asyncRefresh()
            let entries = Array(realm.objects(FeedEntry.self))
            let entry = try XCTUnwrap(
                entries.first { $0.url == articleURL },
                "Persisted feed entries: \(entries.count); urls: \(entries.map { $0.url.absoluteString }.joined(separator: ", "))"
            )
            return (
                title: entry.title,
                html: entry.html,
                isReaderModeByDefault: entry.isReaderModeByDefault,
                rssContainsFullContent: entry.rssContainsFullContent
            )
        }()

        XCTAssertEqual(entrySnapshot.title, "「親友は努力です」。山岳カメラマンだった友と自らの半生を＂ありのまま＂に描いたノンフィクション作家・小林元喜さんにインタビュー")
        XCTAssertTrue(entrySnapshot.isReaderModeByDefault)
        XCTAssertFalse(entrySnapshot.rssContainsFullContent)

        let storedFeedHTML = try XCTUnwrap(entrySnapshot.html)
        XCTAssertTrue(storedFeedHTML.contains("平賀淳さんのホームページ"))

        let contentCandidates = try await ReaderContentLoader.loadAll(url: articleURL)
        _ = try XCTUnwrap(
            contentCandidates.compactMap { $0 as? FeedEntry }.first
        )
        let loadedEntryRSSContainsFullContent = try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await realm.asyncRefresh()
            let entry = try XCTUnwrap(
                realm.objects(FeedEntry.self).first { $0.url == articleURL }
            )
            return entry.rssContainsFullContent
        }()
        XCTAssertFalse(loadedEntryRSSContainsFullContent)

        let parser = SwiftReadability.Readability(
            html: articleHTML,
            url: articleURL,
            options: SwiftReadability.ReadabilityOptions(charThreshold: max(feed.meaningfulContentMinLength, 1))
        )
        let parsedArticle = try XCTUnwrap(parser.parse())
        let readerHTML = buildCanonicalReadabilityHTML(
            title: parsedArticle.title ?? "",
            byline: parsedArticle.byline ?? "",
            publishedTime: parsedArticle.publishedTime,
            content: parsedArticle.content,
            contentURL: articleURL
        )
        let doc = try SwiftSoup.parse(readerHTML)
        let readerTitle = try doc.getElementById("reader-title")?.text()
        let readerByline = try doc.getElementById("reader-byline")?.text()
        let readerContentText = try XCTUnwrap(doc.getElementById("reader-content")?.text())
        let readerContentHTML = try XCTUnwrap(doc.getElementById("reader-content")?.html())

        XCTAssertEqual(readerTitle?.hasPrefix(entrySnapshot.title), true)
        XCTAssertEqual(readerByline, "BE-PAL編集部")
        XCTAssertTrue(readerContentText.contains("2022年5月、映像カメラマンの平賀淳さんがアラスカで亡くなった"))
        XCTAssertTrue(readerContentText.contains("何者かになれない焦りについても書いています"))
        XCTAssertTrue(readerContentText.contains("もし親友がいるなら、自分の思いを明確に言葉にして目を見て伝えたほうがいいと思います"))
        XCTAssertTrue(readerContentText.contains("平賀淳さんのホームページでは、彼の想いや作品を見ることができる"))
        XCTAssertTrue(readerContentHTML.contains("59795348069fd503888a600_98254281.png"))
        XCTAssertTrue(readerContentHTML.contains("18443890069fd50388a5de0_79655026.png"))
    }
}
