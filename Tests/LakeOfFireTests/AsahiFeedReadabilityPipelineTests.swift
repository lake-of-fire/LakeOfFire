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
    func testCanonicalReadabilityHTMLLabelsPublicationDateWithoutChangingVisibleText() throws {
        let publishedTime = "May 11, 2026 <evening> & later"
        let html = buildCanonicalReadabilityHTML(
            title: "Title",
            byline: "",
            publishedTime: publishedTime,
            content: "<p>Body</p>",
            contentURL: URL(string: "https://example.com/article")!
        )

        let document = try SwiftSoup.parse(html)
        let publicationDate = try XCTUnwrap(document.getElementById("reader-publication-date"))
        XCTAssertEqual(try publicationDate.text(), publishedTime)
        XCTAssertEqual(
            try publicationDate.attr("aria-label"),
            "Reader metadata date: \(publishedTime)"
        )
    }

    private final class FeedURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responses = [URL: Data]()
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
                        "Content-Type": "application/rdf+xml; charset=utf-8",
                        "Content-Length": String(data.count),
                    ],
                    data
                )
            } else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            let response = HTTPURLResponse(
                url: url,
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
        addTeardownBlock {
            let sidecarExtensions = ["realm", "realm.lock", "realm.management", "realm.note"]
            for ext in sidecarExtensions {
                try? FileManager.default.removeItem(
                    at: realmURL.deletingPathExtension().appendingPathExtension(ext)
                )
            }
        }
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
            bundle.url(forResource: fileName, withExtension: nil, subdirectory: "Fixtures/Asahi"),
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
        feed.rssUrl = rssURL
        feed.lastFetchedETag = "\"stale-validator\""
        try await realm.asyncWrite {
            realm.add(feed)
        }

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
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            sessionConfiguration.protocolClasses = [FeedURLProtocol.self]
            return URLSession(configuration: sessionConfiguration)
        }

        try await feed.fetch(realmConfiguration: configuration)
        await realm.asyncRefresh()

        XCTAssertEqual(realm.objects(FeedEntry.self).where { !$0.isDeleted }.count, 1)
        XCTAssertEqual(
            realm.object(ofType: Feed.self, forPrimaryKey: feed.id)?.lastFetchedETag,
            "\"fresh-validator\""
        )
        XCTAssertEqual(requests.map(\.method), ["HEAD", "HEAD", "GET"])
        XCTAssertEqual(requests.map(\.validator), ["\"stale-validator\"", nil, nil])
    }

    @MainActor
    func testChangedHEADTagFetchesBodyDespiteEqualOrOlderModificationDate() async throws {
        for modificationDate in [
            "Wed, 01 Jan 2020 00:00:00 GMT",
            "Tue, 31 Dec 2019 00:00:00 GMT",
        ] {
            try await assertHTTPRefresh(
                headStatus: 200,
                headHeaders: [
                    "ETag": "\"head-version\"", "Last-Modified": modificationDate,
                ],
                getHeaders: ["ETag": "\"get-version\""],
                expectedETag: "\"get-version\"", expectedModifiedAt: nil
            )
        }
    }

    @MainActor
    func testUnsupportedHEADFallsBackToConditionalGET() async throws {
        for status in [405, 501] {
            try await assertHTTPRefresh(
                headStatus: status, getHeaders: ["ETag": "\"get-version\""],
                expectedETag: "\"get-version\"", expectedModifiedAt: nil
            )
        }
    }

    @MainActor
    func testFetchedBodyDoesNotInheritHEADOrStoredValidators() async throws {
        try await assertHTTPRefresh(headStatus: 200, expectedETag: nil, expectedModifiedAt: nil)
    }

    @MainActor
    func testGETPartialValidatorsDescribeOnlyFetchedRepresentation() async throws {
        try await assertHTTPRefresh(
            headStatus: 200, getHeaders: ["ETag": "\"get-version\""],
            expectedETag: "\"get-version\"", expectedModifiedAt: nil
        )
        try await assertHTTPRefresh(
            headStatus: 200, getHeaders: ["Last-Modified": "Fri, 01 Jan 2021 00:00:00 GMT"],
            expectedETag: nil, expectedModifiedAt: Date(timeIntervalSince1970: 1609459200)
        )
    }

    @MainActor
    func testGET304DoesNotBorrowNewHEADValidators() async throws {
        try await assertHTTPRefresh(
            headStatus: 200, getStatus: 304,
            expectedETag: "\"stored-version\"", expectedModifiedAt: Date(timeIntervalSince1970: 1577836800)
        )
    }

    @MainActor
    func testHEAD304PreservesStoredValidatorsAndSkipsGET() async throws {
        try await assertHTTPRefresh(
            headStatus: 304, headHeaders: [:],
            expectedETag: "\"stored-version\"", expectedModifiedAt: Date(timeIntervalSince1970: 1577836800),
            expectsGET: false
        )
    }

    @MainActor
    func testHEADAuthorizationAndGETFailureRemainErrors() async throws {
        try await assertHTTPRefresh(
            headStatus: 401, expectedETag: "\"stored-version\"",
            expectedModifiedAt: Date(timeIntervalSince1970: 1577836800),
            expectsGET: false, expectsFailure: true
        )
        try await assertHTTPRefresh(
            headStatus: 405, getStatus: 500, expectedETag: "\"stored-version\"",
            expectedModifiedAt: Date(timeIntervalSince1970: 1577836800), expectsFailure: true
        )
    }

    @MainActor
    private func assertHTTPRefresh(
        headStatus: Int,
        headHeaders: [String: String] = [
            "ETag": "\"head-version\"", "Last-Modified": "Sat, 01 Jan 2022 00:00:00 GMT"
        ],
        getStatus: Int = 200,
        getHeaders: [String: String] = [:],
        expectedETag: String?, expectedModifiedAt: Date?,
        expectsGET: Bool = true, expectsFailure: Bool = false
    ) async throws {
        let rssURL = URL(string: "https://example.com/\(UUID().uuidString)/feed.xml")!
        let entryURL = rssURL.deletingLastPathComponent().appendingPathComponent("new-entry")
        let data = Data("""
            <rss version="2.0"><channel><title>Test</title><link>https://example.com/</link>
            <description>Test</description><item><guid>new-entry</guid><title>New body</title>
            <link>\(entryURL.absoluteString)</link><description>New body content</description>
            </item></channel></rss>
            """.utf8)
        let configuration = makeRealmConfiguration()
        let previousLibrary = LibraryDataManager.realmConfiguration
        let previousBookmarks = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistory = ReaderContentLoader.historyRealmConfiguration
        let previousEntries = ReaderContentLoader.feedEntryRealmConfiguration
        let previousSession = makeFeedSessionOverrideForTesting
        let previousHandler = FeedURLProtocol.requestHandler
        defer {
            LibraryDataManager.realmConfiguration = previousLibrary
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmarks
            ReaderContentLoader.historyRealmConfiguration = previousHistory
            ReaderContentLoader.feedEntryRealmConfiguration = previousEntries
            makeFeedSessionOverrideForTesting = previousSession
            FeedURLProtocol.requestHandler = previousHandler
        }
        LibraryDataManager.realmConfiguration = configuration
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        await ReaderContentLoader.resetTransientCachesForTesting()
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let feed = Feed()
        feed.rssUrl = rssURL
        feed.lastFetchedETag = "\"stored-version\""
        feed.lastFetchedModifiedAt = Date(timeIntervalSince1970: 1577836800)
        let cached = FeedEntry()
        cached.feedID = feed.id
        cached.url = rssURL.appendingPathComponent("cached-entry")
        cached.compoundKey = feed.id.uuidString + "-cached-entry"
        try await realm.asyncWrite { realm.add(feed); realm.add(cached) }
        var requests = [URLRequest]()
        FeedURLProtocol.requestHandler = { request in
            requests.append(request)
            return request.httpMethod == "HEAD"
                ? (headStatus, headHeaders, Data()) : (getStatus, getHeaders, data)
        }
        makeFeedSessionOverrideForTesting = {
            let session = URLSessionConfiguration.ephemeral
            session.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            session.protocolClasses = [FeedURLProtocol.self]
            return URLSession(configuration: session)
        }
        do {
            try await feed.fetch(realmConfiguration: configuration)
            XCTAssertFalse(expectsFailure, "Refresh unexpectedly succeeded")
        } catch FeedError.downloadFailed {
            XCTAssertTrue(expectsFailure, "Refresh unexpectedly rejected HEAD/GET")
        }
        await realm.asyncRefresh()
        XCTAssertEqual(requests.map(\.httpMethod), expectsGET ? ["HEAD", "GET"] : ["HEAD"])
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"stored-version\"")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Modified-Since"), "Wed, 01 Jan 2020 00:00:00 GMT")
        }
        XCTAssertEqual(feed.lastFetchedETag, expectedETag)
        XCTAssertEqual(feed.lastFetchedModifiedAt, expectedModifiedAt)
        if !expectsFailure, expectsGET, getStatus == 200 {
            XCTAssertEqual(realm.objects(FeedEntry.self).where { $0.url == entryURL && !$0.isDeleted }.count, 1)
        }
        if expectsFailure { XCTAssertNil(feed.lastRefreshedEntriesAt) }
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
        let originalObservesDownloadController = LibraryDataManager.observesDownloadController
        defer {
            LibraryDataManager.realmConfiguration = originalLibraryConfiguration
            ReaderContentLoader.bookmarkRealmConfiguration = originalBookmarkConfiguration
            ReaderContentLoader.historyRealmConfiguration = originalHistoryConfiguration
            ReaderContentLoader.feedEntryRealmConfiguration = originalFeedEntryConfiguration
            makeFeedSessionOverrideForTesting = originalFeedSessionOverride
            LibraryDataManager.observesDownloadController = originalObservesDownloadController
        }
        LibraryDataManager.observesDownloadController = false
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
}
