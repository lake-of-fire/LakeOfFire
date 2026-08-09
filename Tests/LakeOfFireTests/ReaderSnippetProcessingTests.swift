import SwiftSoup
import XCTest
@testable import LakeOfFireReader

final class ReaderSnippetProcessingTests: XCTestCase {
    func testDirectSnippetFastPathRequiresPublishedCompactMetadata() {
        let canonicalOnly = """
        <html><body class="readability-mode"><article id="reader-content">日本語</article></body></html>
        """
        let segmentsWithoutSidecar = """
        <html><body class="readability-mode"><article id="reader-content"><m-m>日本語</m-m></article></body></html>
        """
        let published = """
        <html><body class="readability-mode"><article id="reader-content"><m-m>日本語</m-m></article>
        <script id="mnb-segment-metadata" type="application/json" data-mnb-seg-meta="true">{}</script>
        </body></html>
        """

        XCTAssertFalse(hasPublishedReaderSegmentMetadataMarkup(in: canonicalOnly))
        XCTAssertFalse(hasPublishedReaderSegmentMetadataMarkup(in: segmentsWithoutSidecar))
        XCTAssertTrue(hasPublishedReaderSegmentMetadataMarkup(in: published))
    }

    func testProcessForReaderModePromotesPersistedSnippetWrapper() throws {
        let document = try SwiftSoup.parse(
            """
            <html>
                <body>
                    <div class="mnb-snippet"><p>日本語の本文です。</p></div>
                </body>
            </html>
            """
        )

        try processForReaderMode(
            doc: document,
            url: URL(string: "internal://local/snippet/regression")!,
            contentSectionLocationIdentifier: nil,
            isEBook: false,
            isCacheWarmer: true,
            defaultTitle: nil,
            imageURL: nil,
            injectEntryImageIntoHeader: false,
            defaultFontSize: 16
        )

        let readerContent = try XCTUnwrap(document.getElementById("reader-content"))
        XCTAssertFalse(readerContent.hasClass("mnb-snippet"))
        XCTAssertEqual(try readerContent.text(), "日本語の本文です。")
    }
}
