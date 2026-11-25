import Foundation

enum BookCatalogPageRequest {
    case first(URL)
    case next(URL, visited: Set<URL>)

    var url: URL {
        switch self {
        case let .first(url), let .next(url, _): return url
        }
    }
}

struct BookCatalogPage {
    let publications: [Publication]
    var nextURL: URL? = nil
    var visited: Set<URL> = []
}

enum BookCatalogPageLoad {
    static let cycleMessage = "The catalog links back to a document that was already opened."

    case page(BookCatalogPage)
    case failure(String)
    case cycle
    case cancelled
}

/// Owns one catalog request. Cancellation is advisory; identity is checked at
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
        start(fetch: fetch, publish: { publish($0.0, $0.1) }, onFinish: {})
    }

    @discardableResult
    func startPage(
        fetch: @escaping @MainActor () async -> BookCatalogPageLoad,
        publish: @escaping @MainActor (BookCatalogPageLoad) -> Void,
        onFinish: @escaping @MainActor () -> Void = {}
    ) -> Task<Void, Never>? {
        start(fetch: fetch, publish: publish, onFinish: onFinish)
    }

    private func start<Value>(
        fetch: @escaping @MainActor () async -> Value,
        publish: @escaping @MainActor (Value) -> Void,
        onFinish: @escaping @MainActor () -> Void
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
                    onFinish()
                }
            }
            guard !Task.isCancelled, self?.requestID == id else { return }
            let result = await fetch()
            guard !Task.isCancelled, self?.requestID == id else { return }
            publish(result)
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
