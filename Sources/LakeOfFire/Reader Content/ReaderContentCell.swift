import SwiftUI
import Foundation
import RealmSwift
import RealmSwiftGaps
import LakeOfFire
import LakeKit
import Combine

private let readerContentCellWordCountFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter
}()
// Do not import ManabiCommon from LakeOfFire. Integrations happen via environment.

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
    @Published var humanReadablePublicationDate: String?
    @Published var imageURL: URL?
    @Published var sourceIconURL: URL?
    @Published var sourceTitle: String?
    @Published var totalWordCount: Int?
    @Published var remainingTime: TimeInterval?
    // Continue Reading menu is driven by an injected provider in the environment.

    init() { }
    
    @MainActor
    func load(
        item: C,
        includeSource: Bool
    ) async throws {
        debugPrint("# loading", item.url.lastPathComponent)
        
        guard let config = item.realm?.configuration else { return }
        let pk = item.compoundKey
        let imageURL = try await item.imageURLToDisplay()
        try await { @ReaderContentCellActor [weak self] in
            guard let self else { return }
            let realm = try await Realm.open(configuration: config)
            if let item = realm.object(ofType: C.self, forPrimaryKey: pk) {
                try Task.checkCancellation()
                let title = item.titleForDisplay
                let humanReadablePublicationDate = item.displayPublicationDate ? item.humanReadablePublicationDate : nil
                let progressResult = try await ReaderContentReadingProgressLoader.readingProgressLoader?(item.url)
                let metadataResult = try await ReaderContentReadingProgressLoader.readingProgressMetadataLoader?(item.url)
                try Task.checkCancellation()

                let sourceURL = item.url
                var sourceTitle: String?
                // TODO: Store and get site names from OpenGraph
                var sourceIconURL: URL?
                
                if includeSource {
                    if sourceURL.isSnippetURL {
                        sourceTitle = "Snippet"
                    } else if sourceURL.isHTTP {
                        sourceTitle = sourceURL.host
                        let readerRealm = try await Realm.open(configuration: ReaderContentLoader.feedEntryRealmConfiguration)
                        try Task.checkCancellation()
                        
                        if let feedEntry = item as? FeedEntry ?? readerRealm.objects(FeedEntry.self).filter(NSPredicate(format: "url == %@", sourceURL.absoluteString as CVarArg)).first, let feed = feedEntry.getFeed() {
                            try Task.checkCancellation()
                            sourceTitle = feed.title
                            sourceIconURL = feed.iconUrl
                        } else if let host = sourceURL.host {
                            sourceTitle = host.removingPrefix("www.")
                            sourceIconURL = item.sourceIconURL
                        }
                    }
                }
                
                let sourceIconURLChoice = sourceIconURL
                let sourceTitleChoice = sourceTitle
                
                try await { @MainActor [weak self] in
                    guard let self else { return }
                    try Task.checkCancellation()
                    self.title = title
                    self.imageURL = imageURL
                    self.humanReadablePublicationDate = humanReadablePublicationDate
                    self.sourceIconURL = sourceIconURLChoice
                    self.sourceTitle = sourceTitleChoice
                    if let (progress, finished) = progressResult {
                        self.readingProgress = progress
                        self.isFullArticleFinished = finished
                    } else {
                        self.readingProgress = nil
                        self.isFullArticleFinished = nil
                    }
                    self.totalWordCount = metadataResult?.totalWordCount
                    self.remainingTime = metadataResult?.remainingTime
                }()
                // Continue Reading state is provided externally via environment provider.
            }
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

extension ReaderContentProtocol {
    @ViewBuilder func readerContentCellView(
        appearance: ReaderContentCellAppearance
    ) -> some View {
        ReaderContentCell(
            item: self,
            appearance: appearance
        )
    }
    
    // Overload that allows injecting custom menu options.
    @ViewBuilder func readerContentCellView(
        appearance: ReaderContentCellAppearance,
        customMenuOptions: ((Self) -> AnyView)?
    ) -> some View {
        ReaderContentCell(
            item: self,
            appearance: appearance,
            customMenuOptions: customMenuOptions
        )
    }
    
    // Back-compat convenience
    @ViewBuilder func readerContentCellView(
        maxCellHeight: CGFloat,
        alwaysShowThumbnails: Bool = true,
        isEbookStyle: Bool = false,
        includeSource: Bool = false,
        thumbnailDimension: CGFloat? = nil,
        thumbnailCornerRadius: CGFloat? = nil
    ) -> some View {
        let appearance = ReaderContentCellAppearance(
            maxCellHeight: maxCellHeight,
            alwaysShowThumbnails: alwaysShowThumbnails,
            isEbookStyle: isEbookStyle,
            includeSource: includeSource,
            thumbnailDimension: thumbnailDimension,
            thumbnailCornerRadius: thumbnailCornerRadius
        )
        readerContentCellView(appearance: appearance)
    }
}

struct CloudDriveSyncStatusView: View { //, Equatable {
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
        if let title = title, let systemImage = systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text("")
                .hidden()
        }
    }
}

struct ReaderContentCell<C: ReaderContentProtocol & ObjectKeyIdentifiable>: View { //, Equatable {
    @ObservedRealmObject var item: C
    var appearance: ReaderContentCellAppearance
    // Optional custom menu items to include in the trailing menu.
    // Using AnyView avoids templating this struct with another generic.
    var customMenuOptions: ((C) -> AnyView)? = nil
    
    static var buttonSize: CGFloat {
        return 26
    }
    
    private var thumbnailEdgeLength: CGFloat {
        let base = appearance.thumbnailDimension ?? appearance.maxCellHeight
        return max(1, base)
    }
    
    @Environment(\.stackListGroupBoxContentInsets) private var stackListContentInsets

    private var thumbnailCornerRadius: CGFloat {
        if let customCornerRadius = appearance.thumbnailCornerRadius {
            return customCornerRadius
        }
        let cardCornerRadius: CGFloat = 20
        return max(0, cardCornerRadius - stackListContentInsets.leading)
    }
    
    private var contentColumnHeight: CGFloat? {
        if let dimension = appearance.thumbnailDimension {
            return dimension
        }
        if viewModel.imageURL != nil || item.imageUrl != nil {
            return appearance.maxCellHeight
        }
        return nil
    }

    private var titleLineLimit: Int {
        if appearance.maxCellHeight >= 150 { return 3 }
        if appearance.maxCellHeight >= 110 { return 2 }
        return 1
    }
    
    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel
    
    @ScaledMetric(relativeTo: .caption) private var sourceIconSize = 14
    @StateObject private var viewModel = ReaderContentCellViewModel<C>()
    @State private var menuTrailingPadding: CGFloat = 0

    private var buttonSize: CGFloat {
        return ReaderContentCell<C>.buttonSize
    }

    private var contentLeadingInset: CGFloat {
        appearance.includeSource ? 1 : 0
    }

    private var isProgressVisible: Bool {
        if let readingProgressFloat = viewModel.readingProgress, readingProgressFloat > 0 {
            return true
        }
        return false
    }
    
    private var metadataText: String? {
        Self.formatMetadata(wordCount: viewModel.totalWordCount, remainingTime: viewModel.remainingTime)
    }
    
    private static func formatMetadata(wordCount: Int?, remainingTime: TimeInterval?) -> String? {
        var parts: [String] = []
        if let wordCount, wordCount > 0 {
            let value = readerContentCellWordCountFormatter.string(from: NSNumber(value: wordCount)) ?? "\(wordCount)"
            parts.append("\(value) words")
        }
        if let remainingTime, remainingTime > 1 {
            if let formatted = ReaderDateFormatter.shortDurationString(from: remainingTime) {
                parts.append("\(formatted) remaining")
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " • ")
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let imageUrl = viewModel.imageURL {
                if appearance.isEbookStyle {
                    BookThumbnail(imageURL: imageUrl, scaledImageWidth: thumbnailEdgeLength, cellHeight: appearance.maxCellHeight)
                    //                        .frame(maxWidth: scaledImageWidth, maxHeight: cellHeight)
                } else {
                    ReaderImage(
                        imageUrl,
                        maxWidth: thumbnailEdgeLength,
                        minHeight: thumbnailEdgeLength,
                        maxHeight: thumbnailEdgeLength
                    )
                        .clipShape(RoundedRectangle(cornerRadius: thumbnailCornerRadius, style: .continuous))
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if appearance.includeSource {
                        HStack(alignment: .center) {
                            if let sourceIconURL = viewModel.sourceIconURL {
                                ReaderContentSourceIconImage(
                                    sourceIconURL: sourceIconURL,
                                    iconSize: sourceIconSize
                                )
                                .opacity((viewModel.isFullArticleFinished ?? false) ? 0.75 : 1)
                            }
                            if let sourceTitle = viewModel.sourceTitle {
                                Text(sourceTitle)
                                    .lineLimit(1)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
//                        .padding(.leading, 1)
                    }

                    Text(viewModel.title)
                        .font(.headline)
                        .lineLimit(titleLineLimit)
                        .multilineTextAlignment(.leading)
                        .foregroundColor((viewModel.isFullArticleFinished ?? false) ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .layoutPriority(1)
                }
//                .padding(.trailing, 4)

                Spacer(minLength: 4)

                VStack(spacing: 0) {
                    if let readingProgressFloat = viewModel.readingProgress, isProgressVisible {
                        HStack(spacing: 8) {
                            ProgressView(value: min(1, readingProgressFloat))
                                .progressViewStyle(LinearProgressViewStyle())
                                .tint((viewModel.isFullArticleFinished ?? false) ? Color("PaletteGreen") : .secondary)
                                .frame(maxWidth: .infinity)
                            if let metadataText {
                                Text(metadataText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .allowsTightening(true)
                            }
                        }
                        .padding(.leading, contentLeadingInset)
                    }
                    
                    HStack(alignment: .center, spacing: 6) {
                        HStack(spacing: 6) {
                            if let publicationDate = viewModel.humanReadablePublicationDate {
                                Text("\(publicationDate)")
                                    .lineLimit(1)
                                    .allowsTightening(true)
                                    .minimumScaleFactor(0.9)
                                    .font(.footnote)
                                    .layoutPriority(2)
                            }
                            if let item = item as? ContentFile {
                                CloudDriveSyncStatusView(item: item)
                                    .labelStyle(.iconOnly)
                                    .font(.callout)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.secondary)
                        .padding(.leading, contentLeadingInset)
                        
                        HStack(alignment: .center, spacing: 0) {
                            BookmarkButton(readerContent: item, hiddenIfUnbookmarked: true)
                                .labelStyle(.iconOnly)
                            
                            let deletable = (self.item as? (any DeletableReaderContent))
                            let shouldShowMenu = deletable != nil || customMenuOptions != nil
                            if shouldShowMenu {
                                Menu {
                                    if let item = self.item as? ContentFile {
                                        CloudDriveSyncStatusView(item: item)
                                            .labelStyle(.titleAndIcon)
                                        Divider()
                                    }
                                    
                                    AnyView(self.item.bookmarkButtonView())
                                    
                                    if let customMenuOptions {
                                        customMenuOptions(self.item)
                                    }
                                    
                                    if let deletable {
                                        Divider()
                                        Button(role: .destructive) {
                                            readerContentListModalsModel.confirmDeletionOf = [deletable]
                                            readerContentListModalsModel.confirmDelete = true
                                        } label: {
                                            Label(deletable.deleteActionTitle, systemImage: "trash")
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
                            }
                        }
                        .buttonStyle(.clearBordered)
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
//                        .padding(.trailing, 4)
                        .offset(x: menuTrailingPadding)
                    }
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
                    //                .padding(.trailing, -menuTrailingPadding)
                    .offset(y: menuTrailingPadding)
                    .onPreferenceChange(ClearBorderedButtonTrailingPaddingKey.self) { menuTrailingPadding = $0 }
                    // Keep menu and footer aligned without shifting content outside the card bounds.
                }
            }
            .frame(height: contentColumnHeight, alignment: .top)
        }
        .frame(
            minWidth: appearance.maxCellHeight,
            idealHeight: appearance.alwaysShowThumbnails ? appearance.maxCellHeight : ((viewModel.imageURL ?? item.imageUrl) == nil ? nil : appearance.maxCellHeight)
        )
        .onHover { hovered in
            viewModel.forceShowBookmark = hovered
        }
        .onAppear {
            Task { @MainActor in
                try? await viewModel.load(
                    item: item,
                    includeSource: appearance.includeSource
                )
            }
        }
        .onChange(of: item.imageUrl) { newImageURL in
            guard newImageURL != viewModel.imageURL else { return }
            Task { @MainActor in
                viewModel.imageURL = try await item.imageURLToDisplay()
            }
        }
        // No provider-based onReceive; lists refresh via Realm publishers.
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
        .stackListStyle(.grouped)
        .stackListInterItemSpacing(18)
        .environmentObject(store.modalsModel)
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
            .stackListGroupBoxContentInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            .stackListGroupBoxContentSpacing(12)
            .groupBoxStyle(.groupedStackList)
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
