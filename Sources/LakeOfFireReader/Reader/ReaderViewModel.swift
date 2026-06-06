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

private func logReaderLoad(_ message: String) {
}

private func logTitleTrace(_ message: String) {
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
    @Published public private(set) var ebookNativeMarkReadAvailable: Bool = false
    @Published public private(set) var ebookNativeMarkReadIsRead: Bool = false
    @Published public private(set) var ebookNativeMarkReadIsBusy: Bool = false
    @Published public private(set) var ebookNativeMarkReadStateVersion: UInt64 = 0
    @Published public private(set) var ebookNativeMarkReadStateReason: String = ""
    
    public var scriptCaller = WebViewScriptCaller()
    @Published var webViewUserScripts: [WebViewUserScript]? = nil
    @Published var webViewSystemScripts: [WebViewUserScript]? = nil
    
    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    @AppStorage("readerFontSize") private var readerFontSize: Double?
    
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()
    
    public var allScripts: [WebViewUserScript] {
        return (webViewSystemScripts ?? []) + (webViewUserScripts ?? [])
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
    
    public init(realmConfiguration: Realm.Configuration = Realm.Configuration.defaultConfiguration, systemScripts: [WebViewUserScript]) {
        super.init()
        webViewSystemScripts = systemScripts
        
        Task { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration) 
            
            realm.objects(LibraryConfiguration.self)
                .collectionPublisher
                .subscribe(on: readerViewModelQueue)
                .map { _ in }
                .debounceLeadingTrailing(for: .seconds(0.3), scheduler: readerViewModelQueue)
                .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                    Task { @RealmBackgroundActor [weak self] in
                        let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate()
                        let ref = ThreadSafeReference(to: libraryConfiguration)
                        try await { @MainActor [weak self] in
                            let realm = try await Realm.open(configuration: LibraryDataManager.realmConfiguration)
                            guard let libraryConfiguration = realm.resolve(ref) else { return }
                            let webViewSystemScripts = systemScripts + libraryConfiguration.systemScripts
                            let webViewUserScripts = libraryConfiguration.getActiveWebViewUserScripts()
                            guard let self else { return }
                            if self.webViewSystemScripts != webViewSystemScripts {
                                self.webViewSystemScripts = webViewSystemScripts
                            }
                            if self.webViewUserScripts != webViewUserScripts {
                                self.webViewUserScripts = webViewUserScripts
                            }
                        }()
                    }
                })
                .store(in: &cancellables)
            
            realm.objects(UserScript.self)
                .collectionPublisher
                .subscribe(on: readerViewModelQueue)
                .map { _ in }
                .debounceLeadingTrailing(for: .seconds(1), scheduler: readerViewModelQueue)
                .receive(on: readerViewModelQueue)
                .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
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
            guard let scripts = realm.resolve(ref)?.getActiveWebViewUserScripts() else { return }
            guard let self = self else { return }
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
            "stage=readerViewModel.pageMetadataUpdated.received pageURL=\(state.pageURL.absoluteString) incomingTitle=\(title.debugTitleFragment) sanitizedTitle=\(sanitizedIncomingTitle.debugTitleFragment) author=\(author.debugTitleFragment) isNativeReaderView=\(state.pageURL.isNativeReaderView) httpStatus=\(state.mainFrameHTTPStatusCode.map(String.init) ?? "nil")"
        )
        if ReaderHTTPErrorRecoveryPolicy.isHTTPErrorStatus(state.mainFrameHTTPStatusCode) {
            let statusCode = state.mainFrameHTTPStatusCode
            debugPrint(
                "# 404 reader.metadata.skip",
                "url=\(state.pageURL.absoluteString)",
                "status=\(statusCode.map(String.init) ?? "nil")",
                "incomingTitle=\(title.debugTitleFragment)",
                "preservedStoredMetadata=true"
            )
            logTitleTrace(
                "stage=readerViewModel.pageMetadataUpdated.skippedHTTPError pageURL=\(state.pageURL.absoluteString) status=\(statusCode.map(String.init) ?? "nil") incomingTitle=\(title.debugTitleFragment)"
            )
            return
        }
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
