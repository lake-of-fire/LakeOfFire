import SwiftUI
import SwiftUIWebView
import SwiftSoup
import RealmSwift
import Combine
import RealmSwiftGaps
import WebKit

@MainActor
public class ReaderViewModel: NSObject, ObservableObject {
    public var processReadabilityContent: ((SwiftSoup.Document) async -> String)? = nil
    public var readerFileManager: ReaderFileManager?
    public let navigator = WebViewNavigator()
    @Published public var state: WebViewState = .empty 
    {
//    public var action: WebViewAction = .idle
//    public var state: WebViewState = .empty {
        didSet {
            if let imageURL = state.pageImageURL, content.imageUrl == nil {
                // TODO: Replace with fromMainActor instead of the if / else if
                if let content = content as? Bookmark {
                    let contentRef = ThreadSafeReference(to: content)
                    guard let config = content.realm?.configuration else { return }
                    Task.detached { @RealmBackgroundActor in
                        try await Realm.asyncWrite(contentRef, configuration: config) { _, content in
                            content.imageUrl = imageURL
                        }
                    }
                } else if let content = content as? HistoryRecord {
                    let contentRef = ThreadSafeReference(to: content)
                    guard let config = content.realm?.configuration else { return }
                    Task.detached { @RealmBackgroundActor in
                        try await Realm.asyncWrite(contentRef, configuration: config) { _, content in
                            content.imageUrl = imageURL
                        }
                    }
                }
            }
        }
    }
    
    @Published public var content: (any ReaderContentModel) = ReaderContentLoader.unsavedHome
 
    @Published var readabilityContent: String? = nil
    @Published var readabilityContainerSelector: String? = nil
    @Published var readabilityContainerFrameInfo: WKFrameInfo? = nil
    
    @Published var readabilityFrames = Set<WKFrameInfo>()
    
    public var scriptCaller = WebViewScriptCaller()
    @Published var webViewUserScripts: [WebViewUserScript]? = nil
    @Published var webViewSystemScripts: [WebViewUserScript]? = nil
    
    @Published var contentRules: String? = nil
    @Published public var isMediaPlayerPresented = false
    @Published public var audioURLs = [URL]()
    
    public var defaultFontSize: Double?
    @AppStorage("readerFontSize") private var readerFontSize: Double?
    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    
    private var navigationTask: Task<Void, Error>?
    private var cancellables = Set<AnyCancellable>()
    
    public var allScripts: [WebViewUserScript] {
        return (webViewSystemScripts ?? []) + (webViewUserScripts ?? [])
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
    
    public init(realmConfiguration: Realm.Configuration = Realm.Configuration.defaultConfiguration, systemScripts: [WebViewUserScript], processReadabilityContent: ((SwiftSoup.Document) async -> String)? = nil) {
        super.init()
        
        self.processReadabilityContent = processReadabilityContent
        
        Task.detached { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            let configuration = try await LibraryConfiguration.getOrCreate()
            let ref = ThreadSafeReference(to: configuration)
            try await Task { @MainActor [weak self] in
                let realm = try Realm(configuration: LibraryDataManager.realmConfiguration)
                guard let self = self, let configuration = realm.resolve(ref) else { return }
                webViewSystemScripts = systemScripts + configuration.systemScripts
                webViewUserScripts = configuration.activeWebViewUserScripts
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
                    .store(in: &cancellables)
            }
        }
    }
    
    @MainActor
    func showReaderView(content: (any ReaderContentModel)? = nil) {
        let content = content ?? self.content
        guard let readabilityContent = readabilityContent else {
            return
        }
        let title = content.title
        let imageURL = content.imageURLToDisplay
        let url = content.url
        let readabilityContainerSelector = readabilityContainerSelector
        let readabilityContainerFrameInfo = readabilityContainerFrameInfo
        let contentType = content.objectSchema.objectClass as? RealmSwift.Object.Type
        let contentKey = content.compoundKey
        guard let contentConfig = content.realm?.configuration else { return }
        Task.detached { @MainActor [weak self] in
            guard let self = self else { return }
            let realm = try await Realm(configuration: contentConfig, actor: MainActor.shared)
            guard let contentType = contentType, let content = realm.object(ofType: contentType, forPrimaryKey: contentKey) as? any ReaderContentModel else { return }
            do {
                try await showReadabilityContent(content: content, readabilityContent: readabilityContent, url: url, defaultTitle: title, imageURL: imageURL, renderToSelector: readabilityContainerSelector, in: readabilityContainerFrameInfo)
            } catch { }
        }
    }
    
    /// Content before it has been treated with Reader-specific processing.
    private func showReadabilityContent(content: (any ReaderContentModel), readabilityContent: String, url: URL?, defaultTitle: String?, imageURL: URL?, renderToSelector: String?, in frameInfo: WKFrameInfo?) async throws {
        try await content.asyncWrite { _, content in
            content.isReaderModeByDefault = true
        }
        
        let injectEntryImageIntoHeader = self.content.injectEntryImageIntoHeader
        let readerFontSize = readerFontSize
        let defaultFontSize = defaultFontSize ?? 15
        let processReadabilityContent = processReadabilityContent
        try await Task.detached { [weak self] in
            var doc: SwiftSoup.Document
            do {
                doc = try processForReaderMode(content: readabilityContent, url: url, isEBook: false, defaultTitle: defaultTitle, imageURL: imageURL, injectEntryImageIntoHeader: injectEntryImageIntoHeader, fontSize: readerFontSize ?? defaultFontSize)
            } catch {
                print(error.localizedDescription)
                return
            }
            
            var html: String
            if let processReadabilityContent = processReadabilityContent {
                html = await processReadabilityContent(doc)
            } else {
                html = try doc.outerHtml()
            }
#warning("SwiftUIDrag menu (?)")
            let transformedContent = html
            await Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let frameInfo = frameInfo, !frameInfo.isMainFrame {
                    await scriptCaller.evaluateJavaScript(
                                """
                                var root = document.body
                                if (renderToSelector) {
                                    root = document.querySelector(renderToSelector)
                                }
                                var serialized = html
                                
                                let xmlns = document.documentElement.getAttribute('xmlns')
                                if (xmlns) {
                                    let parser = new DOMParser()
                                    let doc = parser.parseFromString(serialized, 'text/html')
                                    let readabilityNode = doc.body
                                    let replacementNode = root.cloneNode()
                                    replacementNode.innerHTML = ''
                                    for (let innerNode of readabilityNode.childNodes) {
                                        serialized = new XMLSerializer().serializeToString(innerNode)
                                        replacementNode.innerHTML += serialized
                                    }
                                    root.innerHTML = replacementNode.innerHTML
                                } else if (root) {
                                    root.outerHTML = serialized
                                }
                                
                                let style = document.createElement('style')
                                style.textContent = css
                                document.head.appendChild(style)
                                document.body.classList.add('readability-mode')
                                """,
                                arguments: [
                                    "renderToSelector": renderToSelector ?? "",
                                    "html": transformedContent,
                                    "css": Readability.shared.css,
                                ], in: frameInfo)
                } else {
                    navigator.loadHTML(transformedContent, baseURL: url)
                }
            }.value
        }.value
    }
    @RealmBackgroundActor
    private func updateScripts() async throws {
        let libraryConfiguration = try await LibraryConfiguration.getOrCreate()
        let ref = ThreadSafeReference(to: libraryConfiguration)
        Task { @MainActor [weak self] in
            let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration)
            guard let scripts = realm.resolve(ref)?.activeWebViewUserScripts else { return }
            guard let self = self else { return }
            if webViewUserScripts != scripts {
                webViewUserScripts = scripts
            }
        }
    }
    
    public func onNavigationCommitted(newState: WebViewState, completion: ((WebViewState) -> Void)? = nil) {
        readabilityContent = nil
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard let content = try await getContent(forURL: newState.pageURL) else {
                print("WARNING No content matched for \(newState.pageURL)")
                return
            }
            self.content = content
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
            
            if newState.pageURL.absoluteString.hasPrefix("internal://local/load/reader?reader-url=") {
                //                newContent = content
                //                guard let realmConfiguration = content.realm?.configuration, let contentType = content.objectSchema.objectClass as? RealmSwift.Object.Type else { return }
                //                let contentKey = content.compoundKey
                //                    let htmlToDisplay = content.htmlToDisplay
                
                if let readerFileManager = readerFileManager, var html = await content.htmlToDisplay(readerFileManager: readerFileManager) {
                    //                if isNextLoadInReaderMode && !html.contains("<html class=.readability-mode.>") {
                    if content.isReaderModeByDefault && !html.contains("<body.* class=.readability-mode.>") {
                        if let _ = html.range(of: "<html", options: .caseInsensitive) {
                            html = html.replacingOccurrences(of: "<html", with: "<html data-is-next-load-in-reader-mode ", options: .caseInsensitive)
                        } else {
                            html = "<html data-is-next-load-in-reader-mode>\n\(html)\n</html>"
                        }
                        contentRules = contentRulesForReadabilityLoading
                    }
                    navigator.loadHTML(html, baseURL: content.url)
                } else {
                    // Shouldn't come here... results in duplicate history. Here for safety though.
                    navigator.load(URLRequest(url: content.url))
                }
            } else {
                if content.isReaderModeByDefault {
                    // TODO gotta wait later in readabilityParsed task callbacks to get isReaderModeAvailable=true...
                    contentRules = contentRulesForReadabilityLoading
                    if content.isReaderModeAvailable {
                        showReaderView(content: content)
                    }
                } else {
                    contentRules = nil
                }
                
                let voiceAudioURLs = Array(content.voiceAudioURLs)
                if !newState.pageURL.isNativeReaderView, newState.pageURL.host != nil, !newState.pageURL.isFileURL {
                    if voiceAudioURLs != audioURLs {
                        audioURLs = voiceAudioURLs
                    }
                    if !voiceAudioURLs.isEmpty {
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
            guard let self = self else { return }
            try Task.checkCancellation()
            refreshSettingsInWebView(content: content, newState: newState)
            refreshTitleInWebView(content: content, newState: newState)
            
            if let completion = completion {
                completion(newState)
            }
        }
    }
    
    @MainActor
    public func getContent(forURL pageURL: URL) async throws -> (any ReaderContentModel)? {
        if pageURL.absoluteString.hasPrefix("internal://local/load/reader?reader-url="), let range = pageURL.absoluteString.range(of: "?reader-url=", options: []), let rawURL = String(pageURL.absoluteString[range.upperBound...]).removingPercentEncoding, let contentURL = URL(string: rawURL), let content = try await ReaderContentLoader.load(url: contentURL, countsAsHistoryVisit: true) {
            return content
        } else if let content = try await ReaderContentLoader.load(url: pageURL, persist: !pageURL.isNativeReaderView, countsAsHistoryVisit: true) {
            return content
        }
        return nil
    }
    
    private func getContent(configuration: Realm.Configuration, type: RealmSwift.Object.Type, key: String) -> (any ReaderContentModel)? {
        guard let content = try! Realm(configuration: configuration).object(ofType: type, forPrimaryKey: key) as? any ReaderContentModel else { return nil }
        return content
    }
    
    @MainActor
    func refreshTitleInWebView(content: (any ReaderContentModel), newState: WebViewState? = nil) {
        // TODO: consolidate code duplication
        let state = newState ?? state
        if content.url.absoluteString == state.pageURL.absoluteString, !state.isLoading && !state.isProvisionallyNavigating {
            scriptCaller.evaluateJavaScript("(function() { let title = DOMPurify.sanitize(`\(content.titleForDisplay)`); if (document.title != title) { document.title = title } })()")
        }
    }
    
    @MainActor
    func refreshSettingsInWebView(content: (any ReaderContentModel), newState: WebViewState? = nil) {
        // TODO: consolidate code duplication
        Task { @MainActor in
            await scriptCaller.evaluateJavaScript("document.documentElement.setAttribute('data-manabi-light-theme', '\(lightModeTheme)')", duplicateInMultiTargetFrames: true)
            await scriptCaller.evaluateJavaScript("document.documentElement.setAttribute('data-manabi-dark-theme', '\(darkModeTheme)')", duplicateInMultiTargetFrames: true)
            refreshTitleInWebView(content: content, newState: newState)
        }
    }
}

func processForReaderMode(content: String, url: URL?, isEBook: Bool, defaultTitle: String?, imageURL: URL?, injectEntryImageIntoHeader: Bool, fontSize: Double) throws -> SwiftSoup.Document {
    let isXML = content.hasPrefix("<?xml")
    let parser = isXML ? SwiftSoup.Parser.xmlParser() : SwiftSoup.Parser.htmlParser()
    let doc = try SwiftSoup.parse(content, url?.absoluteString ?? "", parser)
    doc.outputSettings().prettyPrint(pretty: false).syntax(syntax: isXML ? .xml : .html)
    
    if isEBook {
        try doc.attr("data-is-ebook", true)
    }
    
    if let htmlTag = try? doc.select("html") {
        var htmlStyle = "font-size: \(fontSize)px"
        if let existingHtmlStyle = try? htmlTag.attr("style"), !existingHtmlStyle.isEmpty {
            htmlStyle = "\(htmlStyle); \(existingHtmlStyle)"
        }
        _ = try? htmlTag.attr("style", htmlStyle)
    }
    
    if let defaultTitle = defaultTitle, let existing = try? doc.select("#reader-title"), !existing.hasText() {
        let escapedTitle = Entities.escape(defaultTitle, OutputSettings().charset(String.Encoding.utf8).escapeMode(Entities.EscapeMode.extended))
        do {
            try doc.body()?.select("#reader-title").html(escapedTitle)
        } catch { }
    }
    do {
        try fixAnnoyingTitlesWithPipes(doc: doc)
    } catch { }
    
    if injectEntryImageIntoHeader, let imageURL = imageURL, let existing = try? doc.select("img[src='\(imageURL.absoluteString)'"), existing.isEmpty() {
        do {
            try doc.body()?.select("#reader-header").prepend("<img src='\(imageURL.absoluteString)'>")
        } catch { }
    }
    if let url = url {
        transformContentSpecificToFeed(doc: doc, url: url)
        do {
            try wireViewOriginalLinks(doc: doc, url: url)
        } catch { }
    }
    return doc
}
