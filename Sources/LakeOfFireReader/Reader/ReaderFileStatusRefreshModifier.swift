import Foundation
import SwiftUI
import LakeOfFireContent

/// Shared by the actual list row and its hosted SwiftUI lifecycle regression.
@MainActor
struct ReaderFileStatusRefreshModifier: ViewModifier {
    let item: ContentFile?
    @ObservedObject var statusModel: CloudDriveSyncStatusModel
    @State private var refreshRevision = UUID()

    private struct RefreshKey: Hashable {
        let itemID: String?
        let url: URL?
        let revision: UUID
    }

    func body(content: Content) -> some View {
        content
            .task { @MainActor in
                guard let item else { return }
                await statusModel.refreshAsync(item: item)
            }
            .onReceive(NotificationCenter.default.publisher(for: ReaderFileManager.readerBackingStatusRefreshRequestedNotification)) { notification in
                guard let item,
                      let requestedURL = notification.object as? String,
                      let backingURL = ReaderFileManager.shared.canonicalReaderBackingURL(for: item.url),
                      backingURL.absoluteString == requestedURL else { return }
                Task { @MainActor in
                    await statusModel.refreshAsync(item: item)
                }
            }
    }
}
