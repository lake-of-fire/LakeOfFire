import SwiftUI
import SwiftUIWebView
import RealmSwift
import RealmSwiftGaps
import SwiftUtilities

struct ListItemToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(PlainButtonStyle())
        .background(configuration.isOn ? Color.accentColor : Color.clear)
    }
}
    
public enum ReaderContentSortOrder {
    case publicationDate
    case createdAt
    case lastVisitedAt
}

public class ReaderContentListViewModel<C: ReaderContentModel>: ObservableObject {
//    @Published var filteredContents: [ReaderContentType] = []
    @Published var filteredContents: [C] = []
    var refreshSelectionTask: Task<Void, Never>?
    
    @MainActor
    func load(contents: [C], contentFilter: @escaping (@RealmBackgroundActor (C) async throws -> Bool), sortOrder: ReaderContentSortOrder) async throws {
        try await Task { @RealmBackgroundActor in
            var filtered: [C] = []
            //            let filtered: AsyncFilterSequence<AnyRealmCollection<ReaderContentType>> = contents.filter({
            //                try await contentFilter($0)
            //            })
            for content in contents {
                if try await contentFilter(content) {
                    filtered.append(content)
                }
            }
            
            let sorted: [C]
            switch sortOrder {
            case .publicationDate:
                sorted = filtered.sorted(using: [KeyPathComparator(\.publicationDate, order: .reverse)])
            case .createdAt:
                sorted = filtered.sorted(using: [KeyPathComparator(\.createdAt, order: .reverse)])
            case .lastVisitedAt:
                if let filtered = filtered as? [HistoryRecord] {
                    sorted = filtered.sorted(using: [KeyPathComparator(\.lastVisitedAt, order: .reverse)]) as? [C] ?? []
                } else {
                    sorted = filtered
                    print("ERROR No sorting for lastVisitedAt unless HistoryRecord")
                }
            }
            // TODO: Pagination
            let toSet = Array(sorted.prefix(3000))
            try await Task { @MainActor [weak self] in
                guard let self = self else { return }
                //                self?.filteredContents = toSet
                filteredContents = try await ReaderContentLoader.fromBackgroundActor(contents: toSet as [any ReaderContentModel]) as? [C] ?? filteredContents
            }.value
        }.value
    }
}

fileprivate struct ReaderContentInnerList<C: ReaderContentModel>: View {
    @Binding var entrySelection: String?
    var showThumbnails = true
    @ObservedObject private var viewModel: ReaderContentListViewModel<C>
    
    @Environment(\.readerWebViewState) private var readerState
    @AppStorage("appTint") private var appTint: Color = Color("AccentColor")
    
    @State private var confirmDelete: Bool = false
    @State private var confirmDeletionOf: (any DeletableReaderContent)?
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    
    var body: some View {
        Group {
#if os(macOS)
            ScrollView {
                LazyVStack {
                    ForEach(viewModel.filteredContents, id: \.compoundKey)  { (feedEntry: C) in
                        Toggle(isOn: Binding<Bool>(
                            get: {
                                //                                itemSelection == feedEntry.compoundKey && readerState.matches(content: feedEntry)
                                readerState.matches(content: feedEntry)
                            },
                            set: {
                                entrySelection = $0 ? feedEntry.compoundKey : nil
                            }
                        ), label: {
                            AnyView(feedEntry.readerContentCellView(showThumbnails: showThumbnails))
                                .background(Color.white.opacity(0.00000001)) // Clickability
                        })
                        .toggleStyle(ListItemToggleStyle())
                        //                    .buttonStyle(.borderless)
                        //                    .id(feedEntry.compoundKey)
                        .contextMenu {
                            if let entry = feedEntry as? (any DeletableReaderContent) {
                                Button(role: .destructive) {
                                    confirmDeletionOf = entry
                                    confirmDelete = true
                                } label: {
                                    Label(entry.deleteActionTitle, image: "trash")
                                }
                            }
                        }
                    }
                    .headerProminence(.increased)
                }
            }
#else
            List(viewModel.filteredContents, id: \.compoundKey, selection: $entrySelection) { content in
                Group {
                    if #available(iOS 16.0, *) {
                        cellView(content)
                    } else {
                        Button {
                            entrySelection = content.compoundKey
                        } label: {
                            AnyView(content.readerContentCellView(showThumbnails: showThumbnails))
                                .multilineTextAlignment(.leading)
                            //                        .id(content.compoundKey)
                        }
                        .buttonStyle(.borderless)
                        .tint(.primary)
                        .frame(maxWidth: .infinity)
                    }
                    //                .headerProminence(.increased)
                }
                .deleteDisabled((content as? any DeletableReaderContent) == nil)
                .onDelete {
                    confirmDeletionOf = content as? any DeletableReaderContent
                    if confirmDeletionOf != nil {
                        confirmDelete = true
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackgroundIfAvailable(.hidden)
            .listItemTint(appTint)
#endif
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
    
    init(entrySelection: Binding<String?>, showThumbnails: Bool = true, viewModel: ReaderContentListViewModel<C>) {
        _entrySelection = entrySelection
        self.showThumbnails = showThumbnails
        self.viewModel = viewModel
    }
}

public struct ReaderContentList<C: ReaderContentModel>: View {
    let contents: [C]
    @Binding var entrySelection: String?
    var contentSortAscending = false
    var showThumbnails = true
    var contentFilter: ((C) async throws -> Bool)? = nil
//    var sortOrder = [KeyPathComparator(\(any ReaderContentModel).publicationDate, order: .reverse)] //KeyPathComparator(\TrackedWord.lastReadAtOrEpoch, order: .reverse)]
    var sortOrder = ReaderContentSortOrder.publicationDate
    
    @StateObject private var viewModel = ReaderContentListViewModel<C>()
    
    @Environment(\.readerWebViewState) private var readerState
    @EnvironmentObject private var navigator: WebViewNavigator
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    
    public var body: some View {
        ScrollViewReader { scrollViewProxy in
            ReaderContentInnerList(entrySelection: $entrySelection, showThumbnails: showThumbnails, viewModel: viewModel)
            .onChange(of: entrySelection) { itemSelection in
                guard let itemSelection = itemSelection, let content = viewModel.filteredContents.first(where: { $0.compoundKey == itemSelection }), !content.url.matchesReaderURL(readerState.pageURL) else { return }
                Task { @MainActor in
                    await navigator.load(content: content, readerFileManager: readerFileManager)
                    // TODO: This is crashy sadly.
//                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
//                        scrollViewProxy.scrollTo(entrySelection)
//                    }
                }
            }
            .onChange(of: readerState) { [oldState = readerState] state in
                refreshSelection(scrollViewProxy: scrollViewProxy, state: state, oldState: oldState)
            }
            .onChange(of: contents, debounceTime: 0.1) { contents in
                Task { @MainActor in
                    try? await viewModel.load(contents: contents, contentFilter: contentFilter ?? { _ in return true }, sortOrder: sortOrder)
                    refreshSelection(scrollViewProxy: scrollViewProxy, state: readerState)
                }
            }
            .task { @MainActor in
                try? await viewModel.load(contents: contents, contentFilter: contentFilter ?? { _ in return true }, sortOrder: sortOrder)
                refreshSelection(scrollViewProxy: scrollViewProxy, state: readerState)
            }
//            .onChange(of: contents) { contents in
//                Task { @MainActor in
//                    try? await viewModel.load(contents: contents, contentFilter: contentFilter, sortOrder: sortOrder)
//                    refreshSelection(scrollViewProxy: scrollViewProxy, state: readerState)
//                }
//            }
        }
    }
    
    public init(contents: [C], entrySelection: Binding<String?>, contentSortAscending: Bool = false, showThumbnails: Bool = true, contentFilter: ((C) async throws -> Bool)? = nil, sortOrder: ReaderContentSortOrder) {
        self.contents = contents
        _entrySelection = entrySelection
        self.showThumbnails = showThumbnails
        self.contentSortAscending = contentSortAscending
        self.contentFilter = contentFilter
        self.sortOrder = sortOrder
    }
    
    private func refreshSelection(scrollViewProxy: ScrollViewProxy, state: WebViewState, oldState: WebViewState? = nil) {
        guard !state.isProvisionallyNavigating else { return }
        viewModel.refreshSelectionTask?.cancel()
        
//        let readerContentCompoundKey = readerContent.compoundKey
        let entrySelection = entrySelection
        let filteredContentKeys = viewModel.filteredContents.map { $0.compoundKey }
        let filteredContentURLs = viewModel.filteredContents.map { $0.url }
        viewModel.refreshSelectionTask = Task.detached {
            do {
                if !state.pageURL.isNativeReaderView, let entrySelection = entrySelection, let idx = filteredContentKeys.firstIndex(of: entrySelection), !filteredContentURLs[idx].matchesReaderURL(state.pageURL) {
                    Task { @MainActor in
                        do {
                            try Task.checkCancellation()
                            self.entrySelection = nil
                        }
                    }
                }
                
                guard !state.pageURL.isNativeReaderView, filteredContentURLs.contains(state.pageURL) else {
                    if !state.pageURL.absoluteString.hasPrefix("internal://local/load"), entrySelection != nil {
                        try Task.checkCancellation()
                        Task { @MainActor in
                            self.entrySelection = nil
                        }
                    }
                    return
                }
//                if entrySelection == nil, oldState?.pageURL != state.pageURL, content.url != state.pageURL {
//                    try Task.checkCancellation()
//                    Task { @MainActor in
//                        self.entrySelection = content.compoundKey
//                    }
//                }
            } catch { }
        }
    }
}

public extension ReaderContentModel {
    static func readerContentListView(contents: [Self], entrySelection: Binding<String?>, sortOrder: ReaderContentSortOrder, contentFilter: ((Self) async throws -> Bool)? = nil) -> some View {
        return ReaderContentList(contents: contents, entrySelection: entrySelection, contentFilter: contentFilter, sortOrder: sortOrder)
    }
}
