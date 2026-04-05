import SwiftUI
import Foundation
import RealmSwift
import RealmSwiftGaps
import LakeKit
import ImageIO

private let ebookAbsoluteDateFormatter: DateFormatter = {
    ReaderDateFormatter.makeAbsoluteFormatter(dateStyle: .medium)
}()

@globalActor
fileprivate actor ReaderContentCellActor {
    static var shared = ReaderContentCellActor()
}

@MainActor
class ReaderContentCellViewModel<C: ReaderContentProtocol & ObjectKeyIdentifiable>: ObservableObject {
    @Published var readingProgress: Float? = nil
    @Published var isFullArticleFinished: Bool? = nil
    @Published var forceShowBookmark = false
    @Published var title = ""
    @Published var author: String?
    @Published var humanReadablePublicationDate: String?
    @Published var imageURL: URL?
    @Published var sourceIconURL: URL?
    @Published var sourceTitle: String?

    init() { }

    @MainActor
    func load(item: C, includeSource: Bool) async throws {
        guard let config = item.realm?.configuration else { return }
        let pk = item.compoundKey
        let imageURL = try await item.imageURLToDisplay()
        try await { @ReaderContentCellActor [weak self] in
            guard let self else { return }
            let realm = try await Realm(configuration: config, actor: ReaderContentCellActor.shared)
            guard let item = realm.object(ofType: C.self, forPrimaryKey: pk) else { return }
            try Task.checkCancellation()

            let title = item.titleForDisplay
            let author = item.author.trimmingCharacters(in: .whitespacesAndNewlines)
            let shouldDisplayPublicationDate = item.displayPublicationDate || item.isPhysicalMedia
            let humanReadablePublicationDate = shouldDisplayPublicationDate ? item.humanReadablePublicationDate : nil
            let progressResult = try await ReaderContentReadingProgressLoader.readingProgressLoader?(item.url)

            var sourceIconURL: URL?
            var sourceTitle: String?
            if includeSource {
                if item.url.isSnippetURL {
                    sourceTitle = "Snippet"
                } else if let feedEntry = item as? FeedEntry, let feed = feedEntry.getFeed() {
                    sourceTitle = feed.title
                    sourceIconURL = feed.iconUrl ?? item.sourceIconURL
                } else if let host = item.url.host, !host.isEmpty {
                    sourceTitle = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                    sourceIconURL = item.sourceIconURL
                }
            }

            try await { @MainActor in
                try Task.checkCancellation()
                self.title = title
                self.author = author.isEmpty ? nil : author
                self.imageURL = imageURL
                self.humanReadablePublicationDate = humanReadablePublicationDate
                self.sourceIconURL = sourceIconURL
                self.sourceTitle = sourceTitle
                if let (progress, finished) = progressResult {
                    self.readingProgress = progress
                    self.isFullArticleFinished = finished
                } else {
                    self.readingProgress = nil
                    self.isFullArticleFinished = nil
                }
            }()
        }()
    }
}

public struct ReaderContentCellAppearance {
    public var maxCellHeight: CGFloat
    public var alwaysShowThumbnails: Bool
    public var isEbookStyle: Bool
    public var includeSource: Bool
    public var thumbnailDimension: CGFloat?
    public var thumbnailCornerRadius: CGFloat?

    public init(
        maxCellHeight: CGFloat,
        alwaysShowThumbnails: Bool = true,
        isEbookStyle: Bool = false,
        includeSource: Bool = false,
        thumbnailDimension: CGFloat? = nil,
        thumbnailCornerRadius: CGFloat? = nil
    ) {
        self.maxCellHeight = maxCellHeight
        self.alwaysShowThumbnails = alwaysShowThumbnails
        self.isEbookStyle = isEbookStyle
        self.includeSource = includeSource
        self.thumbnailDimension = thumbnailDimension
        self.thumbnailCornerRadius = thumbnailCornerRadius
    }
}

public enum ReaderContentCellStyle: Sendable {
    case card
    case plain
}

private struct ReaderContentCellStyleKey: EnvironmentKey {
    static let defaultValue: ReaderContentCellStyle = .plain
}

public extension EnvironmentValues {
    var readerContentCellStyle: ReaderContentCellStyle {
        get { self[ReaderContentCellStyleKey.self] }
        set { self[ReaderContentCellStyleKey.self] = newValue }
    }
}

public extension View {
    func readerContentCellStyle(_ style: ReaderContentCellStyle) -> some View {
        environment(\.readerContentCellStyle, style)
    }
}

extension ReaderContentProtocol {
    @ViewBuilder public func readerContentCellView(
        appearance: ReaderContentCellAppearance,
        customMenuOptions: ((Self) -> AnyView)?
    ) -> some View {
        ReaderContentCell(
            item: self,
            appearance: appearance,
            customMenuOptions: customMenuOptions
        )
    }

    @ViewBuilder public func readerContentCellView(
        appearance: ReaderContentCellAppearance
    ) -> some View {
        readerContentCellView(
            appearance: appearance,
            customMenuOptions: nil
        )
    }

    @ViewBuilder public func readerContentCellView(
        maxCellHeight: CGFloat,
        alwaysShowThumbnails: Bool = true,
        isEbookStyle: Bool = false,
        includeSource: Bool = false,
        thumbnailDimension: CGFloat? = nil,
        thumbnailCornerRadius: CGFloat? = nil
    ) -> some View {
        readerContentCellView(
            appearance: ReaderContentCellAppearance(
                maxCellHeight: maxCellHeight,
                alwaysShowThumbnails: alwaysShowThumbnails,
                isEbookStyle: isEbookStyle,
                includeSource: includeSource,
                thumbnailDimension: thumbnailDimension,
                thumbnailCornerRadius: thumbnailCornerRadius
            )
        )
    }
}

struct CloudDriveSyncStatusView: View {
    @ObservedRealmObject var item: ContentFile

    @EnvironmentObject var cloudDriveSyncStatusModel: CloudDriveSyncStatusModel

    private var title: String? {
        switch cloudDriveSyncStatusModel.status {
        case .fileMissing:
            return "File Missing"
        case .notInUbiquityContainer:
            return "Local File"
        case .downloading:
            return "Downloading from iCloud"
        case .uploading:
            return "Uploading to iCloud"
        case .synced:
            return "Synced with iCloud"
        case .notSynced:
            return "Not Synced with iCloud"
        case .loadingStatus:
            return nil
        }
    }

    private var systemImage: String? {
        switch cloudDriveSyncStatusModel.status {
        case .fileMissing:
            return "exclamationmark.icloud"
        case .notInUbiquityContainer:
            return "icloud.slash"
        case .downloading:
            return "icloud.and.arrow.down"
        case .uploading:
            return "icloud.and.arrow.up"
        case .synced:
            return "checkmark.icloud.fill"
        case .notSynced:
            return "xmark.icloud"
        case .loadingStatus:
            return nil
        }
    }

    var body: some View {
        if let title, let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text("").hidden()
        }
    }
}

public struct ReaderContentBookCoverRenderedWidthPreferenceKey: PreferenceKey {
    public static var defaultValue: CGFloat = 0

    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ReaderContentCell<C: ReaderContentProtocol & ObjectKeyIdentifiable>: View {
    @ObservedRealmObject var item: C
    var appearance: ReaderContentCellAppearance
    var customMenuOptions: ((C) -> AnyView)? = nil

    static var buttonSize: CGFloat { 26 }

    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel
    @Environment(\.readerContentCellStyle) private var readerContentCellStyle
    @Environment(\.stackListGroupBoxContentInsets) private var stackListGroupBoxContentInsets

    @ScaledMetric(relativeTo: .caption) private var sourceIconSize = 14
    @StateObject private var viewModel = ReaderContentCellViewModel<C>()

    init(item: C, appearance: ReaderContentCellAppearance, customMenuOptions: ((C) -> AnyView)? = nil) {
        self._item = ObservedRealmObject(wrappedValue: item)
        self.appearance = appearance
        self.customMenuOptions = customMenuOptions
    }

    init(
        item: C,
        maxCellHeight: CGFloat,
        alwaysShowThumbnails: Bool = true,
        isEbookStyle: Bool = false,
        includeSource: Bool = false,
        thumbnailDimension: CGFloat? = nil,
        thumbnailCornerRadius: CGFloat? = nil
    ) {
        self.init(
            item: item,
            appearance: ReaderContentCellAppearance(
                maxCellHeight: maxCellHeight,
                alwaysShowThumbnails: alwaysShowThumbnails,
                isEbookStyle: isEbookStyle,
                includeSource: includeSource,
                thumbnailDimension: thumbnailDimension,
                thumbnailCornerRadius: thumbnailCornerRadius
            )
        )
    }

    private var buttonSize: CGFloat { Self.buttonSize }

    private var thumbnailEdgeLength: CGFloat {
        max(1, appearance.thumbnailDimension ?? appearance.maxCellHeight)
    }

    private var displayImageURL: URL? {
        viewModel.imageURL ?? item.imageUrl
    }

    private var resolvedSourceIconURL: URL? {
        viewModel.sourceIconURL ?? item.sourceIconURL
    }

    private var usesSourceIconAsThumbnail: Bool {
        displayImageURL == nil && resolvedSourceIconURL != nil
    }

    private var inlineSourceIconURL: URL? {
        usesSourceIconAsThumbnail ? nil : resolvedSourceIconURL
    }

    private var displaySourceTitle: String? {
        if let title = viewModel.sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        guard appearance.includeSource else { return nil }
        if item.url.isSnippetURL {
            return "Snippet"
        }
        if let host = item.url.host, !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return nil
    }

    private var displayAuthor: String? {
        if let author = viewModel.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            return author
        }
        let fallback = item.author.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    private var comparisonTitles: [String] {
        [viewModel.title, item.titleForDisplay]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func isSameAsAnyTitle(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return comparisonTitles.contains(normalized)
    }

    private var bookAuthorText: String? {
        guard let author = displayAuthor, !isSameAsAnyTitle(author) else { return nil }
        return author
    }

    private var displayTitle: String {
        let title = viewModel.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        let fallback = item.titleForDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fallback.isEmpty {
            return fallback
        }
        return item.url.absoluteString
    }

    private var isProgressVisible: Bool {
        if let readingProgressFloat = viewModel.readingProgress, readingProgressFloat > 0 {
            return true
        }
        return false
    }

    private var publicationDateText: String? {
        if let formatted = viewModel.humanReadablePublicationDate, !formatted.isEmpty {
            return formatted
        }
        if appearance.isEbookStyle {
            if let fallback = item.humanReadablePublicationDate?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty {
                return fallback
            }
            if let date = item.publicationDate {
                return ReaderDateFormatter.absoluteString(from: date, dateFormatter: ebookAbsoluteDateFormatter)
            }
        }
        return nil
    }

    private var titleLineLimit: Int {
        appearance.maxCellHeight >= 110 ? 2 : 1
    }

    private var thumbnailCornerRadius: CGFloat {
        if let custom = appearance.thumbnailCornerRadius {
            return custom
        }

        let containerCornerRadius = stackListCornerRadius
        let insetOffset = min(stackListGroupBoxContentInsets.leading, stackListGroupBoxContentInsets.top)
        let baseCornerRadius = max(0, containerCornerRadius - insetOffset)
        let scale = min(thumbnailEdgeLength / max(appearance.maxCellHeight, 1), 1)
        let scaledCornerRadius = baseCornerRadius * scale
        let upperBound = min(containerCornerRadius, thumbnailEdgeLength / 2)

        return max(0, min(upperBound, scaledCornerRadius))
    }

    private var contentColumnHeight: CGFloat? {
        if appearance.thumbnailDimension != nil || displayImageURL != nil {
            return appearance.maxCellHeight
        }
        return nil
    }

    private enum ThumbnailChoice {
        case image(URL)
        case icon(URL)
        case initial(String)
    }

    private var fallbackInitial: String {
        guard let first = displayTitle.first else { return "#" }
        return String(first).uppercased()
    }

    private var thumbnailChoice: ThumbnailChoice? {
        if let imageURL = displayImageURL {
            return .image(imageURL)
        }
        if let iconURL = resolvedSourceIconURL {
            return .icon(iconURL)
        }
        return appearance.alwaysShowThumbnails ? .initial(fallbackInitial) : nil
    }

    private var hasVisibleThumbnail: Bool {
        thumbnailChoice != nil
    }

    private var usesPlainLayout: Bool {
        readerContentCellStyle == .plain
    }

    private var showsAudioBadge: Bool {
        !item.voiceAudioURLs.isEmpty
    }

    @ViewBuilder
    private var sourceOrAuthorRow: some View {
        if appearance.isEbookStyle, let author = bookAuthorText {
            Text(author)
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if appearance.includeSource, let sourceTitle = displaySourceTitle {
            HStack(spacing: 6) {
                if let sourceIconURL = inlineSourceIconURL {
                    ReaderContentSourceIconImage(sourceIconURL: sourceIconURL, iconSize: sourceIconSize)
                }
                Text(sourceTitle)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var topStatusRow: some View {
        HStack(spacing: 8) {
            if showsAudioBadge {
                Image(systemName: "headphones")
                    .imageScale(.small)
            }

            if appearance.isEbookStyle, !isProgressVisible {
                Text("NEW")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .textCase(.uppercase)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(
                            Color(
                                red: 0x1d / 255.0,
                                green: 0x46 / 255.0,
                                blue: 0x75 / 255.0
                            )
                        )
                    )
            }

            if let item = item as? ContentFile {
                CloudDriveSyncStatusView(item: item)
                    .labelStyle(.iconOnly)
                    .font(.callout)
                    .imageScale(.small)
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var metadataRow: some View {
        HStack(spacing: 6) {
            if let publicationDate = publicationDateText {
                Text(publicationDate)
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.9)
                    .font(.footnote)
                    .layoutPriority(2)
            }

            Spacer(minLength: 0)

            BookmarkButton(iconOnly: true, readerContent: item, hiddenIfUnbookmarked: true)
                .labelStyle(.iconOnly)
                .frame(width: viewModel.forceShowBookmark ? buttonSize : 0, height: buttonSize)
                .opacity(viewModel.forceShowBookmark ? 1 : 0)
                .accessibilityHidden(!viewModel.forceShowBookmark)

            controlsRow
        }
        .foregroundStyle(.secondary)
        .buttonStyle(.clearBordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var progressRow: some View {
        if let readingProgressFloat = viewModel.readingProgress, isProgressVisible {
            ProgressView(value: min(1, readingProgressFloat))
                .tint((viewModel.isFullArticleFinished ?? false) ? Color("Green") : .secondary)
        }
    }

    @ViewBuilder
    private var controlsRow: some View {
        if let item = item as? (any DeletableReaderContent) {
            Menu {
                    if let item = item as? ContentFile {
                        CloudDriveSyncStatusView(item: item)
                            .labelStyle(.titleAndIcon)
                        Divider()
                    }

                    AnyView(self.item.bookmarkButtonView(iconOnly: false))

                    if let customMenuOptions {
                        customMenuOptions(self.item)
                    }

                    Divider()

                    Button(role: .destructive) {
                        readerContentListModalsModel.confirmDeletionOf = [item]
                        readerContentListModalsModel.confirmDelete = true
                    } label: {
                        Label(item.deleteActionTitle, systemImage: "trash")
                    }
            } label: {
                Label("More Options", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .modifier {
                if #available(iOS 16, macOS 13, *) {
                    $0.menuStyle(.button)
                } else {
                    $0
                }
            }
            .menuIndicator(.hidden)
        } else if let customMenuOptions {
            Menu {
                AnyView(self.item.bookmarkButtonView(iconOnly: false))
                customMenuOptions(self.item)
            } label: {
                Label("More Options", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .modifier {
                if #available(iOS 16, macOS 13, *) {
                    $0.menuStyle(.button)
                } else {
                    $0
                }
            }
            .menuIndicator(.hidden)
        }
    }

    @ViewBuilder
    private func thumbnailView(for thumbnailChoice: ThumbnailChoice) -> some View {
        switch thumbnailChoice {
        case .image(let imageURL):
            if appearance.isEbookStyle {
                BookCoverImageView(imageURL: imageURL, dimension: thumbnailEdgeLength)
            } else {
                ReaderImage(
                    imageURL,
                    maxWidth: thumbnailEdgeLength,
                    minHeight: thumbnailEdgeLength,
                    maxHeight: thumbnailEdgeLength
                )
                .clipShape(RoundedRectangle(cornerRadius: thumbnailCornerRadius, style: .continuous))
            }
        case .icon(let sourceIconURL):
            ReaderContentThumbnailTile(
                content: .icon(sourceIconURL, placeholder: fallbackInitial),
                width: thumbnailEdgeLength,
                height: thumbnailEdgeLength,
                cornerRadius: thumbnailCornerRadius
            )
        case .initial(let letter):
            ReaderContentThumbnailTile(
                content: .initial(letter),
                width: thumbnailEdgeLength,
                height: thumbnailEdgeLength,
                cornerRadius: thumbnailCornerRadius
            )
        }
    }

    var body: some View {
        HStack(alignment: usesPlainLayout ? .center : .top, spacing: 12) {
            if let thumbnailChoice {
                thumbnailView(for: thumbnailChoice)
            }

            Group {
                if usesPlainLayout {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 6) {
                            sourceOrAuthorRow

                            VStack(alignment: .leading, spacing: 6) {
                                Text(displayTitle)
                                    .font(.headline)
                                    .lineLimit(titleLineLimit)
                                    .multilineTextAlignment(.leading)
                                    .environment(\._lineHeightMultiple, 0.875)
                                    .foregroundColor((viewModel.isFullArticleFinished ?? false) ? .secondary : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .layoutPriority(1)

                                topStatusRow
                            }
                        }

                        progressRow
                        metadataRow
                    }
                    .frame(maxWidth: .infinity, minHeight: contentColumnHeight, maxHeight: contentColumnHeight, alignment: .top)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 6) {
                            sourceOrAuthorRow
                            Text(displayTitle)
                                .font(.headline)
                                .lineLimit(titleLineLimit)
                                .multilineTextAlignment(.leading)
                                .environment(\._lineHeightMultiple, 0.875)
                                .foregroundColor((viewModel.isFullArticleFinished ?? false) ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .layoutPriority(1)

                            topStatusRow
                        }

                        Spacer(minLength: 4)

                        VStack(alignment: .leading, spacing: 0) {
                            progressRow
                            metadataRow
                        }
                        .offset(y: 2)
                    }
                    .frame(height: contentColumnHeight, alignment: .top)
                }
            }
        }
        .frame(
            minWidth: appearance.maxCellHeight,
            minHeight: readerContentCellStyle == .card ? appearance.maxCellHeight : nil,
            idealHeight: hasVisibleThumbnail ? appearance.maxCellHeight : nil,
            maxHeight: readerContentCellStyle == .card ? appearance.maxCellHeight : nil
        )
        .onHover { hovered in
            viewModel.forceShowBookmark = hovered
        }
        .onAppear {
            Task { @MainActor in
                try? await viewModel.load(item: item, includeSource: appearance.includeSource)
            }
        }
        .onChange(of: item.imageUrl) { newImageURL in
            guard newImageURL != viewModel.imageURL else { return }
            Task { @MainActor in
                viewModel.imageURL = try await item.imageURLToDisplay()
            }
        }
    }
}

private struct ReaderContentThumbnailTile: View {
    enum Content {
        case icon(URL, placeholder: String)
        case initial(String)
    }

    let content: Content
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.secondary.opacity(0.18), Color.secondary.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if case let .icon(iconURL, _) = content {
                ReaderContentSourceIconImage(sourceIconURL: iconURL, iconSize: min(width, height) * 0.52)
            }

            if let placeholderLetter {
                Text(placeholderLetter)
                    .font(.system(size: min(width, height) * 0.42, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.4)
                    .foregroundStyle(Color.secondary.opacity(0.9))
            }
        }
        .frame(width: width, height: height)
    }

    private var placeholderLetter: String? {
        switch content {
        case .icon(_, let placeholder):
            return placeholder.isEmpty ? nil : placeholder
        case .initial(let letter):
            return letter.isEmpty ? nil : letter
        }
    }
}

public struct BookCoverImageView: View {
    public let imageURL: URL
    public let dimension: CGFloat

    @State private var renderedCoverWidth: CGFloat = 0

    public init(imageURL: URL, dimension: CGFloat) {
        self.imageURL = imageURL
        self.dimension = dimension
    }

    public var body: some View {
        Color.clear
            .frame(width: dimension, height: dimension)
            .overlay {
                ReaderImage(
                    imageURL,
                    contentMode: .fit,
                    cornerRadius: max(4, dimension / 28)
                )
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: dimension, maxHeight: dimension, alignment: .center)
            }
            .preference(key: ReaderContentBookCoverRenderedWidthPreferenceKey.self, value: renderedCoverWidth)
            .task(id: "\(imageURL.absoluteString)|\(dimension)") {
                let width = await resolveRenderedCoverWidth(imageURL: imageURL, dimension: dimension)
                if abs(width - renderedCoverWidth) >= 0.5 {
                    renderedCoverWidth = width
                }
            }
    }

    private func resolveRenderedCoverWidth(imageURL: URL, dimension: CGFloat) async -> CGFloat {
        guard dimension > 0 else { return 0 }
        guard let pixelSize = await imagePixelSize(for: imageURL), pixelSize.height > 0 else {
            return 0
        }
        let aspectRatio = pixelSize.width / pixelSize.height
        guard aspectRatio.isFinite, aspectRatio > 0 else { return 0 }
        return min(dimension, dimension * aspectRatio)
    }

    private func imagePixelSize(for url: URL) async -> CGSize? {
        await Task.detached(priority: .utility) {
            if url.isFileURL,
               let data = try? Data(contentsOf: url) {
                return imagePixelSize(from: data)
            }
            return nil
        }.value
    }

    private func imagePixelSize(from data: Data) -> CGSize? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        return CGSize(width: CGFloat(width.doubleValue), height: CGFloat(height.doubleValue))
    }
}
