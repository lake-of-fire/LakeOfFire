import SwiftUIWebView
import WebKit

/// Reports the explicit reader render-ready contract to the native reader host.
/// Reader markup owns the `mnb` dataset keys; SwiftUIWebView only transports messages.
@MainActor
struct ReaderDocStateUserScript {
    let userScript: WebViewUserScript

    init() {
        let contents = """
(function () {
    try {
        const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.readerDocState;
        if (!handler || typeof handler.postMessage !== "function") { return; }
        const bootstrapNow = (typeof performance !== "undefined" && typeof performance.now === "function")
            ? performance.now.bind(performance)
            : () => Date.now();
        const bootstrapStartedAt = bootstrapNow();
        const isEbookDocument = window.location.href.startsWith("ebook://");
        window.__swiftUIWebViewNavigationScrollSemantics = function() {
            const body = document.body;
            const content = document.getElementById("reader-content") || body || document.documentElement;
            const writingMode = content
                ? String(getComputedStyle(content)?.writingMode || "").toLowerCase()
                : "";
            const resolved = typeof window.manabiResolveReaderWritingDirection === "function"
                ? window.manabiResolveReaderWritingDirection()
                : null;
            const vertical = Boolean(resolved?.vertical) || writingMode.startsWith("vertical");
            if (!vertical) {
                return { axis: "vertical", horizontalForwardSign: 1 };
            }
            const verticalRTL = Boolean(resolved?.verticalRTL) || writingMode.startsWith("vertical-rl");
            return { axis: "horizontal", horizontalForwardSign: verticalRTL ? -1 : 1 };
        };
        let stateMachine = { stopped: false, attempts: 0 };
        let rafHandle = { value: 0 };
        let timeoutHandle = { value: 0 };
        let observer = isEbookDocument ? null : new MutationObserver(() => {
            postState("mutation");
        });
        function rounded(value) {
            if (typeof value !== "number" || !Number.isFinite(value)) { return null; }
            return Math.round(value * 1000) / 1000;
        }
        function currentState(reason) {
            const html = document.documentElement;
            const body = document.body;
            const readerContent = document.getElementById("reader-content");
            const readerStage = document.getElementById("reader-stage");
            const foliateView = readerStage?.querySelector?.("foliate-view") ?? document.querySelector("foliate-view");
            const hasReaderContent = !!readerContent || !!foliateView;
            const hasRenderReadyMarker = html?.dataset?.mnbReaderRenderReady === '1'
                || body?.dataset?.mnbReaderRenderReady === '1';
            return {
                href: window.location.href,
                elapsedMs: rounded(bootstrapNow() - bootstrapStartedAt),
                readyState: document.readyState,
                hasBody: !!body,
                hasReaderContent,
                hasReaderRenderReady: hasRenderReadyMarker
                    && hasReaderContent
                    && (html?.dataset?.manabiFontPending ?? null) !== '1',
                reason,
                attempts: stateMachine.attempts
            };
        }
        function stopPolling() {
            if (stateMachine.stopped) { return; }
            stateMachine.stopped = true;
            try { observer?.disconnect?.(); } catch (_error) {}
            if (rafHandle.value) { cancelAnimationFrame(rafHandle.value); }
            if (timeoutHandle.value) { clearTimeout(timeoutHandle.value); }
        }
        function postState(reason) {
            const state = currentState(reason);
            handler.postMessage(state);
            if (state.hasReaderRenderReady) {
                stopPolling();
                return true;
            }
            return false;
        }
        window.__manabiPostReaderDocStateEvent = function(reason) {
            return postState(reason || "event");
        };
        if (isEbookDocument) { return; }
        function scheduleNextTick() {
            if (stateMachine.stopped || stateMachine.attempts >= 80) { return; }
            stateMachine.attempts += 1;
            rafHandle.value = requestAnimationFrame(() => {
                timeoutHandle.value = setTimeout(() => {
                    if (!postState("poll")) { scheduleNextTick(); }
                }, 25);
            });
        }
        if (document.documentElement && observer) {
            observer.observe(document.documentElement, {
                childList: true,
                subtree: true,
                attributes: true,
                attributeFilter: ["data-mnb-reader-render-ready", "data-manabi-font-pending"]
            });
        }
        document.addEventListener("readystatechange", () => { postState("readystatechange"); });
        document.addEventListener("DOMContentLoaded", () => { postState("domcontentloaded"); });
        window.addEventListener("load", () => { postState("load"); });
        if (!postState("initial")) { scheduleNextTick(); }
    } catch (_error) {}
})();
"""
        userScript = WebViewUserScript(
            source: contents,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .page
        )
    }
}
