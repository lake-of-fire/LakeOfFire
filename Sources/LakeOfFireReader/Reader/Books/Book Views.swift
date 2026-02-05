import SwiftUI
import SwiftUtilities
import SwiftUIDownloads
import LakeImage
import LakeKit
import Pow
import ExpandableText
import SwiftUIWebView
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent
import LakeOfFireContentUI

struct BookThumbnail: View { //, Equatable {
    let imageURL: URL
    var limitWidth: Bool = true
    
    @ScaledMetric(relativeTo: .headline) var scaledImageWidth: CGFloat = 100
    @ScaledMetric(relativeTo: .headline) var cellHeight: CGFloat = 140
    
    //    @StateObject private var viewModel = ReaderContentCellViewModel<C>()
    
    var body: some View {
        let resolvedMaxWidth = limitWidth ? scaledImageWidth : nil
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ReaderImage(
                imageURL,
                contentMode: .fit,
                maxWidth: resolvedMaxWidth,
                maxHeight: cellHeight,
                cornerRadius: scaledImageWidth / 28
            )
        }
    }
}

struct HorizontalBooks: View {
    let publications: [Publication]
    let isDownloadable: Bool
    var onSelected: ((Publication, Bool) -> Void)? = nil
 
    var body: some View {
        ScrollView(.horizontal) {
            HStack {
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

struct BookListRow: View {
    let publication: Publication
    var onSelected: ((Bool) -> Void)? = nil
    var onNavigateToReader: (() -> Void)? = nil
    @State private var downloadable: Downloadable?
    
    var body: some View {
        Group {
            if let downloadable {
                DownloadableBookListRow(
                    publication: publication,
                    onSelected: onSelected,
                    onNavigateToReader: onNavigateToReader,
                    downloadable: downloadable
                )
            } else {
                StaticBookListRow(publication: publication)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .listRowInsets(.init())
        .listRowBackground(Color.clear)
        .listRowSeparatorIfAvailable(.hidden)
        .task { @MainActor in
            await refreshDownloadable()
        }
    }
    
    private func refreshDownloadable() async {
        guard let downloadURL = publication.downloadURL else {
            downloadable = nil
            return
        }
        if downloadable?.url != downloadURL || downloadable?.name != publication.title {
            downloadable = try? await ReaderFileManager.shared.downloadable(url: downloadURL, name: publication.title)
        }
    }
}

fileprivate struct StaticBookListRow: View {
    let publication: Publication
    
    var body: some View {
        BookListRowContent(
            imageURL: publication.coverURL,
            title: publication.title,
            author: publication.author,
            publicationDate: publication.publicationDate,
            summary: publication.summary,
            hasAudio: publication.voiceAudioURL != nil || publication.audioSubtitlesURL != nil,
            onTopTap: nil
        ) {
            EmptyView()
        }
        .contentShape(Rectangle())
    }
}

fileprivate struct DownloadableBookListRow: View {
    let publication: Publication
    let onSelected: ((Bool) -> Void)?
    let onNavigateToReader: (() -> Void)?
    @ObservedObject var downloadable: Downloadable
    @State private var wasDownloaded = false
    @ObservedObject private var downloadController = DownloadController.shared
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel
    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    
    var body: some View {
        BookListRowContent(
            imageURL: publication.coverURL,
            title: publication.title,
            author: publication.author,
            publicationDate: publication.publicationDate,
            summary: publication.summary,
            hasAudio: publication.voiceAudioURL != nil || publication.audioSubtitlesURL != nil,
            onTopTap: topTap
        ) {
            HidingDownloadButton(
                downloadable: downloadable,
                downloadText: "Get",
                downloadedText: "In Library"
            ) { _ in
                buttonPress()
            }
            .font(.caption)
            .textCase(.uppercase)
            .foregroundStyle(.primary)
            .modifier {
                if #available(macOS 13, iOS 16, *) {
                    $0.fontWeight(.bold)
                } else { $0 }
            }
        }
        .contentShape(Rectangle())
        .task { @MainActor in
            await refreshDownloadable()
        }
        .onChange(of: downloadable.isFinishedDownloading) { _ in
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
                await BookLibraryViewModel.updateMediaLinks(for: [publication])
            }
            onSelected?(wasAlreadyDownloaded)
        }
    }
    
    @MainActor
    private func refreshDownloadable() async {
        if await downloadable.existsLocally() && !wasDownloaded {
            try? await ReaderFileManager.shared.refreshAllFilesMetadata()
            wasDownloaded = true
        }
    }

    private func topTap() {
        Task { @MainActor in
            let alreadyDownloaded = await downloadable.existsLocally()
            if alreadyDownloaded {
                do {
                    try await BookLibraryViewModel.openDownloaded(
                        publication: publication,
                        readerFileManager: ReaderFileManager.shared,
                        readerContent: readerContent,
                        navigator: navigator,
                        readerModeViewModel: readerModeViewModel,
                        onNavigateToReader: onNavigateToReader
                    )
                } catch {
                    print("Failed to open downloaded book: \\(error)")
                }
            } else {
                buttonPress()
            }
        }
    }
}

fileprivate struct BookListRowContent<Trailing: View>: View {
    let imageURL: URL?
    let title: String
    let author: String?
    let publicationDate: Date?
    let summary: String?
    let hasAudio: Bool
    let onTopTap: (() -> Void)?
    private let trailing: () -> Trailing

    @ScaledMetric(relativeTo: .title3) private var thumbnailWidth: CGFloat = 68
    private var thumbnailDimension: CGFloat { thumbnailWidth * 1.45 * (2.0 / 3.0) }
    private let cornerRadius: CGFloat = 18
    private var resolvedSummary: String? {
        let trimmed = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
    
    init(
        imageURL: URL?,
        title: String,
        author: String?,
        publicationDate: Date?,
        summary: String?,
        hasAudio: Bool = false,
        onTopTap: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.imageURL = imageURL
        self.title = title
        self.author = author
        self.publicationDate = publicationDate
        self.summary = summary
        self.hasAudio = hasAudio
        self.onTopTap = onTopTap
        self.trailing = trailing
    }
    
    var body: some View {
        VStack(spacing: 0) {
            topHalf
            Divider()
                .padding(.horizontal, 14)
            summaryView
                .contentShape(Rectangle())
                .allowsHitTesting(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .modifier {
                    if #available(iOS 15, macOS 14, *) {
                        $0.fill(Color(.tertiarySystemFill))
                    } else {
                        $0.fill(Color(.lightGray))
                    }
                }
        )
    }

    @ViewBuilder
    private var topHalf: some View {
        let content = HStack(alignment: .center, spacing: 12) {
            BookListRowThumbnail(
                imageURL: imageURL,
                dimension: thumbnailDimension
            )
            VStack(alignment: .leading, spacing: 6) {
                if let author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                // Temporarily hide audiobook badge pending UX update.
//                if hasAudio {
//                    HStack(spacing: 6) {
//                        Image(systemName: "headphones")
//                            .imageScale(.small)
//                        Text("Audiobook with Text")
//                            .font(.caption)
//                            .fontWeight(.semibold)
//                    }
//                    .foregroundStyle(.secondary)
//                }
                if let publicationYearText {
                    Text(publicationYearText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())

        if let onTopTap {
            Button(action: onTopTap) {
                content
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
    }
    
    private var summaryView: some View {
        Group {
            if let resolvedSummary {
                ExpandableText(LocalizedStringKey(resolvedSummary))
                    .lineLimit(3)
                    .foregroundColor(.secondary)
                    .moreButtonText("MORE")
                    .moreButtonFont(.footnote)
                    .moreButtonForegroundStyle(.primary)
                    .expandAnimation(.easeIn)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
    }
    private var trailingAsButton: (() -> Void)? {
        nil // Trailing view is rendered; tap is handled by the surrounding Button to keep top-half tappable.
    }
    
private var publicationYearText: String? {
        guard let publicationDate else { return nil }
        let components = Calendar.current.dateComponents([.year], from: publicationDate)
        guard let year = components.year else { return nil }
        return String(year)
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

fileprivate struct BookListRowThumbnail: View {
    let imageURL: URL?
    let dimension: CGFloat
    private var coverCornerRadius: CGFloat { max(1, dimension / 28) }
    
    var body: some View {
        Group {
            if let imageURL {
                BookCoverImageView(
                    imageURL: imageURL,
                    dimension: dimension
                )
            } else {
                RoundedRectangle(cornerRadius: coverCornerRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay {
                        Image(systemName: "book.closed")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
            }
        }
        .frame(width: dimension, height: dimension)
    }
}
