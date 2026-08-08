import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore

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
    private var urlChangedGeneration = 0

    private static func waitForTask(_ task: Task<Void, Error>?) async {
        guard let task else { return }
        _ = try? await task.value
    }
    
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
        let committedTask = onNavigationCommittedTask
        onNavigationFinishedTask = Task { @MainActor in
            await Self.waitForTask(committedTask)
            try Task.checkCancellation()
            await task()
        }
    }
    
    @MainActor
    func startOnNavigationFailed(task: @escaping () async -> Void) {
        onNavigationFailedTask?.cancel()
        onNavigationFailedTask = Task { @MainActor in
            try Task.checkCancellation()
            await task()
        }
    }
    
    @MainActor
    func startOnURLChanged(task: @escaping () async -> Void) {
        onURLChangedTask?.cancel()
        urlChangedGeneration += 1
        let generation = urlChangedGeneration
        let nextTask = Task { @MainActor in
            try Task.checkCancellation()
            await task()
        }
        onURLChangedTask = nextTask
        Task { @MainActor [weak self] in
            _ = try? await nextTask.value
            guard let self, self.urlChangedGeneration == generation else { return }
            self.onURLChangedTask = nil
        }
    }
}
