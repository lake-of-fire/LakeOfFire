import SwiftUI
import SwiftUIWebView
import SwiftSoup
import RealmSwift
import Combine
import RealmSwiftGaps
import SwiftUtilities
import WebKit

let readerViewModelQueue = DispatchQueue(label: "ReaderViewModelQueue")

@MainActor
public class ReaderViewModel: NSObject, ObservableObject {
    public var navigator: WebViewNavigator?
    @Published public var state: WebViewState = .empty
    
    public var scriptCaller = WebViewScriptCaller()
    @Published var webViewUserScripts: [WebViewUserScript]? = nil
    @Published var webViewSystemScripts: [WebViewUserScript]? = nil
    
    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()
    
    public var allScripts: [WebViewUserScript] {
        return (webViewSystemScripts ?? []) + (webViewUserScripts ?? [])
    }
    
    public init(realmConfiguration: Realm.Configuration = Realm.Configuration.defaultConfiguration, systemScripts: [WebViewUserScript]) {
        super.init()
        
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
                        let webViewSystemScripts = systemScripts + libraryConfiguration.systemScripts
                        let webViewUserScripts = libraryConfiguration.getActiveWebViewUserScripts()
                        try await { @MainActor [weak self] in
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
        debugPrint("# FLASH ReaderViewModel.getContent start", "page=\(flashURLDescription(pageURL))")
        if let contentURL = ReaderContentLoader.getContentURL(fromLoaderURL: pageURL) {
            debugPrint(
                "# FLASH ReaderViewModel.getContent loaderRedirect",
                "page=\(flashURLDescription(pageURL))",
                "->",
                flashURLDescription(contentURL)
            )
            if let content = try await ReaderContentLoader.load(url: contentURL, countsAsHistoryVisit: countsAsHistoryVisit) {
                try Task.checkCancellation()
                debugPrint("# FLASH ReaderViewModel.getContent resolved via loader", "content=\(flashURLDescription(contentURL))")
                return content
            } else {
                debugPrint("# FLASH ReaderViewModel.getContent loaderRedirectFailed", "content=\(flashURLDescription(contentURL))")
            }
        }
        if pageURL.isSnippetURL {
            debugPrint("# FLASH ReaderViewModel.getContent snippetNoLoader", "page=\(flashURLDescription(pageURL))")
        }
        if let content = try await ReaderContentLoader.load(url: pageURL, persist: !pageURL.isNativeReaderView, countsAsHistoryVisit: true) {
            try Task.checkCancellation()
            debugPrint("# FLASH ReaderViewModel.getContent resolved direct", "page=\(flashURLDescription(pageURL))")
            return content
        } else if let content = try await ReaderContentLoader.load(url: pageURL, persist: !pageURL.isNativeReaderView, countsAsHistoryVisit: true) {
            try Task.checkCancellation()
            debugPrint("# FLASH ReaderViewModel.getContent resolved direct", "page=\(flashURLDescription(pageURL))")
            return content
        }
        try Task.checkCancellation()
        debugPrint("# FLASH ReaderViewModel.getContent no match", "page=\(flashURLDescription(pageURL))")
        return nil
    }
    
    @MainActor
    private func refreshTitleInWebView(content: (any ReaderContentProtocol), newState: WebViewState? = nil) async throws {
        let state = newState ?? self.state
        if !content.url.isEBookURL && !content.isFromClipboard && content.rssContainsFullContent && !content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if content.url.absoluteString == state.pageURL.absoluteString, !state.isLoading && !state.isProvisionallyNavigating {
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
        let contentRefs = try await { @RealmBackgroundActor in
            let contents = try await ReaderContentLoader.loadAll(url: state.pageURL)
            return contents.compactMap { ReaderContentLoader.ContentReference(content: $0) }
        }()
        for contentRef in contentRefs {
            guard let content = try await contentRef.resolveOnMainActor() else { continue }
            let shouldStripClipboardIndicator = content.isFromClipboard || content.url.isSnippetURL
            let finalTitle = newTitle.removingClipboardIndicatorIfNeeded(shouldStripClipboardIndicator)
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
            try await self.scriptCaller.evaluateJavaScript("""
                if (document.body.getAttribute('data-manabi-light-theme') !== '\(lightModeTheme)') {
                    document.body.setAttribute('data-manabi-light-theme', '\(lightModeTheme)');
                }
                if (document.body.getAttribute('data-manabi-dark-theme') !== '\(darkModeTheme)') {
                    document.body.setAttribute('data-manabi-dark-theme', '\(darkModeTheme)');
                }
                """, duplicateInMultiTargetFrames: true)
            try await self.refreshTitleInWebView(content: content, newState: newState)
        }
    }
}
