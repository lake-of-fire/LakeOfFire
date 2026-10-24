import XCTest
@testable import LakeOfFireCore

final class URLInternalTests: XCTestCase {
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
            "internal://local/load/reader?reader-url=reader-file%3Ano-backing-file",
            "internal://local/load/reader?reader-url=reader-file%3A%2F%2Fevil%2Fload%2Flocal%2Fstory.html",
            "internal://local/load/reader?reader-url=reader-file%3A%2F%2Ffile%2Fload%2Funknown%2Fstory.html",
            "internal://local/load/reader?reader-url=reader-file%3A%2F%2Ffile%2Fload%2Flocal%252Fstory.html",
            "internal://local/load/reader?reader-url=reader-file%3A%2F%2Ffile%3A8080%2Fload%2Flocal%2Fstory.html",
            "internal://local/load/reader?reader-url=internal%3A%2F%2Flocal%2Fload%2Freader%3Freader-url%3Dhttps%253A%252F%252Fexample.org",
            "internal://local/load/reader?reader-url=https%3A%2F%2Fexample.org&reader-url=https%3A%2F%2Fevil.example",
            "internal://local/load/reader?reader-url=https%3A%2F%2Fexample.org&source=other",
        ]
        for string in unsafeURLs {
            let loaderURL = try XCTUnwrap(URL(string: string))
            XCTAssertNil(loaderURL.readerLoaderContentURL, string)
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

