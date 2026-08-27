import XCTest
@testable import LakeOfFireReader

final class ReaderJavascriptMessagesTests: XCTestCase {
    private let pageURL = "https://example.com/article"

    func testReaderModeUnavailableRejectsMissingOrWrongURLFields() {
        XCTAssertNil(
            ReaderModeUnavailableMessage(body: ["windowURL": pageURL])
        )
        XCTAssertNil(
            ReaderModeUnavailableMessage(body: [
                "pageURL": pageURL,
                "windowURL": 42,
            ])
        )
        XCTAssertNotNil(
            ReaderModeUnavailableMessage(body: [
                "pageURL": pageURL,
                "windowURL": pageURL,
            ])
        )
    }

    func testReadabilityParsedRejectsMissingRequiredFieldsWithoutTrapping() {
        let validBody: [String: Any] = [
            "pageURL": pageURL,
            "windowURL": pageURL,
            "title": "Title",
            "byline": "Author",
            "content": "<p>Content</p>",
            "inputHTML": "<html></html>",
        ]
        XCTAssertNotNil(ReadabilityParsedMessage(body: validBody))

        for key in ["pageURL", "windowURL", "title", "byline", "content", "inputHTML"] {
            var malformed = validBody
            malformed.removeValue(forKey: key)
            XCTAssertNil(
                ReadabilityParsedMessage(body: malformed),
                "Missing \(key) must reject the payload"
            )
        }
    }

    func testVideoStatusRejectsMalformedURLFieldsWithoutTrapping() {
        XCTAssertNil(
            VideoStatusMessage(body: ["pageURL": pageURL])
        )
        XCTAssertNil(
            VideoStatusMessage(body: [
                "pageURL": pageURL,
                "windowURL": [pageURL],
            ])
        )
        XCTAssertNotNil(
            VideoStatusMessage(body: [
                "pageURL": pageURL,
                "windowURL": pageURL,
            ])
        )
    }

    func testPageMetadataRejectsMalformedRequiredFieldsWithoutTrapping() {
        let validBody: [String: Any] = [
            "title": "Title",
            "author": "Author",
            "url": pageURL,
        ]
        XCTAssertNotNil(PageMetadataUpdatedMessage(body: validBody))

        for key in ["title", "author", "url"] {
            var malformed = validBody
            malformed[key] = 7
            XCTAssertNil(
                PageMetadataUpdatedMessage(body: malformed),
                "Wrongly typed \(key) must reject the payload"
            )
        }
    }

    func testFractionalCompletionRejectsNonfiniteCompletionAndIgnoresUnsafeIntegers() {
        XCTAssertNil(
            FractionalCompletionMessage(body: [
                "fractionalCompletion": Double.nan,
                "cfi": "epubcfi(/6/2)",
                "reason": "scroll",
            ])
        )

        let message = FractionalCompletionMessage(body: [
            "fractionalCompletion": 0.5,
            "cfi": "epubcfi(/6/2)",
            "reason": "scroll",
            "sectionIndex": Double.infinity,
            "currentPageNumber": -Double.infinity,
            "totalPages": Double.greatestFiniteMagnitude,
            "visibleSegmentCount": 3.9,
            "observedSegmentCount": "7",
        ])
        XCTAssertNotNil(message)
        XCTAssertNil(message?.sectionIndex)
        XCTAssertNil(message?.currentPageNumber)
        XCTAssertNil(message?.totalPages)
        XCTAssertEqual(message?.visibleSegmentCount, 3)
        XCTAssertEqual(message?.observedSegmentCount, 7)
    }
}
