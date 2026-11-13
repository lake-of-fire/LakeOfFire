import Foundation
import SwiftUI
import WebKit
import XCTest
import LakeOfFireContent
@testable import SwiftUIWebView
@testable import LakeOfFireReader

private final class HistoryActionFrameProbe: NSObject, WKScriptMessageHandler {
    var receive: ((WKScriptMessage) -> Void)?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive?(message)
    }
}

@MainActor
private final class HistoryActionEvaluator {
    struct Call {
        let arguments: [String: any Sendable]?
        let frame: WKFrameInfo?
    }
    var calls: [Call] = []
    var result: Any? = true
    var onEvaluate: (@MainActor () async throws -> Void)?

    func evaluate(arguments: [String: any Sendable]?, frame: WKFrameInfo?) async throws
        -> WebViewScriptCaller.JavaScriptEvaluationResult {
        calls.append(.init(arguments: arguments, frame: frame))
        try await onEvaluate?()
        return .init(result)
    }
}

/// These tests exercise the production receiver/action and Web29 evaluator
/// with real WK frame receipts and a controlled evaluation endpoint. They do
/// not initialize ReaderViewModel's Realm observers or execute the JS bridge.
@MainActor
final class ReaderEBookHistoryActionTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let receiver = ReaderEBookNativeHistoryState()
        let caller: WebViewScriptCaller
        let coordinator: WebViewCoordinator
        let view: EnhancedWKWebView
        let mainFrame: WKFrameInfo
        let childFrame: WKFrameInfo
        let url: URL
        let evaluator: HistoryActionEvaluator
        var currentCaller: WebViewScriptCaller
        var publicationCount = 0
        var overlay: ReaderEBookNativeOverlayState?

        init(caller: WebViewScriptCaller, coordinator: WebViewCoordinator,
             view: EnhancedWKWebView, mainFrame: WKFrameInfo, childFrame: WKFrameInfo,
             url: URL, evaluator: HistoryActionEvaluator) {
            self.caller = caller
            self.currentCaller = caller
            self.coordinator = coordinator
            self.view = view
            self.mainFrame = mainFrame
            self.childFrame = childFrame
            self.url = url
            self.evaluator = evaluator
        }

        func body(token: String = "1") -> [String: Any] {
            ["historyActionContext": ["kind": "ebook-history-action-v1", "loadToken": token,
                                       "loadURL": url.absoluteString],
             "percentLabel": " 25% \n", "relocateBackEnabled": true]
        }

        func message(sequence: UInt64? = 1, body: Any? = nil, frame: WKFrameInfo? = nil,
                     binding: WebViewScriptCaller.JavaScriptBindingToken? = nil) -> WebViewMessage {
            .init(frameInfo: frame ?? mainFrame, uuid: UUID(), name: "ebookNativeOverlayState",
                  body: body ?? self.body(), receiptSequence: sequence,
                  javaScriptBindingToken: binding ?? caller.currentJavaScriptBindingToken)
        }

        func receive(_ message: WebViewMessage, loaderURL: URL? = nil) {
            receiver.receive(message: message, caller: caller, loaderURL: loaderURL ?? url,
                callerIsCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.currentCaller === self.caller
                },
                publish: { [weak self] _, overlay, isCurrent in
                    guard let self, isCurrent() else { return }
                    self.publicationCount += 1
                    if let overlay { self.overlay = overlay }
                })
        }
    }

    private func fixture() async throws -> Fixture {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/native-history.epub"))
        let configuration = WKWebViewConfiguration()
        let probe = HistoryActionFrameProbe()
        configuration.userContentController.add(probe, name: "nativeHistoryFrame")
        let view = EnhancedWKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        let framesReady = expectation(description: "real main and child history frames")
        framesReady.expectedFulfillmentCount = 2
        var frames: [String: WKFrameInfo] = [:]
        probe.receive = { message in
            guard let key = message.body as? String, frames[key] == nil else { return }
            frames[key] = message.frameInfo
            framesReady.fulfill()
        }
        addTeardownBlock { @MainActor in
            probe.receive = nil
            view.configuration.userContentController.removeScriptMessageHandler(forName: "nativeHistoryFrame")
            view.stopLoading()
        }
        view.loadHTMLString("""
            <script>window.webkit.messageHandlers.nativeHistoryFrame.postMessage('main')</script>
            <iframe srcdoc="<script>window.webkit.messageHandlers.nativeHistoryFrame.postMessage('child')</script>"></iframe>
            """, baseURL: url)
        await fulfillment(of: [framesReady], timeout: 10)
        let mainFrame = try XCTUnwrap(frames["main"])
        let childFrame = try XCTUnwrap(frames["child"])
        XCTAssertTrue(mainFrame.isMainFrame)
        XCTAssertFalse(childFrame.isMainFrame)
        XCTAssertEqual(ReaderViewModel.restoreContentURL(try XCTUnwrap(mainFrame.request.url)), url)

        let caller = WebViewScriptCaller()
        let navigator = WebViewNavigator()
        let coordinator = WebView(navigator: navigator, state: .constant(.empty)).makeCoordinatorForTesting()
        coordinator.updateScriptCaller(caller)
        coordinator.setWebView(view)
        coordinator.webView(view, didCommit: nil)
        let evaluator = HistoryActionEvaluator()
        coordinator.installScriptCallerBinding(for: view,
            asyncCaller: { _, arguments, frame, _ in
                try await evaluator.evaluate(arguments: arguments, frame: frame)
            }, unsafeCaller: nil, snapshotCapture: nil)
        addTeardownBlock { @MainActor in
            evaluator.onEvaluate = nil
            coordinator.tearDownBindingsForDetachedWebView(view)
        }
        return Fixture(caller: caller, coordinator: coordinator, view: view,
                       mainFrame: mainFrame, childFrame: childFrame, url: url, evaluator: evaluator)
    }

    private func expectCancellation(_ operation: () async throws -> Void,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Retired action succeeded", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line) }
    }

    func testContextAcceptsOnlyCanonicalPositiveSafeIntegerStrings() throws {
        for token in ["1", "9007199254740991"] {
            let context = try XCTUnwrap(ReaderEBookHistoryAction.Context(
                kind: "ebook-history-action-v1", loadToken: token, loadURL: "ebook://book/a.epub"
            ))
            XCTAssertEqual(try JSONDecoder().decode(ReaderEBookHistoryAction.Context.self,
                from: JSONEncoder().encode(context)), context)
        }
        for token in ["", "0", "-1", "+1", "01", "1.0", "1e2", " 1", "1 ", "9007199254740992"] {
            XCTAssertNil(ReaderEBookHistoryAction.Context(kind: "ebook-history-action-v1", loadToken: token,
                                                         loadURL: "ebook://book/a.epub"), token)
        }
        XCTAssertNil(ReaderEBookHistoryAction.Context(kind: "other", loadToken: "1", loadURL: "a"))
        XCTAssertNil(ReaderEBookHistoryAction.Context(kind: "ebook-history-action-v1", loadToken: "1", loadURL: ""))
        let numeric = Data(#"{"kind":"ebook-history-action-v1","loadToken":1,"loadURL":"ebook://book/a.epub"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ReaderEBookHistoryAction.Context.self, from: numeric))
    }

    func testReceiverPreservesExistingOverlayDecodingAndSameContextActionIdentity() async throws {
        let f = try await fixture()
        var body = f.body()
        body.merge(["hideNavigationDueToScroll": false, "navigationHidden": true,
                    "titleLocationLabel": " Chapter 2 ", "titleLocationVisible": true,
                    "bookTitleLabel": " Book ", "pagesLeftLabel": " 7 left ", "source": " refresh ",
                    "relocateForwardEnabled": true, "currentPageNumber": NSNumber(value: 2), "totalPages": 9]) { _, new in new }
        f.receive(f.message(body: body))
        let first = try XCTUnwrap(f.receiver.action)
        XCTAssertTrue(first.isCurrent)
        XCTAssertEqual(f.overlay?.percentLabel, "25%")
        XCTAssertEqual(f.overlay?.navigationHidden, false)
        XCTAssertEqual(f.overlay?.titleLocationLabel, "Chapter 2")
        XCTAssertEqual(f.overlay?.titleLocationVisible, true)
        XCTAssertEqual(f.overlay?.bookTitleLabel, "Book")
        XCTAssertEqual(f.overlay?.pagesLeftLabel, "7 left")
        XCTAssertEqual(f.overlay?.source, "refresh")
        XCTAssertEqual(f.overlay?.relocateBackEnabled, true)
        XCTAssertEqual(f.overlay?.relocateForwardEnabled, true)
        XCTAssertEqual(f.overlay?.currentPageNumber, 2)
        XCTAssertEqual(f.overlay?.totalPages, 9)
        f.receive(f.message(sequence: 2))
        XCTAssertTrue(f.receiver.action === first)
        XCTAssertEqual(first.receiptSequence, 1)
        f.receive(f.message(sequence: 3, body: f.body(token: "2")))
        XCTAssertFalse(first.isCurrent)
        XCTAssertFalse(f.receiver.action === first)
    }

    func testStaleDuplicateAndMissingReceiptsCannotClearAnAdmittedAction() async throws {
        let f = try await fixture()
        f.receive(f.message(sequence: 9))
        let first = try XCTUnwrap(f.receiver.action)
        let staleSequences: [UInt64?] = [8, 9, nil, 0]
        for sequence in staleSequences {
            f.receive(f.message(sequence: sequence, body: ["percentLabel": "stale"]))
        }
        let missingBinding = WebViewMessage(frameInfo: f.mainFrame, uuid: UUID(), name: "ebookNativeOverlayState",
                                           body: f.body(), receiptSequence: 10)
        f.receive(missingBinding)
        XCTAssertTrue(f.receiver.action === first)
        XCTAssertTrue(first.isCurrent)
        XCTAssertEqual(f.publicationCount, 1)
        XCTAssertEqual(f.overlay?.percentLabel, "25%")
    }

    func testReaderLoaderAndFragmentNormalizationPreservesExactJavaScriptContext() async throws {
        let f = try await fixture()
        let loaderURL = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: f.url))
        let exactLoadURL = f.url.absoluteString + "#chapter-2"
        let body: [String: Any] = ["historyActionContext": ["kind": "ebook-history-action-v1",
            "loadToken": "1", "loadURL": exactLoadURL]]
        f.receive(f.message(body: body), loaderURL: loaderURL)
        let action = try XCTUnwrap(f.receiver.action)
        XCTAssertTrue(action.isCurrent)
        XCTAssertEqual(action.context.loadURL, exactLoadURL)
        let succeeded = try await action.perform(direction: .back, shouldPerform: { true })
        XCTAssertTrue(succeeded)
        let json = try XCTUnwrap(f.evaluator.calls.last?.arguments?["historyActionContextJSON"] as? String)
        XCTAssertEqual(try JSONDecoder().decode(ReaderEBookHistoryAction.Context.self,
            from: Data(json.utf8)).loadURL, exactLoadURL)
    }

    func testChildMismatchedPageAndRetiredCallerCannotPublish() async throws {
        let f = try await fixture()
        f.receive(f.message())
        let first = try XCTUnwrap(f.receiver.action)
        f.receive(f.message(sequence: 2, frame: f.childFrame))
        f.receive(f.message(sequence: 3), loaderURL: try XCTUnwrap(URL(string: "https://example.invalid/other.epub")))
        f.receive(f.message(sequence: 4), loaderURL: try XCTUnwrap(URL(string: "https://example.invalid/article")))
        f.currentCaller = WebViewScriptCaller()
        f.receive(f.message(sequence: 5))
        XCTAssertTrue(f.receiver.action === first)
        XCTAssertFalse(first.isCurrent)
        XCTAssertEqual(f.publicationCount, 1)
    }

    func testCurrentMissingMalformedOrMismatchedContextRetiresActionAndAllowsFreshRetry() async throws {
        let f = try await fixture()
        var sequence: UInt64 = 1
        let invalidBodies: [Any] = [
            ["percentLabel": " 50% "],
            ["historyActionContext": NSNull()],
            ["historyActionContext": ["kind": "ebook-history-action-v1", "loadToken": 1,
                                      "loadURL": f.url.absoluteString]],
            ["historyActionContext": ["kind": "ebook-history-action-v1", "loadToken": "1",
                                      "loadURL": "https://example.invalid/other.epub"]],
            "invalid body"
        ]
        for body in invalidBodies {
            f.receive(f.message(sequence: sequence)); sequence += 1
            let old = try XCTUnwrap(f.receiver.action)
            f.receive(f.message(sequence: sequence, body: body)); sequence += 1
            XCTAssertNil(f.receiver.action)
            XCTAssertFalse(old.isCurrent)
            f.receive(f.message(sequence: sequence)); sequence += 1
            XCTAssertNotNil(f.receiver.action)
            XCTAssertFalse(f.receiver.action === old)
            XCTAssertFalse(old.isCurrent)
        }
    }

    func testSameURLNativeDocumentReplacementRejectsOldMessageAndAction() async throws {
        let f = try await fixture()
        let oldBinding = try XCTUnwrap(f.caller.currentJavaScriptBindingToken)
        f.receive(f.message(sequence: 100))
        let old = try XCTUnwrap(f.receiver.action)
        f.coordinator.webView(f.view, didCommit: nil)
        f.receive(f.message(sequence: 101, binding: oldBinding))
        XCTAssertTrue(f.receiver.action === old)
        XCTAssertFalse(old.isCurrent)
        f.receive(f.message(sequence: 1))
        let replacement = try XCTUnwrap(f.receiver.action)
        XCTAssertFalse(replacement === old)
        XCTAssertTrue(replacement.isCurrent)
        await expectCancellation { _ = try await old.perform(direction: .back, shouldPerform: { true }) }
        XCTAssertTrue(f.evaluator.calls.isEmpty)
    }

    func testClearRetiresBeforePublicationAndCannotOverwriteReentrantSuccessor() async throws {
        let f = try await fixture()
        f.receive(f.message(sequence: 1))
        let old = try XCTUnwrap(f.receiver.action)
        f.receiver.clear(source: "close") { action, overlay, isCurrent in
            XCTAssertNil(action)
            XCTAssertFalse(old.isCurrent)
            XCTAssertEqual(overlay?.relocateBackEnabled, false)
            XCTAssertEqual(overlay?.source, "close")
            XCTAssertTrue(isCurrent())
            f.receive(f.message(sequence: 2, body: f.body(token: "2")))
            XCTAssertFalse(isCurrent())
        }
        let successor = try XCTUnwrap(f.receiver.action)
        XCTAssertTrue(successor.isCurrent)
        XCTAssertEqual(successor.context.loadToken, "2")
        f.receive(f.message(sequence: 1, body: ["historyActionContext": NSNull()]))
        XCTAssertTrue(f.receiver.action === successor)
    }

    func testReentrantReceiptInvalidatesOuterPublicationWithoutRetiringSuccessor() async throws {
        let f = try await fixture()
        f.receiver.receive(message: f.message(sequence: 1), caller: f.caller, loaderURL: f.url,
            callerIsCurrent: { f.currentCaller === f.caller },
            publish: { action, _, isCurrent in
                XCTAssertTrue(isCurrent())
                XCTAssertTrue(f.receiver.action === action)
                f.receive(f.message(sequence: 2, body: f.body(token: "2")))
                XCTAssertFalse(isCurrent())
                XCTAssertFalse(action?.isCurrent ?? true)
            })
        XCTAssertEqual(f.receiver.action?.context.loadToken, "2")
        XCTAssertTrue(f.receiver.action?.isCurrent ?? false)
    }

    func testPerformCarriesExactContextAndOriginalMainFrameWithoutMulticast() async throws {
        let f = try await fixture()
        f.caller.addMultiTargetFrame(f.childFrame, uuid: "other-frame")
        f.receive(f.message())
        let action = try XCTUnwrap(f.receiver.action)
        for direction in [ReaderEBookHistoryAction.Direction.back, .forward] {
            let succeeded = try await action.perform(direction: direction, shouldPerform: { true })
            XCTAssertTrue(succeeded)
            let call = try XCTUnwrap(f.evaluator.calls.last)
            XCTAssertTrue(call.frame === f.mainFrame)
            XCTAssertEqual(call.arguments?["direction"] as? String, direction.rawValue)
            let json = try XCTUnwrap(call.arguments?["historyActionContextJSON"] as? String)
            XCTAssertEqual(try JSONDecoder().decode(ReaderEBookHistoryAction.Context.self, from: Data(json.utf8)), action.context)
        }
        XCTAssertEqual(f.evaluator.calls.count, 2)
    }

    func testCancelledAndRetiredConsumerActionsDoNotDispatch() async throws {
        let f = try await fixture()
        f.receive(f.message())
        let action = try XCTUnwrap(f.receiver.action)
        await expectCancellation { _ = try await action.perform(direction: .back, shouldPerform: { false }) }
        let cancelled = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await action.perform(direction: .forward, shouldPerform: { true }); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(cancelled)
        await expectCancellation {
            _ = try await action.perform(direction: .back, shouldPerform: {
                f.receiver.clear(source: "retire") { _, _, _ in }
                return true
            })
        }
        XCTAssertTrue(f.evaluator.calls.isEmpty)
    }

    func testDocumentOrConsumerReplacementDuringEvaluationCannotReturnSuccess() async throws {
        let f = try await fixture()
        f.receive(f.message())
        let action = try XCTUnwrap(f.receiver.action)
        f.evaluator.onEvaluate = { f.coordinator.webView(f.view, didCommit: nil); await Task.yield() }
        await expectCancellation { _ = try await action.perform(direction: .back, shouldPerform: { true }) }
        XCTAssertEqual(f.evaluator.calls.count, 1)
        f.evaluator.onEvaluate = nil
        f.receive(f.message(sequence: 2))
        let next = try XCTUnwrap(f.receiver.action)
        var permitted = true
        f.evaluator.onEvaluate = { permitted = false; await Task.yield() }
        await expectCancellation { _ = try await next.perform(direction: .forward, shouldPerform: { permitted }) }
        XCTAssertEqual(f.evaluator.calls.count, 2)
    }

    func testEvaluatorFailureAndFalseResultRemainRetryableForCurrentAction() async throws {
        enum Failure: Error { case ordinary }
        let f = try await fixture()
        f.receive(f.message())
        let action = try XCTUnwrap(f.receiver.action)
        f.evaluator.onEvaluate = { throw Failure.ordinary }
        do { _ = try await action.perform(direction: .back, shouldPerform: { true }); XCTFail("Expected failure") }
        catch Failure.ordinary {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertTrue(action.isCurrent)
        f.evaluator.onEvaluate = nil
        f.evaluator.result = false
        let rejected = try await action.perform(direction: .back, shouldPerform: { true })
        XCTAssertFalse(rejected)
        f.evaluator.result = true
        let retried = try await action.perform(direction: .back, shouldPerform: { true })
        XCTAssertTrue(retried)
        XCTAssertEqual(f.evaluator.calls.count, 3)
    }
}
