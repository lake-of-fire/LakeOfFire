import Foundation
import XCTest
@preconcurrency import WebKit
import LakeOfFireCore
@testable import LakeOfFireReader
@testable import SwiftUIWebView

/// The router, caller, frame messages and command execution are real. Only the
/// platform play promise is held to expose retirement/cancellation interleavings.
@MainActor
private final class MediaRouterWebKitFixture: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    let caller = WebViewScriptCaller()
    let router = ReaderWebMediaPlaybackRouter()
    let bindingID = UUID()
    let scriptDocumentID = UUID().uuidString
    let tagID = UUID().uuidString
    let sourceURL = URL(string: "https://example.com/voice.m4a")!
    let ready = XCTestExpectation(description: "real WebKit frame ready")
    var frame: WKFrameInfo?
    var playDidStart: (() -> Void)?
    var cleanupDidComplete: (() -> Void)?

    override init() {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        webView.configuration.userContentController.add(self, name: "ready")
        webView.configuration.userContentController.add(self, name: "play")
        caller.installBinding(ownedBy: bindingID, asyncCaller: { [weak self] source, arguments, frame, world in
            guard let self else { throw CancellationError() }
            let result = try await self.webView.callAsyncJavaScript(source,
                arguments: arguments?.mapValues { $0 as Any } ?? [:], in: frame, contentWorld: world ?? .page)
            if arguments?["operation"] as? String == "cancel" {
                let completed = self.cleanupDidComplete
                self.cleanupDidComplete = nil
                completed?()
            }
            return .init(result)
        }, unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
    }

    func load() {
        webView.loadHTMLString("""
            <audio preload="none" src="\(sourceURL.absoluteString)"></audio>
            <script>
            window.__manabiReaderMediaDocumentID = '\(scriptDocumentID)';
            window.media = document.querySelector('audio');
            media.__manabiReaderMediaTagID = '\(tagID)';
            window.plays = [];
            window.pauseCalls = 0;
            const nativePause = media.pause.bind(media);
            media.pause = () => { pauseCalls++; nativePause(); };
            media.play = () => new Promise(resolve => {
                plays.push(resolve);
                window.webkit.messageHandlers.play.postMessage(plays.length);
            });
            window.webkit.messageHandlers.ready.postMessage('ready');
            </script>
            """, baseURL: URL(string: "https://example.com/article")!)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "ready" { frame = message.frameInfo; ready.fulfill() }
        if message.name == "play" {
            let started = playDidStart
            playDidStart = nil
            started?()
        }
    }

    func registerOwner() throws -> ReaderMediaPlaybackOwner {
        let message = WebViewMessage(frameInfo: try XCTUnwrap(frame), uuid: UUID(), name: "fixture", body: [:],
            javaScriptBindingToken: try XCTUnwrap(caller.currentJavaScriptBindingToken))
        return try XCTUnwrap(router.register(message: message, scriptCaller: caller,
            canonicalContentURL: URL(string: "https://example.com/article")!, sourceURL: sourceURL,
            tagID: tagID, scriptDocumentID: scriptDocumentID, providerResourceID: nil, isVideo: false))
    }

    func close() async {
        router.retire(for: caller)
        _ = try? await webView.evaluateJavaScript("window.plays?.forEach(resolve => resolve())")
        caller.clearBinding(ownedBy: bindingID)
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "ready")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "play")
    }
}

private final class MediaCandidateUpdateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var update: ReaderWebMediaCandidateUpdate?
    func store(_ value: ReaderWebMediaCandidateUpdate?) { lock.withLock { update = value } }
    var value: ReaderWebMediaCandidateUpdate? { lock.withLock { update } }
}

@MainActor
final class ReaderWebMediaPlaybackRouterTests: XCTestCase {
    private func makeFixture() async throws -> (MediaRouterWebKitFixture, ReaderMediaPlaybackOwner) {
        let fixture = MediaRouterWebKitFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        fixture.load()
        await fulfillment(of: [fixture.ready], timeout: 5)
        return (fixture, try fixture.registerOwner())
    }

    func testBridgeMarksOnlyItsSynthesizedNegotiationHeadersOptional() async throws {
        let (fixture, _) = try await makeFixture()
        let page = URL(string: "https://example.com/article")!
        let payload: [String: Any] = ["src": fixture.sourceURL.absoluteString,
            "pageSrc": page.absoluteString, "tagId": fixture.tagID,
            "scriptDocumentID": fixture.scriptDocumentID, "mimeType": "audio/mp4"]
        let info = try JSONDecoder().decode(ReaderWebMediaInfo.self,
            from: JSONSerialization.data(withJSONObject: payload))
        let message = WebViewMessage(frameInfo: try XCTUnwrap(fixture.frame), uuid: UUID(),
            name: ReaderWebMediaBridge.messageHandlerName, body: payload,
            javaScriptBindingToken: try XCTUnwrap(fixture.caller.currentJavaScriptBindingToken))
        let box = MediaCandidateUpdateBox()
        let observer = NotificationCenter.default.addObserver(forName: .readerWebMediaCandidateDidUpdate,
            object: nil, queue: nil) { box.store($0.userInfo?["update"] as? ReaderWebMediaCandidateUpdate) }
        defer {
            NotificationCenter.default.removeObserver(observer)
            ReaderWebMediaPlaybackRouter.shared.retire(for: fixture.caller)
        }
        ReaderWebMediaBridge.postCandidateUpdate(info, message: message, scriptCaller: fixture.caller, currentPageURL: page)
        let update = try XCTUnwrap(box.value)
        XCTAssertEqual(update.requestHeaders, ["Accept": "video/*,audio/*,application/vnd.apple.mpegurl",
            "Referer": "https://example.com/"])
        XCTAssertEqual(update.nativeOptionalRequestHeaders, update.requestHeaders)
        XCTAssertNil(update.requestHeaders["Cookie"])
        XCTAssertNil(update.requestHeaders["Authorization"])
    }

    func testOwnedSourceHintsAreExplicitAndGenericCandidateHeadersRemainRequired() async throws {
        let (fixture, owner) = try await makeFixture()
        let candidates = await fixture.router.sourceCandidates(owner: owner)
        let source = try XCTUnwrap(candidates.first)
        XCTAssertEqual(source.url, fixture.sourceURL)
        XCTAssertEqual(source.requestHeaders["Accept"], "video/*,audio/*,application/vnd.apple.mpegurl")
        XCTAssertEqual(source.requestHeaders["Referer"], "https://example.com/")
        XCTAssertEqual(source.nativeOptionalRequestHeaders, source.requestHeaders)
        let generic = ReaderMediaSourceCandidate(url: source.url, requestHeaders: source.requestHeaders)
        XCTAssertTrue(generic.nativeOptionalRequestHeaders.isEmpty)
    }

    private func verifyRetirement(_ kind: String) async throws {
        let (fixture, owner) = try await makeFixture()
        let started = expectation(description: "segment play entered")
        fixture.playDidStart = { started.fulfill() }
        let pending = Task { await fixture.router.playSegment(owner: owner, start: 1, end: 2, rewindTo: 0) }
        await fulfillment(of: [started], timeout: 5)
        _ = try await fixture.webView.evaluateJavaScript("plays[0]()")
        let accepted = await pending.value
        XCTAssertTrue(accepted)
        let cleanup = expectation(description: "retirement cleanup delivered to WebKit")
        fixture.cleanupDidComplete = { cleanup.fulfill() }
        switch kind {
        case "owner": fixture.router.retire(owner: owner)
        case "document": fixture.router.retire(documentID: owner.documentID)
        default: fixture.router.retire(for: fixture.caller)
        }
        await fulfillment(of: [cleanup], timeout: 5)
        XCTAssertFalse(fixture.router.isCurrent(owner: owner))
        let result = try await fixture.webView.callAsyncJavaScript("""
            media.currentTime = 2;
            media.dispatchEvent(new Event('timeupdate'));
            return {position: media.currentTime, pauses: pauseCalls,
                segment: !!media.__manabiReaderTranscriptSegment};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(result?["position"] as? Double, 2)
        XCTAssertEqual(result?["pauses"] as? Int, 0)
        XCTAssertEqual(result?["segment"] as? Bool, false)
    }

    func testOwnerRetirementRevokesInstalledSegment() async throws { try await verifyRetirement("owner") }
    func testDocumentRetirementRevokesInstalledSegment() async throws { try await verifyRetirement("document") }
    func testCallerRetirementRevokesInstalledSegment() async throws { try await verifyRetirement("caller") }

    func testCancelledHeldPlayCannotRetainOrRemoveSuccessorSegment() async throws {
        let (fixture, owner) = try await makeFixture()
        let firstStarted = expectation(description: "first play entered")
        fixture.playDidStart = { firstStarted.fulfill() }
        let first = Task { await fixture.router.playSegment(owner: owner, start: 1, end: 2, rewindTo: 0) }
        await fulfillment(of: [firstStarted], timeout: 5)
        let cancelled = expectation(description: "cancelled command cleanup delivered")
        fixture.cleanupDidComplete = { cancelled.fulfill() }
        first.cancel()
        await fulfillment(of: [cancelled], timeout: 5)
        let secondStarted = expectation(description: "successor play entered")
        fixture.playDidStart = { secondStarted.fulfill() }
        let second = Task { await fixture.router.playSegment(owner: owner, start: 4, end: 5, rewindTo: 3) }
        await fulfillment(of: [secondStarted], timeout: 5)
        let lateCleanup = expectation(description: "old completion cleanup delivered")
        fixture.cleanupDidComplete = { lateCleanup.fulfill() }
        _ = try await fixture.webView.evaluateJavaScript("plays[0](); plays[1]()")
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertFalse(firstResult)
        XCTAssertTrue(secondResult)
        await fulfillment(of: [lateCleanup], timeout: 5)
        let result = try await fixture.webView.callAsyncJavaScript("""
            const retained = !!media.__manabiReaderTranscriptSegment;
            media.currentTime = 5;
            media.dispatchEvent(new Event('timeupdate'));
            return {retained, position: media.currentTime, pauses: pauseCalls};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(result?["retained"] as? Bool, true)
        XCTAssertEqual(result?["position"] as? Double, 3)
        XCTAssertEqual(result?["pauses"] as? Int, 1)
    }
}
