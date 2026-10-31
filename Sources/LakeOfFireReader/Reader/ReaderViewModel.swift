import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import SwiftUIWebView
import SwiftSoup
import RealmSwift
import Combine
import RealmSwiftGaps
import WebKit

let readerViewModelQueue = DispatchQueue(label: "ReaderViewModelQueue")



@MainActor
public class ReaderViewModel: NSObject, ObservableObject {
    private static var inFlightContentTasks: [String: Task<(any ReaderContentProtocol)?, Error>] = [:]

    public var navigator: WebViewNavigator?
    @Published public var state: WebViewState = .empty {
        didSet {
#if DEBUG
            if oldValue.pageURL != state.pageURL { ebookPageTurnStyles = [] }
            if oldValue.hasReaderRenderReady != state.hasReaderRenderReady
                || oldValue.pageURL != state.pageURL {
                ReaderLoadTrace.event("readerModel.stateAssigned",
                                      "model=\(ObjectIdentifier(self)) oldReady=\(oldValue.hasReaderRenderReady) ready=\(state.hasReaderRenderReady) pageURL=\(state.pageURL.absoluteString)")
            }
#endif
        }
    }
    @Published public private(set) var ebookViewerLoadedProbeSummary: String?
#if DEBUG
    @Published public private(set) var ebookPageTurnStyles: [String] = []
#endif
    @Published public private(set) var ebookChromeInsetsResyncID: UInt64 = 0
    @Published public private(set) var ebookNativeOverlayPercentLabel: String = ""
    @Published public private(set) var ebookNativeOverlayNavigationHidden: Bool = false
    @Published public private(set) var ebookNativeOverlayTitleLocationLabel: String = ""
    @Published public private(set) var ebookNativeOverlayTitleLocationVisible: Bool = false
    @Published public private(set) var ebookNativeOverlayBookTitleLabel: String = ""
    @Published public private(set) var ebookNativeOverlayPagesLeftLabel: String = ""
    @Published public private(set) var ebookNativeOverlaySource: String = ""
    @Published public private(set) var ebookNativeOverlayRelocateBackEnabled: Bool = false
    @Published public private(set) var ebookNativeOverlayRelocateForwardEnabled: Bool = false
    @Published public private(set) var ebookNativeOverlayCurrentPageNumber: Int?
    @Published public private(set) var ebookNativeOverlayTotalPages: Int?
    @Published public private(set) var ebookNativeMarkReadAvailable: Bool = false
    @Published public private(set) var ebookNativeMarkReadIsRead: Bool = false
    @Published public private(set) var ebookNativeMarkReadIsBusy: Bool = false
    @Published public private(set) var ebookNativeMarkReadStateVersion: UInt64 = 0
    @Published public private(set) var ebookNativeMarkReadStateReason: String = ""
    @Published public private(set) var ebookNativeMarkReadRequestOutcome: String = "none"
    @Published public private(set) var ebookNativeMarkReadRequestErrorCode: String = ""
    public var scriptCaller = WebViewScriptCaller()
    // Empty is already the effective rendering value before library hydration.
    // An empty first snapshot must not invalidate the newly constructed reader.
    @Published var webViewUserScripts: [WebViewUserScript] = []
    @Published var webViewSystemScripts: [WebViewUserScript] = []
    
    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    @AppStorage("readerFontSize") private var readerFontSize: Double?
    
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()
    @RealmBackgroundActor
    private var scriptSnapshotRevision: UInt64 = 0
    private var appliedScriptSnapshotRevision: UInt64 = 0

    @MainActor
    private static let builtInReaderScripts = [
        ReaderDocStateUserScript().userScript,
        ReaderUnhandledTapUserScript().userScript,
    ]
    
    @MainActor
    public var allScripts: [WebViewUserScript] {
        Self.builtInReaderScripts + webViewSystemScripts + webViewUserScripts
    }

    @MainActor
    public func setEbookViewerLoadedProbeSummary(_ summary: String?) {
        ebookViewerLoadedProbeSummary = summary
#if DEBUG
        if summary == nil { ebookPageTurnStyles = [] }
#endif
    }

#if DEBUG
    public func setEbookPageTurnStyles(_ styles: [String]) {
        ebookPageTurnStyles = ["instant", "slide"].filter { styles.contains($0) }
    }
#endif

    @MainActor
    public func triggerEbookChromeInsetsResync() {
        ebookChromeInsetsResyncID &+= 1
    }

    @MainActor
    public func setEbookNativeOverlayState(
        percentLabel: String,
        navigationHidden: Bool,
        titleLocationLabel: String,
        titleLocationVisible: Bool,
        bookTitleLabel: String,
        pagesLeftLabel: String,
        source: String,
        relocateBackEnabled: Bool,
        relocateForwardEnabled: Bool
    ) {
        if ebookNativeOverlayPercentLabel != percentLabel {
            ebookNativeOverlayPercentLabel = percentLabel
        }
        if ebookNativeOverlayNavigationHidden != navigationHidden {
            ebookNativeOverlayNavigationHidden = navigationHidden
        }
        if ebookNativeOverlayTitleLocationLabel != titleLocationLabel {
            ebookNativeOverlayTitleLocationLabel = titleLocationLabel
        }
        if ebookNativeOverlayTitleLocationVisible != titleLocationVisible {
            ebookNativeOverlayTitleLocationVisible = titleLocationVisible
        }
        if ebookNativeOverlayBookTitleLabel != bookTitleLabel {
            ebookNativeOverlayBookTitleLabel = bookTitleLabel
        }
        if ebookNativeOverlayPagesLeftLabel != pagesLeftLabel {
            ebookNativeOverlayPagesLeftLabel = pagesLeftLabel
        }
        if ebookNativeOverlaySource != source {
            ebookNativeOverlaySource = source
        }
        if ebookNativeOverlayRelocateBackEnabled != relocateBackEnabled {
            ebookNativeOverlayRelocateBackEnabled = relocateBackEnabled
        }
        if ebookNativeOverlayRelocateForwardEnabled != relocateForwardEnabled {
            ebookNativeOverlayRelocateForwardEnabled = relocateForwardEnabled
        }
    }

    @MainActor
    public func setEbookNativeOverlayPageState(
        currentPageNumber: Int?,
        totalPages: Int?
    ) {
        if ebookNativeOverlayCurrentPageNumber != currentPageNumber {
            ebookNativeOverlayCurrentPageNumber = currentPageNumber
        }
        if ebookNativeOverlayTotalPages != totalPages {
            ebookNativeOverlayTotalPages = totalPages
        }
    }

    @MainActor
    public func clearEbookNativeOverlayState(source: String) {
        setEbookNativeOverlayState(
            percentLabel: "",
            navigationHidden: false,
            titleLocationLabel: "",
            titleLocationVisible: false,
            bookTitleLabel: "",
            pagesLeftLabel: "",
            source: source,
            relocateBackEnabled: false,
            relocateForwardEnabled: false
        )
        setEbookNativeOverlayPageState(currentPageNumber: nil, totalPages: nil)
    }

    @MainActor
    public func setEbookNativeMarkReadState(
        available: Bool,
        isRead: Bool,
        isBusy: Bool,
        reason: String,
        requestOutcome: String = "none",
        requestErrorCode: String = ""
    ) {
        ebookNativeMarkReadStateVersion &+= 1
        ebookNativeMarkReadStateReason = reason
        ebookNativeMarkReadRequestOutcome = requestOutcome
        ebookNativeMarkReadRequestErrorCode = requestErrorCode
        if ebookNativeMarkReadAvailable != available {
            ebookNativeMarkReadAvailable = available
        }
        if ebookNativeMarkReadIsRead != isRead {
            ebookNativeMarkReadIsRead = isRead
        }
        if ebookNativeMarkReadIsBusy != isBusy {
            ebookNativeMarkReadIsBusy = isBusy
        }
    }
    
    public init(
        realmConfiguration: Realm.Configuration = LibraryDataManager.realmConfiguration,
        systemScripts: [WebViewUserScript]
    ) {
        let trace = ReaderLoadTrace.begin("reader.viewModelConstruction")
        defer { trace?.end() }
        super.init()
        webViewSystemScripts = systemScripts + LibraryConfiguration.bundledSystemScripts
        
        Task { @RealmBackgroundActor [weak self, realmConfiguration] in
            guard let self = self else { return }
            let libraryRealm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)

            let configurationChanges = libraryRealm.objects(LibraryConfiguration.self)
                .collectionPublisher
                .subscribe(on: readerViewModelQueue)
                .map { @Sendable _ in }
            let scriptChanges = libraryRealm.objects(UserScript.self)
                .collectionPublisher
                .subscribe(on: readerViewModelQueue)
                .map { @Sendable _ in }
            // Domains are UUID references, not Realm links. A domain-only edit
            // or independently synced arrival must invalidate the projection.
            let domainChanges = libraryRealm.objects(UserScriptAllowedDomain.self)
                .collectionPublisher
                .subscribe(on: readerViewModelQueue)
                .map { @Sendable _ in }

            // All subscriptions emit an initial value. Start one current-state
            // refresh after all are observing, then coalesce each source's
            // invalidations through the same path. Dropping one initial event
            // could miss an edit made while that subscription is installed.
            configurationChanges.combineLatest(scriptChanges, domainChanges)
                .map { @Sendable _ in }
                .debounceLeadingTrailing(for: .seconds(0.3), scheduler: readerViewModelQueue)
                .sink(receiveCompletion: { @Sendable _ in }, receiveValue: { @Sendable [weak self] _ in
                    Task { @RealmBackgroundActor [weak self] in
                        try await self?.updateScripts(
                            realmConfiguration: realmConfiguration
                        )
                    }
                })
                .store(in: &self.cancellables)
        }
    }
    
    @RealmBackgroundActor
    private func updateScripts(
        realmConfiguration: Realm.Configuration
    ) async throws {
        let trace = ReaderLoadTrace.begin("reader.scriptSnapshot")
        defer { trace?.end() }
        try Task.checkCancellation()
        ReaderLoadTrace.event("reader.scriptSnapshot", "phase=consolidationStarted")
        let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate(realmConfiguration: realmConfiguration)
        ReaderLoadTrace.event("reader.scriptSnapshot", "phase=consolidationFinished")
        try Task.checkCancellation()
        guard !libraryConfiguration.isInvalidated, !libraryConfiguration.isDeleted else { return }
        // Only plain values cross actors. WebKit worlds and scripts are both
        // created on MainActor, without opening another Realm there.
        let scripts = libraryConfiguration.getActiveUserScriptSnapshots() ?? []
        scriptSnapshotRevision += 1
        let revision = scriptSnapshotRevision
        ReaderLoadTrace.event("reader.scriptSnapshot", "phase=publicationRequested count=\(scripts.count)")
        try await { @MainActor [weak self, scripts] in
            try Task.checkCancellation()
            guard let self else { return }
            ReaderLoadTrace.event("reader.scriptSnapshot", "phase=publicationStarted")
            self.applyUserScriptSnapshot(scripts, revision: revision)
        }()
    }

    @MainActor
    func applyUserScriptSnapshot(_ snapshots: [UserScriptSnapshot], revision: UInt64) {
        // Actor hops need not deliver in order. Advance even for equal values so
        // an older, different snapshot cannot replace the latest accepted one.
        guard revision > appliedScriptSnapshotRevision else { return }
        appliedScriptSnapshotRevision = revision
        let scripts = snapshots.map { $0.makeWebViewUserScript() }
        if webViewUserScripts != scripts {
            webViewUserScripts = scripts
        }
    }
    
    @MainActor
    public func onNavigationCommitted(content: any ReaderContentProtocol, newState: WebViewState) async throws {
        if let historyRecord = content as? HistoryRecord {
            let contentRef = ReaderContentLoader.ContentReference(content: historyRecord)
            try await { @RealmBackgroundActor in
                try Task.checkCancellation()
                guard let contentRef else { return }
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: contentRef.realmConfiguration)
                try await realm.asyncRefresh()
                try await realm.asyncWritePreservingOwnership {
                    guard let content = realm.object(
                        ofType: HistoryRecord.self, forPrimaryKey: contentRef.contentKey
                    ), !content.isDeleted else { return }
                    try Task.checkCancellation()
                    content.lastVisitedAt = Date()
                    content.refreshChangeMetadata(explicitlyModified: true)
                }
            }()
        }
    }
    
    public func onNavigationFinished(content: any ReaderContentProtocol, newState: WebViewState, completion: ((WebViewState) -> Void)? = nil) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            try Task.checkCancellation()
            refreshSettingsInWebView(content: content, newState: newState, reason: "navigation-finished")
            
            completion?(newState)
        }
    }
    
    // TODO: Move to Loader probably
    @MainActor
    public static func getContent(
        forURL pageURL: URL,
        countsAsHistoryVisit: Bool = false,
        source: String = "ReaderViewModel.getContent"
    ) async throws -> (any ReaderContentProtocol)? {
        try await ReaderContentLoader.getContent(
            forURL: pageURL,
            countsAsHistoryVisit: countsAsHistoryVisit,
            source: source
        )
    }
    
    @MainActor
    private func refreshTitleInWebView(content: (any ReaderContentProtocol), newState: WebViewState? = nil) async throws {
        let state = newState ?? self.state
        if !content.url.isEBookURL && !content.isFromClipboard && content.rssContainsFullContent && !content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if content.url.absoluteString == state.pageURL.absoluteString, !state.isLoading && !state.isProvisionallyNavigating {
                try await scriptCaller.evaluateJavaScript(
                    """
                    (function() {
                        if (document.body?.classList.contains('readability-mode')) {
                            const title = arguments.title
                            if (typeof title === 'string' && document.title !== title) {
                                document.title = title
                            }
                        }
                    })()
                    """,
                    arguments: ["title": content.title]
                )
            }
        }
    }
    
    @MainActor
    public func pageMetadataUpdated(
        title: String?,
        author: String? = nil,
        expectedDocumentURL: URL? = nil
    ) async throws {
        let sanitizedIncomingTitle = title?
            .replacingOccurrences(of: String("\u{fffc}").trimmingCharacters(in: .whitespacesAndNewlines), with: "")
        if ReaderHTTPErrorRecoveryPolicy.isHTTPErrorStatus(state.mainFrameHTTPStatusCode) {
            return
        }
        if let expectedDocumentURL,
           !urlsMatchWithoutHash(expectedDocumentURL, state.pageURL) {
            return
        }
        let targetURL = expectedDocumentURL ?? state.pageURL
        guard !targetURL.isNativeReaderView, let title = title?.replacingOccurrences(of: String("\u{fffc}").trimmingCharacters(in: .whitespacesAndNewlines), with: ""), !title.isEmpty else { return }
        let newTitle: String
        if targetURL.isEBookURL {
            newTitle = title
        } else {
            newTitle = fixAnnoyingTitlesWithPipes(title: title, url: targetURL)
        }
        let contentRefs = try await { @RealmBackgroundActor in
            let contents = try await ReaderContentLoader.loadAll(url: targetURL)
            return contents.compactMap { ReaderContentLoader.ContentReference(content: $0) }
        }()
        for contentRef in contentRefs {
            if let expectedDocumentURL,
               !urlsMatchWithoutHash(expectedDocumentURL, state.pageURL) {
                return
            }
            guard let content = try await contentRef.resolveOnMainActor() else { continue }
            let shouldStripClipboardIndicator = content.isFromClipboard || content.url.isSnippetURL
            let finalTitle = newTitle.removingClipboardIndicatorIfNeeded(shouldStripClipboardIndicator)
            let existingTitle = content.title
                .replacingOccurrences(of: String("\u{fffc}"), with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalTitle.isEmpty, existingTitle != finalTitle || content.author != author ?? "" {
                if let expectedDocumentURL,
                   !urlsMatchWithoutHash(expectedDocumentURL, state.pageURL) {
                    return
                }
                try await content.asyncWrite { _, content in
                    guard !Task.isCancelled else { return }
                    content.title = finalTitle
                    content.author = author ?? ""
                    content.refreshChangeMetadata(explicitlyModified: true)
                }
                try await refreshTitleInWebView(content: content)
            } else if targetURL.isEBookURL {
                try await refreshTitleInWebView(content: content)
            }
        }
    }
    
    @MainActor
    public func refreshSettingsInWebView(content: any ReaderContentProtocol, newState: WebViewState? = nil) {
        refreshSettingsInWebView(content: content, newState: newState, reason: "unspecified")
    }

    @MainActor
    public func refreshSettingsInWebView(content: any ReaderContentProtocol, newState: WebViewState? = nil, reason: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let maxWidthOverride = readerAdaptiveMaxWidthOverrideCSSValue(readerFontSize: readerFontSize)
            let reasonJSON = (try? JSONEncoder().encode(reason))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\"unspecified\""
            try await self.scriptCaller.evaluateJavaScript("""
                (() => {
                    const settingsTraceReason = \(reasonJSON);
                    const traceAll = globalThis.__manabiTimelineTraceAll === true;
                    const mark = (event, payload = '', force = false) => {
                        if (!traceAll && !force) { return; }
                        const label = `MANABI swiftSettings.refreshSettingsInWebView.${event}${payload ? ' ' + payload : ''}`;
                        try { performance.mark(label); } catch (_) {}
                    };
                    const signature = [
                        'light=\(lightModeTheme)',
                        'dark=\(darkModeTheme)',
                        'maxWidth=\(maxWidthOverride)'
                    ].join('|');
                    if (document.body?.dataset?.mnbReaderViewModelSettingsSignature === signature) {
                        mark('skipSameSignature', `reason=${settingsTraceReason} maxWidth=\(maxWidthOverride)`);
                        return;
                    }
                    mark('start', `reason=${settingsTraceReason} maxWidth=\(maxWidthOverride)`);
                    let changedCount = 0;
                    if (document.body?.getAttribute('data-mnb-light-theme') !== '\(lightModeTheme)') {
                        document.body?.setAttribute('data-mnb-light-theme', '\(lightModeTheme)');
                        changedCount += 1;
                    }
                    if (document.body?.getAttribute('data-mnb-dark-theme') !== '\(darkModeTheme)') {
                        document.body?.setAttribute('data-mnb-dark-theme', '\(darkModeTheme)');
                        changedCount += 1;
                    }
                    if (document.body?.style?.getPropertyValue('--mnb-reader-max-width-override') !== '\(maxWidthOverride)') {
                        document.body?.style?.setProperty('--mnb-reader-max-width-override', '\(maxWidthOverride)');
                        changedCount += 1;
                    }
                    if (document.body?.dataset) {
                        document.body.dataset.mnbReaderViewModelSettingsSignature = signature;
                    }
                    if (changedCount > 0 || traceAll) {
                        mark('finish', `reason=${settingsTraceReason} maxWidth=\(maxWidthOverride) changedCount=${changedCount}`, changedCount > 0);
                    }
                })();
                //# sourceURL=lake-reader-view-model-settings-sync.js

                """, duplicateInMultiTargetFrames: true)
            try await self.refreshTitleInWebView(content: content, newState: newState)
        }
    }
}

private extension String {
    var debugTitleFragment: String {
        let normalized = replacingOccurrences(of: "\n", with: "\\n")
        if normalized.isEmpty {
            return "\"\""
        }
        return "\"\(normalized.truncate(120, trailing: "…"))\""
    }
}

private extension Optional where Wrapped == String {
    var debugTitleFragment: String {
        guard let value = self else { return "<nil>" }
        return value.debugTitleFragment
    }
}
