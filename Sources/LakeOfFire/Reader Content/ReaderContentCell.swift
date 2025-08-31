import SwiftUI
import RealmSwift
import RealmSwiftGaps
import LakeOfFire
import LakeKit
import Combine
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
                try Task.checkCancellation()

                let sourceURL = item.url
                var sourceTitle = sourceURL.host
                // TODO: Store and get site names from OpenGraph
                var sourceIconURL: URL?
                
                if includeSource, sourceURL.isHTTP {
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
                    }
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
    public init(
        maxCellHeight: CGFloat,
        alwaysShowThumbnails: Bool = true,
        isEbookStyle: Bool = false,
        includeSource: Bool = false
    ) {
        self.maxCellHeight = maxCellHeight
        self.alwaysShowThumbnails = alwaysShowThumbnails
        self.isEbookStyle = isEbookStyle
        self.includeSource = includeSource
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
        includeSource: Bool = false
    ) -> some View {
        let appearance = ReaderContentCellAppearance(
            maxCellHeight: maxCellHeight,
            alwaysShowThumbnails: alwaysShowThumbnails,
            isEbookStyle: isEbookStyle,
            includeSource: includeSource
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
    
    var scaledImageWidth: CGFloat { appearance.maxCellHeight }
    
    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel
    
    @ScaledMetric(relativeTo: .caption) private var sourceIconSize = 14
    @ScaledMetric private var progressViewPaddingBottom: CGFloat = 32 / 2
    @StateObject private var viewModel = ReaderContentCellViewModel<C>()
    
    private let padding: CGFloat = 8
    
    private var buttonSize: CGFloat {
        return ReaderContentCell<C>.buttonSize
    }
    
    private var isProgressVisible: Bool {
        if let readingProgressFloat = viewModel.readingProgress, readingProgressFloat > 0 {
            return true
        }
        return false
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            //            if let imageUrl = viewModel.imageURL {
            //                if appearance.isEbookStyle {
            //                    BookThumbnail(imageURL: imageUrl, scaledImageWidth: scaledImageWidth, cellHeight: appearance.maxCellHeight)
            ////                        .frame(maxWidth: scaledImageWidth, maxHeight: cellHeight)
            //                } else {
            //                    ReaderImage(imageUrl, maxWidth: scaledImageWidth, minHeight: appearance.maxCellHeight, maxHeight: appearance.maxCellHeight)
            //                        .clipShape(RoundedRectangle(cornerRadius: scaledImageWidth / 16))
            //                }
            //            }
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
                        .padding(.leading, 1)
                        .padding(.bottom, 3)
                    }
                    
                    Text(viewModel.title)
                        .font(.headline)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundColor((viewModel.isFullArticleFinished ?? false) ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(.trailing, padding)

                Spacer(minLength: 0)
                
                HStack(alignment: .bottom, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            if let publicationDate = viewModel.humanReadablePublicationDate {
                                Text("\(publicationDate)")
                                    .lineLimit(1)
                                    .font(.footnote)
                            }
                            if let item = item as? ContentFile {
                                CloudDriveSyncStatusView(item: item)
                                    .labelStyle(.iconOnly)
                                    .font(.callout)
                            }
                        }
                        .foregroundStyle(.secondary)
                        
                        if let readingProgressFloat = viewModel.readingProgress, isProgressVisible {
                            ProgressView(value: min(1, readingProgressFloat))
                                .tint((viewModel.isFullArticleFinished ?? false) ? Color("Green") : .secondary)
                        }
                    }
#if os(macOS)
                    .padding(.bottom, progressViewPaddingBottom - (isProgressVisible ? 10 : 5))
#elseif os(iOS)
                    .padding(.bottom, progressViewPaddingBottom - (isProgressVisible ? 3 : 7))
#endif
                    
                    Spacer(minLength: 0)
                    
                    HStack(alignment: .center, spacing: 0) {
                        BookmarkButton(readerContent: item, hiddenIfUnbookmarked: true)
                            .labelStyle(.iconOnly)
                            .padding(.leading, 2)

                        // Show menu if item is deletable or caller provided custom menu items
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
                
                                // Inject any custom menu options provided by caller
                                if let customMenuOptions {
                                    customMenuOptions(self.item)
                                }

                                // Continue Reading controls are injected via customMenuOptions.

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
                            //                        .buttonStyle(.borderless)
                            //                        .buttonStyle(.plain)
                            //#if os(macOS)
                            //                        .offset(y: -(buttonSize / 2.5)) // IDK why
                            //                                                        //                        .offset(y: 3)
                            //#endif
                        }
                    }
                    .buttonStyle(.clearBordered)
                    .foregroundStyle(.secondary)
                    .controlSize(.mini)
                    .padding(.trailing, padding / 2)
                }
            }
            .padding(.leading, padding)
            .padding(.top, padding)
            .frame(maxHeight: appearance.maxCellHeight)
        }
        .frame(
            minWidth: appearance.maxCellHeight,
            idealHeight: appearance.alwaysShowThumbnails ? appearance.maxCellHeight : (viewModel.imageURL == nil ? nil : appearance.maxCellHeight)
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
