import SwiftUI
import SwiftUIWebView
import SwiftSoup
import SwiftReadability
import RealmSwift
import Combine
import RealmSwiftGaps
import LakeKit
import WebKit

@globalActor
fileprivate actor ReaderViewModelActor {
    static let shared = ReaderViewModelActor()
}

private let readabilityViewportMetaContent = "width=device-width, user-scalable=no, minimum-scale=1.0, maximum-scale=1.0, initial-scale=1.0"
private let readabilityBylinePrefixRegex = try! NSRegularExpression(pattern: "^(by|par)\\s+", options: [.caseInsensitive])
private let readabilityClassesToPreserve: [String] = [
    "caption",
    "emoji",
    "hidden",
    "invisible",
    "sr-only",
    "visually-hidden",
    "visuallyhidden",
    "wp-caption",
    "wp-caption-text",
    "wp-smiley",
]

private enum SwiftReadabilityProcessingOutcome {
    case success(SwiftReadabilityProcessingResult)
    case unavailable
    case failed
}

private struct SwiftReadabilityProcessingResult {
    let outputHTML: String
}

private func escapeReadabilityText(_ raw: String) -> String {
    raw
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private func escapeReadabilityHTMLAttribute(_ raw: String) -> String {
    escapeReadabilityText(raw)
}

private func normalizeReadabilityBylineText(_ rawByline: String) -> String {
    let trimmed = rawByline.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let nsByline = trimmed as NSString
    let range = NSRange(location: 0, length: nsByline.length)
    let stripped = readabilityBylinePrefixRegex.stringByReplacingMatches(
        in: trimmed,
        options: [],
        range: range,
        withTemplate: ""
    )
    let cleaned = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? trimmed : cleaned
}

private func isInternalReaderURL(_ url: URL) -> Bool {
    url.scheme == "internal" && url.host == "local"
}

internal func buildCanonicalReadabilityHTML(
    title: String,
    byline: String,
    publishedTime: String?,
    content: String,
    contentURL: URL
) -> String {
    let resolvedTitle = escapeReadabilityText(title)
    let resolvedByline = escapeReadabilityText(normalizeReadabilityBylineText(byline))
    let viewOriginal = isInternalReaderURL(contentURL) ? "" : "<a class=\"reader-view-original\">View Original</a>"
    let bylineLine = resolvedByline.isEmpty
        ? ""
        : "<div id=\"reader-byline-line\" class=\"byline-line\"><span class=\"byline-label\">By</span> <span id=\"reader-byline\" class=\"byline\">\(resolvedByline)</span></div>"
    let publicationDateText = publishedTime.map(escapeReadabilityText) ?? ""
    let metaLine = """
    <div id="reader-meta-line" class="byline-meta-line"><span id="reader-publication-date">\(publicationDateText)</span>\(viewOriginal.isEmpty ? "" : "<span class=\"reader-meta-divider\"></span>\(viewOriginal)")</div>
    """
    let availabilityAttributes = "data-manabi-reader-mode-available=\"true\" data-manabi-reader-mode-available-for=\"\(escapeReadabilityHTMLAttribute(contentURL.absoluteString))\""
    return """
    <!DOCTYPE html>
    <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="\(readabilityViewportMetaContent)">
            <style type="text/css" id="swiftuiwebview-readability-styles">\(Readability.shared.css)</style>
            <title>\(resolvedTitle)</title>
        </head>
        <body class="readability-mode" \(availabilityAttributes)>
            <div id="reader-header" class="header">
                <h1 id="reader-title">\(resolvedTitle)</h1>
                <div id="reader-byline-container">
                    \(bylineLine)
                    \(metaLine)
                </div>
            </div>
            <div id="reader-content">
                \(content)
            </div>
            <script>
                \(Readability.shared.scripts)
            </script>
        </body>
    </html>
    """
}

internal func bodyInnerHTML(from html: String) -> String? {
    guard let doc = try? SwiftSoup.parse(html) else {
        return nil
    }
    return try? doc.body()?.html()
}

internal func hasReadabilityModeBodyClassMarkup(in html: String) -> Bool {
    html.range(of: #"<body[^>]*class=['"][^'"]*\breadability-mode\b[^'"]*['"]"#, options: .regularExpression) != nil
}

internal func hasReaderContentNodeMarkup(in html: String) -> Bool {
    html.range(of: #"<[^>]+id=['"]reader-content['"]"#, options: .regularExpression) != nil
}

internal func hasCanonicalReadabilityMarkup(in html: String) -> Bool {
    hasReadabilityModeBodyClassMarkup(in: html) && hasReaderContentNodeMarkup(in: html)
}

internal func titleFromReadabilityHTML(_ html: String) -> String? {
    guard let doc = try? SwiftSoup.parse(html) else {
        let stripped = html.strippingHTML().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        return stripped.components(separatedBy: "\n").first?.truncate(36)
    }
    let rawCandidate = (try? doc.getElementById("reader-title")?.text())
        ?? (try? doc.title())
    let candidate = rawCandidate?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let candidate, !candidate.isEmpty else { return nil }
    return candidate.truncate(36)
}

private func canHaveReadabilityContent(for url: URL) -> Bool {
    if url.absoluteString == "about:blank" || url.isEBookURL {
        return false
    }
    return url.scheme?.lowercased() != "about"
}

private func ensureReadabilityBodyExists(_ html: String) -> String {
    if html.range(of: "<body", options: .caseInsensitive) != nil {
        return html
    }
    return """
    <html>
    <head></head>
    <body>
    \(html)
    </body>
    </html>
    """
}

private func stripTemplateTagsForReadability(_ html: String) -> String {
    guard html.range(of: "<template", options: .caseInsensitive) != nil else {
        return html
    }
    return html.replacingOccurrences(
        of: #"(?is)<template\b[^>]*>.*?</template>"#,
        with: "",
        options: .regularExpression
    )
}

func buildSnippetCanonicalReadabilityHTML(
    html: String,
    contentURL: URL,
    fallbackTitle: String?
) -> String? {
    let normalizedHTML = ensureReadabilityBodyExists(html)
    if hasCanonicalReadabilityMarkup(in: normalizedHTML) {
        return normalizedHTML
    }
    guard let rawContent = bodyInnerHTML(from: normalizedHTML)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawContent.isEmpty else {
        return nil
    }
    return buildCanonicalReadabilityHTML(
        title: fallbackTitle ?? "",
        byline: "",
        publishedTime: nil,
        content: rawContent,
        contentURL: contentURL
    )
}

@MainActor
private func locallyRetrievableReaderHTML(
    for content: any ReaderContentProtocol,
    readerFileManager: ReaderFileManager
) async throws -> String? {
    var html = try await content.htmlToDisplay(readerFileManager: readerFileManager)
    if html == nil, content.url.isSnippetURL {
        html = content.html
    }
    guard let html else {
        return nil
    }
    let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

@MainActor
public class ReaderModeViewModel: ObservableObject {
    public var readerFileManager: ReaderFileManager?
    public var ebookTextProcessorCacheHits: ((URL) async throws -> Bool)? = nil
    public var processReadabilityContent: ((String, URL, URL?, Bool, ((SwiftSoup.Document) async -> SwiftSoup.Document)) async -> SwiftSoup.Document)? = nil
    public var processHTML: ((String, Bool) async -> String)? = nil
    public var navigator: WebViewNavigator?
    public var defaultFontSize: Double?
    
    @Published public var isReaderMode = false
    @Published public var isReaderModeLoading = false
    @Published var readabilityContent: String? = nil
    @Published var readabilityContainerSelector: String? = nil
    @Published var readabilityContainerFrameInfo: WKFrameInfo? = nil
    @Published var readabilityFrames = Set<WKFrameInfo>()
    
//    @Published var contentRules: String? = nil

    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    
//    private var contentRulesForReadabilityLoading = """
//    [\(["image", "style-sheet", "font", "media", "popup", "svg-document", "websocket", "other"].map {
//        """
//        {
//             "trigger": {
//                 "url-filter": ".*",
//                 "resource-type": ["\($0)"]
//             },
//             "action": {
//                 "type": "block"
//             }
//         }
//        """
//    } .joined(separator: ", "))
//    ]
//    """
    
    internal func readerModeLoading(_ isLoading: Bool) {
        if isLoading && !isReaderModeLoading {
            isReaderModeLoading = true
        } else if !isLoading && isReaderModeLoading {
            isReaderModeLoading = false
        }
    }
    
    public func isReaderModeButtonBarVisible(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && !content.isReaderModeOfferHidden && content.isReaderModeAvailable && !content.isReaderModeByDefault
    }
    public func isReaderModeVisibleInMenu(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && content.isReaderModeOfferHidden && content.isReaderModeAvailable && !content.isReaderModeByDefault
    }
    
    public init() { }

    private enum ReaderModeRoute: String {
        case localHTML = "swiftFinalLoad"
        case capturedReadability = "webviewReadability"
        case unavailable = "unavailable"
    }
    
    func isReaderModeLoadPending(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && content.isReaderModeAvailable && content.isReaderModeByDefault
    }
    
    @MainActor
    func hideReaderModeButtonBar(content: (any ReaderContentProtocol)) async throws {
        if !content.isReaderModeOfferHidden {
            try await content.asyncWrite { _, content in
                content.isReaderModeOfferHidden = true
                content.refreshChangeMetadata(explicitlyModified: true)
            }
            objectWillChange.send()
        }
    }

    @MainActor
    private func resolveReaderModeRoute(readerContent: ReaderContent) async -> ReaderModeRoute {
        let activeReaderFileManager = readerFileManager ?? .shared
        if let content = try? await readerContent.getContent(),
           let html = try? await locallyRetrievableReaderHTML(
                for: content,
                readerFileManager: activeReaderFileManager
           ),
           !html.isEmpty {
            return .localHTML
        }
        if readabilityContent != nil {
            return .capturedReadability
        }
        return .unavailable
    }

    @MainActor
    func readerModeRouteForTesting(readerContent: ReaderContent) async -> String {
        await resolveReaderModeRoute(readerContent: readerContent).rawValue
    }
    
    @MainActor
    internal func showReaderView(readerContent: ReaderContent, scriptCaller: WebViewScriptCaller) {
        let contentURL = readerContent.pageURL
        readerModeLoading(true)
        Task { @MainActor in
            guard contentURL == readerContent.pageURL else {
                readerModeLoading(false)
                return
            }
            let route = await resolveReaderModeRoute(readerContent: readerContent)
            switch route {
            case .localHTML:
                await showReaderViewUsingSwiftProcessing(
                    readerContent: readerContent,
                    scriptCaller: scriptCaller
                )
            case .capturedReadability:
                guard let readabilityContent else {
                    readerModeLoading(false)
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
                    readerModeLoading(false)
                }
            case .unavailable:
                readerModeLoading(false)
            }
        }
    }

    @MainActor
    private func showReaderViewUsingSwiftProcessing(
        readerContent: ReaderContent,
        scriptCaller: WebViewScriptCaller
    ) async {
        do {
            guard let content = try await readerContent.getContent() else {
                readerModeLoading(false)
                return
            }
            let activeReaderFileManager = readerFileManager ?? .shared
            guard let html = try await locallyRetrievableReaderHTML(
                for: content,
                readerFileManager: activeReaderFileManager
            ) else {
                readerModeLoading(false)
                return
            }

            let resolvedReadabilityHTML: String?
            if hasCanonicalReadabilityMarkup(in: html) {
                resolvedReadabilityHTML = html
            } else {
                let swiftReadability = await processReadabilityHTMLInSwift(
                    html: html,
                    url: content.url,
                    meaningfulContentMinChars: max(content.meaningfulContentMinLength, 1)
                )
                switch swiftReadability {
                case .success(let result):
                    resolvedReadabilityHTML = result.outputHTML
                case .unavailable, .failed:
                    resolvedReadabilityHTML = nil
                }
            }

            if let resolvedReadabilityHTML {
                readabilityContent = resolvedReadabilityHTML
                try await showReadabilityContent(
                    readerContent: readerContent,
                    readabilityContent: resolvedReadabilityHTML,
                    renderToSelector: nil,
                    in: nil,
                    scriptCaller: scriptCaller
                )
                return
            }

            readabilityContent = nil
            let directHTML = prepareHTMLForDirectLoad(html)
            if let htmlData = directHTML.data(using: .utf8) {
                navigator?.load(
                    htmlData,
                    mimeType: "text/html",
                    characterEncodingName: "UTF-8",
                    baseURL: content.url
                )
            } else {
                navigator?.loadHTML(directHTML, baseURL: content.url)
            }
        } catch {
            print(error)
            readerModeLoading(false)
        }
    }
    
    /// `readerContent` is used to verify current reader state before loading processed `content`
    @MainActor
    internal func showReadabilityContent(
        readerContent: ReaderContent,
        readabilityContent: String,
        renderToSelector: String?,
        in frameInfo: WKFrameInfo?,
        scriptCaller: WebViewScriptCaller
    ) async throws {
        guard let content = try await readerContent.getContent() else {
            print("No content set to show in reader mode")
            readerModeLoading(false)
            return
        }
        let url = content.url
        let renderBaseURL: URL
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" || url.isSnippetURL {
            renderBaseURL = url
        } else if url.absoluteString == "about:blank" {
            renderBaseURL = readerContent.pageURL
        } else {
            renderBaseURL = url
        }
        
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
            content.refreshChangeMetadata(explicitlyModified: true)
        }
        
        if !isReaderMode {
            isReaderMode = true
        }
        
        let injectEntryImageIntoHeader = content.injectEntryImageIntoHeader
        let titleForDisplay = content.titleForDisplay
        let imageURLToDisplay = try await content.imageURLToDisplay()
        let processReadabilityContent = processReadabilityContent
        let processHTML = processHTML
        
        try await { @ReaderViewModelActor [weak self] in
            var doc: SwiftSoup.Document?
            
            if let processReadabilityContent {
                doc = await processReadabilityContent(
                    readabilityContent,
                    url,
                    nil,
                    false,
                    { doc in
                        do {
                            return try await preprocessWebContentForReaderMode(
                                doc: doc,
                                url: url
                            )
                        } catch {
                            print(error)
                            return doc
                        }
                    }
                )
            } else {
                let isXML = readabilityContent.hasPrefix("<?xml") || readabilityContent.hasPrefix("<?XML") // TODO: Case insensitive
                let parser = isXML ? SwiftSoup.Parser.xmlParser() : SwiftSoup.Parser.htmlParser()
                doc = try SwiftSoup.parse(readabilityContent, url.absoluteString, parser)
                doc?.outputSettings().prettyPrint(pretty: false).syntax(syntax: isXML ? .xml : .html)
                doc?.outputSettings().charset(.utf8)
                if isXML {
                    doc?.outputSettings().escapeMode(.xhtml)
                }
            }
            
            guard let doc else {
                print("Error: Unexpectedly failed to receive doc")
                return
            }

            try await processForReaderMode(
                doc: doc,
                url: url,
                contentSectionLocationIdentifier: nil,
                isEBook: false,
                isCacheWarmer: false,
                defaultTitle: titleForDisplay,
                imageURL: imageURLToDisplay,
                injectEntryImageIntoHeader: injectEntryImageIntoHeader,
                defaultFontSize: defaultFontSize ?? 21
            )

            var html = try doc.outerHtml()
            
            if let processHTML {
                html = await processHTML(
                    html,
                    false
                )
            }

            let transformedContent = html
            try await { @MainActor in
                guard url.matchesReaderURL(readerContent.pageURL) else {
                    print("Readability content URL mismatch", url, readerContent.pageURL)
                    readerModeLoading(false)
                    return
                }
                if let frameInfo = frameInfo, !frameInfo.isMainFrame {
                    try await scriptCaller.evaluateJavaScript(
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
                    readerModeLoading(false)
                } else if let htmlData = transformedContent.data(using: .utf8) {
                    navigator?.load(
                        htmlData,
                        mimeType: "text/html",
                        characterEncodingName: "UTF-8",
                        baseURL: renderBaseURL
                    )
                } else {
                    navigator?.loadHTML(transformedContent, baseURL: renderBaseURL)
                }
//                try await { @MainActor in
//                    readerModeLoading(false)
//                }()
            }()
        }()
    }

    @ReaderViewModelActor
    private func processReadabilityHTMLInSwift(
        html: String,
        url: URL,
        meaningfulContentMinChars: Int
    ) async -> SwiftReadabilityProcessingOutcome {
        guard canHaveReadabilityContent(for: url) else {
            return .unavailable
        }

        let normalizedHTML = ensureReadabilityBodyExists(html)
        let options = SwiftReadability.ReadabilityOptions(
            charThreshold: max(meaningfulContentMinChars, 1),
            classesToPreserve: readabilityClassesToPreserve
        )
        let parser = SwiftReadability.Readability(
            html: normalizedHTML,
            url: url,
            options: options
        )

        guard let result = try? parser.parse() else {
            if url.isSnippetURL,
               let snippetHTML = buildSnippetCanonicalReadabilityHTML(
                    html: normalizedHTML,
                    contentURL: url,
                    fallbackTitle: titleFromReadabilityHTML(normalizedHTML)
               ) {
                return .success(SwiftReadabilityProcessingResult(outputHTML: snippetHTML))
            }
            return .failed
        }

        let rawContent = stripTemplateTagsForReadability(result.content)
        guard !rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed
        }

        let outputHTML = buildCanonicalReadabilityHTML(
            title: stripTemplateTagsForReadability(result.title ?? ""),
            byline: stripTemplateTagsForReadability(result.byline ?? ""),
            publishedTime: result.publishedTime,
            content: rawContent,
            contentURL: url
        )
        return .success(SwiftReadabilityProcessingResult(outputHTML: outputHTML))
    }
    
    @MainActor
    public func onNavigationCommitted(
        readerContent: ReaderContent,
        newState: WebViewState,
        scriptCaller: WebViewScriptCaller
    ) async throws {
        readabilityContainerFrameInfo = nil
        readabilityContent = nil
        readabilityContainerSelector = nil
//        contentRules = nil
        try Task.checkCancellation()

        guard let content = readerContent.content else {
            print("No content to display in ReaderModeViewModel onNavigationCommitted")
            readerModeLoading(false)
            return
        }
        try Task.checkCancellation()
        
        let committedURL = content.url
        guard committedURL.matchesReaderURL(newState.pageURL) else {
            print("URL mismatch in ReaderModeViewModel onNavigationCommitted", committedURL, newState.pageURL)
            readerModeLoading(false)
            return
        }
        try Task.checkCancellation()

        // FIXME: Mokuro? check plugins thing for reader mode url instead of hardcoding methods here
        let isReaderModeVerified = content.isReaderModeByDefault
        try Task.checkCancellation()
        
        if isReaderMode != isReaderModeVerified && !newState.pageURL.isEBookURL {
            withAnimation {
                readerModeLoading(isReaderModeVerified)
                isReaderMode = isReaderModeVerified // Reset and confirm via JS later
            }
            try Task.checkCancellation()
        }
        
        if newState.pageURL.isReaderURLLoaderURL {
            if let readerFileManager, let html = try await content.htmlToDisplay(readerFileManager: readerFileManager) {
                try Task.checkCancellation()
                
                let currentURL = readerContent.pageURL
                guard committedURL.matchesReaderURL(currentURL) else {
                    print("URL mismatch in ReaderModeViewModel onNavigationCommitted", currentURL, committedURL)
                    readerModeLoading(false)
                    return
                }
                if hasCanonicalReadabilityMarkup(in: html) {
                    readabilityContent = html
                } else {
                    readabilityContent = nil
                }
                showReaderView(
                    readerContent: readerContent,
                    scriptCaller: scriptCaller
                )
            } else {
                guard let navigator else {
                    print("Error: No navigator set in ReaderModeViewModel onNavigationCommitted")
                    return
                }
                navigator.load(URLRequest(url: committedURL))
            }
//        } else {
//            debugPrint("# nav commit mid 2..", newState.pageURL, content.isReaderModeAvailable)
//            if content.isReaderModeByDefault, !content.isReaderModeAvailable {
//                debugPrint("# on commit, read mode NOT avail, loading false")
//                readerModeLoading(false)
//            }
        }
    }
    
    @MainActor
    public func onNavigationFinished(
        newState: WebViewState,
        scriptCaller: WebViewScriptCaller
    ) async {
        if !newState.pageURL.isReaderURLLoaderURL {
            do {
                let isNextReaderMode = try await scriptCaller.evaluateJavaScript("return document.body?.dataset.isNextLoadInReaderMode === 'true'") as? Bool ?? false
                if !isNextReaderMode {
                    readerModeLoading(false)
                }
            } catch {
                readerModeLoading(false)
            }
        }
    }
    
    @MainActor
    public func onNavigationFailed(newState: WebViewState) {
        readerModeLoading(false)
    }
}

func prepareHTMLForDirectLoad(_ html: String) -> String {
    var updatedHTML = html
    let markerPatterns = [
        #"data-is-next-load-in-reader-mode=['\"][^'"]*['\"]"#,
        #"data-manabi-reader-mode-available=['\"][^'"]*['\"]"#,
        #"data-manabi-reader-mode-available-for=['\"][^'"]*['\"]"#
    ]
    for pattern in markerPatterns {
        updatedHTML = updatedHTML.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
    }

    if updatedHTML.range(of: "<body", options: .caseInsensitive) == nil {
        return """
        <html>
        <head></head>
        <body>
        \(updatedHTML)
        </body>
        </html>
        """
    }
    return updatedHTML
}

fileprivate let readerFontSizeStylePattern = #"(?i)(<body[^>]*\bstyle="[^"]*)font-size:\s*[\d.]+px"#
fileprivate let readerFontSizeStyleRegex = try! NSRegularExpression(pattern: readerFontSizeStylePattern, options: .caseInsensitive)

fileprivate let bodyStylePattern = #"(?i)(<body[^>]*\bstyle=")([^"]*)(")"#
fileprivate let bodyStyleRegex = try! NSRegularExpression(pattern: bodyStylePattern, options: .caseInsensitive)

fileprivate func rewriteManabiReaderFontSizeStyle(in htmlBytes: [UInt8], newFontSize: Double) -> [UInt8] {
    // Convert the UTF8 bytes to a String.
    guard let html = String(bytes: htmlBytes, encoding: .utf8) else {
        return htmlBytes
    }
    
    let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
    let nsHTML = html as NSString
    var updatedHtml: String
    let newFontSizeStr = "font-size: " + String(newFontSize) + "px"
    // If a font-size exists in the style, replace it.
    if let firstMatch = readerFontSizeStyleRegex.firstMatch(in: html, options: [], range: nsRange) {
        let replacement = readerFontSizeStyleRegex.replacementString(
            for: firstMatch,
            in: html,
            offset: 0,
            template: "$1" + newFontSizeStr
        )
        updatedHtml = nsHTML.replacingCharacters(in: firstMatch.range, with: replacement)
    }
    // Otherwise, if a <body ... style="..."> exists, insert the font-size.
    else if let styleMatch = bodyStyleRegex.firstMatch(in: html, options: [], range: nsRange) {
        let prefix = nsHTML.substring(with: styleMatch.range(at: 1))
        let content = nsHTML.substring(with: styleMatch.range(at: 2))
        let suffix = nsHTML.substring(with: styleMatch.range(at: 3))
        let newContent = newFontSizeStr + "; " + content
        let replacement = prefix + newContent + suffix
        updatedHtml = nsHTML.replacingCharacters(in: styleMatch.range, with: replacement)
    }
    else {
        updatedHtml = html
    }
    
    // Convert the updated HTML string back to UTF8 bytes.
    return Array(updatedHtml.utf8)
}

public func preprocessWebContentForReaderMode(
    doc: SwiftSoup.Document,
    url: URL
) throws -> SwiftSoup.Document {
    transformContentSpecificToFeed(doc: doc, url: url)
    do {
        try wireViewOriginalLinks(doc: doc, url: url)
    } catch { }
    return doc
}

public func processForReaderMode(
    doc: SwiftSoup.Document,
    url: URL,
    contentSectionLocationIdentifier: String?,
    isEBook: Bool,
    isCacheWarmer: Bool,
    defaultTitle: String?,
    imageURL: URL?,
    injectEntryImageIntoHeader: Bool,
    defaultFontSize: CGFloat
) throws {
    // Migrate old cached versions
    // TODO: Update cache, if this is a performance issue.
    if let oldElement = try doc.getElementsByClass("reader-content").first(), try doc.getElementById("reader-content") == nil {
        try oldElement.attr("id", "reader-content")
        try oldElement.removeAttr("class")
    }
    
    if isEBook {
        try doc.body()?.attr("data-is-ebook", "true")
    }
    
    if !isCacheWarmer {
        if let bodyTag = doc.body() {
            // TODO: font size and theme set elsewhere already..?
            let readerFontSize = (UserDefaults.standard.object(forKey: "readerFontSize") as? Double) ?? defaultFontSize
            let lightModeTheme = (UserDefaults.standard.object(forKey: "lightModeTheme") as? LightModeTheme) ?? .white
            let darkModeTheme = (UserDefaults.standard.object(forKey: "darkModeTheme") as? DarkModeTheme) ?? .black
            
            var bodyStyle = "font-size: \(readerFontSize)px"
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
        
        if !isEBook {
            do {
                try fixAnnoyingTitlesWithPipes(doc: doc)
            } catch { }
        }
        
        if try injectEntryImageIntoHeader || (doc.body()?.getElementsByTag(UTF8Arrays.img).isEmpty() ?? true), let imageURL = imageURL, let existing = try? doc.select("img[src='\(imageURL.absoluteString)'"), existing.isEmpty() {
            do {
                try doc.getElementById("reader-header")?.prepend("<img src='\(imageURL.absoluteString)'>")
            } catch { }
        }
    }
}
