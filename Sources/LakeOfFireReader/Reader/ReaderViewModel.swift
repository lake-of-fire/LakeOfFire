import SwiftUI
import SwiftUIWebView
import SwiftSoup
import RealmSwift
import Combine
import RealmSwiftGaps
import SwiftUtilities
import WebKit
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

let readerViewModelQueue = DispatchQueue(label: "ReaderViewModelQueue")

public enum ReaderPageTurnRequestedLocationSource: String, Codable, Equatable, Sendable {
    case defaultRestore
    case savedRestore
}

public struct ReaderPageTurnRequestedLocationState: Codable, Equatable, Sendable {
    public let source: ReaderPageTurnRequestedLocationSource
    public let kind: String
    public let value: String
    public let surroundingContext: String?
    public let isRequestedPageChange: Bool
    public let fractionalCompletion: Float?
    public let sectionIndex: Int?
    public let mainDocumentURL: URL?

    public init(
        source: ReaderPageTurnRequestedLocationSource,
        kind: String,
        value: String,
        surroundingContext: String? = nil,
        isRequestedPageChange: Bool = false,
        fractionalCompletion: Float? = nil,
        sectionIndex: Int? = nil,
        mainDocumentURL: URL? = nil
    ) {
        self.source = source
        self.kind = kind
        self.value = value
        self.surroundingContext = surroundingContext
        self.isRequestedPageChange = isRequestedPageChange
        self.fractionalCompletion = fractionalCompletion
        self.sectionIndex = sectionIndex
        self.mainDocumentURL = mainDocumentURL
    }
}

public struct ReaderPageTurnReadingProgressState: Codable, Equatable, Sendable {
    public let cfi: String?
    public let fractionalCompletion: Float?
    public let highWaterMarkFractionalCompletion: Float?
    public let reason: String
    public let sectionIndex: Int?
    public let mainDocumentURL: URL?

    public init(
        cfi: String?,
        fractionalCompletion: Float?,
        highWaterMarkFractionalCompletion: Float? = nil,
        reason: String,
        sectionIndex: Int? = nil,
        mainDocumentURL: URL? = nil
    ) {
        self.cfi = cfi
        self.fractionalCompletion = fractionalCompletion
        self.highWaterMarkFractionalCompletion = highWaterMarkFractionalCompletion
        self.reason = reason
        self.sectionIndex = sectionIndex
        self.mainDocumentURL = mainDocumentURL
    }
}

@MainActor
public class ReaderViewModel: NSObject, ObservableObject {
    public var navigator: WebViewNavigator?
    @Published public var state: WebViewState = .empty
    @Published public private(set) var pageTurnBootstrapSerial = 0
    @Published public private(set) var ebookViewerLoadedProbeSummary: String?
    @Published public private(set) var pageTurnRequestedLocationState: ReaderPageTurnRequestedLocationState?
    @Published public private(set) var pageTurnReadingProgressState: ReaderPageTurnReadingProgressState?
    @Published public private(set) var pageTurnReadingProgressSuppressionReason: String?
    private var pageTurnReadingProgressHighWaterMark: Float?
    private var pendingPageTurnReadingProgressSuppressionCount = 0
    private var pageTurnProbeRefreshHandler: ((WKFrameInfo?) async -> Void)?
    
    public var scriptCaller = WebViewScriptCaller()
    @Published var webViewUserScripts: [WebViewUserScript]? = nil
    @Published var webViewSystemScripts: [WebViewUserScript]? = nil
    private var baseSystemScripts: [WebViewUserScript]
    
    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    @AppStorage("readerFontSize") private var readerFontSize: Double?
    
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()
    
    public var allScripts: [WebViewUserScript] {
        return (webViewSystemScripts ?? []) + (webViewUserScripts ?? [])
    }

    @MainActor
    private func logScriptDiagnostics(
        context: String,
        systemScripts: [WebViewUserScript],
        userScripts: [WebViewUserScript]
    ) {
        let total = systemScripts.count + userScripts.count
        let hasReadabilityInSystem = systemScripts.contains(where: { scriptContainsReadability($0) })
        let hasReadabilityInUser = userScripts.contains(where: { scriptContainsReadability($0) })
        let hasReadability = hasReadabilityInSystem || hasReadabilityInUser
        debugPrint(
            "# READERMODE scripts",
            "context=\(context)",
            "systemCount=\(systemScripts.count)",
            "userCount=\(userScripts.count)",
            "total=\(total)",
            "hasReadability=\(hasReadability)",
            "readabilitySystem=\(hasReadabilityInSystem)",
            "readabilityUser=\(hasReadabilityInUser)"
        )
    }

    private func scriptContainsReadability(_ script: WebViewUserScript) -> Bool {
        let source = script.source
        return source.contains("readabilityParsed") || source.contains("manabi_readability")
    }
    
    public init(realmConfiguration: Realm.Configuration = Realm.Configuration.defaultConfiguration, systemScripts: [WebViewUserScript]) {
        self.baseSystemScripts = systemScripts
        self.webViewSystemScripts = systemScripts
        self.webViewUserScripts = []
        super.init()

        logScriptDiagnostics(
            context: "initial",
            systemScripts: systemScripts,
            userScripts: []
        )
        
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
                        let baseScripts = await { @MainActor [weak self] in
                            self?.baseSystemScripts ?? []
                        }()
                        let userScriptDescriptors = libraryConfiguration.getActiveWebViewUserScriptDescriptors() ?? []
                        let librarySystemScripts = await MainActor.run { LibraryConfiguration.sharedSystemScripts }
                        let webViewUserScripts = await MainActor.run {
                            userScriptDescriptors.map { $0.makeUserScript() }
                        }
                        let webViewSystemScripts = baseScripts + librarySystemScripts
                        try await { @MainActor [weak self] in
                            guard let self else { return }
                            self.logScriptDiagnostics(
                                context: "libraryConfig",
                                systemScripts: webViewSystemScripts,
                                userScripts: webViewUserScripts ?? []
                            )
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

    @MainActor
    public func markPageTurnBootstrapReady() {
        pageTurnBootstrapSerial &+= 1
    }

    @MainActor
    public func setPageTurnProbeRefreshHandler(_ handler: ((WKFrameInfo?) async -> Void)?) {
        pageTurnProbeRefreshHandler = handler
    }

    @MainActor
    public func requestImmediatePageTurnProbeRefresh(in frameInfo: WKFrameInfo? = nil) async {
        if let pageTurnProbeRefreshHandler {
            await pageTurnProbeRefreshHandler(frameInfo)
        } else {
            markPageTurnBootstrapReady()
        }
    }

    @MainActor
    public func schedulePageTurnBootstrapRefresh(delaysNanoseconds: [UInt64]) {
        for delay in delaysNanoseconds {
            Task { @MainActor [weak self] in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                self?.markPageTurnBootstrapReady()
            }
        }
    }

    @MainActor
    public func setEbookViewerLoadedProbeSummary(_ summary: String?) {
        ebookViewerLoadedProbeSummary = summary
    }

    @MainActor
    public func setPageTurnRequestedLocationState(_ state: ReaderPageTurnRequestedLocationState?) {
        pageTurnRequestedLocationState = state
        if let state, state.source == .defaultRestore || state.source == .savedRestore {
            pendingPageTurnReadingProgressSuppressionCount = max(1, pendingPageTurnReadingProgressSuppressionCount)
            pageTurnReadingProgressSuppressionReason = "requestedLocation:\(state.source.rawValue)"
        } else if state == nil {
            pendingPageTurnReadingProgressSuppressionCount = 0
            pageTurnReadingProgressSuppressionReason = nil
        }
    }

    @MainActor
    public func setPageTurnReadingProgressState(_ state: ReaderPageTurnReadingProgressState?) {
        guard let state else {
            pageTurnReadingProgressHighWaterMark = nil
            pageTurnReadingProgressState = nil
            pageTurnReadingProgressSuppressionReason = nil
            return
        }

        if pendingPageTurnReadingProgressSuppressionCount > 0 {
            pendingPageTurnReadingProgressSuppressionCount -= 1
            pageTurnReadingProgressSuppressionReason = "progress:\(state.reason)"
            if pageTurnRequestedLocationState?.source == .defaultRestore
                || pageTurnRequestedLocationState?.source == .savedRestore {
                pageTurnRequestedLocationState = nil
            }
            return
        }
        pageTurnReadingProgressSuppressionReason = nil

        let nextHighWater = [
            pageTurnReadingProgressHighWaterMark,
            state.highWaterMarkFractionalCompletion,
            state.fractionalCompletion,
        ]
        .compactMap { $0 }
        .max()

        pageTurnReadingProgressHighWaterMark = nextHighWater
        pageTurnReadingProgressState = ReaderPageTurnReadingProgressState(
            cfi: state.cfi,
            fractionalCompletion: state.fractionalCompletion,
            highWaterMarkFractionalCompletion: nextHighWater,
            reason: state.reason,
            sectionIndex: state.sectionIndex,
            mainDocumentURL: state.mainDocumentURL
        )
    }
    
    @RealmBackgroundActor
    private func updateScripts() async throws {
        let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate()
        let descriptors = libraryConfiguration.getActiveWebViewUserScriptDescriptors() ?? []
        try await { @MainActor [weak self] in
            let scripts = descriptors.map { $0.makeUserScript() }
            guard let self = self else { return }
            self.logScriptDiagnostics(
                context: "userScripts",
                systemScripts: self.webViewSystemScripts ?? [],
                userScripts: scripts
            )
            if self.webViewUserScripts != scripts {
                self.webViewUserScripts = scripts
            }
        }()
    }

    @MainActor
    public func updateBaseSystemScripts(_ scripts: [WebViewUserScript]) {
        guard scripts != baseSystemScripts else { return }
        baseSystemScripts = scripts

        Task { @RealmBackgroundActor [weak self] in
            guard let self else { return }
            let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate()
            let librarySystemScripts = await MainActor.run { LibraryConfiguration.sharedSystemScripts }
            let webViewSystemScripts = scripts + librarySystemScripts
            try await { @MainActor [weak self] in
                guard let self else { return }
                self.logScriptDiagnostics(
                    context: "baseSystem",
                    systemScripts: webViewSystemScripts,
                    userScripts: self.webViewUserScripts ?? []
                )
                if self.webViewSystemScripts != webViewSystemScripts {
                    self.webViewSystemScripts = webViewSystemScripts
                }
            }()
        }
    }
    
    @MainActor
    public func onNavigationCommitted(content: any ReaderContentProtocol, newState: WebViewState) async throws {
        debugPrint(
            "# FLASH ReaderViewModel.onNavigationCommitted",
            "page=\(flashURLDescription(newState.pageURL))",
            "content=\(flashURLDescription(content.url))"
        )
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
        debugPrint(
            "# FLASH ReaderViewModel.onNavigationFinished",
            "page=\(flashURLDescription(newState.pageURL))",
            "content=\(flashURLDescription(content.url))"
        )
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            try Task.checkCancellation()
            refreshSettingsInWebView(content: content, newState: newState)

            completion?(newState)
            debugPrint("# FLASH ReaderViewModel.onNavigationFinished completed", "page=\(flashURLDescription(newState.pageURL))")
        }
    }
    
    // TODO: Move to Loader probably
    @MainActor
    public static func getContent(forURL pageURL: URL, countsAsHistoryVisit: Bool = false) async throws -> (any ReaderContentProtocol)? {
        return try await ReaderContentLoader.getContent(forURL: pageURL, countsAsHistoryVisit: countsAsHistoryVisit)
    }
    
    @MainActor
    private func refreshTitleInWebView(content: (any ReaderContentProtocol), newState: WebViewState? = nil) async throws {
        let state = newState ?? self.state
        if !content.url.isEBookURL && !content.isFromClipboard && content.rssContainsFullContent && !content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if content.url.absoluteString == state.pageURL.absoluteString, !state.isLoading && !state.isProvisionallyNavigating {
                debugPrint(
                    "# READERMODETITLE webView.documentTitle.sync",
                    "pageURL=\(state.pageURL.absoluteString)",
                    "title=\(content.title)"
                )
                debugPrint(
                    "# READERHEADER swift.syncDocumentTitle.start",
                    "pageURL=\(state.pageURL.absoluteString)",
                    "titleBytes=\(content.title.count)"
                )
                try await scriptCaller.evaluateJavaScript("(function() { if (document.body?.classList.contains('readability-mode')) { let title = DOMPurify.sanitize(`\(content.title)`); if (document.title != title) { document.title = title } } })()")
            }
        }
    }
    
    @MainActor
    public func pageMetadataUpdated(title: String?, author: String? = nil) async throws {
        guard !state.pageURL.isNativeReaderView, let title = title?.replacingOccurrences(of: String("\u{fffc}").trimmingCharacters(in: .whitespacesAndNewlines), with: ""), !title.isEmpty else { return }
        let newTitle: String
        if state.pageURL.isEBookURL {
            newTitle = title
        } else {
            newTitle = fixAnnoyingTitlesWithPipes(title: title)
        }
        debugPrint(
            "# READERMODETITLE metadata.received",
            "pageURL=\(state.pageURL.absoluteString)",
            "raw=\(title)",
            "normalized=\(newTitle)"
        )
        debugPrint(
            "# READERHEADER swift.pageMetadataUpdated.received",
            "pageURL=\(state.pageURL.absoluteString)",
            "rawTitleBytes=\(title.count)",
            "normalizedTitleBytes=\(newTitle.count)"
        )
        let contentRefs = try await { @RealmBackgroundActor in
            let contents = try await ReaderContentLoader.loadAll(url: state.pageURL)
            return contents.compactMap { ReaderContentLoader.ContentReference(content: $0) }
        }()
        for contentRef in contentRefs {
            guard let content = try await contentRef.resolveOnMainActor() else { continue }
            let shouldStripClipboardIndicator = content.isFromClipboard || content.url.isSnippetURL
            let finalTitle = newTitle.removingClipboardIndicatorIfNeeded(shouldStripClipboardIndicator)
            debugPrint(
                "# READERMODETITLE metadata.apply",
                "contentURL=\(content.url.absoluteString)",
                "final=\(finalTitle)",
                "author=\(author ?? "")"
            )
            debugPrint(
                "# READERHEADER swift.pageMetadataUpdated.apply",
                "contentURL=\(content.url.absoluteString)",
                "finalTitleBytes=\(finalTitle.count)",
                "authorBytes=\((author ?? "").count)"
            )
            if !finalTitle.isEmpty,
               content.title.replacingOccurrences(of: String("\u{fffc}"), with: "").trimmingCharacters(in: .whitespacesAndNewlines) != finalTitle
                || content.author != author ?? "" {
                try await content.asyncWrite { _, content in
                    content.title = finalTitle
                    content.author = author ?? ""
                    content.refreshChangeMetadata(explicitlyModified: true)
                }
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
            let resolvedFontSize = readerFontSize ?? 16
            try await self.scriptCaller.evaluateJavaScript("""
                const px = '\(resolvedFontSize)px';
                if (document.body.getAttribute('data-manabi-light-theme') !== '\(lightModeTheme)') {
                    document.body.setAttribute('data-manabi-light-theme', '\(lightModeTheme)');
                }
                if (document.body.getAttribute('data-manabi-dark-theme') !== '\(darkModeTheme)') {
                    document.body.setAttribute('data-manabi-dark-theme', '\(darkModeTheme)');
                }
                try { document.documentElement?.style?.setProperty('font-size', px); } catch (_error) {}
                try { document.body?.style?.setProperty('font-size', px); } catch (_error) {}
                try { document.body?.setAttribute?.('data-manabi-diagnostic-font-size', px); } catch (_error) {}
                globalThis.manabiDiagnosticFontSize = px;
                """, duplicateInMultiTargetFrames: true)
            debugPrint("# PAGETURN refreshSettingsInWebView.applied", "fontSize=\(resolvedFontSize)")
            try await self.refreshTitleInWebView(content: content, newState: newState)
        }
    }
}
