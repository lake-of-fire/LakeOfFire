import XCTest
import Foundation
import WebKit
import RealmSwift
import LakeOfFireCore
@testable import LakeOfFireContent
@testable import LakeOfFireReader

private actor TranscriptLoadGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

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
    func testRegisteredServingRoutesLoadOneStableNativeContentWithoutChangingOriginalArticle() async throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self]
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let previousBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistory = ReaderContentLoader.historyRealmConfiguration
        let previousFeed = ReaderContentLoader.feedEntryRealmConfiguration
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmark
            ReaderContentLoader.historyRealmConfiguration = previousHistory
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeed
        }
        let source = URL(string: "https://example.com/article")!
        let original = HistoryRecord()
        original.url = source
        original.title = "Original article"
        original.html = "<p>Original article body</p>"
        original.isReaderModeByDefault = false
        original.rssContainsFullContent = false
        original.updateCompoundKey()
        try realm.write { realm.add(original) }
        let stableKey = MediaTranscript.makeCompoundKey(contentURL: source,
            stableMediaIdentity: "youtube:videoA", languageCode: "en")
        func asset(_ key: String, title: String = "Transcript", caption: String = "Caption") -> TranscriptPageAsset {
            .fromWebVTT(key: UUID().uuidString, canonicalContentURL: source,
                title: title, webVTT: "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n\(caption)\n",
                stableContentKey: key)
        }
        let first = asset(stableKey)
        let second = asset(stableKey, title: "Replacement transcript", caption: "Replacement caption")
        let otherMedia = asset(MediaTranscript.makeCompoundKey(contentURL: source,
            stableMediaIdentity: "youtube:videoB", languageCode: "en"))
        let otherLanguage = asset(MediaTranscript.makeCompoundKey(contentURL: source,
            stableMediaIdentity: "youtube:videoA", languageCode: "ja"))
        XCTAssertNotEqual(first.pageURL, second.pageURL)
        XCTAssertEqual(first.readerContentURL, second.readerContentURL)
        XCTAssertNotEqual(first.readerContentURL, otherMedia.readerContentURL)
        XCTAssertNotEqual(first.readerContentURL, otherLanguage.readerContentURL)
        let stableURL = try XCTUnwrap(first.readerContentURL)
        XCTAssertTrue(stableURL.isTranscriptContentURL)
        XCTAssertNotEqual(stableURL, source)
        XCTAssertTrue(TranscriptReaderProtocol.providesNativeReaderView(forURL: stableURL))
        let reader = ReaderContent()
        var precedingFence: (() -> Bool)?
        for current in [first, second] {
            await TranscriptPageRegistry.shared.register(current)
            addTeardownBlock { await TranscriptPageRegistry.shared.remove(key: current.key) }
            let servingURL = try XCTUnwrap(current.pageURL)
            XCTAssertEqual(ReaderContentLoader.getContentURL(fromLoaderURL: servingURL), stableURL)
            XCTAssertTrue(servingURL.matchesReaderURL(stableURL))
            let resolved = try await ReaderContentLoader.getContent(forURL: servingURL)
            XCTAssertEqual(resolved?.url, stableURL)
            try await reader.load(url: servingURL)
            if let precedingFence { XCTAssertFalse(precedingFence()) }
            XCTAssertEqual(reader.pageURL, stableURL)
            XCTAssertEqual(reader.content?.url, stableURL)
            XCTAssertEqual(reader.content?.title, current.title)
            XCTAssertEqual((reader.content as? HistoryRecord)?.html, current.html)
            XCTAssertEqual((reader.content as? HistoryRecord)?.sourceDownloadURL, source)
            let selectionID = reader.currentSelectionID
            precedingFence = reader.makeSelectionCommitFence(requiring: selectionID)
            // Reopening this exact payload retains its selection authority.
            try await reader.load(url: servingURL)
            XCTAssertEqual(reader.currentSelectionID, selectionID)
            XCTAssertEqual(precedingFence?(), true)
        }
        XCTAssertEqual(original.url, source)
        XCTAssertEqual(original.title, "Original article")
        XCTAssertEqual(original.html, "<p>Original article body</p>")
        XCTAssertFalse(original.isReaderModeByDefault)
        XCTAssertFalse(original.rssContainsFullContent)
        XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
    }

    func testDistinctTranscriptPayloadDoesNotConsumeAnotherRoutesPreload() async throws {
        let source = URL(string: "https://example.com/preload")!
        let stableKey = MediaTranscript.makeCompoundKey(contentURL: source,
            stableMediaIdentity: "video", languageCode: "en")
        func asset(_ title: String) -> TranscriptPageAsset {
            .fromWebVTT(key: UUID().uuidString, canonicalContentURL: source,
                title: title, webVTT: "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n\(title)\n",
                stableContentKey: stableKey)
        }
        let first = asset("Old preload")
        let replacement = asset("New payload")
        await TranscriptPageRegistry.shared.register(first)
        await TranscriptPageRegistry.shared.register(replacement)
        addTeardownBlock {
            await TranscriptPageRegistry.shared.remove(key: first.key)
            await TranscriptPageRegistry.shared.remove(key: replacement.key)
        }
        let firstURL = try XCTUnwrap(first.pageURL)
        let replacementURL = try XCTUnwrap(replacement.pageURL)
        let loaded = try await ReaderContentLoader.getContent(forURL: firstURL)
        let preload = try XCTUnwrap(loaded)
        let reader = ReaderContent()
        reader.preloadResolvedContent(preload, for: firstURL)
        try await reader.load(url: replacementURL)
        XCTAssertEqual(reader.content?.title, replacement.title)
        XCTAssertEqual((reader.content as? HistoryRecord)?.html, replacement.html)
        XCTAssertEqual(reader.content?.url, first.readerContentURL)
    }

    func testSameIdentityTranscriptReplacementRetiresSuspendedOldPayload() async throws {
        let source = URL(string: "https://example.com/replacement")!
        let stableKey = MediaTranscript.makeCompoundKey(contentURL: source,
            stableMediaIdentity: "video", languageCode: "en")
        func asset(_ title: String) -> TranscriptPageAsset {
            .fromWebVTT(key: UUID().uuidString, canonicalContentURL: source,
                title: title, webVTT: "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n\(title)\n",
                stableContentKey: stableKey)
        }
        let first = asset("Delayed payload")
        let replacement = asset("Current payload")
        await TranscriptPageRegistry.shared.register(first)
        await TranscriptPageRegistry.shared.register(replacement)
        addTeardownBlock {
            await TranscriptPageRegistry.shared.remove(key: first.key)
            await TranscriptPageRegistry.shared.remove(key: replacement.key)
        }
        let firstURL = try XCTUnwrap(first.pageURL)
        let replacementURL = try XCTUnwrap(replacement.pageURL)
        let reader = ReaderContent()
        let entered = expectation(description: "first payload resolved but held")
        let gate = TranscriptLoadGate()
        let old = Task { @MainActor in
            try await reader.load(url: firstURL) { url in
                let content = try await ReaderContentLoader.getContent(forURL: url)
                entered.fulfill()
                await gate.wait()
                return content
            }
        }
        addTeardownBlock { await gate.release(); _ = await old.result }
        await fulfillment(of: [entered], timeout: 5)
        let oldFence = reader.makeSelectionCommitFence(requiring: reader.currentSelectionID)
        let replacementFinished = expectation(description: "replacement does not join old payload")
        let fresh = Task { @MainActor in
            defer { replacementFinished.fulfill() }
            try await reader.load(url: replacementURL)
        }
        addTeardownBlock { await gate.release(); _ = await fresh.result }
        await fulfillment(of: [replacementFinished], timeout: 5)
        // Release even when the expectation fails: the old cache/coalescing
        // behavior must produce an assertion failure rather than a stuck test.
        await gate.release()
        _ = await old.result
        try await fresh.value
        XCTAssertFalse(oldFence())
        XCTAssertEqual(reader.content?.title, replacement.title)
        XCTAssertEqual((reader.content as? HistoryRecord)?.html, replacement.html)
        XCTAssertEqual(reader.content?.url, first.readerContentURL)
    }

    func testTypedBackingQueryDoesNotGrantUnregisteredServingRouteAdmission() async throws {
        let source = URL(string: "https://example.com/article")!
        let key = String(repeating: "a", count: 64)
        let asset = TranscriptPageAsset.fromWebVTT(key: UUID().uuidString,
            canonicalContentURL: source, title: "Transcript", webVTT: "WEBVTT",
            stableContentKey: key)
        await TranscriptPageRegistry.shared.register(asset)
        let servingURL = try XCTUnwrap(asset.pageURL)
        var components = try XCTUnwrap(URLComponents(url: servingURL, resolvingAgainstBaseURL: false))
        components.queryItems = [URLQueryItem(name: "transcript-content-url", value: source.absoluteString)]
        let httpForgery = try XCTUnwrap(components.url)
        XCTAssertNil(ReaderContentLoader.getContentURL(fromLoaderURL: httpForgery))
        let forgedHTTP = try await ReaderContentLoader.getContent(forURL: httpForgery)
        XCTAssertNil(forgedHTTP)
        let otherNative = try XCTUnwrap(URL.transcriptContentIdentityURL(key: String(repeating: "b", count: 64)))
        components.queryItems = [URLQueryItem(name: "transcript-content-url", value: otherNative.absoluteString)]
        let nativeForgery = try XCTUnwrap(components.url)
        XCTAssertEqual(ReaderContentLoader.getContentURL(fromLoaderURL: nativeForgery), otherNative)
        let forgedNative = try await ReaderContentLoader.getContent(forURL: nativeForgery)
        let forgedData = await TranscriptPageRegistry.shared.htmlData(for: nativeForgery)
        XCTAssertNil(forgedNative)
        XCTAssertNil(forgedData)
        components.queryItems?.append(URLQueryItem(name: "transcript-content-url", value: otherNative.absoluteString))
        XCTAssertNil(try XCTUnwrap(components.url).transcriptBackingContentURL)
        XCTAssertNil(URL.transcriptContentIdentityURL(key: "not-a-compound-key"))
        XCTAssertNil(URL.transcriptContentIdentityURL(key: key + "\n"))
        for value in [
            "https://local/content/\(key)",
            "transcript://local/other/\(key)",
            "transcript://user@local/content/\(key)",
            "transcript://local/content/\(key)?extra=1",
            "transcript://local/content/\(key)#fragment",
            "transcript://local/content/\(key.uppercased())"
        ] {
            XCTAssertFalse(try XCTUnwrap(URL(string: value)).isTranscriptContentURL)
        }
        await TranscriptPageRegistry.shared.remove(key: asset.key)
    }

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
        XCTAssertNotNil(first.captionSelectionIdentity)
        XCTAssertEqual(first.captionSelectionIdentity, repeated.captionSelectionIdentity)
        XCTAssertEqual(first.title, "Transcript source")
        XCTAssertEqual(first.webVTT, "WEBVTT\n\n00:00:01.250 --> 00:00:02.500\nHello world &amp; &lt;name&gt;\n")
        let count = try await webView.evaluateJavaScript("window.fetchCount")
        XCTAssertEqual(count as? Int, 0)
        try await load(html, in: webView, delegate: delegate)
        let replacement = try await capture(webView)
        XCTAssertNotEqual(first.documentID, replacement.documentID)
    }

    private func installTranscriptFrames(in webView: WKWebView, nested: Bool, loadedCues: Bool) async throws {
        _ = try await webView.callAsyncJavaScript("""
            document.querySelector('iframe')?.remove();
            const frame = async parent => {
              const value = parent.createElement('iframe');
              value.srcdoc = '<!doctype html><title>Child player</title><body></body>';
              await new Promise((resolve, reject) => {
                const timer = setTimeout(() => reject(new Error('iframe load timeout')), 3000);
                value.onload = () => { clearTimeout(timer); resolve(); };
                parent.body.append(value);
              });
              return value;
            };
            const outer = await frame(document);
            const leaf = nested ? await frame(outer.contentDocument) : outer;
            window.transcriptLeaf = leaf;
            const child = leaf.contentWindow;
            child.document.body.innerHTML = '<video preload="none" src="https://example.com/child.m4a"></video>';
            const media = child.document.querySelector('video');
            if (loadedCues) {
              const track = media.addTextTrack('subtitles', 'Japanese', 'ja');
              track.mode = 'showing';
              track.addCue(new child.VTTCue(1, 2, 'Child caption'));
            } else {
              const track = child.document.createElement('track');
              track.kind = 'subtitles'; track.srclang = 'ja';
              track.src = 'https://example.com/child.vtt';
              media.append(track);
            }
            window.rootFetches = 0; child.childFetches = 0;
            window.fetch = () => { window.rootFetches++; throw new Error('wrong fetch realm'); };
            child.fetch = async () => {
              child.childFetches++;
              return new child.Response('WEBVTT\\n\\n00:00:01.000 --> 00:00:02.000\\nFetched child caption\\n',
                {status: 200, headers: {'Content-Type': 'text/vtt'}});
            };
            """, arguments: ["nested": nested, "loadedCues": loadedCues],
            in: nil, contentWorld: .page)
    }

    func testActualSameOriginSrcdocAndNestedCaptureRetiresReplacedOrDetachedChild() async throws {
        for nested in [false, true] {
            let webView = WKWebView()
            let delegate = TranscriptNavigation()
            try await load("<title>Article title</title><body>Article</body>", in: webView, delegate: delegate)
            try await installTranscriptFrames(in: webView, nested: nested, loadedCues: true)
            let first = try await capture(webView)
            let repeated = try await capture(webView)
            XCTAssertEqual(first.title, "Article title")
            XCTAssertEqual(first.documentURL, repeated.documentURL)
            XCTAssertEqual(first.documentID, repeated.documentID)
            XCTAssertEqual(first.mediaIdentity, repeated.mediaIdentity)
            XCTAssertEqual(first.mediaDocumentURL?.absoluteString, "about:srcdoc")
            XCTAssertEqual(first.languageCode, "ja")
            XCTAssertTrue(first.webVTT?.contains("Child caption") == true)
            try await installTranscriptFrames(in: webView, nested: nested, loadedCues: true)
            let replacement = try await capture(webView)
            XCTAssertEqual(replacement.documentURL, first.documentURL)
            XCTAssertEqual(replacement.documentID, first.documentID)
            XCTAssertEqual(replacement.title, first.title)
            XCTAssertEqual(replacement.mediaURL, first.mediaURL)
            XCTAssertNotEqual(replacement.mediaIdentity, first.mediaIdentity)
            _ = try await webView.evaluateJavaScript("document.querySelector('iframe').remove()")
            let detached = try await webView.callAsyncJavaScript(
                ReaderTranscriptMediaBridge.snapshotJavaScript, arguments: [:], in: nil, contentWorld: .page)
            XCTAssertEqual(detached as? String, "null")
        }
    }

    func testActualNestedChildCaptionFetchUsesOwningWindow() async throws {
        let webView = WKWebView()
        let delegate = TranscriptNavigation()
        try await load("<title>Article title</title><body>Article</body>", in: webView, delegate: delegate)
        try await installTranscriptFrames(in: webView, nested: true, loadedCues: false)
        let selected = try await capture(webView)
        XCTAssertNil(selected.webVTT)
        let output = try await webView.callAsyncJavaScript(
            ReaderTranscriptMediaBridge.captionsJavaScript,
            arguments: ["expectedDocumentID": selected.documentID,
                "expectedDocumentURL": selected.documentURL.absoluteString,
                "expectedMediaIdentity": selected.mediaIdentity,
                "expectedCaptionSelectionIdentity": try XCTUnwrap(selected.captionSelectionIdentity)],
            in: nil, contentWorld: .page)
        XCTAssertTrue((output as? String)?.contains("Fetched child caption") == true)
        let rootFetches = try await webView.evaluateJavaScript("window.rootFetches")
        let childFetches = try await webView.evaluateJavaScript("window.transcriptLeaf.contentWindow.childFetches")
        XCTAssertEqual(rootFetches as? Int, 0)
        XCTAssertEqual(childFetches as? Int, 1)
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

    func testRendererDeclaresTranscriptLanguageAndUsesUnknownForLegacyOrInvalidInput() {
        let source = URL(string: "https://example.com/watch")!
        let vtt = "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nこんにちは\n"
        let japanese = TranscriptPageAsset.fromWebVTT(
            key: "japanese", canonicalContentURL: source, title: "日本語", webVTT: vtt,
            languageCode: "ja")
        XCTAssertTrue(japanese.html.contains("<html lang=\"ja\">"))
        XCTAssertTrue(japanese.html.contains("こんにちは"))
        let regional = TranscriptPageAsset.makeHTML(
            title: "English", canonicalContentURL: source, cues: [], languageCode: "en_US")
        XCTAssertTrue(regional.contains("<html lang=\"en-US\">"))
        let legacy = TranscriptPageAsset.fromWebVTT(
            key: "legacy", canonicalContentURL: source, title: "Unknown", webVTT: vtt)
        XCTAssertTrue(legacy.html.contains("<html lang=\"und\">"))
        for language in ["", " \n", "ja\" onload=\"alert(1)"] {
            let html = TranscriptPageAsset.makeHTML(
                title: "Unknown", canonicalContentURL: source, cues: [], languageCode: language)
            XCTAssertTrue(html.contains("<html lang=\"und\">"))
            XCTAssertFalse(html.contains("onload="))
        }
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

extension ReaderTranscriptTests {
    private func shadowCaptionArguments(_ snapshot: ReaderTranscriptMediaSnapshot) throws -> [String: Any] {
        ["expectedDocumentID": snapshot.documentID,
         "expectedDocumentURL": snapshot.documentURL.absoluteString,
         "expectedMediaIdentity": snapshot.mediaIdentity,
         "expectedCaptionSelectionIdentity": try XCTUnwrap(snapshot.captionSelectionIdentity)]
    }

    private func shadowCaptions(_ snapshot: ReaderTranscriptMediaSnapshot, in webView: WKWebView) async throws -> String? {
        let value = try await webView.callAsyncJavaScript(
            ReaderTranscriptMediaBridge.captionsJavaScript,
            arguments: shadowCaptionArguments(snapshot), in: nil, contentWorld: .page)
        return value as? String
    }

    private func installShadowTranscriptPlayer(in webView: WKWebView, inFrame: Bool = false, remote: Bool = false) async throws {
        _ = try await webView.callAsyncJavaScript("""
            window.shadowTranscript?.host.remove()
            const host = document.createElement('div')
            const root = host.attachShadow({mode: 'open'})
            document.body.append(host)
            let view = window
            let parent = root
            let frame = null
            if (inFrame) {
              frame = document.createElement('iframe')
              frame.srcdoc = '<!doctype html><title>Shadow child</title><body></body>'
              await new Promise((resolve, reject) => {
                const timer = setTimeout(() => reject(new Error('shadow iframe load timeout')), 3000)
                frame.onload = () => { clearTimeout(timer); resolve() }
                root.append(frame)
              })
              view = frame.contentWindow
              parent = view.document.body
            }
            const innerHost = view.document.createElement('div')
            const innerRoot = innerHost.attachShadow({mode: 'open'})
            parent.append(innerHost)
            const media = view.document.createElement(inFrame ? 'audio' : 'video')
            media.preload = 'none'
            media.src = 'https://example.com/shadow.m4a'
            innerRoot.append(media)
            if (remote) {
              const element = view.document.createElement('track')
              element.kind = 'subtitles'
              element.srclang = 'ja'
              element.src = 'https://example.com/shadow.vtt'
              media.append(element)
              element.track.mode = 'disabled'
            } else {
              const track = media.addTextTrack('subtitles', 'Japanese', 'ja')
              track.mode = 'showing'
              track.addCue(new view.VTTCue(1, 2, 'Shadow <i>caption</i> &amp; &lt;safe&gt;'))
            }
            const fixture = {host, root, innerHost, innerRoot, media, view, frame, ownerFetches: 0, rootFetches: 0}
            window.shadowTranscript = fixture
            window.fetch = () => { fixture.rootFetches++; throw new Error('unexpected root fetch') }
            if (remote) view.fetch = async function(url, options) {
              if (this !== view || options.credentials !== 'same-origin') throw new Error('wrong caption transport owner')
              fixture.ownerFetches++
              return new view.Response('WEBVTT\\n\\n00:00:01.000 --> 00:00:02.000\\nFetched shadow caption\\n',
                {status: 200, headers: {'Content-Type': 'text/vtt'}})
            }
            """, arguments: ["inFrame": inFrame, "remote": remote], in: nil, contentWorld: .page)
    }

    func testActualOpenShadowCaptureExcludesClosedAndDetachedTrees() async throws {
        let webView = WKWebView()
        let delegate = TranscriptNavigation()
        defer { webView.stopLoading(); webView.navigationDelegate = nil }
        try await load("<title>Shadow article</title><body>Article</body>", in: webView, delegate: delegate)
        try await installShadowTranscriptPlayer(in: webView)
        let first = try await capture(webView)
        let repeated = try await capture(webView)
        XCTAssertEqual(first.title, "Shadow article")
        XCTAssertEqual(first.documentURL, first.mediaDocumentURL)
        XCTAssertEqual(first.languageCode, "ja")
        XCTAssertEqual(first.mediaIdentity, repeated.mediaIdentity)
        XCTAssertEqual(first.captionSelectionIdentity, repeated.captionSelectionIdentity)
        XCTAssertEqual(first.webVTT, "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nShadow caption &amp; &lt;safe&gt;\n")
        let loaded = try await shadowCaptions(first, in: webView)
        XCTAssertEqual(loaded, first.webVTT)
        let fetches = try await webView.evaluateJavaScript("window.shadowTranscript.rootFetches")
        XCTAssertEqual(fetches as? Int, 0)

        _ = try await webView.evaluateJavaScript("window.shadowTranscript.host.remove()")
        let detached = try await webView.callAsyncJavaScript(
            ReaderTranscriptMediaBridge.snapshotJavaScript, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(detached as? String, "null")
        _ = try await webView.callAsyncJavaScript("""
            const closedHost = document.createElement('div')
            document.body.append(closedHost)
            closedHost.attachShadow({mode: 'closed'}).append(window.shadowTranscript.media)
            """, arguments: [:], in: nil, contentWorld: .page)
        let closed = try await webView.callAsyncJavaScript(
            ReaderTranscriptMediaBridge.snapshotJavaScript, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(closed as? String, "null")
        _ = try await webView.callAsyncJavaScript("""
            const fixture = window.shadowTranscript
            fixture.innerRoot.append(fixture.media)
            document.body.append(fixture.host)
            """, arguments: [:], in: nil, contentWorld: .page)
        let fresh = try await capture(webView)
        let retry = try await shadowCaptions(fresh, in: webView)
        XCTAssertEqual(retry, first.webVTT)
    }

    func testActualNestedShadowHostReparentRetiresOriginalCapture() async throws {
        let webView = WKWebView()
        let delegate = TranscriptNavigation()
        defer { webView.stopLoading(); webView.navigationDelegate = nil }
        try await load("<title>Shadow article</title><body>Article</body>", in: webView, delegate: delegate)
        try await installShadowTranscriptPlayer(in: webView)
        let old = try await capture(webView)
        let sameNode = try await webView.callAsyncJavaScript("""
            const fixture = window.shadowTranscript
            const replacementHost = document.createElement('div')
            document.body.append(replacementHost)
            replacementHost.attachShadow({mode: 'open'}).append(fixture.innerHost)
            return fixture.innerRoot.querySelector('video') === fixture.media
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(sameNode as? Bool, true)
        let fresh = try await capture(webView)
        XCTAssertEqual(fresh.documentID, old.documentID)
        XCTAssertEqual(fresh.mediaURL, old.mediaURL)
        XCTAssertEqual(fresh.captionSelectionIdentity, old.captionSelectionIdentity)
        XCTAssertNotEqual(fresh.mediaIdentity, old.mediaIdentity)
        let stale = try await shadowCaptions(old, in: webView)
        let current = try await shadowCaptions(fresh, in: webView)
        XCTAssertNil(stale)
        XCTAssertEqual(current, old.webVTT)
        _ = try await webView.evaluateJavaScript("document.body.append(window.shadowTranscript.media)")
        let staleShadow = try await shadowCaptions(fresh, in: webView)
        XCTAssertNil(staleShadow)
        let light = try await capture(webView)
        let lightCaptions = try await shadowCaptions(light, in: webView)
        XCTAssertEqual(lightCaptions, old.webVTT)
    }

    func testActualShadowIframeWithChildShadowUsesOwningCaptionTransport() async throws {
        let webView = WKWebView()
        let delegate = TranscriptNavigation()
        defer { webView.stopLoading(); webView.navigationDelegate = nil }
        try await load("<title>Shadow article</title><body>Article</body>", in: webView, delegate: delegate)
        try await installShadowTranscriptPlayer(in: webView, inFrame: true, remote: true)
        let snapshot = try await capture(webView)
        XCTAssertEqual(snapshot.title, "Shadow article")
        XCTAssertEqual(snapshot.mediaDocumentURL?.absoluteString, "about:srcdoc")
        XCTAssertEqual(snapshot.languageCode, "ja")
        XCTAssertNil(snapshot.webVTT)
        let before = try await webView.evaluateJavaScript("window.shadowTranscript.ownerFetches")
        XCTAssertEqual(before as? Int, 0)
        let captions = try await shadowCaptions(snapshot, in: webView)
        XCTAssertTrue(captions?.contains("Fetched shadow caption") == true)
        let rootFetches = try await webView.evaluateJavaScript("window.shadowTranscript.rootFetches")
        let ownerFetches = try await webView.evaluateJavaScript("window.shadowTranscript.ownerFetches")
        XCTAssertEqual(rootFetches as? Int, 0)
        XCTAssertEqual(ownerFetches as? Int, 1)
        _ = try await webView.evaluateJavaScript("window.shadowTranscript.host.remove()")
        let retired = try await shadowCaptions(snapshot, in: webView)
        XCTAssertNil(retired)
        let after = try await webView.evaluateJavaScript("window.shadowTranscript.ownerFetches")
        XCTAssertEqual(after as? Int, 1)
        try await installShadowTranscriptPlayer(in: webView, inFrame: true, remote: true)
        let fresh = try await capture(webView)
        let retry = try await shadowCaptions(fresh, in: webView)
        XCTAssertTrue(retry?.contains("Fetched shadow caption") == true)
    }

    func testActualShadowReparentDuringBodyReadRejectsStaleTextAndAllowsRetry() async throws {
        let webView = WKWebView()
        let delegate = TranscriptNavigation()
        defer { webView.stopLoading(); webView.navigationDelegate = nil }
        try await load("<title>Shadow article</title><body>Article</body>", in: webView, delegate: delegate)
        try await installShadowTranscriptPlayer(in: webView, remote: true)
        let old = try await capture(webView)
        let output = try await webView.callAsyncJavaScript("""
            let release, entered, timer
            const started = new Promise(resolve => { entered = resolve })
            window.fetch = async (_url, options) => {
              window.shadowCaptionSignal = options.signal
              const stream = new ReadableStream({start(controller) {
                release = () => {
                  controller.enqueue(new TextEncoder().encode('WEBVTT\\n\\n00:00:01.000 --> 00:00:02.000\\nStale shadow\\n'))
                  controller.close()
                }
              }})
              const response = new Response(stream)
              const read = response.text.bind(response)
              response.text = () => { entered(); return read() }
              return response
            }
            const pending = (async () => {
              \(ReaderTranscriptMediaBridge.captionsJavaScript)
            })()
            try {
              await Promise.race([started, new Promise((_, reject) => {
                timer = setTimeout(() => reject(new Error('caption body never started')), 3000)
              })])
              const host = document.createElement('div')
              document.body.append(host)
              host.attachShadow({mode: 'open'}).append(window.shadowTranscript.media)
            } finally {
              clearTimeout(timer)
              release?.()
            }
            return await pending
            """, arguments: shadowCaptionArguments(old), in: nil, contentWorld: .page)
        XCTAssertNil(output as? String)
        let aborted = try await webView.evaluateJavaScript("window.shadowCaptionSignal.aborted")
        XCTAssertEqual(aborted as? Bool, true)
        _ = try await webView.callAsyncJavaScript("""
            window.fetch = async () => new Response('WEBVTT\\n\\n00:00:01.000 --> 00:00:02.000\\nFresh shadow\\n')
            """, arguments: [:], in: nil, contentWorld: .page)
        let fresh = try await capture(webView)
        XCTAssertEqual(fresh.captionSelectionIdentity, old.captionSelectionIdentity)
        XCTAssertNotEqual(fresh.mediaIdentity, old.mediaIdentity)
        let retry = try await shadowCaptions(fresh, in: webView)
        XCTAssertTrue(retry?.contains("Fresh shadow") == true)
    }
}
