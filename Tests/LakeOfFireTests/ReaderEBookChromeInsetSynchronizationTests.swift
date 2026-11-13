#if DEBUG
import Foundation
import CoreGraphics
import XCTest
@testable import SwiftUIWebView
@testable import LakeOfFireReader

/// Native delivery/acknowledgement tests. The real WebView caller transaction is
/// used where binding admission matters; its installed evaluator is controlled.
@MainActor
final class ReaderEBookChromeInsetSynchronizationTests: XCTestCase {
    private enum Failure: Error { case transient }

    @MainActor
    private final class Context {
        let caller = WebViewScriptCaller()
        var pageURL = URL(string: "ebook://ebook/load/fixture.epub")!
        var renderedURL = URL(string: "ebook://ebook/load/fixture.epub")!
        var cachedContentURL: URL? = URL(string: "ebook://ebook/load/fixture.epub")!
        var resyncID: UInt64 = 1

        init() {
            caller.asyncCaller = { _, _, _, _ in WebViewScriptCaller.JavaScriptEvaluationResult(nil) }
        }

        func key(top: CGFloat = 20, toolbarBottom: CGFloat = 12, bottom: CGFloat = 34) throws
            -> ReaderEBookChromeInsetSynchronization.Key {
            .init(pageURL: pageURL, renderedURL: renderedURL, cachedContentURL: cachedContentURL,
                binding: try XCTUnwrap(caller.currentJavaScriptBindingToken),
                top: top, toolbarBottom: toolbarBottom, bottom: bottom, resyncID: resyncID)
        }

        func isCurrent(_ key: ReaderEBookChromeInsetSynchronization.Key) -> Bool {
            caller.currentJavaScriptBindingToken == key.binding
                && pageURL == key.pageURL && renderedURL == key.renderedURL
                && cachedContentURL == key.cachedContentURL && resyncID == key.resyncID
        }
    }

    @MainActor
    private final class Gate {
        private let arrival = XCTestExpectation(description: "Inset evaluator entered")
        private var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !entered else { XCTFail("One-shot inset gate entered twice"); return }
            entered = true
            arrival.fulfill()
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            let result = await XCTWaiter.fulfillment(of: [arrival], timeout: 5)
            if result != .completed {
                release()
                XCTFail("Inset evaluator never entered")
            }
        }

        func release() {
            guard !released else { return }
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    func testIndependentReadersWithSamePageAndInsetsBothDeliver() async throws {
        let first = Context(), second = Context()
        let firstKey = try first.key(), secondKey = try second.key()
        let firstOwner = ReaderEBookChromeInsetSynchronization()
        let secondOwner = ReaderEBookChromeInsetSynchronization()
        var revisions = [Int]()
        let firstAccepted = await firstOwner.deliver(key: firstKey, isCurrent: { first.isCurrent(firstKey) }) {
            revision, current in
            XCTAssertTrue(current())
            revisions.append(revision)
        }
        let secondAccepted = await secondOwner.deliver(key: secondKey, isCurrent: { second.isCurrent(secondKey) }) {
            revision, current in
            XCTAssertTrue(current())
            revisions.append(revision)
        }
        XCTAssertEqual(firstKey.pageURL, secondKey.pageURL)
        XCTAssertEqual(firstKey.top, secondKey.top)
        XCTAssertEqual(firstKey.bottom, secondKey.bottom)
        XCTAssertTrue(firstAccepted)
        XCTAssertTrue(secondAccepted)
        XCTAssertEqual(revisions.count, 2, "One window's ACK must not suppress the other window")
        if revisions.count == 2 {
            XCTAssertGreaterThan(revisions[1], revisions[0], "The shared renderer revision order remains monotonic")
        }
        firstOwner.retire()
        secondOwner.retire()
    }

    func testOnlySuccessfullyAcknowledgedSameKeyIsDeduplicated() async throws {
        let context = Context(), owner = ReaderEBookChromeInsetSynchronization()
        let key = try context.key()
        var evaluations = 0
        let first = await owner.deliver(key: key, isCurrent: { context.isCurrent(key) }) { _, _ in
            evaluations += 1
        }
        let duplicate = await owner.deliver(key: key, isCurrent: { context.isCurrent(key) }) { _, _ in
            evaluations += 1
        }
        XCTAssertTrue(first)
        XCTAssertTrue(duplicate)
        XCTAssertEqual(evaluations, 1)
        owner.retire()
    }

    func testFailedDeliveryWithIdenticalValuesRemainsRetryable() async throws {
        let context = Context(), owner = ReaderEBookChromeInsetSynchronization()
        let key = try context.key()
        var evaluations = 0
        let failed = await owner.deliver(key: key, isCurrent: { context.isCurrent(key) }) { _, _ in
            evaluations += 1
            throw Failure.transient
        }
        let retry = await owner.deliver(key: key, isCurrent: { context.isCurrent(key) }) { _, current in
            XCTAssertTrue(current())
            evaluations += 1
        }
        XCTAssertFalse(failed)
        XCTAssertTrue(retry)
        XCTAssertEqual(evaluations, 2)
        owner.retire()
    }

    func testCancelledDeliveryCannotAcknowledgeAndFreshTaskRetriesSameValues() async throws {
        let context = Context(), owner = ReaderEBookChromeInsetSynchronization()
        let key = try context.key()
        var evaluations = 0
        let cancelled = Task { @MainActor in
            await owner.deliver(key: key, isCurrent: { context.isCurrent(key) }) { _, current in
                evaluations += 1
                withUnsafeCurrentTask { $0?.cancel() }
                XCTAssertFalse(current())
            }
        }
        let accepted = await cancelled.value
        XCTAssertFalse(accepted)
        let retry = await owner.deliver(key: key, isCurrent: { context.isCurrent(key) }) { _, current in
            XCTAssertTrue(current())
            evaluations += 1
        }
        XCTAssertTrue(retry)
        XCTAssertEqual(evaluations, 2)
        XCTAssertFalse(Task.isCancelled)
        owner.retire()
    }

    func testFailedDifferentFanoutInvalidatesEarlierAcknowledgementBeforeRestoringOldInsets() async throws {
        let context = Context(), owner = ReaderEBookChromeInsetSynchronization()
        let oldKey = try context.key(top: 20)
        let interruptedKey = try context.key(top: 40)
        var evaluations = 0
        var appliedTop: CGFloat?
        let initial = await owner.deliver(key: oldKey, isCurrent: { context.isCurrent(oldKey) }) { _, _ in
            evaluations += 1
            appliedTop = oldKey.top
        }
        let failed = await owner.deliver(key: interruptedKey, isCurrent: { context.isCurrent(interruptedKey) }) { _, _ in
            evaluations += 1
            // A main target can accept the different value before a later
            // registered target rejects the same fanout transaction.
            appliedTop = interruptedKey.top
            throw Failure.transient
        }
        let restored = await owner.deliver(key: oldKey, isCurrent: { context.isCurrent(oldKey) }) { _, _ in
            evaluations += 1
            appliedTop = oldKey.top
        }
        XCTAssertTrue(initial)
        XCTAssertFalse(failed)
        XCTAssertTrue(restored)
        XCTAssertEqual(evaluations, 3, "The old ACK cannot describe the partially changed renderer")
        XCTAssertEqual(appliedTop, oldKey.top)
        owner.retire()
    }

    func testResyncAndNewBindingDeliverEvenWhenInsetsRemainIdentical() async throws {
        let context = Context(), owner = ReaderEBookChromeInsetSynchronization()
        let firstKey = try context.key()
        var evaluations = 0
        let first = await owner.deliver(key: firstKey, isCurrent: { context.isCurrent(firstKey) }) { _, _ in
            evaluations += 1
        }
        context.resyncID += 1
        let resyncKey = try context.key()
        let resynced = await owner.deliver(key: resyncKey, isCurrent: { context.isCurrent(resyncKey) }) { _, _ in
            evaluations += 1
        }
        context.caller.asyncCaller = { _, _, _, _ in WebViewScriptCaller.JavaScriptEvaluationResult(nil) }
        let newBindingKey = try context.key()
        let rebound = await owner.deliver(key: newBindingKey, isCurrent: { context.isCurrent(newBindingKey) }) { _, _ in
            evaluations += 1
        }
        XCTAssertTrue(first)
        XCTAssertTrue(resynced)
        XCTAssertTrue(rebound)
        XCTAssertEqual(firstKey.top, newBindingKey.top)
        XCTAssertNotEqual(firstKey.binding, newBindingKey.binding)
        XCTAssertEqual(evaluations, 3)
        owner.retire()
    }

    func testHeldOldCompletionCannotAcknowledgeOrSuppressNewerInsets() async throws {
        let context = Context(), owner = ReaderEBookChromeInsetSynchronization(), gate = Gate()
        let oldKey = try context.key(top: 20)
        let newKey = try context.key(top: 40)
        var oldCouldContinue = true, newCalls = 0
        let old = Task { @MainActor in
            await owner.deliver(key: oldKey, isCurrent: { context.isCurrent(oldKey) }) { _, current in
                await gate.wait()
                oldCouldContinue = current()
            }
        }
        await gate.waitUntilEntered()
        let replacement = await owner.deliver(key: newKey, isCurrent: { context.isCurrent(newKey) }) { _, current in
            XCTAssertTrue(current())
            newCalls += 1
        }
        gate.release()
        let oldAccepted = await old.value
        let repeated = await owner.deliver(key: newKey, isCurrent: { context.isCurrent(newKey) }) { _, _ in
            newCalls += 1
        }
        XCTAssertTrue(replacement)
        XCTAssertFalse(oldAccepted)
        XCTAssertFalse(oldCouldContinue)
        XCTAssertTrue(repeated)
        XCTAssertEqual(newCalls, 1, "A late old completion must not overwrite the newer acknowledged key")
        owner.retire()
    }

    func testRetirementRejectsHeldCompletionAndAllowsFreshAppearance() async throws {
        let context = Context(), owner = ReaderEBookChromeInsetSynchronization(), gate = Gate()
        let key = try context.key()
        var couldContinue = true, calls = 0
        let held = Task { @MainActor in
            await owner.deliver(key: key, isCurrent: { context.isCurrent(key) }) { _, current in
                calls += 1
                await gate.wait()
                couldContinue = current()
            }
        }
        await gate.waitUntilEntered()
        owner.retire()
        gate.release()
        let accepted = await held.value
        XCTAssertFalse(accepted)
        XCTAssertFalse(couldContinue)
        let fresh = await owner.deliver(key: key, isCurrent: { context.isCurrent(key) }) { _, _ in calls += 1 }
        XCTAssertTrue(fresh)
        XCTAssertEqual(calls, 2)
        owner.retire()
    }

    func testAlreadyCancelledQueuedDeliveryCannotRevokeRunningSuccessor() async throws {
        let context = Context(), owner = ReaderEBookChromeInsetSynchronization(), gate = Gate()
        let oldKey = try context.key(top: 20), freshKey = try context.key(top: 40)
        var freshCouldContinue = false, staleDispatches = 0, freshDispatches = 0
        let fresh = Task { @MainActor in
            await owner.deliver(key: freshKey, isCurrent: { context.isCurrent(freshKey) }) { _, current in
                freshDispatches += 1
                await gate.wait()
                freshCouldContinue = current()
            }
        }
        await gate.waitUntilEntered()
        let stale = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await owner.deliver(key: oldKey, isCurrent: { context.isCurrent(oldKey) }) { _, _ in
                staleDispatches += 1
            }
        }
        let staleAccepted = await stale.value
        gate.release()
        let freshAccepted = await fresh.value
        let duplicate = await owner.deliver(key: freshKey, isCurrent: { context.isCurrent(freshKey) }) { _, _ in
            freshDispatches += 1
        }
        XCTAssertFalse(staleAccepted)
        XCTAssertEqual(staleDispatches, 0)
        XCTAssertTrue(freshAccepted)
        XCTAssertTrue(freshCouldContinue)
        XCTAssertTrue(duplicate)
        XCTAssertEqual(freshDispatches, 1)
        owner.retire()
    }

    func testObsoleteCapturedBindingIsRejectedBeforeRealWebViewTransaction() async throws {
        let context = Context(), owner = ReaderEBookChromeInsetSynchronization()
        let originalKey = try context.key()
        var dispatched = 0
        context.caller.asyncCaller = { _, _, _, _ in
            dispatched += 1
            return WebViewScriptCaller.JavaScriptEvaluationResult(nil)
        }
        let accepted = await syncEbookViewerChromeInsets(key: originalKey, synchronization: owner,
            isCurrent: { context.isCurrent(originalKey) }) { script, current in
            _ = try await context.caller.evaluateJavaScriptInMultiTargetFrames(
                script, propagatesFrameErrors: true, continueWhile: current)
        }
        XCTAssertFalse(accepted)
        XCTAssertEqual(dispatched, 0)
        owner.retire()
    }

    func testNoncancelledQueuedOldBindingCannotRevokeHeldValidSuccessor() async throws {
        let context = Context(), owner = ReaderEBookChromeInsetSynchronization(), gate = Gate()
        let oldKey = try context.key()
        context.caller.asyncCaller = { _, _, _, _ in WebViewScriptCaller.JavaScriptEvaluationResult(nil) }
        let freshKey = try context.key()
        var freshCouldContinue = false, freshDispatches = 0, oldDispatches = 0
        let fresh = Task { @MainActor in
            await owner.deliver(key: freshKey, isCurrent: { context.isCurrent(freshKey) }) { _, current in
                freshDispatches += 1
                await gate.wait()
                freshCouldContinue = current()
            }
        }
        await gate.waitUntilEntered()
        XCTAssertFalse(Task.isCancelled, "This case retires by captured binding, not cancellation")
        let staleAccepted = await owner.deliver(key: oldKey, isCurrent: { context.isCurrent(oldKey) }) { _, _ in
            oldDispatches += 1
        }
        gate.release()
        let freshAccepted = await fresh.value
        let duplicate = await owner.deliver(key: freshKey, isCurrent: { context.isCurrent(freshKey) }) { _, _ in
            freshDispatches += 1
        }
        XCTAssertFalse(staleAccepted)
        XCTAssertEqual(oldDispatches, 0)
        XCTAssertTrue(freshCouldContinue)
        XCTAssertTrue(freshAccepted)
        XCTAssertTrue(duplicate)
        XCTAssertEqual(freshDispatches, 1, "Invalid old admission must preserve the successor and its ACK")
        owner.retire()
    }

    func testSynchronousSourcePredicateRetirementInvalidatesEntryAndFreshRetryRemainsPossible() async throws {
        let context = Context(), owner = ReaderEBookChromeInsetSynchronization()
        let key = try context.key()
        var sourceChecks = 0, evaluations = 0
        let retired = await owner.deliver(key: key, isCurrent: {
            sourceChecks += 1
            owner.retire()
            return true
        }) { _, _ in evaluations += 1 }
        XCTAssertFalse(retired)
        XCTAssertGreaterThan(sourceChecks, 0)
        XCTAssertEqual(evaluations, 0, "Returning true cannot undo synchronous owner retirement")
        let fresh = await owner.deliver(key: key, isCurrent: { context.isCurrent(key) }) { _, current in
            XCTAssertTrue(current())
            evaluations += 1
        }
        XCTAssertTrue(fresh)
        XCTAssertEqual(evaluations, 1)
        owner.retire()
    }

    func testBindingReplacementDuringRealWebViewTransactionCannotAcknowledgeNewDocument() async throws {
        let context = Context(), owner = ReaderEBookChromeInsetSynchronization(), gate = Gate()
        var oldDispatches = 0, freshDispatches = 0
        context.caller.asyncCaller = { _, _, _, _ in
            oldDispatches += 1
            await gate.wait()
            return WebViewScriptCaller.JavaScriptEvaluationResult(nil)
        }
        let oldKey = try context.key()
        let old = Task { @MainActor in
            await syncEbookViewerChromeInsets(key: oldKey, synchronization: owner,
                isCurrent: { context.isCurrent(oldKey) }) { script, current in
                _ = try await context.caller.evaluateJavaScriptInMultiTargetFrames(
                    script, propagatesFrameErrors: true, continueWhile: current)
            }
        }
        await gate.waitUntilEntered()
        context.caller.asyncCaller = { _, _, _, _ in
            freshDispatches += 1
            return WebViewScriptCaller.JavaScriptEvaluationResult(nil)
        }
        gate.release()
        let accepted = await old.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(oldDispatches, 1)
        XCTAssertEqual(freshDispatches, 0)
        // No held work remains before the potentially throwing fresh capture.
        let freshKey = try context.key()
        let fresh = await syncEbookViewerChromeInsets(key: freshKey, synchronization: owner,
            isCurrent: { context.isCurrent(freshKey) }) { script, current in
            _ = try await context.caller.evaluateJavaScriptInMultiTargetFrames(
                script, propagatesFrameErrors: true, continueWhile: current)
        }
        XCTAssertTrue(fresh)
        XCTAssertEqual(freshDispatches, 1)
        owner.retire()
    }
}
#endif
