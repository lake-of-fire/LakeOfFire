import SwiftUI
import SwiftUIWebView
import RealmSwift
import Combine
import RealmSwiftGaps
import WebKit

public class ReaderViewModel: NSObject, ObservableObject {
    public let navigator = WebViewNavigator()
    @Published public var state: WebViewState = .empty {
//    public var action: WebViewAction = .idle
//    public var state: WebViewState = .empty {
        didSet {
            if let imageURL = state.pageImageURL, content.imageUrl == nil {
                Task { @MainActor in
                    safeWrite(content) { _, content in
                        content.imageUrl = imageURL
                    }
                }
            }
        }
    }
    
    @Published public var content: (any ReaderContentModel) = ReaderContentLoader.unsavedHome
    @Published var readabilityContent: String? = nil
    public var scriptCaller = WebViewScriptCaller()
    @Published var webViewUserScripts =  LibraryConfiguration.shared.activeWebViewUserScripts
    @Published var webViewSystemScripts = LibraryConfiguration.shared.systemScripts
    
    @Published var contentRules: String? = nil
    @Published public var isMediaPlayerPresented = false
    @Published public var audioURLs = [URL]()
    
    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    
    private var navigationTask: Task<Void, Error>?
    private var cancellables = Set<AnyCancellable>()
    
    public var allScripts: [WebViewUserScript] {
        return webViewSystemScripts + webViewUserScripts
    }
    
    public var contentRulesForReadabilityLoading = """
    [\(["image", "style-sheet", "font", "media", "popup", "svg-document", "websocket", "other"].map {
        """
        {
             "trigger": {
                 "url-filter": ".*",
                 "resource-type": ["\($0)"]
             },
             "action": {
                 "type": "block"
             }
         },
        """
    })
    ]
    """
    
    public init(realmConfiguration: Realm.Configuration = Realm.Configuration.defaultConfiguration, systemScripts: [WebViewUserScript]) {
        super.init()
        
        webViewSystemScripts = systemScripts + LibraryConfiguration.shared.systemScripts
        webViewUserScripts = webViewUserScripts
        
        let realm = try! Realm(configuration: realmConfiguration)
        realm.objects(UserScript.self)
            .changesetPublisher
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main, options: .init(qos: .userInitiated))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] changes in
                switch changes {
                case .initial(_):
                    self?.updateScripts()
                case .update(_, deletions: _, insertions: _, modifications: _):
                    self?.updateScripts()
                case .error(let error):
                    print(error.localizedDescription)
                }
            }
            .store(in: &cancellables)
    }
    
    private func updateScripts() {
        Task { @MainActor in
            let scripts = LibraryConfiguration.shared.activeWebViewUserScripts
            if webViewUserScripts != scripts {
                webViewUserScripts = scripts
            }
        }
    }
    
    public func onNavigationCommitted(newState: WebViewState, completion: ((WebViewState) -> Void)? = nil) {
//
//        if let content = ReaderContentLoader.load(url: newState.pageURL, persist: !newState.pageURL.isNativeReaderView, countsAsHistoryVisit: true) {
//
//            self.content = content
//            self.isNextLoadInReaderMode = content.isReaderModeByDefault
//
//            print("## nav committed content \(content.className) \(content.url) page url: \(newState.pageURL) is reader: \(content.isReaderModeByDefault)")
//        }
//        let isReaderModeByDefault = content.isReaderModeByDefault
//        let existingTitle = content.title
//        let contentURL = content.url
        
        if newState.pageURL.absoluteString.starts(with: "about:load/reader?reader-url="), let range = newState.pageURL.absoluteString.range(of: "?reader-url=", options: []), let rawURL = String(newState.pageURL.absoluteString[range.upperBound...]).removingPercentEncoding, let contentURL = URL(string: rawURL), let content = ReaderContentLoader.load(url: contentURL, countsAsHistoryVisit: true) {
            //                newContent = content
            //                guard let realmConfiguration = content.realm?.configuration, let contentType = content.objectSchema.objectClass as? RealmSwift.Object.Type else { return }
            //                let contentKey = content.compoundKey
            self.content = content
            //                    let htmlToDisplay = content.htmlToDisplay
            
            if var html = content.htmlToDisplay {
//                if isNextLoadInReaderMode && !html.contains("<html class=.readability-mode.>") {
                if content.isReaderModeByDefault && !html.contains("<html class=.readability-mode.>") {
                    if let _ = html.range(of: "<html", options: .caseInsensitive) {
                        html = html.replacingOccurrences(of: "<html", with: "<html data-is-next-load-in-reader-mode ", options: .caseInsensitive)
                    } else {
                        html = "<html data-is-next-load-in-reader-mode>\n\(html)\n</html>"
                    }
                    contentRules = contentRulesForReadabilityLoading
                }
                navigator.loadHTML(html, baseURL: contentURL)
            } else {
                // Shouldn't come here... results in duplicate history. Here for safety though.
                navigator.load(URLRequest(url: contentURL))
            }
        } else if let content = ReaderContentLoader.load(url: newState.pageURL, persist: !newState.pageURL.isNativeReaderView, countsAsHistoryVisit: true) {
            self.content = content
            if content.isReaderModeByDefault {
                contentRules = contentRulesForReadabilityLoading
            } else {
                contentRules = nil
            }
            
            let voiceAudioURLs = Array(content.voiceAudioURLs)
            Task { @MainActor in
                if !newState.pageURL.isNativeReaderView, newState.pageURL.host != nil, !newState.pageURL.isFileURL {
                    if voiceAudioURLs != audioURLs {
                        audioURLs = voiceAudioURLs
                    } else if !voiceAudioURLs.isEmpty {
                        isMediaPlayerPresented = true
                    }
                } else if newState.pageURL.isNativeReaderView {
                    Task { @MainActor [weak self] in
                        try Task.checkCancellation()
                        guard let self = self else { return }
                        if isMediaPlayerPresented {
                            isMediaPlayerPresented = false
                        }
                    }
                }
            }
        }
        
        /*else { // ReaderContentLoader.load(url: newState.pageURL, persist: !newState.pageURL.isNativeReaderView) {
            //                newContent = content
            //                guard let realmConfiguration = content.realm?.configuration, let contentType = content.objectSchema.objectClass as? RealmSwift.Object.Type else { return }
            //                let contentKey = content.compoundKey
            
            Task { @MainActor [weak self] in
                try Task.checkCancellation()
                guard let self = self else { return }
                //                    guard let content = getContent(configuration: realmConfiguration, type: contentType, key: contentKey) else { return }
                isNextLoadInReaderMode = isReaderModeByDefault
                //                    self.content = content
                
                print("## nav fin else: isNextReader \(isNextLoadInReaderMode)")
                if isNextLoadInReaderMode {
                    await scriptCaller.evaluateJavaScript("if (document.documentElement && !document.documentElement.classList.contains('readability-mode')) { document.documentElement.dataset.isNextLoadInReaderMode = ''; return false } else { return true }", in: nil, in: WKContentWorld.page) { result in
                        switch result {
                        case .success(let value):
                            if let isReaderMode = value as? Bool, !isReaderMode {
                                Task { @MainActor [weak self] in
                                    guard let self = self else { return }
                                    contentRules = contentRulesForReadabilityLoading
                                }
                            } else {
                                print("Error getting isReaderMode bool from \(value) or is already true")
                            }
                        case .failure(let error):
                            print(error.localizedDescription)
                        }
                    }
                }
            }
        }
// TODO: contentRules resetting
         */

    }
    
    public func onNavigationFinished(newState: WebViewState, completion: ((WebViewState) -> Void)? = nil) {
//        if contentRules != nil {
//            contentRules = nil
//        }
        
        /*
        print("## nav finished \(content.className) \(content.url) page url: \(newState.pageURL) is reader: \(content.isReaderModeByDefault)")
        let isReaderModeByDefault = content.isReaderModeByDefault
//        let existingTitle = content.title
//        let contentURL = content.url
        
         // FIXME: move isNextLoadInReaderMode setting to onCommitted, so that readabilityParsed can trigger showReaderView
        navigationTask?.cancel()
        navigationTask = Task.detached {
            try Task.checkCancellation()
//            var newContent: (any ReaderContentModel)? = nil
            
            if newState.pageURL.absoluteString.starts(with: "about:load/reader?reader-url="), let range = newState.pageURL.absoluteString.range(of: "?reader-url=", options: []), let rawURL = String(newState.pageURL.absoluteString[range.upperBound...]).removingPercentEncoding, let contentURL = URL(string: rawURL), let content = ReaderContentLoader.load(url: contentURL) {
//                newContent = content
                guard let realmConfiguration = content.realm?.configuration, let contentType = content.objectSchema.objectClass as? RealmSwift.Object.Type else { return }
                let contentKey = content.compoundKey
                let htmlToDisplay = content.htmlToDisplay
                
                Task { @MainActor [weak self] in
                    try Task.checkCancellation()
                    guard let self = self else { return }
                    guard let content = getContent(configuration: realmConfiguration, type: contentType, key: contentKey) else { return }
                    isNextLoadInReaderMode = content.isReaderModeByDefault
                    self.content = content
                    
                    if var html = htmlToDisplay {
                        if isNextLoadInReaderMode && !html.contains("<html class=.readability-mode.>") {
                            if let _ = html.range(of: "<html", options: .caseInsensitive) {
                                html = html.replacingOccurrences(of: "<html", with: "<html data-is-next-load-in-reader-mode ", options: .caseInsensitive)
                            } else {
                                html = "<html data-is-next-load-in-reader-mode>\n\(html)\n</html>"
                            }
                            contentRules = contentRulesForReadabilityLoading
                        }
                        try Task.checkCancellation()
                        navigator.loadHTML(html, baseURL: contentURL)
                    } else {
                        // Shouldn't come here... results in duplicate history. Here for safety though.
                        navigator.load(URLRequest(url: contentURL))
                    }
                }
            } else { // ReaderContentLoader.load(url: newState.pageURL, persist: !newState.pageURL.isNativeReaderView) {
//                newContent = content
//                guard let realmConfiguration = content.realm?.configuration, let contentType = content.objectSchema.objectClass as? RealmSwift.Object.Type else { return }
//                let contentKey = content.compoundKey
                
                Task { @MainActor [weak self] in
                    try Task.checkCancellation()
                    guard let self = self else { return }
//                    guard let content = getContent(configuration: realmConfiguration, type: contentType, key: contentKey) else { return }
                    isNextLoadInReaderMode = isReaderModeByDefault
//                    self.content = content
                    
        print("## nav fin else: isNextReader \(isNextLoadInReaderMode)")
                    if isNextLoadInReaderMode {
                        await scriptCaller.evaluateJavaScript("if (document.documentElement && !document.documentElement.classList.contains('readability-mode')) { document.documentElement.dataset.isNextLoadInReaderMode = ''; return false } else { return true }", in: nil, in: WKContentWorld.page) { result in
                            switch result {
                            case .success(let value):
                                if let isReaderMode = value as? Bool, !isReaderMode {
                                    Task { @MainActor [weak self] in
                                        guard let self = self else { return }
                                        contentRules = contentRulesForReadabilityLoading
                                    }
                                } else {
                                    print("Error getting isReaderMode bool from \(value) or is already true")
                                }
                            case .failure(let error):
                                print(error.localizedDescription)
                            }
                        }
                    }
                }
            }
         */
            
//            if let pageTitle = newState.pageTitle, !pageTitle.isEmpty, pageTitle != existingTitle, contentURL == newState.pageURL {
//                try Task.checkCancellation()
//                safeWrite(content) { (realm, content) in
//                    content.title = pageTitle
//                }
//            }

//            if let newContent = newContent, !newState.pageURL.isNativeReaderView, (newState.pageURL.host != nil && !newState.pageURL.isNativeReaderView) {
//                let urls = Array(newContent.voiceAudioURLs)
//                Task { @MainActor [weak self] in
//                    try Task.checkCancellation()
//                    guard let self = self else { return }
//                    if urls != audioURLs {
//                        audioURLs = urls
//                    } else if !urls.isEmpty {
//                        isMediaPlayerPresented = true
//                    }
//                }
//            } else if newState.pageURL.isNativeReaderView {
//                Task { @MainActor [weak self] in
//                    try Task.checkCancellation()
//                    guard let self = self else { return }
//                    if isMediaPlayerPresented {
//                        isMediaPlayerPresented = false
//                    }
//                }
//            }
        
        Task { @MainActor [weak self] in
            try Task.checkCancellation()
            self?.refreshSettingsInWebView(newState: newState)
            self?.refreshTitleInWebView(newState: newState)
            
            if let completion = completion {
                completion(newState)
            }
        }
    }
    
    private func getContent(configuration: Realm.Configuration, type: RealmSwift.Object.Type, key: String) -> (any ReaderContentModel)? {
        guard let content = try! Realm(configuration: configuration).object(ofType: type, forPrimaryKey: key) as? any ReaderContentModel else { return nil }
        return content
    }
    
    @MainActor
    func refreshTitleInWebView(newState: WebViewState? = nil) {
        let state = newState ?? state
        if content.url.absoluteString == state.pageURL.absoluteString, !state.isLoading {
            scriptCaller.evaluateJavaScript("(function() { let title = DOMPurify.sanitize(`\(content.titleForDisplay)`); if (document.title != title) { document.title = title } })()")
        }
    }
    
    @MainActor
    func refreshSettingsInWebView(newState: WebViewState) {
        scriptCaller.evaluateJavaScript("document.documentElement.setAttribute('data-manabi-light-theme', '\(lightModeTheme)')")
        scriptCaller.evaluateJavaScript("document.documentElement.setAttribute('data-manabi-dark-theme', '\(darkModeTheme)')")
        refreshTitleInWebView(newState: newState)
    }
}
