import XCTest
@testable import LakeOfFireCore

final class URLInternalTests: XCTestCase {
    func testReaderLoaderFragmentResolvesAgainstOriginalArticle() throws {
        let original = try XCTUnwrap(URL(string: "https://example.com/a%2Fb?next=x%26y#old"))
        let encoded = try XCTUnwrap(original.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let loader = try XCTUnwrap(URL(string: "internal://local/load/reader?reader-url=\(encoded)#next"))

        XCTAssertEqual(
            loader.readerLoaderContentURL?.absoluteString,
            "https://example.com/a%2Fb?next=x%26y#next"
        )
        XCTAssertEqual(
            loader.removingFragmentIfNeeded().readerLoaderContentURL,
            original
        )
    }

    func testReaderLoaderRejectsMalformedAndUnexpectedDestinations() throws {
        let cases = [
            "internal://local/load/reader?reader-url=javascript%3Aalert%281%29",
            "internal://local/load/reader?reader-url=data%3Atext%2Fhtml%2Ctest",
            "internal://local/load/reader?reader-url=internal%3A%2F%2Flocal%2Fload%2Freader",
            "internal://local/load/reader?reader-url=https%3A%2F%2Fexample.com&reader-url=https%3A%2F%2Fother.com",
            "internal://local/load/reader?other=reader-url%3Dhttps%3A%2F%2Fexample.com",
            "internal://local/load/reader?reader-url=%2Frelative%2Fpath",
        ]
        for value in cases {
            let loader = try XCTUnwrap(URL(string: value))
            XCTAssertNil(loader.readerLoaderContentURL, value)
            XCTAssertNil(loader.snippetKey, value)
        }
    }

    func testReaderLoaderSnippetKeyPreservesEscapedReservedCharacters() throws {
        let snippetURL = try XCTUnwrap(URL(
            string: "internal://local/snippet?key=alpha%252Fbeta%2523gamma"
        ))
        let encodedSnippetURL = try XCTUnwrap(
            snippetURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let loaderURL = try XCTUnwrap(URL(
            string: "internal://local/load/reader?reader-url=\(encodedSnippetURL)"
        ))

        XCTAssertEqual(snippetURL.snippetKey, "alpha%2Fbeta%23gamma")
        XCTAssertEqual(loaderURL.snippetKey, snippetURL.snippetKey)
    }

    func testReaderLoaderSnippetKeySupportsLegacyDoubleEncoding() throws {
        let snippetURL = try XCTUnwrap(URL(
            string: "internal://local/snippet?key=alpha%252Fbeta"
        ))
        let encodedSnippetURL = try XCTUnwrap(
            snippetURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let doubleEncodedSnippetURL = try XCTUnwrap(
            encodedSnippetURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let loaderURL = try XCTUnwrap(URL(
            string: "internal://local/load/reader?reader-url=\(doubleEncodedSnippetURL)"
        ))

        XCTAssertEqual(loaderURL.snippetKey, snippetURL.snippetKey)
    }
}

