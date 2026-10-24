import Foundation
import SwiftUI
import LakeOfFireContent

@MainActor
class CloudDriveSyncStatusModel: ObservableObject {
    typealias StatusReader = @MainActor @Sendable (URL) async throws -> CloudDriveSyncStatus
    typealias RefreshDelay = @Sendable () async throws -> Void

    @Published var status: CloudDriveSyncStatus = .loadingStatus
    private var refreshTask: Task<Void, Never>?
    private var activeRefreshID: UUID?
    private let readStatus: StatusReader
    private let waitBeforeRefresh: RefreshDelay

    init(
        readStatus: @escaping StatusReader = { readerFileURL in
            try await ReaderFileManager.shared.cloudDriveSyncStatus(readerFileURL: readerFileURL)
        },
        waitBeforeRefresh: @escaping RefreshDelay = {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    ) {
        self.readStatus = readStatus
        self.waitBeforeRefresh = waitBeforeRefresh
    }

    @MainActor
    func refreshAsync(item: ContentFile) async {
        guard let task = requestRefresh(item: item) else { return }
        // Capture this task, not the mutable property: late cancellation of an
        // older row task must not cancel a replacement refresh.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Notifications have no view-owned async task to join. Starting the same
    /// owned refresh synchronously avoids retaining this model in an abandoned
    /// notification waiter; deinit can cancel its weakly owned polling task.
    @discardableResult
    func requestRefresh(
        item: ContentFile,
        matchingBackingURLString: String? = nil
    ) -> Task<Void, Never>? {
        guard !Task.isCancelled, !item.isInvalidated else { return nil }
        let contentURL = item.url
        if let matchingBackingURLString {
            guard let readerBackingURL = ReaderFileManager.shared.canonicalReaderBackingURL(for: contentURL),
                  readerBackingURL.absoluteString == matchingBackingURLString else { return nil }
        }
        let contentKey = item.compoundKey
        let createdAt = item.createdAt
        let refreshID = UUID()
        let readStatus = readStatus
        let waitBeforeRefresh = waitBeforeRefresh

        refreshTask?.cancel()
        activeRefreshID = refreshID
        let task = Task { @MainActor [weak self] in
            defer { self?.finishRefresh(refreshID) }
            while self?.admitsRefresh(
                refreshID, item: item, key: contentKey,
                url: contentURL, createdAt: createdAt
            ) == true {
                do {
                    let newStatus = try await readStatus(contentURL)
                    guard self?.admitsRefresh(
                        refreshID, item: item, key: contentKey,
                        url: contentURL, createdAt: createdAt
                    ) == true else { return }
                    self?.status = newStatus

                    if newStatus != .downloading && newStatus != .uploading {
                        return
                    }

                    try await waitBeforeRefresh()
                } catch {
                    guard self?.admitsRefresh(
                        refreshID, item: item, key: contentKey,
                        url: contentURL, createdAt: createdAt
                    ) == true else { return }
                    print(error)
                    return
                }
            }
        }
        refreshTask = task
        return task
    }

    private func finishRefresh(_ refreshID: UUID) {
        if activeRefreshID == refreshID {
            refreshTask = nil
            activeRefreshID = nil
        }
    }

    private func admitsRefresh(
        _ refreshID: UUID,
        item: ContentFile,
        key: String,
        url: URL,
        createdAt: Date
    ) -> Bool {
        activeRefreshID == refreshID && !Task.isCancelled
            && !item.isInvalidated && item.compoundKey == key
            && item.url == url && item.createdAt == createdAt
    }

    deinit {
        refreshTask?.cancel()
    }
}
