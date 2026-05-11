import XCTest
import RealmSwift
import RealmSwiftGaps
@testable import LakeOfFireContent

final class ReaderSnippetTitleTests: XCTestCase {
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

    private func snippetHTML(token: String = "") -> String {
        ReaderContentLoader.snippetHTML(fromRawText: """
        Updated via Snippet Helper

        This snippet body gives the generated title enough content to truncate.

        - First bullet.
        - Second bullet.
        \(token)
        """)
    }

    private func updatedSnippetHTML(token: String = "") -> String {
        ReaderContentLoader.snippetHTML(fromRawText: """
        Updated after editing the snippet content

        The content changed, so the auto-generated title should change too.

        - Replacement bullet.
        - Another replacement bullet.
        \(token)
        """)
    }

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
    func testLoadHTMLCreatesSnippetWithGeneratedTitleAndPrefixFlag() async throws {
        let snippetHTML = self.snippetHTML(token: "load-html")
        try await withSnippetRealm { _ in
            let loadedContent = try await ReaderContentLoader.load(html: snippetHTML)
            let content = try XCTUnwrap(loadedContent)
            XCTAssertTrue(content.url.isSnippetURL)
            XCTAssertEqual(
                content.title,
                ReaderContentLoader.generatedSnippetTitle(fromSourceHTML: snippetHTML)
            )
            XCTAssertTrue(content.isTitlePrefixOfContent)
        }
    }

    @MainActor
    func testUpdateSnippetContentAutoRetitlesGeneratedTitles() async throws {
        let snippetHTML = self.snippetHTML(token: "auto-retitle")
        let updatedSnippetHTML = self.updatedSnippetHTML(token: "auto-retitle")
        try await withSnippetRealm { _ in
            let loadedContent = try await ReaderContentLoader.load(html: snippetHTML)
            let content = try XCTUnwrap(loadedContent)
            let originalURL = content.url

            let didUpdate = try await ReaderContentLoader.updateSnippetContent(
                contentURL: originalURL,
                title: content.title,
                html: updatedSnippetHTML
            )
            XCTAssertTrue(didUpdate)

            let reloaded = try await ReaderContentLoader.load(
                url: originalURL,
                persist: false,
                countsAsHistoryVisit: false
            )
            let reloadedContent = try XCTUnwrap(reloaded)
            XCTAssertEqual(
                reloadedContent.title,
                ReaderContentLoader.generatedSnippetTitle(fromSourceHTML: updatedSnippetHTML)
            )
            XCTAssertTrue(reloadedContent.isTitlePrefixOfContent)
        }
    }

    @MainActor
    func testUpdateSnippetContentPreservesManualTitlesAndClearsPrefixFlag() async throws {
        let snippetHTML = self.snippetHTML(token: "manual-title")
        let updatedSnippetHTML = self.updatedSnippetHTML(token: "manual-title")
        try await withSnippetRealm { _ in
            let loadedContent = try await ReaderContentLoader.load(html: snippetHTML)
            let content = try XCTUnwrap(loadedContent)
            let originalURL = content.url

            let didUpdate = try await ReaderContentLoader.updateSnippetContent(
                contentURL: originalURL,
                title: "Manual Snippet Title",
                html: updatedSnippetHTML
            )
            XCTAssertTrue(didUpdate)

            let reloaded = try await ReaderContentLoader.load(
                url: originalURL,
                persist: false,
                countsAsHistoryVisit: false
            )
            let reloadedContent = try XCTUnwrap(reloaded)
            XCTAssertEqual(reloadedContent.title, "Manual Snippet Title")
            XCTAssertFalse(reloadedContent.isTitlePrefixOfContent)
        }
    }

    @MainActor
    func testReaderContentUsesSnippetChromeTitleOnlyForPrefixTitles() async throws {
        let snippetHTML = self.snippetHTML(token: "chrome-title")
        try await withSnippetRealm { _ in
            let loadedContent = try await ReaderContentLoader.load(html: snippetHTML)
            let autoTitledContent = try XCTUnwrap(loadedContent)

            let readerContent = ReaderContent()
            readerContent.content = autoTitledContent
            readerContent.pageURL = autoTitledContent.url

            XCTAssertEqual(readerContent.locationBarTitle, autoTitledContent.defaultSnippetChromeTitle)
            XCTAssertTrue(readerContent.snippetTitleIsGeneratedFromPrefix)

            let didUpdate = try await ReaderContentLoader.updateSnippetContent(
                contentURL: autoTitledContent.url,
                title: "Manual Snippet Title",
                html: snippetHTML
            )
            XCTAssertTrue(didUpdate)
            let reloaded = try await ReaderContentLoader.load(
                url: autoTitledContent.url,
                persist: false,
                countsAsHistoryVisit: false
            )
            let manualContent = try XCTUnwrap(reloaded)

            readerContent.content = manualContent
            readerContent.pageURL = manualContent.url

            XCTAssertEqual(readerContent.locationBarTitle, "Manual Snippet Title")
            XCTAssertFalse(readerContent.snippetTitleIsGeneratedFromPrefix)
        }
    }

    @MainActor
    func testAddBookmarkCopiesSnippetPrefixFlag() async throws {
        let snippetHTML = self.snippetHTML(token: "bookmark-copy")
        try await withSnippetRealm { configuration in
            let loadedContent = try await ReaderContentLoader.load(html: snippetHTML)
            let content = try XCTUnwrap(loadedContent)

            try await content.addBookmark(realmConfiguration: configuration)

            let realm = try await Realm(configuration: configuration)
            try await realm.asyncRefresh()
            let bookmark = try XCTUnwrap(
                realm.objects(Bookmark.self)
                    .filter(NSPredicate(format: "url == %@", content.url.absoluteString))
                    .first
            )
            XCTAssertTrue(bookmark.isTitlePrefixOfContent)
            XCTAssertEqual(bookmark.locationBarTitle, bookmark.defaultSnippetChromeTitle)
        }
    }
}
