import Foundation
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

final class FeedRSSPersistenceBatchTests: XCTestCase {
    @MainActor
    func testInterruptedRSSBatchesKeepOrphansUntilRetryCompletes() async throws {
        let configuration = makeRealmConfiguration()
        let previousLibrary = LibraryDataManager.realmConfiguration
        let previousBookmarks = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistory = ReaderContentLoader.historyRealmConfiguration
        let previousEntries = ReaderContentLoader.feedEntryRealmConfiguration
        let previousSession = makeFeedSessionOverrideForTesting
        let previousHandler = BatchFeedURLProtocol.requestHandler
        defer {
            LibraryDataManager.realmConfiguration = previousLibrary
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmarks
            ReaderContentLoader.historyRealmConfiguration = previousHistory
            ReaderContentLoader.feedEntryRealmConfiguration = previousEntries
            makeFeedSessionOverrideForTesting = previousSession
            BatchFeedURLProtocol.requestHandler = previousHandler
        }
        LibraryDataManager.realmConfiguration = configuration
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        await ReaderContentLoader.resetTransientCachesForTesting()
        addTeardownBlock {
            await ReaderContentLoader.resetTransientCachesForTesting()
            await { @RealmBackgroundActor in rssFeedPersistBatchGateForTesting = nil }()
        }

        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let rssURL = URL(string: "https://example.com/batch.rss")!
        let feed = Feed()
        feed.rssUrl = rssURL
        feed.deleteOrphans = true
        feed.lastFetchedRSSURL = rssURL
        feed.lastFetchedETag = "\"old\""
        let orphan = FeedEntry()
        orphan.feedID = feed.id
        orphan.url = URL(string: "https://example.com/old-entry")!
        orphan.title = "Cached entry"
        orphan.html = "Cached body"
        orphan.updateCompoundKey()
        try realm.write {
            realm.add(feed)
            realm.add(orphan)
        }

        let items = (0..<130).map { index in
            "<item><link>https://example.com/article-\(index)</link><title>Article \(index)</title><description>Body \(index)</description></item>"
        }.joined()
        let body = Data("<rss version='2.0'><channel><title>Batch</title>\(items)</channel></rss>".utf8)
        BatchFeedURLProtocol.requestHandler = { _ in
            (200, ["Content-Type": "application/rss+xml", "ETag": "\"new\""], body)
        }
        makeFeedSessionOverrideForTesting = {
            let session = URLSessionConfiguration.ephemeral
            session.protocolClasses = [BatchFeedURLProtocol.self]
            return URLSession(configuration: session)
        }

        let gate = RSSPersistenceBatchPause()
        await { @RealmBackgroundActor in
            rssFeedPersistBatchGateForTesting = { _ in await gate.pause() }
        }()
        let interruptedFetch = Task { try await feed.freeze().fetch(realmConfiguration: configuration) }
        await gate.waitUntilPaused()

        try await realm.asyncWrite { feed.isDeleted = true }
        await gate.release()
        do {
            try await interruptedFetch.value
            XCTFail("A tombstoned feed must stop before another batch or orphan cleanup")
        } catch is CancellationError {
            // Expected: the first committed batch is retryable and no orphan was removed.
        }
        await realm.asyncRefresh()
        XCTAssertEqual(realm.objects(FeedEntry.self).filter { $0.feedID == feed.id && !$0.isDeleted }.count, 129)
        XCTAssertFalse(orphan.isDeleted)
        XCTAssertNil(feed.lastFetchedRSSURL)
        XCTAssertNil(feed.lastFetchedETag)

        try await realm.asyncWrite { feed.isDeleted = false }
        await { @RealmBackgroundActor in rssFeedPersistBatchGateForTesting = nil }()
        try await feed.freeze().fetch(realmConfiguration: configuration)
        await realm.asyncRefresh()
        XCTAssertEqual(realm.objects(FeedEntry.self).filter { $0.feedID == feed.id && !$0.isDeleted }.count, 130)
        XCTAssertTrue(orphan.isDeleted)
        XCTAssertEqual(feed.lastFetchedETag, "\"new\"")
    }

    private func makeRealmConfiguration() -> Realm.Configuration {
        let realmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("realm")
        var configuration = DefaultRealmConfiguration.configuration
        configuration.inMemoryIdentifier = nil
        configuration.fileURL = realmURL
        configuration.objectTypes = (configuration.objectTypes ?? []) + [
            Feed.self, FeedEntry.self, Bookmark.self, ContentFile.self,
            ContentPackageFile.self, HistoryRecord.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
            for ext in ["realm", "realm.lock", "realm.management", "realm.note"] {
                try? FileManager.default.removeItem(
                    at: realmURL.deletingPathExtension().appendingPathExtension(ext)
                )
            }
        }
        return configuration
    }
}

private actor RSSPersistenceBatchPause {
    private var paused = false
    private var released = false
    private var arrivalWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseWaiter = continuation
            }
        }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class BatchFeedURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { requestHandler != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
