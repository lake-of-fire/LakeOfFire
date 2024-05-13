import SwiftUI
import SwiftUIWebView
import RealmSwift
import RealmSwiftGaps
import SwiftUtilities
import LakeKit

public class ReaderContentListModalsModel: ObservableObject {
    @Published var confirmDelete: Bool = false
    @Published var confirmDeletionOf: (any DeletableReaderContent)?
    
    public init() { }
}
struct ReaderContentListSheetsModifier: ViewModifier {
    @ObservedObject var readerContentListModalsModel: ReaderContentListModalsModel
    let isActive: Bool
    
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    
    func body(content: Content) -> some View {
        content
            .confirmationDialog("Do you really want to delete \(readerContentListModalsModel.confirmDeletionOf?.title.truncate(20) ?? "")?", isPresented: $readerContentListModalsModel.confirmDelete && isActive) {
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
    func readerContentListSheets(readerContentListModalsModel: ReaderContentListModalsModel, isActive: Bool) -> some View {
        modifier(ReaderContentListSheetsModifier(readerContentListModalsModel: readerContentListModalsModel, isActive: isActive))
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
    var loadContentsTask: Task<Void, Error>?
    
    @MainActor
    func load(contents: [C], sortOrder: ReaderContentSortOrder, contentFilter: (@RealmBackgroundActor (C) async throws -> Bool)? = nil) async throws {
        loadContentsTask?.cancel()
        loadContentsTask = Task { @RealmBackgroundActor in
            var filtered: [C] = []
            //            let filtered: AsyncFilterSequence<AnyRealmCollection<ReaderContentType>> = contents.filter({
            //                try await contentFilter($0)
            //            })
            for content in contents {
                try Task.checkCancellation()
                if try await contentFilter?(content) ?? true {
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
            try Task.checkCancellation()
            
            // TODO: Pagination
            let toSet = Array(sorted.prefix(3000))
            try await Task { @MainActor [weak self] in
                try Task.checkCancellation()
                guard let self = self else { return }
                //                self?.filteredContents = toSet
                filteredContents = try await ReaderContentLoader.fromBackgroundActor(contents: toSet as [any ReaderContentModel]) as? [C] ?? filteredContents
            }.value
        }
        try await loadContentsTask?.value
    }
}

fileprivate struct ReaderContentInnerListItem<C: ReaderContentModel>: View {
    let content: C
    @Binding var entrySelection: String?
    var alwaysShowThumbnails = true
    var showSeparators = false
    @ObservedObject var viewModel: ReaderContentListViewModel<C>
    
    //    @Environment(\.readerWebViewState) private var readerState
    
    @State private var cloudDriveSyncStatusModel = CloudDriveSyncStatusModel()
    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    
    @ViewBuilder private func unstyledCell(item: C) -> some View {
        item.readerContentCellView(alwaysShowThumbnails: alwaysShowThumbnails, isEbookStyle: viewModel.filteredContents.allSatisfy { $0.url.isEBookURL })
    }
    
    @ViewBuilder private func cell(item: C) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                if showSeparators {
                    unstyledCell(item: item)
                } else {
                    unstyledCell(item: item)
                    //                    .padding(.vertical, 4)
                    //                    .padding(.horizontal, 8)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .background(.secondary.opacity(0.09))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            Spacer(minLength: 0)
        }
        .tag(item.compoundKey)
    }
    
    var body: some View {
        VStack(spacing: 0) {
#if os(macOS)
            Toggle(isOn: Binding<Bool>(
                get: {
                    //                                itemSelection == feedEntry.compoundKey && readerState.matches(content: feedEntry)
                    readerViewModel.state.matches(content: content)
                },
                set: {
                    entrySelection = $0 ? content.compoundKey : nil
                }
            ), label: {
                cell(item: content)
                    .background(Color.white.opacity(0.00000001)) // Clickability
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.secondary.opacity(0.2))
                            .shadow(radius: 5)
                    }
            })
            .toggleStyle(ListItemToggleStyle())
            .overlay {
                AnyView(content.readerContentCellButtonsView())
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if showSeparators, content.compoundKey != viewModel.filteredContents.last?.compoundKey {
                Divider()
                    .padding(.top, 4)
            }
            //                                    .contextMenu {
            //                    if let content = content as? (any DeletableReaderContent) {
            //                        Button(role: .destructive) {
            //                            readerContentListModalsModel.confirmDeletionOf = content
            //                            readerContentListModalsModel.confirmDelete = true
            //                        } label: {
            //                            Label(content.deleteActionTitle, image: "trash")
            //                        }
            //                    }
            //                }
            
            //                    .buttonStyle(.borderless)
            //                    .id(feedEntry.compoundKey)
#elseif os(iOS)
            if #available(iOS 16.0, *) {
                cell(item: content)
            } else {
                Button {
                    entrySelection = content.compoundKey
                } label: {
                    cell(item: content)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.borderless)
                .tint(.primary)
                .frame(maxWidth: .infinity)
            }
            //                .headerProminence(.increased)
            //                    if showSeparators, content.compoundKey != viewModel.filteredContents.last?.compoundKey {
            //                        Divider()
            //                            .padding(.top, 8)
            //                    }
#endif
        }
#if os(iOS)
        .overlay {
            AnyView(content.readerContentCellButtonsView())
        }
        //                .listRowInsets(showSeparators ? nil : EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
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
        //                .tint(.)
#endif
        .environmentObject(cloudDriveSyncStatusModel)
        .task { @MainActor in
            if let item = content as? ContentFile {
                await cloudDriveSyncStatusModel.refreshAsync(item: item, readerFileManager: readerFileManager)
            }
        }
    }
}

fileprivate struct ReaderContentInnerListItems<C: ReaderContentModel>: View {
    @Binding var entrySelection: String?
    var alwaysShowThumbnails = true
    var showSeparators = false
    @ObservedObject private var viewModel: ReaderContentListViewModel<C>
    
//    @Environment(\.readerWebViewState) private var readerState
    
    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    
    @ViewBuilder private func unstyledCell(item: C) -> some View {
        item.readerContentCellView(alwaysShowThumbnails: alwaysShowThumbnails, isEbookStyle: viewModel.filteredContents.allSatisfy { $0.url.isEBookURL })
    }

    @ViewBuilder private func cell(item: C) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                if showSeparators {
                    unstyledCell(item: item)
                } else {
                    unstyledCell(item: item)
                    //                    .padding(.vertical, 4)
                    //                    .padding(.horizontal, 8)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .background(.secondary.opacity(0.09))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            Spacer(minLength: 0)
        }
        .tag(item.compoundKey)
    }
    
    var body: some View {
        Group {
#if os(macOS)
            ForEach(viewModel.filteredContents, id: \.compoundKey) { (content: C) in
                ReaderContentInnerListItem(content: content, entrySelection: $entrySelection, alwaysShowThumbnails: alwaysShowThumbnails, showSeparators: showSeparators, viewModel: viewModel)
            }
            .headerProminence(.increased)
#else
            ForEach(viewModel.filteredContents, id: \.compoundKey) { (content: C) in
                ReaderContentInnerListItem(content: content, entrySelection: $entrySelection, alwaysShowThumbnails: alwaysShowThumbnails, showSeparators: showSeparators, viewModel: viewModel)
                    .listRowInsets(.init(top: 4, leading: 8, bottom: 4, trailing: 8))
            }
#endif
        }
        .frame(minHeight: 10) // Needed so ScrollView doesn't collapse at start...
   }
    
    init(entrySelection: Binding<String?>, alwaysShowThumbnails: Bool = true, showSeparators: Bool = false, viewModel: ReaderContentListViewModel<C>) {
        _entrySelection = entrySelection
        self.alwaysShowThumbnails = alwaysShowThumbnails
        self.showSeparators = showSeparators
        self.viewModel = viewModel
    }
}

public struct ReaderContentList<C: ReaderContentModel>: View {
    let contents: [C]
    @Binding var entrySelection: String?
    var contentSortAscending = false
    var alwaysShowThumbnails = true
    //    var sortOrder = [KeyPathComparator(\(any ReaderContentModel).publicationDate, order: .reverse)] //KeyPathComparator(\TrackedWord.lastReadAtOrEpoch, order: .reverse)]
    var contentFilter: ((C) async throws -> Bool)? = nil
    var sortOrder = ReaderContentSortOrder.publicationDate
    
    @StateObject private var viewModel = ReaderContentListViewModel<C>()
    
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    @EnvironmentObject private var navigator: WebViewNavigator
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    @AppStorage("appTint") private var appTint: Color = Color("AccentColor")

    @ViewBuilder private var listItems: some View {
        ReaderContentListItems(viewModel: viewModel, entrySelection: $entrySelection, contentSortAscending: contentSortAscending, alwaysShowThumbnails: alwaysShowThumbnails, showSeparators: false)
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
                    .listRowSeparatorIfAvailable(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackgroundIfAvailable(.hidden)
            .listItemTint(appTint)
#endif
        }
        .task { @MainActor in
            try? await viewModel.load(contents: contents, sortOrder: sortOrder, contentFilter: contentFilter)
        }
        .onChange(of: contents) { contents in
            Task { @MainActor in
                try? await viewModel.load(contents: contents, sortOrder: sortOrder, contentFilter: contentFilter)
            }
        }
        .onChange(of: readerFileManager.ebookFiles) { ebookFiles in
            Task { @MainActor in
                try? await viewModel.load(contents: contents, sortOrder: sortOrder, contentFilter: contentFilter)
            }
        }
    }
    
    public init(contents: [C], entrySelection: Binding<String?>, contentSortAscending: Bool = false, alwaysShowThumbnails: Bool = true, sortOrder: ReaderContentSortOrder, contentFilter: ((C) async throws -> Bool)? = nil) {
        self.contents = contents
        _entrySelection = entrySelection
        self.alwaysShowThumbnails = alwaysShowThumbnails
        self.contentSortAscending = contentSortAscending
        self.sortOrder = sortOrder
        self.contentFilter = contentFilter
    }
}

public struct ReaderContentListItems<C: ReaderContentModel>: View {
    @ObservedObject private var viewModel = ReaderContentListViewModel<C>()
//    let contents: [C]
    // TODO: Something with this triggers repreatedly in printchanges; change to an environmentkey
    @Binding var entrySelection: String?
    var contentSortAscending = false
    var alwaysShowThumbnails = true
    var showSeparators = false
//    var contentFilter: ((C) async throws -> Bool)? = nil
//    var sortOrder = [KeyPathComparator(\(any ReaderContentModel).publicationDate, order: .reverse)] //KeyPathComparator(\TrackedWord.lastReadAtOrEpoch, order: .reverse)]
//    var sortOrder = ReaderContentSortOrder.publicationDate
    
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    @EnvironmentObject private var navigator: WebViewNavigator
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    
    public var body: some View {
        ReaderContentInnerListItems(entrySelection: $entrySelection, alwaysShowThumbnails: alwaysShowThumbnails, showSeparators: showSeparators, viewModel: viewModel)
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
                    refreshSelection(state: state, oldState: oldState)
                }
            }
            .onChange(of: viewModel.filteredContents/*, debounceTime: 0.1*/) { contents in
                Task { @MainActor in
                    refreshSelection(state: readerViewModel.state)
                }
            }
            .task { @MainActor in
                refreshSelection(state: readerViewModel.state)
            }
        //            .onChange(of: contents) { contents in
        //                Task { @MainActor in
        //                    try? await viewModel.load(contents: contents, contentFilter: contentFilter, sortOrder: sortOrder)
        //                    refreshSelection(state: readerState)
        //                }
        //            }
    }
    
    public init(viewModel: ReaderContentListViewModel<C>, entrySelection: Binding<String?>, contentSortAscending: Bool = false, alwaysShowThumbnails: Bool = true, showSeparators: Bool = false) {
        self.viewModel = viewModel
        _entrySelection = entrySelection
        self.alwaysShowThumbnails = alwaysShowThumbnails
        self.showSeparators = showSeparators
        self.contentSortAscending = contentSortAscending
    }
    
    private func refreshSelection(state: WebViewState, oldState: WebViewState? = nil) {
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
        return ReaderContentList(contents: contents, entrySelection: entrySelection, sortOrder: sortOrder, contentFilter: contentFilter)
    }
}
