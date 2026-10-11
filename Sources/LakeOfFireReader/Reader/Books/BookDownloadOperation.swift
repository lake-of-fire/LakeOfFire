import Foundation

/// Owns row-local download/import work. Passive download notifications cannot
/// revoke a user's selection; a new explicit selection may replace older work.
@MainActor
final class BookDownloadOperation {
    private var requestID: UUID?
    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    @discardableResult
    func start<Value: Sendable>(
        replacingCurrent: Bool = true,
        operation: @escaping @MainActor () async -> Value?,
        publish: @escaping @MainActor (Value) -> Void
    ) -> Task<Void, Never>? {
        guard !Task.isCancelled,
              replacingCurrent || task == nil || task?.isCancelled == true else { return nil }
        task?.cancel()
        let id = UUID()
        requestID = id
        let startedTask = Task { @MainActor [weak self] in
            defer {
                if self?.requestID == id {
                    self?.requestID = nil
                    self?.task = nil
                }
            }
            guard !Task.isCancelled, self?.requestID == id else { return }
            let result = await operation()
            guard !Task.isCancelled, self?.requestID == id, let result else { return }
            publish(result)
        }
        task = startedTask
        return startedTask
    }

    func refresh<Value: Sendable>(
        operation: @escaping @MainActor () async -> Value?,
        publish: @escaping @MainActor (Value) -> Void
    ) async {
        guard let ownedTask = start(replacingCurrent: false, operation: operation, publish: publish) else { return }
        await withTaskCancellationHandler {
            await ownedTask.value
        } onCancel: {
            ownedTask.cancel()
        }
    }

    func cancel() {
        requestID = nil
        task?.cancel()
        task = nil
    }
}
