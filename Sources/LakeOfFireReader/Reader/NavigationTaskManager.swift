import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore

/// Owns the semantic commit/finish lifecycle for one mounted reader document.
///
/// WebKit may deliver `didFinish` before asynchronous commit preparation has
/// completed. It may also receive `pushState`/`replaceState` notifications while
/// the main document is still loading. Keep those paths under one document
/// generation so only a successful commit authorizes finish publication:
///
/// - a URL mutation before semantic finish completes is retained as the latest
///   pending same-document refresh and runs once afterward without stealing the
///   main document's `didFinish`;
/// - a URL mutation on a fully settled document is a complete same-document
///   commit/finish operation because WebKit will not send another `didFinish`.
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
        guard documentGeneration == generation else {
            throw CancellationError()
        }
    }

    private func logFailure(_ error: Error, stage: String) {
        guard !(error is CancellationError) else { return }
        print("Error during \(stage): \(error)")
    }

    func startOnNavigationCommitted(
        task operation: @escaping NavigationOperation
    ) {
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
                try self.validateDocumentGeneration(generation)
            } catch {
                if self.documentGeneration == generation {
                    self.documentPhase = .failed
                    self.pendingURLChangedOperation = nil
                }
                self.logFailure(error, stage: "onNavigationCommitted")
                throw error
            }
        }
        onNavigationCommittedTask = committedTask
    }

    func startOnNavigationFinished(
        task operation: @escaping NavigationOperation
    ) {
        let generation = documentGeneration
        guard let committedTask = onNavigationCommittedTask,
              documentPhase == .awaitingFinish else {
            return
        }

        documentPhase = .finishing
        let finishedTask = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            do {
                try await committedTask.value
                try Task.checkCancellation()
                try self.validateDocumentGeneration(generation)
                try await operation()
                try Task.checkCancellation()
                try self.validateDocumentGeneration(generation)

                self.documentPhase = .settled
                let pendingURLChangedOperation = self.pendingURLChangedOperation
                self.pendingURLChangedOperation = nil
                if let pendingURLChangedOperation {
                    self.startURLChangedOperation(pendingURLChangedOperation)
                }
            } catch {
                if self.documentGeneration == generation {
                    self.documentPhase = .failed
                    self.pendingURLChangedOperation = nil
                }
                self.logFailure(error, stage: "onNavigationFinished")
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
            // A failed provisional replacement leaves the currently committed
            // document mounted. Report the failure without invalidating that
            // document's semantic commit/finish or later same-document URLs.
            onNavigationFailedTask?.cancel()
            onNavigationFailedTask = nil
        } else {
            // A terminal navigation failure invalidates all work that was still
            // preparing or publishing the failed document. Do not let a cancelled
            // commit, finish, or URL callback resume and repopulate reader state.
            cancelNavigationWork()
        }
        let generation = documentGeneration
        onNavigationFailedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try self.validateDocumentGeneration(generation)
                await operation()
                try Task.checkCancellation()
                try self.validateDocumentGeneration(generation)
            } catch {
                self.logFailure(error, stage: "onNavigationFailed")
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

    /// Handles a same-document URL mutation without stealing the main document's
    /// finish. While commit/finish is active, retain only the latest mutation and
    /// run its complete refresh after semantic finish succeeds. This matters when
    /// a page calls `replaceState` during load: the original commit may own the old
    /// content URL even though WebKit's eventual state already exposes the new one.
    func startOnURLChanged(
        task operation: @escaping NavigationOperation
    ) {
        switch documentPhase {
        case .awaitingFinish, .finishing:
            pendingURLChangedOperation = operation
        case .settled:
            startURLChangedOperation(operation)
        case .idle, .failed, .invalidated:
            // A URL notification received before the first successful commit has
            // no semantic document baseline. It can be a delayed message from a
            // detached/replaced WebView or a document-start mutation racing the
            // main-frame commit. The commit's current URL will establish the next
            // valid owner; do not synthesize an independent commit/finish cycle.
            break
        }
    }

    private func startURLChangedOperation(
        _ operation: @escaping NavigationOperation
    ) {
        onURLChangedTask?.cancel()
        urlChangedGeneration &+= 1
        let urlGeneration = urlChangedGeneration
        let generation = documentGeneration

        let urlTask = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            do {
                try Task.checkCancellation()
                try self.validateDocumentGeneration(generation)
                guard self.urlChangedGeneration == urlGeneration else {
                    throw CancellationError()
                }
                try await operation()
                try Task.checkCancellation()
                try self.validateDocumentGeneration(generation)
                guard self.urlChangedGeneration == urlGeneration else {
                    throw CancellationError()
                }
            } catch {
                self.logFailure(error, stage: "onURLChanged")
                throw error
            }
        }
        onURLChangedTask = urlTask
    }
}
