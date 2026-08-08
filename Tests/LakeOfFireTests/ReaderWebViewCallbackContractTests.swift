import XCTest
@testable import LakeOfFireReader

private actor ReaderCallbackGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private enum ReaderCallbackTestError: Error {
    case commitFailed
}

@MainActor
final class ReaderWebViewCallbackContractTests: XCTestCase {
    func testCommitFailureSuppressesFinishAndPendingURLChange() async {
        let manager = NavigationTaskManager()
        var finishCount = 0
        var urlCount = 0

        manager.startOnNavigationCommitted {
            throw ReaderCallbackTestError.commitFailed
        }
        manager.startOnURLChanged {
            urlCount += 1
        }
        manager.startOnNavigationFinished {
            finishCount += 1
        }

        do {
            try await manager.onNavigationFinishedTask?.value
            XCTFail("A failed commit must fail the matching finish task")
        } catch ReaderCallbackTestError.commitFailed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(finishCount, 0)
        XCTAssertEqual(urlCount, 0)
        XCTAssertNil(manager.onURLChangedTask)
    }

    func testFinishWaitsForCommitAndRunsExactlyOnce() async throws {
        let manager = NavigationTaskManager()
        let commitGate = ReaderCallbackGate()
        var finishCount = 0

        manager.startOnNavigationCommitted {
            await commitGate.wait()
        }
        manager.startOnNavigationFinished {
            finishCount += 1
        }
        manager.startOnNavigationFinished {
            finishCount += 100
        }

        await Task.yield()
        XCTAssertEqual(finishCount, 0)
        await commitGate.release()
        try await manager.onNavigationFinishedTask?.value
        XCTAssertEqual(finishCount, 1)

        manager.startOnNavigationFinished {
            finishCount += 1000
        }
        await Task.yield()
        XCTAssertEqual(finishCount, 1)
    }

    func testURLChangeBeforeDidFinishQueuesBehindDocumentFinish() async throws {
        let manager = NavigationTaskManager()
        var order: [String] = []

        manager.startOnNavigationCommitted {
            order.append("commit")
        }
        try await manager.onNavigationCommittedTask?.value
        manager.startOnURLChanged {
            order.append("url")
        }

        await Task.yield()
        XCTAssertEqual(order, ["commit"])
        XCTAssertNil(manager.onURLChangedTask)

        manager.startOnNavigationFinished {
            order.append("finish")
        }
        try await manager.onNavigationFinishedTask?.value
        try await manager.onURLChangedTask?.value
        XCTAssertEqual(order, ["commit", "finish", "url"])
    }

    func testURLChangeDuringSemanticFinishKeepsOnlyLatestMutation() async throws {
        let manager = NavigationTaskManager()
        let finishGate = ReaderCallbackGate()
        let finishStarted = expectation(description: "semantic finish started")
        var order: [String] = []

        manager.startOnNavigationCommitted {
            order.append("commit")
        }
        try await manager.onNavigationCommittedTask?.value
        manager.startOnNavigationFinished {
            order.append("finish-start")
            finishStarted.fulfill()
            await finishGate.wait()
            order.append("finish-end")
        }

        await fulfillment(of: [finishStarted], timeout: 1)
        manager.startOnURLChanged {
            order.append("stale-url")
        }
        manager.startOnURLChanged {
            order.append("latest-url")
        }
        await Task.yield()
        XCTAssertEqual(order, ["commit", "finish-start"])

        await finishGate.release()
        try await manager.onNavigationFinishedTask?.value
        try await manager.onURLChangedTask?.value
        XCTAssertEqual(
            order,
            ["commit", "finish-start", "finish-end", "latest-url"]
        )
    }

    func testURLChangeBeforeFirstCommitIsIgnored() async {
        let manager = NavigationTaskManager()
        var urlCount = 0

        manager.startOnURLChanged {
            urlCount += 1
        }
        await Task.yield()

        XCTAssertEqual(urlCount, 0)
        XCTAssertNil(manager.onURLChangedTask)
    }

    func testSettledDocumentURLChangeRunsWithoutAnotherDidFinish() async throws {
        let manager = NavigationTaskManager()
        var order: [String] = []

        manager.startOnNavigationCommitted {
            order.append("commit")
        }
        manager.startOnNavigationFinished {
            order.append("finish")
        }
        try await manager.onNavigationFinishedTask?.value

        manager.startOnURLChanged {
            order.append("url")
        }
        try await manager.onURLChangedTask?.value
        XCTAssertEqual(order, ["commit", "finish", "url"])
    }

    func testNewCommitCancelsFinishWaitingOnPreviousCommit() async {
        let manager = NavigationTaskManager()
        let firstCommitStarted = expectation(description: "first commit started")
        let firstCommitCancelled = expectation(description: "first commit cancelled")
        let staleFinishCalled = expectation(description: "stale finish must not run")
        staleFinishCalled.isInverted = true
        let replacementCommitCalled = expectation(description: "replacement commit called")

        manager.startOnNavigationCommitted {
            firstCommitStarted.fulfill()
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch is CancellationError {
                firstCommitCancelled.fulfill()
                throw CancellationError()
            }
        }
        manager.startOnNavigationFinished {
            staleFinishCalled.fulfill()
        }

        await fulfillment(of: [firstCommitStarted], timeout: 1)
        manager.startOnNavigationCommitted {
            replacementCommitCalled.fulfill()
        }
        await fulfillment(
            of: [firstCommitCancelled, replacementCommitCalled],
            timeout: 1
        )
        await fulfillment(of: [staleFinishCalled], timeout: 0.05)
    }

    func testTerminalCancellationStopsRunningURLCallbackAndClearsTasks() async throws {
        let manager = NavigationTaskManager()
        let urlStarted = expectation(description: "URL callback started")
        let urlCancelled = expectation(description: "URL callback cancelled")

        manager.startOnNavigationCommitted {}
        manager.startOnNavigationFinished {}
        try await manager.onNavigationFinishedTask?.value

        manager.startOnURLChanged {
            urlStarted.fulfill()
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch is CancellationError {
                urlCancelled.fulfill()
                throw CancellationError()
            }
        }

        await fulfillment(of: [urlStarted], timeout: 1)
        manager.cancelNavigationWork()
        await fulfillment(of: [urlCancelled], timeout: 1)

        XCTAssertNil(manager.onNavigationCommittedTask)
        XCTAssertNil(manager.onNavigationFinishedTask)
        XCTAssertNil(manager.onNavigationFailedTask)
        XCTAssertNil(manager.onURLChangedTask)

        var lateURLCount = 0
        manager.startOnURLChanged {
            lateURLCount += 1
        }
        await Task.yield()
        XCTAssertEqual(lateURLCount, 0)
        XCTAssertNil(manager.onURLChangedTask)
    }

    func testNavigationFailureCancelsPendingDocumentWorkBeforeFailureCallback() async {
        let manager = NavigationTaskManager()
        let committedStarted = expectation(description: "committed callback started")
        let committedCancelled = expectation(description: "committed callback cancelled")
        let pendingURLCalled = expectation(description: "pending URL callback must not run")
        pendingURLCalled.isInverted = true
        let failureCalled = expectation(description: "failure callback called")

        manager.startOnNavigationCommitted {
            committedStarted.fulfill()
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch is CancellationError {
                committedCancelled.fulfill()
                throw CancellationError()
            }
        }
        manager.startOnURLChanged {
            pendingURLCalled.fulfill()
        }

        await fulfillment(of: [committedStarted], timeout: 1)
        manager.startOnNavigationFailed {
            failureCalled.fulfill()
        }
        await fulfillment(
            of: [committedCancelled, failureCalled],
            timeout: 1
        )
        await fulfillment(of: [pendingURLCalled], timeout: 0.05)
    }

    func testPreservedDocumentFailureKeepsSettledURLLifecycleAvailable() async throws {
        let manager = NavigationTaskManager()
        var order: [String] = []

        manager.startOnNavigationCommitted {
            order.append("commit")
        }
        manager.startOnNavigationFinished {
            order.append("finish")
        }
        try await manager.onNavigationFinishedTask?.value

        manager.startOnNavigationFailed(preservingCommittedDocument: true) {
            order.append("recoverable-failure")
        }
        try await manager.onNavigationFailedTask?.value

        manager.startOnURLChanged {
            order.append("url")
        }
        try await manager.onURLChangedTask?.value

        XCTAssertEqual(order, ["commit", "finish", "recoverable-failure", "url"])
    }
}
