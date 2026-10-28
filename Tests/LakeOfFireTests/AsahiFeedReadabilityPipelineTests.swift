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
        feed.lastFetchedRSSURL = feed.rssUrl
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

    @MainActor
    func testLegacyRefreshMetadataRequiresAnUnconditionalBody() async throws {
        try await assertHTTPRefresh(
            headStatus: 200, headHeaders: ["ETag": "\"stored-version\""],
            getHeaders: ["ETag": "\"new-version\""],
            expectedETag: "\"new-version\"", expectedModifiedAt: nil,
            storedFetchProvenance: .legacy,
            storedRefreshedAt: Date().addingTimeInterval(-60)
        )
    }

    @MainActor
    func testURLOnlyReplacementIgnoresPreviousURLValidatorsAndRefreshDate() async throws {
        try await assertHTTPRefresh(
            headStatus: 200, headHeaders: ["ETag": "\"stored-version\""],
            getHeaders: ["ETag": "\"new-version\""],
            expectedETag: "\"new-version\"", expectedModifiedAt: nil,
            storedFetchProvenance: .previousURL,
            storedRefreshedAt: Date().addingTimeInterval(-60)
        )
    }

    @MainActor
    func testUnprovenHEAD304StillRequiresAnUnconditionalBody() async throws {
        for provenance in [StoredFetchProvenance.legacy, .previousURL] {
            try await assertHTTPRefresh(
                headStatus: 304, headHeaders: [:],
                getHeaders: ["ETag": "\"new-version\""],
                expectedETag: "\"new-version\"", expectedModifiedAt: nil,
                storedFetchProvenance: provenance,
                storedRefreshedAt: Date().addingTimeInterval(-60)
            )
        }
    }

    @MainActor
    func testUnprovenGET304CannotPublishRefreshMetadataForCurrentURL() async throws {
        for provenance in [StoredFetchProvenance.legacy, .previousURL] {
            try await assertHTTPRefresh(
                headStatus: 405, getStatus: 304,
                expectedETag: "\"stored-version\"",
                expectedModifiedAt: Date(timeIntervalSince1970: 1577836800),
                expectsFailure: true, storedFetchProvenance: provenance,
                storedRefreshedAt: Date().addingTimeInterval(-60)
            )
        }
    }

    @MainActor
    func testFetchedURLProvenanceIsLocalOnlyAndStartsUnknown() {
        let feed = Feed()
        XCTAssertNil(feed.lastFetchedRSSURL)
        XCTAssertTrue(feed.skipSyncingProperties()?.contains("lastFetchedRSSURL") == true)
    }

    @MainActor
    func testFrozenCallerCannotRevalidateSameValidatorsFetchedFromAnotherURL() async throws {
        let originalURL = URL(string: "https://example.com/\(UUID().uuidString)/original.xml")!
        let replacementURL = originalURL.deletingLastPathComponent().appendingPathComponent("replacement.xml")
        let entryURL = originalURL.deletingLastPathComponent().appendingPathComponent("entry")
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
        feed.rssUrl = originalURL
        feed.lastFetchedRSSURL = originalURL
        feed.lastFetchedETag = "\"shared-validator\""
        feed.lastFetchedModifiedAt = Date(timeIntervalSince1970: 1577836800)
        feed.lastRefreshedEntriesAt = Date()
        let cached = FeedEntry()
        cached.feedID = feed.id
        cached.url = entryURL
        cached.title = "Original"
        cached.html = "Original body"
        cached.updateCompoundKey()
        try await realm.asyncWrite { realm.add(feed); realm.add(cached) }
        let staleFeed = feed.freeze()
        var requests = [URLRequest]()
        FeedURLProtocol.requestHandler = { request in
            requests.append(request)
            let headers = [
                "ETag": "\"shared-validator\"",
                "Last-Modified": "Wed, 01 Jan 2020 00:00:00 GMT",
                "Content-Type": "application/xml",
            ]
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"shared-validator\"" {
                return (304, headers, Data())
            }
            let title = request.url == originalURL ? "Original" : "Replacement"
            return (200, headers, RefreshFixtureFormat.rss.data(entryURL: entryURL, title: title))
        }
        makeFeedSessionOverrideForTesting = {
            let session = URLSessionConfiguration.ephemeral
            session.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            session.protocolClasses = [FeedURLProtocol.self]
            return URLSession(configuration: session)
        }

        // URL-only sync edits can surround a successful fetch of another resource with equal validators.
        try await realm.asyncWrite { feed.rssUrl = replacementURL }
        try await feed.fetch(realmConfiguration: configuration)
        await realm.asyncRefresh()
        XCTAssertEqual(cached.title, "Replacement")
        XCTAssertEqual(feed.lastFetchedRSSURL, replacementURL)
        try await realm.asyncWrite { feed.rssUrl = originalURL }
        XCTAssertTrue(feed.shouldRefreshAutomaticallyOnFeedAppear)

        try await staleFeed.fetch(realmConfiguration: configuration)
        await realm.asyncRefresh()
        XCTAssertEqual(requests.map(\.url), [replacementURL, replacementURL, originalURL, originalURL, originalURL])
        XCTAssertEqual(requests.map(\.httpMethod), ["HEAD", "GET", "HEAD", "HEAD", "GET"])
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "If-None-Match") },
            [nil, nil, "\"shared-validator\"", nil, nil]
        )
        XCTAssertEqual(cached.title, "Original")
        XCTAssertEqual(cached.html, "Original body")
        XCTAssertEqual(feed.lastFetchedRSSURL, originalURL)
        XCTAssertNotNil(feed.lastRefreshedEntriesAt)
        XCTAssertFalse(feed.shouldRefreshAutomaticallyOnFeedAppear)
    }

    private enum StoredFetchProvenance: Equatable {
        case matching, legacy, previousURL
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
        expectsGET: Bool = true, expectsFailure: Bool = false,
        storedETag: String? = "\"stored-version\"",
        storedFetchProvenance: StoredFetchProvenance = .matching,
        storedRefreshedAt: Date? = nil
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
        let storedRSSURL: URL?
        switch storedFetchProvenance {
        case .matching: storedRSSURL = rssURL
        case .legacy: storedRSSURL = nil
        case .previousURL:
            storedRSSURL = rssURL.deletingLastPathComponent().appendingPathComponent("previous.xml")
        }
        feed.rssUrl = storedRSSURL ?? rssURL
        feed.lastFetchedRSSURL = storedRSSURL
        feed.lastFetchedETag = storedETag
        feed.lastFetchedModifiedAt = Date(timeIntervalSince1970: 1577836800)
        feed.lastRefreshedEntriesAt = storedRefreshedAt
        let cached = FeedEntry()
        cached.feedID = feed.id
        cached.url = rssURL.appendingPathComponent("cached-entry")
        cached.compoundKey = feed.id.uuidString + "-cached-entry"
        try await realm.asyncWrite { realm.add(feed); realm.add(cached) }
        if feed.rssUrl != rssURL {
            // Inbound sync changes the synchronized URL while retaining this device's local fields.
            try await realm.asyncWrite { feed.rssUrl = rssURL }
        }
        let hasMatchingFetchURL = storedFetchProvenance == .matching
        if !hasMatchingFetchURL {
            XCTAssertFalse(feed.hasRecentlyRefreshedEntries)
            XCTAssertTrue(feed.shouldRefreshAutomaticallyOnFeedAppear)
        }
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
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), hasMatchingFetchURL ? storedETag : nil)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "If-Modified-Since"),
                hasMatchingFetchURL ? "Wed, 01 Jan 2020 00:00:00 GMT" : nil
            )
        }
        XCTAssertEqual(feed.lastFetchedETag, expectedETag)
        XCTAssertEqual(feed.lastFetchedModifiedAt, expectedModifiedAt)
        if !expectsFailure, expectsGET, getStatus == 200 {
            XCTAssertEqual(realm.objects(FeedEntry.self).where { $0.url == entryURL && !$0.isDeleted }.count, 1)
        }
        if expectsFailure {
            XCTAssertEqual(feed.lastFetchedRSSURL, storedRSSURL)
            XCTAssertEqual(feed.lastRefreshedEntriesAt, storedRefreshedAt)
            if !hasMatchingFetchURL { XCTAssertTrue(feed.shouldRefreshAutomaticallyOnFeedAppear) }
        } else {
            XCTAssertEqual(feed.lastFetchedRSSURL, rssURL)
            XCTAssertNotNil(feed.lastRefreshedEntriesAt)
            XCTAssertFalse(feed.shouldRefreshAutomaticallyOnFeedAppear)
        }
    }


    private enum InterruptedRefresh: Equatable {
        case superseded, cancelled
    }

    private enum RefreshFixtureFormat {
        case rss, atom

        func data(entryURL: URL, title: String) -> Data {
            switch self {
            case .rss:
                return Data("""
                    <rss version="2.0"><channel><title>Test</title><link>https://example.com/</link>
                    <description>Test</description><item><guid>entry</guid><title>\(title)</title>
                    <link>\(entryURL.absoluteString)</link><description>\(title) body</description>
                    </item></channel></rss>
                    """.utf8)
            case .atom:
                return Data("""
                    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:manabi="https://manabi.io/feed">
                    <title>Test</title><id>urn:test:feed</id><updated>2022-01-01T00:00:00Z</updated>
                    <manabi:collection scheme="https://example.com/series" id="series" title="Collection \(title)"/>
                    <entry><id>urn:test:entry</id><title>\(title)</title>
                    <updated>2022-01-01T00:00:00Z</updated><link href="\(entryURL.absoluteString)"/>
                    <category scheme="https://example.com/series" term="series"/>
                    <content type="html">\(title) body</content></entry></feed>
                    """.utf8)
            }
        }
    }

    private enum RefreshFixtureError: Error {
        case registrationTimedOut, refreshUnexpectedlySucceeded
    }

    @MainActor
    private final class ReaderContentGate {
        let registered = XCTestExpectation(description: "Reader-content continuation registered")
        private var continuation: CheckedContinuation<Void, Never>?
        private var entered = false
        private var released = false

        func pauseFirstLookup() async {
            guard !entered, !released else { return }
            entered = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                registered.fulfill()
            }
        }

        func release() {
            released = true
            let continuation = continuation
            self.continuation = nil
            continuation?.resume()
        }
    }

    private final class RefreshHTTPScenario: @unchecked Sendable {
        struct Request {
            let method: String?
            let etag: String?
            let modifiedSince: String?
        }

        let originalRequestStarted = XCTestExpectation(description: "Restored representation requested")
        private let lock = NSLock()
        private let originalData: Data
        private let changedData: Data
        private var servesOriginal = false
        private var recordedOriginalRequest = false
        private var requestHistory = [Request]()

        init(originalData: Data, changedData: Data) {
            self.originalData = originalData
            self.changedData = changedData
        }

        var requests: [Request] {
            lock.lock()
            defer { lock.unlock() }
            return requestHistory
        }

        func restoreOriginalRepresentation() {
            lock.lock()
            defer { lock.unlock() }
            servesOriginal = true
        }

        func respond(to request: URLRequest) -> (statusCode: Int, headers: [String: String], data: Data) {
            lock.lock()
            let original = servesOriginal
            let shouldSignal = original && !recordedOriginalRequest
            if original { recordedOriginalRequest = true }
            requestHistory.append(Request(
                method: request.httpMethod,
                etag: request.value(forHTTPHeaderField: "If-None-Match"),
                modifiedSince: request.value(forHTTPHeaderField: "If-Modified-Since")
            ))
            lock.unlock()
            if shouldSignal { originalRequestStarted.fulfill() }
            let etag = original ? "\"A\"" : "\"B\""
            let headers = [
                "ETag": etag,
                "Last-Modified": original
                    ? "Wed, 01 Jan 2020 00:00:00 GMT" : "Sat, 01 Jan 2022 00:00:00 GMT",
                "Content-Type": "application/xml",
            ]
            return request.value(forHTTPHeaderField: "If-None-Match") == etag
                ? (304, headers, Data()) : (200, headers, original ? originalData : changedData)
        }
    }

    @MainActor
    func testSupersededRSSCommitCannotRevalidateOldBodyFromFrozenCaller() async throws {
        try await assertInterruptedRefresh(.superseded, format: .rss)
    }

    @MainActor
    func testSupersededAtomCommitCannotRevalidateOldBodyFromFrozenCaller() async throws {
        try await assertInterruptedRefresh(.superseded, format: .atom)
    }

    @MainActor
    func testCancelledRefreshRetiresValidatorsAfterEntryCommit() async throws {
        try await assertInterruptedRefresh(.cancelled, format: .rss)
    }

    @MainActor
    private func assertInterruptedRefresh(
        _ interruption: InterruptedRefresh, format: RefreshFixtureFormat
    ) async throws {
        let rssURL = URL(string: "https://example.com/\(UUID().uuidString)/feed.xml")!
        let entryURL = rssURL.deletingLastPathComponent().appendingPathComponent("entry")
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
        feed.lastFetchedRSSURL = rssURL
        feed.lastFetchedETag = "\"A\""
        feed.lastFetchedModifiedAt = Date(timeIntervalSince1970: 1577836800)
        feed.lastRefreshedEntriesAt = Date()
        let cached = FeedEntry()
        cached.feedID = feed.id
        cached.url = entryURL
        cached.title = "A"
        cached.html = "A body"
        cached.updateCompoundKey()
        try await realm.asyncWrite { realm.add(feed); realm.add(cached) }
        // Keep a same-actor snapshot to exercise a caller that captured A before the partial write.
        let staleFeed = feed.freeze()
        let scenario = RefreshHTTPScenario(
            originalData: format.data(entryURL: entryURL, title: "A"),
            changedData: format.data(entryURL: entryURL, title: "B")
        )
        FeedURLProtocol.requestHandler = { scenario.respond(to: $0) }
        makeFeedSessionOverrideForTesting = {
            let session = URLSessionConfiguration.ephemeral
            session.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            session.protocolClasses = [FeedURLProtocol.self]
            return URLSession(configuration: session)
        }
        let gate = ReaderContentGate()
        await { @RealmBackgroundActor in
            ReaderContentLoader.loadAllDiscoveryGateForTesting = {
                await gate.pauseFirstLookup()
            }
        }()
        let first = Task { @MainActor in try await feed.fetch(realmConfiguration: configuration) }
        var replacement: Task<Void, Error>?
        do {
            guard await XCTWaiter.fulfillment(of: [gate.registered], timeout: 2) == .completed else {
                throw RefreshFixtureError.registrationTimedOut
            }
            await realm.asyncRefresh()
            XCTAssertEqual(cached.title, "B", "The real entry transaction must have committed before suspension")
            XCTAssertNil(feed.lastFetchedETag)
            XCTAssertNil(feed.lastFetchedModifiedAt)
            XCTAssertNil(feed.lastRefreshedEntriesAt)
            XCTAssertNil(feed.lastFetchedRSSURL)
            if case .atom = format {
                XCTAssertEqual(realm.objects(FeedEntryCollection.self).first?.title, "Collection B")
            }

            scenario.restoreOriginalRepresentation()
            if interruption == .superseded {
                replacement = Task { @MainActor in
                    try await staleFeed.fetch(realmConfiguration: configuration)
                }
                // Wait for R2's actual request before releasing R1; loadAll may coalesce their work.
                guard await XCTWaiter.fulfillment(
                    of: [scenario.originalRequestStarted], timeout: 2
                ) == .completed else {
                    throw RefreshFixtureError.registrationTimedOut
                }
            } else if interruption == .cancelled {
                first.cancel()
            }
            gate.release()
            switch await first.result {
            case .success:
                throw RefreshFixtureError.refreshUnexpectedlySucceeded
            case .failure(let error):
                XCTAssertTrue(error is CancellationError, "Unexpected refresh error: \(error)")
            }
            if let replacement {
                try await replacement.value
            } else {
                await realm.asyncRefresh()
                XCTAssertNil(feed.lastFetchedRSSURL)
                XCTAssertNil(feed.lastRefreshedEntriesAt)
                await { @RealmBackgroundActor in
                    ReaderContentLoader.loadAllDiscoveryGateForTesting = nil
                }()
                try await feed.fetch(realmConfiguration: configuration)
            }
            await realm.asyncRefresh()
            XCTAssertEqual(cached.title, "A")
            XCTAssertEqual(cached.html, "A body")
            XCTAssertEqual(feed.lastFetchedETag, "\"A\"")
            XCTAssertEqual(feed.lastFetchedModifiedAt, Date(timeIntervalSince1970: 1577836800))
            XCTAssertNotNil(feed.lastRefreshedEntriesAt)
            XCTAssertEqual(feed.lastFetchedRSSURL, rssURL)
            if case .atom = format {
                XCTAssertEqual(realm.objects(FeedEntryCollection.self).first?.title, "Collection A")
            }
            let recoveryRequests = Array(scenario.requests.dropFirst(2))
            XCTAssertEqual(
                recoveryRequests.map(\.method),
                interruption == .superseded ? ["HEAD", "HEAD", "GET"] : ["HEAD", "GET"]
            )
            let unconditionalRequests = interruption == .superseded
                ? Array(recoveryRequests.dropFirst()) : recoveryRequests
            for request in unconditionalRequests {
                XCTAssertNil(request.etag)
                XCTAssertNil(request.modifiedSince)
            }
            if interruption == .superseded {
                XCTAssertEqual(recoveryRequests.first?.etag, "\"A\"")
            }
            // A fully settled representation still benefits from conditional refresh.
            let requestCount = scenario.requests.count
            try await feed.fetch(realmConfiguration: configuration)
            XCTAssertEqual(Array(scenario.requests.dropFirst(requestCount)).map(\.method), ["HEAD"])
        } catch {
            first.cancel()
            replacement?.cancel()
            gate.release()
            _ = await first.result
            _ = await replacement?.result
            await ReaderContentLoader.resetTransientCachesForTesting()
            throw error
        }
        await ReaderContentLoader.resetTransientCachesForTesting()
    }

    @MainActor
    func testLastModifiedOnlyBaselineStillAcceptsUnchangedHEAD() async throws {
        try await assertHTTPRefresh(
            headStatus: 200, headHeaders: ["Last-Modified": "Wed, 01 Jan 2020 00:00:00 GMT"],
            expectedETag: nil, expectedModifiedAt: Date(timeIntervalSince1970: 1577836800),
            expectsGET: false, storedETag: nil
        )
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
