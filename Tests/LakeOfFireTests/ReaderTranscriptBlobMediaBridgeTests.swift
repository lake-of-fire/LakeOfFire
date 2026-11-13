import Foundation
import XCTest
import LakeOfFireReader

final class ReaderTranscriptBlobMediaBridgeTests: XCTestCase {
    private typealias Bridge = ReaderTranscriptBlobMediaBridge
    private let token = "A6CB7D13-5AF6-48D5-928E-4EB23FD123AE"

    func testDecodesDeclaredAndUnknownLengthHeaders() throws {
        let header = try Bridge.decodeOpen(json([
            "status": "ok", "transferID": token, "mimeType": "audio/wav", "byteLength": 42
        ]))
        XCTAssertEqual(header.transferID, token)
        XCTAssertEqual(header.mimeType, "audio/wav")
        XCTAssertEqual(header.byteLength, 42)
        let unknown = try Bridge.decodeOpen(json([
            "status": "ok", "transferID": token, "mimeType": "", "byteLength": NSNull()
        ]))
        XCTAssertNil(unknown.byteLength)
    }

    func testDecodesExactChunkAndSeparateEOF() throws {
        let bytes = Data((0..<Bridge.chunkByteCount).map { UInt8($0 % 256) })
        let chunk = try Bridge.decodeRead(json([
            "status": "ok", "transferID": token, "offset": 0,
            "base64": bytes.base64EncodedString(), "done": false
        ]))
        XCTAssertEqual(chunk.data, bytes)
        XCTAssertEqual(chunk.offset, 0)
        XCTAssertFalse(chunk.done)
        let eof = try Bridge.decodeRead(json([
            "status": "ok", "transferID": token, "offset": bytes.count, "base64": "", "done": true
        ]))
        XCTAssertTrue(eof.data.isEmpty)
        XCTAssertTrue(eof.done)
        XCTAssertEqual(eof.offset, bytes.count)
    }

    func testAllowsNonemptyTerminalChunkAfterActualEOF() throws {
        let chunk = try Bridge.decodeRead(json([
            "status": "ok", "transferID": token, "offset": 3, "base64": "BAU=", "done": true
        ]))
        XCTAssertEqual(chunk.data, Data([4, 5]))
        XCTAssertTrue(chunk.done)
    }

    func testRejectsMalformedAndOversizedHeaders() throws {
        for count in [-1, 0, Bridge.maximumByteCount + 1] {
            XCTAssertThrowsError(try Bridge.decodeOpen(json([
                "status": "ok", "transferID": token, "mimeType": "audio/wav", "byteLength": count
            ])))
        }
        XCTAssertThrowsError(try Bridge.decodeOpen(json([
            "status": "ok", "transferID": token, "mimeType": "audio/wav", "byteLength": 1.5
        ])))
        XCTAssertThrowsError(try Bridge.decodeOpen(json([
            "status": "ok", "transferID": "", "mimeType": "audio/wav"
        ])))
        XCTAssertThrowsError(try Bridge.decodeOpen(json([
            "status": "ok", "transferID": token, "mimeType": String(repeating: "x", count: 257)
        ])))
    }

    func testRejectsMalformedBase64AndNonterminalEmptyChunks() throws {
        for base64 in ["!", "AQ=", "AQ==\n"] {
            XCTAssertThrowsError(try Bridge.decodeRead(json([
                "status": "ok", "transferID": token, "offset": 0, "base64": base64, "done": true
            ])))
        }
        XCTAssertThrowsError(try Bridge.decodeRead(json([
            "status": "ok", "transferID": token, "offset": 0, "base64": "", "done": false
        ])))
    }

    func testRejectsOversizedChunksAndOffsetOverflow() throws {
        let oversized = Data(repeating: 1, count: Bridge.chunkByteCount + 1)
        XCTAssertThrowsError(try Bridge.decodeRead(json([
            "status": "ok", "transferID": token, "offset": 0,
            "base64": oversized.base64EncodedString(), "done": true
        ])))
        for offset in [-1, Bridge.maximumByteCount, Int.max] {
            XCTAssertThrowsError(try Bridge.decodeRead(json([
                "status": "ok", "transferID": token, "offset": offset, "base64": "AQ==", "done": true
            ])))
        }
    }

    func testRejectsOversizedJSONBeforeBase64Decoding() {
        XCTAssertThrowsError(try Bridge.decodeOpen(String(repeating: " ", count: 4_097)))
        XCTAssertThrowsError(try Bridge.decodeRead(String(repeating: " ", count: 400_000)))
    }

    func testTypedFailuresAndCancellationArePreserved() throws {
        for code in ["staleSelection", "unsupportedSource", "unreadableMedia", "emptyMedia",
                     "tooLarge", "incompleteMedia", "busy", "invalidRequest"] {
            XCTAssertThrowsError(try Bridge.decodeOpen(json(["status": "error", "error": code]))) {
                XCTAssertEqual($0 as? Bridge.Failure, Bridge.Failure(rawValue: code))
            }
        }
        XCTAssertThrowsError(try Bridge.decodeRead(json(["status": "error", "error": "cancelled"]))) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try Bridge.decodeOpen(json(["status": "error", "error": "unknown"]))) {
            XCTAssertEqual($0 as? Bridge.Failure, .invalidResponse)
        }
    }

    func testCloseAcknowledgementMustBelongToOriginalTransfer() throws {
        let response = try json(["status": "ok", "transferID": token])
        XCTAssertNoThrow(try Bridge.decodeClose(response, transferID: token))
        XCTAssertThrowsError(try Bridge.decodeClose(response, transferID: UUID().uuidString))
        XCTAssertThrowsError(try Bridge.decodeClose("null", transferID: token))
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
