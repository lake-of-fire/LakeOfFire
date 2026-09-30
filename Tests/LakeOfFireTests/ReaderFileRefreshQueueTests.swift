import Foundation
import XCTest
@testable import LakeOfFireContent

private actor InventoryTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private actor InventoryTestSleeper {
    let entered = InventoryTestGate()
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var durations: [TimeInterval] = []
    private(set) var cancellations = 0
    func sleep(_ duration: TimeInterval) async throws {
        let id = UUID()
        durations.append(duration)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[id] = continuation
                Task { await entered.open() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) {
        if let continuation = waiters.removeValue(forKey: id) {
            cancellations += 1
            continuation.resume(throwing: CancellationError())
        }
    }
    func finish() {
        let continuations = Array(waiters.values)
        waiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

@MainActor
private final class InventoryTestClock { var value: TimeInterval = 0 }

private enum InventoryRefreshTestError: Error, Equatable {
    case failed
}

@MainActor
final class ReaderFileRefreshQueueTests: XCTestCase, @unchecked Sendable {
    func testOrdinaryInvalidationDuringScanRunsAnotherSnapshot() async {
        let queue = ReaderFileRefreshQueue(interval: 0)
        let entered = InventoryTestGate()
        let release = InventoryTestGate()
        var snapshots: [Int] = []
        queue.enqueue(scope: "library", force: false) {
            snapshots.append(1)
            await entered.open()
            await release.wait()
        }
        await entered.wait()
        queue.enqueue(scope: "library", force: false) { snapshots.append(2) }
        await release.open()
        await queue.waitForIdle()
        XCTAssertEqual(snapshots, [1, 2])
    }

    func testBurstCoalescesWithoutDroppingTheLatestFullSnapshot() async {
        let queue = ReaderFileRefreshQueue(interval: 0)
        let entered = InventoryTestGate()
        let release = InventoryTestGate()
        var snapshots: [Int] = []
        queue.enqueue(scope: "library", force: false) {
            snapshots.append(0)
            await entered.open()
            await release.wait()
        }
        await entered.wait()
        for value in 1...100 {
            queue.enqueue(scope: "library", force: false) { snapshots.append(value) }
        }
        await release.open()
        await queue.waitForIdle()
        XCTAssertEqual(snapshots, [0, 100])
    }

    func testThrottleHasATrailingWakeupWithoutAnotherNotification() async {
        let sleeper = InventoryTestSleeper()
        let clock = InventoryTestClock()
        let queue = ReaderFileRefreshQueue(now: { clock.value }, sleep: { try await sleeper.sleep($0) })
        var count = 0
        queue.enqueue(scope: "library", force: false) { count += 1 }
        await queue.waitForIdle()
        clock.value = 0.5
        queue.enqueue(scope: "library", force: false) { count += 1 }
        await sleeper.entered.wait()
        let delays = await sleeper.durations
        XCTAssertEqual(delays, [1.5])
        XCTAssertEqual(count, 1)
        clock.value = 2
        await sleeper.finish()
        await queue.waitForIdle()
        XCTAssertEqual(count, 2)
    }

    func testForceWakesAnExistingThrottleWithoutCancellingScan() async {
        let sleeper = InventoryTestSleeper()
        let queue = ReaderFileRefreshQueue(now: { 0 }, sleep: { try await sleeper.sleep($0) })
        var results: [Int] = []
        queue.enqueue(scope: "library", force: false) { results.append(1) }
        await queue.waitForIdle()
        queue.enqueue(scope: "library", force: false) { results.append(2) }
        await sleeper.entered.wait()
        queue.enqueue(scope: "library", force: true) {
            XCTAssertFalse(Task.isCancelled)
            results.append(3)
        }
        await queue.waitForIdle()
        XCTAssertEqual(results, [1, 3])
        let cancellations = await sleeper.cancellations
        XCTAssertEqual(cancellations, 1)
    }

    func testOrdinaryRequestCannotWeakenAnAlreadyForcedPendingRequest() async {
        let queue = ReaderFileRefreshQueue(now: { 0 }, sleep: { _ in XCTFail("Forced work must not throttle") })
        let entered = InventoryTestGate()
        let release = InventoryTestGate()
        var results: [Int] = []
        queue.enqueue(scope: "library", force: false) {
            results.append(1)
            await entered.open()
            await release.wait()
        }
        await entered.wait()
        queue.enqueue(scope: "library", force: true) { results.append(2) }
        queue.enqueue(scope: "library", force: false) { results.append(3) }
        await release.open()
        await queue.waitForIdle()
        XCTAssertEqual(results, [1, 3])
    }

    func testDifferentStorageScopesAreNotCoalescedTogether() async {
        let queue = ReaderFileRefreshQueue(interval: 0)
        let entered = InventoryTestGate()
        let release = InventoryTestGate()
        var results: [String] = []
        queue.enqueue(scope: "first", force: false) {
            results.append("first")
            await entered.open()
            await release.wait()
        }
        await entered.wait()
        queue.enqueue(scope: "second", force: false) { results.append("second") }
        queue.enqueue(scope: "third", force: false) { results.append("third") }
        await release.open()
        await queue.waitForIdle()
        XCTAssertEqual(results, ["first", "second", "third"])
    }

    func testCancellingAWaiterDoesNotCancelSharedInventoryWork() async {
        let queue = ReaderFileRefreshQueue(interval: 0)
        let entered = InventoryTestGate()
        let release = InventoryTestGate()
        var count = 0
        queue.enqueue(scope: "library", force: false) {
            count += 1
            await entered.open()
            await release.wait()
            XCTAssertFalse(Task.isCancelled)
        }
        await entered.wait()
        let waiter = Task { await queue.waitForIdle() }
        waiter.cancel()
        queue.enqueue(scope: "library", force: false) { count += 1 }
        await release.open()
        await waiter.value
        await queue.waitForIdle()
        XCTAssertEqual(count, 2)
    }

    func testAlreadyCancelledCallerDoesNotEnqueueWork() async {
        let queue = ReaderFileRefreshQueue(interval: 0)
        let release = InventoryTestGate()
        var count = 0
        let caller = Task {
            await release.wait()
            queue.enqueue(scope: "library", force: false) { count += 1 }
        }
        caller.cancel()
        await release.open()
        await caller.value
        await queue.waitForIdle()
        XCTAssertEqual(count, 0)
    }

    func testSuspendingAScanReplaysItAfterResume() async {
        let queue = ReaderFileRefreshQueue(interval: 0)
        let entered = InventoryTestGate()
        let release = InventoryTestGate()
        var count = 0
        queue.enqueue(scope: "library", force: false) {
            count += 1
            await entered.open()
            await release.wait()
        }
        await entered.wait()
        queue.suspend()
        await release.open()
        await queue.waitForIdle()
        XCTAssertEqual(count, 1)
        queue.resume()
        await queue.waitForIdle()
        XCTAssertEqual(count, 2)
        queue.resume()
        await queue.waitForIdle()
        XCTAssertEqual(count, 2)
    }

    func testNewerPendingRequestSubsumesCancelledSnapshot() async {
        let queue = ReaderFileRefreshQueue(interval: 0)
        let entered = InventoryTestGate()
        let release = InventoryTestGate()
        var results: [Int] = []
        queue.enqueue(scope: "library", force: false) {
            results.append(1)
            await entered.open()
            await release.wait()
        }
        await entered.wait()
        queue.suspend()
        queue.enqueue(scope: "library", force: false) { results.append(2) }
        await release.open()
        await queue.waitForIdle()
        queue.resume()
        await queue.waitForIdle()
        XCTAssertEqual(results, [1, 2])
    }

    func testResumeWaitsForCancelledPredecessorToUnwind() async {
        let queue = ReaderFileRefreshQueue(interval: 0)
        let entered = InventoryTestGate()
        let release = InventoryTestGate()
        var active = 0
        var maxActive = 0
        var count = 0
        queue.enqueue(scope: "library", force: false) {
            active += 1
            maxActive = max(maxActive, active)
            count += 1
            await entered.open()
            await release.wait()
            active -= 1
        }
        await entered.wait()
        queue.suspend()
        queue.resume()
        XCTAssertEqual(count, 1)
        await release.open()
        await queue.waitForIdle()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(maxActive, 1)
    }

    func testSuspendingTheThrottleRetainsTheOnlyPendingNotification() async {
        let sleeper = InventoryTestSleeper()
        let queue = ReaderFileRefreshQueue(now: { 0 }, sleep: { try await sleeper.sleep($0) })
        var count = 0
        queue.enqueue(scope: "library", force: false) { count += 1 }
        await queue.waitForIdle()
        queue.enqueue(scope: "library", force: false) { count += 1 }
        await sleeper.entered.wait()
        queue.suspend()
        await queue.waitForIdle()
        XCTAssertEqual(count, 1)
        queue.resume()
        await queue.waitForIdle()
        XCTAssertEqual(count, 2)
    }

    func testRequestsWhileSuspendedWaitForResume() async {
        let queue = ReaderFileRefreshQueue(interval: 0)
        var count = 0
        queue.suspend()
        queue.enqueue(scope: "library", force: true) { count += 1 }
        await queue.waitForIdle()
        XCTAssertEqual(count, 0)
        queue.resume()
        await queue.waitForIdle()
        XCTAssertEqual(count, 1)
    }

    func testReentrantNotificationRunsAfterCurrentOperation() async {
        let queue = ReaderFileRefreshQueue(interval: 0)
        var results: [Int] = []
        queue.enqueue(scope: "library", force: false) {
            results.append(1)
            queue.enqueue(scope: "library", force: false) { results.append(3) }
            results.append(2)
        }
        await queue.waitForIdle()
        XCTAssertEqual(results, [1, 2, 3])
    }
    func testCallerCompletionDoesNotWaitForLaterInventoryRequests() async {
        let queue = ReaderFileRefreshQueue(interval: 0)
        let firstEntered = InventoryTestGate()
        let firstRelease = InventoryTestGate()
        let secondEntered = InventoryTestGate()
        let secondRelease = InventoryTestGate()
        let first = queue.enqueue(scope: "library", force: false) {
            await firstEntered.open()
            await firstRelease.wait()
        }
        await firstEntered.wait()
        queue.enqueue(scope: "library", force: false) {
            await secondEntered.open()
            await secondRelease.wait()
        }
        let finished = expectation(description: "first request completed independently")
        let waiter = Task { await first.wait(); finished.fulfill() }
        await firstRelease.open()
        await secondEntered.wait()
        let outcome = await XCTWaiter.fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(outcome, .completed)
        if outcome != .completed { waiter.cancel() }
        await secondRelease.open()
        await waiter.value
        await queue.waitForIdle()
    }

    func testCoalescedCallersBothCompleteWithTheirSharedSnapshot() async {
        let queue = ReaderFileRefreshQueue(interval: 0)
        var count = 0
        let first = queue.enqueue(scope: "library", force: false) { count += 1 }
        let second = queue.enqueue(scope: "library", force: false) { count += 10 }
        await first.wait()
        await second.wait()
        XCTAssertEqual(count, 10)
    }

    func testCancelledSnapshotCompletionTransfersToItsNewerPendingReplacement() async {
        let queue = ReaderFileRefreshQueue(interval: 0)
        let entered = InventoryTestGate()
        let release = InventoryTestGate()
        var count = 0
        let first = queue.enqueue(scope: "library", force: false) {
            count += 1
            await entered.open()
            await release.wait()
        }
        await entered.wait()
        queue.suspend()
        let second = queue.enqueue(scope: "library", force: false) { count += 10 }
        await release.open()
        await queue.waitForIdle()
        queue.resume()
        let finished = expectation(description: "both suspended callers completed")
        let waiter = Task { await first.wait(); await second.wait(); finished.fulfill() }
        let outcome = await XCTWaiter.fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(outcome, .completed)
        if outcome != .completed { waiter.cancel() }
        await waiter.value
        XCTAssertEqual(count, 11)
    }

    func testCancellingCompletionWaiterReturnsWithoutCancellingHeldProducer() async {
        let queue = ReaderFileRefreshQueue(interval: 0)
        let entered = InventoryTestGate()
        let release = InventoryTestGate()
        var completed = false
        let completion = queue.enqueue(scope: "library", force: false) {
            await entered.open()
            await release.wait()
            XCTAssertFalse(Task.isCancelled)
            completed = true
        }
        await entered.wait()
        let finished = expectation(description: "cancelled waiter returned")
        let waiter = Task { await completion.wait(); finished.fulfill() }
        waiter.cancel()
        let outcome = await XCTWaiter.fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(outcome, .completed)
        XCTAssertFalse(completed)
        await release.open()
        await waiter.value
        await completion.wait()
        XCTAssertTrue(completed)
    }


    func testProducerFailureReachesAllCoalescedCallersAndQueueContinues()
    async {
        let queue = ReaderFileRefreshQueue(interval: 0)

        let first = queue.enqueue(scope: "library", force: false) {
            XCTFail("The later coalesced snapshot should replace this operation")
        }
        let second = queue.enqueue(scope: "library", force: false) {
            throw InventoryRefreshTestError.failed
        }

        let firstResult = await first.wait()
        let secondResult = await second.wait()

        for result in [firstResult, secondResult] {
            guard case .failure(let error) = result else {
                return XCTFail("Expected the shared producer failure")
            }
            XCTAssertEqual(error as? InventoryRefreshTestError, .failed)
        }

        var successorRan = false
        let successor = queue.enqueue(scope: "library", force: true) {
            successorRan = true
        }
        guard case .success = await successor.wait() else {
            return XCTFail("A failed snapshot must not poison the queue")
        }
        XCTAssertTrue(successorRan)
    }

    func testCancellationAfterProducerSettlementOwnsWaiterDelivery() async {
        let completion = ReaderFileRefreshQueue.Completion()
        let entered = expectation(description: "waiter entered")
        let waiter = Task { @MainActor in
            entered.fulfill()
            return await completion.wait()
        }
        await fulfillment(of: [entered], timeout: 2)
        // Let wait() install its continuation, then settle and cancel without
        // yielding the MainActor between those two events. The producer result
        // is real, but cancellation must own this waiter's eventual delivery.
        await Task.yield()
        completion.finish(.success(()))
        waiter.cancel()

        let result = await waiter.value
        guard case .failure(let error) = result else {
            return XCTFail("Late-cancelled waiter reported producer success")
        }
        XCTAssertTrue(error is CancellationError)
    }

    func testCancelledCompletionWaiterGetsCancellationWithoutCancellingProducer()
    async {
        let queue = ReaderFileRefreshQueue(interval: 0)
        let entered = InventoryTestGate()
        let release = InventoryTestGate()
        var producerCompleted = false

        let completion = queue.enqueue(scope: "library", force: false) {
            await entered.open()
            await release.wait()
            XCTAssertFalse(Task.isCancelled)
            producerCompleted = true
        }
        await entered.wait()

        let waiter = Task { await completion.wait() }
        waiter.cancel()
        let cancelledResult = await waiter.value
        guard case .failure(let error) = cancelledResult else {
            return XCTFail("Cancelled waiter reported success")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(producerCompleted)

        await release.open()
        let producerResult = await completion.wait()
        guard case .success = producerResult else {
            return XCTFail("Shared producer was cancelled with its waiter")
        }
        XCTAssertTrue(producerCompleted)
    }

    func testSuspendedProducerReplaysWithoutPublishingCancellationFailure()
    async {
        let queue = ReaderFileRefreshQueue(interval: 0)
        let entered = InventoryTestGate()
        let release = InventoryTestGate()
        var runs = 0

        let completion = queue.enqueue(scope: "library", force: false) {
            runs += 1
            if runs == 1 {
                await entered.open()
                await release.wait()
                try Task.checkCancellation()
            }
        }

        await entered.wait()
        queue.suspend()
        await release.open()
        await queue.waitForIdle()

        queue.resume()
        let result = await completion.wait()

        guard case .success = result else {
            return XCTFail("Lifecycle suspension should replay, not fail, the request")
        }
        XCTAssertEqual(runs, 2)
    }

}
