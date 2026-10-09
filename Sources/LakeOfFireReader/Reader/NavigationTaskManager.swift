import SwiftUI
import SwiftUIWebView
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
    internal typealias NavigationOperation = @MainActor @Sendable () async throws -> Void

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
    private struct URLChangedOperation: Sendable {
        let run: NavigationOperation
        let discard: @MainActor @Sendable () -> Void
        var intentID: UUID? = nil
    }
    private var pendingURLChangedOperation: URLChangedOperation?
    private var activeURLChangedOperation: URLChangedOperation?

    private func discardPendingURLChange() {
        let discarded = pendingURLChangedOperation
        pendingURLChangedOperation = nil
        discarded?.discard()
    }

    private func failDocumentWork(ifGeneration generation: UInt64) {
        guard documentGeneration == generation else { return }
        documentPhase = .failed
        discardPendingURLChange()
    }

    private func cancelOutstandingTasks() {
        let active = activeURLChangedOperation
        activeURLChangedOperation = nil
        active?.discard()
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
        discardPendingURLChange()
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
                try await withTaskCancellationHandler {
                    try await operation()
                } onCancel: {
                    Task { @MainActor [weak self] in
                        self?.failDocumentWork(ifGeneration: generation)
                    }
                }
                try Task.checkCancellation()
                try self.validateDocumentGeneration(generation)
            } catch {
                if self.documentGeneration == generation {
                    self.failDocumentWork(ifGeneration: generation)
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
                try await withTaskCancellationHandler {
                    try await committedTask.value
                } onCancel: {
                    Task { @MainActor [weak self] in
                        self?.failDocumentWork(ifGeneration: generation)
                    }
                }
                try Task.checkCancellation()
                try self.validateDocumentGeneration(generation)
                try await withTaskCancellationHandler {
                    try await operation()
                } onCancel: {
                    Task { @MainActor [weak self] in
                        self?.failDocumentWork(ifGeneration: generation)
                    }
                }
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
                    self.failDocumentWork(ifGeneration: generation)
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
        discardPendingURLChange()
        cancelOutstandingTasks()
    }

    /// Handles a same-document URL mutation without stealing the main document's
    /// finish. While commit/finish is active, retain only the latest mutation and
    /// run its complete refresh after semantic finish succeeds. This matters when
    /// a page calls `replaceState` during load: the original commit may own the old
    /// content URL even though WebKit's eventual state already exposes the new one.
    @discardableResult
    func startOnURLChanged(task operation: @escaping NavigationOperation) -> Bool {
        startOnURLChanged(URLChangedOperation(run: operation, discard: {}))
    }

    /// Reserve native ownership synchronously, before this manager can defer.
    /// Every failed, replaced or cancelled operation withdraws its exact handoff.
    @discardableResult
    func startOnURLChanged(state: WebViewState, readerContent: ReaderContent,
                           task operation: @escaping NavigationOperation) -> Bool {
        let intent = state.urlTransitionIntent
        if let intent {
            guard readerContent.receiveSelectionIntent(intent) != nil else { return false }
            if pendingURLChangedOperation?.intentID == intent.id || activeURLChangedOperation?.intentID == intent.id {
                return true
            }
        }
        return startOnURLChanged(URLChangedOperation(run: operation, discard: {
            if let intent { readerContent.withdrawSelectionIntent(intent) }
        }, intentID: intent?.id))
    }

    private func startOnURLChanged(_ operation: URLChangedOperation) -> Bool {
        switch documentPhase {
        case .awaitingFinish, .finishing:
            discardPendingURLChange()
            pendingURLChangedOperation = operation
        case .settled:
            startURLChangedOperation(operation)
        case .idle, .failed, .invalidated:
            operation.discard()
            return false
        }
        return true
    }

    private func startURLChangedOperation(
        _ operation: URLChangedOperation
    ) {
        activeURLChangedOperation?.discard()
        activeURLChangedOperation = operation
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
                try await withTaskCancellationHandler {
                    try await operation.run()
                } onCancel: {
                    Task { @MainActor in operation.discard() }
                }
                try Task.checkCancellation()
                try self.validateDocumentGeneration(generation)
                guard self.urlChangedGeneration == urlGeneration else {
                    throw CancellationError()
                }
                if self.urlChangedGeneration == urlGeneration { self.activeURLChangedOperation = nil }
            } catch {
                operation.discard()
                if self.urlChangedGeneration == urlGeneration { self.activeURLChangedOperation = nil }
                self.logFailure(error, stage: "onURLChanged")
                throw error
            }
        }
        onURLChangedTask = urlTask
    }
}
