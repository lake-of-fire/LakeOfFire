import SwiftUI
import SwiftUIWebView
import RealmSwift
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

class ReaderContentListViewModel<ReaderContentType: ReaderContentModel>: ObservableObject where ReaderContentType: RealmCollectionValue {
    @Published var filteredContents: [ReaderContentType] = []
    var refreshSelectionTask: Task<Void, Never>?
    
    func load(contents: AnyRealmCollection<ReaderContentType>, contentFilter: @escaping ((ReaderContentType) -> Bool), sortOrder: [KeyPathComparator<ReaderContentType>]) {
//        Task.detached {
            let filtered: LazyFilterSequence<AnyRealmCollection<ReaderContentType>> = contents.filter({
                contentFilter($0)
            })
            let sorted = filtered.sorted(using: sortOrder)
            let toSet = Array(sorted.prefix(30))
//            Task { @MainActor [weak self] in
//                self?.filteredContents = toSet
                filteredContents = toSet
//            }
//        }
    }
}

fileprivate struct ReaderContentInnerList<ReaderContentType: ReaderContentModel>: View where ReaderContentType: RealmCollectionValue {
    @Binding var entrySelection: String?
    var filteredContents: [ReaderContentType]
    
    @Environment(\.readerWebViewState) private var readerState
    @AppStorage("appTint") private var appTint: Color = Color("AccentColor")
    
    private var cellView: ((_ content: ReaderContentType) -> ReaderContentCell) = { content in
        ReaderContentCell(item: content)
    }

    var body: some View {
#if os(macOS)
        ScrollView {
            LazyVStack {
                ForEach(filteredContents, id: \.compoundKey)  { (feedEntry: ReaderContentType) in
                    Toggle(isOn: Binding<Bool>(
                        get: {
                            //                                itemSelection == feedEntry.compoundKey && readerState.matches(content: feedEntry)
                            readerState.matches(content: feedEntry)
                        },
                        set: {
                            entrySelection = $0 ? feedEntry.compoundKey : nil
                        }
                    ), label: {
                        cellView(feedEntry)
                            .background(Color.white.opacity(0.00000001)) // Clickability
                    })
                    .toggleStyle(ListItemToggleStyle())
                    //                    .buttonStyle(.borderless)
//                    .id(feedEntry.compoundKey)
                }
                .headerProminence(.increased)
            }
        }
#else
        List(filteredContents, id: \.compoundKey, selection: $entrySelection) { content in
            if #available(iOS 16.0, *) {
                cellView(content)
            } else {
                Button {
                    entrySelection = content.compoundKey
                } label: {
                    cellView(content)
                        .multilineTextAlignment(.leading)
//                        .id(content.compoundKey)
                }
                .buttonStyle(.borderless)
                .tint(.primary)
                .frame(maxWidth: .infinity)
            }
            //                .headerProminence(.increased)
        }
        .listStyle(.plain)
        .scrollContentBackgroundIfAvailable(.hidden)
        .listItemTint(appTint)
#endif
    }
    
    init(entrySelection: Binding<String?>, filteredContents: [ReaderContentType]) {
        _entrySelection = entrySelection
        self.filteredContents = filteredContents
    }
}

public struct ReaderContentList<ReaderContentType: ReaderContentModel>: View where ReaderContentType: RealmCollectionValue {
    let contents: AnyRealmCollection<ReaderContentType>
    @Binding var entrySelection: String?
    var contentSortAscending = false
    var contentFilter: ((ReaderContentType) -> Bool) = { _ in return true }
    var sortOrder = [KeyPathComparator(\ReaderContentType.publicationDate, order: .reverse)] //KeyPathComparator(\TrackedWord.lastReadAtOrEpoch, order: .reverse)]

    @StateObject private var viewModel = ReaderContentListViewModel<ReaderContentType>()
    
    @Environment(\.readerWebViewState) private var readerState
    @EnvironmentObject private var navigator: WebViewNavigator
    
    var filteredContents: [ReaderContentType] {
        let filtered: LazyFilterSequence<AnyRealmCollection<ReaderContentType>> = contents.filter({
            contentFilter($0)
        })
        let sorted = filtered.sorted(using: sortOrder)
        return Array(sorted)
    }
    
    public var body: some View {
        ScrollViewReader { scrollViewProxy in
            ReaderContentInnerList(entrySelection: $entrySelection, filteredContents: filteredContents)
            .onChange(of: entrySelection) { itemSelection in
                guard let itemSelection = itemSelection, let content = filteredContents.first(where: { $0.compoundKey == itemSelection }), !content.url.matchesReaderURL(readerState.pageURL) else { return }
                Task { @MainActor in
                    navigator.load(content: content)
                    // TODO: This is crashy sadly.
//                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
//                        scrollViewProxy.scrollTo(entrySelection)
//                    }
                }
            }
            .onChange(of: readerState) { [oldState = readerState] state in
                refreshSelection(scrollViewProxy: scrollViewProxy, state: state, oldState: oldState)
            }
            .task {
                refreshSelection(scrollViewProxy: scrollViewProxy, state: readerState)
            }
            .onAppear {
                refreshSelection(scrollViewProxy: scrollViewProxy, state: readerState)
            }
        }
    }
    
    public init(contents: AnyRealmCollection<ReaderContentType>, entrySelection: Binding<String?>, contentSortAscending: Bool = false, contentFilter: @escaping ((ReaderContentType) -> Bool) = { _ in return true }, sortOrder: [KeyPathComparator<ReaderContentType>]) {
        self.contents = contents
        _entrySelection = entrySelection
        self.contentSortAscending = contentSortAscending
        self.contentFilter = contentFilter
        self.sortOrder = sortOrder
    }
    
    private func refreshSelection(scrollViewProxy: ScrollViewProxy, state: WebViewState, oldState: WebViewState? = nil) {
        guard !state.isProvisionallyNavigating else { return }
        viewModel.refreshSelectionTask?.cancel()
        
//        let readerContentCompoundKey = readerContent.compoundKey
        let entrySelection = entrySelection
        let filteredContents = filteredContents
        
        viewModel.refreshSelectionTask = Task.detached {
            do {
                if !state.pageURL.isNativeReaderView, let entrySelection = entrySelection, let content = filteredContents.first(where: { $0.compoundKey == entrySelection }), !content.url.matchesReaderURL(state.pageURL) {
                    Task { @MainActor in
                        do {
                            try Task.checkCancellation()
                            self.entrySelection = nil
                        }
                    }
                }
                
                guard !state.pageURL.isNativeReaderView, let content = contents.first(where: { $0.url == state.pageURL }) else {
                    if !state.pageURL.absoluteString.starts(with: "about:load"), entrySelection != nil {
                        try Task.checkCancellation()
                        Task { @MainActor in
                            self.entrySelection = nil
                        }
                    }
                    return
                }
                if entrySelection == nil, oldState?.pageURL != state.pageURL, content.url != state.pageURL {
                    try Task.checkCancellation()
                    Task { @MainActor in
                        self.entrySelection = content.compoundKey
                    }
                }
            } catch { }
        }
    }
}
