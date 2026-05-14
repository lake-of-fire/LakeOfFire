import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore

private actor NavigationTaskWaitState {
    private var didResume = false

    func resume(_ continuation: CheckedContinuation<Void, Never>) {
        guard !didResume else { return }
        didResume = true
        continuation.resume()
    }
}

internal class NavigationTaskManager: Identifiable {
    private static let taskDrainTimeoutNanoseconds: UInt64 = 1_000_000_000

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

    private static func waitBrieflyForTask(_ task: Task<Void, Error>?) async {
        guard let task else { return }

        await withCheckedContinuation { continuation in
            let state = NavigationTaskWaitState()
            Task {
                _ = try? await task.value
                await state.resume(continuation)
            }
            Task {
                try? await Task.sleep(nanoseconds: taskDrainTimeoutNanoseconds)
                await state.resume(continuation)
            }
        }
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
            await Self.waitBrieflyForTask(committedTask)
            try Task.checkCancellation()
            await task()
        }
    }
    
    @MainActor
    func startOnNavigationFailed(task: @escaping () async -> Void) {
        let failedTask = onNavigationFailedTask
        failedTask?.cancel()
        onNavigationFailedTask = Task { @MainActor in
            await Self.waitBrieflyForTask(failedTask)
            try Task.checkCancellation()
            await task()
        }
    }
    
    @MainActor
    func startOnURLChanged(task: @escaping () async -> Void) {
        let previousURLChangedTask = onURLChangedTask
        previousURLChangedTask?.cancel()
        urlChangedGeneration += 1
        let generation = urlChangedGeneration
        let nextTask = Task { @MainActor in
            await Self.waitBrieflyForTask(previousURLChangedTask)
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
