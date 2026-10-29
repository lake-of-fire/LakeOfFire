import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import SwiftUIWebView
import SwiftSoup
import SwiftReadability
import RealmSwift
import Combine
import RealmSwiftGaps
import LakeKit
import WebKit
import SwiftUtilities
import Perception

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

private enum ReaderModeRuntimeAuthorityError: Error {
    case unavailable
}

private func readerFontCSSValues(horizontalFamily: String) -> (
    horizontalFamily: String,
    verticalFamily: String,
    horizontalCSSValue: String,
    verticalCSSValue: String
) {
    let verticalFamily = horizontalFamily == "YuKyokasho" ? "YuKyokasho Yoko" : horizontalFamily
    return (
        horizontalFamily,
        verticalFamily,
        "'\(horizontalFamily)'",
        "'\(verticalFamily)'"
    )
}

private let readerModeReadabilityCSS = Readability.shared.css

private enum ReaderModeJSONStringByte {
    static let backspace = UInt8(ascii: "\u{08}")
    static let tab = UInt8(ascii: "\t")
    static let newline = UInt8(ascii: "\n")
    static let formFeed = UInt8(ascii: "\u{0C}")
    static let carriageReturn = UInt8(ascii: "\r")
    static let doubleQuote = UInt8(ascii: "\"")
    static let backslash = UInt8(ascii: "\\")
    static let lowercaseB = UInt8(ascii: "b")
    static let lowercaseF = UInt8(ascii: "f")
    static let lowercaseN = UInt8(ascii: "n")
    static let lowercaseR = UInt8(ascii: "r")
    static let lowercaseT = UInt8(ascii: "t")
    static let lowercaseU = UInt8(ascii: "u")
    static let digit0 = UInt8(ascii: "0")
    static let digit2 = UInt8(ascii: "2")
    static let digit8 = UInt8(ascii: "8")
    static let digit9 = UInt8(ascii: "9")
    static let utf8LineSeparator0 = UInt8(0xE2)
    static let utf8LineSeparator1 = UInt8(0x80)
    static let utf8LineSeparator2 = UInt8(0xA8)
    static let utf8ParagraphSeparator2 = UInt8(0xA9)
    static let hexDigits = Array("0123456789ABCDEF".utf8)
}

private func readerModeJSONStringLiteral(_ string: String) -> String {
    let source = string.utf8
    var literal = [UInt8]()
    literal.reserveCapacity(source.count + 2)
    literal.append(ReaderModeJSONStringByte.doubleQuote)

    var index = source.startIndex
    while index < source.endIndex {
        let byte = source[index]
        switch byte {
        case ReaderModeJSONStringByte.backspace:
            literal.append(ReaderModeJSONStringByte.backslash)
            literal.append(ReaderModeJSONStringByte.lowercaseB)
        case ReaderModeJSONStringByte.tab:
            literal.append(ReaderModeJSONStringByte.backslash)
            literal.append(ReaderModeJSONStringByte.lowercaseT)
        case ReaderModeJSONStringByte.newline:
            literal.append(ReaderModeJSONStringByte.backslash)
            literal.append(ReaderModeJSONStringByte.lowercaseN)
        case ReaderModeJSONStringByte.formFeed:
            literal.append(ReaderModeJSONStringByte.backslash)
            literal.append(ReaderModeJSONStringByte.lowercaseF)
        case ReaderModeJSONStringByte.carriageReturn:
            literal.append(ReaderModeJSONStringByte.backslash)
            literal.append(ReaderModeJSONStringByte.lowercaseR)
        case ReaderModeJSONStringByte.doubleQuote, ReaderModeJSONStringByte.backslash:
            literal.append(ReaderModeJSONStringByte.backslash)
            literal.append(byte)
        case 0x00...0x1F:
            appendReaderModeJSONUnicodeEscape(byte, to: &literal)
        case ReaderModeJSONStringByte.utf8LineSeparator0
            where readerModeJSONLineOrParagraphSeparatorThirdByte(in: source, at: index) != nil:
            let separatorThirdByte = readerModeJSONLineOrParagraphSeparatorThirdByte(in: source, at: index)!
            literal.append(ReaderModeJSONStringByte.backslash)
            literal.append(ReaderModeJSONStringByte.lowercaseU)
            literal.append(ReaderModeJSONStringByte.digit2)
            literal.append(ReaderModeJSONStringByte.digit0)
            literal.append(ReaderModeJSONStringByte.digit2)
            literal.append(separatorThirdByte == ReaderModeJSONStringByte.utf8LineSeparator2
                           ? ReaderModeJSONStringByte.digit8
                           : ReaderModeJSONStringByte.digit9)
            index = source.index(index, offsetBy: 2)
        default:
            literal.append(byte)
        }
        source.formIndex(after: &index)
    }

    literal.append(ReaderModeJSONStringByte.doubleQuote)
    return String(decoding: literal, as: UTF8.self)
}

private func readerModeJSONLineOrParagraphSeparatorThirdByte(
    in source: String.UTF8View,
    at index: String.UTF8View.Index
) -> UInt8? {
    let secondIndex = source.index(after: index)
    guard secondIndex < source.endIndex,
          source[secondIndex] == ReaderModeJSONStringByte.utf8LineSeparator1 else {
        return nil
    }
    let thirdIndex = source.index(after: secondIndex)
    guard thirdIndex < source.endIndex,
          source[thirdIndex] == ReaderModeJSONStringByte.utf8LineSeparator2
            || source[thirdIndex] == ReaderModeJSONStringByte.utf8ParagraphSeparator2 else {
        return nil
    }
    return source[thirdIndex]
}

private func appendReaderModeJSONUnicodeEscape(_ byte: UInt8, to output: inout [UInt8]) {
    output.append(ReaderModeJSONStringByte.backslash)
    output.append(ReaderModeJSONStringByte.lowercaseU)
    output.append(ReaderModeJSONStringByte.digit0)
    output.append(ReaderModeJSONStringByte.digit0)
    output.append(ReaderModeJSONStringByte.hexDigits[Int(byte >> 4)])
    output.append(ReaderModeJSONStringByte.hexDigits[Int(byte & 0xF)])
}

// Generated reader HTML already contains the small local font declarations.
// Reader documents opened with a system font can install the local stylesheet
// on first selection. Native callbacks join the same bounded promise.
internal let sharedReaderFontInjectionJavaScript = #"""
return (function installSharedReaderFont(allowRetry = false) {
    const root = document.documentElement;
    if (!root || window.location.href.startsWith('internal://local/load/reader')) return 'skipped';
    if (!stylesheetURLTemplate) return 'skipped';
    const mode = 'local-scheme';
    const previous = globalThis.manabiReaderFontLoad;
    // Native callbacks can arrive after settings selected another family.
    // Joining a prior attempt must not overwrite that newer selection.
    if (root.dataset.mnbHorizontalFontFamily
        && root.dataset.mnbHorizontalFontFamily !== horizontalFontFamily) return previous?.promise || 'skipped';
    const vertical = (!document.body && root.dataset.mnbInitialWritingDirection === 'vertical')
        || document.body?.dataset.mnbWritingDirection === 'vertical'
        || (document.body?.dataset.mnbWritingDirection !== 'horizontal'
            && document.body?.classList.contains('reader-vertical-writing'));
    const family = vertical ? verticalFontFamily : horizontalFontFamily;
    const key = [mode, fontHash, family].join(':');
    if (!allowRetry && previous?.key === key) return previous.promise;
    // Once visible fallback has been admitted, keep typography stable until
    // navigation. A commit/finish replay must not start a second font attempt.
    const settledOutcome = root.dataset.mnbFontOutcome;
    if (!allowRetry && settledOutcome && settledOutcome !== 'loaded') return previous?.promise || settledOutcome;
    previous?.expire?.();
    if (allowRetry) {
        delete root.dataset.mnbFontOutcome;
        const oldStyle = document.getElementById('mnb-custom-fonts-inline');
        if (oldStyle?.tagName === 'LINK') oldStyle.remove();
        else if (oldStyle?.tagName === 'STYLE' && oldStyle.disabled) {
            // A failed CSSFontFace cannot be restarted by enabling its sheet.
            // Recreate the declarations only for an explicit user retry.
            const replacement = oldStyle.cloneNode(true);
            replacement.disabled = false;
            oldStyle.replaceWith(replacement);
        }
    }
    root.dataset.mnbHorizontalFontFamily = horizontalFontFamily;
    root.dataset.mnbVerticalFontFamily = verticalFontFamily;
    globalThis.manabiHorizontalFontFamilyName = horizontalFontFamily;
    globalThis.manabiVerticalFontFamilyName = verticalFontFamily;
    // Once an attempt exists it owns the deadline. The initial HTML escape
    // must not expire a later user-requested attempt in this same document.
    clearTimeout(globalThis.manabiReaderFontGateFallbackTimer);
    globalThis.manabiReaderFontGateFallbackTimer = null;

    const ensureStyle = (desiredFamily = family) => {
        const outcome = root.dataset.mnbFontOutcome;
        if (outcome && outcome !== 'loaded') return null;
        let style = document.getElementById('mnb-custom-fonts-inline');
        if (stylesheetURLTemplate && style?.tagName === 'STYLE'
            && style.dataset.mnbFontSource === 'local-scheme'
            && style.dataset.mnbFontHash === fontHash) {
            style.disabled = false;
            style.dataset.mnbInjectedFontFamily = desiredFamily;
            root.dataset.mnbInjectedFontFamily = desiredFamily;
            root.dataset.mnbFontInjected = '1';
            return style;
        }
        if (style?.dataset.mnbFontHash === fontHash
            && style.dataset.mnbInjectedFontFamily === desiredFamily && !style.disabled) return style;
        const href = stylesheetURLTemplate.replace('__MANABI_FONT_FAMILY__', encodeURIComponent(desiredFamily));
        if (!style) {
            style = document.createElement('link');
            style.id = 'mnb-custom-fonts-inline';
            style.rel = 'stylesheet';
        }
        // A newly navigated document can independently retry a disabled face
        // forwarded from another document; settled attempts above stay closed.
        style.disabled = false;
        style.dataset.mnbFontHash = fontHash;
        style.dataset.mnbInjectedFontFamily = desiredFamily;
        style.dataset.mnbFontSource = mode;
        if (style.href !== href) style.href = href;
        root.dataset.mnbInjectedFontFamily = desiredFamily;
        root.dataset.mnbFontInjected = '1';
        if (!style.isConnected) (document.head || root).appendChild(style);
        return style;
    };
    globalThis.manabiReaderFontInjectionMode = mode;
    globalThis.manabiReaderFontCSSHash = fontHash;
    globalThis.manabiEnsureReaderFontStyle = ensureStyle;
    // Only an explicit font-setting change may reopen a settled attempt.
    globalThis.manabiRestartReaderFontLoad = () => installSharedReaderFont(true);
    // The font gate is an initial-presentation gate. A later settings change
    // or differently keyed native replay must never conceal an already revealed
    // document while its new font request waits (including across suspension).
    if (root.dataset.mnbFontReady !== '1') {
        root.dataset.mnbFontPending = '1';
        root.dataset.mnbFontReady = '0';
    }
    const now = () => performance.now();
    const startedAt = now();
    const state = { key, promise: null, expire: null, cancel: null, timings: {} };
    let timedOut = false;
    let timer;
    // Publish cancellation before deferring work: a same-turn settings change
    // or retry must be able to retire this attempt before it installs a style.
    const deadline = new Promise(resolve => {
        state.expire = () => {
            timedOut = true;
            // Bound layout without discarding a face already loaded.
            if (state.timings.fontLoadMs != null) {
                state.timings.layoutDeadlineReached = 1;
                resolve('loaded');
            } else {
                resolve('timeout');
            }
        };
        state.cancel = () => { timedOut = true; resolve('unavailable'); };
        timer = setTimeout(state.expire, 4000);
    });
    // Defer work one microtask so duplicate commit/finish calls can join it.
    state.promise = Promise.resolve().then(async () => {
        let removeListeners = () => {};
        let removeDOMListener = () => {};
        let installedStyle;
        let outcome;
        try {
            const load = async () => {
                if (timedOut || globalThis.manabiReaderFontLoad !== state) return 'unavailable';
                const style = ensureStyle();
                installedStyle = style;
                if (!style) return 'unavailable';
                // Forwarded data markers cannot prove readiness in this
                // document. A parsed sheet must also match the current href:
                // replacing href can temporarily retain the preceding sheet.
                if (style.tagName === 'LINK' && style.sheet?.href !== style.href) {
                    await new Promise((resolve, reject) => {
                        const loaded = () => resolve();
                        const failed = () => reject(new Error('stylesheet'));
                        style.addEventListener('load', loaded, { once: true });
                        style.addEventListener('error', failed, { once: true });
                        removeListeners = () => {
                            style.removeEventListener('load', loaded);
                            style.removeEventListener('error', failed);
                        };
                    });
                }
                if (timedOut) return 'timeout';
                // A stylesheet's absence used to make fonts.load resolve with
                // zero faces. Never treat that as proof Kyokasho is available.
                const faces = await document.fonts.load("500 1em '" + family + "'", '日本語');
                if (timedOut) return 'timeout';
                if (faces.length === 0) return 'unavailable';
                state.timings.fontLoadMs = now() - startedAt;
                // Ordinary generated articles reveal after font-dependent
                // layout settles. EPUB retains its renderer's own layout gate.
                if (root.dataset.mnbFontLayoutGate === '1') {
                    if (document.readyState === 'loading') {
                        await new Promise(resolve => {
                            const ready = () => resolve();
                            document.addEventListener('DOMContentLoaded', ready, { once: true });
                            removeDOMListener = () => document.removeEventListener('DOMContentLoaded', ready);
                        });
                    }
                    if (timedOut) return 'timeout';
                    // WebKit's ready promise is gated on the load event, so
                    // awaiting it during initial loading also waits on images.
                    // The selected face is already loaded: settle its layout
                    // directly while those unrelated resources remain pending.
                    if (document.readyState === 'complete') await document.fonts.ready;
                    if (timedOut) return 'timeout';
                    const content = document.getElementById('reader-content') || document.body;
                    content?.getBoundingClientRect();
                }
                state.timings.layoutMs = now() - startedAt - state.timings.fontLoadMs;
                return 'loaded';
            };
            outcome = await Promise.race([deadline, load()]);
        } catch (_) {
            outcome = 'failed';
        } finally {
            clearTimeout(timer);
            removeListeners();
            removeDOMListener();
            if (state.timings.fontLoadMs != null && state.timings.layoutMs == null) {
                state.timings.layoutMs = now() - startedAt - state.timings.fontLoadMs;
            }
            state.expire = null;
            state.cancel = null;
        }
        if (globalThis.manabiReaderFontLoad === state) {
            // Disable before revealing fallback. Removing the node lets
            // settings/direction synchronization recreate it and swap fonts.
            if (outcome !== 'loaded') {
                if (installedStyle) installedStyle.disabled = true;
                // Forwarding can replace a pending node. Disable the current
                // node too, so it cannot introduce a face after fallback.
                const currentStyle = document.getElementById('mnb-custom-fonts-inline');
                if (currentStyle) currentStyle.disabled = true;
            }
            root.dataset.mnbFontOutcome = outcome;
            root.dataset.mnbFontReady = '1';
            state.timings.revealMs = now() - startedAt;
            delete root.dataset.mnbFontPending;
            try { globalThis.manabiForwardReaderFontToEbookDocuments?.('font-ready'); } catch (_) {}
            try { window.parent?.manabiForwardReaderFontToEbookDocuments?.('font-ready-child'); } catch (_) {}
            window.__manabiPostReaderDocStateEvent?.('font-' + outcome);
        }
        return outcome;
    });
    globalThis.manabiReaderFontLoad = state;
    return state.promise;
})();
"""#

/// Starts the existing readiness promise while WebKit parses the final document.
/// Commit/finish callbacks join this same attempt rather than transferring font data.
internal func upsertLocalSharedReaderFontBootstrap(
    in doc: SwiftSoup.Document,
    pageURL: URL,
    horizontalFontFamily: String,
    fontAsset: SharedReaderFontAsset? = nil,
    preloadsFont: Bool = false
) throws {
    guard let template = sharedReaderFontStylesheetURLTemplate(for: pageURL) else { return }
    let values = readerFontCSSValues(horizontalFamily: horizontalFontFamily)
    let body = doc.body()
    let direction = try body?.attr("data-mnb-writing-direction")
    let hasVerticalClass = (try body?.hasClass("reader-vertical-writing")) ?? false
    let bodyIsEbook = (try body?.attr("data-is-ebook")) == "true"
    let vertical = direction == "vertical" || (direction != "horizontal" && hasVerticalClass)
    try doc.getElementsByTag("html").first()?.attr("data-mnb-initial-writing-direction", vertical ? "vertical" : "horizontal")
    // A fresh generated document must not reuse serialized styles from an
    // earlier attempt, including a disabled timeout link or Base64 payload.
    try doc.select("#mnb-local-font-bootstrap, #mnb-local-font-preload, #mnb-custom-fonts-inline, #mnb-custom-fonts-inline-bootstrap").remove()
    if pageURL.isEBookURL || bodyIsEbook {
        try doc.getElementsByTag("html").first()?.removeAttr("data-mnb-font-layout-gate")
    } else if pageURL.isReaderDocumentURL {
        try doc.getElementsByTag("html").first()?.attr("data-mnb-font-layout-gate", "1")
    }
    if let fontAsset, fontAsset.supportsFamily(horizontalFontFamily),
       let css = sharedReaderFontCSS(for: pageURL, asset: fontAsset) {
        let style = try doc.createElement("style")
        try style.attr("id", "mnb-custom-fonts-inline")
        try style.attr("data-mnb-font-source", "local-scheme")
        try style.attr("data-mnb-font-hash", "local")
        try style.appendChild(DataNode(Array(css.utf8), doc.getBaseUriUTF8()))
        try (doc.head() ?? doc).appendChild(style)
        // Opt-in experiment only: do not enable without proving request reuse
        // and a meaningful latency improvement in iOS WebKit.
        if preloadsFont, let fontURL = sharedReaderFontFontURL(for: pageURL, asset: fontAsset) {
            let preload = try doc.createElement("link")
            try preload.attr("id", "mnb-local-font-preload")
            try preload.attr("rel", "preload")
            try preload.attr("as", "font")
            try preload.attr("type", fontAsset.mimeType)
            try preload.attr("crossorigin", "anonymous")
            try preload.attr("href", fontURL.absoluteString)
            try (doc.head() ?? doc).appendChild(preload)
        }
    }
    let script = try doc.createElement("script")
    try script.attr("id", "mnb-local-font-bootstrap")
    let javascript = """
    (() => {
        const stylesheetURLTemplate = \(readerModeJSONStringLiteral(template));
        const fontHash = 'local';
        const horizontalFontFamily = \(readerModeJSONStringLiteral(values.horizontalFamily));
        const verticalFontFamily = \(readerModeJSONStringLiteral(values.verticalFamily));
        \(sharedReaderFontInjectionJavaScript)
    })();
    """
    try script.appendChild(DataNode(Array(javascript.utf8), doc.getBaseUriUTF8()))
    try (doc.head() ?? doc).appendChild(script)
}

/// Readability always owns its renderer origin. Provider referrers and resource
/// context are supplied by the typed transports, never by changing this URL.
internal func readerModeDocumentURL(for sourceURL: URL, in doc: SwiftSoup.Document) throws -> URL {
    if sourceURL.isHTTP || sourceURL.isSnippetURL {
        return ReaderContentLoader.readerDocumentURL(for: sourceURL) ?? sourceURL
    }
    return sourceURL
}

public enum ReaderStoredContentLoadOutcome: Sendable, Equatable {
    case inapplicable
    case accepted
    case superseded
}

enum ReaderPreparedReadabilityDocumentError: Error {
    case superseded
}

@MainActor
internal func retrySupersededReadabilityPreparation(
    operation: @MainActor () async throws -> Void
) async throws {
    for attempt in 1...3 {
        try Task.checkCancellation()
        do {
            try await operation()
            return
        } catch ReaderPreparedReadabilityDocumentError.superseded {
            ReaderLoadTrace.event("readerMode.preparationSuperseded", "attempt=\(attempt)")
            guard attempt < 3 else { throw ReaderPreparedReadabilityDocumentError.superseded }
        }
    }
}

/// Installs a presentation-only gate in fresh Readability HTML. It is never
/// cached as progress or used by EPUB. Layout remains measurable while hidden.
internal func prepareReaderInitialArticlePresentation(in document: SwiftSoup.Document) throws {
    guard let root = try document.select("html").first() else { return }
    try root.attr("data-mnb-article-presentation", "pending")
    try document.getElementById("mnb-initial-article-presentation-style")?.remove()
    let style = try document.createElement("style")
    try style.attr("id", "mnb-initial-article-presentation-style")
    try style.text("html[data-mnb-article-presentation='pending'] body.readability-mode{visibility:hidden!important;opacity:0!important}")
    try (document.head() ?? document).appendChild(style)
    try document.getElementById("mnb-initial-article-presentation")?.remove()
    let script = try document.createElement("script")
    try script.attr("id", "mnb-initial-article-presentation")
    let source = #"""
    (() => {
        const root = document.documentElement;
        let deadline;
        const finish = outcome => {
            if (root.dataset.mnbArticlePresentation !== 'pending') return false;
            clearTimeout(deadline);
            if (outcome !== 'ready') {
                // Visible fallback and browser history now own the viewport.
                // A late native progress sample may hydrate, but must not jump it.
                document.manabi_hasRecalledReadingPosition = true;
                try { window.manabi_cancelPositionRecallPresentation?.(); } catch (_) {}
            }
            root.dataset.mnbArticlePresentation = outcome;
            if (outcome === 'timeout') {
                window.webkit?.messageHandlers?.manabiReaderPresentationSettled?.postMessage?.({
                    windowURL: window.location.href,
                    documentStartedAtMs: performance.timeOrigin,
                    outcome,
                });
            }
            window.dispatchEvent(new Event('manabiarticlepresentationchange'));
            window.__manabiPostReaderDocStateEvent?.('article-' + outcome);
            return true;
        };
        window.manabi_finishInitialArticlePresentation = finish;
        // A missing native callback must not permanently conceal readable text.
        deadline = setTimeout(() => finish('timeout'), 8000);
        // BFCache preserves styles and DOM state. Never store a concealed page
        // whose native initialization owner was retired by navigation away.
        window.addEventListener('pagehide', () => finish('interrupted'), { once: true });
    })();
    """#
    try script.appendChild(DataNode(Array(source.utf8), document.getBaseUriUTF8()))
    try (document.head() ?? document).appendChild(script)
}

internal func upsertDeferredSharedReaderFontGate(in doc: SwiftSoup.Document, waitsForArticleLayout: Bool = false) throws {
    let gateCSS = """
    html[data-mnb-font-pending="1"] body.readability-mode {
        visibility: hidden !important;
        opacity: 0 !important;
    }
    """

    let htmlElement = try doc.getElementsByTag("html").first()
    try htmlElement?.attr("data-mnb-font-pending", "1")
    try htmlElement?.attr("data-mnb-font-ready", "0")
    try htmlElement?.removeAttr("data-mnb-font-outcome")
    try htmlElement?.removeAttr("data-mnb-font-layout-gate")
    if waitsForArticleLayout {
        try htmlElement?.attr("data-mnb-font-layout-gate", "1")
    }
    try doc.select("#mnb-custom-fonts-inline, #mnb-custom-fonts-inline-bootstrap, #mnb-local-font-bootstrap, #mnb-local-font-preload").remove()

    try doc.getElementById("mnb-custom-font-gate-fallback")?.remove()
    let script = try doc.createElement("script")
    try script.attr("id", "mnb-custom-font-gate-fallback")
    let fallbackJavaScript = """
    clearTimeout(globalThis.manabiReaderFontGateFallbackTimer);
    globalThis.manabiReaderFontGateFallbackTimer = setTimeout(() => {
        const root = document.documentElement;
        if (root?.dataset.mnbFontPending !== '1') return;
        // The visibility escape and injector settle the same attempt.
        // Without this, an early escape can race a later font load.
        const attempt = globalThis.manabiReaderFontLoad;
        if (typeof attempt?.expire === 'function') {
            attempt.expire();
            return;
        }
        const style = document.getElementById('mnb-custom-fonts-inline');
        if (style) style.disabled = true;
        root.dataset.mnbFontOutcome = 'timeout';
        root.dataset.mnbFontReady = '1';
        delete root.dataset.mnbFontPending;
        window.__manabiPostReaderDocStateEvent?.('font-timeout');
    }, 4500);
    """
    // Script is raw text. Fragment parsing a detached script produces
    // ordinary text nodes, whose arrow operators serialize as entities.
    try script.appendChild(DataNode(Array(fallbackJavaScript.utf8), doc.getBaseUriUTF8()))
    try (doc.head() ?? doc).appendChild(script)

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

enum SwiftReadabilityProcessingOutcome {
    case success(SwiftReadabilityProcessingResult)
    case unavailable
    case failed
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

struct SwiftReadabilityProcessingResult {
    let outputHTML: String
}

private func normalizeReadabilityBodyOrder(_ doc: SwiftSoup.Document) {
    guard let body = doc.body(),
          let readerHeader = try? doc.getElementById("reader-header"),
          let readerContent = try? doc.getElementById("reader-content") else {
        return
    }

    var nodesToMove: [SwiftSoup.Element] = []
    for child in body.children().array() {
        if child === readerHeader {
            break
        }
        if child === readerContent {
            continue
        }
        nodesToMove.append(child)
    }

    for node in nodesToMove.reversed() {
        try? readerContent.prependChild(node)
    }
}

private func hasReaderContentMedia(in doc: SwiftSoup.Document) -> Bool {
    guard let readerContent = try? doc.getElementById("reader-content") else {
        return false
    }
    let selector = [
        "[data-readability-carousel=\"true\"]",
        "[data-readability-carousel=true]",
        "img",
        "picture",
        "video",
        "figure",
    ].joined(separator: ",")
    return ((try? readerContent.select(selector).isEmpty()) == false)
}

private enum ReadabilityHTMLEscapeBytes {
    static let ampersand = UInt8(ascii: "&")
    static let lessThan = UInt8(ascii: "<")
    static let greaterThan = UInt8(ascii: ">")
    static let quotationMark = UInt8(ascii: "\"")
    static let ampersandEntity = Array("&amp;".utf8)
    static let lessThanEntity = Array("&lt;".utf8)
    static let greaterThanEntity = Array("&gt;".utf8)
    static let quotationMarkEntity = Array("&quot;".utf8)
}

private func escapeReadabilityUTF8(
    _ bytes: UnsafeBufferPointer<UInt8>,
    original: String
) -> String {
    guard let firstEscapeIndex = bytes.firstIndex(where: { byte in
        byte == ReadabilityHTMLEscapeBytes.ampersand
            || byte == ReadabilityHTMLEscapeBytes.lessThan
            || byte == ReadabilityHTMLEscapeBytes.greaterThan
            || byte == ReadabilityHTMLEscapeBytes.quotationMark
    }) else {
        return original
    }

    var escaped = [UInt8]()
    escaped.reserveCapacity(bytes.count + 16)
    escaped.append(contentsOf: bytes[..<firstEscapeIndex])
    for byte in bytes[firstEscapeIndex...] {
        switch byte {
        case ReadabilityHTMLEscapeBytes.ampersand:
            escaped.append(contentsOf: ReadabilityHTMLEscapeBytes.ampersandEntity)
        case ReadabilityHTMLEscapeBytes.lessThan:
            escaped.append(contentsOf: ReadabilityHTMLEscapeBytes.lessThanEntity)
        case ReadabilityHTMLEscapeBytes.greaterThan:
            escaped.append(contentsOf: ReadabilityHTMLEscapeBytes.greaterThanEntity)
        case ReadabilityHTMLEscapeBytes.quotationMark:
            escaped.append(contentsOf: ReadabilityHTMLEscapeBytes.quotationMarkEntity)
        default:
            escaped.append(byte)
        }
    }
    return String(decoding: escaped, as: UTF8.self)
}

private func escapeReadabilityText(_ raw: String) -> String {
    if let escaped = raw.utf8.withContiguousStorageIfAvailable({ bytes in
        escapeReadabilityUTF8(bytes, original: raw)
    }) {
        return escaped
    }
    let bytes = Array(raw.utf8)
    return bytes.withUnsafeBufferPointer { buffer in
        escapeReadabilityUTF8(buffer, original: raw)
    }
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
    let trace = ReaderLoadTrace.begin("readerMode.publicationDateFallback")
    defer { trace?.end() }
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

@MainActor
internal func readerContentPublicationDateFallback(
    for content: any ReaderContentProtocol
) async -> String? {
    if !(content is HistoryRecord),
       (content.displayPublicationDate || content.isPhysicalMedia),
       let publicationDate = content.publicationDate {
        return formattedReaderContentPublicationDate(
            ReaderContentPublicationDateSnapshot(
                publicationDate: publicationDate,
                displayAbsolutePublicationDate: content.displayAbsolutePublicationDate,
                contentType: String(describing: type(of: content))
            )
        )
    }
    return await readerContentPublicationDateFallback(for: content.url)
}

internal func buildCanonicalReadabilityHTML(
    title: String,
    byline: String,
    publishedTime: String?,
    content: String,
    contentURL: URL,
    hideReaderTitle: Bool = false,
    referrerPolicy: String? = nil,
    resourceBaseURL: URL? = nil,
    headerImageGeometry: ReaderImageGeometry? = nil
) -> String {
    let resourceBase = resourceBaseURL.map { "<base href=\"\(escapeReadabilityHTMLAttribute($0.absoluteString))\">" } ?? ""
    let referrerMeta = normalizedReaderReferrerPolicy(referrerPolicy).map { "<meta name=\"referrer\" content=\"\($0)\">" } ?? ""
    let resolvedTitle = escapeReadabilityText(title)
    let resolvedByline = escapeReadabilityText(normalizeReadabilityBylineText(byline))
    let readerFontSize = readerStoredFontSize()
    let viewOriginal = isInternalReaderURL(contentURL) ? nil : "<a class=\"reader-view-original\" href=\"\(escapeReadabilityHTMLAttribute(contentURL.absoluteString))\">View Original</a>"
    let publishedTime = publishedTime?.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasPublicationDate = !(publishedTime?.isEmpty ?? true)
    let authorDivider = hasPublicationDate || viewOriginal != nil
        ? "<span class=\"reader-byline-divider\" aria-hidden=\"true\">\u{00a0}·</span>" : ""
    let bylineLine = resolvedByline.isEmpty
        ? ""
        : "<div id=\"reader-byline-line\" class=\"byline-line\"><span class=\"byline-label\">By</span> <span id=\"reader-byline\" class=\"byline\" data-mnb-explicit-divider=\"true\">\(resolvedByline)</span>\(authorDivider)</div>"
    let publicationDateItem = publishedTime.flatMap { publishedTime -> String? in
        guard hasPublicationDate else { return nil }
        let text = escapeReadabilityText(publishedTime)
        let accessibilityLabel = escapeReadabilityHTMLAttribute(
            "Date: \(publishedTime)"
        )
        return "<span id=\"reader-publication-date\" aria-label=\"\(accessibilityLabel)\">\(text)</span>"
    }
    let metaItems = [
        publicationDateItem,
        viewOriginal,
    ]
        .compactMap { $0 }
    let metaLine = metaItems.isEmpty
        ? ""
        : """
        <div id="reader-meta-line" class="byline-meta-line">\(metaItems.joined(separator: "<span class=\"reader-meta-divider\" aria-hidden=\"true\">·</span>"))</div>
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
    // Owned documents recreate their trusted shell at final preparation.
    // Keep canonical content small through storage, parsing and analysis.
    // File-backed routes still require their existing inline presentation.
    let usesOwnedDocument = contentURL.isHTTP || contentURL.isSnippetURL
    let inlineStyles = usesOwnedDocument ? "" : """
    <style type="text/css" id="swiftuiwebview-readability-styles">\(readerModeReadabilityCSS)
    \(titleSuppressionCSS)</style>
    """
    let inlineScript = usesOwnedDocument ? "" : """
    <script>
        \(Readability.shared.scripts)
    </script>
    """
    let bodyClass = hideReaderTitle
        ? "readability-mode \(suppressionBodyClass)"
        : "readability-mode"
    return """
    <!DOCTYPE html>
    <html>
        <head>
            <meta charset="utf-8">
            \((try? headerImageGeometry?.metadataHTML()) ?? "")
            \(referrerMeta)\(resourceBase)
            <meta name="viewport" content="\(readabilityViewportMetaContent)">
            \(inlineStyles)
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
            \(inlineScript)
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

internal func hasPersistedReaderSegmentMarkup(in html: String) -> Bool {
    guard hasCanonicalReadabilityMarkup(in: html) else { return false }
    // Persisted scripts may have been stripped or externalized. Native-owned
    // wrappers still require re-admission or clean regeneration in both cases.
    return html.range(
        of: #"<m-(?:m|s|c|t)(?:\s|>)"#,
        options: [.regularExpression, .caseInsensitive]
    ) != nil
}

/// Removes only markup that the native reader processor owns from a persisted
/// snippet so it can be submitted to the current readability processor again.
/// Source ruby is left intact unless the native ruby marker identifies it as
/// generated. The reader tags are structural wrappers, so unwrapping them
/// preserves text and the order of adjacent source nodes.
internal func recoverPersistedSnippetSourceHTMLForProcessing(_ html: String) -> String? {
    guard let document = try? SwiftSoup.parse(html),
          (try? document.getElementById("reader-content")) != nil else {
        return nil
    }
    document.outputSettings().prettyPrint(pretty: false).syntax(syntax: .html)
    document.outputSettings().charset(.utf8)

    let generatedSidecarSelectors = [
        "#mnb-initial-article-presentation",
        "#mnb-initial-article-presentation-style",
        "script#mnb-segment-metadata",
        "script#mnb-segment-metadata-aggregate",
        "meta[name=mnb-segment-sidecar]",
        "[data-mnb-seg-meta]",
        "[data-mnb-seg-meta-aggregate]",
        "[data-mnb-title-seg-meta]",
    ]
    for selector in generatedSidecarSelectors {
        try? document.select(selector).remove()
    }

    for ruby in (try? document.getElementsByTag("ruby").array()) ?? [] {
        let isGenerated = (try? ruby.hasClass("mnb-gen")) == true
            || (try? ruby.attr("data-mnb-generated")) == "true"
        guard isGenerated else { continue }
        try? ruby.select("rt, rp").remove()
        try? ruby.unwrap()
    }

    for selector in ["m-m", "m-t", "m-s", "m-c"] {
        try? document.select(selector).unwrap()
    }

    let generatedAttributes = [
        "data-mnb-cache-reset-epoch",
        "data-mnb-cache-reset-generation",
        "data-mnb-analysis-session-cache-identifier",
        "data-mnb-native-sidecar-content-fingerprint",
        "data-mnb-initial-source-reading-memory",
        "data-mnb-source-reading-memory-changed",
        "data-mnb-native-dictionaries-key",
        "data-mnb-native-processor-schema",
        "data-mnb-has-reader-segments",
        "data-mnb-seg-meta-token",
        "data-mnb-article-presentation",
        "data-mnb-reader-render-ready",
        "data-mnb-reader-render-generation",
        "data-mnb-reader-mode-available",
        "data-mnb-reader-mode-available-for",
    ]
    for element in (try? document.select("html, body, [data-mnb-seg-meta-token]").array()) ?? [] {
        for attribute in generatedAttributes {
            try? element.removeAttr(attribute)
        }
    }

    guard let body = document.body(),
          let content = try? body.getElementById("reader-content"),
          let contentHTML = try? content.html(),
          !contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    return try? document.outerHtml()
}

internal func processPersistedSnippetWithCurrentReadabilityProcessor(
    document: SwiftSoup.Document,
    readabilityContent: String,
    url: URL,
    tracksReadingProgress: Bool,
    processReadabilityContent: EbookReadabilityContentProcessor?,
    republishReaderModeRuntimeAuthority: ((SwiftSoup.Document, URL, URL?) async -> Bool)?,
    preprocessDoc: @escaping EbookDocumentTransform
) async throws -> SwiftSoup.Document {
    if let republishReaderModeRuntimeAuthority,
       await republishReaderModeRuntimeAuthority(document, url, nil) {
        return document
    }

    guard let processReadabilityContent,
          let sourceHTML = recoverPersistedSnippetSourceHTMLForProcessing(readabilityContent) else {
        throw ReaderModeRuntimeAuthorityError.unavailable
    }
    return try await processReadabilityContent(
        sourceHTML,
        url,
        nil,
        false,
        tracksReadingProgress,
        nil,
        preprocessDoc
    )
}

internal struct ReaderSnippetFinalDocumentSnapshot: Equatable, Sendable {
    let parsedSuccessfully: Bool
    let readerContentContainerPresent: Bool
    let segmentCount: Int
    let inlineSidecarPresent: Bool
    let externalSidecarDescriptorPresent: Bool

    static func make(htmlBytes: [UInt8]) -> ReaderSnippetFinalDocumentSnapshot {
        guard let html = String(bytes: htmlBytes, encoding: .utf8),
              let document = try? SwiftSoup.parse(html) else {
            return ReaderSnippetFinalDocumentSnapshot(
                parsedSuccessfully: false,
                readerContentContainerPresent: false,
                segmentCount: 0,
                inlineSidecarPresent: false,
                externalSidecarDescriptorPresent: false
            )
        }
        return ReaderSnippetFinalDocumentSnapshot(
            parsedSuccessfully: true,
            readerContentContainerPresent: (try? document.getElementById("reader-content")) != nil,
            segmentCount: (try? document.select("m-m").count) ?? 0,
            inlineSidecarPresent: (try? document.getElementById("mnb-segment-metadata")) != nil,
            externalSidecarDescriptorPresent: !((try? document.select(
                "meta[name=mnb-segment-sidecar]"
            ).array()) ?? []).isEmpty
        )
    }
}

private enum ReaderSnippetFinalDocumentDiagnostics {
    static let logPrefix = "ReaderSnippetProcessingDiagnostics"

    static func emitIfEnabled(htmlBytes: [UInt8], contentURL: URL) {
#if DEBUG
        guard contentURL.isSnippetURL,
              ProcessInfo.processInfo.arguments.contains("--ui-test-enable-lookup-probe") else {
            return
        }
        let snapshot = ReaderSnippetFinalDocumentSnapshot.make(htmlBytes: htmlBytes)
        print(
            "\(logPrefix) stage=finalDocument isSnippet=true contentURL=\(contentURL.absoluteString) "
                + "parsedSuccessfully=\(snapshot.parsedSuccessfully) "
                + "readerContentContainerPresent=\(snapshot.readerContentContainerPresent) "
                + "segmentCount=\(snapshot.segmentCount) "
                + "inlineSidecarPresent=\(snapshot.inlineSidecarPresent) "
                + "externalSidecarDescriptorPresent=\(snapshot.externalSidecarDescriptorPresent)"
        )
#endif
    }
}

/// Removes regenerable reader assets before canonical HTML is stored. Final
/// presentation sanitization and resource registration have their own boundary.
internal func stripRuntimeReadabilityAssets(from html: String) -> String {
    // Legacy caches and retained content with scripts/styles still use parsed
    // cleanup. Already-clean canonical content needs no parse or serialization.
    guard html.range(of: "<script", options: .caseInsensitive) != nil
            || html.range(of: "<style", options: .caseInsensitive) != nil,
          hasCanonicalReadabilityMarkup(in: html),
          let doc = try? SwiftSoup.parse(html) else {
        return html
    }

    try? doc.select("script").remove()
    try? doc.select([
        "style#swiftuiwebview-readability-styles",
        "style#mnb-reader-canvas",
        "style#mnb-mark-read-buttons-visibility-style",
        "style#mnb-readability-styles",
    ].joined(separator: ",")).remove()
    return (try? doc.outerHtml()) ?? html
}

private func readabilitySubstringCount(_ needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let range = haystack.range(of: needle, options: [.caseInsensitive], range: searchRange) {
        count += 1
        searchRange = range.upperBound..<haystack.endIndex
    }
    return count
}

private func looksLikeStaleCachedCanonicalReadabilityHTML(_ html: String, url: URL) -> Bool {
    guard hasCanonicalReadabilityMarkup(in: html),
          let host = url.host?.lowercased(),
          host == "hypebeast.com" || host.hasSuffix(".hypebeast.com") else {
        return false
    }
    return readabilitySubstringCount("data-readability-carousel", in: html) == 0
}

internal func markReaderRenderReady(
    in doc: SwiftSoup.Document,
    renderGeneration: UUID? = nil
) {
    try? doc.select("html").first()?.attr("data-mnb-reader-render-ready", "1")
    try? doc.body()?.attr("data-mnb-reader-render-ready", "1")
    if let renderGeneration {
        let value = renderGeneration.uuidString
        try? doc.select("html").first()?.attr("data-mnb-reader-render-generation", value)
        try? doc.body()?.attr("data-mnb-reader-render-generation", value)
    }
}

internal func markReaderSubscriptionInactiveByDefault(in doc: SwiftSoup.Document) {
    guard let body = doc.body(),
          ((try? body.hasAttr("data-mnb-subscription-is-active")) ?? false) == false else {
        return
    }
    try? body.attr("data-mnb-subscription-is-active", "false")
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

private func readerHeadingTextWithoutRuby(_ heading: SwiftSoup.Element?) -> String? {
    guard let copy = heading?.copy() as? SwiftSoup.Element else { return nil }
    // Annotations belong to the rendered heading, not its saved plain title.
    try? copy.select("rt, rp").remove()
    return try? copy.text()
}

/// Keep prepared lookup identities and ruby when a snippet's saved title is
/// unchanged. Replacing its children here would make JavaScript process the
/// same title again after native preparation and sidecar publication.
@discardableResult
internal func updateSnippetReaderTitleIfNeeded(
    in document: SwiftSoup.Document,
    title: String
) throws -> Bool {
    guard let heading = try document.getElementById("reader-title"),
          readerHeadingTextWithoutRuby(heading) != title else { return false }
    try heading.text(title)
    return true
}

internal func titleFromReadabilityDocument(_ doc: SwiftSoup.Document) -> String? {
    func normalisedTitle(_ raw: String?) -> String? {
        let trimmed = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.truncate(36)
    }

    if let readerTitleText = readerHeadingTextWithoutRuby(try? doc.getElementById("reader-title")),
       let title = normalisedTitle(readerTitleText) {
        return title
    }

    if let headingText = readerHeadingTextWithoutRuby(try? doc.getElementsByTag("h1").first()),
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

/// Captured-body authority is separate from the presence of source HTML bytes.
func shouldStorePreparedReaderHTML(for content: any ReaderContentProtocol) -> Bool {
    let url = content.url
    // FeedEntry's body policy is inherited from Feed. Capturing one article
    // must neither replace its source entry nor change the entire feed policy.
    guard !(content is FeedEntry), !url.isEBookURL, !url.isFileURL,
          !url.isNativeReaderView, !url.isReaderFileURL else { return false }
    // Summaries and metadata-only HTML have bytes but are not captured bodies.
    return !content.rssContainsFullContent || (content.content?.isEmpty ?? true)
}

/// Enrich only our canonical head; interpreting the article body still has one
/// parser owner. Replacing metadata also retires a previous image's dimensions.
func canonicalHTMLPreservingImageGeometry(_ html: String, geometry: ReaderImageGeometry?,
                                          sourceURL: URL) -> String {
    guard let geometry, hasCanonicalReadabilityMarkup(in: html) else { return html }
    return geometry.mergingIntoDocumentHead(html, sourceURL: sourceURL)
}

/// Immutable interpretation of one canonical document. The mutable parser tree
/// stays on the caller's actor and never crosses an asynchronous boundary.
struct ReaderCanonicalReadabilityContent: Sendable {
    let title: String?
    let fallbackTitle: String?
    let byline: String?
    let publicationDate: String?
    let contentHTML: String
    let referrerPolicy: String?
    let resourceBaseURL: URL?
    let headerImageGeometry: ReaderImageGeometry?
}

func extractCanonicalReadabilityContent(
    html: String,
    sourceURL: URL
) -> ReaderCanonicalReadabilityContent? {
    let trace = ReaderLoadTrace.begin("readerMode.canonicalInterpretation")
    defer { trace?.end() }
    guard let document = try? SwiftSoup.parse(html, sourceURL.absoluteString) else { return nil }
    document.outputSettings().prettyPrint(pretty: false)
    guard let rawContent = try? document.getElementById("reader-content")?.html(),
          let content = trimmedNonEmptyReadabilityText(rawContent) else { return nil }
    let declaredBase = try? document.select("base[href]").first()?.attr("href")
    return ReaderCanonicalReadabilityContent(
        title: try? document.getElementById("reader-title")?.text(trimAndNormaliseWhitespace: false),
        fallbackTitle: titleFromReadabilityDocument(document)
            ?? trimmedNonEmptyReadabilityText(readerHeadingTextWithoutRuby(document.body()))?.truncate(36),
        byline: try? document.getElementById("reader-byline")?.text(trimAndNormaliseWhitespace: false),
        publicationDate: try? document.getElementById("reader-publication-date")?.text(trimAndNormaliseWhitespace: false),
        contentHTML: content,
        referrerPolicy: try? readerDocumentReferrerPolicy(in: document),
        resourceBaseURL: declaredBase.flatMap { URL(string: $0, relativeTo: sourceURL)?.absoluteURL },
        headerImageGeometry: ReaderImageGeometry.metadata(in: document, sourceURL: sourceURL)
    )
}

func rebuildCanonicalSnippetReadabilityHTML(
    html: String,
    contentURL: URL,
    fallbackTitle: String? = nil,
    publishedTime: String? = nil,
    preferredTitle: String? = nil,
    hideReaderTitleOverride: Bool? = nil
) -> String? {
    guard let extracted = extractCanonicalReadabilityContent(html: html, sourceURL: contentURL) else { return nil }
    let resolvedTitle = trimmedNonEmptyReadabilityText(preferredTitle)
        ?? trimmedNonEmptyReadabilityText(extracted.title)
        ?? trimmedNonEmptyReadabilityText(fallbackTitle)
        ?? extracted.fallbackTitle
        ?? ""
    let sanitizedTitle = sanitizeReadabilityFragment(resolvedTitle)
    let sanitizedByline = sanitizeReadabilityFragment(extracted.byline ?? "")
    let resolvedPublishedTime = trimmedNonEmptyReadabilityText(publishedTime)
        ?? trimmedNonEmptyReadabilityText(extracted.publicationDate)
    let sanitizedContent = sanitizeReadabilityFragment(extracted.contentHTML)
    let shouldHideReaderTitle = hideReaderTitleOverride
        ?? ReaderContentLoader.snippetTitleMatchesGeneratedPrefix(
            resolvedTitle,
            sourceHTML: extracted.contentHTML
        )
    guard !sanitizedContent.isEmpty else { return nil }
    return buildCanonicalReadabilityHTML(
        title: sanitizedTitle,
        byline: sanitizedByline,
        publishedTime: resolvedPublishedTime,
        content: sanitizedContent,
        contentURL: contentURL.canonicalReaderContentURLForHotfix(),
        hideReaderTitle: shouldHideReaderTitle,
        referrerPolicy: extracted.referrerPolicy,
        resourceBaseURL: extracted.resourceBaseURL,
        headerImageGeometry: extracted.headerImageGeometry
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
    let result = trimmed.isEmpty ? nil : trimmed
    return result
}

/// Related-record defaults are durable bookkeeping, not a prerequisite for
/// presenting the prepared article. Capture storage before queueing the write;
/// a later account/store replacement must not redirect it into another Realm.
func propagateReaderModeDefaults(
    for url: URL,
    primaryKey: String,
    readabilityHTML: String,
    fallbackTitle: String?,
    derivedTitle: String? = nil,
    storage: ReaderContentLoader.DiscoveryStorage = .init()
) async {
    if url.isSnippetURL {
        return
    }
    let storageReadabilityHTML = stripRuntimeReadabilityAssets(from: readabilityHTML)
    let resolvedTitle = derivedTitle ?? titleFromReadabilityHTML(storageReadabilityHTML) ?? fallbackTitle
    let trace = ReaderLoadTrace.begin("readerMode.defaultsPropagation")
    var outcome = "failed"
    defer { trace?.end(outcome) }
    do {
        let changed = try await propagateReaderModeDefaultsOnBackgroundActor(
            for: url,
            primaryKey: primaryKey,
            readabilityHTML: storageReadabilityHTML,
            resolvedTitle: resolvedTitle,
            storage: storage
        )
        outcome = "changed=\(changed)"
    } catch is CancellationError {
        outcome = "cancelled"
    } catch {
        // This is an optional cache/default update. The original content
        // remains available, and a later open can try again.
    }
}

@RealmBackgroundActor
func propagateReaderModeDefaultsOnBackgroundActor(
    for url: URL,
    primaryKey: String,
    readabilityHTML: String,
    resolvedTitle: String?,
    storage: ReaderContentLoader.DiscoveryStorage
) async throws -> Int {
    let relatedRecords = try await ReaderContentLoader.loadAll(
        url: url, skipContentFiles: false, skipFeedEntries: true, storage: storage
    )

    let writableRecords = relatedRecords.filter { $0.compoundKey != primaryKey && $0.realm != nil }
    let suppliesWebContent = !url.isEBookURL && !url.isFileURL && !url.isNativeReaderView
    let timestamp = Date()
    var changed = 0
    for record in writableRecords {
        func needsUpdate() -> Bool {
            guard !record.isInvalidated, !record.isDeleted else { return false }
            return !record.isReaderModeByDefault || record.isReaderModeAvailable
                || (suppliesWebContent && (
                    !record.rssContainsFullContent
                        || (!url.isReaderFileURL && (record.content?.isEmpty ?? true))
                        || (resolvedTitle != nil && record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && record.title != resolvedTitle)
                ))
        }
        guard needsUpdate(), let realm = record.realm else { continue }
        let didChange = try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            try storage.validate()
            guard needsUpdate() else { return false }
            record.isReaderModeByDefault = true
            record.isReaderModeAvailable = false
            if suppliesWebContent {
                if shouldStorePreparedReaderHTML(for: record) {
                    record.html = readabilityHTML
                }
                if let resolvedTitle,
                   record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    record.title = resolvedTitle
                }
                record.rssContainsFullContent = true
            }
            record.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
            return true
        }
        if didChange { changed += 1 }
    }
    return changed
}

@MainActor
@Perceptible
public final class ReaderModeLoadingState {
    public struct Snapshot: Equatable {
        public var isReaderModeLoading: Bool
        public var lastRenderedURL: URL?
        public var expectedSyntheticReaderLoaderURL: URL?
        public var pendingReaderModeURL: URL?
        public var originalHTMLFallbackURL: URL?
        public var failedReaderModeURL: URL? = nil

        public static let empty = Snapshot(
            isReaderModeLoading: false,
            lastRenderedURL: nil,
            expectedSyntheticReaderLoaderURL: nil,
            pendingReaderModeURL: nil,
            originalHTMLFallbackURL: nil
        )

        public var hasRenderedReadabilityContent: Bool {
            lastRenderedURL != nil
        }
    }

    public private(set) var snapshot: Snapshot = .empty

    public init() {}

    public var isReaderModeLoading: Bool { snapshot.isReaderModeLoading }
    public var lastRenderedURL: URL? { snapshot.lastRenderedURL }
    public var expectedSyntheticReaderLoaderURL: URL? { snapshot.expectedSyntheticReaderLoaderURL }
    public var pendingReaderModeURL: URL? { snapshot.pendingReaderModeURL }
    public var hasRenderedReadabilityContent: Bool { snapshot.hasRenderedReadabilityContent }
    public var originalHTMLFallbackURL: URL? { snapshot.originalHTMLFallbackURL }
    public var failedReaderModeURL: URL? { snapshot.failedReaderModeURL }

    public func hasFailedReaderModeLoad(for url: URL) -> Bool {
        snapshot.failedReaderModeURL?.matchesReaderURL(url) == true
    }

    public func isShowingOriginalHTMLFallback(for url: URL) -> Bool {
        guard !url.isReaderURLLoaderURL else { return false }
        return snapshot.originalHTMLFallbackURL?.matchesReaderURL(url) == true
    }

    fileprivate func set(
        isReaderModeLoading: Bool,
        lastRenderedURL: URL?,
        expectedSyntheticReaderLoaderURL: URL?,
        pendingReaderModeURL: URL?,
        originalHTMLFallbackURL: URL?,
        failedReaderModeURL: URL?
    ) {
        snapshot = Snapshot(
            isReaderModeLoading: isReaderModeLoading,
            lastRenderedURL: lastRenderedURL,
            expectedSyntheticReaderLoaderURL: expectedSyntheticReaderLoaderURL,
            pendingReaderModeURL: pendingReaderModeURL,
            originalHTMLFallbackURL: originalHTMLFallbackURL,
            failedReaderModeURL: failedReaderModeURL
        )
    }
}

func readerModeRenderGenerationIsCurrent(
    activeGeneration: UUID?,
    expectedGeneration: UUID,
    taskIsCancelled: Bool
) -> Bool {
    !taskIsCancelled && activeGeneration == expectedGeneration
}

func readerModeReadyGenerationIsCurrent(
    activeGeneration: UUID?,
    completedGeneration: UUID?,
    reportedGeneration: UUID?
) -> Bool {
    if let activeGeneration {
        return reportedGeneration == activeGeneration
    }
    if let completedGeneration {
        return reportedGeneration == completedGeneration
    }
    return reportedGeneration == nil
}

@MainActor
public class ReaderModeViewModel: ObservableObject {
    public var readerFileManager: ReaderFileManager?
    private var isBatchingProcessingDependencyChanges = false
    internal private(set) var processingDependencyRevision: UInt64 = 0
    private func processingDependencyWillChange() {
        guard !isBatchingProcessingDependencyChanges else { return }
        processingDependencyRevision &+= 1
        objectWillChange.send()
    }

    /// Publishes one observable-object change for a logically atomic dependency
    /// installation. ReaderWebView uses that publication to bind the complete
    /// configuration to its URL-scheme handler instead of rebinding once per closure.
    public func performBatchProcessingDependencyUpdate(_ update: () -> Void) {
        guard !isBatchingProcessingDependencyChanges else {
            update()
            return
        }
        isBatchingProcessingDependencyChanges = true
        defer { isBatchingProcessingDependencyChanges = false }
        processingDependencyRevision &+= 1
        objectWillChange.send()
        update()
    }

    public var ebookProcessedTextCacheReader: EbookProcessedTextCacheReader? = nil {
        willSet { processingDependencyWillChange() }
    }
    public var ebookProcessedTextCacheWriter: EbookProcessedTextCacheWriter? = nil {
        willSet { processingDependencyWillChange() }
    }
    public var ebookProcessingVariantProvider: EbookProcessingVariantProvider? = nil {
        willSet { processingDependencyWillChange() }
    }
    public var ebookSectionPresentationProvider: EbookSectionPresentationProvider? = nil {
        willSet { processingDependencyWillChange() }
    }
    public var nativeEbookSectionPrewarmer: ((ReaderEBookServingLease, String, Bool) async throws -> EBookNativeSectionPrewarmResult)? = nil {
        willSet { processingDependencyWillChange() }
    }
    public var processReadabilityContent: ((String, URL, URL?, Bool, Bool, String?, ((SwiftSoup.Document) async -> SwiftSoup.Document)) async throws -> SwiftSoup.Document)? = nil {
        willSet { processingDependencyWillChange() }
    }
    /// Re-admits native segment authority when a persisted snippet already has
    /// canonical markup. A failed admission causes the caller to regenerate
    /// semantic content through its current readability processor.
    public var republishReaderModeRuntimeAuthority: ((SwiftSoup.Document, URL, URL?) async -> Bool)? = nil {
        willSet { processingDependencyWillChange() }
    }
    /// Validates the provenance already emitted by the native processor at
    /// final submission. A dictionary publication can supersede preparation
    /// after processing returns but before its document reaches WebKit.
    public var isPreparedReadabilityContentCurrent: (@MainActor (Data) -> Bool)? = nil {
        willSet { processingDependencyWillChange() }
    }
    public var processHTMLDocument: EbookHTMLDocumentProcessor? = nil {
        willSet { processingDependencyWillChange() }
    }
    public var processHTMLBytes: (([UInt8], Bool) async -> [UInt8])? = nil {
        willSet { processingDependencyWillChange() }
    }
    public var processHTML: ((String, Bool) async -> String)? = nil {
        willSet { processingDependencyWillChange() }
    }
    public var navigator: WebViewNavigator?
    private var resourcePresentation: ReaderDocumentPresentation?

    func recordEmbedState(generation: UUID, registration: String, stage: String) {
        guard resourcePresentation?.generation == generation,
              let entry = ReaderDocumentResourceRegistry.shared.entry(for: registration), entry.generation == generation else {
            ReaderLoadTrace.$operationID.withValue(resourcePresentation?.generation) {
                ReaderLoadTrace.event("reader.embedStateRejected", "reason=retired")
            }
            return
        }
        guard ["dispatched", "unavailable", "initialized", "navigation-complete", "navigation-error", "retry", "resolver-fetch-failed", "resolver-response-failed", "resolver-data-invalid", "media-initialized", "media-playing", "media-paused", "media-ended", "media-error", "media-advanced"].contains(stage) else { return }
        ReaderLoadTrace.$operationID.withValue(generation) {
            ReaderLoadTrace.event("reader.embedState", "component=\(entry.diagnosticID) state=\(stage)")
        }
    }
    @MainActor private weak var directLoadContent: ReaderContent?
    @MainActor private weak var directLoadScriptCaller: WebViewScriptCaller?
    @MainActor private weak var directLoadNavigator: WebViewNavigator?
    @MainActor private var contentNavigationID: UUID?

    @MainActor
    func beginContentNavigation() -> UUID {
        let id = UUID()
        contentNavigationID = id
        return id
    }

    @MainActor
    func contentNavigationIsCurrent(_ id: UUID) -> Bool {
        contentNavigationID == id
    }

    /// Native URL resolution begins before the navigator receives a request.
    /// Deferred recovery must yield to that intent even for the same URL.
    @MainActor
    public func captureContentNavigationIntent() -> @MainActor @Sendable () -> Bool {
        let id = contentNavigationID
        return { [weak self] in
            guard let self else { return false }
            return self.contentNavigationID == id
        }
    }

    @MainActor
    public func bindDirectContentLoading(
        readerContent: ReaderContent,
        scriptCaller: WebViewScriptCaller,
        navigator: WebViewNavigator
    ) {
        self.navigator = navigator
        directLoadContent = readerContent
        directLoadScriptCaller = scriptCaller
        directLoadNavigator = navigator
    }

    /// Only an inapplicable request may select another route. An admitted
    /// request retired during preparation must never dispatch an old loader.
    @MainActor
    public func loadStoredReaderContentIfPossible(
        content: any ReaderContentProtocol,
        navigator: WebViewNavigator,
        forceReload: Bool = false,
        recordHistoryVisit: Bool = true,
        shouldLoad: @MainActor () -> Bool = { true }
    ) async throws -> ReaderStoredContentLoadOutcome {
        guard !Task.isCancelled, shouldLoad(),
              !content.isInvalidated, !content.isDeleted else { return .superseded }
        guard self.navigator === navigator, directLoadNavigator === navigator,
              let readerContent = directLoadContent,
              let scriptCaller = directLoadScriptCaller,
              canDirectlyRenderStoredContent(content) else { return .inapplicable }
        let sourceURL = content.url
        let binding = scriptCaller.currentJavaScriptBindingToken
        let before = navigator.debugLoadSnapshot
        do {
            try await readerContent.prepareForDisplay(content: content, recordHistoryVisit: recordHistoryVisit)
        } catch is CancellationError {
            return .superseded
        }
        let after = navigator.debugLoadSnapshot
        guard !Task.isCancelled, shouldLoad(), self.navigator === navigator, directLoadNavigator === navigator,
              directLoadContent === readerContent, directLoadScriptCaller === scriptCaller,
              scriptCaller.currentJavaScriptBindingToken == binding,
              readerContent.pageURL.matchesReaderURL(sourceURL),
              let prepared = readerContent.content, !prepared.isInvalidated, !prepared.isDeleted,
              prepared.url.matchesReaderURL(sourceURL), canDirectlyRenderStoredContent(prepared),
              before.currentWebViewURL == after.currentWebViewURL,
              before.lastRequestURL == after.lastRequestURL,
              before.lastDataLoadBaseURL == after.lastDataLoadBaseURL,
              before.lastHTMLBaseURL == after.lastHTMLBaseURL else {
            ReaderLoadTrace.event("reader.directLoadSkipped", "reason=retired")
            return .superseded
        }
        if forceReload { clearReadabilityCache(for: sourceURL) }
        readerContent.isRenderingReaderHTML = true
        let admitted = beginSyntheticLoadForCurrentContentIfPossible(readerContent: readerContent, scriptCaller: scriptCaller)
        if admitted {
            ReaderLoadTrace.event(forceReload ? "reader.reloadDispatched" : "reader.openDispatched", "loader=false mode=storedDirect")
        } else {
            readerContent.isRenderingReaderHTML = false
        }
        // This request already prepared the selected content. A cancellation
        // at synchronous render admission retires it rather than choosing a
        // second route against that prepared selection.
        return admitted ? .accepted : .superseded
    }

    @MainActor
    private func canDirectlyRenderStoredContent(_ content: any ReaderContentProtocol) -> Bool {
        if content.url.isSnippetURL { return true }
        guard content.url.isHTTP, content.isReaderModeByDefault, content.rssContainsFullContent,
              let html = content.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !looksLikeStaleCachedCanonicalReadabilityHTML(html, url: content.url)
    }
    public var defaultFontSize: Double?
    /// In-memory presentation state supplied by the app's settings owner.
    public var readerFontFamilyName = "YuKyokasho"
    @Published public var sharedReaderFontAsset: SharedReaderFontAsset?
    public var readerModeLoadCompletionHandler: ((URL) -> Void)?
    
    @Published public var isReaderMode = false
    public let loadingState = ReaderModeLoadingState()
    @Published public var isReaderModeLoading = false {
        didSet { updateLoadingStateSnapshot() }
    }
    @Published public private(set) var lastRenderedURL: URL? {
        didSet { updateLoadingStateSnapshot() }
    }
    @Published public private(set) var expectedSyntheticReaderLoaderURL: URL? {
        didSet { updateLoadingStateSnapshot() }
    }
    @Published public private(set) var pendingReaderModeURL: URL? {
        didSet { updateLoadingStateSnapshot() }
    }
    @Published public private(set) var originalHTMLFallbackURL: URL? {
        didSet { updateLoadingStateSnapshot() }
    }
    @Published public private(set) var failedReaderModeURL: URL? {
        didSet { updateLoadingStateSnapshot() }
    }
    @Published var readabilityContent: String? = nil
    @Published var readabilityContainerSelector: String? = nil
    @Published var readabilityContainerFrameInfo: WKFrameInfo? = nil
    @Published var readabilityFrames = Set<WKFrameInfo>()

    private func resetReadabilitySource() {
        readabilityContent = nil
        readabilityContainerSelector = nil
        readabilityContainerFrameInfo = nil
    }

    public var hasRenderedReadabilityContent: Bool { lastRenderedURL != nil }

    private func updateLoadingStateSnapshot() {
#if DEBUG
        let previousSnapshot = loadingState.snapshot
#endif
        loadingState.set(
            isReaderModeLoading: isReaderModeLoading,
            lastRenderedURL: lastRenderedURL,
            expectedSyntheticReaderLoaderURL: expectedSyntheticReaderLoaderURL,
            pendingReaderModeURL: pendingReaderModeURL,
            originalHTMLFallbackURL: originalHTMLFallbackURL,
            failedReaderModeURL: failedReaderModeURL
        )
#if DEBUG
        if previousSnapshot != loadingState.snapshot {
            ReaderLoadTrace.event("readerMode.loadingStateAssigned",
                                  "model=\(ObjectIdentifier(self)) loadingState=\(ObjectIdentifier(loadingState)) loading=\(isReaderModeLoading) pending=\(pendingReaderModeURL != nil) expected=\(expectedSyntheticReaderLoaderURL != nil)")
        }
#endif
    }

    public func shouldIgnoreHideNavigationDueToScrollForNativeWebChrome(
        pageURL: URL,
        contentURL: URL?
    ) -> Bool {
        false
    }

    public func effectiveHideNavigationDueToScrollForNativeWebChrome(
        _ hidden: Bool,
        pageURL: URL,
        contentURL: URL?
    ) -> Bool {
        shouldIgnoreHideNavigationDueToScrollForNativeWebChrome(pageURL: pageURL, contentURL: contentURL)
            ? false
            : hidden
    }
    
//    @Published var contentRules: String? = nil

    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    private var lastFallbackLoaderURL: URL?
    private struct CompletedRenderOwner: Equatable {
        let key: String
        let generation: UUID
    }

    private var activeRenderTaskByURL: [String: Task<Void, Never>] = [:]
    private var activeRenderGenerationByURL: [String: UUID] = [:]
    private var completedRenderOwner: CompletedRenderOwner?

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
    public func beginReaderModeLoad(for url: URL, suppressSpinner: Bool = false) {
        failedReaderModeURL = nil
        originalHTMLFallbackURL = nil
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        let pendingMatches = pendingReaderModeURL.map { pendingKeysMatch($0, canonicalURL) } ?? false
        if !pendingMatches {
            if let expectedSyntheticReaderLoaderURL,
               !expectedSyntheticReaderLoaderURL.matchesReaderURL(canonicalURL) {
                self.expectedSyntheticReaderLoaderURL = nil
            }
            updatePendingReaderModeURL(canonicalURL)
            lastFallbackLoaderURL = nil
        }
        if let rendered = lastRenderedURL, !pendingKeysMatch(rendered, canonicalURL) {
            lastRenderedURL = nil
        }
        if !suppressSpinner {
            readerModeLoading(true)
        }
    }

    @MainActor
    public func cancelReaderModeLoad(for url: URL? = nil) {
        if let url, let pendingReaderModeURL, !pendingKeysMatch(pendingReaderModeURL, url) {
            return
        }
        ReaderLoadTrace.event("readerMode.loadCancelled", "loading=\(isReaderModeLoading) pending=\(pendingReaderModeURL != nil)")
        let completedURL = pendingReaderModeURL ?? url ?? lastRenderedURL
        originalHTMLFallbackURL = nil
        if let url {
            cancelActiveRender(for: url)
        }
        updatePendingReaderModeURL(nil)
        expectedSyntheticReaderLoaderURL = nil
        lastRenderedURL = nil
        if let completedURL,
           completedRenderOwner?.key == canonicalRenderKey(completedURL) {
            completedRenderOwner = nil
        }
        readerModeLoading(false)
    }

    /// Cancels only the render still owned by `url` and releases its content
    /// overlay. A stale callback cannot clear a newer page because both the
    /// content URL and the pending reader-mode URL are checked.
    @MainActor
    func cancelReaderModeLoad(
        for url: URL,
        readerContent: ReaderContent
    ) {
        if readerContent.pageURL.matchesReaderURL(url) {
            readerContent.isRenderingReaderHTML = false
        }
        cancelReaderModeLoad(for: url)
    }

    @MainActor
    public func markReaderModeLoadComplete(for url: URL) {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        let matchesPending = pendingKeysMatch(pendingReaderModeURL, canonicalURL)
        let matchesLastRendered = pendingKeysMatch(lastRenderedURL, canonicalURL)
        let matchesExpected = expectedSyntheticReaderLoaderURL.map {
            $0.matchesReaderURL(canonicalURL)
        } ?? false
        guard matchesPending || matchesLastRendered || matchesExpected else {
            return
        }
        if let pendingReaderModeURL, (readabilityContent?.utf8.count ?? 0) == 0 {
            if handleEmptyReadabilityCompletion(url: canonicalURL, pendingReaderModeURL: pendingReaderModeURL) {
                return
            }
        }
        completeRenderedReaderModeLoad(for: canonicalURL)
    }

    private func completeRenderedReaderModeLoad(for canonicalURL: URL) {
        guard !hasCompletedReaderModeLoad(for: canonicalURL) else { return }
        ReaderLoadTrace.event("readerMode.loadCompleted")
        originalHTMLFallbackURL = nil
        updatePendingReaderModeURL(nil)
        expectedSyntheticReaderLoaderURL = nil
        readerModeLoading(false)
        let renderKey = canonicalRenderKey(canonicalURL)
        if let activeGeneration = activeRenderGenerationByURL[renderKey] {
            completedRenderOwner = CompletedRenderOwner(
                key: renderKey,
                generation: activeGeneration
            )
        }
        lastRenderedURL = canonicalURL
        readerModeLoadCompletionHandler?(canonicalURL)
    }

    @MainActor
    public func isReaderModeLoadPending(for url: URL) -> Bool {
        pendingKeysMatch(pendingReaderModeURL, url)
    }

    @MainActor
    public func clearReadabilityCache(for url: URL) {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        let matchesLastRendered = pendingKeysMatch(lastRenderedURL, canonicalURL)
        let matchesPending = pendingKeysMatch(pendingReaderModeURL, canonicalURL)
        let isHandling = isReaderModeHandlingURL(canonicalURL)
        let matchesFailed = failedReaderModeURL?.matchesReaderURL(canonicalURL) == true
        let shouldClear = matchesLastRendered || matchesPending || isHandling || matchesFailed || readabilityContent != nil
        guard shouldClear else { return }
        cancelActiveRender(for: canonicalURL)
        if matchesFailed { failedReaderModeURL = nil }
        resetReadabilitySource()
        expectedSyntheticReaderLoaderURL = nil
        if matchesLastRendered {
            lastRenderedURL = nil
            if completedRenderOwner?.key == canonicalRenderKey(canonicalURL) {
                completedRenderOwner = nil
            }
        }
        if matchesPending {
            updatePendingReaderModeURL(nil)
        }
    }

    @MainActor
    @discardableResult
    public func handleRenderedReaderDocumentReady(
        pageURL: URL,
        hasReaderContent: Bool,
        renderGeneration: UUID? = nil,
        navigator committedNavigator: WebViewNavigator? = nil
    ) -> Bool {
        let canonicalURL = pageURL.canonicalReaderContentURLForHotfix()
        guard hasReaderContent, !pageURL.isReaderURLLoaderURL else { return false }
        if let pendingReaderModeURL, !pendingKeysMatch(pendingReaderModeURL, canonicalURL) {
            return false
        }

        let pendingMatches = pendingReaderModeURL.map { pendingKeysMatch($0, canonicalURL) } ?? false
        let expectedMatches = expectedSyntheticReaderLoaderURL.map { urlsMatchWithoutHashForHotfix($0, pageURL) } ?? false
        let completedMatches = urlMatchesLastRendered(canonicalURL)
        // A current UUID proves this exact generated document's owner even
        // if semantic navigation finish already cleared its transient flags.
        // Legacy documents without a UUID still need a pending/rendered URL.
        guard isCurrentOrCompletedRenderReady(
                for: canonicalURL,
                reportedGeneration: renderGeneration
              ), pendingMatches || expectedMatches || completedMatches || renderGeneration != nil else {
            return false
        }

        let isReplay = hasCompletedReaderModeLoad(for: canonicalURL)
        ReaderLoadTrace.$operationID.withValue(renderGeneration) {
            ReaderLoadTrace.event("readerMode.renderReadyAccepted", "replay=\(isReplay)")
        }
        // Replays restore host state after attach/pageshow. They do not own a
        // second navigation completion or native processing's loading state.
        guard !isReplay else { return true }
        (committedNavigator ?? navigator)?.forceClearLoadingIndicators(
            reason: "readerMode.syntheticLoad.renderReady",
            pageURL: canonicalURL
        )

        // The document's validated ready marker is stronger than the raw
        // readability buffer, which commit preparation deliberately clears.
        completeRenderedReaderModeLoad(for: canonicalURL)
        return true
    }

    private func handleEmptyReadabilityCompletion(url: URL, pendingReaderModeURL: URL) -> Bool {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()

        if urlMatchesLastRendered(canonicalURL) {
            updatePendingReaderModeURL(nil)
            readerModeLoading(false)
            readerModeLoadCompletionHandler?(canonicalURL)
            return true
        }

        if canonicalURL.isSnippetURL {
            updatePendingReaderModeURL(nil)
            expectedSyntheticReaderLoaderURL = nil
            lastFallbackLoaderURL = canonicalURL
            readerModeLoading(false)
            readerModeLoadCompletionHandler?(canonicalURL)
            return true
        }

        if expectedSyntheticReaderLoaderURL != nil {
            return true
        }

        updatePendingReaderModeURL(nil)
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

    nonisolated private static func shouldUseDeferredSharedReaderFontGate(
        for pageURL: URL, fontFamilyName: String
    ) -> Bool {
        guard #available(iOS 16.4, macOS 14, *), fontFamilyName == "YuKyokasho" else { return false }
        return sharedReaderFontUsesLocalScheme(for: pageURL)
    }

    private func evaluateReaderDocumentJavaScript(
        _ js: String,
        arguments: [String: any Sendable]? = nil,
        duplicateInMultiTargetFrames: Bool = false,
        scriptCaller: WebViewScriptCaller,
        requiring bindingToken: WebViewScriptCaller.JavaScriptBindingToken?
    ) async throws -> Any? {
        if let bindingToken {
            return try await scriptCaller.evaluateJavaScript(
                js,
                arguments: arguments,
                duplicateInMultiTargetFrames: duplicateInMultiTargetFrames,
                requiring: bindingToken
            )
        }
        guard !scriptCaller.canEvaluateJavaScript else {
            throw CancellationError()
        }
        return try await scriptCaller.evaluateJavaScript(
            js,
            arguments: arguments,
            duplicateInMultiTargetFrames: duplicateInMultiTargetFrames
        )
    }

    private func ownsReaderDocumentBinding(
        _ bindingToken: WebViewScriptCaller.JavaScriptBindingToken?,
        scriptCaller: WebViewScriptCaller
    ) -> Bool {
        guard let bindingToken else {
            // An unmounted caller has no successor document to protect. A
            // mounted caller that cannot provide exact document identity must
            // fail closed instead of allowing resumed work to adopt it.
            return !scriptCaller.canEvaluateJavaScript
        }
        return scriptCaller.currentJavaScriptBindingToken == bindingToken
    }

    public func injectSharedFontIfNeeded(
        scriptCaller: WebViewScriptCaller,
        pageURL: URL,
        requiring bindingToken: WebViewScriptCaller.JavaScriptBindingToken? = nil
    ) async {
        // Publisher documents keep their own typography. Only our resource-
        // serving origins participate in the reader font lifecycle.
        guard !pageURL.isReaderURLLoaderURL,
              let stylesheetURLTemplate = sharedReaderFontStylesheetURLTemplate(for: pageURL) else { return }
        let trace = ReaderLoadTrace.begin("readerMode.fontInjection")
        defer { trace?.end() }
        let bindingToken = bindingToken ?? scriptCaller.currentJavaScriptBindingToken
        guard pageURL.absoluteString != "about:blank" else {
            return
        }
        guard #available(iOS 16.4, macOS 14, *) else {
            return
        }
        // A downloaded Kyokasho face must not be relabeled as a selected
        // system font. Those families are already available to WebKit.
        guard sharedReaderFontAsset?.supportsFamily(readerFontFamilyName)
                ?? (readerFontFamilyName == "YuKyokasho") else { return }
        let fontFamilyName = readerFontFamilyName
        let fontValues = readerFontCSSValues(horizontalFamily: fontFamilyName)
        do {
            let result = try await evaluateReaderDocumentJavaScript(
                sharedReaderFontInjectionJavaScript,
                arguments: [
                    "stylesheetURLTemplate": stylesheetURLTemplate,
                    "fontHash": "local",
                    "horizontalFontFamily": fontValues.horizontalFamily,
                    "verticalFontFamily": fontValues.verticalFamily,
                ],
                duplicateInMultiTargetFrames: true,
                scriptCaller: scriptCaller,
                requiring: bindingToken
            )
            if let status = result as? String {
                ReaderLoadTrace.event("readerMode.fontReadiness", "status=\(status) mode=local-scheme")
            }
        } catch {
            ReaderLoadTrace.event("readerMode.fontReadiness", "status=\(error is CancellationError ? "cancelled" : "failed")")
        }
    }
    
    public func isReaderModeVisibleInMenu(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && content.isReaderModeOfferHidden && content.isReaderModeAvailable && !content.isReaderModeByDefault
    }
    
    public init() { }

    func expectSyntheticReaderLoaderCommit(for baseURL: URL?) {
        expectedSyntheticReaderLoaderURL = baseURL
    }

    func expectsSyntheticReaderLoaderCommit(for url: URL) -> Bool {
        guard let expectedSyntheticReaderLoaderURL else { return false }
        return urlsMatchWithoutHashForHotfix(
            expectedSyntheticReaderLoaderURL,
            url
        )
    }

    @discardableResult
    private func consumeSyntheticReaderLoaderExpectationIfNeeded(for url: URL) -> Bool {
        if expectsSyntheticReaderLoaderCommit(for: url) {
            self.expectedSyntheticReaderLoaderURL = nil
            return true
        }
        return false
    }

    private func updatePendingReaderModeURL(_ newValue: URL?) {
        if let newValue, newValue.absoluteString == "about:blank" {
            return
        }
        let canonicalNewValue = newValue?.canonicalReaderContentURLForHotfix()
        pendingReaderModeURL = canonicalNewValue
    }

    private func normalizedPendingMatchKey(for url: URL?) -> String? {
        guard let url else { return nil }
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        if let snippetKey = canonicalURL.snippetKey {
            return "snippet:\(snippetKey)"
        }
        return canonicalURL.removingFragmentIfNeeded().absoluteString
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

    private func renderGenerationDescription(for key: String) -> String {
        if let activeGeneration = activeRenderGenerationByURL[key] {
            return activeGeneration.uuidString
        }
        if completedRenderOwner?.key == key {
            return completedRenderOwner?.generation.uuidString ?? "nil"
        }
        return "nil"
    }

    private func isCurrentOrCompletedRenderReady(
        for url: URL,
        reportedGeneration: UUID?
    ) -> Bool {
        let key = canonicalRenderKey(url)
        return readerModeReadyGenerationIsCurrent(
            activeGeneration: activeRenderGenerationByURL[key],
            completedGeneration: completedRenderOwner?.key == key
                ? completedRenderOwner?.generation
                : nil,
            reportedGeneration: reportedGeneration
        )
    }

    private func urlMatchesLastRendered(_ url: URL) -> Bool {
        guard let lastRenderedURL else { return false }
        return pendingKeysMatch(lastRenderedURL, url)
    }

    private func hasCompletedReaderModeLoad(for url: URL) -> Bool {
        urlMatchesLastRendered(url) && pendingReaderModeURL == nil
            && expectedSyntheticReaderLoaderURL == nil && !isReaderModeLoading
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

    /// The active owner can adopt dictionary changes until it submits its
    /// document. The final provenance check retries stale preparation; once
    /// navigation is queued the normal publication refresh must reload it.
    @MainActor
    public func canAdoptDictionaryPublicationDuringPreparation(for url: URL) -> Bool {
        (url.isHTTP || url.isSnippetURL)
            && isPreparedReadabilityContentCurrent != nil
            && pendingKeysMatch(pendingReaderModeURL, url)
            && expectedSyntheticReaderLoaderURL == nil
            && hasActiveRender(for: url)
            && resourcePresentation?.generation != activeRenderGenerationByURL[canonicalRenderKey(url)]
    }

    private func ownsRender(for url: URL, generation: UUID) -> Bool {
        activeRenderGenerationByURL[canonicalRenderKey(url)] == generation
    }

    private func isCurrentRender(for url: URL, generation: UUID) -> Bool {
        readerModeRenderGenerationIsCurrent(
            activeGeneration: activeRenderGenerationByURL[canonicalRenderKey(url)],
            expectedGeneration: generation,
            taskIsCancelled: Task.isCancelled
        )
    }

    private func cancelReaderModeLoad(
        for url: URL,
        ifOwnedBy generation: UUID,
        readerContent: ReaderContent
    ) {
        guard ownsRender(for: url, generation: generation) else { return }
        cancelReaderModeLoad(for: url, readerContent: readerContent)
    }

    /// Upstream work can be interrupted without cancelling the render's caller.
    /// Retire that render explicitly instead of leaving restoration waiting for
    /// a ready message from a document which was never loaded. Navigation and
    /// superseded generations must not publish an error over their replacement.
    @MainActor
    func failReaderModeLoad(
        for url: URL,
        ifOwnedBy generation: UUID,
        readerContent: ReaderContent
    ) {
        guard ownsRender(for: url, generation: generation),
              readerContent.pageURL.matchesReaderURL(url) else { return }
        let callerWasCancelled = Task.isCancelled
        cancelReaderModeLoad(for: url, readerContent: readerContent)
        guard !callerWasCancelled else { return }
        failedReaderModeURL = url.canonicalReaderContentURLForHotfix()
        ReaderLoadTrace.event("readerMode.loadFailed", "loading=\(isReaderModeLoading) pending=\(pendingReaderModeURL != nil) rendering=\(readerContent.isRenderingReaderHTML)")
    }

    private func markReaderModeLoadComplete(for url: URL, ifOwnedBy generation: UUID) {
        guard isCurrentRender(for: url, generation: generation) else { return }
        markReaderModeLoadComplete(for: url)
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

    private func finishRenderTask(for url: URL, generation: UUID) {
        let key = canonicalRenderKey(url)
        guard let activeGeneration = activeRenderGenerationByURL[key], activeGeneration == generation else {
            return
        }
        completedRenderOwner = CompletedRenderOwner(
            key: key,
            generation: generation
        )
        activeRenderTaskByURL.removeValue(forKey: key)
        activeRenderGenerationByURL.removeValue(forKey: key)
    }

    private func cancelActiveRender(for url: URL) {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        let key = canonicalRenderKey(canonicalURL)
        guard let task = activeRenderTaskByURL[key] else {
            return
        }
        task.cancel()
        activeRenderTaskByURL.removeValue(forKey: key)
        activeRenderGenerationByURL.removeValue(forKey: key)
    }

    private func cancelOtherActiveRenders(except keyToKeep: String) {
        let staleKeys = activeRenderTaskByURL.keys.filter { $0 != keyToKeep }
        for staleKey in staleKeys {
            activeRenderTaskByURL[staleKey]?.cancel()
            activeRenderTaskByURL.removeValue(forKey: staleKey)
            activeRenderGenerationByURL.removeValue(forKey: staleKey)
        }
    }

    @discardableResult
    @MainActor
    func startRenderTaskIfNeeded(
        for url: URL,
        operation: @escaping @ReaderViewModelActor (_ generation: UUID) async -> Void
    ) -> Bool {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        let key = canonicalRenderKey(canonicalURL)
        cancelOtherActiveRenders(except: key)

        if let existingTask = activeRenderTaskByURL[key], !existingTask.isCancelled {
            return false
        }

        let generation = UUID()
        activeRenderGenerationByURL[key] = generation
        completedRenderOwner = nil
        ReaderLoadTrace.$operationID.withValue(generation) {
            ReaderLoadTrace.event("readerMode.renderTaskScheduled")
        }
        let task = Task { @ReaderViewModelActor [weak self] in
            guard let self else { return }
            await ReaderLoadTrace.$operationID.withValue(generation) { @ReaderViewModelActor in
                ReaderLoadTrace.event("readerMode.renderTaskStarted", "cancelled=\(Task.isCancelled)")
                defer {
                    ReaderLoadTrace.event("readerMode.renderTaskReturned", "cancelled=\(Task.isCancelled)")
                }
                await operation(generation)
            }
            await self.finishRenderTask(for: canonicalURL, generation: generation)
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
        let trace = ReaderLoadTrace.begin("readerMode.resolveRoute")
        defer { trace?.end() }
        let activeReaderFileManager = readerFileManager ?? .shared
        if let content = try? await readerContent.getContent(),
           content.rssContainsFullContent,
           !content.isReaderModeByDefault {
            if let html = try? await locallyRetrievableReaderHTML(
                for: content,
                readerFileManager: activeReaderFileManager
            ),
               !html.isEmpty {
                if !looksLikeStaleCachedCanonicalReadabilityHTML(html, url: content.url) {
                    return ReaderModeRouteDecision(
                        route: .localHTML,
                        prefetchedContent: content,
                        prefetchedLocalHTML: html
                    )
                }
            }
        }
        if let readabilityContent, !readabilityContent.isEmpty {
            let contentURL = readerContent.pageURL
            if !looksLikeStaleCachedCanonicalReadabilityHTML(readabilityContent, url: contentURL) {
                return ReaderModeRouteDecision(
                    route: .capturedReadability,
                    prefetchedContent: nil,
                    prefetchedLocalHTML: nil
                )
            }
        }
        if let content = try? await readerContent.getContent(),
           let html = try? await locallyRetrievableReaderHTML(
                for: content,
                readerFileManager: activeReaderFileManager
           ),
           !html.isEmpty {
            if !looksLikeStaleCachedCanonicalReadabilityHTML(html, url: content.url) {
                return ReaderModeRouteDecision(
                    route: .localHTML,
                    prefetchedContent: content,
                    prefetchedLocalHTML: html
                )
            }
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
    public func showReaderView(readerContent: ReaderContent, scriptCaller: WebViewScriptCaller) {
        ReaderLoadTrace.event("readerMode.request",
            "navigatorBound=\(navigator != nil) canEvaluate=\(scriptCaller.canEvaluateJavaScript)")
        guard let navigator else {
            let contentURL = readerContent.pageURL
            cancelReaderModeLoad(
                for: contentURL,
                readerContent: readerContent
            )
            return
        }
        showReaderView(
            readerContent: readerContent,
            scriptCaller: scriptCaller,
            navigator: navigator
        )
    }

    @MainActor
    private func showReaderView(
        readerContent: ReaderContent,
        scriptCaller: WebViewScriptCaller,
        navigator: WebViewNavigator
    ) {
        let contentURL = readerContent.pageURL
        // Readiness can arrive before the active task finishes unwinding.
        // Reject duplicates before they can rearm the loading state.
        guard !hasActiveRender(for: contentURL) else { return }
        let requestBindingToken = scriptCaller.currentJavaScriptBindingToken
        let cachedReadabilityContent = readabilityContent
        let cachedContainerSelector = readabilityContainerSelector
        let cachedContainerFrameInfo = readabilityContainerFrameInfo
        beginReaderModeLoad(for: contentURL)
        let didStart = startRenderTaskIfNeeded(for: contentURL) { [weak self] generation in
            guard let self else { return }
            guard await self.isCurrentRender(for: contentURL, generation: generation) else {
                return
            }
            let currentPageURL = await MainActor.run { readerContent.pageURL }
            guard contentURL.matchesReaderURL(currentPageURL) else {
                await self.cancelReaderModeLoad(
                    for: contentURL,
                    ifOwnedBy: generation,
                    readerContent: readerContent
                )
                return
            }
            let routeDecision = await self.resolveReaderModeRouteDecision(readerContent: readerContent)
            guard await self.isCurrentRender(for: contentURL, generation: generation) else {
                return
            }
            ReaderLoadTrace.event("readerMode.route", routeDecision.route.rawValue)
            switch routeDecision.route {
            case .localHTML:
                await self.showReaderViewUsingSwiftProcessing(
                    readerContent: readerContent,
                    scriptCaller: scriptCaller,
                    navigator: navigator,
                    renderURL: contentURL,
                    renderGeneration: generation,
                    prefetchedContent: routeDecision.prefetchedContent,
                    prefetchedLocalHTML: routeDecision.prefetchedLocalHTML
                )
            case .capturedReadability:
                guard let cachedReadabilityContent else {
                    await self.failReaderModeLoad(
                        for: contentURL,
                        ifOwnedBy: generation,
                        readerContent: readerContent
                    )
                    return
                }
                do {
                    let contentSnapshot = try await self.readerContentRenderSnapshot(readerContent: readerContent)
                    guard await self.isCurrentRender(for: contentURL, generation: generation) else {
                        return
                    }
                    let publicationDateFallback = cachedReadabilityContent.contains("id=\"reader-publication-date\"")
                        ? nil
                        : await readerContentPublicationDateFallback(for: contentURL)
                    guard await self.isCurrentRender(for: contentURL, generation: generation) else {
                        return
                    }
                    let resolvedReadabilityContent = rebuildCanonicalSnippetReadabilityHTML(
                        html: cachedReadabilityContent,
                        contentURL: contentSnapshot?.url ?? contentURL,
                        fallbackTitle: contentSnapshot?.title,
                        publishedTime: publicationDateFallback,
                        preferredTitle: contentSnapshot?.title,
                        hideReaderTitleOverride: contentSnapshot?.isTitlePrefixOfContent
                    )
                    guard let resolvedReadabilityContent else {
                        await self.failReaderModeLoad(
                            for: contentURL,
                            ifOwnedBy: generation,
                            readerContent: readerContent
                        )
                        return
                    }
                    try await self.showReadabilityContent(
                        readerContent: readerContent,
                        readabilityContent: resolvedReadabilityContent,
                        renderToSelector: cachedContainerSelector,
                        in: cachedContainerFrameInfo,
                        scriptCaller: scriptCaller,
                        navigator: navigator,
                        renderURL: contentURL,
                        renderGeneration: generation
                    )
                } catch is CancellationError {
                    await self.failReaderModeLoad(
                        for: contentURL,
                        ifOwnedBy: generation,
                        readerContent: readerContent
                    )
                } catch {
                    print(error)
                    await self.failReaderModeLoad(
                        for: contentURL,
                        ifOwnedBy: generation,
                        readerContent: readerContent
                    )
                }
            case .unavailable:
                // A document-end readability message can be missed during
                // startup. An explicit Reader request still owns the live
                // source document; feed its HTML through the ordinary Swift
                // pipeline rather than silently cancelling the request.
                do {
                    guard contentURL.isHTTP,
                          let requestBindingToken else {
                        throw CancellationError()
                    }
                    let snapshot = try await self.evaluateReaderDocumentJavaScript(
                        "return { href: location.href, html: document.documentElement.outerHTML };",
                        scriptCaller: scriptCaller,
                        requiring: requestBindingToken
                    ) as? [String: Any]
                    guard await self.isCurrentRender(for: contentURL, generation: generation),
                          let href = snapshot?["href"] as? String,
                          let snapshotURL = URL(string: href),
                          urlsMatchWithoutHashForHotfix(contentURL, snapshotURL),
                          let html = snapshot?["html"] as? String,
                          !html.isEmpty else {
                        throw CancellationError()
                    }
                    await self.showReaderViewUsingSwiftProcessing(
                        readerContent: readerContent,
                        scriptCaller: scriptCaller,
                        navigator: navigator,
                        renderURL: contentURL,
                        renderGeneration: generation,
                        prefetchedLocalHTML: html
                    )
                } catch {
                    await self.failReaderModeLoad(
                        for: contentURL,
                        ifOwnedBy: generation,
                        readerContent: readerContent
                    )
                }
            }
        }
    }

    @MainActor
    public func beginSyntheticLoadForCurrentContentIfPossible(
        readerContent: ReaderContent,
        scriptCaller: WebViewScriptCaller
    ) -> Bool {
        // Admission consumes the already prepared selection synchronously so
        // cancellation cannot interleave before its render owner is reserved.
        guard !Task.isCancelled,
              navigator != nil,
              let content = readerContent.content,
              !content.isInvalidated else {
            return false
        }
        guard canDirectlyRenderStoredContent(content) else {
            return false
        }
        guard readerContent.pageURL.matchesReaderURL(content.url) else {
            return false
        }
        guard !hasActiveRender(for: content.url) else { return true }
        // A local-content intent must not adopt readability or frame selectors
        // cached from the previously mounted document. The loader commit used
        // to establish this same boundary before starting the Swift renderer.
        resetReadabilitySource()
        showReaderView(readerContent: readerContent, scriptCaller: scriptCaller)
        return true
    }

    @MainActor
    private func showReaderViewUsingSwiftProcessing(
        readerContent: ReaderContent,
        scriptCaller: WebViewScriptCaller,
        navigator: WebViewNavigator,
        renderURL: URL,
        renderGeneration: UUID,
        prefetchedContent: (any ReaderContentProtocol)? = nil,
        prefetchedLocalHTML: String? = nil
    ) async {
        let trace = ReaderLoadTrace.begin("readerMode.swiftProcessing")
        defer { trace?.end() }
        let contentURL = renderURL
        guard isCurrentRender(for: contentURL, generation: renderGeneration) else {
            return
        }
        guard contentURL.matchesReaderURL(readerContent.pageURL) else {
            cancelReaderModeLoad(
                for: contentURL,
                ifOwnedBy: renderGeneration,
                readerContent: readerContent
            )
            return
        }
        do {
            let content: any ReaderContentProtocol
            if let prefetchedContent {
                content = prefetchedContent
            } else {
                guard let resolvedContent = try await readerContent.getContent() else {
                    cancelReaderModeLoad(
                        for: contentURL,
                        ifOwnedBy: renderGeneration,
                        readerContent: readerContent
                    )
                    return
                }
                content = resolvedContent
            }
            guard isCurrentRender(for: contentURL, generation: renderGeneration) else {
                return
            }
            let activeReaderFileManager = readerFileManager ?? .shared
            let html: String
            if let prefetchedLocalHTML {
                html = prefetchedLocalHTML
            } else {
                guard let resolvedHTML = try await locallyRetrievableReaderHTML(
                    for: content,
                    readerFileManager: activeReaderFileManager
                ) else {
                    cancelReaderModeLoad(
                        for: contentURL,
                        ifOwnedBy: renderGeneration,
                        readerContent: readerContent
                    )
                    return
                }
                html = resolvedHTML
            }
            guard isCurrentRender(for: contentURL, generation: renderGeneration) else {
                return
            }

            let resolvedReadabilityHTML: String?
            if hasCanonicalReadabilityMarkup(in: html) {
                resolvedReadabilityHTML = rebuildCanonicalSnippetReadabilityHTML(
                    html: html,
                    contentURL: content.url
                )
            } else {
                let publicationDateFallback = await readerContentPublicationDateFallback(for: content)
                guard isCurrentRender(for: contentURL, generation: renderGeneration) else {
                    return
                }
                let extractionTrace = ReaderLoadTrace.begin("readerMode.readabilityPreparation")
                let swiftReadability = await processReadabilityHTMLInSwift(
                    html: html,
                    url: content.url,
                    snippetPublishedTime: publicationDateFallback,
                    meaningfulContentMinChars: max(content.meaningfulContentMinLength, 1)
                )
                extractionTrace?.end()
                switch swiftReadability {
                case .success(let result):
                    resolvedReadabilityHTML = result.outputHTML
                case .unavailable, .failed:
                    resolvedReadabilityHTML = nil
                }
            }

            guard isCurrentRender(for: contentURL, generation: renderGeneration) else {
                return
            }

            if let resolvedReadabilityHTML {
                readabilityContent = resolvedReadabilityHTML
                try await showReadabilityContent(
                    readerContent: readerContent,
                    readabilityContent: resolvedReadabilityHTML,
                    renderToSelector: nil,
                    in: nil,
                    scriptCaller: scriptCaller,
                    navigator: navigator,
                    renderURL: contentURL,
                    renderGeneration: renderGeneration
                )
                return
            }

            loadOriginalHTMLAfterReaderModeExtractionFailed(
                html,
                for: contentURL,
                generation: renderGeneration,
                readerContent: readerContent,
                navigator: navigator
            )
        } catch {
            recordReaderRenderFailure(error, phase: .localHTML)
            failReaderModeLoad(
                for: contentURL,
                ifOwnedBy: renderGeneration,
                readerContent: readerContent
            )
        }
    }
    
    @MainActor
    @discardableResult
    func loadOriginalHTMLAfterReaderModeExtractionFailed(
        _ html: String,
        for url: URL,
        generation: UUID,
        readerContent: ReaderContent,
        navigator: WebViewNavigator
    ) -> Bool {
        guard isCurrentRender(for: url, generation: generation),
              url.matchesReaderURL(readerContent.pageURL) else {
            return false
        }
        let directHTML = prepareHTMLForDirectLoad(html)
        readabilityContent = nil
        // Original HTML cannot publish a generated Reader document's ready
        // marker. Retire that wait before loading the fallback; navigation
        // finish must not leave its overlay waiting for an impossible event.
        cancelReaderModeLoad(for: url, ifOwnedBy: generation, readerContent: readerContent)
        isReaderMode = false
        originalHTMLFallbackURL = url
        if let htmlData = directHTML.data(using: .utf8) {
            navigator.load(
                htmlData,
                mimeType: "text/html",
                characterEncodingName: "UTF-8",
                baseURL: url
            )
        } else {
            navigator.loadHTML(directHTML, baseURL: url)
        }
        return true
    }

    /// `readerContent` is used to verify current reader state before loading processed `content`
    @MainActor
    internal func showReadabilityContent(
        readerContent: ReaderContent,
        readabilityContent: String,
        renderToSelector: String?,
        in frameInfo: WKFrameInfo?,
        scriptCaller: WebViewScriptCaller,
        navigator: WebViewNavigator,
        renderURL: URL,
        renderGeneration: UUID
    ) async throws {
        try await retrySupersededReadabilityPreparation {
            try await self.prepareAndShowReadabilityContent(
                readerContent: readerContent,
                readabilityContent: readabilityContent,
                renderToSelector: renderToSelector,
                in: frameInfo,
                scriptCaller: scriptCaller,
                navigator: navigator,
                renderURL: renderURL,
                renderGeneration: renderGeneration
            )
        }
    }

    @MainActor
    private func prepareAndShowReadabilityContent(
        readerContent: ReaderContent,
        readabilityContent originalReadabilityContent: String,
        renderToSelector: String?,
        in frameInfo: WKFrameInfo?,
        scriptCaller: WebViewScriptCaller,
        navigator: WebViewNavigator,
        renderURL: URL,
        renderGeneration: UUID
    ) async throws {
        let trace = ReaderLoadTrace.begin("readerMode.render")
        defer { trace?.end() }
        let requestedURL = renderURL
        guard isCurrentRender(for: requestedURL, generation: renderGeneration) else {
            return
        }
        guard requestedURL.matchesReaderURL(readerContent.pageURL) else {
            cancelReaderModeLoad(
                for: requestedURL,
                ifOwnedBy: renderGeneration,
                readerContent: readerContent
            )
            return
        }
        let resolvedContent: (any ReaderContentProtocol)?
        do {
            let resolutionTrace = ReaderLoadTrace.begin("readerMode.renderContentResolution")
            defer { resolutionTrace?.end() }
            resolvedContent = try await readerContent.getContent()
        }
        guard let content = resolvedContent else {
            print("No content set to show in reader mode")
            cancelReaderModeLoad(
                for: requestedURL,
                ifOwnedBy: renderGeneration,
                readerContent: readerContent
            )
            return
        }
        guard isCurrentRender(for: requestedURL, generation: renderGeneration) else {
            return
        }
        let url = content.url
        // URL-only feed images carry semantic geometry in existing HTML. Keep
        // it when publisher extraction replaces a summary with canonical HTML.
        // This insertion targets our own template, avoiding another body parse.
        // The content accessor may decompress stored HTML. Read it once for
        // this synchronous decision; the write still rechecks live state.
        let sourceHTMLAtResolution = content.html
        var sourceImageGeometry = ReaderImageGeometry.metadata(
            inHTML: sourceHTMLAtResolution, matchingURL: content.imageUrl, sourceURL: url)
        if sourceImageGeometry == nil, let imageURL = content.imageUrl, url.isHTTP {
            let geometryTrace = ReaderLoadTrace.begin("readerMode.cachedImageGeometry")
            sourceImageGeometry = try? await ReaderContentLoader.cachedFeedImageGeometry(
                sourceURL: url, imageURL: imageURL)
            geometryTrace?.end(sourceImageGeometry == nil ? "unavailable" : "matched")
            guard !Task.isCancelled, isCurrentRender(for: requestedURL, generation: renderGeneration),
                  !content.isInvalidated, !content.isDeleted, content.url == url else { return }
        }
        let enrichedSourceHTML = sourceHTMLAtResolution.map {
            canonicalHTMLPreservingImageGeometry($0, geometry: sourceImageGeometry, sourceURL: url)
        }
        let resolvedImageGeometry = sourceImageGeometry
        let readabilityContent = canonicalHTMLPreservingImageGeometry(
            originalReadabilityContent, geometry: sourceImageGeometry, sourceURL: url)
        let documentSourceURL = url.absoluteString == "about:blank" ? readerContent.pageURL : url
        let shouldStoreReaderHTML = shouldStorePreparedReaderHTML(for: content)
        let resolvedStoredHTML = shouldStoreReaderHTML ? stripRuntimeReadabilityAssets(from: readabilityContent) : nil
        let resolvedTitleIfNeeded: String? = {
            guard content.title.isEmpty else { return nil }
            return (resolvedStoredHTML ?? sourceHTMLAtResolution)?
                .strippingHTML()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
                .first?
                .truncate(36) ?? ""
        }()
        let titleForDisplay = content.titleForDisplay
        let needsAsyncWrite = !(content is FeedEntry) && (
            content.isReaderModeByDefault == false
            || content.isReaderModeAvailable == true
            || content.isReaderModeOfferHidden == true
            || (
                !url.isEBookURL
                && !url.isFileURL
                && !url.isNativeReaderView
                && content.rssContainsFullContent == false
            )
            || (resolvedStoredHTML != nil && sourceHTMLAtResolution != resolvedStoredHTML)
            || enrichedSourceHTML != sourceHTMLAtResolution
            || (resolvedTitleIfNeeded != nil && content.title != resolvedTitleIfNeeded))

        guard isCurrentRender(for: requestedURL, generation: renderGeneration) else {
            return
        }
        if needsAsyncWrite {
            let metadataTrace = ReaderLoadTrace.begin("readerMode.primaryMetadataWrite")
            defer { metadataTrace?.end() }
            try await content.asyncWrite { _, content in
                // Recheck after the actor hop/write queue: another owner may
                // already have captured the body or supplied its title.
                var changed = false
                if !content.isReaderModeByDefault { content.isReaderModeByDefault = true; changed = true }
                if content.isReaderModeAvailable { content.isReaderModeAvailable = false; changed = true }
                if content.isReaderModeOfferHidden { content.isReaderModeOfferHidden = false; changed = true }
                if !url.isEBookURL && !url.isFileURL && !url.isNativeReaderView {
                    if let resolvedStoredHTML, shouldStorePreparedReaderHTML(for: content),
                       content.html != resolvedStoredHTML {
                        content.html = resolvedStoredHTML
                        changed = true
                    }
                    if let resolvedTitleIfNeeded, content.title.isEmpty, content.title != resolvedTitleIfNeeded {
                        content.title = resolvedTitleIfNeeded
                        changed = true
                    }
                    if !content.rssContainsFullContent {
                        content.rssContainsFullContent = true
                        changed = true
                    }
                    // Merge into live HTML, never a body snapshot captured
                    // before the feed read or writer suspension. This also
                    // handles restoration/Reload, which need not record a visit.
                    if !content.isDeleted, content.url == url,
                       let geometry = resolvedImageGeometry, content.imageUrl == geometry.url,
                       let currentHTML = content.html,
                       ReaderImageGeometry.metadata(inHTML: currentHTML,
                        matchingURL: geometry.url, sourceURL: url) == nil {
                        let enriched = geometry.mergingIntoDocumentHead(currentHTML, sourceURL: url)
                        if enriched != currentHTML { content.html = enriched; changed = true }
                    }
                }
                if changed { content.refreshChangeMetadata(explicitlyModified: true) }
            }
        }

        guard isCurrentRender(for: requestedURL, generation: renderGeneration) else {
            return
        }
        
        if !isReaderMode {
            isReaderMode = true
        }

        let injectEntryImageIntoHeader = content.injectEntryImageIntoHeader
        let imageURLToDisplay: URL?
        do {
            let imageTrace = ReaderLoadTrace.begin("readerMode.headerImageResolution")
            defer { imageTrace?.end() }
            imageURLToDisplay = try await content.imageURLToDisplay()
        }
        guard isCurrentRender(for: requestedURL, generation: renderGeneration) else {
            return
        }
        let processReadabilityContent = processReadabilityContent
        let fontFamilyName = readerFontFamilyName
        let fontAsset = sharedReaderFontAsset
        let processHTMLBytes = processHTMLBytes
        let processHTML = processHTML
        let republishReaderModeRuntimeAuthority = republishReaderModeRuntimeAuthority
        let prefersDirectSnippetReadabilityParse = url.isSnippetURL
            && hasPersistedReaderSegmentMarkup(in: readabilityContent)
        let snippetRawTitle = content.title
        let snippetNeedsClipboardIndicator = content.needsClipboardIndicator
        let hideRedundantSnippetTitle = content.isTitlePrefixOfContent
        let tracksReadingProgress = content.tracksReadingProgress
        let primaryRecordCompoundKey = content.compoundKey
        
        let processingTrace = ReaderLoadTrace.begin("readerMode.processAndSerialize")
        defer { processingTrace?.end() }
        try await { @ReaderViewModelActor [weak self] in
            guard let self,
                  await self.isCurrentRender(
                      for: requestedURL,
                      generation: renderGeneration
                  ) else {
                return
            }
            var doc: SwiftSoup.Document?
            
            if let processReadabilityContent, !prefersDirectSnippetReadabilityParse {
                doc = try await processReadabilityContent(
                    readabilityContent,
                    url,
                    nil,
                    false,
                    tracksReadingProgress,
                    nil,
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

            guard await self.isCurrentRender(
                for: requestedURL,
                generation: renderGeneration
            ) else {
                return
            }

            guard var doc else {
                print("Error: Unexpectedly failed to receive doc")
                await self.failReaderModeLoad(
                    for: requestedURL,
                    ifOwnedBy: renderGeneration,
                    readerContent: readerContent
                )
                return
            }
            if prefersDirectSnippetReadabilityParse {
                doc = try await processPersistedSnippetWithCurrentReadabilityProcessor(
                    document: doc,
                    readabilityContent: readabilityContent,
                    url: url,
                    tracksReadingProgress: tracksReadingProgress,
                    processReadabilityContent: processReadabilityContent,
                    republishReaderModeRuntimeAuthority: republishReaderModeRuntimeAuthority,
                    preprocessDoc: { doc in
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
                guard await self.isCurrentRender(
                    for: requestedURL,
                    generation: renderGeneration
                ) else {
                    return
                }
            }
            let derivedTitle = titleFromReadabilityDocument(doc) ?? titleForDisplay
            // A structured child keeps bookkeeping owned by this render, but
            // lets final document delivery proceed while the writer is busy.
            // Early return/cancellation cancels and joins this child as well.
            let defaultsStorage = ReaderContentLoader.DiscoveryStorage()
            async let defaultsPropagation: Void = propagateReaderModeDefaults(
                for: url,
                primaryKey: primaryRecordCompoundKey,
                readabilityHTML: readabilityContent,
                fallbackTitle: titleForDisplay,
                derivedTitle: derivedTitle,
                storage: defaultsStorage
            )
            guard await self.isCurrentRender(
                for: requestedURL,
                generation: renderGeneration
            ) else {
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
            guard await self.isCurrentRender(
                for: requestedURL,
                generation: renderGeneration
            ) else {
                return
            }
            normalizeReadabilityBodyOrder(doc)
            if url.isSnippetURL {
                let cleanedSnippetTitle = ReaderContentLoader.resolvedDisplayTitle(
                    snippetRawTitle,
                    needsClipboardIndicator: snippetNeedsClipboardIndicator
                )
                try? updateSnippetReaderTitleIfNeeded(in: doc, title: cleanedSnippetTitle)
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
            }

            let processedIsEbook = ((try? doc.body()?.attr("data-is-ebook")) ?? "") == "true"
            let shouldInjectProcessedStyles = !(processedIsEbook && readerModeDisableInjectedStylingForEbookLayoutDiagnosis)
            let processedBodyClasses = (try? doc.body()?.className()) ?? ""
            let processedBodyClassesForFrameInjection: String = {
                let trimmed = processedBodyClasses.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "readability-mode" : trimmed
            }()
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
            let renderBaseURL = try readerModeDocumentURL(for: documentSourceURL, in: doc)
            let presentation: ReaderDocumentPresentation?
            if renderBaseURL.isReaderDocumentURL {
                presentation = try prepareReaderOwnedDocument(doc, sourceURL: url, generation: renderGeneration)
            } else { presentation = nil }
            let fontPageURL = renderBaseURL.isReaderDocumentURL ? renderBaseURL : (frameInfo?.isMainFrame == false ? url : renderBaseURL)
            let fontPreparation = ReaderLoadTrace.begin("readerMode.fontPreparation")
            do {
                if Self.shouldUseDeferredSharedReaderFontGate(for: fontPageURL, fontFamilyName: fontFamilyName) {
                    try upsertDeferredSharedReaderFontGate(in: doc,
                        waitsForArticleLayout: !processedIsEbook && !url.isEBookURL && (renderBaseURL.isReaderDocumentURL || frameInfo?.isMainFrame != false))
                    if (renderBaseURL.isReaderDocumentURL || frameInfo?.isMainFrame != false), sharedReaderFontUsesLocalScheme(for: renderBaseURL) {
                        try upsertLocalSharedReaderFontBootstrap(in: doc, pageURL: renderBaseURL,
                                                               horizontalFontFamily: fontFamilyName,
                                                               fontAsset: fontAsset)
                    }
                }
                fontPreparation?.end("status=prepared")
            } catch {
                fontPreparation?.end("status=failed")
                recordReaderRenderFailure(error, phase: .fontPreparation)
                throw error
            }

            // The app's Swift processor requests this boundary. Recreate its
            // bundled code only after publisher/cached scripts were removed.
            if !processedIsEbook, !url.isEBookURL,
               try doc.select("html").first()?.attr("data-mnb-article-presentation") == "pending" {
                try prepareReaderInitialArticlePresentation(in: doc)
            }
            markReaderRenderReady(
                in: doc,
                renderGeneration: frameInfo?.isMainFrame == false && !renderBaseURL.isReaderDocumentURL ? nil : renderGeneration
            )

            ReaderLoadTrace.event("readerMode.nativeProcessingFinished")
            let serializedHTMLBytes: [UInt8] = try {
                let serializationTrace = ReaderLoadTrace.begin("readerMode.serialize")
                var outcome = "interrupted"
                defer { serializationTrace?.end(outcome) }
                let bytes = try doc.outerHtmlUTF8()
                outcome = "bytes=\(bytes.count)"
                return bytes
            }()

            var transformedHTMLBytes = serializedHTMLBytes
            var transformedHTMLString: String?
            if let processHTMLBytes {
                transformedHTMLBytes = await processHTMLBytes(
                    transformedHTMLBytes,
                    false
                )
                guard await self.isCurrentRender(
                    for: requestedURL,
                    generation: renderGeneration
                ) else {
                    return
                }
            }
            if let processHTML {
                let serializedHTML = String(decoding: transformedHTMLBytes, as: UTF8.self)
                let processedHTML = await processHTML(
                    serializedHTML,
                    false
                )
                transformedHTMLString = processedHTML
                transformedHTMLBytes = Array(processedHTML.utf8)
                guard await self.isCurrentRender(
                    for: requestedURL,
                    generation: renderGeneration
                ) else {
                    return
                }
            }

            if !url.isHTTP, renderBaseURL.scheme?.lowercased() == "internal",
               renderBaseURL.isReaderDocumentURL || frameInfo?.isMainFrame != false {
                transformedHTMLBytes = Array(externalizingCanonicalReaderSegmentSidecar(
                    in: transformedHTMLBytes,
                    scheme: .internalReader
                ).documentHTML)
            }

            ReaderSnippetFinalDocumentDiagnostics.emitIfEnabled(
                htmlBytes: transformedHTMLBytes,
                contentURL: url
            )

            let transformedContentForFrameInjection: String?
            let transformedBodyClassesForFrameInjection: String?
            let transformedStyleTextForFrameInjection: String?
            if let frameInfo, !frameInfo.isMainFrame, !renderBaseURL.isReaderDocumentURL {
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
            let transformedHTMLData = Data(transformedHTMLBytes)
            try await { @MainActor in
                guard isCurrentRender(
                    for: requestedURL,
                    generation: renderGeneration
                ) else {
                    return
                }
                guard url.matchesReaderURL(readerContent.pageURL) else {
                    cancelReaderModeLoad(
                        for: requestedURL,
                        ifOwnedBy: renderGeneration,
                        readerContent: readerContent
                    )
                    return
                }
                if let frameInfo = frameInfo, !frameInfo.isMainFrame, !renderBaseURL.isReaderDocumentURL {
                    let transformedContent = transformedContentForFrameInjection ?? ""
                    let transformedBodyClasses = transformedBodyClassesForFrameInjection ?? "readability-mode"
                    let transformedStyleText = shouldInjectProcessedStyles
                        ? (transformedStyleTextForFrameInjection ?? "")
                        : ""
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
                        const manabiStyle = document.getElementById('mnb-readability-styles')
                        if (manabiStyle && document.head) {
                            document.head.appendChild(manabiStyle)
                        }
                        if (document.body) {
                            document.body.className = bodyClassNames || 'readability-mode'
                        }
                        if (readerModeScript) {
                            try {
                                new Function(readerModeScript)()
                            } catch (error) {
                                console.error(error)
                            }
                        }
                        """,
                        arguments: [
                            "renderToSelector": renderToSelector ?? "",
                            "html": transformedContent,
                            "css": transformedStyleText,
                            "bodyClassNames": transformedBodyClasses,
                            "readerModeScript": Readability.shared.scripts,
                        ], in: frameInfo)
                    guard isCurrentRender(
                        for: requestedURL,
                        generation: renderGeneration
                    ) else {
                        return
                    }
                    markReaderModeLoadComplete(for: url, ifOwnedBy: renderGeneration)
                } else {
                    guard isCurrentRender(
                        for: requestedURL,
                        generation: renderGeneration
                    ) else {
                        return
                    }
                    if renderBaseURL.isReaderDocumentURL,
                       let isPreparedReadabilityContentCurrent,
                       !isPreparedReadabilityContentCurrent(transformedHTMLData) {
                        throw ReaderPreparedReadabilityDocumentError.superseded
                    }
                    ReaderLoadTrace.event("readerMode.loadFinalHTML", "bytes=\(transformedHTMLBytes.count) origin=\(renderBaseURL.isReaderDocumentURL ? "reader" : "source") attached=\(navigator.isReadyForDirectLoad)")
                    // Ends when native submission returns, independently of
                    // WebKit's later policy callback, resource request and commit.
                    let submission = ReaderLoadTrace.begin("readerMode.navigationSubmission")
                    defer { submission?.end() }
                    if let presentation {
                        let existingURL = navigator.currentDocumentURL
                        let replacesCurrent = existingURL?.isReaderDocumentURL == true
                            && existingURL?.matchesReaderURL(url) == true
                        let documentURL = replacesCurrent ? existingURL! : readerPresentationDocumentURL(baseURL: renderBaseURL)
                        try presentation.installDocument(transformedHTMLData, at: documentURL)
                        resourcePresentation = presentation
                        expectSyntheticReaderLoaderCommit(for: documentURL)
                        if !replacesCurrent || !navigator.reloadCurrentDocument(at: documentURL) {
                            navigator.load(URLRequest(url: documentURL, cachePolicy: .reloadIgnoringLocalCacheData))
                        }
                    } else {
                        expectSyntheticReaderLoaderCommit(for: renderBaseURL)
                        navigator.load(transformedHTMLData, mimeType: "text/html", characterEncodingName: "UTF-8", baseURL: renderBaseURL)
                    }
                    if ReaderLoadTrace.isRecording("readerMode.navigationMainQueueTurn") {
                        let operationID = ReaderLoadTrace.operationID
                        // Observation only: separate main-queue congestion from
                        // waiting for WebKit, without sampling the process.
                        DispatchQueue.main.async {
                            ReaderLoadTrace.$operationID.withValue(operationID) {
                                ReaderLoadTrace.event("readerMode.navigationMainQueueTurn")
                            }
                        }
                    }
                }
//                try await { @MainActor in
//                    readerModeLoading(false)
//                }()
            }()
            await defaultsPropagation
        }()

    }

    @ReaderViewModelActor
    func processReadabilityHTMLInSwift(
        html: String,
        url: URL,
        snippetPublishedTime: String? = nil,
        meaningfulContentMinChars: Int
    ) async -> SwiftReadabilityProcessingOutcome {
        let trace = ReaderLoadTrace.begin("readerMode.readabilityExtraction")
        defer { trace?.end() }
        guard canHaveReadabilityContent(for: url) else {
            return .unavailable
        }

        let normalizedHTML = ensureReadabilityBodyExists(html)
        if url.isSnippetURL {
            if let snippetHTML = buildSnippetCanonicalReadabilityHTML(
                html: normalizedHTML,
                contentURL: url,
                fallbackTitle: titleFromReadabilityHTML(normalizedHTML),
                publishedTime: snippetPublishedTime
            ) {
                return .success(SwiftReadabilityProcessingResult(outputHTML: snippetHTML))
            }
        }
        let options = SwiftReadability.ReadabilityOptions(
            charThreshold: max(meaningfulContentMinChars, 1),
            classesToPreserve: readabilityClassesToPreserve
        )
        guard let sourceDocument = try? SwiftSoup.parse(normalizedHTML, url.absoluteString) else { return .failed }
        if url.isHTTP {
            try? normalizeReaderDocumentResourceURLs(in: sourceDocument, sourceURL: url)
        }
        let sourceReferrerPolicy = try? readerDocumentReferrerPolicy(in: sourceDocument)
        let sourceImageGeometry = ReaderImageGeometry.metadata(in: sourceDocument, sourceURL: url)
        let parser = SwiftReadability.Readability(document: sourceDocument, options: options)
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

        let resolvedPublishedTime = trimmedNonEmptyReadabilityText(result.publishedTime)
            ?? trimmedNonEmptyReadabilityText(snippetPublishedTime)
        let outputHTML = buildCanonicalReadabilityHTML(
            title: stripTemplateTagsForReadability(result.title ?? ""),
            byline: stripTemplateTagsForReadability(result.byline ?? ""),
            publishedTime: resolvedPublishedTime,
            content: rawContent,
            contentURL: url,
            referrerPolicy: sourceReferrerPolicy,
            headerImageGeometry: sourceImageGeometry
        )
        return .success(SwiftReadabilityProcessingResult(outputHTML: outputHTML))
    }
    
    @MainActor
    public func onNavigationCommitted(
        readerContent: ReaderContent,
        newState: WebViewState,
        scriptCaller: WebViewScriptCaller,
        navigator: WebViewNavigator
    ) async throws {
        let commitTrace = ReaderLoadTrace.begin("readerMode.navigationCommittedCallback")
        defer { commitTrace?.end() }
        try Task.checkCancellation()
        if !newState.pageURL.isReaderDocumentURL { resourcePresentation = nil }

        guard let content = readerContent.content else {
            print("No content to display in ReaderModeViewModel onNavigationCommitted")
            cancelReaderModeLoad(
                for: newState.pageURL,
                readerContent: readerContent
            )
            return
        }
        try Task.checkCancellation()
        
        let committedURL = content.url
        guard committedURL.matchesReaderURL(newState.pageURL) else {
            print("URL mismatch in ReaderModeViewModel onNavigationCommitted", committedURL, newState.pageURL)
            // Cleanup belongs to this callback's document, not the content
            // selected by a newer restore while the callback was suspended.
            cancelReaderModeLoad(
                for: newState.pageURL,
                readerContent: readerContent
            )
            throw CancellationError()
        }
        try Task.checkCancellation()
        if !newState.pageURL.isReaderDocumentURL && !newState.pageURL.isReaderURLLoaderURL {
            failedReaderModeURL = nil
        }
        resetReadabilitySource()

        let navigationBindingToken = scriptCaller.currentJavaScriptBindingToken
        // A URL request from Back/Forward or WebKit reload needs reconstruction.
        // Only the prepared final-document navigation carries an expected
        // commit. Later requests reconstruct through the themed shell.
        var restoresReaderDocument = false
        if newState.pageURL.isReaderDocumentURL,
           !expectsSyntheticReaderLoaderCommit(for: newState.pageURL) {
            let documentState = try await evaluateReaderDocumentJavaScript(
                """
                return {shell: document.body?.dataset.mnbReaderShell === '1',
                    generation: document.documentElement?.dataset.mnbReaderRenderGeneration || ''};
                """,
                scriptCaller: scriptCaller, requiring: navigationBindingToken
            ) as? [String: Any]
            try Task.checkCancellation()
            guard ownsReaderDocumentBinding(navigationBindingToken, scriptCaller: scriptCaller),
                  readerContent.content?.url.matchesReaderURL(committedURL) == true else { throw CancellationError() }
            // Back/Forward can restore real HTML from a retired render, rather
            // than requesting the shell. Only the native render owner can admit
            // that document's messages and sidecars.
            let generation = (documentState?["generation"] as? String).flatMap(UUID.init(uuidString:))
            restoresReaderDocument = documentState?["shell"] as? Bool == true
                || generation == nil
                || resourcePresentation?.generation != generation
                || !isCurrentOrCompletedRenderReady(for: committedURL, reportedGeneration: generation)
        }
        let requiresDocumentSetup = !newState.pageURL.isReaderURLLoaderURL
            && !restoresReaderDocument
            && newState.pageURL.absoluteString != "about:blank"
        if requiresDocumentSetup {
            await injectSharedFontIfNeeded(
                scriptCaller: scriptCaller,
                pageURL: newState.pageURL,
                requiring: navigationBindingToken
            )
        } else if newState.pageURL.isReaderURLLoaderURL {
            ReaderLoadTrace.event("readerMode.loaderDocumentSetupSkipped")
        } else {
            ReaderLoadTrace.event("readerMode.blankDocumentSetupSkipped")
        }
        try Task.checkCancellation()
        guard ownsReaderDocumentBinding(
            navigationBindingToken,
            scriptCaller: scriptCaller
        ), readerContent.content?.url.matchesReaderURL(committedURL) == true,
           readerContent.pageURL.matchesReaderURL(committedURL) else {
            throw CancellationError()
        }
        if requiresDocumentSetup, scriptCaller.canEvaluateJavaScript {
            do {
                let paginationTrace = ReaderLoadTrace.begin("readerMode.paginationSetup")
                defer { paginationTrace?.end(Task.isCancelled ? "cancelled" : "returned") }
                _ = try await evaluateReaderDocumentJavaScript(
                    "window.paginationTrackingBookKey = bookKey;",
                    arguments: ["bookKey": committedURL.absoluteString],
                    duplicateInMultiTargetFrames: true,
                    scriptCaller: scriptCaller,
                    requiring: navigationBindingToken
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
            }
        }
        try Task.checkCancellation()
        guard ownsReaderDocumentBinding(
            navigationBindingToken,
            scriptCaller: scriptCaller
        ), readerContent.content?.url.matchesReaderURL(committedURL) == true,
           readerContent.pageURL.matchesReaderURL(committedURL) else {
            throw CancellationError()
        }

        if consumeSyntheticReaderLoaderExpectationIfNeeded(for: newState.pageURL) {
            return
        }

        // FIXME: Mokuro? check plugins thing for reader mode url instead of hardcoding methods here
        let isReaderModeVerified = content.isReaderModeByDefault
            && !loadingState.isShowingOriginalHTMLFallback(for: newState.pageURL)
        try Task.checkCancellation()
        
        if isReaderMode != isReaderModeVerified && !newState.pageURL.isEBookURL {
            withAnimation {
                readerModeLoading(isReaderModeVerified)
                isReaderMode = isReaderModeVerified // Reset and confirm via JS later
            }
            try Task.checkCancellation()
        }
        
        if newState.pageURL.isReaderURLLoaderURL || restoresReaderDocument {
            if restoresReaderDocument {
                ReaderLoadTrace.event("readerMode.restoreOwnedDocument")
                clearReadabilityCache(for: committedURL)
            }
            let duplicateLoaderRender = shouldSkipDuplicateLoaderRender(for: committedURL)
            if duplicateLoaderRender.skip {
                return
            }
            let activeReaderFileManager = readerFileManager ?? .shared
            let contentTrace = ReaderLoadTrace.begin("readerMode.storedHTMLRead")
            let html: String?
            do {
                html = try await content.htmlToDisplay(readerFileManager: activeReaderFileManager)
                contentTrace?.end(html == nil ? "missing" : "available")
            } catch {
                contentTrace?.end("failed")
                throw error
            }
            if let html {
                try Task.checkCancellation()
                guard ownsReaderDocumentBinding(
                    navigationBindingToken,
                    scriptCaller: scriptCaller
                ) else {
                    throw CancellationError()
                }

                let currentURL = readerContent.pageURL
                guard committedURL.matchesReaderURL(currentURL) else {
                    print("URL mismatch in ReaderModeViewModel onNavigationCommitted", currentURL, committedURL)
                    cancelReaderModeLoad(for: committedURL)
                    return
                }
                let publicationDateFallback = await readerContentPublicationDateFallback(for: content)
                try Task.checkCancellation()
                guard ownsReaderDocumentBinding(
                    navigationBindingToken,
                    scriptCaller: scriptCaller
                ) else {
                    throw CancellationError()
                }
                guard committedURL.matchesReaderURL(readerContent.pageURL) else {
                    return
                }
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
                } else if hasCanonicalReadabilityMarkup(in: html) {
                    readabilityContent = html
                } else {
                    readabilityContent = nil
                }
                readerContent.isRenderingReaderHTML = true
                showReaderView(
                    readerContent: readerContent,
                    scriptCaller: scriptCaller,
                    navigator: navigator
                )
            } else {
                navigator.load(URLRequest(url: committedURL))
            }
        }
    }
    
    @MainActor
    public func onNavigationFinished(
        newState: WebViewState,
        scriptCaller: WebViewScriptCaller
    ) async {
        let navigationBindingToken = scriptCaller.currentJavaScriptBindingToken
        var isOwnedShell = false
        if newState.pageURL.isReaderDocumentURL {
            isOwnedShell = (try? await evaluateReaderDocumentJavaScript(
                "return document.body?.dataset.mnbReaderShell === '1';",
                scriptCaller: scriptCaller, requiring: navigationBindingToken
            )) as? Bool == true
        }
        let requiresDocumentSetup = !newState.pageURL.isReaderURLLoaderURL
            && !isOwnedShell && newState.pageURL.absoluteString != "about:blank"
        // Blank and loader documents have no article state to initialize.
        // Keep native completion below; the final document retains normal setup.
        if requiresDocumentSetup {
            await injectSharedFontIfNeeded(
                scriptCaller: scriptCaller,
                pageURL: newState.pageURL,
                requiring: navigationBindingToken
            )
        }
        guard !Task.isCancelled,
              ownsReaderDocumentBinding(
                navigationBindingToken,
                scriptCaller: scriptCaller
              ) else {
            return
        }
        if requiresDocumentSetup && !newState.pageURL.isEBookURL {
            // Initial document-end readiness can arrive before the native
            // commit handler has established its render owner. Replay it once
            // after commit/font work, through the same generation-checked
            // message handler, before deciding to defer loader completion.
            _ = try? await evaluateReaderDocumentJavaScript(
                "return window.__manabiPostReaderDocStateEvent?.('navigation-finished');",
                scriptCaller: scriptCaller,
                requiring: navigationBindingToken
            )
            guard !Task.isCancelled,
                  ownsReaderDocumentBinding(
                    navigationBindingToken,
                    scriptCaller: scriptCaller
                  ) else {
                return
            }
        }
        if navigationFinishedDeferral(newState: newState) != nil {
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
        if requiresDocumentSetup {
            do {
                let result = try await evaluateReaderDocumentJavaScript(
                    "return document.body?.dataset.isNextLoadInReaderMode === 'true'",
                    scriptCaller: scriptCaller,
                    requiring: navigationBindingToken
                )
                guard !Task.isCancelled,
                      ownsReaderDocumentBinding(
                        navigationBindingToken,
                        scriptCaller: scriptCaller
                      ) else {
                    return
                }
                let isNextReaderMode = result as? Bool ?? false
                if !isNextReaderMode {
                    readerModeLoading(false)
                }
            } catch {
                guard !Task.isCancelled,
                      ownsReaderDocumentBinding(
                        navigationBindingToken,
                        scriptCaller: scriptCaller
                      ) else {
                    return
                }
                readerModeLoading(false)
            }
        }
    }

    private enum NavigationFinishedDeferral {
        case loader
        case synthetic
        case pending
    }

    private func navigationFinishedDeferral(newState: WebViewState) -> NavigationFinishedDeferral? {
        guard let pendingReaderModeURL else { return nil }

        let renderKey = canonicalRenderKey(pendingReaderModeURL)
        if !pendingReaderModeURL.isEBookURL,
           !newState.hasReaderRenderReady,
           activeRenderGenerationByURL[renderKey] != nil || completedRenderOwner?.key == renderKey {
            return .pending
        }

        if newState.pageURL.isReaderURLLoaderURL {
            let pageMatchesPending = pendingKeysMatch(pendingReaderModeURL, newState.pageURL)
            if !(hasRenderedReadabilityContent && pageMatchesPending) {
                return .loader
            }
        }

        if expectedSyntheticReaderLoaderURL != nil {
            let pageURL = newState.pageURL
            let pageMatchesPending = pendingKeysMatch(pendingReaderModeURL, pageURL)
            if hasRenderedReadabilityContent && pageMatchesPending {
                self.expectedSyntheticReaderLoaderURL = nil
            } else {
                return .synthetic
            }
        }

        if pendingReaderModeURL.isSnippetURL && !hasRenderedReadabilityContent {
            return .pending
        }

        if !hasRenderedReadabilityContent {
            let pageURL = newState.pageURL
            let pageMatchesPending = pendingKeysMatch(pendingReaderModeURL, pageURL)
            let pageIsRealPendingContent = pageMatchesPending && !pageURL.isReaderURLLoaderURL
            if !pageIsRealPendingContent || expectedSyntheticReaderLoaderURL != nil {
                return .pending
            }
        }

        return nil
    }
    
    @MainActor
    public func onNavigationFailed(newState: WebViewState) {
        cancelReaderModeLoad(for: newState.pageURL)
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
        <body data-mnb-subscription-is-active="false">
        \(updatedHTML)
        </body>
        </html>
        """
    }
    if updatedHTML.range(of: #"(?i)<body\b[^>]*\bdata-mnb-subscription-is-active\s*=\s*['"]"#, options: .regularExpression) == nil,
       let bodyRange = updatedHTML.range(of: #"(?i)<body\b"#, options: .regularExpression) {
        updatedHTML.insert(contentsOf: #" data-mnb-subscription-is-active="false""#, at: bodyRange.upperBound)
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
    // Migrate old cached versions
    // TODO: Update cache, if this is a performance issue.
    if !isEBook,
       try doc.getElementById("reader-content") == nil,
       let oldElement = try doc.getElementsByClass("reader-content").first() {
        try oldElement.attr("id", "reader-content")
        try oldElement.removeAttr("class")
    }

    // Pasted/snippet content is persisted inside the loader's mnb-snippet
    // wrapper rather than a readability reader-content wrapper. Promote that
    // wrapper before the native processor partitions text so snippets follow
    // the same segment/sidecar path as web reader content.
    if !isEBook,
       try doc.getElementById("reader-content") == nil,
       let snippetElement = try doc.getElementsByClass("mnb-snippet").first() {
        try snippetElement.attr("id", "reader-content")
        try snippetElement.removeClass("mnb-snippet")
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
        if !isEBook, let head = doc.head() {
            let canvasStyle: SwiftSoup.Element
            if let existing = try doc.getElementById("mnb-reader-canvas") {
                canvasStyle = existing
            } else {
                canvasStyle = try doc.createElement("style")
                try canvasStyle.attr("id", "mnb-reader-canvas")
                try head.prependChild(canvasStyle)
            }
            try canvasStyle.text(readerDocumentCanvasCSS())
        }
        if let bodyTag = doc.body() {
            markReaderSubscriptionInactiveByDefault(in: doc)
            // TODO: font size and theme set elsewhere already..?
            let readerFontSize = readerStoredFontSize() ?? defaultFontSize
            let lightModeTheme = UserDefaults.standard.string(forKey: "lightModeTheme")
                .flatMap(LightModeTheme.init(rawValue:)) ?? .white
            let darkModeTheme = UserDefaults.standard.string(forKey: "darkModeTheme")
                .flatMap(DarkModeTheme.init(rawValue:)) ?? .black
            
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
            do {
                try existing.html(escapeReadabilityText(defaultTitle))
            } catch { }
        }
        
        if !isEBook {
            do {
                try fixAnnoyingTitlesWithPipes(doc: doc, url: url)
            } catch { }
        }
        
        let headerGeometry = !isEBook
            ? ReaderImageGeometry.metadata(in: doc, matchingURL: imageURL, sourceURL: url) : nil
        if !isEBook, let imageURL = imageURL ?? headerGeometry?.url {
            let readerContentAlreadyHasMedia = hasReaderContentMedia(in: doc)
            let documentHasImages = try !(doc.body()?.getElementsByTag(UTF8Arrays.img).isEmpty() ?? true)
            let shouldInjectHeaderImage = (injectEntryImageIntoHeader && !readerContentAlreadyHasMedia)
                || !documentHasImages
            if shouldInjectHeaderImage,
               let header = try doc.getElementById("reader-header") {
                let source = imageURL.absoluteString
                let alreadyPresent = try doc.getElementsByTag(UTF8Arrays.img).contains {
                    try $0.attr("src") == source
                }
                if !alreadyPresent {
                    let image = try doc.createElement("img")
                    try image.attr("src", source)
                    if let headerGeometry {
                        try image.attr("width", String(headerGeometry.width))
                        try image.attr("height", String(headerGeometry.height))
                    }
                    try header.prependChild(image)
                }
            }
        }
    }
}

enum ReaderRenderFailurePhase: String { case documentPreparation, fontPreparation, localHTML }

func recordReaderRenderFailure(_ error: Error, phase: ReaderRenderFailurePhase) {
    let kind: String
    var reason = "other"
    if error is CancellationError { kind = "cancelled" }
    else if let soupError = error as? SwiftSoup.Exception, case .Error(let type, let message) = soupError {
        kind = "SwiftSoup." + String(describing: type)
        // Exact library constants only. Never log arbitrary exception text.
        switch message {
        case "Object must not be null": reason = "missingNode"
        case "String must not be empty": reason = "emptyString"
        case "Insert position out of bounds.": reason = "insertionBounds"
        case "Must be true": reason = "validationTrue"
        case "Must be false": reason = "validationFalse"
        default: break
        }
    } else { kind = String(reflecting: type(of: error)).prefix(128).description }
    ReaderLoadTrace.event("readerMode.renderFailed", "phase=\(phase.rawValue) kind=\(kind) reason=\(reason) code=\((error as NSError).code)")
}
