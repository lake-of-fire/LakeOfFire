import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LakeOfFireOPDS

final class OPDSURLForwardPortTests: XCTestCase {
    private let base = URL(string: "https://catalog.example/nested/feed.xml?old=1#old")!

    private func assertReference(_ reference: String, _ expected: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Link(href: reference).url(relativeTo: base)?.absoluteString,
                       expected, file: file, line: line)
        XCTAssertEqual(URLHelper.getAbsolute(href: reference, base: base),
                       expected, file: file, line: line)
    }

    func testRootRelativeAcquisitionKeepsTheOriginRoot() {
        assertReference("/books/book.epub", "https://catalog.example/books/book.epub")
    }

    func testNetworkPathReferenceKeepsItsOwnHost() {
        assertReference("//cdn.example/book.epub", "https://cdn.example/book.epub")
    }

    func testQueryOnlyReferenceDoesNotBecomeAPath() {
        assertReference("?q=cat%20dog&lang=ja", "https://catalog.example/nested/feed.xml?q=cat%20dog&lang=ja")
    }

    func testFragmentOnlyReferencePreservesTheCurrentQuery() {
        assertReference("#chapter-2", "https://catalog.example/nested/feed.xml?old=1#chapter-2")
    }

    func testEscapedReferenceIsNotDoubleEncoded() {
        assertReference("book%2Fpart.epub?token=a%2Bb%3D#p%201",
                        "https://catalog.example/nested/book%2Fpart.epub?token=a%2Bb%3D#p%201")
    }

    func testJapaneseIRIIsEncodedWithoutLosingQueryOrFragment() {
        assertReference("書籍/猫.epub?q=犬#猫",
                        "https://catalog.example/nested/%E6%9B%B8%E7%B1%8D/%E7%8C%AB.epub?q=%E7%8A%AC#%E7%8C%AB")
    }

    func testEmptyReferenceKeepsDocumentAndQueryButDropsFragment() {
        assertReference("", "https://catalog.example/nested/feed.xml?old=1")
    }

    func testHostlessAbsoluteURIsNeedNoBase() {
        for reference in ["urn:isbn:9781234567890", "mailto:catalog@example.test", "file:///books/book.epub"] {
            XCTAssertTrue(URLHelper.isAbsolute(href: reference))
            XCTAssertEqual(URLHelper.getAbsolute(href: reference, base: nil), reference)
            XCTAssertEqual(Link(href: reference).url(relativeTo: nil)?.absoluteString, reference)
        }
    }

    func testAbsoluteHTTPSIgnoresTheBase() {
        assertReference("https://other.example/book.epub?q=a%2Bb#p",
                        "https://other.example/book.epub?q=a%2Bb#p")
    }

    func testRelativeReferencesRequireAnAbsoluteBase() {
        for reference in ["", "book.epub", "/books/book.epub", "//cdn.example/book.epub", "?q=cat", "#chapter"] {
            XCTAssertNil(Link(href: reference).url(relativeTo: nil))
            XCTAssertNil(URLHelper.getAbsolute(href: reference, base: nil))
            XCTAssertFalse(URLHelper.isAbsolute(href: reference))
        }
        let relativeBase = URL(string: "nested/feed.xml")!
        XCTAssertNil(URLHelper.getAbsolute(href: "book.epub", base: relativeBase))
        XCTAssertNil(Link(href: "book.epub").url(relativeTo: relativeBase))
        XCTAssertNil(URLHelper.getAbsolute(href: nil, base: base))
    }

    func testDotSegmentsResolveWithoutChangingEscapes() {
        assertReference("../books/./book%20one.epub", "https://catalog.example/books/book%20one.epub")
    }

    func testFileBaseRetainsRootRelativeMeaning() {
        let fileBase = URL(string: "file:///catalog/nested/feed.xml")!
        XCTAssertEqual(Link(href: "/books/book.epub").url(relativeTo: fileBase)?.absoluteString,
                       "file:///books/book.epub")
        XCTAssertEqual(URLHelper.getAbsolute(href: "/books/book.epub", base: fileBase),
                       "file:///books/book.epub")
    }

    func testNormalizedLinksDoNotChangeWhenConvertedAgain() throws {
        for reference in ["/book%2Fone.epub?q=a%2Bb#p", "//cdn.example/book.epub", "?q=猫", "#chapter"] {
            let resolved = try XCTUnwrap(URLHelper.getAbsolute(href: reference, base: base))
            XCTAssertEqual(Link(href: resolved).url(relativeTo: base)?.absoluteString, resolved)
            XCTAssertEqual(URLHelper.getAbsolute(href: resolved, base: base), resolved)
        }
    }

    func testOPDS2NestedLinksUseTheSameResolverAsPublicModels() throws {
        let href = "/books/book%2Fone.epub?q=a%2Bb#p"
        let link: [String: Any] = ["href": href, "rel": "http://opds-spec.org/acquisition"]
        let publication: [String: Any] = [
            "metadata": ["title": "猫", "author": [["name": "Writer", "links": [link]]]],
            "links": [link], "images": [link]
        ]
        let feed = try OPDS2Parser.parse(jsonDict: [
            "metadata": ["title": "Catalog"],
            "links": [link], "navigation": [link], "publications": [publication],
            "facets": [["metadata": ["title": "Facet"], "links": [link]]],
            "groups": [["metadata": ["title": "Group"], "links": [link],
                        "navigation": [link], "publications": [publication]]]
        ], baseURL: base)
        let group = try XCTUnwrap(feed.groups.first)
        let book = try XCTUnwrap(feed.publications.first)
        var values = [Link]()
        values.append(contentsOf: feed.links)
        values.append(contentsOf: feed.navigation)
        values.append(contentsOf: book.links)
        values.append(contentsOf: book.images)
        values.append(contentsOf: book.metadata.authors.first?.links ?? [])
        values.append(contentsOf: feed.facets.first?.links ?? [])
        values.append(contentsOf: group.links)
        values.append(contentsOf: group.navigation)
        values.append(contentsOf: group.publications.first?.links ?? [])
        XCTAssertEqual(values.count, 9)
        let expected = "https://catalog.example/books/book%2Fone.epub?q=a%2Bb#p"
        for value in values {
            XCTAssertEqual(value.href, expected)
            XCTAssertEqual(value.url(relativeTo: base)?.absoluteString, expected)
        }
        XCTAssertEqual(Link(href: href).url(relativeTo: base)?.absoluteString, expected)
    }

    func testOPDS1AcquisitionAndModelResolutionAgree() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Catalog</title>
          <entry><title>Book</title><link rel="http://opds-spec.org/acquisition"
          href="/book.epub?q=cat&amp;lang=ja#chapter"/></entry>
        </feed>
        """
        let response = URLResponse(url: base, mimeType: "application/atom+xml", expectedContentLength: -1, textEncodingName: nil)
        let parsed = try OPDS1Parser.parse(xmlData: Data(xml.utf8), url: base, response: response)
        let link = try XCTUnwrap(parsed.feed?.publications.first?.links.first)
        let expected = "https://catalog.example/book.epub?q=cat&lang=ja#chapter"
        XCTAssertEqual(link.href, expected)
        XCTAssertEqual(link.url(relativeTo: base)?.absoluteString, expected)
        XCTAssertEqual(Link(href: "/book.epub?q=cat&lang=ja#chapter").url(relativeTo: base)?.absoluteString, expected)
    }

    func testStandaloneJSONPublicationNormalizesItsRelativeLink() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "metadata": ["title": "Book"], "links": [["href": "?download=1"]]
        ])
        let response = URLResponse(url: base, mimeType: "application/opds+json", expectedContentLength: -1, textEncodingName: nil)
        let parsed = try OPDS2Parser.parse(jsonData: data, url: base, response: response)
        let link = try XCTUnwrap(parsed.publication?.links.first)
        XCTAssertEqual(link.href, "https://catalog.example/nested/feed.xml?download=1")
        XCTAssertEqual(link.url(relativeTo: base)?.absoluteString, "https://catalog.example/nested/feed.xml?download=1")
    }

    func testExactRelationFamiliesAndSlashSubtypesRemainSupported() {
        for value in [LinkRelation.opdsAcquisition, .opdsAcquisitionOpenAccess, .opdsAcquisitionBuy,
                      LinkRelation("HTTP://OPDS-SPEC.ORG/ACQUISITION/CUSTOM")] {
            XCTAssertTrue(value.isOPDSAcquisition)
            XCTAssertFalse(value.isImage)
        }
        XCTAssertTrue(LinkRelation.opdsImage.isImage)
        XCTAssertTrue(LinkRelation.opdsImageThumbnail.isImage)
        XCTAssertTrue(LinkRelation("http://opds-spec.org/image/custom").isImage)
        XCTAssertTrue(LinkRelation.preview.isSample)
        XCTAssertTrue(LinkRelation.opdsAcquisitionSample.isSample)
    }

    func testLookalikeRelationPrefixesAreNotFamilyMembers() {
        for suffix in ["X", "-other", ".json", "?download=1", "#other"] {
            XCTAssertFalse(LinkRelation("http://opds-spec.org/acquisition" + suffix).isOPDSAcquisition)
            XCTAssertFalse(LinkRelation("http://opds-spec.org/image" + suffix).isImage)
        }
        XCTAssertFalse(LinkRelation("https://other.example/http://opds-spec.org/acquisition").isOPDSAcquisition)
    }

    func testMainSendableRelationContractIsRetained() {
        func requireSendable<Value: Sendable>(_ value: Value) -> Value { value }
        XCTAssertEqual(requireSendable(LinkRelation.opdsAcquisition), .opdsAcquisition)
    }

    func testURLConversionDoesNotMutateStoredLinkIdentityOrMetadata() {
        let first = Link(href: "/book.epub", type: "application/epub+zip", title: "Book", rel: .opdsAcquisition)
        let second = Link(href: "https://catalog.example/book.epub", rel: .opdsAcquisition)
        XCTAssertEqual(first.url(relativeTo: base), second.url(relativeTo: base))
        XCTAssertEqual(first.href, "/book.epub")
        XCTAssertEqual(first.title, "Book")
        XCTAssertEqual(first.type, "application/epub+zip")
        XCTAssertEqual(first.rels, [.opdsAcquisition])
        XCTAssertEqual(Set([first, second]).count, 2)
    }
}
