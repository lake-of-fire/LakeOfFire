import XCTest
import RealmSwift
import RealmSwiftGaps
@testable import LakeOfFireContent
@testable import LakeOfFireCore

@objc(LakeOfFireTestsExternalBookContent)
private final class ExternalBookContent: Bookmark {
    @Persisted var externalHTML: String?

    override var locationBarTitle: String? {
        title
    }

    func htmlToDisplay(readerFileManager: ReaderFileManager) async throws -> String? {
        externalHTML
    }

    var hasHTML: Bool {
        externalHTML?.isEmpty == false
    }

    var bookmarkInlineHTML: String? { nil }
    var bookmarkInlineContent: Data? { nil }
    var historyInlineContent: Data? { nil }
}

final class ReaderContentLoaderAdditionalProviderTests: XCTestCase {
    @RealmBackgroundActor
    private static func updateProviderBookTitle(contentURL: URL) async throws {
        try await ReaderContentLoader.updateContent(url: contentURL) { object in
            object.title = "Updated Provider Book"
            return true
        }
    }

    private func makeConfiguration() throws -> (Realm.Configuration, () -> Void) {
        let originalBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        let originalHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        let originalFeedEntryConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        let originalAdditionalProviders = ReaderContentLoader.additionalContentProviders
        let originalInlineHTMLAnalysisEnqueuer = ReaderContentBackgroundAnalysisLoader.inlineHTMLAnalysisEnqueuer
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LakeOfFireAdditionalProvider-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var configuration = Realm.Configuration()
        configuration.fileURL = directoryURL.appendingPathComponent("reader-content.realm")
        configuration.schemaVersion = 1
        configuration.deleteRealmIfMigrationNeeded = true
        configuration.objectTypes = [
            Bookmark.self,
            ContentFile.self,
            HistoryRecord.self,
            FeedEntry.self,
            MediaTranscript.self,
            ExternalBookContent.self,
        ]
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        ReaderContentLoader.additionalContentProviders = []

        return (
            configuration,
            {
                ReaderContentLoader.bookmarkRealmConfiguration = originalBookmarkConfiguration
                ReaderContentLoader.historyRealmConfiguration = originalHistoryConfiguration
                ReaderContentLoader.feedEntryRealmConfiguration = originalFeedEntryConfiguration
                ReaderContentLoader.additionalContentProviders = originalAdditionalProviders
                ReaderContentBackgroundAnalysisLoader.inlineHTMLAnalysisEnqueuer = originalInlineHTMLAnalysisEnqueuer
                try? FileManager.default.removeItem(at: directoryURL)
            }
        )
    }

    private actor InlineHTMLAnalysisRecorder {
        struct Event: Sendable {
            let url: URL
            let imageURL: URL?
            let title: String?
            let html: String
        }

        private(set) var events = [Event]()

        func append(url: URL, imageURL: URL?, title: String?, html: String) {
            events.append(.init(url: url, imageURL: imageURL, title: title, html: html))
        }
    }

    @MainActor
    func testAdditionalProviderParticipatesInLookupAndLoaderRouting() async throws {
        let (configuration, restore) = try makeConfiguration()
        defer { restore() }
        await ReaderContentLoader.resetTransientCachesForTesting()

        let contentURL = try XCTUnwrap(URL(string: "ttsu:///book/provider-test"))
        let loaderURL = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: contentURL))

        let realm = try await Realm(configuration: configuration)
        try realm.write {
            let content = ExternalBookContent()
            content.url = contentURL
            content.title = "Provider Test Book"
            content.externalHTML = "<html><body><p>Provider Book</p></body></html>"
            content.updateCompoundKey()
            realm.add(content, update: .modified)
        }

        ReaderContentLoader.registerAdditionalContentProvider(
            .init(id: "external-book-test") { url in
                try await MainActor.run {
                    let realm = try Realm(configuration: configuration)
                    guard let content = ExternalBookContent.get(forURL: url, realm: realm),
                          let reference = ReaderContentLoader.ContentReference(content: content) else {
                        return []
                    }
                    return [reference]
                }
            }
        )

        let loadedAll = try await ReaderContentLoader.loadAll(url: contentURL)
        XCTAssertEqual(loadedAll.count, 1)
        XCTAssertTrue(loadedAll.first is ExternalBookContent)

        let lookedUp = try await ReaderContentLoader.lookupStoredContent(url: loaderURL)
        XCTAssertTrue(lookedUp is ExternalBookContent)
        XCTAssertTrue(contentURL.matchesReaderURL(loaderURL))

        let navigationURL = try await ReaderContentLoader.load(
            content: try XCTUnwrap(lookedUp),
            readerFileManager: .shared
        )
        XCTAssertEqual(navigationURL, loaderURL)

        try await Self.updateProviderBookTitle(contentURL: contentURL)

        let updated = try await ReaderContentLoader.lookupStoredContent(url: contentURL) as? ExternalBookContent
        XCTAssertEqual(updated?.title, "Updated Provider Book")
    }

    @MainActor
    func testCustomPayloadHooksKeepBookmarksAndHistoryLightweight() async throws {
        let (configuration, restore) = try makeConfiguration()
        defer { restore() }
        await ReaderContentLoader.resetTransientCachesForTesting()

        let contentURL = try XCTUnwrap(URL(string: "ttsu:///book/lightweight"))
        let realm = try await Realm(configuration: configuration)
        let content = ExternalBookContent()
        content.url = contentURL
        content.title = "Lightweight"
        content.externalHTML = "<html><body><p>Do not inline this</p></body></html>"
        content.updateCompoundKey()

        try realm.write {
            realm.add(content, update: .modified)
        }

        let managedContent = try XCTUnwrap(realm.object(ofType: ExternalBookContent.self, forPrimaryKey: content.compoundKey))
        let threadSafeContent = managedContent.freeze()
        try await threadSafeContent.addBookmark(realmConfiguration: configuration)
        _ = try await threadSafeContent.addHistoryRecord(realmConfiguration: configuration, pageURL: contentURL)

        let verificationRealm = try await Realm(configuration: configuration)
        verificationRealm.refresh()
        let bookmark = try XCTUnwrap(Bookmark.get(forURL: contentURL, realm: verificationRealm))
        XCTAssertNil(bookmark.html)
        XCTAssertNil(bookmark.content)
        let historyContentIsNil = try await Self.historyRecordContentIsNil(configuration: configuration, url: contentURL)
        XCTAssertTrue(historyContentIsNil)
    }

    @MainActor
    func testBookmarkAndHistoryCreationEnqueueInlineHTMLAnalysis() async throws {
        let (configuration, restore) = try makeConfiguration()
        defer { restore() }
        await ReaderContentLoader.resetTransientCachesForTesting()

        let recorder = InlineHTMLAnalysisRecorder()
        ReaderContentBackgroundAnalysisLoader.inlineHTMLAnalysisEnqueuer = { url, imageURL, title, html in
            await recorder.append(url: url, imageURL: imageURL, title: title, html: html)
        }

        let contentURL = try XCTUnwrap(URL(string: "https://example.com/article"))
        let imageURL = try XCTUnwrap(URL(string: "https://example.com/image.jpg"))
        let html = "<html><body><mnb-seg>本文</mnb-seg></body></html>"
        let realm = try await Realm(configuration: configuration)
        let content = Bookmark()
        content.url = contentURL
        content.title = "Inline Analysis"
        content.imageUrl = imageURL
        content.html = html
        content.rssContainsFullContent = true
        content.updateCompoundKey()

        try realm.write {
            realm.add(content, update: .modified)
        }

        let managedContent = try XCTUnwrap(realm.object(ofType: Bookmark.self, forPrimaryKey: content.compoundKey))
        let threadSafeContent = managedContent.freeze()
        try await threadSafeContent.addBookmark(realmConfiguration: configuration)
        _ = try await threadSafeContent.addHistoryRecord(realmConfiguration: configuration, pageURL: contentURL)

        let events = await recorder.events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.url), [contentURL, contentURL])
        XCTAssertEqual(events.map(\.imageURL), [imageURL, imageURL])
        XCTAssertEqual(events.map(\.title), ["Inline Analysis", "Inline Analysis"])
        XCTAssertTrue(events.allSatisfy { $0.html == html })
    }

    @RealmBackgroundActor
    private static func historyRecordContentIsNil(configuration: Realm.Configuration, url: URL) async throws -> Bool {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        guard let history = HistoryRecord.get(forURL: url, realm: realm) else {
            return false
        }
        return history.content == nil
    }
}
