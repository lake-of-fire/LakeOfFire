import LakeOfFireWeb
import LakeOfFireFiles
import SwiftUI
import LakeOfFireContent
import LakeOfFireCore
import SwiftUIWebView
import RealmSwift
import RealmSwiftGaps
import SwiftUtilities
import LakeKit

#if DEBUG
public typealias ReaderContentVideoMakerOpenAction = @MainActor (_ contents: [any ReaderContentProtocol]) -> Void

private struct ReaderContentVideoMakerOpenActionKey: EnvironmentKey {
    static let defaultValue: ReaderContentVideoMakerOpenAction? = nil
}

public extension EnvironmentValues {
    var readerContentVideoMakerOpenAction: ReaderContentVideoMakerOpenAction? {
        get { self[ReaderContentVideoMakerOpenActionKey.self] }
        set { self[ReaderContentVideoMakerOpenActionKey.self] = newValue }
    }
}
#endif



public func readerContentListSeparatedRowScrollAnchorID(_ contentID: String) -> String {
    "reader-content-list-section-\(contentID)"
}

public struct ReaderContentGroupingSection<C: ReaderContentProtocol>: Identifiable {
    public let id: String
    public let title: String
    public let items: [C]
    public let itemIDs: [String]
    public let initiallyExpanded: Bool

    public init(id: String, title: String, items: [C], itemIDs: [String]? = nil, initiallyExpanded: Bool = true) {
        self.id = id
        self.title = title
        self.items = items
        self.itemIDs = itemIDs ?? items.map(\.compoundKey)
        self.initiallyExpanded = initiallyExpanded
    }
}

struct ReaderContentIdentifiedItem<C: ReaderContentProtocol>: Identifiable {
    let id: String
    let content: C
    let offset: Int
}

func readerContentIdentifiedItems<C: ReaderContentProtocol>(
    contents: [C],
    ids: [String]
) -> [ReaderContentIdentifiedItem<C>] {
    assert(ids.count == contents.count, "Reader content IDs and values must remain aligned")
    return contents.indices.map { index in
        ReaderContentIdentifiedItem(id: ids[index], content: contents[index], offset: index)
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
public enum ReaderContentListDeleteDialog: Identifiable {
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

    public func presentDeleteConfirmation(for items: [any DeletableReaderContent]) {
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
        content
            .alert(item: Binding<ReaderContentListDeleteDialog?>(
                get: {
                    guard isActive else { return nil }
                    return readerContentListModalsModel.deleteDialog
                },
                set: { newValue in
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
                            Task { @MainActor in
                                do {
                                    try await preflightDeleteBatch(items)
                                    for item in items {
                                        try await item.delete()
                                    }
                                    readerContentListModalsModel.clearDeleteDialog()
                                } catch {
                                    readerContentListModalsModel.presentDeleteError(for: error)
                                }
                            }
                        },
                        secondaryButton: .cancel {
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
    var useDefaultRowInsets: Bool = false
    var showsNewBadges: Bool = true
    var wrapsContentInGroupBox: Bool = false

    var usesNativeRowInsets: Bool {
        useDefaultRowInsets || (!useCardBackground && !clearRowBackground)
    }
}

private struct ReaderContentSelectionSyncModifier<C: ReaderContentProtocol>: ViewModifier {
    @ObservedObject var viewModel: ReaderContentListViewModel<C>
    @Binding var entrySelection: String?
    let enabled: Bool
    let onSelection: ((C) -> Void)?
    @State private var selectionLoadGeneration = UUID()

    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    @Environment(\.contentSelectionNavigationHint) private var contentSelectionNavigationHint
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel
    @AppStorage("errorMessage") private var errorMessage = ""

    func body(content: Content) -> some View {
        let shouldSyncToReader = enabled && onSelection == nil

        return content
            .onChange(of: entrySelection) { [oldValue = entrySelection] itemSelection in
                guard enabled else { return }
                guard oldValue != itemSelection,
                      let itemSelection,
                      let selectedContent = viewModel.filteredContents.first(where: { $0.compoundKey == itemSelection })
                else {
                    return
                }
                let isAlreadyLoaded = selectedContent.url.matchesReaderURL(readerContent.pageURL)
                if selectedContent.url.isSnippetURL {
                }
                if isAlreadyLoaded {
                }

                let loadGeneration = UUID()
                selectionLoadGeneration = loadGeneration

                Task { @MainActor in
                    guard selectionLoadGeneration == loadGeneration else {
                        return
                    }
                    if let onSelection {
                        if selectedContent.url.isSnippetURL {
                        }
                        onSelection(selectedContent)
                        if selectionLoadGeneration == loadGeneration, entrySelection == itemSelection {
                            entrySelection = nil
                        }
                        return
                    }

                    guard shouldSyncToReader else {
                        return
                    }
                    if selectedContent.url.isSnippetURL {
                    }
                    contentSelectionNavigationHint?(selectedContent.url, selectedContent.compoundKey)
                    guard !isAlreadyLoaded else {
                        if selectionLoadGeneration == loadGeneration, entrySelection == itemSelection {
                            entrySelection = nil
                        }
                        return
                    }
                    guard entrySelection == itemSelection else {
                        return
                    }
                    guard selectionLoadGeneration == loadGeneration else {
                        return
                    }
                    do {
                        try await navigator.load(
                            content: selectedContent,
                            readerModeViewModel: readerModeViewModel
                        )
                    } catch {
                        errorMessage = ReaderFileOperationMessageMapper.openMessage(for: error) ?? error.localizedDescription
                        debugPrint("Failed to load reader content for selection", error)
                    }
                    if selectionLoadGeneration == loadGeneration, entrySelection == itemSelection {
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
        let refreshStartedAt = Date()
        viewModel.refreshSelectionTask?.cancel()
        guard !isReaderProvisionallyNavigating else {
            return
        }

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
        loadContentsTask != nil
    }

    public var showLoadingIndicator: Bool {
        !hasLoadedBefore || isLoading
    }

    private static func initialDisplayContents(from contents: [C], sortOrder: ReaderContentSortOrder?) -> [C] {
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

        if hasLoadedBefore {
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
            applyFilteredContents(
                contents,
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
        realmConfiguration = realmConfig
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
            await MainActor.run {
            }
            try await { @MainActor [weak self] in
                guard let self else { return }
                guard self.currentLoadID == loadID else {
                    return
                }
                let resolvedContents: [C]
                if let realmConfig {
                    let realm = try await Realm(configuration: realmConfig, actor: MainActor.shared)
                    guard self.currentLoadID == loadID else {
                        return
                    }
                    resolvedContents = ids.compactMap { realm.object(ofType: C.self, forPrimaryKey: $0) }
                } else {
                    resolvedContents = filtered
                }
                self.applyFilteredContents(resolvedContents, ids: ids)
            }()
        }
        loadContentsTask = task

        try? await task.value
        guard currentLoadID == loadID else {
            return
        }
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
    let onRequestDelete: (@MainActor (C) async throws -> Void)?
    let customMenuOptions: ((C) -> AnyView)?
    let onContentAppear: ((C) -> Void)?

    @StateObject private var cloudDriveSyncStatusModel = CloudDriveSyncStatusModel()
    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel

    @ScaledMetric(relativeTo: .headline) private var maxCellHeight: CGFloat = 120

    private var isDeleteBlockedByStatus: Bool {
        guard content is ContentFile else {
            return false
        }
        switch cloudDriveSyncStatusModel.status {
        case .cloudOnly, .loadingStatus:
            return true
        default:
            return false
        }
    }

    @MainActor
    private func selectContent() {
        entrySelection = content.compoundKey
    }

    @ViewBuilder
    private func cell(item: C) -> some View {
        HStack(spacing: 0) {
            let cellAppearance = ReaderContentCellAppearance(
                maxCellHeight: maxCellHeight,
                alwaysShowThumbnails: appearance.alwaysShowThumbnails,
                isEbookStyle: item.isPhysicalMedia,
                includeSource: includeSource,
                showsNewBadge: appearance.showsNewBadges,
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
        .padding(appearance.usesNativeRowInsets ? 0 : 11)
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
        } else if appearance.wrapsContentInGroupBox {
            GroupBox {
                cell(item: item)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
        .id(content.compoundKey)
#if os(iOS)
        .deleteDisabled((content as? any DeletableReaderContent) == nil || isDeleteBlockedByStatus)
        .swipeActions {
            if let deletable = content as? any DeletableReaderContent {
                Button {
                    if let onRequestDelete {
                        Task { @MainActor in
                            do {
                                try await onRequestDelete(self.content)
                            } catch {
                                readerContentListModalsModel.presentDeleteError(for: error)
                            }
                        }
                    } else {
                        readerContentListModalsModel.presentDeleteConfirmation(for: [deletable])
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
                .disabled(isDeleteBlockedByStatus)
            }
        }
#endif
#if os(macOS)
        .contextMenu(menuItems: {
            if let deletable = content as? any DeletableReaderContent {
                Button(role: .destructive) {
                    if let onRequestDelete {
                        Task { @MainActor in
                            do {
                                try await onRequestDelete(self.content)
                            } catch {
                                readerContentListModalsModel.presentDeleteError(for: error)
                            }
                        }
                    } else {
                        readerContentListModalsModel.presentDeleteConfirmation(for: [deletable])
                    }
                } label: {
                    Label(deletable.deleteActionTitle, systemImage: "trash")
                }
                .disabled(isDeleteBlockedByStatus)
            }
        })
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
            if appearance.useCardBackground || appearance.wrapsContentInGroupBox {
                $0.listRowBackground(Color.clear)
            } else {
                $0
            }
        }
        .environmentObject(cloudDriveSyncStatusModel)
        .task { @MainActor in
            onContentAppear?(content)
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
    let onContentAppear: ((C) -> Void)?

    var body: some View {
        let contents = viewModel.filteredContents
        let items = readerContentIdentifiedItems(
            contents: contents,
            ids: viewModel.filteredContentIDs
        )
        Group {
            ForEach(items) { item in
                let content = item.content
                let isFirst = item.offset == contents.startIndex
                let isLast = item.offset == contents.indices.last
                ReaderContentInnerListItem(
                    content: content,
                    entrySelection: $entrySelection,
                    includeSource: includeSource,
                    appearance: appearance,
                    isFirst: isFirst,
                    isLast: isLast,
                    onRequestDelete: onRequestDelete,
                    customMenuOptions: customMenuOptions,
                    onContentAppear: onContentAppear
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
        customMenuOptions: ((C) -> AnyView)? = nil,
        onContentAppear: ((C) -> Void)? = nil
    ) {
        _entrySelection = entrySelection
        self.includeSource = includeSource
        self.appearance = appearance
        self.viewModel = viewModel
        self.onRequestDelete = onRequestDelete
        self.customMenuOptions = customMenuOptions
        self.onContentAppear = onContentAppear
    }
}

public struct ReaderContentList<C: ReaderContentProtocol, SupplementarySections: View, Header: View, EmptyState: View>: View {
    let contents: [C]
    var contentFilter: ((Int, C) async throws -> Bool)? = nil
    var sortOrder = ReaderContentSortOrder.publicationDate
    let postSortTransform: (@ReaderContentListActor ([C]) -> [C])?
    let includeSource: Bool
    @Binding var entrySelection: String?
    var contentSortAscending = false
    var alwaysShowThumbnails = true
    let useCardBackground: Bool
    let clearRowBackground: Bool
    let useDefaultRowInsets: Bool
    let showsNewBadges: Bool
    let separateRowsIntoSections: Bool
    let listRowSpacing: CGFloat?
    let listSectionSpacing: CGFloat?
    let contentSectionTitle: String?
    let rendersHeaderViewInSectionHeader: Bool
    let allowEditing: Bool
    let externalMultiSelection: Binding<Set<String>>?
    let showsDeletionToolbarItem: Bool
    let onDelete: (@MainActor ([C]) async throws -> Void)?
    let customGrouping: (([C]) -> [ReaderContentGroupingSection<C>])?
    @ViewBuilder let supplementarySections: () -> SupplementarySections
    @ViewBuilder let headerView: () -> Header
    @ViewBuilder let emptyStateView: () -> EmptyState
    let customMenuOptions: ((C) -> AnyView)?
    let onContentSelected: ((C) -> Void)?
    let onContentAppear: ((C) -> Void)?
    let scrollTargetID: String?

    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel
#if DEBUG
    @Environment(\.readerContentVideoMakerOpenAction) private var readerContentVideoMakerOpenAction
#endif

    @StateObject private var viewModel = ReaderContentListViewModel<C>()
    @AppStorage("appTint") private var appTint: Color = Color("AccentColor")
    @State private var groupedSections: [ReaderContentGroupingSection<C>] = []
    @State private var sectionExpanded: [String: Bool] = [:]

#if os(iOS)
    @Environment(\.editMode) private var editMode
#endif
    @State private var internalMultiSelection = Set<String>()
    @State private var deleteEligibilityByContentKey: [String: ReaderFileDeleteEligibility] = [:]
    @State private var deleteEligibilityRefreshTask: Task<Void, Never>?
    @State private var pendingScrollTargetID: String?
    @State private var lastScrolledTargetID: String?

    private var showEmptyState: Bool {
        !viewModel.showLoadingIndicator && viewModel.filteredContents.isEmpty
    }

    private var showDeletionToolbarButton: Bool {
        if showsDeletionToolbarItem, allowEditing, C.self is DeletableReaderContent.Type {
#if os(iOS)
            return editMode?.wrappedValue != .inactive
#else
            return true
#endif
        }
        return false
    }

    private var isDeletionToolbarButtonDisabled: Bool {
        guard !multiSelection.isEmpty else {
            return true
        }
        let selectedContentFiles = viewModel.filteredContents.compactMap { content -> ContentFile? in
            guard multiSelection.contains(content.compoundKey) else { return nil }
            return content as? ContentFile
        }
        guard !selectedContentFiles.isEmpty else {
            return false
        }
        guard selectedContentFiles.allSatisfy({ deleteEligibilityByContentKey[$0.compoundKey] != nil }) else {
            return true
        }
        return selectedContentFiles.contains {
            deleteEligibilityByContentKey[$0.compoundKey] != .allowed
        }
    }

    private var multiSelection: Set<String> {
        multiSelectionBinding.wrappedValue
    }

    private var multiSelectionBinding: Binding<Set<String>> {
        externalMultiSelection ?? $internalMultiSelection
    }

#if DEBUG
    private var selectedVideoMakerContents: [C] {
        viewModel.filteredContents.filter {
            multiSelection.contains($0.compoundKey) && $0.hasTranscriptTracerVideoSource
        }
    }

    private var showsVideoMakerToolbarMenu: Bool {
        guard readerContentVideoMakerOpenAction != nil else { return false }
        guard !selectedVideoMakerContents.isEmpty else { return false }
#if os(iOS)
        return allowEditing && editMode?.wrappedValue != .inactive
#else
        return true
#endif
    }

    private var makeSelectedVideoTitle: String {
        selectedVideoMakerContents.count == 1 ? "Make Video" : "Make Videos"
    }
#endif

    private var showsHeaderSection: Bool {
        !rendersHeaderViewInSectionHeader && Header.self != EmptyView.self
    }

    private var usesNativeRowInsets: Bool {
        useDefaultRowInsets || (!useCardBackground && !clearRowBackground)
    }

    private var effectiveListRowSpacing: CGFloat? {
        usesNativeRowInsets || separateRowsIntoSections ? nil : listRowSpacing
    }

    private var effectiveListSectionSpacing: CGFloat? {
        guard separateRowsIntoSections else {
            return listSectionSpacing
        }
        return min(listSectionSpacing ?? 10, 10)
    }

    private var normalizedScrollTargetID: String? {
        let trimmed = scrollTargetID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var separatedRowsUseGroupBox: Bool {
#if os(macOS)
        separateRowsIntoSections && !useCardBackground && !clearRowBackground
#else
        false
#endif
    }

    @ViewBuilder
    private var listItems: some View {
        ReaderContentListItems(
            viewModel: viewModel,
            entrySelection: $entrySelection,
            contentSortAscending: contentSortAscending,
            includeSource: includeSource,
            alwaysShowThumbnails: alwaysShowThumbnails,
            useCardBackground: useCardBackground,
            clearRowBackground: clearRowBackground,
            useDefaultRowInsets: useDefaultRowInsets,
            showsNewBadges: showsNewBadges,
            onRequestDelete: onRequestDeleteSingle,
            customMenuOptions: customMenuOptions,
            onContentSelected: onContentSelected,
            onContentAppear: onContentAppear
        )
    }

    private var onRequestDeleteSingle: (@MainActor (C) async throws -> Void)? {
        guard let onDelete else { return nil }
        return { content in
            try await onDelete([content])
        }
    }

    @ViewBuilder
    private var separateRowSections: some View {
        let items = readerContentIdentifiedItems(
            contents: viewModel.filteredContents,
            ids: viewModel.filteredContentIDs
        )
        ForEach(items) { item in
            let content = item.content
            sectionWithSpacing(
                Section {
                    ReaderContentInnerListItem(
                        content: content,
                        entrySelection: $entrySelection,
                        includeSource: includeSource,
                        appearance: ReaderContentListAppearance(
                            alwaysShowThumbnails: alwaysShowThumbnails,
                            showSeparators: false,
                            useCardBackground: useCardBackground,
                            clearRowBackground: clearRowBackground,
                            useDefaultRowInsets: useDefaultRowInsets,
                            showsNewBadges: showsNewBadges,
                            wrapsContentInGroupBox: separatedRowsUseGroupBox
                        ),
                        isFirst: true,
                        isLast: true,
                        onRequestDelete: onRequestDeleteSingle,
                        customMenuOptions: customMenuOptions,
                        onContentAppear: onContentAppear
                    )
                    .readerContentListRowStyle(
                        useDefaultRowInsets: useDefaultRowInsets || (!useCardBackground && !clearRowBackground),
                        zeroHorizontalRowInsets: clearRowBackground
                    )
                } header: {
                    if item.offset == viewModel.filteredContents.startIndex,
                       !showEmptyState || rendersHeaderViewInSectionHeader {
                        contentSectionHeader
                    }
                }
                .headerProminence(.increased)
            )
            .id(readerContentListSeparatedRowScrollAnchorID(content.compoundKey))
        }
    }

    private func refreshDeleteEligibilityCache() {
        deleteEligibilityRefreshTask?.cancel()
        let selectedContentFiles = viewModel.filteredContents.compactMap { content -> ContentFile? in
            guard multiSelection.contains(content.compoundKey) else { return nil }
            return content as? ContentFile
        }
        guard !selectedContentFiles.isEmpty else {
            deleteEligibilityByContentKey = [:]
            return
        }
        deleteEligibilityRefreshTask = Task { @MainActor in
            var nextEligibility = [String: ReaderFileDeleteEligibility]()
            for contentFile in selectedContentFiles {
                guard let readerBackingURL = ReaderFileManager.shared.canonicalReaderBackingURL(for: contentFile.url) else {
                    continue
                }
                let eligibility = await ReaderFileManager.shared.deleteEligibility(forReaderBackingURL: readerBackingURL)
                if Task.isCancelled {
                    return
                }
                nextEligibility[contentFile.compoundKey] = eligibility
            }
            deleteEligibilityByContentKey = nextEligibility
        }
    }

    @MainActor
    private func scheduleScrollToTarget(with proxy: ScrollViewProxy, reason: String) {
        guard let targetID = normalizedScrollTargetID else { return }
        guard viewModel.filteredContentIDs.contains(targetID) else {
            return
        }
        guard pendingScrollTargetID != targetID else {
            return
        }
        let anchorID = readerContentListSeparatedRowScrollAnchorID(targetID)
        pendingScrollTargetID = targetID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard pendingScrollTargetID == targetID else {
                return
            }
            pendingScrollTargetID = nil
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(anchorID, anchor: .center)
            }
        }
    }

    private var listContainer: some View {
        ZStack {
#if os(iOS)
            if allowEditing && editMode?.wrappedValue != .inactive {
                List(selection: multiSelectionBinding) {
                    listContent
                }
            } else {
                List(selection: $entrySelection) {
                    listContent
                }
            }
#else
#if DEBUG
            if allowEditing {
                List(selection: multiSelectionBinding) {
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
#endif
        }
        .listItemTint(appTint)
        .readerContentListLayoutAdjustments()
    }

#if os(iOS)
    @ViewBuilder
    private var listContainerWithSpacing: some View {
        if #available(iOS 17, *) {
            let sectionSpacing = effectiveListSectionSpacing.map(ListSectionSpacing.custom) ?? .default
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
        if #available(iOS 17, *), let effectiveListSectionSpacing {
            section.listSectionSpacing(.custom(effectiveListSectionSpacing))
        } else {
            section
        }
#else
        section
#endif
    }

    @ViewBuilder
    private func listBody(scrollProxy: ScrollViewProxy) -> some View {
        listContainerWithSpacing
            .onAppear {
            }
            .onDisappear {
            }
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
#if DEBUG
                ToolbarItem(placement: videoMakerToolbarPlacement) {
                    videoMakerToolbarMenu
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
                scheduleScrollToTarget(with: scrollProxy, reason: "taskEnd")
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
                    scheduleScrollToTarget(with: scrollProxy, reason: "contentsChanged")
                }
            }
            .onChange(of: viewModel.filteredContents) { _ in
                refreshGrouping()
                refreshDeleteEligibilityCache()
                scheduleScrollToTarget(with: scrollProxy, reason: "filteredContentsChanged")
            }
            .onChange(of: multiSelection) { _ in
                refreshDeleteEligibilityCache()
            }
    }

    public var body: some View {
        ScrollViewReader { scrollProxy in
            listBody(scrollProxy: scrollProxy)
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
                            readerContentListModalsModel.presentDeleteError(for: error)
                        }
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

#if DEBUG
    private var videoMakerToolbarPlacement: ToolbarItemPlacement {
#if os(macOS)
        .automatic
#else
        .topBarTrailing
#endif
    }

    @ViewBuilder
    private var videoMakerToolbarMenu: some View {
        if showsVideoMakerToolbarMenu, let readerContentVideoMakerOpenAction {
            Menu {
                Button {
                    readerContentVideoMakerOpenAction(
                        selectedVideoMakerContents.map { $0 as any ReaderContentProtocol }
                    )
                } label: {
                    Label(makeSelectedVideoTitle, systemImage: "film")
                }
            } label: {
                Label("More Options", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
        }
    }
#endif

    @ViewBuilder
    private var contentSectionHeader: some View {
        if rendersHeaderViewInSectionHeader {
            VStack(alignment: .leading, spacing: 8) {
                headerView()
                if let contentSectionTitle {
                    Text(contentSectionTitle)
                        .foregroundStyle(.secondary)
                }
            }
        } else if let contentSectionTitle {
            Text(contentSectionTitle)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func groupedRowContent(
        section: ReaderContentGroupingSection<C>,
        index: Array<C>.Index,
        content: C
    ) -> some View {
        let lastIndex = section.items.indices.last ?? section.items.startIndex
        ReaderContentInnerListItem(
            content: content,
            entrySelection: $entrySelection,
            includeSource: includeSource,
            appearance: ReaderContentListAppearance(
                alwaysShowThumbnails: alwaysShowThumbnails,
                showSeparators: false,
                useCardBackground: useCardBackground,
                clearRowBackground: clearRowBackground,
                useDefaultRowInsets: useDefaultRowInsets,
                showsNewBadges: showsNewBadges,
                wrapsContentInGroupBox: separatedRowsUseGroupBox
            ),
            isFirst: index == section.items.startIndex,
            isLast: index == lastIndex,
            onRequestDelete: onRequestDeleteSingle,
            customMenuOptions: customMenuOptions,
            onContentAppear: onContentAppear
        )
        .readerContentListRowStyle(
            useDefaultRowInsets: useDefaultRowInsets || (!useCardBackground && !clearRowBackground),
            zeroHorizontalRowInsets: clearRowBackground
        )
    }

    @ViewBuilder
    private func groupedRows(section: ReaderContentGroupingSection<C>) -> some View {
        let items = readerContentIdentifiedItems(contents: section.items, ids: section.itemIDs)
        if separateRowsIntoSections {
            ForEach(items) { item in
                let content = item.content
                sectionWithSpacing(
                    Section {
                        groupedRowContent(section: section, index: item.offset, content: content)
                    } header: {
                        if item.offset == section.items.startIndex {
                            Text(section.title)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .headerProminence(.increased)
                )
                .id(readerContentListSeparatedRowScrollAnchorID(item.id))
            }
        } else {
            let lastIndex = section.items.indices.last ?? section.items.startIndex
            ForEach(items) { item in
                let content = item.content
                ReaderContentInnerListItem(
                    content: content,
                    entrySelection: $entrySelection,
                    includeSource: includeSource,
                    appearance: ReaderContentListAppearance(
                        alwaysShowThumbnails: alwaysShowThumbnails,
                        showSeparators: false,
                        useCardBackground: useCardBackground,
                        clearRowBackground: clearRowBackground,
                        useDefaultRowInsets: useDefaultRowInsets,
                        showsNewBadges: showsNewBadges,
                        wrapsContentInGroupBox: false
                    ),
                    isFirst: item.offset == section.items.startIndex,
                    isLast: item.offset == lastIndex,
                    onRequestDelete: onRequestDeleteSingle,
                    customMenuOptions: customMenuOptions,
                    onContentAppear: onContentAppear
                )
            }
            .readerContentListRowStyle(
                useDefaultRowInsets: useDefaultRowInsets || (!useCardBackground && !clearRowBackground),
                zeroHorizontalRowInsets: clearRowBackground
            )
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

        if customGrouping == nil, !showEmptyState, separateRowsIntoSections {
            separateRowSections
        } else if customGrouping == nil {
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
                    } else {
                        listItems
                            .readerContentListRowStyle(
                                useDefaultRowInsets: useDefaultRowInsets || (!useCardBackground && !clearRowBackground),
                                zeroHorizontalRowInsets: clearRowBackground
                            )
                    }
                } header: {
                    if !showEmptyState || rendersHeaderViewInSectionHeader {
                        contentSectionHeader
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
            } else if separateRowsIntoSections {
                ForEach(groupedSections) { section in
                    groupedRows(section: section)
                }
            } else {
                ForEach(groupedSections) { section in
                    if #available(iOS 17, macOS 14, *) {
                        sectionWithSpacing(
                            Section(isExpanded: binding(for: section.id)) {
                                groupedRows(section: section)
                            } header: {
                                Text(section.title)
                                    .foregroundStyle(.secondary)
                            }
                            .headerProminence(.increased)
                        )
                    } else {
                        sectionWithSpacing(
                            Section {
                                groupedRows(section: section)
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
        contentFilter: ((Int, C) async throws -> Bool)? = nil,
        sortOrder: ReaderContentSortOrder,
        includeSource: Bool,
        entrySelection: Binding<String?>,
        contentSortAscending: Bool = false,
        alwaysShowThumbnails: Bool = true,
        useCardBackground: Bool = false,
        clearRowBackground: Bool = false,
        useDefaultRowInsets: Bool = false,
        showsNewBadges: Bool = true,
        separateRowsIntoSections: Bool = false,
        listRowSpacing: CGFloat? = 15,
        listSectionSpacing: CGFloat? = nil,
        contentSectionTitle: String? = nil,
        rendersHeaderViewInSectionHeader: Bool = false,
        allowEditing: Bool = false,
        multiSelection: Binding<Set<String>>? = nil,
        showsDeletionToolbarItem: Bool = true,
        onDelete: (@MainActor ([C]) async throws -> Void)? = nil,
        customGrouping: (([C]) -> [ReaderContentGroupingSection<C>])? = nil,
        customMenuOptions: ((C) -> AnyView)? = nil,
        onContentSelected: ((C) -> Void)? = nil,
        onContentAppear: ((C) -> Void)? = nil,
        scrollTargetID: String? = nil,
        postSortTransform: (@ReaderContentListActor ([C]) -> [C])? = nil,
        @ViewBuilder supplementarySections: @escaping () -> SupplementarySections,
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
        self.useCardBackground = useCardBackground
        self.clearRowBackground = clearRowBackground
        self.useDefaultRowInsets = useDefaultRowInsets
        self.showsNewBadges = showsNewBadges
        self.separateRowsIntoSections = separateRowsIntoSections
        self.listRowSpacing = listRowSpacing
        self.listSectionSpacing = listSectionSpacing
        self.contentSectionTitle = contentSectionTitle
        self.rendersHeaderViewInSectionHeader = rendersHeaderViewInSectionHeader
        self.allowEditing = allowEditing
        self.externalMultiSelection = multiSelection
        self.showsDeletionToolbarItem = showsDeletionToolbarItem
        self.onDelete = onDelete
        self.customGrouping = customGrouping
        self.customMenuOptions = customMenuOptions
        self.onContentSelected = onContentSelected
        self.onContentAppear = onContentAppear
        self.scrollTargetID = scrollTargetID
        self.postSortTransform = postSortTransform
        self.supplementarySections = supplementarySections
        self.headerView = headerView
        self.emptyStateView = emptyStateView
        _viewModel = StateObject(wrappedValue: ReaderContentListViewModel(initialContents: contents, sortOrder: sortOrder))
    }
}

public extension ReaderContentList where SupplementarySections == EmptyView, Header == EmptyView, EmptyState == EmptyView {
    init(
        contents: [C],
        entrySelection: Binding<String?>,
        contentSortAscending: Bool = false,
        alwaysShowThumbnails: Bool = true,
        listRowSpacing: CGFloat? = 15,
        listSectionSpacing: CGFloat? = nil,
        includeSource: Bool = false,
        useCardBackground: Bool = false,
        clearRowBackground: Bool = false,
        useDefaultRowInsets: Bool = false,
        showsNewBadges: Bool = true,
        separateRowsIntoSections: Bool = false,
        sortOrder: ReaderContentSortOrder,
        contentFilter: ((C) async throws -> Bool)? = nil,
        allowEditing: Bool = false,
        multiSelection: Binding<Set<String>>? = nil,
        showsDeletionToolbarItem: Bool = true,
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
            useCardBackground: useCardBackground,
            clearRowBackground: clearRowBackground,
            useDefaultRowInsets: useDefaultRowInsets,
            showsNewBadges: showsNewBadges,
            separateRowsIntoSections: separateRowsIntoSections,
            listRowSpacing: listRowSpacing,
            listSectionSpacing: listSectionSpacing,
            contentSectionTitle: nil,
            allowEditing: allowEditing,
            multiSelection: multiSelection,
            showsDeletionToolbarItem: showsDeletionToolbarItem,
            onDelete: onDelete.map { onDelete in
                { @MainActor contents in
                    onDelete(contents)
                }
            },
            customGrouping: nil,
            customMenuOptions: nil,
            onContentSelected: nil,
            onContentAppear: nil,
            postSortTransform: nil,
            supplementarySections: { EmptyView() },
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
        useCardBackground: Bool = false,
        clearRowBackground: Bool = false,
        useDefaultRowInsets: Bool = false,
        showsNewBadges: Bool = true,
        separateRowsIntoSections: Bool = false,
        listRowSpacing: CGFloat? = 15,
        listSectionSpacing: CGFloat? = nil,
        contentSectionTitle: String? = nil,
        allowEditing: Bool = false,
        multiSelection: Binding<Set<String>>? = nil,
        showsDeletionToolbarItem: Bool = true,
        onDelete: (@MainActor ([C]) async throws -> Void)? = nil,
        customGrouping: (([C]) -> [ReaderContentGroupingSection<C>])? = nil,
        customMenuOptions: ((C) -> AnyView)? = nil,
        onContentSelected: ((C) -> Void)? = nil,
        onContentAppear: ((C) -> Void)? = nil,
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
            useCardBackground: useCardBackground,
            clearRowBackground: clearRowBackground,
            useDefaultRowInsets: useDefaultRowInsets,
            showsNewBadges: showsNewBadges,
            separateRowsIntoSections: separateRowsIntoSections,
            listRowSpacing: listRowSpacing,
            listSectionSpacing: listSectionSpacing,
            contentSectionTitle: contentSectionTitle,
            allowEditing: allowEditing,
            multiSelection: multiSelection,
            showsDeletionToolbarItem: showsDeletionToolbarItem,
            onDelete: onDelete,
            customGrouping: customGrouping,
            customMenuOptions: customMenuOptions,
            onContentSelected: onContentSelected,
            onContentAppear: onContentAppear,
            postSortTransform: postSortTransform,
            supplementarySections: { EmptyView() },
            headerView: { EmptyView() },
            emptyStateView: { EmptyView() }
        )
    }
}

public extension ReaderContentList where SupplementarySections == EmptyView {
    init(
        contents: [C],
        contentFilter: ((Int, C) async throws -> Bool)? = nil,
        sortOrder: ReaderContentSortOrder,
        includeSource: Bool,
        entrySelection: Binding<String?>,
        contentSortAscending: Bool = false,
        alwaysShowThumbnails: Bool = true,
        useCardBackground: Bool = false,
        clearRowBackground: Bool = false,
        useDefaultRowInsets: Bool = false,
        showsNewBadges: Bool = true,
        separateRowsIntoSections: Bool = false,
        listRowSpacing: CGFloat? = 15,
        listSectionSpacing: CGFloat? = nil,
        contentSectionTitle: String? = nil,
        rendersHeaderViewInSectionHeader: Bool = false,
        allowEditing: Bool = false,
        multiSelection: Binding<Set<String>>? = nil,
        showsDeletionToolbarItem: Bool = true,
        onDelete: (@MainActor ([C]) async throws -> Void)? = nil,
        customGrouping: (([C]) -> [ReaderContentGroupingSection<C>])? = nil,
        customMenuOptions: ((C) -> AnyView)? = nil,
        onContentSelected: ((C) -> Void)? = nil,
        scrollTargetID: String? = nil,
        postSortTransform: (@ReaderContentListActor ([C]) -> [C])? = nil,
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
            useCardBackground: useCardBackground,
            clearRowBackground: clearRowBackground,
            useDefaultRowInsets: useDefaultRowInsets,
            showsNewBadges: showsNewBadges,
            separateRowsIntoSections: separateRowsIntoSections,
            listRowSpacing: listRowSpacing,
            listSectionSpacing: listSectionSpacing,
            contentSectionTitle: contentSectionTitle,
            rendersHeaderViewInSectionHeader: rendersHeaderViewInSectionHeader,
            allowEditing: allowEditing,
            multiSelection: multiSelection,
            showsDeletionToolbarItem: showsDeletionToolbarItem,
            onDelete: onDelete,
            customGrouping: customGrouping,
            customMenuOptions: customMenuOptions,
            onContentSelected: onContentSelected,
            onContentAppear: nil,
            scrollTargetID: scrollTargetID,
            postSortTransform: postSortTransform,
            headerView: headerView,
            emptyStateView: emptyStateView
        )
    }

    init(
        contents: [C],
        contentFilter: ((Int, C) async throws -> Bool)? = nil,
        sortOrder: ReaderContentSortOrder,
        includeSource: Bool,
        entrySelection: Binding<String?>,
        contentSortAscending: Bool = false,
        alwaysShowThumbnails: Bool = true,
        useCardBackground: Bool = false,
        clearRowBackground: Bool = false,
        useDefaultRowInsets: Bool = false,
        showsNewBadges: Bool = true,
        separateRowsIntoSections: Bool = false,
        listRowSpacing: CGFloat? = 15,
        listSectionSpacing: CGFloat? = nil,
        contentSectionTitle: String? = nil,
        rendersHeaderViewInSectionHeader: Bool = false,
        allowEditing: Bool = false,
        multiSelection: Binding<Set<String>>? = nil,
        showsDeletionToolbarItem: Bool = true,
        onDelete: (@MainActor ([C]) async throws -> Void)? = nil,
        customGrouping: (([C]) -> [ReaderContentGroupingSection<C>])? = nil,
        customMenuOptions: ((C) -> AnyView)? = nil,
        onContentSelected: ((C) -> Void)? = nil,
        onContentAppear: ((C) -> Void)? = nil,
        scrollTargetID: String? = nil,
        postSortTransform: (@ReaderContentListActor ([C]) -> [C])? = nil,
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
            useCardBackground: useCardBackground,
            clearRowBackground: clearRowBackground,
            useDefaultRowInsets: useDefaultRowInsets,
            showsNewBadges: showsNewBadges,
            separateRowsIntoSections: separateRowsIntoSections,
            listRowSpacing: listRowSpacing,
            listSectionSpacing: listSectionSpacing,
            contentSectionTitle: contentSectionTitle,
            rendersHeaderViewInSectionHeader: rendersHeaderViewInSectionHeader,
            allowEditing: allowEditing,
            multiSelection: multiSelection,
            showsDeletionToolbarItem: showsDeletionToolbarItem,
            onDelete: onDelete,
            customGrouping: customGrouping,
            customMenuOptions: customMenuOptions,
            onContentSelected: onContentSelected,
            onContentAppear: onContentAppear,
            scrollTargetID: scrollTargetID,
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
    let onContentAppear: ((C) -> Void)?

    public var body: some View {
        ReaderContentInnerListItems(
            entrySelection: $entrySelection,
            includeSource: includeSource,
            appearance: appearance,
            viewModel: viewModel,
            onRequestDelete: onRequestDelete,
            customMenuOptions: customMenuOptions,
            onContentAppear: onContentAppear
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
        .onAppear {
        }
        .onDisappear {
        }
    }

    public init(
        viewModel: ReaderContentListViewModel<C>,
        entrySelection: Binding<String?>,
        contentSortAscending: Bool = false,
        includeSource: Bool = false,
        alwaysShowThumbnails: Bool = true,
        showSeparators: Bool = false,
        useCardBackground: Bool = false,
        clearRowBackground: Bool = false,
        useDefaultRowInsets: Bool = false,
        showsNewBadges: Bool = true,
        onRequestDelete: (@MainActor (C) async throws -> Void)? = nil,
        customMenuOptions: ((C) -> AnyView)? = nil,
        onContentSelected: ((C) -> Void)? = nil,
        onContentAppear: ((C) -> Void)? = nil
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
            showsNewBadges: showsNewBadges,
            wrapsContentInGroupBox: false
        )
        self.onRequestDelete = onRequestDelete
        self.customMenuOptions = customMenuOptions
        self.onContentSelected = onContentSelected
        self.onContentAppear = onContentAppear
    }
}

public extension ReaderContentProtocol {
    static func readerContentListView<SupplementarySections: View, Header: View, EmptyState: View>(
        contents: [Self],
        contentFilter: ((Int, Self) async throws -> Bool)? = nil,
        sortOrder: ReaderContentSortOrder,
        entrySelection: Binding<String?>,
        includeSource: Bool,
        useCardBackground: Bool = false,
        clearRowBackground: Bool = false,
        showsNewBadges: Bool = true,
        separateRowsIntoSections: Bool = false,
        listRowSpacing: CGFloat? = 15,
        listSectionSpacing: CGFloat? = nil,
        contentSectionTitle: String? = nil,
        allowEditing: Bool = false,
        multiSelection: Binding<Set<String>>? = nil,
        showsDeletionToolbarItem: Bool = true,
        onDelete: (@MainActor ([Self]) async throws -> Void)? = nil,
        customGrouping: (([Self]) -> [ReaderContentGroupingSection<Self>])? = nil,
        customMenuOptions: ((Self) -> AnyView)? = nil,
        @ViewBuilder supplementarySections: @escaping () -> SupplementarySections,
        @ViewBuilder headerView: @escaping () -> Header,
        @ViewBuilder emptyStateView: @escaping () -> EmptyState
    ) -> some View {
        ReaderContentList(
            contents: contents,
            contentFilter: contentFilter,
            sortOrder: sortOrder,
            includeSource: includeSource,
            entrySelection: entrySelection,
            useCardBackground: useCardBackground,
            clearRowBackground: clearRowBackground,
            showsNewBadges: showsNewBadges,
            separateRowsIntoSections: separateRowsIntoSections,
            listRowSpacing: listRowSpacing,
            listSectionSpacing: listSectionSpacing,
            contentSectionTitle: contentSectionTitle,
            allowEditing: allowEditing,
            multiSelection: multiSelection,
            showsDeletionToolbarItem: showsDeletionToolbarItem,
            onDelete: onDelete,
            customGrouping: customGrouping,
            customMenuOptions: customMenuOptions,
            onContentSelected: nil,
            postSortTransform: nil,
            supplementarySections: supplementarySections,
            headerView: headerView,
            emptyStateView: emptyStateView
        )
    }

    static func readerContentListView<Header: View, EmptyState: View>(
        contents: [Self],
        contentFilter: ((Int, Self) async throws -> Bool)? = nil,
        sortOrder: ReaderContentSortOrder,
        entrySelection: Binding<String?>,
        includeSource: Bool,
        useCardBackground: Bool = false,
        clearRowBackground: Bool = false,
        showsNewBadges: Bool = true,
        separateRowsIntoSections: Bool = false,
        listRowSpacing: CGFloat? = 15,
        listSectionSpacing: CGFloat? = nil,
        contentSectionTitle: String? = nil,
        allowEditing: Bool = false,
        multiSelection: Binding<Set<String>>? = nil,
        showsDeletionToolbarItem: Bool = true,
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
            useCardBackground: useCardBackground,
            clearRowBackground: clearRowBackground,
            showsNewBadges: showsNewBadges,
            separateRowsIntoSections: separateRowsIntoSections,
            listRowSpacing: listRowSpacing,
            listSectionSpacing: listSectionSpacing,
            contentSectionTitle: contentSectionTitle,
            allowEditing: allowEditing,
            multiSelection: multiSelection,
            showsDeletionToolbarItem: showsDeletionToolbarItem,
            onDelete: onDelete,
            customGrouping: customGrouping,
            customMenuOptions: customMenuOptions,
            supplementarySections: { EmptyView() },
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
        multiSelection: Binding<Set<String>>? = nil,
        showsDeletionToolbarItem: Bool = true,
        onDelete: (([Self]) -> Void)? = nil
    ) -> some View {
        ReaderContentList(
            contents: contents,
            entrySelection: entrySelection,
            sortOrder: sortOrder,
            contentFilter: contentFilter,
            allowEditing: allowEditing,
            multiSelection: multiSelection,
            showsDeletionToolbarItem: showsDeletionToolbarItem,
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
