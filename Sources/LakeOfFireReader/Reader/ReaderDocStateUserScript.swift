import SwiftUIWebView
import WebKit

@MainActor
struct ReaderDocStateUserScript {
    let userScript: WebViewUserScript

    init() {
        let contents = """
(function () {
    try {
        const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.readerDocState;
        const printHandler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.print;
        if (!handler || typeof handler.postMessage !== "function") { return; }
        let stateMachine = { stopped: false, attempts: 0 };
        let rafHandle = { value: 0 };
        let timeoutHandle = { value: 0 };
        let lastTextVisibleSignature = null;
        const isEbookDocument = (() => {
            try {
                const href = String(window.location?.href || "");
                if (href.startsWith("ebook://")) { return true; }
                return document.body?.dataset?.isEbook === "true";
            } catch (_error) {
                return false;
            }
        })();
        let observer = new MutationObserver(() => {
            postState("mutation");
        });
        function hiddenReason(node) {
            if (!node || typeof window.getComputedStyle !== "function") { return null; }
            let current = node;
            while (current) {
                const style = window.getComputedStyle(current);
                const opacity = Number.parseFloat(style.opacity || "1");
                if (style.visibility === "hidden") { return "visibility:hidden"; }
                if (style.display === "none") { return "display:none"; }
                if (current.hidden) { return "hidden-attr"; }
                if (opacity <= 0.01) { return "opacity"; }
                current = current.parentElement ?? null;
            }
            return null;
        }
        function trackingStateForSegment(segment) {
            if (!segment?.classList) { return "unknown"; }
            if (segment.classList.contains("mnb-known")) { return "known"; }
            if (segment.classList.contains("mnb-learning") || segment.classList.contains("mnb-card-created")) {
                return "learning";
            }
            if (segment.classList.contains("mnb-read")) { return "familiar"; }
            if (segment.classList.contains("mnb-suspended")) { return "suspended"; }
            return "unknown";
        }
        function summarizeSegment(segment) {
            if (!segment) { return null; }
            return {
                id: segment.id ?? null,
                state: trackingStateForSegment(segment),
                className: segment.className || null,
                textSample: typeof segment.textContent === "string" ? segment.textContent.trim().slice(0, 48) : null,
                hasSurface: segment.querySelector("mnb-sur") !== null,
                hiddenReason: hiddenReason(segment),
                jlptLevel: segment.dataset?.jlptLevel ?? null,
                lookup: segment.dataset?.jmdictSearchString ?? null
            };
        }
        function summarizeSettings(body, html) {
            return {
                colorScheme: body?.dataset?.manabiColorScheme ?? null,
                lightTheme: body?.dataset?.manabiLightTheme ?? null,
                darkTheme: body?.dataset?.manabiDarkTheme ?? null,
                trackingEnabled: body?.dataset?.mnbTrackingEnabled ?? null,
                trackingHighlightsEnabled: body?.dataset?.manabiTrackingHighlightsEnabled ?? null,
                learningStatusVisibility: body?.dataset?.manabiLearningStatusVisibility ?? null,
                showFamiliar: body?.dataset?.manabiShowFamiliar ?? null,
                showKnown: body?.dataset?.manabiShowKnown ?? null,
                lookupHighlightMode: body?.dataset?.manabiLookupHighlightMode ?? null,
                furiganaEnabled: body?.dataset?.manabiFuriganaEnabled ?? null,
                readerRenderReady: body?.dataset?.mnbReaderRenderReady ?? html?.dataset?.mnbReaderRenderReady ?? null,
                fontPending: html?.dataset?.manabiFontPending ?? null,
                fontReady: html?.dataset?.manabiFontReady ?? null,
                layoutComplete: html?.dataset?.manabiLayoutComplete ?? null,
                subscriptionActive: body?.dataset?.manabiSubscriptionIsActive ?? null
            };
        }
        function summarizeTracking(readerContent) {
            const root = readerContent ?? document;
            const segments = Array.from(root.querySelectorAll("mnb-seg"));
            const surfaces = Array.from(root.querySelectorAll("mnb-sur"));
            const trackedWords = (typeof document.manabi_trackedWords === "object" && document.manabi_trackedWords) ? document.manabi_trackedWords : null;
            const trackedWordKeys = trackedWords ? Object.keys(trackedWords) : [];
            const counts = {
                segments: segments.length,
                surfaces: surfaces.length,
                familiar: 0,
                learning: 0,
                known: 0,
                suspended: 0,
                unknown: 0,
                hiddenSegments: 0,
                visibleSegments: 0,
                segmentsWithoutSurface: 0
            };
            for (const segment of segments) {
                const state = trackingStateForSegment(segment);
                counts[state] = (counts[state] ?? 0) + 1;
                if (hiddenReason(segment)) {
                    counts.hiddenSegments += 1;
                } else {
                    counts.visibleSegments += 1;
                }
                if (!segment.querySelector("mnb-sur")) {
                    counts.segmentsWithoutSurface += 1;
                }
            }
            const samples = segments.slice(0, 8).map(summarizeSegment);
            return {
                counts,
                trackedWords: {
                    count: trackedWordKeys.length,
                    sampleEntryIDs: trackedWordKeys.slice(0, 8)
                },
                samples
            };
        }
        function diagnoseTextVisibleIssue(settings, tracking, state) {
            const counts = tracking.counts;
            const diagnoses = [];
            if (!state?.hasReaderContent) {
                diagnoses.push("reader-content-missing");
                return diagnoses;
            }
            if (settings.fontPending === "1" && settings.fontReady !== "1") {
                diagnoses.push("font-gate-still-pending");
            }
            if (settings.layoutComplete === "false") {
                diagnoses.push("layout-still-building");
            }
            if (counts.segments === 0) {
                diagnoses.push("no-tracked-segments-in-live-dom");
                return diagnoses;
            }
            if (counts.applied === 0) {
                diagnoses.push("tracking-classes-not-applied");
            }
            if ((tracking.trackedWords?.count ?? 0) === 0) {
                diagnoses.push("no-tracked-words-in-js");
            }
            if (counts.surfaces === 0) {
                diagnoses.push("no-mnb-sur-nodes-in-live-dom");
            }
            if (counts.segmentsWithoutSurface === counts.segments && counts.segments > 0) {
                diagnoses.push("all-segments-lost-surface-wrappers");
            }
            if ((tracking.trackedWords?.count ?? 0) > 0 && counts.applied === 0) {
                diagnoses.push("tracked-words-loaded-but-no-segment-status-applied");
            }
            if (counts.hiddenSegments === counts.segments && counts.segments > 0) {
                diagnoses.push("all-tracked-segments-hidden");
            }
            if (counts.learning === 0 && counts.unknown === 0 && counts.familiar > 0 && settings.showFamiliar !== "true") {
                diagnoses.push("only-familiar-segments-present-and-familiar-highlights-disabled");
            }
            if (counts.learning === 0 && counts.unknown === 0 && counts.known > 0 && settings.showKnown !== "true") {
                diagnoses.push("known-segments-present-but-known-highlights-disabled");
            }
            if (diagnoses.length === 0) {
                diagnoses.push("tracked-segments-present-check-css-rendering");
            }
            return diagnoses;
        }
        function postTextVisible(reason, state) {
            try {
                if (!printHandler || typeof printHandler.postMessage !== "function") { return; }
                const body = document.body;
                const html = document.documentElement;
                const readerContent = document.getElementById('reader-content');
                const tracking = summarizeTracking(readerContent);
                const settings = summarizeSettings(body, html);
                const payload = {
                    message: "# TEXTVISIBLE",
                    probeVersion: 2,
                    reason,
                    href: window.location.href,
                    readyState: document.readyState,
                    state: {
                        hasReaderContent: !!readerContent,
                        hasReaderRenderReady: !!state?.hasReaderRenderReady,
                        bodyClassName: body?.className ?? null
                    },
                    settings,
                    tracking,
                    diagnosis: diagnoseTextVisibleIssue(settings, tracking, state)
                };
                const signature = JSON.stringify(payload);
                if (signature === lastTextVisibleSignature) { return; }
                lastTextVisibleSignature = signature;
                printHandler.postMessage(payload);
            } catch (_error) {}
        }
        function currentState(reason) {
            return {
                href: window.location.href,
                readyState: document.readyState,
                hasBody: !!document.body,
                hasReaderContent: !!document.getElementById('reader-content'),
                hasReadabilityGlobal: typeof window.manabi_readability === 'function',
                hasReaderRenderReady:
                    (document.documentElement?.dataset?.mnbReaderRenderReady === '1'
                    || document.body?.dataset?.mnbReaderRenderReady === '1')
                    && !!document.getElementById('reader-content')
                    && (document.documentElement?.dataset?.manabiFontPending ?? null) !== '1'
                    && window.getComputedStyle(document.body).visibility !== 'hidden'
                    && window.getComputedStyle(document.body).display !== 'none'
                    && Number.parseFloat(window.getComputedStyle(document.body).opacity || '1') > 0.01,
                reason
            };
        }
        function stopPolling() {
            if (stateMachine.stopped) { return; }
            stateMachine.stopped = true;
            try { observer.disconnect(); } catch (_error) {}
            if (rafHandle.value) { cancelAnimationFrame(rafHandle.value); }
            if (timeoutHandle.value) { clearTimeout(timeoutHandle.value); }
        }
        function postState(reason) {
            const state = currentState(reason);
            handler.postMessage(state);
            postTextVisible(reason, state);
            if (state.hasReaderRenderReady) {
                stopPolling();
                return true;
            }
            return false;
        }
        window.__manabiPostReaderDocStateEvent = function(reason) {
            return postState(reason || "event");
        };
        if (isEbookDocument) {
            return;
        }
        let attempts = 0;
        function scheduleNextTick() {
            if (stateMachine.stopped || stateMachine.attempts >= 80) { return; }
            stateMachine.attempts += 1;
            rafHandle.value = requestAnimationFrame(() => {
                timeoutHandle.value = setTimeout(() => {
                    if (!postState("poll")) {
                        scheduleNextTick();
                    }
                }, 25);
            });
        }
        if (document.documentElement) {
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
        if (!postState("initial")) {
            scheduleNextTick();
        }
    } catch (e) { /* noop */ }
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
