import XCTest
@testable import LakeOfFireReader

private actor BookOpenSelectionGate {
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

final class BookOpenSelectionOwnershipTests: XCTestCase {
    @MainActor
    func testProductionOpenPipelineRejectsCancellationIgnoringOlderSelection()
    async throws {
        let viewModel = BookLibraryViewModel()
        let gate = BookOpenSelectionGate()
        var events: [String] = []
        let older = try XCTUnwrap(viewModel.startOpenSelection { selection in
            do {
                try await viewModel.open(
                    selection: selection,
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
                        publishNavigation: {
                            events.append("older-publish")
                        }
                    )
                )
            } catch {
                XCTFail("unexpected older open error: \(error)")
            }
        })
        await gate.waitUntilSuspended()

        let newer = try XCTUnwrap(viewModel.startOpenSelection { selection in
            do {
                try await viewModel.open(
                    selection: selection,
                    stages: .init(
                        resolveDownloadable: { true },
                        existsLocally: { true },
                        importContent: { _ in true },
                        loadContent: { true },
                        navigate: { claim in
                            XCTAssertTrue(claim.isCurrent())
                            events.append("newer-navigate")
                        },
                        publishNavigation: {
                            events.append("newer-publish")
                        }
                    )
                )
            } catch {
                XCTFail("unexpected newer open error: \(error)")
            }
        })
        await newer.value
        await gate.release()
        await older.value

        XCTAssertEqual(
            events,
            [
                "newer-navigate",
                "newer-publish",
                "older-import-complete",
            ]
        )
    }

    @MainActor
    func testCancelledEntrantDoesNotRevokeSuspendedHealthyProductionOpen()
    async throws {
        let viewModel = BookLibraryViewModel()
        let gate = BookOpenSelectionGate()
        var events: [String] = []
        let healthy = try XCTUnwrap(viewModel.startOpenSelection { selection in
            do {
                try await viewModel.open(
                    selection: selection,
                    stages: .init(
                        resolveDownloadable: { true },
                        existsLocally: { true },
                        importContent: { _ in
                            await gate.suspendIgnoringCancellation()
                            return true
                        },
                        loadContent: { true },
                        navigate: { claim in
                            XCTAssertTrue(claim.isCurrent())
                            events.append("healthy-navigate")
                        },
                        publishNavigation: {
                            events.append("healthy-publish")
                        }
                    )
                )
            } catch {
                XCTFail("unexpected healthy open error: \(error)")
            }
        })
        await gate.waitUntilSuspended()

        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return viewModel.startOpenSelection { _ in
                events.append("cancelled")
            }
        }
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)
        XCTAssertTrue(events.isEmpty)

        await gate.release()
        await healthy.value

        XCTAssertEqual(events, ["healthy-navigate", "healthy-publish"])
    }

    @MainActor
    func testUnsupersededProductionOpenNavigatesAndPublishesExactlyOnce()
    async throws {
        let viewModel = BookLibraryViewModel()
        var events: [String] = []
        let task = try XCTUnwrap(viewModel.startOpenSelection { selection in
            do {
                try await viewModel.open(
                    selection: selection,
                    stages: .init(
                        resolveDownloadable: { true },
                        existsLocally: { false },
                        importContent: { existsLocally in
                            XCTAssertFalse(existsLocally)
                            return true
                        },
                        loadContent: { true },
                        navigate: { claim in
                            XCTAssertTrue(claim.isCurrent())
                            events.append("navigate")
                        },
                        publishNavigation: { events.append("publish") }
                    )
                )
            } catch {
                XCTFail("unexpected open error: \(error)")
            }
        })

        await task.value

        XCTAssertEqual(events, ["navigate", "publish"])
    }

    @MainActor
    func testDisappearanceRevokesSuspendedProductionOpen() async throws {
        let viewModel = BookLibraryViewModel()
        let gate = BookOpenSelectionGate()
        var events: [String] = []
        let task = try XCTUnwrap(viewModel.startOpenSelection { selection in
            do {
                try await viewModel.open(
                    selection: selection,
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
                    )
                )
            } catch {
                XCTFail("unexpected open error: \(error)")
            }
        })
        await gate.waitUntilSuspended()

        viewModel.cancelOpenSelection()
        await gate.release()
        await task.value

        XCTAssertTrue(events.isEmpty)
    }

    @MainActor
    func testDownloadedTopTapPipelineHonorsCancellationAfterSuspension()
    async throws {
        let gate = BookOpenSelectionGate()
        var events: [String] = []
        let task = Task { @MainActor in
            try await BookLibraryViewModel.openDownloaded(
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
                )
            )
        }
        await gate.waitUntilSuspended()

        task.cancel()
        await gate.release()
        try await task.value

        XCTAssertTrue(events.isEmpty)
    }

    @MainActor
    func testDownloadedTopTapPipelinePublishesForCurrentOwner() async throws {
        var events: [String] = []
        try await BookLibraryViewModel.openDownloaded(
            stages: .init(
                resolveDownloadable: { true },
                existsLocally: { true },
                importContent: { existsLocally in
                    XCTAssertTrue(existsLocally)
                    return true
                },
                loadContent: { true },
                navigate: { claim in
                    XCTAssertTrue(claim.isCurrent())
                    events.append("navigate")
                },
                publishNavigation: { events.append("publish") }
            )
        )

        XCTAssertEqual(events, ["navigate", "publish"])
    }

    @MainActor
    func testSupersededOwnerCannotPublishAfterNavigatorReturns() async throws {
        let viewModel = BookLibraryViewModel()
        let gate = BookOpenSelectionGate()
        var events: [String] = []
        let older = try XCTUnwrap(viewModel.startOpenSelection { selection in
            do {
                try await viewModel.open(
                    selection: selection,
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
                        publishNavigation: {
                            events.append("older-publish")
                        }
                    )
                )
            } catch {
                XCTFail("unexpected older navigation error: \(error)")
            }
        })
        await gate.waitUntilSuspended()

        let newer = try XCTUnwrap(viewModel.startOpenSelection { selection in
            do {
                try await viewModel.open(
                    selection: selection,
                    stages: .init(
                        resolveDownloadable: { true },
                        existsLocally: { true },
                        importContent: { _ in true },
                        loadContent: { true },
                        navigate: { claim in
                            XCTAssertTrue(claim.isCurrent())
                            events.append("newer-navigate")
                        },
                        publishNavigation: {
                            events.append("newer-publish")
                        }
                    )
                )
            } catch {
                XCTFail("unexpected newer navigation error: \(error)")
            }
        })
        await newer.value
        await gate.release()
        await older.value

        XCTAssertEqual(
            events,
            [
                "older-navigator-admitted",
                "newer-navigate",
                "newer-publish",
                "older-navigator-returned",
            ]
        )
    }
}
