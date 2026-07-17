import LakeOfFireWeb
import LakeOfFireFiles
import SwiftUI
import LakeOfFireContent
import LakeOfFireCore
import Foundation
import RealmSwift
import RealmSwiftGaps
import LakeKit
import ImageIO

struct ReaderNewBadge: View {
    @Environment(\.controlSize) private var controlSize
    @ScaledMetric(relativeTo: .caption2) private var compactFontSize: CGFloat = 10

    public var body: some View {
        Text("NEW")
            .font(isCompactControlSize ? .system(size: compactFontSize, weight: .semibold) : .caption2)
            .fontWeight(.semibold)
            .textCase(.uppercase)
            .foregroundStyle(.white)
            .padding(.horizontal, isCompactControlSize ? 5 : 6)
            .padding(.vertical, isCompactControlSize ? 2 : 3)
            .modifier {
                if #available(iOS 16, macOS 14, *) {
                    $0.baselineOffset(-0.5)
                } else { $0 }
            }
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

    private var isCompactControlSize: Bool {
        switch controlSize {
        case .mini, .small:
            return true
        default:
            return false
        }
    }
}

private let ebookAbsoluteDateFormatter: DateFormatter = {
    ReaderDateFormatter.makeAbsoluteFormatter(dateStyle: .medium)
}()

@globalActor
fileprivate actor ReaderContentCellActor {
    static var shared = ReaderContentCellActor()
}

fileprivate struct ReaderContentCellDisplayState: Equatable {
    var readingProgress: Float?
    var isFullArticleFinished: Bool?
    var latestHistoryRecordLastVisitedAt: Date?
    var title = ""
    var author: String?
    var humanReadablePublicationDate: String?
    var imageURL: URL?
    var sourceIconURL: URL?
    var sourceTitle: String?
    var totalWordCount: Int?
    var remainingTime: TimeInterval?
    var hasLoadedDisplayState = false
}

private func usableReaderContentSourceIconURL(_ url: URL?) -> URL? {
    guard let url, !url.isNativeReaderView else { return nil }
    return url
}

@MainActor
class ReaderContentCellViewModel<C: ReaderContentProtocol & ObjectKeyIdentifiable>: ObservableObject {
    @Published var forceShowBookmark = false
    @Published private var displayState = ReaderContentCellDisplayState()

    var readingProgress: Float? { displayState.readingProgress }
    var isFullArticleFinished: Bool? { displayState.isFullArticleFinished }
    var latestHistoryRecordLastVisitedAt: Date? { displayState.latestHistoryRecordLastVisitedAt }
    var title: String { displayState.title }
    var author: String? { displayState.author }
    var humanReadablePublicationDate: String? { displayState.humanReadablePublicationDate }
    var imageURL: URL? { displayState.imageURL }
    var sourceIconURL: URL? { displayState.sourceIconURL }
    var sourceTitle: String? { displayState.sourceTitle }
    var totalWordCount: Int? { displayState.totalWordCount }
    var remainingTime: TimeInterval? { displayState.remainingTime }
    var hasLoadedDisplayState: Bool { displayState.hasLoadedDisplayState }

    init() { }

    @MainActor
    func load(item: C, includeSource: Bool) async throws {
        if displayState.hasLoadedDisplayState {
            var nextState = displayState
            nextState.hasLoadedDisplayState = false
            displayState = nextState
        }
        guard let config = item.realm?.configuration else { return }
        let pk = item.compoundKey
        let imageURL = try await item.imageURLToDisplay()
        try await { @ReaderContentCellActor [weak self] in
            guard let self else { return }
            let realm = try await Realm(configuration: config, actor: ReaderContentCellActor.shared)
            guard let item = realm.object(ofType: C.self, forPrimaryKey: pk) else { return }
            try Task.checkCancellation()

            let rawTitle = item.title.removingClipboardIndicatorIfNeeded(item.needsClipboardIndicator)
            let sanitizedTitle = rawTitle.removingHTMLTags() ?? rawTitle
            let trimmedTitle = sanitizedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
            let author = item.author.trimmingCharacters(in: .whitespacesAndNewlines)
            let shouldDisplayPublicationDate = item.displayPublicationDate || item.isPhysicalMedia
            let humanReadablePublicationDate = shouldDisplayPublicationDate ? item.humanReadablePublicationDate : nil
            let itemURL = item.url
            let itemSourceIconURL = item.sourceIconURL
            let feed = (item as? FeedEntry)?.getFeed()
            let sourceIconURL = usableReaderContentSourceIconURL(feed?.iconUrl) ?? usableReaderContentSourceIconURL(itemSourceIconURL)
            let tracksReadingProgress = item.tracksReadingProgress
            let progressResult = tracksReadingProgress ? try await ReaderContentReadingProgressLoader.readingProgressLoader?(itemURL) : nil
            let metadataResult = tracksReadingProgress ? try await ReaderContentReadingProgressLoader.readingProgressMetadataLoader?(itemURL) : nil
            let historyRealm = try await Realm(configuration: ReaderContentLoader.historyRealmConfiguration, actor: ReaderContentCellActor.shared)
            let latestHistoryRecordLastVisitedAt = HistoryRecord.latestLastVisitedAt(for: itemURL, in: historyRealm)

            var sourceTitle: String?
            if includeSource {
                if itemURL.isSnippetURL {
                    sourceTitle = "Snippet"
                } else if let feed {
                    sourceTitle = feed.title
                } else if let host = itemURL.host, !host.isEmpty {
                    sourceTitle = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                }
            }

            try await { @MainActor in
                try Task.checkCancellation()
                self.displayState = ReaderContentCellDisplayState(
                    readingProgress: progressResult?.0,
                    isFullArticleFinished: progressResult?.1,
                    latestHistoryRecordLastVisitedAt: latestHistoryRecordLastVisitedAt,
                    title: title,
                    author: author.isEmpty ? nil : author,
                    humanReadablePublicationDate: humanReadablePublicationDate,
                    imageURL: imageURL,
                    sourceIconURL: sourceIconURL,
                    sourceTitle: sourceTitle,
                    totalWordCount: metadataResult?.totalWordCount,
                    remainingTime: metadataResult?.remainingTime,
                    hasLoadedDisplayState: true
                )
            }()
        }()
    }

    @MainActor
    func updateImageURL(_ imageURL: URL?) {
        guard imageURL != displayState.imageURL else { return }
        var nextState = displayState
        nextState.imageURL = imageURL
        displayState = nextState
    }
}

public struct ReaderContentCellAppearance {
    public var maxCellHeight: CGFloat
    public var alwaysShowThumbnails: Bool
    public var isEbookStyle: Bool
    public var includeSource: Bool
    public var showsNewBadge: Bool
    public var thumbnailDimension: CGFloat?
    public var thumbnailCornerRadius: CGFloat?

    public init(
        maxCellHeight: CGFloat,
        alwaysShowThumbnails: Bool = true,
        isEbookStyle: Bool = false,
        includeSource: Bool = false,
        showsNewBadge: Bool = true,
        thumbnailDimension: CGFloat? = nil,
        thumbnailCornerRadius: CGFloat? = nil
    ) {
        self.maxCellHeight = maxCellHeight
        self.alwaysShowThumbnails = alwaysShowThumbnails
        self.isEbookStyle = isEbookStyle
        self.includeSource = includeSource
        self.showsNewBadge = showsNewBadge
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

public struct ReaderContentCellAnnotationStatus: Equatable, Sendable {
    public var noteCount: Int
    public var unfinishedTaskCount: Int
    public var finishedTaskCount: Int

    public init(noteCount: Int = 0, unfinishedTaskCount: Int = 0, finishedTaskCount: Int = 0) {
        self.noteCount = noteCount
        self.unfinishedTaskCount = unfinishedTaskCount
        self.finishedTaskCount = finishedTaskCount
    }

    public var taskSymbolName: String? {
        if unfinishedTaskCount > 0 {
            return "circle"
        }
        if finishedTaskCount > 0 {
            return "checkmark.circle"
        }
        return nil
    }
}

private struct ReaderContentCellAnnotationStatusLoaderKey: EnvironmentKey {
    static let defaultValue: @MainActor (URL, String) async -> ReaderContentCellAnnotationStatus = { _, _ in
        ReaderContentCellAnnotationStatus()
    }
}

public extension EnvironmentValues {
    var readerContentCellAnnotationStatusLoader: @MainActor (URL, String) async -> ReaderContentCellAnnotationStatus {
        get { self[ReaderContentCellAnnotationStatusLoaderKey.self] }
        set { self[ReaderContentCellAnnotationStatusLoaderKey.self] = newValue }
    }
}

public extension View {
    func readerContentCellAnnotationStatusLoader(
        _ loader: @escaping @MainActor (URL, String) async -> ReaderContentCellAnnotationStatus
    ) -> some View {
        environment(\.readerContentCellAnnotationStatusLoader, loader)
    }
}

extension ReaderContentProtocol {
    @ViewBuilder public func readerContentCellView(
        appearance: ReaderContentCellAppearance,
        customLeadingMenuOptions: ((Self) -> AnyView)? = nil,
        customMenuOptions: ((Self) -> AnyView)?
    ) -> some View {
        ReaderContentCell(
            item: self,
            appearance: appearance,
            customLeadingMenuOptions: customLeadingMenuOptions,
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
        showsNewBadge: Bool = true,
        thumbnailDimension: CGFloat? = nil,
        thumbnailCornerRadius: CGFloat? = nil
    ) -> some View {
        readerContentCellView(
            appearance: ReaderContentCellAppearance(
                maxCellHeight: maxCellHeight,
                alwaysShowThumbnails: alwaysShowThumbnails,
                isEbookStyle: isEbookStyle,
                includeSource: includeSource,
                showsNewBadge: showsNewBadge,
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
        case .localOnly:
            return "Local File"
        case .cloudOnly:
            return "In iCloud"
        case .downloading:
            return "Downloading from iCloud"
        case .uploading:
            return "Uploading to iCloud"
        case .availableLocally:
            return "Available Offline"
        case .loadingStatus:
            return nil
        }
    }

    private var systemImage: String? {
        switch cloudDriveSyncStatusModel.status {
        case .fileMissing:
            return "exclamationmark.icloud"
        case .localOnly:
            return "icloud.slash"
        case .cloudOnly:
            return "icloud"
        case .downloading:
            return "icloud.and.arrow.down"
        case .uploading:
            return "icloud.and.arrow.up"
        case .availableLocally:
            return "checkmark.icloud"
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

public struct ReaderContentCell<C: ReaderContentProtocol & ObjectKeyIdentifiable>: View {
    @ObservedRealmObject private var item: C
    private let appearance: ReaderContentCellAppearance
    private let customLeadingMenuOptions: ((C) -> AnyView)?
    private let customMenuOptions: ((C) -> AnyView)?

    public init(
        item: C,
        appearance: ReaderContentCellAppearance,
        customLeadingMenuOptions: ((C) -> AnyView)? = nil,
        customMenuOptions: ((C) -> AnyView)? = nil
    ) {
        self._item = ObservedRealmObject(wrappedValue: item)
        self.appearance = appearance
        self.customLeadingMenuOptions = customLeadingMenuOptions
        self.customMenuOptions = customMenuOptions
    }

    public init(
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

    public var body: some View {
        ReaderContentCellBody(
            item: item,
            appearance: appearance,
            customLeadingMenuOptions: customLeadingMenuOptions,
            customMenuOptions: customMenuOptions
        )
    }
}

/// Keeps Realm observation at the cell boundary so nested builders use one resolved object.
private struct ReaderContentCellBody<C: ReaderContentProtocol & ObjectKeyIdentifiable>: View {
    let item: C
    var appearance: ReaderContentCellAppearance
    var customLeadingMenuOptions: ((C) -> AnyView)? = nil
    var customMenuOptions: ((C) -> AnyView)? = nil

    static var buttonSize: CGFloat { 26 }

    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel
    @Environment(\.readerContentCellStyle) private var readerContentCellStyle
    @Environment(\.readerContentCellAnnotationStatusLoader) private var readerContentCellAnnotationStatusLoader
    @Environment(\.stackListGroupBoxContentInsets) private var stackListGroupBoxContentInsets
    @Environment(\.controlSize) private var controlSize
#if DEBUG
    @Environment(\.readerContentVideoMakerOpenAction) private var readerContentVideoMakerOpenAction
#endif

    @ScaledMetric(relativeTo: .caption) private var sourceIconSize = 14
    @ScaledMetric(relativeTo: .caption2) private var scaledSmallNewBadgeHeight: CGFloat = 15
    @StateObject private var viewModel = ReaderContentCellViewModel<C>()
    @State private var annotationStatus = ReaderContentCellAnnotationStatus()

    init(
        item: C,
        appearance: ReaderContentCellAppearance,
        customLeadingMenuOptions: ((C) -> AnyView)? = nil,
        customMenuOptions: ((C) -> AnyView)? = nil
    ) {
        self.item = item
        self.appearance = appearance
        self.customLeadingMenuOptions = customLeadingMenuOptions
        self.customMenuOptions = customMenuOptions
    }

    private var buttonSize: CGFloat { Self.buttonSize }

    private var thumbnailEdgeLength: CGFloat {
        max(1, appearance.thumbnailDimension ?? appearance.maxCellHeight)
    }

    private var effectiveCardCellHeight: CGFloat {
        appearance.maxCellHeight
    }

    private var usesCompactControlSize: Bool {
        controlSize == .small || controlSize == .mini
    }

    private var compactScale: CGFloat {
        0.4
    }

    private var compactCellHeight: CGFloat {
        max(1, appearance.maxCellHeight * compactScale)
    }

    private var compactCellMinWidth: CGFloat {
        appearance.maxCellHeight + 30
    }

    private var compactThumbnailEdgeLength: CGFloat {
        max(1, thumbnailEdgeLength * compactScale)
    }

    private var displayImageURL: URL? {
        viewModel.imageURL ?? item.imageUrl
    }

    private var resolvedSourceIconURL: URL? {
        usableReaderContentSourceIconURL(viewModel.sourceIconURL) ?? usableReaderContentSourceIconURL(item.sourceIconURL)
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
        if item.url.contentKind != .webpage {
            return item.url.contentKindTitle
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

    private var fallbackTitle: String {
        let primary = viewModel.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty {
            return primary
        }

        let rawTitle = item.title.removingClipboardIndicatorIfNeeded(item.needsClipboardIndicator)
        let sanitizedTitle = rawTitle.removingHTMLTags() ?? rawTitle
        let fallback = sanitizedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fallback.isEmpty {
            return fallback
        }

        if item.url.isSnippetURL {
            return "Untitled"
        }

        if item.url.contentKind != .webpage {
            return item.url.contentKindTitle
        }

        if let host = item.url.host, !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }

        return item.url.absoluteString
    }

    private var comparisonTitles: [String] {
        [viewModel.title, fallbackTitle]
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
        fallbackTitle
    }

    private var showsUnreadIndicator: Bool {
        viewModel.latestHistoryRecordLastVisitedAt == nil
    }

    private var isProgressVisible: Bool {
        if let readingProgressFloat = viewModel.readingProgress, readingProgressFloat > 0 {
            return true
        }
        return false
    }

    private var remainingDurationText: String? {
        Self.formatMetadata(remainingTime: viewModel.remainingTime)
    }

    private static func formatMetadata(remainingTime: TimeInterval?) -> String? {
        guard let remainingTime, remainingTime > 1,
              let formatted = ReaderDateFormatter.shortDurationString(from: remainingTime) else {
            return nil
        }
        return "\(formatted) left"
    }

    private var publicationDateText: String? {
        if let formatted = viewModel.humanReadablePublicationDate, !formatted.isEmpty {
            return formatted
        }
        if item.displayPublicationDate || item.isPhysicalMedia {
            if let fallback = item.humanReadablePublicationDate?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty {
                return fallback
            }
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
        if appearance.maxCellHeight >= 110 {
            return 3
        }
        return 1
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
        if appearance.thumbnailDimension != nil || hasVisibleThumbnail {
            return readerContentCellStyle == .card ? effectiveCardCellHeight : appearance.maxCellHeight
        }
        return nil
    }

    private enum ThumbnailChoice {
        case image(URL)
        case icon(URL)
        case initial(String)
        case symbol(String)
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
        guard appearance.alwaysShowThumbnails else { return nil }
        if item.needsClipboardIndicator {
            return .symbol("paperclip")
        }
        return .initial(fallbackInitial)
    }

    private var hasVisibleThumbnail: Bool {
        thumbnailChoice != nil
    }

    private var usesPlainLayout: Bool {
        readerContentCellStyle == .plain
    }

    private var metadataRowVerticalOffset: CGFloat {
        guard readerContentCellStyle == .card else { return 0 }
        return 4
    }

    private var bottomAccessoryVerticalOffset: CGFloat {
        guard readerContentCellStyle == .card else { return 0 }
        return metadataRowVerticalOffset + 1
    }

    private var bottomBlockVerticalOffset: CGFloat {
        0
    }

    private var bottomBlockSpacing: CGFloat {
        isProgressVisible ? -4 : 0
    }

    private var showsAudioBadge: Bool {
        item.hasAudio
    }

#if DEBUG
    @ViewBuilder
    private var videoMakerMenuItem: some View {
        if let readerContentVideoMakerOpenAction, item.hasTranscriptTracerVideoSource {
            Button {
                readerContentVideoMakerOpenAction([item])
            } label: {
                Label("Make Video", systemImage: "film")
            }
        }
    }
#endif

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
            if showsNewBadge {
                ReaderNewBadge()
                    .controlSize(.small)
                    .transition(.opacity.animation(.default))
            }

            if showsAudioBadge {
                Image(systemName: "headphones")
                    .imageScale(.small)
                    .transition(.opacity.animation(.default))
            }

            if !usesCompactControlSize, annotationStatus.noteCount > 0 {
                Image(systemName: "text.pad.header")
                    .imageScale(.small)
            }

            if !usesCompactControlSize, let taskSymbolName = annotationStatus.taskSymbolName {
                Image(systemName: taskSymbolName)
                    .imageScale(.small)
            }

            if let item = item as? ContentFile {
                CloudDriveSyncStatusView(item: item)
                    .labelStyle(.iconOnly)
                    .font(.callout)
                    .imageScale(.small)
            }
        }
        .foregroundStyle(.secondary)
        .frame(height: scaledSmallNewBadgeHeight)
    }

    @ViewBuilder
    private var publicationDateRow: some View {
        if let publicationDate = publicationDateText {
            Text(publicationDate)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.9)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .layoutPriority(2)
        }
    }

    @ViewBuilder
    private var progressMetadata: some View {
        if let readingProgressFloat = viewModel.readingProgress, isProgressVisible {
            HStack(spacing: 8) {
                ProgressView(value: min(1, readingProgressFloat))
                    .tint((viewModel.isFullArticleFinished ?? false) ? Color("Green") : .secondary)
                    .frame(width: 24)

                if let remainingDurationText {
                    Text(remainingDurationText)
                        .font(.caption)
                        .lineLimit(1)
                        .allowsTightening(true)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    @ViewBuilder
    private var metadataRow: some View {
        HStack(alignment: .center, spacing: 6) {
            if isProgressVisible {
                progressMetadata
            } else {
                publicationDateRow
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer(minLength: 0)

            BookmarkButton(iconOnly: true, readerContent: item, hiddenIfUnbookmarked: true)
                .labelStyle(.iconOnly)
                .imageScale(.small)
                .frame(width: buttonSize, height: buttonSize, alignment: .center)

            controlsRow
                .frame(width: buttonSize, height: buttonSize, alignment: .center)
        }
        .frame(height: buttonSize, alignment: .center)
        .offset(y: bottomAccessoryVerticalOffset)
        .foregroundStyle(.secondary)
        .buttonStyle(.clearBordered)
        .controlSize(.small)
        .animation(.easeInOut(duration: 0.2), value: isProgressVisible)
    }

    @ViewBuilder
    private var progressRow: some View {
        if isProgressVisible {
            publicationDateRow
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var titleRow: some View {
        titleText
            .font(.headline)
            .lineLimit(titleLineLimit)
            .multilineTextAlignment(.leading)
            .environment(\._lineHeightMultiple, 0.875)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleText: Text {
        Text(displayTitle)
            .foregroundColor((viewModel.isFullArticleFinished ?? false) ? .secondary : .primary)
    }

    @ViewBuilder
    private var compactTitleRow: some View {
        titleText
            .font(.callout)
            .lineLimit(1)
            .multilineTextAlignment(.leading)
            .environment(\._lineHeightMultiple, 0.875)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var showsNewBadge: Bool {
        viewModel.hasLoadedDisplayState &&
        appearance.showsNewBadge &&
        (showsUnreadIndicator || (appearance.isEbookStyle && !isProgressVisible))
    }

    @ViewBuilder
    private var controlsRow: some View {
        let deletable = item as? (any DeletableReaderContent)
        if #available(iOS 16, macOS 13, *) {
            Menu {
                if let customLeadingMenuOptions {
                    customLeadingMenuOptions(self.item)
                }

                if let item = item as? ContentFile {
                    CloudDriveSyncStatusView(item: item)
                        .labelStyle(.titleAndIcon)
                    Divider()
                }

                AnyView(self.item.bookmarkButtonView(iconOnly: false))

#if DEBUG
                videoMakerMenuItem
#endif

                if let customMenuOptions {
                    customMenuOptions(self.item)
                }

                if let deletable {
                    Divider()
                    Button(role: .destructive) {
                        readerContentListModalsModel.presentDeleteConfirmation(for: [deletable])
                    } label: {
                        Label(deletable.deleteActionTitle, systemImage: "trash")
                    }
                }
            } label: {
                Label("More Options", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .accessibilityLabel("More Options")
        } else if #available(iOS 15, macOS 12, *) {
            Menu {
                if let customLeadingMenuOptions {
                    customLeadingMenuOptions(self.item)
                }

                if let item = item as? ContentFile {
                    CloudDriveSyncStatusView(item: item)
                        .labelStyle(.titleAndIcon)
                    Divider()
                }

                AnyView(self.item.bookmarkButtonView(iconOnly: false))

#if DEBUG
                videoMakerMenuItem
#endif

                if let customMenuOptions {
                    customMenuOptions(self.item)
                }

                if let deletable {
                    Divider()
                    Button(role: .destructive) {
                        readerContentListModalsModel.presentDeleteConfirmation(for: [deletable])
                    } label: {
                        Label(deletable.deleteActionTitle, systemImage: "trash")
                    }
                }
            } label: {
                Label("More Options", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("More Options")
        } else {
            Menu {
                if let customLeadingMenuOptions {
                    customLeadingMenuOptions(self.item)
                }

                if let item = item as? ContentFile {
                    CloudDriveSyncStatusView(item: item)
                        .labelStyle(.titleAndIcon)
                    Divider()
                }

                AnyView(self.item.bookmarkButtonView(iconOnly: false))

#if DEBUG
                videoMakerMenuItem
#endif

                if let customMenuOptions {
                    customMenuOptions(self.item)
                }

                if let deletable {
                    Divider()
                    Button(role: .destructive) {
                        readerContentListModalsModel.presentDeleteConfirmation(for: [deletable])
                    } label: {
                        Label(deletable.deleteActionTitle, systemImage: "trash")
                    }
                }
            } label: {
                Label("More Options", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("More Options")
        }
    }

    @ViewBuilder
    private func thumbnailView(for thumbnailChoice: ThumbnailChoice, edgeLength: CGFloat? = nil) -> some View {
        let edgeLength = edgeLength ?? thumbnailEdgeLength
        Group {
            switch thumbnailChoice {
            case .image(let imageURL):
                if appearance.isEbookStyle {
                    BookCoverImageView(imageURL: imageURL, dimension: edgeLength)
                } else {
                    ReaderImage(
                        imageURL,
                        maxWidth: edgeLength,
                        minHeight: edgeLength,
                        maxHeight: edgeLength
                    )
                    .clipShape(RoundedRectangle(cornerRadius: thumbnailCornerRadius, style: .continuous))
                }
            case .icon(let sourceIconURL):
                ReaderContentThumbnailTile(
                    content: .icon(sourceIconURL, placeholder: fallbackInitial),
                    width: edgeLength,
                    height: edgeLength,
                    cornerRadius: thumbnailCornerRadius
                )
            case .initial(let letter):
                ReaderContentThumbnailTile(
                    content: .initial(letter),
                    width: edgeLength,
                    height: edgeLength,
                    cornerRadius: thumbnailCornerRadius
                )
            case .symbol(let systemName):
                ReaderContentThumbnailTile(
                    content: .symbol(systemName),
                    width: edgeLength,
                    height: edgeLength,
                    cornerRadius: thumbnailCornerRadius
                )
            }
        }
    }

    @ViewBuilder
    private var compactLayout: some View {
        HStack(alignment: .center, spacing: 10) {
            if let thumbnailChoice {
                thumbnailView(for: thumbnailChoice, edgeLength: compactThumbnailEdgeLength)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                sourceOrAuthorRow
                compactTitleRow
                progressMetadata
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(2)
            .accessibilityHidden(true)

            controlsRow
                .frame(width: buttonSize, height: buttonSize, alignment: .center)
                .foregroundStyle(.secondary)
                .buttonStyle(.clearBordered)
                .controlSize(.small)
        }
        .frame(minHeight: compactCellHeight, maxHeight: compactCellHeight, alignment: .center)
    }

    @ViewBuilder
    private var regularLayout: some View {
        HStack(alignment: .top, spacing: 12) {
            if let thumbnailChoice {
                thumbnailView(for: thumbnailChoice)
                    .accessibilityHidden(true)
            }

            Group {
                if usesPlainLayout {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 6) {
                            sourceOrAuthorRow

                            VStack(alignment: .leading, spacing: 6) {
                                titleRow

                                topStatusRow
                            }
                        }

                        Spacer(minLength: 4)

                        VStack(alignment: .leading, spacing: bottomBlockSpacing) {
                            progressRow
                            metadataRow
                        }
                        .offset(y: bottomBlockVerticalOffset)
                        .layoutPriority(3)
                    }
                    .frame(maxWidth: .infinity, minHeight: contentColumnHeight, maxHeight: contentColumnHeight, alignment: .top)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 6) {
                            sourceOrAuthorRow
                            titleRow

                            topStatusRow
                        }

                        Spacer(minLength: 4)

                        VStack(alignment: .leading, spacing: bottomBlockSpacing) {
                            progressRow
                            metadataRow
                        }
                        .offset(y: bottomBlockVerticalOffset)
                        .layoutPriority(3)
                    }
                    .frame(height: contentColumnHeight, alignment: .top)
                }
            }
            .accessibilityHidden(true)
        }
    }

    var body: some View {
        Group {
            if usesCompactControlSize {
                compactLayout
            } else {
                regularLayout
            }
        }
        .frame(
            minWidth: usesCompactControlSize ? compactCellMinWidth : appearance.maxCellHeight,
            minHeight: usesCompactControlSize ? compactCellHeight : (readerContentCellStyle == .card ? effectiveCardCellHeight : nil),
            idealHeight: usesCompactControlSize ? compactCellHeight : (hasVisibleThumbnail ? (readerContentCellStyle == .card ? effectiveCardCellHeight : appearance.maxCellHeight) : nil),
            maxHeight: usesCompactControlSize ? compactCellHeight : (readerContentCellStyle == .card ? effectiveCardCellHeight : nil)
        )
        .onHover { hovered in
            guard viewModel.forceShowBookmark != hovered else { return }
            viewModel.forceShowBookmark = hovered
        }
        .onAppear {
            Task { @MainActor in
                try? await viewModel.load(item: item, includeSource: appearance.includeSource)
            }
        }
        .task(id: item.compoundKey) {
            annotationStatus = await readerContentCellAnnotationStatusLoader(item.url, item.compoundKey)
        }
        .onChange(of: item.imageUrl) { newImageURL in
            guard newImageURL != viewModel.imageURL else { return }
            Task { @MainActor in
                viewModel.updateImageURL(try await item.imageURLToDisplay())
            }
        }
    }
}

private struct ReaderContentThumbnailTile: View {
    enum Content {
        case icon(URL, placeholder: String)
        case initial(String)
        case symbol(String)
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
                if let placeholderLetter {
                    Text(placeholderLetter)
                        .font(.system(size: min(width, height) * 0.42, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.4)
                        .foregroundStyle(Color.secondary.opacity(0.9))
                }

                ReaderContentSourceIconImage(sourceIconURL: iconURL, iconSize: min(width, height) * 0.52)
            }

            if case let .symbol(systemName) = content {
                Image(systemName: systemName)
                    .font(.system(size: min(width, height) * 0.34, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.85))
            }

            if case .initial = content, let placeholderLetter {
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
        case .symbol:
            return nil
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
