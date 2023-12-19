import SwiftUI
import SwiftUIWebView
import RealmSwift
import RealmSwiftGaps
import SwiftUtilities

fileprivate struct ReaderContentInnerHorizontalList: View {
    var filteredContents: [any ReaderContentModel]
    
    @EnvironmentObject private var navigator: WebViewNavigator
    @Environment(\.readerWebViewState) private var readerState
    @AppStorage("appTint") private var appTint: Color = Color.accentColor
    
    @ScaledMetric(relativeTo: .headline) private var maxWidth = 330
    @State private var viewWidth: CGFloat = 0
    
    private func cellView(_ content: any ReaderContentModel) -> some View {
        Group {
            if let content = content as? Bookmark {
                ReaderContentCell(item: content)
            } else if let content = content as? HistoryRecord {
                ReaderContentCell(item: content)
            } else if let content = content as? FeedEntry {
                ReaderContentCell(item: content)
            }
        }
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack {
                ForEach(filteredContents, id: \.compoundKey) { (content: (any ReaderContentModel)) in
                    Button {
                        guard !content.url.matchesReaderURL(readerState.pageURL) else { return }
                        Task { @MainActor in
                            navigator.load(content: content)
                        }
                    } label: {
                        cellView(content)
                            .background(Color.white.opacity(0.00000001)) // Clickability
                            .frame(maxWidth: max(155, min(maxWidth, viewWidth - 50)))
                    }
#if os(iOS)
                    .buttonStyle(.bordered)
#else
                    .buttonStyle(.borderless)
#endif
                    .tint(.secondary)
                    //                    .id(feedEntry.compoundKey)
                    Divider()
                }
                .headerProminence(.increased)
            }
            .fixedSize()
            .padding(.horizontal)
        }
        .geometryReader { geometry in
            Task { @MainActor in
                if viewWidth != geometry.size.width {
                    viewWidth = geometry.size.width
                }
            }
        }
    }
    
    init(filteredContents: [any ReaderContentModel]) {
        self.filteredContents = filteredContents
    }
}

public struct ReaderContentHorizontalList: View {
//    let contents: AnyRealmCollection<ReaderContentType>
    let contents: [any ReaderContentModel]
    
    @StateObject var viewModel = ReaderContentListViewModel()
    
    @Environment(\.readerWebViewState) private var readerState

    let contentSortAscending = false
    var contentFilter: (@RealmBackgroundActor (any ReaderContentModel) async throws -> Bool) = { @RealmBackgroundActor _ in return true }
//    @State var sortOrder = [KeyPathComparator(\ReaderContentType.publicationDate, order: .reverse)] //KeyPathComparator(\TrackedWord.lastReadAtOrEpoch, order: .reverse)]
//    var sortOrder = [KeyPathComparator(\(any ReaderContentModel).publicationDate, order: .reverse)] //KeyPathComparator(\TrackedWord.lastReadAtOrEpoch, order: .reverse)]
    var sortOrder = ReaderContentListViewModel.SortOrder.publicationDate
    
    public var body: some View {
        ReaderContentInnerHorizontalList(filteredContents: viewModel.filteredContents)
            .task {
                await Task { @RealmBackgroundActor in
                    try? await viewModel.load(contents: ReaderContentLoader.fromMainActor(contents: contents), contentFilter: contentFilter, sortOrder: sortOrder)
                }.value
            }
    }
    
    public init(contents: [any ReaderContentModel], contentFilter: ((any ReaderContentModel) async throws -> Bool)? = nil, sortOrder: ReaderContentListViewModel.SortOrder? = nil) {
        self.contents = contents
        if let contentFilter = contentFilter {
            self.contentFilter = contentFilter
        }
        if let sortOrder = sortOrder {
            self.sortOrder = sortOrder
        }
    }
}
