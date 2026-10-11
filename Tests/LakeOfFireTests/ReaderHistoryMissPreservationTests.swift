import XCTest
import RealmSwift
import RealmSwiftGaps
@testable import LakeOfFireContent

final class ReaderHistoryMissPreservationTests: XCTestCase {
    @MainActor
    func testCachedMissPreservesLaterCaptureAndVisitRestoresTombstone() async throws {
        let originalBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let originalHistory = ReaderContentLoader.historyRealmConfiguration
        let originalFeed = ReaderContentLoader.feedEntryRealmConfiguration
        let originalProviders = ReaderContentLoader.additionalContentProviders
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = UUID().uuidString
        configuration.objectTypes = [Bookmark.self, HistoryRecord.self, FeedEntry.self, ContentFile.self, MediaTranscript.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        ReaderContentLoader.additionalContentProviders = []
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = originalBookmark
            ReaderContentLoader.historyRealmConfiguration = originalHistory
            ReaderContentLoader.feedEntryRealmConfiguration = originalFeed
            ReaderContentLoader.additionalContentProviders = originalProviders
        }
        await ReaderContentLoader.resetTransientCachesForTesting()
        let url = URL(string: "https://example.com/captured-after-miss")!
        let missingCount = try await { @RealmBackgroundActor in
            try await ReaderContentLoader.loadAll(url: url).count
        }()
        XCTAssertEqual(missingCount, 0)
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let loaderAlias = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: url))
        let record = HistoryRecord()
        record.url = loaderAlias
        record.content = Data("captured body".utf8)
        record.title = "Captured title"
        record.rssContainsFullContent = true
        record.updateCompoundKey()
        let visit = record.lastVisitedAt
        try await realm.asyncWrite { realm.add(record) }
        let loadedContent = try await ReaderContentLoader.load(url: url)
        let loaded = try XCTUnwrap(loadedContent)
        XCTAssertEqual(loaded.compoundKey, record.compoundKey)
        XCTAssertEqual(loaded.content, Data("captured body".utf8))
        XCTAssertEqual(loaded.title, "Captured title")
        XCTAssertTrue(loaded.rssContainsFullContent)
        await realm.asyncRefresh()
        XCTAssertEqual(record.lastVisitedAt, visit)
        try await realm.asyncWrite { record.isDeleted = true }
        await ReaderContentLoader.resetTransientCachesForTesting()
        let tombstoned = try await ReaderContentLoader.load(url: url)
        XCTAssertEqual(tombstoned?.compoundKey, record.compoundKey)
        XCTAssertEqual(tombstoned?.content, Data("captured body".utf8))
        await realm.asyncRefresh()
        XCTAssertTrue(record.isDeleted)
        XCTAssertEqual(record.lastVisitedAt, visit)
        XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
        await ReaderContentLoader.resetTransientCachesForTesting()
        let restored = try await ReaderContentLoader.load(url: url, countsAsHistoryVisit: true)
        XCTAssertEqual(restored?.content, Data("captured body".utf8))
        await realm.asyncRefresh()
        XCTAssertFalse(record.isDeleted)
        XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
    }
}
