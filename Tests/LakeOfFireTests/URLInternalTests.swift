import XCTest
@testable import LakeOfFireCore
@testable import LakeOfFireContent

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
            "https://example.com/load/reader?reader-url=https://example.com/other",
            "reader-file://file/load/local/Documents/article.html",
            "about:blank",
            "internal://local/manabi-fonts.css?family=Reader",
            "internal://local/reader-sidecar/token",
            "ebook://ebook/load/manabi-fonts.css",
        ] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertFalse(url.isReaderURLLoaderURL)
            XCTAssertNil(url.readerLoaderContentURL)
            XCTAssertEqual(url.readerContentURL, url)
        }
    }

    func testReaderContentURLRejectsPrivateLoadingAliases() throws {
        for value in [
            "internal://other/load/reader?reader-url=https://example.com/article",
            "INTERNAL://LOCAL/LOAD/reader?reader-url=https://example.com/article",
            "internal://local/load/reader-other?reader-url=https://example.com/article",
            "internal://local/load",
        ] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertTrue(url.isInternalReaderLoadingURL, value)
            XCTAssertNil(url.readerContentURL, value)
            XCTAssertNil(ReaderContentLoader.readerLoaderURL(for: url), value)
            XCTAssertNil(ReaderContentLoader.getContentURL(fromLoaderURL: url), value)
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

    func testReaderLoaderBuilderFlattensNestedWrappersAndRoundTripsSourceBytes() throws {
        let source = try XCTUnwrap(URL(string:
            "https://example.com/a%2Fb?query=C%2B%2B&literal=%2523&value=a%26b#part%202"))
        var nested = source
        for _ in 0..<3 {
            var components = try XCTUnwrap(URLComponents(string: "internal://local/load/reader"))
            components.queryItems = [URLQueryItem(name: "reader-url", value: nested.absoluteString)]
            nested = try XCTUnwrap(components.url)
        }

        let loader = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: nested))
        XCTAssertEqual(loader.readerLoaderContentURL?.absoluteString, source.absoluteString)
        XCTAssertEqual(loader.readerContentURL?.absoluteString, source.absoluteString)
        XCTAssertFalse(try XCTUnwrap(loader.readerLoaderContentURL).isReaderURLLoaderURL)
        XCTAssertEqual(loader, ReaderContentLoader.readerLoaderURL(for: source))
    }

    func testReaderLoaderBuilderRejectsInvalidOrUnsupportedContent() throws {
        for value in [
            "/relative/article",
            "javascript:alert(1)",
            "data:text/html,example",
            "file:///private/article.html",
            "about:blank",
            "internal://local/snippet?key=first&key=second",
            "internal://local/snippet-other?key=first",
            "internal://user@local/snippet?key=first",
            "internal://local/load/reader?reader-url=",
            "internal://local/load/reader?reader-url=https://example.com/first&reader-url=https://example.com/second",
            "internal://other/load/reader?reader-url=https://example.com/article",
            "reader-file://other/load/local/Documents/article.html",
            "reader-file://user@file/load/local/Documents/article.html",
            "transcript://local/vtt/asset?content-url=https://example.com/video",
        ] {
            let source = try XCTUnwrap(URL(string: value))
            XCTAssertNil(ReaderContentLoader.readerLoaderURL(for: source), value)
        }
    }

    func testReaderLoaderBuilderPreservesSelectedBookAndReaderFileSources() throws {
        for value in [
            "ttsu:///book/folder%2Fpart%252Fone",
            "reader-file://file/load/local/Documents/article%20one.html#part%202",
            "reader-file://file/load/icloud/Documents/article.html",
            "ebook://book/chapter%2Fpart.xhtml?literal=%2523#selection",
            "about:snippet?key=legacy%252Fnote",
            "internal://local/snippet?key=note%252Fone",
        ] {
            let source = try XCTUnwrap(URL(string: value))
            let loader = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: source), value)
            XCTAssertEqual(loader.readerLoaderContentURL?.absoluteString, source.absoluteString, value)
            XCTAssertEqual(loader.readerContentURL?.absoluteString, source.absoluteString, value)
        }
    }

    func testContentIdentityKeepsSourceFragmentWhilePresentationUsesOuterFragment() throws {
        let source = try XCTUnwrap(URL(string: "https://example.com/article?literal=%2523#source%2Fpart"))
        let loader = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: source))
        var components = try XCTUnwrap(URLComponents(url: loader, resolvingAgainstBaseURL: false))
        components.percentEncodedFragment = "current%2Fpart%2523tail"
        let navigatedLoader = try XCTUnwrap(components.url)

        XCTAssertEqual(navigatedLoader.readerContentURL?.absoluteString,
                       "https://example.com/article?literal=%2523#current%2Fpart%2523tail")
        XCTAssertEqual(ReaderContentLoader.getContentURL(fromLoaderURL: navigatedLoader), source)
        XCTAssertEqual(HistoryRecord.canonicalHistoryURL(for: navigatedLoader), source)
        let rebuilt = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: navigatedLoader))
        XCTAssertEqual(rebuilt.readerContentURL, navigatedLoader.readerContentURL)
    }

    func testNestedWrapperFragmentsPreserveExplicitStorageAndPresentationSemantics() throws {
        let source = try XCTUnwrap(URL(string: "https://example.com/article#source"))
        let inner = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: source))
        var innerComponents = try XCTUnwrap(URLComponents(url: inner, resolvingAgainstBaseURL: false))
        innerComponents.fragment = "inner"
        let innerPosition = try XCTUnwrap(innerComponents.url)
        var outerComponents = try XCTUnwrap(URLComponents(string: "internal://local/load/reader"))
        outerComponents.queryItems = [URLQueryItem(name: "reader-url", value: innerPosition.absoluteString)]
        outerComponents.fragment = "outer"
        let outer = try XCTUnwrap(outerComponents.url)

        XCTAssertEqual(outer.readerContentURL, URL(string: "https://example.com/article#outer"))
        // Only the outer transport position is removed by the storage API.
        XCTAssertEqual(ReaderContentLoader.getContentURL(fromLoaderURL: outer),
                       URL(string: "https://example.com/article#inner"))
    }

    func testGetContentURLRetainsOptionalLoaderAndCanonicalSnippetContract() throws {
        for value in [
            "https://example.com/article#source",
            "ttsu:///book/one",
            "about:blank",
            "internal://local/load/reader?reader-url=",
        ] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertNil(ReaderContentLoader.getContentURL(fromLoaderURL: url), value)
        }

        let snippet = try XCTUnwrap(ReaderContentLoader.snippetURL(key: "saved-note"))
        let legacy = try XCTUnwrap(URL(string: "about:snippet?key=saved-note#position"))
        let loader = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: legacy))
        for url in [snippet, legacy, loader] {
            XCTAssertEqual(ReaderContentLoader.getContentURL(fromLoaderURL: url), snippet)
        }
    }
}
