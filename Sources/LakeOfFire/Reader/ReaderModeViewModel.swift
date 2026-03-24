import SwiftUI
import SwiftUIWebView
import SwiftSoup
import SwiftReadability
import CryptoKit
import RealmSwift
import Combine
import RealmSwiftGaps
import LakeKit
import WebKit

@globalActor
fileprivate actor ReaderViewModelActor {
    static let shared = ReaderViewModelActor()
}

private func stripTemplateTagsForSanitize(_ html: String) -> String {
    guard html.range(of: "<template", options: .caseInsensitive) != nil else {
        return html
    }
    return html.replacingOccurrences(
        of: #"(?is)<template\b[^>]*>.*?</template>"#,
        with: "",
        options: .regularExpression
    )
}

private func sanitizeReadabilityFragment(_ html: String) -> String {
    stripTemplateTagsForSanitize(html)
}

private extension URL {
    func canonicalReaderContentURLForHotfix() -> URL {
        ReaderContentLoader.getContentURL(fromLoaderURL: self) ?? self
    }

    func removingFragmentIfNeededForHotfix() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              components.fragment != nil else {
            return self
        }
        components.fragment = nil
        return components.url ?? self
    }
}

private func urlsMatchWithoutHashForHotfix(_ lhs: URL?, _ rhs: URL?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case let (.some(lhsURL), .some(rhsURL)):
        if lhsURL == rhsURL {
            return true
        }
        return lhsURL.removingFragmentIfNeededForHotfix() == rhsURL.removingFragmentIfNeededForHotfix()
    default:
        return false
    }
}

private func readerFontPayloadHash(_ payload: String) -> String {
    let digest = SHA256.hash(data: Data(payload.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

internal func upsertDeferredSharedReaderFontGate(in doc: SwiftSoup.Document) throws {
    let gateCSS = """
    html[data-manabi-font-pending="1"] body.readability-mode {
        visibility: hidden !important;
    }
    """

    let htmlElement = try doc.getElementsByTag("html").first()
    try htmlElement?.attr("data-manabi-font-pending", "1")
    try htmlElement?.attr("data-manabi-font-ready", "0")

    if let existingStyle = try doc.getElementById("manabi-custom-font-gate") {
        try existingStyle.text(gateCSS)
        return
    }

    let styleElement = try doc.createElement("style")
    try styleElement.attr("id", "manabi-custom-font-gate")
    try styleElement.text(gateCSS)

    if let head = doc.head() {
        try head.appendChild(styleElement)
        return
    }

    if let html = try doc.getElementsByTag("html").first() {
        try html.prepend("<head></head>")
        if let head = doc.head() {
            try head.appendChild(styleElement)
            return
        }
    }

    try doc.appendChild(styleElement)
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
            \(lookupSmAR15InlineProbeHTML(context: "canonical-readability", url: contentURL))
            <script>
                \(Readability.shared.scripts)
            </script>
        </body>
    </html>
    """
}

fileprivate func lookupSmAR15InlineProbeHTML(context: String, url: URL?) -> String {
    let urlString = escapeReadabilityText(url?.absoluteString ?? "nil")
    let escapedContext = escapeReadabilityText(context)
    return """
    <script>
    (function () {
        function post(prefix) {
            try {
                window.webkit?.messageHandlers?.print?.postMessage({
                    message: '# LOOKUPSMAR15 ' + prefix
                });
            } catch {}
        }
        function collect(label) {
            try {
                post(
                    label
                    + ' context=\(escapedContext)'
                    + ' url=\(urlString)'
                    + ' ready=' + document.readyState
                    + ' body=' + !!document.body
                    + ' inlineHTML=' + (document.documentElement?.getAttribute('data-lookupsmar15-inline-probe') ?? 'nil')
                    + ' inlineBody=' + (document.body?.getAttribute('data-lookupsmar15-inline-probe') ?? 'nil')
                    + ' scriptLoaded=' + (document.documentElement?.getAttribute('data-lookupsmar15-script-loaded') ?? 'nil')
                    + ' hasLookupNext=' + typeof window.manabi_lookupNextSegmentMatch
                    + ' hasLookupPrev=' + typeof window.manabi_lookupPreviousSegmentMatch
                    + ' hasReprocess=' + typeof window.manabi_reprocessJapanese
                    + ' hasInit=' + typeof window.manabiReaderInitialized
                    + ' hasButtonsStore=' + typeof document.manabi_markAsReadButtonsWired
                    + ' segmentCount=' + document.getElementsByTagName('manabi-segment').length
                    + ' buttonCount=' + document.querySelectorAll('button.manabi-tracking-button').length
                );
            } catch (error) {
                post('inline-collect-error context=\(escapedContext) error=' + String(error));
            }
        }
        try {
            document.documentElement?.setAttribute('data-lookupsmar15-inline-probe', '\(escapedContext)');
            document.body?.setAttribute('data-lookupsmar15-inline-probe', '\(escapedContext)');
            collect('inline-probe');
            setTimeout(function () { collect('inline-probe-timeout-0'); }, 0);
            setTimeout(function () { collect('inline-probe-timeout-100'); }, 100);
            document.addEventListener('DOMContentLoaded', function handleDOMContentLoaded() {
                document.removeEventListener('DOMContentLoaded', handleDOMContentLoaded);
                collect('inline-probe-domcontentloaded');
            });
            window.addEventListener('load', function handleLoad() {
                window.removeEventListener('load', handleLoad);
                collect('inline-probe-load');
            });
        } catch (error) {
            post('inline-probe-error context=\(escapedContext) error=' + String(error));
        }
    })();
    </script>
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
        return rebuildCanonicalSnippetReadabilityHTML(
            html: normalizedHTML,
            contentURL: contentURL,
            fallbackTitle: fallbackTitle
        )
    }
    guard let rawContent = bodyInnerHTML(from: normalizedHTML)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawContent.isEmpty else {
        return nil
    }
    let sanitizedTitle = sanitizeReadabilityFragment(fallbackTitle ?? "")
    let sanitizedContent = sanitizeReadabilityFragment(rawContent)
    guard !sanitizedContent.isEmpty else {
        return nil
    }
    return buildCanonicalReadabilityHTML(
        title: sanitizedTitle,
        byline: "",
        publishedTime: nil,
        content: sanitizedContent,
        contentURL: contentURL.canonicalReaderContentURLForHotfix()
    )
}

private func rebuildCanonicalSnippetReadabilityHTML(
    html: String,
    contentURL: URL,
    fallbackTitle: String?
) -> String? {
    guard let document = try? SwiftSoup.parse(html) else {
        return nil
    }
    let extractedTitle = (try? document.getElementById("reader-title")?.text(trimAndNormaliseWhitespace: false))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let extractedByline = (try? document.getElementById("reader-byline")?.text(trimAndNormaliseWhitespace: false))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let extractedContent = (try? document.getElementById("reader-content")?.html())
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard let extractedContent, !extractedContent.isEmpty else {
        return nil
    }

    let sanitizedTitle = sanitizeReadabilityFragment(extractedTitle ?? fallbackTitle ?? "")
    let sanitizedByline = sanitizeReadabilityFragment(extractedByline ?? "")
    let sanitizedContent = sanitizeReadabilityFragment(extractedContent)
    guard !sanitizedContent.isEmpty else {
        return nil
    }

    return buildCanonicalReadabilityHTML(
        title: sanitizedTitle,
        byline: sanitizedByline,
        publishedTime: nil,
        content: sanitizedContent,
        contentURL: contentURL.canonicalReaderContentURLForHotfix()
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
    public var ebookTextProcessorCacheHits: ((URL, String) async throws -> Bool)? = nil
    public var processReadabilityContent: ((String, URL, URL?, Bool, ((SwiftSoup.Document) async -> SwiftSoup.Document)) async -> SwiftSoup.Document)? = nil
    public var processHTML: ((String, Bool) async -> String)? = nil
    public var navigator: WebViewNavigator?
    public var defaultFontSize: Double?
    public var sharedFontCSSBase64: String?
    public var sharedFontCSSBase64Provider: (() async -> String?)?
    public var readerModeLoadCompletionHandler: ((URL) -> Void)?
    
    @Published public var isReaderMode = false
    @Published public var isReaderModeLoading = false
    @Published public private(set) var lastRenderedURL: URL?
    @Published public private(set) var expectedSyntheticReaderLoaderURL: URL?
    @Published public private(set) var pendingReaderModeURL: URL?
    @Published var readabilityContent: String? = nil
    @Published var readabilityContainerSelector: String? = nil
    @Published var readabilityContainerFrameInfo: WKFrameInfo? = nil
    @Published var readabilityFrames = Set<WKFrameInfo>()

    public var hasRenderedReadabilityContent: Bool { lastRenderedURL != nil }
    
//    @Published var contentRules: String? = nil

    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    private var lastFallbackLoaderURL: URL?
    private var loadTraceRecords: [String: ReaderModeLoadTraceRecord] = [:]
    private var loadStartTimes: [String: Date] = [:]
    private var activeRenderTaskByURL: [String: Task<Void, Never>] = [:]
    private var activeRenderGenerationByURL: [String: UUID] = [:]
    private var metadataRefreshTaskByURL: [String: Task<Void, Never>] = [:]
    private var metadataRefreshGenerationByURL: [String: UUID] = [:]

    private struct ReaderModeLoadTraceRecord {
        var startedAt: Date
        var lastEventAt: Date
    }

    private enum ReaderModeLoadStage: String {
        case begin
        case navCommitted
        case readabilityTaskScheduled
        case navigatorLoad
        case cancel
        case complete
        case navFinished

        var isTerminal: Bool {
            switch self {
            case .cancel, .complete:
                return true
            default:
                return false
            }
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
            isReaderModeLoading = true
            if !isReaderMode {
                lastRenderedURL = nil
            }
        } else if !isLoading && isReaderModeLoading {
            isReaderModeLoading = false
        }
    }

    @MainActor
    public func beginReaderModeLoad(for url: URL, suppressSpinner: Bool = false, reason: String? = nil) {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        let pendingMatches = pendingReaderModeURL.map { pendingKeysMatch($0, canonicalURL) } ?? false
        if !pendingMatches {
            updatePendingReaderModeURL(canonicalURL, reason: "beginLoad")
            lastFallbackLoaderURL = nil
        }
        if let rendered = lastRenderedURL, !pendingKeysMatch(rendered, canonicalURL) {
            lastRenderedURL = nil
        }
        debugPrint(
            "# READERRELOAD beginLoad",
            "url=\(canonicalURL.absoluteString)",
            "reason=\(reason ?? "nil")",
            "suppressSpinner=\(suppressSpinner)",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "rendered=\(lastRenderedURL?.absoluteString ?? "nil")"
        )
        logStateSnapshot("beginLoad", url: canonicalURL)
        logTrace(.begin, url: canonicalURL, captureStart: !pendingMatches, details: reason)
        loadStartTimes[(pendingReaderModeURL ?? canonicalURL).absoluteString] = Date()
        if !suppressSpinner {
            readerModeLoading(true)
        }
    }

    @MainActor
    public func cancelReaderModeLoad(for url: URL? = nil, reason: String = "unspecified") {
        if let url, let pendingReaderModeURL, !pendingKeysMatch(pendingReaderModeURL, url) {
            return
        }
        let completedURL = pendingReaderModeURL ?? url ?? lastRenderedURL
        debugPrint(
            "# READERRELOAD cancelLoad",
            "url=\(url?.absoluteString ?? "nil")",
            "reason=\(reason)",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "rendered=\(lastRenderedURL?.absoluteString ?? "nil")"
        )
        logStateSnapshot("cancelLoad", url: completedURL)
        if let url {
            cancelActiveRender(for: url, reason: "cancelReaderModeLoad.\(reason)")
        }
        updatePendingReaderModeURL(nil, reason: "cancelReaderModeLoad")
        expectedSyntheticReaderLoaderURL = nil
        lastRenderedURL = nil
        readerModeLoading(false)
        if let completedURL {
            logTrace(.cancel, url: completedURL, details: reason)
        }
    }

    @MainActor
    public func markReaderModeLoadComplete(for url: URL) {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        guard pendingKeysMatch(pendingReaderModeURL, canonicalURL) || pendingKeysMatch(lastRenderedURL, canonicalURL) else {
            return
        }
        if let pendingReaderModeURL, (readabilityContent?.utf8.count ?? 0) == 0 {
            if handleEmptyReadabilityCompletion(url: canonicalURL, pendingReaderModeURL: pendingReaderModeURL) {
                return
            }
        }
        lastRenderedURL = canonicalURL
        updatePendingReaderModeURL(nil, reason: "markReaderModeLoadComplete")
        expectedSyntheticReaderLoaderURL = nil
        readerModeLoading(false)
        readerModeLoadCompletionHandler?(canonicalURL)
        debugPrint(
            "# READERRELOAD completeLoad",
            "url=\(canonicalURL.absoluteString)",
            "rendered=\(lastRenderedURL?.absoluteString ?? "nil")"
        )
        if let startedAt = loadStartTimes[canonicalURL.absoluteString] {
            debugPrint(
                "# READERPERF readerMode.complete",
                "url=\(canonicalURL.absoluteString)",
                "elapsed=\(formattedInterval(Date().timeIntervalSince(startedAt)))"
            )
        }
        logStateSnapshot("completeLoad", url: canonicalURL)
        logTrace(.complete, url: canonicalURL, details: "markReaderModeLoadComplete")
        loadStartTimes.removeValue(forKey: canonicalURL.absoluteString)
    }

    @MainActor
    public func isReaderModeLoadPending(for url: URL) -> Bool {
        pendingKeysMatch(pendingReaderModeURL, url)
    }

    @MainActor
    public func clearReadabilityCache(for url: URL, reason: String) {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        let matchesLastRendered = pendingKeysMatch(lastRenderedURL, canonicalURL)
        let matchesPending = pendingKeysMatch(pendingReaderModeURL, canonicalURL)
        let isHandling = isReaderModeHandlingURL(canonicalURL)
        let shouldClear = matchesLastRendered || matchesPending || isHandling || readabilityContent != nil
        debugPrint(
            "# READERRELOAD cache.clear",
            "url=\(canonicalURL.absoluteString)",
            "reason=\(reason)",
            "matchesLastRendered=\(matchesLastRendered)",
            "matchesPending=\(matchesPending)",
            "isHandling=\(isHandling)",
            "hadReadability=\(readabilityContent != nil)",
            "lastRendered=\(lastRenderedURL?.absoluteString ?? "nil")"
        )
        guard shouldClear else { return }
        cancelActiveRender(for: canonicalURL, reason: "clearReadabilityCache.\(reason)")
        cancelMetadataRefresh(for: canonicalURL, reason: "clearReadabilityCache.\(reason)")
        readabilityContent = nil
        readabilityContainerSelector = nil
        readabilityContainerFrameInfo = nil
        expectedSyntheticReaderLoaderURL = nil
        if matchesLastRendered {
            lastRenderedURL = nil
        }
        if matchesPending {
            updatePendingReaderModeURL(nil, reason: "clearReadabilityCache")
        }
    }

    @MainActor
    public func handleRenderedReaderDocumentReady(pageURL: URL, hasReaderContent: Bool) {
        let canonicalURL = pageURL.canonicalReaderContentURLForHotfix()
        guard canonicalURL.isSnippetURL, hasReaderContent else { return }

        let pendingMatches = pendingReaderModeURL.map { pendingKeysMatch($0, canonicalURL) } ?? false
        let expectedMatches = expectedSyntheticReaderLoaderURL.map { urlsMatchWithoutHashForHotfix($0, pageURL) } ?? false
        guard pendingMatches || expectedMatches else { return }

        debugPrint(
            "# READER snippet.readerDocumentReady",
            "pageURL=\(pageURL.absoluteString)",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "expected=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
            "hasReaderContent=\(hasReaderContent)"
        )

        lastRenderedURL = canonicalURL

        if expectedMatches {
            expectedSyntheticReaderLoaderURL = nil
        }
        if pendingMatches {
            markReaderModeLoadComplete(for: canonicalURL)
        }
    }

    private func handleEmptyReadabilityCompletion(url: URL, pendingReaderModeURL: URL) -> Bool {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()

        if urlMatchesLastRendered(canonicalURL) {
            updatePendingReaderModeURL(nil, reason: "markReaderModeLoadComplete.renderedEmptyReadability")
            readerModeLoading(false)
            readerModeLoadCompletionHandler?(canonicalURL)
            return true
        }

        if canonicalURL.isSnippetURL {
            updatePendingReaderModeURL(nil, reason: "complete.emptyReadability.snippet")
            expectedSyntheticReaderLoaderURL = nil
            lastFallbackLoaderURL = canonicalURL
            readerModeLoading(false)
            readerModeLoadCompletionHandler?(canonicalURL)
            return true
        }

        if expectedSyntheticReaderLoaderURL != nil {
            debugPrint("# READER readerMode.complete.defer.emptyReadability.expectedSyntheticCommit", canonicalURL.absoluteString)
            return true
        }

        updatePendingReaderModeURL(nil, reason: "complete.emptyReadability")
        lastFallbackLoaderURL = canonicalURL
        readerModeLoading(false)
        readerModeLoadCompletionHandler?(canonicalURL)
        return true
    }

    func isReaderModeHandlingURL(_ url: URL) -> Bool {
        if let pendingReaderModeURL, pendingKeysMatch(pendingReaderModeURL, url) {
            return true
        }
        if let lastRenderedURL, pendingKeysMatch(lastRenderedURL, url) {
            return true
        }
        if hasActiveRender(for: url) {
            return true
        }
        return false
    }

    func resolveSharedReaderFontCSSBase64() async -> String? {
        if let sharedFontCSSBase64, !sharedFontCSSBase64.isEmpty {
            return sharedFontCSSBase64
        }
        if let sharedFontCSSBase64Provider {
            let base64 = await sharedFontCSSBase64Provider()
            guard let base64, !base64.isEmpty else { return nil }
            return base64
        }
        return nil
    }

    func injectSharedFontIfNeeded(scriptCaller: WebViewScriptCaller, pageURL: URL) async {
        guard !pageURL.isEBookURL, pageURL.absoluteString != "about:blank" else { return }
        guard #available(iOS 16.4, macOS 14, *) else { return }
        guard let base64 = await resolveSharedReaderFontCSSBase64() else { return }

        let fontHash = readerFontPayloadHash(base64)
        let js = """
        (function() {
            const postFontLoad = (event, payload) => {
                try {
                    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.print;
                    handler && handler.postMessage && handler.postMessage(Object.assign({
                        message: "# FONTLOAD js.readerInjection." + event,
                        pageURL: window.location.href
                    }, payload || {}));
                } catch (_) {}
            };
            const setFontPendingState = (pending) => {
                const root = document.documentElement;
                if (!root) return;
                if (pending) {
                    root.dataset.manabiFontPending = '1';
                    root.dataset.manabiFontReady = '0';
                } else {
                    delete root.dataset.manabiFontPending;
                    root.dataset.manabiFontReady = '1';
                }
            };
            const replaceFontBlob = (css, fontHash, desiredFamily) => {
                if (!css) return null;
                const resolvedCSS = desiredFamily
                    ? css.replace(/font-family:\\s*['"][^'"]+['"]\\s*;/g, "font-family: '" + desiredFamily + "';")
                    : css;
                const blob = new Blob([resolvedCSS], { type: 'text/css' });
                const nextBlobURL = URL.createObjectURL(blob);
                const previousBlobURL = globalThis.manabiReaderFontCSSBlobURL || null;
                globalThis.manabiReaderFontCSSBlobURL = nextBlobURL;
                globalThis.manabiReaderFontCSSHash = fontHash;
                if (previousBlobURL && previousBlobURL !== nextBlobURL) {
                    try { URL.revokeObjectURL(previousBlobURL); } catch (_) {}
                }
                return nextBlobURL;
            };
            const ensureReaderFontStyle = (desiredFamily) => {
                const root = document.documentElement;
                if (!root) return null;
                let style = document.getElementById('manabi-custom-fonts-inline');
                if (style) return style;
                const css = globalThis.manabiReaderFontCSSText || '';
                if (!css) return null;
                const blobURL = replaceFontBlob(css, fontHash, desiredFamily);
                if (!blobURL) return null;
                style = document.createElement('link');
                style.id = 'manabi-custom-fonts-inline';
                style.rel = 'stylesheet';
                style.href = blobURL;
                style.dataset.manabiFontHash = fontHash;
                if (desiredFamily) {
                    style.dataset.manabiInjectedFontFamily = desiredFamily;
                }
                (document.head || document.documentElement).appendChild(style);
                postFontLoad('reinsertedFromCache', { cssBytes: css.length, mode: 'blob-link' });
                return style;
            };
            globalThis.manabiEnsureReaderFontStyle = ensureReaderFontStyle;
            const waitForFontReady = async (desiredFamily) => {
                const fontSet = document.fonts;
                if (!fontSet) return;
                if (desiredFamily && typeof fontSet.load === 'function') {
                    try {
                        await fontSet.load("1em '" + desiredFamily + "'");
                    } catch (_) {}
                }
                if (typeof fontSet.ready === 'object' && fontSet.ready && typeof fontSet.ready.then === 'function') {
                    try {
                        await fontSet.ready;
                    } catch (_) {}
                }
            };
            return (async () => {
                const root = document.documentElement;
                const desiredFamily =
                    root?.dataset?.manabiHorizontalFontFamily
                    || globalThis.manabiHorizontalFontFamilyName
                    || null;
                setFontPendingState(true);
                let style = ensureReaderFontStyle(desiredFamily);
                if (!style) {
                    const css = atob(fontCSSBase64);
                    globalThis.manabiReaderFontCSSText = css;
                    const blobURL = replaceFontBlob(css, fontHash, desiredFamily);
                    style = document.createElement('link');
                    style.id = 'manabi-custom-fonts-inline';
                    style.rel = 'stylesheet';
                    style.href = blobURL;
                    style.dataset.manabiFontHash = fontHash;
                    if (desiredFamily) {
                        style.dataset.manabiInjectedFontFamily = desiredFamily;
                    }
                    (document.head || document.documentElement).appendChild(style);
                    root.dataset.manabiFontInjected = '1';
                    postFontLoad('inserted', { cssBytes: css.length, mode: 'blob-link' });
                } else {
                    postFontLoad('reusedExisting', { cssBytes: (globalThis.manabiReaderFontCSSText || '').length, mode: style.tagName });
                }
                if (typeof window.manabiApplyDirectionalInjectedFont === 'function') {
                    window.manabiApplyDirectionalInjectedFont();
                }
                const resolvedFamily =
                    document.documentElement?.dataset?.manabiInjectedFontFamily
                    || desiredFamily
                    || null;
                await waitForFontReady(resolvedFamily);
                setFontPendingState(false);
                postFontLoad('fontReady', {
                    family: resolvedFamily,
                    status: document.fonts?.status || 'unknown'
                });
            })().catch((e) => {
                setFontPendingState(false);
                postFontLoad('error', { error: String(e) });
                try { console.log('manabi font inject error', e); } catch (_) {}
            });
        })();
        """
        try? await scriptCaller.evaluateJavaScript(
            js,
            arguments: [
                "fontCSSBase64": base64,
                "fontHash": fontHash,
            ],
            duplicateInMultiTargetFrames: true
        )
    }
    
    public func isReaderModeVisibleInMenu(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && content.isReaderModeOfferHidden && content.isReaderModeAvailable && !content.isReaderModeByDefault
    }
    
    public init() { }

    private func formattedInterval(_ interval: TimeInterval) -> String {
        String(format: "%.3fs", interval)
    }

    private func traceKey(for url: URL) -> String {
        normalizedPendingMatchKey(for: url) ?? url.absoluteString
    }

    private func logStateSnapshot(_ label: String, url: URL?) {
        debugPrint(
            "# READERPERF state.snapshot",
            "label=\(label)",
            "url=\(url?.absoluteString ?? "nil")",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
            "isReaderModeLoading=\(isReaderModeLoading)",
            "isReaderMode=\(isReaderMode)",
            "lastRendered=\(lastRenderedURL?.absoluteString ?? "nil")",
            "lastFallback=\(lastFallbackLoaderURL?.absoluteString ?? "nil")"
        )
    }

    private func logTrace(
        _ stage: ReaderModeLoadStage,
        url: URL?,
        captureStart: Bool = false,
        details: String? = nil
    ) {
        guard let url else { return }
        let now = Date()
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

    private func expectSyntheticReaderLoaderCommit(for baseURL: URL?) {
        expectedSyntheticReaderLoaderURL = baseURL
    }

    @discardableResult
    private func consumeSyntheticReaderLoaderExpectationIfNeeded(for url: URL) -> Bool {
        guard let expectedSyntheticReaderLoaderURL else { return false }
        if urlsMatchWithoutHashForHotfix(expectedSyntheticReaderLoaderURL, url) {
            self.expectedSyntheticReaderLoaderURL = nil
            return true
        }
        return false
    }

    private func updatePendingReaderModeURL(_ newValue: URL?, reason: String) {
        if let newValue, newValue.absoluteString == "about:blank" {
            return
        }
        let canonicalNewValue = newValue?.canonicalReaderContentURLForHotfix()
        let canonicalOldValue = pendingReaderModeURL?.canonicalReaderContentURLForHotfix()
        debugPrint(
            "# READERRELOAD pending.update",
            "reason=\(reason)",
            "from=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "to=\(canonicalNewValue?.absoluteString ?? "nil")",
            "change=\(urlsMatchWithoutHash(canonicalOldValue, canonicalNewValue) ? "unchanged" : "updated")"
        )
        pendingReaderModeURL = canonicalNewValue
    }

    private func normalizedPendingMatchKey(for url: URL?) -> String? {
        guard let url else { return nil }

        if let snippetKey = url.snippetKey {
            return "snippet:\(snippetKey)"
        }

        if url.isReaderURLLoaderURL,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let readerValue = components.queryItems?.first(where: { $0.name == "reader-url" })?.value {
            let decodedReaderURLString = readerValue.removingPercentEncoding ?? readerValue
            guard let readerURL = URL(string: decodedReaderURLString) else {
                return url.absoluteString
            }
            if let snippetKey = readerURL.snippetKey {
                return "snippet:\(snippetKey)"
            }
            return readerURL.removingFragmentIfNeeded().absoluteString
        }

        return url.canonicalReaderContentURLForHotfix().removingFragmentIfNeeded().absoluteString
    }

    private func pendingKeysMatch(_ lhs: URL?, _ rhs: URL?) -> Bool {
        normalizedPendingMatchKey(for: lhs) == normalizedPendingMatchKey(for: rhs)
    }

    private func canonicalRenderKey(_ url: URL) -> String {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        return normalizedPendingMatchKey(for: canonicalURL) ?? canonicalURL.absoluteString
    }

    private func activeRenderGenerationDescription(for key: String) -> String {
        activeRenderGenerationByURL[key]?.uuidString ?? "nil"
    }

    private func metadataRefreshGenerationDescription(for key: String) -> String {
        metadataRefreshGenerationByURL[key]?.uuidString ?? "nil"
    }

    private func urlMatchesLastRendered(_ url: URL) -> Bool {
        guard let lastRenderedURL else { return false }
        return pendingKeysMatch(lastRenderedURL, url)
    }

    private func hasActiveRender(for url: URL) -> Bool {
        let key = canonicalRenderKey(url)
        guard let task = activeRenderTaskByURL[key] else {
            return false
        }
        if task.isCancelled {
            activeRenderTaskByURL.removeValue(forKey: key)
            activeRenderGenerationByURL.removeValue(forKey: key)
            return false
        }
        return true
    }

    private func finishRenderTask(for url: URL, generation: UUID, reason: String) {
        let key = canonicalRenderKey(url)
        guard let activeGeneration = activeRenderGenerationByURL[key], activeGeneration == generation else {
            return
        }
        activeRenderTaskByURL.removeValue(forKey: key)
        activeRenderGenerationByURL.removeValue(forKey: key)
        debugPrint(
            "# READERPERF readerMode.render.singleFlight.finish",
            "url=\(url.absoluteString)",
            "reason=\(reason)",
            "generation=\(generation.uuidString)"
        )
    }

    private func cancelActiveRender(for url: URL, reason: String) {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        let key = canonicalRenderKey(canonicalURL)
        guard let task = activeRenderTaskByURL[key] else {
            return
        }
        let generation = activeRenderGenerationDescription(for: key)
        task.cancel()
        activeRenderTaskByURL.removeValue(forKey: key)
        activeRenderGenerationByURL.removeValue(forKey: key)
        debugPrint(
            "# READERPERF readerMode.render.singleFlight.cancel",
            "url=\(canonicalURL.absoluteString)",
            "reason=\(reason)",
            "generation=\(generation)"
        )
    }

    private func cancelOtherActiveRenders(except keyToKeep: String, requestedURL: URL, reason: String) {
        let staleKeys = activeRenderTaskByURL.keys.filter { $0 != keyToKeep }
        for staleKey in staleKeys {
            let generation = activeRenderGenerationDescription(for: staleKey)
            activeRenderTaskByURL[staleKey]?.cancel()
            activeRenderTaskByURL.removeValue(forKey: staleKey)
            activeRenderGenerationByURL.removeValue(forKey: staleKey)
            debugPrint(
                "# READERPERF readerMode.render.singleFlight.cancel",
                "url=\(requestedURL.absoluteString)",
                "reason=\(reason).replaced",
                "generation=\(generation)",
                "staleKey=\(staleKey)"
            )
        }
    }

    private func finishMetadataRefreshTask(for url: URL, generation: UUID, reason: String) {
        let key = canonicalRenderKey(url)
        guard let activeGeneration = metadataRefreshGenerationByURL[key], activeGeneration == generation else {
            return
        }
        metadataRefreshTaskByURL.removeValue(forKey: key)
        metadataRefreshGenerationByURL.removeValue(forKey: key)
        debugPrint(
            "# READERLOAD stage=readerMode.metadataRefresh",
            "state=finished",
            "url=\(url.absoluteString)",
            "reason=\(reason)",
            "generation=\(generation.uuidString)"
        )
    }

    private func cancelMetadataRefresh(for url: URL, reason: String) {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        let key = canonicalRenderKey(canonicalURL)
        guard let task = metadataRefreshTaskByURL[key] else {
            return
        }
        let generation = metadataRefreshGenerationDescription(for: key)
        task.cancel()
        metadataRefreshTaskByURL.removeValue(forKey: key)
        metadataRefreshGenerationByURL.removeValue(forKey: key)
        debugPrint(
            "# READERLOAD stage=readerMode.metadataRefresh",
            "state=cancelled",
            "url=\(canonicalURL.absoluteString)",
            "reason=\(reason)",
            "generation=\(generation)"
        )
    }

    private func cancelOtherMetadataRefreshTasks(except keyToKeep: String? = nil, reason: String) {
        let staleKeys = metadataRefreshTaskByURL.keys.filter { key in
            guard let keyToKeep else { return true }
            return key != keyToKeep
        }
        for staleKey in staleKeys {
            let generation = metadataRefreshGenerationDescription(for: staleKey)
            metadataRefreshTaskByURL[staleKey]?.cancel()
            metadataRefreshTaskByURL.removeValue(forKey: staleKey)
            metadataRefreshGenerationByURL.removeValue(forKey: staleKey)
            debugPrint(
                "# READERLOAD stage=readerMode.metadataRefresh",
                "state=cancelled",
                "reason=\(reason)",
                "generation=\(generation)",
                "staleKey=\(staleKey)"
            )
        }
    }

    @discardableResult
    @MainActor
    private func startRenderTaskIfNeeded(
        for url: URL,
        reason: String,
        operation: @escaping @MainActor (_ generation: UUID) async -> Void
    ) -> Bool {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        let key = canonicalRenderKey(canonicalURL)
        cancelOtherActiveRenders(except: key, requestedURL: canonicalURL, reason: reason)

        if let existingTask = activeRenderTaskByURL[key], !existingTask.isCancelled {
            debugPrint(
                "# READERPERF readerMode.render.singleFlight.skip",
                "url=\(canonicalURL.absoluteString)",
                "reason=\(reason)",
                "generation=\(activeRenderGenerationDescription(for: key))"
            )
            return false
        }

        let generation = UUID()
        activeRenderGenerationByURL[key] = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.finishRenderTask(for: canonicalURL, generation: generation, reason: reason)
            }
            await operation(generation)
        }
        activeRenderTaskByURL[key] = task
        return true
    }

    private enum ReaderModeRoute: String {
        case localHTML = "swiftFinalLoad"
        case capturedReadability = "webviewReadability"
        case unavailable = "unavailable"
    }
    
    func isReaderModeLoadPending(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && content.isReaderModeAvailable && content.isReaderModeByDefault
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
        beginReaderModeLoad(for: contentURL, reason: "showReaderView")
        logTrace(.readabilityTaskScheduled, url: contentURL, details: "readabilityBytes=\(readabilityContent?.utf8.count ?? 0)")
        _ = startRenderTaskIfNeeded(for: contentURL, reason: "showReaderView") { [weak self] generation in
            guard let self else { return }
            guard urlsMatchWithoutHashForHotfix(contentURL, readerContent.pageURL) else {
                cancelReaderModeLoad(for: contentURL, reason: "showReaderView.urlMismatch")
                return
            }
            let route = await resolveReaderModeRoute(readerContent: readerContent)
            switch route {
            case .localHTML:
                await showReaderViewUsingSwiftProcessing(
                    readerContent: readerContent,
                    scriptCaller: scriptCaller,
                    renderGeneration: generation
                )
            case .capturedReadability:
                guard let readabilityContent else {
                    cancelReaderModeLoad(for: contentURL, reason: "showReaderView.missingReadability")
                    return
                }
                do {
                    try await showReadabilityContent(
                        readerContent: readerContent,
                        readabilityContent: readabilityContent,
                        renderToSelector: readabilityContainerSelector,
                        in: readabilityContainerFrameInfo,
                        scriptCaller: scriptCaller,
                        renderGeneration: generation
                    )
                } catch is CancellationError {
                    cancelReaderModeLoad(for: contentURL, reason: "showReaderView.cancelled")
                } catch {
                    print(error)
                    cancelReaderModeLoad(for: contentURL, reason: "showReaderView.readabilityError")
                }
            case .unavailable:
                cancelReaderModeLoad(for: contentURL, reason: "showReaderView.unavailable")
            }
        }
    }

    @MainActor
    private func showReaderViewUsingSwiftProcessing(
        readerContent: ReaderContent,
        scriptCaller: WebViewScriptCaller,
        renderGeneration: UUID? = nil
    ) async {
        do {
            guard let content = try await readerContent.getContent() else {
                cancelReaderModeLoad(for: readerContent.pageURL, reason: "swiftProcessing.missingContent")
                return
            }
            let activeReaderFileManager = readerFileManager ?? .shared
            guard let html = try await locallyRetrievableReaderHTML(
                for: content,
                readerFileManager: activeReaderFileManager
            ) else {
                cancelReaderModeLoad(for: content.url, reason: "swiftProcessing.missingHTML")
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
                    scriptCaller: scriptCaller,
                    renderGeneration: renderGeneration
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
            cancelReaderModeLoad(for: readerContent.pageURL, reason: "swiftProcessing.error")
        }
    }
    
    /// `readerContent` is used to verify current reader state before loading processed `content`
    @MainActor
    internal func showReadabilityContent(
        readerContent: ReaderContent,
        readabilityContent: String,
        renderToSelector: String?,
        in frameInfo: WKFrameInfo?,
        scriptCaller: WebViewScriptCaller,
        renderGeneration: UUID? = nil
    ) async throws {
        guard let content = try await readerContent.getContent() else {
            print("No content set to show in reader mode")
            cancelReaderModeLoad(for: readerContent.pageURL, reason: "showReadabilityContent.missingContent")
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

        debugPrint(
            "# READERTRACE",
            "readerMode.showReadabilityContent.start",
            [
                "contentURL": url.absoluteString,
                "renderBaseURL": renderBaseURL.absoluteString,
                "readerContentPageURL": readerContent.pageURL.absoluteString,
                "frameMain": frameInfo?.isMainFrame as Any,
                "hasProcessReadabilityContent": processReadabilityContent != nil,
                "hasProcessHTML": processHTML != nil
            ] as [String: Any]
        )
        
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

            let processedSegmentCount = (try? doc.getElementsByTag("manabi-segment").size()) ?? 0
            let processedBodyExists = doc.body() != nil
            debugPrint(
                "# READERTRACE",
                "readerMode.showReadabilityContent.processed",
                [
                    "contentURL": url.absoluteString,
                    "renderBaseURL": renderBaseURL.absoluteString,
                    "segmentCount": processedSegmentCount,
                    "hasBody": processedBodyExists,
                    "baseUri": doc.getBaseUri()
                ] as [String: Any]
            )

            if let sharedFontCSSBase64 = await resolveSharedReaderFontCSSBase64(), !sharedFontCSSBase64.isEmpty {
                try? upsertDeferredSharedReaderFontGate(in: doc)
            }

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
                    debugPrint(
                        "# READERTRACE",
                        "readerMode.showReadabilityContent.skip.urlMismatch",
                        [
                            "contentURL": url.absoluteString,
                            "readerContentPageURL": readerContent.pageURL.absoluteString,
                            "renderBaseURL": renderBaseURL.absoluteString
                        ] as [String: Any]
                    )
                    cancelReaderModeLoad(for: url, reason: "showReadabilityContent.urlMismatch")
                    return
                }
                self?.lastRenderedURL = url.canonicalReaderContentURLForHotfix()
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
                    self?.markReaderModeLoadComplete(for: url)
                } else if let htmlData = transformedContent.data(using: .utf8) {
                    self?.expectSyntheticReaderLoaderCommit(for: renderBaseURL)
                    self?.logTrace(.navigatorLoad, url: url, details: "mode=readability-html | bytes=\(htmlData.count)")
                    navigator?.load(
                        htmlData,
                        mimeType: "text/html",
                        characterEncodingName: "UTF-8",
                        baseURL: renderBaseURL
                    )
                } else {
                    self?.expectSyntheticReaderLoaderCommit(for: renderBaseURL)
                    self?.logTrace(.navigatorLoad, url: url, details: "mode=readability-html | bytes=\(transformedContent.utf8.count)")
                    navigator?.loadHTML(transformedContent, baseURL: renderBaseURL)
                }
//                try await { @MainActor in
//                    readerModeLoading(false)
//                }()
            }()
        }()

        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        if injectEntryImageIntoHeader && content.imageUrl == nil {
            schedulePostRenderMetadataRefreshIfNeeded(
                content: content,
                contentURL: canonicalURL
            )
        }
    }

    @MainActor
    private func schedulePostRenderMetadataRefreshIfNeeded(
        content: any ReaderContentProtocol,
        contentURL: URL
    ) {
        _ = schedulePostRenderMetadataRefreshTaskIfNeededImpl(
            contentURL: contentURL,
            injectEntryImageIntoHeader: content.injectEntryImageIntoHeader,
            cachedImageURL: content.imageUrl
        ) {
            try await content.imageURLToDisplay()
        }
    }

    @discardableResult
    @MainActor
    private func schedulePostRenderMetadataRefreshTaskIfNeededImpl(
        contentURL: URL,
        injectEntryImageIntoHeader: Bool,
        cachedImageURL: URL?,
        imageLookup: @escaping @MainActor () async throws -> URL?
    ) -> Bool {
        let canonicalURL = contentURL.canonicalReaderContentURLForHotfix()
        let refreshKey = canonicalRenderKey(canonicalURL)
        guard injectEntryImageIntoHeader else { return false }
        guard cachedImageURL == nil else { return false }
        cancelOtherMetadataRefreshTasks(except: refreshKey, reason: "schedulePostRenderMetadataRefreshIfNeeded")
        if let existingTask = metadataRefreshTaskByURL[refreshKey], !existingTask.isCancelled {
            debugPrint(
                "# READERLOAD stage=readerMode.metadataRefresh",
                "state=coalesced",
                "url=\(canonicalURL.absoluteString)",
                "generation=\(metadataRefreshGenerationDescription(for: refreshKey))"
            )
            return false
        }

        let generation = UUID()
        metadataRefreshGenerationByURL[refreshKey] = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.finishMetadataRefreshTask(for: canonicalURL, generation: generation, reason: "taskComplete")
            }
            do {
                let refreshedImageURL = try await imageLookup()
                debugPrint(
                    "# READERLOAD stage=readerMode.metadataRefresh",
                    "state=completed",
                    "url=\(canonicalURL.absoluteString)",
                    "hasImage=\(refreshedImageURL != nil)",
                    "generation=\(generation.uuidString)"
                )
            } catch is CancellationError {
                debugPrint(
                    "# READERLOAD stage=readerMode.metadataRefresh",
                    "state=cancelled",
                    "url=\(canonicalURL.absoluteString)",
                    "generation=\(generation.uuidString)"
                )
            } catch {
                debugPrint(
                    "# READERLOAD stage=readerMode.metadataRefresh",
                    "state=failed",
                    "url=\(canonicalURL.absoluteString)",
                    "error=\(error.localizedDescription)",
                    "generation=\(generation.uuidString)"
                )
            }
        }
        metadataRefreshTaskByURL[refreshKey] = task
        return true
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
            cancelReaderModeLoad(for: newState.pageURL, reason: "navCommit.missingContent")
            return
        }
        try Task.checkCancellation()
        
        let committedURL = content.url
        guard committedURL.matchesReaderURL(newState.pageURL) else {
            print("URL mismatch in ReaderModeViewModel onNavigationCommitted", committedURL, newState.pageURL)
            cancelReaderModeLoad(for: committedURL, reason: "navCommit.urlMismatch")
            return
        }
        try Task.checkCancellation()

        await injectSharedFontIfNeeded(scriptCaller: scriptCaller, pageURL: committedURL)
        logTrace(.navCommitted, url: committedURL, details: "pageURL=\(newState.pageURL.absoluteString)")
        logStateSnapshot("navCommitted", url: committedURL)

        if consumeSyntheticReaderLoaderExpectationIfNeeded(for: newState.pageURL) {
            return
        }

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
                    cancelReaderModeLoad(for: committedURL, reason: "navCommit.currentURLMismatch")
                    return
                }
                if hasCanonicalReadabilityMarkup(in: html) {
                    readabilityContent = html
                } else {
                    readabilityContent = nil
                }
                readerContent.isRenderingReaderHTML = true
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
        await injectSharedFontIfNeeded(scriptCaller: scriptCaller, pageURL: newState.pageURL)
        if let trackedURL = pendingReaderModeURL {
            logTrace(.navFinished, url: trackedURL, details: "pageURL=\(newState.pageURL.absoluteString)")
        } else if loadTraceRecords[traceKey(for: newState.pageURL)] != nil {
            logTrace(.navFinished, url: newState.pageURL, details: "pageURL=\(newState.pageURL.absoluteString)")
        }
        if let deferral = navigationFinishedDeferral(newState: newState) {
            switch deferral {
            case .loader:
                debugPrint("# FLASH readerMode.navFinished.defer.loader", "pageURL=\(newState.pageURL)")
            case .synthetic(let pendingURL, let expectedURL):
                debugPrint(
                    "# FLASH readerMode.navFinished.defer.synthetic",
                    "pageURL=\(newState.pageURL)",
                    "pending=\(pendingURL)",
                    "expected=\(expectedURL)"
                )
            case .pending(let pendingURL):
                debugPrint(
                    "# FLASH readerMode.navFinished.defer.pending",
                    "pageURL=\(newState.pageURL.absoluteString)",
                    "pending=\(pendingURL.absoluteString)",
                    "expected=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
                    "isReaderModeLoading=\(isReaderModeLoading)"
                )
            }
            return
        }

        let pendingMatchesPage: Bool = {
            guard let pendingReaderModeURL else { return false }
            let pendingKey = normalizedPendingMatchKey(for: pendingReaderModeURL)
            let pendingLoaderKey = ReaderContentLoader.readerLoaderURL(for: pendingReaderModeURL).flatMap { normalizedPendingMatchKey(for: $0) }
            let pageKey = normalizedPendingMatchKey(for: newState.pageURL)
            let pageLoaderKey = ReaderContentLoader.readerLoaderURL(for: newState.pageURL).flatMap { normalizedPendingMatchKey(for: $0) }
            if let pendingKey, pendingKey == pageKey || pendingKey == pageLoaderKey {
                return true
            }
            if let pendingLoaderKey, pendingLoaderKey == pageKey || pendingLoaderKey == pendingKey {
                return true
            }
            return false
        }()

        if pendingMatchesPage, let pendingReaderModeURL {
            markReaderModeLoadComplete(for: pendingReaderModeURL)
        } else {
            readerModeLoading(false)
        }
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

    private enum NavigationFinishedDeferral {
        case loader
        case synthetic(pendingURL: URL, expectedURL: URL)
        case pending(pendingURL: URL)
    }

    private func navigationFinishedDeferral(newState: WebViewState) -> NavigationFinishedDeferral? {
        guard let pendingReaderModeURL else { return nil }

        if newState.pageURL.isReaderURLLoaderURL {
            let pageMatchesPending = pendingKeysMatch(pendingReaderModeURL, newState.pageURL)
            if !(hasRenderedReadabilityContent && pageMatchesPending) {
                return .loader
            }
        }

        if let expectedSyntheticReaderLoaderURL {
            let pageURL = newState.pageURL
            let pageMatchesPending = pendingKeysMatch(pendingReaderModeURL, pageURL)
            let pageMatchesExpected = urlsMatchWithoutHashForHotfix(expectedSyntheticReaderLoaderURL, pageURL)
            if hasRenderedReadabilityContent && pageMatchesPending {
                debugPrint(
                    "# READERPERF readerMode.expectedLoader.reset",
                    "from=\(expectedSyntheticReaderLoaderURL.absoluteString)",
                    "to=nil",
                    "reason=\(pageMatchesExpected ? "navFinished.expectedPageArrived" : "navFinished.realContentArrived")",
                    "pageURL=\(pageURL.absoluteString)"
                )
                self.expectedSyntheticReaderLoaderURL = nil
            } else {
                return .synthetic(pendingURL: pendingReaderModeURL, expectedURL: expectedSyntheticReaderLoaderURL)
            }
        }

        if pendingReaderModeURL.isSnippetURL && !hasRenderedReadabilityContent {
            return .pending(pendingURL: pendingReaderModeURL)
        }

        if !hasRenderedReadabilityContent {
            let pageURL = newState.pageURL
            let pageMatchesPending = pendingKeysMatch(pendingReaderModeURL, pageURL)
            let pageIsRealPendingContent = pageMatchesPending && !pageURL.isReaderURLLoaderURL
            if !pageIsRealPendingContent || expectedSyntheticReaderLoaderURL != nil {
                return .pending(pendingURL: pendingReaderModeURL)
            }
        }

        return nil
    }
    
    @MainActor
    public func onNavigationFailed(newState: WebViewState) {
        cancelReaderModeLoad(for: newState.pageURL, reason: "navigationFailed")
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
