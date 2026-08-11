import XCTest
@testable import LakeOfFireReader

private actor ReaderCallbackGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private enum ReaderCallbackTestError: Error {
    case commitFailed
}

@MainActor
final class ReaderWebViewCallbackContractTests: XCTestCase {
    func testOnlyPhoneReaderExpandsIntoEverySafeArea() {
        XCTAssertTrue(ReaderWebViewSafeAreaPolicy.expandsIntoAllSafeAreas(isPhone: true))
        XCTAssertFalse(ReaderWebViewSafeAreaPolicy.expandsIntoAllSafeAreas(isPhone: false))
    }

    func testIPadReaderModeDoesNotApplySplitViewLeadingInsetInsideWebKit() {
        let resolved = ReaderWebViewObscuredInsetResolver.resolve(
            obscuredInsets: EdgeInsets(top: 0, leading: 450, bottom: 0, trailing: 0),
            additionalInsets: EdgeInsets(top: 0, leading: 450, bottom: 0, trailing: 0),
            usesEBookChromeInsets: false,
            preservesLeadingSafeAreaInset: false
        )

        XCTAssertEqual(resolved.leading, 0)
    }

    func testPhoneReaderModeRetainsPhysicalLeadingSafeAreaInset() {
        let resolved = ReaderWebViewObscuredInsetResolver.resolve(
            obscuredInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
            additionalInsets: EdgeInsets(top: 0, leading: 44, bottom: 0, trailing: 0),
            usesEBookChromeInsets: false,
            preservesLeadingSafeAreaInset: true
        )

        XCTAssertEqual(resolved.leading, 44)
    }

    func testIPadEBookDoesNotApplySplitViewLeadingInsetInsideWebKit() {
        let resolved = ReaderWebViewObscuredInsetResolver.resolve(
            obscuredInsets: EdgeInsets(top: 0, leading: 450, bottom: 0, trailing: 0),
            additionalInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
            usesEBookChromeInsets: true,
            preservesLeadingSafeAreaInset: false
        )

        XCTAssertEqual(resolved.leading, 0)
    }

    func testIgnoredSampledTopRetainsFallbackAndClampPolicy() {
        let resolved = ReaderWebViewObscuredInsetResolver.resolve(
            obscuredInsets: EdgeInsets(top: 160, leading: 0, bottom: 0, trailing: 0),
            additionalInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
            usesEBookChromeInsets: false,
            preservesLeadingSafeAreaInset: false,
            ignoresSampledTopObscuredInset: true,
            fallbackTopInset: 47
        )

        XCTAssertEqual(resolved.top, 88)
    }

    func testCommitFailureSuppressesFinishAndPendingURLChange() async {
        let manager = NavigationTaskManager()
        var finishCount = 0
        var urlCount = 0

        manager.startOnNavigationCommitted { throw ReaderCallbackTestError.commitFailed }
        manager.startOnURLChanged { urlCount += 1 }
        manager.startOnNavigationFinished { finishCount += 1 }

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

    func testFinishWaitsForCommitAndRunsOnce() async throws {
        let manager = NavigationTaskManager()
        let gate = ReaderCallbackGate()
        let commitStarted = expectation(description: "commit started")
        var finishCount = 0

        manager.startOnNavigationCommitted {
            commitStarted.fulfill()
            await gate.wait()
        }
        manager.startOnNavigationFinished { finishCount += 1 }
        manager.startOnNavigationFinished { finishCount += 100 }

        await fulfillment(of: [commitStarted], timeout: 1)
        XCTAssertEqual(finishCount, 0)
        await gate.release()
        try await manager.onNavigationFinishedTask?.value
        XCTAssertEqual(finishCount, 1)
    }

    func testURLChangeDuringFinishKeepsOnlyLatestMutation() async throws {
        let manager = NavigationTaskManager()
        let gate = ReaderCallbackGate()
        let finishStarted = expectation(description: "finish started")
        var order = [String]()

        manager.startOnNavigationCommitted { order.append("commit") }
        manager.startOnNavigationFinished {
            order.append("finish-start")
            finishStarted.fulfill()
            await gate.wait()
            order.append("finish-end")
        }
        await fulfillment(of: [finishStarted], timeout: 1)
        manager.startOnURLChanged { order.append("stale-url") }
        manager.startOnURLChanged { order.append("latest-url") }

        await gate.release()
        try await manager.onNavigationFinishedTask?.value
        try await manager.onURLChangedTask?.value
        XCTAssertEqual(order, ["commit", "finish-start", "finish-end", "latest-url"])
    }

    func testURLChangeBeforeFirstCommitIsIgnored() async {
        let manager = NavigationTaskManager()
        var urlCount = 0

        manager.startOnURLChanged { urlCount += 1 }
        await Task.yield()

        XCTAssertEqual(urlCount, 0)
        XCTAssertNil(manager.onURLChangedTask)
    }

    func testTerminalFailureCancelsDocumentWork() async {
        let manager = NavigationTaskManager()
        let commitStarted = expectation(description: "commit started")
        let commitCancelled = expectation(description: "commit cancelled")
        let failureCalled = expectation(description: "failure called")

        manager.startOnNavigationCommitted {
            commitStarted.fulfill()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                commitCancelled.fulfill()
                throw CancellationError()
            }
        }
        await fulfillment(of: [commitStarted], timeout: 1)
        manager.startOnNavigationFailed {
            failureCalled.fulfill()
        }

        await fulfillment(of: [commitCancelled, failureCalled], timeout: 1)
    }

    func testPreservedDocumentFailureKeepsSettledURLLifecycle() async throws {
        let manager = NavigationTaskManager()
        var order = [String]()

        manager.startOnNavigationCommitted { order.append("commit") }
        manager.startOnNavigationFinished { order.append("finish") }
        try await manager.onNavigationFinishedTask?.value
        manager.startOnNavigationFailed(preservingCommittedDocument: true) {
            order.append("recoverable-failure")
        }
        try await manager.onNavigationFailedTask?.value
        manager.startOnURLChanged { order.append("url") }
        try await manager.onURLChangedTask?.value

        XCTAssertEqual(order, ["commit", "finish", "recoverable-failure", "url"])
    }
}
