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
    public var scriptCaller = WebViewScriptCaller()

    public var defaultFontSize: Double?
    @AppStorage("readerFontSize") private var readerFontSize: Double?
    
    @Published public var isReaderMode = false {
        didSet {
            debugPrint("# isReaderMode", isReaderMode)
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
    internal func showReaderView(content: any ReaderContentProtocol) {
        guard let readabilityContent = readabilityContent else { return }
        Task { @MainActor in
            do {
                try await showReadabilityContent(content: content, readabilityContent: readabilityContent, renderToSelector: readabilityContainerSelector, in: readabilityContainerFrameInfo)
            } catch { }
        }
    }
    
    @MainActor
    private func showReadabilityContent(content: (any ReaderContentProtocol), readabilityContent: String, renderToSelector: String?, in frameInfo: WKFrameInfo?) async throws {
        await scriptCaller.evaluateJavaScript("""
            if (document.body) {
                document.body.dataset.isNextLoadInReaderMode = 'true';
            }
            """)
        
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
            content.modifiedAt = Date()
        }
        
        let injectEntryImageIntoHeader = content.injectEntryImageIntoHeader
        let readerFontSize = readerFontSize
        let defaultFontSize = defaultFontSize ?? 17
        let processReadabilityContent = processReadabilityContent
        let titleForDisplay = content.titleForDisplay
        let imageURLToDisplay = try await content.imageURLToDisplay()
        let url = content.url
        let lightModeTheme = lightModeTheme
        let darkModeTheme = darkModeTheme
        
        try await { @ReaderViewModelActor [weak self] in
            var doc: SwiftSoup.Document
            do {
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
            try await { @MainActor in
//                guard url == self.state.pageURL else { return }
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
                    navigator?.loadHTML(transformedContent, baseURL: url)
                }
            }()
        }()
    }
    
    @MainActor
    public func onNavigationCommitted(content: any ReaderContentProtocol, newState: WebViewState) async throws {
        readabilityContainerFrameInfo = nil
        readabilityContent = nil
        readabilityContainerSelector = nil
        contentRules = nil
        
        let isReaderModeVerified = newState.pageURL.isEBookURL || content.isReaderModeByDefault
        if isReaderMode != isReaderModeVerified {
            withAnimation {
                isReaderMode = isReaderModeVerified // Reset and confirm via JS later
            }
        }
        
        if newState.pageURL.absoluteString.hasPrefix("internal://local/load/reader?reader-url=") {
            if let readerFileManager = readerFileManager, var html = await content.htmlToDisplay(readerFileManager: readerFileManager) {
                if html.range(of: "<body.*?class=['\"].*?readability-mode.*?['\"]>", options: .regularExpression) == nil {
                    if let _ = html.range(of: "<body", options: .caseInsensitive) {
                        html = html.replacingOccurrences(of: "<body", with: "<body data-is-next-load-in-reader-mode='true' ", options: .caseInsensitive)
                    } else {
                        html = "<body data-is-next-load-in-reader-mode='true'>\n\(html)\n</html>"
                    }
                    contentRules = contentRulesForReadabilityLoading
                    Task { @MainActor in
                        navigator?.loadHTML(html, baseURL: content.url)
                    }
                } else {
                    readabilityContent = html
                    showReaderView(content: content)
                }
            } else {
                navigator?.load(URLRequest(url: content.url))
            }
        } else {
            if content.isReaderModeByDefault {
                contentRules = contentRulesForReadabilityLoading
                if content.isReaderModeAvailable {
                    showReaderView(content: content)
                }
            }
        }
    }
}

public func processForReaderMode(content: String, url: URL?, isEBook: Bool, defaultTitle: String?, imageURL: URL?, injectEntryImageIntoHeader: Bool, fontSize: Double, lightModeTheme: LightModeTheme, darkModeTheme: DarkModeTheme) throws -> SwiftSoup.Document {
    let isXML = content.hasPrefix("<?xml")
    let parser = isXML ? SwiftSoup.Parser.xmlParser() : SwiftSoup.Parser.htmlParser()
    let doc = try SwiftSoup.parse(content, url?.absoluteString ?? "", parser)
    doc.outputSettings().prettyPrint(pretty: false).syntax(syntax: isXML ? .xml : .html)
    
    // Migrate old cached versions
    // TODO: Update cache, if this is a performance issue.
    if try doc.getElementById("reader-content") == nil, let oldElement = try doc.getElementsByClass("reader-content").first() {
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
