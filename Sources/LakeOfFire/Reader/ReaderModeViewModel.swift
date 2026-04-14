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
import SwiftUtilities

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

extension URL {
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

private func currentReaderFontNeedsDeferredSharedCSS() -> Bool {
    guard let rawValue = UserDefaults.standard.string(forKey: "readerFont") else {
        return true
    }
    return rawValue == "YuKyokasho"
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
    contentURL: URL,
    hideReaderTitle: Bool = false
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
    let availabilityAttributes = "data-manabi-reader-mode-available=\"true\" data-manabi-reader-mode-available-for=\"\(escapeReadabilityHTMLAttribute(contentURL.absoluteString))\" data-manabi-reader-render-ready=\"1\""
    let suppressionBodyClass = ReaderContentLoader.snippetReaderTitleSuppressionBodyClass
    let bodyStyle = ManabiSystemUIFontCSS.cssDeclarations(from: ManabiSystemUIFontCSS.fallbackSizeMap())
    let titleSuppressionCSS = """
    body.\(suppressionBodyClass) #reader-title {
        display: none !important;
    }
    """
    let systemUICSS = """
    body.readability-mode #reader-byline-container {
        font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        font-size: var(--manabi-system-font-size-footnote, 13px);
        line-height: 20px;
    }
    body.readability-mode #reader-byline-line,
    body.readability-mode #reader-byline,
    body.readability-mode #reader-byline-container .reader-view-original,
    body.readability-mode #reader-byline-container .byline-label {
        font-size: inherit;
        line-height: inherit;
    }
    body.readability-mode #reader-meta-line {
        font-size: inherit;
        line-height: inherit;
    }
    body.readability-mode #manabi-tracking-footer button,
    body.readability-mode .manabi-start-over-book-button,
    body.readability-mode .manabi-start-over-button {
        font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        font-size: var(--manabi-system-font-size-footnote, 13px);
        font-weight: 600;
        height: 40px !important;
    }
    body.readability-mode .manabi-finished-reading-button-subtitle {
        font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        font-size: var(--manabi-system-font-size-footnote, 13px);
    }
    """
    let bodyClass = hideReaderTitle
        ? "readability-mode \(suppressionBodyClass)"
        : "readability-mode"
    return """
    <!DOCTYPE html>
    <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="\(readabilityViewportMetaContent)">
            <style type="text/css" id="swiftuiwebview-readability-styles">\(Readability.shared.css)
            \(systemUICSS)
            \(titleSuppressionCSS)</style>
            <title>\(resolvedTitle)</title>
        </head>
        <body class="\(bodyClass)" style="\(escapeReadabilityHTMLAttribute(bodyStyle))" \(availabilityAttributes)>
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
                (function() {
                    const postSnippetTitleLog = (payload) => {
                        try {
                            const message = '# SNIPPETTITLE ' + JSON.stringify(payload);
                            const webkitPrint = window.webkit?.messageHandlers?.print;
                            if (webkitPrint && typeof webkitPrint.postMessage === 'function') {
                                webkitPrint.postMessage(message);
                                return;
                            }
                            if (typeof print !== 'undefined' && print && typeof print.postMessage === 'function') {
                                print.postMessage(message);
                            }
                        } catch (_) {}
                    };
                    const emit = () => {
                        const el = document.getElementById('reader-title');
                        const body = document.body;
                        postSnippetTitleLog({
                            source: 'canonicalHTML',
                            bodyClasses: body ? body.className : null,
                            hasTitleElement: !!el,
                            titleText: el ? el.textContent : null,
                            computedDisplay: el ? window.getComputedStyle(el).display : null,
                        });
                    };
                    if (document.readyState === 'loading') {
                        document.addEventListener('DOMContentLoaded', emit, { once: true });
                    } else {
                        emit();
                    }
                })();
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

internal func markReaderRenderReady(in doc: SwiftSoup.Document) {
    try? doc.select("html").first()?.attr("data-manabi-reader-render-ready", "1")
    try? doc.body()?.attr("data-manabi-reader-render-ready", "1")
}

internal func titleFromReadabilityHTML(_ html: String) -> String? {
    if let doc = try? SwiftSoup.parse(html),
       let title = titleFromReadabilityDocument(doc) {
        return title
    }

    func normalisedTitle(_ raw: String?) -> String? {
        let trimmed = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.truncate(36)
    }

    let stripped = html.strippingHTML().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !stripped.isEmpty else { return nil }
    let candidate = stripped.components(separatedBy: "\n").first ?? stripped
    return normalisedTitle(candidate)
}

internal func titleFromReadabilityDocument(_ doc: SwiftSoup.Document) -> String? {
    func normalisedTitle(_ raw: String?) -> String? {
        let trimmed = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.truncate(36)
    }

    if let readerTitleText = try? doc.getElementById("reader-title")?.text(),
       let title = normalisedTitle(readerTitleText) {
        return title
    }

    if let headingText = try? doc.getElementsByTag("h1").first()?.text(),
       let title = normalisedTitle(headingText) {
        return title
    }

    if let headTitle = try? doc.title(),
       let title = normalisedTitle(headTitle) {
        return title
    }

    if let body = doc.body(),
       let bodyText = bodyTextExcludingReaderContent(from: body),
       let title = normalisedTitle(bodyText) {
        return title
    }
    return nil
}

private func bodyTextExcludingReaderContent(from body: SwiftSoup.Element) -> String? {
    let children = body.children().array()
    guard !children.isEmpty else {
        return try? body.text()
    }

    var candidates: [String] = []
    candidates.reserveCapacity(children.count)
    for child in children {
        if (try? child.attr("id")) == "reader-content" { continue }
        if (try? child.getElementById("reader-content")) != nil { continue }
        let text = (try? child.text())?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, !text.isEmpty {
            candidates.append(text)
        }
    }
    if candidates.isEmpty {
        return try? body.text()
    }
    return candidates.joined(separator: " ")
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

private func trimmedNonEmptyReadabilityText(_ raw: String?) -> String? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

func buildSnippetCanonicalReadabilityHTML(
    html: String,
    contentURL: URL,
    fallbackTitle: String?,
    publishedTime: String? = nil,
    preferredTitle: String? = nil,
    hideReaderTitleOverride: Bool? = nil
) -> String? {
    let normalizedHTML = ensureReadabilityBodyExists(html)
    if hasCanonicalReadabilityMarkup(in: normalizedHTML) {
        return rebuildCanonicalSnippetReadabilityHTML(
            html: normalizedHTML,
            contentURL: contentURL,
            fallbackTitle: fallbackTitle,
            publishedTime: publishedTime,
            preferredTitle: preferredTitle,
            hideReaderTitleOverride: hideReaderTitleOverride
        )
    }
    guard let rawContent = bodyInnerHTML(from: normalizedHTML)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawContent.isEmpty else {
        return nil
    }
    let resolvedTitle = trimmedNonEmptyReadabilityText(preferredTitle)
        ?? trimmedNonEmptyReadabilityText(fallbackTitle)
        ?? ""
    let sanitizedTitle = sanitizeReadabilityFragment(resolvedTitle)
    let sanitizedContent = sanitizeReadabilityFragment(rawContent)
    let shouldHideReaderTitle = hideReaderTitleOverride
        ?? ReaderContentLoader.snippetTitleMatchesGeneratedPrefix(
            resolvedTitle,
            sourceHTML: normalizedHTML
        )
    debugPrint(
        "# SNIPPETTITLE buildSnippetCanonical",
        "url=\(contentURL.absoluteString)",
        "title=\(resolvedTitle)",
        "hideReaderTitle=\(shouldHideReaderTitle)",
        "contentBytes=\(rawContent.utf8.count)"
    )
    guard !sanitizedContent.isEmpty else {
        return nil
    }
    return buildCanonicalReadabilityHTML(
        title: sanitizedTitle,
        byline: "",
        publishedTime: publishedTime,
        content: sanitizedContent,
        contentURL: contentURL.canonicalReaderContentURLForHotfix(),
        hideReaderTitle: shouldHideReaderTitle
    )
}

private func rebuildCanonicalSnippetReadabilityHTML(
    html: String,
    contentURL: URL,
    fallbackTitle: String?,
    publishedTime: String? = nil,
    preferredTitle: String? = nil,
    hideReaderTitleOverride: Bool? = nil
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

    let resolvedTitle = trimmedNonEmptyReadabilityText(preferredTitle)
        ?? trimmedNonEmptyReadabilityText(extractedTitle)
        ?? trimmedNonEmptyReadabilityText(fallbackTitle)
        ?? ""
    let sanitizedTitle = sanitizeReadabilityFragment(resolvedTitle)
    let sanitizedByline = sanitizeReadabilityFragment(extractedByline ?? "")
    let sanitizedContent = sanitizeReadabilityFragment(extractedContent)
    let shouldHideReaderTitle = hideReaderTitleOverride
        ?? ReaderContentLoader.snippetTitleMatchesGeneratedPrefix(
            resolvedTitle,
            sourceHTML: extractedContent
        )
    debugPrint(
        "# SNIPPETTITLE rebuildSnippetCanonical",
        "url=\(contentURL.absoluteString)",
        "title=\(resolvedTitle)",
        "hideReaderTitle=\(shouldHideReaderTitle)",
        "contentBytes=\(extractedContent.utf8.count)"
    )
    guard !sanitizedContent.isEmpty else {
        return nil
    }

    return buildCanonicalReadabilityHTML(
        title: sanitizedTitle,
        byline: sanitizedByline,
        publishedTime: publishedTime,
        content: sanitizedContent,
        contentURL: contentURL.canonicalReaderContentURLForHotfix(),
        hideReaderTitle: shouldHideReaderTitle
    )
}

@MainActor
private func locallyRetrievableReaderHTML(
    for content: any ReaderContentProtocol,
    readerFileManager: ReaderFileManager
) async throws -> String? {
    let startedAt = CFAbsoluteTimeGetCurrent()
    var html = try await content.htmlToDisplay(readerFileManager: readerFileManager)
    if html == nil, content.url.isSnippetURL {
        html = content.html
    }
    guard let html else {
        debugPrint(
            "# READERLOAD stage=readerMode.localHTML",
            "contentURL=\(content.url.absoluteString)",
            "hasHTML=false",
            "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startedAt))s"
        )
        return nil
    }
    let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
    let result = trimmed.isEmpty ? nil : trimmed
    debugPrint(
        "# READERLOAD stage=readerMode.localHTML",
        "contentURL=\(content.url.absoluteString)",
        "hasHTML=\(result != nil)",
        "bytes=\(result?.utf8.count ?? 0)",
        "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startedAt))s"
    )
    return result
}

@MainActor
private func propagateReaderModeDefaults(
    for url: URL,
    primaryRecord: any ReaderContentProtocol,
    readabilityHTML: String,
    fallbackTitle: String?,
    derivedTitle: String? = nil
) async {
    let startedAt = Date()
    if url.isSnippetURL {
        debugPrint(
            "# READERLOAD stage=readerMode.propagateDefaults.skipped",
            "reason=snippetURL"
        )
        debugPrint(
            "# READERLOAD stage=readerMode.propagateDefaults.complete",
            "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(startedAt)))s"
        )
        return
    }
    let primaryKey = primaryRecord.compoundKey
    let resolvedTitle = derivedTitle ?? titleFromReadabilityHTML(readabilityHTML) ?? fallbackTitle
    do {
        try await propagateReaderModeDefaultsOnBackgroundActor(
            for: url,
            primaryKey: primaryKey,
            readabilityHTML: readabilityHTML,
            resolvedTitle: resolvedTitle
        )
    } catch {
        debugPrint(
            "# READER readerMode.propagateDefaults.error",
            url.absoluteString,
            error.localizedDescription
        )
    }
    debugPrint(
        "# READERLOAD stage=readerMode.propagateDefaults.complete",
        "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(startedAt)))s"
    )
}

@RealmBackgroundActor
private func propagateReaderModeDefaultsOnBackgroundActor(
    for url: URL,
    primaryKey: String,
    readabilityHTML: String,
    resolvedTitle: String?
) async throws {
    let loadAllStartedAt = Date()
    let relatedRecords = try await ReaderContentLoader.loadAll(url: url)
    debugPrint(
        "# READERLOAD stage=readerMode.propagateDefaults.loadAll",
        "count=\(relatedRecords.count)",
        "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(loadAllStartedAt)))s"
    )

    let writableRecords = relatedRecords.filter { $0.compoundKey != primaryKey && $0.realm != nil }
    guard !writableRecords.isEmpty else {
        debugPrint(
            "# READERLOAD stage=readerMode.propagateDefaults.writes",
            "updatedCount=0",
            "elapsed=0.000s",
            "reason=noSecondaryRecords"
        )
        return
    }

    var updatedCount = 0
    let writesStartedAt = Date()
    for record in writableRecords {
        guard let realm = record.realm else { continue }
        try await realm.asyncWrite {
            record.isReaderModeByDefault = true
            record.isReaderModeAvailable = false
            if !url.isEBookURL && !url.isFileURL && !url.isNativeReaderView {
                if !url.isReaderFileURL && (record.content?.isEmpty ?? true) {
                    record.html = readabilityHTML
                }
                if let resolvedTitle,
                   record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    record.title = resolvedTitle
                }
                record.rssContainsFullContent = true
            }
            record.refreshChangeMetadata(explicitlyModified: true)
        }
        updatedCount += 1
    }
    debugPrint(
        "# READERLOAD stage=readerMode.propagateDefaults.writes",
        "updatedCount=\(updatedCount)",
        "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(writesStartedAt)))s"
    )
}

@MainActor
public class ReaderModeViewModel: ObservableObject {
    public var readerFileManager: ReaderFileManager?
    public var ebookTextProcessorCacheHits: ((URL, String) async throws -> Bool)? = nil
    public var processReadabilityContent: ((String, URL, URL?, Bool, ((SwiftSoup.Document) async -> SwiftSoup.Document)) async throws -> SwiftSoup.Document)? = nil
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
    private var syntheticLoadIssuedAtByURL: [String: Date] = [:]
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
        let previousValue = isReaderModeLoading
        if isLoading && !isReaderModeLoading {
            isReaderModeLoading = true
            if !isReaderMode {
                lastRenderedURL = nil
            }
        } else if !isLoading && isReaderModeLoading {
            isReaderModeLoading = false
        }
        if previousValue != isReaderModeLoading {
            debugPrint(
                "# READERLOAD stage=readerMode.loadingState",
                "previous=\(previousValue)",
                "next=\(isReaderModeLoading)",
                "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
                "expected=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
                "rendered=\(lastRenderedURL?.absoluteString ?? "nil")"
            )
        }
    }

    @MainActor
    public func beginReaderModeLoad(for url: URL, suppressSpinner: Bool = false, reason: String? = nil) {
        let startedAt = Date()
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
        debugPrint(
            "# READERLOAD stage=readerMode.beginLoad",
            "url=\(canonicalURL.absoluteString)",
            "pendingMatches=\(pendingMatches)",
            "suppressSpinner=\(suppressSpinner)",
            "reason=\(reason ?? "nil")",
            "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(startedAt)))s"
        )
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
            let elapsed = loadStartTimes[completedURL.absoluteString].map { formattedInterval(Date().timeIntervalSince($0)) } ?? "nil"
            debugPrint(
                "# READERLOAD stage=readerMode.cancelLoad",
                "url=\(completedURL.absoluteString)",
                "reason=\(reason)",
                "elapsed=\(elapsed)"
            )
            logTrace(.cancel, url: completedURL, details: reason)
        }
    }

    @MainActor
    public func markReaderModeLoadComplete(for url: URL) {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        let matchesPending = pendingKeysMatch(pendingReaderModeURL, canonicalURL)
        let matchesLastRendered = pendingKeysMatch(lastRenderedURL, canonicalURL)
        let matchesExpected = expectedSyntheticReaderLoaderURL.map {
            urlsMatchWithoutHashForHotfix($0, canonicalURL)
        } ?? false
        let syntheticCompletionInFlight = isReaderModeLoading && !canonicalURL.isReaderURLLoaderURL
        guard matchesPending || matchesLastRendered || matchesExpected || syntheticCompletionInFlight else {
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
        let elapsed = loadStartTimes[canonicalURL.absoluteString].map { formattedInterval(Date().timeIntervalSince($0)) } ?? "nil"
        debugPrint(
            "# READERLOAD stage=readerMode.markComplete",
            "url=\(canonicalURL.absoluteString)",
            "elapsed=\(elapsed)",
            "matchesPending=\(matchesPending)",
            "matchesLastRendered=\(matchesLastRendered)",
            "matchesExpected=\(matchesExpected)",
            "syntheticCompletionInFlight=\(syntheticCompletionInFlight)"
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
        clearSyntheticLoadIssued(for: canonicalURL)
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
        guard hasReaderContent, !pageURL.isReaderURLLoaderURL else { return }

        let pendingMatches = pendingReaderModeURL.map { pendingKeysMatch($0, canonicalURL) } ?? false
        let expectedMatches = expectedSyntheticReaderLoaderURL.map { urlsMatchWithoutHashForHotfix($0, pageURL) } ?? false
        let syntheticCompletionInFlight = isReaderModeLoading && !pageURL.isReaderURLLoaderURL
        guard pendingMatches || expectedMatches || syntheticCompletionInFlight else { return }

        debugPrint(
            "# READER snippet.readerDocumentReady",
            "pageURL=\(pageURL.absoluteString)",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "expected=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
            "hasReaderContent=\(hasReaderContent)",
            "syntheticCompletionInFlight=\(syntheticCompletionInFlight)"
        )
        if let issuedAt = syntheticLoadIssuedAtByURL[canonicalRenderKey(canonicalURL)] {
            debugPrint(
                "# READERLOAD stage=readerMode.syntheticLoad.renderReady",
                "contentURL=\(canonicalURL.absoluteString)",
                "elapsedSinceSyntheticLoad=\(formattedInterval(Date().timeIntervalSince(issuedAt)))"
            )
        }
        debugPrint(
            "# READERLOAD stage=readerMode.syntheticLoad.forceClearLoadingIndicators",
            "contentURL=\(canonicalURL.absoluteString)",
            "pageURL=\(pageURL.absoluteString)",
            "pendingReaderModeURL=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "expectedSyntheticReaderLoaderURL=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")"
        )
        navigator?.forceClearLoadingIndicators(
            reason: "readerMode.syntheticLoad.renderReady",
            pageURL: canonicalURL
        )

        lastRenderedURL = canonicalURL

        if expectedMatches {
            expectedSyntheticReaderLoaderURL = nil
        }
        markReaderModeLoadComplete(for: canonicalURL)
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
            debugPrint(
                "# READERLOAD stage=readerMode.sharedFont.source",
                "source=cached",
                "bytes=\(sharedFontCSSBase64.utf8.count)"
            )
            return sharedFontCSSBase64
        }
        if let sharedFontCSSBase64Provider {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let base64 = await sharedFontCSSBase64Provider()
            guard let base64, !base64.isEmpty else {
                debugPrint(
                    "# READERLOAD stage=readerMode.sharedFont.source",
                    "source=provider",
                    "result=empty",
                    "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startedAt))s"
                )
                return nil
            }
            debugPrint(
                "# READERLOAD stage=readerMode.sharedFont.source",
                "source=provider",
                "bytes=\(base64.utf8.count)",
                "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startedAt))s"
            )
            return base64
        }
        debugPrint(
            "# READERLOAD stage=readerMode.sharedFont.source",
            "source=unavailable"
        )
        return nil
    }

    func injectSharedFontIfNeeded(scriptCaller: WebViewScriptCaller, pageURL: URL) async {
        guard !pageURL.isEBookURL, pageURL.absoluteString != "about:blank" else { return }
        guard #available(iOS 16.4, macOS 14, *) else { return }
        guard let base64 = await resolveSharedReaderFontCSSBase64() else { return }

        let fontHash = readerFontPayloadHash(base64)
        let js = """
        (function() {
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
                } else {
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
            })().catch((e) => {
                setFontPendingState(false);
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
        debugPrint(
            "# READERLOAD stage=readerMode.syntheticExpectation.set",
            "url=\(baseURL?.absoluteString ?? "nil")"
        )
    }

    @discardableResult
    private func consumeSyntheticReaderLoaderExpectationIfNeeded(for url: URL) -> Bool {
        guard let expectedSyntheticReaderLoaderURL else { return false }
        if urlsMatchWithoutHashForHotfix(expectedSyntheticReaderLoaderURL, url) {
            self.expectedSyntheticReaderLoaderURL = nil
            debugPrint(
                "# READERLOAD stage=readerMode.syntheticExpectation.consume",
                "expectedURL=\(expectedSyntheticReaderLoaderURL.absoluteString)",
                "actualURL=\(url.absoluteString)"
            )
            return true
        }
        debugPrint(
            "# READERLOAD stage=readerMode.syntheticExpectation.miss",
            "expectedURL=\(expectedSyntheticReaderLoaderURL.absoluteString)",
            "actualURL=\(url.absoluteString)"
        )
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

    private func markSyntheticLoadIssued(for url: URL) {
        syntheticLoadIssuedAtByURL[canonicalRenderKey(url)] = Date()
    }

    private func clearSyntheticLoadIssued(for url: URL) {
        syntheticLoadIssuedAtByURL.removeValue(forKey: canonicalRenderKey(url))
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
        debugPrint(
            "# READERLOAD stage=readerMode.render.singleFlight.start",
            "url=\(canonicalURL.absoluteString)",
            "reason=\(reason)",
            "generation=\(generation.uuidString)"
        )
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
        let startedAt = CFAbsoluteTimeGetCurrent()
        let activeReaderFileManager = readerFileManager ?? .shared
        if let content = try? await readerContent.getContent(),
           let html = try? await locallyRetrievableReaderHTML(
                for: content,
                readerFileManager: activeReaderFileManager
           ),
           !html.isEmpty {
            debugPrint(
                "# READERLOAD stage=readerMode.route.resolve",
                "pageURL=\(readerContent.pageURL.absoluteString)",
                "route=\(ReaderModeRoute.localHTML.rawValue)",
                "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startedAt))s"
            )
            return .localHTML
        }
        if readabilityContent != nil {
            debugPrint(
                "# READERLOAD stage=readerMode.route.resolve",
                "pageURL=\(readerContent.pageURL.absoluteString)",
                "route=\(ReaderModeRoute.capturedReadability.rawValue)",
                "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startedAt))s"
            )
            return .capturedReadability
        }
        debugPrint(
            "# READERLOAD stage=readerMode.route.resolve",
            "pageURL=\(readerContent.pageURL.absoluteString)",
            "route=\(ReaderModeRoute.unavailable.rawValue)",
            "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startedAt))s"
        )
        return .unavailable
    }

    @MainActor
    func readerModeRouteForTesting(readerContent: ReaderContent) async -> String {
        await resolveReaderModeRoute(readerContent: readerContent).rawValue
    }
    
    @MainActor
    internal func showReaderView(readerContent: ReaderContent, scriptCaller: WebViewScriptCaller) {
        let contentURL = readerContent.pageURL
        let scheduledAt = CFAbsoluteTimeGetCurrent()
        beginReaderModeLoad(for: contentURL, reason: "showReaderView")
        logTrace(.readabilityTaskScheduled, url: contentURL, details: "readabilityBytes=\(readabilityContent?.utf8.count ?? 0)")
        _ = startRenderTaskIfNeeded(for: contentURL, reason: "showReaderView") { [weak self] generation in
            guard let self else { return }
            debugPrint(
                "# READERLOAD stage=readerMode.showReaderView.renderStart",
                "contentURL=\(contentURL.absoluteString)",
                "generation=\(generation.uuidString)",
                "elapsedSinceSchedule=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - scheduledAt))s"
            )
            guard urlsMatchWithoutHashForHotfix(contentURL, readerContent.pageURL) else {
                cancelReaderModeLoad(for: contentURL, reason: "showReaderView.urlMismatch")
                return
            }
            let route = await resolveReaderModeRoute(readerContent: readerContent)
            debugPrint(
                "# READERLOAD stage=readerMode.showReaderView.route",
                "contentURL=\(contentURL.absoluteString)",
                "route=\(route.rawValue)",
                "readabilityBytes=\(self.readabilityContent?.utf8.count ?? 0)"
            )
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
    public func beginSyntheticLoadForCurrentContentIfPossible(
        readerContent: ReaderContent,
        scriptCaller: WebViewScriptCaller
    ) async -> Bool {
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard let content = try? await readerContent.getContent() else {
            debugPrint(
                "# READERLOAD stage=readerMode.syntheticEntry",
                "result=missingContent",
                "pageURL=\(readerContent.pageURL.absoluteString)",
                "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startedAt))s"
            )
            return false
        }
        guard content.url.isSnippetURL else {
            debugPrint(
                "# READERLOAD stage=readerMode.syntheticEntry",
                "result=notSnippet",
                "contentURL=\(content.url.absoluteString)",
                "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startedAt))s"
            )
            return false
        }
        guard readerContent.pageURL.matchesReaderURL(content.url) else {
            debugPrint(
                "# READERLOAD stage=readerMode.syntheticEntry",
                "result=pageMismatch",
                "contentURL=\(content.url.absoluteString)",
                "pageURL=\(readerContent.pageURL.absoluteString)",
                "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startedAt))s"
            )
            return false
        }
        debugPrint(
            "# READERLOAD stage=readerMode.syntheticEntry",
            "result=starting",
            "contentURL=\(content.url.absoluteString)",
            "pageURL=\(readerContent.pageURL.absoluteString)",
            "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startedAt))s"
        )
        showReaderView(readerContent: readerContent, scriptCaller: scriptCaller)
        return true
    }

    @MainActor
    private func showReaderViewUsingSwiftProcessing(
        readerContent: ReaderContent,
        scriptCaller: WebViewScriptCaller,
        renderGeneration: UUID? = nil
    ) async {
        do {
            let swiftProcessingStart = CFAbsoluteTimeGetCurrent()
            let getContentStart = CFAbsoluteTimeGetCurrent()
            guard let content = try await readerContent.getContent() else {
                cancelReaderModeLoad(for: readerContent.pageURL, reason: "swiftProcessing.missingContent")
                return
            }
            debugPrint(
                "# READERLOAD stage=readerMode.swiftProcessing.getContent",
                "contentURL=\(content.url.absoluteString)",
                "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - getContentStart))s"
            )
            let activeReaderFileManager = readerFileManager ?? .shared
            let localHTMLStart = CFAbsoluteTimeGetCurrent()
            guard let html = try await locallyRetrievableReaderHTML(
                for: content,
                readerFileManager: activeReaderFileManager
            ) else {
                cancelReaderModeLoad(for: content.url, reason: "swiftProcessing.missingHTML")
                return
            }
            debugPrint(
                "# READERLOAD stage=readerMode.swiftProcessing.localHTML",
                "contentURL=\(content.url.absoluteString)",
                "bytes=\(html.utf8.count)",
                "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - localHTMLStart))s"
            )

            let resolvedReadabilityHTML: String?
            if hasCanonicalReadabilityMarkup(in: html) {
                resolvedReadabilityHTML = html
            } else {
                let readabilityProcessingStart = CFAbsoluteTimeGetCurrent()
                let swiftReadability = await processReadabilityHTMLInSwift(
                    html: html,
                    url: content.url,
                    snippetPublishedTime: content.humanReadablePublicationDate,
                    meaningfulContentMinChars: max(content.meaningfulContentMinLength, 1)
                )
                debugPrint(
                    "# READERLOAD stage=readerMode.swiftProcessing.readabilityResolved",
                    "contentURL=\(content.url.absoluteString)",
                    "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - readabilityProcessingStart))s"
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
                let showReadabilityStart = CFAbsoluteTimeGetCurrent()
                try await showReadabilityContent(
                    readerContent: readerContent,
                    readabilityContent: resolvedReadabilityHTML,
                    renderToSelector: nil,
                    in: nil,
                    scriptCaller: scriptCaller,
                    renderGeneration: renderGeneration
                )
                debugPrint(
                    "# READERLOAD stage=readerMode.swiftProcessing.showReadabilityContent",
                    "contentURL=\(content.url.absoluteString)",
                    "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - showReadabilityStart))s"
                )
                debugPrint(
                    "# READERLOAD stage=readerMode.swiftProcessing.complete",
                    "contentURL=\(content.url.absoluteString)",
                    "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - swiftProcessingStart))s",
                    "mode=readability"
                )
                return
            }

            readabilityContent = nil
            let directHTML = prepareHTMLForDirectLoad(html)
            let directHTMLHasBody = directHTML.contains("<body")
            let directHTMLHasArticle = directHTML.contains("<article")
            debugPrint(
                "# READERLOAD stage=readerMode.swiftProcessing.directHTML",
                "contentURL=\(content.url.absoluteString)",
                "sourceHTMLBytes=\(html.utf8.count)",
                "directHTMLBytes=\(directHTML.utf8.count)",
                "hasBody=\(directHTMLHasBody)",
                "hasArticle=\(directHTMLHasArticle)"
            )
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
            debugPrint(
                "# READERLOAD stage=readerMode.swiftProcessing.complete",
                "contentURL=\(content.url.absoluteString)",
                "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - swiftProcessingStart))s",
                "mode=directHTML"
            )
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
        let totalStart = CFAbsoluteTimeGetCurrent()
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

        if currentReaderFontNeedsDeferredSharedCSS() {
            let sharedFontStart = CFAbsoluteTimeGetCurrent()
            _ = await resolveSharedReaderFontCSSBase64()
            debugPrint(
                "# READERLOAD stage=readerMode.showReadabilityContent.sharedFontResolve",
                "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - sharedFontStart))s"
            )
        }
        
        let injectEntryImageIntoHeader = content.injectEntryImageIntoHeader
        let titleForDisplay = content.titleForDisplay
        let imageURLToDisplay = try await content.imageURLToDisplay()
        let processReadabilityContent = processReadabilityContent
        let processHTML = processHTML
        let prefersDirectSnippetReadabilityParse = url.isSnippetURL && hasCanonicalReadabilityMarkup(in: readabilityContent)
        let snippetRawTitle = content.title
        let snippetNeedsClipboardIndicator = content.needsClipboardIndicator
        let hideRedundantSnippetTitle = content.isTitlePrefixOfContent
        
        let renderDispatchStart = CFAbsoluteTimeGetCurrent()
        try await { @ReaderViewModelActor [weak self] in
            let transformStart = CFAbsoluteTimeGetCurrent()
            var doc: SwiftSoup.Document?
            
            if let processReadabilityContent, !prefersDirectSnippetReadabilityParse {
                let parseStart = CFAbsoluteTimeGetCurrent()
                doc = try await processReadabilityContent(
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
                debugPrint(
                    "# READERLOAD stage=readerMode.showReadabilityContent.parse",
                    "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - parseStart))s",
                    "path=customProcessor"
                )
            } else {
                let parseStart = CFAbsoluteTimeGetCurrent()
                let isXML = readabilityContent.hasPrefix("<?xml") || readabilityContent.hasPrefix("<?XML") // TODO: Case insensitive
                let parser = isXML ? SwiftSoup.Parser.xmlParser() : SwiftSoup.Parser.htmlParser()
                doc = try SwiftSoup.parse(readabilityContent, url.absoluteString, parser)
                doc?.outputSettings().prettyPrint(pretty: false).syntax(syntax: isXML ? .xml : .html)
                doc?.outputSettings().charset(.utf8)
                if isXML {
                    doc?.outputSettings().escapeMode(.xhtml)
                }
                debugPrint(
                    "# READERLOAD stage=readerMode.showReadabilityContent.parse",
                    "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - parseStart))s",
                    "path=\(prefersDirectSnippetReadabilityParse ? "snippetCanonical" : "swiftSoup")"
                )
            }

            guard let doc else {
                print("Error: Unexpectedly failed to receive doc")
                return
            }
            let derivedTitle = titleFromReadabilityDocument(doc) ?? titleForDisplay
            let propagateStart = CFAbsoluteTimeGetCurrent()
            await propagateReaderModeDefaults(
                for: url,
                primaryRecord: content,
                readabilityHTML: readabilityContent,
                fallbackTitle: titleForDisplay,
                derivedTitle: derivedTitle
            )
            debugPrint(
                "# READERLOAD stage=readerMode.showReadabilityContent.propagateDefaults",
                "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - propagateStart))s"
            )

            let processForReaderModeStart = CFAbsoluteTimeGetCurrent()
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
            debugPrint(
                "# READERLOAD stage=readerMode.showReadabilityContent.processForReaderMode",
                "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - processForReaderModeStart))s"
            )

            if url.isSnippetURL {
                let cleanedSnippetTitle = ReaderContentLoader.resolvedDisplayTitle(
                    snippetRawTitle,
                    needsClipboardIndicator: snippetNeedsClipboardIndicator
                )
                if let titleElement = try? doc.getElementById("reader-title") {
                    try? titleElement.text(cleanedSnippetTitle)
                }
                if let body = doc.body() {
                    let existingClassNames = ((try? body.className()) ?? "")
                        .split(separator: " ")
                        .map(String.init)
                    var classNames = existingClassNames.filter { !$0.isEmpty }
                    if !classNames.contains("readability-mode") {
                        classNames.insert("readability-mode", at: 0)
                    }
                    let suppressionClass = ReaderContentLoader.snippetReaderTitleSuppressionBodyClass
                    classNames.removeAll { $0 == suppressionClass }
                    if hideRedundantSnippetTitle {
                        classNames.append(suppressionClass)
                    }
                    try? body.attr("class", classNames.joined(separator: " "))
                }
                debugPrint(
                    "# SNIPPETTITLE processedDocNormalize",
                    "url=\(url.absoluteString)",
                    "title=\(cleanedSnippetTitle)",
                    "hideReaderTitle=\(hideRedundantSnippetTitle)",
                    "bodyClasses=\((try? doc.body()?.className()) ?? "")"
                )
            }

            let processedSegmentCount = (try? doc.getElementsByTag("manabi-segment").size()) ?? 0
            let processedBodyExists = doc.body() != nil
            let processedBodyClasses = (try? doc.body()?.className()) ?? ""
            let processedTitleDisplayStyle = (try? doc.getElementById("reader-title")?.attr("style")) ?? ""
            debugPrint(
                "# READERTRACE",
                "readerMode.showReadabilityContent.processed",
                [
                    "contentURL": url.absoluteString,
                    "renderBaseURL": renderBaseURL.absoluteString,
                    "segmentCount": processedSegmentCount,
                    "hasBody": processedBodyExists,
                    "baseUri": doc.getBaseUri(),
                    "bodyClasses": processedBodyClasses,
                    "titleStyle": processedTitleDisplayStyle
                ] as [String: Any]
            )

            if let sharedFontCSSBase64 = await resolveSharedReaderFontCSSBase64(), !sharedFontCSSBase64.isEmpty {
                try? upsertDeferredSharedReaderFontGate(in: doc)
            }

            markReaderRenderReady(in: doc)

            let serializeStart = CFAbsoluteTimeGetCurrent()
            let serializedHTMLBytes = try doc.outerHtmlUTF8()
            debugPrint(
                "# READERLOAD stage=readerMode.showReadabilityContent.serialize",
                "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - serializeStart))s",
                "bytes=\(serializedHTMLBytes.count)"
            )

            var transformedHTMLBytes = serializedHTMLBytes
            var transformedHTMLString: String?
            if let processHTML {
                let processHTMLStart = CFAbsoluteTimeGetCurrent()
                let serializedHTML = String(decoding: serializedHTMLBytes, as: UTF8.self)
                let processedHTML = await processHTML(
                    serializedHTML,
                    false
                )
                transformedHTMLString = processedHTML
                transformedHTMLBytes = Array(processedHTML.utf8)
                debugPrint(
                    "# READERLOAD stage=readerMode.showReadabilityContent.processHTML",
                    "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - processHTMLStart))s",
                    "bytes=\(transformedHTMLBytes.count)"
                )
            }

            debugPrint(
                "# READERLOAD stage=readerMode.showReadabilityContent.transformed",
                "renderBaseURL=\(renderBaseURL.absoluteString)",
                "bytes=\(transformedHTMLBytes.count)",
                "segmentCount=\(processedSegmentCount)",
                "hasBody=\(processedBodyExists)",
                "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - transformStart))s"
            )
            let mainActorHandoffStart = CFAbsoluteTimeGetCurrent()
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
                if let frameInfo = frameInfo, !frameInfo.isMainFrame {
                    let transformedContent = transformedHTMLString ?? String(decoding: transformedHTMLBytes, as: UTF8.self)
                    let transformedBodyClasses = {
                        guard let document = try? SwiftSoup.parse(transformedContent),
                              let bodyClassNames = try? document.body()?.className() else {
                            return "readability-mode"
                        }
                        let trimmed = bodyClassNames.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? "readability-mode" : trimmed
                    }()
                    let transformedStyleText = {
                        guard let document = try? SwiftSoup.parse(transformedContent),
                              let styleHTML = try? document.getElementById("swiftuiwebview-readability-styles")?.html() else {
                            return Readability.shared.css
                        }
                        return styleHTML.isEmpty ? Readability.shared.css : styleHTML
                    }()
                    debugPrint(
                        "# SNIPPETTITLE frameInjection",
                        "url=\(url.absoluteString)",
                        "bodyClasses=\(transformedBodyClasses)",
                        "styleBytes=\(transformedStyleText.utf8.count)"
                    )
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
                        
                        let existingStyle = document.getElementById('swiftuiwebview-readability-styles')
                        if (existingStyle) {
                            existingStyle.textContent = css
                        } else {
                            let style = document.createElement('style')
                            style.id = 'swiftuiwebview-readability-styles'
                            style.textContent = css
                            document.head.appendChild(style)
                        }
                        if (document.body) {
                            document.body.className = bodyClassNames || 'readability-mode'
                        }
                        """,
                        arguments: [
                            "renderToSelector": renderToSelector ?? "",
                            "html": transformedContent,
                            "css": transformedStyleText,
                            "bodyClassNames": transformedBodyClasses,
                        ], in: frameInfo)
                    self?.markReaderModeLoadComplete(for: url)
                } else {
                    let htmlData = Data(transformedHTMLBytes)
                    self?.markSyntheticLoadIssued(for: renderBaseURL)
                    self?.expectSyntheticReaderLoaderCommit(for: renderBaseURL)
                    self?.logTrace(.navigatorLoad, url: url, details: "mode=readability-html | bytes=\(htmlData.count)")
                    debugPrint(
                        "# READERLOAD stage=readerMode.syntheticLoad.data",
                        "contentURL=\(url.absoluteString)",
                        "renderBaseURL=\(renderBaseURL.absoluteString)",
                        "bytes=\(htmlData.count)"
                    )
                    navigator?.load(
                        htmlData,
                        mimeType: "text/html",
                        characterEncodingName: "UTF-8",
                        baseURL: renderBaseURL
                    )
                }
//                try await { @MainActor in
//                    readerModeLoading(false)
//                }()
            }()
            debugPrint(
                "# READERLOAD stage=readerMode.showReadabilityContent.mainActorHandoff",
                "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - mainActorHandoffStart))s",
                "renderBaseURL=\(renderBaseURL.absoluteString)"
            )
        }()
        debugPrint(
            "# READERLOAD stage=readerMode.showReadabilityContent.renderDispatch",
            "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - renderDispatchStart))s",
            "renderBaseURL=\(renderBaseURL.absoluteString)"
        )

        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        if injectEntryImageIntoHeader && content.imageUrl == nil {
            let metadataRefreshStart = CFAbsoluteTimeGetCurrent()
            schedulePostRenderMetadataRefreshIfNeeded(
                content: content,
                contentURL: canonicalURL
            )
            debugPrint(
                "# READERLOAD stage=readerMode.showReadabilityContent.metadataRefreshSchedule",
                "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - metadataRefreshStart))s",
                "contentURL=\(canonicalURL.absoluteString)"
            )
        }
        debugPrint(
            "# READERLOAD stage=readerMode.showReadabilityContent.total",
            "contentURL=\(canonicalURL.absoluteString)",
            "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - totalStart))s"
        )
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
        snippetPublishedTime: String? = nil,
        meaningfulContentMinChars: Int
    ) async -> SwiftReadabilityProcessingOutcome {
        guard canHaveReadabilityContent(for: url) else {
            return .unavailable
        }

        let normalizedHTML = ensureReadabilityBodyExists(html)
        if url.isSnippetURL,
           let snippetHTML = buildSnippetCanonicalReadabilityHTML(
                html: normalizedHTML,
                contentURL: url,
                fallbackTitle: titleFromReadabilityHTML(normalizedHTML),
                publishedTime: snippetPublishedTime
           ) {
            debugPrint(
                "# SNIPPETS",
                "processReadabilityHTMLInSwift",
                "snippetBypassReadability=true",
                "url=\(url.absoluteString)",
                "contentBytes=\(normalizedHTML.utf8.count)"
            )
            return .success(SwiftReadabilityProcessingResult(outputHTML: snippetHTML))
        }
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
                    fallbackTitle: titleFromReadabilityHTML(normalizedHTML),
                    publishedTime: snippetPublishedTime
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
        if !scriptCaller.hasAsyncCaller {
            debugPrint("# READER paginationBookKey.set.skip", "reason=asyncCallerNil", "url=\(newState.pageURL.absoluteString)")
        } else {
            do {
                try await scriptCaller.evaluateJavaScript(
                    "window.paginationTrackingBookKey = bookKey;",
                    arguments: ["bookKey": newState.pageURL.absoluteString],
                    in: nil,
                    duplicateInMultiTargetFrames: true
                )
                debugPrint("# READER paginationBookKey.set", "key=\(newState.pageURL.absoluteString.prefix(72))…")
            } catch {
                debugPrint("# READER paginationBookKey.set.error", error.localizedDescription)
            }
        }

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
            let loaderStartedAt = Date()
            debugPrint(
                "# READERLOAD stage=readerMode.navCommit.loaderBegin",
                "loaderURL=\(newState.pageURL.absoluteString)",
                "contentURL=\(committedURL.absoluteString)",
                "currentPageURL=\(readerContent.pageURL.absoluteString)",
                "hasReaderFileManager=\(readerFileManager != nil)",
                "hasExistingReadability=\(readabilityContent != nil)"
            )
            if let readerFileManager {
                let htmlResolutionStartedAt = Date()
                let html = try await content.htmlToDisplay(readerFileManager: readerFileManager)
                debugPrint(
                    "# READERLOAD stage=readerMode.navCommit.loaderHTMLResolved",
                    "contentURL=\(committedURL.absoluteString)",
                    "hasHTML=\(html != nil)",
                    "htmlBytes=\(html?.utf8.count ?? 0)",
                    "elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(htmlResolutionStartedAt)))"
                )
                if let html {
                    try Task.checkCancellation()

                    let currentURL = readerContent.pageURL
                    guard committedURL.matchesReaderURL(currentURL) else {
                        print("URL mismatch in ReaderModeViewModel onNavigationCommitted", currentURL, committedURL)
                        cancelReaderModeLoad(for: committedURL, reason: "navCommit.currentURLMismatch")
                        return
                    }
                    let usedSnippetCanonical: Bool
                    let usedCanonicalMarkup: Bool
                    if committedURL.isSnippetURL,
                       let snippetHTML = buildSnippetCanonicalReadabilityHTML(
                        html: html,
                        contentURL: committedURL,
                        fallbackTitle: titleFromReadabilityHTML(html) ?? content.title,
                        publishedTime: content.humanReadablePublicationDate,
                        preferredTitle: content.title,
                        hideReaderTitleOverride: content.isTitlePrefixOfContent
                       ) {
                        readabilityContent = snippetHTML
                        usedSnippetCanonical = true
                        usedCanonicalMarkup = false
                    } else if hasCanonicalReadabilityMarkup(in: html) {
                        readabilityContent = html
                        usedSnippetCanonical = false
                        usedCanonicalMarkup = true
                    } else {
                        readabilityContent = nil
                        usedSnippetCanonical = false
                        usedCanonicalMarkup = false
                    }
                    debugPrint(
                        "# READERLOAD stage=readerMode.navCommit.loaderReadabilityPrepared",
                        "contentURL=\(committedURL.absoluteString)",
                        "readabilityBytes=\(readabilityContent?.utf8.count ?? 0)",
                        "usedSnippetCanonical=\(usedSnippetCanonical)",
                        "usedCanonicalMarkup=\(usedCanonicalMarkup)"
                    )
                    readerContent.isRenderingReaderHTML = true
                    debugPrint(
                        "# READERLOAD stage=readerMode.navCommit.loaderShowReaderView",
                        "contentURL=\(committedURL.absoluteString)",
                        "elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(loaderStartedAt)))"
                    )
                    showReaderView(
                        readerContent: readerContent,
                        scriptCaller: scriptCaller
                    )
                } else {
                    debugPrint(
                        "# READERLOAD stage=readerMode.navCommit.loaderHTMLMissing",
                        "contentURL=\(committedURL.absoluteString)",
                        "elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(loaderStartedAt)))"
                    )
                    guard let navigator else {
                        print("Error: No navigator set in ReaderModeViewModel onNavigationCommitted")
                        return
                    }
                    navigator.load(URLRequest(url: committedURL))
                }
            } else {
                debugPrint(
                    "# READERLOAD stage=readerMode.navCommit.loaderNoReaderFileManager",
                    "contentURL=\(committedURL.absoluteString)",
                    "elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(loaderStartedAt)))"
                )
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
    let processStartedAt = Date()
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
            let bodyAttributesStartedAt = Date()
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
            debugPrint(
                "# READERLOAD stage=readerMode.processForReaderMode.bodyAttributes",
                "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(bodyAttributesStartedAt)))s"
            )
        }
        
        if let defaultTitle = defaultTitle, let existing = try? doc.getElementById("reader-title"), !existing.hasText() {
            let titleFallbackStartedAt = Date()
            let escapedTitle = Entities.escape(defaultTitle, OutputSettings().charset(String.Encoding.utf8).escapeMode(Entities.EscapeMode.extended))
            do {
                try existing.html(escapedTitle)
            } catch { }
            debugPrint(
                "# READERLOAD stage=readerMode.processForReaderMode.titleFallback",
                "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(titleFallbackStartedAt)))s"
            )
        }
        
        if !isEBook {
            let fixTitlesStartedAt = Date()
            do {
                try fixAnnoyingTitlesWithPipes(doc: doc)
            } catch { }
            debugPrint(
                "# READERLOAD stage=readerMode.processForReaderMode.fixTitles",
                "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(fixTitlesStartedAt)))s"
            )
        }
        
        if try injectEntryImageIntoHeader || (doc.body()?.getElementsByTag(UTF8Arrays.img).isEmpty() ?? true), let imageURL = imageURL, let existing = try? doc.select("img[src='\(imageURL.absoluteString)'"), existing.isEmpty() {
            let headerImageStartedAt = Date()
            do {
                try doc.getElementById("reader-header")?.prepend("<img src='\(imageURL.absoluteString)'>")
            } catch { }
            debugPrint(
                "# READERLOAD stage=readerMode.processForReaderMode.headerImage",
                "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(headerImageStartedAt)))s"
            )
        }
    }
    debugPrint(
        "# READERLOAD stage=readerMode.processForReaderMode.complete",
        "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(processStartedAt)))s"
    )
}
