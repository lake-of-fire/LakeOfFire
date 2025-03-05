import SwiftUI
import SwiftUIWebView
import SwiftSoup
import RealmSwift
import Combine
import RealmSwiftGaps
import WebKit

@globalActor
fileprivate actor ReaderViewModelActor {
    static var shared = ReaderViewModelActor()
}

@MainActor
public class ReaderModeViewModel: ObservableObject {
    public var readerFileManager: ReaderFileManager?
    public var processReadabilityContent: ((SwiftSoup.Document) async -> String)? = nil
    public var navigator: WebViewNavigator?
    
    public var defaultFontSize: Double?
    @AppStorage("readerFontSize") private var readerFontSize: Double?
    
    @Published public var isReaderMode = false
    @Published public var isReaderModeLoading = false {
        didSet {
            debugPrint("# isReadeerMode LOADING", isReaderModeLoading)
        }
    }
    @Published var readabilityContent: String? = nil
    @Published var readabilityContainerSelector: String? = nil
    @Published var readabilityContainerFrameInfo: WKFrameInfo? = nil
    @Published var readabilityFrames = Set<WKFrameInfo>()
    
    @Published var contentRules: String? = nil

    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    
    private var contentRulesForReadabilityLoading = """
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
    
    public func isReaderModeButtonBarVisible(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && !content.isReaderModeOfferHidden && content.isReaderModeAvailable && !content.isReaderModeByDefault
    }
    public func isReaderModeVisibleInMenu(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && content.isReaderModeOfferHidden && content.isReaderModeAvailable && !content.isReaderModeByDefault
    }
    
    public init() { }
    
    func isReaderModeLoadPending(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && content.isReaderModeAvailable && content.isReaderModeByDefault
    }
    
    @MainActor
    func hideReaderModeButtonBar(content: (any ReaderContentProtocol)) async throws {
        if !content.isReaderModeOfferHidden {
            try await content.asyncWrite { _, content in
                content.isReaderModeOfferHidden = true
                content.modifiedAt = Date()
            }
            objectWillChange.send()
        }
    }
    
    @MainActor
    internal func showReaderView(readerContent: ReaderContent, scriptCaller: WebViewScriptCaller) {
        guard let readabilityContent else { return }
        let contentURL = readerContent.pageURL
        isReaderModeLoading = true
        Task { @MainActor in
            guard contentURL == readerContent.pageURL else {
                isReaderModeLoading = false
                return
            }
            do {
                try await showReadabilityContent(
                    readerContent: readerContent,
                    readabilityContent: readabilityContent,
                    renderToSelector: readabilityContainerSelector,
                    in: readabilityContainerFrameInfo,
                    scriptCaller: scriptCaller
                )
            } catch {
                print(error)
                isReaderModeLoading = false
            }
        }
    }
    
    /// `readerContent` is used to verify current reader state before loading processed `content`
    @MainActor
    private func showReadabilityContent(readerContent: ReaderContent, readabilityContent: String, renderToSelector: String?, in frameInfo: WKFrameInfo?, scriptCaller: WebViewScriptCaller) async throws {
        debugPrint("# showReadabilityContent content", readerContent.content?.url, "pageurl", readerContent.pageURL)
        guard let content = try await readerContent.getContent() else {
            print("No content set to show in reader mode")
            isReaderModeLoading = false
            return
        }
        let url = content.url
        
        await scriptCaller.evaluateJavaScript("""
            if (document.body) {
                document.body.dataset.isNextLoadInReaderMode = 'true';
            }
            """)
        
        try await content.asyncWrite { _, content in
            content.isReaderModeByDefault = true
            content.isReaderModeAvailable = false
            content.isReaderModeOfferHidden = false
            if !url.isEBookURL && !url.isFileURL && !url.isNativeReaderView {
                if !url.isReaderFileURL && (content.content?.isEmpty ?? true) {
                    content.html = readabilityContent
                }
                if content.title.isEmpty {
                    content.title = content.html?.strippingHTML().trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first?.truncate(36) ?? ""
                }
                content.rssContainsFullContent = true
            }
            content.modifiedAt = Date()
        }
        
        if !isReaderMode {
            isReaderMode = true
        }
        
        let injectEntryImageIntoHeader = content.injectEntryImageIntoHeader
        let readerFontSize = readerFontSize
        let defaultFontSize = defaultFontSize ?? 17
        let processReadabilityContent = processReadabilityContent
        let titleForDisplay = content.titleForDisplay
        let imageURLToDisplay = try await content.imageURLToDisplay()
        let lightModeTheme = lightModeTheme
        let darkModeTheme = darkModeTheme
        
        try await { @ReaderViewModelActor [weak self] in
            var doc: SwiftSoup.Document
            doc = try processForReaderMode(
                content: readabilityContent,
                url: url,
                isEBook: false,
                defaultTitle: titleForDisplay,
                imageURL: imageURLToDisplay,
                injectEntryImageIntoHeader: injectEntryImageIntoHeader,
                fontSize: readerFontSize ?? defaultFontSize,
                lightModeTheme: lightModeTheme,
                darkModeTheme: darkModeTheme
            )
            
            var html: String
            if let processReadabilityContent = processReadabilityContent {
                html = await processReadabilityContent(doc)
            } else {
                html = try doc.outerHtml()
            }
            let transformedContent = html
            try await { @MainActor in
                guard url.matchesReaderURL(readerContent.pageURL) else {
                    print("Readability content URL mismatch", url, readerContent.pageURL)
                    isReaderModeLoading = false
                    return
                }
                if let frameInfo = frameInfo, !frameInfo.isMainFrame {
                    await scriptCaller.evaluateJavaScript(
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
                    debugPrint("# load html from showReada", url, readerContent.content?.url)
//                    navigator?.loadHTML(transformedContent, baseURL: url)
                    await scriptCaller.evaluateJavaScript(
                        """
                        document.open();
                        document.write(html);
                        document.close();
                        """,
                        arguments: [
                            "html": transformedContent,
                        ])
                }
                isReaderModeLoading = false
            }()
        }()
    }
    
    @MainActor
    public func onNavigationCommitted(readerContent: ReaderContent, newState: WebViewState, scriptCaller: WebViewScriptCaller) async throws {
        readabilityContainerFrameInfo = nil
        readabilityContent = nil
        readabilityContainerSelector = nil
        contentRules = nil
        
        guard let content = readerContent.content else {
            print("No content to display in ReaderModeViewModel onNavigationCommitted")
            isReaderModeLoading = false
            return
        }
        let committedURL = content.url
        guard committedURL.matchesReaderURL(newState.pageURL) else {
            print("URL mismatch in ReaderModeViewModel onNavigationCommitted", committedURL, newState.pageURL)
            isReaderModeLoading = false
            return
        }
        
        // FIXME: Mokuro? check plugins thing for reader mode url instead of hardcoding methods here
        let isReaderModeVerified = newState.pageURL.isEBookURL || content.isReaderModeByDefault
        if isReaderMode != isReaderModeVerified {
            withAnimation {
                isReaderModeLoading = isReaderModeVerified
                isReaderMode = isReaderModeVerified // Reset and confirm via JS later
            }
        }
        
        if newState.pageURL.isReaderURLLoaderURL {
            if let readerFileManager = readerFileManager, var html = await content.htmlToDisplay(readerFileManager: readerFileManager) {
                let currentURL = readerContent.pageURL
                guard committedURL.matchesReaderURL(currentURL) else {
                    print("URL mismatch in ReaderModeViewModel onNavigationCommitted", currentURL, committedURL)
                    isReaderModeLoading = false
                    return
                }
                if html.range(of: "<body.*?class=['\"].*?readability-mode.*?['\"]>", options: .regularExpression) == nil, html.range(of: "<body.*?data-is-next-load-in-reader-mode=['\"]true['\"]>", options: .regularExpression) == nil {
                    if let _ = html.range(of: "<body", options: .caseInsensitive) {
                        html = html.replacingOccurrences(of: "<body", with: "<body data-is-next-load-in-reader-mode='true' ", options: .caseInsensitive)
                    } else {
                        html = "<body data-is-next-load-in-reader-mode='true'>\n\(html)\n</html>"
                    }
                    // TODO: Fix content rules... images still load...
                    contentRules = contentRulesForReadabilityLoading
//                    Task { @MainActor in
//                        debugPrint("# load html from onNavCommit")
                    navigator?.loadHTML(html, baseURL: committedURL)
//                    }
                } else {
                    readabilityContent = html
                    debugPrint("#  onNavCommit gonna show reader view for loader url")
                    showReaderView(
                        readerContent: readerContent,
                        scriptCaller: scriptCaller
                    )
                }
            } else {
                navigator?.load(URLRequest(url: committedURL))
            }
        } else {
            if content.isReaderModeByDefault {
                if content.isReaderModeAvailable {
                    contentRules = contentRulesForReadabilityLoading
                    showReaderView(
                        readerContent: readerContent,
                        scriptCaller: scriptCaller
                    )
                } else {
                    isReaderModeLoading = false
                }
            }
        }
    }
    
    @MainActor
    public func onNavigationFinished() {
//        isReaderModeLoading = false
    }
}

public func processForReaderMode(content: String, url: URL?, isEBook: Bool, defaultTitle: String?, imageURL: URL?, injectEntryImageIntoHeader: Bool, fontSize: Double, lightModeTheme: LightModeTheme, darkModeTheme: DarkModeTheme) throws -> SwiftSoup.Document {
    let isXML = content.hasPrefix("<?xml")
    let parser = isXML ? SwiftSoup.Parser.xmlParser() : SwiftSoup.Parser.htmlParser()
    let doc = try SwiftSoup.parse(content, url?.absoluteString ?? "", parser)
    doc.outputSettings().prettyPrint(pretty: false).syntax(syntax: isXML ? .xml : .html)
    
    // Migrate old cached versions
    // TODO: Update cache, if this is a performance issue.
    if let oldElement = try doc.getElementsByClass("reader-content").first(), try doc.getElementById("reader-content") == nil {
        try oldElement.attr("id", "reader-content")
        try oldElement.removeAttr("class")
    }
    
    if isEBook {
        try doc.body()?.attr("data-is-ebook", "true")
    }
    
    if let bodyTag = doc.body() {
        var bodyStyle = "font-size: \(fontSize)px"
        if let existingBodyStyle = try? bodyTag.attr("style"), !existingBodyStyle.isEmpty {
            bodyStyle = "\(bodyStyle); \(existingBodyStyle)"
        }
        _ = try? bodyTag.attr("style", bodyStyle)
        _ = try? bodyTag.attr("data-manabi-light-theme", lightModeTheme.rawValue)
        _ = try? bodyTag.attr("data-manabi-dark-theme", darkModeTheme.rawValue)
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
    
    if try injectEntryImageIntoHeader || (doc.body()?.getElementsByTag(UTF8Arrays.img).isEmpty() ?? true), let imageURL = imageURL, let existing = try? doc.select("img[src='\(imageURL.absoluteString)'"), existing.isEmpty() {
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
