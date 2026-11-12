import Foundation

/// Owns one catalog producer. Cancellation is advisory; identity is checked at
/// publication as well, so an uncooperative old producer cannot replace new data.
@MainActor
final class BookCatalogRefresh {
    private var requestID: UUID?
    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    @discardableResult
    func start(
        fetch: @escaping @MainActor () async -> ([Publication], String?),
        publish: @escaping @MainActor ([Publication], String?) -> Void
    ) -> Task<Void, Never>? {
        // An already-cancelled entrant must not revoke a healthy current request.
        guard !Task.isCancelled else { return nil }
        task?.cancel()
        let id = UUID()
        requestID = id
        let newTask = Task { @MainActor [weak self] in
            defer {
                if self?.requestID == id {
                    self?.requestID = nil
                    self?.task = nil
                }
            }
            guard !Task.isCancelled, self?.requestID == id else { return }
            let result = await fetch()
            guard !Task.isCancelled, self?.requestID == id else { return }
            publish(result.0, result.1)
        }
        task = newTask
        return newTask
    }

    func load(
        fetch: @escaping @MainActor () async -> ([Publication], String?),
        publish: @escaping @MainActor ([Publication], String?) -> Void
    ) async {
        guard let ownedTask = start(fetch: fetch, publish: publish) else { return }
        // Cancelling an old refresh cancels its task, never the latest task slot.
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
