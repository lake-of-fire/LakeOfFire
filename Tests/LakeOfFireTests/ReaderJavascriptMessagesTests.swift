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

    func testFractionalCompletionBoundsDurablePositionInputs() throws {
        let valid = try XCTUnwrap(FractionalCompletionMessage(body: [
            "fractionalCompletion": 0.5,
            "cfi": "epubcfi(/6/2)",
            "reason": "scroll",
            "mainDocumentURL": pageURL,
            "documentStartedAtMs": 1234.5,
        ]))
        XCTAssertEqual(valid.documentStartedAtMilliseconds, 1234.5)

        for invalidCompletion in [-0.1, 1.1] {
            XCTAssertNil(FractionalCompletionMessage(body: [
                "fractionalCompletion": invalidCompletion,
                "cfi": "epubcfi(/6/2)",
                "reason": "scroll",
            ]))
        }

        for invalidTimestamp: Any in [NSNumber(value: true), Double.infinity] {
            XCTAssertNil(FractionalCompletionMessage(body: [
                "fractionalCompletion": 0.5,
                "cfi": "epubcfi(/6/2)",
                "reason": "scroll",
                "documentStartedAtMs": invalidTimestamp,
            ]))
        }

        XCTAssertNil(FractionalCompletionMessage(body: [
            "fractionalCompletion": 0.5,
            "cfi": String(
                repeating: "x",
                count: FractionalCompletionMessage.maximumCFIUTF8Bytes + 1
            ),
            "reason": "scroll",
        ]))
    }
}
