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
}
