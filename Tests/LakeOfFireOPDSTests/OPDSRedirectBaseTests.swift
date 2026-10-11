import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LakeOfFireOPDS

final class OPDSRedirectBaseTests: XCTestCase {
    private let requested = URL(string: "https://catalog.example/old/catalog")!
    private let redirected = URL(string: "https://cdn.example/new/catalog.json")!

    private func response() -> URLResponse {
        URLResponse(url: redirected, mimeType: nil, expectedContentLength: -1, textEncodingName: nil)
    }

    func testRedirectedJSONFeedResolvesNavigationAgainstResponseURL() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "metadata": ["title": "Catalog"],
            "navigation": [["href": "next.json"]]
        ])
        let parsed = try OPDS2Parser.parse(jsonData: data, url: requested, response: response())
        XCTAssertEqual(parsed.feed?.navigation.first?.href, "https://cdn.example/new/next.json")
    }

    func testRedirectedStandalonePublicationResolvesSubjectsAndAcquisition() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "metadata": ["title": "Book",
                         "subject": [["name": "History", "links": [["href": "../history"]]]]],
            "links": [["href": "book.epub"]]
        ])
        let parsed = try OPDS2Parser.parse(jsonData: data, url: requested, response: response())
        XCTAssertEqual(parsed.publication?.links.first?.href, "https://cdn.example/new/book.epub")
        XCTAssertEqual(parsed.publication?.metadata.subjects.first?.links.first?.href,
                       "https://cdn.example/history")
    }

    func testRedirectedXMLAcquisitionUsesResponseURL() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Catalog</title>
        <entry><title>Book</title>
        <link rel="http://opds-spec.org/acquisition" href="book.epub"/>
        </entry></feed>
        """
        let parsed = try OPDS1Parser.parse(xmlData: Data(xml.utf8), url: requested, response: response())
        XCTAssertEqual(parsed.feed?.publications.first?.links.first?.href,
                       "https://cdn.example/new/book.epub")
    }
}
