import Foundation
import SwiftUIWebView

/// One native URL intent may acquire exactly one successor selection. Waiting
/// retains that intent; it cannot adopt a later selection with the same URL.
public final class ReaderContentSelectionHandoff: @unchecked Sendable {
    public let intent: WebViewURLTransitionIntent
    public let predecessorSelectionID: UUID?
    private let predecessorIsCurrent: @Sendable () -> Bool
    private let lock = NSLock()
    private enum State {
        case pending
        case loading(UUID?, @Sendable () -> Bool)
        case selected(UUID?, @Sendable () -> Bool)
        case withdrawn
    }
    private var state = State.pending
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    internal init(intent: WebViewURLTransitionIntent, predecessorSelectionID: UUID?,
                  predecessorIsCurrent: @escaping @Sendable () -> Bool) {
        self.intent = intent
        self.predecessorSelectionID = predecessorSelectionID
        self.predecessorIsCurrent = predecessorIsCurrent
    }

    private func snapshot() -> State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public var permitsCapture: Bool {
        guard intent.isCurrent else { return false }
        switch snapshot() {
        case .pending: return predecessorIsCurrent()
        case .loading(_, let fence), .selected(_, let fence): return fence()
        case .withdrawn: return false
        }
    }

    public var permitsCommit: Bool {
        guard intent.isCurrent, case .selected(_, let fence) = snapshot() else { return false }
        return fence() && intent.isCurrent
    }

    internal var isPending: Bool {
        if case .pending = snapshot() { return true }
        return false
    }

    /// Bind the next selection before publishing any of its observable state.
    /// This does not release lifecycle handlers until its content is available.
    internal func beginSelection(selectionID: UUID?, fence: @escaping @Sendable () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard intent.isCurrent else { return false }
        switch state {
        case .pending:
            state = .loading(selectionID, fence)
            return true
        case .loading(let currentID, _), .selected(let currentID, _):
            return currentID == selectionID
        case .withdrawn:
            return false
        }
    }

    internal func completeSelection(selectionID: UUID?) {
        lock.lock()
        guard intent.isCurrent,
              case .loading(let currentID, let fence) = state,
              currentID == selectionID else { lock.unlock(); return }
        state = .selected(selectionID, fence)
        let completions = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        completions.forEach { $0.resume(returning: true) }
    }

    internal func withdrawIfUnselected() {
        lock.lock()
        if case .selected = state { lock.unlock(); return }
        state = .withdrawn
        let completions = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        completions.forEach { $0.resume(returning: false) }
    }

    internal func withdraw() {
        lock.lock()
        state = .withdrawn
        let completions = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        completions.forEach { $0.resume(returning: false) }
    }

    private func cancelWaiter(_ id: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.resume(returning: false)
    }

    private func register(_ continuation: CheckedContinuation<Bool, Never>, id: UUID) {
        lock.lock()
        guard !Task.isCancelled, intent.isCurrent else {
            lock.unlock()
            continuation.resume(returning: false)
            return
        }
        switch state {
        case .pending, .loading:
            waiters[id] = continuation
            lock.unlock()
        case .selected:
            lock.unlock()
            continuation.resume(returning: true)
        case .withdrawn:
            lock.unlock()
            continuation.resume(returning: false)
        }
    }

    public func waitUntilSelected() async -> Bool {
        let id = UUID()
        let selected = await withTaskCancellationHandler {
            await withCheckedContinuation { register($0, id: id) }
        } onCancel: {
            self.cancelWaiter(id)
        }
        return selected && !Task.isCancelled && permitsCommit
    }
}
