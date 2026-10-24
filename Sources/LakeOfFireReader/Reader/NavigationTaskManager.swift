import SwiftUI
import LakeOfFireContent

/// Owns the semantic commit/finish lifecycle for one mounted reader document.
@MainActor
internal final class NavigationTaskManager: Identifiable {
    internal typealias NavigationOperation = @MainActor () async throws -> Void

    private enum DocumentPhase {
        case idle
        case awaitingFinish
        case finishing
        case settled
        case failed
        case invalidated
    }

    private(set) var onNavigationCommittedTask: Task<Void, Error>?
    private(set) var onNavigationFinishedTask: Task<Void, Error>?
    private(set) var onNavigationFailedTask: Task<Void, Error>?
    private(set) var onURLChangedTask: Task<Void, Error>?

    private var documentGeneration: UInt64 = 0
    private var urlChangedGeneration: UInt64 = 0
    private var documentPhase: DocumentPhase = .idle
    private var pendingURLChangedOperation: NavigationOperation?

    private(set) var callbackOwner: ReaderNavigationCallbackOwner?
    var committedCallbackContext: ReaderNavigationCallbackContext?

    func registerCallbackOwner(_ candidate: ReaderNavigationCallbackOwner) -> ReaderNavigationCallbackOwner {
        if let callbackOwner, callbackOwner.matches(candidate) { return callbackOwner }
        let hadOwner = callbackOwner != nil
        callbackOwner = candidate
        // Retire before cancellation/activity publication can reenter. An
        // unchanged SwiftUI wrapper reconstruction never takes this path.
        if hadOwner {
            let generation = invalidateNavigationWork()
            if callbackOwner === candidate, documentGeneration == generation {
                documentPhase = .idle
            }
        }
        return candidate
    }

    /// The environment's two-argument refresh function captures the mounted
    /// selection at invocation. A stale peer cannot borrow the current row's
    /// admission merely because its URL matches.
    func makeSettingsCommitFence(
        content: any ReaderContentProtocol,
        readerViewModel: ReaderViewModel
    ) -> @MainActor () -> Bool {
        guard let owner = callbackOwner, owner.readerViewModel === readerViewModel,
              owner.scriptCaller === readerViewModel.scriptCaller,
              owner.readerContent.content === content else { return { false } }
        let selection = owner.readerContent.makeSelectionCommitFence(
            requiring: owner.readerContent.currentSelectionID
        )
        let generation = documentGeneration
        return { [weak self] in
            guard let self, callbackOwner === owner,
                  documentGeneration == generation, selection(),
                  owner.readerContent.content === content else { return false }
            switch documentPhase {
            case .idle, .awaitingFinish, .finishing, .settled:
                return true
            case .failed, .invalidated:
                return false
            }
        }
    }

    private func cancelOutstandingTasks() {
        onNavigationCommittedTask?.cancel()
        onNavigationFinishedTask?.cancel()
        onNavigationFailedTask?.cancel()
        onURLChangedTask?.cancel()
        onNavigationCommittedTask = nil
        onNavigationFinishedTask = nil
        onNavigationFailedTask = nil
        onURLChangedTask = nil
    }

    private func validateDocumentGeneration(_ generation: UInt64) throws {
        guard documentGeneration == generation else { throw CancellationError() }
    }

    /// Capture at the native callback, before its operation is queued. This
    /// keeps later presentation work on the existing document lifetime even
    /// after the callback's own Task has finished.
    func makeDocumentCommitFence() -> @MainActor () -> Bool {
        let generation = documentGeneration
        return { [weak self] in
            guard let self, documentGeneration == generation else { return false }
            switch documentPhase {
            case .awaitingFinish, .finishing, .settled:
                return true
            case .idle, .failed, .invalidated:
                return false
            }
        }
    }

    private func logFailure(_ error: Error, stage: String) {
        guard !(error is CancellationError) else { return }
        print("Error during \(stage): \(error)")
    }

    func startOnNavigationCommitted(task operation: @escaping NavigationOperation) {
        cancelOutstandingTasks()
        documentGeneration &+= 1
        urlChangedGeneration &+= 1
        documentPhase = .awaitingFinish
        pendingURLChangedOperation = nil
        let generation = documentGeneration

        let committedTask = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            do {
                try Task.checkCancellation()
                try await operation()
                try Task.checkCancellation()
                try validateDocumentGeneration(generation)
            } catch {
                if documentGeneration == generation {
                    documentPhase = .failed
                    pendingURLChangedOperation = nil
                }
                logFailure(error, stage: "onNavigationCommitted")
                throw error
            }
        }
        onNavigationCommittedTask = committedTask
    }

    func startOnNavigationFinished(task operation: @escaping NavigationOperation) {
        let generation = documentGeneration
        guard let committedTask = onNavigationCommittedTask,
              documentPhase == .awaitingFinish else { return }

        documentPhase = .finishing
        let finishedTask = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            do {
                try await committedTask.value
                try Task.checkCancellation()
                try validateDocumentGeneration(generation)
                try await operation()
                try Task.checkCancellation()
                try validateDocumentGeneration(generation)
                documentPhase = .settled
                let pendingOperation = pendingURLChangedOperation
                pendingURLChangedOperation = nil
                if let pendingOperation {
                    startURLChangedOperation(pendingOperation)
                }
            } catch {
                if documentGeneration == generation {
                    documentPhase = .failed
                    pendingURLChangedOperation = nil
                }
                logFailure(error, stage: "onNavigationFinished")
                throw error
            }
        }
        onNavigationFinishedTask = finishedTask
    }

    func startOnNavigationFailed(
        preservingCommittedDocument: Bool = false,
        task operation: @escaping @MainActor () async -> Void
    ) {
        let generation: UInt64
        if preservingCommittedDocument {
            generation = documentGeneration
            onNavigationFailedTask?.cancel()
            onNavigationFailedTask = nil
        } else {
            generation = invalidateNavigationWork()
        }
        guard documentGeneration == generation else { return }
        onNavigationFailedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try validateDocumentGeneration(generation)
                await operation()
                try Task.checkCancellation()
                try validateDocumentGeneration(generation)
            } catch {
                logFailure(error, stage: "onNavigationFailed")
            }
        }
    }

    func cancelNavigationWork() {
        _ = invalidateNavigationWork()
    }

    private func invalidateNavigationWork() -> UInt64 {
        let retiredContext = committedCallbackContext
        committedCallbackContext = nil
        documentGeneration &+= 1
        let generation = documentGeneration
        urlChangedGeneration &+= 1
        documentPhase = .invalidated
        pendingURLChangedOperation = nil
        cancelOutstandingTasks()
        retiredContext?.endNavigationActivity()
        return generation
    }

    func startOnURLChanged(task operation: @escaping NavigationOperation) {
        switch documentPhase {
        case .awaitingFinish, .finishing:
            pendingURLChangedOperation = operation
        case .settled:
            startURLChangedOperation(operation)
        case .idle, .failed, .invalidated:
            break
        }
    }

    private func startURLChangedOperation(_ operation: @escaping NavigationOperation) {
        onURLChangedTask?.cancel()
        urlChangedGeneration &+= 1
        let urlGeneration = urlChangedGeneration
        let generation = documentGeneration
        let urlTask = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            do {
                try Task.checkCancellation()
                try validateDocumentGeneration(generation)
                guard urlChangedGeneration == urlGeneration else { throw CancellationError() }
                try await operation()
                try Task.checkCancellation()
                try validateDocumentGeneration(generation)
                guard urlChangedGeneration == urlGeneration else { throw CancellationError() }
            } catch {
                logFailure(error, stage: "onURLChanged")
                throw error
            }
        }
        onURLChangedTask = urlTask
    }
}
