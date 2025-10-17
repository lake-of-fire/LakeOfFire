import SwiftUI
import SwiftUIWebView
import RealmSwift
import RealmSwiftGaps
import SwiftUtilities
import Pow
import LakeKit

fileprivate struct ReaderContentCellButtonStyle: ButtonStyle {
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

fileprivate struct ReaderContentInnerHorizontalListItem<C: ReaderContentProtocol>: View {
    var content: C
    let includeSource: Bool
    let maxCellHeight: CGFloat
    let customMenuOptions: ((C) -> AnyView)?
    let contentSelection: Binding<String?>
    let onContentSelected: ((C) -> Void)?
    
    private enum Layout {
        static var cardCornerRadius: CGFloat { 20 }
        static var contentPadding: CGFloat { 16 }
    }

    @StateObject var cloudDriveSyncStatusModel = CloudDriveSyncStatusModel()
    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel
    @Environment(\.stackListStyle) private var stackListStyle
    
    private var cardWidth: CGFloat { maxCellHeight * 2.5 }

    var body: some View {
        Button {
            let selection = content.compoundKey
            contentSelection.wrappedValue = selection
            if content.url.matchesReaderURL(readerContent.pageURL) {
                Task { @MainActor in
                    if contentSelection.wrappedValue == selection {
                        contentSelection.wrappedValue = nil
                    }
                }
                return
            }
            if let handler = onContentSelected {
                handler(content)
                Task { @MainActor in
                    if contentSelection.wrappedValue == selection {
                        contentSelection.wrappedValue = nil
                    }
                }
                return
            }
            Task { @MainActor in
                do {
                    try await navigator.load(
                        content: content,
                        readerModeViewModel: readerModeViewModel
                    )
                } catch {
                    debugPrint("Failed to load reader content from horizontal list", error)
                }
                if contentSelection.wrappedValue == selection {
                    contentSelection.wrappedValue = nil
                }
            }
        } label: {
            GroupBox {
                VStack(spacing: 0) {
                    if let customMenuOptions {
                        content.readerContentCellView(
                            appearance: ReaderContentCellAppearance(
                                maxCellHeight: maxCellHeight,
                                alwaysShowThumbnails: true,
                                isEbookStyle: false,
                                includeSource: includeSource,
                                thumbnailDimension: maxCellHeight
                            ),
                            customMenuOptions: customMenuOptions
                        )
                    } else {
                        content.readerContentCellView(
                            appearance: ReaderContentCellAppearance(
                                maxCellHeight: maxCellHeight,
                                alwaysShowThumbnails: true,
                                isEbookStyle: false,
                                includeSource: includeSource,
                                thumbnailDimension: maxCellHeight
                            )
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .groupBoxStyle(.groupedStackList)
            .stackListGroupBoxContentInsets(EdgeInsets(top: 11, leading: 11, bottom: 11, trailing: 11))
//            .padding(16)
//            .background(cardBackground)
//            .contentShape(RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous))
//#if os(macOS)
//            .overlay {
//                RoundedRectangle(cornerRadius: Layout.cardCornerRadius)
//                    .stroke(.secondary.opacity(0.2))
//                    .shadow(radius: 5)
//            }
//#endif
            //            )
            //                .background(Color.white.opacity(0.00000001)) // Clickability
            //                            .frame(maxWidth: max(155, min(maxWidth, viewWidth)))
            .frame(width: cardWidth)
            //            .frame(width: 275, height: maxCellHeight - (padding * 2))
            //            .background(Color.primary.colorInvert())
            //                .background(.regularMaterial)
            //                .background(.secondary.opacity(0.09))
        }
        //        .frame(width: 275, height: maxCellHeight - (padding * 2))
        //                    .buttonStyle(ReaderContentCellButtonStyle())
        .buttonStyle(.borderless)
        .tint(.secondary)
        //        .background(.cyan)
        //                    .padding(.vertical, 4)
        //                    .padding(.horizontal, 8)
        //        //                    .id(feedEntry.compoundKey)
        //        .contextMenu {
        //            if let entry = content as? (any DeletableReaderContent) {
        //                Button(role: .destructive) {
        //                    readerContentListModalsModel.confirmDeletionOf = entry
        //                    readerContentListModalsModel.confirmDelete = true
        //                } label: {
        //                    Label(entry.deleteActionTitle, systemImage: "trash")
        //                }
        //            }
        //        }
        .environmentObject(cloudDriveSyncStatusModel)
        .task { @MainActor in
            if let item = content as? ContentFile {
                await cloudDriveSyncStatusModel.refreshAsync(item: item)
            }
        }
        //.enableInjection()
    }

    //@ObserveInjection var forceRedraw

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
            .fill(stackListStyle == .grouped ? Color.stackListCardBackgroundGrouped : Color.stackListCardBackgroundPlain)
    }

    init(
        content: C,
        includeSource: Bool,
        maxCellHeight: CGFloat,
        customMenuOptions: ((C) -> AnyView)? = nil,
        contentSelection: Binding<String?>,
        onContentSelected: ((C) -> Void)? = nil
    ) {
        self.content = content
        self.includeSource = includeSource
        self.maxCellHeight = maxCellHeight
        self.customMenuOptions = customMenuOptions
        self.contentSelection = contentSelection
        self.onContentSelected = onContentSelected
    }
}

fileprivate struct ReaderContentInnerHorizontalList<C: ReaderContentProtocol>: View {
    var filteredContents: [C]
    let includeSource: Bool
    let customMenuOptions: ((C) -> AnyView)?
    let contentSelection: Binding<String?>
    let onContentSelected: ((C) -> Void)?
    
    @ScaledMetric(relativeTo: .headline) private var maxCellHeight: CGFloat = 130
    //    @State private var viewWidth: CGFloat = 0
    
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 15) {
                ForEach(filteredContents, id: \.compoundKey) { (content: C) in
                    ReaderContentInnerHorizontalListItem(
                        content: content,
                        includeSource: includeSource,
                        maxCellHeight: maxCellHeight,
                        customMenuOptions: customMenuOptions,
                        contentSelection: contentSelection,
                        onContentSelected: onContentSelected
                    )
                }
                //                .headerProminence(.increased)
            }
            .frame(minHeight: maxCellHeight)
            .applyStackListGroupBoxStyle(.grouped)
            //            .fixedSize()
            //            .padding(.horizontal)
        }
        .modifier {
            if #available(iOS 17, macOS 14, *) {
                $0.scrollClipDisabled()
            } else { $0 }
        }
        //        .geometryReader { geometry in
        //            Task { @MainActor in
        //                if viewWidth != geometry.size.width {
        //                    viewWidth = geometry.size.width
        //                }
        //            }
        //        }
        //.enableInjection()
    }
    
    //@ObserveInjection var forceRedraw
    
    init(
        filteredContents: [C],
        includeSource: Bool,
        customMenuOptions: ((C) -> AnyView)? = nil,
        contentSelection: Binding<String?>,
        onContentSelected: ((C) -> Void)? = nil
    ) {
        self.filteredContents = filteredContents
        self.includeSource = includeSource
        self.customMenuOptions = customMenuOptions
        self.contentSelection = contentSelection
        self.onContentSelected = onContentSelected
    }
}

public struct ReaderContentHorizontalList<C: ReaderContentProtocol, EmptyState: View>: View {
    let contents: [C]
    let includeSource: Bool
    var contentSelection: Binding<String?>
    let emptyStateView: () -> EmptyState
    let customMenuOptions: ((C) -> AnyView)?
    let onContentSelected: ((C) -> Void)?
    
    @StateObject var viewModel = ReaderContentListViewModel<C>()
    
    let contentSortAscending = false
    var contentFilter: (@ReaderContentListActor (Int, C) async throws -> Bool) = { @ReaderContentListActor _, _ in return true }
    //    @State var sortOrder = [KeyPathComparator(\ReaderContentType.publicationDate, order: .reverse)] //KeyPathComparator(\TrackedWord.lastReadAtOrEpoch, order: .reverse)]
    //    var sortOrder = [KeyPathComparator(\(any ReaderContentProtocol).publicationDate, order: .reverse)] //KeyPathComparator(\TrackedWord.lastReadAtOrEpoch, order: .reverse)]
    var sortOrder = ReaderContentSortOrder.publicationDate
    
    public var body: some View {
        ZStack {
            if viewModel.showLoadingIndicator || !viewModel.filteredContents.isEmpty {
                ReaderContentInnerHorizontalList(
                    filteredContents: viewModel.filteredContents,
                    includeSource: includeSource,
                    customMenuOptions: customMenuOptions,
                    contentSelection: contentSelection,
                    onContentSelected: onContentSelected
                )
            }
            
            if !viewModel.showLoadingIndicator,
               viewModel.filteredContents.isEmpty {
                emptyStateView()
            }
            
            if viewModel.showLoadingIndicator {
                ProgressView()
                    .controlSize(.small)
                    .delayedAppearance()
            }
        }
        .task { @MainActor in
            //                await Task { @RealmBackgroundActor in
            //                    try? await viewModel.load(contents: ReaderContentLoader.fromMainActor(contents: contents) as? [C] ?? [], contentFilter: contentFilter, sortOrder: sortOrder)
            try? await viewModel.load(
                contents: contents,
                contentFilter: contentFilter,
                sortOrder: sortOrder
            )
            //                }.value
        }
        .onChange(of: contents, debounceTime: 0.1) { contents in
            Task { @MainActor in
                try? await viewModel.load(
                    contents: contents,
                    contentFilter: contentFilter,
                    sortOrder: sortOrder
                )
                //                    try? await viewModel.load(contents: ReaderContentLoader.fromMainActor(contents: contents) as? [C] ?? [], contentFilter: contentFilter, sortOrder: sortOrder)
            }
        }
        //.enableInjection()
    }
    
    //@ObserveInjection var forceRedraw
    
    /// Initializer with a view builder for the empty state (required).
    public init(
        contents: [C],
        contentFilter: ((Int, C) async throws -> Bool)? = nil,
        sortOrder: ReaderContentSortOrder? = nil,
        includeSource: Bool,
        contentSelection: Binding<String?>,
        customMenuOptions: ((C) -> AnyView)? = nil,
        onContentSelected: ((C) -> Void)? = nil,
        @ViewBuilder emptyStateView: @escaping () -> EmptyState
    ) {
        self.contents = contents
        if let contentFilter = contentFilter {
            self.contentFilter = contentFilter
        }
        if let sortOrder = sortOrder {
            self.sortOrder = sortOrder
        }
        self.includeSource = includeSource
        self.contentSelection = contentSelection
        self.customMenuOptions = customMenuOptions
        self.onContentSelected = onContentSelected
        self.emptyStateView = { emptyStateView() }
    }
}

#if DEBUG
@MainActor
private final class ReaderContentHorizontalListPreviewStore: ObservableObject {
    let modalsModel = ReaderContentListModalsModel()
    let readerContent = ReaderContent()
    let readerModeViewModel = ReaderModeViewModel()

    let entries: [FeedEntry]
    let maxCellHeight: CGFloat = 110

    var cardWidth: CGFloat { maxCellHeight * 2.25 }

    init() {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: "ReaderContentHorizontalListPreview",
            objectTypes: [FeedEntry.self, Bookmark.self]
        )

        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        ReaderContentLoader.bookmarkRealmConfiguration = configuration

        let realm = try! Realm(configuration: configuration)

        let recentArticle = FeedEntry()
        recentArticle.compoundKey = "preview-horizontal-recent"
        recentArticle.url = URL(string: "https://example.com/articles/fresh")!
        recentArticle.title = "Fresh Article With Thumbnail"
        recentArticle.author = "Asahi"
        recentArticle.imageUrl = URL(string: "https://placehold.co/360x200.png?text=Asahi")
        recentArticle.sourceIconURL = URL(string: "https://placehold.co/48x48.png?text=A")
        recentArticle.publicationDate = Calendar.current.date(byAdding: .hour, value: -6, to: .now)

        let olderArticle = FeedEntry()
        olderArticle.compoundKey = "preview-horizontal-older"
        olderArticle.url = URL(string: "https://example.com/articles/older")!
        olderArticle.title = "Older Article Without Image"
        olderArticle.author = "Mainichi"
        olderArticle.publicationDate = Calendar.current.date(byAdding: .day, value: -2, to: .now)
        olderArticle.displayPublicationDate = true

        let longformArticle = FeedEntry()
        longformArticle.compoundKey = "preview-horizontal-longform"
        longformArticle.url = URL(string: "https://example.com/articles/longform")!
        longformArticle.title = "Longform Piece Highlighting Bookmark State"
        longformArticle.author = "NHK"
        longformArticle.imageUrl = URL(string: "https://placehold.co/360x200.png?text=NHK")
        longformArticle.sourceIconURL = URL(string: "https://placehold.co/48x48.png?text=N")
        longformArticle.publicationDate = Calendar.current.date(byAdding: .day, value: -7, to: .now)

        let entries = [recentArticle, olderArticle, longformArticle]

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

        let progress: [URL: (Float, Bool)] = [
            recentArticle.url: (0.2, false),
            longformArticle.url: (0.9, true)
        ]

        ReaderContentReadingProgressLoader.readingProgressLoader = { url in
            progress[url]
        }

        readerContent.content = entries.first
        readerContent.pageURL = entries.first?.url ?? URL(string: "https://example.com")!

        self.entries = entries
    }
}

private struct ReaderContentHorizontalListPreviewGallery: View {
    @StateObject private var store = ReaderContentHorizontalListPreviewStore()
    @State private var contentSelection: String? = nil

    private let previewMenuOptions: (FeedEntry) -> AnyView = { entry in
        AnyView(
            Button {
                debugPrint("Preview menu tapped for", entry.title)
            } label: {
                Label("Preview Menu", systemImage: "ellipsis.circle")
            }
        )
    }
    
    var body: some View {
        StackList {
            StackSection("Horizontal List - Scrollable") {
                ReaderContentHorizontalList(
                    contents: store.entries,
                    includeSource: true,
                    contentSelection: $contentSelection,
                    customMenuOptions: previewMenuOptions
                ) {
                    Text("No Items")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .foregroundStyle(.secondary)
                }
                .frame(width: store.cardWidth * 1.9, height: store.maxCellHeight + 64)
            }
        }
        .stackListStyle(.grouped)
        .stackListInterItemSpacing(18)
        .environmentObject(store.modalsModel)
        .environmentObject(store.readerContent)
        .environmentObject(store.readerModeViewModel)
//        .frame(maxWidth: store.cardWidth * 2.2)
//        .padding()
    }
}

struct ReaderContentHorizontalList_Previews: PreviewProvider {
    static var previews: some View {
        ReaderContentHorizontalListPreviewGallery()
            .previewLayout(.sizeThatFits)
    }
}
#endif
