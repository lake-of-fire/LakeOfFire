#if DEBUG
import Foundation
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader
@testable import SwiftUIWebView

@MainActor
final class ReaderTitleSynchronizationTests: XCTestCase {
    private enum Failure: Error { case transient }

    @MainActor
    private final class Fixture {
        let reader = ReaderContent()
        let row = HistoryRecord()
        let caller = WebViewScriptCaller()

        init(title: String) {
            row.url = URL(string: "https://title-sync.test/\(UUID().uuidString)")!
            row.title = title
            row.updateCompoundKey()
            caller.asyncCaller = { _, _, _, _ in WebViewScriptCaller.JavaScriptEvaluationResult(nil) }
        }

        func load() async throws { try await reader.load(url: row.url) { _ in self.row } }
        func snapshot() throws -> ReaderContentTitleSnapshot { try XCTUnwrap(reader.captureTitleSnapshot()) }
        func binding() throws -> WebViewScriptCaller.JavaScriptBindingToken {
            try XCTUnwrap(caller.currentJavaScriptBindingToken)
        }
    }

    @MainActor
    private final class Gate {
        private let arrival = XCTestExpectation(description: "Title evaluator entered")
        private var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !entered else { XCTFail("One-shot title gate entered twice"); return }
            entered = true
            arrival.fulfill()
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            let result = await XCTWaiter.fulfillment(of: [arrival], timeout: 5)
            if result != .completed { release(); XCTFail("Title evaluator never entered") }
        }

        func release() {
            guard !released else { return }
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    func testAuthoritativeEmptyTitleUsesExistingUntitledFormatterThroughRealCaller() async throws {
        let fixture = Fixture(title: ""), synchronization = ReaderTitleSynchronization()
        try await fixture.load()
        let snapshot = try fixture.snapshot(), binding = try fixture.binding()
        var calls = 0
        var deliveredArguments: [String: any Sendable]?
        fixture.caller.asyncCaller = { _, arguments, _, _ in
            calls += 1
            deliveredArguments = arguments
            return WebViewScriptCaller.JavaScriptEvaluationResult(nil)
        }
        // Replacing the installed evaluator also replaces the binding token.
        let currentBinding = try fixture.binding()
        XCTAssertNotEqual(binding, currentBinding)
        let accepted = await synchronization.deliver(snapshot: snapshot, binding: currentBinding,
            isCurrent: { fixture.caller.currentJavaScriptBindingToken == currentBinding }) { script, arguments, current in
            _ = try await fixture.caller.evaluateJavaScriptInMultiTargetFrames(script,
                arguments: arguments, propagatesFrameErrors: true, continueWhile: current)
        }
        XCTAssertTrue(accepted)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(deliveredArguments?["title"] as? String, "Untitled")
        XCTAssertEqual(deliveredArguments?["bodyClassName"] as? String,
            ReaderContentLoader.snippetReaderTitleSuppressionBodyClass)
        XCTAssertEqual(deliveredArguments?["hideReaderTitle"] as? Bool, false)
        synchronization.retire()
    }

    func testSnippetSuppressionFlagChangeDeliversEvenWhenFormattedTitleIsUnchanged() async throws {
        let fixture = Fixture(title: "Snippet title"), synchronization = ReaderTitleSynchronization()
        fixture.row.url = try XCTUnwrap(ReaderContentLoader.snippetURL(key: UUID().uuidString))
        fixture.row.isTitlePrefixOfContent = true
        fixture.row.updateCompoundKey()
        try await fixture.load()
        let binding = try fixture.binding()
        let generated = try fixture.snapshot()
        var values = [(String?, Bool?)]()
        let first = await synchronization.deliver(snapshot: generated, binding: binding, isCurrent: { true }) {
            _, arguments, _ in values.append((arguments["title"] as? String, arguments["hideReaderTitle"] as? Bool))
        }
        fixture.row.isTitlePrefixOfContent = false
        fixture.reader.refreshObservedContentState()
        let authored = try fixture.snapshot()
        let second = await synchronization.deliver(snapshot: authored, binding: binding, isCurrent: { true }) {
            _, arguments, _ in values.append((arguments["title"] as? String, arguments["hideReaderTitle"] as? Bool))
        }
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(values.count, 2)
        if values.count == 2 {
            XCTAssertEqual(values[0].0, values[1].0)
            XCTAssertEqual(values[0].1, true)
            XCTAssertEqual(values[1].1, false)
        }
        synchronization.retire()
    }

    func testSuccessfulAckDeduplicatesButFailureAndRenderReadyRecoveryRedispatch() async throws {
        let fixture = Fixture(title: "Current"), synchronization = ReaderTitleSynchronization()
        try await fixture.load()
        let snapshot = try fixture.snapshot(), binding = try fixture.binding()
        var evaluations = 0
        let failed = await synchronization.deliver(snapshot: snapshot, binding: binding, isCurrent: { true }) { _, _, _ in
            evaluations += 1
            throw Failure.transient
        }
        let retry = await synchronization.deliver(snapshot: snapshot, binding: binding, isCurrent: { true }) { _, _, _ in
            evaluations += 1
        }
        let duplicate = await synchronization.deliver(snapshot: snapshot, binding: binding, isCurrent: { true }) { _, _, _ in
            evaluations += 1
        }
        let ready = await synchronization.deliver(snapshot: snapshot, binding: binding, renderReady: true,
            isCurrent: { true }) { _, _, _ in evaluations += 1 }
        XCTAssertFalse(failed)
        XCTAssertTrue(retry)
        XCTAssertTrue(duplicate)
        XCTAssertTrue(ready)
        XCTAssertEqual(evaluations, 3)
        synchronization.retire()
    }

    func testChangedSourceSupersedesHeldCompletionAndOldAckCannotSuppressCurrentTitle() async throws {
        let fixture = Fixture(title: "Old"), synchronization = ReaderTitleSynchronization(), gate = Gate()
        try await fixture.load()
        let oldSnapshot = try fixture.snapshot(), binding = try fixture.binding()
        var oldCouldContinue = true, newCalls = 0
        let old = Task { @MainActor in
            await synchronization.deliver(snapshot: oldSnapshot, binding: binding, isCurrent: { true }) { _, _, current in
                await gate.wait()
                oldCouldContinue = current()
            }
        }
        await gate.waitUntilEntered()
        fixture.row.title = "New"
        fixture.reader.refreshObservedContentState()
        // Avoid throwing setup while the old noncooperative collaborator is held.
        let newSnapshot = fixture.reader.captureTitleSnapshot()
        var newAccepted = false
        if let newSnapshot {
            newAccepted = await synchronization.deliver(snapshot: newSnapshot, binding: binding,
                isCurrent: { true }) { _, arguments, _ in
                XCTAssertEqual(arguments["title"] as? String, "New")
                newCalls += 1
            }
        } else { XCTFail("The changed real model must produce a new title snapshot") }
        gate.release()
        let oldAccepted = await old.value
        XCTAssertFalse(oldAccepted)
        XCTAssertFalse(oldCouldContinue)
        XCTAssertTrue(newAccepted)
        if let newSnapshot {
            let repeated = await synchronization.deliver(snapshot: newSnapshot, binding: binding,
                isCurrent: { true }) { _, _, _ in newCalls += 1 }
            XCTAssertTrue(repeated)
        }
        XCTAssertEqual(newCalls, 1)
        synchronization.retire()
    }

    func testCancelledAndStaleQueuedEntriesCannotRevokeHeldCurrentSuccessor() async throws {
        for cancelled in [false, true] {
            let fixture = Fixture(title: "Old"), synchronization = ReaderTitleSynchronization(), gate = Gate()
            try await fixture.load()
            let oldSnapshot = try fixture.snapshot(), binding = try fixture.binding()
            fixture.row.title = "Current"
            fixture.reader.refreshObservedContentState()
            let currentSnapshot = try fixture.snapshot()
            var freshCouldContinue = false, freshCalls = 0, rejectedCalls = 0
            let fresh = Task { @MainActor in
                await synchronization.deliver(snapshot: currentSnapshot, binding: binding, isCurrent: { true }) { _, _, current in
                    freshCalls += 1
                    await gate.wait()
                    freshCouldContinue = current()
                }
            }
            await gate.waitUntilEntered()
            let queued = Task { @MainActor in
                if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
                return await synchronization.deliver(snapshot: cancelled ? currentSnapshot : oldSnapshot,
                    binding: binding, isCurrent: { true }) { _, _, _ in rejectedCalls += 1 }
            }
            let queuedAccepted = await queued.value
            gate.release()
            let freshAccepted = await fresh.value
            XCTAssertFalse(queuedAccepted)
            XCTAssertEqual(rejectedCalls, 0)
            XCTAssertTrue(freshAccepted)
            XCTAssertTrue(freshCouldContinue)
            XCTAssertEqual(freshCalls, 1)
            synchronization.retire()
        }
    }

    func testRetiredHeldOperationAndPredicateReentryCannotAcknowledgeButFreshAppearanceWorks() async throws {
        let fixture = Fixture(title: "Current"), synchronization = ReaderTitleSynchronization(), gate = Gate()
        try await fixture.load()
        let snapshot = try fixture.snapshot(), binding = try fixture.binding()
        var continuationWasCurrent = true, calls = 0
        let held = Task { @MainActor in
            await synchronization.deliver(snapshot: snapshot, binding: binding, isCurrent: { true }) { _, _, current in
                calls += 1
                await gate.wait()
                continuationWasCurrent = current()
            }
        }
        await gate.waitUntilEntered()
        synchronization.retire()
        gate.release()
        let accepted = await held.value
        XCTAssertFalse(accepted)
        XCTAssertFalse(continuationWasCurrent)
        let reentrant = await synchronization.deliver(snapshot: snapshot, binding: binding, isCurrent: {
            synchronization.retire()
            return true
        }) { _, _, _ in calls += 1 }
        XCTAssertFalse(reentrant)
        XCTAssertEqual(calls, 1)
        let fresh = await synchronization.deliver(snapshot: snapshot, binding: binding,
            isCurrent: { true }) { _, _, current in XCTAssertTrue(current()); calls += 1 }
        XCTAssertTrue(fresh)
        XCTAssertEqual(calls, 2)
        synchronization.retire()
    }

    func testRealWebViewTransactionRejectsHeldOldBindingAndFreshBindingRecoversSameTitle() async throws {
        let fixture = Fixture(title: "Current"), synchronization = ReaderTitleSynchronization(), gate = Gate()
        try await fixture.load()
        var oldCalls = 0, freshCalls = 0
        fixture.caller.asyncCaller = { _, _, _, _ in
            oldCalls += 1
            await gate.wait()
            return WebViewScriptCaller.JavaScriptEvaluationResult(nil)
        }
        let snapshot = try fixture.snapshot(), oldBinding = try fixture.binding()
        let old = Task { @MainActor in
            await synchronization.deliver(snapshot: snapshot, binding: oldBinding,
                isCurrent: { fixture.caller.currentJavaScriptBindingToken == oldBinding }) { script, arguments, current in
                _ = try await fixture.caller.evaluateJavaScriptInMultiTargetFrames(script,
                    arguments: arguments, propagatesFrameErrors: true, continueWhile: current)
            }
        }
        await gate.waitUntilEntered()
        fixture.caller.asyncCaller = { _, arguments, _, _ in
            freshCalls += 1
            XCTAssertEqual(arguments?["title"] as? String, "Current")
            return WebViewScriptCaller.JavaScriptEvaluationResult(nil)
        }
        gate.release()
        let oldAccepted = await old.value
        XCTAssertFalse(oldAccepted)
        XCTAssertEqual(oldCalls, 1)
        XCTAssertEqual(freshCalls, 0)
        let freshBinding = try fixture.binding()
        let fresh = await synchronization.deliver(snapshot: snapshot, binding: freshBinding,
            isCurrent: { fixture.caller.currentJavaScriptBindingToken == freshBinding }) { script, arguments, current in
            _ = try await fixture.caller.evaluateJavaScriptInMultiTargetFrames(script,
                arguments: arguments, propagatesFrameErrors: true, continueWhile: current)
        }
        XCTAssertTrue(fresh)
        XCTAssertEqual(freshCalls, 1)
        synchronization.retire()
    }
}
#endif
