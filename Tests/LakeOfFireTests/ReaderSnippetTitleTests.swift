import XCTest
import RealmSwift
import RealmSwiftGaps
@testable import LakeOfFire

final class ReaderSnippetTitleTests: XCTestCase {
    private func makeInMemoryConfiguration(name: String = UUID().uuidString) -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: name)
        configuration.objectTypes = [Bookmark.self, HistoryRecord.self, FeedEntry.self]
        return configuration
    }

    private var snippetHTML: String {
        ReaderContentLoader.snippetHTML(fromRawText: """
        Updated via Snippet Helper

        This snippet body gives the generated title enough content to truncate.

        - First bullet.
        - Second bullet.
        """)
    }

    private var updatedSnippetHTML: String {
        ReaderContentLoader.snippetHTML(fromRawText: """
        Updated after editing the snippet content

        The content changed, so the auto-generated title should change too.

        - Replacement bullet.
        - Another replacement bullet.
        """)
    }

    private func withSnippetRealm<T>(
        _ body: @escaping (Realm.Configuration) async throws -> T
    ) async throws -> T {
        let configuration = makeInMemoryConfiguration()
        let previousBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        let previousFeedConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmarkConfiguration
            ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeedConfiguration
        }
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        return try await body(configuration)
    }

    @MainActor
    func testLoadHTMLCreatesSnippetWithGeneratedTitleAndPrefixFlag() async throws {
        try await withSnippetRealm { _ in
            let content = try XCTUnwrap(try await ReaderContentLoader.load(html: snippetHTML))
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
        try await withSnippetRealm { _ in
            let content = try XCTUnwrap(try await ReaderContentLoader.load(html: snippetHTML))
            let originalURL = content.url

            XCTAssertTrue(
                try await ReaderContentLoader.updateSnippetContent(
                    contentURL: originalURL,
                    title: content.title,
                    html: updatedSnippetHTML
                )
            )

            let reloadedContent = try XCTUnwrap(
                try await ReaderContentLoader.load(
                    url: originalURL,
                    persist: false,
                    countsAsHistoryVisit: false
                )
            )
            XCTAssertEqual(
                reloadedContent.title,
                ReaderContentLoader.generatedSnippetTitle(fromSourceHTML: updatedSnippetHTML)
            )
            XCTAssertTrue(reloadedContent.isTitlePrefixOfContent)
        }
    }

    @MainActor
    func testUpdateSnippetContentPreservesManualTitlesAndClearsPrefixFlag() async throws {
        try await withSnippetRealm { _ in
            let content = try XCTUnwrap(try await ReaderContentLoader.load(html: snippetHTML))
            let originalURL = content.url

            XCTAssertTrue(
                try await ReaderContentLoader.updateSnippetContent(
                    contentURL: originalURL,
                    title: "Manual Snippet Title",
                    html: updatedSnippetHTML
                )
            )

            let reloadedContent = try XCTUnwrap(
                try await ReaderContentLoader.load(
                    url: originalURL,
                    persist: false,
                    countsAsHistoryVisit: false
                )
            )
            XCTAssertEqual(reloadedContent.title, "Manual Snippet Title")
            XCTAssertFalse(reloadedContent.isTitlePrefixOfContent)
        }
    }

    @MainActor
    func testReaderContentUsesSnippetChromeTitleOnlyForPrefixTitles() async throws {
        try await withSnippetRealm { _ in
            let autoTitledContent = try XCTUnwrap(try await ReaderContentLoader.load(html: snippetHTML))

            let readerContent = ReaderContent()
            readerContent.content = autoTitledContent
            readerContent.pageURL = autoTitledContent.url

            XCTAssertEqual(readerContent.locationBarTitle, autoTitledContent.defaultSnippetChromeTitle)
            XCTAssertTrue(readerContent.snippetTitleIsGeneratedFromPrefix)

            XCTAssertTrue(
                try await ReaderContentLoader.updateSnippetContent(
                    contentURL: autoTitledContent.url,
                    title: "Manual Snippet Title",
                    html: snippetHTML
                )
            )
            let manualContent = try XCTUnwrap(
                try await ReaderContentLoader.load(
                    url: autoTitledContent.url,
                    persist: false,
                    countsAsHistoryVisit: false
                )
            )

            readerContent.content = manualContent
            readerContent.pageURL = manualContent.url

            XCTAssertEqual(readerContent.locationBarTitle, "Manual Snippet Title")
            XCTAssertFalse(readerContent.snippetTitleIsGeneratedFromPrefix)
        }
    }

    @MainActor
    func testAddBookmarkCopiesSnippetPrefixFlag() async throws {
        try await withSnippetRealm { configuration in
            let content = try XCTUnwrap(try await ReaderContentLoader.load(html: snippetHTML))

            try await content.addBookmark(realmConfiguration: configuration)

            let realm = try await Realm(configuration: configuration)
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
