import Foundation
import XCTest
@testable import LakeOfFireReader

@MainActor
final class BookDownloadOperationTests: XCTestCase {
    private final class SuspendedOperation {
        let started = XCTestExpectation(description: "Operation entered")
        private var continuation: CheckedContinuation<Int?, Never>?
        func run() async -> Int? {
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        func finish(_ value: Int?) {
            let saved = continuation
            continuation = nil
            saved?.resume(returning: value)
        }
    }

    private func entered(_ operation: SuspendedOperation) async {
        let result = await XCTWaiter.fulfillment(of: [operation.started], timeout: 3)
        XCTAssertEqual(result, .completed)
    }

    func testSuccessfulOperationPublishesExactlyOnce() async throws {
        let owner = BookDownloadOperation()
        var results: [Int] = []
        let task = try XCTUnwrap(owner.start(operation: { 42 }, publish: { results.append($0) }))
        await task.value
        XCTAssertEqual(results, [42])
    }

    func testNilOperationReleasesTheSlotWithoutPublishing() async throws {
        let owner = BookDownloadOperation()
        var results: [Int] = []
        let first = try XCTUnwrap(owner.start(operation: { nil as Int? }, publish: { results.append($0) }))
        await first.value
        let second = try XCTUnwrap(owner.start(replacingCurrent: false, operation: { 2 }, publish: { results.append($0) }))
        await second.value
        XCTAssertEqual(results, [2])
    }

    func testPassiveNotificationCannotRevokeAnActiveSelection() async throws {
        let owner = BookDownloadOperation()
        let active = SuspendedOperation()
        var results: [Int] = []
        let selection = try XCTUnwrap(owner.start(operation: { await active.run() }, publish: { results.append($0) }))
        await entered(active)
        await owner.refresh(operation: { XCTFail("Passive event replaced a selection"); return 99 }, publish: { results.append($0) })
        XCTAssertFalse(selection.isCancelled)
        active.finish(1)
        await selection.value
        XCTAssertEqual(results, [1])
    }

    func testNewSelectionSuppressesOldUncooperativeRefresh() async throws {
        let owner = BookDownloadOperation()
        let old = SuspendedOperation()
        var results: [Int] = []
        let refresh = Task { @MainActor in
            await owner.refresh(operation: { await old.run() }, publish: { results.append($0) })
        }
        await entered(old)
        let selection = try XCTUnwrap(owner.start(operation: { 2 }, publish: { results.append($0) }))
        await selection.value
        old.finish(1)
        await refresh.value
        XCTAssertEqual(results, [2])
    }

    func testCancelledEntrantDoesNotRevokeCurrentOperation() async throws {
        let owner = BookDownloadOperation()
        let active = SuspendedOperation()
        var results: [Int] = []
        let healthy = try XCTUnwrap(owner.start(operation: { await active.run() }, publish: { results.append($0) }))
        await entered(active)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            let task = owner.start(operation: { XCTFail("Cancelled entrant ran"); return 9 }, publish: { results.append($0) })
            XCTAssertNil(task)
        }
        await cancelled.value
        active.finish(1)
        await healthy.value
        XCTAssertEqual(results, [1])
    }

    func testCancellingOldRefreshWaiterDoesNotCancelReplacement() async throws {
        let owner = BookDownloadOperation()
        let old = SuspendedOperation()
        let new = SuspendedOperation()
        var results: [Int] = []
        let waiter = Task { @MainActor in
            await owner.refresh(operation: { await old.run() }, publish: { results.append($0) })
        }
        await entered(old)
        let replacement = try XCTUnwrap(owner.start(operation: { await new.run() }, publish: { results.append($0) }))
        await entered(new)
        waiter.cancel()
        old.finish(1)
        await waiter.value
        XCTAssertFalse(replacement.isCancelled)
        new.finish(2)
        await replacement.value
        XCTAssertEqual(results, [2])
    }

    func testOldCleanupCannotDetachAReplacement() async throws {
        let owner = BookDownloadOperation()
        let old = SuspendedOperation()
        let new = SuspendedOperation()
        var results: [Int] = []
        let first = try XCTUnwrap(owner.start(operation: { await old.run() }, publish: { results.append($0) }))
        await entered(old)
        let second = try XCTUnwrap(owner.start(operation: { await new.run() }, publish: { results.append($0) }))
        await entered(new)
        old.finish(1)
        await first.value
        owner.cancel()
        new.finish(2)
        await second.value
        XCTAssertTrue(second.isCancelled)
        XCTAssertEqual(results, [])
    }

    func testCancelSuppressesUncooperativeResult() async throws {
        let owner = BookDownloadOperation()
        let work = SuspendedOperation()
        var results: [Int] = []
        let task = try XCTUnwrap(owner.start(operation: { await work.run() }, publish: { results.append($0) }))
        await entered(work)
        owner.cancel()
        work.finish(1)
        await task.value
        XCTAssertEqual(results, [])
    }

    func testCancellationBeforeScheduledEntryPreventsOperation() async throws {
        let owner = BookDownloadOperation()
        var calls = 0
        let task = try XCTUnwrap(owner.start(operation: { calls += 1; return 1 }, publish: { _ in XCTFail("Cancelled result") }))
        owner.cancel()
        await task.value
        XCTAssertEqual(calls, 0)
    }

    func testOwnerReleaseCancelsWithoutRetainingTheOwner() async throws {
        var owner: BookDownloadOperation? = BookDownloadOperation()
        weak var weakOwner = owner
        let work = SuspendedOperation()
        let task = try XCTUnwrap(owner?.start(operation: { await work.run() }, publish: { _ in XCTFail("Orphan published") }))
        await entered(work)
        owner = nil
        XCTAssertNil(weakOwner)
        XCTAssertTrue(task.isCancelled)
        work.finish(1)
        await task.value
    }

    func testReentrantSelectionRetainsItsOwnSlot() async throws {
        let owner = BookDownloadOperation()
        let pending = SuspendedOperation()
        var results: [Int] = []
        var second: Task<Void, Never>?
        let first = try XCTUnwrap(owner.start(operation: { 1 }, publish: { result in
            results.append(result)
            second = owner.start(operation: { await pending.run() }, publish: { results.append($0) })
        }))
        await first.value
        await entered(pending)
        owner.cancel()
        pending.finish(2)
        await second?.value
        XCTAssertEqual(results, [1])
        XCTAssertEqual(second?.isCancelled, true)
    }

    func testRefreshWaitsForItsOperation() async {
        let owner = BookDownloadOperation()
        let work = SuspendedOperation()
        var completed = false
        var results: [Int] = []
        let waiter = Task { @MainActor in
            await owner.refresh(operation: { await work.run() }, publish: { results.append($0) })
            completed = true
        }
        await entered(work)
        XCTAssertFalse(completed)
        work.finish(1)
        await waiter.value
        XCTAssertTrue(completed)
        XCTAssertEqual(results, [1])
    }

    func testReturnedHandleCancellationPreventsPublication() async throws {
        let owner = BookDownloadOperation()
        let work = SuspendedOperation()
        var results: [Int] = []
        let task = try XCTUnwrap(owner.start(operation: { await work.run() }, publish: { results.append($0) }))
        await entered(work)
        task.cancel()
        work.finish(1)
        await task.value
        let retry = try XCTUnwrap(owner.start(replacingCurrent: false, operation: { 2 }, publish: { results.append($0) }))
        await retry.value
        XCTAssertEqual(results, [2])
    }
    func testPassiveRefreshCanReplaceAnAlreadyCancelledTask() async throws {
        let owner = BookDownloadOperation()
        let old = SuspendedOperation()
        var results: [Int] = []
        let cancelled = try XCTUnwrap(owner.start(operation: { await old.run() }, publish: { results.append($0) }))
        await entered(old)
        cancelled.cancel()
        await owner.refresh(operation: { 2 }, publish: { results.append($0) })
        old.finish(1)
        await cancelled.value
        XCTAssertEqual(results, [2])
    }

    func testCancelledRefreshDoesNotInterruptActiveSelection() async throws {
        let owner = BookDownloadOperation()
        let active = SuspendedOperation()
        var results: [Int] = []
        let selection = try XCTUnwrap(owner.start(operation: { await active.run() }, publish: { results.append($0) }))
        await entered(active)
        let refresh = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await owner.refresh(operation: { XCTFail("Cancelled refresh ran"); return 9 }, publish: { results.append($0) })
        }
        await refresh.value
        active.finish(1)
        await selection.value
        XCTAssertFalse(selection.isCancelled)
        XCTAssertEqual(results, [1])
    }

}
