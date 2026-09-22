import SwiftUI
import SwiftUtilities
import SwiftUIDownloads
import LakeImage
import LakeKit
import Pow
import SwiftUIWebView
import ExpandableText
import LakeOfFireContent
import LakeOfFireContentUI

struct BookThumbnail: View {
    let imageURL: URL
    var limitWidth: Bool = true

    @ScaledMetric(relativeTo: .headline) var scaledImageWidth: CGFloat = 100
    @ScaledMetric(relativeTo: .headline) var cellHeight: CGFloat = 140

    var body: some View {
        let resolvedMaxWidth = limitWidth ? scaledImageWidth : nil
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ReaderImage(
                imageURL,
                contentMode: .fit,
                thumbnailSize: resolvedMaxWidth.map {
                    CGSize(width: $0, height: cellHeight)
                },
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
                        downloadURL: isDownloadable ? publication.downloadURL : nil
                    ) { wasAlreadyDownloaded in
                        onSelected?(publication, wasAlreadyDownloaded)
                    }
                }
            }
            .modifier {
                if #available(macOS 14, iOS 17, *) {
                    $0.scrollTargetLayout()
                } else {
                    $0
                }
            }
        }
        .modifier {
            if #available(macOS 14, iOS 17, *) {
                $0.scrollTargetBehavior(.viewAligned)
            } else {
                $0
            }
        }
    }
}

struct BookListRow: View {
    let publication: Publication
    let commandOwner: BookLibraryViewModel
    let suppliedReaderFileManager: ReaderFileManager
    let readerPageURL: URL
    let navigator: WebViewNavigator
    let readerModeViewModel: ReaderModeViewModel

    @State private var downloadable: Downloadable?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let downloadable {
                DownloadableBookListRow(
                    publication: publication,
                    commandOwner: commandOwner,
                    suppliedReaderFileManager: suppliedReaderFileManager,
                    readerPageURL: readerPageURL,
                    navigator: navigator,
                    readerModeViewModel: readerModeViewModel,
                    downloadable: downloadable
                )
            } else if publication.downloadURL != nil {
                UnavailableDownloadableBookListRow(
                    publication: publication,
                    commandOwner: commandOwner,
                    suppliedReaderFileManager: suppliedReaderFileManager,
                    readerPageURL: readerPageURL,
                    navigator: navigator,
                    readerModeViewModel: readerModeViewModel
                )
            } else {
                StaticBookListRow(publication: publication)
            }
            if let message = commandOwner.catalogBookErrorMessage(for: publication) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("BookLibrary.CommandError.\(publication.title)")
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
            downloadable = try? await suppliedReaderFileManager.downloadable(
                url: downloadURL,
                name: publication.title
            )
        }
    }
}

fileprivate struct UnavailableDownloadableBookListRow: View {
    let publication: Publication
    let commandOwner: BookLibraryViewModel
    let suppliedReaderFileManager: ReaderFileManager
    let readerPageURL: URL
    let navigator: WebViewNavigator
    let readerModeViewModel: ReaderModeViewModel

    var body: some View {
        BookListRowContent(
            imageURL: publication.coverURL,
            title: publication.title,
            author: publication.author,
            publicationDate: publication.publicationDate,
            summary: publication.summary,
            hasContentAudio: publication.hasContentAudio,
            onTopTap: startCommand
        ) {
            if commandOwner.isCatalogBookCommandActive(publication) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Button("Cancel") {
                        commandOwner.cancelCatalogBookCommand(for: publication)
                    }
                }
            } else {
                Button {
                    startCommand()
                } label: {
                    Text("Get")
                }
                .accessibilityIdentifier("BookLibrary.Download.\(publication.title)")
                .buttonStyle(.bordered)
                .font(.caption)
                .textCase(.uppercase)
                .foregroundStyle(.primary)
            }
        }
        .contentShape(Rectangle())
    }

    private func startCommand() {
        guard !commandOwner.isCatalogBookCommandActive(publication) else { return }
        commandOwner.startManualCatalogBookCommand(
            publication: publication,
            readerFileManager: suppliedReaderFileManager,
            readerPageURL: readerPageURL,
            navigator: navigator,
            readerModeViewModel: readerModeViewModel
        )
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
            hasContentAudio: publication.hasContentAudio,
            onTopTap: nil
        ) {
            EmptyView()
        }
        .contentShape(Rectangle())
    }
}

fileprivate struct DownloadableBookListRow: View {
    let publication: Publication
    let commandOwner: BookLibraryViewModel
    let suppliedReaderFileManager: ReaderFileManager
    let readerPageURL: URL
    let navigator: WebViewNavigator
    let readerModeViewModel: ReaderModeViewModel
    @ObservedObject var downloadable: Downloadable

    var body: some View {
        BookListRowContent(
            imageURL: publication.coverURL,
            title: publication.title,
            author: publication.author,
            publicationDate: publication.publicationDate,
            summary: publication.summary,
            hasContentAudio: publication.hasContentAudio,
            onTopTap: topTap
        ) {
            if commandOwner.isCatalogBookCommandActive(publication) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Button("Cancel") {
                        commandOwner.cancelCatalogBookCommand(for: publication)
                    }
                }
            } else {
                Button {
                    buttonPress()
                } label: {
                    Text(commandOwner.isCatalogBookImported(publication) ? "In Library" : "Get")
                }
                .accessibilityIdentifier("BookLibrary.Download.\(publication.title)")
                .buttonStyle(.bordered)
                .font(.caption)
                .textCase(.uppercase)
                .foregroundStyle(.primary)
                .modifier {
                    if #available(macOS 13, iOS 16, *) {
                        $0.fontWeight(.bold)
                    } else {
                        $0
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .task(id: ObjectIdentifier(suppliedReaderFileManager)) { @MainActor in
            commandOwner.reconcileDownloadedPublication(
                publication,
                readerFileManager: suppliedReaderFileManager
            )
        }
        .onChange(of: downloadable.isFinishedDownloading) { isFinishedDownloading in
            guard isFinishedDownloading, !downloadable.isFailed else { return }
            commandOwner.reconcileDownloadedPublication(
                publication,
                readerFileManager: suppliedReaderFileManager
            )
        }
    }

    private func buttonPress() {
        guard !commandOwner.isCatalogBookCommandActive(publication) else { return }
        commandOwner.startManualCatalogBookCommand(
            publication: publication,
            readerFileManager: suppliedReaderFileManager,
            readerPageURL: readerPageURL,
            navigator: navigator,
            readerModeViewModel: readerModeViewModel
        )
    }

    private func topTap() {
        buttonPress()
    }
}

fileprivate struct BookListRowContent<Trailing: View>: View {
    let imageURL: URL?
    let title: String
    let author: String?
    let publicationDate: Date?
    let summary: String?
    let hasContentAudio: Bool
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
        hasContentAudio: Bool = false,
        onTopTap: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.imageURL = imageURL
        self.title = title
        self.author = author
        self.publicationDate = publicationDate
        self.summary = summary
        self.hasContentAudio = hasContentAudio
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
            BookListRowThumbnail(imageURL: imageURL, dimension: thumbnailDimension)
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
                if hasContentAudio {
                    HStack(spacing: 6) {
                        Image(systemName: "headphones")
                            .imageScale(.small)
                        Text("Audiobook with Text")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.secondary)
                }
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
            .accessibilityIdentifier("BookLibrary.Row.\(title)")
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

    private var publicationYearText: String? {
        guard let publicationDate else { return nil }
        let components = Calendar.current.dateComponents([.year], from: publicationDate)
        guard let year = components.year else { return nil }
        return String(year)
    }
}

fileprivate struct BookListRowThumbnail: View {
    let imageURL: URL?
    let dimension: CGFloat

    private var coverCornerRadius: CGFloat { max(1, dimension / 28) }

    var body: some View {
        Group {
            if let imageURL {
                BookCoverImageView(imageURL: imageURL, dimension: dimension)
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
