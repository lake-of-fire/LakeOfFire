import Foundation
import XCTest
import LakeOfFireContent

final class ReaderTranscriptDocumentTests: XCTestCase {
    private func document(_ body: String) throws -> ReaderTranscriptDocument {
        try ReaderTranscriptDocument(webVTT: "WEBVTT\n\n" + body)
    }

    func test_literalMarkupAndEntitiesSurviveCanonicalRoundTrip() throws {
        let original = try document("00:00.000 --> 00:01.000\n&lt;猫&gt; &amp; 犬 🐈\n")
        let reopened = try ReaderTranscriptDocument(webVTT: original.webVTT)
        XCTAssertEqual(original.cues.first?.text, "<猫> & 犬 🐈")
        // Canonical serialization assigns numeric cue identifiers.
        XCTAssertNil(original.cues.first?.identifier)
        XCTAssertEqual(reopened.cues.first?.identifier, "1")
        XCTAssertEqual(reopened.cues.map(\.text), original.cues.map(\.text))
        XCTAssertEqual(reopened.cues.map(\.start), original.cues.map(\.start))
        XCTAssertEqual(reopened.cues.map(\.end), original.cues.map(\.end))
        XCTAssertEqual(reopened.webVTT, original.webVTT)
    }

    func test_cueTagsAreRemovedAndJapaneseTextIsRetained() throws {
        let value = try document("00:00.000 --> 00:01.000\n<v Speaker><c.highlight>猫</c></v>\n<00:00.500>犬\n")
        XCTAssertEqual(value.cues.first?.text, "猫\n犬")
    }

    func test_bomAndCRLFProduceUsableCanonicalDocument() throws {
        let value = try ReaderTranscriptDocument(webVTT: "\u{feff}WEBVTT\r\n\r\ncue-id\r\n00:00.000 --> 00:01.000\r\n猫\r\n")
        XCTAssertEqual(value.cues.first?.identifier, "cue-id")
        XCTAssertEqual(value.cues.first?.start, 0)
        XCTAssertEqual(value.cues.first?.end, 1)
        XCTAssertEqual(value.cues.first?.text, "猫")
        XCTAssertEqual(try ReaderTranscriptDocument(webVTT: value.webVTT).webVTT, value.webVTT)
    }

    func test_notesStylesAndRegionsAreNotTranscriptCues() throws {
        let value = try document("NOTE comment\nignored\n\nSTYLE\n::cue { color: red; }\n\nREGION\nid: example\n\n00:00.000 --> 00:01.000\n猫\n")
        XCTAssertEqual(value.cues.count, 1)
        XCTAssertEqual(value.cues.first?.text, "猫")
    }

    func test_overlappingCuesWithOrderedStartsAreAdmitted() throws {
        let value = try document("00:00.000 --> 00:02.000\n猫\n\n00:01.000 --> 00:03.000\n犬\n")
        XCTAssertEqual(value.cues.map(\.start), [0, 1])
        XCTAssertEqual(value.cues.map(\.end), [2, 3])
    }

    func test_equalOrReversedCueEndpointsAreRejected() {
        for timing in ["00:01.000 --> 00:01.000", "00:02.000 --> 00:01.000"] {
            XCTAssertThrowsError(try document(timing + "\n猫\n"))
        }
    }

    func test_decreasingCueStartsAreRejected() {
        XCTAssertThrowsError(try document("00:02.000 --> 00:03.000\n猫\n\n00:01.000 --> 00:04.000\n犬\n"))
    }

    func test_missingHeaderSeparatorIsRejected() {
        XCTAssertThrowsError(try ReaderTranscriptDocument(webVTT: "WEBVTT\n00:00.000 --> 00:01.000\n猫\n"))
    }

    func test_invalidUTF8AndEmbeddedNulAreRejected() {
        XCTAssertThrowsError(try ReaderTranscriptDocument(data: Data([0xff, 0xfe])))
        XCTAssertThrowsError(try document("00:00.000 --> 00:01.000\n猫\0犬\n"))
    }

    func test_documentAndCueByteLimitsAreEnforced() {
        XCTAssertThrowsError(try ReaderTranscriptDocument(data: Data(repeating: 65, count: ReaderTranscriptDocument.maximumBytes + 1)))
        XCTAssertThrowsError(try document("00:00.000 --> 00:01.000\n" + String(repeating: "a", count: 32_769)))
    }

    func test_emptyTranscriptAndEmptyCueTextAreRejected() {
        XCTAssertThrowsError(try document(""))
        XCTAssertThrowsError(try document("00:00.000 --> 00:01.000\n<v Speaker></v>\n"))
    }

    func test_invalidTimestampFieldsAreRejected() {
        for start in ["00:60.000", "00:00.00", "-1:00.000", "169:00:00.000", "NaN"] {
            XCTAssertThrowsError(try document(start + " --> 168:00:01.000\n猫\n"))
        }
    }
}
