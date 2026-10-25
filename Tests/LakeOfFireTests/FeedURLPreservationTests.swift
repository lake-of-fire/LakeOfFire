import Foundation
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

final class FeedURLPreservationTests: XCTestCase {
    @MainActor
    func testRSSFeedLinksPreservePercentEscapesAndFragments() async throws {
        let origin = "https://\(UUID().uuidString.lowercased()).example"
        let rawURLs = [
            "\(origin)/%E6%97%A5%E6%9C%AC",
            "\(origin)/article?next=%2Fnews%3Fid%3D1&token=a%2Bb%26c",
            "\(origin)/story#section-2",
            "\(origin)/plain-article",
        ]
        let items = rawURLs.enumerated().map { index, rawURL in
            """
            <item>
                <title>Entry \(index)</title>
                <link><![CDATA[\(rawURL)]]></link>
                <description>Fixture \(index)</description>
            </item>
            """
        }.joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
            <title>URL preservation</title>
            <link>\(origin)</link>
            <description>fixture</description>
            \(items)
        </channel></rss>
        """

        let entries = try await fetchEntries(xml: xml)
        XCTAssertEqual(entries.count, rawURLs.count)
        for (index, rawURL) in rawURLs.enumerated() {
            let entry = try XCTUnwrap(entries.first { $0.title == "Entry \(index)" })
            XCTAssertEqual(entry.articleURL, rawURL)
        }
    }

    @MainActor
    func testAtomFeedLinksPreservePercentEscapesAndFragments() async throws {
        let origin = "https://\(UUID().uuidString.lowercased()).example"
        let articleURL = "\(origin)/%E6%97%A5%E6%9C%AC?next=%2Fnews#section-2"
        let imageURL = "\(origin)/images/%E6%97%A5%E6%9C%AC.jpg?token=a%2Bb%26c"
        let translationsURL = "\(origin)/comments/%2Fthread#translation"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
            <title>URL preservation</title>
            <id>\(origin)/feed</id>
            <updated>2026-10-19T00:00:00Z</updated>
            <entry>
                <id>\(origin)/entry</id>
                <title>Atom entry</title>
                <updated>2026-10-19T00:00:00Z</updated>
                <link rel="alternate" href="\(articleURL)" />
                <link rel="enclosure" type="image/jpeg" href="\(imageURL)" />
                <link rel="reddit-translations" href="\(translationsURL)" />
                <content type="html">Fixture</content>
            </entry>
        </feed>
        """

        let entries = try await fetchEntries(xml: xml)
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.articleURL, articleURL)
        XCTAssertEqual(entry.imageURL, imageURL)
        XCTAssertEqual(entry.translationsURL, translationsURL)
    }

    private struct EntrySnapshot: Sendable {
        let title: String
        let articleURL: String
        let imageURL: String?
        let translationsURL: String?
    }

    @MainActor
    private func fetchEntries(xml: String) async throws -> [EntrySnapshot] {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            Feed.self,
            FeedEntry.self,
            FeedEntryCollection.self,
            Bookmark.self,
            ContentFile.self,
            ContentPackageFile.self,
            HistoryRecord.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)

        let originalHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        let originalProviders = ReaderContentLoader.additionalContentProviders
        let originalSessionOverride = makeFeedSessionOverrideForTesting
        let feedURL = try XCTUnwrap(URL(string: "https://\(UUID().uuidString.lowercased()).example/feed.xml"))
        FeedURLProtocol.install(Data(xml.utf8), for: feedURL)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfiguration.protocolClasses = [FeedURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer {
            session.invalidateAndCancel()
            FeedURLProtocol.removeResponse(for: feedURL)
            ReaderContentLoader.historyRealmConfiguration = originalHistoryConfiguration
            ReaderContentLoader.additionalContentProviders = originalProviders
            makeFeedSessionOverrideForTesting = originalSessionOverride
        }
        // Related-content lookup uses this same captured Realm. Keep unrelated
        // provider callbacks outside the transport-to-persistence fixture.
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.additionalContentProviders = []
        makeFeedSessionOverrideForTesting = { session }

        var cachedURLs = [URL]()
        do {
            let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
            defer { realm.invalidate() }
            let feed = Feed()
            feed.title = "URL preservation"
            feed.rssUrl = feedURL
            let feedID = feed.id
            try realm.write { realm.add(feed) }

            try await feed.fetch(realmConfiguration: configuration)
            await realm.asyncRefresh()
            let entries = realm.objects(FeedEntry.self)
                .where { $0.feedID == feedID && !$0.isDeleted }
            cachedURLs = entries.map(\.url)
            let snapshots = entries.map { entry in
                EntrySnapshot(
                    title: entry.title,
                    articleURL: entry.url.absoluteString,
                    imageURL: entry.imageUrl?.absoluteString,
                    translationsURL: entry.redditTranslationsUrl?.absoluteString
                )
            }
            await Self.releaseFixtureRealm(configuration, cachedURLs: cachedURLs)
            return snapshots
        } catch {
            await Self.releaseFixtureRealm(configuration, cachedURLs: cachedURLs)
            throw error
        }
    }

    @RealmBackgroundActor
    private static func releaseFixtureRealm(
        _ configuration: Realm.Configuration,
        cachedURLs: [URL]
    ) async {
        for url in cachedURLs {
            ReaderContentLoader.invalidateCachedContent(for: url)
        }
        RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        let remaining = await RealmBackgroundActor.shared.existingCachedRealm(for: configuration)
        XCTAssertNil(remaining, "Release only the quiesced fixture's cached Realm.")
    }

    private final class FeedURLProtocol: URLProtocol {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var responses = [URL: Data]()

        static func install(_ data: Data, for url: URL) {
            lock.withLock { responses[url] = data }
        }

        static func removeResponse(for url: URL) {
            lock.withLock { _ = responses.removeValue(forKey: url) }
        }

        private static func response(for request: URLRequest) -> Data? {
            guard let url = request.url else { return nil }
            return lock.withLock { responses[url] }
        }

        override class func canInit(with request: URLRequest) -> Bool {
            response(for: request) != nil
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let url = request.url, let data = Self.response(for: request),
                  let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/xml"]
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if request.httpMethod != "HEAD" {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}
