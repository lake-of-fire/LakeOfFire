import Foundation
import XCTest
@testable import LakeOfFireOPDS
@testable import LakeOfFireReader

final class BookAcquisitionTests: XCTestCase {
    private let catalogURL = URL(string: "https://catalog.example/opds/index.json")!

    private func parse(_ json: String) throws -> ParseData {
        let response = URLResponse(url: catalogURL, mimeType: "application/opds+json",
                                   expectedContentLength: -1, textEncodingName: "utf-8")
        return try OPDS2Parser.parse(jsonData: Data(json.utf8), url: catalogURL, response: response)
    }

    @MainActor
    private func mappedBook(from json: String, requiresEPUB: Bool = true) throws -> LakeOfFireReader.Publication {
        let document = try parse(json)
        let books = try XCTUnwrap(BookLibraryViewModel.mappedPublications(
            in: document, relativeTo: catalogURL, requiresEPUB: requiresEPUB
        ))
        XCTAssertEqual(books.count, 1)
        return try XCTUnwrap(books.first)
    }

    @MainActor
    func testMappingSelectsDeclaredEPUBAfterPDFAndCarriesItsType() throws {
        let book = try mappedBook(from: #"""
        {
          "metadata": {"title": "吾輩は猫である"},
          "links": [
            {"href": "book.pdf", "rel": "acquisition", "type": "application/pdf"},
            {"href": "download.php?id=42&key=a%2Fb+%2523", "rel": "acquisition", "type": "Application/EPUB+ZIP; profile=book"}
          ]
        }
        """#)

        XCTAssertEqual(book.downloadURL?.absoluteString, "https://catalog.example/opds/download.php?id=42&key=a%2Fb+%2523")
        XCTAssertEqual(book.downloadMediaType, "application/epub+zip")
    }

    @MainActor
    func testMappingKeepsMetadataWhenThereIsNoEligibleEPUB() throws {
        let book = try mappedBook(from: #"""
        {
          "metadata": {"title": "こころ", "author": {"name": "夏目漱石"}, "description": "Book description"},
          "links": [
            {"href": "misleading.epub", "rel": "acquisition", "type": "application/pdf"},
            {"href": "sample.epub", "rel": "http://opds-spec.org/acquisition/sample", "type": "application/epub+zip"}
          ]
        }
        """#)

        XCTAssertEqual(book.title, "こころ")
        XCTAssertEqual(book.author, "夏目漱石")
        XCTAssertEqual(book.summary, "Book description")
        XCTAssertNil(book.downloadURL)
        XCTAssertNil(book.downloadMediaType)
    }

    @MainActor
    func testMappingAllowsMokuroZIPOnlyWhenEPUBIsNotRequired() throws {
        let json = #"""
        {
          "metadata": {"title": "Mokuro book"},
          "links": [{"href": "manga.zip", "rel": "download", "type": "application/zip"}]
        }
        """#

        XCTAssertNil(try mappedBook(from: json).downloadURL)
        let book = try mappedBook(from: json, requiresEPUB: false)
        XCTAssertEqual(book.downloadURL?.absoluteString, "https://catalog.example/opds/manga.zip")
        XCTAssertNil(book.downloadMediaType)
    }

    @MainActor
    func testDefaultMappingAcceptsUntypedEPUBSuffix() throws {
        let json = #"""
        {
          "metadata": {"title": "Book"},
          "links": [
            {"href": "manga.zip", "rel": "acquisition"},
            {"href": "book.EPUB?key=a%2Fb", "rel": "acquisition"}
          ]
        }
        """#
        let document = try parse(json)
        let book = try XCTUnwrap(BookLibraryViewModel.mappedPublications(in: document, relativeTo: catalogURL)?.first)

        XCTAssertEqual(book.downloadURL?.absoluteString, "https://catalog.example/opds/book.EPUB?key=a%2Fb")
        XCTAssertNil(book.downloadMediaType)
    }

    @MainActor
    func testDownloadTaskIdentityIncludesURLNameAndMediaType() {
        let url = URL(string: "https://catalog.example/download.php?id=42")!
        let otherURL = URL(string: "https://catalog.example/download.php?id=43")!
        let mediaType = "application/epub+zip"
        let original = BookDownloadIdentity(url: url, name: "Book", mediaType: mediaType)

        XCTAssertEqual(original, BookDownloadIdentity(url: url, name: "Book", mediaType: mediaType))
        XCTAssertNotEqual(original, BookDownloadIdentity(url: otherURL, name: "Book", mediaType: mediaType))
        XCTAssertNotEqual(original, BookDownloadIdentity(url: url, name: "Retitled book", mediaType: mediaType))
        XCTAssertNotEqual(original, BookDownloadIdentity(url: url, name: "Book", mediaType: nil))
    }
}
