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
    
    @StateObject var cloudDriveSyncStatusModel = CloudDriveSyncStatusModel()
    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel
    
    @ScaledMetric(relativeTo: .headline) private var maxWidth = 275
    //    @State private var viewWidth: CGFloat = 0
    
    var body: some View {
        Button {
            guard !content.url.matchesReaderURL(readerContent.pageURL) else { return }
            Task { @MainActor in
                try await navigator.load(
                    content: content,
                    readerModeViewModel: readerModeViewModel
                )
            }
        } label: {
            Group {
                //            AnyView(
                if let customMenuOptions {
                    content.readerContentCellView(
                        appearance: ReaderContentCellAppearance(
                            maxCellHeight: maxCellHeight,
                            alwaysShowThumbnails: true,
                            isEbookStyle: false,
                            includeSource: includeSource
                        ),
                        customMenuOptions: customMenuOptions
                    )
                } else {
                    content.readerContentCellView(
                        appearance: ReaderContentCellAppearance(
                            maxCellHeight: maxCellHeight,
                            alwaysShowThumbnails: true,
                            isEbookStyle: false,
                            includeSource: includeSource
                        )
                    )
                }
            }
            .modifier {
                if #available(iOS 17, macOS 14, *) {
                    $0.background(.background.secondary)
                } else { $0.background(.secondary.opacity(0.25)) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
#if os(macOS)
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.secondary.opacity(0.2))
                    .shadow(radius: 5)
            }
#endif
            //            )
            //                .background(Color.white.opacity(0.00000001)) // Clickability
            //                            .frame(maxWidth: max(155, min(maxWidth, viewWidth)))
            .frame(maxWidth: maxWidth)
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
        .enableInjection()
    }
    
    @ObserveInjection var forceRedraw
}

fileprivate struct ReaderContentInnerHorizontalList<C: ReaderContentProtocol>: View {
    var filteredContents: [C]
    let includeSource: Bool
    let customMenuOptions: ((C) -> AnyView)?
    
    @ScaledMetric(relativeTo: .headline) private var maxCellHeight: CGFloat = 140
    @ScaledMetric(relativeTo: .headline) private var maxWidth = 275
    //    @State private var viewWidth: CGFloat = 0
    
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack {
                ForEach(filteredContents, id: \.compoundKey) { (content: C) in
                    ReaderContentInnerHorizontalListItem(
                        content: content,
                        includeSource: includeSource,
                        maxCellHeight: maxCellHeight,
                        customMenuOptions: customMenuOptions
                    )
                }
                //                .headerProminence(.increased)
            }
            .frame(minHeight: maxCellHeight)
            //            .fixedSize()
            //            .padding(.horizontal)
        }
        //        .geometryReader { geometry in
        //            Task { @MainActor in
        //                if viewWidth != geometry.size.width {
        //                    viewWidth = geometry.size.width
        //                }
        //            }
        //        }
        .enableInjection()
    }
    
    @ObserveInjection var forceRedraw
    
    init(
        filteredContents: [C],
        includeSource: Bool,
        customMenuOptions: ((C) -> AnyView)?
    ) {
        self.filteredContents = filteredContents
        self.includeSource = includeSource
        self.customMenuOptions = customMenuOptions
    }
}

public struct ReaderContentHorizontalList<C: ReaderContentProtocol, EmptyState: View>: View {
    let contents: [C]
    let includeSource: Bool
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
                    customMenuOptions: customMenuOptions
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
        .enableInjection()
    }
    
    @ObserveInjection var forceRedraw
    
    /// Initializer with a view builder for the empty state (required).
    public init(
        contents: [C],
        contentFilter: ((Int, C) async throws -> Bool)? = nil,
        sortOrder: ReaderContentSortOrder? = nil,
        includeSource: Bool,
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
        self.customMenuOptions = customMenuOptions
        self.emptyStateView = { emptyStateView() }
    }
}
