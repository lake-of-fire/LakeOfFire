import Foundation
import XCTest
@testable import LakeOfFireContent

@MainActor
final class ReaderLoaderFragmentSelectionTests: XCTestCase {
    func testLoaderAnchorChangeKeepsSelectionAndUpdatesPublishedPageURL() async throws {
        let original = try XCTUnwrap(URL(string: "https://example.com/article"))
        let loader = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: original))
        let record = HistoryRecord()
        record.url = original
        record.title = "Article"
        record.updateCompoundKey()

        let reader = ReaderContent()
        try await reader.load(url: loader) { requested in
            XCTAssertEqual(requested, loader)
            return record
        }
        let originalSelection = reader.currentSelectionID
        XCTAssertTrue(reader.content === record)
        XCTAssertEqual(reader.pageURL, original)

        let anchorLoader = try XCTUnwrap(URL(string: loader.absoluteString + "#section"))
        try await reader.load(url: anchorLoader) { _ in
            XCTFail("Same-document anchors should not start another content lookup")
            return nil
        }

        XCTAssertEqual(reader.currentSelectionID, originalSelection)
        XCTAssertTrue(reader.content === record)
        XCTAssertEqual(reader.pageURL.absoluteString, "https://example.com/article#section")
        XCTAssertTrue(original.matchesReaderURL(anchorLoader))
        XCTAssertTrue(original.matchesReaderURL(reader.pageURL))
        XCTAssertFalse(original.matchesReaderURL(URL(string: "https://example.com/other#section")))
    }

    func testLoaderAnchorDoesNotReplacePersistedArticleFragment() throws {
        let original = try XCTUnwrap(URL(string: "https://example.com/article#original"))
        let loader = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: original))
        let anchorLoader = try XCTUnwrap(URL(string: loader.absoluteString + "#current"))

        XCTAssertEqual(
            ReaderContentLoader.backingContentURL(fromLoaderURL: anchorLoader),
            original
        )
        XCTAssertEqual(
            ReaderContentLoader.getContentURL(fromLoaderURL: anchorLoader)?.absoluteString,
            "https://example.com/article#current"
        )
    }

    func testLookalikeSnippetRouteCannotInheritStoredSnippetIdentity() throws {
        let snippet = try XCTUnwrap(URL(string: "internal://local/snippet?key=article%252Fone"))
        let wrapper = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: snippet))
        let lookalike = try XCTUnwrap(URL(string:
            "internal://local/snippet-other?key=article%252Fone"))
        let fragmentOnly = try XCTUnwrap(URL(string:
            "internal://local/snippet#key=article%252Fone"))

        XCTAssertTrue(snippet.matchesReaderURL(wrapper))
        XCTAssertFalse(snippet.matchesReaderURL(lookalike))
        XCTAssertFalse(snippet.matchesReaderURL(fragmentOnly))
    }
}
