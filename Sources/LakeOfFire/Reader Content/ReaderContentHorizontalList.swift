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
    
    @State var cloudDriveSyncStatusModel = CloudDriveSyncStatusModel()
    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel

    @ScaledMetric(relativeTo: .headline) private var maxWidth = 275
    //    @State private var viewWidth: CGFloat = 0
    
    @ViewBuilder var body: some View {
        Button {
            guard !content.url.matchesReaderURL(readerContent.pageURL) else { return }
            Task { @MainActor in
                try await navigator.load(content: content, readerFileManager: readerFileManager)
            }
        } label: {
            AnyView(content.readerContentCellView(alwaysShowThumbnails: true))
//                .background(Color.white.opacity(0.00000001)) // Clickability
                                                             //                            .frame(maxWidth: max(155, min(maxWidth, viewWidth)))
                .frame(maxWidth: maxWidth)
                .padding(8)
                .background(Color.groupBoxBackground)
            //                .background(.regularMaterial)
            //                .background(.secondary.opacity(0.09))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.secondary.opacity(0.2))
                        .shadow(radius: 5)
                }
        }
        //                    .buttonStyle(ReaderContentCellButtonStyle())
        .buttonStyle(.borderless)
        .tint(.secondary)
        //                    .padding(.vertical, 4)
        //                    .padding(.horizontal, 8)
        .overlay {
            AnyView(content.readerContentCellButtonsView())
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        //                    .id(feedEntry.compoundKey)
        .contextMenu {
            if let entry = content as? (any DeletableReaderContent) {
                Button(role: .destructive) {
                    readerContentListModalsModel.confirmDeletionOf = entry
                    readerContentListModalsModel.confirmDelete = true
                } label: {
                    Label(entry.deleteActionTitle, systemImage: "trash")
                }
            }
        }
        .environmentObject(cloudDriveSyncStatusModel)
        .task { @MainActor in
            if let item = content as? ContentFile {
                await cloudDriveSyncStatusModel.refreshAsync(item: item, readerFileManager: readerFileManager)
            }
        }
    }
}

fileprivate struct ReaderContentInnerHorizontalList<C: ReaderContentProtocol>: View {
    var filteredContents: [C]
    
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    
    @ScaledMetric(relativeTo: .headline) private var maxWidth = 275
//    @State private var viewWidth: CGFloat = 0
    
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack {
                ForEach(filteredContents, id: \.compoundKey) { (content: C) in
                    ReaderContentInnerHorizontalListItem(content: content)
                }
                .headerProminence(.increased)
            }
            .fixedSize()
//            .padding(.horizontal)
        }
//        .geometryReader { geometry in
//            Task { @MainActor in
//                if viewWidth != geometry.size.width {
//                    viewWidth = geometry.size.width
//                }
//            }
//        }
    }
    
    init(filteredContents: [C]) {
        self.filteredContents = filteredContents
    }
}

public struct ReaderContentHorizontalList<C: ReaderContentProtocol>: View {
    let contents: [C]
    
    @StateObject var viewModel = ReaderContentListViewModel<C>()

    let contentSortAscending = false
    var contentFilter: (@RealmBackgroundActor (C) async throws -> Bool) = { @RealmBackgroundActor _ in return true }
//    @State var sortOrder = [KeyPathComparator(\ReaderContentType.publicationDate, order: .reverse)] //KeyPathComparator(\TrackedWord.lastReadAtOrEpoch, order: .reverse)]
//    var sortOrder = [KeyPathComparator(\(any ReaderContentProtocol).publicationDate, order: .reverse)] //KeyPathComparator(\TrackedWord.lastReadAtOrEpoch, order: .reverse)]
    var sortOrder = ReaderContentSortOrder.publicationDate
    
    public var body: some View {
        ReaderContentInnerHorizontalList(filteredContents: viewModel.filteredContents)
            .task { @MainActor in
//                await Task { @RealmBackgroundActor in
//                    try? await viewModel.load(contents: ReaderContentLoader.fromMainActor(contents: contents) as? [C] ?? [], contentFilter: contentFilter, sortOrder: sortOrder)
                try? await viewModel.load(contents: contents, sortOrder: sortOrder, contentFilter: contentFilter)
//                }.value
            }
            .onChange(of: contents, debounceTime: 0.1) { contents in
                Task { @MainActor in
                    try? await viewModel.load(contents: contents, sortOrder: sortOrder, contentFilter: contentFilter)
//                    try? await viewModel.load(contents: ReaderContentLoader.fromMainActor(contents: contents) as? [C] ?? [], contentFilter: contentFilter, sortOrder: sortOrder)
                }
            }
    }
    
    public init(contents: [C], contentFilter: ((C) async throws -> Bool)? = nil, sortOrder: ReaderContentSortOrder? = nil) {
        self.contents = contents
        if let contentFilter = contentFilter {
            self.contentFilter = contentFilter
        }
        if let sortOrder = sortOrder {
            self.sortOrder = sortOrder
        }
    }
}
