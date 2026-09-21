import SwiftUI
import LakeOfFireContent

@MainActor
class CloudDriveSyncStatusModel: ObservableObject {
    @Published var status: CloudDriveSyncStatus = .loadingStatus
    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?

    typealias StatusLoader = @MainActor (ContentFile) async throws -> CloudDriveSyncStatus
    private let statusLoader: StatusLoader
    private let pollingDelay: @Sendable () async throws -> Void

    init() {
        statusLoader = { try await $0.cloudDriveSyncStatus() }
        pollingDelay = { try await Task.sleep(nanoseconds: 2_000_000_000) }
    }

    init(
        statusLoader: @escaping StatusLoader,
        pollingDelay: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    ) {
        self.statusLoader = statusLoader
        self.pollingDelay = pollingDelay
    }

    @MainActor
    func refreshAsync(
        item: ContentFile,
        statusLoader: StatusLoader? = nil
    ) async {
        guard !Task.isCancelled else { return }

        refreshTask?.cancel()
        let identifier = UUID()
        refreshID = identifier
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await periodicStatusRefresh(
                item: item,
                identifier: identifier,
                statusLoader: statusLoader ?? self.statusLoader
            )
        }
        refreshTask = task

        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        if refreshID == identifier {
            refreshTask = nil
            refreshID = nil
        }
    }

    private func periodicStatusRefresh(
        item: ContentFile,
        identifier: UUID,
        statusLoader: @escaping StatusLoader
    ) async {
        while !Task.isCancelled, refreshID == identifier {
            do {
                let newStatus = try await statusLoader(item)
                try Task.checkCancellation()
                guard refreshID == identifier else { return }
                status = newStatus

                if newStatus != .downloading && newStatus != .uploading {
                    break
                }

                try await pollingDelay()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, refreshID == identifier else { return }
                print(error)
                return
            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }
}
