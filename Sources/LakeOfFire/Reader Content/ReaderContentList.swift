import SwiftUI
import SwiftUIWebView
import RealmSwift
import RealmSwiftGaps
import SwiftUtilities
import LakeKit

public struct ReaderContentGroupingSection<C: ReaderContentProtocol>: Identifiable {
    public let id: String
    public let title: String
    public let items: [C]
    public let initiallyExpanded: Bool

    public init(id: String, title: String, items: [C], initiallyExpanded: Bool = true) {
        self.id = id
        self.title = title
        self.items = items
        self.initiallyExpanded = initiallyExpanded
    }
}

@globalActor
public actor ReaderContentListActor: CachedRealmsActor {
    public static let shared = ReaderContentListActor()

    public var cachedRealms = [String: RealmSwift.Realm]()

    public func getCachedRealm(key: String) async -> Realm? {
        cachedRealms[key]
    }

    public func setCachedRealm(_ realm: Realm, key: String) async {
        cachedRealms[key] = realm
    }
}

@MainActor
public class ReaderContentListModalsModel: ObservableObject {
    @Published var confirmDelete: Bool = false
    @Published var confirmDeletionOf: [(any DeletableReaderContent)]? {
        didSet { refreshDeletionTexts() }
    }
    @Published var deletionConfirmationTitle: String = "Are you sure?"
    @Published var deletionConfirmationMessage: String = "Do you really want to delete?"
    @Published var deletionConfirmationActionTitle: String = "Delete"

    public init() {
        refreshDeletionTexts()
    }

    private func refreshDeletionTexts() {
        guard let first = confirmDeletionOf?.first else {
            deletionConfirmationTitle = "Are you sure?"
            deletionConfirmationMessage = "Do you really want to delete?"
            deletionConfirmationActionTitle = "Delete"
            return
        }
        deletionConfirmationTitle = first.deletionConfirmationTitle
        deletionConfirmationMessage = first.deletionConfirmationMessage
        deletionConfirmationActionTitle = first.deletionConfirmationActionTitle
    }
}

struct ReaderContentListSheetsModifier: ViewModifier {
    @Binding var isActive: Bool
    let origin: String

    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel

    func body(content: Content) -> some View {
        let hostID = ObjectIdentifier(readerContentListModalsModel)
        let logPrefix = "# DELETEMODAL [\(origin)] host=\(hostID)"
        content
            .onChange(of: readerContentListModalsModel.confirmDelete) { newValue in
                debugPrint("\(logPrefix) confirmDelete changed -> \(newValue) isActive=\(isActive)")
            }
            .onReceive(readerContentListModalsModel.$confirmDeletionOf) { newValue in
                debugPrint("\(logPrefix) confirmDeletionOf updated count=\(newValue?.count ?? 0)")
            }
            .alert(readerContentListModalsModel.deletionConfirmationTitle, isPresented: Binding<Bool>(
                get: {
                    readerContentListModalsModel.confirmDelete && isActive
                },
                set: { newValue in
                    debugPrint("\(logPrefix) SHEET SET", newValue)
                    if isActive {
                        Task { @MainActor in
                            readerContentListModalsModel.confirmDelete = newValue
                        }
                    } else {
                        debugPrint("\(logPrefix) ignoring set newValue=\(newValue) because isActive=false")
                    }
                }
            ), actions: {
                Button("Cancel", role: .cancel) {
                    debugPrint("\(logPrefix) cancel tapped")
                    readerContentListModalsModel.confirmDeletionOf = nil
                }
                .modifier {
                    if #available(iOS 26, macOS 26, *) { $0.tint(.primary) } else { $0 }
                }
                Button(readerContentListModalsModel.deletionConfirmationActionTitle, role: .destructive) {
                    guard let items = readerContentListModalsModel.confirmDeletionOf else { return }
                    debugPrint("\(logPrefix) delete confirmed items=\(items.count)")
                    Task { @MainActor in
                        for item in items {
                            try await item.delete()
                        }
                    }
                }
            }, message: {
                Text(readerContentListModalsModel.deletionConfirmationMessage)
            })
            .onAppear {
                debugPrint("\(logPrefix) sheets modifier appear isActive=\(isActive)")
            }
    }
}

public extension View {
    func readerContentListSheets(isActive: Binding<Bool>, origin: String) -> some View {
        modifier(
            ReaderContentListSheetsModifier(
                isActive: isActive,
                origin: origin
            )
        )
    }
}

private extension View {
    @ViewBuilder
    func readerContentListRowStyle(showSeparators: Bool = false) -> some View {
        if #available(iOS 15, macOS 12, *) {
            self
                .listRowInsets(.init())
                .listRowSeparator(showSeparators ? .visible : .hidden)
        } else {
            self.listRowInsets(.init())
        }
    }
}

private struct ReaderContentRowSeparatorModifier: ViewModifier {
    let isFirst: Bool
    let isLast: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 15, macOS 12, *) {
            content
                .listRowSeparator(isFirst ? .hidden : .automatic, edges: .top)
                .listRowSeparator(isLast ? .hidden : .automatic, edges: .bottom)
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func readerContentListLayoutAdjustments() -> some View {
        if #available(iOS 17, macOS 14, *) {
            self
#if os(iOS)
                .listSectionSpacing(0)
#endif
                .contentMargins(.top, 0, for: .scrollContent)
        } else {
            self
        }
    }
}

struct ReaderContentListAppearance: Sendable {
    var alwaysShowThumbnails: Bool = true
    var showSeparators: Bool = false
    var useCardBackground: Bool = false
    var clearRowBackground: Bool = false
}

private struct ReaderContentSelectionSyncModifier<C: ReaderContentProtocol>: ViewModifier {
    @ObservedObject var viewModel: ReaderContentListViewModel<C>
    @Binding var entrySelection: String?
    let enabled: Bool
    let onSelection: ((C) -> Void)?

    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    @Environment(\.contentSelectionNavigationHint) private var contentSelectionNavigationHint
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel

    func body(content: Content) -> some View {
        let shouldSyncToReader = enabled && onSelection == nil
        let shouldSkipWhenAlreadyLoaded = onSelection == nil

        return content
            .onChange(of: entrySelection) { [oldValue = entrySelection] itemSelection in
                guard enabled else { return }
                guard oldValue != itemSelection,
                      let itemSelection,
                      let selectedContent = viewModel.filteredContents.first(where: { $0.compoundKey == itemSelection }),
                      (!shouldSkipWhenAlreadyLoaded || !selectedContent.url.matchesReaderURL(readerContent.pageURL))
                else {
                    return
                }

                Task { @MainActor in
                    if let onSelection {
                        onSelection(selectedContent)
                        if entrySelection == itemSelection {
                            entrySelection = nil
                        }
                        return
                    }

                    guard shouldSyncToReader else { return }
                    contentSelectionNavigationHint?(selectedContent.url, selectedContent.compoundKey)
                    do {
                        try await navigator.load(
                            content: selectedContent,
                            readerModeViewModel: readerModeViewModel
                        )
                    } catch {
                        debugPrint("Failed to load reader content for selection", error)
                    }
                    if entrySelection == itemSelection {
                        entrySelection = nil
                    }
                }
            }
            .onChange(of: readerContent.pageURL) { [oldPageURL = readerContent.pageURL] readerPageURL in
                guard shouldSyncToReader else { return }
                if oldPageURL != readerPageURL {
                    refreshSelection(
                        readerPageURL: readerPageURL,
                        isReaderProvisionallyNavigating: readerContent.isReaderProvisionallyNavigating,
                        oldPageURL: oldPageURL
                    )
                }
            }
            .onChange(of: viewModel.filteredContents) { _ in
                guard shouldSyncToReader else { return }
                Task { @MainActor in
                    refreshSelection(
                        readerPageURL: readerContent.pageURL,
                        isReaderProvisionallyNavigating: readerContent.isReaderProvisionallyNavigating
                    )
                }
            }
            .task { @MainActor in
                guard shouldSyncToReader else { return }
                refreshSelection(
                    readerPageURL: readerContent.pageURL,
                    isReaderProvisionallyNavigating: readerContent.isReaderProvisionallyNavigating
                )
            }
    }

    private func refreshSelection(
        readerPageURL: URL,
        isReaderProvisionallyNavigating: Bool,
        oldPageURL: URL? = nil
    ) {
        viewModel.refreshSelectionTask?.cancel()
        guard !isReaderProvisionallyNavigating else { return }

        let currentSelection = entrySelection
        let filteredContentURLs = viewModel.filteredContents.map(\.url)

        viewModel.refreshSelectionTask = Task.detached {
            try Task.checkCancellation()
            do {
                if !readerPageURL.isNativeReaderView,
                   let currentSelection,
                   let idx = await viewModel.filteredContentIDs.firstIndex(of: currentSelection),
                   idx < filteredContentURLs.count,
                   !filteredContentURLs[idx].matchesReaderURL(readerPageURL) {
                    async let clearTask = { @MainActor in
                        try Task.checkCancellation()
                        self.entrySelection = nil
                    }()
                    try await clearTask
                }

                guard !readerPageURL.isNativeReaderView,
                      filteredContentURLs.contains(readerPageURL)
                else {
                    if !readerPageURL.absoluteString.hasPrefix("internal://local/load"),
                       currentSelection != nil {
                        async let clearTask = { @MainActor in
                            try Task.checkCancellation()
                            self.entrySelection = nil
                        }()
                        try await clearTask
                    }
                    return
                }

                if currentSelection == nil,
                   oldPageURL != readerPageURL,
                   let idx = filteredContentURLs.firstIndex(of: readerPageURL) {
                    let contentKey = await viewModel.filteredContentIDs[idx]
                    async let selectTask = { @MainActor in
                        try Task.checkCancellation()
                        self.entrySelection = contentKey
                    }()
                    try await selectTask
                }
            } catch { }
        }
    }
}

private extension View {
    func readerContentSelectionSync<C: ReaderContentProtocol>(
        viewModel: ReaderContentListViewModel<C>,
        entrySelection: Binding<String?>,
        enabled: Bool,
        onSelection: ((C) -> Void)? = nil
    ) -> some View {
        modifier(
            ReaderContentSelectionSyncModifier(
                viewModel: viewModel,
                entrySelection: entrySelection,
                enabled: enabled,
                onSelection: onSelection
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
    case title
    case urlAddress
}

@MainActor
public class ReaderContentListViewModel<C: ReaderContentProtocol>: ObservableObject {
    public init() { }

    @Published public var filteredContents: [C] = []
    public var filteredContentIDs: [String] = []
    public var realmConfiguration: Realm.Configuration?
    var refreshSelectionTask: Task<Void, Error>?
    @Published public var loadContentsTask: Task<Void, Error>?

    @Published public var hasLoadedBefore = false

    public var isLoading: Bool {
        loadContentsTask != nil
    }

    public var showLoadingIndicator: Bool {
        !hasLoadedBefore || isLoading
    }

    @MainActor
    public func load(
        contents: [C],
        sortOrder: ReaderContentSortOrder? = nil,
        contentFilter: (@ReaderContentListActor (C) async throws -> Bool)? = nil
    ) async throws {
        try await load(
            contents: contents,
            contentFilter: contentFilter.map { contentFilter in
                { @ReaderContentListActor _, content in
                    try await contentFilter(content)
                }
            },
            sortOrder: sortOrder,
            postSortTransform: nil
        )
    }

    @MainActor
    public func load(
        contents: [C],
        contentFilter: (@ReaderContentListActor (Int, C) async throws -> Bool)? = nil,
        sortOrder: ReaderContentSortOrder? = nil,
        postSortTransform: (@ReaderContentListActor ([C]) -> [C])? = nil
    ) async throws {
        let contentIDs = contents.map(\.compoundKey)

        if sortOrder == nil && contentFilter == nil && postSortTransform == nil {
            filteredContentIDs = contentIDs
            filteredContents = contents.map { $0.realm == nil ? $0 : $0.freeze() }
            hasLoadedBefore = true
            return
        }

        let realmConfig = contents.first?.realm?.configuration
        realmConfiguration = realmConfig
        loadContentsTask?.cancel()
        loadContentsTask = Task { @ReaderContentListActor in
            var filtered: [C] = []

            if let realmConfig {
                let realm = try await ReaderContentListActor.shared.cachedRealm(for: realmConfig)
                let resolvedContents = contentIDs.compactMap { realm.object(ofType: C.self, forPrimaryKey: $0) }
                for (idx, content) in resolvedContents.enumerated() {
                    try Task.checkCancellation()
                    if try await contentFilter?(idx, content) ?? true {
                        filtered.append(content)
                    }
                }
            } else {
                for (idx, content) in contents.enumerated() {
                    try Task.checkCancellation()
                    if try await contentFilter?(idx, content) ?? true {
                        filtered.append(content)
                    }
                }
            }

            if let sortOrder {
                switch sortOrder {
                case .publicationDate:
                    filtered = filtered.sorted { lhs, rhs in
                        switch (lhs.publicationDate, rhs.publicationDate) {
                        case let (l?, r?):
                            if l != r { return l > r }
                            return lhs.createdAt > rhs.createdAt
                        case (nil, nil):
                            return lhs.createdAt > rhs.createdAt
                        case (nil, _?):
                            return false
                        case (_?, nil):
                            return true
                        }
                    }
                case .createdAt:
                    filtered = filtered.sorted(using: [KeyPathComparator(\.createdAt, order: .reverse)])
                case .lastVisitedAt:
                    if let filteredHistoryRecords = filtered as? [HistoryRecord] {
                        filtered = filteredHistoryRecords.sorted(using: [KeyPathComparator(\.lastVisitedAt, order: .reverse)]) as? [C] ?? []
                    } else {
                        print("ERROR No sorting for lastVisitedAt unless HistoryRecord")
                    }
                case .title:
                    filtered = filtered.sorted { lhs, rhs in
                        if lhs.title != rhs.title {
                            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                        }
                        return lhs.createdAt > rhs.createdAt
                    }
                case .urlAddress:
                    filtered = filtered.sorted { lhs, rhs in
                        let l = lhs.url.absoluteString
                        let r = rhs.url.absoluteString
                        if l != r {
                            return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
                        }
                        return lhs.createdAt > rhs.createdAt
                    }
                }
            }

            if let postSortTransform {
                filtered = postSortTransform(filtered)
            }
            try Task.checkCancellation()

            let ids = Array(filtered.prefix(10_000)).map(\.compoundKey)
            try await { @MainActor [weak self] in
                guard let self else { return }
                self.filteredContentIDs = ids
                if let realmConfig {
                    let realm = try await Realm(configuration: realmConfig, actor: MainActor.shared)
                    self.filteredContents = ids.compactMap { realm.object(ofType: C.self, forPrimaryKey: $0)?.freeze() }
                } else {
                    self.filteredContents = filtered.map { $0.realm == nil ? $0 : $0.freeze() }
                }
                self.hasLoadedBefore = true
            }()
        }

        try? await loadContentsTask?.value
        loadContentsTask = nil
    }
}

fileprivate struct ReaderContentInnerListItem<C: ReaderContentProtocol>: View {
    let content: C
    @Binding var entrySelection: String?
    let includeSource: Bool
    let appearance: ReaderContentListAppearance
    let isFirst: Bool
    let isLast: Bool
    @ObservedObject var viewModel: ReaderContentListViewModel<C>
    let onRequestDelete: (@MainActor (C) async throws -> Void)?
    let customMenuOptions: ((C) -> AnyView)?

    @StateObject private var cloudDriveSyncStatusModel = CloudDriveSyncStatusModel()
    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel

    @ScaledMetric(relativeTo: .headline) private var maxCellHeight: CGFloat = 120

    @ViewBuilder
    private func cell(item: C) -> some View {
        HStack(spacing: 0) {
            let shouldReserveThumbnailSpace = appearance.alwaysShowThumbnails && item.imageUrl != nil
            let cellAppearance = ReaderContentCellAppearance(
                maxCellHeight: maxCellHeight,
                alwaysShowThumbnails: shouldReserveThumbnailSpace,
                isEbookStyle: item.isPhysicalMedia,
                includeSource: includeSource,
                thumbnailCornerRadius: 12
            )
            if let customMenuOptions {
                item.readerContentCellView(
                    appearance: cellAppearance,
                    customMenuOptions: customMenuOptions
                )
                .readerContentCellStyle(.plain)
            } else {
                item.readerContentCellView(appearance: cellAppearance)
                    .readerContentCellStyle(.plain)
            }
        }
        .padding(11)
    }

    @ViewBuilder
    private func rowContent(item: C) -> some View {
        if appearance.useCardBackground {
            cell(item: item)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .modifier {
                            if #available(iOS 17, macOS 14, *) {
                                $0.fill(Color(.tertiarySystemFill))
                            } else {
#if os(iOS)
                                $0.fill(Color(.secondarySystemFill))
#else
                                $0.fill(Color.gray.opacity(0.12))
#endif
                            }
                        }
                )
        } else {
            cell(item: item)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if #available(iOS 16.0, *) {
                rowContent(item: content)
                    .tag(content.compoundKey)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("ReaderContentRow.\(content.compoundKey)")
                    .accessibilityLabel(content.title)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        entrySelection = content.compoundKey
                    }
            } else {
                Button {
                    entrySelection = content.compoundKey
                } label: {
                    rowContent(item: content)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.borderless)
                .tint(.primary)
                .frame(maxWidth: .infinity)
            }
        }
#if os(iOS)
        .deleteDisabled((content as? any DeletableReaderContent) == nil)
        .swipeActions {
            if let deletable = content as? any DeletableReaderContent {
                Button(role: .destructive) {
                    if let onRequestDelete {
                        Task { @MainActor in
                            do {
                                try await onRequestDelete(self.content)
                            } catch {
                                print(error)
                            }
                        }
                    } else {
                        readerContentListModalsModel.confirmDeletionOf = [deletable]
                        if readerContentListModalsModel.confirmDeletionOf != nil {
                            readerContentListModalsModel.confirmDelete = true
                        }
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
#endif
#if os(macOS)
        .contextMenu {
            if let deletable = content as? any DeletableReaderContent {
                Button(role: .destructive) {
                    if let onRequestDelete {
                        Task { @MainActor in
                            do {
                                try await onRequestDelete(self.content)
                            } catch {
                                print(error)
                            }
                        }
                    } else {
                        readerContentListModalsModel.confirmDeletionOf = [deletable]
                        readerContentListModalsModel.confirmDelete = true
                    }
                } label: {
                    Label(deletable.deleteActionTitle, systemImage: "trash")
                }
            }
        }
#endif
#if os(iOS) || os(macOS)
        .modifier(
            ReaderContentRowSeparatorModifier(
                isFirst: isFirst,
                isLast: isLast
            )
        )
#endif
        .modifier {
            if appearance.useCardBackground || appearance.clearRowBackground {
                $0.listRowBackground(Color.clear)
            } else {
                $0
            }
        }
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
    let includeSource: Bool
    let appearance: ReaderContentListAppearance
    @ObservedObject private var viewModel: ReaderContentListViewModel<C>
    let onRequestDelete: (@MainActor (C) async throws -> Void)?
    let customMenuOptions: ((C) -> AnyView)?

    var body: some View {
        let lastIndex = viewModel.filteredContents.indices.last
        Group {
            ForEach(Array(viewModel.filteredContents.enumerated()), id: \.element.compoundKey) { index, content in
                let isFirst = index == viewModel.filteredContents.startIndex
                let isLast = lastIndex.map { index == $0 } ?? false
                ReaderContentInnerListItem(
                    content: content,
                    entrySelection: $entrySelection,
                    includeSource: includeSource,
                    appearance: appearance,
                    isFirst: isFirst,
                    isLast: isLast,
                    viewModel: viewModel,
                    onRequestDelete: onRequestDelete,
                    customMenuOptions: customMenuOptions
                )
            }
        }
        .frame(minHeight: 10)
    }

    init(
        entrySelection: Binding<String?>,
        includeSource: Bool,
        appearance: ReaderContentListAppearance,
        viewModel: ReaderContentListViewModel<C>,
        onRequestDelete: (@MainActor (C) async throws -> Void)? = nil,
        customMenuOptions: ((C) -> AnyView)? = nil
    ) {
        _entrySelection = entrySelection
        self.includeSource = includeSource
        self.appearance = appearance
        self.viewModel = viewModel
        self.onRequestDelete = onRequestDelete
        self.customMenuOptions = customMenuOptions
    }
}

public struct ReaderContentList<C: ReaderContentProtocol, Header: View, EmptyState: View>: View {
    let contents: [C]
    var contentFilter: ((Int, C) async throws -> Bool)? = nil
    var sortOrder = ReaderContentSortOrder.publicationDate
    let postSortTransform: (@ReaderContentListActor ([C]) -> [C])?
    let includeSource: Bool
    @Binding var entrySelection: String?
    var contentSortAscending = false
    var alwaysShowThumbnails = true
    let contentSectionTitle: String?
    let allowEditing: Bool
    let onDelete: (@MainActor ([C]) async throws -> Void)?
    let customGrouping: (([C]) -> [ReaderContentGroupingSection<C>])?
    @ViewBuilder let headerView: () -> Header
    @ViewBuilder let emptyStateView: () -> EmptyState
    let customMenuOptions: ((C) -> AnyView)?
    let onContentSelected: ((C) -> Void)?

    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel

    @StateObject private var viewModel = ReaderContentListViewModel<C>()
    @AppStorage("appTint") private var appTint: Color = Color("AccentColor")
    @State private var groupedSections: [ReaderContentGroupingSection<C>] = []
    @State private var sectionExpanded: [String: Bool] = [:]

#if os(iOS)
    @Environment(\.editMode) private var editMode
#endif
    @State private var multiSelection = Set<String>()

    private var showEmptyState: Bool {
        !viewModel.showLoadingIndicator && viewModel.filteredContents.isEmpty
    }

    private var showDeletionToolbarButton: Bool {
        if allowEditing, C.self is DeletableReaderContent.Type {
#if os(iOS)
            return editMode?.wrappedValue != .inactive
#else
            return true
#endif
        }
        return false
    }

    private var isDeletionToolbarButtonDisabled: Bool {
        multiSelection.isEmpty
    }

    @ViewBuilder
    private var listItems: some View {
        ReaderContentListItems(
            viewModel: viewModel,
            entrySelection: $entrySelection,
            contentSortAscending: contentSortAscending,
            includeSource: includeSource,
            alwaysShowThumbnails: alwaysShowThumbnails,
            onRequestDelete: onRequestDeleteSingle,
            customMenuOptions: customMenuOptions,
            onContentSelected: onContentSelected
        )
    }

    private var onRequestDeleteSingle: (@MainActor (C) async throws -> Void)? {
        guard let onDelete else { return nil }
        return { content in
            try await onDelete([content])
        }
    }

    private var listContainer: some View {
        ZStack {
#if os(iOS)
            if allowEditing && editMode?.wrappedValue != .inactive {
                List(selection: $multiSelection) {
                    listContent
                }
            } else {
                List(selection: $entrySelection) {
                    listContent
                }
            }
#else
            List(selection: $entrySelection) {
                listContent
            }
#endif
        }
        .listItemTint(appTint)
        .readerContentListLayoutAdjustments()
    }

#if os(iOS)
    @ViewBuilder
    private var listContainerWithSpacing: some View {
        if #available(iOS 16, *) {
            listContainer.listRowSpacing(15)
        } else {
            listContainer
        }
    }
#else
    private var listContainerWithSpacing: some View { listContainer }
#endif

    public var body: some View {
        Group {
            listContainerWithSpacing
                .toolbar {
#if os(iOS)
                    ToolbarItem(placement: .topBarLeading) {
                        deletionToolbarButtonView
                    }
#elseif os(macOS)
                    ToolbarItem(placement: .destructiveAction) {
                        deletionToolbarButtonView
                    }
#endif
                }
                .onChange(of: multiSelection) { newSelection in
#if os(iOS)
                    guard editMode?.wrappedValue != .inactive else { return }
#endif
                    if newSelection.count == 1 {
                        entrySelection = newSelection.first
                    } else if newSelection.count > 1 {
                        entrySelection = nil
                    }
                }
                .task { @MainActor in
                    try? await viewModel.load(
                        contents: contents,
                        contentFilter: contentFilter,
                        sortOrder: sortOrder,
                        postSortTransform: postSortTransform
                    )
                    refreshGrouping()
                }
                .onChange(of: contents) { contents in
                    Task { @MainActor in
                        try? await viewModel.load(
                            contents: contents,
                            contentFilter: contentFilter,
                            sortOrder: sortOrder,
                            postSortTransform: postSortTransform
                        )
                        refreshGrouping()
                    }
                }
                .onChange(of: viewModel.filteredContents) { _ in
                    refreshGrouping()
                }
        }
        .readerContentSelectionSync(
            viewModel: viewModel,
            entrySelection: $entrySelection,
            enabled: true,
            onSelection: onContentSelected
        )
    }

    @ViewBuilder
    private var deletionToolbarButtonView: some View {
        if showDeletionToolbarButton {
            Button(role: .destructive) {
                let selected = viewModel.filteredContents.filter { multiSelection.contains($0.compoundKey) }
                if let onDelete {
                    Task { @MainActor in
                        do {
                            try await onDelete(selected)
                        } catch {
                            print(error)
                        }
                    }
                } else if let selected = selected as? [any DeletableReaderContent] {
                    readerContentListModalsModel.confirmDeletionOf = selected
                    readerContentListModalsModel.confirmDelete = true
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(isDeletionToolbarButtonDisabled)
        }
    }

    @ViewBuilder
    private var listContent: some View {
        Section {
            headerView()
                .listRowInsets(.init())
                .listRowBackground(Color.clear)
        }

        if customGrouping == nil {
            Section {
                if showEmptyState {
                    if #available(iOS 16, *) {
                        emptyStateView()
                            .padding(.top, 8)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .readerContentListRowStyle()
                            .listRowBackground(Color.clear)
                            .stackListStyle(.grouped)
                    }
                } else {
                    listItems
                        .readerContentListRowStyle()
                }
            } header: {
                if !showEmptyState, let contentSectionTitle {
                    Text(contentSectionTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .headerProminence(.increased)
        } else {
            if showEmptyState {
                if #available(iOS 16, *) {
                    Section {
                        emptyStateView()
                            .frame(maxHeight: .infinity, alignment: .top)
                            .listRowInsets(.init(top: 20, leading: 0, bottom: 0, trailing: 0))
                            .listRowBackground(Color.clear)
                            .stackListStyle(.grouped)
                    }
                }
            } else {
                ForEach(groupedSections) { section in
                    if #available(iOS 17, macOS 14, *) {
                        Section(isExpanded: binding(for: section.id)) {
                            let lastIndex = section.items.indices.last ?? section.items.startIndex
                            ForEach(Array(section.items.enumerated()), id: \.element.compoundKey) { index, content in
                                ReaderContentInnerListItem(
                                    content: content,
                                    entrySelection: $entrySelection,
                                    includeSource: includeSource,
                                    appearance: ReaderContentListAppearance(
                                        alwaysShowThumbnails: alwaysShowThumbnails,
                                        showSeparators: false,
                                        useCardBackground: false
                                    ),
                                    isFirst: index == section.items.startIndex,
                                    isLast: index == lastIndex,
                                    viewModel: viewModel,
                                    onRequestDelete: onRequestDeleteSingle,
                                    customMenuOptions: customMenuOptions
                                )
                            }
                            .readerContentListRowStyle()
                        } header: {
                            Text(section.title)
                        }
                        .headerProminence(.increased)
                    } else {
                        Section {
                            let lastIndex = section.items.indices.last ?? section.items.startIndex
                            ForEach(Array(section.items.enumerated()), id: \.element.compoundKey) { index, content in
                                ReaderContentInnerListItem(
                                    content: content,
                                    entrySelection: $entrySelection,
                                    includeSource: includeSource,
                                    appearance: ReaderContentListAppearance(
                                        alwaysShowThumbnails: alwaysShowThumbnails,
                                        showSeparators: false,
                                        useCardBackground: false
                                    ),
                                    isFirst: index == section.items.startIndex,
                                    isLast: index == lastIndex,
                                    viewModel: viewModel,
                                    onRequestDelete: onRequestDeleteSingle,
                                    customMenuOptions: customMenuOptions
                                )
                            }
                            .readerContentListRowStyle()
                        } header: {
                            Text(section.title)
                                .bold()
                                .foregroundStyle(.secondary)
                        }
                        .headerProminence(.increased)
                    }
                }
            }
        }
    }

    public init(
        contents: [C],
        contentFilter: ((Int, C) async throws -> Bool)? = nil,
        sortOrder: ReaderContentSortOrder,
        includeSource: Bool,
        entrySelection: Binding<String?>,
        contentSortAscending: Bool = false,
        alwaysShowThumbnails: Bool = true,
        contentSectionTitle: String? = nil,
        allowEditing: Bool = false,
        onDelete: (@MainActor ([C]) async throws -> Void)? = nil,
        customGrouping: (([C]) -> [ReaderContentGroupingSection<C>])? = nil,
        customMenuOptions: ((C) -> AnyView)? = nil,
        onContentSelected: ((C) -> Void)? = nil,
        postSortTransform: (@ReaderContentListActor ([C]) -> [C])? = nil,
        @ViewBuilder headerView: @escaping () -> Header,
        @ViewBuilder emptyStateView: @escaping () -> EmptyState
    ) {
        self.contents = contents
        self.contentFilter = contentFilter
        self.sortOrder = sortOrder
        self.includeSource = includeSource
        _entrySelection = entrySelection
        self.contentSortAscending = contentSortAscending
        self.alwaysShowThumbnails = alwaysShowThumbnails
        self.contentSectionTitle = contentSectionTitle
        self.allowEditing = allowEditing
        self.onDelete = onDelete
        self.customGrouping = customGrouping
        self.customMenuOptions = customMenuOptions
        self.onContentSelected = onContentSelected
        self.postSortTransform = postSortTransform
        self.headerView = headerView
        self.emptyStateView = emptyStateView
    }
}

public extension ReaderContentList where Header == EmptyView, EmptyState == EmptyView {
    init(
        contents: [C],
        entrySelection: Binding<String?>,
        contentSortAscending: Bool = false,
        alwaysShowThumbnails: Bool = true,
        includeSource: Bool = false,
        useCardBackground: Bool = true,
        clearRowBackground: Bool = false,
        sortOrder: ReaderContentSortOrder,
        contentFilter: ((C) async throws -> Bool)? = nil,
        allowEditing: Bool = false,
        onDelete: (([C]) -> Void)? = nil
    ) {
        self.init(
            contents: contents,
            contentFilter: contentFilter.map { contentFilter in
                { _, content in
                    try await contentFilter(content)
                }
            },
            sortOrder: sortOrder,
            includeSource: includeSource,
            entrySelection: entrySelection,
            contentSortAscending: contentSortAscending,
            alwaysShowThumbnails: alwaysShowThumbnails,
            contentSectionTitle: nil,
            allowEditing: allowEditing,
            onDelete: onDelete.map { onDelete in
                { @MainActor contents in
                    onDelete(contents)
                }
            },
            customGrouping: nil,
            customMenuOptions: nil,
            onContentSelected: nil,
            postSortTransform: nil,
            headerView: { EmptyView() },
            emptyStateView: { EmptyView() }
        )
    }

    init(
        contents: [C],
        contentFilter: ((Int, C) async throws -> Bool)? = nil,
        sortOrder: ReaderContentSortOrder,
        includeSource: Bool = false,
        entrySelection: Binding<String?>,
        contentSortAscending: Bool = false,
        alwaysShowThumbnails: Bool = true,
        contentSectionTitle: String? = nil,
        allowEditing: Bool = false,
        onDelete: (@MainActor ([C]) async throws -> Void)? = nil,
        customGrouping: (([C]) -> [ReaderContentGroupingSection<C>])? = nil,
        customMenuOptions: ((C) -> AnyView)? = nil,
        onContentSelected: ((C) -> Void)? = nil,
        postSortTransform: (@ReaderContentListActor ([C]) -> [C])? = nil
    ) {
        self.init(
            contents: contents,
            contentFilter: contentFilter,
            sortOrder: sortOrder,
            includeSource: includeSource,
            entrySelection: entrySelection,
            contentSortAscending: contentSortAscending,
            alwaysShowThumbnails: alwaysShowThumbnails,
            contentSectionTitle: contentSectionTitle,
            allowEditing: allowEditing,
            onDelete: onDelete,
            customGrouping: customGrouping,
            customMenuOptions: customMenuOptions,
            onContentSelected: onContentSelected,
            postSortTransform: postSortTransform,
            headerView: { EmptyView() },
            emptyStateView: { EmptyView() }
        )
    }
}

public struct ReaderContentListItems<C: ReaderContentProtocol>: View {
    @ObservedObject private var viewModel = ReaderContentListViewModel<C>()
    @Binding var entrySelection: String?
    var contentSortAscending = false
    let includeSource: Bool
    let appearance: ReaderContentListAppearance
    let onRequestDelete: (@MainActor (C) async throws -> Void)?
    let customMenuOptions: ((C) -> AnyView)?
    let onContentSelected: ((C) -> Void)?

    public var body: some View {
        ReaderContentInnerListItems(
            entrySelection: $entrySelection,
            includeSource: includeSource,
            appearance: appearance,
            viewModel: viewModel,
            onRequestDelete: onRequestDelete,
            customMenuOptions: customMenuOptions
        )
        .readerContentListRowStyle(showSeparators: appearance.showSeparators)
        .readerContentSelectionSync(
            viewModel: viewModel,
            entrySelection: $entrySelection,
            enabled: true,
            onSelection: onContentSelected
        )
    }

    public init(
        viewModel: ReaderContentListViewModel<C>,
        entrySelection: Binding<String?>,
        contentSortAscending: Bool = false,
        includeSource: Bool = false,
        alwaysShowThumbnails: Bool = true,
        showSeparators: Bool = false,
        useCardBackground: Bool = true,
        clearRowBackground: Bool = false,
        onRequestDelete: (@MainActor (C) async throws -> Void)? = nil,
        customMenuOptions: ((C) -> AnyView)? = nil,
        onContentSelected: ((C) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        _entrySelection = entrySelection
        self.contentSortAscending = contentSortAscending
        self.includeSource = includeSource
        self.appearance = ReaderContentListAppearance(
            alwaysShowThumbnails: alwaysShowThumbnails,
            showSeparators: showSeparators,
            useCardBackground: useCardBackground,
            clearRowBackground: clearRowBackground
        )
        self.onRequestDelete = onRequestDelete
        self.customMenuOptions = customMenuOptions
        self.onContentSelected = onContentSelected
    }
}

public extension ReaderContentProtocol {
    static func readerContentListView<Header: View, EmptyState: View>(
        contents: [Self],
        contentFilter: ((Int, Self) async throws -> Bool)? = nil,
        sortOrder: ReaderContentSortOrder,
        entrySelection: Binding<String?>,
        includeSource: Bool,
        contentSectionTitle: String? = nil,
        allowEditing: Bool = false,
        onDelete: (@MainActor ([Self]) async throws -> Void)? = nil,
        customGrouping: (([Self]) -> [ReaderContentGroupingSection<Self>])? = nil,
        customMenuOptions: ((Self) -> AnyView)? = nil,
        @ViewBuilder headerView: @escaping () -> Header,
        @ViewBuilder emptyStateView: @escaping () -> EmptyState
    ) -> some View {
        ReaderContentList(
            contents: contents,
            contentFilter: contentFilter,
            sortOrder: sortOrder,
            includeSource: includeSource,
            entrySelection: entrySelection,
            contentSectionTitle: contentSectionTitle,
            allowEditing: allowEditing,
            onDelete: onDelete,
            customGrouping: customGrouping,
            customMenuOptions: customMenuOptions,
            onContentSelected: nil,
            postSortTransform: nil,
            headerView: headerView,
            emptyStateView: emptyStateView
        )
    }

    static func readerContentListView(
        contents: [Self],
        entrySelection: Binding<String?>,
        sortOrder: ReaderContentSortOrder,
        contentFilter: ((Self) async throws -> Bool)? = nil,
        allowEditing: Bool = false,
        onDelete: (([Self]) -> Void)? = nil
    ) -> some View {
        ReaderContentList(
            contents: contents,
            entrySelection: entrySelection,
            sortOrder: sortOrder,
            contentFilter: contentFilter,
            allowEditing: allowEditing,
            onDelete: onDelete
        )
    }
}

private extension ReaderContentList {
    func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { sectionExpanded[id] ?? true },
            set: { newValue in sectionExpanded[id] = newValue }
        )
    }

    func refreshGrouping() {
        guard let customGrouping else {
            groupedSections = []
            sectionExpanded = [:]
            return
        }
        let newGroups = customGrouping(viewModel.filteredContents)
        var nextExpanded = sectionExpanded
        for group in newGroups where nextExpanded[group.id] == nil {
            nextExpanded[group.id] = group.initiallyExpanded
        }
        let validKeys = Set(newGroups.map(\.id))
        nextExpanded = nextExpanded.filter { validKeys.contains($0.key) }
        sectionExpanded = nextExpanded
        groupedSections = newGroups
    }
}
