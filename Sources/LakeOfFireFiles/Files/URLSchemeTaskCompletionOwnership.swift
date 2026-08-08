import Foundation

/// Owns the single terminal callback right for class-backed URL-scheme tasks.
/// Cancellation and completion race through one exact object-identity claim.
public final class URLSchemeTaskCompletionOwnership: @unchecked Sendable {
    private struct ActiveTask {
        let task: AnyObject
        var workCancellations: [@Sendable () -> Void] = []
    }

    private let lock = NSLock()
    private var activeTasks: [ObjectIdentifier: ActiveTask] = [:]

    public init() {}

    public func begin(_ task: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        activeTasks[ObjectIdentifier(task)] = ActiveTask(task: task)
    }

    /// Attaches cancellation for asynchronous work owned by an active scheme task.
    /// If WebKit already stopped or completed the task, the work is cancelled
    /// immediately rather than being allowed to run without a terminal owner.
    @discardableResult
    public func attachCancellation(
        _ task: AnyObject,
        cancellation: @escaping @Sendable () -> Void
    ) -> Bool {
        lock.lock()
        let identifier = ObjectIdentifier(task)
        guard var activeTask = activeTasks[identifier], activeTask.task === task else {
            lock.unlock()
            cancellation()
            return false
        }
        activeTask.workCancellations.append(cancellation)
        activeTasks[identifier] = activeTask
        lock.unlock()
        return true
    }

    @discardableResult
    public func cancel(_ task: AnyObject) -> Bool {
        guard let activeTask = remove(task) else {
            return false
        }
        for cancellation in activeTask.workCancellations {
            cancellation()
        }
        return true
    }

    @discardableResult
    public func claimCompletion(_ task: AnyObject) -> Bool {
        remove(task) != nil
    }

    private func remove(_ task: AnyObject) -> ActiveTask? {
        lock.lock()
        defer { lock.unlock() }
        let identifier = ObjectIdentifier(task)
        guard let activeTask = activeTasks[identifier], activeTask.task === task else {
            return nil
        }
        activeTasks.removeValue(forKey: identifier)
        return activeTask
    }
}
