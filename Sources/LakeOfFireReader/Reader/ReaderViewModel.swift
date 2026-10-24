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
    public private(set) var ebookNativeHistoryAction: ReaderEBookHistoryAction?
    private let ebookNativeHistoryState = ReaderEBookNativeHistoryState()
    @Published public private(set) var ebookNativeMarkReadAvailable: Bool = false
    @Published public private(set) var ebookNativeMarkReadIsRead: Bool = false
    @Published public private(set) var ebookNativeMarkReadIsBusy: Bool = false
    @Published public private(set) var ebookNativeMarkReadStateVersion: UInt64 = 0
    @Published public private(set) var ebookNativeMarkReadStateReason: String = ""
    @Published public private(set) var requestedLocationState: ReaderRequestedLocationState?
    @Published public private(set) var readingProgressState: ReaderReadingProgressState?

    public var scriptCaller = WebViewScriptCaller()
    /// Optional owner-supplied presentation lifetime, captured before an EPUB
    /// restore reads saved data. A configured provider returning nil denies a
    /// new attempt; LakeOfFire does not own the consumer's account model.
    public var ebookRestoreLifetimeCheckProvider: (@MainActor () -> (@MainActor () -> Bool)?)?
    var ebookRestoreAttempt = ReaderEBookRestoreAttemptState<ReaderEBookRestoreNativeOwner>()
    weak var ebookRestoreCaller: WebViewScriptCaller?
    var ebookRestoreOwner: ReaderEBookRestoreNativeOwner?
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
        publishEbookNativeOverlayState(
            percentLabel: percentLabel, navigationHidden: navigationHidden,
            titleLocationLabel: titleLocationLabel, titleLocationVisible: titleLocationVisible,
            bookTitleLabel: bookTitleLabel, pagesLeftLabel: pagesLeftLabel, source: source,
            relocateBackEnabled: relocateBackEnabled, relocateForwardEnabled: relocateForwardEnabled,
            currentPageNumber: currentPageNumber, totalPages: totalPages,
            isCurrentPublication: { true }
        )
    }

    private func publishEbookNativeOverlayState(
        percentLabel: String, navigationHidden: Bool,
        titleLocationLabel: String, titleLocationVisible: Bool,
        bookTitleLabel: String, pagesLeftLabel: String, source: String,
        relocateBackEnabled: Bool, relocateForwardEnabled: Bool,
        currentPageNumber: Int?, totalPages: Int?,
        isCurrentPublication: @MainActor () -> Bool
    ) {
        guard isCurrentPublication() else { return }
        if ebookNativeOverlayPercentLabel != percentLabel {
            ebookNativeOverlayPercentLabel = percentLabel
        }
        guard isCurrentPublication() else { return }
        if ebookNativeOverlayNavigationHidden != navigationHidden {
            ebookNativeOverlayNavigationHidden = navigationHidden
        }
        guard isCurrentPublication() else { return }
        if ebookNativeOverlayTitleLocationLabel != titleLocationLabel {
            ebookNativeOverlayTitleLocationLabel = titleLocationLabel
        }
        guard isCurrentPublication() else { return }
        if ebookNativeOverlayTitleLocationVisible != titleLocationVisible {
            ebookNativeOverlayTitleLocationVisible = titleLocationVisible
        }
        guard isCurrentPublication() else { return }
        if ebookNativeOverlayBookTitleLabel != bookTitleLabel {
            ebookNativeOverlayBookTitleLabel = bookTitleLabel
        }
        guard isCurrentPublication() else { return }
        if ebookNativeOverlayPagesLeftLabel != pagesLeftLabel {
            ebookNativeOverlayPagesLeftLabel = pagesLeftLabel
        }
        guard isCurrentPublication() else { return }
        if ebookNativeOverlaySource != source {
            ebookNativeOverlaySource = source
        }
        guard isCurrentPublication() else { return }
        if ebookNativeOverlayRelocateBackEnabled != relocateBackEnabled {
            ebookNativeOverlayRelocateBackEnabled = relocateBackEnabled
        }
        guard isCurrentPublication() else { return }
        if ebookNativeOverlayRelocateForwardEnabled != relocateForwardEnabled {
            ebookNativeOverlayRelocateForwardEnabled = relocateForwardEnabled
        }
        guard isCurrentPublication() else { return }
        if ebookNativeOverlayCurrentPageNumber != currentPageNumber {
            ebookNativeOverlayCurrentPageNumber = currentPageNumber
        }
        guard isCurrentPublication() else { return }
        if ebookNativeOverlayTotalPages != totalPages {
            ebookNativeOverlayTotalPages = totalPages
        }
    }

    public func receiveEbookNativeOverlayState(
        message: WebViewMessage, caller: WebViewScriptCaller, loaderURL: URL
    ) {
        ebookNativeHistoryState.receive(
            message: message, caller: caller, loaderURL: loaderURL,
            callerIsCurrent: { [weak self, weak caller] in
                guard let self, let caller else { return false }
                return self.scriptCaller === caller
            },
            publish: { [weak self] action, overlay, isCurrent in
                self?.publishEbookNativeHistory(action: action, overlay: overlay, isCurrent: isCurrent)
            }
        )
    }

    @MainActor
    public func clearEbookNativeOverlayState(source: String) {
        ebookNativeHistoryState.clear(source: source) { [weak self] action, overlay, isCurrent in
            self?.publishEbookNativeHistory(action: action, overlay: overlay, isCurrent: isCurrent)
        }
    }

    private func publishEbookNativeHistory(
        action: ReaderEBookHistoryAction?, overlay: ReaderEBookNativeOverlayState?,
        isCurrent: @MainActor () -> Bool
    ) {
        guard isCurrent() else { return }
        let actionChanged = ebookNativeHistoryAction !== action
        // Store first: a synchronous observer can install a successor. A
        // Published willSet would overwrite that successor on return.
        ebookNativeHistoryAction = action
        if actionChanged { objectWillChange.send() }
        guard isCurrent(), let overlay else { return }
        publishEbookNativeOverlayState(
            percentLabel: overlay.percentLabel, navigationHidden: overlay.navigationHidden,
            titleLocationLabel: overlay.titleLocationLabel, titleLocationVisible: overlay.titleLocationVisible,
            bookTitleLabel: overlay.bookTitleLabel, pagesLeftLabel: overlay.pagesLeftLabel, source: overlay.source,
            relocateBackEnabled: overlay.relocateBackEnabled, relocateForwardEnabled: overlay.relocateForwardEnabled,
            currentPageNumber: overlay.currentPageNumber, totalPages: overlay.totalPages,
            isCurrentPublication: isCurrent
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
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            try Task.checkCancellation()
            refreshSettingsInWebView(content: content, newState: newState)

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
                    arguments: ["title": content.title]
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            let maxWidthOverride = readerAdaptiveMaxWidthOverrideCSSValue(readerFontSize: readerFontSize)
            try await self.scriptCaller.evaluateJavaScript("""
                if (document.body?.getAttribute('data-mnb-light-theme') !== '\(lightModeTheme)') {
                    document.body?.setAttribute('data-mnb-light-theme', '\(lightModeTheme)');
                }
                if (document.body?.getAttribute('data-mnb-dark-theme') !== '\(darkModeTheme)') {
                    document.body?.setAttribute('data-mnb-dark-theme', '\(darkModeTheme)');
                }
                document.body?.style?.setProperty('--mnb-reader-max-width-override', '\(maxWidthOverride)');
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
