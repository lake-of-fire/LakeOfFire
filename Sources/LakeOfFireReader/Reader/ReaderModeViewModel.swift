import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
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

private let readerModeReadabilityCSS = Readability.shared.css

internal func upsertDeferredSharedReaderFontGate(in doc: SwiftSoup.Document) throws {
    let gateCSS = """
    html[data-mnb-font-pending="1"] body.readability-mode {
        visibility: hidden !important;
    }
    """

    let htmlElement = try doc.getElementsByTag("html").first()
    try htmlElement?.attr("data-mnb-font-pending", "1")
    try htmlElement?.attr("data-mnb-font-ready", "0")

    if let existingStyle = try doc.getElementById("mnb-custom-font-gate") {
        try existingStyle.text(gateCSS)
        return
    }

    let styleElement = try doc.createElement("style")
    try styleElement.attr("id", "mnb-custom-font-gate")
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
private let readerContentPublicationDateFallbackFormatter: DateFormatter = {
    ReaderDateFormatter.makeAbsoluteFormatter(dateStyle: .short)
}()
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

private func logTitleTrace(_ message: String) {
#if DEBUG
#endif
}

private extension String {
    var debugTitleFragment: String {
        let normalized = replacingOccurrences(of: "\n", with: "\\n")
        if normalized.isEmpty {
            return "\"\""
        }
        return "\"\(normalized.truncate(120, trailing: "…"))\""
    }
}

private extension Optional where Wrapped == String {
    var debugTitleFragment: String {
        guard let value = self else { return "<nil>" }
        return value.debugTitleFragment
    }
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

private struct ReaderContentPublicationDateSnapshot: Sendable {
    let publicationDate: Date
    let displayAbsolutePublicationDate: Bool
    let contentType: String
}

private struct ReaderContentRenderSnapshot: Sendable {
    let url: URL
    let title: String
    let isTitlePrefixOfContent: Bool
}

private func formattedReaderContentPublicationDate(_ snapshot: ReaderContentPublicationDateSnapshot) -> String {
    if snapshot.displayAbsolutePublicationDate {
        return ReaderDateFormatter.absoluteString(from: snapshot.publicationDate, dateFormatter: readerContentPublicationDateFallbackFormatter)
    }
    return ReaderDateFormatter.relativeString(from: snapshot.publicationDate)
        ?? ReaderDateFormatter.absoluteString(from: snapshot.publicationDate, dateFormatter: readerContentPublicationDateFallbackFormatter)
}

internal func readerContentPublicationDateFallback(for url: URL) async -> String? {
    let resolvedURL = ReaderContentLoader.getContentURL(fromLoaderURL: url) ?? url
    let snapshot = try? await { @RealmBackgroundActor () -> ReaderContentPublicationDateSnapshot? in
        let matches = try await ReaderContentLoader.loadAll(url: resolvedURL)
        let candidates = matches.compactMap { content -> ReaderContentPublicationDateSnapshot? in
            guard content.displayPublicationDate || content.isPhysicalMedia,
                  let publicationDate = content.publicationDate else {
                return nil
            }
            return ReaderContentPublicationDateSnapshot(
                publicationDate: publicationDate,
                displayAbsolutePublicationDate: content.displayAbsolutePublicationDate,
                contentType: String(describing: type(of: content))
            )
        }
        return candidates.first { $0.contentType != String(describing: HistoryRecord.self) } ?? candidates.first
    }()

    guard let snapshot else {
        return nil
    }

    let fallback = formattedReaderContentPublicationDate(snapshot)
    return fallback
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
    let readerFontSize = UserDefaults.standard.object(forKey: "readerFontSize") as? Double
    let viewOriginal = isInternalReaderURL(contentURL) ? nil : "<a class=\"reader-view-original\" href=\"\(escapeReadabilityHTMLAttribute(contentURL.absoluteString))\">View Original</a>"
    let bylineLine = resolvedByline.isEmpty
        ? ""
        : "<div id=\"reader-byline-line\" class=\"byline-line\"><span class=\"byline-label\">By</span> <span id=\"reader-byline\" class=\"byline\">\(resolvedByline)</span></div>"
    let publicationDateText = publishedTime.map(escapeReadabilityText)
    let metaItems = [
        publicationDateText.map { "<span id=\"reader-publication-date\">\($0)</span>" },
        viewOriginal,
    ]
        .compactMap { $0 }
    let metaLine = metaItems.isEmpty
        ? ""
        : """
        <div id="reader-meta-line" class="byline-meta-line">\(metaItems.joined(separator: "<span class=\"reader-meta-divider\">·</span>"))</div>
        """
    let actionLine = """
        <div id="reader-header-actions"></div>
        """
    let availabilityAttributes = "data-mnb-reader-mode-available=\"true\" data-mnb-reader-mode-available-for=\"\(escapeReadabilityHTMLAttribute(contentURL.absoluteString))\" data-mnb-reader-render-ready=\"1\""
    let suppressionBodyClass = ReaderContentLoader.snippetReaderTitleSuppressionBodyClass
    let bodyStyle = readerAdaptiveMaxWidthStyleDeclaration(readerFontSize: readerFontSize)
    let titleSuppressionCSS = """
    body.\(suppressionBodyClass) #reader-title {
        display: none !important;
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
            <style type="text/css" id="swiftuiwebview-readability-styles">\(readerModeReadabilityCSS)
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
                \(actionLine)
            </div>
            <div id="reader-content">
                \(content)
            </div>
            <script>
                \(Readability.shared.scripts)
                (function() {
                    const bootstrapNow = (typeof performance !== 'undefined' && typeof performance.now === 'function')
                        ? performance.now.bind(performance)
                        : () => Date.now();
                    const bootstrapStartedAt = bootstrapNow();
                    let firstNonZeroReaderContentReason = null;
                    let firstNonZeroReaderContentElapsedMs = null;
                    let firstNonZeroBodyReason = null;
                    let firstNonZeroBodyElapsedMs = null;
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
                    const postInvisibleLog = (payload) => {
                        try {
                            const message = '# INVISIBLE ' + JSON.stringify(payload);
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
                    const elapsedMs = () => Math.round((bootstrapNow() - bootstrapStartedAt) * 1000) / 1000;
                    const describeNode = (node) => {
                        if (!node || typeof node.getBoundingClientRect !== 'function') {
                            return null;
                        }
                        const rect = node.getBoundingClientRect();
                        const style = window.getComputedStyle(node);
                        return {
                            tag: node.tagName || null,
                            id: node.id || null,
                            className: typeof node.className === 'string' ? node.className : null,
                            textLength: (node.textContent || '').trim().length,
                            display: style.display,
                            visibility: style.visibility,
                            opacity: style.opacity,
                            color: style.color,
                            backgroundColor: style.backgroundColor,
                            rect: {
                                x: Math.round(rect.x),
                                y: Math.round(rect.y),
                                width: Math.round(rect.width),
                                height: Math.round(rect.height),
                            },
                        };
                    };
                    const summarizeElement = (id) => {
                        const el = document.getElementById(id);
                        if (!el) {
                            return { id, exists: false };
                        }
                        const rect = el.getBoundingClientRect();
                        const style = window.getComputedStyle(el);
                        return {
                            id,
                            exists: true,
                            childCount: el.childElementCount,
                            textLength: (el.textContent || '').trim().length,
                            htmlLength: (el.innerHTML || '').length,
                            display: style.display,
                            visibility: style.visibility,
                            opacity: style.opacity,
                            color: style.color,
                            backgroundColor: style.backgroundColor,
                            rect: {
                                x: Math.round(rect.x),
                                y: Math.round(rect.y),
                                width: Math.round(rect.width),
                                height: Math.round(rect.height),
                            },
                            clientHeight: el.clientHeight,
                            clientWidth: el.clientWidth,
                            scrollHeight: el.scrollHeight,
                            scrollWidth: el.scrollWidth,
                        };
                    };
                    const summarizeStylesheets = () => {
                        const readabilityStyle = document.getElementById('swiftuiwebview-readability-styles');
                        return {
                            styleTagCount: document.querySelectorAll('style').length,
                            stylesheetCount: document.styleSheets ? document.styleSheets.length : null,
                            readabilityStyleExists: !!readabilityStyle,
                            readabilityStyleLength: readabilityStyle?.textContent?.length ?? null,
                        };
                    };
                    const summarizeFonts = () => {
                        const body = document.body;
                        const title = document.getElementById('reader-title');
                        const bodyStyle = body ? window.getComputedStyle(body) : null;
                        const titleStyle = title ? window.getComputedStyle(title) : null;
                        return {
                            fontsApiPresent: !!document.fonts,
                            fontsStatus: document.fonts?.status ?? null,
                            bodyFontFamily: bodyStyle?.fontFamily ?? null,
                            bodyFontSize: bodyStyle?.fontSize ?? null,
                            bodyLineHeight: bodyStyle?.lineHeight ?? null,
                            titleFontFamily: titleStyle?.fontFamily ?? null,
                            titleFontSize: titleStyle?.fontSize ?? null,
                        };
                    };
                    const summarizePaint = () => {
                        try {
                            if (typeof performance === 'undefined' || typeof performance.getEntriesByType !== 'function') {
                                return null;
                            }
                            return performance.getEntriesByType('paint').map((entry) => ({
                                name: entry.name,
                                startTimeMs: Math.round(entry.startTime * 1000) / 1000,
                                durationMs: Math.round(entry.duration * 1000) / 1000,
                            }));
                        } catch (_) {
                            return null;
                        }
                    };
                    const summarizeNavigation = () => {
                        try {
                            if (typeof performance === 'undefined' || typeof performance.getEntriesByType !== 'function') {
                                return null;
                            }
                            const navigationEntry = performance.getEntriesByType('navigation')[0];
                            if (!navigationEntry) { return null; }
                            return {
                                type: navigationEntry.type ?? null,
                                domContentLoadedEventStartMs: Math.round((navigationEntry.domContentLoadedEventStart || 0) * 1000) / 1000,
                                domContentLoadedEventEndMs: Math.round((navigationEntry.domContentLoadedEventEnd || 0) * 1000) / 1000,
                                loadEventStartMs: Math.round((navigationEntry.loadEventStart || 0) * 1000) / 1000,
                                loadEventEndMs: Math.round((navigationEntry.loadEventEnd || 0) * 1000) / 1000,
                                responseEndMs: Math.round((navigationEntry.responseEnd || 0) * 1000) / 1000,
                            };
                        } catch (_) {
                            return null;
                        }
                    };
                    const summarizeImages = () => {
                        const images = Array.from(document.images || []);
                        const pending = images.filter((img) => !img.complete);
                        const largest = images
                            .map((img) => {
                                const rect = typeof img.getBoundingClientRect === 'function' ? img.getBoundingClientRect() : null;
                                return {
                                    src: img.currentSrc || img.src || null,
                                    complete: img.complete,
                                    naturalWidth: img.naturalWidth,
                                    naturalHeight: img.naturalHeight,
                                    rectWidth: rect ? Math.round(rect.width) : null,
                                    rectHeight: rect ? Math.round(rect.height) : null,
                                };
                            })
                            .sort((lhs, rhs) => ((rhs.rectWidth || 0) * (rhs.rectHeight || 0)) - ((lhs.rectWidth || 0) * (lhs.rectHeight || 0)))
                            .slice(0, 3);
                        return {
                            totalCount: images.length,
                            pendingCount: pending.length,
                            largest,
                        };
                    };
                    const summarizeViewportCenter = () => {
                        const centerX = Math.max(0, Math.round(window.innerWidth / 2));
                        const centerY = Math.max(0, Math.round(window.innerHeight / 2));
                        const node = document.elementFromPoint(centerX, centerY);
                        return {
                            centerX,
                            centerY,
                            elementAtCenter: describeNode(node),
                            closestReaderContent: describeNode(node?.closest?.('#reader-content') ?? null),
                            visibleMarkAsReadButtons: Array.from(document.querySelectorAll('.mnb-mark-section-as-read-button')).filter((button) => {
                                const style = getComputedStyle(button);
                                return style.display !== 'none'
                                    && style.visibility !== 'hidden'
                                    && Number.parseFloat(style.opacity || '1') > 0.01;
                            }).length,
                        };
                    };
                    const trackFirstNonZeroGeometry = (reason) => {
                        const body = document.body;
                        const content = document.getElementById('reader-content');
                        if (!firstNonZeroBodyReason && body) {
                            const bodyRect = body.getBoundingClientRect();
                            if (bodyRect.width > 0 && bodyRect.height > 0) {
                                firstNonZeroBodyReason = reason;
                                firstNonZeroBodyElapsedMs = elapsedMs();
                            }
                        }
                        if (!firstNonZeroReaderContentReason && content) {
                            const contentRect = content.getBoundingClientRect();
                            if (contentRect.width > 0 && contentRect.height > 0) {
                                firstNonZeroReaderContentReason = reason;
                                firstNonZeroReaderContentElapsedMs = elapsedMs();
                            }
                        }
                    };
                    const emitInvisible = (reason) => {
                        const body = document.body;
                        const html = document.documentElement;
                        const bodyStyle = body ? window.getComputedStyle(body) : null;
                        const htmlStyle = html ? window.getComputedStyle(html) : null;
                        trackFirstNonZeroGeometry(reason);
                        postInvisibleLog({
                            reason,
                            elapsedMs: elapsedMs(),
                            href: window.location.href,
                            readyState: document.readyState,
                            bodyClassName: body ? body.className : null,
                            bodyTextLength: body ? (body.textContent || '').trim().length : null,
                            bodyChildCount: body ? body.childElementCount : null,
                            bodyDisplay: bodyStyle ? bodyStyle.display : null,
                            bodyVisibility: bodyStyle ? bodyStyle.visibility : null,
                            bodyOpacity: bodyStyle ? bodyStyle.opacity : null,
                            bodyColor: bodyStyle ? bodyStyle.color : null,
                            bodyBackgroundColor: bodyStyle ? bodyStyle.backgroundColor : null,
                            bodyRect: body ? {
                                width: Math.round(body.getBoundingClientRect().width),
                                height: Math.round(body.getBoundingClientRect().height),
                            } : null,
                            htmlDisplay: htmlStyle ? htmlStyle.display : null,
                            htmlVisibility: htmlStyle ? htmlStyle.visibility : null,
                            htmlOpacity: htmlStyle ? htmlStyle.opacity : null,
                            firstNonZeroBodyReason,
                            firstNonZeroBodyElapsedMs,
                            firstNonZeroReaderContentReason,
                            firstNonZeroReaderContentElapsedMs,
                            viewport: {
                                innerWidth: window.innerWidth,
                                innerHeight: window.innerHeight,
                                scrollX: Math.round(window.scrollX),
                                scrollY: Math.round(window.scrollY),
                            },
                            navigation: summarizeNavigation(),
                            paintEntries: summarizePaint(),
                            stylesheets: summarizeStylesheets(),
                            fonts: summarizeFonts(),
                            images: summarizeImages(),
                            viewportCenter: summarizeViewportCenter(),
                            readerHeader: summarizeElement('reader-header'),
                            readerTitle: summarizeElement('reader-title'),
                            readerContent: summarizeElement('reader-content'),
                        });
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
                        emitInvisible('emit');
                    };
                    if (document.readyState === 'loading') {
                        document.addEventListener('DOMContentLoaded', () => {
                            emitInvisible('DOMContentLoaded');
                            emit();
                        }, { once: true });
                    } else {
                        emit();
                    }
                    document.addEventListener('visibilitychange', () => emitInvisible('visibilitychange'));
                    window.addEventListener('pageshow', () => emitInvisible('pageshow'), { once: true });
                    window.addEventListener('resize', () => emitInvisible('resize'));
                    window.addEventListener('load', () => emitInvisible('load'), { once: true });
                    requestAnimationFrame(() => emitInvisible('requestAnimationFrame'));
                    setTimeout(() => emitInvisible('timeout-100ms'), 100);
                    setTimeout(() => emitInvisible('timeout-500ms'), 500);
                    setTimeout(() => emitInvisible('timeout-1500ms'), 1500);
                    if (document.fonts && typeof document.fonts.ready?.then === 'function') {
                        document.fonts.ready.then(() => emitInvisible('fonts-ready')).catch(() => emitInvisible('fonts-ready-error'));
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
    try? doc.select("html").first()?.attr("data-mnb-reader-render-ready", "1")
    try? doc.body()?.attr("data-mnb-reader-render-ready", "1")
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
    let extractedPublicationDate = (try? document.getElementById("reader-publication-date")?.text(trimAndNormaliseWhitespace: false))
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
    let resolvedPublishedTime = trimmedNonEmptyReadabilityText(publishedTime)
        ?? trimmedNonEmptyReadabilityText(extractedPublicationDate)
    let sanitizedContent = sanitizeReadabilityFragment(extractedContent)
    let shouldHideReaderTitle = hideReaderTitleOverride
        ?? ReaderContentLoader.snippetTitleMatchesGeneratedPrefix(
            resolvedTitle,
            sourceHTML: extractedContent
        )
    guard !sanitizedContent.isEmpty else {
        return nil
    }

    return buildCanonicalReadabilityHTML(
        title: sanitizedTitle,
        byline: sanitizedByline,
        publishedTime: resolvedPublishedTime,
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
        return nil
    }
    let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
    let result = trimmed.isEmpty ? nil : trimmed
    return result
}

private func propagateReaderModeDefaults(
    for url: URL,
    primaryKey: String,
    readabilityHTML: String,
    fallbackTitle: String?,
    derivedTitle: String? = nil
) async {
    let startedAt = Date()
    if url.isSnippetURL {
        return
    }
    let resolvedTitle = derivedTitle ?? titleFromReadabilityHTML(readabilityHTML) ?? fallbackTitle
    do {
        try await propagateReaderModeDefaultsOnBackgroundActor(
            for: url,
            primaryKey: primaryKey,
            readabilityHTML: readabilityHTML,
            resolvedTitle: resolvedTitle
        )
    } catch {
    }
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

    let writableRecords = relatedRecords.filter { $0.compoundKey != primaryKey && $0.realm != nil }
    guard !writableRecords.isEmpty else {
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
}

@MainActor
public class ReaderModeViewModel: ObservableObject {
    public var readerFileManager: ReaderFileManager?
    @Published public var ebookTextProcessorCacheHits: ((URL, String) async throws -> Bool)? = nil
    @Published public var processReadabilityContent: ((String, URL, URL?, Bool, ((SwiftSoup.Document) async -> SwiftSoup.Document)) async throws -> SwiftSoup.Document)? = nil
    @Published public var processHTMLBytes: (([UInt8], Bool) async -> [UInt8])? = nil
    @Published public var processHTML: ((String, Bool) async -> String)? = nil
    public var navigator: WebViewNavigator?
    public var defaultFontSize: Double?
    @Published public var sharedFontCSSBase64: String?
    @Published public var sharedFontCSSBase64Provider: (() async -> String?)?
    @Published public var sharedReaderFontAsset: SharedReaderFontAsset?
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
    private var completedRenderGenerationByURL: [String: UUID] = [:]
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
        logStateSnapshot("cancelLoad", url: completedURL)
        if let url {
            cancelActiveRender(for: url, reason: "cancelReaderModeLoad.\(reason)")
        }
        updatePendingReaderModeURL(nil, reason: "cancelReaderModeLoad")
        expectedSyntheticReaderLoaderURL = nil
        lastRenderedURL = nil
        if let completedURL {
            completedRenderGenerationByURL.removeValue(forKey: canonicalRenderKey(completedURL))
        }
        readerModeLoading(false)
        if let completedURL {
            let elapsed = loadStartTimes[completedURL.absoluteString].map { formattedInterval(Date().timeIntervalSince($0)) } ?? "nil"
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
        updatePendingReaderModeURL(nil, reason: "markReaderModeLoadComplete")
        expectedSyntheticReaderLoaderURL = nil
        readerModeLoading(false)
        let renderKey = canonicalRenderKey(canonicalURL)
        if let activeGeneration = activeRenderGenerationByURL[renderKey] {
            completedRenderGenerationByURL[renderKey] = activeGeneration
        }
        lastRenderedURL = canonicalURL
        readerModeLoadCompletionHandler?(canonicalURL)
        let elapsed = loadStartTimes[canonicalURL.absoluteString].map { formattedInterval(Date().timeIntervalSince($0)) } ?? "nil"
        if let startedAt = loadStartTimes[canonicalURL.absoluteString] {
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
        guard shouldClear else { return }
        cancelActiveRender(for: canonicalURL, reason: "clearReadabilityCache.\(reason)")
        cancelMetadataRefresh(for: canonicalURL, reason: "clearReadabilityCache.\(reason)")
        readabilityContent = nil
        readabilityContainerSelector = nil
        readabilityContainerFrameInfo = nil
        expectedSyntheticReaderLoaderURL = nil
        if matchesLastRendered {
            lastRenderedURL = nil
            completedRenderGenerationByURL.removeValue(forKey: canonicalRenderKey(canonicalURL))
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

        navigator?.forceClearLoadingIndicators(
            reason: "readerMode.syntheticLoad.renderReady",
            pageURL: canonicalURL
        )

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
#if DEBUG
#endif
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
            let startedAt = CFAbsoluteTimeGetCurrent()
            let base64 = await sharedFontCSSBase64Provider()
            guard let base64, !base64.isEmpty else {
                return nil
            }
            return base64
        }
        return nil
    }

    private func logSharedReaderFontInjectionDecision(
        mode: SharedReaderFontInjectionMode,
        pageURL: URL,
        stylesheetURLTemplate: String? = nil,
        base64: String? = nil,
        skippedReason: String? = nil
    ) {
        let desiredFamily = UserDefaults.standard.string(forKey: "readerFont") ?? "nil"
        var metadata: [String: String] = [
            "mode": mode.rawValue,
            "pageURL": pageURL.absoluteString,
            "desiredFamily": desiredFamily,
            "fontAssetPresent": sharedReaderFontAsset == nil ? "0" : "1",
            "fontAssetFilename": sharedReaderFontAsset?.publicFilename ?? "nil",
            "fontAssetFamilies": sharedReaderFontAsset?.supportedFamilyNames.joined(separator: "|") ?? "nil",
            "fontCSSBase64Present": {
                guard let base64 else { return "0" }
                return base64.isEmpty ? "0" : "1"
            }(),
        ]
        if let stylesheetURLTemplate {
            metadata["stylesheetURLTemplate"] = stylesheetURLTemplate
        }
        if let skippedReason {
            metadata["skippedReason"] = skippedReason
        }
        if let base64, !base64.isEmpty {
            metadata["fontCSSBase64Length"] = String(base64.count)
            metadata["fontCSSBase64Hash"] = readerFontPayloadHash(base64)
        }
#if DEBUG
#endif
    }

    private func shouldUseDeferredSharedReaderFontGate(for pageURL: URL) async -> Bool {
        guard !pageURL.isReaderURLLoaderURL else { return false }
        if sharedReaderFontUsesLocalScheme(for: pageURL) {
            return true
        }
        guard let base64 = await resolveSharedReaderFontCSSBase64() else { return false }
        return !base64.isEmpty
    }

    func injectSharedFontIfNeeded(scriptCaller: WebViewScriptCaller, pageURL: URL) async {
        guard pageURL.absoluteString != "about:blank" else {
            logSharedReaderFontInjectionDecision(
                mode: sharedReaderFontInjectionMode(for: pageURL),
                pageURL: pageURL,
                skippedReason: "about-blank"
            )
            return
        }
        guard !pageURL.isReaderURLLoaderURL else {
            logSharedReaderFontInjectionDecision(
                mode: sharedReaderFontInjectionMode(for: pageURL),
                pageURL: pageURL,
                skippedReason: "reader-url-loader"
            )
            return
        }
        guard #available(iOS 16.4, macOS 14, *) else {
            logSharedReaderFontInjectionDecision(
                mode: sharedReaderFontInjectionMode(for: pageURL),
                pageURL: pageURL,
                skippedReason: "unsupported-os"
            )
            return
        }
        if let stylesheetURLTemplate = sharedReaderFontStylesheetURLTemplate(for: pageURL) {
            logSharedReaderFontInjectionDecision(
                mode: .localScheme,
                pageURL: pageURL,
                stylesheetURLTemplate: stylesheetURLTemplate
            )
            let js = """
            (function() {
                const postLog = (_message) => {};
                const isLoaderShellDocument = () => {
                    const href = window.location.href || '';
                    return href.startsWith('internal://local/load/reader');
                };
                const setFontPendingState = (pending) => {
                    const root = document.documentElement;
                    if (!root) return;
                    if (pending) {
                        root.dataset.mnbFontPending = '1';
                        root.dataset.mnbFontReady = '0';
                    } else {
                        delete root.dataset.mnbFontPending;
                        root.dataset.mnbFontReady = '1';
                    }
                    postLog('pending=' + (pending ? '1' : '0')
                        + ' mode=local-scheme'
                        + ' href=' + window.location.href
                        + ' fontsStatus=' + (document.fonts?.status || 'nil'));
                };
                const resolveStylesheetURL = (desiredFamily) => {
                    const family = desiredFamily || 'YuKyokasho';
                    return stylesheetURLTemplate.replace('__MANABI_FONT_FAMILY__', encodeURIComponent(family));
                };
                const ensureReaderFontStyle = (desiredFamily) => {
                    if (isLoaderShellDocument()) {
                        postLog('skipLoaderShell mode=local-scheme href=' + window.location.href);
                        return null;
                    }
                    const root = document.documentElement;
                    if (!root) return null;
                    const family = desiredFamily
                        || root?.dataset?.mnbHorizontalFontFamily
                        || globalThis.manabiHorizontalFontFamilyName
                        || 'YuKyokasho';
                    const stylesheetURL = resolveStylesheetURL(family);
                    let style = document.getElementById('mnb-custom-fonts-inline');
                    if (!style) {
                        style = document.createElement('link');
                        style.id = 'mnb-custom-fonts-inline';
                        style.rel = 'stylesheet';
                        (document.head || document.documentElement).appendChild(style);
                    }
                    style.href = stylesheetURL;
                    style.dataset.mnbInjectedFontFamily = family;
                    style.dataset.mnbFontSource = 'local-scheme';
                    root.dataset.mnbInjectedFontFamily = family;
                    root.dataset.mnbFontInjected = '1';
                    style.onload = () => postLog('stylesheetLoaded mode=local-scheme family=' + family + ' href=' + window.location.href);
                    style.onerror = () => {
                        postLog('stylesheetError mode=local-scheme family=' + family + ' href=' + window.location.href);
                        setFontPendingState(false);
                    };
                    postLog('stylesheetPrepared mode=local-scheme family=' + family + ' href=' + window.location.href);
                    return style;
                };
                if (isLoaderShellDocument()) {
                    postLog('skipLoaderShell mode=local-scheme href=' + window.location.href);
                    return;
                }
                globalThis.manabiReaderFontInjectionMode = 'local-scheme';
                globalThis.manabiResolveReaderFontStylesheetURL = resolveStylesheetURL;
                globalThis.manabiEnsureReaderFontStyle = ensureReaderFontStyle;
                let gateTimeout = null;
                const scheduleGateTimeout = () => {
                    if (gateTimeout) {
                        clearTimeout(gateTimeout);
                    }
                    gateTimeout = setTimeout(() => {
                        postLog('timeoutClear mode=local-scheme href=' + window.location.href);
                        setFontPendingState(false);
                    }, 4000);
                };
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
                        root?.dataset?.mnbHorizontalFontFamily
                        || globalThis.manabiHorizontalFontFamilyName
                        || 'YuKyokasho';
                    setFontPendingState(true);
                    scheduleGateTimeout();
                    ensureReaderFontStyle(desiredFamily);
                    try { globalThis.manabiForwardReaderFontToEbookDocuments?.('readerMode-local-scheme-inject'); } catch (_) {}
                    try { window.parent?.manabiForwardReaderFontToEbookDocuments?.('readerMode-local-scheme-inject-child'); } catch (_) {}
                    if (typeof window.manabiApplyDirectionalInjectedFont === 'function') {
                        window.manabiApplyDirectionalInjectedFont();
                    }
                    const resolvedFamily =
                        document.documentElement?.dataset?.mnbInjectedFontFamily
                        || desiredFamily
                        || null;
                    await waitForFontReady(resolvedFamily);
                    if (gateTimeout) {
                        clearTimeout(gateTimeout);
                        gateTimeout = null;
                    }
                    postLog('fontsReady mode=local-scheme family=' + (resolvedFamily || 'nil') + ' href=' + window.location.href);
                    setFontPendingState(false);
                })().catch((e) => {
                    if (gateTimeout) {
                        clearTimeout(gateTimeout);
                        gateTimeout = null;
                    }
                    postLog('error mode=local-scheme href=' + window.location.href + ' error=' + String(e));
                    setFontPendingState(false);
                    try { console.log('manabi font inject error', e); } catch (_) {}
                });
            })();
            """
            try? await scriptCaller.evaluateJavaScript(
                js,
                arguments: ["stylesheetURLTemplate": stylesheetURLTemplate],
                duplicateInMultiTargetFrames: true
            )
            return
        }

        guard let base64 = await resolveSharedReaderFontCSSBase64() else {
            logSharedReaderFontInjectionDecision(
                mode: .blob,
                pageURL: pageURL,
                skippedReason: "missing-base64-css"
            )
            return
        }
        logSharedReaderFontInjectionDecision(
            mode: .blob,
            pageURL: pageURL,
            base64: base64
        )
        let fontHash = readerFontPayloadHash(base64)
        let js = """
            (function() {
                const postLog = (_message) => {};
                const isLoaderShellDocument = () => {
                    const href = window.location.href || '';
                    return href.startsWith('internal://local/load/reader');
                };
                const setFontPendingState = (pending) => {
                    const root = document.documentElement;
                    if (!root) return;
                if (pending) {
                    root.dataset.mnbFontPending = '1';
                    root.dataset.mnbFontReady = '0';
                } else {
                    delete root.dataset.mnbFontPending;
                    root.dataset.mnbFontReady = '1';
                }
                postLog('pending=' + (pending ? '1' : '0')
                    + ' mode=blob'
                    + ' href=' + window.location.href
                    + ' fontsStatus=' + (document.fonts?.status || 'nil'));
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
                globalThis.manabiReaderFontInjectionMode = 'blob';
                if (previousBlobURL && previousBlobURL !== nextBlobURL) {
                    try { URL.revokeObjectURL(previousBlobURL); } catch (_) {}
                }
                return nextBlobURL;
                };
                const ensureReaderFontStyle = (desiredFamily) => {
                    if (isLoaderShellDocument()) {
                        postLog('skipLoaderShell mode=blob href=' + window.location.href);
                        return null;
                    }
                    const root = document.documentElement;
                    if (!root) return null;
                let style = document.getElementById('mnb-custom-fonts-inline');
                if (style) return style;
                const css = globalThis.manabiReaderFontCSSText || '';
                if (!css) return null;
                const blobURL = replaceFontBlob(css, fontHash, desiredFamily);
                if (!blobURL) return null;
                style = document.createElement('link');
                style.id = 'mnb-custom-fonts-inline';
                style.rel = 'stylesheet';
                style.href = blobURL;
                style.dataset.mnbFontHash = fontHash;
                if (desiredFamily) {
                    style.dataset.mnbInjectedFontFamily = desiredFamily;
                }
                style.onload = () => postLog('stylesheetLoaded mode=blob family=' + (desiredFamily || 'nil') + ' href=' + window.location.href);
                style.onerror = () => {
                    postLog('stylesheetError mode=blob family=' + (desiredFamily || 'nil') + ' href=' + window.location.href);
                    setFontPendingState(false);
                };
                (document.head || document.documentElement).appendChild(style);
                postLog('stylesheetPrepared mode=blob family=' + (desiredFamily || 'nil') + ' href=' + window.location.href);
                return style;
                };
                if (isLoaderShellDocument()) {
                    postLog('skipLoaderShell mode=blob href=' + window.location.href);
                    return;
                }
                globalThis.manabiEnsureReaderFontStyle = ensureReaderFontStyle;
                let gateTimeout = null;
            const scheduleGateTimeout = () => {
                if (gateTimeout) {
                    clearTimeout(gateTimeout);
                }
                gateTimeout = setTimeout(() => {
                    postLog('timeoutClear mode=blob href=' + window.location.href);
                    setFontPendingState(false);
                }, 4000);
            };
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
                    root?.dataset?.mnbHorizontalFontFamily
                    || globalThis.manabiHorizontalFontFamilyName
                    || null;
                setFontPendingState(true);
                scheduleGateTimeout();
                let style = ensureReaderFontStyle(desiredFamily);
                if (!style) {
                    const css = atob(fontCSSBase64);
                    globalThis.manabiReaderFontCSSText = css;
                    const blobURL = replaceFontBlob(css, fontHash, desiredFamily);
                    style = document.createElement('link');
                    style.id = 'mnb-custom-fonts-inline';
                    style.rel = 'stylesheet';
                    style.href = blobURL;
                    style.dataset.mnbFontHash = fontHash;
                    if (desiredFamily) {
                        style.dataset.mnbInjectedFontFamily = desiredFamily;
                    }
                    (document.head || document.documentElement).appendChild(style);
                    root.dataset.mnbFontInjected = '1';
                }
                if (typeof window.manabiApplyDirectionalInjectedFont === 'function') {
                    window.manabiApplyDirectionalInjectedFont();
                }
                try { globalThis.manabiForwardReaderFontToEbookDocuments?.('readerMode-blob-inject'); } catch (_) {}
                try { window.parent?.manabiForwardReaderFontToEbookDocuments?.('readerMode-blob-inject-child'); } catch (_) {}
                const resolvedFamily =
                    document.documentElement?.dataset?.mnbInjectedFontFamily
                    || desiredFamily
                    || null;
                await waitForFontReady(resolvedFamily);
                if (gateTimeout) {
                    clearTimeout(gateTimeout);
                    gateTimeout = null;
                }
                postLog('fontsReady mode=blob family=' + (resolvedFamily || 'nil') + ' href=' + window.location.href);
                setFontPendingState(false);
            })().catch((e) => {
                if (gateTimeout) {
                    clearTimeout(gateTimeout);
                    gateTimeout = null;
                }
                postLog('error mode=blob href=' + window.location.href + ' error=' + String(e));
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

    @MainActor
    public func currentRenderGenerationDescription(for url: URL) -> String {
        renderGenerationDescription(for: canonicalRenderKey(url))
    }

    private func markSyntheticLoadIssued(for url: URL) {
        syntheticLoadIssuedAtByURL[canonicalRenderKey(url)] = Date()
    }

    private func clearSyntheticLoadIssued(for url: URL) {
        syntheticLoadIssuedAtByURL.removeValue(forKey: canonicalRenderKey(url))
    }

    @MainActor
    public func syntheticLoadElapsedString(for url: URL) -> String {
        guard let issuedAt = syntheticLoadIssuedAtByURL[canonicalRenderKey(url)] else {
            return "nil"
        }
        return formattedInterval(Date().timeIntervalSince(issuedAt))
    }

    @MainActor
    func logSyntheticDocumentState(
        pageURL: URL,
        readyState: String,
        hasReaderContent: Bool,
        hasReaderRenderReady: Bool,
        reason: String,
        manabiFontPending: String,
        bodyVisibility: String,
        bodyOpacity: String
    ) {
    }

    private func activeRenderGenerationDescription(for key: String) -> String {
        activeRenderGenerationByURL[key]?.uuidString ?? "nil"
    }

    private func renderGenerationDescription(for key: String) -> String {
        if let activeGeneration = activeRenderGenerationByURL[key] {
            return activeGeneration.uuidString
        }
        if let completedGeneration = completedRenderGenerationByURL[key] {
            return completedGeneration.uuidString
        }
        return "nil"
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

    @MainActor
    private func shouldSkipDuplicateLoaderRender(for url: URL) -> (skip: Bool, reason: String) {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        if hasActiveRender(for: canonicalURL) {
            return (true, "activeRender")
        }
        if pendingKeysMatch(pendingReaderModeURL, canonicalURL), readabilityContent != nil {
            return (true, "pendingWithReadability")
        }
        if pendingKeysMatch(lastRenderedURL, canonicalURL), readabilityContent != nil {
            return (true, "alreadyRenderedWithReadability")
        }
        return (false, "none")
    }

    private func finishRenderTask(for url: URL, generation: UUID, reason: String) {
        let key = canonicalRenderKey(url)
        guard let activeGeneration = activeRenderGenerationByURL[key], activeGeneration == generation else {
            return
        }
        completedRenderGenerationByURL[key] = generation
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
        }
    }

    @discardableResult
    @MainActor
    private func startRenderTaskIfNeeded(
        for url: URL,
        reason: String,
        operation: @escaping @ReaderViewModelActor (_ generation: UUID) async -> Void
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
        let scheduledAt = CFAbsoluteTimeGetCurrent()
        activeRenderGenerationByURL[key] = generation
        completedRenderGenerationByURL.removeValue(forKey: key)
        let task = Task { @ReaderViewModelActor [weak self] in
            guard let self else { return }
            let operationInvokeStartedAt = CFAbsoluteTimeGetCurrent()
            await operation(generation)
            await self.finishRenderTask(for: canonicalURL, generation: generation, reason: reason)
        }
        activeRenderTaskByURL[key] = task
        return true
    }

    private enum ReaderModeRoute: String {
        case localHTML = "swiftFinalLoad"
        case capturedReadability = "webviewReadability"
        case unavailable = "unavailable"
    }

    private struct ReaderModeRouteDecision {
        let route: ReaderModeRoute
        let prefetchedContent: (any ReaderContentProtocol)?
        let prefetchedLocalHTML: String?
    }
    
    func isReaderModeLoadPending(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && content.isReaderModeAvailable && content.isReaderModeByDefault
    }
    
    @MainActor
    private func resolveReaderModeRoute(readerContent: ReaderContent) async -> ReaderModeRoute {
        await resolveReaderModeRouteDecision(readerContent: readerContent).route
    }

    @MainActor
    private func resolveReaderModeRouteDecision(readerContent: ReaderContent) async -> ReaderModeRouteDecision {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let activeReaderFileManager = readerFileManager ?? .shared
        if let content = try? await readerContent.getContent(),
           content.rssContainsFullContent,
           !content.isReaderModeByDefault {
            if let html = try? await locallyRetrievableReaderHTML(
                for: content,
                readerFileManager: activeReaderFileManager
            ),
               !html.isEmpty {
                return ReaderModeRouteDecision(
                    route: .localHTML,
                    prefetchedContent: content,
                    prefetchedLocalHTML: html
                )
            }
        }
        if let readabilityContent, !readabilityContent.isEmpty {
            return ReaderModeRouteDecision(
                route: .capturedReadability,
                prefetchedContent: nil,
                prefetchedLocalHTML: nil
            )
        }
        if let content = try? await readerContent.getContent(),
           let html = try? await locallyRetrievableReaderHTML(
                for: content,
                readerFileManager: activeReaderFileManager
           ),
           !html.isEmpty {
            return ReaderModeRouteDecision(
                route: .localHTML,
                prefetchedContent: content,
                prefetchedLocalHTML: html
            )
        }
        return ReaderModeRouteDecision(
            route: .unavailable,
            prefetchedContent: nil,
            prefetchedLocalHTML: nil
        )
    }

    @MainActor
    func readerModeRouteForTesting(readerContent: ReaderContent) async -> String {
        await resolveReaderModeRoute(readerContent: readerContent).rawValue
    }

    @MainActor
    private func readerContentRenderSnapshot(readerContent: ReaderContent) async throws -> ReaderContentRenderSnapshot? {
        guard let content = try await readerContent.getContent() else {
            return nil
        }
        return ReaderContentRenderSnapshot(
            url: content.url,
            title: content.title,
            isTitlePrefixOfContent: content.isTitlePrefixOfContent
        )
    }
    
    @MainActor
    internal func showReaderView(readerContent: ReaderContent, scriptCaller: WebViewScriptCaller) {
        let contentURL = readerContent.pageURL
        let scheduledAt = CFAbsoluteTimeGetCurrent()
        let cachedReadabilityContent = readabilityContent
        let cachedReadabilityBytes = cachedReadabilityContent?.utf8.count ?? 0
        let cachedContainerSelector = readabilityContainerSelector
        let cachedContainerFrameInfo = readabilityContainerFrameInfo
        beginReaderModeLoad(for: contentURL, reason: "showReaderView")
        logTrace(.readabilityTaskScheduled, url: contentURL, details: "readabilityBytes=\(cachedReadabilityBytes)")
        let startedRenderTask = startRenderTaskIfNeeded(for: contentURL, reason: "showReaderView") { [weak self] generation in
            guard let self else { return }
            let currentPageURL = await MainActor.run { readerContent.pageURL }
            guard urlsMatchWithoutHashForHotfix(contentURL, currentPageURL) else {
                await self.cancelReaderModeLoad(for: contentURL, reason: "showReaderView.urlMismatch")
                return
            }
            let routeDecision = await self.resolveReaderModeRouteDecision(readerContent: readerContent)
            let route = routeDecision.route
            switch route {
            case .localHTML:
                await self.showReaderViewUsingSwiftProcessing(
                    readerContent: readerContent,
                    scriptCaller: scriptCaller,
                    renderGeneration: generation,
                    prefetchedContent: routeDecision.prefetchedContent,
                    prefetchedLocalHTML: routeDecision.prefetchedLocalHTML
                )
            case .capturedReadability:
                guard let cachedReadabilityContent else {
                    await self.cancelReaderModeLoad(for: contentURL, reason: "showReaderView.missingReadability")
                    return
                }
                do {
                    let contentSnapshot = try await self.readerContentRenderSnapshot(readerContent: readerContent)
                    let resolvedReadabilityContent: String
                    if !cachedReadabilityContent.contains("id=\"reader-publication-date\""),
                       let publicationDateFallback = await readerContentPublicationDateFallback(for: contentURL),
                       let canonicalHTML = rebuildCanonicalSnippetReadabilityHTML(
                        html: cachedReadabilityContent,
                        contentURL: contentSnapshot?.url ?? contentURL,
                        fallbackTitle: titleFromReadabilityHTML(cachedReadabilityContent) ?? contentSnapshot?.title,
                        publishedTime: publicationDateFallback,
                        preferredTitle: contentSnapshot?.title,
                        hideReaderTitleOverride: contentSnapshot?.isTitlePrefixOfContent
                       ) {
                        debugPrint(
                            "# BYLINE capturedReadability.publicationDateFallback",
                            "contentURL=\((contentSnapshot?.url ?? contentURL).absoluteString)",
                            "publishedTime=\(publicationDateFallback)",
                            "result=rebuildCanonical"
                        )
                        resolvedReadabilityContent = canonicalHTML
                    } else {
                        resolvedReadabilityContent = cachedReadabilityContent
                    }
                    try await self.showReadabilityContent(
                        readerContent: readerContent,
                        readabilityContent: resolvedReadabilityContent,
                        renderToSelector: cachedContainerSelector,
                        in: cachedContainerFrameInfo,
                        scriptCaller: scriptCaller,
                        renderGeneration: generation
                    )
                } catch is CancellationError {
                    await self.cancelReaderModeLoad(for: contentURL, reason: "showReaderView.cancelled")
                } catch {
                    print(error)
                    await self.cancelReaderModeLoad(for: contentURL, reason: "showReaderView.readabilityError")
                }
            case .unavailable:
                await self.cancelReaderModeLoad(for: contentURL, reason: "showReaderView.unavailable")
            }
        }
        if !startedRenderTask {
        }
    }

    @MainActor
    public func beginSyntheticLoadForCurrentContentIfPossible(
        readerContent: ReaderContent,
        scriptCaller: WebViewScriptCaller
    ) async -> Bool {
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard let content = try? await readerContent.getContent() else {
            return false
        }
        guard content.url.isSnippetURL else {
            return false
        }
        guard readerContent.pageURL.matchesReaderURL(content.url) else {
            return false
        }
        showReaderView(readerContent: readerContent, scriptCaller: scriptCaller)
        return true
    }

    @MainActor
    private func showReaderViewUsingSwiftProcessing(
        readerContent: ReaderContent,
        scriptCaller: WebViewScriptCaller,
        renderGeneration: UUID? = nil,
        prefetchedContent: (any ReaderContentProtocol)? = nil,
        prefetchedLocalHTML: String? = nil
    ) async {
        do {
            let swiftProcessingStart = CFAbsoluteTimeGetCurrent()
            var getContentElapsed: Double = 0
            var localHTMLElapsed: Double = 0
            var readabilityResolveElapsed: Double = 0
            var showReadabilityElapsed: Double = 0
            let content: any ReaderContentProtocol
            if let prefetchedContent {
                content = prefetchedContent
            } else {
                let getContentStart = CFAbsoluteTimeGetCurrent()
                guard let resolvedContent = try await readerContent.getContent() else {
                    cancelReaderModeLoad(for: readerContent.pageURL, reason: "swiftProcessing.missingContent")
                    return
                }
                content = resolvedContent
                getContentElapsed = CFAbsoluteTimeGetCurrent() - getContentStart
            }
            let activeReaderFileManager = readerFileManager ?? .shared
            let html: String
            if let prefetchedLocalHTML {
                html = prefetchedLocalHTML
            } else {
                let localHTMLStart = CFAbsoluteTimeGetCurrent()
                guard let resolvedHTML = try await locallyRetrievableReaderHTML(
                    for: content,
                    readerFileManager: activeReaderFileManager
                ) else {
                    cancelReaderModeLoad(for: content.url, reason: "swiftProcessing.missingHTML")
                    return
                }
                html = resolvedHTML
                localHTMLElapsed = CFAbsoluteTimeGetCurrent() - localHTMLStart
            }

            let resolvedReadabilityHTML: String?
            if hasCanonicalReadabilityMarkup(in: html) {
                resolvedReadabilityHTML = html
            } else {
                let publicationDateFallback = await readerContentPublicationDateFallback(for: content.url)
                let readabilityProcessingStart = CFAbsoluteTimeGetCurrent()
                let swiftReadability = await processReadabilityHTMLInSwift(
                    html: html,
                    url: content.url,
                    snippetPublishedTime: publicationDateFallback,
                    meaningfulContentMinChars: max(content.meaningfulContentMinLength, 1)
                )
                readabilityResolveElapsed = CFAbsoluteTimeGetCurrent() - readabilityProcessingStart
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
                showReadabilityElapsed = CFAbsoluteTimeGetCurrent() - showReadabilityStart
                let totalElapsed = CFAbsoluteTimeGetCurrent() - swiftProcessingStart
                let residualElapsed = max(
                    0,
                    totalElapsed
                        - getContentElapsed
                        - localHTMLElapsed
                        - readabilityResolveElapsed
                        - showReadabilityElapsed
                )
                return
            }

            readabilityContent = nil
            let directHTML = prepareHTMLForDirectLoad(html)
            let directHTMLHasBody = directHTML.contains("<body")
            let directHTMLHasArticle = directHTML.contains("<article")
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
        let totalStart = CFAbsoluteTimeGetCurrent()
        let getContentStart = CFAbsoluteTimeGetCurrent()
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
                "hasProcessHTMLBytes": processHTMLBytes != nil,
                "hasProcessHTML": processHTML != nil
            ] as [String: Any]
        )
        let shouldStoreReaderHTML = !url.isEBookURL
            && !url.isFileURL
            && !url.isNativeReaderView
            && !url.isReaderFileURL
            && (content.content?.isEmpty ?? true)
        let resolvedStoredHTML = shouldStoreReaderHTML ? readabilityContent : nil
        let resolvedTitleIfNeeded: String? = {
            guard content.title.isEmpty else { return nil }
            return (resolvedStoredHTML ?? content.html)?
                .strippingHTML()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
                .first?
                .truncate(36) ?? ""
        }()
        let titleForDisplay = content.titleForDisplay
        logTitleTrace(
            "stage=readerMode.showReadabilityContent.preflight contentURL=\(url.absoluteString) pageURL=\(readerContent.pageURL.absoluteString) contentType=\(String(describing: type(of: content))) existingTitle=\(content.title.debugTitleFragment) titleForDisplay=\(titleForDisplay.debugTitleFragment) shouldStoreReaderHTML=\(shouldStoreReaderHTML) resolvedTitleIfNeeded=\(resolvedTitleIfNeeded.debugTitleFragment) rssContainsFullContent=\(content.rssContainsFullContent)"
        )
        let needsAsyncWrite =
            content.isReaderModeByDefault == false
            || content.isReaderModeAvailable == true
            || content.isReaderModeOfferHidden == true
            || (
                !url.isEBookURL
                && !url.isFileURL
                && !url.isNativeReaderView
                && content.rssContainsFullContent == false
            )
            || (resolvedStoredHTML != nil && content.html != resolvedStoredHTML)
            || (resolvedTitleIfNeeded != nil && content.title != resolvedTitleIfNeeded)

        if needsAsyncWrite {
            try await content.asyncWrite { _, content in
                content.isReaderModeByDefault = true
                content.isReaderModeAvailable = false
                content.isReaderModeOfferHidden = false
                if !url.isEBookURL && !url.isFileURL && !url.isNativeReaderView {
                    if let resolvedStoredHTML {
                        content.html = resolvedStoredHTML
                    }
                    if let resolvedTitleIfNeeded {
                        content.title = resolvedTitleIfNeeded
                    }
                    content.rssContainsFullContent = true
                }
                content.refreshChangeMetadata(explicitlyModified: true)
            }
            logTitleTrace(
                "stage=readerMode.showReadabilityContent.persisted contentURL=\(url.absoluteString) storedHTML=\(resolvedStoredHTML != nil) resolvedTitleIfNeeded=\(resolvedTitleIfNeeded.debugTitleFragment) rssContainsFullContentSet=\(!url.isEBookURL && !url.isFileURL && !url.isNativeReaderView)"
            )
        }
        
        if !isReaderMode {
            isReaderMode = true
        }

        if currentReaderFontNeedsDeferredSharedCSS() {
            _ = await resolveSharedReaderFontCSSBase64()
        }
        
        let injectEntryImageIntoHeader = content.injectEntryImageIntoHeader
        let imageURLToDisplay = try await content.imageURLToDisplay()
        let processReadabilityContent = processReadabilityContent
        let processHTMLBytes = processHTMLBytes
        let processHTML = processHTML
        let prefersDirectSnippetReadabilityParse = url.isSnippetURL && hasCanonicalReadabilityMarkup(in: readabilityContent)
        let snippetRawTitle = content.title
        let snippetNeedsClipboardIndicator = content.needsClipboardIndicator
        let hideRedundantSnippetTitle = content.isTitlePrefixOfContent
        let primaryRecordCompoundKey = await MainActor.run { content.compoundKey }
        
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
            }

            guard let doc else {
                print("Error: Unexpectedly failed to receive doc")
                return
            }
            let derivedTitle = titleFromReadabilityDocument(doc) ?? titleForDisplay
            logTitleTrace(
                "stage=readerMode.showReadabilityContent.derived contentURL=\(url.absoluteString) titleForDisplay=\(titleForDisplay.debugTitleFragment) derivedTitle=\(derivedTitle.debugTitleFragment) snippetRawTitle=\(snippetRawTitle.debugTitleFragment) prefersDirectSnippetParse=\(prefersDirectSnippetReadabilityParse)"
            )
            await propagateReaderModeDefaults(
                for: url,
                primaryKey: primaryRecordCompoundKey,
                readabilityHTML: readabilityContent,
                fallbackTitle: titleForDisplay,
                derivedTitle: derivedTitle
            )
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

            let processedSegmentCount = (try? doc.getElementsByTag("mnb-seg").size()) ?? 0
            let processedBodyExists = doc.body() != nil
            let processedIsEbook = ((try? doc.body()?.attr("data-is-ebook")) ?? "") == "true"
            let shouldInjectProcessedStyles = !(processedIsEbook && readerModeDisableInjectedStylingForEbookLayoutDiagnosis)
            let processedBodyClasses = (try? doc.body()?.className()) ?? ""
            let processedBodyClassesForFrameInjection: String = {
                let trimmed = processedBodyClasses.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "readability-mode" : trimmed
            }()
            let processedTitleDisplayStyle = (try? doc.getElementById("reader-title")?.attr("style")) ?? ""
            let processedStyleTextForFrameInjection: String = {
                guard shouldInjectProcessedStyles else {
                    return ""
                }
                guard let styleElement = try? doc.getElementById("swiftuiwebview-readability-styles"),
                      let styleHTML = try? styleElement.html() else {
                    return readerModeReadabilityCSS
                }
                return styleHTML.isEmpty ? readerModeReadabilityCSS : styleHTML
            }()
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

            if await shouldUseDeferredSharedReaderFontGate(for: url) {
                try? upsertDeferredSharedReaderFontGate(in: doc)
            }

            markReaderRenderReady(in: doc)

            let serializeStartedAt = CFAbsoluteTimeGetCurrent()
            let serializedHTMLBytes = try doc.outerHtmlUTF8()
            let serializeElapsed = CFAbsoluteTimeGetCurrent() - serializeStartedAt

            var transformedHTMLBytes = serializedHTMLBytes
            var transformedHTMLString: String?
            var processHTMLElapsed: CFAbsoluteTime = 0
            if let processHTMLBytes {
                let processHTMLBytesStart = CFAbsoluteTimeGetCurrent()
                transformedHTMLBytes = await processHTMLBytes(
                    transformedHTMLBytes,
                    false
                )
                let processHTMLBytesElapsed = CFAbsoluteTimeGetCurrent() - processHTMLBytesStart
                processHTMLElapsed += processHTMLBytesElapsed
            }
            if let processHTML {
                let processHTMLStart = CFAbsoluteTimeGetCurrent()
                let serializedHTML = String(decoding: transformedHTMLBytes, as: UTF8.self)
                let processedHTML = await processHTML(
                    serializedHTML,
                    false
                )
                transformedHTMLString = processedHTML
                transformedHTMLBytes = Array(processedHTML.utf8)
                let processHTMLStringElapsed = CFAbsoluteTimeGetCurrent() - processHTMLStart
                processHTMLElapsed += processHTMLStringElapsed
            }

            let frameInjectionPrepStartedAt = CFAbsoluteTimeGetCurrent()
            let transformedContentForFrameInjection: String?
            let transformedBodyClassesForFrameInjection: String?
            let transformedStyleTextForFrameInjection: String?
            if let frameInfo, !frameInfo.isMainFrame {
                let transformedContent = transformedHTMLString ?? String(decoding: transformedHTMLBytes, as: UTF8.self)
                transformedContentForFrameInjection = transformedContent
                if processHTML == nil {
                    transformedBodyClassesForFrameInjection = processedBodyClassesForFrameInjection
                    transformedStyleTextForFrameInjection = processedStyleTextForFrameInjection
                } else {
                    let transformedDocument = try? SwiftSoup.parse(transformedContent)
                    let transformedBodyClasses = {
                        guard let transformedDocument,
                              let bodyElement = transformedDocument.body(),
                              let bodyClassNames = try? bodyElement.className() else {
                            return processedBodyClassesForFrameInjection
                        }
                        let trimmed = bodyClassNames.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? "readability-mode" : trimmed
                    }()
                    let transformedStyleText = {
                        guard shouldInjectProcessedStyles else {
                            return ""
                        }
                        guard let transformedDocument,
                              let styleElement = try? transformedDocument.getElementById("swiftuiwebview-readability-styles"),
                              let styleHTML = try? styleElement.html() else {
                            return processedStyleTextForFrameInjection
                        }
                        return styleHTML.isEmpty ? processedStyleTextForFrameInjection : styleHTML
                    }()
                    transformedBodyClassesForFrameInjection = transformedBodyClasses
                    transformedStyleTextForFrameInjection = transformedStyleText
                }
            } else {
                transformedContentForFrameInjection = nil
                transformedBodyClassesForFrameInjection = nil
                transformedStyleTextForFrameInjection = nil
            }
            let dataBuildStartedAt = CFAbsoluteTimeGetCurrent()
            let transformedHTMLData = Data(transformedHTMLBytes)
            let mainActorHandoffStartedAt = CFAbsoluteTimeGetCurrent()
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
                    let transformedContent = transformedContentForFrameInjection ?? ""
                    let transformedBodyClasses = transformedBodyClassesForFrameInjection ?? "readability-mode"
                    let transformedStyleText = shouldInjectProcessedStyles
                        ? (transformedStyleTextForFrameInjection ?? "")
                        : ""
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
                    self?.markSyntheticLoadIssued(for: renderBaseURL)
                    self?.expectSyntheticReaderLoaderCommit(for: renderBaseURL)
                    self?.logTrace(.navigatorLoad, url: url, details: "mode=readability-html | bytes=\(transformedHTMLData.count)")
                    navigator?.load(
                        transformedHTMLData,
                        mimeType: "text/html",
                        characterEncodingName: "UTF-8",
                        baseURL: renderBaseURL
                    )
                }
//                try await { @MainActor in
//                    readerModeLoading(false)
//                }()
            }()
        }()

        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        if injectEntryImageIntoHeader && content.imageUrl == nil {
            let metadataRefreshStart = CFAbsoluteTimeGetCurrent()
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
            } catch is CancellationError {
            } catch {
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
        let totalStart = CFAbsoluteTimeGetCurrent()
        guard canHaveReadabilityContent(for: url) else {
            return .unavailable
        }

        let normalizeStart = CFAbsoluteTimeGetCurrent()
        let normalizedHTML = ensureReadabilityBodyExists(html)
        let normalizeElapsed = CFAbsoluteTimeGetCurrent() - normalizeStart
        if url.isSnippetURL {
            let snippetBypassStart = CFAbsoluteTimeGetCurrent()
            if let snippetHTML = buildSnippetCanonicalReadabilityHTML(
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
        }
        let parserSetupStart = CFAbsoluteTimeGetCurrent()
        let options = SwiftReadability.ReadabilityOptions(
            charThreshold: max(meaningfulContentMinChars, 1),
            classesToPreserve: readabilityClassesToPreserve
        )
        let parser = SwiftReadability.Readability(
            html: normalizedHTML,
            url: url,
            options: options
        )
        let parserSetupElapsed = CFAbsoluteTimeGetCurrent() - parserSetupStart

        let parseStart = CFAbsoluteTimeGetCurrent()
        guard let result = try? parser.parse() else {
            let parseElapsed = CFAbsoluteTimeGetCurrent() - parseStart
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
        let parseElapsed = CFAbsoluteTimeGetCurrent() - parseStart

        let canonicalBuildStart = CFAbsoluteTimeGetCurrent()
        let rawContent = stripTemplateTagsForReadability(result.content)
        guard !rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed
        }

        let resolvedPublishedTime = trimmedNonEmptyReadabilityText(result.publishedTime)
            ?? trimmedNonEmptyReadabilityText(snippetPublishedTime)
        debugPrint(
            "# BYLINE readabilityResult",
            "contentURL=\(url.absoluteString)",
            "resultByline=\((result.byline ?? "").isEmpty ? "nil" : result.byline ?? "nil")",
            "resultBylineBytes=\((result.byline ?? "").utf8.count)",
            "resultPublishedTime=\(result.publishedTime ?? "nil")",
            "fallbackPublishedTime=\(snippetPublishedTime ?? "nil")",
            "resolvedPublishedTime=\(resolvedPublishedTime ?? "nil")"
        )
        let outputHTML = buildCanonicalReadabilityHTML(
            title: stripTemplateTagsForReadability(result.title ?? ""),
            byline: stripTemplateTagsForReadability(result.byline ?? ""),
            publishedTime: resolvedPublishedTime,
            content: rawContent,
            contentURL: url
        )
        let canonicalBuildElapsed = CFAbsoluteTimeGetCurrent() - canonicalBuildStart
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
#if DEBUG
#endif
        } else {
            do {
                try await scriptCaller.evaluateJavaScript(
                    "window.paginationTrackingBookKey = bookKey;",
                    arguments: ["bookKey": newState.pageURL.absoluteString],
                    in: nil,
                    duplicateInMultiTargetFrames: true
                )
#if DEBUG
#endif
            } catch {
#if DEBUG
#endif
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
            let duplicateLoaderRender = shouldSkipDuplicateLoaderRender(for: committedURL)
            if duplicateLoaderRender.skip {
                return
            }
            if let readerFileManager {
                let html = try await content.htmlToDisplay(readerFileManager: readerFileManager)
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
                    let publicationDateFallback = await readerContentPublicationDateFallback(for: committedURL)
                    if committedURL.isSnippetURL,
                       let snippetHTML = buildSnippetCanonicalReadabilityHTML(
                        html: html,
                        contentURL: committedURL,
                        fallbackTitle: titleFromReadabilityHTML(html) ?? content.title,
                        publishedTime: publicationDateFallback,
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
#if DEBUG
                debugPrint("# FLASH readerMode.navFinished.defer.loader", "pageURL=\(newState.pageURL)")
#endif
            case .synthetic(let pendingURL, let expectedURL):
#if DEBUG
                debugPrint(
                    "# FLASH readerMode.navFinished.defer.synthetic",
                    "pageURL=\(newState.pageURL)",
                    "pending=\(pendingURL)",
                    "expected=\(expectedURL)"
                )
#endif
            case .pending(let pendingURL):
#if DEBUG
                debugPrint(
                    "# FLASH readerMode.navFinished.defer.pending",
                    "pageURL=\(newState.pageURL.absoluteString)",
                    "pending=\(pendingURL.absoluteString)",
                    "expected=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
                    "isReaderModeLoading=\(isReaderModeLoading)"
                )
#endif
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

private let readerModeDisableInjectedStylingForEbookLayoutDiagnosis = false

func prepareHTMLForDirectLoad(_ html: String) -> String {
    var updatedHTML = html
    let markerPatterns = [
        #"data-is-next-load-in-reader-mode=['\"][^'"]*['\"]"#,
        #"data-mnb-reader-mode-available=['\"][^'"]*['\"]"#,
        #"data-mnb-reader-mode-available-for=['\"][^'"]*['\"]"#
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

nonisolated public func processForReaderMode(
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
        if readerModeDisableInjectedStylingForEbookLayoutDiagnosis {
            try? doc.getElementById("swiftuiwebview-readability-styles")?.remove()
            try? doc.getElementById("mnb-mark-read-buttons-visibility-style")?.remove()
            try? doc.getElementById("mnb-readability-styles")?.remove()
            try? doc.body()?.removeAttr("style")
        }
    }
    
    if !isCacheWarmer {
        if let bodyTag = doc.body() {
            let bodyAttributesStartedAt = Date()
            // TODO: font size and theme set elsewhere already..?
            let readerFontSize = (UserDefaults.standard.object(forKey: "readerFontSize") as? Double) ?? defaultFontSize
            let lightModeTheme = (UserDefaults.standard.object(forKey: "lightModeTheme") as? LightModeTheme) ?? .white
            let darkModeTheme = (UserDefaults.standard.object(forKey: "darkModeTheme") as? DarkModeTheme) ?? .black
            
            var bodyStyle = "font-size: \(readerFontSize)px;"
            if !(isEBook && readerModeDisableInjectedStylingForEbookLayoutDiagnosis) {
                bodyStyle += " \(readerAdaptiveMaxWidthStyleDeclaration(readerFontSize: readerFontSize))"
                if let existingBodyStyle = try? bodyTag.attr("style"), !existingBodyStyle.isEmpty {
                    bodyStyle = "\(bodyStyle); \(existingBodyStyle)"
                }
            }
            _ = try? bodyTag.attr("style", bodyStyle)
            _ = try? bodyTag.attr("data-mnb-light-theme", lightModeTheme.rawValue)
            _ = try? bodyTag.attr("data-mnb-dark-theme", darkModeTheme.rawValue)
        }
        
        if let defaultTitle = defaultTitle, let existing = try? doc.getElementById("reader-title"), !existing.hasText() {
            let titleFallbackStartedAt = Date()
            let escapedTitle = Entities.escape(defaultTitle, OutputSettings().charset(String.Encoding.utf8).escapeMode(Entities.EscapeMode.extended))
            do {
                try existing.html(escapedTitle)
            } catch { }
        }
        
        if !isEBook {
            let fixTitlesStartedAt = Date()
            do {
                try fixAnnoyingTitlesWithPipes(doc: doc, url: url)
            } catch { }
        }
        
        if try injectEntryImageIntoHeader || (doc.body()?.getElementsByTag(UTF8Arrays.img).isEmpty() ?? true), let imageURL = imageURL, let existing = try? doc.select("img[src='\(imageURL.absoluteString)'"), existing.isEmpty() {
            let headerImageStartedAt = Date()
            do {
                try doc.getElementById("reader-header")?.prepend("<img src='\(imageURL.absoluteString)'>")
            } catch { }
        }
    }
}
