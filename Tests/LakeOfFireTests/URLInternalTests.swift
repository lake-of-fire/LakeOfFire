import XCTest
@testable import LakeOfFireCore

final class URLInternalTests: XCTestCase {
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

    func testSnippetKeysRequireExactUnambiguousRoutes() throws {
        let snippet = try XCTUnwrap(URL(string: "internal://local/snippet?key=article%252Fone"))
        let legacy = try XCTUnwrap(URL(string: "about:snippet?key=article%252Fone"))
        XCTAssertTrue(snippet.isSnippetURL)
        XCTAssertEqual(snippet.snippetKey, "article%2Fone")
        XCTAssertEqual(legacy.snippetKey, snippet.snippetKey)
        XCTAssertFalse(legacy.isSnippetURL)

        for value in [
            "internal://local/snippet-extra?key=article%252Fone",
            "internal://local/snippet/?key=article%252Fone",
            "internal://other/snippet?key=article%252Fone",
            "internal://local:443/snippet?key=article%252Fone",
            "internal://user@local/snippet?key=article%252Fone",
            "internal://user:password@local/snippet?key=article%252Fone",
            "internal://local/snippet?other=key%3Darticle%252Fone",
            "internal://local/snippet?key=article%252Fone&other=x",
            "internal://local/snippet?other=x&key=article%252Fone",
            "internal://local/snippet?key=article%252Fone&key=article%252Fone",
            "internal://local/snippet?key=article%252Fone&key=other",
            "internal://local/snippet?key=",
            "internal://local/snippet?key",
            "internal://local/snippet#key=article%252Fone",
            "about:snippet-other?key=article%252Fone",
            "about:snippet#key=article%252Fone",
            "about://local/snippet?key=article%252Fone",
            "https://local/snippet?key=article%252Fone",
        ] {
            let candidate = try XCTUnwrap(URL(string: value))
            XCTAssertNil(candidate.snippetKey, value)
            XCTAssertFalse(candidate.isSnippetURL, value)
        }
    }

    func testSnippetKeysDecodeOnlyTheQueryValueAndPreserveDocumentFragments() throws {
        for (value, expectedKey) in [
            ("internal://local/snippet?key=alpha%2Fbeta%23gamma#section", "alpha/beta#gamma"),
            ("internal://local/snippet?key=alpha%252Fbeta%2523gamma#key=other", "alpha%2Fbeta%23gamma"),
            ("internal://local/snippet?key=%E8%AA%9E%26%3D%3F%2B", "語&=?+"),
            ("about:snippet?key=alpha%252Fbeta%2523gamma#section", "alpha%2Fbeta%23gamma"),
        ] {
            let candidate = try XCTUnwrap(URL(string: value))
            XCTAssertEqual(candidate.snippetKey, expectedKey, value)
        }
    }
}
