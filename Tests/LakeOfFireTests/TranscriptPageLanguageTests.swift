import Foundation
import XCTest
import LakeOfFireContent

final class TranscriptPageLanguageTests: XCTestCase {
    private let contentURL = URL(string: "https://example.com/watch?v=language")!
    private let webVTT = "WEBVTT\r\n\r\ncue-1\r\n00:01.250 --> 00:02.500\r\n日本語 & text\r\n"

    func testOmittedLanguagePreservesEnglishHTML() {
        let cues = TranscriptPageAsset.cues(fromWebVTT: webVTT)
        let html = TranscriptPageAsset.makeHTML(title: "Transcript", canonicalContentURL: contentURL, cues: cues)
        XCTAssertEqual(rootElement(in: html), "<html lang=\"en\">")
        let asset = TranscriptPageAsset.fromWebVTT(
            key: "language-default", canonicalContentURL: contentURL, title: "Transcript", webVTT: webVTT
        )
        XCTAssertEqual(asset.html, html)
        XCTAssertEqual(asset.html, TranscriptPageAsset.makeHTML(
            title: "Transcript", canonicalContentURL: contentURL, cues: cues, languageIdentifier: "en"
        ))
    }

    func testDeclaredLanguageChangesOnlyRootMetadata() {
        let cues = TranscriptPageAsset.cues(fromWebVTT: webVTT)
        let baseline = TranscriptPageAsset.makeHTML(title: "Transcript", canonicalContentURL: contentURL, cues: cues)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let cases = [
            ("ja", "ja"), ("ja-JP", "ja-jp"), ("JA_jp", "ja-jp"),
            (" zh_Hant_TW \n", "zh-hant-tw"), ("es-419", "es-419"),
            ("und", "und"), ("", "und"), (" \n", "und"),
            ("ja--JP", "und"), ("ja-", "und"), ("日本語", "und"),
            ("j", "und"), ("123", "und"), ("en_US.UTF-8", "und"),
            ("ja-123456789", "und"), (String(repeating: "a", count: 65), "und"),
            ("ja\" onload=\"alert(1)", "und"), ("ja&<script>", "und"),
            ("ja\nJP", "und"), ("ja\u{0000}JP", "und"),
            // Deliberately bounded shape, not a complete BCP 47 validator.
            ("x-private", "und"), ("i-klingon", "und"), ("zz", "zz")
        ]
        for (input, expected) in cases {
            let expectedHTML = baseline.replacingOccurrences(
                of: "<html lang=\"en\">", with: "<html lang=\"\(expected)\">"
            )
            let html = TranscriptPageAsset.makeHTML(
                title: "Transcript", canonicalContentURL: contentURL, cues: cues, languageIdentifier: input
            )
            XCTAssertEqual(rootElement(in: html), "<html lang=\"\(expected)\">", input)
            XCTAssertEqual(html, expectedHTML, input)
            let asset = TranscriptPageAsset.fromWebVTT(
                key: "unchanged-key", canonicalContentURL: contentURL, title: "Transcript",
                webVTT: webVTT, createdAt: createdAt, languageIdentifier: input
            )
            XCTAssertEqual(asset.html, expectedHTML, input)
            XCTAssertEqual(asset.key, "unchanged-key", input)
            XCTAssertEqual(asset.canonicalContentURL, contentURL, input)
            XCTAssertEqual(asset.title, "Transcript", input)
            XCTAssertEqual(asset.webVTT, webVTT, input)
            XCTAssertEqual(asset.createdAt, createdAt, input)
        }
        XCTAssertEqual(cues, [TranscriptPageAsset.Cue(
            identifier: "cue-1", startTimestamp: "00:01.250", endTimestamp: "00:02.500", text: "日本語 & text"
        )])
    }

    private func rootElement(in html: String) -> String? {
        html.components(separatedBy: "\n").first { $0.hasPrefix("<html ") }
    }
}
