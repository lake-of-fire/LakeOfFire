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
    public var navigator: WebViewNavigator?
    @Published public var state: WebViewState = .empty
    @Published public var locationBarShouldGainFocusOnAppearance = false
    @Published public var isReaderMode = false
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
    
    public func isReaderModeButtonBarVisible(content: any ReaderContentProtocol) -> Bool {
        return !content.isReaderModeOfferHidden && content.isReaderModeAvailable && !content.isReaderModeByDefault
    }
    public func isReaderModeVisibleInMenu(content: any ReaderContentProtocol) -> Bool {
        return content.isReaderModeOfferHidden && content.isReaderModeAvailable
    }
    
    public func locationShortName(content: any ReaderContentProtocol) -> String? {
        if content.url.absoluteString == "about:blank" {
            return "Home"
        } else if content.url.isNativeReaderView {
            return nil
        } else if content.url.isEBookURL || content.url.isSnippetURL {
            return content.titleForDisplay
        } else {
            return content.url.host
        }
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
         }
        """
    } .joined(separator: ", "))
    ]
    """
    
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
    
    func isReaderModeLoadPending(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && content.isReaderModeAvailable && content.isReaderModeByDefault
    }
    
    @MainActor
    func hideReaderModeButtonBar(content: (any ReaderContentProtocol)) async throws {
        try await content.asyncWrite { _, content in
            content.isReaderModeOfferHidden = true
        }
        objectWillChange.send()
    }
    
    @MainActor
    internal func showReaderView(content: any ReaderContentProtocol) {
        guard let readabilityContent = readabilityContent else { return }
        let title = content.title
        let imageURL = content.imageURLToDisplay
        let readabilityContainerSelector = readabilityContainerSelector
        let readabilityContainerFrameInfo = readabilityContainerFrameInfo
        let contentType = content.objectSchema.objectClass as? RealmSwift.Object.Type
        let contentKey = content.compoundKey
        guard let contentConfig = content.realm?.configuration else { return }
        Task.detached { @MainActor [weak self] in
            guard let self = self else { return }
            let realm = try await Realm(configuration: contentConfig, actor: MainActor.shared)
            guard let contentType = contentType, let content = realm.object(ofType: contentType, forPrimaryKey: contentKey) as? any ReaderContentProtocol else { return }
            do {
                try await self.showReadabilityContent(content: content, readabilityContent: readabilityContent, defaultTitle: title, imageURL: imageURL, renderToSelector: readabilityContainerSelector, in: readabilityContainerFrameInfo)
            } catch { }
        }
    }
    
    @MainActor
    private func showReadabilityContent(content: (any ReaderContentProtocol), readabilityContent: String, defaultTitle: String?, imageURL: URL?, renderToSelector: String?, in frameInfo: WKFrameInfo?) async throws {
        guard content.url == state.pageURL else { return }
        try await content.asyncWrite { _, content in
            content.isReaderModeByDefault = true
            content.isReaderModeAvailable = false
            content.isReaderModeOfferHidden = false
            if !content.url.isEBookURL && !content.url.isFileURL && !content.url.isNativeReaderView {
                if !content.url.isReaderFileURL && (content.content?.isEmpty ?? true) {
                    content.html = readabilityContent
                }
                if content.title.isEmpty {
                    content.title = content.html?.strippingHTML().trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first?.truncate(36) ?? ""
                }
                content.rssContainsFullContent = true
            }
        }
        
        let injectEntryImageIntoHeader = content.injectEntryImageIntoHeader
        let readerFontSize = readerFontSize
        let defaultFontSize = defaultFontSize ?? 15
        let processReadabilityContent = processReadabilityContent
        let url = content.url
        
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
            
            let transformedContent = html
            await Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard url == self.state.pageURL else { return }
                if let frameInfo = frameInfo, !frameInfo.isMainFrame {
                    await self.scriptCaller.evaluateJavaScript(
                        """
                        var root = document.body
                        if (renderToSelector) {
                            root = document.querySelector(renderToSelector)
                        }
                        var serialized = html
                        
                        let xmlns = document.body?.getAttribute('xmlns')
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
                        document.body?.classList.add('readability-mode')
                        """,
                        arguments: [
                            "renderToSelector": renderToSelector ?? "",
                            "html": transformedContent,
                            "css": Readability.shared.css,
                        ], in: frameInfo)
                } else {
                    self.navigator?.loadHTML(transformedContent, baseURL: url)
                }
                self.isReaderMode = true
            }.value
        }.value
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
        readabilityContent = nil
        guard let content = try await ReaderViewModel.getContent(forURL: newState.pageURL) else {
            print("WARNING No content matched for \(newState.pageURL)")
            return
        }
        
        if let historyRecord = content as? HistoryRecord {
            Task.detached { @RealmBackgroundActor in
                guard let content = try await ReaderContentLoader.fromMainActor(content: historyRecord) as? HistoryRecord, let realm = content.realm else { return }
                try await realm.asyncWrite {
                    content.lastVisitedAt = Date()
                }
            }
        }
        
        if newState.pageURL.absoluteString.hasPrefix("internal://local/load/reader?reader-url=") {
            if let readerFileManager = readerFileManager, var html = await content.htmlToDisplay(readerFileManager: readerFileManager) {
                if content.isReaderModeByDefault && html.range(of: "<body.*?class=['\"]readability-mode['\"]>", options: .regularExpression) == nil {
                    if let _ = html.range(of: "<body", options: .caseInsensitive) {
                        html = html.replacingOccurrences(of: "<body", with: "<body data-is-next-load-in-reader-mode='true' ", options: .caseInsensitive)
                    } else {
                        html = "<body data-is-next-load-in-reader-mode='true'>\n\(html)\n</html>"
                    }
                    contentRules = contentRulesForReadabilityLoading
                }
                navigator?.loadHTML(html, baseURL: content.url)
            } else {
                navigator?.load(URLRequest(url: content.url))
            }
        } else {
            if content.isReaderModeByDefault {
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
                    if self.isMediaPlayerPresented {
                        self.isMediaPlayerPresented = false
                    }
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
            await self.scriptCaller.evaluateJavaScript("document.body.setAttribute('data-manabi-light-theme', '\(self.lightModeTheme)')", duplicateInMultiTargetFrames: true)
            await self.scriptCaller.evaluateJavaScript("document.body.setAttribute('data-manabi-dark-theme', '\(self.darkModeTheme)')", duplicateInMultiTargetFrames: true)
            self.refreshTitleInWebView(content: content, newState: newState)
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
    
    if let bodyTag = doc.body() {
        var bodyStyle = "font-size: \(fontSize)px"
        if let existingBodyStyle = try? bodyTag.attr("style"), !existingBodyStyle.isEmpty {
            bodyStyle = "\(bodyStyle); \(existingBodyStyle)"
        }
        _ = try? bodyTag.attr("style", bodyStyle)
    }
    
    if let defaultTitle = defaultTitle, let existing = try? doc.getElementById("reader-title"), !existing.hasText() {
        let escapedTitle = Entities.escape(defaultTitle, OutputSettings().charset(String.Encoding.utf8).escapeMode(Entities.EscapeMode.extended))
        do {
            try existing.html(escapedTitle)
        } catch { }
    }
    do {
        try fixAnnoyingTitlesWithPipes(doc: doc)
    } catch { }
    
    if try injectEntryImageIntoHeader || (doc.body()?.getElementsByTag("img").isEmpty() ?? true), let imageURL = imageURL, let existing = try? doc.select("img[src='\(imageURL.absoluteString)'"), existing.isEmpty() {
        do {
            try doc.getElementById("reader-header")?.prepend("<img src='\(imageURL.absoluteString)'>")
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
