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

@MainActor
final class opensearch_test: XCTestCase {
    func testFetchOpenSearchTemplate() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let feed = Feed(title: "Catalog")
        feed.links = [
            Link(
                href: "https://catalog.example.com/feed.atom",
                type: "application/atom+xml;profile=opds-catalog;kind=acquisition",
                rel: .self
            ),
            Link(
                href: "https://catalog.example.com/absolute.xml",
                type: "application/opensearchdescription+xml",
                rel: .search
            ),
        ]

        let expectation = expectation(description: "OpenSearch template")

        OPDS1Parser.fetchOpenSearchTemplate(feed: feed, session: session) { template, error in
            XCTAssertNil(error)
            XCTAssertEqual(template, "https://catalog.example.com/search?q={searchTerms}")
            expectation.fulfill()
        }

        let completion = await XCTWaiter.fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(completion, .completed)
    }

    func testFetchOpenSearchTemplateResolvesRelativeTemplateAgainstSearchDocumentURL() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let feed = Feed(title: "Catalog")
        feed.links = [
            Link(
                href: "https://catalog.example.com/feed.atom",
                type: "application/atom+xml;profile=opds-catalog;kind=acquisition",
                rel: .self
            ),
            Link(
                href: "https://catalog.example.com/relative.xml",
                type: "application/opensearchdescription+xml",
                rel: .search
            ),
        ]

        let expectation = expectation(description: "Relative OpenSearch template")

        OPDS1Parser.fetchOpenSearchTemplate(feed: feed, session: session) { template, error in
            XCTAssertNil(error)
            XCTAssertEqual(template, "https://catalog.example.com/search?q={searchTerms}")
            expectation.fulfill()
        }

        let completion = await XCTWaiter.fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(completion, .completed)
    }

    func testFetchOpenSearchTemplateUsesFinalSearchDocumentURL() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let feed = Feed(title: "Catalog")
        feed.links = [
            Link(
                href: "https://catalog.example.com/feed.atom",
                type: "application/atom+xml;profile=opds-catalog;kind=acquisition",
                rel: .self
            ),
            Link(
                href: "https://catalog.example.com/redirected.xml",
                type: "application/opensearchdescription+xml",
                rel: .search
            ),
        ]

        let expectation = expectation(description: "Final OpenSearch template")

        OPDS1Parser.fetchOpenSearchTemplate(feed: feed, session: session) { template, error in
            XCTAssertNil(error)
            XCTAssertEqual(template, "https://cdn.example.net/search/search?q={searchTerms}")
            expectation.fulfill()
        }

        let completion = await XCTWaiter.fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(completion, .completed)
    }
}

private final class MockURLProtocol: URLProtocol {

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "catalog.example.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let (response, data) = try response(for: request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }


    private func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        switch request.url?.lastPathComponent {
        case "absolute.xml":
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
              <Url type="application/atom+xml;profile=opds-catalog;kind=acquisition" template="https://catalog.example.com/search?q={searchTerms}"/>
              <Url type="application/opds+json" template="https://catalog.example.com/search.json?q={searchTerms}"/>
            </OpenSearchDescription>
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(xml.utf8))
        case "relative.xml":
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
              <Url type="application/atom+xml;profile=opds-catalog;kind=acquisition" template="/search?q={searchTerms}"/>
            </OpenSearchDescription>
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(xml.utf8))
        case "redirected.xml":
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
              <Url type="application/atom+xml;profile=opds-catalog;kind=acquisition" template="search?q={searchTerms}"/>
            </OpenSearchDescription>
            """
            let response = HTTPURLResponse(
                url: URL(string: "https://cdn.example.net/search/opensearch.xml")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(xml.utf8))
        default:
            throw URLError(.unsupportedURL)
        }
    }

    override func stopLoading() {}
}
