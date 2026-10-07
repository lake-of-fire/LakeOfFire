import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LakeOfFireOPDS

@MainActor
final class OPDSConcurrencyPortTests: XCTestCase {
    private func session(delegateQueue: OperationQueue? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConcurrencyPortURLProtocol.self]
        configuration.timeoutIntervalForRequest = 3
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: delegateQueue)
    }

    func testParserTransfersWholeMutableResultToMainActor() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let result: (ParseData?, Error?) = await withCheckedContinuation { continuation in
            OPDSParser.parseURL(url: URL(string: "https://opds-concurrency.example/feed")!, session: session) {
                continuation.resume(returning: ($0, $1))
            }
        }
        MainActor.preconditionIsolated()
        XCTAssertNil(result.1)
        let feed = try XCTUnwrap(result.0?.feed)
        XCTAssertEqual(feed.metadata.title, "Original")
        feed.metadata.title = "Owned by the receiving actor"
        XCTAssertEqual(feed.metadata.title, "Owned by the receiving actor")
    }

    func testSeparateRequestsDoNotShareMutableFeedMetadata() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        var feeds: [Feed] = []
        for _ in 0..<2 {
            let result: (ParseData?, Error?) = await withCheckedContinuation { continuation in
                OPDSParser.parseURL(url: URL(string: "https://opds-concurrency.example/feed")!, session: session) {
                    continuation.resume(returning: ($0, $1))
                }
            }
            XCTAssertNil(result.1)
            feeds.append(try XCTUnwrap(result.0?.feed))
        }
        XCTAssertFalse(feeds[0] === feeds[1])
        XCTAssertFalse(feeds[0].metadata === feeds[1].metadata)
        feeds[0].metadata.title = "Edited"
        XCTAssertEqual(feeds[1].metadata.title, "Original")
    }

    func testSearchUsesRequestTimeFeedType() async {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.isSuspended = true
        let session = session(delegateQueue: queue)
        defer { queue.isSuspended = false; session.invalidateAndCancel() }
        let feed = Feed(title: "Catalog")
        feed.links = [
            Link(href: "https://opds-concurrency.example/catalog", type: "application/atom+xml", rel: .self),
            Link(href: "https://opds-concurrency.example/search", rel: .search),
        ]
        let result: (String?, Error?) = await withCheckedContinuation { continuation in
            OPDS1Parser.fetchOpenSearchTemplate(feed: feed, session: session) {
                continuation.resume(returning: ($0, $1))
            }
            // The callback cannot run until this caller-owned edit is complete.
            feed.links[0] = Link(href: "https://other.example/catalog", type: "application/opds+json", rel: .self)
            queue.isSuspended = false
        }
        XCTAssertNil(result.1)
        XCTAssertEqual(result.0, "https://opds-concurrency.example/atom?q={searchTerms}")
        XCTAssertEqual(feed.links[0].type, "application/opds+json")
    }

    func testSearchWithoutLinkReportsFailureToActorCaller() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        let result: (String?, Error?) = await withCheckedContinuation { continuation in
            OPDS1Parser.fetchOpenSearchTemplate(feed: Feed(title: "No search"), session: session) {
                continuation.resume(returning: ($0, $1))
            }
        }
        XCTAssertNil(result.0)
        guard case OPDSParserOpenSearchHelperError.searchLinkNotFound? = result.1 else {
            return XCTFail("Missing no-search-link error")
        }
    }

    func testGenericFetcherTransfersHTTPFailureWithoutAPartialFeed() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        let result: (ParseData?, Error?) = await withCheckedContinuation { continuation in
            OPDSParser.parseURL(url: URL(string: "https://opds-concurrency.example/error")!, session: session) {
                continuation.resume(returning: ($0, $1))
            }
        }
        XCTAssertNil(result.0)
        guard case OPDSParserError.httpStatus(503)? = result.1 else {
            return XCTFail("Missing HTTP error")
        }
    }

    func testSearchPreservesTransportCancellation() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        let feed = Feed(title: "Cancelled search")
        feed.links = [Link(href: "https://opds-concurrency.example/cancel", rel: .search)]
        let result: (String?, Error?) = await withCheckedContinuation { continuation in
            OPDS1Parser.fetchOpenSearchTemplate(feed: feed, session: session) {
                continuation.resume(returning: ($0, $1))
            }
        }
        XCTAssertNil(result.0)
        XCTAssertEqual((result.1 as? URLError)?.code, .cancelled)
    }
}

private final class ConcurrencyPortURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "opds-concurrency.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.lastPathComponent == "cancel" {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let body: String
        if request.url?.lastPathComponent == "search" {
            body = """
            <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
              <Url type="application/opds+json" template="json?q={searchTerms}"/>
              <Url type="application/atom+xml" template="atom?q={searchTerms}"/>
            </OpenSearchDescription>
            """
        } else {
            body = #"{"metadata":{"title":"Original"},"publications":[]}"#
        }
        let response = HTTPURLResponse(url: request.url!,
            statusCode: request.url?.lastPathComponent == "error" ? 503 : 200,
            httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
