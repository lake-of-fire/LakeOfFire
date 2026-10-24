import XCTest
@testable import LakeOfFireCore

final class URLInternalTests: XCTestCase {
    func testReaderContentURLPreservesEscapedSourceURLAndFragment() throws {
        let sourceURL = try XCTUnwrap(URL(
            string: "https://example.com/a%2Fb?query=C%2B%2B&literal=%2523&value=a%26b#part%202"
        ))
        let encoded = try XCTUnwrap(
            sourceURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let loaderURL = try XCTUnwrap(URL(
            string: "internal://local/load/reader?reader-url=\(encoded)"
        ))

        XCTAssertEqual(sourceURL.readerContentURL, sourceURL)
        XCTAssertEqual(loaderURL.readerContentURL, sourceURL)
        XCTAssertEqual(loaderURL.readerLoaderContentURL, sourceURL)
    }

    func testReaderContentURLResolvesNestedLegacyTransportWrappers() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/article?value=a%26b"))
        var loaderURL = sourceURL
        for _ in 0..<3 {
            let encoded = try XCTUnwrap(
                loaderURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            )
            loaderURL = try XCTUnwrap(URL(
                string: "internal://local/load/reader?reader-url=\(encoded)"
            ))
        }

        XCTAssertEqual(loaderURL.readerContentURL, sourceURL)
    }

    func testReaderContentURLRejectsMalformedOrAmbiguousTransportQueries() throws {
        let queries = [
            "",
            "?reader-url",
            "?reader-url=",
            "?reader-url=/relative/article",
            "?reader-url=https%253A%252F%252F",
            "?not-reader-url=https://example.com/wrong",
            "?note=reader-url=https://example.com/wrong",
            "?reader-url=https://example.com/first&reader-url=https://example.com/second",
        ]
        for query in queries {
            let loaderURL = try XCTUnwrap(URL(string: "internal://local/load/reader\(query)"))
            XCTAssertTrue(loaderURL.isReaderURLLoaderURL, query)
            XCTAssertNil(loaderURL.readerLoaderContentURL, query)
            XCTAssertNil(loaderURL.readerContentURL, query)
        }
    }

    func testReaderContentURLRejectsLoaderAuthorityOverrides() throws {
        for authority in ["user@local", "user:password@local", "local:443"] {
            let loaderURL = try XCTUnwrap(URL(
                string: "internal://\(authority)/load/reader?reader-url=https://example.com/article"
            ))
            XCTAssertTrue(loaderURL.isReaderURLLoaderURL)
            XCTAssertNil(loaderURL.readerLoaderContentURL)
            XCTAssertNil(loaderURL.readerContentURL)
        }
    }

    func testReaderContentURLRecognizesCaseInsensitiveTransportSchemeAndHost() throws {
        let loaderURL = try XCTUnwrap(URL(
            string: "INTERNAL://LOCAL/load/reader?reader-url=https://example.com/article"
        ))

        XCTAssertTrue(loaderURL.isReaderURLLoaderURL)
        XCTAssertEqual(loaderURL.readerContentURL, URL(string: "https://example.com/article"))
    }

    func testReaderContentURLDoesNotDecodeUnrelatedRoutesOrPlainURLs() throws {
        for value in [
            "internal://local/load/reader-other?reader-url=https://example.com/article",
            "https://example.com/load/reader?reader-url=https://example.com/other",
            "reader-file://file/load/local/Documents/article.html",
            "about:blank",
        ] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertFalse(url.isReaderURLLoaderURL)
            XCTAssertNil(url.readerLoaderContentURL)
            XCTAssertEqual(url.readerContentURL, url)
        }
    }

    func testReaderLoaderTransportFragmentTargetsSourceDocument() throws {
        let source = try XCTUnwrap(URL(
            string: "https://example.org/article?title=%E6%97%A5%E6%9C%AC%E8%AA%9E&value=a%26b#original"
        ))
        let encoded = try XCTUnwrap(
            source.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let loader = try XCTUnwrap(URL(
            string: "internal://local/load/reader?reader-url=\(encoded)#next"
        ))

        XCTAssertEqual(loader.readerContentURL,
                       URL(string: "https://example.org/article?title=%E6%97%A5%E6%9C%AC%E8%AA%9E&value=a%26b#next"))
    }

    func testReaderLoaderRejectsUnsafeTargetsAndUnexpectedParameters() throws {
        let invalid = [
            "internal://local/load/reader?reader-url=javascript%3Aalert%281%29",
            "internal://local/load/reader?reader-url=data%3Atext%2Fhtml%2Chello",
            "internal://local/load/reader?reader-url=file%3A%2F%2F%2Fprivate%2Fstory.html",
            "internal://local/load/reader?reader-url=reader-file%3Ano-backing-file",
            "internal://local/load/reader?reader-url=reader-file%3A%2F%2Fevil%2Fload%2Flocal%2Fstory.html",
            "internal://local/load/reader?reader-url=reader-file%3A%2F%2Ffile%2Fload%2Funknown%2Fstory.html",
            "internal://local/load/reader?reader-url=reader-file%3A%2F%2Ffile%2Fload%2Flocal%252Fstory.html",
            "internal://local/load/reader?reader-url=reader-file%3A%2F%2Ffile%3A8080%2Fload%2Flocal%2Fstory.html",
            "internal://local/load/reader?reader-url=internal%3A%2F%2Flocal%2Fload%2Freader%3Freader-url%3Djavascript%253Aalert%25281%2529",
            "internal://local/load/reader?reader-url=https%3A%2F%2Fexample.org&source=other",
        ]
        for raw in invalid {
            let loader = try XCTUnwrap(URL(string: raw))
            XCTAssertNil(loader.readerContentURL, raw)
        }
    }

    func testReaderLoaderPreservesLegacyAboutSnippet() throws {
        let legacySnippet = try XCTUnwrap(URL(string: "about:snippet?key=legacy%252Fnote"))
        let encoded = try XCTUnwrap(
            legacySnippet.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let loader = try XCTUnwrap(URL(
            string: "internal://local/load/reader?reader-url=\(encoded)"
        ))

        XCTAssertEqual(loader.readerContentURL, legacySnippet)
        XCTAssertEqual(loader.snippetKey, legacySnippet.snippetKey)
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
