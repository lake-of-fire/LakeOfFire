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

    public init(
        realmConfiguration: Realm.Configuration = Realm.Configuration.defaultConfiguration,
        systemScripts: [WebViewUserScript],
        observeLibraryChanges: Bool = true
    ) {
        self.baseSystemScripts = systemScripts
        super.init()
        ReaderContent.contentResolver = { pageURL, countsAsHistoryVisit, source in
            try await ReaderViewModel.getContent(
                forURL: pageURL,
                countsAsHistoryVisit: countsAsHistoryVisit,
                source: source
            )
        }

        guard observeLibraryChanges else { return }

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
    private func refreshTitleInWebView(content: any ReaderContentProtocol, newState: WebViewState? = nil) async throws {
        guard !content.isInvalidated, !content.isDeleted else { return }
        try await refreshTitleInWebView(
            title: content.title, contentURL: content.url,
            isFromClipboard: content.isFromClipboard,
            rssContainsFullContent: content.rssContainsFullContent,
            newState: newState
        )
    }

    @MainActor
    private func refreshTitleInWebView(
        title: String,
        contentURL: URL,
        isFromClipboard: Bool,
        rssContainsFullContent: Bool,
        newState: WebViewState? = nil,
        requiring bindingToken: WebViewScriptCaller.JavaScriptBindingToken? = nil
    ) async throws {
        let state = newState ?? self.state
        if !contentURL.isEBookURL && !isFromClipboard && rssContainsFullContent
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if contentURL.absoluteString == state.pageURL.absoluteString,
               !state.isLoading && !state.isProvisionallyNavigating {
                let script = """
                    (function() {
                        if (document.body?.classList.contains('readability-mode')) {
                            const title = arguments.title
                            if (typeof title === 'string' && document.title !== title) {
                                document.title = title
                            }
                        }
                    })()
                    """
                if let bindingToken {
                    try await scriptCaller.evaluateJavaScript(
                        script, arguments: ["title": title], requiring: bindingToken
                    )
                } else {
                    try await scriptCaller.evaluateJavaScript(script, arguments: ["title": title])
                }
            }
        }
    }

    @MainActor
    public func pageMetadataUpdated(title: String?, author: String? = nil) async throws {
        // Preserve the native page-title callback, including headless callers.
        // Mounted work retains its original binding through the durable write.
        let admission: ReaderDocumentMutationAdmission
        if scriptCaller.canEvaluateJavaScript {
            guard let captured = ReaderDocumentMutationAdmission.capture(
                targetURL: state.pageURL,
                requiring: scriptCaller.currentJavaScriptBindingToken,
                scriptCaller: scriptCaller
            ) else { return }
            admission = captured
        } else {
            admission = ReaderDocumentMutationAdmission(
                targetURL: state.pageURL, bindingToken: nil, bindingIsCurrent: { true }
            )
        }
        try await pageMetadataUpdated(title: title, author: author, admission: admission)
    }

    @MainActor
    func pageMetadataUpdated(
        title: String?,
        author: String? = nil,
        admission: ReaderDocumentMutationAdmission
    ) async throws {
        let targetURL = admission.targetURL
        guard admission.permitsMutation, urlsMatchWithoutHash(targetURL, state.pageURL),
              !targetURL.isNativeReaderView,
              let title = title?.replacingOccurrences(of: String("\u{fffc}"), with: ""),
              !title.isEmpty else { return }
        let newTitle = targetURL.isEBookURL
            ? title : fixAnnoyingTitlesWithPipes(title: title, url: targetURL)
        // Keep the same selected history/feed/provider discovery policy, with
        // original configurations/physical admissions captured before any await.
        let context = ReaderContentLoader.ReaderModePropagationContext()
        let references = try await ReaderContentLoader.pageMetadataReferences(for: targetURL, context: context)
        for reference in references {
            guard admission.permitsMutation, urlsMatchWithoutHash(targetURL, state.pageURL) else { return }
            let result = try await reference.writePageMetadata(
                title: newTitle, author: author, isAdmitted: { admission.permitsMutation }
            )
            guard admission.permitsMutation, urlsMatchWithoutHash(targetURL, state.pageURL) else { return }
            guard let result, result.changed || targetURL.isEBookURL,
                  let bindingToken = admission.bindingToken else { continue }
            // Presentation uses values from the committed row, never a same-key
            // successor reopened after the transaction.
            try await refreshTitleInWebView(
                title: result.title, contentURL: result.url,
                isFromClipboard: result.isFromClipboard,
                rssContainsFullContent: result.rssContainsFullContent,
                requiring: bindingToken
            )
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
