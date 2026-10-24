import Combine
import Foundation
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

@MainActor
final class ReaderFileImportPresentationOwnerTests: XCTestCase {
    private typealias Owner = ReaderFileImportPresentationOwner
    private let source = URL(fileURLWithPath: "/synthetic/日本語.epub")
    private let destination = URL(string: "ebook://ebook/load/local/Books/imported.epub")!

    private struct ImportFailure: LocalizedError {
        var errorDescription: String? { "The importer could not index this file." }
    }

    @MainActor
    private final class SuspendedImport {
        let entered = XCTestExpectation(description: "Importer continuation registered")
        private(set) var inputs: [URL] = []
        private var continuation: CheckedContinuation<URL?, Error>?
        private var terminal: Result<URL?, Error>?

        func run(_ url: URL) async throws -> URL? {
            inputs.append(url)
            return try await withCheckedThrowingContinuation { continuation in
                if let terminal {
                    continuation.resume(with: terminal)
                } else {
                    self.continuation = continuation
                }
                entered.fulfill()
            }
        }

        func finish(_ result: Result<URL?, Error>) {
            guard terminal == nil else { return }
            terminal = result
            let pending = continuation
            continuation = nil
            pending?.resume(with: result)
        }
    }

    private func waitForEntry(_ operation: SuspendedImport) async {
        let result = await XCTWaiter.fulfillment(of: [operation.entered], timeout: 3)
        XCTAssertEqual(result, .completed)
    }

    private func releaseOnTeardown(
        _ operation: SuspendedImport,
        task: Task<Void, Never>
    ) {
        addTeardownBlock {
            task.cancel()
            await operation.finish(.failure(CancellationError()))
            await task.value
        }
    }

    func testAutomaticPickerDismissalStillAdmitsItsOriginalSuccessfulResult() async throws {
        let owner = Owner()
        var inputs: [URL] = []
        let expectedDestination = destination
        let picker = try XCTUnwrap(owner.beginPicker { url in
            inputs.append(url)
            return expectedDestination
        })

        XCTAssertTrue(owner.isPickerPresented(picker))
        XCTAssertTrue(owner.hidePicker(picker))
        XCTAssertFalse(owner.isPickerPresented(picker))
        XCTAssertTrue(owner.isCurrent(picker))

        let task = try XCTUnwrap(owner.accept(.success(source), from: picker))
        await task.value

        XCTAssertEqual(inputs, [source])
        XCTAssertNil(owner.failure)
        XCTAssertFalse(owner.isImporting)
    }

    func testNilImportShowsFailureAndNewPickerCanRetrySuccessfully() async throws {
        let owner = Owner()
        let first = try XCTUnwrap(owner.beginPicker { _ in nil })
        let failedTask = try XCTUnwrap(owner.accept(.success(source), from: first))
        await failedTask.value

        let failure = try XCTUnwrap(owner.failure)
        XCTAssertTrue(owner.isErrorPresented(failure))
        XCTAssertTrue(failure.message.contains("日本語.epub"))
        XCTAssertFalse(owner.isImporting)

        let expectedDestination = destination
        let retry = try XCTUnwrap(owner.beginPicker { _ in expectedDestination })
        XCTAssertNil(owner.failure)
        let retryTask = try XCTUnwrap(owner.accept(.success(source), from: retry))
        await retryTask.value

        XCTAssertNil(owner.failure)
        XCTAssertFalse(owner.isImporting)
        XCTAssertFalse(owner.isCurrent(first))
    }

    func testThrownImportFailureIsVisibleAndCanBeDismissed() async throws {
        let owner = Owner()
        let picker = try XCTUnwrap(owner.beginPicker { _ in throw ImportFailure() })
        let task = try XCTUnwrap(owner.accept(.success(source), from: picker))
        await task.value

        let failure = try XCTUnwrap(owner.failure)
        XCTAssertTrue(failure.message.contains("日本語.epub"))
        XCTAssertTrue(failure.message.contains("could not index"))
        XCTAssertTrue(owner.isErrorPresented(failure))
        owner.dismissError(failure)
        XCTAssertNil(owner.failure)
        XCTAssertFalse(owner.isErrorPresented(failure))
    }

    func testPickerProviderFailureNeverCallsTheImporter() async throws {
        let owner = Owner()
        var calls = 0
        let picker = try XCTUnwrap(owner.beginPicker { _ in
            calls += 1
            return nil
        })
        let task = try XCTUnwrap(owner.accept(.failure(ImportFailure()), from: picker))
        await task.value

        XCTAssertEqual(calls, 0)
        XCTAssertTrue(try XCTUnwrap(owner.failure).message.contains("could not index"))
        XCTAssertFalse(owner.isImporting)
    }

    func testCancellationErrorsRemainSilentAndAnotherPickerRemainsAvailable() async throws {
        let errors: [Error] = [
            CancellationError(),
            CocoaError(.userCancelled),
            URLError(.cancelled),
            ReaderPackageEntrySourceError.cancelled,
        ]
        for error in errors {
            let owner = Owner()
            let picker = try XCTUnwrap(owner.beginPicker { _ in throw error })
            let task = try XCTUnwrap(owner.accept(.success(source), from: picker))
            await task.value

            XCTAssertNil(owner.failure)
            XCTAssertFalse(owner.isImporting)
            let expectedDestination = destination
            let retry = try XCTUnwrap(owner.beginPicker { _ in expectedDestination })
            let retryTask = try XCTUnwrap(owner.accept(.success(source), from: retry))
            await retryTask.value
            XCTAssertNil(owner.failure)
        }
    }

    func testOnePickerCannotImportItsSelectionTwice() async throws {
        let owner = Owner()
        let suspended = SuspendedImport()
        let picker = try XCTUnwrap(owner.beginPicker(importing: suspended.run))
        let task = try XCTUnwrap(owner.accept(.success(source), from: picker))
        releaseOnTeardown(suspended, task: task)
        await waitForEntry(suspended)

        XCTAssertNil(owner.accept(.success(source), from: picker))
        XCTAssertFalse(task.isCancelled)
        suspended.finish(.success(destination))
        await task.value

        XCTAssertNil(owner.accept(.success(source), from: picker))
        XCTAssertEqual(suspended.inputs, [source])
    }

    func testRetainedPickerAResultCannotStartOrCancelImportB() async throws {
        let owner = Owner()
        var obsoleteCalls = 0
        let obsolete = try XCTUnwrap(owner.beginPicker { _ in
            obsoleteCalls += 1
            return nil
        })
        let selectedURL = source
        let retainedResult = { owner.accept(.success(selectedURL), from: obsolete) }
        let active = SuspendedImport()
        let replacement = try XCTUnwrap(owner.beginPicker(importing: active.run))
        let replacementTask = try XCTUnwrap(owner.accept(.success(source), from: replacement))
        releaseOnTeardown(active, task: replacementTask)
        await waitForEntry(active)

        XCTAssertNil(retainedResult())
        XCTAssertEqual(obsoleteCalls, 0)
        XCTAssertFalse(replacementTask.isCancelled)
        XCTAssertTrue(owner.isImporting)
        XCTAssertTrue(owner.isCurrent(replacement))

        active.finish(.success(destination))
        await replacementTask.value
        XCTAssertNil(owner.failure)
    }

    func testRetainedPickerASetterCannotDismissPickerB() throws {
        let owner = Owner()
        let first = try XCTUnwrap(owner.beginPicker { _ in nil })
        let retainedDismissal = { owner.hidePicker(first) }
        let replacement = try XCTUnwrap(owner.beginPicker { _ in nil })

        XCTAssertFalse(retainedDismissal())
        XCTAssertTrue(owner.isPickerPresented(replacement))
        XCTAssertTrue(owner.hidePicker(replacement))
        XCTAssertTrue(owner.isCurrent(replacement))
    }

    func testLateOldFailureCannotOverwriteNewFailureWithTheSameSourceURL() async throws {
        let owner = Owner()
        let oldImport = SuspendedImport()
        let first = try XCTUnwrap(owner.beginPicker(importing: oldImport.run))
        let firstTask = try XCTUnwrap(owner.accept(.success(source), from: first))
        releaseOnTeardown(oldImport, task: firstTask)
        await waitForEntry(oldImport)

        let replacement = try XCTUnwrap(owner.beginPicker { _ in nil })
        let replacementTask = try XCTUnwrap(owner.accept(.success(source), from: replacement))
        await replacementTask.value
        let currentFailure = try XCTUnwrap(owner.failure)

        oldImport.finish(.failure(ImportFailure()))
        await firstTask.value

        XCTAssertTrue(firstTask.isCancelled)
        XCTAssertEqual(owner.failure, currentFailure)
        XCTAssertTrue(owner.isErrorPresented(currentFailure))
        XCTAssertFalse(owner.isImporting)
    }

    func testOldCompletionCannotClearNewBusyState() async throws {
        let owner = Owner()
        let oldImport = SuspendedImport()
        let first = try XCTUnwrap(owner.beginPicker(importing: oldImport.run))
        let firstTask = try XCTUnwrap(owner.accept(.success(source), from: first))
        releaseOnTeardown(oldImport, task: firstTask)
        await waitForEntry(oldImport)
        let newImport = SuspendedImport()
        let replacement = try XCTUnwrap(owner.beginPicker(importing: newImport.run))
        let replacementTask = try XCTUnwrap(owner.accept(.success(source), from: replacement))
        releaseOnTeardown(newImport, task: replacementTask)
        await waitForEntry(newImport)

        oldImport.finish(.success(destination))
        await firstTask.value
        XCTAssertTrue(owner.isImporting)
        XCTAssertFalse(replacementTask.isCancelled)
        XCTAssertTrue(owner.isCurrent(replacement))

        newImport.finish(.success(destination))
        await replacementTask.value
        XCTAssertFalse(owner.isImporting)
        XCTAssertNil(owner.failure)
    }

    func testRetiredHostRejectsQueuedAndRetainedSelectionsAfterReactivation() async throws {
        let owner = Owner()
        let oldLifetime = owner.lifetime
        var calls = 0
        let first = try XCTUnwrap(owner.beginPicker { _ in
            calls += 1
            return nil
        })
        let queued = try XCTUnwrap(owner.accept(.success(source), from: first))
        owner.retire(lifetime: oldLifetime)
        await queued.value

        XCTAssertEqual(calls, 0)
        XCTAssertTrue(queued.isCancelled)
        XCTAssertNil(owner.beginPicker { _ in nil })
        XCTAssertNil(owner.accept(.success(source), from: first))

        owner.activate()
        let replacement = try XCTUnwrap(owner.beginPicker { _ in nil })
        XCTAssertNotEqual(owner.lifetime, oldLifetime)
        XCTAssertNil(owner.accept(.success(source), from: first))
        owner.retire(lifetime: oldLifetime)
        XCTAssertTrue(owner.isPickerPresented(replacement))
    }

    func testRetiredHostSuppressesUncooperativeSuccessAndFailure() async throws {
        let outcomes: [Result<URL?, Error>] = [
            .success(destination),
            .failure(ImportFailure()),
        ]
        for outcome in outcomes {
            let owner = Owner()
            let suspended = SuspendedImport()
            let picker = try XCTUnwrap(owner.beginPicker(importing: suspended.run))
            let task = try XCTUnwrap(owner.accept(.success(source), from: picker))
            releaseOnTeardown(suspended, task: task)
            await waitForEntry(suspended)

            owner.retire(lifetime: owner.lifetime)
            suspended.finish(outcome)
            await task.value

            XCTAssertTrue(task.isCancelled)
            XCTAssertNil(owner.picker)
            XCTAssertNil(owner.failure)
            XCTAssertFalse(owner.isImporting)
        }
    }

    func testPreCancelledEntrantCannotReplaceAnActiveImport() async throws {
        let owner = Owner()
        let active = SuspendedImport()
        let picker = try XCTUnwrap(owner.beginPicker(importing: active.run))
        let healthy = try XCTUnwrap(owner.accept(.success(source), from: picker))
        releaseOnTeardown(active, task: healthy)
        await waitForEntry(active)
        let selectedURL = source

        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertNil(owner.beginPicker { _ in
                XCTFail("A cancelled picker started its importer")
                return nil
            })
            XCTAssertNil(owner.accept(.success(selectedURL), from: picker))
        }
        await cancelled.value

        XCTAssertFalse(healthy.isCancelled)
        XCTAssertTrue(owner.isCurrent(picker))
        active.finish(.success(destination))
        await healthy.value
        XCTAssertNil(owner.failure)
    }

    func testRetainedAlertDismissalCannotClearTheNextIdenticalError() async throws {
        let owner = Owner()
        let first = try XCTUnwrap(owner.beginPicker { _ in nil })
        let firstTask = try XCTUnwrap(owner.accept(.success(source), from: first))
        await firstTask.value
        let firstFailure = try XCTUnwrap(owner.failure)
        let retainedDismissal = { owner.dismissError(firstFailure) }

        let replacement = try XCTUnwrap(owner.beginPicker { _ in nil })
        let secondTask = try XCTUnwrap(owner.accept(.success(source), from: replacement))
        await secondTask.value
        let secondFailure = try XCTUnwrap(owner.failure)
        XCTAssertEqual(firstFailure.message, secondFailure.message)
        XCTAssertNotEqual(firstFailure.id, secondFailure.id)

        retainedDismissal()
        XCTAssertFalse(owner.isErrorPresented(firstFailure))
        XCTAssertTrue(owner.isErrorPresented(secondFailure))
        XCTAssertEqual(owner.failure, secondFailure)
        owner.dismissError(secondFailure)
        XCTAssertNil(owner.failure)
    }

    func testReentrantFailureObserverCannotLoseItsSuccessorTask() async throws {
        let owner = Owner()
        let suspended = SuspendedImport()
        let selectedURL = source
        var shouldReplace = true
        var replacementTask: Task<Void, Never>?
        let observation = owner.objectWillChange.sink { _ in
            MainActor.assumeIsolated {
                guard shouldReplace, owner.failure != nil else { return }
                shouldReplace = false
                guard let picker = owner.beginPicker(importing: suspended.run) else {
                    XCTFail("Replacement picker was rejected")
                    return
                }
                replacementTask = owner.accept(.success(selectedURL), from: picker)
            }
        }
        let first = try XCTUnwrap(owner.beginPicker { _ in nil })
        let firstTask = try XCTUnwrap(owner.accept(.success(source), from: first))
        await firstTask.value
        await waitForEntry(suspended)

        let replacement = try XCTUnwrap(replacementTask)
        releaseOnTeardown(suspended, task: replacement)
        XCTAssertTrue(owner.isImporting)
        XCTAssertFalse(replacement.isCancelled)
        XCTAssertNil(owner.failure)
        suspended.finish(.success(destination))
        await replacement.value

        XCTAssertFalse(owner.isImporting)
        XCTAssertNil(owner.failure)
        withExtendedLifetime(observation) {}
        observation.cancel()
    }

    func testOwnerReleaseCancelsItsWaiterWithoutRetainingThePresentation() async throws {
        var owner: Owner? = Owner()
        weak var weakOwner = owner
        let suspended = SuspendedImport()
        let picker = try XCTUnwrap(owner?.beginPicker(importing: suspended.run))
        let task = try XCTUnwrap(owner?.accept(.success(source), from: picker))
        releaseOnTeardown(suspended, task: task)
        await waitForEntry(suspended)

        owner = nil
        XCTAssertNil(weakOwner)
        XCTAssertTrue(task.isCancelled)
        suspended.finish(.failure(ImportFailure()))
        await task.value
    }

    func testCancellationAfterFileCommitKeepsTheFileWithoutPublishingAnError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenericImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("committed.epub")
        let bytes = Data("already committed import".utf8)
        let owner = Owner()
        let picker = try XCTUnwrap(owner.beginPicker { _ in
            try bytes.write(to: output, options: .atomic)
            withUnsafeCurrentTask { $0?.cancel() }
            return output
        })
        let task = try XCTUnwrap(owner.accept(.success(source), from: picker))
        await task.value

        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertNil(owner.failure)
        XCTAssertFalse(owner.isImporting)
    }

    func testCapturedImporterDoesNotSwitchToANewerProvider() async throws {
        let owner = Owner()
        var firstInputs: [URL] = []
        var replacementInputs: [URL] = []
        let expectedDestination = destination
        var provider: Owner.Importer = { url in
            firstInputs.append(url)
            return expectedDestination
        }
        let picker = try XCTUnwrap(owner.beginPicker(importing: provider))
        provider = { url in
            replacementInputs.append(url)
            return nil
        }

        let task = try XCTUnwrap(owner.accept(.success(source), from: picker))
        await task.value
        XCTAssertEqual(firstInputs, [source])
        XCTAssertTrue(replacementInputs.isEmpty)
        XCTAssertNil(owner.failure)

        let replacement = try XCTUnwrap(owner.beginPicker(importing: provider))
        let replacementTask = try XCTUnwrap(owner.accept(.success(source), from: replacement))
        await replacementTask.value
        XCTAssertEqual(replacementInputs, [source])
        XCTAssertNotNil(owner.failure)
    }

    func testInactiveCallerCannotReplaceAHealthyImport() async throws {
        let owner = Owner()
        let suspended = SuspendedImport()
        let picker = try XCTUnwrap(owner.beginPicker(importing: suspended.run))
        let task = try XCTUnwrap(owner.accept(.success(source), from: picker))
        releaseOnTeardown(suspended, task: task)
        await waitForEntry(suspended)

        XCTAssertNil(owner.beginPicker(permitsPresentation: { false }) { _ in
            XCTFail("An inactive host started an import")
            return nil
        })
        XCTAssertTrue(owner.isCurrent(picker))
        XCTAssertFalse(task.isCancelled)
        suspended.finish(.success(destination))
        await task.value
        XCTAssertFalse(owner.isImporting)
    }

    func testMountedInactiveHostRejectsRetainedPickerResultWithoutDisappearing() throws {
        let owner = Owner()
        var hostIsActive = true
        var currentActivation = UUID()
        let originalActivation = currentActivation
        var calls = 0
        let picker = try XCTUnwrap(owner.beginPicker(
            permitsPresentation: { hostIsActive && currentActivation == originalActivation }
        ) { _ in
            calls += 1
            return nil
        })
        XCTAssertTrue(owner.hidePicker(picker))

        hostIsActive = false
        currentActivation = UUID()
        XCTAssertFalse(owner.isCurrent(picker))
        XCTAssertFalse(owner.hidePicker(picker))
        XCTAssertNil(owner.accept(.success(source), from: picker))

        // The same mounted host becomes active again, but its old lease does not.
        hostIsActive = true
        XCTAssertFalse(owner.isCurrent(picker))
        XCTAssertNil(owner.accept(.success(source), from: picker))
        XCTAssertEqual(calls, 0)
        XCTAssertNil(owner.failure)
    }

    func testMountedHostRetirementSuppressesLateFailureAndStillCleansItsAttempt() async throws {
        let owner = Owner()
        var hostIsActive = true
        let suspended = SuspendedImport()
        let picker = try XCTUnwrap(owner.beginPicker(
            permitsPresentation: { hostIsActive },
            importing: suspended.run
        ))
        let task = try XCTUnwrap(owner.accept(.success(source), from: picker))
        releaseOnTeardown(suspended, task: task)
        await waitForEntry(suspended)

        hostIsActive = false
        XCTAssertFalse(owner.isPickerPresented(picker))
        XCTAssertFalse(task.isCancelled)
        suspended.finish(.failure(ImportFailure()))
        await task.value

        XCTAssertNil(owner.failure)
        XCTAssertFalse(owner.isImporting)
        XCTAssertNotNil(owner.lifetime, "This schedule does not rely on onDisappear")
    }

    func testHostABADoesNotReviveErrorAndFreshActivationCanRetry() async throws {
        let owner = Owner()
        var hostIsActive = true
        var currentActivation = UUID()
        let originalActivation = currentActivation
        let first = try XCTUnwrap(owner.beginPicker(
            permitsPresentation: { hostIsActive && currentActivation == originalActivation }
        ) { _ in nil })
        let firstTask = try XCTUnwrap(owner.accept(.success(source), from: first))
        await firstTask.value
        let oldFailure = try XCTUnwrap(owner.failure)
        XCTAssertTrue(owner.isErrorPresented(oldFailure))

        hostIsActive = false
        currentActivation = UUID()
        XCTAssertFalse(owner.isErrorPresented(oldFailure))
        hostIsActive = true
        XCTAssertFalse(owner.isErrorPresented(oldFailure))
        XCTAssertNil(owner.accept(.success(source), from: first))

        let replacementActivation = currentActivation
        let replacement = try XCTUnwrap(owner.beginPicker(
            permitsPresentation: { hostIsActive && currentActivation == replacementActivation }
        ) { _ in nil })
        let retryTask = try XCTUnwrap(owner.accept(.success(source), from: replacement))
        await retryTask.value
        let newFailure = try XCTUnwrap(owner.failure)
        owner.dismissError(oldFailure)
        XCTAssertTrue(owner.isErrorPresented(newFailure))
        XCTAssertEqual(owner.failure, newFailure)
    }

    func testHostABABeforeSuspendedCompletionDoesNotReauthorizeTheOldAttempt() async throws {
        let owner = Owner()
        var hostIsActive = true
        var currentActivation = UUID()
        let originalActivation = currentActivation
        let suspended = SuspendedImport()
        let picker = try XCTUnwrap(owner.beginPicker(
            permitsPresentation: { hostIsActive && currentActivation == originalActivation },
            importing: suspended.run
        ))
        let task = try XCTUnwrap(owner.accept(.success(source), from: picker))
        releaseOnTeardown(suspended, task: task)
        await waitForEntry(suspended)

        hostIsActive = false
        currentActivation = UUID()
        hostIsActive = true
        XCTAssertFalse(owner.isCurrent(picker))
        XCTAssertFalse(task.isCancelled)
        suspended.finish(.failure(ImportFailure()))
        await task.value

        XCTAssertNil(owner.failure)
        XCTAssertFalse(owner.isImporting)
        XCTAssertNotNil(owner.lifetime)
    }

    func testHostRetirementDuringFailureNotificationCannotPublishOrClearSuccessor() async throws {
        let owner = Owner()
        var currentActivation = UUID()
        let originalActivation = currentActivation
        let suspended = SuspendedImport()
        let selectedURL = source
        var shouldReplace = true
        var retiredFailure: Owner.Failure?
        var replacementTask: Task<Void, Never>?
        let observation = owner.objectWillChange.sink { _ in
            MainActor.assumeIsolated {
                guard shouldReplace, let failure = owner.failure else { return }
                shouldReplace = false
                retiredFailure = failure
                currentActivation = UUID()
                XCTAssertFalse(owner.isErrorPresented(failure))
                let replacementActivation = currentActivation
                guard let picker = owner.beginPicker(
                    permitsPresentation: { currentActivation == replacementActivation },
                    importing: suspended.run
                ) else {
                    XCTFail("The new host activation could not begin a picker")
                    return
                }
                replacementTask = owner.accept(.success(selectedURL), from: picker)
            }
        }
        let first = try XCTUnwrap(owner.beginPicker(
            permitsPresentation: { currentActivation == originalActivation }
        ) { _ in nil })
        let firstTask = try XCTUnwrap(owner.accept(.success(source), from: first))
        await firstTask.value
        let replacement = try XCTUnwrap(replacementTask)
        releaseOnTeardown(suspended, task: replacement)
        await waitForEntry(suspended)

        XCTAssertTrue(owner.isImporting)
        XCTAssertFalse(replacement.isCancelled)
        XCTAssertNil(owner.failure)
        owner.dismissError(try XCTUnwrap(retiredFailure))
        XCTAssertTrue(owner.isImporting)
        suspended.finish(.success(destination))
        await replacement.value
        XCTAssertFalse(owner.isImporting)
        XCTAssertNil(owner.failure)
        withExtendedLifetime(observation) {}
        observation.cancel()
    }
}
