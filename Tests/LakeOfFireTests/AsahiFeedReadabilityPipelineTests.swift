import Foundation
import RealmSwift
import RealmSwiftGaps
import SwiftReadability
import SwiftSoup
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

final class AsahiFeedReadabilityPipelineTests: XCTestCase {
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
