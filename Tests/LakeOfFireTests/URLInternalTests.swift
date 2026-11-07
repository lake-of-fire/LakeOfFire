import XCTest
@testable import LakeOfFireCore

final class URLInternalTests: XCTestCase {
    func testReaderLoaderFragmentPreservesEscapedReservedCharacters() throws {
        let source = try XCTUnwrap(URL(string: "https://example.org/article#old"))
        var loader = try XCTUnwrap(URLComponents(string: "internal://local/load/reader"))
        loader.queryItems = [URLQueryItem(name: "reader-url", value: source.absoluteString)]
        loader.percentEncodedFragment = "section%2Ftwo%2523tail"
        XCTAssertEqual(try XCTUnwrap(loader.url).readerContentURL?.absoluteString,
                       "https://example.org/article#section%2Ftwo%2523tail")
    }

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
            // The canonical resolver validates the complete nested destination;
            // readerLoaderContentURL intentionally unwraps only one layer.
            XCTAssertNil(loader.readerContentURL, value)
            XCTAssertNil(loader.snippetKey, value)
        }
    }

    func testReaderLoaderRoundTripsSourceQueryFragmentAndEscapedUnicode() throws {
        let sourceURL = try XCTUnwrap(URL(
            string: "https://example.org/article?title=%E6%97%A5%E6%9C%AC%E8%AA%9E&mode=reader%26notes#start"
        ))
        let encodedSource = try XCTUnwrap(
            sourceURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let loaderURL = try XCTUnwrap(URL(
            string: "internal://local/load/reader?reader-url=\(encodedSource)"
        ))

        XCTAssertTrue(loaderURL.isReaderLoaderTransportURL)
        XCTAssertEqual(loaderURL.readerLoaderContentURL, sourceURL)
        XCTAssertEqual(
            URL(string: loaderURL.absoluteString + "#next")?.readerLoaderContentURL,
            URL(string: "https://example.org/article?title=%E6%97%A5%E6%9C%AC%E8%AA%9E&mode=reader%26notes#next")
        )
    }

    func testReaderLoaderRejectsAmbiguousOrUnsafeTargets() throws {
        let unsafeURLs = [
            "internal://local/load/reader?reader-url=javascript%3Aalert%281%29",
            "internal://local/load/reader?reader-url=data%3Atext%2Fhtml%2Chello",
            "internal://local/load/reader?reader-url=file%3A%2F%2F%2Fprivate%2Fstory.html",
            "internal://local/load/reader?reader-url=internal%3A%2F%2Flocal%2Fload%2Freader%3Freader-url%3Djavascript%253Aalert%25281%2529",
            "internal://local/load/reader?reader-url=https%3A%2F%2Fexample.org&reader-url=https%3A%2F%2Fevil.example",
            "internal://local/load/reader?reader-url=https%3A%2F%2Fexample.org&source=other",
        ]
        for string in unsafeURLs {
            let loaderURL = try XCTUnwrap(URL(string: string))
            XCTAssertNil(loaderURL.readerContentURL, string)
        }
    }

    func testReaderLoaderRequiresExactLocalEndpoint() throws {
        let misplacedURLs = [
            "internal://local/load/reader-extra?reader-url=https%3A%2F%2Fexample.org",
            "internal://elsewhere/load/reader?reader-url=https%3A%2F%2Fexample.org",
            "internal://local:123/load/reader?reader-url=https%3A%2F%2Fexample.org",
            "internal://user@local/load/reader?reader-url=https%3A%2F%2Fexample.org",
        ]
        for string in misplacedURLs {
            let candidate = try XCTUnwrap(URL(string: string))
            XCTAssertFalse(candidate.isReaderLoaderTransportURL, string)
            XCTAssertNil(candidate.readerLoaderContentURL, string)
        }
    }

    func testReaderLoaderPreservesLegacyEbookSource() throws {
        let source = try XCTUnwrap(URL(string:
            "ebook://book/chapter%2Fpart.xhtml?literal=%2523#selection"))
        let encoded = try XCTUnwrap(
            source.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let loader = try XCTUnwrap(URL(string:
            "internal://local/load/reader?reader-url=\(encoded)"))

        XCTAssertEqual(loader.readerContentURL, source)
        XCTAssertEqual(loader.readerLoaderContentURL, source)
    }

    func testReaderLoaderPreservesLegacyAboutSnippetSource() throws {
        let legacySnippet = try XCTUnwrap(URL(string: "about:snippet?key=legacy%252Fnote"))
        let encoded = try XCTUnwrap(
            legacySnippet.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let loader = try XCTUnwrap(URL(
            string: "internal://local/load/reader?reader-url=\(encoded)"
        ))

        XCTAssertEqual(loader.readerLoaderContentURL, legacySnippet)
        XCTAssertEqual(loader.snippetKey, legacySnippet.snippetKey)
    }

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
        XCTAssertTrue(snippet.isSnippetURL)
        XCTAssertEqual(snippet.snippetKey, "article%2Fone")
        XCTAssertEqual(
            URL(string: "about:snippet?key=article%252Fone")?.snippetKey,
            snippet.snippetKey
        )

        let wrapped = try XCTUnwrap(URL(string:
            "internal://local/load/reader?reader-url=internal%3A%2F%2Flocal%2Fsnippet%3Fkey%3Darticle%25252Fone"))
        XCTAssertEqual(wrapped.snippetKey, snippet.snippetKey)
        XCTAssertFalse(wrapped.isSnippetURL, "The loader is a transport, not a direct snippet")

        for value in [
            "internal://local/snippet-extra?key=article%252Fone",
            "internal://other/snippet?key=article%252Fone",
            "internal://local:443/snippet?key=article%252Fone",
            "internal://local/snippet?other=key%3Darticle%252Fone",
            "internal://local/snippet?key=article%252Fone&other=x",
            "internal://local/snippet#key=article%252Fone",
            "about:snippet-other?key=article%252Fone",
            "about:snippet#key=article%252Fone",
        ] {
            let candidate = try XCTUnwrap(URL(string: value))
            XCTAssertNil(candidate.snippetKey, value)
            XCTAssertFalse(candidate.isSnippetURL, value)
        }
    }

    func testInternalLoadingRoutesCannotBeStoredAsSourceURLs() throws {
        for value in [
            "internal://local/load/reader?reader-url=https://example.com",
            "INTERNAL://LOCAL/load/unknown",
            "internal://local/LOAD/reader",
            "internal://other/load/reader",
            "internal://local/load",
        ] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertTrue(url.isInternalReaderLoadingURL, value)
        }
        for value in [
            "internal://local/snippet?key=valid",
            "https://example.com/load/reader",
            "ebook://book/load/reader",
        ] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertFalse(url.isInternalReaderLoadingURL, value)
        }
    }
}
