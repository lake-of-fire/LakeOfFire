import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LakeOfFireOPDS

@MainActor
final class OPDSFetcherAdmissionPortTests: XCTestCase {
    func testPublicAndVersionSpecificFetchersRejectHTTPErrorBodies() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundaryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for version in [0, 1, 2] {
            let result: (ParseData?, Error?) = await withCheckedContinuation { continuation in
                let completion: @Sendable (sending ParseData?, Error?) -> Void = { continuation.resume(returning: ($0, $1)) }
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
