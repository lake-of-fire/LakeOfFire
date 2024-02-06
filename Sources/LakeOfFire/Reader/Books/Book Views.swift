import SwiftUI
import SwiftUtilities
import SwiftUIDownloads
import LakeImage
import Pow

struct BookThumbnail: View { //, Equatable {
    let imageURL: URL
    
    @ScaledMetric(relativeTo: .headline) private var scaledImageWidth: CGFloat = 100
    @ScaledMetric(relativeTo: .headline) private var cellHeight: CGFloat = 140
    
    //    @StateObject private var viewModel = ReaderContentCellViewModel<C>()
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
//            LakeImage(imageURL, contentMode: .fit, maxWidth: scaledImageWidth, maxHeight: cellHeight)
            LakeImage(imageURL, contentMode: .fit, maxWidth: scaledImageWidth, maxHeight: cellHeight, cornerRadius: scaledImageWidth / 28)
            //                        .frame(maxWidth: scaledImageWidth)
        }
//        .frame(idealHeight: cellHeight)
//                .frame(maxWidth: scaledImageWidth, maxHeight: cellHeight)
    }
}

struct BookGridCell: View {
    let imageURL: URL?
    let title: String
    let author: String?
    let publicationDate: Date?
    let downloadURL: URL?
    var onSelected: ((Bool) -> Void)? = nil
    
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    @ObservedObject private var downloadController = DownloadController.shared
    
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
        VStack(alignment: .leading) {
            if let imageURL = imageURL {
                Button {
                    buttonPress()
                } label: {
                    BookThumbnail(imageURL: imageURL)
                }
                .buttonStyle(BookButtonStyle())
                
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
                
                if let downloadable = downloadable {
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
                        if #available(macOS 13, iOS 15, *) {
                            $0
                                .fontWeight(.bold)
                        } else { $0 }
                    }
                }
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .task { @MainActor in
            await refreshDownloadable()
        }
    }
    
    private func refreshDownloadable() async {
        if let downloadURL = downloadURL {
            downloadable = try? await readerFileManager.downloadable(url: downloadURL, name: title)
        }
    }
    
    private func buttonPress() {
        Task { @MainActor in
            var wasAlreadyDownloaded = false
            if let downloadable = downloadable {
                wasAlreadyDownloaded = downloadable.existsLocally()
                if !wasAlreadyDownloaded {
                    await downloadController.ensureDownloaded([downloadable])
                }
            }
            onSelected?(wasAlreadyDownloaded)
            await refreshDownloadable()
        }
    }
}

struct HorizontalBooks: View {
    let publications: [Publication]
    let isDownloadable: Bool
    var onSelected: ((Publication, Bool) -> Void)? = nil
 
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack {
                ForEach(publications) { publication in
                    BookGridCell(
                        imageURL: publication.coverURL,
                        title: publication.title,
                        author: publication.author,
                        publicationDate: publication.publicationDate,
                        downloadURL: isDownloadable ? publication.downloadURL : nil) { wasAlreadyDownloaded in
                            onSelected?(publication, wasAlreadyDownloaded)
                        }
                }
            }
            .modifier {
                if #available(macOS 14, iOS 17, *) {
                    $0
                        .scrollTargetLayout()
                } else { $0 }
            }
        }
        .modifier {
            if #available(macOS 14, iOS 17, *) {
                $0
                    .scrollTargetBehavior(.viewAligned)
            } else { $0 }
        }
    }
}

fileprivate struct BookButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
//            .padding(.vertical, 12)
//            .padding(.horizontal, 64)
            .brightness(configuration.isPressed ? -0.1 : 0)
            .conditionalEffect(
                .pushDown,
                condition: configuration.isPressed)
    }
}
