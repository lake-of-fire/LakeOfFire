import Foundation
import RealmSwift
import SwiftReadability
import SwiftSoup
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

final class AsahiFeedReadabilityPipelineTests: XCTestCase {
    private final class FeedURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responses = [URL: Data]()

        override class func canInit(with request: URLRequest) -> Bool {
            request.url.map { responses[$0] != nil } ?? false
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let url = request.url, let data = Self.responses[url] else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            let headers = [
                "Content-Type": "application/rdf+xml; charset=utf-8",
                "Content-Length": String(data.count),
            ]
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if request.httpMethod != "HEAD" {
                client?.urlProtocol(self, didLoad: data)
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
        let originalFeedEntryConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            LibraryDataManager.realmConfiguration = originalLibraryConfiguration
            ReaderContentLoader.feedEntryRealmConfiguration = originalFeedEntryConfiguration
        }
        LibraryDataManager.realmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration

        FeedURLProtocol.responses = [rssURL: rssData]
        URLProtocol.registerClass(FeedURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(FeedURLProtocol.self)
            FeedURLProtocol.responses.removeAll()
        }

        let manager = LibraryDataManager()
        try await manager.importOPML(fileURL: opmlURL, realmConfiguration: configuration)

        let feed = try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            return try XCTUnwrap(
                realm.objects(Feed.self).first { $0.rssUrl == rssURL }
            ).freeze()
        }()

        XCTAssertTrue(feed.isReaderModeByDefault)
        XCTAssertFalse(feed.rssContainsFullContent)
        XCTAssertFalse(feed.injectEntryImageIntoHeader)
        XCTAssertEqual(feed.meaningfulContentMinLength, 0)

        let managedFeed = try XCTUnwrap(feed.thaw())
        try await managedFeed.fetch(realmConfiguration: configuration)

        let entry = try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            return try XCTUnwrap(
                realm.objects(FeedEntry.self).first {
                    $0.url.absoluteString.contains("ASV5C451NV5CUEFT01YM")
                }
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
