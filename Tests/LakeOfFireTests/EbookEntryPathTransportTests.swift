import Foundation
import XCTest
@testable import LakeOfFireReader

final class EbookEntryPathTransportTests: XCTestCase {
    private let sourceURL = URL(
        string: "ebook://ebook/load/local/Books/%E6%97%A5%E6%9C%AC%E8%AA%9E.epub"
    )!
    private let generationID = "g1-" + String(repeating: "a", count: 64)

    private func ownerURL() -> URL {
        var components = URLComponents()
        components.scheme = "ebook"
        components.host = "ebook"
        components.path = "/processed-section"
        components.queryItems = [
            URLQueryItem(name: "sourceURL", value: sourceURL.absoluteString),
            URLQueryItem(name: "subpath", value: "OPS/Text/chapter.xhtml"),
        ]
        return components.url!
    }

    private func requestURL(percentEncodedSubpath: String) -> URL {
        let token = ebookBase64URLToken(for: sourceURL.absoluteString)
        return URL(
            string: "ebook://ebook/entry-source/\(token)/\(generationID)/\(percentEncodedSubpath)"
        )!
    }

    func testLiteralPercentEscapeIsDecodedExactlyOnce() throws {
        let request = try XCTUnwrap(ebookPathBackedEntryRequest(
            from: requestURL(
                percentEncodedSubpath:
                    "OPS/literal%252Fslash%2525percent.xhtml"
            ),
            mainDocumentURL: ownerURL()
        ))
        XCTAssertEqual(
            request.subpath,
            "OPS/literal%2Fslash%25percent.xhtml"
        )
    }

    func testTransportEncodedSeparatorCannotCreateAnotherPackagePath() throws {
        XCTAssertNil(ebookPathBackedEntryRequest(
            from: requestURL(
                percentEncodedSubpath: "OPS/escape%2Fchapter.xhtml"
            ),
            mainDocumentURL: ownerURL()
        ))
        XCTAssertNil(ebookPathBackedEntryRequest(
            from: requestURL(
                percentEncodedSubpath: "OPS/escape%5Cchapter.xhtml"
            ),
            mainDocumentURL: ownerURL()
        ))
    }

    func testTransportEncodedTraversalIsRejectedButLiteralPercentTextSurvives() throws {
        XCTAssertNil(ebookPathBackedEntryRequest(
            from: requestURL(
                percentEncodedSubpath: "OPS/%2E%2E/chapter.xhtml"
            ),
            mainDocumentURL: ownerURL()
        ))
        let literal = try XCTUnwrap(ebookPathBackedEntryRequest(
            from: requestURL(
                percentEncodedSubpath: "OPS/%252E%252E/chapter.xhtml"
            ),
            mainDocumentURL: ownerURL()
        ))
        XCTAssertEqual(literal.subpath, "OPS/%2E%2E/chapter.xhtml")
    }

    func testUnicodeReservedCharactersAndLiteralPercentRoundTrip() throws {
        let original =
            "OPS/日本語/space # question ? literal%2F.xhtml"
        let encoded = percentEncodedEbookEntrySubpath(original)
        XCTAssertTrue(encoded.contains("%E6%97%A5%E6%9C%AC%E8%AA%9E"))
        XCTAssertTrue(encoded.contains("space%20%23%20question%20%3F%20literal%252F.xhtml"))
        XCTAssertEqual(
            decodedEbookEntrySubpath(fromPercentEncodedPath: encoded),
            original
        )
    }

    func testProcessedSectionBaseURLEscapesLiteralPercentBeforeBrowserResolution() {
        let base = ebookProcessedSectionBaseURL(
            sourceURL: sourceURL,
            sectionHref: "OPS/100%/Text/chapter.xhtml",
            generationID: generationID
        )
        XCTAssertTrue(base.contains("/OPS/100%25/Text/"))
        XCTAssertFalse(base.contains("/OPS/100%/Text/"))
    }

    func testOwnerAndGenerationStillFenceTheDecodedPath() throws {
        var otherOwner = URLComponents(
            url: ownerURL(),
            resolvingAgainstBaseURL: false
        )!
        otherOwner.queryItems = [
            URLQueryItem(
                name: "sourceURL",
                value: "ebook://ebook/load/local/Books/other.epub"
            ),
            URLQueryItem(
                name: "subpath",
                value: "OPS/Text/chapter.xhtml"
            ),
        ]
        let valid = requestURL(
            percentEncodedSubpath: "OPS/Text/image.png"
        )
        XCTAssertNil(ebookPathBackedEntryRequest(
            from: valid,
            mainDocumentURL: otherOwner.url
        ))
        XCTAssertNil(ebookPathBackedEntryRequest(
            from: try XCTUnwrap(URL(
                string: valid.absoluteString.replacingOccurrences(
                    of: generationID,
                    with: "g1-short"
                )
            )),
            mainDocumentURL: ownerURL()
        ))
    }
}
