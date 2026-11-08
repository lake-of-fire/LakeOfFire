import Foundation
import XCTest
import LakeOfFireContent

final class MediaTranscriptByteLimitTests: XCTestCase {
    func testRejectsOversizedDeclaredFrameBeforeDecompression() {
        // Zstandard single-segment header with an eight-byte frame content size.
        // No payload is needed: size admission must reject before decompression.
        for size in [UInt64(MediaTranscript.maximumWebVTTBytes) + 1, UInt64(MediaTranscript.maximumWebVTTBytes) + 1024] {
            XCTAssertThrowsError(try MediaTranscript.decodeWebVTTData(frameHeader(size: size))) { error in
                guard case MediaTranscriptCodecError.contentTooLarge = error else {
                    return XCTFail("Expected size admission failure, got \(error)")
                }
            }
        }
    }

    func testRejectsOversizedEncodingInput() {
        let input = Data(repeating: 65, count: MediaTranscript.maximumWebVTTBytes + 1)
        XCTAssertThrowsError(try MediaTranscript.encodeWebVTTData(input)) { error in
            guard case MediaTranscriptCodecError.contentTooLarge = error else {
                return XCTFail("Expected size admission failure, got \(error)")
            }
        }
    }

    func testBoundarySizeRoundTrips() throws {
        let input = Data(repeating: 65, count: MediaTranscript.maximumWebVTTBytes)
        let encoded = try MediaTranscript.encodeWebVTTData(input)
        XCTAssertEqual(try MediaTranscript.decodeWebVTTData(encoded), input)
    }

    func testOrdinaryTranscriptAndInvalidFrameBehavior() throws {
        let transcript = "WEBVTT\n\n00:00.000 --> 00:01.000\nこんにちは\n"
        XCTAssertEqual(
            try MediaTranscript.decodeWebVTT(MediaTranscript.encodeWebVTT(transcript)),
            transcript
        )
        XCTAssertThrowsError(try MediaTranscript.decodeWebVTTData(Data([0, 1, 2, 3]))) { error in
            guard case MediaTranscriptCodecError.invalidFrame = error else {
                return XCTFail("Expected invalid-frame failure, got \(error)")
            }
        }
    }

    private func frameHeader(size: UInt64) -> Data {
        // Magic, Frame_Header_Descriptor (FCS flag 3, single segment), then FCS.
        var bytes: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0xE0]
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: size >> shift))
        }
        return Data(bytes)
    }
}
