import SwiftUI
import SwiftUIWebView
import RealmSwift
import RealmSwiftGaps
import SwiftUtilities
import LakeKit
import LakeOfFireContent
import LakeOfFireCore
import LakeOfFireAdblock

// MARK: - Grouping Support

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
        return cachedRealms[key]
    }
    
    public func setCachedRealm(_ realm: Realm, key: String) async {
        cachedRealms[key] = realm
    }
}

@MainActor
public enum ReaderContentListDeleteDialog: @preconcurrency Identifiable {
    case confirm(
        items: [any DeletableReaderContent],
        title: String,
        message: String,
        actionTitle: String
    )
    case error(title: String, message: String)

    public var id: String {
        switch self {
        case .confirm(let items, let title, let message, let actionTitle):
            let itemIDs = items.map { $0.compoundKey }.joined(separator: "|")
            return "confirm:\(title)|\(message)|\(actionTitle)|\(itemIDs)"
        case .error(let title, let message):
            return "error:\(title)|\(message)"
        }
    }
}

@MainActor
public class ReaderContentListModalsModel: ObservableObject {
    @Published var deleteDialog: ReaderContentListDeleteDialog?

    public init() { }

    func presentDeleteConfirmation(for items: [any DeletableReaderContent]) {
        guard let first = items.first else {
            deleteDialog = nil
            return
        }
        deleteDialog = .confirm(
            items: items,
            title: first.deletionConfirmationTitle,
            message: first.deletionConfirmationMessage,
            actionTitle: first.deletionConfirmationActionTitle
        )
    }

    func presentDeleteError(for error: Error) {
        let alert = ReaderFileOperationMessageMapper.deleteAlert(for: error)
            ?? ("Delete Failed", error.localizedDescription)
        deleteDialog = .error(title: alert.title, message: alert.message)
    }

    func clearDeleteDialog() {
        deleteDialog = nil
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
            .onReceive(readerContentListModalsModel.$deleteDialog) { newValue in
                debugPrint("\(logPrefix) deleteDialog updated \(String(describing: newValue))")
            }
            .alert(item: Binding<ReaderContentListDeleteDialog?>(
                get: {
                    guard isActive else { return nil }
                    return readerContentListModalsModel.deleteDialog
                },
                set: { newValue in
                    debugPrint("\(logPrefix) SHEET SET \(String(describing: newValue))")
                    if isActive {
                        readerContentListModalsModel.deleteDialog = newValue
                    }
                }
            )) { dialog in
                switch dialog {
                case .confirm(let items, let title, let message, let actionTitle):
                    return Alert(
                        title: Text(title),
                        message: Text(message),
                        primaryButton: .destructive(Text(actionTitle)) {
                            debugPrint("\(logPrefix) delete confirmed items=\(items.count)")
                            Task { @MainActor in
                                do {
                                    try await preflightDeleteBatch(items)
                                    for item in items {
                                        try await item.delete()
                                    }
                                    readerContentListModalsModel.clearDeleteDialog()
                                } catch {
                                    debugPrint("\(logPrefix) delete failed \(error.localizedDescription)")
                                    readerContentListModalsModel.presentDeleteError(for: error)
                                }
                            }
                        },
                        secondaryButton: .cancel {
                            debugPrint("\(logPrefix) cancel tapped")
                            readerContentListModalsModel.clearDeleteDialog()
                        }
                    )
                case .error(let title, let message):
                    return Alert(
                        title: Text(title),
                        message: Text(message),
                        dismissButton: .default(Text("OK")) {
                            readerContentListModalsModel.clearDeleteDialog()
                        }
                    )
                }
            }
            .onAppear {
                debugPrint("\(logPrefix) sheets modifier appear isActive=\(isActive)")
            }
    }
}

@MainActor
private func preflightDeleteBatch(_ items: [any DeletableReaderContent]) async throws {
    for case let contentFile as ContentFile in items {
        guard let readerBackingURL = ReaderFileManager.shared.canonicalReaderBackingURL(for: contentFile.url) else {
            continue
        }
        let eligibility = await ReaderFileManager.shared.deleteEligibility(forReaderBackingURL: readerBackingURL)
        switch eligibility {
        case .allowed:
            continue
        case .blockedCloudOnly:
            throw ReaderFileDeleteError.blockedCloudOnly
        case .blockedLoadingStatus:
            throw ReaderFileDeleteError.blockedLoadingStatus
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
    func readerContentListRowStyle(
        showSeparators: Bool = false,
        useDefaultRowInsets: Bool = false,
        zeroHorizontalRowInsets: Bool = false
    ) -> some View {
        if #available(iOS 26, macOS 26, *) {
            if zeroHorizontalRowInsets {
                self
                    .listRowInsets(.horizontal, 0)
                    .listRowSeparator(showSeparators ? .visible : .hidden)
            } else if useDefaultRowInsets {
                self
                    .listRowSeparator(showSeparators ? .visible : .hidden)
            } else {
                self
                    .listRowInsets(.init())
                    .listRowSeparator(showSeparators ? .visible : .hidden)
            }
        } else if #available(iOS 15, macOS 12, *) {
            if useDefaultRowInsets {
                self.listRowSeparator(showSeparators ? .visible : .hidden)
            } else {
                self
                    .listRowInsets(.init())
                    .listRowSeparator(showSeparators ? .visible : .hidden)
            }
        } else {
            if useDefaultRowInsets {
                self
            } else {
                self.listRowInsets(.init())
            }
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

struct ReaderContentListAppearance: Sendable {
    var alwaysShowThumbnails: Bool = true
    var showSeparators: Bool = false
    var useCardBackground: Bool = false
    var clearRowBackground: Bool = false
    var useDefaultRowInsets: Bool = false
    var showsNewBadges: Bool = true

    var usesNativeRowInsets: Bool {
        useDefaultRowInsets || (!useCardBackground && !clearRowBackground)
    }
}

// MARK: - Shared selection syncing

private struct ReaderContentSelectionSyncModifier<C: ReaderContentProtocol>: ViewModifier {
    @ObservedObject var viewModel: ReaderContentListViewModel<C>
    @Binding var entrySelection: String?
    let enabled: Bool
    let onSelection: ((C) -> Void)?

    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    @EnvironmentObject private var readerContent: ReaderContent
    @Environment(\.readerModeLoadHandler) private var readerModeLoadHandler
    @Environment(\.contentSelectionNavigationHint) private var contentSelectionNavigationHint
    @Environment(\.contentSelectionReaderTabHandoff) private var contentSelectionReaderTabHandoff

    func body(content: Content) -> some View {
        let shouldSyncToReader = enabled && onSelection == nil
        let shouldSkipWhenAlreadyLoaded = onSelection == nil
        return content
            .onChange(of: entrySelection) { [oldValue = entrySelection] itemSelection in
                guard enabled else { return }
                guard oldValue != itemSelection,
                      let itemSelection = itemSelection,
                      let content = viewModel.filteredContents.first(where: { $0.compoundKey == itemSelection }),
                      (!shouldSkipWhenAlreadyLoaded || !content.url.matchesReaderURL(readerContent.pageURL)) else { return }
                debugPrint(
                    "# SNIPPETLOAD ReaderContentList.select",
                    "key=\(itemSelection)",
                    "url=\(content.url.absoluteString)",
                    "isSnippet=\(content.url.isSnippetURL)",
                    "hasHandler=\(onSelection != nil)",
                    "shouldSyncToReader=\(shouldSyncToReader)"
                )
                debugPrint(
                    "# STALECONTENTVIEW ReaderContentList.select",
                    "key=\(itemSelection)",
                    "url=\(content.url.absoluteString)",
                    "currentURL=\(readerContent.pageURL.absoluteString)",
                    "matchesCurrent=\(content.url.matchesReaderURL(readerContent.pageURL))",
                    "hasHandler=\(onSelection != nil)",
                    "shouldSyncToReader=\(shouldSyncToReader)"
                )
                Task { @MainActor in
                    if let handler = onSelection {
                        debugPrint("# SNIPPETLOAD ReaderContentList.select", "action=customHandler")
                        handler(content)
                        if entrySelection == itemSelection {
                            entrySelection = nil
                        }
                        debugPrint(
                            "# STALECONTENTVIEW ReaderContentList.select",
                            "action=customHandler",
                            "key=\(itemSelection)"
                        )
                        return
                    }
                    guard shouldSyncToReader else { return }
                    debugPrint(
                        "# STALECONTENTVIEW ReaderContentList.select",
                        "action=hint",
                        "key=\(itemSelection)",
                        "url=\(content.url.absoluteString)"
                    )
                    contentSelectionNavigationHint?(content.url, content.compoundKey)
                    contentSelectionReaderTabHandoff?(content.url, content.compoundKey)
                    do {
                        debugPrint("# SNIPPETLOAD ReaderContentList.select", "action=navigatorLoad")
                        try await navigator.load(
                            content: content,
                            readerModeViewModel: readerModeLoadHandler
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
                    refreshSelection(readerPageURL: readerPageURL, isReaderProvisionallyNavigating: readerContent.isReaderProvisionallyNavigating, oldPageURL: oldPageURL)
                }
            }
            .onChange(of: viewModel.filteredContents) { _ in
                guard shouldSyncToReader else { return }
                Task { @MainActor in
                    refreshSelection(readerPageURL: readerContent.pageURL, isReaderProvisionallyNavigating: readerContent.isReaderProvisionallyNavigating)
                }
            }
            .task { @MainActor in
                guard shouldSyncToReader else { return }
                refreshSelection(readerPageURL: readerContent.pageURL, isReaderProvisionallyNavigating: readerContent.isReaderProvisionallyNavigating)
            }
    }

private func refreshSelection(readerPageURL: URL, isReaderProvisionallyNavigating: Bool, oldPageURL: URL? = nil) {
        viewModel.refreshSelectionTask?.cancel()
        guard !isReaderProvisionallyNavigating else { return }
        let currentSelection = entrySelection
        let filteredContentURLs = viewModel.filteredContents.map { $0.url }
        let readerPageIsNativeReaderView = readerPageURL.isNativeReaderView
        viewModel.refreshSelectionTask = Task.detached {
            try Task.checkCancellation()
            do {
                if !readerPageIsNativeReaderView,
                   let currentSelection = currentSelection,
                   let idx = await viewModel.filteredContentIDs.firstIndex(of: currentSelection),
                   idx < filteredContentURLs.count,
                   !filteredContentURLs[idx].matchesReaderURL(readerPageURL) {
                    async let task = { @MainActor in
                        try Task.checkCancellation()
                        self.entrySelection = nil
                    }()
                    try await task
                }

                guard !readerPageIsNativeReaderView, filteredContentURLs.contains(readerPageURL) else {
                    if !readerPageURL.absoluteString.hasPrefix("internal://local/load"), currentSelection != nil {
                        async let task = { @MainActor in
                            try Task.checkCancellation()
                            self.entrySelection = nil
                        }()
                        try await task
                    }
                    return
                }
            } catch { }
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

private extension View {
    func readerContentSelectionSync<C: ReaderContentProtocol>(
        viewModel: ReaderContentListViewModel<C>,
        entrySelection: Binding<String?>,
        enabled: Bool,
        onSelection: ((C) -> Void)? = nil
    ) -> some View {
        modifier(ReaderContentSelectionSyncModifier(viewModel: viewModel, entrySelection: entrySelection, enabled: enabled, onSelection: onSelection))
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

public enum ReaderContentSortOrder: Sendable {
    case providedOrder
    case publicationDate
    case createdAt
    case lastVisitedAt
    case title
    case urlAddress
}

@MainActor
public class ReaderContentListViewModel<C: ReaderContentProtocol>: ObservableObject {
    public init() { }

    public init(initialContents contents: [C], sortOrder: ReaderContentSortOrder? = nil) {
        let initialContents = Self.initialDisplayContents(from: contents, sortOrder: sortOrder)
        self.filteredContentIDs = initialContents.map(\.compoundKey)
        self.filteredContents = initialContents
    }
    
    @Published public var filteredContents: [C] = []
    public var filteredContentIDs: [String] = []
    public var realmConfiguration: Realm.Configuration?
    var refreshSelectionTask: Task<Void, Error>?
    @Published public var loadContentsTask: Task<Void, Error>?
    private var currentLoadID: UUID?
    
    @Published public var hasLoadedBefore = false
    
    public var isLoading: Bool {
        return loadContentsTask != nil
    }
    
    public var showLoadingIndicator: Bool {
        return !hasLoadedBefore || isLoading
    }

    private static func initialDisplayContents(from contents: [C], sortOrder: ReaderContentSortOrder?) -> [C] {
        let contents = contents.map { $0.realm == nil ? $0 : $0.freeze() }
        guard let sortOrder else { return contents }

        switch sortOrder {
        case .providedOrder:
            return contents
        case .publicationDate:
            return contents.sorted { lhs, rhs in
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
            return contents.sorted(using: [KeyPathComparator(\.createdAt, order: .reverse)])
        case .lastVisitedAt:
            if let historyRecords = contents as? [HistoryRecord] {
                return historyRecords.sorted(using: [KeyPathComparator(\.lastVisitedAt, order: .reverse)]) as? [C] ?? contents
            }
            return contents
        case .title:
            return contents.sorted { lhs, rhs in
                if lhs.title != rhs.title {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.createdAt > rhs.createdAt
            }
        case .urlAddress:
            return contents.sorted { lhs, rhs in
                let l = lhs.url.absoluteString
                let r = rhs.url.absoluteString
                if l != r {
                    return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
                }
                return lhs.createdAt > rhs.createdAt
            }
        }
    }

    @MainActor
    private func applyFilteredContents(_ contents: [C], ids: [String]) {
        let updateState = {
            self.filteredContentIDs = ids
            self.filteredContents = contents
            self.hasLoadedBefore = true
        }

        if self.hasLoadedBefore {
            withAnimation(.default) {
                updateState()
            }
        } else {
            updateState()
        }
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
            applyFilteredContents(
                contents.map { $0.realm == nil ? $0 : $0.freeze() },
                ids: contentIDs
            )
            return
        }

        if !hasLoadedBefore,
           filteredContents.isEmpty,
           !contents.isEmpty,
           postSortTransform == nil {
            let initialContents = Self.initialDisplayContents(from: contents, sortOrder: sortOrder)
            applyFilteredContents(initialContents, ids: initialContents.map(\.compoundKey))
        }
        
        let realmConfig = contents.first?.realm?.configuration
        self.realmConfiguration = realmConfig
        loadContentsTask?.cancel()
        let loadID = UUID()
        currentLoadID = loadID
        let task = Task { @ReaderContentListActor in
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
                case .providedOrder:
                    break
                case .publicationDate:
                    // Sort by publication date (descending). Place nils last and sub-sort nils by createdAt (descending).
                    filtered = filtered.sorted { lhs, rhs in
                        switch (lhs.publicationDate, rhs.publicationDate) {
                        case let (l?, r?):
                            if l != r { return l > r }
                            // Tie-breaker: most recently added first
                            return lhs.createdAt > rhs.createdAt
                        case (nil, nil):
                            return lhs.createdAt > rhs.createdAt
                        case (nil, _?):
                            return false // nils last
                        case (_?, nil):
                            return true // non-nil before nil
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
                    // Sort by title ascending; tie-breaker by createdAt descending
                    filtered = filtered.sorted { lhs, rhs in
                        if lhs.title != rhs.title {
                            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                        }
                        return lhs.createdAt > rhs.createdAt
                    }
                case .urlAddress:
                    // Sort by URL absolute string ascending; tie-breaker by createdAt descending
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
            
            // TODO: Pagination
            let ids = Array(filtered.prefix(10_000)).map { $0.compoundKey }
            try await { @MainActor [weak self] in
                try Task.checkCancellation()
                guard let self = self else { return }
                guard self.currentLoadID == loadID else { return }

                let resolvedContents: [C]
                if let realmConfig {
                    let realm = try await Realm(configuration: realmConfig, actor: MainActor.shared)
                    guard self.currentLoadID == loadID else { return }
                    resolvedContents = ids.compactMap { realm.object(ofType: C.self, forPrimaryKey: $0) }
                } else {
                    resolvedContents = filtered.map { $0.realm == nil ? $0 : $0.freeze() }
                }
                self.applyFilteredContents(resolvedContents, ids: ids)
            }()
        }
        loadContentsTask = task

        try? await task.value
        guard currentLoadID == loadID else { return }
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

    @MainActor
    private func selectContent() {
        entrySelection = content.compoundKey
    }
    
    @ViewBuilder private func cell(item: C) -> some View {
        HStack(spacing: 0) {
            let appearance = ReaderContentCellAppearance(
                maxCellHeight: maxCellHeight,
                alwaysShowThumbnails: appearance.alwaysShowThumbnails,
                isEbookStyle: item.isPhysicalMedia,
                includeSource: includeSource,
                showsNewBadge: appearance.showsNewBadges,
                thumbnailCornerRadius: 12
            )
            if let customMenuOptions {
                item.readerContentCellView(
                    appearance: appearance,
                    customMenuOptions: customMenuOptions
                )
                .readerContentCellStyle(.plain)
            } else {
                item.readerContentCellView(
                    appearance: appearance
                )
                .readerContentCellStyle(.plain)
            }
        }
        .padding(appearance.usesNativeRowInsets ? 0 : 11)
    }

    @ViewBuilder private func rowContent(item: C) -> some View {
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
                        selectContent()
                    }
            } else {
                Button {
                    selectContent()
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
            if let content = content as? any DeletableReaderContent {
                Button {
                    if let onRequestDelete {
                        Task { @MainActor in
                            do {
                                try await onRequestDelete(self.content)
                            } catch {
                                print(error)
                            }
                        }
                    } else {
                        // Fallback to default deletion
                        readerContentListModalsModel.presentDeleteConfirmation(for: [content])
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
        }
#endif
#if os(macOS)
        .contextMenu {
            if let content = content as? any DeletableReaderContent {
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
                        // Fallback to default deletion
                        readerContentListModalsModel.presentDeleteConfirmation(for: [content])
                    }
                } label: {
                    Label(content.deleteActionTitle, systemImage: "trash")
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
        .onReceive(NotificationCenter.default.publisher(for: ReaderFileManager.readerBackingStatusRefreshRequestedNotification)) { notification in
            guard let contentFile = content as? ContentFile,
                  let requestedURLString = notification.object as? String,
                  let readerBackingURL = ReaderFileManager.shared.canonicalReaderBackingURL(for: contentFile.url),
                  readerBackingURL.absoluteString == requestedURLString else {
                return
            }
            Task { @MainActor in
                await cloudDriveSyncStatusModel.refreshAsync(item: contentFile)
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

@MainActor
public struct ReaderContentList<C: ReaderContentProtocol, SupplementarySections: View, Header: View, EmptyState: View>: View {
    let contents: [C]
    var contentFilter: (@Sendable (Int, C) async throws -> Bool)? = nil
    var sortOrder = ReaderContentSortOrder.publicationDate
    let postSortTransform: (@ReaderContentListActor @Sendable ([C]) -> [C])?
    let includeSource: Bool
    @Binding var entrySelection: String?
    var contentSortAscending = false
    var alwaysShowThumbnails = true
    let useDefaultRowInsets: Bool
    let showsNewBadges: Bool
    let separateRowsIntoSections: Bool
    let listRowSpacing: CGFloat?
    let listSectionSpacing: CGFloat?
    let contentSectionTitle: String?
    let allowEditing: Bool
    let onDelete: (@MainActor ([C]) async throws -> Void)?
    // Optional custom grouping
    let customGrouping: (([C]) -> [ReaderContentGroupingSection<C>])?
    @ViewBuilder let supplementarySections: () -> SupplementarySections
    @ViewBuilder let headerView: () -> Header
    @ViewBuilder let emptyStateView: () -> EmptyState
    let customMenuOptions: ((C) -> AnyView)?
    let onContentSelected: ((C) -> Void)?
    
    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel
    
    @StateObject private var viewModel = ReaderContentListViewModel<C>()
    @AppStorage("appTint") private var appTint: Color = Color("AccentColor")
    @State private var groupedSections: [ReaderContentGroupingSection<C>] = []
    @State private var sectionExpanded: [String: Bool] = [:]

    // Navigation/env for selection syncing when using custom grouping
    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    @EnvironmentObject private var readerContent: ReaderContent
    @Environment(\.readerModeLoadHandler) private var readerModeLoadHandler
    
#if os(iOS)
    @Environment(\.editMode) private var editMode
#endif
    @State private var multiSelection = Set<String>()
    
    private var showEmptyState: Bool {
        return !viewModel.showLoadingIndicator && viewModel.filteredContents.isEmpty
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
        return multiSelection.isEmpty
    }

    private var showsHeaderSection: Bool {
        Header.self != EmptyView.self
    }

    private var effectiveListRowSpacing: CGFloat? {
        useDefaultRowInsets || separateRowsIntoSections ? nil : listRowSpacing
    }
    
    @ViewBuilder private var listItems: some View {
        ReaderContentListItems(
            viewModel: viewModel,
            entrySelection: $entrySelection,
            contentSortAscending: contentSortAscending,
            includeSource: includeSource,
            alwaysShowThumbnails: alwaysShowThumbnails,
            onRequestDelete: onRequestDelete,
            customMenuOptions: customMenuOptions,
            onContentSelected: onContentSelected,
            useDefaultRowInsets: useDefaultRowInsets,
            showsNewBadges: showsNewBadges,
        )
    }
    
    private var onRequestDelete: (@MainActor (C) async throws -> Void)? {
        if let onDelete {
            return { c in
                try await onDelete([c])
            }
        }
        return nil
    }

    @ViewBuilder
    private var separateRowSections: some View {
        ForEach(Array(viewModel.filteredContents.enumerated()), id: \.element.compoundKey) { index, content in
            sectionWithSpacing(
                Section {
                    ReaderContentInnerListItem(
                        content: content,
                        entrySelection: $entrySelection,
                        includeSource: includeSource,
                        appearance: ReaderContentListAppearance(
                            alwaysShowThumbnails: alwaysShowThumbnails,
                            showSeparators: false,
                            useDefaultRowInsets: useDefaultRowInsets,
                            showsNewBadges: showsNewBadges
                        ),
                        isFirst: true,
                        isLast: true,
                        viewModel: viewModel,
                        onRequestDelete: onRequestDelete,
                        customMenuOptions: customMenuOptions
                    )
                    .readerContentListRowStyle(useDefaultRowInsets: useDefaultRowInsets)
                } header: {
                    if index == viewModel.filteredContents.startIndex,
                       let contentSectionTitle {
                        Text(contentSectionTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .headerProminence(.increased)
            )
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
        if #available(iOS 17, *) {
            let sectionSpacing = listSectionSpacing.map(ListSectionSpacing.custom) ?? .default
            if let listRowSpacing = effectiveListRowSpacing {
                listContainer
                    .listRowSpacing(listRowSpacing)
                    .listSectionSpacing(sectionSpacing)
            } else {
                listContainer
                    .listSectionSpacing(sectionSpacing)
            }
        } else if #available(iOS 16, *), let listRowSpacing = effectiveListRowSpacing {
            listContainer.listRowSpacing(listRowSpacing)
        } else {
            listContainer
        }
    }
#else
    private var listContainerWithSpacing: some View { listContainer }
#endif

    @ViewBuilder
    private func sectionWithSpacing<Content: View>(_ section: Content) -> some View {
#if os(iOS)
        if #available(iOS 17, *), let listSectionSpacing {
            section.listSectionSpacing(.custom(listSectionSpacing))
        } else {
            section
        }
#else
        section
#endif
    }

    public var body: some View {
        Group {
            listContainerWithSpacing
                .toolbar {
                    //#if os(iOS)
                    //            ToolbarItem(placement: .navigationBarTrailing) {
                    //                if allowEditing {
                    //                    EditButton()
                    //                }
                    //            }
                    //#endif
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
                    guard editMode?.wrappedValue != .inactive else {
                        return
                    }
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
                    do {
                        Task { @MainActor in
                            try await onDelete(selected)
                            //                                    //                                multiSelection.removeAll()
                        }
                    } catch {
                        print(error)
                    }
                } else if let selected = selected as? [any DeletableReaderContent] {
                    readerContentListModalsModel.presentDeleteConfirmation(for: selected)
                }
            } label: {
                if #available(iOS 26, *), allowEditing {
                    Image(systemName: "trash")
                        .font(.system(size: 24, weight: .regular, design: .rounded))
                        .foregroundStyle(.red)
                        .frame(width: 54, height: 54)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial.opacity(0.92))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                        )
                } else {
                    Label("Delete", systemImage: "trash")
                }
            }
            .buttonStyle(.plain)
            .disabled(isDeletionToolbarButtonDisabled)
            .opacity(isDeletionToolbarButtonDisabled ? 0.45 : 1)
        }
    }
    
    @ViewBuilder
    private var listContent: some View {
        if showsHeaderSection {
            Section {
                headerView()
                    .listRowInsets(.init())
                    .listRowBackground(Color.clear)
            }
        }

        supplementarySections()

        if customGrouping == nil {
            sectionWithSpacing(
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
                    } else if separateRowsIntoSections {
                        separateRowSections
                    } else {
                        listItems
                            .readerContentListRowStyle(useDefaultRowInsets: useDefaultRowInsets)
                    }
                } header: {
                    if !showEmptyState, let contentSectionTitle {
                        Text(contentSectionTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .headerProminence(.increased)
            )
        } else {
            if showEmptyState {
                if #available(iOS 16, *) {
                    sectionWithSpacing(
                        Section {
                            emptyStateView()
                                .frame(maxHeight: .infinity, alignment: .top)
                                .listRowInsets(.init(top: 20, leading: 0, bottom: 0, trailing: 0))
                                .listRowBackground(Color.clear)
                                .stackListStyle(.grouped)
                        }
                    )
                }
            } else {
                ForEach(groupedSections) { section in
                    if #available(iOS 17, macOS 14, *) {
                        sectionWithSpacing(
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
                                        onRequestDelete: onRequestDelete,
                                        customMenuOptions: customMenuOptions
                                    )
                                }
                                .readerContentListRowStyle()
                            } header: {
                                Text(section.title)
                                    .foregroundStyle(.secondary)
                            }
                            .headerProminence(.increased)
                        )
                    } else {
                        sectionWithSpacing(
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
                                        onRequestDelete: onRequestDelete,
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
                        )
                    }
                }
            }
        }
    }
    
    public init(
        contents: [C],
        contentFilter: (@Sendable (Int, C) async throws -> Bool)? = nil,
        sortOrder: ReaderContentSortOrder,
        includeSource: Bool,
        entrySelection: Binding<String?>,
        contentSortAscending: Bool = false,
        alwaysShowThumbnails: Bool = true,
        useDefaultRowInsets: Bool = false,
        showsNewBadges: Bool = true,
        separateRowsIntoSections: Bool = false,
        listRowSpacing: CGFloat? = 15,
        listSectionSpacing: CGFloat? = nil,
        contentSectionTitle: String? = nil,
        allowEditing: Bool = false,
        onDelete: (@MainActor ([C]) async throws -> Void)? = nil,
        customGrouping: (([C]) -> [ReaderContentGroupingSection<C>])? = nil,
        customMenuOptions: ((C) -> AnyView)? = nil,
        onContentSelected: ((C) -> Void)? = nil,
        postSortTransform: (@ReaderContentListActor @Sendable ([C]) -> [C])? = nil,
        @ViewBuilder supplementarySections: @escaping () -> SupplementarySections,
        @ViewBuilder headerView: @escaping () -> Header,
        @ViewBuilder emptyStateView: @escaping () -> EmptyState
    ) {
        self.contents = contents
        self.contentFilter = contentFilter
        self.sortOrder = sortOrder
        self.postSortTransform = postSortTransform
        self.includeSource = includeSource
        _entrySelection = entrySelection
        self.alwaysShowThumbnails = alwaysShowThumbnails
        self.useDefaultRowInsets = useDefaultRowInsets
        self.showsNewBadges = showsNewBadges
        self.separateRowsIntoSections = separateRowsIntoSections
        self.contentSortAscending = contentSortAscending
        self.listRowSpacing = listRowSpacing
        self.listSectionSpacing = listSectionSpacing
        self.contentSectionTitle = contentSectionTitle
        self.allowEditing = allowEditing
        self.onDelete = onDelete
        self.customGrouping = customGrouping
        self.customMenuOptions = customMenuOptions
        self.supplementarySections = supplementarySections
        self.headerView = headerView
        self.emptyStateView = emptyStateView
        self.onContentSelected = onContentSelected
        _viewModel = StateObject(wrappedValue: ReaderContentListViewModel(initialContents: contents, sortOrder: sortOrder))
    }
}

public extension ReaderContentList where SupplementarySections == EmptyView {
    init(
        contents: [C],
        contentFilter: (@Sendable (Int, C) async throws -> Bool)? = nil,
        sortOrder: ReaderContentSortOrder,
        includeSource: Bool,
        entrySelection: Binding<String?>,
        contentSortAscending: Bool = false,
        alwaysShowThumbnails: Bool = true,
        useDefaultRowInsets: Bool = false,
        showsNewBadges: Bool = true,
        separateRowsIntoSections: Bool = false,
        listRowSpacing: CGFloat? = 15,
        listSectionSpacing: CGFloat? = nil,
        contentSectionTitle: String? = nil,
        allowEditing: Bool = false,
        onDelete: (@MainActor ([C]) async throws -> Void)? = nil,
        customGrouping: (([C]) -> [ReaderContentGroupingSection<C>])? = nil,
        customMenuOptions: ((C) -> AnyView)? = nil,
        onContentSelected: ((C) -> Void)? = nil,
        postSortTransform: (@ReaderContentListActor @Sendable ([C]) -> [C])? = nil,
        @ViewBuilder headerView: @escaping () -> Header,
        @ViewBuilder emptyStateView: @escaping () -> EmptyState
    ) {
        self.init(
            contents: contents,
            contentFilter: contentFilter,
            sortOrder: sortOrder,
            includeSource: includeSource,
            entrySelection: entrySelection,
            contentSortAscending: contentSortAscending,
            alwaysShowThumbnails: alwaysShowThumbnails,
            useDefaultRowInsets: useDefaultRowInsets,
            showsNewBadges: showsNewBadges,
            separateRowsIntoSections: separateRowsIntoSections,
            listRowSpacing: listRowSpacing,
            listSectionSpacing: listSectionSpacing,
            contentSectionTitle: contentSectionTitle,
            allowEditing: allowEditing,
            onDelete: onDelete,
            customGrouping: customGrouping,
            customMenuOptions: customMenuOptions,
            onContentSelected: onContentSelected,
            postSortTransform: postSortTransform,
            supplementarySections: { EmptyView() },
            headerView: headerView,
            emptyStateView: emptyStateView
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
        .readerContentListRowStyle(
            showSeparators: appearance.showSeparators,
            useDefaultRowInsets: appearance.usesNativeRowInsets,
            zeroHorizontalRowInsets: appearance.clearRowBackground
        )
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
        includeSource: Bool,
        alwaysShowThumbnails: Bool = true,
        onRequestDelete: (@MainActor (C) async throws -> Void)? = nil,
        customMenuOptions: ((C) -> AnyView)? = nil,
        onContentSelected: ((C) -> Void)? = nil,
        showSeparators: Bool = false,
        useCardBackground: Bool = false,
        clearRowBackground: Bool = false,
        useDefaultRowInsets: Bool = false,
        showsNewBadges: Bool = true
    ) {
        self.viewModel = viewModel
        _entrySelection = entrySelection
        self.contentSortAscending = contentSortAscending
        self.includeSource = includeSource
        self.appearance = ReaderContentListAppearance(
            alwaysShowThumbnails: alwaysShowThumbnails,
            showSeparators: showSeparators,
            useCardBackground: useCardBackground,
            clearRowBackground: clearRowBackground,
            useDefaultRowInsets: useDefaultRowInsets,
            showsNewBadges: showsNewBadges
        )
        self.onRequestDelete = onRequestDelete
        self.customMenuOptions = customMenuOptions
        self.onContentSelected = onContentSelected
    }
    
}

public extension ReaderContentProtocol {
    @MainActor
    static func readerContentListView<SupplementarySections: View, Header: View, EmptyState: View>(
        contents: [Self],
        contentFilter: (@Sendable (Int, Self) async throws -> Bool)? = nil,
        sortOrder: ReaderContentSortOrder,
        entrySelection: Binding<String?>,
        includeSource: Bool,
        listRowSpacing: CGFloat? = 15,
        listSectionSpacing: CGFloat? = nil,
        contentSectionTitle: String? = nil,
        allowEditing: Bool = false,
        onDelete: (@MainActor ([Self]) async throws -> Void)? = nil,
        customGrouping: (([Self]) -> [ReaderContentGroupingSection<Self>])? = nil,
        customMenuOptions: ((Self) -> AnyView)? = nil,
        @ViewBuilder supplementarySections: @escaping () -> SupplementarySections,
        @ViewBuilder headerView: @escaping () -> Header,
        @ViewBuilder emptyStateView: @escaping () -> EmptyState
    ) -> some View {
        return ReaderContentList(
            contents: contents,
            contentFilter: contentFilter,
            sortOrder: sortOrder,
            includeSource: includeSource,
            entrySelection: entrySelection,
            listRowSpacing: listRowSpacing,
            listSectionSpacing: listSectionSpacing,
            contentSectionTitle: contentSectionTitle,
            allowEditing: allowEditing,
            onDelete: onDelete,
            customGrouping: customGrouping,
            customMenuOptions: customMenuOptions,
            supplementarySections: supplementarySections,
            headerView: headerView,
            emptyStateView: emptyStateView
        )
    }

    @MainActor
    static func readerContentListView<Header: View, EmptyState: View>(
        contents: [Self],
        contentFilter: (@Sendable (Int, Self) async throws -> Bool)? = nil,
        sortOrder: ReaderContentSortOrder,
        entrySelection: Binding<String?>,
        includeSource: Bool,
        listRowSpacing: CGFloat? = 15,
        listSectionSpacing: CGFloat? = nil,
        contentSectionTitle: String? = nil,
        allowEditing: Bool = false,
        onDelete: (@MainActor ([Self]) async throws -> Void)? = nil,
        customGrouping: (([Self]) -> [ReaderContentGroupingSection<Self>])? = nil,
        customMenuOptions: ((Self) -> AnyView)? = nil,
        @ViewBuilder headerView: @escaping () -> Header,
        @ViewBuilder emptyStateView: @escaping () -> EmptyState
    ) -> some View {
        readerContentListView(
            contents: contents,
            contentFilter: contentFilter,
            sortOrder: sortOrder,
            entrySelection: entrySelection,
            includeSource: includeSource,
            listRowSpacing: listRowSpacing,
            listSectionSpacing: listSectionSpacing,
            contentSectionTitle: contentSectionTitle,
            allowEditing: allowEditing,
            onDelete: onDelete,
            customGrouping: customGrouping,
            customMenuOptions: customMenuOptions,
            supplementarySections: { EmptyView() },
            headerView: headerView,
            emptyStateView: emptyStateView
        )
    }
}

// MARK: - Private helpers

extension ReaderContentList {
    private func binding(for id: String) -> Binding<Bool> {
        Binding<Bool>(
            get: { sectionExpanded[id] ?? true },
            set: { newValue in sectionExpanded[id] = newValue }
        )
    }
    
    private func refreshGrouping() {
        guard let customGrouping else {
            groupedSections = []
            sectionExpanded = [:]
            return
        }
        let newGroups = customGrouping(viewModel.filteredContents)
        var nextExpanded = sectionExpanded
        for g in newGroups {
            if nextExpanded[g.id] == nil {
                nextExpanded[g.id] = g.initiallyExpanded
            }
        }
        // Drop any removed groups to keep state tidy
        let validKeys = Set(newGroups.map { $0.id })
        nextExpanded = nextExpanded.filter { validKeys.contains($0.key) }
        sectionExpanded = nextExpanded
        groupedSections = newGroups
    }

}

#if DEBUG
@MainActor
private final class ReaderContentListPreviewStore: ObservableObject {
    let modalsModel = ReaderContentListModalsModel()
    let readerContent = ReaderContent()

    let entries: [FeedEntry]

    init() {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: "ReaderContentListPreview",
            objectTypes: [FeedEntry.self, Bookmark.self]
        )

        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        ReaderContentLoader.bookmarkRealmConfiguration = configuration

        let realm = try! Realm(configuration: configuration)

        let recentArticle = FeedEntry()
        recentArticle.compoundKey = "preview-list-recent"
        recentArticle.url = URL(string: "https://example.com/articles/fresh")!
        recentArticle.title = "Fresh Article with Thumbnail"
        recentArticle.author = "Asahi"
        recentArticle.imageUrl = URL(string: "https://placehold.co/360x200.png?text=Asahi")
        recentArticle.sourceIconURL = URL(string: "https://placehold.co/48x48.png?text=A")
        recentArticle.publicationDate = Calendar.current.date(byAdding: .hour, value: -6, to: .now)

        let olderArticle = FeedEntry()
        olderArticle.compoundKey = "preview-list-older"
        olderArticle.url = URL(string: "https://example.com/articles/older")!
        olderArticle.title = "Older Article without Image"
        olderArticle.author = "Mainichi"
        olderArticle.publicationDate = Calendar.current.date(byAdding: .day, value: -2, to: .now)
        olderArticle.displayPublicationDate = true

        let longformArticle = FeedEntry()
        longformArticle.compoundKey = "preview-list-longform"
        longformArticle.url = URL(string: "https://example.com/articles/longform")!
        longformArticle.title = "Longform Piece Highlighting Bookmark State"
        longformArticle.author = "NHK"
        longformArticle.imageUrl = URL(string: "https://placehold.co/360x200.png?text=NHK")
        longformArticle.sourceIconURL = URL(string: "https://placehold.co/48x48.png?text=N")
        longformArticle.publicationDate = Calendar.current.date(byAdding: .day, value: -7, to: .now)

        let entries = [recentArticle, olderArticle, longformArticle]

        try! realm.write {
            realm.add(entries, update: .modified)

            for entry in entries {
                let bookmark = Bookmark()
                bookmark.compoundKey = entry.compoundKey
                bookmark.url = entry.url
                bookmark.title = entry.title
                bookmark.author = entry.author
                bookmark.imageUrl = entry.imageUrl
                bookmark.sourceIconURL = entry.sourceIconURL
                bookmark.publicationDate = entry.publicationDate
                bookmark.isDeleted = false
                realm.add(bookmark, update: .modified)
            }
        }

        let progress: [URL: (Float, Bool)] = [
            recentArticle.url: (0.25, false),
            longformArticle.url: (0.85, true)
        ]

        ReaderContentReadingProgressLoader.readingProgressLoader = { url in
            progress[url]
        }

        readerContent.content = entries.first
        readerContent.pageURL = entries.first?.url ?? URL(string: "https://example.com")!

        self.entries = entries
    }
}

private struct ReaderContentListPreviewGallery: View {
    @StateObject private var store = ReaderContentListPreviewStore()
    @State private var entrySelection: String? = nil

    private let previewMenuOptions: (FeedEntry) -> AnyView = { entry in
        AnyView(
            Button {
                debugPrint("Preview menu tapped for", entry.title)
            } label: {
                Label("Preview Menu", systemImage: "ellipsis.circle")
            }
        )
    }
    
    var body: some View {
        ReaderContentList(
            contents: store.entries,
            sortOrder: .publicationDate,
            includeSource: true,
            entrySelection: $entrySelection,
            contentSectionTitle: "Saved Articles",
            allowEditing: true,
            customMenuOptions: previewMenuOptions
        ) {
            HStack {
                Text("Library")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.vertical, 12)
        } emptyStateView: {
            Text("Nothing to read yet")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .foregroundStyle(.secondary)
        }
        .frame(maxHeight: 420)
        .environmentObject(store.modalsModel)
        .environmentObject(store.readerContent)
//        .padding()
    }
}

struct ReaderContentList_Previews: PreviewProvider {
    static var previews: some View {
        ReaderContentListPreviewGallery()
    }
}
#endif
