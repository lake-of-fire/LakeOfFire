import SwiftUI
import LakeOfFireCore
import LakeOfFireAdblock

internal class NavigationTaskManager: Identifiable {
    @MainActor
    var onNavigationCommittedTask: Task<Void, Error>?
    @MainActor
    var onNavigationFinishedTask: Task<Void, Error>?
    @MainActor
    var onNavigationFailedTask: Task<Void, Error>?
    @MainActor
    var onURLChangedTask: Task<Void, Error>?
    
    @MainActor
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
    
    @MainActor
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
    
    @MainActor
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
    
    @MainActor
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
