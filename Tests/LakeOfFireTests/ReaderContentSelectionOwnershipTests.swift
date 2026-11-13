import Combine
import Foundation
import XCTest
@testable import LakeOfFireContent

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

}
