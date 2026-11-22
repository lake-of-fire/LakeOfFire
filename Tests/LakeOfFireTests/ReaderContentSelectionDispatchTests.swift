import Foundation
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

@MainActor
final class ReaderContentSelectionDispatchTests: XCTestCase {
    private final class Selection {
        var key: String?
        var generation = UUID()
        init(_ key: String?) { self.key = key }
        var binding: Binding<String?> {
            Binding(get: { self.key }, set: { self.key = $0 })
        }
    }

    private func record(_ key: String = "selected") -> HistoryRecord {
        let value = HistoryRecord()
        value.compoundKey = key
        value.title = "Saved selection"
        return value
    }

    func testOptInCallbackRunsInlineWithSelectedObjectBeforeSelectionCleanup() {
        let content = record(), selection = Selection("selected")
        var events = ["before"]
        let task = ReaderContentSelectionDispatch.dispatch(
            selectedContent: content, selectedKey: content.compoundKey,
            capturedGeneration: selection.generation, selection: selection.binding,
            currentGeneration: { selection.generation },
            onSelectionSynchronously: { selected in
                XCTAssertTrue(selected === content)
                XCTAssertEqual(selection.key, "selected")
                events.append("synchronous")
            }, deferred: { events.append("legacy") }
        )
        events.append("after")
        XCTAssertNil(task)
        XCTAssertEqual(events, ["before", "synchronous", "after"])
        XCTAssertNil(selection.key)
    }

    func testStaleBindingRefusesOptInWithoutFallingBackToLegacyReader() {
        let content = record(), selection = Selection("replacement")
        var synchronousCalls = 0, deferredCalls = 0
        let task = ReaderContentSelectionDispatch.dispatch(
            selectedContent: content, selectedKey: "selected",
            capturedGeneration: selection.generation, selection: selection.binding,
            currentGeneration: { selection.generation },
            onSelectionSynchronously: { _ in synchronousCalls += 1 },
            deferred: { deferredCalls += 1 }
        )
        XCTAssertNil(task)
        XCTAssertEqual(synchronousCalls, 0)
        XCTAssertEqual(deferredCalls, 0)
        XCTAssertEqual(selection.key, "replacement")
    }

    func testStaleGenerationRefusesSameKeyReplacementWithoutClearingIt() {
        let content = record(), selection = Selection("selected")
        let retiredGeneration = selection.generation
        selection.generation = UUID()
        var calls = 0
        let task = ReaderContentSelectionDispatch.dispatch(
            selectedContent: content, selectedKey: "selected",
            capturedGeneration: retiredGeneration, selection: selection.binding,
            currentGeneration: { selection.generation },
            onSelectionSynchronously: { _ in calls += 1 }, deferred: { calls += 100 }
        )
        XCTAssertNil(task)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(selection.key, "selected")
    }

    func testCallbackSelectingDifferentItemKeepsReplacementBinding() {
        let content = record(), selection = Selection("selected")
        _ = ReaderContentSelectionDispatch.dispatch(
            selectedContent: content, selectedKey: "selected",
            capturedGeneration: selection.generation, selection: selection.binding,
            currentGeneration: { selection.generation },
            onSelectionSynchronously: { _ in selection.key = "replacement" }, deferred: {}
        )
        XCTAssertEqual(selection.key, "replacement")
    }

    func testCallbackReplacingSameKeyGenerationKeepsReplacementBinding() {
        let content = record(), selection = Selection("selected")
        _ = ReaderContentSelectionDispatch.dispatch(
            selectedContent: content, selectedKey: "selected",
            capturedGeneration: selection.generation, selection: selection.binding,
            currentGeneration: { selection.generation },
            onSelectionSynchronously: { _ in selection.generation = UUID() }, deferred: {}
        )
        XCTAssertEqual(selection.key, "selected")
    }

    func testCallbackMayClearSelectionWithoutDispatchingOrRestoringItAgain() {
        let content = record(), selection = Selection("selected")
        var calls = 0
        _ = ReaderContentSelectionDispatch.dispatch(
            selectedContent: content, selectedKey: "selected",
            capturedGeneration: selection.generation, selection: selection.binding,
            currentGeneration: { selection.generation },
            onSelectionSynchronously: { _ in calls += 1; selection.key = nil }, deferred: {}
        )
        XCTAssertEqual(calls, 1)
        XCTAssertNil(selection.key)
    }

    func testDuplicateSelectionHandlersCannotRepeatAlreadyConsumedInlineAction() {
        let content = record(), selection = Selection("selected")
        let originalGeneration = selection.generation
        var calls = 0, legacyCalls = 0
        for _ in 0..<2 {
            let task = ReaderContentSelectionDispatch.dispatch(
                selectedContent: content, selectedKey: "selected",
                capturedGeneration: originalGeneration, selection: selection.binding,
                currentGeneration: { selection.generation },
                onSelectionSynchronously: { _ in calls += 1 }, deferred: { legacyCalls += 1 }
            )
            XCTAssertNil(task)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(legacyCalls, 0)
    }

    func testDefaultNilOptInKeepsLegacyCallbackDeferredOnMainActorTask() async throws {
        let content = record(), selection = Selection("selected")
        var events = ["before"]
        let task = ReaderContentSelectionDispatch.dispatch(
            selectedContent: content, selectedKey: "selected",
            capturedGeneration: selection.generation, selection: selection.binding,
            currentGeneration: { selection.generation }, onSelectionSynchronously: nil,
            deferred: { events.append("legacy callback") }
        )
        events.append("after")
        XCTAssertEqual(events, ["before", "after"])
        // The existing caller owns the legacy callback and default-reader
        // branch; dispatch preserves their shared deferred execution boundary.
        let queued = try XCTUnwrap(task)
        await queued.value
        XCTAssertEqual(events, ["before", "after", "legacy callback"])
        XCTAssertEqual(selection.key, "selected")
    }

    func testDefaultReaderFallbackRemainsDeferredAndPreservesCallerCleanupOwnership() async throws {
        let content = record(), selection = Selection("selected")
        var navigationRequests = 0
        let task = ReaderContentSelectionDispatch.dispatch(
            selectedContent: content, selectedKey: "selected",
            capturedGeneration: selection.generation, selection: selection.binding,
            currentGeneration: { selection.generation }, onSelectionSynchronously: nil,
            deferred: { navigationRequests += 1; selection.key = nil }
        )
        XCTAssertEqual(navigationRequests, 0)
        XCTAssertEqual(selection.key, "selected")
        let queued = try XCTUnwrap(task)
        await queued.value
        XCTAssertEqual(navigationRequests, 1)
        XCTAssertNil(selection.key)
    }

    func testSupersededGenerationRefusesQueuedLegacyWork() async throws {
        let content = record(), selection = Selection("selected")
        var deferredCalls = 0
        let task = ReaderContentSelectionDispatch.dispatch(
            selectedContent: content, selectedKey: "selected",
            capturedGeneration: selection.generation, selection: selection.binding,
            currentGeneration: { selection.generation }, onSelectionSynchronously: nil,
            deferred: { deferredCalls += 1 }
        )
        selection.generation = UUID()
        let queued = try XCTUnwrap(task)
        await queued.value
        XCTAssertEqual(deferredCalls, 0)
        XCTAssertEqual(selection.key, "selected")
    }

    func testQueuedRefreshCannotClearReplacementOrSameKeyNewGeneration() async throws {
        let page = URL(string: "https://example.invalid/old")!
        for replacementKey in ["B", "A"] {
            let selection = Selection("A")
            let stale = try XCTUnwrap(refresh(contents: [], page: page, selection: selection))
            selection.key = "B"
            if replacementKey == "A" {
                selection.key = "A"
                selection.generation = UUID()
            }

            try await stale.value

            XCTAssertEqual(selection.key, replacementKey)
        }
    }

    func testRefreshPairsSelectedURLWithItsKeyBeforeDeferredClear() async throws {
        let page = URL(string: "https://example.invalid/visible")!
        let visible = record("visible")
        visible.url = page
        let selected = record("selected")
        selected.url = URL(string: "https://example.invalid/not-visible")!
        var rows = [visible, selected]
        let selection = Selection(selected.compoundKey)
        let clear = try XCTUnwrap(refresh(contents: rows, page: page, selection: selection))

        // The retained work has already captured its row identity and URL.
        rows.swapAt(0, 1)
        selected.url = page
        try await clear.value
        XCTAssertNil(selection.key)

        selection.key = selected.compoundKey
        selection.generation = UUID()
        XCTAssertNil(refresh(contents: rows, page: page, selection: selection))
        XCTAssertEqual(selection.key, selected.compoundKey)
    }

    func testRefreshPreservesMatchingProvisionalAndInternalLoadingSelections() {
        let page = URL(string: "https://example.invalid/visible")!
        let row = record("selected")
        row.url = page
        let selection = Selection(row.compoundKey)
        XCTAssertNil(refresh(contents: [row], page: page, selection: selection))
        XCTAssertNil(refresh(contents: [], page: page, provisional: true, selection: selection))
        XCTAssertNil(refresh(contents: [], page: URL(string: "internal://local/load/reader")!, selection: selection))
        XCTAssertEqual(selection.key, row.compoundKey)
    }

    func testRefreshClearsCurrentSelectionOnNativePageAndWithEmptyList() async throws {
        let nativePage = URL(string: "about:blank")!
        let row = record("selected")
        row.url = nativePage
        let selection = Selection(row.compoundKey)
        let nativeRefresh = try XCTUnwrap(refresh(contents: [row], page: nativePage, selection: selection))
        try await nativeRefresh.value
        XCTAssertNil(selection.key)

        selection.key = row.compoundKey
        selection.generation = UUID()
        let page = URL(string: "https://example.invalid/visible")!
        let emptyRefresh = try XCTUnwrap(refresh(contents: [], page: page, selection: selection))
        try await emptyRefresh.value
        XCTAssertNil(selection.key)
    }

    func testCancelledRefreshCannotClearCurrentBinding() async throws {
        let selection = Selection("selected")
        let page = URL(string: "https://example.invalid/visible")!
        let queued = try XCTUnwrap(refresh(contents: [], page: page, selection: selection))
        queued.cancel()
        _ = await queued.result
        XCTAssertEqual(selection.key, "selected")
    }

    func testDefaultDeferredDispatchRejectsReplacementBindingAndCancellation() async throws {
        for cancelled in [false, true] {
            let content = record()
            let selection = Selection(content.compoundKey)
            var deferredCalls = 0
            let task = try XCTUnwrap(ReaderContentSelectionDispatch.dispatch(
                selectedContent: content, selectedKey: content.compoundKey,
                capturedGeneration: selection.generation, selection: selection.binding,
                currentGeneration: { selection.generation }, onSelectionSynchronously: nil,
                deferred: { deferredCalls += 1 }
            ))
            if cancelled {
                task.cancel()
            } else {
                // The binding can change before SwiftUI delivers its onChange.
                selection.key = "replacement"
            }
            await task.value
            XCTAssertEqual(deferredCalls, 0)
            XCTAssertEqual(selection.key, cancelled ? content.compoundKey : "replacement")
        }
    }

    private func refresh(
        contents: [HistoryRecord],
        page: URL,
        provisional: Bool = false,
        selection: Selection
    ) -> Task<Void, Error>? {
        ReaderContentSelectionDispatch.refresh(
            contents: contents, readerPageURL: page, isReaderProvisionallyNavigating: provisional,
            selectedKey: selection.key, capturedGeneration: selection.generation,
            selection: selection.binding, currentGeneration: { selection.generation }
        )
    }

}
