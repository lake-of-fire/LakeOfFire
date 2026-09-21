import SwiftUI
import Foundation
import CoreText
import RealmSwift
import RealmSwiftGaps
import LakeKit
import Combine
import LakeOfFireContent
import LakeOfFireCore
import LakeOfFireAdblock
import SwiftUtilities

public struct ReaderNewBadge: View {
    @Environment(\.controlSize) private var controlSize
    @ScaledMetric(relativeTo: .caption2) private var compactFontSize: CGFloat = 10

    public init() {}

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

private let readerContentCellWordCountFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter
}()

@globalActor
fileprivate actor ReaderContentCellActor {
    static let shared = ReaderContentCellActor()
}

fileprivate struct ReaderContentCellDisplayState {
    var readingProgress: Float?
    var isFullArticleFinished: Bool?
    var title = ""
    var author: String?
    var humanReadablePublicationDate: String?
    var imageURL: URL?
    var sourceIconURL: URL?
    var sourceTitle: String?
    var totalWordCount: Int?
    var remainingTime: TimeInterval?
    var syncStatusPresentation: ReaderContentSyncStatusPresentation?
    var hasLoadedDisplayState = false
}

/// Same-row metadata edits restart the one generation-fenced display-state producer.
/// Progress and history stored in other models retain their separate invalidation owners.
struct ReaderContentCellLoadIdentity: Hashable {
    let compoundKey: String
    let sourceIncarnation: BookmarkMutationSourceIncarnation
    let accountSessionSnapshot: AccountSessionSnapshot?
    let includesSource: Bool
    let url: URL
    let modifiedAt: Date
    let imageURL: URL?

    @MainActor
    init(
        item: any ReaderContentProtocol,
        includesSource: Bool,
        accountSessionSnapshot: AccountSessionSnapshot? = nil
    ) {
        compoundKey = item.compoundKey
        sourceIncarnation = BookmarkMutationSourceIncarnation(item)
        self.accountSessionSnapshot = accountSessionSnapshot
        self.includesSource = includesSource
        url = item.url
        modifiedAt = item.modifiedAt
        imageURL = item.imageUrl
    }
}

struct ReaderContentCellLoadTaskIdentity: Hashable {
    let loadIdentity: ReaderContentCellLoadIdentity
    let retryRevision: UInt64
    let derivedStateRevision: UInt64

    init(
        loadIdentity: ReaderContentCellLoadIdentity,
        retryRevision: UInt64,
        derivedStateRevision: UInt64 = 0
    ) {
        self.loadIdentity = loadIdentity
        self.retryRevision = retryRevision
        self.derivedStateRevision = derivedStateRevision
    }
}

struct ReaderContentCellHistoryIdentity: Hashable {
    let compoundKey: String
    let sourceIncarnation: BookmarkMutationSourceIncarnation
    let accountSessionSnapshot: AccountSessionSnapshot?
    let url: URL
    let realmConfigurationIdentity: String

    @MainActor
    init(
        item: any ReaderContentProtocol,
        realmConfiguration: Realm.Configuration,
        accountSessionSnapshot: AccountSessionSnapshot? = nil
    ) {
        compoundKey = item.compoundKey
        sourceIncarnation = BookmarkMutationSourceIncarnation(item)
        self.accountSessionSnapshot = accountSessionSnapshot
        url = item.url
        realmConfigurationIdentity = feedRealmConfigurationIdentity(realmConfiguration)
    }
}

enum ReaderContentCellHistoryState: Equatable, Sendable {
    case loading
    case value(Date?)
}

@MainActor
private final class ReaderContentCellHistorySubscription {
    var cancellable: AnyCancellable?

    func cancel() {
        cancellable?.cancel()
        cancellable = nil
    }
}

private func usableReaderContentSourceIconURL(_ url: URL?) -> URL? {
    guard let url, !url.isNativeReaderView else { return nil }
    return url
}

@MainActor
class ReaderContentCellViewModel<C: ReaderContentProtocol & ObjectKeyIdentifiable>: ObservableObject {
    @Published var forceShowBookmark = false
    @Published private var displayState = ReaderContentCellDisplayState()
    @Published private(set) var historyState = ReaderContentCellHistoryState.loading
    private var loadGeneration: UInt64 = 0
    private var historyGeneration: UInt64 = 0

    var readingProgress: Float? { displayState.readingProgress }
    var isFullArticleFinished: Bool? { displayState.isFullArticleFinished }
    var hasLoadedHistoryState: Bool { historyState != .loading }
    var latestHistoryRecordLastVisitedAt: Date? {
        if case let .value(lastVisitedAt) = historyState {
            return lastVisitedAt
        }
        return nil
    }
    var title: String { displayState.title }
    var author: String? { displayState.author }
    var humanReadablePublicationDate: String? { displayState.humanReadablePublicationDate }
    var imageURL: URL? { displayState.imageURL }
    var sourceIconURL: URL? { displayState.sourceIconURL }
    var sourceTitle: String? { displayState.sourceTitle }
    var totalWordCount: Int? { displayState.totalWordCount }
    var remainingTime: TimeInterval? { displayState.remainingTime }
    var syncStatusPresentation: ReaderContentSyncStatusPresentation? { displayState.syncStatusPresentation }
    var hasLoadedDisplayState: Bool { displayState.hasLoadedDisplayState }
    // Continue Reading menu is driven by an injected provider in the environment.

    private let imageURLLoader: @MainActor (C) async throws -> URL?
    private let feedEntryRealmConfigurationOverride: Realm.Configuration?

    init(imageURLLoader: @escaping @MainActor (C) async throws -> URL? = {
        try await $0.imageURLToDisplay()
    },
    feedEntryRealmConfiguration: Realm.Configuration? = nil) {
        self.imageURLLoader = imageURLLoader
        feedEntryRealmConfigurationOverride = feedEntryRealmConfiguration
    }

    func suspendAccountDerivedState() {
        loadGeneration &+= 1
        var nextState = displayState
        nextState.readingProgress = nil
        nextState.isFullArticleFinished = nil
        nextState.totalWordCount = nil
        nextState.remainingTime = nil
        displayState = nextState
    }

    func suspendHistoryObservation() {
        historyGeneration &+= 1
        historyState = .loading
    }

    func observeHistory(
        for itemURL: URL,
        realmConfiguration: Realm.Configuration
    ) async throws {
        try Task.checkCancellation()
        historyGeneration &+= 1
        let generation = historyGeneration
        if historyState != .loading {
            historyState = .loading
        }

        let realm = try await Realm.open(configuration: realmConfiguration)
        try Task.checkCancellation()
        guard generation == historyGeneration else { throw CancellationError() }
        let historyRecords = HistoryRecord.openedRecords(matching: itemURL, in: realm)
        let historyPublisher = historyRecords
            .collectionPublisher(keyPaths: ["isDeleted", "url", "lastVisitedAt"])
            .map { records in
                records.map(\.lastVisitedAt).max()
            }
            .removeDuplicates()
        let observation = ReaderContentCellHistorySubscription()
        let historyValues = AsyncThrowingStream<Date?, Error> { continuation in
            continuation.onTermination = { _ in
                Task { @MainActor in
                    observation.cancel()
                }
            }
            observation.cancellable = historyPublisher.sink(
                receiveCompletion: { completion in
                    switch completion {
                    case .finished:
                        continuation.finish()
                    case let .failure(error):
                        continuation.finish(throwing: error)
                    }
                },
                receiveValue: { value in
                    continuation.yield(value)
                }
            )
        }

        for try await lastVisitedAt in historyValues {
            try Task.checkCancellation()
            guard generation == historyGeneration else { throw CancellationError() }
            let nextState = ReaderContentCellHistoryState.value(lastVisitedAt)
            guard historyState != nextState else { continue }
            historyState = nextState
        }
        try Task.checkCancellation()
        guard generation == historyGeneration else { throw CancellationError() }
    }

    func load(
        item: C,
        includeSource: Bool
    ) async throws {
        try Task.checkCancellation()
        loadGeneration &+= 1
        let generation = loadGeneration

        if displayState.hasLoadedDisplayState {
            var loadingState = displayState
            loadingState.hasLoadedDisplayState = false
            displayState = loadingState
        }
        debugPrint("# loading", item.url.lastPathComponent)

        guard let contentRealmConfiguration = item.realm?.configuration else { return }
        let primaryKey = item.compoundKey
        let itemURL = item.url
        let feedEntryRealmConfiguration = feedEntryRealmConfigurationOverride
            ?? ReaderContentLoader.feedEntryRealmConfiguration
        let imageURL = try await imageURLLoader(item)
        try Task.checkCancellation()
        guard generation == loadGeneration else { throw CancellationError() }

        let nextDisplayState = try await { @ReaderContentCellActor in
            let realm = try await Realm(
                configuration: contentRealmConfiguration,
                actor: ReaderContentCellActor.shared
            )
            guard let item = realm.object(ofType: C.self, forPrimaryKey: primaryKey) else {
                return nil as ReaderContentCellDisplayState?
            }
            try Task.checkCancellation()

            let rawTitle = item.title.removingClipboardIndicatorIfNeeded(item.needsClipboardIndicator)
            let sanitizedTitle = rawTitle.removingHTMLTags() ?? rawTitle
            let trimmedTitle = sanitizedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
            let shouldDisplayPublicationDate = item.displayPublicationDate || item.isPhysicalMedia
            let humanReadablePublicationDate = shouldDisplayPublicationDate ? item.humanReadablePublicationDate : nil
            let author = item.author.trimmingCharacters(in: .whitespacesAndNewlines)
            let itemSourceIconURL = item.sourceIconURL
            let feed = (item as? FeedEntry)?.getFeed()
            let feedTitle = feed?.title
            let resolvedSourceIconURL = usableReaderContentSourceIconURL(feed?.iconUrl)
                ?? usableReaderContentSourceIconURL(itemSourceIconURL)
            let tracksReadingProgress = item.tracksReadingProgress
            let progressResult = tracksReadingProgress
                ? try await ReaderContentReadingProgressLoader.readingProgressLoader?(itemURL)
                : nil
            let metadataResult = tracksReadingProgress
                ? try await ReaderContentReadingProgressLoader.readingProgressMetadataLoader?(itemURL)
                : nil
            let syncStatusPresentation = try await ReaderContentSyncStatusLoader.syncStatusLoader?(itemURL)
            try Task.checkCancellation()

            var sourceTitle: String?
            var sourceIconURL: URL? = resolvedSourceIconURL

            if includeSource {
                if itemURL.isSnippetURL {
                    sourceTitle = "Snippet"
                } else if itemURL.contentKind != .webpage {
                    sourceTitle = itemURL.contentKindTitle
                } else if let feedTitle {
                    sourceTitle = feedTitle
                } else if itemURL.isHTTP {
                    sourceTitle = itemURL.host
                    let feedRealm = try await Realm(
                        configuration: feedEntryRealmConfiguration,
                        actor: ReaderContentCellActor.shared
                    )
                    try Task.checkCancellation()

                    if let feedEntry = feedRealm.objects(FeedEntry.self)
                        .filter(NSPredicate(format: "url == %@", itemURL.absoluteString as CVarArg))
                        .first,
                       let feed = feedEntry.getFeed() {
                        sourceTitle = feed.title
                        sourceIconURL = usableReaderContentSourceIconURL(feed.iconUrl)
                            ?? resolvedSourceIconURL
                    } else if let host = itemURL.host {
                        sourceTitle = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                    }
                }
            }

            return ReaderContentCellDisplayState(
                readingProgress: progressResult?.0,
                isFullArticleFinished: progressResult?.1,
                title: title,
                author: author.isEmpty ? nil : author,
                humanReadablePublicationDate: humanReadablePublicationDate,
                imageURL: imageURL,
                sourceIconURL: sourceIconURL,
                sourceTitle: sourceTitle,
                totalWordCount: metadataResult?.totalWordCount,
                remainingTime: metadataResult?.remainingTime,
                syncStatusPresentation: syncStatusPresentation,
                hasLoadedDisplayState: true
            )
        }()
        try Task.checkCancellation()
        guard generation == loadGeneration else { throw CancellationError() }
        guard let nextDisplayState else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            displayState = nextDisplayState
        }
        // Continue Reading state is provided externally via environment provider.
    }
}

private let ebookAbsoluteDateFormatter: DateFormatter = {
    ReaderDateFormatter.makeAbsoluteFormatter(dateStyle: .medium)
}()

struct ReaderContentBookCoverRenderedWidthPreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

public struct ReaderContentCellAppearance: Sendable {
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

private struct ReaderContentRowOwnsAccessibilityLabelKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var readerContentRowOwnsAccessibilityLabel: Bool {
        get { self[ReaderContentRowOwnsAccessibilityLabelKey.self] }
        set { self[ReaderContentRowOwnsAccessibilityLabelKey.self] = newValue }
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
        if unfinishedTaskCount > 0 { return "circle" }
        if finishedTaskCount > 0 { return "circle.checkmark" }
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

private struct ReaderContentNewBadgeVisibilityKey: EnvironmentKey {
    static let defaultValue: @MainActor (String) -> Bool = { _ in true }
}

private struct ReaderContentCellAccountSessionSnapshotKey: EnvironmentKey {
    static let defaultValue: AccountSessionSnapshot? = nil
}

public extension EnvironmentValues {
    var readerContentNewBadgeVisibility: @MainActor (String) -> Bool {
        get { self[ReaderContentNewBadgeVisibilityKey.self] }
        set { self[ReaderContentNewBadgeVisibilityKey.self] = newValue }
    }


    var readerContentCellAccountSessionSnapshot: AccountSessionSnapshot? {
        get { self[ReaderContentCellAccountSessionSnapshotKey.self] }
        set { self[ReaderContentCellAccountSessionSnapshotKey.self] = newValue }
    }
}

public extension View {
    func readerContentNewBadgeVisibility(
        _ visibility: @escaping @MainActor (String) -> Bool
    ) -> some View {
        environment(\.readerContentNewBadgeVisibility, visibility)
    }

    func readerContentCellAccountSessionSnapshot(
        _ snapshot: AccountSessionSnapshot?
    ) -> some View {
        environment(\.readerContentCellAccountSessionSnapshot, snapshot)
    }
}

extension ReaderContentProtocol {
    // Overload that allows injecting custom menu options.
    @MainActor
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

    @MainActor
    @ViewBuilder public func readerContentCellView(
        appearance: ReaderContentCellAppearance
    ) -> some View {
        readerContentCellView(
            appearance: appearance,
            customMenuOptions: nil
        )
    }

    // Back-compat convenience
    @MainActor
    @ViewBuilder public func readerContentCellView(
        maxCellHeight: CGFloat,
        alwaysShowThumbnails: Bool = true,
        isEbookStyle: Bool = false,
        includeSource: Bool = false,
        showsNewBadge: Bool = true,
        thumbnailDimension: CGFloat? = nil,
        thumbnailCornerRadius: CGFloat? = nil
    ) -> some View {
        let appearance = ReaderContentCellAppearance(
            maxCellHeight: maxCellHeight,
            alwaysShowThumbnails: alwaysShowThumbnails,
            isEbookStyle: isEbookStyle,
            includeSource: includeSource,
            showsNewBadge: showsNewBadge,
            thumbnailDimension: thumbnailDimension,
            thumbnailCornerRadius: thumbnailCornerRadius
        )
        readerContentCellView(appearance: appearance)
    }
}

private struct ReaderContentSyncStatusLabel: View {
    let presentation: ReaderContentSyncStatusPresentation
    let iconOnly: Bool

    var body: some View {
        Group {
            if presentation.imageIsSystemSymbol {
                Label(presentation.title, systemImage: presentation.imageName)
            } else {
                Label {
                    Text(presentation.title)
                } icon: {
                    Image(presentation.imageName)
                        .renderingMode(.template)
                }
            }
        }
        .modifier {
            if iconOnly {
                $0.labelStyle(.iconOnly)
            } else {
                $0.labelStyle(.titleAndIcon)
            }
        }
    }
}

struct CloudDriveSyncStatusView: View { //, Equatable {
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
        if let title = title, let systemImage = systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text("")
                .hidden()
        }
    }
}

@MainActor
struct ReaderContentCell<C: ReaderContentProtocol & ObjectKeyIdentifiable>: View { //, Equatable {
    @ObservedRealmObject var item: C
    var appearance: ReaderContentCellAppearance
    // Optional custom menu items to include in the trailing menu.
    // Using AnyView avoids templating this struct with another generic.
    var customMenuOptions: ((C) -> AnyView)? = nil

    static var buttonSize: CGFloat {
        return 26
    }

    var body: some View {
        ReaderContentCellBody(
            item: item,
            appearance: appearance,
            customMenuOptions: customMenuOptions
        )
    }
}

/// Keeps Realm observation at the cell boundary so nested builders use one resolved object.
@MainActor
private struct ReaderContentCellBody<C: ReaderContentProtocol & ObjectKeyIdentifiable>: View {
    let item: C
    let appearance: ReaderContentCellAppearance
    let customMenuOptions: ((C) -> AnyView)?

    @State private var resolvedContentFile: ContentFile?
    @State private var contentFileLookupStarted = false
    @ScaledMetric(relativeTo: .caption2) private var scaledSmallNewBadgeHeight: CGFloat = 15

    private let progressBarWidth: CGFloat = 21.0

    private var thumbnailEdgeLength: CGFloat {
        let base = appearance.thumbnailDimension ?? appearance.maxCellHeight
        return max(1, base)
    }

    private var displayImageURL: URL? {
        viewModel.imageURL ?? item.imageUrl
    }

    private var coverCacheRefreshIdentity: String {
        "\(item.compoundKey)|\(item.modifiedAt.timeIntervalSinceReferenceDate.bitPattern)"
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

    @Environment(\.stackListGroupBoxContentInsets) private var stackListGroupBoxContentInsets
    @Environment(\.readerContentCellAnnotationStatusLoader) private var readerContentCellAnnotationStatusLoader
    @Environment(\.readerContentCellAnnotationStatusUpdates) private var readerContentCellAnnotationStatusUpdates
    @Environment(\.readerContentCellDerivedStateUpdates) private var readerContentCellDerivedStateUpdates
    @Environment(\.readerContentNewBadgeVisibility) private var readerContentNewBadgeVisibility
    @Environment(\.readerContentCellAccountSessionSnapshot) private var accountSessionSnapshot
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    @State private var annotationStatus = ReaderContentCellAnnotationStatus()
    @State private var loadFailureDescription: String?
    @State private var loadRetryRevision: UInt64 = 0
    @State private var derivedStateRevision: UInt64 = 0
    @State private var renderedPhysicalCoverWidth: CGFloat = 0

    private var historyRealmConfiguration: Realm.Configuration {
        ReaderContentLoader.historyRealmConfiguration
    }

    private var loadIdentity: ReaderContentCellLoadIdentity {
        ReaderContentCellLoadIdentity(
            item: item,
            includesSource: appearance.includeSource,
            accountSessionSnapshot: accountSessionSnapshot
        )
    }

    // Match the parent card's rounding minus its padding and scale it with the actual thumbnail size.
    private var thumbnailCornerRadius: CGFloat {
        if let customCornerRadius = appearance.thumbnailCornerRadius {
            return max(0, min(customCornerRadius, thumbnailEdgeLength / 2))
        }

        let containerCornerRadius = stackListCornerRadius
        let insetOffset = min(stackListGroupBoxContentInsets.leading, stackListGroupBoxContentInsets.top)
        let baseCornerRadius = max(0, containerCornerRadius - insetOffset)
        let scale = min(thumbnailEdgeLength / max(appearance.maxCellHeight, 1), 1)
        let scaledCornerRadius = baseCornerRadius * scale
        let upperBound = min(containerCornerRadius, thumbnailEdgeLength / 2)

        return max(0, min(upperBound, scaledCornerRadius))
    }

    private enum ThumbnailChoice {
        case image(URL)
        case icon(URL)
        case initial
        case symbol(String)
    }

    private var thumbnailChoice: ThumbnailChoice? {
        if let url = displayImageURL {
            return .image(url)
        }
        if let iconURL = resolvedSourceIconURL {
            return .icon(iconURL)
        }
        if item.needsClipboardIndicator {
            return .symbol("paperclip")
        }
        return .initial
    }

    private var fallbackTitle: String {
        let primary = viewModel.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty { return primary }
        let rawTitle = item.title.removingClipboardIndicatorIfNeeded(item.needsClipboardIndicator)
        let sanitizedTitle = rawTitle.removingHTMLTags() ?? rawTitle
        let secondary = sanitizedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secondary.isEmpty { return secondary }
        if item.url.contentKind != .webpage {
            return item.url.contentKindTitle
        }
        if let host = item.url.host {
            let trimmedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if !trimmedHost.isEmpty {
                return trimmedHost
            }
        }
        return item.url.absoluteString
    }

    private var displayTitle: String {
        fallbackTitle
    }

    private var showsUnreadIndicator: Bool {
        viewModel.hasLoadedHistoryState && viewModel.latestHistoryRecordLastVisitedAt == nil
    }

    private var fallbackSourceTitle: String? {
        guard appearance.includeSource else { return nil }
        if item.url.isSnippetURL {
            return "Snippet"
        }
        if item.url.contentKind != .webpage {
            return item.url.contentKindTitle
        }
        if let host = item.url.host, !host.isEmpty {
            let trimmedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if !trimmedHost.isEmpty {
                return trimmedHost
            }
        }
        return nil
    }

    private var displaySourceTitle: String? {
        let primary = viewModel.sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let primary, !primary.isEmpty {
            return primary
        }
        return fallbackSourceTitle
    }

    private func normalizedAuthor(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var comparisonTitles: [String] {
        var titles: [String] = []
        let candidates = [viewModel.title, item.title]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                titles.append(trimmed)
            }
        }
        return titles
    }

    private func isSameAsAnyTitle(_ value: String) -> Bool {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return comparisonTitles.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedValue }
    }

    private var bookAuthorText: String? {
        if let normalizedVM = normalizedAuthor(viewModel.author), !isSameAsAnyTitle(normalizedVM) {
            return normalizedVM
        }
        if let normalizedItemAuthor = normalizedAuthor(item.author), !isSameAsAnyTitle(normalizedItemAuthor) {
            return normalizedItemAuthor
        }
        return nil
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

    private var fallbackInitial: String {
        guard let first = fallbackTitle.first else { return "#" }
        return String(first).uppercased()
    }

    private var hasVisibleThumbnail: Bool {
        thumbnailChoice != nil
    }

    private var physicalMediaThumbnailTargetWidth: CGFloat {
        max(1, thumbnailEdgeLength * 0.7)
    }

    private var physicalMediaThumbnailMaxHeight: CGFloat {
        max(1, thumbnailEdgeLength - stackListGroupBoxContentInsets.top - stackListGroupBoxContentInsets.bottom)
    }

    private var contentColumnHeight: CGFloat? {
        if let dimension = appearance.thumbnailDimension {
            return dimension
        }
        if hasVisibleThumbnail {
            return appearance.maxCellHeight
        }
        return nil
    }

    private var isProgressVisible: Bool {
        guard item.tracksReadingProgress else { return false }
        if let readingProgressFloat = viewModel.readingProgress, readingProgressFloat > 0 {
            return true
        }
        if let mediaProgressValue, mediaProgressValue > 0 {
            return true
        }
        return false
    }

    private var mediaProgressValue: Double? {
        guard let duration = item.primaryMediaDuration,
              duration > 0,
              let position = item.primaryMediaLastPlaybackTime
        else {
            return nil
        }
        return min(1, max(0, position / duration))
    }

    private var shouldShowProgressRow: Bool {
        guard item.tracksReadingProgress else { return false }
        if isProgressVisible { return true }
        if item.hasAudio { return !appearance.isEbookStyle }
        if item.hasPrimaryMedia { return !appearance.isEbookStyle }
        return false
    }

    private var bottomAccessoryVerticalOffset: CGFloat {
        guard readerContentCellStyle == .card else { return 0 }
        return 1
    }

    @ViewBuilder
    private var audioBadge: some View {
        if item.primaryMediaKindRawValue?.lowercased() == "video" {
            Image(systemName: "video")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        } else if item.hasPrimaryMedia || item.hasAudio {
            Image(systemName: "headphones")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var newBadge: some View {
        if showsNewBadge {
            ReaderNewBadge()
                .controlSize(.small)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
    }

    private var titleLineLimit: Int {
        if appearance.maxCellHeight >= 150 { return 3 }
        if appearance.maxCellHeight >= 110 { return 2 }
        return 1
    }

    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel
    @Environment(\.readerContentCellStyle) private var readerContentCellStyle
    @Environment(\.readerContentRowOwnsAccessibilityLabel) private var readerContentRowOwnsAccessibilityLabel
    @Environment(\.controlSize) private var controlSize

    private var usesCompactControlSize: Bool {
        controlSize == .small || controlSize == .mini
    }

    private var compactScale: CGFloat {
        0.4
    }

    private var compactCellHeight: CGFloat {
        max(1, appearance.maxCellHeight * compactScale)
    }

    private var compactThumbnailEdgeLength: CGFloat {
        max(1, thumbnailEdgeLength * compactScale)
    }

    @ScaledMetric(relativeTo: .caption) private var sourceIconSize = 14
    @StateObject private var viewModel = ReaderContentCellViewModel<C>()

    private var buttonSize: CGFloat {
        return ReaderContentCell<C>.buttonSize
    }

    private var remainingDurationText: String? {
        Self.formatMetadata(/*wordCount: viewModel.totalWordCount, */remainingTime: viewModel.remainingTime)
    }

    private static func formatMetadata(/*wordCount: Int?,*/ remainingTime: TimeInterval?) -> String? {
        var parts: [String] = []
//        if let wordCount, wordCount > 0 {
//            let value = readerContentCellWordCountFormatter.string(from: NSNumber(value: wordCount)) ?? "\(wordCount)"
//            parts.append("\(value) words")
//        }
        if let remainingTime, remainingTime > 1 {
            if let formatted = ReaderDateFormatter.shortDurationString(from: remainingTime) {
                parts.append("\(formatted) left")
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " • ")
    }

    private var usesPlainLayout: Bool {
        readerContentCellStyle == .plain
    }

    private var bottomBlockSpacing: CGFloat {
        isProgressVisible ? -4 : 0
    }

    @ViewBuilder
    private var sourceOrAuthorRow: some View {
        Group {
            if appearance.isEbookStyle, let authorText = bookAuthorText {
                Text(authorText)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if appearance.includeSource {
                HStack(alignment: .center, spacing: 6) {
                    if let sourceIconURL = inlineSourceIconURL {
                        ReaderContentSourceIconImage(
                            sourceIconURL: sourceIconURL,
                            iconSize: sourceIconSize
                        )
                        .opacity((viewModel.isFullArticleFinished ?? false) ? 0.75 : 1)
                    }
                    if let sourceTitle = displaySourceTitle {
                        Text(sourceTitle)
                            .lineLimit(1)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityHidden(readerContentRowOwnsAccessibilityLabel)
    }

    @ViewBuilder
    private var topStatusRow: some View {
        HStack(spacing: 8) {
            newBadge
            audioBadge

            if !usesCompactControlSize, annotationStatus.noteCount > 0 {
                Image(systemName: "text.pad.header")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }

            if !usesCompactControlSize, let taskSymbolName = annotationStatus.taskSymbolName {
                Image(systemName: taskSymbolName)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }

            if let contentFile = item as? ContentFile {
                CloudDriveSyncStatusView(item: contentFile)
                    .labelStyle(.iconOnly)
                    .font(.callout)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            } else if let syncStatusPresentation = viewModel.syncStatusPresentation {
                ReaderContentSyncStatusLabel(presentation: syncStatusPresentation, iconOnly: true)
                    .font(.callout)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }

            if let loadFailureDescription {
                Button {
                    loadRetryRevision &+= 1
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Retry loading: \(loadFailureDescription)")
                .accessibilityLabel("Retry loading \(displayTitle)")
            }
        }
        .frame(height: scaledSmallNewBadgeHeight)
        .accessibilityHidden(readerContentRowOwnsAccessibilityLabel)
        .animation(.easeInOut(duration: 0.2), value: showsNewBadge)
    }

    @ViewBuilder
    private var titleRow: some View {
        titleText
            .font(.headline)
            .lineLimit(titleLineLimit)
            .multilineTextAlignment(.leading)
            .environment(\._lineHeightMultiple, 0.875)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(readerContentRowOwnsAccessibilityLabel)
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
            .accessibilityHidden(readerContentRowOwnsAccessibilityLabel)
    }

    private var showsNewBadge: Bool {
        viewModel.hasLoadedDisplayState &&
        appearance.showsNewBadge &&
        readerContentNewBadgeVisibility(item.compoundKey) &&
        (showsUnreadIndicator || (appearance.isEbookStyle && !isProgressVisible))
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
                .accessibilityHidden(readerContentRowOwnsAccessibilityLabel)
        }
    }

    @ViewBuilder
    private var progressMetadata: some View {
        if shouldShowProgressRow {
            HStack(spacing: 8) {
                if let readingProgressFloat = viewModel.readingProgress, isProgressVisible {
                    ProgressView(value: min(1, readingProgressFloat))
                        .progressViewStyle(LinearProgressViewStyle())
                        .tint((viewModel.isFullArticleFinished ?? false) ? Color("PaletteGreen") : .secondary)
                        .frame(width: 24)

                    if let remainingDurationText {
                        Text(remainingDurationText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .allowsTightening(true)
                    }
                } else if let mediaProgressValue {
                    ProgressView(value: mediaProgressValue)
                        .progressViewStyle(LinearProgressViewStyle())
                        .tint(.secondary)
                        .frame(width: progressBarWidth)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .accessibilityHidden(readerContentRowOwnsAccessibilityLabel)
        }
    }

    @ViewBuilder
    private var progressRow: some View {
        if shouldShowProgressRow {
            publicationDateRow
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var trailingMenuButton: some View {
        let deletable = (self.item as? (any DeletableReaderContent))
        let menuSyncStatusPresentation = ReaderContentSyncStatusPresentationBuilder.menuPresentation(
            for: item.url,
            externalPresentation: viewModel.syncStatusPresentation
        )
        let menuSyncStatusLabelPresentation = ReaderContentSyncStatusPresentation(
            title: "Sync Status: \(menuSyncStatusPresentation.title)",
            imageName: menuSyncStatusPresentation.imageName,
            imageIsSystemSymbol: menuSyncStatusPresentation.imageIsSystemSymbol
        )

        Menu {
            ReaderContentSyncStatusLabel(presentation: menuSyncStatusLabelPresentation, iconOnly: false)
            Divider()

            AnyView(self.item.bookmarkButtonView())

            if let customMenuOptions {
                customMenuOptions(self.item)
            }

            if let deletable {
                Divider()
                Button(role: .destructive) {
                    readerContentListModalsModel.presentDeleteConfirmation(for: [deletable])
                    debugPrint("# DELETEMODAL cell tapped ellipsis delete confirmDelete=true host=\(ObjectIdentifier(readerContentListModalsModel))")
                } label: {
                    Label(deletable.deleteActionTitle, systemImage: "trash")
                }
                .task { kickOffContentFileLookupIfNeeded() }
            }

            if let contentFile = resolvedContentFile {
                Button(role: .destructive) {
                    readerContentListModalsModel.presentDeleteConfirmation(for: [contentFile])
                } label: {
                    Label(contentFile.deleteActionTitle, systemImage: "trash")
                }
            }
        } label: {
            Label("More Options", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .modifier {
            if #available(iOS 16, macOS 13, *) {
                $0.menuStyle(.button)
            } else { $0 }
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("More Options")
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

            Spacer(minLength: ReaderContentCell<C>.buttonSize * 2 + 6)
        }
        .frame(height: ReaderContentCell<C>.buttonSize, alignment: .center)
        .offset(y: bottomAccessoryVerticalOffset)
        .foregroundStyle(.secondary)
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 6) {
                BookmarkButton(readerContent: item, hiddenIfUnbookmarked: true)
                    .labelStyle(.iconOnly)
                    .frame(
                        width: viewModel.forceShowBookmark ? ReaderContentCell<C>.buttonSize : 0,
                        height: ReaderContentCell<C>.buttonSize,
                        alignment: .bottom
                    )
                    .opacity(viewModel.forceShowBookmark ? 1 : 0)
                    .accessibilityHidden(!viewModel.forceShowBookmark)

                trailingMenuButton
                    .frame(height: ReaderContentCell<C>.buttonSize, alignment: .center)
            }
            .foregroundStyle(.secondary)
            .buttonStyle(.clearBordered)
            .controlSize(.small)
        }
        .buttonStyle(.clearBordered)
        .controlSize(.small)
        .animation(.easeInOut(duration: 0.2), value: isProgressVisible)
    }

    @ViewBuilder
    private func thumbnailView(
        for thumbnailChoice: ThumbnailChoice,
        edgeLength: CGFloat? = nil,
        contentHeight: CGFloat? = nil
    ) -> some View {
        let edgeLength = edgeLength ?? thumbnailEdgeLength
        let contentHeight = contentHeight ?? contentColumnHeight
        let physicalTargetWidth = max(1, edgeLength * 0.7)
        let physicalMaxHeight = edgeLength
        let physicalThumbnailMaxHeight = edgeLength == thumbnailEdgeLength
            ? physicalMediaThumbnailMaxHeight
            : physicalMaxHeight
        switch thumbnailChoice {
        case .image(let imageUrl):
            if appearance.isEbookStyle {
                Color.clear
                    .frame(
                        width: physicalTargetWidth,
                        height: contentHeight
                    )
                    .overlay {
                        ReaderImage(
                            imageUrl,
                            contentMode: .fit,
                            cacheRefreshIdentity: coverCacheRefreshIdentity,
                            thumbnailSize: CGSize(
                                width: physicalTargetWidth,
                                height: physicalThumbnailMaxHeight
                            ),
                            maxWidth: physicalTargetWidth,
                            maxHeight: physicalThumbnailMaxHeight,
                            onResolvedSize: { imageSize in
                                let width = readerImageAspectFitWidth(
                                    imageSize: imageSize,
                                    maximumWidth: physicalTargetWidth,
                                    maximumHeight: physicalThumbnailMaxHeight
                                )
                                guard abs(renderedPhysicalCoverWidth - width) >= 0.5 else { return }
                                renderedPhysicalCoverWidth = width
                            }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: thumbnailCornerRadius, style: .continuous))
                        .preference(
                            key: ReaderContentBookCoverRenderedWidthPreferenceKey.self,
                            value: renderedPhysicalCoverWidth
                        )
                        .onChange(of: coverCacheRefreshIdentity) { _ in
                            renderedPhysicalCoverWidth = 0
                        }
                    }
            } else {
                ReaderImage(
                    imageUrl,
                    cacheRefreshIdentity: coverCacheRefreshIdentity,
                    thumbnailSize: CGSize(width: edgeLength, height: edgeLength),
                    maxWidth: edgeLength,
                    minHeight: edgeLength,
                    maxHeight: edgeLength
                )
                .clipShape(RoundedRectangle(cornerRadius: thumbnailCornerRadius, style: .continuous))
            }
        case .icon(let iconURL):
            Color.clear
                .frame(
                    width: appearance.isEbookStyle ? physicalTargetWidth : edgeLength,
                    height: contentHeight
                )
                .overlay {
                    ReaderContentThumbnailTile(
                        content: .icon(iconURL, placeholder: fallbackInitial),
                        width: appearance.isEbookStyle ? physicalTargetWidth : edgeLength,
                        height: appearance.isEbookStyle ? physicalMaxHeight : edgeLength,
                        cornerRadius: thumbnailCornerRadius
                    )
                }
        case .initial:
            Color.clear
                .frame(
                    width: appearance.isEbookStyle ? physicalTargetWidth : edgeLength,
                    height: contentHeight
                )
                .overlay {
                    ReaderContentThumbnailTile(
                        content: .initial(fallbackInitial),
                        width: appearance.isEbookStyle ? physicalTargetWidth : edgeLength,
                        height: appearance.isEbookStyle ? physicalMaxHeight : edgeLength,
                        cornerRadius: thumbnailCornerRadius
                    )
                }
        case .symbol(let systemName):
            Color.clear
                .frame(
                    width: appearance.isEbookStyle ? physicalTargetWidth : edgeLength,
                    height: contentHeight
                )
                .overlay {
                    ReaderContentThumbnailTile(
                        content: .symbol(systemName),
                        width: appearance.isEbookStyle ? physicalTargetWidth : edgeLength,
                        height: appearance.isEbookStyle ? physicalMaxHeight : edgeLength,
                        cornerRadius: thumbnailCornerRadius
                    )
                }
        }
    }

    @ViewBuilder
    private var compactLayout: some View {
        HStack(alignment: .center, spacing: 10) {
            if let thumbnailChoice {
                thumbnailView(
                    for: thumbnailChoice,
                    edgeLength: compactThumbnailEdgeLength,
                    contentHeight: compactCellHeight
                )
                .accessibilityHidden(readerContentRowOwnsAccessibilityLabel)
            }

            VStack(alignment: .leading, spacing: 3) {
                sourceOrAuthorRow
                compactTitleRow
                progressMetadata
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(2)

            trailingMenuButton
                .frame(width: ReaderContentCell<C>.buttonSize, height: ReaderContentCell<C>.buttonSize, alignment: .center)
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
                    .accessibilityHidden(readerContentRowOwnsAccessibilityLabel)
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
                        .layoutPriority(3)
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: contentColumnHeight,
                        maxHeight: contentColumnHeight,
                        alignment: .top
                    )
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
                        .layoutPriority(3)
                    }
                    .frame(height: contentColumnHeight, alignment: .top)
                }
            }
        }
    }

    var body: some View {
//        GroupBox {
            Group {
                if usesCompactControlSize {
                    compactLayout
                } else {
                    regularLayout
                }
            }
//        }
        .frame(
            minWidth: appearance.maxCellHeight,
            minHeight: usesCompactControlSize ? compactCellHeight : (readerContentCellStyle == .card ? appearance.maxCellHeight : nil),
            idealHeight: usesCompactControlSize ? compactCellHeight : (hasVisibleThumbnail ? appearance.maxCellHeight : nil),
            maxHeight: usesCompactControlSize ? compactCellHeight : (readerContentCellStyle == .card ? appearance.maxCellHeight : nil)
        )
        .onHover { hovered in
            guard viewModel.forceShowBookmark != hovered else { return }
            viewModel.forceShowBookmark = hovered
        }
        .task(id: ReaderContentCellLoadTaskIdentity(
            loadIdentity: loadIdentity,
            retryRevision: loadRetryRevision,
            derivedStateRevision: derivedStateRevision
        )) {
            guard accountSessionSnapshot?.identity != .transitioning else {
                viewModel.suspendAccountDerivedState()
                return
            }
            do {
                loadFailureDescription = nil
                try await viewModel.load(item: item, includeSource: appearance.includeSource)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                loadFailureDescription = error.localizedDescription
                debugPrint("Failed to load reader-content cell", error)
            }
        }
        .task(id: ReaderContentCellHistoryIdentity(
            item: item,
            realmConfiguration: historyRealmConfiguration,
            accountSessionSnapshot: accountSessionSnapshot
        )) {
            guard accountSessionSnapshot?.identity != .transitioning else {
                viewModel.suspendHistoryObservation()
                return
            }
            let itemURL = item.url
            let realmConfiguration = historyRealmConfiguration
            do {
                try await viewModel.observeHistory(
                    for: itemURL,
                    realmConfiguration: realmConfiguration
                )
            } catch is CancellationError {
            } catch {
                debugPrint("Failed to observe reader-content history", error)
            }
        }
        .task(id: loadIdentity) {
            guard accountSessionSnapshot?.identity != .transitioning else { return }
            let itemURL = item.url
            await observeReaderContentCellDerivedStateUpdates(
                updates: { readerContentCellDerivedStateUpdates?(itemURL) },
                invalidate: { derivedStateRevision &+= 1 }
            )
        }
        .task(id: "\(item.compoundKey)|\(item.url.absoluteString)") {
            let url = item.url
            let contentID = item.compoundKey
            await observeReaderContentCellAnnotationStatus(
                updates: { readerContentCellAnnotationStatusUpdates?(url, contentID) },
                initialStatus: { await readerContentCellAnnotationStatusLoader(url, contentID) },
                publish: { annotationStatus = $0 }
            )
        }
        .onChange(of: item.compoundKey) { _ in
            resolvedContentFile = nil
            contentFileLookupStarted = false
        }
        // No provider-based onReceive; lists refresh via Realm publishers.
    }

    private var shouldAttemptContentFileLookup: Bool {
        guard !(item is ContentFile) else { return false }
        return item.url.isReaderFileURL || item.url.isEBookURL
    }

    private func kickOffContentFileLookupIfNeeded() {
        guard shouldAttemptContentFileLookup, !contentFileLookupStarted else { return }
        contentFileLookupStarted = true
        Task { @MainActor in
            resolvedContentFile = try? await lookupContentFile(for: item.url)
        }
    }

    @MainActor
    private func lookupContentFile(for url: URL) async throws -> ContentFile? {
        if let files = readerFileManager.files,
           let match = files.first(where: { !$0.isDeleted && $0.url == url }) {
            let realm = try await Realm(configuration: ReaderContentLoader.historyRealmConfiguration, actor: MainActor.shared)
            if let live = realm.object(ofType: ContentFile.self, forPrimaryKey: match.compoundKey), !live.isDeleted {
                return live
            }
        }

        let primaryKey = try await ReaderFileManager.contentFilePrimaryKey(for: url)
        guard let primaryKey else { return nil }
        let realm = try await Realm(configuration: ReaderContentLoader.historyRealmConfiguration, actor: MainActor.shared)
        let object = realm.object(ofType: ContentFile.self, forPrimaryKey: primaryKey)
        return (object?.isDeleted ?? true) ? nil : object
    }
}

public struct BookCoverImageView: View {
    public let imageURL: URL
    public let dimension: CGFloat
    @State private var renderedCoverWidth: CGFloat = 0

    public var body: some View {
        Color.clear
            .frame(width: dimension, height: dimension)
            .overlay {
                ReaderImage(
                    imageURL,
                    contentMode: .fit,
                    thumbnailSize: CGSize(width: dimension, height: dimension),
                    cornerRadius: dimension / 28,
                    onResolvedSize: { imageSize in
                        let width = readerImageAspectFitWidth(
                            imageSize: imageSize,
                            maximumWidth: dimension,
                            maximumHeight: dimension
                        )
                        guard abs(renderedCoverWidth - width) >= 0.5 else { return }
                        renderedCoverWidth = width
                    }
                )
                .aspectRatio(contentMode: .fit)
                .frame(
                    maxWidth: dimension,
                    maxHeight: dimension,
                    alignment: .center
                )
            }
            .preference(
                key: ReaderContentBookCoverRenderedWidthPreferenceKey.self,
                value: renderedCoverWidth
            )
            .onChange(of: imageURL) { _ in
                renderedCoverWidth = 0
            }
            .onChange(of: dimension) { _ in
                renderedCoverWidth = 0
            }
    }

    public init(imageURL: URL, dimension: CGFloat) {
        self.imageURL = imageURL
        self.dimension = dimension
    }

}

/// Rasterizes fallback initials once per visible text and pixel size. Keeping this
/// outside the SwiftUI tile makes the fallback decorative content rather than a
/// `Text` view, so it cannot participate in the surrounding cell's text layout.
@MainActor
enum ReaderContentInitialImageRenderer {
    static let cacheCountLimit = 128
    static let cacheTotalCostLimit = 4 * 1_024 * 1_024
    private static let maximumPixelDimension = 4_096

    private static let imageCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = cacheCountLimit
        cache.totalCostLimit = cacheTotalCostLimit
        return cache
    }()

    static func render(
        initial: String,
        dimension: CGFloat,
        displayScale: CGFloat
    ) -> CGImage? {
        guard !initial.isEmpty, dimension.isFinite, dimension > 0 else { return nil }
        let scale = displayScale.isFinite ? max(displayScale, 1) : 1
        let scaledDimension = dimension * scale
        guard scaledDimension.isFinite else { return nil }
        let boundedPixelDimension = min(CGFloat(maximumPixelDimension), max(1, scaledDimension.rounded(.up)))
        let pixelDimension = Int(boundedPixelDimension)
        let cacheKey = "\(initial)|\(pixelDimension)" as NSString
        if let cachedImage = imageCache.object(forKey: cacheKey) {
            return cachedImage
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelDimension,
            height: pixelDimension,
            bitsPerComponent: 8,
            bytesPerRow: pixelDimension * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let fontSize = CGFloat(pixelDimension) * 0.42
        guard let baseFont = CTFontCreateUIFontForLanguage(.system, fontSize, nil) else {
            return nil
        }
        let font = CTFontCreateCopyWithSymbolicTraits(
            baseFont,
            fontSize,
            nil,
            .boldTrait,
            .boldTrait
        ) ?? baseFont
        let attributedInitial = NSAttributedString(
            string: initial,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(gray: 1, alpha: 1),
            ]
        )
        let line = CTLineCreateWithAttributedString(attributedInitial)
        let glyphBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        context.textPosition = CGPoint(
            x: (CGFloat(pixelDimension) - glyphBounds.width) / 2 - glyphBounds.minX,
            y: (CGFloat(pixelDimension) - glyphBounds.height) / 2 - glyphBounds.minY
        )
        CTLineDraw(line, context)

        guard let image = context.makeImage() else { return nil }
        imageCache.setObject(
            image,
            forKey: cacheKey,
            cost: pixelDimension * pixelDimension * 4
        )
        return image
    }

    static func resetCacheForTesting() {
        imageCache.removeAllObjects()
    }
}

private struct ReaderContentThumbnailTile: View {
    enum Content {
        case icon(URL, placeholder: String)
        case initial(String)
        case symbol(String)
    }

    @Environment(\.displayScale) private var displayScale

    let content: Content
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            placeholderLayer
            if case let .icon(iconURL, _) = content {
                ReaderImage(
                    iconURL,
                    contentMode: .fit,
                    maxWidth: width * 0.7,
                    maxHeight: height * 0.7
                )
                .frame(width: width * 0.7, height: height * 0.7)
            }
            if case let .symbol(systemName) = content {
                Image(systemName: systemName)
                    .font(.system(size: min(width, height) * 0.34, weight: .semibold))
                    .foregroundStyle(placeholderForeground.opacity(0.95))
            }
        }
        .frame(width: width, height: height)
    }

    @ViewBuilder
    private var placeholderLayer: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(placeholderBackground)
            .overlay {
                if let letter = placeholderLetter {
                    initialImage(letter)
                }
            }
    }

    @ViewBuilder
    private func initialImage(_ initial: String) -> some View {
        if let image = ReaderContentInitialImageRenderer.render(
            initial: initial,
            dimension: min(width, height),
            displayScale: displayScale
        ) {
            Image(decorative: image, scale: displayScale)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: min(width, height), height: min(width, height))
                .foregroundStyle(placeholderForeground)
        }
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

    private var placeholderBackground: LinearGradient {
        let light = Color.secondary.opacity(0.18)
        let dark = Color.secondary.opacity(0.32)
        return LinearGradient(colors: [light, dark], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var placeholderForeground: Color {
        Color.secondary.opacity(0.9)
    }
}

// No NotificationCenter for list refresh; view models observe Realm and republish via Combine.

#if DEBUG
@MainActor
private final class ReaderContentCellPreviewStore: ObservableObject {
    let modalsModel = ReaderContentListModalsModel()

    let verticalImageEntry: FeedEntry
    let verticalPlainEntry: FeedEntry
    let horizontalImageEntry: FeedEntry
    let horizontalPlainEntry: FeedEntry

    let verticalImageAppearance = ReaderContentCellAppearance(
        maxCellHeight: 140,
        includeSource: true
    )

    let verticalPlainAppearance = ReaderContentCellAppearance(
        maxCellHeight: 140,
        alwaysShowThumbnails: false,
        includeSource: true
    )

    private let horizontalMaxHeight: CGFloat = 140 * (2.0 / 3.0)
    let verticalCardWidth: CGFloat = 360

    lazy var horizontalAppearance: ReaderContentCellAppearance = ReaderContentCellAppearance(
        maxCellHeight: horizontalMaxHeight,
        alwaysShowThumbnails: true,
        includeSource: true,
        thumbnailDimension: horizontalMaxHeight
    )

    var horizontalCardWidth: CGFloat { horizontalMaxHeight * 3 }

    init() {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: "ReaderContentCellPreview",
            objectTypes: [FeedEntry.self, Bookmark.self]
        )

        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        ReaderContentLoader.bookmarkRealmConfiguration = configuration

        let realm = try! Realm(configuration: configuration)

        let verticalImage = FeedEntry()
        verticalImage.compoundKey = "preview-vertical-image"
        verticalImage.url = URL(string: "https://example.com/articles/with-image")!
        verticalImage.title = "NHK Yasashii News Preview"
        verticalImage.author = "NHK"
        verticalImage.imageUrl = URL(string: "https://placehold.co/400x240.png?text=NHK+News")
        verticalImage.sourceIconURL = URL(string: "https://placehold.co/48x48.png?text=N")
        verticalImage.publicationDate = Calendar.current.date(byAdding: .day, value: -22, to: .now)

        let verticalPlain = FeedEntry()
        verticalPlain.compoundKey = "preview-vertical-plain"
        verticalPlain.url = URL(string: "https://example.com/articles/no-image")!
        verticalPlain.title = "Reading Practice Without Thumbnail"
        verticalPlain.author = "NHK"
        verticalPlain.publicationDate = Calendar.current.date(byAdding: .day, value: -6, to: .now)

        let horizontalImage = FeedEntry()
        horizontalImage.compoundKey = "preview-horizontal-image"
        horizontalImage.url = URL(string: "https://example.com/articles/horizontal-image")!
        horizontalImage.title = "Horizontal Card With Progress"
        horizontalImage.author = "NHK"
        horizontalImage.imageUrl = URL(string: "https://placehold.co/360x200.png?text=NHK")
        horizontalImage.sourceIconURL = URL(string: "https://placehold.co/48x48.png?text=N")
        horizontalImage.publicationDate = Calendar.current.date(byAdding: .day, value: -3, to: .now)

        let horizontalPlain = FeedEntry()
        horizontalPlain.compoundKey = "preview-horizontal-plain"
        horizontalPlain.url = URL(string: "https://example.com/articles/horizontal-plain")!
        horizontalPlain.title = "Horizontal Card Without Progress"
        horizontalPlain.author = "NHK"
        horizontalPlain.publicationDate = Calendar.current.date(byAdding: .day, value: -1, to: .now)

        let entries = [verticalImage, verticalPlain, horizontalImage, horizontalPlain]

        try! realm.write {
            realm.add(entries, update: .modified)

            for entry in entries {
                let bookmark = Bookmark()
                bookmark.compoundKey = entry.compoundKey
                bookmark.url = entry.url
                bookmark.title = entry.title
                bookmark.author = entry.author
                bookmark.imageUrl = entry.imageUrl
                bookmark.sourceIconURL = entry.sourceIconURL
                bookmark.publicationDate = entry.publicationDate
                bookmark.isDeleted = false
                realm.add(bookmark, update: .modified)
            }
        }

        self.verticalImageEntry = verticalImage
        self.verticalPlainEntry = verticalPlain
        self.horizontalImageEntry = horizontalImage
        self.horizontalPlainEntry = horizontalPlain

        let progress: [URL: (Float, Bool)] = [
            verticalImage.url: (0.35, false),
            horizontalImage.url: (0.65, false)
        ]

        ReaderContentReadingProgressLoader.readingProgressLoader = { url in
            progress[url]
        }

        let metadata: [URL: ReaderContentProgressMetadata] = [
            verticalImage.url: ReaderContentProgressMetadata(totalWordCount: 640, remainingTime: 1800),
            verticalPlain.url: ReaderContentProgressMetadata(totalWordCount: 520, remainingTime: 1400),
            horizontalImage.url: ReaderContentProgressMetadata(totalWordCount: 890, remainingTime: 2600),
            horizontalPlain.url: ReaderContentProgressMetadata(totalWordCount: 430, remainingTime: 900)
        ]

        ReaderContentReadingProgressLoader.readingProgressMetadataLoader = { url in
            metadata[url]
        }
    }
}

private struct ReaderContentCellPreviewGallery: View {
    @StateObject private var store = ReaderContentCellPreviewStore()
    @StateObject private var readerFileManager = ReaderFileManager()
    private let previewMenuOptions: (FeedEntry) -> AnyView = { _ in
        AnyView(
            Button {
                debugPrint("Preview action tapped")
            } label: {
                Label("Preview Action", systemImage: "star")
            }
        )
    }

    var body: some View {
        StackList {
            variant("Vertical - Image - Progress", targetWidth: store.verticalCardWidth) {
                ReaderContentCell(
                    item: store.verticalImageEntry,
                    appearance: store.verticalImageAppearance,
                    customMenuOptions: previewMenuOptions
                )
            }

            variant("Vertical - No Image - No Progress", targetWidth: store.verticalCardWidth) {
                ReaderContentCell(
                    item: store.verticalPlainEntry,
                    appearance: store.verticalPlainAppearance,
                    customMenuOptions: previewMenuOptions
                )
            }

            variant("Horizontal - Image - Progress", targetWidth: store.horizontalCardWidth) {
                ReaderContentCell(
                    item: store.horizontalImageEntry,
                    appearance: store.horizontalAppearance,
                    customMenuOptions: previewMenuOptions
                )
            }

            variant("Horizontal - No Image - No Progress", targetWidth: store.horizontalCardWidth) {
                ReaderContentCell(
                    item: store.horizontalPlainEntry,
                    appearance: store.horizontalAppearance,
                    customMenuOptions: previewMenuOptions
                )
            }
        }
//        .groupBoxStyle(.groupedStackList)
        .stackListStyle(.grouped)
        .stackListInterItemSpacing(18)
        .environmentObject(store.modalsModel)
        .environmentObject(readerFileManager)
        .frame(maxWidth: 420)
        .padding()
    }

    private func variant<Content: View>(_ title: String, targetWidth: CGFloat?, @ViewBuilder content: () -> Content) -> StackListRowItem {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            GroupBox {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: targetWidth, alignment: .leading)
        }
        .stackListRowSeparator(.hidden)
    }
}

struct ReaderContentCell_Previews: PreviewProvider {
    static var previews: some View {
        ReaderContentCellPreviewGallery()
            .previewLayout(.sizeThatFits)
    }
}
#endif
