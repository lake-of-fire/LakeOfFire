import SwiftUI
import SwiftUIWebView
import SwiftSoup
import RealmSwift
import Combine
import RealmSwiftGaps
import WebKit

@MainActor
public class ReaderViewModel: NSObject, ObservableObject {
    public var navigator: WebViewNavigator?
    @Published public var state: WebViewState = .empty
    
    public var scriptCaller = WebViewScriptCaller()
    @Published var webViewUserScripts: [WebViewUserScript]? = nil
    @Published var webViewSystemScripts: [WebViewUserScript]? = nil
    
    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    
    private var cancellables = Set<AnyCancellable>()
    
    public var allScripts: [WebViewUserScript] {
        return (webViewSystemScripts ?? []) + (webViewUserScripts ?? [])
    }

    public init(realmConfiguration: Realm.Configuration = Realm.Configuration.defaultConfiguration, systemScripts: [WebViewUserScript]) {
        super.init()
        
        Task.detached { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            let configuration = try await LibraryConfiguration.getOrCreate()
            let ref = ThreadSafeReference(to: configuration)
            try await Task { @MainActor [weak self] in
                let realm = try Realm(configuration: LibraryDataManager.realmConfiguration)
                guard let self = self, let configuration = realm.resolve(ref) else { return }
                self.webViewSystemScripts = systemScripts + configuration.systemScripts
                self.webViewUserScripts = configuration.activeWebViewUserScripts
            }.value
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let realm = try await Realm(configuration: realmConfiguration)
                realm.objects(UserScript.self)
                    .collectionPublisher
                    .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
                    .receive(on: DispatchQueue.main)
                    .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                        Task { [weak self] in
                            try await self?.updateScripts()
                        }
                    })
                    .store(in: &self.cancellables)
            }
        }
    }
    
    @RealmBackgroundActor
    private func updateScripts() async throws {
        let libraryConfiguration = try await LibraryConfiguration.getOrCreate()
        let ref = ThreadSafeReference(to: libraryConfiguration)
        Task { @MainActor [weak self] in
            let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: MainActor.shared)
            guard let scripts = realm.resolve(ref)?.activeWebViewUserScripts else { return }
            guard let self = self else { return }
            if self.webViewUserScripts != scripts {
                self.webViewUserScripts = scripts
            }
        }
    }
    
    @MainActor
    public func onNavigationCommitted(content: any ReaderContentProtocol, newState: WebViewState) async throws {
        if let historyRecord = content as? HistoryRecord {
            Task.detached { @RealmBackgroundActor in
                guard let content = try await ReaderContentLoader.fromMainActor(content: historyRecord) as? HistoryRecord, let realm = content.realm else { return }
                try await realm.asyncWrite {
                    content.lastVisitedAt = Date()
                }
            }
        }
    }
    
    public func onNavigationFinished(content: any ReaderContentProtocol, newState: WebViewState, completion: ((WebViewState) -> Void)? = nil) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            try Task.checkCancellation()
            refreshSettingsInWebView(content: content, newState: newState)
            refreshTitleInWebView(content: content, newState: newState)
            
            if let completion = completion {
                completion(newState)
            }
        }
    }
    
    // TODO: Move to Loader probably
    @MainActor
    public static func getContent(forURL pageURL: URL) async throws -> (any ReaderContentProtocol)? {
        if pageURL.absoluteString.hasPrefix("internal://local/load/reader?reader-url="), let range = pageURL.absoluteString.range(of: "?reader-url=", options: []), let rawURL = String(pageURL.absoluteString[range.upperBound...]).removingPercentEncoding, let contentURL = URL(string: rawURL), let content = try await ReaderContentLoader.load(url: contentURL, countsAsHistoryVisit: true) {
            return content
        } else if let content = try await ReaderContentLoader.load(url: pageURL, persist: !pageURL.isNativeReaderView, countsAsHistoryVisit: true) {
            return content
        }
        return nil
    }
    
    @MainActor
    private func refreshTitleInWebView(content: (any ReaderContentProtocol), newState: WebViewState? = nil) {
        let state = newState ?? self.state
        if !content.url.isEBookURL && !content.isFromClipboard && content.rssContainsFullContent && !content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if content.url.absoluteString == state.pageURL.absoluteString, !state.isLoading && !state.isProvisionallyNavigating {
                scriptCaller.evaluateJavaScript("(function() { if (document.body?.classList.contains('readability-mode')) { let title = DOMPurify.sanitize(`\(content.title)`); if (document.title != title) { document.title = title } } })()")
            }
        }
    }
    
    @MainActor
    public func pageMetadataUpdated(title: String?, author: String? = nil) async throws {
        guard !state.pageURL.isNativeReaderView, let title = title?.replacingOccurrences(of: String("\u{fffc}").trimmingCharacters(in: .whitespacesAndNewlines), with: ""), !title.isEmpty else { return }
        let newTitle = fixAnnoyingTitlesWithPipes(title: title)
        let contents = try await ReaderContentLoader.fromBackgroundActor(contents: ReaderContentLoader.loadAll(url: state.pageURL))
        for content in contents {
            if !newTitle.isEmpty, state.pageURL.isEBookURL || content.title.replacingOccurrences(of: String("\u{fffc}"), with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await content.asyncWrite { _, content in
                    content.title = newTitle
                    content.author = author ?? ""
                }
                refreshTitleInWebView(content: content)
            }
        }
    }
    
    @MainActor
    public func refreshSettingsInWebView(content: any ReaderContentProtocol, newState: WebViewState? = nil) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.scriptCaller.evaluateJavaScript("""
                if (document.body.getAttribute('data-manabi-light-theme') !== '\(lightModeTheme)') {
                    document.body.setAttribute('data-manabi-light-theme', '\(lightModeTheme)');
                }
                if (document.body.getAttribute('data-manabi-dark-theme') !== '\(darkModeTheme)') {
                    document.body.setAttribute('data-manabi-dark-theme', '\(darkModeTheme)');
                }
                """, duplicateInMultiTargetFrames: true)
            self.refreshTitleInWebView(content: content, newState: newState)
        }
    }
}
