import XCTest
@testable import LakeOfFireCore
@testable import LakeOfFireContent

final class URLInternalTests: XCTestCase {
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

    private func wrap(_ source: URL) throws -> URL {
        var components = try XCTUnwrap(URLComponents(string: "internal://local/load/reader"))
        components.queryItems = [URLQueryItem(name: "reader-url", value: source.absoluteString)]
        return try XCTUnwrap(components.url)
    }

    func testNestedLoaderPreservesEscapesAndPresentationFragment() throws {
        let source = try XCTUnwrap(URL(string: "https://example.org/a%2Fb?q=C%2B%2B&literal=%2523&value=a%26b#source"))
        var nested = source
        for _ in 0..<3 { nested = try wrap(nested) }
        XCTAssertEqual(nested.readerContentURL, source)
        var presentation = try XCTUnwrap(URLComponents(url: nested, resolvingAgainstBaseURL: false))
        presentation.percentEncodedFragment = "section%2Ftwo%2523tail"
        let presented = try XCTUnwrap(presentation.url)
        XCTAssertEqual(presented.readerContentURL?.absoluteString,
                       "https://example.org/a%2Fb?q=C%2B%2B&literal=%2523&value=a%26b#section%2Ftwo%2523tail")
        XCTAssertEqual(presented.removingFragmentIfNeeded().readerContentURL, source)
    }

    func testMalformedTransportAndUnsafeNestedTargetsHaveNoContentIdentity() throws {
        for query in [
            "", "?reader-url", "?reader-url=", "?reader-url=/relative/article",
            "?reader-url=https%253A%252F%252F", "?note=reader-url=https://example.org",
            "?reader-url=https://example.org&reader-url=https://other.example",
            "?reader-url=https://example.org&source=other",
            "?reader-url=javascript%3Aalert%281%29", "?reader-url=data%3Atext%2Fhtml%2Ctest",
            "?reader-url=file%3A%2F%2F%2Fprivate%2Fstory.html"
        ] {
            let transport = try XCTUnwrap(URL(string: "internal://local/load/reader\(query)"))
            XCTAssertNil(transport.readerContentURL, query)
            XCTAssertNil(transport.snippetKey, query)
            XCTAssertNil(try wrap(transport).readerContentURL, query)
        }
    }

    func testLoaderAuthorityAndPrivateRouteAliasesCannotSupplyIdentity() throws {
        for value in [
            "internal://user@local/load/reader?reader-url=https://example.org",
            "internal://user:password@local/load/reader?reader-url=https://example.org",
            "internal://local:443/load/reader?reader-url=https://example.org",
            "internal://elsewhere/load/reader?reader-url=https://example.org",
            "internal://local/load/reader-extra?reader-url=https://example.org",
            "internal://local/load?reader-url=https://example.org"
        ] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertFalse(url.isReaderLoaderTransportURL, value)
            XCTAssertNil(url.readerLoaderContentURL, value)
            XCTAssertNil(url.readerContentURL, value)
        }
        let uppercase = try XCTUnwrap(URL(string: "INTERNAL://LOCAL/load/reader?reader-url=https://example.org"))
        XCTAssertEqual(uppercase.readerContentURL, URL(string: "https://example.org"))
    }

    func testLegacySourcesAndOrdinaryRoutesKeepTheirOwnIdentity() throws {
        for value in [
            "ebook://book/chapter%2Fpart.xhtml?literal=%2523#selection",
            "about:snippet?key=legacy%252Fnote"
        ] {
            let source = try XCTUnwrap(URL(string: value))
            let transport = try wrap(source)
            XCTAssertEqual(transport.readerLoaderContentURL, source, value)
            XCTAssertEqual(transport.readerContentURL, source, value)
            XCTAssertEqual(transport.snippetKey, source.snippetKey, value)
        }
        for value in [
            "https://example.org/load/reader?reader-url=https://other.example",
            "reader-file://file/load/local/Documents/article.html", "about:blank",
            "internal://local/manabi-fonts.css?family=Reader", "internal://local/reader-sidecar/token",
            "ebook://ebook/load/manabi-fonts.css"
        ] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertFalse(url.isReaderURLLoaderURL, value)
            XCTAssertNil(url.readerLoaderContentURL, value)
            XCTAssertEqual(url.readerContentURL, url, value)
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
