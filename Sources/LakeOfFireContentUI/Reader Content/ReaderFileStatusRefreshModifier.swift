import Foundation
import SwiftUI
import LakeOfFireContent

@MainActor
struct ReaderFileStatusRefreshModifier: ViewModifier {
    let item: ContentFile?
    @ObservedObject var statusModel: CloudDriveSyncStatusModel
    var statusLoader: CloudDriveSyncStatusModel.StatusLoader? = nil
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    @State private var refreshRevision = UUID()

    private struct RefreshKey: Hashable {
        let itemID: String?
        let url: URL?
        let revision: UUID
    }

    func body(content: Content) -> some View {
        content
            .task(
                id: RefreshKey(
                    itemID: item?.compoundKey,
                    url: item?.url,
                    revision: refreshRevision
                )
            ) { @MainActor in
                guard let item else { return }
                let statusLoader = statusLoader ?? { item in
                    try await readerFileManager.cloudDriveSyncStatus(readerFileURL: item.url)
                }
                await statusModel.refreshAsync(item: item, statusLoader: statusLoader)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: ReaderFileManager.readerBackingStatusRefreshRequestedNotification
                )
            ) { notification in
                guard let item,
                      let requestedURLString = notification.object as? String,
                      let readerBackingURL = readerFileManager.canonicalReaderBackingURL(for: item.url),
                      readerBackingURL.absoluteString == requestedURLString else {
                    return
                }
                refreshRevision = UUID()
            }
    }
}
