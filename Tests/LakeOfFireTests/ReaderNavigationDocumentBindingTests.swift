import Foundation
import SwiftUIWebView
import XCTest
@testable import LakeOfFireReader

private actor ReaderDocumentBindingGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class ReaderNavigationDocumentBindingTests: XCTestCase {
    func testFontInjectionRejectsMountedCallerWithoutDocumentIdentity() async {
        let model = ReaderModeViewModel()
        let caller = WebViewScriptCaller()
        let owner = UUID()
        var evaluations = 0
        caller.installBinding(
            ownedBy: owner,
            asyncCaller: { _, _, _, _ in
                evaluations += 1
                return .init(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { nil },
            documentGenerationProvider: { nil }
        )
        defer { _ = caller.clearBinding(ownedBy: owner) }

        XCTAssertTrue(caller.canEvaluateJavaScript)
        XCTAssertNil(caller.currentJavaScriptBindingToken)
        await model.injectSharedFontIfNeeded(
            scriptCaller: caller,
            pageURL: URL(string: "ebook:///missing-document.epub")!
        )
        XCTAssertEqual(evaluations, 0)
    }

    func testRetiredFontTokenCannotEvaluateInReplacementBinding() async throws {
        let model = ReaderModeViewModel()
        let caller = WebViewScriptCaller()
        let firstOwner = UUID()
        caller.installBinding(
            ownedBy: firstOwner,
            asyncCaller: { _, _, _, _ in
                XCTFail("Retired binding must not evaluate")
                return .init(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        let retiredToken = try XCTUnwrap(caller.currentJavaScriptBindingToken)
        _ = caller.clearBinding(ownedBy: firstOwner)
        let replacementOwner = UUID()
        var replacementEvaluations = 0
        caller.installBinding(
            ownedBy: replacementOwner,
            asyncCaller: { _, _, _, _ in
                replacementEvaluations += 1
                return .init(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        defer { _ = caller.clearBinding(ownedBy: replacementOwner) }

        await model.injectSharedFontIfNeeded(
            scriptCaller: caller,
            pageURL: URL(string: "ebook:///retired-font.epub")!,
            requiring: retiredToken
        )
        XCTAssertEqual(replacementEvaluations, 0)
    }

    func testFinishedCallbackCannotSettleReplacementAfterFontWait() async {
        let model = ReaderModeViewModel()
        let caller = WebViewScriptCaller()
        let firstOwner = UUID()
        let gate = ReaderDocumentBindingGate()
        let entered = expectation(description: "font evaluation entered")
        caller.installBinding(
            ownedBy: firstOwner,
            asyncCaller: { _, _, _, _ in
                entered.fulfill()
                await gate.wait()
                return .init(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        let url = URL(string: "ebook:///same-document-url.epub")!
        model.beginReaderModeLoad(for: url)
        var state = WebViewState.empty
        state.pageURL = url
        let callback = Task { @MainActor in
            await model.onNavigationFinished(newState: state, scriptCaller: caller)
        }
        await fulfillment(of: [entered], timeout: 1)
        _ = caller.clearBinding(ownedBy: firstOwner)
        let replacementOwner = UUID()
        var successorEvaluations = 0
        caller.installBinding(
            ownedBy: replacementOwner,
            asyncCaller: { _, _, _, _ in
                successorEvaluations += 1
                return .init(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        defer { _ = caller.clearBinding(ownedBy: replacementOwner) }
        await gate.release()
        await callback.value

        XCTAssertTrue(model.isReaderModeLoading)
        XCTAssertTrue(model.isReaderModeLoadPending(for: url))
        XCTAssertEqual(successorEvaluations, 0)
    }

    func testRetiredFinishedEvaluationDoesNotClearSuccessorPendingState() async {
        let model = ReaderModeViewModel()
        let caller = WebViewScriptCaller()
        let firstOwner = UUID()
        let gate = ReaderDocumentBindingGate()
        let entered = expectation(description: "finished-state evaluation entered")
        caller.installBinding(
            ownedBy: firstOwner,
            asyncCaller: { javaScript, _, _, _ in
                // The actual finished-state read is delayed; font injection completes normally.
                if javaScript.contains("isNextLoadInReaderMode") {
                    entered.fulfill()
                    await gate.wait()
                    return .init(false)
                }
                return .init(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        let url = URL(string: "ebook:///finished-read.epub")!
        var state = WebViewState.empty
        state.pageURL = url
        let callback = Task { @MainActor in
            await model.onNavigationFinished(newState: state, scriptCaller: caller)
        }
        await fulfillment(of: [entered], timeout: 1)
        _ = caller.clearBinding(ownedBy: firstOwner)
        let replacementOwner = UUID()
        caller.installBinding(
            ownedBy: replacementOwner,
            asyncCaller: { _, _, _, _ in .init(nil) },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        defer { _ = caller.clearBinding(ownedBy: replacementOwner) }
        model.beginReaderModeLoad(for: url)
        await gate.release()
        await callback.value

        XCTAssertTrue(model.isReaderModeLoading)
        XCTAssertTrue(model.isReaderModeLoadPending(for: url))
    }
}
