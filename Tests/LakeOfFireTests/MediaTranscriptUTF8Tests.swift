import Foundation
import XCTest
import LakeOfFireContent

final class MediaTranscriptUTF8Tests: XCTestCase {
    func testMalformedUTF8IsRejectedAfterSuccessfulDecompression() throws {
        let fixtures: [[UInt8]] = [[0xFF], [0xC3], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80]]
        for bytes in fixtures {
            let raw = Data(bytes)
            let frame = try MediaTranscript.encodeWebVTTData(raw)
            XCTAssertEqual(try MediaTranscript.decodeWebVTTData(frame), raw)
            XCTAssertThrowsError(try MediaTranscript.decodeWebVTT(frame)) { error in
                guard case MediaTranscriptCodecError.invalidFrame = error else {
                    return XCTFail("Expected invalidFrame, got \(error)")
                }
            }
        }
    }

    func testMalformedBytesInsideOtherwiseNonemptyTranscriptAreRejected() throws {
        var raw = Data("WEBVTT\n\n00:00.000 --> 00:01.000\n".utf8)
        raw.append(contentsOf: [0xE2, 0x82])
        raw.append(contentsOf: "\n".utf8)
        let frame = try MediaTranscript.encodeWebVTTData(raw)
        XCTAssertThrowsError(try MediaTranscript.decodeWebVTT(frame)) { error in
            guard case MediaTranscriptCodecError.invalidFrame = error else {
                return XCTFail("Expected invalidFrame, got \(error)")
            }
        }
    }

    func testValidUnicodeAndLiteralReplacementCharacterArePreserved() throws {
        for value in ["", "WEBVTT\r\n\r\n日本語 😀 e\u{301} �\r\n", "\u{feff}WEBVTT\n\n"] {
            let frame = try MediaTranscript.encodeWebVTT(value)
            let decoded = try MediaTranscript.decodeWebVTT(frame)
            XCTAssertEqual(decoded, value)
            XCTAssertEqual(Data(decoded.utf8), Data(value.utf8))
        }
    }
}
