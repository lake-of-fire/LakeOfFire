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
    public var readerModeLoadCompletionHandler: ((URL) -> Void)?
    private var lastFallbackLoaderURL: URL?
    private var lastRenderedReadabilityURL: URL?
    private var expectedSyntheticReaderLoaderURL: URL?
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

    private func expectSyntheticReaderLoaderCommit(for baseURL: URL?) {
        guard let baseURL else {
            expectedSyntheticReaderLoaderURL = nil
            return
        }
        expectedSyntheticReaderLoaderURL = baseURL
    }

    @discardableResult
    private func consumeSyntheticReaderLoaderExpectationIfNeeded(for url: URL) -> Bool {
        guard let expectedSyntheticReaderLoaderURL else { return false }

        func matchesLoaderURL(_ lhs: URL, _ rhs: URL) -> Bool {
            if lhs.matchesReaderURL(rhs) || rhs.matchesReaderURL(lhs) {
                return true
            }
            return urlsMatchWithoutHash(lhs, rhs)
        }

        if matchesLoaderURL(expectedSyntheticReaderLoaderURL, url) {
            self.expectedSyntheticReaderLoaderURL = nil
            return true
        }

        return false
    }

    private func traceKey(for url: URL) -> String {
        url.absoluteString
    }

    private func updatePendingReaderModeURL(_ newValue: URL?, reason: String) {
        let oldValue = pendingReaderModeURL
        let oldDescription = oldValue?.absoluteString ?? "nil"
        let newDescription = newValue?.absoluteString ?? "nil"
        let changeDescription: String
        if urlsMatchWithoutHash(oldValue, newValue) {
            changeDescription = "unchanged"
        } else {
            changeDescription = "updated"
        }
        debugPrint(
            "# READER readerMode.pendingUpdate",
            "from=\(oldDescription)",
            "to=\(newDescription)",
            "change=\(changeDescription)",
            "reason=\(reason)"
        )
        pendingReaderModeURL = newValue
    }

    private func logTrace(
        _ stage: ReaderModeLoadStage,
        url: URL?,
        captureStart: Bool = false,
        details: String? = nil
    ) {
        let now = Date()
        guard let url else { return }
        let key = traceKey(for: url)
        var elapsedSinceStart: TimeInterval = 0
        var elapsedSinceLast: TimeInterval?
        if captureStart || loadTraceRecords[key] == nil {
            loadTraceRecords[key] = ReaderModeLoadTraceRecord(startedAt: now, lastEventAt: now)
        } else if var record = loadTraceRecords[key] {
            elapsedSinceStart = now.timeIntervalSince(record.startedAt)
            elapsedSinceLast = now.timeIntervalSince(record.lastEventAt)
            record.lastEventAt = now
            loadTraceRecords[key] = record
        }
        var segments: [String] = [
            "# READER readerMode.trace",
            "stage=\(stage.rawValue)",
            "url=\(url.absoluteString)",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "elapsed=\(formattedInterval(elapsedSinceStart))"
        ]
        if let elapsedSinceLast {
            segments.append("delta=\(formattedInterval(elapsedSinceLast))")
        }
        if let details, !details.isEmpty {
            segments.append("details=\(details)")
        }
        debugPrint(segments.joined(separator: " "))
        if stage.isTerminal {
            loadTraceRecords.removeValue(forKey: key)
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
            debugPrint(
                "# READER readerMode.spinner",
                "loading=true",
                "pendingURL=\(pendingReaderModeURL?.absoluteString ?? "nil")"
            )
            isReaderModeLoading = true
        } else if !isLoading && isReaderModeLoading {
            debugPrint(
                "# READER readerMode.spinner",
                "loading=false",
                "pendingURL=\(pendingReaderModeURL?.absoluteString ?? "nil")"
            )
            isReaderModeLoading = false
        }
    }

    @MainActor
    public func beginReaderModeLoad(for url: URL, suppressSpinner: Bool = false) {
        var isContinuing = false
        if let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(url) {
            // already tracking this load
            isContinuing = true
        } else {
            updatePendingReaderModeURL(url, reason: "beginLoad")
            lastRenderedReadabilityURL = nil
            lastFallbackLoaderURL = nil
        }
        let trackedURL = pendingReaderModeURL ?? url
        debugPrint(
            "# READER readerMode.beginLoad",
            "url=\(trackedURL.absoluteString)",
            "continuing=\(isContinuing)",
            "suppressSpinner=\(suppressSpinner)",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")"
        )
        logTrace(
            .begin,
            url: trackedURL,
            captureStart: !isContinuing,
            details: isContinuing ? "continuing pending load" : "starting new load"
        )
        if !suppressSpinner {
            readerModeLoading(true)
        }
    }

    @MainActor
    public func cancelReaderModeLoad(for url: URL? = nil) {
        guard let pendingReaderModeURL else {
            debugPrint(
                "# READER readerMode.cancel",
                "url=\(url?.absoluteString ?? "nil")",
                "reason=noPending"
            )
            logTrace(.cancel, url: url, details: "no pending load to cancel")
            if url == nil {
                readerModeLoading(false)
            }
            return
        }
        if let url, !pendingReaderModeURL.matchesReaderURL(url) {
            debugPrint(
                "# READER readerMode.cancel",
                "url=\(url.absoluteString)",
                "reason=pendingMismatch",
                "pending=\(pendingReaderModeURL.absoluteString)"
            )
            logTrace(.cancel, url: url, details: "cancel ignored: pending load is for \(pendingReaderModeURL.absoluteString)")
            return
        }
        debugPrint(
            "# READER readerMode.cancel",
            "url=\(pendingReaderModeURL.absoluteString)",
            "reason=requested",
            "caller=\(url?.absoluteString ?? "nil")"
        )
        let traceURL = pendingReaderModeURL
        updatePendingReaderModeURL(nil, reason: "cancelReaderModeLoad")
        logTrace(.cancel, url: traceURL, details: "cancelReaderModeLoad invoked")
        readerModeLoading(false)
    }

    @MainActor
    public func markReaderModeLoadComplete(for url: URL) {
        guard let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(url) else {
            let pendingDescription = self.pendingReaderModeURL?.absoluteString ?? "nil"
            let readabilityBytes = readabilityContent?.utf8.count ?? 0
            let pendingState = self.pendingReaderModeURL == nil ? "noPending" : "pendingMismatch"
            debugPrint(
                "# READER readerMode.complete.skip",
                "url=\(url.absoluteString)",
                "pending=\(pendingDescription)",
                "pendingState=\(pendingState)",
                "isReaderMode=\(isReaderMode)",
                "isReaderModeLoading=\(isReaderModeLoading)",
                "readabilityBytes=\(readabilityBytes)",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
                "lastFallback=\(lastFallbackLoaderURL?.absoluteString ?? "nil")",
                "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")"
            )
            return
        }
        let traceURL = pendingReaderModeURL
        updatePendingReaderModeURL(nil, reason: "markReaderModeLoadComplete")
        debugPrint(
            "# READER readerMode.complete",
            "url=\(traceURL.absoluteString)"
        )
        logTrace(.complete, url: traceURL, details: "markReaderModeLoadComplete")
        readerModeLoading(false)
        readerModeLoadCompletionHandler?(traceURL)
    }

    @MainActor
    public func isReaderModeLoadPending(for url: URL) -> Bool {
        guard let pendingReaderModeURL else { return false }
        return pendingReaderModeURL.matchesReaderURL(url)
    }
    
    func isReaderModeHandlingURL(_ url: URL) -> Bool {
        if let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(url) {
            return true
        }
        if let lastRenderedReadabilityURL, lastRenderedReadabilityURL.matchesReaderURL(url) {
            return true
        }
        return false
    }

//    @MainActor
//    public func invalidateLastRenderedReadabilityURL() {
//        debugPrint("# FLASH ReaderModeViewModel.invalidateLastRenderedReadabilityURL clearing", lastRenderedReadabilityURL?.absoluteString ?? "nil")
//        lastRenderedReadabilityURL = nil
//        lastFallbackLoaderURL = nil
//    }
    
    public func isReaderModeButtonAvailable(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && content.isReaderModeAvailable && !content.isReaderModeByDefault
    }
    
    public init() { }
    
    func isReaderModeLoadPending(content: any ReaderContentProtocol) -> Bool {
        if let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(content.url) {
            return true
        }
        return !isReaderMode && content.isReaderModeAvailable && content.isReaderModeByDefault
    }
    
    @MainActor
    public func showReaderView(readerContent: ReaderContent, scriptCaller: WebViewScriptCaller) {
        debugPrint("# FLASH ReaderModeViewModel.showReaderView invoked", readerContent.pageURL)
        let readabilityBytes = readabilityContent?.utf8.count ?? 0
        logTrace(.readabilityTaskScheduled, url: readerContent.pageURL, details: "readabilityBytes=\(readabilityBytes)")
        let contentURL = readerContent.pageURL
        guard let readabilityContent else {
            // FIME: WHY THIS CALLED WHEN LOAD??
            debugPrint("# FLASH ReaderModeViewModel.showReaderView missing readabilityContent", readerContent.pageURL)
            debugPrint("# READER readability.missingContent", "url=\(readerContent.pageURL.absoluteString)")
            cancelReaderModeLoad(for: readerContent.pageURL)
            return
        }
        let readabilityPreview = snippetPreview(readabilityContent, maxLength: 360)
        debugPrint(
            "# READER readability.renderHTML",
            "url=\(contentURL.absoluteString)",
            "bytes=\(readabilityBytes)",
            "preview=\(readabilityPreview)"
        )
        beginReaderModeLoad(for: contentURL)
        Task { @MainActor in
            guard urlsMatchWithoutHash(contentURL, readerContent.pageURL) else {
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
            print("No content set to show in reader mode")
            cancelReaderModeLoad(for: readerContent.pageURL)
            return
        }
        let url = content.url
        if url.isSnippetURL {
            debugPrint(
                "# READER snippet.renderStart",
                "contentURL=\(url.absoluteString)",
                "readabilityBytes=\(readabilityContent.utf8.count)",
                "frameIsMain=\(frameInfo?.isMainFrame ?? true)",
                "renderSelector=\(renderToSelector ?? "<root>")"
            )
        }
        let renderBaseURL: URL
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            renderBaseURL = url
        } else if let loaderURL = ReaderContentLoader.readerLoaderURL(for: url) {
            renderBaseURL = loaderURL
        } else {
            renderBaseURL = readerContent.pageURL
        }
        debugPrint(
            "# READER readability.renderBase",
            "contentURL=\(url.absoluteString)",
            "renderBase=\(renderBaseURL.absoluteString)",
            "frameIsMain=\(frameInfo?.isMainFrame ?? true)"
        )
        let renderTarget = renderToSelector ?? "<root>"
        logTrace(.readabilityProcessingStart, url: url, details: "renderTo=\(renderTarget) | frameIsMain=\(frameInfo?.isMainFrame ?? true)")

        if let lastRenderedReadabilityURL, lastRenderedReadabilityURL.matchesReaderURL(url) {
            markReaderModeLoadComplete(for: url)
            return
        }

        if lastFallbackLoaderURL != nil {
            self.lastFallbackLoaderURL = nil
        }
        
        Task {
            do {
                debugPrint("# READER readability.datasetFlag", "url=\(url.absoluteString)")
                try await scriptCaller.evaluateJavaScript("""
                if (document.body) {
                    document.body.dataset.isNextLoadInReaderMode = 'true';
                }
                """)
            } catch {
                debugPrint("# FLASH ReaderModeViewModel.showReadabilityContent dataset flag failed", error.localizedDescription)
            }
        }
        
        let asyncWriteStartedAt = Date()
        logTrace(.contentWriteStart, url: url, details: "marking reader defaults")
        try await content.asyncWrite { [weak self] _, content in
            content.isReaderModeByDefault = true
            content.isReaderModeAvailable = false
            if !url.isEBookURL && !url.isFileURL && !url.isNativeReaderView {
                if !url.isReaderFileURL && (content.content?.isEmpty ?? true) {
                    if url.isSnippetURL {
                        guard let self else { return }
                        let oldPreview = snippetPreview(content.html ?? "")
                        let newPreview = snippetPreview(readabilityContent)
                        debugPrint(
                            "# READER snippetUpdate.content",
                            "url=\(url.absoluteString)",
                            "oldPreview=\(oldPreview)",
                            "newPreview=\(newPreview)",
                            "newBytes=\(readabilityContent.utf8.count)"
                        )
                    }
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
                doc = await processReadabilityContent(
                    readabilityContent,
                    url,
                    nil,
                    false,
                    { doc in
                        do {
                            return try await preprocessWebContentForReaderMode(
                                doc: doc,
                                url: url,
                                fallbackTitle: titleForDisplay
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
            debugPrint(
                "# READER readability.contentPrepared",
                "url=\(url.absoluteString)",
                "bytes=\(transformedContent.utf8.count)",
                "frameIsMain=\(frameInfo?.isMainFrame ?? true)"
            )
            if let bodySummary = summarizeBodyMarkup(from: transformedContent) {
                debugPrint(
                    "# READER readability.renderBody",
                    "url=\(url.absoluteString)",
                    "body=\(bodySummary)"
                )
            }
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
                        try {
                            const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.print
                            if (handler) {
                                handler.postMessage({
                                    message: "# READER snippetLoader.injected",
                                    context: "frame",
                                    targetSelector: renderToSelector || "<root>",
                                    htmlBytes: insertBytes,
                                    windowURL: window.location.href,
                                    pageURL: document.location.href
                                })
                            }
                        } catch (error) {
                            try { console.log("snippetLoader.injected log error", error) } catch (_) {}
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
                            "insertBytes": transformedContent.utf8.count,
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
                    let transformedBytes = transformedContent.utf8.count
                    let transformedPreview = snippetPreview(transformedContent, maxLength: 240)
                    debugPrint(
                        "# READER readability.navigatorLoad",
                        "url=\(url.absoluteString)",
                        "base=\(renderBaseURL.absoluteString)",
                        "bytes=\(transformedBytes)"
                    )
                    debugPrint(
                        "# READER readability.navigatorLoad.preview",
                        "url=\(url.absoluteString)",
                        "bytes=\(transformedBytes)",
                        "preview=\(transformedPreview)"
                    )
                    logTrace(.navigatorLoad, url: url, details: "mode=readability-html | bytes=\(transformedBytes)")
                    expectSyntheticReaderLoaderCommit(for: renderBaseURL)
                    navigator.load(
                        htmlData,
                        mimeType: "text/html",
                        characterEncodingName: "UTF-8",
                        baseURL: renderBaseURL
                    )
                    debugPrint(
                        "# READER readability.navigatorLoad.dispatched",
                        "url=\(url.absoluteString)",
                        "base=\(renderBaseURL.absoluteString)",
                        "bytes=\(transformedBytes)"
                    )
                    if url.isSnippetURL {
                        let preview = snippetPreview(transformedContent, maxLength: 240) ?? "<empty>"
                        debugPrint(
                            "# READER snippetLoader.navigatorLoad",
                            "contentURL=\(url.absoluteString)",
                            "base=\(renderBaseURL.absoluteString)",
                            "bytes=\(transformedContent.utf8.count)",
                            "preview=\(preview)"
                        )
                        injectSnippetLoaderProbe(scriptCaller: scriptCaller, baseURL: renderBaseURL)
                    }
                } else {
                    print("ReaderModeViewModel: readability HTML data missing for", url.absoluteString)
                    debugPrint("# READER readability.navigatorLoad missingData", "url=\(url.absoluteString)")
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

    private nonisolated func summarizeBodyMarkup(from html: String, maxLength: Int = 360) -> String? {
        guard let bodyRange = html.range(of: "<body", options: [.caseInsensitive]) else {
            return nil
        }
        let start = bodyRange.lowerBound
        guard let openTagEnd = html[start...].firstIndex(of: ">") else { return nil }
        let afterOpen = html.index(after: openTagEnd)
        let searchRange = afterOpen..<html.endIndex
        let closingRange = html.range(of: "</body", options: [.caseInsensitive], range: searchRange)
        let end: String.Index
        if let closingRange,
           let closingGT = html[closingRange.lowerBound...].firstIndex(of: ">") {
            end = html.index(after: closingGT)
        } else {
            end = html.endIndex
        }
        var snippet = String(html[start..<end])
        snippet = snippet.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        snippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if snippet.count > maxLength {
            let idx = snippet.index(snippet.startIndex, offsetBy: maxLength)
            snippet = String(snippet[..<idx]) + "…"
        }
        return snippet.isEmpty ? nil : snippet
    }

    private func snippetPreview(_ html: String, maxLength: Int = 360) -> String {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "<empty>" }
        if trimmed.count <= maxLength { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return String(trimmed[..<idx]) + "…"
    }

    private func logDomSnapshot(
        pageURL: URL,
        scriptCaller: WebViewScriptCaller,
        reason: String
    ) {
        Task { @MainActor [weak scriptCaller] in
            guard let scriptCaller else { return }
            do {
                if let jsonString = try await scriptCaller.evaluateJavaScript(
                    """
                    (function () {
                        const body = document.body;
                        const readerContent = document.getElementById("reader-content");
                        const bodyHTMLBytes = body && typeof body.innerHTML === "string" ? body.innerHTML.length : 0;
                        const bodyTextBytes = body && typeof body.textContent === "string" ? body.textContent.length : 0;
                        const readerContentHTMLBytes = readerContent && typeof readerContent.innerHTML === "string" ? readerContent.innerHTML.length : 0;
                        const readerContentTextBytes = readerContent && typeof readerContent.textContent === "string" ? readerContent.textContent.length : 0;
                        const payload = {
                            hasBody: !!body,
                            bodyHTMLBytes,
                            bodyTextBytes,
                            hasReaderContent: !!readerContent,
                            readerContentHTMLBytes,
                            readerContentTextBytes,
                            readyState: document.readyState,
                            windowURL: window.location.href,
                            bodyPreview: body && typeof body.innerHTML === "string" ? body.innerHTML.slice(0, 240) : null,
                            readerContentPreview: readerContent && typeof readerContent.textContent === "string" ? readerContent.textContent.slice(0, 240) : null
                        };
                        return JSON.stringify(payload);
                    })();
                    """
                ) as? String,
                   let data = jsonString.data(using: .utf8) {
                    do {
                        let domInfo = try JSONSerialization.jsonObject(with: data)
                        debugPrint("# READER readerMode.domSnapshot", "reason=\(reason)", "pageURL=\(pageURL.absoluteString)", "info=\(domInfo)")
                    } catch {
                        let preview = String(jsonString.prefix(240))
                        debugPrint(
                            "# READER readerMode.domSnapshot",
                            "reason=\(reason)",
                            "pageURL=\(pageURL.absoluteString)",
                            "info=<invalid json>",
                            "rawPreview=\(preview)"
                        )
                    }
                } else {
                    debugPrint("# READER readerMode.domSnapshot", "reason=\(reason)", "pageURL=\(pageURL.absoluteString)", "info=<serialization failed>")
                }
            } catch {
                debugPrint("# FLASH ReaderModeViewModel.domSnapshot failed", reason, error.localizedDescription)
            }
        }
    }
    
    @MainActor
    private func injectSnippetLoaderProbe(
        scriptCaller: WebViewScriptCaller,
        baseURL: URL
    ) {
        Task { @MainActor [weak scriptCaller] in
            guard let scriptCaller else { return }
            do {
                debugPrint("# READER snippetLoader.injectProbe.injecting", "baseURL=\(baseURL.absoluteString)")
                try await scriptCaller.evaluateJavaScript(
                    """
                    (function () {
                        const logState = () => {
                            try {
                                const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.print
                                if (!handler || typeof handler.postMessage !== "function") {
                                    return
                                }
                                const readerContent = document.getElementById("reader-content")
                                const body = document.body
                                const bodyHTMLBytes = body && typeof body.innerHTML === "string" ? body.innerHTML.length : 0
                                const bodyTextBytes = body && typeof body.textContent === "string" ? body.textContent.length : 0
                                const readerContentHTMLBytes = readerContent && typeof readerContent.innerHTML === "string" ? readerContent.innerHTML.length : 0
                                const readerContentTextBytes = readerContent && typeof readerContent.textContent === "string" ? readerContent.textContent.length : 0
                                handler.postMessage({
                                    message: "# READER snippetLoader.injectProbe",
                                    stage: document.readyState,
                                    hasBody: !!body,
                                    bodyHTMLBytes,
                                    bodyTextBytes,
                                    hasReaderContent: !!readerContent,
                                    readerContentHTMLBytes,
                                    readerContentTextBytes,
                                    bodyPreview: body && typeof body.innerHTML === "string" ? body.innerHTML.slice(0, 240) : null,
                                    readerContentPreview: readerContent && typeof readerContent.textContent === "string" ? readerContent.textContent.slice(0, 240) : null,
                                    windowURL: window.location.href,
                                    pageURL: document.location.href
                                })
                            } catch (error) {
                                try { console.log("snippetLoader.injectProbe error", error) } catch (_) {}
                            }
                        }
                        logState()
                        document.addEventListener("readystatechange", logState)
                    })();
                    """
                )
            } catch {
                debugPrint("# FLASH ReaderModeViewModel.injectSnippetProbe error", error.localizedDescription)
            }
        }
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

        let isLoaderNavigation = newState.pageURL.isReaderURLLoaderURL

        if consumeSyntheticReaderLoaderExpectationIfNeeded(for: newState.pageURL) {
            if let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(committedURL) {
                markReaderModeLoadComplete(for: committedURL)
            }
            return
        }

        let isSnippetContent = committedURL.isSnippetURL
        let isSnippetPage = newState.pageURL.isSnippetURL
        if isSnippetContent && isSnippetPage {
            debugPrint(
                "# READER snippet.navCommit",
                "pageURL=\(newState.pageURL.absoluteString)",
                "contentURL=\(committedURL.absoluteString)",
                "loaderPending=\(pendingReaderModeURL?.absoluteString ?? "nil")"
            )
            return
        }

        if isLoaderNavigation {
            debugPrint(
                "# READER readerMode.loaderCommit",
                "loaderURL=\(newState.pageURL.absoluteString)",
                "contentURL=\(committedURL.absoluteString)",
                "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")"
            )
        }

        // FIXME: Mokuro? check plugins thing for reader mode url instead of hardcoding methods here
        let isReaderModeVerified = content.isReaderModeByDefault
        try Task.checkCancellation()

        if isLoaderNavigation,
           pendingReaderModeURL == nil,
           let lastRenderedReadabilityURL,
           lastRenderedReadabilityURL.matchesReaderURL(committedURL) {
            debugPrint(
                "# FLASH ReaderModeViewModel.onNavigationCommitted skipping redundant reader loader navigation",
                newState.pageURL,
                "for",
                committedURL
            )
            return
        }

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

        if isLoaderNavigation {
            debugPrint("# FLASH ReaderModeViewModel.onNavigationCommitted reader loader url", committedURL)
            if let readerFileManager {
                logTrace(.htmlFetchStart, url: committedURL, details: "readerFileManager available")
                let htmlFetchStartedAt = Date()
                var htmlResult = try await content.htmlToDisplay(readerFileManager: readerFileManager)
                let fetchDuration = formattedInterval(Date().timeIntervalSince(htmlFetchStartedAt))
                let htmlByteCount = htmlResult?.utf8.count ?? 0
                var htmlBodyIsEmpty = false
                if
                    let html = htmlResult,
                    let bodyInnerHTML = bodyInnerHTML(from: html)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    bodyInnerHTML.isEmpty
                {
                    htmlBodyIsEmpty = true
                    let preview = snippetPreview(html, maxLength: 160)
                    debugPrint(
                        "# READER readability.htmlFetched.emptyBody",
                        "url=\(committedURL.absoluteString)",
                        "bytes=\(htmlByteCount)",
                        "preview=\(preview)",
                        "rssFull=\(content.rssContainsFullContent)",
                        "readerDefault=\(content.isReaderModeByDefault)",
                        "compressedBytes=\(content.content?.count ?? 0)"
                    )
                    await invalidateReaderModeCache(
                        for: content,
                        url: committedURL,
                        reason: "emptyBodyAfterDecompress"
                    )
                    htmlResult = nil
                }
                let traceDetails = [
                    "bytes=\(htmlByteCount)",
                    "duration=\(fetchDuration)",
                    "emptyBody=\(htmlBodyIsEmpty)"
                ].joined(separator: " | ")
                logTrace(.htmlFetchEnd, url: committedURL, details: traceDetails)
                if var html = htmlResult {
                    if !htmlBodyIsEmpty {
                        debugPrint(
                            "# READER readability.htmlFetched",
                            "url=\(committedURL.absoluteString)",
                            "bytes=\(html.utf8.count)"
                        )
                    }
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

                    let hasReadabilityMarkup = html.range(of: #"<body.*?class=['"].*?readability-mode.*?['"]>"#, options: .regularExpression) != nil || html.range(of: #"<body.*?data-is-next-load-in-reader-mode=['"]true['"]>"#, options: .regularExpression) != nil
                    let isSnippetURL = committedURL.isSnippetURL
                    let snippetHasReaderContent = isSnippetURL && html.range(of: #"id=['"]reader-content['"]"#, options: .regularExpression) != nil
                    if snippetHasReaderContent {
                        debugPrint(
                            "# READER snippet.readerContentUnexpected",
                            "url=\(committedURL.absoluteString)",
                            "notice=snippetShouldNotIncludeReaderContent"
                        )
                    }
                    let shouldUseReadability = hasReadabilityMarkup
                    debugPrint(
                        "# FLASH ReaderModeViewModel.onNavigationCommitted readabilityDecision",
                        committedURL,
                        "hasReadabilityMarkup=",
                        hasReadabilityMarkup,
                        "isSnippetURL=",
                        isSnippetURL,
                        "shouldUseReadability=",
                        shouldUseReadability
                    )
                    debugPrint(
                        "# READER readability.decision",
                        "url=\(committedURL.absoluteString)",
                        "hasMarkup=\(hasReadabilityMarkup)",
                        "snippet=\(isSnippetURL)",
                        "shouldUse=\(shouldUseReadability)"
                    )

                    if shouldUseReadability {
                        readabilityContent = html
                        debugPrint(
                            "# READER readability.captured",
                            "url=\(committedURL.absoluteString)",
                            "snippet=\(isSnippetURL)",
                            "hasMarkup=\(hasReadabilityMarkup)",
                            "bytes=\(html.utf8.count)"
                        )
                        let details = "hasReadabilityMarkup=\(hasReadabilityMarkup) | snippet=\(isSnippetURL)"
                        logTrace(.readabilityContentReady, url: committedURL, details: details)
                        debugPrint("# FLASH ReaderModeViewModel.onNavigationCommitted readabilityContent captured", committedURL)
                        showReaderView(
                            readerContent: readerContent,
                            scriptCaller: scriptCaller
                        )
                        lastFallbackLoaderURL = nil
                    } else {
                        if isSnippetURL {
                            debugPrint(
                                "# READER snippet.readabilityBypass",
                                "url=\(committedURL.absoluteString)",
                                "reason=missingReadabilityMarkup"
                            )
                        }
                        if let _ = html.range(of: "<body", options: .caseInsensitive) {
                            html = html.replacingOccurrences(of: "<body", with: "<body data-is-next-load-in-reader-mode='true' ", options: .caseInsensitive)
                        } else {
                            html = "<body data-is-next-load-in-reader-mode='true'>\n" + html + "</html>"
                        }
                        try Task.checkCancellation()
                        if let htmlData = html.data(using: .utf8) {
                            debugPrint("# FLASH ReaderModeViewModel.onNavigationCommitted navigator.load fallback html", committedURL)
                            Task { @MainActor in
                                expectSyntheticReaderLoaderCommit(for: committedURL)
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
                    expectSyntheticReaderLoaderCommit(for: nil)
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
                expectSyntheticReaderLoaderCommit(for: nil)
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
        let isLoaderURL = newState.pageURL.isReaderURLLoaderURL
        if !isLoaderURL {
            if newState.pageURL.isNativeReaderView, pendingReaderModeURL != nil {
                // about:blank or native placeholder during the reader-mode bootstrap; keep loading state.
                return
            }
            do {
                let isNextReaderMode = (
                    try await scriptCaller.evaluateJavaScript(
                        """
                        (function () {
                            const body = document.body;
                            if (!body || !body.dataset) { return false; }
                            return body.dataset.isNextLoadInReaderMode === 'true';
                        })();
                        """
                    ) as? Bool
                ) ?? false
                if !isNextReaderMode {
                    if let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(newState.pageURL) {
                        // Keep the spinner alive until the reader-mode initialization finishes.
                    } else {
                        readerModeLoading(false)
                    }
                }
            } catch {
                debugPrint("# FLASH ReaderModeViewModel.onNavigationFinished JS failed", error.localizedDescription)
                if let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(newState.pageURL) {
                    cancelReaderModeLoad(for: newState.pageURL)
                } else {
                    readerModeLoading(false)
                }
            }
        }
        logDomSnapshot(pageURL: newState.pageURL, scriptCaller: scriptCaller, reason: isLoaderURL ? "loader-navFinished" : "navFinished")
        Task { [weak scriptCaller] in
            try await Task.sleep(nanoseconds: 300_000_000)
            guard let scriptCaller else { return }
            logDomSnapshot(pageURL: newState.pageURL, scriptCaller: scriptCaller, reason: isLoaderURL ? "loader-navFinished+300ms" : "navFinished+300ms")
        }
    }

    @MainActor
    public func onNavigationFailed(newState: WebViewState) {
        debugPrint("# FLASH ReaderModeViewModel.onNavigationFailed", newState.pageURL)
        cancelReaderModeLoad(for: newState.pageURL)
    }
    
    @MainActor
    public func onNavigationError(
        pageURL: URL,
        error: Error,
        isProvisional: Bool
    ) {
        debugPrint(
            "# READER readerMode.navigationError",
            "pageURL=\(pageURL.absoluteString)",
            "provisional=\(isProvisional)",
            "error=\(error.localizedDescription)"
        )
        cancelReaderModeLoad(for: pageURL)
    }
}

fileprivate let readerFontSizeStylePattern = #"(?i)(<body[^>]*\bstyle="[^"]*)font-size:\s*[\d.]+px"#
fileprivate let readerFontSizeStyleRegex = try! NSRegularExpression(pattern: readerFontSizeStylePattern, options: .caseInsensitive)

fileprivate let bodyStylePattern = #"(?i)(<body[^>]*\bstyle=")([^"]*)(")"#
fileprivate let bodyStyleRegex = try! NSRegularExpression(pattern: bodyStylePattern, options: .caseInsensitive)

fileprivate let bodyInnerHTMLRegex = try! NSRegularExpression(pattern: #"(?is)<body[^>]*>(.*?)</body>"#)

fileprivate func bodyInnerHTML(from html: String) -> String? {
    let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
    guard
        let match = bodyInnerHTMLRegex.firstMatch(in: html, options: [], range: nsRange),
        match.numberOfRanges > 1,
        let range = Range(match.range(at: 1), in: html)
    else {
        return nil
    }
    return String(html[range])
}

@MainActor
fileprivate func invalidateReaderModeCache(
    for content: any ReaderContentProtocol,
    url: URL,
    reason: String
) async {
    let compressedBytes = content.content?.count ?? 0
    debugPrint(
        "# READER readability.cache.invalidate",
        "url=\(url.absoluteString)",
        "compressedBytes=\(compressedBytes)",
        "reason=\(reason)",
        "readerDefault=\(content.isReaderModeByDefault)",
        "rssFull=\(content.rssContainsFullContent)"
    )
    do {
        try await content.asyncWrite { _, record in
            record.content = nil
            if !url.isSnippetURL {
                record.rssContainsFullContent = false
                record.isReaderModeByDefault = false
                record.isReaderModeAvailable = false
            }
            record.refreshChangeMetadata(explicitlyModified: true)
        }
    } catch {
        debugPrint(
            "# FLASH ReaderModeViewModel.invalidateReaderModeCache failed",
            url.absoluteString,
            error.localizedDescription
        )
    }
}

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
    url: URL,
    fallbackTitle: String? = nil
) throws -> SwiftSoup.Document {
    transformContentSpecificToFeed(doc: doc, url: url)
    do {
        try wireViewOriginalLinks(doc: doc, url: url)
    } catch { }
    
    if let fallbackTitle, !fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if let titleElement = try doc.getElementById("reader-title") {
            let currentTitleText = try titleElement.text(trimAndNormaliseWhitespace: false)
            if currentTitleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try titleElement.text(fallbackTitle)
                if let headTitle = try doc.head()?.getElementsByTag("title").first() {
                    let currentHeadTitle = try headTitle.text()
                    if currentHeadTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        try headTitle.text(fallbackTitle)
                    }
                }
            }
        }
    }
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
