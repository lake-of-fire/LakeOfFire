import XCTest
@testable import LakeOfFireCore
@testable import LakeOfFireContent

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

    func testEncodedSeparatorsStayInsideTheDecodedFirstQuery() throws {
        let url = try XCTUnwrap(URL(string: "https://www.google.com/search?%71=a%26b%3Dc&q=second"))
        XCTAssertEqual(url.googleSearchQuery, "a&b=c")
    }

    func testBookmarkAndProtocolLocationBarsUseDecodedFirstQueryWithoutChangingTitle() throws {
        for (value, expected) in [
            ("https://www.google.com/search?%71=C%2B%2B+%E6%97%A5%E6%9C%AC%E8%AA%9E&q=second", "C++ 日本語"),
            ("https://www.google.com/search?q&q=second", ""),
            ("https://example.org/search?q=ignored", "example.org")
        ] {
            let bookmark = Bookmark()
            bookmark.url = try XCTUnwrap(URL(string: value))
            bookmark.title = "Captured article title"
            XCTAssertEqual(bookmark.locationBarTitle, expected, value)
            XCTAssertEqual(bookmark.defaultLocationBarTitle, expected, value)
            XCTAssertEqual(bookmark.title, "Captured article title", value)
        }
    }

    func testMissingParameterAndOtherHostsHaveNoQuery() throws {
        let missing = try XCTUnwrap(URL(string: "https://www.google.com/search?query=example"))
        let otherHost = try XCTUnwrap(URL(string: "https://example.com/search?q=example"))
        XCTAssertNil(missing.googleSearchQuery)
        XCTAssertNil(otherHost.googleSearchQuery)
    }
}
