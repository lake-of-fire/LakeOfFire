import SwiftUI
import SwiftUIWebView
import RealmSwift
import SwiftUtilities

fileprivate struct ReaderContentInnerHorizontalList<ReaderContentType: ReaderContentModel>: View where ReaderContentType: RealmCollectionValue {
    var filteredContents: [ReaderContentType]
    
    @EnvironmentObject private var navigator: WebViewNavigator
    @Environment(\.readerWebViewState) private var readerState
    @AppStorage("appTint") private var appTint: Color = Color.accentColor
    
    @ScaledMetric(relativeTo: .headline) private var maxWidth = 330
    @State private var viewWidth: CGFloat = 0
    
    private var cellView: ((_ content: ReaderContentType) -> ReaderContentCell) = { content in
        ReaderContentCell(item: content)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack {
                ForEach(filteredContents, id: \.compoundKey)  { (content: ReaderContentType) in
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
    
    init(filteredContents: [ReaderContentType]) {
        self.filteredContents = filteredContents
    }
}

public struct ReaderContentHorizontalList<ReaderContentType: ReaderContentModel>: View where ReaderContentType: RealmCollectionValue {
    let contents: AnyRealmCollection<ReaderContentType>
    
    @StateObject var viewModel = ReaderContentListViewModel<ReaderContentType>()
    
    @Environment(\.readerWebViewState) private var readerState

    let contentSortAscending = false
    var contentFilter: ((ReaderContentType) -> Bool) = { _ in return true }
//    @State var sortOrder = [KeyPathComparator(\ReaderContentType.publicationDate, order: .reverse)] //KeyPathComparator(\TrackedWord.lastReadAtOrEpoch, order: .reverse)]
    var sortOrder = [KeyPathComparator(\ReaderContentType.publicationDate, order: .reverse)] //KeyPathComparator(\TrackedWord.lastReadAtOrEpoch, order: .reverse)]
    
    public var body: some View {
        ReaderContentInnerHorizontalList(filteredContents: viewModel.filteredContents)
            .task {
                viewModel.load(contents: contents, contentFilter: contentFilter, sortOrder: sortOrder)
            }
    }
    
    public init(contents: AnyRealmCollection<ReaderContentType>, contentFilter: ((ReaderContentType) -> Bool)? = nil, sortOrder: [KeyPathComparator<ReaderContentType>]? = nil) {
        self.contents = contents
        if let contentFilter = contentFilter {
            self.contentFilter = contentFilter
        }
        if let sortOrder = sortOrder {
            self.sortOrder = sortOrder
        }
    }
}
