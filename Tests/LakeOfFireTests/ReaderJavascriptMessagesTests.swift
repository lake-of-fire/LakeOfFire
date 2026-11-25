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

    func testFractionalCompletionRejectsNonfiniteOrNonnumericCompletion() {
        for invalidCompletion: Any in [Double.nan, Double.infinity, NSNumber(value: true), "0.5"] {
            XCTAssertNil(FractionalCompletionMessage(body: [
                "fractionalCompletion": invalidCompletion,
                "cfi": "epubcfi(/6/2)",
                "reason": "scroll",
            ]))
        }
    }

    func testFractionalCompletionRejectsMalformedOptionalMeasurements() {
        let base: [String: Any] = [
            "fractionalCompletion": 0.5,
            "cfi": "epubcfi(/6/2)",
            "reason": "scroll",
        ]
        let integerFields = [
            "sectionIndex", "currentPageNumber", "totalPages", "visibleSegmentCount", "observedSegmentCount",
        ]
        let invalidCounts: [Any] = [
            Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude,
            9_007_199_254_740_992.0, -1, 3.9, "7", NSNumber(value: false),
        ]
        for field in integerFields {
            for count in invalidCounts {
                var body = base
                body[field] = count
                XCTAssertNil(FractionalCompletionMessage(body: body), "\(field) = \(count)")
            }
        }
        for invalidVisibleText: Any in [NSNumber(value: 0), NSNumber(value: 1), "false"] {
            var body = base
            body["hasVisibleJapaneseText"] = invalidVisibleText
            XCTAssertNil(FractionalCompletionMessage(body: body))
        }
    }

    func testFractionalCompletionAcceptsTypedMeasurementsAndNullPageCounts() throws {
        var body: [String: Any] = [
            "fractionalCompletion": NSNumber(value: 0.5),
            "cfi": "epubcfi(/6/2)",
            "reason": "scroll",
            "sectionIndex": NSNumber(value: 0),
            "currentPageNumber": NSNumber(value: 3),
            "totalPages": NSNumber(value: 8),
            "hasVisibleJapaneseText": NSNumber(value: true),
            "visibleSegmentCount": NSNumber(value: 1),
            "observedSegmentCount": NSNumber(value: 2),
        ]
        let paginated = try XCTUnwrap(FractionalCompletionMessage(body: body))
        XCTAssertEqual(paginated.fractionalCompletion, 0.5)
        XCTAssertEqual(paginated.sectionIndex, 0)
        XCTAssertEqual(paginated.currentPageNumber, 3)
        XCTAssertEqual(paginated.totalPages, 8)
        XCTAssertEqual(paginated.hasVisibleJapaneseText, true)
        XCTAssertEqual(paginated.visibleSegmentCount, 1)
        XCTAssertEqual(paginated.observedSegmentCount, 2)
        XCTAssertFalse(paginated.representsKnownBlankViewport)

        body["currentPageNumber"] = NSNull()
        body["totalPages"] = NSNull()
        body["hasVisibleJapaneseText"] = NSNumber(value: false)
        body["visibleSegmentCount"] = NSNumber(value: 0)
        let blank = try XCTUnwrap(FractionalCompletionMessage(body: body))
        XCTAssertNil(blank.currentPageNumber)
        XCTAssertNil(blank.totalPages)
        XCTAssertEqual(blank.hasVisibleJapaneseText, false)
        XCTAssertTrue(blank.representsKnownBlankViewport)

        body["sectionIndex"] = NSNull()
        body["hasVisibleJapaneseText"] = NSNull()
        body["visibleSegmentCount"] = NSNull()
        body["observedSegmentCount"] = NSNull()
        let unmeasured = try XCTUnwrap(FractionalCompletionMessage(body: body))
        XCTAssertNil(unmeasured.sectionIndex)
        XCTAssertNil(unmeasured.hasVisibleJapaneseText)
        XCTAssertNil(unmeasured.visibleSegmentCount)
        XCTAssertNil(unmeasured.observedSegmentCount)
        XCTAssertFalse(unmeasured.representsKnownBlankViewport)
    }

    func testFractionalCompletionAcceptsNumericEndpointsAndSafeIntegerLimit() throws {
        var body: [String: Any] = [
            "fractionalCompletion": NSNumber(value: 0),
            "cfi": "epubcfi(/6/2)",
            "reason": "scroll",
            "visibleSegmentCount": NSNumber(value: 0),
            "observedSegmentCount": NSNumber(value: 0),
        ]
        let start = try XCTUnwrap(FractionalCompletionMessage(body: body))
        XCTAssertEqual(start.fractionalCompletion, 0)
        XCTAssertEqual(start.visibleSegmentCount, 0)
        XCTAssertEqual(start.observedSegmentCount, 0)
        XCTAssertFalse(start.representsKnownBlankViewport)

        body["fractionalCompletion"] = NSNumber(value: 1)
        body["observedSegmentCount"] = NSNumber(value: 9_007_199_254_740_991.0)
        let end = try XCTUnwrap(FractionalCompletionMessage(body: body))
        XCTAssertEqual(end.fractionalCompletion, 1)
        XCTAssertEqual(end.observedSegmentCount, 9_007_199_254_740_991)
        XCTAssertTrue(end.representsKnownBlankViewport)

        body["observedSegmentCount"] = NSNumber(value: 9_007_199_254_740_992.0)
        XCTAssertNil(FractionalCompletionMessage(body: body))
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
