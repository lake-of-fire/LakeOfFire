import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import SwiftUtilities
import SwiftUIDownloads
import LakeImage
import Pow

// Dormant UI retained for local development; excluded from shipping builds.
#if DEBUG
fileprivate struct BookGridCellContent: View {
    let imageURL: URL?
    let title: String
    let author: String?
    let publicationDate: Date?
    var onSelected: ((Bool) -> Void)? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            if let imageURL = imageURL {
                Button {
                    buttonPress()
                } label: {
                    BookThumbnail(imageURL: imageURL)
                }
                .buttonStyle(BookButtonStyle())
                .padding(.bottom, 8)
            }
            
            Button {
                buttonPress()
            } label: {
                VStack(alignment: .leading) {
                    Text(title)
                        .font(.headline)
                    Text("\(author ?? "")\(author != nil && publicationDate != nil ? " • " : "")\(publicationDate != nil ? String(Calendar.current.component(.year, from: publicationDate!)) : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }
    
    private func buttonPress() {
        Task { @MainActor in
            onSelected?(true)
        }
    }
}

fileprivate struct DownloadableBookGridCell: View {
    let imageURL: URL?
    let title: String
    let author: String?
    let publicationDate: Date?
    var onSelected: ((Bool) -> Void)? = nil
    @ObservedObject var downloadable: Downloadable
    
    @State private var wasDownloaded = false
    
    @ObservedObject private var downloadController = DownloadController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            BookGridCellContent(imageURL: imageURL, title: title, author: author, publicationDate: publicationDate) { _ in
                buttonPress()
            }
            HidingDownloadButton(
                downloadable: downloadable,
                downloadText: "Get",
                downloadedText: "In Library") { _ in
                    buttonPress()
                }
                .font(.caption)
                .textCase(.uppercase)
                .foregroundStyle(.primary)
                .modifier {
                    if #available(macOS 13, iOS 16, *) {
                        $0
                            .fontWeight(.bold)
                    } else { $0 }
                }
                .padding(.bottom, 2)
            //                    .id("book-grid-cell-\(downloadable.id)-\(wasDownloaded)")
        }
        .task { @MainActor in
            await refreshDownloadable()
        }
        .onChange(of: downloadable.isFinishedDownloading) { isFinishedDownloading in
            Task { @MainActor in
                await refreshDownloadable()
            }
        }
    }
    
    private func buttonPress() {
        Task { @MainActor in
            let wasAlreadyDownloaded = await downloadable.existsLocally()
            if !wasAlreadyDownloaded {
                await downloadController.ensureDownloaded([downloadable])
            }
            _ = try? await ReaderFileManager.shared.ensureImported(downloadable: downloadable)
            onSelected?(wasAlreadyDownloaded)
        }
    }
    
    @MainActor
    private func refreshDownloadable() async {
        if await downloadable.existsLocally() && !wasDownloaded {
            _ = try? await ReaderFileManager.shared.ensureImported(downloadable: downloadable)
            wasDownloaded = true
        }
    }
}

fileprivate struct BookButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
        //            .padding(.vertical, 12)
        //            .padding(.horizontal, 64)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .conditionalEffect(
                .pushDown,
                condition: configuration.isPressed)
    }
}
#endif

struct BookDownloadIdentity: Hashable {
    let url: URL?
    let name: String
    let mediaType: String?
}

// Dormant UI retained for local development; excluded from shipping builds.
#if DEBUG
struct BookGridCell: View {
    let imageURL: URL?
    let title: String
    let author: String?
    let publicationDate: Date?
    let downloadURL: URL?
    let downloadMediaType: String?
    var onSelected: ((Bool) -> Void)? = nil
    
    @State private var downloadable: Downloadable?
    //    @StateObject private var viewModel = ReaderContentCellViewModel<C>()
    
    init(imageURL: URL?, title: String, author: String?, publicationDate: Date?, downloadURL: URL?, downloadMediaType: String? = nil, onSelected: ((Bool) -> Void)? = nil) {
        self.imageURL = imageURL
        self.title = title
        self.author = author
        self.publicationDate = publicationDate
        self.downloadURL = downloadURL
        self.downloadMediaType = downloadMediaType
        self.onSelected = onSelected
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let downloadable = downloadable {
                DownloadableBookGridCell(imageURL: imageURL, title: title, author: author, publicationDate: publicationDate, onSelected: onSelected, downloadable: downloadable)
            } else {
                BookGridCellContent(imageURL: imageURL, title: title, author: author, publicationDate: publicationDate, onSelected: onSelected)
            }
        }
        .task(id: BookDownloadIdentity(url: downloadURL, name: title, mediaType: downloadMediaType)) { @MainActor in
            await refreshDownloadable()
        }
    }
    
    private func refreshDownloadable() async {
        guard !Task.isCancelled else { return }
        guard let downloadURL else {
            downloadable = nil
            return
        }
        let resolved = try? await ReaderFileManager.shared.downloadable(url: downloadURL, name: title, mediaType: downloadMediaType)
        guard !Task.isCancelled else { return }
        downloadable = resolved
    }
}
#endif
