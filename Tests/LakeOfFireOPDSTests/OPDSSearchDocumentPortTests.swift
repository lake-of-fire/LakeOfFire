import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LakeOfFireOPDS

@MainActor
final class OPDSSearchDocumentPortTests: XCTestCase {
    private let base = URL(string: "https://opds-boundary.example/search/description.xml")!

    private func template(_ urls: String, type: String? = nil, attributes: String = "") throws -> String {
        try OPDS1Parser.parseOpenSearchTemplate(
            data: Data("<OpenSearchDescription xmlns=\"http://a9.com/-/spec/opensearch/1.1/\" \(attributes)>\(urls)</OpenSearchDescription>".utf8),
            selfType: type, baseURL: base)
    }

    func testEmptySearchMediaTypeDoesNotTrapOrWinSelection() async throws {
        let urls = "<Url type=\"\" template=\"wrong?q={searchTerms}\"/><Url type=\"application/atom+xml\" template=\"right?q={searchTerms}\"/>"
        XCTAssertEqual(try template(urls, type: ""), "https://opds-boundary.example/search/right?q={searchTerms}")
    }

    func testOnlyEmptySearchMediaTypesFailWithoutTrapping() async {
        XCTAssertThrowsError(try template("<Url type=\"\" template=\"search?q={searchTerms}\"/>"))
        XCTAssertThrowsError(try template("<Url type=\";;;\" template=\"search?q={searchTerms}\"/>"))
    }

    func testSearchMediaTypeMatchingIgnoresTypeAndParameterNameCaseAndUnquotesValues() async throws {
        let result = try template("""
        <Url type="application/atom+xml;profile=other" template="wrong?q={searchTerms}"/>
        <Url type="APPLICATION/ATOM+XML; PROFILE=&quot;opds-catalog&quot; kind=acquisition" template="also-wrong?q={searchTerms}"/>
        <Url type="APPLICATION/ATOM+XML; PROFILE=&quot;opds-catalog&quot;" template="right?q={searchTerms}"/>
        """, type: "application/atom+xml;profile=opds-catalog")
        XCTAssertEqual(result, "https://opds-boundary.example/search/right?q={searchTerms}")
    }

    func testSearchQuotedProfileCanContainASemicolon() async throws {
        let result = try template("""
        <Url type="application/atom+xml;profile=wrong" template="wrong?q={searchTerms}"/>
        <Url type="application/atom+xml;profile=&quot;https://example/profile;a&quot;" template="right?q={searchTerms}"/>
        """, type: "application/atom+xml; profile=\"https://example/profile;a\"")
        XCTAssertEqual(result, "https://opds-boundary.example/search/right?q={searchTerms}")
    }

    func testSearchXMLBaseIsScopedAndTemplateBracesAreRetained() async throws {
        let result = try template("<Url xml:base=\"../find/\" type=\"application/atom+xml\" template=\"books?q={searchTerms}&amp;page={startPage?}\"/>", attributes: "xml:base=\"https://cdn.example/catalog/\"")
        XCTAssertEqual(result, "https://cdn.example/find/books?q={searchTerms}&page={startPage?}")
    }

    func testEscapedLiteralBracesDoNotTurnIntoTemplateParameters() async throws {
        let result = try template("<Url type=\"application/atom+xml\" template=\"books?q={searchTerms}&amp;literal=%7Bstatic%7D&amp;nested=%257Bkeep%257D\"/>")
        XCTAssertEqual(result, "https://opds-boundary.example/search/books?q={searchTerms}&literal=%7Bstatic%7D&nested=%257Bkeep%257D")
    }

    func testTemplateResolutionDoesNotReplaceLiteralSentinelLikeText() async {
        XCTAssertEqual(URLHelper.resolveTemplate("_OPDS_TEMPLATE_OPEN_?q={searchTerms}", base: base),
                       "https://opds-boundary.example/search/_OPDS_TEMPLATE_OPEN_?q={searchTerms}")
    }

    func testOptionalParametersInAPathDoNotConsumeFollowingPathOrQuery() async {
        XCTAssertEqual(URLHelper.resolveTemplate("../find/{language?}/{searchTerms}?page={startPage?}", base: base),
                       "https://opds-boundary.example/find/{language?}/{searchTerms}?page={startPage?}")
    }

    func testUnbalancedTemplateBracesAreRejected() async {
        XCTAssertNil(URLHelper.resolveTemplate("search?q={searchTerms", base: base))
        XCTAssertNil(URLHelper.resolveTemplate("search?q=searchTerms}", base: base))
        XCTAssertNil(URLHelper.resolveTemplate("search?q={{searchTerms}", base: base))
    }

    func testForeignAndNestedSearchURLsCannotOverrideTheDescription() async throws {
        let result = try template("""
        <x:Url xmlns:x="urn:extension" type="application/atom+xml" template="wrong?q={searchTerms}"/>
        <x:extra xmlns:x="urn:extension"><Url type="application/atom+xml" template="also-wrong?q={searchTerms}"/></x:extra>
        <Url type="application/atom+xml" template="right?q={searchTerms}"/>
        """)
        XCTAssertEqual(result, "https://opds-boundary.example/search/right?q={searchTerms}")
    }

    func testForeignSearchRootAndMalformedTailAreRejected() async {
        for xml in [
            "<OpenSearchDescription xmlns=\"urn:wrong\"><Url type=\"application/atom+xml\" template=\"search?q={searchTerms}\"/></OpenSearchDescription>",
            "<OpenSearchDescription><Url type=\"application/atom+xml\" template=\"search?q={searchTerms}\"/><broken></OpenSearchDescription>",
        ] {
            XCTAssertThrowsError(try OPDS1Parser.parseOpenSearchTemplate(data: Data(xml.utf8), selfType: nil, baseURL: base))
        }
    }

}
