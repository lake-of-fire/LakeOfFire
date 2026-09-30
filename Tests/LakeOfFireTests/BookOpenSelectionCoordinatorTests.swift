import XCTest
@testable import LakeOfFireReader

private actor BookOpenSelectionCoordinatorGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspendIgnoringCancellation() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilSuspended() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

final class BookOpenSelectionCoordinatorTests: XCTestCase {

    @MainActor
    func testScopedCancelRevokesOnlyMatchingSelection() async throws {
        let owner = BookOpenSelectionCoordinator()
        var first: BookOpenSelectionCoordinator.Selection?
        let firstTask = try XCTUnwrap(owner.start(onStart: { first = $0 }) { _ in
            await Task.yield()
        })
        let firstSelection = try XCTUnwrap(first)

        XCTAssertTrue(owner.cancel(ifCurrent: firstSelection))
        XCTAssertFalse(owner.isCurrent(firstSelection))
        await firstTask.value
    }

    @MainActor
    func testScopedCancelCannotRevokeNewerSelection() async throws {
        let owner = BookOpenSelectionCoordinator()
        let gate = BookOpenSelectionCoordinatorGate()
        var older: BookOpenSelectionCoordinator.Selection?
        var newer: BookOpenSelectionCoordinator.Selection?

        let olderTask = try XCTUnwrap(owner.start(onStart: { older = $0 }) { _ in
            await gate.suspendIgnoringCancellation()
        })
        await gate.waitUntilSuspended()

        let newerTask = try XCTUnwrap(owner.start(onStart: { newer = $0 }) { _ in
            await Task.yield()
        })
        let olderSelection = try XCTUnwrap(older)
        let newerSelection = try XCTUnwrap(newer)

        XCTAssertFalse(owner.cancel(ifCurrent: olderSelection))
        XCTAssertTrue(owner.isCurrent(newerSelection))

        await newerTask.value
        await gate.release()
        await olderTask.value
    }

    @MainActor
    func testCancellationIgnoringOlderSelectionCannotPublishAfterReplacement() async throws {
        let owner = BookOpenSelectionCoordinator()
        let gate = BookOpenSelectionCoordinatorGate()
        var events: [String] = []
        let older = try XCTUnwrap(owner.start { selection in
            try? await BookOpenSelectionCoordinator.run(
                stages: .init(
                    resolveDownloadable: { true },
                    existsLocally: { true },
                    importContent: { _ in
                        await gate.suspendIgnoringCancellation()
                        events.append("older-import-complete")
                        return true
                    },
                    loadContent: {
                        events.append("older-load")
                        return true
                    },
                    navigate: { _ in events.append("older-navigate") },
                    publishNavigation: { events.append("older-publish") }
                ),
                shouldContinue: { owner.isCurrent(selection) }
            )
        })
        await gate.waitUntilSuspended()

        let newer = try XCTUnwrap(owner.start { selection in
            try? await BookOpenSelectionCoordinator.run(
                stages: .init(
                    resolveDownloadable: { true },
                    existsLocally: { true },
                    importContent: { _ in true },
                    loadContent: { true },
                    navigate: { claim in
                        XCTAssertTrue(claim.isCurrent())
                        events.append("newer-navigate")
                    },
                    publishNavigation: { events.append("newer-publish") }
                ),
                shouldContinue: { owner.isCurrent(selection) }
            )
        })
        await newer.value
        await gate.release()
        await older.value

        XCTAssertEqual(events, ["newer-navigate", "newer-publish", "older-import-complete"])
    }

    @MainActor
    func testCancelledEntrantDoesNotRevokeHealthySelection() async throws {
        let owner = BookOpenSelectionCoordinator()
        let gate = BookOpenSelectionCoordinatorGate()
        var events: [String] = []
        let healthy = try XCTUnwrap(owner.start { selection in
            try? await BookOpenSelectionCoordinator.run(
                stages: .init(
                    resolveDownloadable: { true },
                    existsLocally: { true },
                    importContent: { _ in
                        await gate.suspendIgnoringCancellation()
                        return true
                    },
                    loadContent: { true },
                    navigate: { _ in events.append("navigate") },
                    publishNavigation: { events.append("publish") }
                ),
                shouldContinue: { owner.isCurrent(selection) }
            )
        })
        await gate.waitUntilSuspended()

        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return owner.start { _ in events.append("cancelled") }
        }
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)
        XCTAssertTrue(events.isEmpty)

        await gate.release()
        await healthy.value
        XCTAssertEqual(events, ["navigate", "publish"])
    }

    @MainActor
    func testUnsupersededSelectionNavigatesAndPublishesOnce() async throws {
        let owner = BookOpenSelectionCoordinator()
        var events: [String] = []
        let task = try XCTUnwrap(owner.start { selection in
            try? await BookOpenSelectionCoordinator.run(
                stages: .init(
                    resolveDownloadable: { true },
                    existsLocally: { false },
                    importContent: {
                        XCTAssertFalse($0)
                        return true
                    },
                    loadContent: { true },
                    navigate: { claim in
                        XCTAssertTrue(claim.isCurrent())
                        events.append("navigate")
                    },
                    publishNavigation: { events.append("publish") }
                ),
                shouldContinue: { owner.isCurrent(selection) }
            )
        })
        await task.value
        XCTAssertEqual(events, ["navigate", "publish"])
    }

    @MainActor
    func testCancelRevokesSuspendedSelection() async throws {
        let owner = BookOpenSelectionCoordinator()
        let gate = BookOpenSelectionCoordinatorGate()
        var events: [String] = []
        let task = try XCTUnwrap(owner.start { selection in
            try? await BookOpenSelectionCoordinator.run(
                stages: .init(
                    resolveDownloadable: { true },
                    existsLocally: { true },
                    importContent: { _ in
                        await gate.suspendIgnoringCancellation()
                        return true
                    },
                    loadContent: { true },
                    navigate: { _ in events.append("navigate") },
                    publishNavigation: { events.append("publish") }
                ),
                shouldContinue: { owner.isCurrent(selection) }
            )
        })
        await gate.waitUntilSuspended()
        owner.cancel()
        await gate.release()
        await task.value
        XCTAssertTrue(events.isEmpty)
    }

    @MainActor
    func testDownloadedPipelineHonorsTaskCancellationAfterSuspension() async throws {
        let gate = BookOpenSelectionCoordinatorGate()
        var events: [String] = []
        let task = Task { @MainActor in
            try await BookOpenSelectionCoordinator.run(
                stages: .init(
                    resolveDownloadable: { true },
                    existsLocally: { true },
                    importContent: { _ in
                        await gate.suspendIgnoringCancellation()
                        return true
                    },
                    loadContent: {
                        events.append("load")
                        return true
                    },
                    navigate: { _ in events.append("navigate") },
                    publishNavigation: { events.append("publish") }
                ),
                shouldContinue: { !Task.isCancelled }
            )
        }
        await gate.waitUntilSuspended()
        task.cancel()
        await gate.release()
        try await task.value
        XCTAssertTrue(events.isEmpty)
    }

    @MainActor
    func testDownloadedPipelinePublishesForCurrentOwner() async throws {
        var events: [String] = []
        try await BookOpenSelectionCoordinator.run(
            stages: .init(
                resolveDownloadable: { true },
                existsLocally: { true },
                importContent: {
                    XCTAssertTrue($0)
                    return true
                },
                loadContent: { true },
                navigate: { claim in
                    XCTAssertTrue(claim.isCurrent())
                    events.append("navigate")
                },
                publishNavigation: { events.append("publish") }
            ),
            shouldContinue: { !Task.isCancelled }
        )
        XCTAssertEqual(events, ["navigate", "publish"])
    }

    @MainActor
    func testSupersededOwnerCannotPublishAfterNavigatorReturns() async throws {
        let owner = BookOpenSelectionCoordinator()
        let gate = BookOpenSelectionCoordinatorGate()
        var events: [String] = []
        let older = try XCTUnwrap(owner.start { selection in
            try? await BookOpenSelectionCoordinator.run(
                stages: .init(
                    resolveDownloadable: { true },
                    existsLocally: { true },
                    importContent: { _ in true },
                    loadContent: { true },
                    navigate: { claim in
                        XCTAssertTrue(claim.isCurrent())
                        events.append("older-navigator-admitted")
                        await gate.suspendIgnoringCancellation()
                        XCTAssertFalse(claim.isCurrent())
                        events.append("older-navigator-returned")
                    },
                    publishNavigation: { events.append("older-publish") }
                ),
                shouldContinue: { owner.isCurrent(selection) }
            )
        })
        await gate.waitUntilSuspended()

        let newer = try XCTUnwrap(owner.start { selection in
            try? await BookOpenSelectionCoordinator.run(
                stages: .init(
                    resolveDownloadable: { true },
                    existsLocally: { true },
                    importContent: { _ in true },
                    loadContent: { true },
                    navigate: { _ in events.append("newer-navigate") },
                    publishNavigation: { events.append("newer-publish") }
                ),
                shouldContinue: { owner.isCurrent(selection) }
            )
        })
        await newer.value
        await gate.release()
        await older.value

        XCTAssertEqual(
            events,
            ["older-navigator-admitted", "newer-navigate", "newer-publish", "older-navigator-returned"]
        )
    }
}
