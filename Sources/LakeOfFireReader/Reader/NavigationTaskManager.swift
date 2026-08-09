import SwiftUI

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
        if preservingCommittedDocument {
            onNavigationFailedTask?.cancel()
            onNavigationFailedTask = nil
        } else {
            cancelNavigationWork()
        }
        let generation = documentGeneration
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
        documentGeneration &+= 1
        urlChangedGeneration &+= 1
        documentPhase = .invalidated
        pendingURLChangedOperation = nil
        cancelOutstandingTasks()
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
