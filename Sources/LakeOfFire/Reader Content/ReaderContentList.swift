import SwiftUI
import SwiftUIWebView
import RealmSwift
import RealmSwiftGaps
import SwiftUtilities
import LakeKit

@globalActor
public actor ReaderContentListActor: CachedRealmsActor {
    public static var shared = ReaderContentListActor()
    
    public var cachedRealms = [String: RealmSwift.Realm]()
    
    public func getCachedRealm(key: String) async -> Realm? {
        return cachedRealms[key]
    }
    
    public func setCachedRealm(_ realm: Realm, key: String) async {
        cachedRealms[key] = realm
    }
}

public class ReaderContentListModalsModel: ObservableObject {
    @Published var confirmDelete: Bool = false
    @Published var confirmDeletionOf: (any DeletableReaderContent)?
    
    public init() { }
}

struct ReaderContentListSheetsModifier: ViewModifier {
    let isActive: Bool
    @ObservedObject var readerContentListModalsModel: ReaderContentListModalsModel
    
    func body(content: Content) -> some View {
        content
            .alert("Delete Confirmation", isPresented: $readerContentListModalsModel.confirmDelete.gatedBy(isActive), actions: {
                Button("Cancel", role: .cancel) {
                    readerContentListModalsModel.confirmDeletionOf = nil
                }
                Button("Delete", role: .destructive) {
                    Task { @MainActor in
                        try await readerContentListModalsModel.confirmDeletionOf?.delete()
                    }
                }
            }, message: {
                Text("Do you really want to delete \(readerContentListModalsModel.confirmDeletionOf?.title.truncate(20) ?? "")? Deletion cannot be undone.")
            })
    }
}

public extension View {
    func readerContentListSheets(isActive: Bool, readerContentListModalsModel: ReaderContentListModalsModel) -> some View {
        modifier(
            ReaderContentListSheetsModifier(
                isActive: isActive,
                readerContentListModalsModel: readerContentListModalsModel
            )
        )
    }
}

struct ListItemToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(.plain)
        .background(configuration.isOn ? Color.accentColor : Color.clear)
    }
}

public enum ReaderContentSortOrder {
    case publicationDate
    case createdAt
    case lastVisitedAt
}

public class ReaderContentListViewModel<C: ReaderContentProtocol>: ObservableObject {
    public init() { }
    
    @Published var filteredContents: [C] = []
    var filteredContentIDs: [String] = []
    var realmConfiguration: Realm.Configuration?
    var refreshSelectionTask: Task<Void, Error>?
    @Published var loadContentsTask: Task<Void, Error>?
    
    @Published var hasLoadedBefore = false
    
    var isLoading: Bool {
        return loadContentsTask != nil
    }
    
    var showLoadingIndicator: Bool {
        return !hasLoadedBefore || isLoading
    }
    
    @MainActor
    public func load(contents: [C], sortOrder: ReaderContentSortOrder? = nil, contentFilter: (@ReaderContentListActor (C) async throws -> Bool)? = nil) async throws {
        if sortOrder == nil && contentFilter == nil {
            filteredContentIDs = contents.map { $0.compoundKey }
            filteredContents = contents
            return
        }
        
        let realmConfig = contents.first?.realm?.configuration
        self.realmConfiguration = realmConfig
        let refs = contents.map { ThreadSafeReference(to: $0) }
        loadContentsTask?.cancel()
        loadContentsTask = Task { @ReaderContentListActor in
            var filtered: [C] = []
            //            let filtered: AsyncFilterSequence<AnyRealmCollection<ReaderContentType>> = contents.filter({
            //                try await contentFilter($0)
            //            })
            guard let realmConfig else {
                await { @MainActor [weak self] in
                    self?.filteredContentIDs.removeAll()
                    self?.filteredContents.removeAll()
                    self?.hasLoadedBefore = true
                }()
                return
            }
            let realm = try await ReaderContentListActor.shared.cachedRealm(for: realmConfig)
            let contents = refs.compactMap { realm.resolve($0) }
            for content in contents {
                try Task.checkCancellation()
                if try await contentFilter?(content) ?? true {
                    filtered.append(content)
                }
            }
            
            if let sortOrder {
                switch sortOrder {
                case .publicationDate:
                    filtered = filtered.sorted(using: [KeyPathComparator(\.publicationDate, order: .reverse)])
                case .createdAt:
                    filtered = filtered.sorted(using: [KeyPathComparator(\.createdAt, order: .reverse)])
                case .lastVisitedAt:
                    if let filteredHistoryRecords = filtered as? [HistoryRecord] {
                        filtered = filteredHistoryRecords.sorted(using: [KeyPathComparator(\.lastVisitedAt, order: .reverse)]) as? [C] ?? []
                    } else {
                        print("ERROR No sorting for lastVisitedAt unless HistoryRecord")
                    }
                }
            }
            try Task.checkCancellation()
            
            // TODO: Pagination
            let ids = Array(filtered.prefix(10_000)).map { $0.compoundKey }
            try await { @MainActor [weak self] in
                try Task.checkCancellation()
                guard let self = self else { return }
                let realm = try await Realm(configuration: realmConfig, actor: MainActor.shared)
                let contents = ids.compactMap { realm.object(ofType: C.self, forPrimaryKey: $0) }
                filteredContentIDs = ids
                filteredContents = (contents as [any ReaderContentProtocol]) as? [C] ?? filteredContents
            }()
            
            await { @MainActor [weak self] in
                self?.hasLoadedBefore = true
            }()
        }
        try? await loadContentsTask?.value
        loadContentsTask = nil
    }
}

fileprivate struct ReaderContentInnerListItem<C: ReaderContentProtocol>: View {
    let content: C
    @Binding var entrySelection: String?
    var alwaysShowThumbnails = true
    var showSeparators = false
    @ObservedObject var viewModel: ReaderContentListViewModel<C>
    
    @StateObject private var cloudDriveSyncStatusModel = CloudDriveSyncStatusModel()
    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel
    
    @ScaledMetric(relativeTo: .headline) private var maxCellHeight: CGFloat = 100
    
    @ViewBuilder private func unstyledCell(item: C) -> some View {
        item.readerContentCellView(
            maxCellHeight: maxCellHeight,
            alwaysShowThumbnails: alwaysShowThumbnails,
            isEbookStyle: (item as? PhysicalMediaCapableProtocol)?.isPhysicalMedia ?? false
        )
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
            // TODO: Optimize by using state instead of dynamic binding, and get rid of the readerWebViewState and just use readerPageURL
            Toggle(isOn: Binding<Bool>(
                get: {
                    //                                itemSelection == feedEntry.compoundKey && readerState.matches(content: feedEntry)
                    entrySelection == content.compoundKey
                    //                    readerWebViewState.matches(content: content)
                },
                set: {
                    let newValue = $0 ? content.compoundKey : nil
                    if entrySelection != newValue {
                        entrySelection = newValue
                    }
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
            
            if showSeparators, content.compoundKey != viewModel.filteredContentIDs.last {
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
                await cloudDriveSyncStatusModel.refreshAsync(item: item)
            }
        }
    }
}

fileprivate struct ReaderContentInnerListItems<C: ReaderContentProtocol>: View {
    @Binding var entrySelection: String?
    var alwaysShowThumbnails = true
    var showSeparators = false
    @ObservedObject private var viewModel: ReaderContentListViewModel<C>
    
    var body: some View {
        Group {
            ForEach(viewModel.filteredContents, id: \.compoundKey) { (content: C) in
                ReaderContentInnerListItem(
                    content: content,
                    entrySelection: $entrySelection,
                    alwaysShowThumbnails: alwaysShowThumbnails,
                    showSeparators: showSeparators,
                    viewModel: viewModel
                )
            }
            .modifier {
#if os(macOS)
                $0.headerProminence(.increased)
#else
                $0.listRowInsets(.init(top: 4, leading: 8, bottom: 4, trailing: 8))
#endif
            }
        }
        .frame(minHeight: 10) // Needed so ScrollView doesn't collapse at start...
    }
    
    init(
        entrySelection: Binding<String?>,
        alwaysShowThumbnails: Bool = true,
        showSeparators: Bool = false,
        viewModel: ReaderContentListViewModel<C>
    ) {
        _entrySelection = entrySelection
        self.alwaysShowThumbnails = alwaysShowThumbnails
        self.showSeparators = showSeparators
        self.viewModel = viewModel
    }
}

public struct ReaderContentList<C: ReaderContentProtocol>: View {
    let contents: [C]
    @Binding var entrySelection: String?
    var contentSortAscending = false
    var alwaysShowThumbnails = true
    //    var sortOrder = [KeyPathComparator(\(any ReaderContentProtocol).publicationDate, order: .reverse)] //KeyPathComparator(\TrackedWord.lastReadAtOrEpoch, order: .reverse)]
    var contentFilter: ((C) async throws -> Bool)? = nil
    var sortOrder = ReaderContentSortOrder.publicationDate
    
    @StateObject private var viewModel = ReaderContentListViewModel<C>()
    
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

public struct ReaderContentListItems<C: ReaderContentProtocol>: View {
    @ObservedObject private var viewModel = ReaderContentListViewModel<C>()
    //    let contents: [C]
    // TODO: Something with this triggers repreatedly in printchanges; change to an environmentkey
    @Binding var entrySelection: String?
    var contentSortAscending = false
    var alwaysShowThumbnails = true
    var showSeparators = false
    //    var contentFilter: ((C) async throws -> Bool)? = nil
    //    var sortOrder = [KeyPathComparator(\(any ReaderContentProtocol).publicationDate, order: .reverse)] //KeyPathComparator(\TrackedWord.lastReadAtOrEpoch, order: .reverse)]
    //    var sortOrder = ReaderContentSortOrder.publicationDate
    
    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel
    
    public var body: some View {
        ReaderContentInnerListItems(
            entrySelection: $entrySelection,
            alwaysShowThumbnails: alwaysShowThumbnails,
            showSeparators: showSeparators,
            viewModel: viewModel
        )
        .onChange(of: entrySelection) { [oldValue = entrySelection] itemSelection in
            guard oldValue != itemSelection, let itemSelection = itemSelection, let content = viewModel.filteredContents.first(where: { $0.compoundKey == itemSelection }), !content.url.matchesReaderURL(readerContent.pageURL) else { return }
            Task { @MainActor in
                try await navigator.load(
                    content: content,
                    readerModeViewModel: readerModeViewModel
                )
                // TODO: This is crashy sadly.
                //                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                //                        scrollViewProxy.scrollTo(entrySelection)
                //                    }
            }
        }
        .onChange(of: readerContent.pageURL) { [oldPageURL = readerContent.pageURL] readerPageURL in
            if oldPageURL != readerPageURL {
                refreshSelection(readerPageURL: readerPageURL, isReaderProvisionallyNavigating: readerContent.isReaderProvisionallyNavigating, oldPageURL: oldPageURL)
            }
        }
        .onChange(of: viewModel.filteredContents/*, debounceTime: 0.1*/) { contents in
            Task { @MainActor in
                refreshSelection(readerPageURL: readerContent.pageURL, isReaderProvisionallyNavigating: readerContent.isReaderProvisionallyNavigating)
            }
        }
        .task { @MainActor in
            refreshSelection(readerPageURL: readerContent.pageURL, isReaderProvisionallyNavigating: readerContent.isReaderProvisionallyNavigating)
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
    
    private func refreshSelection(readerPageURL: URL, isReaderProvisionallyNavigating: Bool, oldPageURL: URL? = nil) {
        viewModel.refreshSelectionTask?.cancel()
        guard !isReaderProvisionallyNavigating else { return }
        
        //        let readerContentCompoundKey = readerContent.compoundKey
        let entrySelection = entrySelection
        let filteredContentURLs = viewModel.filteredContents.map { $0.url }
        viewModel.refreshSelectionTask = Task.detached {
            try Task.checkCancellation()
            do {
                if !readerPageURL.isNativeReaderView,
                   let entrySelection = entrySelection,
                   let idx = viewModel.filteredContentIDs.firstIndex(of: entrySelection),
                   idx < filteredContentURLs.count,
                   !filteredContentURLs[idx].matchesReaderURL(readerPageURL) {
                    async let task = { @MainActor in
                        try Task.checkCancellation()
                        self.entrySelection = nil
                    }()
                    try await task
                }
                
                guard !readerPageURL.isNativeReaderView, filteredContentURLs.contains(readerPageURL) else {
                    if !readerPageURL.absoluteString.hasPrefix("internal://local/load"), entrySelection != nil {
                        async let task = { @MainActor in
                            try Task.checkCancellation()
                            self.entrySelection = nil
                        }()
                        try await task
                    }
                    return
                }
                //                if entrySelection == nil, oldState?.pageURL != state.pageURL, content.url != state.pageURL {
                if entrySelection == nil, oldPageURL != readerPageURL, let idx = filteredContentURLs.firstIndex(of: readerPageURL) {
                    let contentKey = viewModel.filteredContentIDs[idx]
                    async let task = { @MainActor in
                        try Task.checkCancellation()
                        self.entrySelection = contentKey
                    }()
                    try await task
                }
            } catch { }
        }
    }
}

public extension ReaderContentProtocol {
    static func readerContentListView(contents: [Self], entrySelection: Binding<String?>, sortOrder: ReaderContentSortOrder, contentFilter: ((Self) async throws -> Bool)? = nil) -> some View {
        return ReaderContentList(contents: contents, entrySelection: entrySelection, sortOrder: sortOrder, contentFilter: contentFilter)
    }
}
