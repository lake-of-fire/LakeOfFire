import XCTest

final class SmokeSummaryTestSupportTests: XCTestCase {
    func testExtractSmokeSummaryParsesNestedJSONAndEscapedQuotes() throws {
        let output = """
        [EbookRendererHarness] boot
        smoke.summary: {"overallSuccess":true,"nested":{"message":"quoted \\\"value\\\"","count":2,"flag":false}}
        [EbookRendererHarness] done
        """

        let summary = try extractSmokeSummary(from: output)

        XCTAssertEqual(smokeSummaryBool(at: ["overallSuccess"], in: summary), true)
        XCTAssertEqual(smokeSummaryString(at: ["nested", "message"], in: summary), "quoted \"value\"")
        XCTAssertEqual(smokeSummaryInt(at: ["nested", "count"], in: summary), 2)
        XCTAssertEqual(smokeSummaryBool(at: ["nested", "flag"], in: summary), false)
    }

    func testExtractSmokeSummaryUsesLastMarkerWhenOutputContainsMultipleSummaries() throws {
        let output = """
        smoke.summary: {"overallSuccess":false,"sequence":1}
        [EbookRendererHarness] retrying
        smoke.summary: {"overallSuccess":true,"sequence":2}
        """

        let summary = try extractSmokeSummary(from: output)

        XCTAssertEqual(smokeSummaryBool(at: ["overallSuccess"], in: summary), true)
        XCTAssertEqual(smokeSummaryInt(at: ["sequence"], in: summary), 2)
    }

    func testExtractSmokeSummaryHandlesBracesInsideJSONStringValues() throws {
        let output = """
        [EbookRendererHarness] boot
        smoke.summary: {"overallSuccess":true,"nested":{"message":"value with { braces } and [brackets]","items":[1,2,3]}}
        [EbookRendererHarness] done
        """

        let summary = try extractSmokeSummary(from: output)

        XCTAssertEqual(smokeSummaryString(at: ["nested", "message"], in: summary), "value with { braces } and [brackets]")
        XCTAssertEqual((smokeSummaryValue(at: ["nested", "items"], in: summary) as? [Int]) ?? [], [1, 2, 3])
    }

    func testSmokeSummaryNumericHelpersCoerceNSNumberValues() {
        let summary: [String: Any] = [
            "nested": [
                "intLike": NSNumber(value: 7),
                "doubleLike": NSNumber(value: 3.5)
            ]
        ]

        XCTAssertEqual(smokeSummaryInt(at: ["nested", "intLike"], in: summary), 7)
        XCTAssertEqual(smokeSummaryNumber(at: ["nested", "doubleLike"], in: summary), 3.5)
    }

    func testSmokeSummaryHelpersReturnNilOrZeroForMissingPaths() {
        let summary: [String: Any] = ["overallSuccess": true]

        XCTAssertNil(smokeSummaryBool(at: ["missing"], in: summary))
        XCTAssertNil(smokeSummaryString(at: ["missing"], in: summary))
        XCTAssertNil(smokeSummaryNumber(at: ["missing"], in: summary))
        XCTAssertEqual(smokeSummaryInt(at: ["missing"], in: summary), 0)
    }
}
