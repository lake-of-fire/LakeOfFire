import SwiftUI

@MainActor
internal class NavigationTaskManager: ObservableObject {
    @Published var onNavigationCommittedTask: Task<Void, Error>?
    @Published var onNavigationFinishedTask: Task<Void, Error>?
    @Published var onNavigationFailedTask: Task<Void, Error>?
    @Published var onURLChangedTask: Task<Void, Error>?
    
    func startOnNavigationCommitted(task: @escaping () async throws -> Void) {
        onNavigationCommittedTask?.cancel()
        onNavigationCommittedTask = Task { @MainActor in
            do {
                try await task()
            } catch {
                if !(error is CancellationError) {
                    print("Error during onNavigationCommitted: \(error)")
                }
            }
        }
    }
    
    func startOnNavigationFinished(task: @escaping () async -> Void) {
        onNavigationFinishedTask?.cancel()
        onNavigationFinishedTask = Task { @MainActor in
            if let committedTask = onNavigationCommittedTask {
                _ = try? await committedTask.value // Wait for the committed task to finish if it's still running
            }
            try Task.checkCancellation()
            await task()
        }
    }
    
    func startOnNavigationFailed(task: @escaping () async -> Void) {
        onNavigationFailedTask?.cancel()
        onNavigationFailedTask = Task { @MainActor in
            if let failedTask = onNavigationFailedTask {
                _ = try? await failedTask.value
            }
            try Task.checkCancellation()
            await task()
        }
    }
    
    func startOnURLChanged(task: @escaping () async -> Void) {
        Task { @MainActor in
            onURLChangedTask?.cancel()
            _ = try? await onURLChangedTask?.value
            onURLChangedTask = Task { @MainActor in
                try Task.checkCancellation()
                await task()
            }
            _ = try? await onURLChangedTask?.value
            onURLChangedTask = nil
        }
    }
}
