import Combine
import Foundation
import XCTest
@testable import LakeOfFireContent

private final class SelectionFenceCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var fence: (@Sendable () -> Bool)?
    private var result: Bool?

    func arm(_ fence: @escaping @Sendable () -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.fence = fence
    }

    func cancellationArrived() {
        lock.lock()
        defer { lock.unlock() }
        result = fence?()
    }

    var observedPermission: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

/// Only the asynchronous content resolver is controlled. The owning content
/// model, preload/coalescing paths, Tasks and publication are production code.
/// Fixtures are unmanaged HistoryRecords; no user Realm or history is opened.
@MainActor
final class ReaderContentSelectionOwnershipTests: XCTestCase, @unchecked Sendable {
    private enum Failure: Error { case expected }
    private typealias Resolver = @MainActor (URL) async throws -> (any ReaderContentProtocol)?

    private func record(_ name: String) -> HistoryRecord {
        let record = HistoryRecord()
        record.url = URL(string: "https://example.com/\(name)")!
        record.title = name
        record.updateCompoundKey()
        return record
    }

    // Preserve the production static resolver entry point, including its visit/source arguments.
    private func load(_ reader: ReaderContent, _ url: URL,
                      resolve: @escaping Resolver) async throws {
        ReaderContent.contentResolver = { requestedURL, countsAsHistoryVisit, source in
            XCTAssertTrue(countsAsHistoryVisit)
            XCTAssertEqual(source, "ReaderContent.load")
            return try await resolve(requestedURL)
        }
        try await reader.load(url: url)
    }

    @MainActor private final class Gate {
        private let entry = XCTestExpectation(description: "resolver entered")
        private let release = XCTestExpectation(description: "resolver released")
        private var entered = false
        private var released = false
        func wait() async {
            guard !entered else { XCTFail("Gate entered twice"); return }
            entered = true
            entry.fulfill()
            if !released {
                let status = await XCTWaiter.fulfillment(of: [release], timeout: 5)
                if status != .completed { open(); XCTFail("Resolver release timed out") }
            }
        }
        func waitForEntry() async {
            if !entered {
                let status = await XCTWaiter.fulfillment(of: [entry], timeout: 5)
                if status != .completed { open(); XCTFail("Resolver entry timed out") }
            }
        }
        func open() { if !released { released = true; release.fulfill() } }
    }

    private func expectFailure(_ task: Task<Void, Error>, file: StaticString = #filePath,
                               line: UInt = #line) async {
        do { try await task.value; XCTFail("Expected original failure", file: file, line: line) }
        catch Failure.expected {} catch { XCTFail("Unexpected failure: \(error)", file: file, line: line) }
    }

    func testPreloadedNavigationRejectsLateOldContent() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("a"), b = record("b"), gate = Gate()
        defer { gate.open() }
        var oldWasCancelled = false
        let old = Task { @MainActor in
            try await self.load(reader, a.url) { _ in
                await gate.wait()
                oldWasCancelled = Task.isCancelled
                return a
            }
        }
        await gate.waitForEntry()
        reader.preloadResolvedContent(b, for: b.url)
        try await load(reader, b.url) { _ in XCTFail("Preload invoked resolver"); return nil }
        XCTAssertTrue(reader.content === b)
        gate.open()
        try await old.value
        XCTAssertTrue(reader.content === b)
        XCTAssertEqual(reader.pageURL, b.url)
        XCTAssertEqual(reader.contentTitle, "b")
        XCTAssertTrue(oldWasCancelled)
        let current = try await reader.getContent()
        XCTAssertTrue(current === b)
    }

    func testCallerResolvedSelectionRejectsOldResolverBeforeNavigationStarts() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("a"), b = record("b"), gate = Gate()
        var wasCancelled = false
        let old = Task { @MainActor in
            try await self.load(reader, a.url) { _ in
                await gate.wait()
                wasCancelled = Task.isCancelled
                return a
            }
        }
        defer { gate.open(); old.cancel() }
        await gate.waitForEntry()
        reader.replaceSelection(with: b)
        gate.open()
        try await old.value
        XCTAssertTrue(wasCancelled)
        XCTAssertTrue(reader.content === b)
        XCTAssertEqual(reader.contentTitle, "b")
        let current = try await reader.getContent()
        XCTAssertTrue(current === b)
    }

    func testClearingCallerSelectionRejectsOldResolver() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("a"), gate = Gate()
        let old = Task { @MainActor in
            try await self.load(reader, a.url) { _ in await gate.wait(); return a }
        }
        defer { gate.open(); old.cancel() }
        await gate.waitForEntry()
        reader.replaceSelection(with: nil)
        gate.open()
        try await old.value
        XCTAssertNil(reader.content)
        let current = try await reader.getContent()
        XCTAssertNil(current)
    }

    func testPendingAccessorRejectsExplicitSameObjectSelectionRoundTrip() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("a"), b = record("b"), gate = Gate()
        var replaced = false
        let observation = reader.contentTitleSubject.sink { title in
            guard title == "a", !replaced else { return }
            replaced = true
            reader.replaceSelection(with: b)
            reader.replaceSelection(with: a)
        }
        defer { observation.cancel() }
        let producer = Task { @MainActor in
            try await self.load(reader, a.url) { _ in await gate.wait(); return a }
        }
        defer { gate.open(); producer.cancel() }
        await gate.waitForEntry()
        let entered = XCTestExpectation(description: "accessor captured original selection")
        let accessor = Task { @MainActor in
            entered.fulfill()
            return try await reader.getContent()
        }
        defer { accessor.cancel() }
        await fulfillment(of: [entered], timeout: 5)
        gate.open()
        try await producer.value
        let obsoleteResult = try await accessor.value
        XCTAssertTrue(replaced)
        XCTAssertTrue(reader.content === a)
        XCTAssertNil(obsoleteResult)
        let current = try await reader.getContent()
        XCTAssertTrue(current === a)
    }

    func testExistingContentFastPathRetiresUnrelatedLoad() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("a"), b = record("b"), gate = Gate()
        defer { gate.open() }
        let old = Task { @MainActor in
            try await self.load(reader, a.url) { _ in await gate.wait(); return a }
        }
        await gate.waitForEntry()
        reader.content = b
        try await load(reader, b.url) { _ in XCTFail("Existing content reloaded"); return nil }
        gate.open(); try await old.value
        XCTAssertTrue(reader.content === b)
        XCTAssertEqual(reader.pageURL, b.url)
    }

    func testAlreadyMatchingDisplayRetiresUnrelatedLoad() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("a"), b = record("b"), gate = Gate()
        defer { gate.open() }
        let old = Task { @MainActor in
            try await self.load(reader, a.url) { _ in await gate.wait(); return a }
        }
        await gate.waitForEntry()
        reader.content = b; reader.pageURL = b.url
        try await load(reader, b.url) { _ in XCTFail("Existing content reloaded"); return nil }
        gate.open(); try await old.value
        XCTAssertTrue(reader.content === b)
    }

    func testPreloadingDoesNotReplaceAlreadyRunningSameURLTask() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("a"), preload = record("a"), gate = Gate()
        defer { gate.open() }
        let first = Task { @MainActor in
            try await self.load(reader, a.url) { _ in await gate.wait(); return a }
        }
        await gate.waitForEntry()
        reader.preloadResolvedContent(preload, for: a.url)
        let entry = XCTestExpectation(description: "coalesced preload")
        let second = Task { @MainActor in
            entry.fulfill()
            try await self.load(reader, a.url) { _ in XCTFail("Duplicate resolver"); return nil }
        }
        await fulfillment(of: [entry], timeout: 5)
        gate.open(); try await first.value; try await second.value
        XCTAssertTrue(reader.content === a)
    }

    func testAlreadyCancelledNavigationCannotDisplaceActiveLoad() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("a"), b = record("b"), gate = Gate()
        defer { gate.open() }
        let active = Task { @MainActor in
            try await self.load(reader, a.url) { _ in await gate.wait(); return a }
        }
        await gate.waitForEntry()
        reader.preloadResolvedContent(b, for: b.url)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await self.load(reader, b.url) { _ in XCTFail("Cancelled resolver called"); return b }
        }
        do { try await cancelled.value; XCTFail("Cancelled navigation was accepted") }
        catch is CancellationError {}
        XCTAssertEqual(reader.pageURL, a.url)
        gate.open(); try await active.value
        XCTAssertTrue(reader.content === a)
        try await load(reader, b.url) { _ in XCTFail("Cancelled caller consumed preload"); return nil }
        XCTAssertTrue(reader.content === b)
    }

    func testAlreadyCancelledUncachedNavigationPreservesActiveLoad() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("a"), b = record("b"), gate = Gate()
        defer { gate.open() }
        let active = Task { @MainActor in
            try await self.load(reader, a.url) { _ in
                await gate.wait(); XCTAssertFalse(Task.isCancelled); return a
            }
        }
        await gate.waitForEntry()
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await self.load(reader, b.url) { _ in XCTFail("Cancelled resolver called"); return b }
        }
        do { try await cancelled.value; XCTFail("Cancelled request accepted") }
        catch is CancellationError {}
        XCTAssertEqual(reader.pageURL, a.url)
        gate.open(); try await active.value
        XCTAssertTrue(reader.content === a)
    }

    func testCoalescedErrorWaitersCanRetryBeforeInitiatorResumes() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("a"), gate = Gate()
        defer { gate.open() }
        let initiator = Task { @MainActor in
            try await self.load(reader, a.url) { _ in await gate.wait(); throw Failure.expected }
        }
        await gate.waitForEntry()
        let entries = (0..<32).map { XCTestExpectation(description: "coalesced \($0)") }
        var retryCalls = 0
        let waiters = entries.map { entry in
            Task { @MainActor in
                entry.fulfill()
                do {
                    try await self.load(reader, a.url) { _ in XCTFail("Original load did not coalesce"); return nil }
                    XCTFail("Original failure disappeared")
                } catch Failure.expected {
                    try await self.load(reader, a.url) { _ in retryCalls += 1; return a }
                }
            }
        }
        await fulfillment(of: entries, timeout: 5)
        gate.open()
        await expectFailure(initiator)
        // Join every waiter even when a counterexample fails one of them.
        var failures = 0
        for waiter in waiters {
            do { try await waiter.value } catch { failures += 1 }
        }
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(retryCalls, 1)
        XCTAssertTrue(reader.content === a)
    }

    func testReentrantTitleReplacementDoesNotReturnDisplacedContent() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        for sameURL in [false, true] {
            let reader = ReaderContent(), a = record("a"), b = record("b"), gate = Gate()
            defer { gate.open() }
            if sameURL { b.url = a.url; b.updateCompoundKey() }
            let observation = reader.contentTitleSubject.sink { title in
                guard title == "a" else { return }
                reader.content = b
                reader.pageURL = b.url
            }
            defer { observation.cancel() }
            let producer = Task { @MainActor in
                try await self.load(reader, a.url) { _ in await gate.wait(); return a }
            }
            await gate.waitForEntry()
            let entered = XCTestExpectation(description: "accessor")
            let accessor = Task { @MainActor in
                entered.fulfill()
                return try await reader.getContent()
            }
            await fulfillment(of: [entered], timeout: 5)
            gate.open(); try await producer.value
            let result = try await accessor.value
            XCTAssertNil(result, "The accessor must neither return displaced A nor adopt B")
            XCTAssertTrue(reader.content === b)
            XCTAssertEqual(reader.pageURL, b.url)
        }
    }

    // Every pending reader must remain admitted across a no-op display reuse.
    private func samplePendingReaders(
        afterPublication transition: @escaping @MainActor (ReaderContent, HistoryRecord) async throws -> Void
    ) async throws -> [(any ReaderContentProtocol)?] {
        let reader = ReaderContent(), original = record("publication"), gate = Gate()
        defer { gate.open() }
        var transitionTask: Task<Void, Error>?
        var scheduled = false
        let observation = reader.contentTitleSubject.sink { title in
            guard title == "publication", !scheduled else { return }
            scheduled = true
            transitionTask = Task { @MainActor in
                try await transition(reader, original)
            }
        }
        defer { observation.cancel() }
        let producer = Task { @MainActor in
            try await self.load(reader, original.url) { _ in await gate.wait(); return original }
        }
        await gate.waitForEntry()
        let entered = (0..<32).map { XCTestExpectation(description: "completed-reader-\($0)") }
        let readers = entered.map { entry in
            Task { @MainActor in
                entry.fulfill()
                return try await reader.getContent()
            }
        }
        await fulfillment(of: entered, timeout: 5)
        gate.open()
        try await producer.value
        try await transitionTask?.value
        var samples: [(any ReaderContentProtocol)?] = []
        for reader in readers { samples.append(try await reader.value) }
        return samples
    }

    func testCompletedReadersSurviveAnUnchangedContentReuse() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let samples = try await samplePendingReaders { reader, original in
            try await self.load(reader, original.url) { _ in
                XCTFail("A no-op reused display should not resolve again"); return nil
            }
        }
        for sample in samples {
            XCTAssertNotNil(sample, "Reusing the already displayed content must not retire readers")
        }
    }

    func testPendingReaderReturnsNormalPublicationAfterProducerCleanup() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), original = record("normal"), gate = Gate()
        defer { gate.open() }
        let producer = Task { @MainActor in
            try await self.load(reader, original.url) { _ in await gate.wait(); return original }
        }
        await gate.waitForEntry()
        let entered = XCTestExpectation(description: "normal reader entered")
        let readerTask = Task { @MainActor in
            entered.fulfill()
            return try await reader.getContent()
        }
        await fulfillment(of: [entered], timeout: 5)
        gate.open()
        try await producer.value
        let value = try await readerTask.value
        XCTAssertTrue(value === original)
        let cached = try await reader.getContent()
        XCTAssertTrue(cached === original)
    }

    func testPendingAccessorPreservesOriginalFailureAfterReplacement() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("a"), b = record("b"), gate = Gate()
        defer { gate.open() }
        let producer = Task { @MainActor in
            try await self.load(reader, a.url) { _ in await gate.wait(); throw Failure.expected }
        }
        await gate.waitForEntry()
        let entered = XCTestExpectation(description: "failing accessor entered")
        let accessor = Task { @MainActor in
            entered.fulfill()
            _ = try await reader.getContent()
        }
        await fulfillment(of: [entered], timeout: 5)
        reader.preloadResolvedContent(b, for: b.url)
        try await load(reader, b.url) { _ in XCTFail("Lost preload"); return nil }
        gate.open()
        await expectFailure(producer)
        await expectFailure(accessor)
        XCTAssertTrue(reader.content === b)
    }

    func testSelectionFenceMatchesOnlyTheCapturedInitialAndLoadedSelection() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("selection-initial")
        XCTAssertNil(reader.currentSelectionID)
        let initial = reader.makeSelectionCommitFence(requiring: nil)
        let mismatch = reader.makeSelectionCommitFence(requiring: UUID())
        XCTAssertTrue(initial())
        XCTAssertFalse(mismatch())
        try await load(reader, a.url) { _ in a }
        let selectedID = try XCTUnwrap(reader.currentSelectionID)
        XCTAssertFalse(initial())
        XCTAssertFalse(mismatch(), "A closed mismatch must never borrow a later selection")
        XCTAssertTrue(reader.makeSelectionCommitFence(requiring: selectedID)())
        XCTAssertFalse(reader.makeSelectionCommitFence(requiring: nil)())
    }

    func testSelectionFenceSurvivesSameURLCoalescingAndCompletedContentReuse() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("selection-coalesced"), gate = Gate()
        defer { gate.open() }
        let first = Task { @MainActor in
            try await self.load(reader, a.url) { _ in await gate.wait(); return a }
        }
        await gate.waitForEntry()
        let selection = try XCTUnwrap(reader.currentSelectionID)
        let fence = reader.makeSelectionCommitFence(requiring: selection)
        let entered = XCTestExpectation(description: "selection coalesced waiter")
        let second = Task { @MainActor in
            entered.fulfill()
            try await self.load(reader, a.url) { _ in XCTFail("Duplicate resolver"); return nil }
        }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(reader.currentSelectionID, selection)
        XCTAssertTrue(fence())
        gate.open()
        try await first.value
        try await second.value
        try await load(reader, a.url) { _ in XCTFail("Completed content reloaded"); return nil }
        XCTAssertEqual(reader.currentSelectionID, selection)
        XCTAssertTrue(fence())
    }

    func testReturningToSameURLCreatesNewSelectionAndNeverReopensOldFences() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("selection-a"), b = record("selection-b")
        try await load(reader, a.url) { _ in a }
        let firstID = try XCTUnwrap(reader.currentSelectionID)
        let first = reader.makeSelectionCommitFence(requiring: firstID)
        reader.preloadResolvedContent(b, for: b.url)
        try await load(reader, b.url) { _ in XCTFail("Lost B preload"); return nil }
        let secondID = try XCTUnwrap(reader.currentSelectionID)
        let second = reader.makeSelectionCommitFence(requiring: secondID)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertFalse(first())
        XCTAssertTrue(second())
        reader.preloadResolvedContent(a, for: a.url)
        try await load(reader, a.url) { _ in XCTFail("Lost A preload"); return nil }
        let returnedID = try XCTUnwrap(reader.currentSelectionID)
        XCTAssertNotEqual(returnedID, firstID)
        XCTAssertNotEqual(returnedID, secondID)
        XCTAssertFalse(first())
        XCTAssertFalse(second())
        XCTAssertTrue(reader.makeSelectionCommitFence(requiring: returnedID)())
        XCTAssertTrue(reader.content === a)
    }

    func testCachedAndPreloadedSelectionWithdrawBeforeCancellationAndPublication() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        for preloaded in [false, true] {
            let reader = ReaderContent(), a = record("selection-held"), b = record("selection-fast")
            let gate = Gate(), cancellation = SelectionFenceCancellationProbe()
            defer { gate.open() }
            let held = Task { @MainActor in
                try await self.load(reader, a.url) { _ in
                    await withTaskCancellationHandler {
                        await gate.wait()
                    } onCancel: {
                        cancellation.cancellationArrived()
                    }
                    return a
                }
            }
            await gate.waitForEntry()
            let originalID = try XCTUnwrap(reader.currentSelectionID)
            let original = reader.makeSelectionCommitFence(requiring: originalID)
            cancellation.arm(original)
            if preloaded {
                reader.preloadResolvedContent(b, for: b.url)
            } else {
                // The production existing-content fast path shares the same
                // selection retirement as preload and resolver publication.
                reader.content = b
            }
            var publications = 0
            let observation = reader.contentTitleSubject.sink { title in
                guard title == b.title else { return }
                publications += 1
                XCTAssertFalse(original(), "Publication must follow withdrawal")
                XCTAssertNotEqual(reader.currentSelectionID, originalID)
            }
            defer { observation.cancel() }
            try await load(reader, b.url) { _ in XCTFail("Fast path resolved again"); return nil }
            XCTAssertEqual(cancellation.observedPermission, false,
                           "Cancellation callbacks must already see withdrawn ownership")
            if preloaded { XCTAssertGreaterThan(publications, 0) }
            XCTAssertFalse(original())
            gate.open()
            try await held.value
            XCTAssertTrue(reader.content === b)
        }
    }

    func testSelectionFenceDoesNotRetainItsContentOwner() {
        var reader: ReaderContent? = ReaderContent()
        weak var observed = reader
        let fence = reader!.makeSelectionCommitFence(requiring: nil)
        XCTAssertTrue(fence())
        reader = nil
        XCTAssertNil(observed)
        XCTAssertFalse(fence(), "A retired owner cannot leave a live selection grant")
    }

    func testCancellationErrorDoesNotPoisonExplicitRetry() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("a")
        do { try await load(reader, a.url) { _ in throw CancellationError() }
            XCTFail("Cancellation was swallowed")
        } catch is CancellationError {}
        try await load(reader, a.url) { _ in return a }
        XCTAssertTrue(reader.content === a)
    }

    func testOldFailureCannotClearNewPendingLoad() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("a"), b = record("b")
        let first = Gate(), second = Gate()
        defer { first.open(); second.open() }
        let old = Task { @MainActor in
            try await self.load(reader, a.url) { _ in await first.wait(); throw Failure.expected }
        }
        await first.waitForEntry()
        let new = Task { @MainActor in
            try await self.load(reader, b.url) { _ in await second.wait(); return b }
        }
        await second.waitForEntry()
        first.open(); await expectFailure(old)
        let accessorEntry = XCTestExpectation(description: "new accessor entered")
        let accessor = Task { @MainActor in accessorEntry.fulfill(); return try await reader.getContent() }
        await fulfillment(of: [accessorEntry], timeout: 5)
        second.open(); try await new.value
        let current = try await accessor.value
        XCTAssertTrue(current === b)
        XCTAssertTrue(reader.content === b)
    }

    func testReadAwaitingOldTaskDoesNotReturnOldContentAfterPreload() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("a"), b = record("b"), gate = Gate()
        defer { gate.open() }
        let old = Task { @MainActor in
            try await self.load(reader, a.url) { _ in await gate.wait(); return a }
        }
        await gate.waitForEntry()
        let entered = XCTestExpectation(description: "accessor started")
        let accessor = Task { @MainActor in entered.fulfill(); return try await reader.getContent() }
        await fulfillment(of: [entered], timeout: 5)
        reader.preloadResolvedContent(b, for: b.url)
        try await load(reader, b.url) { _ in XCTFail("Unexpected resolver"); return nil }
        gate.open(); try await old.value
        let captured = try await accessor.value
        XCTAssertNil(captured, "An old accessor must neither return A nor adopt B")
        XCTAssertTrue(reader.content === b)
    }

    func testCancelledCoalescedWaiterDoesNotCancelSharedLoad() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("a"), gate = Gate()
        defer { gate.open() }
        let first = Task { @MainActor in
            try await self.load(reader, a.url) { _ in
                await gate.wait(); XCTAssertFalse(Task.isCancelled); return a
            }
        }
        await gate.waitForEntry()
        let entry = XCTestExpectation(description: "coalesced waiter entered")
        let waiter = Task { @MainActor in
            entry.fulfill()
            try await self.load(reader, a.url) { _ in XCTFail("Coalesced resolver called"); return nil }
        }
        await fulfillment(of: [entry], timeout: 5)
        waiter.cancel()
        gate.open(); try await first.value; try await waiter.value
        XCTAssertTrue(reader.content === a)
        XCTAssertFalse(Task.isCancelled)
    }

    func testPreloadedSelectionClearsSectionButExistingSelectionPreservesIt() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("a"), b = record("b")
        try await load(reader, a.url) { _ in a }
        reader.currentSectionIndex = 8
        reader.preloadResolvedContent(b, for: b.url)
        try await load(reader, b.url) { _ in XCTFail("Preload was lost"); return nil }
        XCTAssertNil(reader.currentSectionIndex)
        reader.currentSectionIndex = 3
        try await load(reader, b.url) { _ in XCTFail("Current content reloaded"); return nil }
        XCTAssertEqual(reader.currentSectionIndex, 3)
    }

    func testMismatchedResultNeverPublishesAndCanBeRetried() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("a"), b = record("b")
        try await load(reader, a.url) { _ in b }
        XCTAssertNil(reader.content)
        XCTAssertEqual(reader.pageURL, a.url)
        try await load(reader, a.url) { _ in a }
        XCTAssertTrue(reader.content === a)
    }

    func testExplicitReplacementWithdrawsBeforeCancellationAndPublication() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        for clearSelection in [false, true] {
            let reader = ReaderContent(), a = record("explicit-held"), b = record("explicit-next")
            let gate = Gate(), cancellation = SelectionFenceCancellationProbe()
            let held = Task { @MainActor in
                try await self.load(reader, a.url) { _ in
                    await withTaskCancellationHandler {
                        await gate.wait()
                    } onCancel: {
                        cancellation.cancellationArrived()
                    }
                    return a
                }
            }
            defer { gate.open(); held.cancel() }
            await gate.waitForEntry()
            let originalID = try XCTUnwrap(reader.currentSelectionID)
            let original = reader.makeSelectionCommitFence(requiring: originalID)
            cancellation.arm(original)
            var publications = 0
            let observation = reader.$content.dropFirst().sink { _ in
                publications += 1
                XCTAssertFalse(original(), "Even willSet publication must follow withdrawal")
                XCTAssertNotEqual(reader.currentSelectionID, originalID)
            }
            defer { observation.cancel() }

            reader.replaceSelection(with: clearSelection ? nil : b)

            XCTAssertEqual(cancellation.observedPermission, false)
            XCTAssertEqual(publications, 1)
            XCTAssertFalse(original())
            XCTAssertTrue(reader.makeSelectionCommitFence(requiring: reader.currentSelectionID)())
            gate.open()
            try await held.value
            let current = try await reader.getContent()
            if clearSelection {
                XCTAssertNil(current)
            } else {
                XCTAssertTrue(current === b)
            }
        }
    }

    func testPreloadedTitlePublicationCannotOverwriteAReentrantSelectionDisplay() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("display-a"), b = record("display-b")
        let replacement = record("display-replacement")
        reader.replaceSelection(with: a)
        reader.pageURL = a.url
        reader.preloadResolvedContent(b, for: b.url)
        var displacedFence: (@Sendable () -> Bool)?
        let observation = reader.contentTitleSubject.sink { title in
            guard title == b.title else { return }
            displacedFence = reader.makeSelectionCommitFence(requiring: reader.currentSelectionID)
            reader.replaceSelection(with: replacement)
            reader.pageURL = replacement.url
        }
        defer { observation.cancel() }

        try await load(reader, b.url) { _ in XCTFail("Lost preloaded content"); return nil }

        XCTAssertEqual(displacedFence?(), false)
        XCTAssertTrue(reader.content === replacement)
        XCTAssertEqual(reader.pageURL, replacement.url)
        XCTAssertEqual(reader.contentTitle, replacement.title)
        XCTAssertTrue(reader.makeSelectionCommitFence(requiring: reader.currentSelectionID)())
    }

    func testSectionResetObserverReplacementPreventsRetiredResolverStartup() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let reader = ReaderContent(), a = record("clear-held"), replacement = record("clear-next")
        var displacedFence: (@Sendable () -> Bool)?
        var replaced = false
        let observation = reader.$currentSectionIndex.dropFirst().sink { _ in
            guard !replaced else { return }
            replaced = true
            displacedFence = reader.makeSelectionCommitFence(requiring: reader.currentSelectionID)
            reader.replaceSelection(with: replacement)
            reader.pageURL = replacement.url
        }
        defer { observation.cancel() }

        try await load(reader, a.url) { _ in XCTFail("Retired resolver was started"); return a }

        XCTAssertTrue(replaced)
        XCTAssertEqual(displacedFence?(), false)
        XCTAssertTrue(reader.content === replacement)
        XCTAssertEqual(reader.pageURL, replacement.url)
        let current = try await reader.getContent()
        XCTAssertTrue(current === replacement)
    }
}
