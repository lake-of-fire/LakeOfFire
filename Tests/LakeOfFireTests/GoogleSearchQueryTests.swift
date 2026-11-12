import XCTest
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
}
