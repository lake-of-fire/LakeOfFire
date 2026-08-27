//
//  Copyright 2024 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import XCTest

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import LakeOfFireOPDS

final class readium_opds1_1_test: XCTestCase {
    private var feed: Feed!

    override func setUpWithError() throws {
        let fileURL = try XCTUnwrap(Bundle.module.url(forResource: "Samples/wiki_1_1", withExtension: "opds"))
        let data = try Data(contentsOf: fileURL)
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "http://test.com")!, statusCode: 200, httpVersion: nil, headerFields: nil))
        feed = try XCTUnwrap(try OPDS1Parser.parse(xmlData: data, url: URL(string: "http://test.com")!, response: response).feed)
    }

    func testMetadata() {
        XCTAssertEqual(feed.metadata.title, "Unpopular Publications")
        XCTAssertEqual(feed.metadata.modified?.timeIntervalSince1970, 1_263_117_671)
    }

    func testFeedLinks() {
        XCTAssertEqual(feed.links.count, 4)
        XCTAssertEqual(feed.links[0].rels, ["related"])
        XCTAssertEqual(feed.links[1].type, "application/atom+xml;profile=opds-catalog;kind=acquisition")
        XCTAssertEqual(feed.links[2].href, "http://test.com/opds-catalogs/root.xml")
    }

    func testPublicationsAndImages() throws {
        XCTAssertEqual(feed.publications.count, 2)

        let publication = try XCTUnwrap(feed.publications.first)
        XCTAssertEqual(publication.metadata.title, "Bob, Son of Bob")
        XCTAssertEqual(publication.metadata.authors.map(\.name), ["Bob the Recursive"])
        XCTAssertEqual(publication.metadata.languages, ["en"])
        XCTAssertEqual(publication.images.first(withRel: .opdsImage)?.href, "http://test.com/covers/4561.lrg.png")
        XCTAssertEqual(publication.links.first(withRel: .opdsAcquisition)?.href, "http://test.com/content/free/4561.epub")
    }

    func testDateParsingSupportsPartialISO8601() {
        XCTAssertEqual("2019".dateFromISO8601?.timeIntervalSince1970, 1_546_300_800)
        XCTAssertEqual("2019-03".dateFromISO8601?.timeIntervalSince1970, 1_551_398_400)
        XCTAssertEqual("2019-03-12".dateFromISO8601?.timeIntervalSince1970, 1_552_348_800)
        XCTAssertEqual("2019-03-12T07:58:31".dateFromISO8601?.timeIntervalSince1970, 1_552_377_511)
        XCTAssertEqual("2019-03-12T07:58:31Z".dateFromISO8601?.timeIntervalSince1970, 1_552_377_511)
    }

    func testRelativeLinksUseFinalResponseURLAfterRedirect() throws {
        let xml = """
        <feed>
          <title>Redirected Catalog</title>
          <link rel="next" href="next.atom"/>
          <entry>
            <title>Book</title>
            <link rel="http://opds-spec.org/acquisition" href="books/book.epub"/>
          </entry>
        </feed>
        """
        let requestedURL = URL(string: "https://catalog.example.com/feed.xml")!
        let finalURL = URL(string: "https://cdn.example.net/opds/catalog/feed.xml")!
        let response = try XCTUnwrap(
            HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: nil, headerFields: nil)
        )

        let parseData = try OPDS1Parser.parse(
            xmlData: Data(xml.utf8),
            url: requestedURL,
            response: response
        )
        let feed = try XCTUnwrap(parseData.feed)

        XCTAssertEqual(feed.links.first?.href, "https://cdn.example.net/opds/catalog/next.atom")
        XCTAssertEqual(
            feed.publications.first?.links.first?.href,
            "https://cdn.example.net/opds/catalog/books/book.epub"
        )
    }
}
