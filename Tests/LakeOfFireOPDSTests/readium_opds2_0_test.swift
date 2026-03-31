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

final class readium_opds2_0_test: XCTestCase {
    private var feed: Feed!

    override func setUpWithError() throws {
        let fileURL = try XCTUnwrap(Bundle.module.url(forResource: "Samples/opds_2_0", withExtension: "json"))
        let data = try Data(contentsOf: fileURL)
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "http://test.com/catalog.json")!, statusCode: 200, httpVersion: nil, headerFields: nil))
        feed = try XCTUnwrap(try OPDS2Parser.parse(jsonData: data, url: URL(string: "http://test.com/catalog.json")!, response: response).feed)
    }

    func testMetadata() {
        XCTAssertEqual(feed.metadata.numberOfItem, 5)
        XCTAssertEqual(feed.metadata.title, "Readium 2 OPDS 2.0 Feed")
    }

    func testFirstPublication() throws {
        let publication = try XCTUnwrap(feed.publications.first)
        XCTAssertEqual(publication.metadata.title, "Smoke Test FXL")
        XCTAssertEqual(publication.metadata.authors.map(\.name).prefix(2), ["Markus Gylling", "Vincent Gros"])
        XCTAssertEqual(publication.images.first(withRel: .cover)?.href, "https://readium2.feedbooks.net/Ym9va3MvU21va2VUZXN0RlhM/images/EPUB-Logo-Smoke.png")
        XCTAssertEqual(publication.links.first(withRel: .self)?.href, "https://readium2.feedbooks.net/Ym9va3MvU21va2VUZXN0RlhM/manifest.json")
    }

    func testLakeOfFireContractMapping() throws {
        let json = """
        {
          "metadata": {
            "title": "Catalog"
          },
          "publications": [
            {
              "metadata": {
                "title": "Relative Book",
                "author": [
                  { "name": "Author One" },
                  { "name": "Author Two" }
                ],
                "published": "2020-01-02"
              },
              "links": [
                {
                  "href": "downloads/book.epub",
                  "type": "application/epub+zip",
                  "rel": "http://opds-spec.org/acquisition"
                }
              ],
              "images": [
                {
                  "href": "images/thumb.png",
                  "type": "image/png",
                  "rel": "http://opds-spec.org/image/thumbnail"
                }
              ]
            }
          ]
        }
        """

        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://catalog.example.com/feed.json")!, statusCode: 200, httpVersion: nil, headerFields: nil))
        let parseData = try OPDS2Parser.parse(
            jsonData: Data(json.utf8),
            url: URL(string: "https://catalog.example.com/feed.json")!,
            response: response
        )

        let publication = try XCTUnwrap(parseData.feed?.publications.first)
        let authors = publication.metadata.authors.map(\.name).joined(separator: ", ")
        let coverURL = (publication.images.first(withRel: .cover)
            ?? publication.images.first(withRel: .opdsImage)
            ?? publication.images.first(withRel: .opdsImageThumbnail))?
            .url(relativeTo: URL(string: "https://catalog.example.com/")!)
        let downloadURL = publication.links.first(withRel: .opdsAcquisition)?.url(relativeTo: URL(string: "https://catalog.example.com/")!)

        XCTAssertEqual(publication.metadata.title, "Relative Book")
        XCTAssertEqual(authors, "Author One, Author Two")
        XCTAssertEqual(publication.metadata.published?.timeIntervalSince1970, 1_577_923_200)
        XCTAssertEqual(coverURL?.absoluteString, "https://catalog.example.com/images/thumb.png")
        XCTAssertEqual(downloadURL?.absoluteString, "https://catalog.example.com/downloads/book.epub")
    }
}
