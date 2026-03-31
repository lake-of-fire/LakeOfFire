//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import XCTest

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import LakeOfFireOPDS

final class opensearch_test: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testFetchOpenSearchTemplate() {
        MockURLProtocol.requestHandler = { request in
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
              <Url type="application/atom+xml;profile=opds-catalog;kind=acquisition" template="https://catalog.example.com/search?q={searchTerms}"/>
              <Url type="application/opds+json" template="https://catalog.example.com/search.json?q={searchTerms}"/>
            </OpenSearchDescription>
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(xml.utf8))
        }

        let feed = Feed(title: "Catalog")
        feed.links = [
            Link(
                href: "https://catalog.example.com/feed.atom",
                type: "application/atom+xml;profile=opds-catalog;kind=acquisition",
                rel: .self
            ),
            Link(
                href: "https://catalog.example.com/opensearch.xml",
                type: "application/opensearchdescription+xml",
                rel: .search
            ),
        ]

        let expectation = expectation(description: "OpenSearch template")

        OPDS1Parser.fetchOpenSearchTemplate(feed: feed) { template, error in
            XCTAssertNil(error)
            XCTAssertEqual(template, "https://catalog.example.com/search?q={searchTerms}")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    func testFetchOpenSearchTemplateResolvesRelativeTemplateAgainstSearchDocumentURL() {
        MockURLProtocol.requestHandler = { request in
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
              <Url type="application/atom+xml;profile=opds-catalog;kind=acquisition" template="/search?q={searchTerms}"/>
            </OpenSearchDescription>
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(xml.utf8))
        }

        let feed = Feed(title: "Catalog")
        feed.links = [
            Link(
                href: "https://catalog.example.com/feed.atom",
                type: "application/atom+xml;profile=opds-catalog;kind=acquisition",
                rel: .self
            ),
            Link(
                href: "https://catalog.example.com/opensearch.xml",
                type: "application/opensearchdescription+xml",
                rel: .search
            ),
        ]

        let expectation = expectation(description: "Relative OpenSearch template")

        OPDS1Parser.fetchOpenSearchTemplate(feed: feed) { template, error in
            XCTAssertNil(error)
            XCTAssertEqual(template, "https://catalog.example.com/search?q={searchTerms}")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "catalog.example.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("Missing request handler")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
