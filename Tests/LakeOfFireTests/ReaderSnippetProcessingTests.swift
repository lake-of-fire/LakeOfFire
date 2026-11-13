import SwiftSoup
import XCTest
@testable import LakeOfFireReader

final class ReaderSnippetProcessingTests: XCTestCase {
    func testCanonicalRebuildPreservesPublicationDateAsLiteralText() throws {
        for date in [
            "22 October 2026",
            #"<span id="date-injected">not a date</span>"#,
            #"<img src="missing" onerror="dateProbe=1">invalid"#,
            "unknown & pending <time>"
        ] {
            let sourceURL = try XCTUnwrap(URL(string: "https://reader.example/article"))
            let source = buildCanonicalReadabilityHTML(
                title: "Captured article",
                byline: "Author",
                publishedTime: date,
                content: "<p>The captured article body.</p>",
                contentURL: sourceURL
            )
            let rebuilt = try XCTUnwrap(buildSnippetCanonicalReadabilityHTML(
                html: source,
                contentURL: sourceURL,
                fallbackTitle: nil
            ))
            let document = try SwiftSoup.parse(rebuilt)
            let label = try XCTUnwrap(document.getElementById("reader-publication-date"))
            XCTAssertEqual(try label.text(trimAndNormaliseWhitespace: false), date)
            XCTAssertEqual(label.children().count, 0)
            XCTAssertNil(try document.getElementById("date-injected"))
            XCTAssertEqual(try document.getElementById("reader-title")?.text(), "Captured article")
            XCTAssertEqual(try document.getElementById("reader-byline")?.text(), "Author")
            XCTAssertEqual(try document.getElementById("reader-content")?.text(), "The captured article body.")

            // This existing selected-target builder already supplies View Original.
            let originals = try document.getElementsByClass("reader-view-original")
            XCTAssertEqual(originals.count, 1)
            XCTAssertEqual(try originals.first()?.attr("href"), sourceURL.absoluteString)
        }
    }

    func testCanonicalRebuildPreservesExplicitDatePrecedenceAndMissingDate() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://reader.example/article"))
        for (embedded, supplied, expected) in [
            ("captured date", "replacement date", "replacement date"),
            ("captured date", "  ", "captured date"),
            (nil, "fallback date", "fallback date"),
            (nil, nil, nil),
            ("  ", nil, nil)
        ] as [(String?, String?, String?)] {
            let source = buildCanonicalReadabilityHTML(
                title: "Captured article",
                byline: "",
                publishedTime: embedded,
                content: "<p>The captured article body.</p>",
                contentURL: sourceURL
            )
            let rebuilt = try XCTUnwrap(buildSnippetCanonicalReadabilityHTML(
                html: source,
                contentURL: sourceURL,
                fallbackTitle: nil,
                publishedTime: supplied
            ))
            let document = try SwiftSoup.parse(rebuilt)
            let label = try document.getElementById("reader-publication-date")
            XCTAssertEqual(try label?.text(trimAndNormaliseWhitespace: false), expected)
            XCTAssertEqual(try document.getElementsByClass("reader-view-original").count, 1)
        }
    }

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
