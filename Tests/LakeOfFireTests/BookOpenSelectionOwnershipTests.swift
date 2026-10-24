import XCTest
import SwiftUI
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
    func testLocalSelectionRetiresSuspendedEditorBeforeForwardingTheBinding() async throws {
        let viewModel = BookLibraryViewModel()
        let gate = BookOpenSelectionGate()
        var original: BookLibraryViewModel.OpenSelection?
        var events: [String] = []
        let older = try XCTUnwrap(viewModel.startOpenSelection(onStart: { original = $0 }) { selection in
            try? await viewModel.open(
                selection: selection,
                stages: .init(
                    resolveDownloadable: { true },
                    existsLocally: { true },
                    importContent: { _ in
                        await gate.suspendIgnoringCancellation()
                        events.append("older-import-complete")
                        return true
                    },
                    loadContent: { events.append("older-load"); return true },
                    navigate: { _ in events.append("older-navigate") },
                    publishNavigation: { events.append("older-publish") }
                )
            )
        })
        let selection = try XCTUnwrap(original)
        await gate.waitUntilSuspended()
        var selectedKey: String?
        let binding = viewModel.localContentSelectionBinding(Binding(
            get: { selectedKey },
            set: { value in
                XCTAssertFalse(viewModel.isCurrentOpenSelection(selection))
                XCTAssertTrue(older.isCancelled)
                selectedKey = value
                events.append("local-selection-forwarded")
            }
        ))

        binding.wrappedValue = "ContentFile:local-B"
        XCTAssertEqual(binding.wrappedValue, "ContentFile:local-B")
        await gate.release()
        await older.value

        XCTAssertEqual(events, ["local-selection-forwarded", "older-import-complete"])
        XCTAssertEqual(selectedKey, "ContentFile:local-B")
    }

    @MainActor
    func testLocalSelectionSuppressesLateEditorFailureAndAllowsAnExplicitRetry() async throws {
        let viewModel = BookLibraryViewModel()
        let gate = BookOpenSelectionGate()
        let failure = NSError(domain: "BookOpenSelectionOwnershipTests", code: 1)
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
                            throw failure
                        },
                        loadContent: { events.append("older-load"); return true },
                        navigate: { _ in events.append("older-navigate") },
                        publishNavigation: { events.append("older-publish") }
                    )
                )
            } catch {
                viewModel.publishOpenError(error, selection: selection)
            }
        })
        await gate.waitUntilSuspended()
        var selectedKey: String?
        let binding = viewModel.localContentSelectionBinding(Binding(
            get: { selectedKey }, set: { selectedKey = $0 }
        ))

        binding.wrappedValue = "ContentFile:local-B"
        await gate.release()
        await older.value
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(selectedKey, "ContentFile:local-B")

        let retry = try XCTUnwrap(viewModel.startOpenSelection { selection in
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
                            events.append("retry-navigate")
                        },
                        publishNavigation: { events.append("retry-publish") }
                    )
                )
            } catch {
                viewModel.publishOpenError(error, selection: selection)
            }
        })
        await retry.value
        XCTAssertEqual(events, ["retry-navigate", "retry-publish"])
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testNilLocalSelectionCleanupDoesNotCancelTheCurrentEditor() async throws {
        let viewModel = BookLibraryViewModel()
        let gate = BookOpenSelectionGate()
        var original: BookLibraryViewModel.OpenSelection?
        var events: [String] = []
        let current = try XCTUnwrap(viewModel.startOpenSelection(onStart: { original = $0 }) { selection in
            try? await viewModel.open(
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
        })
        let selection = try XCTUnwrap(original)
        await gate.waitUntilSuspended()
        var selectedKey: String? = "ContentFile:local-B"
        let binding = viewModel.localContentSelectionBinding(Binding(
            get: { selectedKey }, set: { selectedKey = $0 }
        ))

        binding.wrappedValue = nil
        XCTAssertNil(selectedKey)
        XCTAssertTrue(viewModel.isCurrentOpenSelection(selection))
        XCTAssertFalse(current.isCancelled)
        await gate.release()
        await current.value
        XCTAssertEqual(events, ["navigate", "publish"])
    }

    @MainActor
    func testReselectingTheSameLocalKeyStillRetiresPendingEditorWork() async throws {
        let viewModel = BookLibraryViewModel()
        let gate = BookOpenSelectionGate()
        var original: BookLibraryViewModel.OpenSelection?
        let current = try XCTUnwrap(viewModel.startOpenSelection(onStart: { original = $0 }) { _ in
            await gate.suspendIgnoringCancellation()
        })
        let selection = try XCTUnwrap(original)
        await gate.waitUntilSuspended()
        var selectedKey: String? = "ContentFile:local-B"
        var writes = 0
        let binding = viewModel.localContentSelectionBinding(Binding(
            get: { selectedKey },
            set: { value in
                writes += 1
                selectedKey = value
            }
        ))

        binding.wrappedValue = "ContentFile:local-B"
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(selectedKey, "ContentFile:local-B")
        XCTAssertFalse(viewModel.isCurrentOpenSelection(selection))
        XCTAssertTrue(current.isCancelled)
        await gate.release()
        await current.value
    }

    @MainActor
    func testReentrantEditorSelectionSurvivesLocalBindingPublication() async throws {
        let viewModel = BookLibraryViewModel()
        var selectedKey: String?
        var newer: BookLibraryViewModel.OpenSelection?
        var newerTask: Task<Void, Never>?
        var events: [String] = []
        let binding = viewModel.localContentSelectionBinding(Binding(
            get: { selectedKey },
            set: { value in
                selectedKey = value
                newerTask = viewModel.startOpenSelection(onStart: { newer = $0 }) { selection in
                    try? await viewModel.open(
                        selection: selection,
                        stages: .init(
                            resolveDownloadable: { true },
                            existsLocally: { true },
                            importContent: { _ in true },
                            loadContent: { true },
                            navigate: { _ in events.append("newer-navigate") },
                            publishNavigation: { events.append("newer-publish") }
                        )
                    )
                }
            }
        ))

        binding.wrappedValue = "ContentFile:local-B"
        let selection = try XCTUnwrap(newer)
        let task = try XCTUnwrap(newerTask)
        XCTAssertTrue(viewModel.isCurrentOpenSelection(selection))
        XCTAssertFalse(task.isCancelled)
        await task.value
        XCTAssertEqual(events, ["newer-navigate", "newer-publish"])
    }

    @MainActor
    func testCurrentEditorFailureStillPublishesThroughTheProductionErrorBoundary() async throws {
        let viewModel = BookLibraryViewModel()
        let failure = NSError(
            domain: "BookOpenSelectionOwnershipTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Current import failed"]
        )
        let task = try XCTUnwrap(viewModel.startOpenSelection { selection in
            do {
                try await viewModel.open(
                    selection: selection,
                    stages: .init(
                        resolveDownloadable: { true },
                        existsLocally: { true },
                        importContent: { _ in throw failure },
                        loadContent: { XCTFail("Failed import must not load"); return true },
                        navigate: { _ in XCTFail("Failed import must not navigate") },
                        publishNavigation: { XCTFail("Failed import must not publish navigation") }
                    )
                )
            } catch {
                viewModel.publishOpenError(error, selection: selection)
            }
        })
        await task.value
        XCTAssertEqual(viewModel.errorMessage, "Current import failed")
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
    @MainActor
    func testExplicitSelectionRevokesLatePassiveImportPublication() async throws {
        let viewModel = BookLibraryViewModel()
        let passive = BookDownloadOperation()
        let gate = BookOpenSelectionGate()
        var publications: [String] = []
        let refresh = Task { @MainActor in
            await passive.refresh(operation: {
                await gate.suspendIgnoringCancellation()
                return "stale passive failure"
            }, publish: { publications.append($0) })
        }
        await gate.waitUntilSuspended()
        let selection = try XCTUnwrap(viewModel.startOpenSelection(
            cancellingPassiveOperation: passive
        ) { _ in
            publications.append("explicit import success")
        })
        await selection.value
        await gate.release()
        await refresh.value
        XCTAssertEqual(publications, ["explicit import success"])
    }
}
