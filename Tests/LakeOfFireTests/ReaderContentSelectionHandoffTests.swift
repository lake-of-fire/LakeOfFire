import Combine
import Foundation
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader
@testable import SwiftUIWebView

private actor SelectionHandoffTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false
    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        open = true
        continuation?.resume()
        continuation = nil
    }
}

private enum SelectionHandoffTestError: Error { case expected }

@MainActor
final class ReaderContentSelectionHandoffTests: XCTestCase {
    private struct Fixture {
        let content: ReaderContent
        let caller: WebViewScriptCaller
        let sequencer: WebViewURLPublicationReceiptSequencer
        let intent: WebViewURLTransitionIntent
        var state: WebViewState {
            var state = WebViewState.empty
            state.pageURL = intent.destinationURL
            state.urlTransitionIntent = intent
            return state
        }
    }

    private func fixture(destination: URL = URL(string: "https://example.invalid/handoff/B")!) throws -> Fixture {
        let content = ReaderContent()
        content.pageURL = URL(string: "https://example.invalid/handoff/A")!
        let caller = WebViewScriptCaller()
        caller.installBinding(ownedBy: UUID(), asyncCaller: { _, _, _, _ in .init(nil) },
            unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
        let sequencer = WebViewURLPublicationReceiptSequencer()
        sequencer.configure(webViewID: ObjectIdentifier(caller),
            binding: try XCTUnwrap(caller.currentJavaScriptBindingToken), url: content.pageURL)
        let intent = try XCTUnwrap(sequencer.observe(destination, from: ObjectIdentifier(caller)).intent)
        return Fixture(content: content, caller: caller, sequencer: sequencer, intent: intent)
    }

    private func resolved(_ url: URL) -> ContentFile {
        let result = ContentFile()
        result.url = url
        result.title = "Selection fixture"
        return result
    }

    func testRejectedSemanticPhaseWithdrawsItsExactHandoff() async throws {
        let fixture = try fixture()
        let manager = NavigationTaskManager()
        let handoff = try XCTUnwrap(fixture.content.receiveSelectionIntent(fixture.intent))
        let accepted = manager.startOnURLChanged(state: fixture.state, readerContent: fixture.content) {
            XCTFail("An idle document cannot schedule independent semantic URL work")
        }
        XCTAssertFalse(accepted)
        let selected = await handoff.waitUntilSelected()
        XCTAssertFalse(selected)
        XCTAssertFalse(handoff.permitsCapture)
    }

    func testFailedSemanticFinishWithdrawsPendingSelection() async throws {
        let fixture = try fixture()
        let manager = NavigationTaskManager()
        let gate = SelectionHandoffTestGate()
        manager.startOnNavigationCommitted { }
        manager.startOnNavigationFinished {
            await gate.wait()
            throw SelectionHandoffTestError.expected
        }
        let accepted = manager.startOnURLChanged(state: fixture.state, readerContent: fixture.content) {
            XCTFail("A failed finish must discard the retained URL")
        }
        XCTAssertTrue(accepted)
        let handoff = try XCTUnwrap(fixture.content.selectionHandoff(for: fixture.intent))
        await gate.release()
        do { try await manager.onNavigationFinishedTask?.value; XCTFail("Expected finish failure") }
        catch SelectionHandoffTestError.expected { }
        let selected = await handoff.waitUntilSelected()
        XCTAssertFalse(selected)
        XCTAssertFalse(handoff.permitsCommit)
    }

    func testCancelledSemanticFinishWithdrawsBeforeHeldFinishReturns() async throws {
        let fixture = try fixture()
        let manager = NavigationTaskManager()
        let entered = expectation(description: "semantic finish is held")
        let gate = SelectionHandoffTestGate()
        manager.startOnNavigationCommitted { }
        manager.startOnNavigationFinished {
            entered.fulfill()
            await gate.wait()
        }
        manager.startOnURLChanged(state: fixture.state, readerContent: fixture.content) {
            XCTFail("Cancelled finish cannot release the URL")
        }
        let handoff = try XCTUnwrap(fixture.content.selectionHandoff(for: fixture.intent))
        await fulfillment(of: [entered], timeout: 5)
        let withdrawn = expectation(description: "waiter terminates without finish returning")
        let waiter = Task { @MainActor in
            let selected = await handoff.waitUntilSelected()
            XCTAssertFalse(selected)
            withdrawn.fulfill()
        }
        manager.onNavigationFinishedTask?.cancel()
        await fulfillment(of: [withdrawn], timeout: 5)
        await waiter.value
        await gate.release()
        do { try await manager.onNavigationFinishedTask?.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }

    func testReplacingDocumentDiscardsPendingSelectionWithoutAdoptingNextDocument() async throws {
        let fixture = try fixture()
        let manager = NavigationTaskManager()
        manager.startOnNavigationCommitted { }
        manager.startOnURLChanged(state: fixture.state, readerContent: fixture.content) { }
        let handoff = try XCTUnwrap(fixture.content.selectionHandoff(for: fixture.intent))
        manager.startOnNavigationCommitted { }
        let selected = await handoff.waitUntilSelected()
        XCTAssertFalse(selected)
        try await manager.onNavigationCommittedTask?.value
        XCTAssertFalse(handoff.permitsCapture)
    }

    func testHandoffWaitsForActualContentResolution() async throws {
        let fixture = try fixture()
        let handoff = try XCTUnwrap(fixture.content.receiveSelectionIntent(fixture.intent))
        let entered = expectation(description: "actual resolver is held")
        let gate = SelectionHandoffTestGate()
        let content = resolved(fixture.intent.destinationURL)
        let load = Task { @MainActor in
            try await fixture.content.load(url: fixture.intent.destinationURL, consuming: fixture.intent) { _ in
                entered.fulfill()
                await gate.wait()
                return content
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(handoff.permitsCapture)
        XCTAssertFalse(handoff.permitsCommit)
        XCTAssertNil(fixture.content.content)
        await gate.release()
        try await load.value
        let selected = await handoff.waitUntilSelected()
        XCTAssertTrue(selected)
        XCTAssertTrue(fixture.content.content === content)
    }

    func testResolverFailureClosesHandoffWithoutPublishingSelectedAuthority() async throws {
        let fixture = try fixture()
        let handoff = try XCTUnwrap(fixture.content.receiveSelectionIntent(fixture.intent))
        do {
            try await fixture.content.load(url: fixture.intent.destinationURL, consuming: fixture.intent) { _ in
                throw SelectionHandoffTestError.expected
            }
            XCTFail("Expected resolver failure")
        } catch SelectionHandoffTestError.expected { }
        let selected = await handoff.waitUntilSelected()
        XCTAssertFalse(selected)
        XCTAssertFalse(handoff.permitsCommit)
        XCTAssertNil(fixture.content.content)
    }

    func testMismatchedResolverResultClosesHandoff() async throws {
        let fixture = try fixture()
        let handoff = try XCTUnwrap(fixture.content.receiveSelectionIntent(fixture.intent))
        let foreign = resolved(URL(string: "https://example.invalid/foreign")!)
        try await fixture.content.load(url: fixture.intent.destinationURL, consuming: fixture.intent) { _ in foreign }
        let selected = await handoff.waitUntilSelected()
        XCTAssertFalse(selected)
        XCTAssertFalse(handoff.permitsCapture)
        XCTAssertNil(fixture.content.content)
    }

    func testSuppressedBlankSelectionTerminatesItsWaiters() async throws {
        let fixture = try fixture(destination: URL(string: "about:blank")!)
        fixture.content.suppressTransientAboutBlank(untilNextNonBlankLoad: URL(string: "https://example.invalid/pending")!)
        let handoff = try XCTUnwrap(fixture.content.receiveSelectionIntent(fixture.intent))
        let previousID = fixture.content.currentSelectionID
        try await fixture.content.load(url: fixture.intent.destinationURL, consuming: fixture.intent) { _ in
            XCTFail("Suppressed about:blank must not resolve")
            return nil
        }
        let selected = await handoff.waitUntilSelected()
        XCTAssertFalse(selected)
        XCTAssertEqual(fixture.content.currentSelectionID, previousID)
    }

    func testWithdrawnIntentCannotRetireExistingNativeSelection() async throws {
        let fixture = try fixture()
        let handoff = try XCTUnwrap(fixture.content.receiveSelectionIntent(fixture.intent))
        let previousID = fixture.content.currentSelectionID
        let previousURL = fixture.content.pageURL
        _ = fixture.sequencer.observe(URL(string: "https://example.invalid/handoff/C")!, from: ObjectIdentifier(fixture.caller))
        do {
            try await fixture.content.load(url: fixture.intent.destinationURL, consuming: fixture.intent) { _ in nil }
            XCTFail("Withdrawn intent must fail before changing selection ownership")
        } catch is CancellationError { }
        let selected = await handoff.waitUntilSelected()
        XCTAssertFalse(selected)
        XCTAssertEqual(fixture.content.currentSelectionID, previousID)
        XCTAssertEqual(fixture.content.pageURL, previousURL)
    }

    func testWithdrawnIntentCannotBeAdmittedAgainUntilNativeTransitionChanges() throws {
        let fixture = try fixture()
        let handoff = try XCTUnwrap(fixture.content.receiveSelectionIntent(fixture.intent))
        fixture.content.withdrawSelectionIntent(fixture.intent)
        XCTAssertTrue(fixture.intent.isCurrent)
        XCTAssertFalse(handoff.permitsCapture)
        XCTAssertNil(fixture.content.receiveSelectionIntent(fixture.intent),
            "A fragment or retry of the failed native intent cannot mint a replacement handoff")
        XCTAssertNil(fixture.content.selectionHandoff(for: fixture.intent))
        let successor = try XCTUnwrap(fixture.sequencer.observe(
            URL(string: "https://example.invalid/handoff/C")!, from: ObjectIdentifier(fixture.caller)).intent)
        XCTAssertNotNil(fixture.content.receiveSelectionIntent(successor))
        XCTAssertNil(fixture.content.selectionHandoff(for: fixture.intent))
    }

    func testRepeatedNativeIntentDoesNotDiscardItsOwnPendingOperation() async throws {
        let fixture = try fixture()
        let manager = NavigationTaskManager()
        var runs = 0
        let content = resolved(fixture.intent.destinationURL)
        manager.startOnNavigationCommitted { }
        manager.startOnURLChanged(state: fixture.state, readerContent: fixture.content) {
            runs += 1
            try await fixture.content.load(url: fixture.intent.destinationURL, consuming: fixture.intent) { _ in content }
        }
        let handoff = try XCTUnwrap(fixture.content.selectionHandoff(for: fixture.intent))
        manager.startOnURLChanged(state: fixture.state, readerContent: fixture.content) { runs += 100 }
        XCTAssertTrue(handoff.permitsCapture)
        manager.startOnNavigationFinished { }
        try await manager.onNavigationFinishedTask?.value
        try await manager.onURLChangedTask?.value
        let selected = await handoff.waitUntilSelected()
        XCTAssertTrue(selected)
        XCTAssertEqual(runs, 1)
    }
    func testNativeWithdrawalSettlesRegisteredWaiterBeforeSemanticAdmission() async throws {
        let fixture = try fixture()
        let handoff = try XCTUnwrap(fixture.content.receiveSelectionIntent(fixture.intent))
        let settled = expectation(description: "original pending intent settles")
        let waiter = Task { @MainActor in
            let selected = await handoff.waitUntilSelected()
            XCTAssertFalse(selected)
            settled.fulfill()
        }
        await Task.yield()
        _ = fixture.sequencer.observe(URL(string: "https://example.invalid/handoff/C")!,
            from: ObjectIdentifier(fixture.caller))
        await fulfillment(of: [settled], timeout: 5)
        await waiter.value
        XCTAssertFalse(handoff.permitsCapture)
    }

    func testCancelledHeldResolverSettlesHandoffBeforeResolverReturns() async throws {
        let fixture = try fixture()
        let handoff = try XCTUnwrap(fixture.content.receiveSelectionIntent(fixture.intent))
        let entered = expectation(description: "resolver suspended")
        let settled = expectation(description: "cancellation settles original waiter")
        let gate = SelectionHandoffTestGate()
        let content = resolved(fixture.intent.destinationURL)
        let load = Task { @MainActor in
            try await fixture.content.load(url: fixture.intent.destinationURL, consuming: fixture.intent) { _ in
                entered.fulfill()
                await gate.wait()
                return content
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        let waiter = Task { @MainActor in
            let selected = await handoff.waitUntilSelected()
            XCTAssertFalse(selected)
            settled.fulfill()
        }
        load.cancel()
        await fulfillment(of: [settled], timeout: 5)
        await waiter.value
        await gate.release()
        do { try await load.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertNil(fixture.content.content)
    }

    func testCoalescedLoadSelectsOnlyOriginalIntentWithoutSecondResolution() async throws {
        let fixture = try fixture()
        let gate = SelectionHandoffTestGate()
        let entered = expectation(description: "existing native load entered")
        let content = resolved(fixture.intent.destinationURL)
        let original = Task { @MainActor in
            try await fixture.content.load(url: fixture.intent.destinationURL) { _ in
                entered.fulfill()
                await gate.wait()
                return content
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        let originalID = fixture.content.currentSelectionID
        let handoff = try XCTUnwrap(fixture.content.receiveSelectionIntent(fixture.intent))
        let joinedEntered = expectation(description: "coalesced caller entered")
        let joined = Task { @MainActor in
            joinedEntered.fulfill()
            try await fixture.content.load(url: fixture.intent.destinationURL, consuming: fixture.intent) { _ in
                XCTFail("Coalesced selection must not resolve again")
                return nil
            }
        }
        await fulfillment(of: [joinedEntered], timeout: 5)
        await gate.release()
        try await original.value
        try await joined.value
        let selected = await handoff.waitUntilSelected()
        XCTAssertTrue(selected)
        XCTAssertEqual(fixture.content.currentSelectionID, originalID)
        XCTAssertTrue(fixture.content.content === content)
    }

    func testReentrantPreloadedPublicationCannotPublishRetiredPageURL() async throws {
        let fixture = try fixture()
        let handoff = try XCTUnwrap(fixture.content.receiveSelectionIntent(fixture.intent))
        let preloaded = resolved(fixture.intent.destinationURL)
        fixture.content.preloadResolvedContent(preloaded, for: preloaded.url)
        let originalURL = fixture.content.pageURL
        var didSupersede = false
        let subscription = fixture.content.contentTitleSubject.sink { _ in
            guard !didSupersede else { return }
            didSupersede = true
            _ = fixture.sequencer.observe(URL(string: "https://example.invalid/handoff/C")!,
                from: ObjectIdentifier(fixture.caller))
        }
        defer { subscription.cancel() }
        do {
            try await fixture.content.load(url: fixture.intent.destinationURL, consuming: fixture.intent) { _ in
                XCTFail("Preloaded content cannot resolve again")
                return nil
            }
            XCTFail("Expected supersession")
        } catch is CancellationError { }
        XCTAssertTrue(didSupersede)
        XCTAssertEqual(fixture.content.pageURL, originalURL)
        let selected = await handoff.waitUntilSelected()
        XCTAssertFalse(selected)
    }

    func testCancelledCoalescedConsumerSettlesOnlyItsOriginalHandoffPromptly() async throws {
        let fixture = try fixture()
        let gate = SelectionHandoffTestGate()
        let entered = expectation(description: "shared resolver entered")
        let joinedEntered = expectation(description: "consuming caller entered")
        let settled = expectation(description: "cancelled handoff settled")
        let content = resolved(fixture.intent.destinationURL)
        let original = Task { @MainActor in
            try await fixture.content.load(url: fixture.intent.destinationURL) { _ in
                entered.fulfill(); await gate.wait(); return content
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        let handoff = try XCTUnwrap(fixture.content.receiveSelectionIntent(fixture.intent))
        let joined = Task { @MainActor in
            joinedEntered.fulfill()
            try await fixture.content.load(url: fixture.intent.destinationURL, consuming: fixture.intent) { _ in
                XCTFail("Coalescing cannot resolve again"); return nil
            }
        }
        await fulfillment(of: [joinedEntered], timeout: 5)
        let waiter = Task { @MainActor in
            let selected = await handoff.waitUntilSelected()
            XCTAssertFalse(selected); settled.fulfill()
        }
        joined.cancel()
        await fulfillment(of: [settled], timeout: 5)
        await waiter.value
        await gate.release()
        try await original.value
        do { try await joined.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertTrue(fixture.content.content === content, "Cancelling the consuming waiter cannot cancel a different resolver owner")
        XCTAssertFalse(handoff.permitsCommit)
    }

    func testFreshSameURLIntentCanRetryWhileCancelledResolverRemainsHeld() async throws {
        let fixture = try fixture()
        let handoff = try XCTUnwrap(fixture.content.receiveSelectionIntent(fixture.intent))
        let gate = SelectionHandoffTestGate()
        let entered = expectation(description: "old resolver held")
        let oldContent = resolved(fixture.intent.destinationURL)
        let old = Task { @MainActor in
            try await fixture.content.load(url: fixture.intent.destinationURL, consuming: fixture.intent) { _ in
                entered.fulfill(); await gate.wait(); return oldContent
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        old.cancel()
        XCTAssertFalse(handoff.permitsCapture)
        XCTAssertNil(fixture.content.receiveSelectionIntent(fixture.intent))
        _ = fixture.sequencer.observe(URL(string: "https://example.invalid/handoff/C")!,
            from: ObjectIdentifier(fixture.caller))
        let next = try XCTUnwrap(fixture.sequencer.observe(fixture.intent.destinationURL,
            from: ObjectIdentifier(fixture.caller)).intent)
        let nextHandoff = try XCTUnwrap(fixture.content.receiveSelectionIntent(next))
        let freshContent = resolved(next.destinationURL)
        try await fixture.content.load(url: next.destinationURL, consuming: next) { _ in freshContent }
        let selected = await nextHandoff.waitUntilSelected()
        XCTAssertTrue(selected)
        await gate.release()
        do { try await old.value; XCTFail("Expected old cancellation") } catch is CancellationError { }
        XCTAssertTrue(fixture.content.content === freshContent)
        XCTAssertFalse(handoff.permitsCommit)
    }

}
