import SwiftUI
import SwiftUIWebView
import RealmSwift
import RealmSwiftGaps
import SwiftUtilities

public class ReaderContentListModalsModel: ObservableObject {
    @Published var confirmDelete: Bool = false
    @Published var confirmDeletionOf: (any DeletableReaderContent)?
    
    public init() { }
}
struct ReaderContentListSheetsModifier: ViewModifier {
    @ObservedObject var readerContentListModalsModel: ReaderContentListModalsModel
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    
    func body(content: Content) -> some View {
        content
            .confirmationDialog("Do you really want to delete \(readerContentListModalsModel.confirmDeletionOf?.title.truncate(20) ?? "")?", isPresented: $readerContentListModalsModel.confirmDelete) {
                Button("Delete", role: .destructive) {
                    Task { @MainActor in
                        try await readerContentListModalsModel.confirmDeletionOf?.delete(readerFileManager: readerFileManager)
                    }
                }.keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {
                    readerContentListModalsModel.confirmDeletionOf = nil
                }.keyboardShortcut(.cancelAction)
            } message: {
                Text("Deletion cannot be undone.")
            }
    }
}

public extension View {
    func readerContentListSheets(readerContentListModalsModel: ReaderContentListModalsModel) -> some View {
        modifier(ReaderContentListSheetsModifier(readerContentListModalsModel: readerContentListModalsModel))
    }
}

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
    @Published var filteredContents: [C] = []
    var refreshSelectionTask: Task<Void, Error>?
    
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

fileprivate struct ReaderContentInnerListItems<C: ReaderContentModel>: View {
    @Binding var entrySelection: String?
    var alwaysShowThumbnails = true
    @ObservedObject private var viewModel: ReaderContentListViewModel<C>
    
//    @Environment(\.readerWebViewState) private var readerState
    @AppStorage("appTint") private var appTint: Color = Color("AccentColor")
    
    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    
    var body: some View {
        Group {
#if os(macOS)
            ForEach(viewModel.filteredContents, id: \.compoundKey) { (content: C) in
                Toggle(isOn: Binding<Bool>(
                    get: {
                        //                                itemSelection == feedEntry.compoundKey && readerState.matches(content: feedEntry)
                        readerViewModel.state.matches(content: content)
                    },
                    set: {
                        entrySelection = $0 ? content.compoundKey : nil
                    }
                ), label: {
                    ReaderContentCell(item: content, alwaysShowThumbnails: alwaysShowThumbnails, isEbookStyle: viewModel.filteredContents.allSatisfy { $0.url.isEBookURL })
                        .background(Color.white.opacity(0.00000001)) // Clickability
                })
                .toggleStyle(ListItemToggleStyle())
                //                    .buttonStyle(.borderless)
                //                    .id(feedEntry.compoundKey)
                .contextMenu {
                    if let content = content as? (any DeletableReaderContent) {
                        Button(role: .destructive) {
                            readerContentListModalsModel.confirmDeletionOf = content
                            readerContentListModalsModel.confirmDelete = true
                        } label: {
                            Label(content.deleteActionTitle, image: "trash")
                        }
                    }
                }
            }
            .headerProminence(.increased)
#else
            ForEach(viewModel.filteredContents, id: \.compoundKey) { (content: C) in
                Group {
                    if #available(iOS 16.0, *) {
                        ReaderContentCell(item: content, alwaysShowThumbnails: showThumbnails, isEbookStyle: viewModel.filteredContents.allSatisfy { $0.url.isEBookURL })
                    } else {
                        Button {
                            entrySelection = content.compoundKey
                        } label: {
                            ReaderContentCell(item: content, alwaysShowThumbnails: showThumbnails, isEbookStyle: viewModel.filteredContents.allSatisfy { $0.url.isEBookURL })
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
                .swipeActions {
                    if let content = content as? any DeletableReaderContent {
                        Button {
                            readerContentListModalsModel.confirmDeletionOf = content
                            if readerContentListModalsModel.confirmDeletionOf != nil {
                                readerContentListModalsModel.confirmDelete = true
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .tint(.red)
            }
#endif
        }
        .frame(minHeight: 10) // Needed so ScrollView doesn't collapse at start...
    }
    
    init(entrySelection: Binding<String?>, alwaysShowThumbnails: Bool = true, viewModel: ReaderContentListViewModel<C>) {
        _entrySelection = entrySelection
        self.alwaysShowThumbnails = alwaysShowThumbnails
        self.viewModel = viewModel
    }
}

public struct ReaderContentList<C: ReaderContentModel>: View {
    let contents: [C]
    @Binding var entrySelection: String?
    var contentSortAscending = false
    var alwaysShowThumbnails = true
    var contentFilter: ((C) async throws -> Bool)? = nil
    //    var sortOrder = [KeyPathComparator(\(any ReaderContentModel).publicationDate, order: .reverse)] //KeyPathComparator(\TrackedWord.lastReadAtOrEpoch, order: .reverse)]
    var sortOrder = ReaderContentSortOrder.publicationDate
    
    @StateObject private var viewModel = ReaderContentListViewModel<C>()
    
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    @EnvironmentObject private var navigator: WebViewNavigator
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    
    @ViewBuilder private var listItems: some View {
        ReaderContentListItems(contents: contents, entrySelection: $entrySelection, contentSortAscending: contentSortAscending, alwaysShowThumbnails: alwaysShowThumbnails, contentFilter: contentFilter, sortOrder: sortOrder)
    }
    
    public var body: some View {
        Group {
#if os(macOS)
            ScrollView {
                LazyVStack {
                    listItems
                }
            }
#else
            List(selection: $entrySelection) {
                listItems
            }
            .listStyle(.plain)
            .scrollContentBackgroundIfAvailable(.hidden)
            .listItemTint(appTint)
#endif
        }
    }
    
    public init(contents: [C], entrySelection: Binding<String?>, contentSortAscending: Bool = false, alwaysShowThumbnails: Bool = true, contentFilter: ((C) async throws -> Bool)? = nil, sortOrder: ReaderContentSortOrder) {
        self.contents = contents
        _entrySelection = entrySelection
        self.alwaysShowThumbnails = alwaysShowThumbnails
        self.contentSortAscending = contentSortAscending
        self.contentFilter = contentFilter
        self.sortOrder = sortOrder
    }
}

public struct ReaderContentListItems<C: ReaderContentModel>: View {
    let contents: [C]
    // TODO: Something with this triggers repreatedly in printchanges; change to an environmentkey
    @Binding var entrySelection: String?
    var contentSortAscending = false
    var alwaysShowThumbnails = true
    var contentFilter: ((C) async throws -> Bool)? = nil
//    var sortOrder = [KeyPathComparator(\(any ReaderContentModel).publicationDate, order: .reverse)] //KeyPathComparator(\TrackedWord.lastReadAtOrEpoch, order: .reverse)]
    var sortOrder = ReaderContentSortOrder.publicationDate
    
    @StateObject private var viewModel = ReaderContentListViewModel<C>()
    
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    @EnvironmentObject private var navigator: WebViewNavigator
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    
    public var body: some View {
        ScrollViewReader { scrollViewProxy in
            ReaderContentInnerListItems(entrySelection: $entrySelection, alwaysShowThumbnails: alwaysShowThumbnails, viewModel: viewModel)
            .onChange(of: entrySelection) { [oldValue = entrySelection] itemSelection in
                guard oldValue != itemSelection, let itemSelection = itemSelection, let content = viewModel.filteredContents.first(where: { $0.compoundKey == itemSelection }), !content.url.matchesReaderURL(readerViewModel.state.pageURL) else { return }
                Task { @MainActor in
                    await navigator.load(content: content, readerFileManager: readerFileManager)
                    // TODO: This is crashy sadly.
//                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
//                        scrollViewProxy.scrollTo(entrySelection)
//                    }
                }
            }
            .onChange(of: readerViewModel.state) { [oldState = readerViewModel.state] state in
                if oldState.pageURL != state.pageURL {
                    refreshSelection(scrollViewProxy: scrollViewProxy, state: state, oldState: oldState)
                }
            }
            .onChange(of: contents/*, debounceTime: 0.1*/) { contents in
                Task { @MainActor in
                    try? await viewModel.load(contents: contents, contentFilter: contentFilter ?? { _ in return true }, sortOrder: sortOrder)
refreshSelection(scrollViewProxy: scrollViewProxy, state: readerViewModel.state)
                }
            }
            .task { @MainActor in
                try? await viewModel.load(contents: contents, contentFilter: contentFilter ?? { _ in return true }, sortOrder: sortOrder)
                refreshSelection(scrollViewProxy: scrollViewProxy, state: readerViewModel.state)
            }
//            .onChange(of: contents) { contents in
//                Task { @MainActor in
//                    try? await viewModel.load(contents: contents, contentFilter: contentFilter, sortOrder: sortOrder)
//                    refreshSelection(scrollViewProxy: scrollViewProxy, state: readerState)
//                }
//            }
        }
    }
    
    public init(contents: [C], entrySelection: Binding<String?>, contentSortAscending: Bool = false, alwaysShowThumbnails: Bool = true, contentFilter: ((C) async throws -> Bool)? = nil, sortOrder: ReaderContentSortOrder) {
        self.contents = contents
        _entrySelection = entrySelection
        self.alwaysShowThumbnails = alwaysShowThumbnails
        self.contentSortAscending = contentSortAscending
        self.contentFilter = contentFilter
        self.sortOrder = sortOrder
    }
    
    private func refreshSelection(scrollViewProxy: ScrollViewProxy, state: WebViewState, oldState: WebViewState? = nil) {
        viewModel.refreshSelectionTask?.cancel()
        guard !state.isProvisionallyNavigating else { return }
        
//        let readerContentCompoundKey = readerContent.compoundKey
        let entrySelection = entrySelection
        let filteredContentKeys = viewModel.filteredContents.map { $0.compoundKey }
        let filteredContentURLs = viewModel.filteredContents.map { $0.url }
        viewModel.refreshSelectionTask = Task.detached {
            try Task.checkCancellation()
            do {
                if !state.pageURL.isNativeReaderView, let entrySelection = entrySelection, let idx = filteredContentKeys.firstIndex(of: entrySelection), !filteredContentURLs[idx].matchesReaderURL(state.pageURL) {
                    try await Task { @MainActor in
                        try Task.checkCancellation()
                        self.entrySelection = nil
                    }.value
                }
                
                guard !state.pageURL.isNativeReaderView, filteredContentURLs.contains(state.pageURL) else {
                    if !state.pageURL.absoluteString.hasPrefix("internal://local/load"), entrySelection != nil {
                        try await Task { @MainActor in
                            try Task.checkCancellation()
                            self.entrySelection = nil
                        }.value
                    }
                    return
                }
//                if entrySelection == nil, oldState?.pageURL != state.pageURL, content.url != state.pageURL {
                if entrySelection == nil, oldState?.pageURL != state.pageURL, let idx = filteredContentURLs.firstIndex(of: state.pageURL) {
                    let contentKey = filteredContentKeys[idx]
                    try await Task { @MainActor in
                        try Task.checkCancellation()
                        self.entrySelection = contentKey
                    }.value
                }
            } catch { }
        }
    }
}

public extension ReaderContentModel {
    static func readerContentListView(contents: [Self], entrySelection: Binding<String?>, sortOrder: ReaderContentSortOrder, contentFilter: ((Self) async throws -> Bool)? = nil) -> some View {
        return ReaderContentList(contents: contents, entrySelection: entrySelection, contentFilter: contentFilter, sortOrder: sortOrder)
    }
}
