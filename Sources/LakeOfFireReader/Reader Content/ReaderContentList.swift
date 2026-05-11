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

private func logReaderLoad(_ message: String) {
#if DEBUG
    debugPrint("# READERLOAD \(message)")
#endif
}

private func logSnippetLoad(_ message: String) {
#if DEBUG
    debugPrint("# SNIPPETLOAD", message)
#endif
}

private func logDetent(_ message: String) {
#if DEBUG
    debugPrint("# DETENT \(message)")
#endif
}

private func logFeedFlash(_ message: String) {
#if DEBUG
    debugPrint("# FEEDFLASH \(message)")
#endif
}

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
    func readerContentListRowStyle(showSeparators: Bool = false, useDefaultRowInsets: Bool = false) -> some View {
        if #available(iOS 15, macOS 12, *) {
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

    var usesNativeRowInsets: Bool {
        useDefaultRowInsets || (!useCardBackground && !clearRowBackground)
    }
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
                    logSnippetLoad(
                        "selectionChanged oldSelection=\(oldValue ?? "nil") selection=\(itemSelection) selectedURL=\(selectedContent.url.absoluteString) currentReaderURL=\(readerContent.pageURL.absoluteString) shouldSyncToReader=\(shouldSyncToReader) hasCustomHandler=\(onSelection != nil) alreadyLoaded=\(isAlreadyLoaded)"
                    )
                }
                if isAlreadyLoaded {
                    logReaderLoad(
                        "# SAMECONTENT stage=list.selectionChanged oldSelection=\(oldValue ?? "nil") selection=\(itemSelection) selectedURL=\(selectedContent.url.absoluteString) currentReaderURL=\(readerContent.pageURL.absoluteString)"
                    )
                }
                logReaderLoad(
                    "stage=contentList.selectionChanged selection=\(itemSelection) selectedURL=\(selectedContent.url.absoluteString) currentReaderURL=\(readerContent.pageURL.absoluteString) shouldSyncToReader=\(shouldSyncToReader) hasCustomHandler=\(onSelection != nil) alreadyLoaded=\(isAlreadyLoaded)"
                )
                logDetent(
                    "contentList.selectionChanged oldSelection=\(oldValue ?? "nil") selection=\(itemSelection) selectedURL=\(selectedContent.url.absoluteString) currentReaderURL=\(readerContent.pageURL.absoluteString) shouldSyncToReader=\(shouldSyncToReader) hasCustomHandler=\(onSelection != nil) alreadyLoaded=\(isAlreadyLoaded)"
                )

                Task { @MainActor in
                    if let onSelection {
                        if selectedContent.url.isSnippetURL {
                            logSnippetLoad(
                                "selectionDispatch mode=customHandler selection=\(itemSelection) selectedURL=\(selectedContent.url.absoluteString)"
                            )
                        }
                        logReaderLoad(
                            "stage=contentList.selectionDispatch mode=customHandler selection=\(itemSelection) selectedURL=\(selectedContent.url.absoluteString)"
                        )
                        logDetent(
                            "contentList.selectionDispatch mode=customHandler selection=\(itemSelection) selectedURL=\(selectedContent.url.absoluteString)"
                        )
                        onSelection(selectedContent)
                        if entrySelection == itemSelection {
                            logDetent(
                                "contentList.clearEntrySelectionAfterCustomHandler selection=\(itemSelection)"
                            )
                            entrySelection = nil
                        }
                        return
                    }

                    guard shouldSyncToReader else { return }
                    if selectedContent.url.isSnippetURL {
                        logSnippetLoad(
                            "selectionDispatch mode=\(isAlreadyLoaded ? "alreadyLoaded" : "navigatorLoad") selection=\(itemSelection) selectedURL=\(selectedContent.url.absoluteString)"
                        )
                    }
                    logReaderLoad(
                        "stage=contentList.selectionDispatch mode=\(isAlreadyLoaded ? "alreadyLoaded" : "navigatorLoad") selection=\(itemSelection) selectedURL=\(selectedContent.url.absoluteString)"
                    )
                    logDetent(
                        "contentList.selectionDispatch mode=\(isAlreadyLoaded ? "alreadyLoaded" : "navigatorLoad") selection=\(itemSelection) selectedURL=\(selectedContent.url.absoluteString)"
                    )
                    logDetent(
                        "contentList.navigationHint.before selection=\(itemSelection) selectedURL=\(selectedContent.url.absoluteString)"
                    )
                    contentSelectionNavigationHint?(selectedContent.url, selectedContent.compoundKey)
                    logDetent(
                        "contentList.navigationHint.after selection=\(itemSelection) selectedURL=\(selectedContent.url.absoluteString)"
                    )
                    guard !isAlreadyLoaded else {
                        logReaderLoad(
                            "# SAMECONTENT stage=list.skipNavigatorLoad selection=\(itemSelection) selectedURL=\(selectedContent.url.absoluteString)"
                        )
                        if entrySelection == itemSelection {
                            logReaderLoad(
                                "# SAMECONTENT stage=list.clearSelection selection=\(itemSelection)"
                            )
                            logDetent(
                                "contentList.clearEntrySelectionSameContent selection=\(itemSelection)"
                            )
                            entrySelection = nil
                        }
                        return
                    }
                    do {
                        try await navigator.load(
                            content: selectedContent,
                            readerModeViewModel: readerModeViewModel
                        )
                    } catch {
                        errorMessage = ReaderFileOperationMessageMapper.openMessage(for: error) ?? error.localizedDescription
                        logReaderLoad(
                            "stage=contentList.selectionDispatchFailed selection=\(itemSelection) selectedURL=\(selectedContent.url.absoluteString) error=\(error.localizedDescription)"
                        )
                        debugPrint("Failed to load reader content for selection", error)
                    }
                    if entrySelection == itemSelection {
                        logDetent(
                            "contentList.clearEntrySelectionAfterNavigatorLoad selection=\(itemSelection) selectedURL=\(selectedContent.url.absoluteString)"
                        )
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
            logReaderLoad(
                "stage=contentList.refreshSelection.skip reason=readerProvisionallyNavigating readerPageURL=\(readerPageURL.absoluteString)"
            )
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
                            logReaderLoad(
                                "stage=contentList.refreshSelection.clear reason=selectionDoesNotMatchReader selection=\(currentSelection ?? "nil") readerPageURL=\(readerPageURL.absoluteString) elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(refreshStartedAt)))"
                            )
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
                            logReaderLoad(
                                "stage=contentList.refreshSelection.clear reason=readerPageMissingFromList selection=\(currentSelection ?? "nil") readerPageURL=\(readerPageURL.absoluteString) elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(refreshStartedAt)))"
                            )
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
        logFeedFlash(
            "readerContentList.applyFilteredContents type=\(String(describing: C.self)) oldCount=\(filteredContents.count) newCount=\(contents.count) oldIDs=\(filteredContentIDs.joined(separator: ",")) newIDs=\(ids.joined(separator: ",")) hasLoadedBefore=\(hasLoadedBefore) isLoading=\(isLoading)"
        )
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
        logFeedFlash(
            "readerContentList.load.begin type=\(String(describing: C.self)) inputCount=\(contents.count) inputIDs=\(contentIDs.joined(separator: ",")) currentFilteredCount=\(filteredContents.count) currentFilteredIDs=\(filteredContentIDs.joined(separator: ",")) hasLoadedBefore=\(hasLoadedBefore) isLoading=\(isLoading) sortOrder=\(String(describing: sortOrder)) hasFilter=\(contentFilter != nil) hasPostSortTransform=\(postSortTransform != nil)"
        )

        if sortOrder == nil && contentFilter == nil && postSortTransform == nil {
            applyFilteredContents(
                contents.map { $0.realm == nil ? $0 : $0.freeze() },
                ids: contentIDs
            )
            logFeedFlash(
                "readerContentList.load.endSync type=\(String(describing: C.self)) outputCount=\(contentIDs.count) outputIDs=\(contentIDs.joined(separator: ","))"
            )
            return
        }

        if !hasLoadedBefore,
           filteredContents.isEmpty,
           !contents.isEmpty,
           postSortTransform == nil {
            let initialContents = Self.initialDisplayContents(from: contents, sortOrder: sortOrder)
            applyFilteredContents(initialContents, ids: initialContents.map(\.compoundKey))
            logFeedFlash(
                "readerContentList.load.seedInitialContents type=\(String(describing: C.self)) outputCount=\(initialContents.count) outputIDs=\(initialContents.map(\.compoundKey).joined(separator: ",")) sortOrder=\(String(describing: sortOrder))"
            )
        }

        let realmConfig = contents.first?.realm?.configuration
        realmConfiguration = realmConfig
        loadContentsTask?.cancel()
        let loadID = UUID()
        currentLoadID = loadID
        logFeedFlash(
            "readerContentList.load.taskScheduled type=\(String(describing: C.self)) inputCount=\(contents.count) hadRealmConfig=\(realmConfig != nil)"
        )
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
                logFeedFlash(
                    "readerContentList.load.taskFiltered type=\(String(describing: C.self)) filteredCount=\(filtered.count) ids=\(ids.joined(separator: ","))"
                )
            }
            try await { @MainActor [weak self] in
                guard let self else { return }
                guard self.currentLoadID == loadID else {
                    logFeedFlash(
                        "readerContentList.load.skipStaleApply type=\(String(describing: C.self)) filteredCount=\(filtered.count) ids=\(ids.joined(separator: ","))"
                    )
                    return
                }
                let resolvedContents: [C]
                if let realmConfig {
                    let realm = try await Realm(configuration: realmConfig, actor: MainActor.shared)
                    guard self.currentLoadID == loadID else {
                        logFeedFlash(
                            "readerContentList.load.skipStaleApplyAfterResolve type=\(String(describing: C.self)) filteredCount=\(filtered.count) ids=\(ids.joined(separator: ","))"
                        )
                        return
                    }
                    resolvedContents = ids.compactMap { realm.object(ofType: C.self, forPrimaryKey: $0)?.freeze() }
                } else {
                    resolvedContents = filtered.map { $0.realm == nil ? $0 : $0.freeze() }
                }
                self.applyFilteredContents(resolvedContents, ids: ids)
            }()
        }
        loadContentsTask = task

        try? await task.value
        guard currentLoadID == loadID else {
            logFeedFlash(
                "readerContentList.load.skipStaleEnd type=\(String(describing: C.self)) filteredCount=\(filteredContents.count) filteredIDs=\(filteredContentIDs.joined(separator: ","))"
            )
            return
        }
        loadContentsTask = nil
        logFeedFlash(
            "readerContentList.load.endAsync type=\(String(describing: C.self)) filteredCount=\(filteredContents.count) filteredIDs=\(filteredContentIDs.joined(separator: ",")) hasLoadedBefore=\(hasLoadedBefore)"
        )
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
    @EnvironmentObject private var readerContent: ReaderContent

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
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            let wasSelected = (entrySelection == content.compoundKey)
                            logDetent(
                                "contentList.rowTap selection=\(content.compoundKey) selectedURL=\(content.url.absoluteString) currentEntrySelection=\(entrySelection ?? "nil") wasSelected=\(wasSelected)"
                            )
                            if content.url.isSnippetURL {
                                logSnippetLoad(
                                    "rowTap selection=\(content.compoundKey) currentEntrySelection=\(entrySelection ?? "nil") wasSelected=\(wasSelected)"
                                )
                            }
                            if !wasSelected {
                                logDetent(
                                    "contentList.rowTap.assignSelection selection=\(content.compoundKey) selectedURL=\(content.url.absoluteString)"
                                )
                                entrySelection = content.compoundKey
                                if content.url.isSnippetURL {
                                    logSnippetLoad(
                                        "rowTap.assignSelection selection=\(content.compoundKey)"
                                    )
                                }
                            }
                        }
                    )
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            guard entrySelection == content.compoundKey else { return }
                            logReaderLoad(
                                "# SAMECONTENT stage=list.reselectGesture selection=\(content.compoundKey) currentReaderURL=\(readerContent.pageURL.absoluteString)"
                            )
                            logDetent(
                                "contentList.reselectGesture.clear selection=\(content.compoundKey) currentReaderURL=\(readerContent.pageURL.absoluteString)"
                            )
                            entrySelection = nil
                            Task { @MainActor in
                                logReaderLoad(
                                    "# SAMECONTENT stage=list.reselectGestureRestore selection=\(content.compoundKey)"
                                )
                                logDetent(
                                    "contentList.reselectGesture.restore selection=\(content.compoundKey)"
                                )
                                entrySelection = content.compoundKey
                            }
                        }
                    )
                    .accessibilityIdentifier("ReaderContentRow.\(content.compoundKey)")
                    .accessibilityLabel(content.title)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        if content.url.isSnippetURL {
                            logSnippetLoad(
                                "accessibilityAction selection=\(content.compoundKey)"
                            )
                        }
                        logDetent(
                            "contentList.accessibilityAction.assignSelection selection=\(content.compoundKey) selectedURL=\(content.url.absoluteString)"
                        )
                        entrySelection = content.compoundKey
                    }
            } else {
                Button {
                    logDetent(
                        "contentList.legacyButtonTap.assignSelection selection=\(content.compoundKey) selectedURL=\(content.url.absoluteString) currentEntrySelection=\(entrySelection ?? "nil")"
                    )
                    if content.url.isSnippetURL {
                        logSnippetLoad(
                            "legacyButtonTap selection=\(content.compoundKey) currentEntrySelection=\(entrySelection ?? "nil")"
                        )
                    }
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
    let onDelete: (@MainActor ([C]) async throws -> Void)?
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

#if os(iOS)
    @Environment(\.editMode) private var editMode
#endif
    @State private var multiSelection = Set<String>()
    @State private var deleteEligibilityByContentKey: [String: ReaderFileDeleteEligibility] = [:]
    @State private var deleteEligibilityRefreshTask: Task<Void, Never>?

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
            onContentSelected: onContentSelected
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
                            useCardBackground: useCardBackground,
                            clearRowBackground: clearRowBackground,
                            useDefaultRowInsets: useDefaultRowInsets,
                            showsNewBadges: showsNewBadges
                        ),
                        isFirst: true,
                        isLast: true,
                        viewModel: viewModel,
                        onRequestDelete: onRequestDeleteSingle,
                        customMenuOptions: customMenuOptions
                    )
                    .readerContentListRowStyle(
                        useDefaultRowInsets: useDefaultRowInsets || (!useCardBackground && !clearRowBackground)
                    )
                } header: {
                    if index == viewModel.filteredContents.startIndex,
                       !showEmptyState || rendersHeaderViewInSectionHeader {
                        contentSectionHeader
                    }
                }
                .headerProminence(.increased)
            )
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

    public var body: some View {
        Group {
            listContainerWithSpacing
                .onAppear {
                    logFeedFlash(
                        "readerContentList.appear type=\(String(describing: C.self)) contents=\(contents.count) filtered=\(viewModel.filteredContents.count) showEmptyState=\(showEmptyState) showLoadingIndicator=\(viewModel.showLoadingIndicator) hasLoadedBefore=\(viewModel.hasLoadedBefore) isLoading=\(viewModel.isLoading)"
                    )
                }
                .onDisappear {
                    logFeedFlash(
                        "readerContentList.disappear type=\(String(describing: C.self)) contents=\(contents.count) filtered=\(viewModel.filteredContents.count) showEmptyState=\(showEmptyState) showLoadingIndicator=\(viewModel.showLoadingIndicator) hasLoadedBefore=\(viewModel.hasLoadedBefore) isLoading=\(viewModel.isLoading)"
                    )
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
                    logFeedFlash(
                        "readerContentList.task.begin type=\(String(describing: C.self)) contents=\(contents.count) filtered=\(viewModel.filteredContents.count) showEmptyState=\(showEmptyState) showLoadingIndicator=\(viewModel.showLoadingIndicator)"
                    )
                    try? await viewModel.load(
                        contents: contents,
                        contentFilter: contentFilter,
                        sortOrder: sortOrder,
                        postSortTransform: postSortTransform
                    )
                    refreshGrouping()
                    logFeedFlash(
                        "readerContentList.task.end type=\(String(describing: C.self)) contents=\(contents.count) filtered=\(viewModel.filteredContents.count) showEmptyState=\(showEmptyState) showLoadingIndicator=\(viewModel.showLoadingIndicator)"
                    )
                }
                .onChange(of: contents) { contents in
                    logFeedFlash(
                        "readerContentList.contentsChanged type=\(String(describing: C.self)) contents=\(contents.count) filtered=\(viewModel.filteredContents.count) showEmptyState=\(showEmptyState) showLoadingIndicator=\(viewModel.showLoadingIndicator)"
                    )
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
                    logFeedFlash(
                        "readerContentList.filteredContentsChanged type=\(String(describing: C.self)) filtered=\(viewModel.filteredContents.count) filteredIDs=\(viewModel.filteredContentIDs.joined(separator: ",")) showEmptyState=\(showEmptyState) showLoadingIndicator=\(viewModel.showLoadingIndicator)"
                    )
                    refreshGrouping()
                    refreshDeleteEligibilityCache()
                }
                .onChange(of: multiSelection) { _ in
                    refreshDeleteEligibilityCache()
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
                showsNewBadges: showsNewBadges
            ),
            isFirst: index == section.items.startIndex,
            isLast: index == lastIndex,
            viewModel: viewModel,
            onRequestDelete: onRequestDeleteSingle,
            customMenuOptions: customMenuOptions
        )
        .readerContentListRowStyle(
            useDefaultRowInsets: useDefaultRowInsets || (!useCardBackground && !clearRowBackground)
        )
    }

    @ViewBuilder
    private func groupedRows(section: ReaderContentGroupingSection<C>) -> some View {
        if separateRowsIntoSections {
            ForEach(Array(section.items.enumerated()), id: \.element.compoundKey) { index, content in
                sectionWithSpacing(
                    Section {
                        groupedRowContent(section: section, index: index, content: content)
                    } header: {
                        if index == section.items.startIndex {
                            Text(section.title)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .headerProminence(.increased)
                )
            }
        } else {
            let lastIndex = section.items.indices.last ?? section.items.startIndex
            ForEach(Array(section.items.enumerated()), id: \.element.compoundKey) { index, content in
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
                        showsNewBadges: showsNewBadges
                    ),
                    isFirst: index == section.items.startIndex,
                    isLast: index == lastIndex,
                    viewModel: viewModel,
                    onRequestDelete: onRequestDeleteSingle,
                    customMenuOptions: customMenuOptions
                )
            }
            .readerContentListRowStyle(
                useDefaultRowInsets: useDefaultRowInsets || (!useCardBackground && !clearRowBackground)
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
                                useDefaultRowInsets: useDefaultRowInsets || (!useCardBackground && !clearRowBackground)
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
            } else {
                ForEach(groupedSections) { section in
                    if separateRowsIntoSections {
                        groupedRows(section: section)
                    } else if #available(iOS 17, macOS 14, *) {
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
        onDelete: (@MainActor ([C]) async throws -> Void)? = nil,
        customGrouping: (([C]) -> [ReaderContentGroupingSection<C>])? = nil,
        customMenuOptions: ((C) -> AnyView)? = nil,
        onContentSelected: ((C) -> Void)? = nil,
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
        self.onDelete = onDelete
        self.customGrouping = customGrouping
        self.customMenuOptions = customMenuOptions
        self.onContentSelected = onContentSelected
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
            onDelete: onDelete.map { onDelete in
                { @MainActor contents in
                    onDelete(contents)
                }
            },
            customGrouping: nil,
            customMenuOptions: nil,
            onContentSelected: nil,
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
            useCardBackground: useCardBackground,
            clearRowBackground: clearRowBackground,
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
        onDelete: (@MainActor ([C]) async throws -> Void)? = nil,
        customGrouping: (([C]) -> [ReaderContentGroupingSection<C>])? = nil,
        customMenuOptions: ((C) -> AnyView)? = nil,
        onContentSelected: ((C) -> Void)? = nil,
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
            useDefaultRowInsets: appearance.usesNativeRowInsets
        )
        .readerContentSelectionSync(
            viewModel: viewModel,
            entrySelection: $entrySelection,
            enabled: true,
            onSelection: onContentSelected
        )
        .onAppear {
            logFeedFlash(
                "readerContentListItems.appear type=\(String(describing: C.self)) filtered=\(viewModel.filteredContents.count) filteredIDs=\(viewModel.filteredContentIDs.joined(separator: ","))"
            )
        }
        .onDisappear {
            logFeedFlash(
                "readerContentListItems.disappear type=\(String(describing: C.self)) filtered=\(viewModel.filteredContents.count) filteredIDs=\(viewModel.filteredContentIDs.joined(separator: ","))"
            )
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
