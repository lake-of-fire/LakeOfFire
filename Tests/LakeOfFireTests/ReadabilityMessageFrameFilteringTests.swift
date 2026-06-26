import XCTest
@testable import LakeOfFireReader

final class ReadabilityMessageFrameFilteringTests: XCTestCase {
    func testMainFrameReadabilityMessageCanRepresentTopLevelDocumentEvenWithoutPageURL() {
        XCTAssertTrue(
            readabilityMessageCanRepresentTopLevelDocument(
                pageURL: nil,
                windowURL: URL(string: "https://www.asahi.com/articles/example.html")!,
                isMainFrame: true
            )
        )
    }

    func testSubframeReadabilityMessageCanRepresentTopLevelDocumentWhenURLsMatchIgnoringFragment() {
        XCTAssertTrue(
            readabilityMessageCanRepresentTopLevelDocument(
                pageURL: URL(string: "https://www.asahi.com/articles/example.html#ad")!,
                windowURL: URL(string: "https://www.asahi.com/articles/example.html")!,
                isMainFrame: false
            )
        )
    }

    func testThirdPartySubframeReadabilityMessageCannotRepresentTopLevelDocument() {
        XCTAssertFalse(
            readabilityMessageCanRepresentTopLevelDocument(
                pageURL: URL(string: "https://suumo.jp/ad/unit.html")!,
                windowURL: URL(string: "https://www.asahi.com/articles/example.html")!,
                isMainFrame: false
            )
        )
    }

    func testBlankSubframeReadabilityMessageCannotRepresentTopLevelDocument() {
        XCTAssertFalse(
            readabilityMessageCanRepresentTopLevelDocument(
                pageURL: URL(string: "about:blank"),
                windowURL: URL(string: "https://www.asahi.com/articles/example.html")!,
                isMainFrame: false
            )
        )
    }
}
