import SwiftUI
import SwiftUtilities
import SwiftUIDownloads
import LakeImage
import Pow

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
            let wasAlreadyDownloaded = downloadable.existsLocally()
            if !wasAlreadyDownloaded {
                await downloadController.ensureDownloaded([downloadable])
            }
            onSelected?(wasAlreadyDownloaded)
        }
    }
    
    private func refreshDownloadable() async {
        if downloadable.existsLocally() && !wasDownloaded {
            try? await ReaderFileManager.shared.refreshAllFilesMetadata()
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

struct BookGridCell: View {
    let imageURL: URL?
    let title: String
    let author: String?
    let publicationDate: Date?
    let downloadURL: URL?
    var onSelected: ((Bool) -> Void)? = nil
    
    @State private var downloadable: Downloadable?
    //    @StateObject private var viewModel = ReaderContentCellViewModel<C>()
    
    init(imageURL: URL?, title: String, author: String?, publicationDate: Date?, downloadURL: URL?, onSelected: ((Bool) -> Void)? = nil) {
        self.imageURL = imageURL
        self.title = title
        self.author = author
        self.publicationDate = publicationDate
        self.downloadURL = downloadURL
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
        .task { @MainActor in
            await refreshDownloadable()
        }
    }
    
    private func refreshDownloadable() async {
        if let downloadURL = downloadURL {
            if downloadable?.url != downloadURL || downloadable?.name != title {
                downloadable = try? await ReaderFileManager.shared.downloadable(url: downloadURL, name: title)
            }
        }
    }
}
