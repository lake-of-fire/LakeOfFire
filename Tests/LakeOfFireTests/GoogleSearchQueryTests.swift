import XCTest
import LakeOfFireContent
@testable import LakeOfFireCore

final class GoogleSearchQueryTests: XCTestCase {
    func testEncodedParameterNamePreservesLiteralPlusAndFormSpaces() throws {
        let url = try XCTUnwrap(URL(string: "https://www.google.com/search?%71=C%2B%2B+%E6%97%A5%E6%9C%AC%E8%AA%9E"))
        XCTAssertEqual(url.googleSearchQuery, "C++ 日本語")
    }

    func testValueIsDecodedOnlyOnceAndIncludesEquals() throws {
        let url = try XCTUnwrap(URL(string: "https://google.co.jp/search?q=a%252Bb=c"))
        XCTAssertEqual(url.googleSearchQuery, "a%2Bb=c")
    }

    func testFirstMatchingParameterWinsIncludingEmptyValue() throws {
        let duplicate = try XCTUnwrap(URL(string: "https://www.google.com/search?%71=first&q=second"))
        let empty = try XCTUnwrap(URL(string: "https://www.google.com/search?q&q=second"))
        XCTAssertEqual(duplicate.googleSearchQuery, "first")
        XCTAssertEqual(empty.googleSearchQuery, "")
    }

    func testMissingParameterAndOtherHostsHaveNoQuery() throws {
        let missing = try XCTUnwrap(URL(string: "https://www.google.com/search?query=example"))
        let otherHost = try XCTUnwrap(URL(string: "https://example.com/search?q=example"))
        XCTAssertNil(missing.googleSearchQuery)
        XCTAssertNil(otherHost.googleSearchQuery)
    }

    func testNamesDecodeOnceAndEncodedSeparatorsStayInsideValues() throws {
        let url = try XCTUnwrap(URL(string: "https://google.co.jp/search?%2571=wrong&%71=a%26b%3Dc&q=ignored"))
        XCTAssertEqual(url.googleSearchQuery, "a&b=c")
    }

    func testBookmarkAndProtocolLocationBarsUseDecodedFirstQuery() throws {
        let bookmark = Bookmark()
        bookmark.url = try XCTUnwrap(URL(string: "https://www.google.com/search?%71=C%2B%2B+%E6%97%A5%E6%9C%AC%E8%AA%9E&q=ignored"))
        bookmark.title = "Captured page title"
        let content: any ReaderContentProtocol = bookmark

        XCTAssertEqual(bookmark.locationBarTitle, "C++ 日本語")
        XCTAssertEqual(content.defaultLocationBarTitle, "C++ 日本語")
        XCTAssertEqual(bookmark.title, "Captured page title")
    }

    func testLocationBarsRetainEmptyFirstQueryAndNonGoogleFallback() throws {
        let bookmark = Bookmark()
        bookmark.url = try XCTUnwrap(URL(string: "https://www.google.com/search?q&q=ignored"))
        XCTAssertEqual(bookmark.locationBarTitle, "")
        XCTAssertEqual(bookmark.defaultLocationBarTitle, "")

        bookmark.url = try XCTUnwrap(URL(string: "https://example.org/search?%71=ignored"))
        XCTAssertEqual(bookmark.locationBarTitle, "example.org")
        XCTAssertEqual(bookmark.defaultLocationBarTitle, "example.org")
    }

}
