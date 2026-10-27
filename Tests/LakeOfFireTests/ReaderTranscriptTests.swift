import XCTest
import Foundation
import WebKit
import LakeOfFireCore
@testable import LakeOfFireContent
@testable import LakeOfFireReader

@MainActor
private final class TranscriptNavigation: NSObject, WKNavigationDelegate {
    var completion: CheckedContinuation<Void, Error>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completion?.resume()
        completion = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completion?.resume(throwing: error)
        completion = nil
    }
}

@MainActor
private final class TranscriptSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var events: [String] = []
    var responseReceived: (() -> Void)?
    var finished: (() -> Void)?
    init(url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) {
        events.append("response")
        responseReceived?()
    }
    func didReceive(_ data: Data) { events.append("data") }
    func didFinish() { events.append("finish"); finished?() }
    func didFailWithError(_ error: Error) { events.append("failure"); finished?() }
}

@MainActor
final class ReaderTranscriptTests: XCTestCase {
    private func load(_ html: String, in webView: WKWebView, delegate: TranscriptNavigation) async throws {
        webView.navigationDelegate = delegate
        try await withCheckedThrowingContinuation { continuation in
            delegate.completion = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/watch")!)
        }
    }

    private func capture(_ webView: WKWebView) async throws -> ReaderTranscriptMediaSnapshot {
        let raw = try await webView.callAsyncJavaScript(
            ReaderTranscriptMediaBridge.snapshotJavaScript, arguments: [:], in: nil, contentWorld: .page)
        return try ReaderTranscriptMediaBridge.decode(XCTUnwrap(raw as? String))
    }

    func testActualDocumentCaptureUsesLoadedCuesAndNewDocumentIdentity() async throws {
        let webView = WKWebView()
        let delegate = TranscriptNavigation()
        let html = "<title>Transcript source</title><video src='https://example.com/video.mp4'></video>"
        try await load(html, in: webView, delegate: delegate)
        _ = try await webView.callAsyncJavaScript("""
            window.fetchCount = 0;
            window.fetch = () => { window.fetchCount++; throw new Error('unexpected network'); };
            const track = document.querySelector('video').addTextTrack('subtitles', 'English', 'en');
            track.mode = 'showing';
            track.addCue(new VTTCue(1.25, 2.5, 'Hello <i>world</i> &amp; &lt;name&gt;'));
            """, arguments: [:], in: nil, contentWorld: .page)
        let first = try await capture(webView)
        let repeated = try await capture(webView)
        XCTAssertEqual(first.documentID, repeated.documentID)
        XCTAssertEqual(first.mediaIdentity, repeated.mediaIdentity)
        XCTAssertEqual(first.title, "Transcript source")
        XCTAssertEqual(first.webVTT, "WEBVTT\n\n00:00:01.250 --> 00:00:02.500\nHello world &amp; &lt;name&gt;\n")
        let count = try await webView.evaluateJavaScript("window.fetchCount")
        XCTAssertEqual(count as? Int, 0)
        try await load(html, in: webView, delegate: delegate)
        let replacement = try await capture(webView)
        XCTAssertNotEqual(first.documentID, replacement.documentID)
    }

    func testRegisteredAssetRoutesRequireExactURLAndResolveThroughCurrentLoader() async throws {
        let key = UUID().uuidString
        let source = URL(string: "https://example.com/watch")!
        let asset = TranscriptPageAsset.fromWebVTT(key: key, canonicalContentURL: source,
            title: "Title", webVTT: "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nCaption\n")
        await TranscriptPageRegistry.shared.register(asset)
        let pageURL = try XCTUnwrap(asset.pageURL)
        let vttURL = try XCTUnwrap(asset.webVTTURL)
        let html = await TranscriptPageRegistry.shared.htmlData(for: pageURL)
        let vtt = await TranscriptPageRegistry.shared.webVTTData(for: vttURL)
        XCTAssertEqual(html, Data(asset.html.utf8))
        XCTAssertEqual(vtt, Data(try XCTUnwrap(asset.webVTT).utf8))
        var components = try XCTUnwrap(URLComponents(url: pageURL, resolvingAgainstBaseURL: false))
        components.query = nil
        let forged = try XCTUnwrap(components.url)
        let rejectedData = await TranscriptPageRegistry.shared.htmlData(for: forged)
        let rejectedContent = try await ReaderContentLoader.getContent(forURL: forged)
        XCTAssertNil(rejectedData)
        XCTAssertNil(rejectedContent)
        let content = try await ReaderContentLoader.getContent(forURL: pageURL)
        XCTAssertEqual(content?.url, pageURL)
        XCTAssertEqual(content?.title, "Title")
        XCTAssertEqual((content as? HistoryRecord)?.sourceDownloadURL, source)
        await TranscriptPageRegistry.shared.remove(key: key)
        let removedContent = try await ReaderContentLoader.getContent(forURL: pageURL)
        XCTAssertNil(removedContent)
    }

    func testRendererEscapesActualCueAndTitleMarkup() throws {
        let asset = TranscriptPageAsset.fromWebVTT(key: "test", canonicalContentURL: URL(string: "https://example.com/?a=1&b=2")!,
            title: "<img src=x>", webVTT: "WEBVTT\n\nid\"\n00:00:01.000 --> 00:00:02.000\n<i>Hello</i> & goodbye\n")
        XCTAssertTrue(asset.html.contains("&lt;img src=x&gt;"))
        XCTAssertTrue(asset.html.contains("Hello &amp; goodbye"))
        XCTAssertTrue(asset.html.contains("data-transcript-cue-id=\"id&quot;\""))
        XCTAssertFalse(asset.html.contains("<img src=x>"))
        let literals = TranscriptPageAsset.cues(fromWebVTT:
            "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<i>Voice</i>: a &lt; b, &lt;name&gt;, &amp;lt; &nbsp;&lrm;&rlm;\n")
        XCTAssertEqual(literals.map(\.text), ["Voice: a < b, <name>, &lt; \u{00A0}\u{200E}\u{200F}"])
    }

    func testCueAdmissionRequiresActualTimestampGrammarAndPositiveDuration() {
        let text = """
        WEBVTT

        foo --> bar
        Invalid words

        00:01.000 --> 00:01.000
        Empty duration

        00:03.000 --> 00:02.000
        Reversed

        -00:01.000 --> 00:02.000
        Negative

        00:60.000 --> 01:02.000
        Invalid seconds

        00:60:00.000 --> 01:01:00.000
        Invalid minutes

        00:01.00 --> 00:02.000
        Invalid fraction

        short
        00:01.250 --> 00:02.500 align:start
        Valid short

        long
        123:01:02.000 --> 123:01:03.000
        Valid long

        NOTE-identifier
        00:04.000 --> 00:05.000
        Valid identifier
        """
        let cues = TranscriptPageAsset.cues(fromWebVTT: text)
        XCTAssertEqual(cues.map(\.identifier), ["short", "long", "NOTE-identifier"])
        XCTAssertEqual(cues.map(\.text), ["Valid short", "Valid long", "Valid identifier"])
        XCTAssertEqual(cues.map(\.startTimestamp), ["00:01.250", "123:01:02.000", "00:04.000"])
        XCTAssertEqual(cues.map(\.endTimestamp), ["00:02.500", "123:01:03.000", "00:05.000"])
    }

    func testSchemeStopDuringResponsePreventsDataAndFinish() async throws {
        let key = UUID().uuidString
        let asset = TranscriptPageAsset.fromWebVTT(key: key, canonicalContentURL: URL(string: "https://example.com")!,
            title: "Title", webVTT: "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nCaption\n")
        await TranscriptPageRegistry.shared.register(asset)
        let webView = WKWebView()
        let handler = TranscriptURLSchemeHandler()
        let task = TranscriptSchemeTask(url: try XCTUnwrap(asset.pageURL))
        let response = expectation(description: "response then synchronous stop")
        task.responseReceived = {
            handler.webView(webView, stop: task)
            response.fulfill()
        }
        handler.webView(webView, start: task)
        await fulfillment(of: [response], timeout: 5)
        XCTAssertEqual(task.events, ["response"])
        let retry = TranscriptSchemeTask(url: try XCTUnwrap(asset.pageURL))
        let finished = expectation(description: "fresh request finishes")
        retry.finished = { finished.fulfill() }
        handler.webView(webView, start: retry)
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(retry.events, ["response", "data", "finish"])
        await TranscriptPageRegistry.shared.remove(key: key)
    }
}
