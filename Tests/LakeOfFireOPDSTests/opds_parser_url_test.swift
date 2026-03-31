import XCTest

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import LakeOfFireOPDS

final class opds_parser_url_test: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockOPDSURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockOPDSURLProtocol.self)
        MockOPDSURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testParseURLParsesOPDS2Feed() async throws {
        let sampleURL = try XCTUnwrap(Bundle.module.url(forResource: "Samples/opds_2_0", withExtension: "json"))
        let data = try Data(contentsOf: sampleURL)
        MockOPDSURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/opds+json"])!
            return (response, data)
        }

        let result = await withCheckedContinuation { continuation in
            OPDSParser.parseURL(url: URL(string: "https://catalog.example.com/feed.json")!) { parseData, error in
                continuation.resume(returning: (parseData, error))
            }
        }

        XCTAssertNil(result.1)
        XCTAssertEqual(result.0?.version, .OPDS2)
        XCTAssertEqual(result.0?.feed?.metadata.title, "Readium 2 OPDS 2.0 Feed")
    }

    func testParseURLRejectsMalformedXML() async {
        MockOPDSURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/atom+xml"])!
            return (response, Data("<feed><entry></feed>".utf8))
        }

        let result = await withCheckedContinuation { continuation in
            OPDSParser.parseURL(url: URL(string: "https://catalog.example.com/bad.xml")!) { parseData, error in
                continuation.resume(returning: (parseData, error))
            }
        }

        XCTAssertNil(result.0)
        XCTAssertNotNil(result.1)
    }

    func testParseURLRejectsMalformedJSON() async {
        MockOPDSURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/opds+json"])!
            return (response, Data("{\"metadata\":".utf8))
        }

        let result = await withCheckedContinuation { continuation in
            OPDSParser.parseURL(url: URL(string: "https://catalog.example.com/bad.json")!) { parseData, error in
                continuation.resume(returning: (parseData, error))
            }
        }

        XCTAssertNil(result.0)
        XCTAssertNotNil(result.1)
    }
}

private final class MockOPDSURLProtocol: URLProtocol {
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
