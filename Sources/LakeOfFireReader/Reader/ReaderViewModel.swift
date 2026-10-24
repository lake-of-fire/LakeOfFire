import SwiftUI
import SwiftUIWebView
import SwiftSoup
import RealmSwift
import Combine
import RealmSwiftGaps
import WebKit
import LakeOfFireContent
import LakeOfFireFiles

let readerViewModelQueue = DispatchQueue(label: "ReaderViewModelQueue")

private func logReaderLoad(_ message: String) {
#if DEBUG
    debugPrint("# READERLOAD \(message)")
#endif
}

private func logTitleTrace(_ message: String) {
}

public struct ReaderRequestedLocationState: Equatable, Sendable {
    public enum Source: String, Sendable {
        case defaultRestore
        case savedRestore
    }

    public var source: Source
    public var kind: String
    public var value: String
    public var surroundingContext: String?
    public var isRequestedPageChange: Bool
    public var fractionalCompletion: Float?
    public var mainDocumentURL: URL?

    public init(
        source: Source,
        kind: String,
        value: String,
        surroundingContext: String? = nil,
        isRequestedPageChange: Bool,
        fractionalCompletion: Float? = nil,
        mainDocumentURL: URL? = nil
    ) {
        self.source = source
        self.kind = kind
        self.value = value
        self.surroundingContext = surroundingContext
        self.isRequestedPageChange = isRequestedPageChange
        self.fractionalCompletion = fractionalCompletion
        self.mainDocumentURL = mainDocumentURL
    }
}

public struct ReaderReadingProgressState: Equatable, Sendable {
    public var cfi: String?
    public var fractionalCompletion: Float?
    public var reason: String
    public var sectionIndex: Int?
    public var mainDocumentURL: URL?

    public init(
        cfi: String?,
        fractionalCompletion: Float?,
        reason: String,
        sectionIndex: Int?,
        mainDocumentURL: URL?
    ) {
        self.cfi = cfi
        self.fractionalCompletion = fractionalCompletion
        self.reason = reason
        self.sectionIndex = sectionIndex
        self.mainDocumentURL = mainDocumentURL
    }
}

@MainActor
public class ReaderViewModel: NSObject, ObservableObject {
    private static var inFlightContentTasks: [String: Task<(any ReaderContentProtocol)?, Error>] = [:]

    public var navigator: WebViewNavigator?
    @Published public var state: WebViewState = .empty
    @Published public private(set) var ebookViewerLoadedProbeSummary: String?
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
    @Published public private(set) var requestedLocationState: ReaderRequestedLocationState?
    @Published public private(set) var readingProgressState: ReaderReadingProgressState?

    public var scriptCaller = WebViewScriptCaller()
    private typealias SettingsAdmission = @MainActor () -> Bool
    private var settingsAdmissionProvider: (@MainActor (any ReaderContentProtocol) -> SettingsAdmission)?

    func bindSettingsOwner(_ owner: NavigationTaskManager) {
        settingsAdmissionProvider = { [weak owner, weak self] content in
            guard let owner, let self else { return { false } }
            return owner.makeSettingsCommitFence(content: content, readerViewModel: self)
        }
    }

    private func captureSettingsAdmission(content: any ReaderContentProtocol) -> SettingsAdmission {
        // Standalone callers retain the public API's caller/page/binding checks.
        // Mounted readers additionally require their original content selection.
        settingsAdmissionProvider?(content) ?? { true }
    }
    @Published var webViewUserScripts: [WebViewUserScript]? = nil
    @Published var webViewSystemScripts: [WebViewUserScript]? = nil
    private let baseSystemScripts: [WebViewUserScript]

    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    @AppStorage("readerFontSize") private var readerFontSize: Double?

    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()

    @MainActor
    private static let builtInReaderScripts = [
        ReaderDocStateUserScript().userScript,
        ReaderUnhandledTapUserScript().userScript,
    ]

    @MainActor
    public var allScripts: [WebViewUserScript] {
        Self.builtInReaderScripts + (webViewSystemScripts ?? []) + (webViewUserScripts ?? [])
    }

    @MainActor
    public func setEbookViewerLoadedProbeSummary(_ summary: String?) {
        ebookViewerLoadedProbeSummary = summary
    }

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
        relocateForwardEnabled: Bool,
        currentPageNumber: Int? = nil,
        totalPages: Int? = nil
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
    }

    @MainActor
    public func setEbookNativeMarkReadState(
        available: Bool,
        isRead: Bool,
        isBusy: Bool,
        reason: String
    ) {
        ebookNativeMarkReadStateVersion &+= 1
        ebookNativeMarkReadStateReason = reason
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

    @MainActor
    public func setRequestedLocationState(_ state: ReaderRequestedLocationState?) {
        requestedLocationState = state
    }

    @MainActor
    public func setReadingProgressState(_ state: ReaderReadingProgressState?) {
        readingProgressState = state
    }

    public init(realmConfiguration: Realm.Configuration = Realm.Configuration.defaultConfiguration, systemScripts: [WebViewUserScript]) {
        self.baseSystemScripts = systemScripts
        super.init()
        ReaderContent.contentResolver = { pageURL, countsAsHistoryVisit, source in
            try await ReaderViewModel.getContent(
                forURL: pageURL,
                countsAsHistoryVisit: countsAsHistoryVisit,
                source: source
            )
        }

        Task { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)

            realm.objects(LibraryConfiguration.self)
                .collectionPublisher
                .subscribe(on: readerViewModelQueue)
                .map { @Sendable _ in }
                .debounceLeadingTrailing(for: .seconds(0.3), scheduler: readerViewModelQueue)
                .sink(receiveCompletion: { @Sendable _ in }, receiveValue: { @Sendable [weak self] _ in
                    Task { @MainActor [weak self] in
                        try await self?.updateScripts()
                    }
                })
                .store(in: &cancellables)

            realm.objects(UserScript.self)
                .collectionPublisher
                .subscribe(on: readerViewModelQueue)
                .map { @Sendable _ in }
                .debounceLeadingTrailing(for: .seconds(1), scheduler: readerViewModelQueue)
                .receive(on: readerViewModelQueue)
                .sink(receiveCompletion: { @Sendable _ in }, receiveValue: { @Sendable [weak self] _ in
                    Task { @MainActor [weak self] in
                        try await self?.updateScripts()
                    }
                })
                .store(in: &self.cancellables)
        }
    }

    @RealmBackgroundActor
    private func updateScripts() async throws {
        let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate()
        let ref = ThreadSafeReference(to: libraryConfiguration)
        try await { @MainActor [weak self] in
            let realm = try await Realm.open(configuration: LibraryDataManager.realmConfiguration)
            guard let libraryConfiguration = realm.resolve(ref) else { return }
            guard let scripts = libraryConfiguration.getActiveWebViewUserScripts() else { return }
            guard let self = self else { return }
            let webViewSystemScripts = self.baseSystemScripts + libraryConfiguration.systemScripts
            if self.webViewSystemScripts != webViewSystemScripts {
                self.webViewSystemScripts = webViewSystemScripts
            }
            if self.webViewUserScripts != scripts {
                self.webViewUserScripts = scripts
            }
        }()
    }

    @MainActor
    public func onNavigationCommitted(content: any ReaderContentProtocol, newState: WebViewState) async throws {
        if let historyRecord = content as? HistoryRecord {
            let contentRef = ReaderContentLoader.ContentReference(content: historyRecord)
            Task { @RealmBackgroundActor in
                guard let content = try await contentRef?.resolveOnBackgroundActor() as? HistoryRecord else { return }
//                await content.realm?.asyncRefresh()
                try await content.realm?.asyncWrite {
                    content.lastVisitedAt = Date()
                    content.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }
    }

    public func onNavigationFinished(content: any ReaderContentProtocol, newState: WebViewState, completion: ((WebViewState) -> Void)? = nil) {
        onNavigationFinished(content: content, newState: newState,
                             documentIsCurrent: captureSettingsAdmission(content: content), completion: completion)
    }

    @discardableResult
    func onNavigationFinished(
        content: any ReaderContentProtocol,
        newState: WebViewState,
        documentIsCurrent: @escaping @MainActor () -> Bool,
        completion: ((WebViewState) -> Void)? = nil
    ) -> Task<Void, Never>? {
        scheduleSettingsRefresh(content: content, newState: newState,
                                documentIsCurrent: documentIsCurrent,
                                completion: completion)
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
    private func refreshTitleInWebView(
        content: any ReaderContentProtocol,
        newState: WebViewState? = nil,
        requiring expectedBinding: WebViewScriptCaller.JavaScriptBindingToken? = nil
    ) async throws {
        let state = newState ?? self.state
        guard !Task.isCancelled, !content.isInvalidated,
              self.state.pageURL.matchesReaderURL(state.pageURL),
              let binding = expectedBinding ?? scriptCaller.currentJavaScriptBindingToken,
              scriptCaller.currentJavaScriptBindingToken == binding else { return }
        logTitleTrace(
            "stage=readerViewModel.refreshTitleInWebView pageURL=\(state.pageURL.absoluteString) contentURL=\(content.url.absoluteString) contentType=\(String(describing: type(of: content))) contentTitle=\(content.title.debugTitleFragment) rssContainsFullContent=\(content.rssContainsFullContent) isLoading=\(state.isLoading) isProvisionallyNavigating=\(state.isProvisionallyNavigating)"
        )
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
                    arguments: ["title": content.title],
                    requiring: binding
                )
            }
        }
    }

    @MainActor
    public func pageMetadataUpdated(title: String?, author: String? = nil) async throws {
        let sanitizedIncomingTitle = title?
            .replacingOccurrences(of: String("\u{fffc}").trimmingCharacters(in: .whitespacesAndNewlines), with: "")
        logTitleTrace(
            "stage=readerViewModel.pageMetadataUpdated.received pageURL=\(state.pageURL.absoluteString) incomingTitle=\(title.debugTitleFragment) sanitizedTitle=\(sanitizedIncomingTitle.debugTitleFragment) author=\(author.debugTitleFragment) isNativeReaderView=\(state.pageURL.isNativeReaderView)"
        )
        guard !state.pageURL.isNativeReaderView, let title = title?.replacingOccurrences(of: String("\u{fffc}").trimmingCharacters(in: .whitespacesAndNewlines), with: ""), !title.isEmpty else { return }
        let newTitle: String
        if state.pageURL.isEBookURL {
            newTitle = title
        } else {
            newTitle = fixAnnoyingTitlesWithPipes(title: title, url: state.pageURL)
        }
        logTitleTrace(
            "stage=readerViewModel.pageMetadataUpdated.normalized pageURL=\(state.pageURL.absoluteString) newTitle=\(newTitle.debugTitleFragment)"
        )
        let contentRefs = try await { @RealmBackgroundActor in
            let contents = try await ReaderContentLoader.loadAll(url: state.pageURL)
            return contents.compactMap { ReaderContentLoader.ContentReference(content: $0) }
        }()
        for contentRef in contentRefs {
            guard let content = try await contentRef.resolveOnMainActor() else { continue }
            let shouldStripClipboardIndicator = content.isFromClipboard || content.url.isSnippetURL
            let finalTitle = newTitle.removingClipboardIndicatorIfNeeded(shouldStripClipboardIndicator)
            let existingTitle = content.title
                .replacingOccurrences(of: String("\u{fffc}"), with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            logTitleTrace(
                "stage=readerViewModel.pageMetadataUpdated.inspect contentURL=\(content.url.absoluteString) contentType=\(String(describing: type(of: content))) key=\(content.compoundKey) existingTitle=\(existingTitle.debugTitleFragment) finalTitle=\(finalTitle.debugTitleFragment) existingAuthor=\(content.author.debugTitleFragment) newAuthor=\((author ?? "").debugTitleFragment)"
            )
            if !finalTitle.isEmpty, existingTitle != finalTitle || content.author != author ?? "" {
                try await content.asyncWrite { _, content in
                    content.title = finalTitle
                    content.author = author ?? ""
                    content.refreshChangeMetadata(explicitlyModified: true)
                }
                logTitleTrace(
                    "stage=readerViewModel.pageMetadataUpdated.persisted contentURL=\(content.url.absoluteString) key=\(content.compoundKey) persistedTitle=\(finalTitle.debugTitleFragment) persistedAuthor=\((author ?? "").debugTitleFragment)"
                )
                try await refreshTitleInWebView(content: content)
            } else if state.pageURL.isEBookURL {
                try await refreshTitleInWebView(content: content)
            }
        }
    }

    @MainActor
    public func refreshSettingsInWebView(content: any ReaderContentProtocol, newState: WebViewState? = nil) {
        refreshSettingsInWebView(content: content, newState: newState,
                                 documentIsCurrent: captureSettingsAdmission(content: content))
    }

    @discardableResult
    func refreshSettingsInWebView(
        content: any ReaderContentProtocol,
        newState: WebViewState? = nil,
        documentIsCurrent: @escaping @MainActor () -> Bool
    ) -> Task<Void, Never>? {
        scheduleSettingsRefresh(content: content, newState: newState ?? state,
                                documentIsCurrent: documentIsCurrent)
    }

    private func scheduleSettingsRefresh(
        content: any ReaderContentProtocol,
        newState: WebViewState,
        documentIsCurrent: @escaping @MainActor () -> Bool,
        completion: ((WebViewState) -> Void)? = nil
    ) -> Task<Void, Never>? {
        guard !Task.isCancelled, !content.isInvalidated else { return nil }
        let caller = scriptCaller
        let binding = caller.currentJavaScriptBindingToken
        guard binding != nil || completion != nil else { return nil }
        let contentURL = content.url
        let ownsCandidate = { @MainActor [weak self] in
            guard let self, !Task.isCancelled, !content.isInvalidated else { return false }
            return self.scriptCaller === caller
                && caller.currentJavaScriptBindingToken == binding
                && (binding != nil || !caller.canEvaluateJavaScript)
                && content.url == contentURL
                && contentURL.matchesReaderURL(newState.pageURL)
                && self.state.pageURL.matchesReaderURL(newState.pageURL)
        }
        // A collaborator may synchronously replace the selection or invalidate
        // the row. Recheck safe access after invoking its admission predicate.
        let isCurrent = { @MainActor in
            ownsCandidate() && documentIsCurrent() && ownsCandidate()
        }
        guard isCurrent() else { return nil }
        return Task { @MainActor [weak self] in
            guard let self, isCurrent() else { return }
            // Preserve completion-before-JavaScript ordering without handing
            // the settings/title continuation to a second unowned task.
            completion?(newState)
            guard isCurrent(), let binding else { return }
            let maxWidthOverride = readerAdaptiveMaxWidthOverrideCSSValue(readerFontSize: readerFontSize)
            do {
                try await caller.evaluateJavaScript("""
                if (document.body?.getAttribute('data-mnb-light-theme') !== '\(lightModeTheme)') {
                    document.body?.setAttribute('data-mnb-light-theme', '\(lightModeTheme)');
                }
                if (document.body?.getAttribute('data-mnb-dark-theme') !== '\(darkModeTheme)') {
                    document.body?.setAttribute('data-mnb-dark-theme', '\(darkModeTheme)');
                }
                document.body?.style?.setProperty('--mnb-reader-max-width-override', '\(maxWidthOverride)');
                """, duplicateInMultiTargetFrames: true, requiring: binding)
                guard isCurrent() else { return }
                try await self.refreshTitleInWebView(content: content, newState: newState,
                                                     requiring: binding)
            } catch {
                // A failed or retired settings command cannot publish a title.
                // A later current refresh remains free to retry.
            }
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
