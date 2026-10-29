import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LakeOfFireOPDS

final class OPDSDocumentBoundaryTests: XCTestCase {
    private let base = URL(string: "https://catalog.example/opds/catalog.atom")!
    private let atom = "http://www.w3.org/2005/Atom"
    private let acquisition = "http://opds-spec.org/acquisition"

    private func parse(_ xml: String, responseURL: URL? = nil) throws -> ParseData {
        let response = URLResponse(url: responseURL ?? base, mimeType: "application/atom+xml",
                                   expectedContentLength: -1, textEncodingName: "utf-8")
        return try OPDS1Parser.parse(xmlData: Data(xml.utf8), url: base, response: response)
    }

    private func feed(_ content: String, attributes: String = "") throws -> Feed {
        try XCTUnwrap(parse("<feed xmlns=\"\(atom)\" \(attributes)><title>Catalog</title>\(content)</feed>").feed)
    }

    private func entry(_ content: String = "", attributes: String = "") -> String {
        "<entry \(attributes)><title>吾輩は猫である</title><id>urn:book:1</id>\(content)<link rel=\"\(acquisition)\" href=\"book.epub\" type=\"application/epub+zip\"/></entry>"
    }

    func testOpenAccessParsedPublicationProvidesActualDownloadURL() throws {
        let xml = "<entry xmlns='\(atom)'><title>Open</title><link rel='\(acquisition)/open-access' href='open.epub' type='application/epub+zip'/></entry>"
        let publication = try XCTUnwrap(parse(xml).publication)
        XCTAssertEqual(publication.downloadURL(relativeTo: base)?.absoluteString, "https://catalog.example/opds/open.epub")
    }

    func testDownloadSelectionSkipsCommerceAndUnusableLinks() {
        let commerce: [Link] = ["buy", "borrow", "subscribe"].map {
            Link(href: "https://example.com/\($0)", rels: [LinkRelation(acquisition + "/" + $0)])
        }
        XCTAssertNil(Publication(metadata: Metadata(title: "Paid"), links: commerce).downloadURL(relativeTo: base))
        let mixedCommerce = Link(href: "https://example.com/buy", rels: [.opdsAcquisition, LinkRelation(acquisition + "/buy")])
        XCTAssertNil(Publication(metadata: Metadata(title: "Mixed"), links: [mixedCommerce]).downloadURL(relativeTo: base))
        let generic = Link(href: "book.epub", rels: [.opdsAcquisition])
        let unusable = [Link(href: "", rels: [.opdsAcquisition]),
                        Link(href: "javascript:alert(1)", rels: [.opdsAcquisition]),
                        Link(href: "catalog.atom", type: "application/atom+xml", rels: [.opdsAcquisition])]
        XCTAssertNil(Publication(metadata: Metadata(title: "None"), links: unusable).downloadURL(relativeTo: base))
        XCTAssertEqual(Publication(metadata: Metadata(title: "Book"), links: commerce + unusable + [generic]).downloadURL(relativeTo: base)?.absoluteString,
                       "https://catalog.example/opds/book.epub")
    }

    func testDownloadSelectionPreservesMediaTypeAndPrefersEPUB() throws {
        let publication = Publication(metadata: Metadata(title: "Formats"), links: [
            Link(href: "book.pdf", type: "application/pdf", rel: .opdsAcquisition),
            Link(href: "/download/42", type: "APPLICATION/EPUB+ZIP; charset=binary", rel: .opdsAcquisitionOpenAccess),
        ])
        let acquisition = try XCTUnwrap(publication.downloadAcquisition(relativeTo: base))
        XCTAssertEqual(acquisition.url.absoluteString, "https://catalog.example/download/42")
        XCTAssertEqual(acquisition.mediaType, "application/epub+zip")
        XCTAssertEqual(publication.downloadURL(relativeTo: base), acquisition.url)
    }

    func testParsedBlankAcquisitionsCannotBecomeCatalogDownloads() throws {
        let response = URLResponse(url: base, mimeType: nil,
            expectedContentLength: -1, textEncodingName: nil)
        for href in ["", "   "] {
            for relation in [acquisition, acquisition + "/open-access"] {
                for hasFallback in [false, true] {
                    let fallbackXML = hasFallback
                        ? "<link href='actual.epub' rel='\(acquisition)' type='application/epub+zip'/>" : ""
                    let xml = "<entry xmlns='\(atom)'><title>Book</title><link href='\(href)' rel='\(relation)' type='application/epub+zip'/>\(fallbackXML)</entry>"
                    var links = [["href": href, "rel": relation, "type": "application/epub+zip"]]
                    if hasFallback {
                        links.append(["href": "actual.epub", "rel": acquisition, "type": "application/epub+zip"])
                    }
                    let json = try JSONSerialization.data(withJSONObject: [
                        "metadata": ["title": "Book"], "links": links,
                    ])
                    let publications = [
                        try XCTUnwrap(parse(xml).publication),
                        try XCTUnwrap(OPDS2Parser.parse(jsonData: json, url: base, response: response).publication),
                    ]
                    for publication in publications {
                        XCTAssertEqual(publication.downloadURL(relativeTo: base)?.absoluteString,
                            hasFallback ? "https://catalog.example/opds/actual.epub" : nil)
                    }
                }
            }
        }
    }

    func testParsedEmptySelfLinksStillResolveToDocument() throws {
        let xml = "<entry xmlns='\(atom)'><title>Book</title><link href='' rel='self'/></entry>"
        let json = Data(#"{"metadata":{"title":"Book"},"links":[{"href":"","rel":"self"}]}"#.utf8)
        let response = URLResponse(url: base, mimeType: nil,
            expectedContentLength: -1, textEncodingName: nil)
        let publications = [
            try XCTUnwrap(parse(xml).publication),
            try XCTUnwrap(OPDS2Parser.parse(jsonData: json, url: base, response: response).publication),
        ]
        for publication in publications {
            XCTAssertEqual(publication.links.first(withRel: .self)?.url(relativeTo: nil), base)
        }
    }

    func testRootRelativeLinkKeepsAuthorityRoot() {
        XCTAssertEqual(Link(href: "/books/one.epub").url(relativeTo: base)?.absoluteString,
                       "https://catalog.example/books/one.epub")
    }

    func testQueryOnlyLinkKeepsDocumentAndQuerySyntax() {
        XCTAssertEqual(Link(href: "?page=2&signature=a%2Fb+%2523").url(relativeTo: base)?.absoluteString,
                       "https://catalog.example/opds/catalog.atom?page=2&signature=a%2Fb+%2523")
    }

    func testFragmentOnlyLinkKeepsDocumentAndFragmentSyntax() {
        XCTAssertEqual(Link(href: "#section").url(relativeTo: base)?.absoluteString,
                       "https://catalog.example/opds/catalog.atom#section")
    }

    func testNetworkPathReferenceSelectsItsOwnHost() {
        XCTAssertEqual(Link(href: "//cdn.example/book.epub").url(relativeTo: base)?.absoluteString,
                       "https://cdn.example/book.epub")
    }

    func testEscapedPathAndQueryAreNotEncodedAgain() {
        XCTAssertEqual(Link(href: "books/a%23b%2520.epub?token=x%2Fy").url(relativeTo: base)?.absoluteString,
                       "https://catalog.example/opds/books/a%23b%2520.epub?token=x%2Fy")
    }

    func testJapaneseLinkUsesOneResolutionForModelsAndParsers() {
        let href = "本/吾輩.epub?download=1#表紙"
        XCTAssertEqual(Link(href: href).url(relativeTo: base)?.absoluteString,
                       URLHelper.getAbsolute(href: href, base: base))
    }

    func testRelativeLinkWithoutABaseIsNotAnAbsoluteURL() {
        XCTAssertNil(Link(href: "book.epub").url(relativeTo: nil))
        XCTAssertNil(URLHelper.getAbsolute(href: "book.epub", base: nil))
    }

    func testAbsoluteOpaqueURIWorksWithoutBase() {
        XCTAssertEqual(URLHelper.getAbsolute(href: "urn:isbn:9780000000000", base: nil),
                       "urn:isbn:9780000000000")
    }

    func testEmptyReferenceResolvesToCurrentDocument() {
        XCTAssertEqual(Link(href: "").url(relativeTo: base)?.absoluteString, base.absoluteString)
    }

    func testNestedXMLBaseResolvesAtTheLinkAndDoesNotLeakToNextEntry() throws {
        let result = try feed(
            entry("<link xml:base=\"images/\" rel=\"http://opds-spec.org/image\" href=\"cover%20one.jpg\"/>", attributes: "xml:base=\"../books/one/\"")
            + entry(), attributes: "xml:base=\"https://cdn.example/catalog/\"")
        XCTAssertEqual(result.publications.count, 2)
        XCTAssertEqual(result.publications[0].links.first?.href, "https://cdn.example/books/one/book.epub")
        XCTAssertEqual(result.publications[0].images.first?.href, "https://cdn.example/books/one/images/cover%20one.jpg")
        XCTAssertEqual(result.publications[1].links.first?.href, "https://cdn.example/catalog/book.epub")
    }

    func testResponseRedirectIsTheInitialXMLBase() throws {
        let xml = "<feed xmlns=\"\(atom)\" xml:base=\"../books/\"><title>C</title>\(entry())</feed>"
        let result = try XCTUnwrap(parse(xml, responseURL: URL(string: "https://mirror.example/new/feed.atom")!).feed)
        XCTAssertEqual(result.publications.first?.links.first?.href, "https://mirror.example/books/book.epub")
    }

    func testStandaloneEntryUsesItsXMLBase() throws {
        let result = try XCTUnwrap(parse("<entry xmlns=\"\(atom)\" xml:base=\"/books/\"><title>Book</title><link href=\"one.epub\" rel=\"\(acquisition)\"/></entry>").publication)
        XCTAssertEqual(result.links.first?.href, "https://catalog.example/books/one.epub")
    }

    func testForeignEntryCannotReplaceOrSplitTheCurrentPublication() throws {
        let result = try feed(entry("<x:entry xmlns:x=\"urn:extension\"><x:title>Wrong</x:title><x:link href=\"wrong.epub\"/></x:entry>"))
        XCTAssertEqual(result.publications.map(\.metadata.title), ["吾輩は猫である"])
        XCTAssertEqual(result.publications.first?.metadata.identifier, "urn:book:1")
        XCTAssertEqual(result.publications.first?.links.map(\.href), ["https://catalog.example/opds/book.epub"])
    }

    func testNestedAtomEntryInsideExtensionCannotCreateAPublication() throws {
        let result = try feed(entry("<x:extension xmlns:x=\"urn:extension\"><entry><title>Wrong</title></entry></x:extension>"))
        XCTAssertEqual(result.publications.map(\.metadata.title), ["吾輩は猫である"])
    }

    func testForeignTitleCannotOverwriteAtomTitle() throws {
        let result = try feed(entry("<x:title xmlns:x=\"urn:extension\">Wrong</x:title>"))
        XCTAssertEqual(result.publications.first?.metadata.title, "吾輩は猫である")
    }

    func testForeignLinkAndEmbeddedXHTMLLinkCannotBecomeAcquisitions() throws {
        let result = try feed(entry("""
        <x:link xmlns:x="urn:extension" rel="http://opds-spec.org/acquisition" href="wrong.epub"/>
        <summary type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><link href="stylesheet.css"/>本文</div></summary>
        """))
        XCTAssertEqual(result.publications.first?.links.map(\.href), ["https://catalog.example/opds/book.epub"])
        XCTAssertEqual(result.publications.first?.metadata.description, "本文")
    }

    func testForeignRootAndAtomFeedEmbeddedInAnotherDocumentAreRejected() {
        XCTAssertThrowsError(try parse("<feed xmlns=\"urn:extension\"><title>Wrong</title></feed>"))
        XCTAssertThrowsError(try parse("<wrapper><feed xmlns=\"\(atom)\"><title>Wrong</title></feed></wrapper>"))
    }

    func testPrefixedAtomAndDublinCoreRemainSupported() throws {
        let result = try XCTUnwrap(parse("""
        <a:feed xmlns:a="http://www.w3.org/2005/Atom" xmlns:d="http://purl.org/dc/terms/">
          <a:title>Catalog</a:title><a:entry><a:title>本</a:title><d:language>ja</d:language>
          <d:publisher>Publisher</d:publisher><a:author><a:name>著者</a:name></a:author>
          <a:link href="book.epub" rel="http://opds-spec.org/acquisition"/></a:entry>
        </a:feed>
        """).feed)
        let publication = try XCTUnwrap(result.publications.first)
        XCTAssertEqual(publication.metadata.title, "本")
        XCTAssertEqual(publication.metadata.languages, ["ja"])
        XCTAssertEqual(publication.metadata.publishers.map(\.name), ["Publisher"])
        XCTAssertEqual(publication.metadata.authors.map(\.name), ["著者"])
    }

    func testLegacyNamespaceLessFeedRemainsSupported() throws {
        let result = try XCTUnwrap(parse("<feed><title>Legacy</title>\(entry())</feed>").feed)
        XCTAssertEqual(result.metadata.title, "Legacy")
        XCTAssertEqual(result.publications.count, 1)
    }

    func testCDATAIsRetainedForTitlesAuthorsAndDescriptions() throws {
        let result = try XCTUnwrap(parse("""
        <feed xmlns="http://www.w3.org/2005/Atom"><title><![CDATA[日本語の本]]></title>
        <entry><title>吾輩<![CDATA[は猫]]>である</title><author><name><![CDATA[夏目漱石]]></name></author>
        <summary><![CDATA[本文 & 説明]]></summary><link href="book.epub" rel="http://opds-spec.org/acquisition"/></entry></feed>
        """).feed)
        XCTAssertEqual(result.metadata.title, "日本語の本")
        XCTAssertEqual(result.publications.first?.metadata.title, "吾輩は猫である")
        XCTAssertEqual(result.publications.first?.metadata.authors.first?.name, "夏目漱石")
        XCTAssertEqual(result.publications.first?.metadata.description, "本文 & 説明")
    }

    func testCanonicalOpenSearchCountersUseTheirNamespace() throws {
        let result = try feed("""
        <o:totalResults xmlns:o="http://a9.com/-/spec/opensearch/1.1/">120</o:totalResults>
        <o:itemsPerPage xmlns:o="http://a9.com/-/spec/opensearch/1.1/">20</o:itemsPerPage>
        <x:TotalResults xmlns:x="urn:extension">999</x:TotalResults>
        """)
        XCTAssertEqual(result.metadata.numberOfItem, 120)
        XCTAssertEqual(result.metadata.itemsPerPage, 20)
    }

    func testNavigationChoosesCatalogLinkNotFirstArtworkOrCollectionLink() throws {
        let result = try feed("""
        <entry><title>Browse</title>
        <link rel="http://opds-spec.org/image" href="cover.jpg" type="image/jpeg"/>
        <link rel="collection" href="group.atom" title="Group" type="application/atom+xml"/>
        <link rel="alternate" href="browser.html" type="text/html"/>
        <link rel="subsection" href="next.atom" type="APPLICATION/ATOM+XML; profile=opds-catalog"/>
        </entry>
        """)
        let group = try XCTUnwrap(result.groups.first)
        XCTAssertEqual(group.navigation.first?.href, "https://catalog.example/opds/next.atom")
        XCTAssertEqual(group.navigation.first?.title, "Browse")
        XCTAssertEqual(group.links.first?.href, "https://catalog.example/opds/group.atom")
    }

    func testNavigationSkipsInvalidFirstLinkInsteadOfDroppingTheEntry() throws {
        let result = try feed("<entry><title>Browse</title><link type=\"image/jpeg\"/><link rel=\"subsection\" href=\"next.atom\" type=\"application/atom+xml\"/></entry>")
        XCTAssertEqual(result.navigation.first?.href, "https://catalog.example/opds/next.atom")
    }

    func testRelationFamiliesRequireAPathBoundary() {
        XCTAssertTrue(LinkRelation.opdsAcquisitionOpenAccess.isOPDSAcquisition)
        XCTAssertFalse(LinkRelation("http://opds-spec.org/acquisition-not-a-book").isOPDSAcquisition)
        XCTAssertFalse(LinkRelation("http://opds-spec.org/images-other").isImage)
        XCTAssertTrue(LinkRelation.opdsImageThumbnail.isImage)
    }

    func testMisleadingAcquisitionSubstringDoesNotOverrideNavigation() throws {
        let result = try feed("<entry><title>Browse</title><link href=\"next.atom\" type=\"application/atom+xml\" rel=\"http://opds-spec.org/acquisition-not-a-book\"/></entry>")
        XCTAssertEqual(result.navigation.count, 1)
        XCTAssertTrue(result.publications.isEmpty)
    }

    func testMalformedTailNeverPublishesPartialFeed() {
        XCTAssertThrowsError(try parse("<feed xmlns=\"\(atom)\"><title>C</title>\(entry())<broken></feed>"))
    }

    func testFeedAndPublicationRemainMutuallyExclusive() throws {
        var data = try parse("<feed xmlns=\"\(atom)\"><title>C</title></feed>")
        data.publication = Publication(metadata: Metadata(title: "Book"))
        XCTAssertNil(data.feed)
        data.feed = Feed(title: "Feed")
        XCTAssertNil(data.publication)
    }

    func testOPDS2NestedHrefsRetainRedirectBaseAndEscaping() throws {
        let responseURL = URL(string: "https://mirror.example/opds/feed.json")!
        let response = URLResponse(url: responseURL, mimeType: "application/opds+json", expectedContentLength: -1, textEncodingName: nil)
        let json = #"{"metadata":{"title":"Catalog"},"publications":[{"metadata":{"title":"本","author":{"name":"著者","links":[{"href":"?author=a%2Fb"}]}},"links":[{"href":"/book%20one.epub?key=a%2Fb","rel":"http://opds-spec.org/acquisition"}],"images":[{"href":"//cdn.example/cover.jpg"}]}]}"#
        let result = try XCTUnwrap(OPDS2Parser.parse(jsonData: Data(json.utf8), url: base, response: response).feed)
        let publication = try XCTUnwrap(result.publications.first)
        XCTAssertEqual(publication.links.first?.href, "https://mirror.example/book%20one.epub?key=a%2Fb")
        XCTAssertEqual(publication.images.first?.href, "https://cdn.example/cover.jpg")
        XCTAssertEqual(publication.metadata.authors.first?.links.first?.href, "https://mirror.example/opds/feed.json?author=a%2Fb")
    }
    func testNamespacedFacetAttributeAcceptsAnArbitraryPrefix() throws {
        let result = try feed("<link xmlns:catalog=\"http://opds-spec.org/2010/catalog\" catalog:facetGroup=\"Language\" href=\"ja.atom\" title=\"Japanese\" rel=\"http://opds-spec.org/facet\"/>")
        XCTAssertEqual(result.facets.first?.metadata.title, "Language")
        XCTAssertEqual(result.facets.first?.links.first?.href, "https://catalog.example/opds/ja.atom")
    }

    func testCategoryWithoutOptionalLabelUsesItsTerm() throws {
        let result = try feed(entry("<category term=\"fiction\" scheme=\"urn:subjects\"/>"))
        XCTAssertEqual(result.publications.first?.metadata.subjects.first?.name, "fiction")
    }

    func testAuthorURIResolvesItsOwnXMLBase() throws {
        let result = try feed(entry("<author xml:base=\"/authors/\"><name>Author</name><uri xml:base=\"japan/\">soseki</uri></author>"))
        XCTAssertEqual(result.publications.first?.metadata.authors.first?.identifier, "https://catalog.example/authors/japan/soseki")
    }

    func testForeignAuthorDoesNotResetAnAtomAuthorBeingCollected() throws {
        let result = try feed(entry("<author><name>Author</name><x:author xmlns:x=\"urn:extension\"><x:name>Wrong</x:name></x:author></author>"))
        XCTAssertEqual(result.publications.first?.metadata.authors.map(\.name), ["Author"])
    }

    func testEmptyReferenceRemovesOnlyTheBaseFragment() {
        let withFragment = URL(string: "https://catalog.example/feed?key=a%2Fb#old")!
        XCTAssertEqual(Link(href: "").url(relativeTo: withFragment)?.absoluteString, "https://catalog.example/feed?key=a%2Fb")
    }

}
