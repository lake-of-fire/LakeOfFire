import SwiftUI
import SwiftUIWebView
import SwiftSoup
import RealmSwift
import Combine
import RealmSwiftGaps
import LakeKit
import WebKit

@globalActor
fileprivate actor ReaderViewModelActor {
    static var shared = ReaderViewModelActor()
}

@MainActor
public class ReaderModeViewModel: ObservableObject {
    public var readerFileManager: ReaderFileManager?
    public var ebookTextProcessorCacheHits: ((URL, String?) async throws -> Bool)? = nil
    public var processReadabilityContent: ((String, URL, URL?, Bool, ((SwiftSoup.Document) async -> SwiftSoup.Document)) async -> SwiftSoup.Document)? = nil
    public var processHTML: ((String, Bool) async -> String)? = nil
    public var navigator: WebViewNavigator?
    public var defaultFontSize: Double?
    private var lastFallbackLoaderURL: URL?
    private var lastRenderedReadabilityURL: URL?
    private var pendingReaderModeURL: URL?
    private var loadTraceRecords: [String: ReaderModeLoadTraceRecord] = [:]
    
    @Published public var isReaderMode = false
    @Published public var isReaderModeLoading = false
    @Published var readabilityContent: String? = nil
    @Published var readabilityContainerSelector: String? = nil
    @Published var readabilityContainerFrameInfo: WKFrameInfo? = nil
    @Published var readabilityFrames = Set<WKFrameInfo>()
    
//    @Published var contentRules: String? = nil

    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black

    private struct ReaderModeLoadTraceRecord {
        var startedAt: Date
        var lastEventAt: Date
    }

    private enum ReaderModeLoadStage: String {
        case begin
        case navCommitted
        case htmlFetchStart
        case htmlFetchEnd
        case readabilityContentReady
        case readabilityTaskScheduled
        case contentWriteStart
        case contentWriteEnd
        case readabilityProcessingStart
        case readabilityProcessingFinish
        case processForReaderModeStart
        case processForReaderModeFinish
        case navigatorLoad
        case fallbackLoad
        case cancel
        case complete
        case navFinished

        var isTerminal: Bool {
            switch self {
            case .complete, .cancel:
                return true
            default:
                return false
            }
        }
    }

    private func formattedInterval(_ interval: TimeInterval) -> String {
        String(format: "%.3fs", interval)
    }

    private func traceKey(for url: URL) -> String {
        url.absoluteString
    }

    private func logTrace(
        _ stage: ReaderModeLoadStage,
        url: URL?,
        captureStart: Bool = false,
        details: String? = nil
    ) {
        let now = Date()
        var components: [String] = []
        if let url {
            let key = traceKey(for: url)
            if captureStart || loadTraceRecords[key] == nil {
                loadTraceRecords[key] = ReaderModeLoadTraceRecord(startedAt: now, lastEventAt: now)
            }
            if var record = loadTraceRecords[key] {
                let elapsed = now.timeIntervalSince(record.startedAt)
                let delta = now.timeIntervalSince(record.lastEventAt)
                components.append("t+\(formattedInterval(elapsed))")
                components.append("Δ\(formattedInterval(delta))")
                record.lastEventAt = now
                loadTraceRecords[key] = record
            }
            if let detail = details, !detail.isEmpty {
                components.append(detail)
            }
            let message = components.joined(separator: " | ")
            debugPrint("# READERTRACE", stage.rawValue, message, url.absoluteString)
            if stage.isTerminal {
                loadTraceRecords.removeValue(forKey: key)
            }
        } else {
            if let detail = details, !detail.isEmpty {
                components.append(detail)
            }
            let message = components.joined(separator: " | ")
            debugPrint("# READERTRACE", stage.rawValue, message)
        }
    }
    
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
            debugPrint("# FLASH ReaderModeViewModel.readerModeLoading", isLoading)
            isReaderModeLoading = true
        } else if !isLoading && isReaderModeLoading {
            debugPrint("# FLASH ReaderModeViewModel.readerModeLoading", isLoading)
            isReaderModeLoading = false
        }
    }

    @MainActor
    public func beginReaderModeLoad(for url: URL) {
        var isContinuing = false
        if let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(url) {
            // already tracking this load
            isContinuing = true
        } else {
            pendingReaderModeURL = url
        }
        logTrace(
            .begin,
            url: pendingReaderModeURL ?? url,
            captureStart: !isContinuing,
            details: isContinuing ? "continuing pending load" : "starting new load"
        )
        readerModeLoading(true)
    }

    @MainActor
    public func cancelReaderModeLoad(for url: URL? = nil) {
        guard let pendingReaderModeURL else {
            logTrace(.cancel, url: url, details: "no pending load to cancel")
            if url == nil {
                readerModeLoading(false)
            }
            return
        }
        if let url, !pendingReaderModeURL.matchesReaderURL(url) {
            logTrace(.cancel, url: url, details: "cancel ignored: pending load is for \(pendingReaderModeURL.absoluteString)")
            return
        }
        let traceURL = pendingReaderModeURL
        self.pendingReaderModeURL = nil
        logTrace(.cancel, url: traceURL, details: "cancelReaderModeLoad invoked")
        readerModeLoading(false)
    }

    @MainActor
    public func markReaderModeLoadComplete(for url: URL) {
        guard let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(url) else {
            return
        }
        let traceURL = pendingReaderModeURL
        self.pendingReaderModeURL = nil
        logTrace(.complete, url: traceURL, details: "markReaderModeLoadComplete")
        readerModeLoading(false)
    }

    @MainActor
    public func isReaderModeLoadPending(for url: URL) -> Bool {
        guard let pendingReaderModeURL else { return false }
        return pendingReaderModeURL.matchesReaderURL(url)
    }

//    @MainActor
//    public func invalidateLastRenderedReadabilityURL() {
//        debugPrint("# FLASH ReaderModeViewModel.invalidateLastRenderedReadabilityURL clearing", lastRenderedReadabilityURL?.absoluteString ?? "nil")
//        lastRenderedReadabilityURL = nil
//        lastFallbackLoaderURL = nil
//    }
    
    public func isReaderModeButtonBarVisible(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && !content.isReaderModeOfferHidden && content.isReaderModeAvailable && !content.isReaderModeByDefault
    }
    public func isReaderModeVisibleInMenu(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && content.isReaderModeOfferHidden && content.isReaderModeAvailable && !content.isReaderModeByDefault
    }
    
    public init() { }
    
    func isReaderModeLoadPending(content: any ReaderContentProtocol) -> Bool {
        if let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(content.url) {
            return true
        }
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
    internal func showReaderView(readerContent: ReaderContent, scriptCaller: WebViewScriptCaller) {
        debugPrint("# FLASH ReaderModeViewModel.showReaderView invoked", readerContent.pageURL)
        let readabilityBytes = readabilityContent?.utf8.count ?? 0
        logTrace(.readabilityTaskScheduled, url: readerContent.pageURL, details: "readabilityBytes=\(readabilityBytes)")
        guard let readabilityContent else {
            // FIME: WHY THIS CALLED WHEN LOAD??
            debugPrint("# FLASH ReaderModeViewModel.showReaderView missing readabilityContent", readerContent.pageURL)
            cancelReaderModeLoad(for: readerContent.pageURL)
            return
        }
        let contentURL = readerContent.pageURL
        beginReaderModeLoad(for: contentURL)
        Task { @MainActor in
            guard contentURL == readerContent.pageURL else {
                debugPrint("# FLASH ReaderModeViewModel.showReaderView contentURL mismatch", contentURL, readerContent.pageURL)
                cancelReaderModeLoad(for: contentURL)
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
                debugPrint("# FLASH ReaderModeViewModel.showReaderView showReadabilityContent failed", error.localizedDescription)
                print(error)
                cancelReaderModeLoad(for: contentURL)
            }
        }
    }
    
    /// `readerContent` is used to verify current reader state before loading processed `content`
    @MainActor
    private func showReadabilityContent(
        readerContent: ReaderContent,
        readabilityContent: String,
        renderToSelector: String?,
        in frameInfo: WKFrameInfo?,
        scriptCaller: WebViewScriptCaller
    ) async throws {
        guard let content = try await readerContent.getContent() else {
            debugPrint("# READERTRACE ReaderModeViewModel.showReadabilityContent missing content")
            print("No content set to show in reader mode")
            cancelReaderModeLoad(for: readerContent.pageURL)
            return
        }
        let url = content.url
        debugPrint("# READERTRACE ReaderModeViewModel.showReadabilityContent start", url, "renderTo", renderToSelector ?? "<root>")
        let renderTarget = renderToSelector ?? "<root>"
        logTrace(.readabilityProcessingStart, url: url, details: "renderTo=\(renderTarget) | frameIsMain=\(frameInfo?.isMainFrame ?? true)")

        if let lastRenderedReadabilityURL {
            debugPrint("# READERTRACE ReaderModeViewModel.showReadabilityContent duplicate check", lastRenderedReadabilityURL.absoluteString, "candidate", url.absoluteString)
            if lastRenderedReadabilityURL.matchesReaderURL(url) {
                debugPrint("# READERTRACE ReaderModeViewModel.showReadabilityContent skipping duplicate render", url)
                markReaderModeLoadComplete(for: url)
                return
            }
        }

        if let lastFallbackLoaderURL {
            debugPrint("# READERTRACE ReaderModeViewModel.showReadabilityContent clearing lastFallbackLoaderURL", lastFallbackLoaderURL.absoluteString)
            self.lastFallbackLoaderURL = nil
        }
        
        Task {
            try await scriptCaller.evaluateJavaScript("""
            if (document.body) {
                document.body.dataset.isNextLoadInReaderMode = 'true';
            }
            """)
        }
        
        let asyncWriteStartedAt = Date()
        logTrace(.contentWriteStart, url: url, details: "marking reader defaults")
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
        logTrace(.contentWriteEnd, url: url, details: "duration=\(formattedInterval(Date().timeIntervalSince(asyncWriteStartedAt)))")

        if !isReaderMode {
            isReaderMode = true
        }
        
        let injectEntryImageIntoHeader = content.injectEntryImageIntoHeader
        let titleForDisplay = content.titleForDisplay
        let imageURLToDisplay = try await content.imageURLToDisplay()
        let processReadabilityContent = processReadabilityContent
        let processHTML = processHTML
        
        try await { @ReaderViewModelActor [weak self] in
            let parseStartedAt = Date()
            var doc: SwiftSoup.Document?

            if let processReadabilityContent {
                debugPrint("# READERTRACE ReaderModeViewModel.showReadabilityContent processReadabilityContent", url)
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
                debugPrint("# READERTRACE ReaderModeViewModel.showReadabilityContent direct parse", url)
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
                debugPrint("# READERTRACE ReaderModeViewModel.showReadabilityContent doc missing", url)
                print("Error: Unexpectedly failed to receive doc")
                return
            }
            let parseDuration = Date().timeIntervalSince(parseStartedAt)
            let parseSummary = String(format: "%.3fs", parseDuration)
            await MainActor.run {
                self?.logTrace(.readabilityProcessingFinish, url: url, details: "duration=\(parseSummary)")
            }

            let transformStartedAt = Date()
            await MainActor.run {
                self?.logTrace(.processForReaderModeStart, url: url)
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
            let transformDuration = Date().timeIntervalSince(transformStartedAt)
            let transformSummary = String(format: "%.3fs", transformDuration)
            await MainActor.run {
                self?.logTrace(.processForReaderModeFinish, url: url, details: "duration=\(transformSummary)")
            }

            var html = try doc.outerHtml()

            if let processHTML {
                debugPrint("# FLASH ReaderModeViewModel.showReadabilityContent processHTML", url)
                html = await processHTML(
                    html,
                    false
                )
            }

            let transformedContent = html
            try await { @MainActor in
                guard url.matchesReaderURL(readerContent.pageURL) else {
                    debugPrint("# FLASH ReaderModeViewModel.showReadabilityContent reader URL mismatch", url, readerContent.pageURL)
                    print("Readability content URL mismatch", url, readerContent.pageURL)
                    cancelReaderModeLoad(for: url)
                    return
                }
                if let frameInfo = frameInfo, !frameInfo.isMainFrame {
                    debugPrint("# FLASH ReaderModeViewModel.showReadabilityContent injecting into frame", frameInfo)
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
                        """
                        ,
                        arguments: [
                            "renderToSelector": renderToSelector ?? "",
                            "html": transformedContent,
                            "css": Readability.shared.css,
                        ], in: frameInfo)
                    logTrace(.navigatorLoad, url: url, details: "mode=frame-injection")
                    markReaderModeLoadComplete(for: url)
                } else if let htmlData = transformedContent.data(using: .utf8) {
                    guard let navigator else {
                        print("ReaderModeViewModel: navigator missing while loading readability content for", url.absoluteString)
                        cancelReaderModeLoad(for: url)
                        return
                    }
                    debugPrint("# FLASH ReaderModeViewModel.showReadabilityContent navigator.load htmlData", url)
                    logTrace(.navigatorLoad, url: url, details: "mode=readability-html | bytes=\(transformedContent.utf8.count)")
                    navigator.load(
                        htmlData,
                        mimeType: "text/html",
                        characterEncodingName: "UTF-8",
                        baseURL: url
                    )
                } else {
                    print("ReaderModeViewModel: readability HTML data missing for", url.absoluteString)
                    cancelReaderModeLoad(for: url)
                }

//                try await { @MainActor in
//                    readerModeLoading(false)
//                }()
            }()
            try await { @MainActor in
                lastRenderedReadabilityURL = url
            }()
        }()
    }

    @MainActor
    public func onNavigationCommitted(
        readerContent: ReaderContent,
        newState: WebViewState,
        scriptCaller: WebViewScriptCaller
    ) async throws {
        debugPrint("# FLASH ReaderModeViewModel.onNavigationCommitted", newState.pageURL)
        readabilityContainerFrameInfo = nil
        readabilityContent = nil
        readabilityContainerSelector = nil
//        contentRules = nil
        try Task.checkCancellation()
        
        guard let content = readerContent.content else {
            debugPrint("# FLASH ReaderModeViewModel.onNavigationCommitted missing readerContent.content", newState.pageURL)
            print("No content to display in ReaderModeViewModel onNavigationCommitted")
            cancelReaderModeLoad(for: newState.pageURL)
            return
        }
        try Task.checkCancellation()
        
        let committedURL = content.url
        guard committedURL.matchesReaderURL(newState.pageURL) else {
            debugPrint("# FLASH ReaderModeViewModel.onNavigationCommitted URL mismatch", committedURL, newState.pageURL)
            print("URL mismatch in ReaderModeViewModel onNavigationCommitted", committedURL, newState.pageURL)
            cancelReaderModeLoad(for: committedURL)
            return
        }
        try Task.checkCancellation()
        logTrace(.navCommitted, url: committedURL, details: "pageURL=\(newState.pageURL.absoluteString)")

        // FIXME: Mokuro? check plugins thing for reader mode url instead of hardcoding methods here
        let isReaderModeVerified = content.isReaderModeByDefault
        try Task.checkCancellation()
        
        if isReaderMode != isReaderModeVerified && !newState.pageURL.isEBookURL {
            withAnimation {
                if isReaderModeVerified {
                    beginReaderModeLoad(for: committedURL)
                } else {
                    cancelReaderModeLoad(for: committedURL)
                }
                isReaderMode = isReaderModeVerified // Reset and confirm via JS later
            }
            try Task.checkCancellation()
        }

        if newState.pageURL.isReaderURLLoaderURL {
            debugPrint("# FLASH ReaderModeViewModel.onNavigationCommitted reader loader url", committedURL)
            if let readerFileManager {
                logTrace(.htmlFetchStart, url: committedURL, details: "readerFileManager available")
                let htmlFetchStartedAt = Date()
                let htmlResult = try await content.htmlToDisplay(readerFileManager: readerFileManager)
                let fetchDuration = formattedInterval(Date().timeIntervalSince(htmlFetchStartedAt))
                if var html = htmlResult {
                    logTrace(.htmlFetchEnd, url: committedURL, details: "bytes=\(html.utf8.count) | duration=\(fetchDuration)")
                    try Task.checkCancellation()

                    let currentURL = readerContent.pageURL
                    guard committedURL.matchesReaderURL(currentURL) else {
                        debugPrint("# FLASH ReaderModeViewModel.onNavigationCommitted currentURL mismatch", committedURL, currentURL)
                        print("URL mismatch in ReaderModeViewModel.onNavigationCommitted", currentURL, committedURL)
                        cancelReaderModeLoad(for: committedURL)
                        return
                    }
                    if let lastFallbackLoaderURL, lastFallbackLoaderURL == newState.pageURL {
                        debugPrint("# FLASH ReaderModeViewModel.onNavigationCommitted skipping duplicate fallback", newState.pageURL)
                        return
                    }

                    let hasReadabilityMarkup = html.range(of: #"<body.*?class['"].*?readability-mode.*?['"]>"#, options: .regularExpression) != nil || html.range(of: #"<body.*?data-is-next-load-in-reader-mode['"]true['"]>"#, options: .regularExpression) != nil
                    let shouldUseReadability = committedURL.isSnippetURL || hasReadabilityMarkup

                    if shouldUseReadability {
                        readabilityContent = html
                        logTrace(
                            .readabilityContentReady,
                            url: committedURL,
                            details: "hasReadabilityMarkup=\(hasReadabilityMarkup) | isSnippet=\(committedURL.isSnippetURL)"
                        )
                        if committedURL.isSnippetURL {
                            debugPrint("# FLASH ReaderModeViewModel.onNavigationCommitted snippet readabilityContent captured", committedURL)
                        } else {
                            debugPrint("# FLASH ReaderModeViewModel.onNavigationCommitted readabilityContent captured", committedURL)
                        }
                        showReaderView(
                            readerContent: readerContent,
                            scriptCaller: scriptCaller
                        )
                        lastFallbackLoaderURL = nil
                    } else {
                        if let _ = html.range(of: "<body", options: .caseInsensitive) {
                            html = html.replacingOccurrences(of: "<body", with: "<body data-is-next-load-in-reader-mode='true' ", options: .caseInsensitive)
                        } else {
                            html = "<body data-is-next-load-in-reader-mode='true'>\n" + html + "</html>"
                        }
                        try Task.checkCancellation()
                        if let htmlData = html.data(using: .utf8) {
                            debugPrint("# FLASH ReaderModeViewModel.onNavigationCommitted navigator.load fallback html", committedURL)
                            Task { @MainActor in
                                navigator?.load(
                                    htmlData,
                                    mimeType: "text/html",
                                    characterEncodingName: "UTF-8",
                                    baseURL: committedURL
                                )
                                logTrace(.navigatorLoad, url: committedURL, details: "mode=fallback-html | bytes=\(htmlData.count)")
                            }
                        }
                        lastFallbackLoaderURL = newState.pageURL
                        logTrace(.fallbackLoad, url: committedURL, details: "rendered fallback markup")
                    }
                } else {
                    logTrace(.fallbackLoad, url: committedURL, details: "htmlToDisplay returned nil | duration=\(fetchDuration)")
                    guard let navigator else {
                        print("Error: No navigator set in ReaderModeViewModel onNavigationCommitted")
                        return
                    }
                    debugPrint("# FLASH ReaderModeViewModel.onNavigationCommitted navigator.load fallback request", committedURL)
                    logTrace(.navigatorLoad, url: committedURL, details: "mode=fallback-request")
                    navigator.load(URLRequest(url: committedURL))
                }
            } else {
                logTrace(.htmlFetchStart, url: committedURL, details: "readerFileManager missing; falling back to request")
                guard let navigator else {
                    print("Error: No navigator set in ReaderModeViewModel onNavigationCommitted")
                    return
                }
                debugPrint("# FLASH ReaderModeViewModel.onNavigationCommitted navigator.load fallback request", committedURL)
                logTrace(.navigatorLoad, url: committedURL, details: "mode=fallback-request")
                navigator.load(URLRequest(url: committedURL))
            }
//        } else {
//            debugPrint("# nav commit mid 2..", newState.pageURL, content.isReaderModeAvailable)
//            if content.isReaderModeByDefault, !content.isReaderModeAvailable {
//                debugPrint("# on commit, read mode NOT avail, loading false")
//                readerModeLoading(false)
//            }
        } else {
            lastFallbackLoaderURL = nil
        }
    }
    
    @MainActor
    public func onNavigationFinished(
        newState: WebViewState,
        scriptCaller: WebViewScriptCaller
    ) async {
        debugPrint("# FLASH ReaderModeViewModel.onNavigationFinished", newState.pageURL)
        if let trackedURL = pendingReaderModeURL {
            logTrace(.navFinished, url: trackedURL, details: "pageURL=\(newState.pageURL.absoluteString)")
        } else if loadTraceRecords[traceKey(for: newState.pageURL)] != nil {
            logTrace(.navFinished, url: newState.pageURL, details: "pageURL=\(newState.pageURL.absoluteString)")
        }
        if !newState.pageURL.isReaderURLLoaderURL {
            if newState.pageURL.isNativeReaderView, pendingReaderModeURL != nil {
                // about:blank or native placeholder during the reader-mode bootstrap; keep loading state.
                return
            }
            do {
                let isNextReaderMode = try await scriptCaller.evaluateJavaScript("return document.body?.dataset.isNextLoadInReaderMode === 'true'") as? Bool ?? false
                if !isNextReaderMode {
                    if let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(newState.pageURL) {
                        // Keep the spinner alive until the reader-mode initialization finishes.
                    } else {
                        readerModeLoading(false)
                    }
                }
            } catch {
                debugPrint("# FLASH ReaderModeViewModel.onNavigationFinished JS failed", error.localizedDescription)
                cancelReaderModeLoad(for: newState.pageURL)
            }
        }
    }

    @MainActor
    public func onNavigationFailed(newState: WebViewState) {
        debugPrint("# FLASH ReaderModeViewModel.onNavigationFailed", newState.pageURL)
        cancelReaderModeLoad(for: newState.pageURL)
    }
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
