import XCTest
import RealmSwift
@testable import LakeOfFireContent
@testable import LakeOfFireCore

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
    private func makeConfiguration() throws -> (Realm.Configuration, () -> Void) {
        let originalBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        let originalHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        let originalFeedEntryConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        let originalAdditionalProviders = ReaderContentLoader.additionalContentProviders
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LakeOfFireAdditionalProvider-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var configuration = Realm.Configuration()
        configuration.fileURL = directoryURL.appendingPathComponent("reader-content.realm")
        configuration.schemaVersion = 1
        configuration.deleteRealmIfMigrationNeeded = true
        configuration.objectTypes = [
            Bookmark.self,
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
                try? FileManager.default.removeItem(at: directoryURL)
            }
        )
    }

    @MainActor
    func testAdditionalProviderParticipatesInLookupAndLoaderRouting() async throws {
        let (configuration, restore) = try makeConfiguration()
        defer { restore() }
        await ReaderContentLoader.resetTransientCachesForTesting()

        let contentURL = try XCTUnwrap(URL(string: "ttsu:///book/provider-test"))
        let loaderURL = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: contentURL))

        let realm = try Realm(configuration: configuration)
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
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                await realm.asyncRefresh()
                guard let content = ExternalBookContent.get(forURL: url, realm: realm),
                      let reference = ReaderContentLoader.ContentReference(content: content) else {
                    return []
                }
                return [reference]
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

        try await { @RealmBackgroundActor in
            try await ReaderContentLoader.updateContent(url: contentURL) { object in
                object.title = "Updated Provider Book"
                return true
            }
        }()

        let updated = try await ReaderContentLoader.lookupStoredContent(url: contentURL) as? ExternalBookContent
        XCTAssertEqual(updated?.title, "Updated Provider Book")
    }

    @MainActor
    func testCustomPayloadHooksKeepBookmarksAndHistoryLightweight() async throws {
        let (configuration, restore) = try makeConfiguration()
        defer { restore() }
        await ReaderContentLoader.resetTransientCachesForTesting()

        let contentURL = try XCTUnwrap(URL(string: "ttsu:///book/lightweight"))
        let realm = try Realm(configuration: configuration)
        let content = ExternalBookContent()
        content.url = contentURL
        content.title = "Lightweight"
        content.externalHTML = "<html><body><p>Do not inline this</p></body></html>"
        content.updateCompoundKey()

        try realm.write {
            realm.add(content, update: .modified)
        }

        let managedContent = try XCTUnwrap(realm.object(ofType: ExternalBookContent.self, forPrimaryKey: content.compoundKey))
        try await managedContent.addBookmark(realmConfiguration: configuration)
        let history = try await managedContent.addHistoryRecord(realmConfiguration: configuration, pageURL: contentURL)

        let bookmark = try XCTUnwrap(Bookmark.get(forURL: contentURL, realm: realm))
        XCTAssertNil(bookmark.html)
        XCTAssertNil(bookmark.content)
        XCTAssertNil(history.content)
    }
}
