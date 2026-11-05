import XCTest

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import LakeOfFireOPDS

private struct ParseURLResultSummary: Sendable {
    let versionIsOPDS2: Bool
    let feedTitle: String?
    let hasParseData: Bool
    let hasError: Bool
}

@MainActor
final class opds_parser_url_test: XCTestCase {
    func testParseURLParsesOPDS2Feed() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockOPDSURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let result = await withCheckedContinuation { continuation in
            OPDSParser.parseURL(url: URL(string: "https://catalog.example.com/feed.json")!, session: session) { parseData, error in
                continuation.resume(
                    returning: ParseURLResultSummary(
                        versionIsOPDS2: parseData?.version == .OPDS2,
                        feedTitle: parseData?.feed?.metadata.title,
                        hasParseData: parseData != nil,
                        hasError: error != nil
                    )
                )
            }
        }

        XCTAssertFalse(result.hasError)
        XCTAssertTrue(result.versionIsOPDS2)
        XCTAssertEqual(result.feedTitle, "Readium 2 OPDS 2.0 Feed")
    }

    func testParseURLRejectsMalformedXML() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockOPDSURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let result = await withCheckedContinuation { continuation in
            OPDSParser.parseURL(url: URL(string: "https://catalog.example.com/bad.xml")!, session: session) { parseData, error in
                continuation.resume(
                    returning: ParseURLResultSummary(
                        versionIsOPDS2: parseData?.version == .OPDS2,
                        feedTitle: parseData?.feed?.metadata.title,
                        hasParseData: parseData != nil,
                        hasError: error != nil
                    )
                )
            }
        }

        XCTAssertFalse(result.hasParseData)
        XCTAssertTrue(result.hasError)
    }

    func testParseURLRejectsMalformedJSON() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockOPDSURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let result = await withCheckedContinuation { continuation in
            OPDSParser.parseURL(url: URL(string: "https://catalog.example.com/bad.json")!, session: session) { parseData, error in
                continuation.resume(
                    returning: ParseURLResultSummary(
                        versionIsOPDS2: parseData?.version == .OPDS2,
                        feedTitle: parseData?.feed?.metadata.title,
                        hasParseData: parseData != nil,
                        hasError: error != nil
                    )
                )
            }
        }

        XCTAssertFalse(result.hasParseData)
        XCTAssertTrue(result.hasError)
    }
}

private final class MockOPDSURLProtocol: URLProtocol {

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
        case "feed.json":
            let sampleURL = try XCTUnwrap(Bundle.module.url(forResource: "Samples/opds_2_0", withExtension: "json"))
            let data = try Data(contentsOf: sampleURL)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/opds+json"])!
            return (response, data)
        case "bad.xml":
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/atom+xml"])!
            return (response, Data("<feed><entry></feed>".utf8))
        case "bad.json":
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/opds+json"])!
            return (response, Data("{\"metadata\":".utf8))
        default:
            throw URLError(.unsupportedURL)
        }
    }

    override func stopLoading() {}
}
