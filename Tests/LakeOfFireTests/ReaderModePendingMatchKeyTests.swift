import XCTest
@testable import LakeOfFireReader

final class ReaderModePendingMatchKeyTests: XCTestCase {
    func testLoaderAndDirectURLHaveTheSameKeyWithoutDoubleDecodingReservedCharacters() throws {
        let contentURL = try XCTUnwrap(URL(
            string: "https://example.com/chapter%2Fpart.xhtml?literal=%2523#selection"
        ))
        let encodedContentURL = try XCTUnwrap(
            contentURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let loaderURL = try XCTUnwrap(URL(
            string: "internal://local/load/reader?reader-url=\(encodedContentURL)"
        ))

        XCTAssertEqual(
            normalizedReaderModePendingMatchKey(for: loaderURL),
            normalizedReaderModePendingMatchKey(for: contentURL)
        )
        XCTAssertEqual(
            normalizedReaderModePendingMatchKey(for: loaderURL),
            "https://example.com/chapter%2Fpart.xhtml?literal=%2523"
        )
    }

    func testLegacyDoubleEncodedLoaderHasTheSameKeyAsItsDirectURL() throws {
        let contentURL = try XCTUnwrap(URL(
            string: "https://example.com/chapter%2Fpart.xhtml?literal=%2523#selection"
        ))
        let encodedContentURL = try XCTUnwrap(
            contentURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let doubleEncodedContentURL = try XCTUnwrap(
            encodedContentURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let loaderURL = try XCTUnwrap(URL(
            string: "internal://local/load/reader?reader-url=\(doubleEncodedContentURL)"
        ))

        XCTAssertEqual(
            normalizedReaderModePendingMatchKey(for: loaderURL),
            normalizedReaderModePendingMatchKey(for: contentURL)
        )
    }

    func testSnippetLoaderUsesCanonicalSnippetIdentity() throws {
        let snippetURL = try XCTUnwrap(URL(
            string: "internal://local/snippet?key=alpha%252Fbeta"
        ))
        let encodedSnippetURL = try XCTUnwrap(
            snippetURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let loaderURL = try XCTUnwrap(URL(
            string: "internal://local/load/reader?reader-url=\(encodedSnippetURL)"
        ))

        XCTAssertEqual(
            normalizedReaderModePendingMatchKey(for: loaderURL),
            "snippet:alpha%2Fbeta"
        )
    }
}
