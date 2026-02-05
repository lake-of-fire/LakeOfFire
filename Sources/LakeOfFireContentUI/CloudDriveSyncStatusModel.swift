import SwiftUI
import LakeOfFireContent

@MainActor
class CloudDriveSyncStatusModel: ObservableObject {
    @Published var status: CloudDriveSyncStatus = .loadingStatus
    private var refreshTask: Task<Void, Never>?

    @MainActor
    func refreshAsync(item: ContentFile) async {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.periodicStatusRefresh(item: item)
        }
        await refreshTask?.value
    }

    private func periodicStatusRefresh(item: ContentFile) async {
        while !Task.isCancelled {
            do {
                let newStatus = try await item.cloudDriveSyncStatus()
                await MainActor.run {
                    self.status = newStatus
                }

                if newStatus != .downloading && newStatus != .uploading {
                    break
                }

                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                await MainActor.run {
                    print(error)
                }
                break
            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }
}
