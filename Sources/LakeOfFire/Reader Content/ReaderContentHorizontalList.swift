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
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    
    @ScaledMetric(relativeTo: .headline) private var maxWidth = 330
    @State private var viewWidth: CGFloat = 0
    
    @State private var confirmDelete: Bool = false
    @State private var confirmDeletionOf: (any DeletableReaderContent)?
    
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack {
                ForEach(filteredContents, id: \.compoundKey) { (content: (any ReaderContentModel)) in
                    Button {
                        guard !content.url.matchesReaderURL(readerState.pageURL) else { return }
                        Task { @MainActor in
                            await navigator.load(content: content, readerFileManager: readerFileManager)
                        }
                    } label: {
                        AnyView(content.readerContentCellView(showThumbnails: true))
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
                    .contextMenu {
                        if let entry = content as? (any DeletableReaderContent) {
                            Button(role: .destructive) {
                                confirmDeletionOf = entry
                                confirmDelete = true
                            } label: {
                                Label(entry.deleteActionTitle, image: "trash")
                            }
                        }
                    }
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
        .confirmationDialog("Do you really want to delete \(confirmDeletionOf?.title.truncate(20) ?? "")?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task { @MainActor in
                    try await confirmDeletionOf?.delete(readerFileManager: readerFileManager)
                }
            }
            Button("Cancel", role: .cancel) {
                confirmDeletionOf = nil
            }
        } message: {
            Text("Deletion cannot be undone.")
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
            .task(id: contents.map { $0.compoundKey }.joined(separator: ":")) { @MainActor in
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
