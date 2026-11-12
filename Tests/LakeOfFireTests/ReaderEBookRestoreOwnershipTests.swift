import Foundation
import SwiftUI
import WebKit
import XCTest
import LakeOfFireContent
@testable import SwiftUIWebView
@testable import LakeOfFireReader

private final class RestoreOwnershipFrameProbe: NSObject, WKScriptMessageHandler {
    var receive: ((WKScriptMessage) -> Void)?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive?(message)
    }
}

@MainActor
final class ReaderEBookRestoreOwnershipTests: XCTestCase {
    private struct Fixture {
        let model: ReaderViewModel
        let caller: WebViewScriptCaller
        let coordinator: WebViewCoordinator
        let view: EnhancedWKWebView
        let mainFrame: WKFrameInfo
        let childFrame: WKFrameInfo
        let url: URL

        func issue(_ fraction: Float? = nil) throws -> ReaderEBookRestoreRequest {
            let bridge = try ReaderEBookInitialRestoreBridgeRequest(restore: fraction.map {
                ReaderContentEbookInitialRestore(cfi: "", fractionalCompletion: $0)
            })
            let binding = try XCTUnwrap(caller.currentJavaScriptBindingToken)
            let initializationID = try model.beginEBookRestoreInitialization(caller: caller, binding: binding)
            return try model.issueEBookRestore(bridge, caller: caller,
                binding: binding, loaderURL: url, initializationID: initializationID)
        }

        func result(_ request: ReaderEBookRestoreRequest, id: String? = nil,
                    locator: String? = nil) throws -> ReaderContentEbookInitialRestoreResult {
            try XCTUnwrap(ReaderContentEbookInitialRestoreResult(payload: [
                "requestID": id ?? request.requestID,
                "requestedLocator": locator ?? request.requestedLocator,
                "terminalState": request.requestedLocator == "none" ? "noTarget" : "satisfied",
                "navigationOk": true, "restoreSatisfied": request.requestedLocator != "none",
                "handledFractionalCompletion": 0, "currentFractionalCompletion": 0,
            ]))
        }

        func message(frame: WKFrameInfo? = nil,
                     binding: WebViewScriptCaller.JavaScriptBindingToken? = nil) -> WebViewMessage {
            .init(frameInfo: frame ?? mainFrame, uuid: UUID(), name: "ebookViewerLoaded", body: [:],
                  javaScriptBindingToken: binding ?? caller.currentJavaScriptBindingToken)
        }

        func capture(_ request: ReaderEBookRestoreRequest, frame: WKFrameInfo? = nil,
                     binding: WebViewScriptCaller.JavaScriptBindingToken? = nil) throws -> ReaderEBookRestoreRequest? {
            model.captureEBookRestore(result: try result(request), message: message(frame: frame, binding: binding),
                                      caller: caller, loaderURL: url)
        }
    }

    private func fixture() async throws -> Fixture {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/restore.epub"))
        let config = WKWebViewConfiguration()
        let probe = RestoreOwnershipFrameProbe()
        config.userContentController.add(probe, name: "restoreFrame")
        let view = EnhancedWKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: config)
        let ready = expectation(description: "real restore frames")
        ready.expectedFulfillmentCount = 2
        var frames: [String: WKFrameInfo] = [:]
        probe.receive = { message in
            guard let key = message.body as? String, frames[key] == nil else { return }
            frames[key] = message.frameInfo
            ready.fulfill()
        }
        addTeardownBlock { @MainActor in
            probe.receive = nil
            view.configuration.userContentController.removeScriptMessageHandler(forName: "restoreFrame")
            view.stopLoading()
        }
        view.loadHTMLString("""
            <script>window.webkit.messageHandlers.restoreFrame.postMessage('main')</script>
            <iframe srcdoc="<script>window.webkit.messageHandlers.restoreFrame.postMessage('child')</script>"></iframe>
            """, baseURL: url)
        await fulfillment(of: [ready], timeout: 10)
        let caller = WebViewScriptCaller()
        let coordinator = WebView(navigator: WebViewNavigator(), state: .constant(.empty)).makeCoordinatorForTesting()
        coordinator.updateScriptCaller(caller)
        coordinator.setWebView(view)
        coordinator.webView(view, didCommit: nil)
        coordinator.installScriptCallerBinding(for: view,
            asyncCaller: { _, _, _, _ in .init(nil) }, unsafeCaller: nil, snapshotCapture: nil)
        addTeardownBlock { @MainActor in coordinator.tearDownBindingsForDetachedWebView(view) }
        return Fixture(model: ReaderViewModel(systemScripts: [], observeLibraryChanges: false),
                       caller: caller, coordinator: coordinator, view: view,
                       mainFrame: try XCTUnwrap(frames["main"]), childFrame: try XCTUnwrap(frames["child"]), url: url)
    }

    func testDefaultOpeningHasUniqueNativeCorrelationAndSettlesExactlyOnce() async throws {
        let f = try await fixture()
        let first = try f.issue()
        XCTAssertEqual(first.requestedLocator, "none")
        XCTAssertEqual(first.javaScriptArgument["requestID"] as? String, first.requestID)
        XCTAssertEqual(try f.capture(first), first)
        XCTAssertTrue(f.model.settleEBookRestore(first, caller: f.caller, loaderURL: f.url))
        XCTAssertNil(try f.capture(first))
        XCTAssertFalse(f.model.settleEBookRestore(first, caller: f.caller, loaderURL: f.url))
        let successor = try f.issue()
        XCTAssertNotEqual(first.requestID, successor.requestID)
        XCTAssertNil(try f.capture(first))
        XCTAssertEqual(try f.capture(successor), successor)
    }

    func testSuccessorInSameDocumentRejectsOldResultAndSettlement() async throws {
        let f = try await fixture()
        let first = try f.issue(0)
        XCTAssertEqual(try f.capture(first), first)
        let successor = try f.issue(0)
        XCTAssertFalse(f.model.isCurrentEBookRestore(first, caller: f.caller, loaderURL: f.url))
        XCTAssertFalse(f.model.settleEBookRestore(first, caller: f.caller, loaderURL: f.url))
        XCTAssertNil(try f.capture(first))
        XCTAssertEqual(try f.capture(successor), successor)
    }

    func testBindingCallerContentAndFrameAreRequiredAlongsideWireIdentity() async throws {
        let f = try await fixture()
        let request = try f.issue(0)
        XCTAssertNil(try f.capture(request, frame: f.childFrame))
        let wrongID = try f.result(request, id: "other")
        XCTAssertNil(f.model.captureEBookRestore(result: wrongID, message: f.message(), caller: f.caller, loaderURL: f.url))
        let wrongLocator = try f.result(request, locator: "cfi")
        XCTAssertNil(f.model.captureEBookRestore(result: wrongLocator, message: f.message(), caller: f.caller, loaderURL: f.url))
        XCTAssertFalse(f.model.isCurrentEBookRestore(request, caller: WebViewScriptCaller(), loaderURL: f.url))
        XCTAssertFalse(f.model.isCurrentEBookRestore(request, caller: f.caller,
            loaderURL: try XCTUnwrap(URL(string: "https://example.invalid/other.epub"))))
        XCTAssertEqual(try f.capture(request), request)
        let oldBinding = try XCTUnwrap(f.caller.currentJavaScriptBindingToken)
        f.coordinator.webView(f.view, didCommit: nil)
        XCTAssertNil(try f.capture(request, binding: oldBinding))
        XCTAssertFalse(f.model.settleEBookRestore(request, caller: f.caller, loaderURL: f.url))
        let replacement = try f.issue(0)
        XCTAssertEqual(try f.capture(replacement), replacement)
    }

    func testCancelledDispatchCleanupCannotDiscardAReentrantSuccessor() async throws {
        let f = try await fixture()
        let old = try f.issue(0)
        let successor = try f.issue(0)
        await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            f.model.discardEBookRestore(old)
        }.value
        XCTAssertEqual(try f.capture(successor), successor)
        await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            f.model.discardEBookRestore(successor)
        }.value
        XCTAssertNil(try f.capture(successor))
    }

    func testSuccessorInitializationImmediatelyRevokesPendingAndOldPreparation() async throws {
        let f = try await fixture()
        let request = try f.issue(0)
        let binding = try XCTUnwrap(f.caller.currentJavaScriptBindingToken)
        let older = try f.model.beginEBookRestoreInitialization(caller: f.caller, binding: binding)
        XCTAssertNil(try f.capture(request))
        XCTAssertFalse(f.model.isCurrentEBookRestore(request, caller: f.caller, loaderURL: f.url))
        let current = try f.model.beginEBookRestoreInitialization(caller: f.caller, binding: binding)
        XCTAssertFalse(f.model.isCurrentEBookRestoreInitialization(older))
        XCTAssertTrue(f.model.isCurrentEBookRestoreInitialization(current))
        XCTAssertThrowsError(try f.model.issueEBookRestore(nil, caller: f.caller,
            binding: binding, loaderURL: f.url, initializationID: older)) {
            XCTAssertTrue($0 is CancellationError)
        }
        let successor = try f.model.issueEBookRestore(nil, caller: f.caller,
            binding: binding, loaderURL: f.url, initializationID: current)
        XCTAssertEqual(try f.capture(successor), successor)
    }

    func testLoaderAndFragmentNormalizationKeepsTheSameContentBoundary() async throws {
        let f = try await fixture()
        let request = try f.issue(0)
        let loader = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: f.url))
        XCTAssertEqual(ReaderViewModel.restoreContentURL(loader), f.url)
        XCTAssertTrue(f.model.isCurrentEBookRestore(request, caller: f.caller, loaderURL: loader))
        XCTAssertEqual(ReaderViewModel.restoreContentURL(try XCTUnwrap(URL(string: f.url.absoluteString + "#chapter"))), f.url)
    }
}
