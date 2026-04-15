import XCTest
import RealmSwift
import RealmSwiftGaps
@testable import LakeOfFireContent

final class ReaderSnippetTitleTests: XCTestCase {
    @MainActor
    private func makeRealmConfiguration(name: String = UUID().uuidString) -> Realm.Configuration {
        let realmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("realm")
        addTeardownBlock {
            let sidecarExtensions = ["realm", "realm.lock", "realm.management", "realm.note"]
            for ext in sidecarExtensions {
                try? FileManager.default.removeItem(
                    at: realmURL.deletingPathExtension().appendingPathExtension(ext)
                )
            }
        }
        var configuration = Realm.Configuration(fileURL: realmURL)
        configuration.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self]
        return configuration
    }

    @MainActor
    private func snippetHTML(token: String = "") -> String {
        """
        <article>
            <h1>Updated via Snippet Helper</h1>
            <p>This snippet body is persisted in compressed storage.</p>
            <p>\(token)</p>
        </article>
        """
    }

    @MainActor
    private func withSnippetRealm<T>(
        _ body: @escaping (Realm.Configuration) async throws -> T
    ) async throws -> T {
        let configuration = makeRealmConfiguration()
        let previousBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        let previousFeedConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmarkConfiguration
            ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeedConfiguration
        }
        await ReaderContentLoader.resetTransientCachesForTesting()
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        let result = try await body(configuration)
        await ReaderContentLoader.resetTransientCachesForTesting()
        return result
    }

    @MainActor
    func testLoadHTMLCreatesSnippetWithInternalSnippetURL() async throws {
        let snippetHTML = self.snippetHTML(token: "load-html")
        try await withSnippetRealm { _ in
            let loadedContent = try await ReaderContentLoader.load(html: snippetHTML)
            let content = try XCTUnwrap(loadedContent)
            XCTAssertTrue(content.url.isSnippetURL)
            XCTAssertEqual(ReaderContentLoader.extractHTML(from: content), snippetHTML)
            XCTAssertEqual(
                ReaderContentLoader.readerLoaderURL(for: content.url)?.absoluteString,
                "internal://local/load/reader?reader-url=\(content.url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"
            )
        }
    }

    @MainActor
    func testLoadHTMLReusesPersistedSnippetForSameHTML() async throws {
        let snippetHTML = self.snippetHTML(token: "reuse")
        try await withSnippetRealm { _ in
            let firstLoaded = try await ReaderContentLoader.load(html: snippetHTML)
            let secondLoaded = try await ReaderContentLoader.load(html: snippetHTML)
            let first = try XCTUnwrap(firstLoaded)
            let second = try XCTUnwrap(secondLoaded)

            XCTAssertEqual(first.compoundKey, second.compoundKey)
            XCTAssertEqual(first.url, second.url)
        }
    }

    @MainActor
    func testGetContentURLResolvesReaderLoaderBackToSnippetURL() async throws {
        let snippetHTML = self.snippetHTML(token: "loader-resolution")
        try await withSnippetRealm { _ in
            let loadedContent = try await ReaderContentLoader.load(html: snippetHTML)
            let content = try XCTUnwrap(loadedContent)
            let loaderURL = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: content.url))

            XCTAssertEqual(ReaderContentLoader.getContentURL(fromLoaderURL: loaderURL), content.url)
            XCTAssertEqual(ReaderContentLoader.getContentURL(fromLoaderURL: content.url), content.url)
        }
    }

    @MainActor
    func testAddBookmarkCopiesSnippetURLAndSnippetLocationBarTitle() async throws {
        let snippetHTML = self.snippetHTML(token: "bookmark-copy")
        try await withSnippetRealm { configuration in
            let content = try await ReaderContentLoader.load(html: snippetHTML)
            let loadedContent = try XCTUnwrap(content)

            try await loadedContent.addBookmark(realmConfiguration: configuration)

            let realm = try await Realm(configuration: configuration)
            await realm.asyncRefresh()
            let bookmark = try XCTUnwrap(
                realm.objects(Bookmark.self)
                    .filter(NSPredicate(format: "url == %@", loadedContent.url.absoluteString))
                    .first
            )
            XCTAssertTrue(bookmark.url.isSnippetURL)
            XCTAssertEqual(ReaderContentLoader.extractHTML(from: bookmark), snippetHTML)
            XCTAssertEqual(bookmark.locationBarTitle, "Snippet: \(bookmark.createdAt.formatted())")
        }
    }
}
