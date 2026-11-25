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

    func testStructuredOPDS2CatalogAcceptsLocalizedMetadata() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundaryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://opds-boundary.example/catalog/localized-opds2")!

        let document = try await OPDSParser.parseURL(url: url, session: session)
        let feed = try XCTUnwrap(document.feed)
        let publication = try XCTUnwrap(feed.publications.first)
        let group = try XCTUnwrap(feed.groups.first)
        XCTAssertEqual(feed.metadata.title, "図書目録")
        XCTAssertEqual(feed.facets.map(\.metadata.title), ["言語"])
        XCTAssertEqual(group.metadata.title, "小説")
        XCTAssertEqual(group.publications.map(\.metadata.title), ["A plain title"])
        XCTAssertNil(group.publications.first?.metadata.subtitle)
        XCTAssertEqual(publication.metadata.title, "吾輩は猫である")
        XCTAssertEqual(publication.metadata.subtitle, "小説")
        XCTAssertEqual(publication.metadata.languages, ["en"])
        XCTAssertEqual(publication.metadata.authors.map(\.name), ["夏目漱石", "A plain contributor"])
        XCTAssertEqual(publication.metadata.publishers.map(\.name), ["試験出版社"])
        XCTAssertEqual(publication.metadata.subjects.map(\.name), ["近代文学"])
        XCTAssertEqual(publication.metadata.authors.first?.links.first?.href,
                       "https://opds-boundary.example/people/soseki?key=a%2Fb")
        XCTAssertEqual(publication.metadata.subjects.first?.links.first?.href,
                       "https://opds-boundary.example/catalog/localized-opds2?topic=modern%2Fliterature")
        XCTAssertEqual(publication.links.first?.href,
                       "https://opds-boundary.example/catalog/books/cat.epub?token=a%2Fb")
    }

    func testStandaloneOPDS2PublicationAcceptsLocalizedTitle() throws {
        let json = #"""
        {
          "metadata": {"title": {"ja": "坊っちゃん"}, "subtitle": "A plain subtitle"},
          "links": [{"href": "book.epub", "rel": "http://opds-spec.org/acquisition"}]
        }
        """#
        let response = URLResponse(url: base, mimeType: "application/opds-publication+json",
                                   expectedContentLength: -1, textEncodingName: nil)
        let document = try OPDS2Parser.parse(jsonData: Data(json.utf8), url: base, response: response)
        XCTAssertNil(document.feed)
        XCTAssertEqual(document.publication?.metadata.title, "坊っちゃん")
        XCTAssertEqual(document.publication?.metadata.subtitle, "A plain subtitle")
    }

    func testOPDS2LocalizedNamesStillRequireValidNestedLinks() {
        let object: [String: Any] = [
            "name": ["ja": "名前"],
            "links": [["title": "Missing href"]],
        ]
        for field in ["author", "publisher", "subject"] {
            let metadata: [String: Any] = ["title": "Book", field: object]
            let catalog: [String: Any] = ["metadata": ["title": "Catalog"], "publications": [["metadata": metadata]]]
            XCTAssertThrowsError(try OPDS2Parser.parse(jsonDict: catalog)) { error in
                guard case OPDS2ParserError.invalidLink = error else {
                    return XCTFail("Unexpected error for \(field): \(error)")
                }
            }
        }
    }

    func testOPDS2LanguageLookupRetainsScriptRegionAndPriority() {
        let variants = [
            "zh-Hant-TW": "Taiwan",
            "zh-Hant": "Traditional",
            "zh-Hans": "Simplified",
            "zh": "Chinese",
            "en": "English",
        ]
        XCTAssertEqual(OPDS2LocalizedText.resolve(variants, preferredLanguages: ["ZH-hant-TW-u-co-stroke"]), "Taiwan")
        XCTAssertEqual(OPDS2LocalizedText.resolve(variants, preferredLanguages: ["zh-Hant-HK", "en"]), "Traditional")
        XCTAssertEqual(OPDS2LocalizedText.resolve(variants, preferredLanguages: ["fr", "zh-Hans"]), "Simplified")
    }

    func testOPDS2LanguageLookupTriesPreferredRangesBeforeRegionalFallback() {
        let variants = ["de": "Deutsch", "en-US": "American English"]
        XCTAssertEqual(OPDS2LocalizedText.resolve(variants, preferredLanguages: ["en-CA"]), "American English")
        XCTAssertEqual(OPDS2LocalizedText.resolve(variants, preferredLanguages: ["en-Latn-CA"]), "American English")
        XCTAssertEqual(OPDS2LocalizedText.resolve(variants, preferredLanguages: ["en-CA", "de-DE"]), "Deutsch")
        let scripts = ["zh-Hans-CN": "Simplified", "zh-Hant-TW": "Traditional"]
        XCTAssertEqual(OPDS2LocalizedText.resolve(scripts, preferredLanguages: ["zh-Hant-HK"]), "Traditional")
        let fallback = ["zh-Hans": "Simplified", "und": "Fallback"]
        XCTAssertEqual(OPDS2LocalizedText.resolve(fallback, preferredLanguages: ["zh-Hant-HK"]), "Fallback")
    }

    func testOPDS2LanguageDefaultsAreDeterministicAndKeepSpecialTags() {
        var variants = ["FR": "Français", "de": "Deutsch", "UND": "Fallback"]
        XCTAssertEqual(OPDS2LocalizedText.resolve(variants, preferredLanguages: ["ja"]), "Fallback")
        variants.removeValue(forKey: "UND")
        XCTAssertEqual(OPDS2LocalizedText.resolve(variants, preferredLanguages: ["ja"]), "Deutsch")
        XCTAssertEqual(OPDS2LocalizedText.resolve(["i-Klingon": "tlhIngan Hol"], preferredLanguages: ["i-klingon"]),
                       "tlhIngan Hol")
        XCTAssertEqual(OPDS2LocalizedText.resolve(["x-reader": "Private"], preferredLanguages: ["x-reader"]),
                       "Private")
    }

    func testOPDS2MalformedRequiredLanguageMapsStillFailCatalogParsing() {
        let malformedTitles: [Any] = [
            [String: String](),
            ["ja": " ", "en": "Valid"],
            ["ja": 123, "en": "Valid"] as [String: Any],
            ["en": "One", "EN": "Ambiguous"],
            ["en_US": "Invalid tag"],
            ["en--US": "Invalid tag"],
        ]
        for title in malformedTitles {
            let catalog: [String: Any] = ["metadata": ["title": title], "publications": []]
            XCTAssertThrowsError(try OPDS2Parser.parse(jsonDict: catalog)) { error in
                guard case OPDS2ParserError.missingTitle = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
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
        var status = 503
        switch request.url?.lastPathComponent {
        case "localized-opds2":
            status = 200
            data = Data(#"""
            {
              "metadata": {"title": {"ja": "図書目録"}},
              "links": [{"href": "localized-opds2", "rel": "self", "type": "application/opds+json"}],
              "facets": [{
                "metadata": {"title": {"ja": "言語"}},
                "links": [{"href": "?language=ja", "title": "Japanese", "rel": "http://opds-spec.org/facet"}]
              }],
              "groups": [{
                "metadata": {"title": {"ja": "小説"}},
                "publications": [{
                  "metadata": {"title": "A plain title", "subtitle": {"en": 123}},
                  "links": [{"href": "books/other.epub", "rel": "http://opds-spec.org/acquisition"}]
                }]
              }],
              "publications": [{
                "metadata": {
                  "title": {"ja": "吾輩は猫である"},
                  "subtitle": {"ja": "小説"},
                  "language": "en",
                  "author": [
                    {"name": {"ja": "夏目漱石"}, "links": [{"href": "../people/soseki?key=a%2Fb"}]},
                    "A plain contributor",
                    {"name": {"ja": 123}, "links": [{"title": "Missing href"}]}
                  ],
                  "publisher": {"name": {"ja": "試験出版社"}},
                  "subject": [
                    {"name": {"ja": "近代文学"}, "links": [{"href": "?topic=modern%2Fliterature"}]},
                    {"name": {"ja": " "}}
                  ]
                },
                "links": [{
                  "href": "books/cat.epub?token=a%2Fb",
                  "rel": "http://opds-spec.org/acquisition",
                  "type": "application/epub+zip"
                }]
              }]
            }
            """#.utf8)
        case "fail-2": data = Data(#"{"metadata":{"title":"Error body"},"publications":[]}"#.utf8)
        case "fail-search": data = Data(#"<OpenSearchDescription><Url type="application/atom+xml" template="https://example.com/search?q={searchTerms}"/></OpenSearchDescription>"#.utf8)
        default: data = Data("<feed><title>Error body</title></feed>".utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
