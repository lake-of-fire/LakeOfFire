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
    
    private var cardWidth: CGFloat { maxCellHeight * 3 }
    private var thumbnailCornerRadius: CGFloat { max(0, Layout.cardCornerRadius - Layout.contentPadding) }

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
            VStack(spacing: 0) {
                if let customMenuOptions {
                    content.readerContentCellView(
                        appearance: ReaderContentCellAppearance(
                            maxCellHeight: maxCellHeight,
                            alwaysShowThumbnails: true,
                            isEbookStyle: false,
                            includeSource: includeSource,
                            thumbnailDimension: maxCellHeight,
                            thumbnailCornerRadius: thumbnailCornerRadius
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
                            thumbnailDimension: maxCellHeight,
                            thumbnailCornerRadius: thumbnailCornerRadius
                        )
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(cardBackground)
            .contentShape(RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous))
#if os(macOS)
            .overlay {
                RoundedRectangle(cornerRadius: Layout.cardCornerRadius)
                    .stroke(.secondary.opacity(0.2))
                    .shadow(radius: 5)
            }
#endif
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
}

fileprivate struct ReaderContentInnerHorizontalList<C: ReaderContentProtocol>: View {
    var filteredContents: [C]
    let includeSource: Bool
    let customMenuOptions: ((C) -> AnyView)?
    let contentSelection: Binding<String?>
    
    @ScaledMetric(relativeTo: .headline) private var maxCellHeight: CGFloat = 140 * (2.0 / 3.0)
    //    @State private var viewWidth: CGFloat = 0
    
    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(filteredContents, id: \.compoundKey) { (content: C) in
                    ReaderContentInnerHorizontalListItem(
                        content: content,
                        includeSource: includeSource,
                        maxCellHeight: maxCellHeight,
                        customMenuOptions: customMenuOptions,
                        contentSelection: contentSelection
                    )
                }
                //                .headerProminence(.increased)
            }
            .frame(minHeight: maxCellHeight)
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
        customMenuOptions: ((C) -> AnyView)?,
        contentSelection: Binding<String?>
    ) {
        self.filteredContents = filteredContents
        self.includeSource = includeSource
        self.customMenuOptions = customMenuOptions
        self.contentSelection = contentSelection
    }
}

public struct ReaderContentHorizontalList<C: ReaderContentProtocol, EmptyState: View>: View {
    let contents: [C]
    let includeSource: Bool
    var contentSelection: Binding<String?>
    let emptyStateView: () -> EmptyState
    let customMenuOptions: ((C) -> AnyView)?
    
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
                    contentSelection: contentSelection
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
        self.emptyStateView = { emptyStateView() }
    }
}
