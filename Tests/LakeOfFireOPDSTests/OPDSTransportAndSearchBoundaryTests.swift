import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LakeOfFireOPDS

final class OPDSTransportAndSearchBoundaryTests: XCTestCase {
    private let base = URL(string: "https://opds-boundary.example/search/description.xml")!

    private func template(_ urls: String, type: String? = nil, attributes: String = "") throws -> String {
        try OPDS1Parser.parseOpenSearchTemplate(
            data: Data("<OpenSearchDescription xmlns=\"http://a9.com/-/spec/opensearch/1.1/\" \(attributes)>\(urls)</OpenSearchDescription>".utf8),
            selfType: type, baseURL: base)
    }

    func testEmptySearchMediaTypeDoesNotTrapOrWinSelection() throws {
        let urls = "<Url type=\"\" template=\"wrong?q={searchTerms}\"/><Url type=\"application/atom+xml\" template=\"right?q={searchTerms}\"/>"
        XCTAssertEqual(try template(urls, type: ""), "https://opds-boundary.example/search/right?q={searchTerms}")
    }

    func testOnlyEmptySearchMediaTypesFailWithoutTrapping() {
        XCTAssertThrowsError(try template("<Url type=\"\" template=\"search?q={searchTerms}\"/>"))
        XCTAssertThrowsError(try template("<Url type=\";;;\" template=\"search?q={searchTerms}\"/>"))
    }

    func testSearchMediaTypeMatchingIgnoresTypeAndParameterNameCaseAndUnquotesValues() throws {
        let result = try template("""
        <Url type="application/atom+xml;profile=other" template="wrong?q={searchTerms}"/>
        <Url type="APPLICATION/ATOM+XML; PROFILE=&quot;opds-catalog&quot; kind=acquisition" template="also-wrong?q={searchTerms}"/>
        <Url type="APPLICATION/ATOM+XML; PROFILE=&quot;opds-catalog&quot;" template="right?q={searchTerms}"/>
        """, type: "application/atom+xml;profile=opds-catalog")
        XCTAssertEqual(result, "https://opds-boundary.example/search/right?q={searchTerms}")
    }

    func testSearchQuotedProfileCanContainASemicolon() throws {
        let result = try template("""
        <Url type="application/atom+xml;profile=wrong" template="wrong?q={searchTerms}"/>
        <Url type="application/atom+xml;profile=&quot;https://example/profile;a&quot;" template="right?q={searchTerms}"/>
        """, type: "application/atom+xml; profile=\"https://example/profile;a\"")
        XCTAssertEqual(result, "https://opds-boundary.example/search/right?q={searchTerms}")
    }

    func testSearchXMLBaseIsScopedAndTemplateBracesAreRetained() throws {
        let result = try template("<Url xml:base=\"../find/\" type=\"application/atom+xml\" template=\"books?q={searchTerms}&amp;page={startPage?}\"/>", attributes: "xml:base=\"https://cdn.example/catalog/\"")
        XCTAssertEqual(result, "https://cdn.example/find/books?q={searchTerms}&page={startPage?}")
    }

    func testEscapedLiteralBracesDoNotTurnIntoTemplateParameters() throws {
        let result = try template("<Url type=\"application/atom+xml\" template=\"books?q={searchTerms}&amp;literal=%7Bstatic%7D&amp;nested=%257Bkeep%257D\"/>")
        XCTAssertEqual(result, "https://opds-boundary.example/search/books?q={searchTerms}&literal=%7Bstatic%7D&nested=%257Bkeep%257D")
    }

    func testTemplateResolutionDoesNotReplaceLiteralSentinelLikeText() {
        XCTAssertEqual(URLHelper.resolveTemplate("_OPDS_TEMPLATE_OPEN_?q={searchTerms}", base: base),
                       "https://opds-boundary.example/search/_OPDS_TEMPLATE_OPEN_?q={searchTerms}")
    }

    func testOptionalParametersInAPathDoNotConsumeFollowingPathOrQuery() {
        XCTAssertEqual(URLHelper.resolveTemplate("../find/{language?}/{searchTerms}?page={startPage?}", base: base),
                       "https://opds-boundary.example/find/{language?}/{searchTerms}?page={startPage?}")
    }

    func testUnbalancedTemplateBracesAreRejected() {
        XCTAssertNil(URLHelper.resolveTemplate("search?q={searchTerms", base: base))
        XCTAssertNil(URLHelper.resolveTemplate("search?q=searchTerms}", base: base))
        XCTAssertNil(URLHelper.resolveTemplate("search?q={{searchTerms}", base: base))
    }

    func testForeignAndNestedSearchURLsCannotOverrideTheDescription() throws {
        let result = try template("""
        <x:Url xmlns:x="urn:extension" type="application/atom+xml" template="wrong?q={searchTerms}"/>
        <x:extra xmlns:x="urn:extension"><Url type="application/atom+xml" template="also-wrong?q={searchTerms}"/></x:extra>
        <Url type="application/atom+xml" template="right?q={searchTerms}"/>
        """)
        XCTAssertEqual(result, "https://opds-boundary.example/search/right?q={searchTerms}")
    }

    func testForeignSearchRootAndMalformedTailAreRejected() {
        for xml in [
            "<OpenSearchDescription xmlns=\"urn:wrong\"><Url type=\"application/atom+xml\" template=\"search?q={searchTerms}\"/></OpenSearchDescription>",
            "<OpenSearchDescription><Url type=\"application/atom+xml\" template=\"search?q={searchTerms}\"/><broken></OpenSearchDescription>",
        ] {
            XCTAssertThrowsError(try OPDS1Parser.parseOpenSearchTemplate(data: Data(xml.utf8), selfType: nil, baseURL: base))
        }
    }

    func testHTTPFailureIsRejectedEvenWhenTheBodyIsAValidCatalog() {
        for status in [301, 304, 401, 403, 404, 429, 500, 503] {
            let response = HTTPURLResponse(url: base, statusCode: status, httpVersion: nil, headerFields: nil)!
            XCTAssertThrowsError(try OPDSParser.validateDocument(data: Data("<feed><title>Valid</title></feed>".utf8), response: response, error: nil)) { error in
                guard case OPDSParserError.httpStatus(let actualStatus) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(actualStatus, status)
            }
        }
    }

    func testPartialContentIsNotAcceptedAsACompleteCatalog() {
        let response = HTTPURLResponse(url: base, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": "bytes 0-99/1000"])!
        XCTAssertThrowsError(try OPDSParser.validateDocument(data: Data("<feed><title>Partial</title></feed>".utf8), response: response, error: nil)) { error in
            guard case OPDSParserError.partialDocument = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testTransportErrorWinsEvenIfTheCallbackAlsoHasDataAndResponse() {
        let response = HTTPURLResponse(url: base, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try OPDSParser.validateDocument(data: Data([1]), response: response, error: URLError(.cancelled))) {
            XCTAssertEqual(($0 as? URLError)?.code, .cancelled)
        }
    }

    func testSuccessfulAndNonHTTPResponsesRetainTheirBytesAndFinalURL() throws {
        let payload = Data("日本語".utf8)
        let response = HTTPURLResponse(url: base, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let result = try OPDSParser.validateDocument(data: payload, response: response, error: nil)
        XCTAssertEqual(result.0, payload)
        XCTAssertEqual(result.1.url, base)
        let local = URLResponse(url: URL(fileURLWithPath: "/catalog.atom"), mimeType: nil, expectedContentLength: -1, textEncodingName: nil)
        XCTAssertEqual(try OPDSParser.validateDocument(data: payload, response: local, error: nil).0, payload)
    }

    func testMissingDataOrResponseIsRejected() {
        XCTAssertThrowsError(try OPDSParser.validateDocument(data: nil, response: nil, error: nil))
        XCTAssertThrowsError(try OPDSParser.validateDocument(data: Data(), response: nil, error: nil))
    }

    func testPublicAndVersionSpecificFetchersRejectHTTPErrorBodies() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundaryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for version in [0, 1, 2] {
            let result: (ParseData?, Error?) = await withCheckedContinuation { continuation in
                let completion: (ParseData?, Error?) -> Void = { continuation.resume(returning: ($0, $1)) }
                let url = URL(string: "https://opds-boundary.example/fail-\(version)")!
                switch version {
                case 1: OPDS1Parser.parseURL(url: url, session: session, completion: completion)
                case 2: OPDS2Parser.parseURL(url: url, session: session, completion: completion)
                default: OPDSParser.parseURL(url: url, session: session, completion: completion)
                }
            }
            XCTAssertNil(result.0)
            guard case OPDSParserError.httpStatus(503)? = result.1 else {
                XCTFail("Missing HTTP failure for fetcher \(version): \(String(describing: result.1))")
                continue
            }
        }
    }

    func testOpenSearchFetcherPreservesHTTPErrorRatherThanPublishingTemplate() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundaryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let feed = Feed(title: "Catalog")
        feed.links = [Link(href: "https://opds-boundary.example/fail-search", rel: .search)]
        let result: (String?, Error?) = await withCheckedContinuation { continuation in
            OPDS1Parser.fetchOpenSearchTemplate(feed: feed, session: session) { continuation.resume(returning: ($0, $1)) }
        }
        XCTAssertNil(result.0)
        guard case OPDSParserError.httpStatus(503)? = result.1 else {
            return XCTFail("Missing HTTP failure")
        }
    }
}

private final class BoundaryURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "opds-boundary.example"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data: Data
        switch request.url?.lastPathComponent {
        case "fail-2": data = Data(#"{"metadata":{"title":"Error body"},"publications":[]}"#.utf8)
        case "fail-search": data = Data(#"<OpenSearchDescription><Url type="application/atom+xml" template="https://example.com/search?q={searchTerms}"/></OpenSearchDescription>"#.utf8)
        default: data = Data("<feed><title>Error body</title></feed>".utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
