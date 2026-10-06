import Foundation

/// Global owner for explicit book-open actions. Row-local refresh/import tasks have
/// separate ownership; this coordinator prevents an older row from navigating or
/// publishing after a newer explicit selection supersedes it.
@MainActor
final class BookOpenSelectionCoordinator {
    struct Selection: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    struct NavigationClaim {
        let isCurrent: @MainActor () -> Bool
    }

    struct StageOperations {
        let resolveDownloadable: @MainActor () async throws -> Bool
        let existsLocally: @MainActor () async -> Bool
        let importContent: @MainActor (Bool) async throws -> Bool
        let loadContent: @MainActor () async throws -> Bool
        let navigate: @MainActor (NavigationClaim) async throws -> Void
        let publishNavigation: @MainActor () -> Void
    }

    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }

    @discardableResult
    func start(
        onStart: (@MainActor (Selection) -> Void)? = nil,
        _ operation: @escaping @MainActor (Selection) async -> Void
    ) -> Task<Void, Never>? {
        // A cancelled entrant must not revoke a healthy existing owner.
        guard !Task.isCancelled else { return nil }
        task?.cancel()
        generation &+= 1
        let selection = Selection(generation: generation)
        onStart?(selection)
        let started = Task { @MainActor [weak self] in
            guard let self, self.isCurrent(selection) else { return }
            await operation(selection)
            if self.isCurrent(selection) {
                self.task = nil
            }
        }
        task = started
        return started
    }

    func isCurrent(_ selection: Selection) -> Bool {
        !Task.isCancelled && selection.generation == generation
    }

    @discardableResult
    func cancel(ifCurrent selection: Selection) -> Bool {
        guard selection.generation == generation else { return false }
        cancel()
        return true
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    static func run(
        stages: StageOperations,
        shouldContinue: @escaping @MainActor () -> Bool
    ) async throws {
        guard shouldContinue() else { return }
        guard try await stages.resolveDownloadable() else { return }
        guard shouldContinue() else { return }

        let existsLocally = await stages.existsLocally()
        guard shouldContinue() else { return }
        guard try await stages.importContent(existsLocally) else { return }
        guard shouldContinue() else { return }
        guard try await stages.loadContent() else { return }
        guard shouldContinue() else { return }

        try await stages.navigate(
            NavigationClaim(isCurrent: shouldContinue)
        )
        guard shouldContinue() else { return }
        stages.publishNavigation()
    }
}
