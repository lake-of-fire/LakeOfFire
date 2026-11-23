import SwiftUI
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
    func testLocalBookSelectionRevokesEditorOpenBeforeForwarding() async throws {
        let viewModel = BookLibraryViewModel()
        let gate = BookOpenSelectionGate()
        var events: [String] = []
        let editor = try XCTUnwrap(viewModel.startOpenSelection { selection in
            do {
                try await viewModel.open(
                    selection: selection,
                    stages: .init(
                        resolveDownloadable: { true },
                        existsLocally: { true },
                        importContent: { _ in
                            await gate.suspendIgnoringCancellation()
                            events.append("editor-import-finished")
                            return true
                        },
                        loadContent: {
                            events.append("editor-load")
                            return true
                        },
                        navigate: { _ in events.append("editor-navigate") },
                        publishNavigation: { events.append("editor-publish") }
                    )
                )
            } catch {
                XCTFail("unexpected Editor open error: \(error)")
            }
        })
        await gate.waitUntilSuspended()

        var selectedKey: String?
        let selection = viewModel.localContentSelectionBinding(Binding(
            get: { selectedKey },
            set: { key in
                XCTAssertTrue(editor.isCancelled)
                selectedKey = key
                events.append("local-selection")
            }
        ))
        selection.wrappedValue = "local-book"
        await gate.release()
        await editor.value

        XCTAssertEqual(selection.wrappedValue, "local-book")
        XCTAssertEqual(events, ["local-selection", "editor-import-finished"])
    }

    @MainActor
    func testReselectingLocalBookSuppressesLateEditorError() async throws {
        let viewModel = BookLibraryViewModel()
        let gate = BookOpenSelectionGate()
        let failure = NSError(
            domain: "BookOpenSelectionOwnershipTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not open Editor’s Pick"]
        )
        let editor = try XCTUnwrap(viewModel.startOpenSelection { selection in
            do {
                try await viewModel.open(
                    selection: selection,
                    stages: .init(
                        resolveDownloadable: { true },
                        existsLocally: { true },
                        importContent: { _ in
                            await gate.suspendIgnoringCancellation()
                            throw failure
                        },
                        loadContent: {
                            XCTFail("failed import must stop the open")
                            return false
                        },
                        navigate: { _ in XCTFail("failed import must not navigate") },
                        publishNavigation: { XCTFail("failed import must not publish") }
                    )
                )
            } catch {
                viewModel.publishOpenError(error, selection: selection)
            }
        })
        await gate.waitUntilSuspended()

        var selectedKey: String? = "local-book"
        var forwardedKeys: [String?] = []
        let selection = viewModel.localContentSelectionBinding(Binding(
            get: { selectedKey },
            set: { key in
                selectedKey = key
                forwardedKeys.append(key)
            }
        ))
        selection.wrappedValue = "local-book"
        await gate.release()
        await editor.value

        XCTAssertTrue(editor.isCancelled)
        XCTAssertEqual(forwardedKeys, ["local-book"])
        XCTAssertNil(viewModel.errorMessage)

        let retry = try XCTUnwrap(viewModel.startOpenSelection { selection in
            viewModel.publishOpenError(failure, selection: selection)
        })
        await retry.value
        XCTAssertEqual(viewModel.errorMessage, failure.localizedDescription)
    }

    @MainActor
    func testClearingLocalBookSelectionKeepsCurrentEditorOpen() async throws {
        let viewModel = BookLibraryViewModel()
        let gate = BookOpenSelectionGate()
        var events: [String] = []
        let editor = try XCTUnwrap(viewModel.startOpenSelection { selection in
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
                            events.append("editor-navigate")
                        },
                        publishNavigation: { events.append("editor-publish") }
                    )
                )
            } catch {
                XCTFail("unexpected Editor open error: \(error)")
            }
        })
        await gate.waitUntilSuspended()

        var selectedKey: String? = "local-book"
        let selection = viewModel.localContentSelectionBinding(Binding(
            get: { selectedKey },
            set: { selectedKey = $0 }
        ))
        selection.wrappedValue = nil
        await gate.release()
        await editor.value

        XCTAssertNil(selection.wrappedValue)
        XCTAssertFalse(editor.isCancelled)
        XCTAssertEqual(events, ["editor-navigate", "editor-publish"])
    }

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
