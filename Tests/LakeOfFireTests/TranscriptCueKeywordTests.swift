import XCTest
import LakeOfFireContent

final class TranscriptCueKeywordTests: XCTestCase {
    func testKeywordPrefixesRemainCueIdentifiers() {
        for identifier in ["NOTEworthy", "STYLEguide", "WEBVTT-example", "NOTE:", "STYLES"] {
            let source = "WEBVTT\n\n\(identifier)\n00:00.000 --> 00:01.000\nHello\n"
            let cues = TranscriptPageAsset.cues(fromWebVTT: source)
            XCTAssertEqual(cues.count, 1, identifier)
            XCTAssertEqual(cues.first?.identifier, identifier)
            XCTAssertEqual(cues.first?.text, "Hello")
            XCTAssertEqual(cues.first?.startTimestamp, "00:00.000")
            XCTAssertEqual(cues.first?.endTimestamp, "00:01.000")
        }
    }

    func testNoteCommentsStillSkipTheirEntireBlock() {
        for firstLine in ["NOTE", "NOTE comment", "NOTE\tcomment"] {
            let source = "WEBVTT\n\n\(firstLine)\n00:00.000 --> 00:01.000\nNot a cue\n\n00:01.000 --> 00:02.000\nVisible\n"
            let cues = TranscriptPageAsset.cues(fromWebVTT: source)
            XCTAssertEqual(cues.map(\.text), ["Visible"], firstLine)
        }
    }

    func testHeaderAndStyleBlocksRemainIgnored() {
        for header in ["WEBVTT", "WEBVTT description", "WEBVTT\tdescription"] {
            let source = "\(header)\n\nSTYLE\n::cue { color: lime; }\n\n00:01.000 --> 00:02.000\nVisible\n"
            XCTAssertEqual(TranscriptPageAsset.cues(fromWebVTT: source).map(\.text), ["Visible"], header)
        }
        // A metadata block must not become a cue merely because it contains
        // an arrow later in the block.
        for firstLine in ["STYLE", "STYLE ", "STYLE\t"] {
            let style = "\(firstLine)\n00:00.000 --> 00:01.000\nNot a cue"
            XCTAssertTrue(TranscriptPageAsset.cues(fromWebVTT: style).isEmpty, firstLine)
        }
        let header = "WEBVTT description\n00:00.000 --> 00:01.000\nNot a cue"
        XCTAssertTrue(TranscriptPageAsset.cues(fromWebVTT: header).isEmpty)
    }

    func testFactoryPreservesRawVTTAndRendersPrefixedCueAfterCRLFNormalization() {
        let source = "WEBVTT\r\n\r\nNOTEworthy\r\n00:00.000 --> 00:01.000\r\nHello\r\n"
        let asset = TranscriptPageAsset.fromWebVTT(
            key: "keyword-test",
            canonicalContentURL: URL(string: "https://example.com/video")!,
            title: "Transcript",
            webVTT: source
        )
        XCTAssertEqual(asset.webVTT, source)
        XCTAssertTrue(asset.html.contains("data-transcript-cue-id=\"NOTEworthy\""))
        XCTAssertTrue(asset.html.contains(">Hello</p>"))
    }
}
