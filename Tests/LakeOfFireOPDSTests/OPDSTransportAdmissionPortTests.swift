import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LakeOfFireOPDS

final class OPDSTransportAdmissionPortTests: XCTestCase {
    private let base = URL(string: "https://opds-boundary.example/search/description.xml")!

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

}
