// Global timers for side-nav chevron fades
import './view.js'
import {
createTOCView
} from './ui/tree.js'
import { NavigationHUD } from './ebook-viewer-nav.js'
import { copyCustomReaderFontStyleToDocument } from './ebook-font-forwarding.js'
import { applyLayoutSettingsToEbookDocument } from './ebook-layout-settings.js'
import {
    classifyEbookRenderReadiness,
    EbookRenderReadinessCoordinator,
    waitForEbookRenderReadinessSignal,
} from './ebook-render-readiness.js'
import { makeDirectSectionURLResolver } from './ebook-direct-section.js'
import { ebookProgressFractionForRelocate } from './ebook-reading-progress.js'
import {
    ebookSentenceIdentifier,
    ebookSegmentIdentity,
    ebookSegmentIdentifierAliases,
} from './ebook-segment-identity.js'
import {
    makeInitialRestoreTerminalResult,
    makeSyntheticRestoreLocator,
    normalizeInitialRestoreRequest,
    parseSyntheticRestoreLocator,
    restoreLocatorKind as classifyRestoreLocator,
    runRequiredRestoreNavigation,
    shouldSkipScheduledReaderFractionGoTo,
} from './ebook-restore-coordination.js'
import { DeferredOpenWorkCoordinator } from './deferred-open-work.js'
import {
    collectSegmentNodesInVisibleRange,
    collectViewportSampleSegmentNodes,
} from './visible-segment-collection.js'
import {
    Overlayer
} from '../foliate-js/overlayer.js'

const MANABI_DISABLE_INITIAL_PAGINATOR_SETTLE = false;
const MANABI_DISABLE_NAV_HIDDEN_LAYOUT_CLASSES = false;
const MANABI_DISABLE_DYNAMIC_CHROME_INSETS = true;
const MANABI_ENABLE_EBOOK_PAGE_TRACKING_BUTTONS = false;

const ignoredWindowErrorMessages = new Set([
    'ResizeObserver loop completed with undelivered notifications.',
]);

const shouldIgnoreWindowError = message => ignoredWindowErrorMessages.has(String(message ?? ''));

window.onerror = function(msg, source, lineno, colno, error) {
    if (shouldIgnoreWindowError(msg)) return true;
    window.webkit?.messageHandlers?.readerOnError?.postMessage?.({
        message: msg,
        source: source,
        lineno: lineno,
        colno: colno,
        error: String(error)
    });
};

window.onunhandledrejection = function(event) {
    window.webkit?.messageHandlers?.readerOnError?.postMessage?.({
        message: event.reason?.message ?? "Unhandled rejection",
        source: window.location.href,
        lineno: null,
        colno: null,
        error: event.reason?.stack ?? String(event.reason)
    });
};

function forwardShadowErrors(root) {
    if (!root) return;
    root.addEventListener('error', e => {
        window.webkit?.messageHandlers?.readerOnError?.postMessage?.({
            message: e.message || e.error?.message || 'Shadow-DOM error',
            source: window.location.href,
            lineno: e.lineno || 0,
            colno: e.colno || 0,
            error: e.error?.stack || String(e.error || e)
        });
    });
    root.addEventListener('unhandledrejection', e => {
        window.webkit?.messageHandlers?.readerOnError?.postMessage?.({
            message: e.reason?.message || 'Shadow-DOM unhandled rejection',
            source: window.location.href,
            lineno: 0,
            colno: 0,
            error: e.reason?.stack || String(e.reason)
        });
    });
}

const markReaderRenderReady = (reason = 'unspecified') => {
    try {
        const html = document.documentElement;
        const body = document.body;
        if (html?.dataset) {
            html.dataset.manabiReaderRenderReady = '1';
        }
        if (body?.dataset) {
            body.dataset.manabiReaderRenderReady = '1';
        }
        globalThis.__manabiPostReaderDocStateEvent?.(`renderReady.${reason}`);
    } catch (_error) {}
};

const roundedDisplayPercent = value => {
    if (typeof value !== 'number' || !Number.isFinite(value)) {
        return null;
    }
    return Math.round(Math.max(0, Math.min(1, value)) * 100);
};

const describeMarkReadNode = (node) => {
    if (!node) return null;
    const element = node.nodeType === Node.ELEMENT_NODE
        ? node
        : (node.parentElement || null);
    if (!element) {
        return {
            nodeType: node.nodeType ?? null,
            nodeName: node.nodeName || null,
        };
    }
    return {
        nodeType: node.nodeType ?? null,
        nodeName: node.nodeName || null,
        elementTag: element.tagName || null,
        elementID: element.id || null,
        classSample: typeof element.className === 'string'
            ? element.className.split(/\s+/).filter(Boolean).slice(0, 4)
            : [],
        segmentIdentifier: segmentIdentifierForNode(element),
        sentenceIdentifier: sentenceIdentifierForNode(element.closest?.('mnb-sen') || null),
    };
};

const getPrimaryRendererContentIndex = (renderer) => {
    try {
        const contents = renderer?.getContents?.();
        const primaryContent = Array.isArray(contents) && contents.length > 0 ? contents[0] ?? null : null;
        return typeof primaryContent?.index === 'number' ? primaryContent.index : null;
    } catch (_error) {
        return null;
    }
};

const captureNavVisibilityState = () => {
    const body = document.body;
    const navBar = document.getElementById('nav-bar');
    const navPrimaryText = document.getElementById('nav-primary-text');
    return {
        bodyNavHiddenClass: body?.classList?.contains?.('nav-hidden') ?? null,
        navHiddenClass: navBar?.classList?.contains?.('nav-hidden') ?? null,
        navHiddenScrollClass: navBar?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null,
        hudHideNavigationDueToScroll: !!globalThis.reader?.navHUD?.hideNavigationDueToScroll,
        hudNavHidden: !!globalThis.reader?.navHUD?.navHidden,
        labelVariant: navPrimaryText?.dataset?.labelVariant ?? null,
        primaryLabel: document.getElementById('nav-primary-text-full')?.textContent
            || navPrimaryText?.textContent
            || '',
        compactLabel: document.getElementById('nav-primary-text-compact')?.textContent || '',
    };
};

const eventClientPoint = (event) => {
    const touch = event?.changedTouches?.[0] || event?.touches?.[0] || null;
    const clientX = Number(touch?.clientX ?? event?.clientX);
    const clientY = Number(touch?.clientY ?? event?.clientY);
    return Number.isFinite(clientX) && Number.isFinite(clientY) ? { clientX, clientY } : null;
};

const isEventInsideElementCircle = (event, element, slop = 2) => {
    if (!(element instanceof Element)) {
        return true;
    }
    const point = eventClientPoint(event);
    const rect = element.getBoundingClientRect?.();
    if (!point || !rect || rect.width <= 0 || rect.height <= 0) {
        return true;
    }
    const radius = Math.min(rect.width, rect.height) / 2 + slop;
    const dx = point.clientX - (rect.left + rect.width / 2);
    const dy = point.clientY - (rect.top + rect.height / 2);
    return Math.hypot(dx, dy) <= radius;
};

const REPLACE_TEXT_RESULT_CACHE_LIMIT = 64;
const CACHE_WARMER_FOREGROUND_PAGE_TURN_COOLDOWN_MS = 1800;
const CACHE_WARMER_IDLE_RETRY_MS = 250;
const CACHE_WARMER_ADVANCE_SPACING_MS = 350;
const CACHE_WARMER_MAX_SECTIONS_AHEAD = 2;
const replaceTextResultCache = new Map();
const replaceTextInFlightCache = new Map();

const fingerprintReplaceTextInput = (text) => {
    if (typeof text !== 'string') return 'invalid';
    let hash = 2166136261;
    for (let i = 0; i < text.length; i += 1) {
        hash ^= text.charCodeAt(i);
        hash = Math.imul(hash, 16777619);
    }
    return `${text.length}:${(hash >>> 0).toString(16)}`;
};

const makeReplaceTextCacheKey = ({ href, text, isCacheWarmer }) => {
    return `${isCacheWarmer ? 'cache' : 'live'}|${href || 'nil'}|${fingerprintReplaceTextInput(text)}`;
};

const rememberReplaceTextResult = (key, value) => {
    replaceTextResultCache.delete(key);
    replaceTextResultCache.set(key, value);
    while (replaceTextResultCache.size > REPLACE_TEXT_RESULT_CACHE_LIMIT) {
        const oldestKey = replaceTextResultCache.keys().next().value;
        replaceTextResultCache.delete(oldestKey);
    }
};

const adaptReplaceTextHTMLForMode = (html, { href, isCacheWarmer }) => {
    if (!isCacheWarmer) return html;
    return injectBodyDatasetAttributes(html, {
        'data-is-cache-warmer': 'true',
        'data-mnb-source-href': href,
    });
};

// Factory for replaceText with isCacheWarmer support
const makeReplaceText = (isCacheWarmer) => async (href, text, mediaType) => {
    if (mediaType !== 'application/xhtml+xml' && mediaType !== 'text/html' /* && mediaType !== 'application/xml'*/ ) {
        return text;
    }
    if (!isCacheWarmer) {
        await ensureCacheWarmerPrecedingSectionsForHref(href);
    }
    const cacheKey = makeReplaceTextCacheKey({
        href,
        text,
        isCacheWarmer: !!isCacheWarmer,
    });
    const liveEquivalentCacheKey = isCacheWarmer
        ? makeReplaceTextCacheKey({ href, text, isCacheWarmer: false })
        : null;
    const resultCacheKey = replaceTextResultCache.has(cacheKey)
        ? cacheKey
        : liveEquivalentCacheKey && replaceTextResultCache.has(liveEquivalentCacheKey)
            ? liveEquivalentCacheKey
            : null;
    if (resultCacheKey) {
        const cachedSourceHTML = replaceTextResultCache.get(resultCacheKey);
        const cachedHTML = resultCacheKey === cacheKey
            ? cachedSourceHTML
            : adaptReplaceTextHTMLForMode(cachedSourceHTML, { href, isCacheWarmer: !!isCacheWarmer });
        replaceTextResultCache.delete(resultCacheKey);
        replaceTextResultCache.set(resultCacheKey, cachedSourceHTML);
        if (!isCacheWarmer) {
            window.manabi_recordLiveProcessedSection?.(href);
        }
        return cachedHTML;
    }
    const inFlightCacheKey = replaceTextInFlightCache.has(cacheKey)
        ? cacheKey
        : liveEquivalentCacheKey && replaceTextInFlightCache.has(liveEquivalentCacheKey)
            ? liveEquivalentCacheKey
            : null;
    if (inFlightCacheKey) {
        const cacheWaitStartedAt = performanceNowMs();
        const sourceHTML = await replaceTextInFlightCache.get(inFlightCacheKey);
        const html = inFlightCacheKey === cacheKey
            ? sourceHTML
            : adaptReplaceTextHTMLForMode(sourceHTML, { href, isCacheWarmer: !!isCacheWarmer });
        if (!isCacheWarmer) {
            window.manabi_recordLiveProcessedSection?.(href);
        }
        return html;
    }
    const run = async () => {
    const replaceTextStartedAt = performanceNowMs();
    globalThis.__manabiInflightReplaceTextCount = (globalThis.__manabiInflightReplaceTextCount ?? 0) + 1;
    if (!isCacheWarmer) {
        globalThis.__manabiInflightLiveReplaceTextCount = (globalThis.__manabiInflightLiveReplaceTextCount ?? 0) + 1;
        const normalizedHref = normalizeSpineHref(href);
        if (normalizedHref && !firstLiveSectionHref()) {
            globalThis.__manabiFirstLiveSectionHref = normalizedHref;
        }
    }
    if (isCacheWarmer) {
        globalThis.__manabiInflightCacheWarmerReplaceTextCount = (globalThis.__manabiInflightCacheWarmerReplaceTextCount ?? 0) + 1;
    }
    const headers = {
        "Content-Type": mediaType,
        "X-Replaced-Text-Location": href,
        "X-Content-Location": globalThis.reader.view.ownerDocument.defaultView.top.location.href,
    };
    if (isCacheWarmer) {
        headers['X-Is-Cache-Warmer'] = 'true';
    }
    const response = await fetch('ebook://ebook/process-text', {
        method: "POST",
        mode: "cors",
        cache: "no-cache",
        headers: headers,
        body: text
    })
    try {
        if (!response.ok) {
            throw new Error(`HTTP error, status = ${response.status}`)
        }
        const bodyReadStartedAt = performanceNowMs();
        let html = await response.text()
        const bodyReadElapsedMs = safeRound(performanceNowMs() - bodyReadStartedAt, 1);
        if (isCacheWarmer && html.length === 0) {
            const escapedHref = String(href || '').replace(/[&<>"']/g, (character) => ({
                '&': '&amp;',
                '<': '&lt;',
                '>': '&gt;',
                '"': '&quot;',
                "'": '&#39;',
            })[character]);
            return `<html><body data-is-cache-warmer="true" data-mnb-source-href="${escapedHref}"></body></html>`;
        }
        const responseTextLength = html.length;
        const transformStartedAt = performanceNowMs();
        const sentenceCount = (html.match(/<mnb-sen\b/g) || []).length;
        const segmentCount = (html.match(/<mnb-seg\b/g) || []).length;
        html = injectBodyDatasetAttributes(html, {
            'data-is-cache-warmer': isCacheWarmer ? 'true' : null,
            'data-mnb-source-href': href,
            'data-mnb-has-sentences': sentenceCount > 0 ? 'true' : null,
            'data-mnb-has-segments': segmentCount > 0 ? 'true' : null,
        });
        const transformElapsedMs = safeRound(performanceNowMs() - transformStartedAt, 1);
        if (!isCacheWarmer) {
            window.manabi_recordLiveProcessedSection?.(href);
        }
        rememberReplaceTextResult(cacheKey, html);
        return html
    } catch (error) {
        console.error("Error replacing text:", error)
        return text
    } finally {
        globalThis.__manabiInflightReplaceTextCount = Math.max(0, (globalThis.__manabiInflightReplaceTextCount ?? 1) - 1);
        if (!isCacheWarmer) {
            globalThis.__manabiInflightLiveReplaceTextCount = Math.max(0, (globalThis.__manabiInflightLiveReplaceTextCount ?? 1) - 1);
        }
        if (isCacheWarmer) {
            globalThis.__manabiInflightCacheWarmerReplaceTextCount = Math.max(0, (globalThis.__manabiInflightCacheWarmerReplaceTextCount ?? 1) - 1);
        }
        if (
            !isCacheWarmer
            && globalThis.__manabiCacheWarmerOpenRequested
            && globalThis.__manabiInflightReplaceTextCount === 0
        ) {
            void maybeOpenDeferredCacheWarmer();
        }
    }
    };
    const promise = run();
    replaceTextInFlightCache.set(cacheKey, promise);
    try {
        return await promise;
    } finally {
        replaceTextInFlightCache.delete(cacheKey);
    }
}

const debounce = (fn, delay) => {
    let timeout = null;
    let latestArgs = null;
    let latestContext = null;

    const debounced = function(...args) {
        latestArgs = args;
        latestContext = this;
        if (timeout) {
            clearTimeout(timeout);
        }
        timeout = setTimeout(() => {
            const callArgs = latestArgs;
            const callContext = latestContext;
            timeout = null;
            latestArgs = null;
            latestContext = null;
            fn.apply(callContext, callArgs ?? []);
        }, delay);
    };

    debounced.cancel = () => {
        if (timeout) {
            clearTimeout(timeout);
            timeout = null;
        }
        latestArgs = null;
        latestContext = null;
    };

    return debounced;
};

const visibleJapaneseTextStateForVisibleSegmentsResult = (visibleSegmentsResult = null) => {
    let visibleSegmentCount = 0;
    for (const item of visibleSegmentsResult?.visibleSegments || []) {
        if ((item.node?.textContent || '').trim()) {
            visibleSegmentCount += 1;
        }
    }
    return {
        hasVisibleJapaneseText: visibleSegmentCount > 0,
        visibleSegmentCount,
        observedSegmentCount: visibleSegmentsResult?.totalSegmentCount ?? 0,
    };
};

const getVisibleJapaneseTextStateForRenderer = (renderer, visibleRange = null, visibleSegmentsResult = null) => {
    if (visibleSegmentsResult) {
        return visibleJapaneseTextStateForVisibleSegmentsResult(visibleSegmentsResult);
    }
    const contents = renderer?.getContents?.() || [];
    const currentIndex = getPrimaryRendererContentIndex(renderer);
    const activeContents = typeof currentIndex === 'number'
        ? contents.filter((content) => typeof content?.index !== 'number' || content.index === currentIndex)
        : contents;
    let observedSegmentCount = 0;
    let visibleSegmentCount = 0;

    for (const content of activeContents) {
        const doc = content?.doc || content?.document || null;
        if (!doc?.querySelectorAll) { continue; }
        const contentVisibleRange = visibleRange?.commonAncestorContainer?.ownerDocument === doc
            || visibleRange?.startContainer?.ownerDocument === doc
            || visibleRange?.endContainer?.ownerDocument === doc
            ? visibleRange
            : null;
        const visibleSegmentsResult = collectVisibleSegmentNodesFromRange(doc, contentVisibleRange);
        observedSegmentCount += visibleSegmentsResult.totalSegmentCount ?? 0;
        for (const item of visibleSegmentsResult.visibleSegments || []) {
            if ((item.node?.textContent || '').trim()) {
                visibleSegmentCount += 1;
            }
        }
    }

    return {
        hasVisibleJapaneseText: visibleSegmentCount > 0,
        visibleSegmentCount,
        observedSegmentCount,
    };
};

const loadRectSnapshot = element => {
    if (!element || typeof element.getBoundingClientRect !== 'function') return null;
    const rect = element.getBoundingClientRect();
    const round = value => Number.isFinite(value) ? Number(value.toFixed(1)) : null;
    return {
        x: round(rect.x),
        y: round(rect.y),
        width: round(rect.width),
        height: round(rect.height),
        top: round(rect.top),
        right: round(rect.right),
        bottom: round(rect.bottom),
        left: round(rect.left),
    };
};

const lookupPositionRectSnapshot = rect => {
    if (!rect) return null;
    const round = value => Number.isFinite(value) ? Number(value.toFixed(2)) : null;
    return {
        left: round(rect.left ?? rect.x),
        top: round(rect.top ?? rect.y),
        width: round(rect.width),
        height: round(rect.height),
        right: round(rect.right),
        bottom: round(rect.bottom),
    };
};

const postEBookSafeAreaTopSnapshot = (event, details = {}) => {
    const readerStage = document.getElementById('reader-stage');
    const navBar = document.getElementById('nav-bar');
    const liveFoliateView = Array.from(document.querySelectorAll('foliate-view'))
        .find((view) => view?.dataset?.isCache !== 'true') || null;
    const renderer = liveFoliateView?.renderer ?? globalThis.reader?.view?.renderer ?? null;
    const visibleFrame = Array.from(renderer?.shadowRoot?.querySelectorAll?.('iframe') ?? [])
        .find((frame) => {
            const rect = frame?.getBoundingClientRect?.();
            return rect && rect.width > 0 && rect.height > 0;
        }) ?? null;
    const bodyStyle = document.body ? getComputedStyle(document.body) : null;
    const htmlStyle = getComputedStyle(document.documentElement);
    const payload = {
        ...details,
        bodyClass: document.body?.className || null,
        htmlPaddingTop: htmlStyle?.paddingTop || null,
        bodyPaddingTop: bodyStyle?.paddingTop || null,
        bodyCssToolbarBottom: bodyStyle?.getPropertyValue('--mnb-toolbar-bottom-offset')?.trim() || null,
        bodyCssReaderStageTop: bodyStyle?.getPropertyValue('--mnb-reader-stage-top-inset')?.trim() || null,
        bodyCssReaderStageBottom: bodyStyle?.getPropertyValue('--mnb-reader-stage-bottom-inset')?.trim() || null,
        visualViewport: window.visualViewport ? {
            width: roundLayoutNumber(window.visualViewport.width),
            height: roundLayoutNumber(window.visualViewport.height),
            offsetTop: roundLayoutNumber(window.visualViewport.offsetTop),
            pageTop: roundLayoutNumber(window.visualViewport.pageTop),
            scale: roundLayoutNumber(window.visualViewport.scale, 3),
        } : null,
        windowInnerHeight: roundLayoutNumber(window.innerHeight),
        readerStageRect: lookupPositionRectSnapshot(readerStage?.getBoundingClientRect?.()),
        navBarRect: lookupPositionRectSnapshot(navBar?.getBoundingClientRect?.()),
        foliateViewRect: lookupPositionRectSnapshot(liveFoliateView?.getBoundingClientRect?.()),
        rendererRect: lookupPositionRectSnapshot(renderer?.getBoundingClientRect?.()),
        iframeRect: lookupPositionRectSnapshot(visibleFrame?.getBoundingClientRect?.()),
    };
    const key = JSON.stringify(payload);
    if (globalThis.__manabiLastLookupPositionSafeAreaTopKey === key) return;
    globalThis.__manabiLastLookupPositionSafeAreaTopKey = key;
};

const roundLayoutNumber = (value, digits = 1) => {
    const number = Number(value);
    return Number.isFinite(number) ? Number(number.toFixed(digits)) : null;
};

const layoutElementSnapshot = element => {
    if (!element) return null;
    return {
        rect: loadRectSnapshot(element),
        scrollLeft: roundLayoutNumber(element.scrollLeft),
        scrollTop: roundLayoutNumber(element.scrollTop),
        scrollWidth: roundLayoutNumber(element.scrollWidth),
        scrollHeight: roundLayoutNumber(element.scrollHeight),
        clientWidth: roundLayoutNumber(element.clientWidth),
        clientHeight: roundLayoutNumber(element.clientHeight),
        offsetWidth: roundLayoutNumber(element.offsetWidth),
        offsetHeight: roundLayoutNumber(element.offsetHeight),
    };
};


const collectEBookLayoutSnapshot = (view = globalThis.reader?.view ?? null, extra = {}) => {
    const renderer = view?.renderer ?? globalThis.reader?.view?.renderer ?? null;
    const shadowRoot = renderer?.shadowRoot ?? null;
    const container = shadowRoot?.getElementById?.('container') ?? shadowRoot?.querySelector?.('#container') ?? null;
    const top = shadowRoot?.getElementById?.('top') ?? shadowRoot?.querySelector?.('#top') ?? null;
    const header = shadowRoot?.getElementById?.('header') ?? shadowRoot?.querySelector?.('#header') ?? null;
    const footer = shadowRoot?.getElementById?.('footer') ?? shadowRoot?.querySelector?.('#footer') ?? null;
    const contents = renderer?.getContents?.() || [];
    const primaryContent = contents.find?.(content =>
        content?.doc?.body
        || content?.document?.body
        || content?.frame?.contentDocument?.body
        || content?.iframe?.contentDocument?.body
    ) ?? null;
    const readerDoc = renderer?.view?.document
        ?? renderer?.view?.doc
        ?? primaryContent?.doc
        ?? primaryContent?.document
        ?? primaryContent?.frame?.contentDocument
        ?? primaryContent?.iframe?.contentDocument
        ?? null;
    const readerRoot = readerDoc?.documentElement ?? null;
    const readerBody = readerDoc?.body ?? null;
    const readerBodyStyle = readerDoc?.defaultView && readerBody
        ? readerDoc.defaultView.getComputedStyle(readerBody)
        : null;
    const visualViewport = window.visualViewport ?? null;

    return {
        ...extra,
        href: location.href,
        windowInnerWidth: roundLayoutNumber(window.innerWidth),
        windowInnerHeight: roundLayoutNumber(window.innerHeight),
        windowScrollX: roundLayoutNumber(window.scrollX),
        windowScrollY: roundLayoutNumber(window.scrollY),
        visualViewportWidth: roundLayoutNumber(visualViewport?.width),
        visualViewportHeight: roundLayoutNumber(visualViewport?.height),
        visualViewportOffsetTop: roundLayoutNumber(visualViewport?.offsetTop),
        visualViewportPageTop: roundLayoutNumber(visualViewport?.pageTop),
        visualViewportScale: roundLayoutNumber(visualViewport?.scale, 3),
        bodyClass: document.body?.className || null,
        rendererLocalName: renderer?.localName || null,
        rendererFlow: renderer?.getAttribute?.('flow') || null,
        rendererDir: renderer?.getAttribute?.('dir') || null,
        rendererClass: renderer?.className || null,
        rendererContentCount: contents.length,
        rendererSnapshot: layoutElementSnapshot(renderer),
        viewSnapshot: layoutElementSnapshot(view),
        topSnapshot: layoutElementSnapshot(top),
        containerSnapshot: layoutElementSnapshot(container),
        headerRect: loadRectSnapshot(header),
        footerRect: loadRectSnapshot(footer),
        readerReadyState: readerDoc?.readyState || null,
        readerRootClientWidth: roundLayoutNumber(readerRoot?.clientWidth),
        readerRootClientHeight: roundLayoutNumber(readerRoot?.clientHeight),
        readerRootScrollWidth: roundLayoutNumber(readerRoot?.scrollWidth),
        readerRootScrollHeight: roundLayoutNumber(readerRoot?.scrollHeight),
        readerBodyClientWidth: roundLayoutNumber(readerBody?.clientWidth),
        readerBodyClientHeight: roundLayoutNumber(readerBody?.clientHeight),
        readerBodyScrollWidth: roundLayoutNumber(readerBody?.scrollWidth),
        readerBodyScrollHeight: roundLayoutNumber(readerBody?.scrollHeight),
        readerWritingMode: readerBodyStyle?.writingMode || null,
        readerDirection: readerBodyStyle?.direction || null,
        readerColumnWidth: readerBodyStyle?.columnWidth || null,
        readerColumnGap: readerBodyStyle?.columnGap || null,
        readerColumnCount: readerBodyStyle?.columnCount || null,
        visibleSegmentCount: document.querySelectorAll?.('[data-mnb-segment-id]').length ?? null,
    };
};



const compactBookLayoutDetails = details => ({
    reason: details.reason ?? null,
    layoutMode: details.layoutMode ?? null,
    writingDirection: details.writingDirection ?? null,
    side: details.side ?? null,
    method: details.method ?? null,
    eventType: details.eventType ?? null,
    rendererFlow: details.rendererFlow ?? null,
    rendererDir: details.rendererDir ?? null,
    rendererRect: details.rendererSnapshot?.rect ?? null,
    viewRect: details.viewSnapshot?.rect ?? null,
    containerRect: details.containerSnapshot?.rect ?? null,
    containerScrollLeft: details.containerSnapshot?.scrollLeft ?? null,
    containerScrollTop: details.containerSnapshot?.scrollTop ?? null,
    containerScrollWidth: details.containerSnapshot?.scrollWidth ?? null,
    containerScrollHeight: details.containerSnapshot?.scrollHeight ?? null,
    readerRootClientWidth: details.readerRootClientWidth ?? null,
    readerRootClientHeight: details.readerRootClientHeight ?? null,
    readerRootScrollWidth: details.readerRootScrollWidth ?? null,
    readerRootScrollHeight: details.readerRootScrollHeight ?? null,
    readerBodyClientWidth: details.readerBodyClientWidth ?? null,
    readerBodyClientHeight: details.readerBodyClientHeight ?? null,
    readerBodyScrollWidth: details.readerBodyScrollWidth ?? null,
    readerBodyScrollHeight: details.readerBodyScrollHeight ?? null,
    readerWritingMode: details.readerWritingMode ?? null,
    readerDirection: details.readerDirection ?? null,
    readerColumnWidth: details.readerColumnWidth ?? null,
    readerColumnGap: details.readerColumnGap ?? null,
    readerColumnCount: details.readerColumnCount ?? null,
    viewportWidth: details.visualViewportWidth ?? details.windowInnerWidth ?? null,
    viewportHeight: details.visualViewportHeight ?? details.windowInnerHeight ?? null,
});


const collectEPUBLoadDiagnostics = (reason, extra = {}) => {
    const renderer = globalThis.reader?.view?.renderer ?? null;
    const readerDoc = globalThis.reader?.view?.renderer?.view?.document ?? null;
    const body = document.body;
    const readerBody = readerDoc?.body ?? null;
    const readerRoot = readerDoc?.documentElement ?? null;
    const readerBodyStyle = readerDoc?.defaultView && readerBody
        ? readerDoc.defaultView.getComputedStyle(readerBody)
        : null;
    return {
        reason,
        href: location.href,
        bodyLoading: !!body?.classList?.contains?.('loading'),
        hasReader: !!globalThis.reader,
        hasView: !!globalThis.reader?.view,
        hasRenderer: !!renderer,
        rendererDisplay: renderer?.style?.display || null,
        rendererFlow: renderer?.getAttribute?.('flow') || null,
        rendererDir: renderer?.getAttribute?.('dir') || null,
        rendererRect: loadRectSnapshot(renderer),
        foliateViewRect: loadRectSnapshot(document.querySelector('foliate-view')),
        loadingIndicatorRect: loadRectSnapshot(document.querySelector('#loading-indicator')),
        windowInnerWidth: window.innerWidth,
        windowInnerHeight: window.innerHeight,
        visualViewportWidth: window.visualViewport?.width ?? null,
        visualViewportHeight: window.visualViewport?.height ?? null,
        sourceKind: globalThis.ebookSource?.kind || null,
        sourceURL: globalThis.ebookSource?.url || null,
        firstLiveSectionHref: globalThis.__manabiFirstLiveSectionHref || null,
        liveProcessedSectionCount: globalThis.__manabiLiveProcessedSectionHrefs?.size ?? null,
        liveSettledSectionCount: globalThis.__manabiLiveSettledSectionHrefs?.size ?? null,
        cacheWarmerReady: !!globalThis.__manabiCacheWarmerReady,
        cacheWarmerFinished: !!globalThis.__manabiCacheWarmerFinished,
        inflightReplaceTextCount: globalThis.__manabiInflightReplaceTextCount ?? null,
        readerDocumentURL: readerDoc?.location?.href || null,
        readerDocumentReadyState: readerDoc?.readyState || null,
        readerWritingMode: readerBodyStyle?.writingMode || null,
        readerDirection: readerBodyStyle?.direction || null,
        readerBodyClass: readerBody?.className || null,
        readerBodySegmentCount: readerDoc?.querySelectorAll?.('mnb-seg')?.length ?? null,
        readerBodySentenceCount: readerDoc?.querySelectorAll?.('mnb-sen')?.length ?? null,
        readerDocumentClientWidth: readerRoot?.clientWidth ?? null,
        readerDocumentClientHeight: readerRoot?.clientHeight ?? null,
        ...extra,
    };
};

const isCacheWarmerDocument = (doc) => doc?.body?.dataset?.isCacheWarmer === 'true';

const captureEPUBOverlapState = () => ({
    inflightReplaceTextCount: globalThis.__manabiInflightReplaceTextCount ?? 0,
    inflightLiveReplaceTextCount: globalThis.__manabiInflightLiveReplaceTextCount ?? 0,
    inflightCacheWarmerReplaceTextCount: globalThis.__manabiInflightCacheWarmerReplaceTextCount ?? 0,
    cacheWarmerOpenInFlight: !!globalThis.__manabiCacheWarmerOpenInFlight,
    cacheWarmerReady: !!globalThis.__manabiCacheWarmerReady,
    cacheWarmerFinished: !!globalThis.__manabiCacheWarmerFinished,
    cacheWarmerHighestSectionIndex: globalThis.__manabiCacheWarmerHighestSectionIndex ?? null,
});

const markCacheWarmerForegroundActivity = (reason = 'unspecified', cooldownMs = CACHE_WARMER_FOREGROUND_PAGE_TURN_COOLDOWN_MS) => {
    const now = performanceNowMs();
    const previousPausedUntil = Number(globalThis.__manabiCacheWarmerPausedUntilMs || 0);
    const nextPausedUntil = Math.max(previousPausedUntil, now + Math.max(0, Number(cooldownMs) || 0));
    globalThis.__manabiCacheWarmerPausedUntilMs = nextPausedUntil;
    globalThis.__manabiCacheWarmerWorkGeneration = (globalThis.__manabiCacheWarmerWorkGeneration || 0) + 1;
};

const cacheWarmerWorkGeneration = () => globalThis.__manabiCacheWarmerWorkGeneration || 0;

const invalidateCacheWarmerWork = () => {
    globalThis.__manabiCacheWarmerWorkGeneration = (globalThis.__manabiCacheWarmerWorkGeneration || 0) + 1;
    return globalThis.__manabiCacheWarmerWorkGeneration;
};

const cacheWarmerForegroundBusyState = () => {
    const now = performanceNowMs();
    const pauseRemainingMs = Math.max(0, Number(globalThis.__manabiCacheWarmerPausedUntilMs || 0) - now);
    const liveReplaceTextCount = globalThis.__manabiInflightLiveReplaceTextCount ?? 0;
    if (liveReplaceTextCount > 0) {
        return {
            busy: true,
            reason: 'live-replace-text',
            retryMs: CACHE_WARMER_IDLE_RETRY_MS,
            pauseRemainingMs: safeRound(pauseRemainingMs, 1),
            liveReplaceTextCount,
        };
    }
    if (pauseRemainingMs > 0) {
        return {
            busy: true,
            reason: 'foreground-cooldown',
            retryMs: Math.min(Math.max(80, pauseRemainingMs), CACHE_WARMER_FOREGROUND_PAGE_TURN_COOLDOWN_MS),
            pauseRemainingMs: safeRound(pauseRemainingMs, 1),
            liveReplaceTextCount,
        };
    }
    return {
        busy: false,
        reason: null,
        retryMs: 0,
        pauseRemainingMs: 0,
        liveReplaceTextCount,
    };
};

const scheduleLoadNextCacheWarmerSection = (settledSectionHrefs = [], reason = 'unspecified', options = {}) => {
    if (typeof window.cacheWarmer?.loadNextSectionSkippingSettled !== 'function') {
        return;
    }
    if (globalThis.__manabiCacheWarmerAdvanceInFlight) {
        return;
    }
    const force = options?.force === true;
    const cacheWarmerWindowLimitState = (targetIndex) => {
        const activeIndex = activeForegroundSectionIndex();
        const minTargetIndex = Number.isInteger(activeIndex) ? Math.max(0, activeIndex) : 0;
        const maxTargetIndex = Number.isInteger(activeIndex)
            ? activeIndex + CACHE_WARMER_MAX_SECTIONS_AHEAD
            : null;
        return {
            activeIndex: Number.isInteger(activeIndex) ? activeIndex : null,
            minTargetIndex,
            maxTargetIndex,
            targetIndex: Number.isInteger(targetIndex) ? targetIndex : null,
            isWithinWindow: !Number.isInteger(targetIndex)
                || !Number.isInteger(maxTargetIndex)
                || targetIndex <= maxTargetIndex,
        };
    };
    const busyState = cacheWarmerForegroundBusyState();
    if (busyState.busy && !(force && busyState.reason === 'foreground-cooldown')) {
        clearTimeout(globalThis.__manabiCacheWarmerLoadNextTimer);
        globalThis.__manabiCacheWarmerLoadNextTimer = setTimeout(() => {
            globalThis.__manabiCacheWarmerLoadNextTimer = null;
            scheduleLoadNextCacheWarmerSection(settledSectionHrefs, `${reason}.retry`, options);
        }, busyState.retryMs);
        return;
    }
    const now = performanceNowMs();
    const lastAdvanceStartedAt = Number(globalThis.__manabiCacheWarmerLastAdvanceStartedAtMs || 0);
    const spacingRemainingMs = Math.max(0, lastAdvanceStartedAt + CACHE_WARMER_ADVANCE_SPACING_MS - now);
    if (!force && spacingRemainingMs > 0) {
        clearTimeout(globalThis.__manabiCacheWarmerLoadNextTimer);
        globalThis.__manabiCacheWarmerLoadNextTimer = setTimeout(() => {
            globalThis.__manabiCacheWarmerLoadNextTimer = null;
            scheduleLoadNextCacheWarmerSection(settledSectionHrefs, `${reason}.spacing`, options);
        }, spacingRemainingMs);
        return;
    }
    const activeIndex = activeForegroundSectionIndex();
    const precedingTargetIndex = cacheWarmerPrecedingTargetIndex();
    const minimumIndex = Number.isInteger(precedingTargetIndex) ? 0 : activeIndex;
    const targetIndex = window.cacheWarmer?.nextUnsettledSectionIndexSkippingSettled?.(settledSectionHrefs, minimumIndex);
    const windowLimitState = cacheWarmerWindowLimitState(targetIndex);
    if (!Number.isInteger(precedingTargetIndex) && !windowLimitState.isWithinWindow) {
        return;
    }
    globalThis.__manabiCacheWarmerLastAdvanceStartedAtMs = performanceNowMs();
    globalThis.__manabiCacheWarmerAdvanceInFlight = true;
    window.cacheWarmer?.loadNextSectionSkippingSettled?.(settledSectionHrefs, minimumIndex)
        ?.finally?.(() => {
            globalThis.__manabiCacheWarmerAdvanceInFlight = false;
        })
        ?.catch?.((error) => console.error(error));
};

const summarizeDocumentFontState = (doc) => ({
    fontStatus: doc?.fonts?.status ?? 'unsupported',
    hasFontsAPI: !!doc?.fonts,
    readyState: doc?.readyState ?? 'nil',
    isCacheWarmerDocument: isCacheWarmerDocument(doc),
});
const classifySingleMediaDocumentForInitialLayout = (doc, reason = 'unknown') => {
    const body = doc?.body;
    if (!body || body.dataset?.mnbSingleMediaInitialLayoutChecked === 'true') {
        return {
            applied: false,
            reason: body ? 'already-checked' : 'missing-body',
        };
    }
    body.dataset.mnbSingleMediaInitialLayoutChecked = 'true';
    const mediaSelector = 'img, svg, image, picture, video, object';
    const mediaElements = Array.from(body.querySelectorAll?.(mediaSelector) ?? []);
    const textLength = body.textContent?.trim?.().length ?? 0;
    const textNodeType = doc.defaultView?.Node?.TEXT_NODE ?? 3;
    const substantiveElements = Array.from(body.querySelectorAll?.('*') ?? [])
        .filter((element) => {
            if (element?.nodeType !== 1) return false;
            if (element.matches(mediaSelector)) return false;
            if (element.closest('mnb-seg, .mnb-tracking-container')) return false;
            if (element.matches('.h-valign-width, .v-valign-height, .inline-width, .inline-height')) return false;
            const tagName = element.tagName?.toLowerCase?.() ?? '';
            if (tagName === 'br' || tagName === 'script' || tagName === 'style') return false;
            const ownText = Array.from(element.childNodes ?? [])
                .filter((node) => node.nodeType === textNodeType)
                .map((node) => node.textContent ?? '')
                .join('')
                .trim();
            return ownText.length > 0;
        });
    const shouldApply = textLength === 0 && mediaElements.length === 1 && substantiveElements.length === 0;
    if (!shouldApply) {
        return {
            applied: false,
            reason: 'not-single-media',
            textLength,
            mediaCount: mediaElements.length,
            substantiveElementCount: substantiveElements.length,
        };
    }
    const htmlWritingMode = doc.defaultView?.getComputedStyle?.(doc.documentElement)?.writingMode || '';
    const bodyWritingMode = doc.defaultView?.getComputedStyle?.(body)?.writingMode || '';
    if (htmlWritingMode.startsWith('vertical') || bodyWritingMode.startsWith('vertical')) {
        body.classList.add('reader-vertical-writing');
    }
    body.classList.add('reader-is-single-media-element-without-text');
    return {
        applied: true,
        reason: 'single-media',
        textLength,
        mediaCount: mediaElements.length,
        htmlWritingMode,
        bodyWritingMode,
    };
};

const ignoreNextIncomingHideNavigation = (source) => {
    globalThis.__manabiIgnoreNextIncomingHideNavigationCount = 1;
};

const ignoreNextIncomingRevealNavigation = (source) => {
    globalThis.__manabiIgnoreNextIncomingRevealNavigationCount = 1;
};

const postEbookNavigationVisibilityToNative = (shouldHide, source, details = {}) => {
    const requestedHide = !!shouldHide;
    try {
        window.webkit?.messageHandlers?.ebookNavigationVisibility?.postMessage?.({
            hideNavigationDueToScroll: requestedHide,
            source,
            ...details,
        });
        return true;
    } catch (_error) {
        return false;
    }
};

const recordPageTurnNavigationIntent = (direction, source, details = {}) => {
    const now = Date.now();
    if (direction === 'forward') {
        globalThis.__manabiLastForwardPageTurnHideAtMs = now;
    } else if (direction === 'backward') {
        globalThis.__manabiLastBackwardPageTurnRevealAtMs = now;
    }
};

const requestLookupCloseForPageMotion = (reason, details = {}) => {
    if (globalThis.reader?.lookupNavigationPageTurnActive === true) {
        return;
    }
    try {
        window.webkit?.messageHandlers?.touchstartCallbackHandler?.postMessage?.({
            touchedEntryWithElementId: null,
            wasAlreadySelected: false,
            lookupCloseReason: reason,
            touchstartAtMs: Date.now(),
        });
    } catch (_error) {}
};

const resolveFoliatePaginator = (view = null) => {
    const renderer = view?.renderer || null;
    if (renderer?.localName === 'foliate-paginator') return renderer;
    return renderer?.querySelector?.('foliate-paginator')
        || view?.shadowRoot?.querySelector?.('foliate-paginator')
        || null;
};

const getActiveReaderDocument = () => {
    const contents = globalThis.reader?.view?.renderer?.getContents?.() || [];
    return contents[0]?.doc || null;
};

const runWithNavigationIntent = async (intent, operation) => {
    const previousIntent = globalThis.__manabiNavigationIntent ?? null;
    globalThis.__manabiNavigationIntent = {
        timestamp: Date.now(),
        ...intent,
    };
    try {
        return await operation();
    } finally {
        globalThis.__manabiNavigationIntent = previousIntent;
    }
};

const shouldSkipScheduledReaderFractionGoToForRestoreSettling = (fraction) => {
    const restoreSettlingMs = typeof bookRestoreSettlingMs === 'function'
        ? bookRestoreSettlingMs()
        : Math.max(0, Number(globalThis.__manabiBookRestoreSettlingUntil || 0) - Date.now());
    if (shouldSkipScheduledReaderFractionGoTo({
        requiresUserInputBeforePositionSave: globalThis.__manabiRequireUserInputBeforePositionSave,
        restoreSettlingMs,
    })) {
        globalThis.manabiPostBookLog?.('position.schedule.skip', {
            reason: 'restore-settling',
            restoreSettlingMs,
            fraction: Number.isFinite(fraction) ? fraction : null,
            source: globalThis.__manabiBookRestoreSettlingSource || null,
        });
        return true;
    }
    return false;
};

const getLoadedEbookDocuments = (explicitDoc = null) => {
    const docs = [];
    const addDoc = (doc) => {
        if (!doc || doc === document || docs.includes(doc)) return;
        docs.push(doc);
    };
    addDoc(explicitDoc);
    try {
        const contents = globalThis.reader?.view?.renderer?.getContents?.() || [];
        for (const content of contents) {
            addDoc(content?.doc ?? content?.document ?? null);
        }
    } catch {}
    return docs;
};

const applyNavigationHiddenStateToEbookDocument = (doc, reason = 'unknown') => {
    const body = doc?.body;
    if (!body || doc === document) {
        return {
            applied: false,
            reason: body ? 'outer-document' : 'missing-body',
        };
    }
    const hidden = globalThis.reader?.navHUD?.hideNavigationDueToScroll === true;
    const previousHidden = body.__manabiNavigationHiddenDueToScroll;
    body.__manabiNavigationHiddenDueToScroll = hidden;
    body.classList.remove('nav-hidden', 'nav-hidden-due-to-scroll');
    delete body.dataset.mnbNavigationHiddenDueToScroll;
    const refreshResult = body.ownerDocument?.defaultView
        ?.manabi_refreshEbookTrackingPaintNavigationState?.(hidden, { source: reason });
    return {
        applied: true,
        hidden,
        changed: previousHidden !== hidden || (refreshResult?.mutatedCount ?? 0) > 0,
    };
};

window.manabiApplyNavigationHiddenStateToEbookDocument = (reason = 'manual', explicitDoc = null) => {
    const docs = getLoadedEbookDocuments(explicitDoc);
    let appliedCount = 0;
    for (const doc of docs) {
        if (applyNavigationHiddenStateToEbookDocument(doc, reason).applied) {
            appliedCount += 1;
        }
    }
    return {
        documentCount: docs.length,
        appliedCount,
    };
};

window.manabiForwardReaderFontToEbookDocuments = (reason = 'manual', explicitDoc = null) => {
    const docs = getLoadedEbookDocuments(explicitDoc);
    const sourceFontStyle = document.getElementById('mnb-custom-fonts-inline')
        || docs.map((doc) => doc?.getElementById?.('mnb-custom-fonts-inline')).find(Boolean)
        || null;
    let forwardedCount = 0;
    for (const doc of docs) {
        if (doc !== document && copyCustomReaderFontStyleToDocument(sourceFontStyle, doc, reason)) {
            forwardedCount += 1;
        }
    }
    return {
        documentCount: docs.length,
        forwardedCount,
        outerHasCustomFontStyle: !!sourceFontStyle,
    };
};

const cacheWarmerSourceForCurrentBook = () => {
    return window.ebookSource
        || makeFileSource(new File([window.blob], new URL(globalThis.reader.view.ownerDocument.defaultView.top.location.href).pathname));
};

const liveProcessedSectionHrefSet = () => {
    if (!(globalThis.__manabiLiveProcessedSectionHrefs instanceof Set)) {
        globalThis.__manabiLiveProcessedSectionHrefs = new Set();
    }
    return globalThis.__manabiLiveProcessedSectionHrefs;
};

const liveSettledSectionHrefSet = () => {
    if (!(globalThis.__manabiLiveSettledSectionHrefs instanceof Set)) {
        globalThis.__manabiLiveSettledSectionHrefs = new Set();
    }
    return globalThis.__manabiLiveSettledSectionHrefs;
};

const firstLiveSectionHref = () => {
    const normalizedHref = normalizeSpineHref(globalThis.__manabiFirstLiveSectionHref ?? null);
    return normalizedHref || null;
};

const sectionHref = (section) => normalizeSpineHref(section?.href ?? section?.id ?? null);

const sectionIndexForHref = (href) => {
    const normalizedHref = normalizeSpineHref(href);
    if (!normalizedHref) return null;
    const sections = Array.isArray(globalThis.reader?.view?.book?.sections)
        ? globalThis.reader.view.book.sections
        : [];
    const index = sections.findIndex((section) => sectionHref(section) === normalizedHref);
    return index >= 0 ? index : null;
};

const nextLinearSectionIndexAfterHref = (href) => {
    const sections = Array.isArray(globalThis.reader?.view?.book?.sections)
        ? globalThis.reader.view.book.sections
        : [];
    const sourceIndex = sectionIndexForHref(href);
    if (!Number.isInteger(sourceIndex)) return null;
    for (let index = sourceIndex + 1; index < sections.length; index += 1) {
        if (sections[index]?.linear === 'no') continue;
        if (sectionHref(sections[index])) return index;
    }
    return null;
};

const activeForegroundSectionHref = () => {
    const sections = Array.isArray(globalThis.reader?.view?.book?.sections)
        ? globalThis.reader.view.book.sections
        : [];
    const contentIndex = getPrimaryRendererContentIndex(globalThis.reader?.view?.renderer);
    const activeHref = Number.isInteger(contentIndex)
        ? sectionHref(sections[contentIndex])
        : null;
    return activeHref || firstLiveSectionHref();
};

const activeForegroundSectionIndex = () => sectionIndexForHref(activeForegroundSectionHref());

const cacheWarmerPrecedingTargetIndex = () => {
    const targetIndex = Number(globalThis.__manabiCacheWarmerRequiredPrecedingTargetIndex);
    return Number.isInteger(targetIndex) && targetIndex > 0 ? targetIndex : null;
};

const isCacheWarmerPrecedingSectionsComplete = (targetIndex) => {
    if (!Number.isInteger(targetIndex) || targetIndex <= 0) return true;
    const highestSectionIndex = Number(globalThis.__manabiCacheWarmerHighestSectionIndex);
    if (Number.isInteger(highestSectionIndex) && highestSectionIndex >= targetIndex - 1) return true;
    if (globalThis.__manabiCacheWarmerFinished) return true;
    return false;
};

const resolveCacheWarmerPrecedingSectionWaiters = () => {
    const waiters = Array.isArray(globalThis.__manabiCacheWarmerPrecedingSectionWaiters)
        ? globalThis.__manabiCacheWarmerPrecedingSectionWaiters
        : [];
    if (waiters.length === 0) return;
    globalThis.__manabiCacheWarmerPrecedingSectionWaiters = waiters.filter((waiter) => {
        if (!isCacheWarmerPrecedingSectionsComplete(waiter?.targetIndex)) return true;
        clearTimeout(waiter.timer);
        waiter.resolve?.();
        return false;
    });
    const requiredTarget = cacheWarmerPrecedingTargetIndex();
    if (Number.isInteger(requiredTarget) && isCacheWarmerPrecedingSectionsComplete(requiredTarget)) {
        globalThis.__manabiCacheWarmerRequiredPrecedingTargetIndex = null;
    }
};

const ensureCacheWarmerPrecedingSectionsForHref = async (href) => {
    const targetIndex = sectionIndexForHref(href);
    if (!Number.isInteger(targetIndex) || targetIndex <= 0) return;
    if (isCacheWarmerPrecedingSectionsComplete(targetIndex)) return;
    const existingTarget = cacheWarmerPrecedingTargetIndex();
    const nextTarget = Math.max(existingTarget ?? 0, targetIndex);
    globalThis.__manabiCacheWarmerRequiredPrecedingTargetIndex = nextTarget;
    if (!globalThis.__manabiCacheWarmerPrecedingSectionWaiters) {
        globalThis.__manabiCacheWarmerPrecedingSectionWaiters = [];
    }
    if (
        !globalThis.__manabiCacheWarmerReady
        && !globalThis.__manabiCacheWarmerOpenInFlight
        && !globalThis.__manabiCacheWarmerOpenRequested
    ) {
        scheduleDeferredCacheWarmerOpen('preceding-sections-required', 0);
    }
    if (globalThis.__manabiCacheWarmerOpenRequested) {
        void maybeOpenDeferredCacheWarmer();
    }
    scheduleLoadNextCacheWarmerSection([], 'preceding-sections-required', { force: true });
    await new Promise((resolve) => {
        const waiter = { targetIndex, resolve };
        globalThis.__manabiCacheWarmerPrecedingSectionWaiters.push(waiter);
        const poll = () => {
            if (isCacheWarmerPrecedingSectionsComplete(targetIndex)) {
                resolve();
                return;
            }
            waiter.timer = setTimeout(poll, 50);
        };
        poll();
    });
};

const activeForegroundSectionHrefSet = () => {
    const href = activeForegroundSectionHref();
    return href ? new Set([href]) : new Set();
};

const foregroundWarmedSectionHrefSet = () => {
    const hrefs = new Set([
        ...activeForegroundSectionHrefSet(),
        ...liveProcessedSectionHrefSet(),
        ...liveSettledSectionHrefSet(),
    ]);
    return hrefs;
};

window.manabi_recordLiveProcessedSection = (href) => {
    const normalizedHref = normalizeSpineHref(href);
    if (!normalizedHref) return;
    const processedSet = liveProcessedSectionHrefSet();
    const sizeBefore = processedSet.size;
    processedSet.add(normalizedHref);
    const firstLiveHref = firstLiveSectionHref();
    const isNewlyProcessed = processedSet.size !== sizeBefore;
    if (isNewlyProcessed) {
        scheduleLoadNextCacheWarmerSection(Array.from(liveSettledSectionHrefSet()).sort(), 'live-section.processed');
    }
    if (globalThis.__manabiInitialForegroundNextSectionPending && processedSet.size >= 2) {
        globalThis.__manabiInitialForegroundNextSectionPending = false;
    }
    if (globalThis.__manabiCacheWarmerOpenRequested) {
        void maybeOpenDeferredCacheWarmer();
    }
};

window.manabi_recordLiveSettledSection = (href) => {
    const normalizedHref = normalizeSpineHref(href);
    if (!normalizedHref) return;
    const settledSet = liveSettledSectionHrefSet();
    const sizeBefore = settledSet.size;
    settledSet.add(normalizedHref);
    const firstLiveHref = firstLiveSectionHref();
    const isNewlySettled = settledSet.size !== sizeBefore;
    if (isNewlySettled) {
        scheduleLoadNextCacheWarmerSection(Array.from(settledSet).sort(), 'live-section.settled');
    }
    if (normalizedHref === firstLiveHref) {
    }
    if (globalThis.__manabiCacheWarmerOpenRequested) {
        void maybeOpenDeferredCacheWarmer();
    }
};

window.manabi_syncLiveSettledSections = (payload = {}) => {
    const rawHrefs =
        (Array.isArray(payload.hrefs) && payload.hrefs)
        || (Array.isArray(payload.settledSectionHrefs) && payload.settledSectionHrefs)
        || [];
    const nextSettledSectionHrefs = Array.from(new Set(
        rawHrefs.map((href) => normalizeSpineHref(href)).filter(Boolean)
    )).sort();
    const previousFirstLiveHref = firstLiveSectionHref();
    const previousSettledSectionHrefs = Array.from(liveProcessedSectionHrefSet()).sort();
    globalThis.__manabiLiveProcessedSectionHrefs = new Set(nextSettledSectionHrefs);
    if (typeof payload.firstLiveHref === 'string' && payload.firstLiveHref.length > 0) {
        globalThis.__manabiFirstLiveSectionHref = normalizeSpineHref(payload.firstLiveHref);
    }
    const nextFirstLiveHref = firstLiveSectionHref();
    const didChange =
        previousFirstLiveHref !== nextFirstLiveHref
        || previousSettledSectionHrefs.length !== nextSettledSectionHrefs.length
        || previousSettledSectionHrefs.some((href, index) => href !== nextSettledSectionHrefs[index]);
    if (!didChange) return;
    if (globalThis.__manabiCacheWarmerOpenRequested) {
        void maybeOpenDeferredCacheWarmer();
    }
};

const isForegroundReaderIdle = () => {
    const bodyLoading = !!document.body?.classList?.contains?.('loading');
    const firstLiveHref = firstLiveSectionHref();
    return !!globalThis.reader?.hasLoadedLastPosition
        && !bodyLoading
        && (globalThis.__manabiInflightReplaceTextCount ?? 0) === 0
        && !!firstLiveHref
        && liveSettledSectionHrefSet().has(firstLiveHref)
        && !globalThis.__manabiCacheWarmerOpenInFlight
        && !globalThis.__manabiCacheWarmerReady;
};

const shouldDeferInitialCacheWarmerTarget = (preflightScan) => {
    if (!globalThis.__manabiInitialForegroundNextSectionPending) return false;
    const firstHref = firstLiveSectionHref();
    const processedCount = liveProcessedSectionHrefSet().size;
    const expectedForegroundIndex = nextLinearSectionIndexAfterHref(firstHref);
    const shouldDefer =
        processedCount < 2
        && Number.isInteger(expectedForegroundIndex)
        && preflightScan?.targetIndex === expectedForegroundIndex;
    if (!shouldDefer && processedCount >= 2) {
        globalThis.__manabiInitialForegroundNextSectionPending = false;
    }
    return shouldDefer;
};

const cacheWarmerSectionScan = ({ startIndex = 0, warmedSectionHrefs = foregroundWarmedSectionHrefSet() } = {}) => {
    const sections = Array.isArray(globalThis.reader?.view?.book?.sections)
        ? globalThis.reader.view.book.sections
        : [];
    const resolvedStartIndex = Number.isInteger(startIndex)
        ? Math.max(0, startIndex)
        : 0;
    const activeHref = activeForegroundSectionHref();
    const warmed = warmedSectionHrefs instanceof Set
        ? new Set(warmedSectionHrefs)
        : new Set(Array.isArray(warmedSectionHrefs) ? warmedSectionHrefs : []);
    if (activeHref) warmed.add(activeHref);
    const sample = [];
    let targetIndex = null;
    let targetHref = null;
    for (let index = resolvedStartIndex; index < sections.length; index += 1) {
        const section = sections[index];
        const normalizedSectionHref = sectionHref(section);
        const isNonLinear = section?.linear === 'no';
        const isWarmed = !!normalizedSectionHref && warmed.has(normalizedSectionHref);
        // Do not skip "metadata-looking" hrefs here. Files like title.xhtml can
        // contain real reader text. Only the actively displayed foreground
        // section is skipped; other live-loaded sections still need warmer scans.
        let skipReason = null;
        if (isNonLinear) skipReason = 'non-linear';
        else if (!normalizedSectionHref) skipReason = 'missing-href';
        else if (normalizedSectionHref === activeHref) skipReason = 'active-foreground';
        else if (isWarmed) skipReason = 'warmed';
        if (sample.length < 12) {
            sample.push({
                index,
                href: normalizedSectionHref,
                linear: section?.linear ?? null,
                skipReason,
            });
        }
        if (targetIndex === null && skipReason === null) {
            targetIndex = index;
            targetHref = normalizedSectionHref;
        }
    }
    return {
        sectionCount: sections.length,
        startIndex: resolvedStartIndex,
        activeForegroundHref: activeHref,
        targetIndex,
        targetHref,
        sample,
    };
};

const nextUsefulCacheWarmerSectionIndex = () => {
    return cacheWarmerSectionScan().targetIndex;
};

const maybeOpenDeferredCacheWarmer = async () => {
    if (globalThis.__manabiCacheWarmerOpenPromise) {
        return await globalThis.__manabiCacheWarmerOpenPromise;
    }
    if (!isForegroundReaderIdle()) {
        const firstLiveHref = firstLiveSectionHref();
        const firstLiveSettled = !!firstLiveHref && liveSettledSectionHrefSet().has(firstLiveHref);
        if (!globalThis.__manabiDeferredCacheWarmerLogged) {
            globalThis.__manabiDeferredCacheWarmerLogged = true;
        }
        return;
    }
    const preflightScan = cacheWarmerSectionScan();
    const nextUsefulIndex = preflightScan.targetIndex;
    if (shouldDeferInitialCacheWarmerTarget(preflightScan)) {
        return;
    }
    if (!Number.isInteger(nextUsefulIndex)) {
        globalThis.__manabiCacheWarmerOpenRequested = false;
        globalThis.__manabiCacheWarmerFinished = true;
        globalThis.__manabiCacheWarmerReady = true;
        return;
    }
    const cacheWarmerSource = cacheWarmerSourceForCurrentBook();
    globalThis.__manabiCacheWarmerOpenRequested = false;
    const openPromise = (async () => {
        await window.cacheWarmer.open(cacheWarmerSource);
    })();
    globalThis.__manabiCacheWarmerOpenPromise = openPromise;
    try {
        await openPromise;
    } finally {
        globalThis.__manabiCacheWarmerOpenPromise = null;
    }
};

const scheduleDeferredCacheWarmerOpen = (reason, delayMs = 0) => {
    if (globalThis.__manabiCacheWarmerReady || globalThis.__manabiCacheWarmerOpenInFlight) {
        return;
    }
    globalThis.__manabiCacheWarmerOpenRequested = true;
    if (reason === 'load-last-position-done' && liveProcessedSectionHrefSet().size < 2) {
        globalThis.__manabiInitialForegroundNextSectionPending = true;
    }
    globalThis.__manabiDeferredCacheWarmerLogged = false;
    clearTimeout(globalThis.__manabiCacheWarmerOpenTimer);
    const normalizedDelay = Math.max(0, Number(delayMs) || 0);
    globalThis.__manabiCacheWarmerOpenTimer = setTimeout(() => {
        globalThis.__manabiCacheWarmerOpenTimer = null;
        const busyState = cacheWarmerForegroundBusyState();
        if (busyState.busy) {
            scheduleDeferredCacheWarmerOpen(`${reason}.retry`, busyState.retryMs);
            return;
        }
        void maybeOpenDeferredCacheWarmer();
    }, normalizedDelay);
};

const postOpenReaderGoToSheetRequest = (source, targetID = null, options = {}) => {
    const preserveHiddenNavigation = !!options.preserveHiddenNavigation;
    const preserveVisibleNavigation = !!options.preserveVisibleNavigation;
    try {
        window.webkit?.messageHandlers?.openReaderGoToSheet?.postMessage?.({
            source,
            targetID,
            preserveHiddenNavigation,
            preserveVisibleNavigation,
        });
    } catch (error) {
    }
};

const flattenTOCEntries = (items, collector = []) => {
    if (!Array.isArray(items)) {
        return collector;
    }
    for (const item of items) {
        if (!item) {
            continue;
        }
        collector.push(item);
        if (Array.isArray(item.subitems) && item.subitems.length > 0) {
            flattenTOCEntries(item.subitems, collector);
        }
    }
    return collector;
};

const fallbackSectionTitle = (href, index) => {
    if (typeof href === 'string' && href) {
        const lastSegment = href.split('/').pop() || href;
        const withoutExtension = lastSegment.replace(/\.[^/.]+$/, '');
        if (/^title$/i.test(withoutExtension)) {
            return 'Title Page';
        }
        const prettified = withoutExtension
            .replace(/[_-]+/g, ' ')
            .replace(/\s+/g, ' ')
            .trim();
        if (prettified && !/^\d+$/.test(prettified)) {
            return prettified.replace(/\b\w/g, (char) => char.toUpperCase());
        }
    }
    return `Section ${index + 1}`;
};

const isLikelyMetadataSectionHref = (href) => {
    if (typeof href !== 'string' || !href) {
        return false;
    }
    const lastSegment = href.split('/').pop() || href;
    const withoutExtension = lastSegment.replace(/\.[^/.]+$/, '').trim();
    return /^(title|cover|nav|toc|contents?)$/i.test(withoutExtension);
};

const buildLinearSectionEntries = (book) => {
    const tocEntries = flattenTOCEntries(book?.toc ?? []);
    const tocTitleByHref = new Map();
    for (const entry of tocEntries) {
        const href = typeof entry?.href === 'string' ? entry.href : null;
        const title = typeof entry?.label === 'string' ? entry.label.trim() : '';
        if (!href || !title || tocTitleByHref.has(href)) {
            continue;
        }
        tocTitleByHref.set(href, title);
    }
    const sectionEntries = Array.isArray(book?.sections)
        ? book.sections
            .filter((section) => section && section.linear !== 'no')
            .map((section, index) => {
                const href = typeof section?.id === 'string' ? section.id : null;
                const title = href ? (tocTitleByHref.get(href) ?? fallbackSectionTitle(href, index)) : '';
                return href && title
                    ? {
                        href,
                        title,
                        pageNumber: null,
                    }
                    : null;
            })
            .filter(Boolean)
        : [];
    const contentSectionEntries = sectionEntries.filter(function(entry) { return !isLikelyMetadataSectionHref(entry?.href); });
    if (contentSectionEntries.length === 1) {
        const onlyContentSection = contentSectionEntries[0];
        if (onlyContentSection && /^Section \d+$/i.test(onlyContentSection.title)) {
            onlyContentSection.title = 'Main Content';
        }
    }
    return sectionEntries;
};

const buildLinearSectionStartPercentByHref = (book) => {
    const linearSections = Array.isArray(book?.sections)
        ? book.sections.filter((section) => section && section.linear !== 'no')
        : [];
    const totalSize = linearSections.reduce((sum, section) => {
        const size = Number(section?.size);
        return sum + (Number.isFinite(size) && size > 0 ? size : 0);
    }, 0);
    const startPercentByHref = new Map();
    let consumedSize = 0;
    for (const section of linearSections) {
        const href = typeof section?.id === 'string' ? section.id : null;
        const normalizedHref = normalizeSpineHref(href);
        if (normalizedHref != null && !startPercentByHref.has(normalizedHref)) {
            const fraction = totalSize > 0 ? consumedSize / totalSize : 0;
            startPercentByHref.set(normalizedHref, safeRound(Math.max(0, Math.min(1, fraction)) * 100, 1));
        }
        const size = Number(section?.size);
        if (Number.isFinite(size) && size > 0) {
            consumedSize += size;
        }
    }
    return startPercentByHref;
};

const buildGoToSnapshotChapters = (book) => {
    const chapters = [];
    const seenHrefs = new Set();
    const tocEntries = flattenTOCEntries(book?.toc ?? []);
    for (const entry of tocEntries) {
        const href = typeof entry?.href === 'string' ? entry.href : null;
        const title = typeof entry?.label === 'string' ? entry.label.trim() : '';
        if (!href || !title || seenHrefs.has(href)) {
            continue;
        }
        seenHrefs.add(href);
        chapters.push({
            href,
            title,
            pageNumber: null,
        });
    }
    const sectionEntries = buildLinearSectionEntries(book);
    for (const entry of sectionEntries) {
        if (!entry?.href || !entry?.title || seenHrefs.has(entry.href)) {
            continue;
        }
        seenHrefs.add(entry.href);
        chapters.push(entry);
    }
    return chapters;
};

const normalizeSpineHref = (href) => {
    if (typeof href !== 'string') return null;
    const trimmed = href.trim();
    if (!trimmed) return null;
    const hashIndex = trimmed.indexOf('#');
    return hashIndex >= 0 ? trimmed.slice(0, hashIndex) : trimmed;
};

const injectBodyDatasetAttributes = (html, attributes) => {
    if (typeof html !== 'string' || !html.replace) {
        return html;
    }
    const entries = Object.entries(attributes)
        .filter(([, value]) => value !== undefined && value !== null && value !== '')
    if (entries.length === 0) {
        return html;
    }
    const escapeAttributeValue = (value) => String(value)
        .replace(/&/g, '&amp;')
        .replace(/"/g, '&quot;')
        .replace(/</g, '&lt;');
    const bodyTagMatch = html.match(/<body\b[^>]*>/i);
    if (!bodyTagMatch) {
        return html;
    }
    let bodyTag = bodyTagMatch[0];
    for (const [key, value] of entries) {
        const escapedValue = escapeAttributeValue(value);
        const attributePattern = new RegExp(`\\s${key}(?:\\s*=\\s*(?:"[^"]*"|'[^']*'|[^\\s>]*))?`, 'ig');
        bodyTag = bodyTag.replace(attributePattern, '');
        bodyTag = bodyTag.replace(/>$/, ` ${key}="${escapedValue}">`);
    }
    return html.slice(0, bodyTagMatch.index) + bodyTag + html.slice(bodyTagMatch.index + bodyTagMatch[0].length);
};

const setNativeHideNavigationState = (shouldHide, source = 'native-bridge') => {
    const sequence = (globalThis.__manabiNativeBridgeVisibilitySequence = Number(globalThis.__manabiNativeBridgeVisibilitySequence || 0) + 1);
    const normalized = !!shouldHide;
    const body = document.body;
    const before = captureNavVisibilityState();
    if (body?.classList?.contains?.('nav-hidden')) {
        body.classList.remove('nav-hidden');
    }
    globalThis.reader?.navHUD?.setHideNavigationDueToScroll?.(normalized, source, {
        bridgeSource: source,
        bodyClassApplied: false,
    });
    const afterSetHide = captureNavVisibilityState();
    const bridgeState = {
        sequence,
        source,
        shouldHide: normalized,
        beforeHudHideNavigationDueToScroll: before.hudHideNavigationDueToScroll ?? null,
        beforeLabelVariant: before.labelVariant ?? null,
        ...captureNavVisibilityState(),
    };
    return normalized;
};

window.manabiSetHideNavigationDueToScroll = (shouldHide, source = 'window.manabiSetHideNavigationDueToScroll') => {
    const requestedHide = !!shouldHide;
    if (requestedHide) {
        const ignoreCount = Number(globalThis.__manabiIgnoreNextIncomingHideNavigationCount || 0);
        if (ignoreCount > 0) {
            globalThis.__manabiIgnoreNextIncomingHideNavigationCount = ignoreCount - 1;
            return false;
        }
    } else {
        const now = Date.now();
        if (
            source === 'touchstartCallbackHandler.noElement.nativeToggle'
            || source?.startsWith?.('explicitReveal.')
        ) {
            globalThis.__manabiLastExplicitNavigationRevealAtMs = now;
        }
        const lastForwardPageTurnHideAtMs = Number(globalThis.__manabiLastForwardPageTurnHideAtMs || 0);
        const lastBackwardPageTurnRevealAtMs = Number(globalThis.__manabiLastBackwardPageTurnRevealAtMs || 0);
        const isStaleSwiftRevealAfterForwardPageTurn =
            source === 'swift.bindingPush'
            && lastForwardPageTurnHideAtMs > lastBackwardPageTurnRevealAtMs
            && now - lastForwardPageTurnHideAtMs < 1500
            && globalThis.reader?.navHUD?.hideNavigationDueToScroll === true;
        if (isStaleSwiftRevealAfterForwardPageTurn) {
            return true;
        }
        if (globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay === true) {
            return true;
        }
        const ignoreCount = Number(globalThis.__manabiIgnoreNextIncomingRevealNavigationCount || 0);
        if (ignoreCount > 0) {
            globalThis.__manabiIgnoreNextIncomingRevealNavigationCount = ignoreCount - 1;
            return true;
        }
    }
    const result = setNativeHideNavigationState(requestedHide, source);
    return result;
};

const isCompactNavigationSheetSidePaginationDisabled = () => (
    document.body?.dataset?.mnbCompactNavigationSheetPresentedAsSheet === 'true'
    && document.body?.dataset?.mnbCompactNavigationSheetDetentKind !== 'zero'
);

window.manabiSetCompactNavigationSheetDetentState = (state = {}) => {
    const presentedAsSheet = state?.presentedAsSheet === true || state?.presentedAsSheet === 'true';
    const semanticDetentKind = typeof state?.semanticDetentKind === 'string'
        ? state.semanticDetentKind
        : 'unknown';
    document.body.dataset.mnbCompactNavigationSheetPresentedAsSheet = presentedAsSheet ? 'true' : 'false';
    document.body.dataset.mnbCompactNavigationSheetDetentKind = semanticDetentKind;
    const sidePaginationDisabled = isCompactNavigationSheetSidePaginationDisabled();
    document.body.dataset.mnbCompactNavigationSheetSidePaginationDisabled = sidePaginationDisabled ? 'true' : 'false';
    void globalThis.reader?.updateNavButtons?.();
    return {
        presentedAsSheet,
        semanticDetentKind,
        sidePaginationDisabled,
    };
};

const normalizeChromeInsetCSSValue = (value) => {
    if (typeof value === 'number' && Number.isFinite(value)) {
        return `${value}px`;
    }
    if (typeof value === 'string') {
        const trimmed = value.trim();
        return trimmed.length > 0 ? trimmed : '0px';
    }
    return '0px';
};

const parseChromeInsetPixelValue = (value) => {
    if (typeof value === 'number' && Number.isFinite(value)) {
        return value;
    }
    if (typeof value !== 'string') {
        return Number.NEGATIVE_INFINITY;
    }
    const trimmed = value.trim();
    if (trimmed.length === 0) {
        return Number.NEGATIVE_INFINITY;
    }
    const numeric = Number.parseFloat(trimmed);
    return Number.isFinite(numeric) ? numeric : Number.NEGATIVE_INFINITY;
};

const createDefaultChromeInsetState = () => ({
    obscuredTopInset: '0px',
    toolbarBottomOffset: '0px',
    obscuredBottomInset: '0px',
    source: 'default',
    revision: 0,
});

const normalizeChromeInsetState = (rawState, fallbackSource = 'unknown') => {
    const normalizedState = {
        obscuredTopInset: normalizeChromeInsetCSSValue(rawState?.obscuredTopInset),
        toolbarBottomOffset: normalizeChromeInsetCSSValue(rawState?.toolbarBottomOffset),
        obscuredBottomInset: normalizeChromeInsetCSSValue(rawState?.obscuredBottomInset),
        source: typeof rawState?.source === 'string' && rawState.source.trim().length > 0
            ? rawState.source.trim()
            : fallbackSource,
        revision: Number.isFinite(rawState?.revision)
            ? rawState.revision
            : null,
    };
    return normalizedState;
};

const getStoredChromeInsetState = () =>
    normalizeChromeInsetState(globalThis.__manabiChromeInsets, 'stored');

const readChromeInsetStateFromWindow = (targetWindow, fallbackSource) => {
    try {
        if (!targetWindow) return null;
        return normalizeChromeInsetState(targetWindow.__manabiChromeInsets, fallbackSource);
    } catch {
        return null;
    }
};

const readLastPositiveChromeInsetStateFromWindow = (targetWindow, fallbackSource) => {
    try {
        if (!targetWindow) return null;
        return normalizeChromeInsetState(targetWindow.__manabiLastPositiveChromeInsets, fallbackSource);
    } catch {
        return null;
    }
};

const getAncestorChromeInsetState = () => {
    const candidates = [];
    try {
        if (window.parent && window.parent !== window) {
            candidates.push(readChromeInsetStateFromWindow(window.parent, 'parent-stored'));
            candidates.push(readLastPositiveChromeInsetStateFromWindow(window.parent, 'parent-stored-positive'));
        }
    } catch {}
    try {
        if (window.top && window.top !== window.parent && window.top !== window) {
            candidates.push(readChromeInsetStateFromWindow(window.top, 'top-stored'));
            candidates.push(readLastPositiveChromeInsetStateFromWindow(window.top, 'top-stored-positive'));
        }
    } catch {}
    for (const candidate of candidates.filter(Boolean)) {
        if (
            parseChromeInsetPixelValue(candidate.obscuredTopInset) > 0 ||
            parseChromeInsetPixelValue(candidate.toolbarBottomOffset) > 0 ||
            parseChromeInsetPixelValue(candidate.obscuredBottomInset) > 0
        ) {
            return candidate;
        }
    }
    return null;
};

const getStoredPositiveChromeInsetState = () => {
    const currentState = getStoredChromeInsetState();
    if (
        parseChromeInsetPixelValue(currentState.obscuredTopInset) > 0 ||
        parseChromeInsetPixelValue(currentState.toolbarBottomOffset) > 0 ||
        parseChromeInsetPixelValue(currentState.obscuredBottomInset) > 0
    ) {
        return currentState;
    }
    const localPositiveState = normalizeChromeInsetState(globalThis.__manabiLastPositiveChromeInsets, 'stored-positive');
    if (
        parseChromeInsetPixelValue(localPositiveState.obscuredTopInset) > 0 ||
        parseChromeInsetPixelValue(localPositiveState.toolbarBottomOffset) > 0 ||
        parseChromeInsetPixelValue(localPositiveState.obscuredBottomInset) > 0
    ) {
        return localPositiveState;
    }
    return getAncestorChromeInsetState()
        ?? localPositiveState;
};

const getNextChromeInsetRevision = () => {
    const currentRevision = Number.isFinite(globalThis.__manabiChromeInsetsRevision)
        ? globalThis.__manabiChromeInsetsRevision
        : 0;
    const nextRevision = currentRevision + 1;
    globalThis.__manabiChromeInsetsRevision = nextRevision;
    return nextRevision;
};

const applyResolvedChromeInsetState = (state) => {
    for (const target of [document.documentElement, document.body].filter(Boolean)) {
        target.style.setProperty('--mnb-reader-stage-top-inset', state.obscuredTopInset);
        target.style.setProperty('--mnb-toolbar-bottom-offset', state.toolbarBottomOffset);
    }
    const readerStage = document.getElementById('reader-stage');
    if (readerStage) {
        readerStage.style.top = state.obscuredTopInset;
        readerStage.style.bottom = 'var(--mnb-reader-stage-bottom-inset, 0px)';
    }
};

const formatLandscapeInsetRect = (rect) => {
    if (!rect) return null;
    return {
        x: Math.round(rect.x),
        y: Math.round(rect.y),
        width: Math.round(rect.width),
        height: Math.round(rect.height),
        top: Math.round(rect.top),
        bottom: Math.round(rect.bottom),
    };
};

const captureLandscapeInsetLayoutProbe = () => {
    const liveFoliateView = Array.from(document.querySelectorAll('foliate-view'))
        .find((view) => view?.dataset?.isCache !== 'true') || null;
    const livePaginator = resolveFoliatePaginator(liveFoliateView);
    const livePaginatorContainer = livePaginator?.shadowRoot?.getElementById?.('container') || null;
    const htmlStyle = getComputedStyle(document.documentElement);
    const bodyStyle = document.body ? getComputedStyle(document.body) : null;
    const navBar = document.getElementById('nav-bar');
    const readerStage = document.getElementById('reader-stage');
    const navBarRect = navBar?.getBoundingClientRect?.() ?? null;
    const readerStageRect = readerStage?.getBoundingClientRect?.() ?? null;
    const visibleFrame = Array.from(livePaginator?.shadowRoot?.querySelectorAll?.('iframe') ?? []).find((frame) => {
        const rect = frame?.getBoundingClientRect?.();
        return rect && rect.width > 0 && rect.height > 0;
    }) ?? null;
    let iframeBodyRect = null;
    try {
        const frameRect = visibleFrame?.getBoundingClientRect?.() ?? null;
        const bodyRect = visibleFrame?.contentDocument?.body?.getBoundingClientRect?.() ?? null;
        if (frameRect && bodyRect) {
            iframeBodyRect = {
                x: frameRect.left + bodyRect.left,
                y: frameRect.top + bodyRect.top,
                width: bodyRect.width,
                height: bodyRect.height,
                top: frameRect.top + bodyRect.top,
                bottom: frameRect.top + bodyRect.bottom,
            };
        }
    } catch {}
    return {
        windowInner: `${window.innerWidth ?? 0}x${window.innerHeight ?? 0}`,
        visualViewport: window.visualViewport ? `${Math.round(window.visualViewport.width)}x${Math.round(window.visualViewport.height)}` : null,
        bodyCssToolbarBottom: bodyStyle?.getPropertyValue('--mnb-toolbar-bottom-offset')?.trim() || null,
        bodyCssSystemBottom: bodyStyle?.getPropertyValue('--mnb-system-bottom-inset')?.trim() || null,
        bodyCssToolbarPhysicalBottom: bodyStyle?.getPropertyValue('--mnb-toolbar-physical-bottom-inset')?.trim() || null,
        bodyCssToolbarLayoutBottom: bodyStyle?.getPropertyValue('--mnb-toolbar-layout-bottom-inset')?.trim() || null,
        bodyCssStageBottom: bodyStyle?.getPropertyValue('--mnb-reader-stage-bottom-inset')?.trim() || null,
        readyState: document.readyState ?? null,
        bodyLoading: !!document.body?.classList?.contains?.('loading'),
        hasLiveFoliateView: !!liveFoliateView,
        hasLivePaginator: !!livePaginator,
        navBarRect: formatLandscapeInsetRect(navBarRect),
        readerStageRect: formatLandscapeInsetRect(readerStageRect),
        navBarBottomGapToViewport: Number.isFinite(navBarRect?.bottom)
            ? Math.round(((window.visualViewport?.height ?? window.innerHeight ?? 0) - navBarRect.bottom) * 10) / 10
            : null,
        readerStageBottomGapToViewport: Number.isFinite(readerStageRect?.bottom)
            ? Math.round(((window.visualViewport?.height ?? window.innerHeight ?? 0) - readerStageRect.bottom) * 10) / 10
            : null,
        foliateViewRect: formatLandscapeInsetRect(liveFoliateView?.getBoundingClientRect?.() ?? null),
        paginatorRect: formatLandscapeInsetRect(livePaginator?.getBoundingClientRect?.() ?? null),
        paginatorContainer: livePaginatorContainer ? `${livePaginatorContainer.clientWidth}x${livePaginatorContainer.clientHeight}` : null,
        iframeRect: formatLandscapeInsetRect(visibleFrame?.getBoundingClientRect?.() ?? null),
        iframeBodyRect: iframeBodyRect ? formatLandscapeInsetRect(iframeBodyRect) : null,
    };
};

const postLandscapeInsetRestoreProbe = (stage, restoreState = null, extra = {}) => {
    try {
        const payload = {
            stage: 'ebookChromeInsets.restoreGeometry',
            restoreStage: stage,
            requestedRestoreFraction: Number.isFinite(globalThis.__manabiRequestedRestoreFraction)
                ? safeRound(globalThis.__manabiRequestedRestoreFraction, 6)
                : null,
            landedFraction: typeof restoreState?.currentFraction === 'number'
                ? safeRound(restoreState.currentFraction, 6)
                : null,
            landedSectionIndex: restoreState?.sectionIndex ?? null,
            landedLocationCurrent: restoreState?.locationCurrent ?? null,
            landedLocationTotal: restoreState?.locationTotal ?? null,
            ...extra,
            layout: captureLandscapeInsetLayoutProbe(),
        };
        const key = JSON.stringify(payload);
        if (globalThis.__manabiLastLandscapeInsetRestoreProbeKey !== key) {
            globalThis.__manabiLastLandscapeInsetRestoreProbeKey = key;
        }
    } catch {}
};

const scheduleReaderUIChromeInsetSettle = (reason, state) => {
    const signature = JSON.stringify({
        reason,
        obscuredTopInset: state?.obscuredTopInset ?? null,
        toolbarBottomOffset: state?.toolbarBottomOffset ?? null,
        obscuredBottomInset: state?.obscuredBottomInset ?? null,
        revision: state?.revision ?? null,
    });
    if (globalThis.__manabiLastReaderUIChromeSettleSignature === signature) {
        return;
    }
    globalThis.__manabiLastReaderUIChromeSettleSignature = signature;
    const run = async (phase) => {
        const renderer = globalThis.reader?.view?.renderer ?? null;
        try {
            if (renderer && typeof renderer.renderIfContainerSizeChanged === 'function') {
                await renderer.renderIfContainerSizeChanged(`reader-ui-chrome-insets.${reason}.${phase}`);
            }
        } catch (_error) {}
    };
    requestAnimationFrame(() => {
        requestAnimationFrame(() => {
            run('raf2');
        });
    });
    setTimeout(() => {
        run('settle250ms');
    }, 250);
};

const applyStoredChromeInsets = (reason = 'unknown', incomingState = null) => {
    if (MANABI_DISABLE_DYNAMIC_CHROME_INSETS) {
        const nextState = {
            ...createDefaultChromeInsetState(),
            source: `${reason}:disabled`,
            revision: Number.isFinite(globalThis.__manabiChromeInsetsRevision)
                ? globalThis.__manabiChromeInsetsRevision
                : 0,
        };
        globalThis.__manabiChromeInsets = nextState;
        applyResolvedChromeInsetState(nextState);
        return nextState;
    }

    const previousState = getStoredChromeInsetState();
    const storedPositiveState = getStoredPositiveChromeInsetState();
    const ancestorPositiveState = getAncestorChromeInsetState();
    let nextState = incomingState
        ? normalizeChromeInsetState(incomingState, reason)
        : previousState;

    if (!Number.isFinite(nextState.revision)) {
        nextState.revision = incomingState ? getNextChromeInsetRevision() : previousState.revision;
    } else {
        globalThis.__manabiChromeInsetsRevision = Math.max(
            Number.isFinite(globalThis.__manabiChromeInsetsRevision) ? globalThis.__manabiChromeInsetsRevision : 0,
            nextState.revision,
        );
    }

    if (!incomingState && !Number.isFinite(nextState.revision)) {
        nextState = createDefaultChromeInsetState();
    }

    const shouldInheritPositiveAncestorState =
        !incomingState &&
        parseChromeInsetPixelValue(nextState.obscuredTopInset) === 0 &&
        parseChromeInsetPixelValue(nextState.toolbarBottomOffset) === 0 &&
        parseChromeInsetPixelValue(nextState.obscuredBottomInset) === 0 &&
        !!ancestorPositiveState &&
        (
            parseChromeInsetPixelValue(ancestorPositiveState.obscuredTopInset) > 0 ||
            parseChromeInsetPixelValue(ancestorPositiveState.toolbarBottomOffset) > 0 ||
            parseChromeInsetPixelValue(ancestorPositiveState.obscuredBottomInset) > 0
        );

    if (shouldInheritPositiveAncestorState) {
        nextState = {
            ...ancestorPositiveState,
            source: `${ancestorPositiveState.source}->inherited`,
        };
    }

    const incomingWouldZeroPositiveState =
        !!incomingState &&
        parseChromeInsetPixelValue(nextState.obscuredTopInset) === 0 &&
        parseChromeInsetPixelValue(nextState.toolbarBottomOffset) === 0 &&
        parseChromeInsetPixelValue(nextState.obscuredBottomInset) === 0 &&
        (
            parseChromeInsetPixelValue(storedPositiveState.obscuredTopInset) > 0 ||
            parseChromeInsetPixelValue(storedPositiveState.toolbarBottomOffset) > 0 ||
            parseChromeInsetPixelValue(storedPositiveState.obscuredBottomInset) > 0
        );

    if (incomingWouldZeroPositiveState) {
        const shortOverwriteLog = {
            reason,
            message: 'preserved existing non-zero inset over zero candidate',
            attemptedObscuredTopInset: nextState.obscuredTopInset,
            attemptedToolbarBottomOffset: nextState.toolbarBottomOffset,
            attemptedObscuredBottomInset: nextState.obscuredBottomInset,
            lastPositiveObscuredTopInset: storedPositiveState.obscuredTopInset,
            lastPositiveToolbarBottomOffset: storedPositiveState.toolbarBottomOffset,
            lastPositiveObscuredBottomInset: storedPositiveState.obscuredBottomInset,
            attemptedSource: nextState.source,
            attemptedRevision: nextState.revision,
        };
        const overwriteLog = {
            reason,
            attemptedState: nextState,
            previousState,
            storedPositiveState,
        };
        const overwriteKey = JSON.stringify(overwriteLog);
        if (globalThis.__manabiLastChromeInsetsOverwriteLogKey !== overwriteKey) {
            globalThis.__manabiLastChromeInsetsOverwriteLogKey = overwriteKey;
        }
    }

    globalThis.__manabiChromeInsets = nextState;
    if (
        parseChromeInsetPixelValue(nextState.obscuredTopInset) > 0 ||
        parseChromeInsetPixelValue(nextState.toolbarBottomOffset) > 0 ||
        parseChromeInsetPixelValue(nextState.obscuredBottomInset) > 0
    ) {
        globalThis.__manabiLastPositiveChromeInsets = nextState;
    }
    applyResolvedChromeInsetState(nextState);
    scheduleReaderUIChromeInsetSettle(reason, nextState);
    postReaderUILayoutSnapshot('chromeInsets.applied', {
        reason,
        incomingObscuredTopInset: incomingState?.obscuredTopInset ?? null,
        appliedObscuredTopInset: nextState.obscuredTopInset,
        appliedToolbarBottomOffset: nextState.toolbarBottomOffset,
        appliedObscuredBottomInset: nextState.obscuredBottomInset,
        source: nextState.source,
        revision: nextState.revision,
    });
    if (reason === 'native-sync' || reason === 'reader.open' || reason === 'reader.didDisplay' || reason === 'setEbookViewerLayout') {
        postEBookSafeAreaTopSnapshot('ebook.safeAreaTop.chromeInsetsApplied', {
            reason,
            incomingObscuredTopInset: incomingState?.obscuredTopInset ?? null,
            appliedObscuredTopInset: nextState.obscuredTopInset,
            appliedToolbarBottomOffset: nextState.toolbarBottomOffset,
            appliedObscuredBottomInset: nextState.obscuredBottomInset,
            source: nextState.source,
            revision: nextState.revision,
            inheritedAncestorSource: shouldInheritPositiveAncestorState ? ancestorPositiveState?.source ?? null : null,
        });
    }
    const landscapeInsetKey = JSON.stringify({
        appliedObscuredTopInset: nextState.obscuredTopInset,
        appliedToolbarBottomOffset: nextState.toolbarBottomOffset,
        appliedObscuredBottomInset: nextState.obscuredBottomInset,
        source: nextState.source,
        inheritedAncestorSource: shouldInheritPositiveAncestorState ? ancestorPositiveState?.source ?? null : null,
    });
    const shouldLogAppliedInsetChange =
        reason === 'reader.didDisplay' && (
            parseChromeInsetPixelValue(nextState.obscuredTopInset) > 0 ||
            parseChromeInsetPixelValue(nextState.toolbarBottomOffset) > 0 ||
            parseChromeInsetPixelValue(nextState.obscuredBottomInset) > 0 ||
            shouldInheritPositiveAncestorState
        );
    if (shouldLogAppliedInsetChange && globalThis.__manabiLastLandscapeInsetLogKey !== landscapeInsetKey) {
        globalThis.__manabiLastLandscapeInsetLogKey = landscapeInsetKey;
    }
    const chromeInsetsLog = {
        reason,
        locationHref: globalThis.location?.href ?? null,
        topLocationHref: (() => {
            try {
                return window.top?.location?.href ?? null;
            } catch {
                return null;
            }
        })(),
        isTopWindow: (() => {
            try {
                return window.top === window;
            } catch {
                return null;
            }
        })(),
        toolbarBottomOffset: nextState.toolbarBottomOffset,
        obscuredTopInset: nextState.obscuredTopInset,
        obscuredBottomInset: nextState.obscuredBottomInset,
        source: nextState.source,
        revision: nextState.revision,
        inheritedAncestorSource: shouldInheritPositiveAncestorState ? ancestorPositiveState?.source ?? null : null,
        inheritedAncestorObscuredTopInset: shouldInheritPositiveAncestorState ? ancestorPositiveState?.obscuredTopInset ?? null : null,
        inheritedAncestorToolbarBottomOffset: shouldInheritPositiveAncestorState ? ancestorPositiveState?.toolbarBottomOffset ?? null : null,
        inheritedAncestorObscuredBottomInset: shouldInheritPositiveAncestorState ? ancestorPositiveState?.obscuredBottomInset ?? null : null,
        ancestorPositiveObscuredTopInset: ancestorPositiveState?.obscuredTopInset ?? null,
        ancestorPositiveToolbarBottomOffset: ancestorPositiveState?.toolbarBottomOffset ?? null,
        ancestorPositiveObscuredBottomInset: ancestorPositiveState?.obscuredBottomInset ?? null,
        ancestorPositiveSource: ancestorPositiveState?.source ?? null,
        incomingState: incomingState ? normalizeChromeInsetState(incomingState, reason) : null,
        previousState,
        bodyReady: !!document.body,
    };
    const shouldLogChromeInsets = !!globalThis.manabiVerboseLayout;
    const chromeInsetsKey = shouldLogChromeInsets ? JSON.stringify(chromeInsetsLog) : null;
    if (shouldLogChromeInsets && globalThis.__manabiLastChromeInsetsLogKey !== chromeInsetsKey) {
        globalThis.__manabiLastChromeInsetsLogKey = chromeInsetsKey;
    }
    return nextState;
};

window.manabiApplyChromeInsets = (rawState, reason = 'window.manabiApplyChromeInsets') => {
    const nextState = applyStoredChromeInsets(reason, rawState);
    return nextState;
};

document.addEventListener('DOMContentLoaded', () => {
    applyStoredChromeInsets('dom-content-loaded');
});

window.addEventListener('load', () => {
    applyStoredChromeInsets('window-load');
});

const safeRound = (value, digits = 1) =>
    typeof value === 'number' && Number.isFinite(value)
        ? Number(value.toFixed(digits))
        : null;

const getAuthoritativeReaderFraction = ({ navHUD = null, detail = null, fallbackFraction = null } = {}) => {
    const primaryLabelFraction = navHUD?.lastPrimaryLabelDiagnostics?.fraction ?? null;
    if (typeof primaryLabelFraction === 'number' && Number.isFinite(primaryLabelFraction)) {
        return Math.max(0, Math.min(1, primaryLabelFraction));
    }
    const scrubberFraction = navHUD?.getScrubberFraction?.(detail ?? null) ?? null;
    if (typeof scrubberFraction === 'number' && Number.isFinite(scrubberFraction)) {
        return Math.max(0, Math.min(1, scrubberFraction));
    }
    if (typeof fallbackFraction === 'number' && Number.isFinite(fallbackFraction)) {
        return Math.max(0, Math.min(1, fallbackFraction));
    }
    return null;
};

const performanceNowMs = () =>
    typeof performance !== 'undefined' && typeof performance.now === 'function'
        ? performance.now()
        : Date.now();

globalThis.__manabiPerformanceNowMs = performanceNowMs;
globalThis.__manabiSafeRound = safeRound;

const summarizeRect = (rect) => {
    if (!rect) return null;
    return {
        left: safeRound(rect.left),
        top: safeRound(rect.top),
        right: safeRound(rect.right),
        bottom: safeRound(rect.bottom),
        width: safeRound(rect.width),
        height: safeRound(rect.height),
    };
};

const summarizeElementLayout = (element) => {
    if (!element || element.nodeType !== 1) {
        return null;
    }
    const ownerWindow = element.ownerDocument?.defaultView || window;
    const rect = summarizeRect(element.getBoundingClientRect?.());
    const style = ownerWindow.getComputedStyle?.(element);
    const hiddenAttr = element.hasAttribute?.('hidden') ?? false;
    const ariaHidden = element.getAttribute?.('aria-hidden');
    const text = (element.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 160);
    return {
        hiddenAttr,
        ariaHidden: ariaHidden ?? null,
        display: style?.display ?? null,
        visibility: style?.visibility ?? null,
        opacity: safeRound(Number(style?.opacity)),
        pointerEvents: style?.pointerEvents ?? null,
        overflowX: style?.overflowX ?? null,
        overflowY: style?.overflowY ?? null,
        position: style?.position ?? null,
        top: style?.top ?? null,
        bottom: style?.bottom ?? null,
        left: style?.left ?? null,
        right: style?.right ?? null,
        heightCSS: style?.height ?? null,
        minHeightCSS: style?.minHeight ?? null,
        maxHeightCSS: style?.maxHeight ?? null,
        lineHeight: style?.lineHeight ?? null,
        fontSize: style?.fontSize ?? null,
        paddingTop: style?.paddingTop ?? null,
        paddingBottom: style?.paddingBottom ?? null,
        marginTop: style?.marginTop ?? null,
        marginBottom: style?.marginBottom ?? null,
        contain: style?.contain ?? null,
        boxSizing: style?.boxSizing ?? null,
        text,
        clientWidth: element.clientWidth ?? null,
        clientHeight: element.clientHeight ?? null,
        scrollWidth: element.scrollWidth ?? null,
        scrollHeight: element.scrollHeight ?? null,
        offsetWidth: element instanceof HTMLElement ? element.offsetWidth : null,
        offsetHeight: element instanceof HTMLElement ? element.offsetHeight : null,
        rect,
    };
};

const summarizeFoliateViewLayout = (_view) => null;

const postReaderVisibilityProbe = (_stage, _view = null, _extra = null) => {};

const isDocumentLike = (value) =>
    !!value
    && value.nodeType === 9
    && typeof value.querySelectorAll === 'function'
    && !!value.documentElement;

const parseEntryIDs = (rawValue) => {
    if (typeof rawValue !== 'string' || rawValue.length === 0) {
        return [];
    }
    try {
        const parsed = JSON.parse(rawValue);
        return Array.isArray(parsed) ? parsed : [];
    } catch (_error) {
        return [];
    }
};

// Mirrors manabi_reader.js sidecar expansion. The HTML sidecar stores table-compressed
// segment tuples so EPUB sections do not repeat large lookup attrs thousands of times.
const segmentMetadataSidecarSnapshot = (doc) => {
    const primarySidecar = typeof doc?.getElementById === 'function'
        ? doc.getElementById('mnb-segment-metadata')
        : null;
    let sidecars = primarySidecar
        ? [primarySidecar]
        : Array.from(doc?.getElementsByTagName?.('script') || [])
            .filter((script) => script?.hasAttribute?.('data-mnb-seg-meta'));
    const externalEntry = primarySidecar ? null : (doc?.manabiExternalSegmentSidecar ?? null);
    if (sidecars.length === 0 && externalEntry?.sidecar) {
        sidecars = [externalEntry.sidecar];
    }
    const sidecarTexts = sidecars.map((sidecar) => sidecar.textContent || '');
    const sidecarSignature = externalEntry?.signature
        ? `external:${externalEntry.signature}`
        : sidecarTexts.map((text) => String(text.length)).join('|');
    return { sidecars, sidecarTexts, sidecarSignature };
};

const segmentMetadataSidecarsMatchCache = (doc, snapshot) => (
    Array.isArray(doc?.manabiSegmentMetadataSidecars)
    && Array.isArray(doc?.manabiSegmentMetadataSidecarTexts)
    && doc.manabiSegmentMetadataSidecars.length === snapshot.sidecars.length
    && doc.manabiSegmentMetadataSidecarTexts.length === snapshot.sidecarTexts.length
    && doc.manabiSegmentMetadataSidecarTexts.every((text, index) => text === snapshot.sidecarTexts[index])
);

const cacheSegmentMetadataSidecarSnapshot = (doc, snapshot) => {
    doc.manabiSegmentMetadataSidecars = snapshot.sidecars;
    doc.manabiSegmentMetadataSidecarTexts = snapshot.sidecarTexts;
    doc.manabiSegmentMetadataSidecarSignature = snapshot.sidecarSignature;
};

const segmentMetadataPayloadsForSnapshot = (doc, snapshot) => {
    const hasMatchingSidecars =
        doc.manabiSegmentMetadataSidecarSignature === snapshot.sidecarSignature
        && segmentMetadataSidecarsMatchCache(doc, snapshot);
    if (hasMatchingSidecars && Array.isArray(doc.manabiSegmentMetadataSidecarPayloads)) {
        return doc.manabiSegmentMetadataSidecarPayloads;
    }
    const payloads = snapshot.sidecars.map((sidecar) => {
        try {
            return JSON.parse(sidecar.textContent || '{}');
        } catch (_error) {
            return null;
        }
    });
    doc.manabiSegmentMetadataSidecarPayloads = payloads;
    cacheSegmentMetadataSidecarSnapshot(doc, snapshot);
    return payloads;
};

const resetSegmentMetadataCachesForSnapshot = (doc, snapshot) => {
    doc.manabiSegmentMetadataByID = new Map();
    doc.manabiSegmentIDsByEntryID = new Map();
    doc.manabiSegmentMetadataSidecarPayloads = null;
    doc.manabiSegmentMetadataFullyBootstrapped = false;
    cacheSegmentMetadataSidecarSnapshot(doc, snapshot);
};

const segmentMetadataTableValue = (table, index, fallback = null) => (
    Number.isInteger(index) && Array.isArray(table) && index >= 0 && index < table.length
        ? table[index]
        : fallback
);

const expandSegmentIDToken = (token, version) => {
    if (typeof token !== 'string' || token.length === 0) return null;
    if (version === 3) return token.startsWith('!') ? token.slice(1) : `mnb-s${token}`;
    return token;
};

const segmentMetadataTableArray = (tables, shortKey, longKey) => (
    Array.isArray(tables?.[shortKey])
        ? tables[shortKey]
        : (Array.isArray(tables?.[longKey]) ? tables[longKey] : [])
);

const compactSegmentMetadataTables = (compactTables) => ({
    h: segmentMetadataTableArray(compactTables, 'h', 'segmentHashes'),
    sid: segmentMetadataTableArray(compactTables, 'sid', 'stableIDs'),
    j: segmentMetadataTableArray(compactTables, 'j', 'jmdictEntryIDs'),
    n: segmentMetadataTableArray(compactTables, 'n', 'jmnedictEntryIDs'),
    s: segmentMetadataTableArray(compactTables, 's', 'jmdictSearchStrings'),
    ns: segmentMetadataTableArray(compactTables, 'ns', 'jmnedictSearchStrings'),
    p: segmentMetadataTableArray(compactTables, 'p', 'partsOfSpeech'),
});

const segmentMetadataFromCompactTuple = (segment, tables, version) => {
    const segmentHash = version === 3
        ? segmentMetadataTableValue(tables.h, segment?.[1], null)
        : segment?.[1];
    const stableSegmentIdentifier = version === 3
        ? segmentMetadataTableValue(tables.sid, segment?.[8], segmentHash)
        : segmentHash;
    return {
        i: expandSegmentIDToken(segment?.[0], version),
        h: segmentHash,
        sid: stableSegmentIdentifier,
        j: segmentMetadataTableValue(tables.j, segment?.[2], []),
        n: segmentMetadataTableValue(tables.n, segment?.[3], []),
        s: segmentMetadataTableValue(tables.s, segment?.[4], null),
        ns: segmentMetadataTableValue(tables.ns, segment?.[5], null),
        p: segmentMetadataTableValue(tables.p, segment?.[6], null),
        l: segment?.[7],
    };
};

const segmentMetadataFromLegacyEntry = (segment) => ({
    i: typeof segment?.i === 'string' ? segment.i : null,
    h: typeof segment?.h === 'string' ? segment.h : null,
    sid: typeof segment?.h === 'string' ? segment.h : (typeof segment?.sid === 'string' ? segment.sid : null),
    j: Array.isArray(segment?.j) ? segment.j : [],
    n: Array.isArray(segment?.n) ? segment.n : [],
    s: typeof segment?.s === 'string' ? segment.s : null,
    ns: typeof segment?.ns === 'string' ? segment.ns : null,
    p: typeof segment?.p === 'string' ? segment.p : null,
    l: Number.isInteger(segment?.l) ? segment.l : null,
});

const expandSegmentMetadataPayload = (payload) => {
    const version = payload?.v ?? payload?.version;
    const compactTables = payload?.t ?? payload?.tables;
    const compactSegments = Array.isArray(payload?.s) ? payload.s : payload?.segments;
    if ((version === 2 || version === 3) && compactTables && Array.isArray(compactSegments)) {
        const tables = compactSegmentMetadataTables(compactTables);
        return compactSegments.map((segment) => segmentMetadataFromCompactTuple(segment, tables, version));
    }
    if (Array.isArray(payload)) {
        return payload.map(segmentMetadataFromLegacyEntry);
    }
    return [];
};

const segmentMetadataPayloadLookupState = (payload) => {
    if (!payload || typeof payload !== 'object') return null;
    if (payload.__manabiSegmentMetadataLookupState) {
        return payload.__manabiSegmentMetadataLookupState;
    }
    const state = {
        byID: new Map(),
        scannedThrough: -1,
        complete: false,
    };
    try {
        Object.defineProperty(payload, '__manabiSegmentMetadataLookupState', {
            value: state,
            configurable: true,
        });
    } catch (_error) {
        payload.__manabiSegmentMetadataLookupState = state;
    }
    return state;
};

const findSegmentMetadataInPayload = (payload, segmentID) => {
    const cacheSegmentMetadataAliases = (metadata, index, state) => {
        if (!state?.byID || !metadata) return;
        for (const alias of [metadata.i, metadata.sid]) {
            if (typeof alias === 'string' && alias.length > 0 && !state.byID.has(alias)) {
                state.byID.set(alias, index);
            }
        }
    };
    const version = payload?.v ?? payload?.version;
    const compactTables = payload?.t ?? payload?.tables;
    const compactSegments = Array.isArray(payload?.s) ? payload.s : payload?.segments;
    if ((version === 2 || version === 3) && compactTables && Array.isArray(compactSegments)) {
        const tables = compactSegmentMetadataTables(compactTables);
        const state = segmentMetadataPayloadLookupState(payload);
        if (state?.byID?.has(segmentID)) {
            const cachedIndex = state.byID.get(segmentID);
            const cachedSegment = compactSegments[cachedIndex];
            return cachedSegment ? segmentMetadataFromCompactTuple(cachedSegment, tables, version) : null;
        }
        if (state?.complete === true) {
            return null;
        }
        for (let index = (state?.scannedThrough ?? -1) + 1; index < compactSegments.length; index += 1) {
            const segment = compactSegments[index];
            const metadata = segmentMetadataFromCompactTuple(segment, tables, version);
            cacheSegmentMetadataAliases(metadata, index, state);
            if (state) state.scannedThrough = index;
            if (metadata?.i !== segmentID && metadata?.sid !== segmentID) continue;
            return metadata;
        }
        if (state) state.complete = true;
        return null;
    }
    if (Array.isArray(payload)) {
        const state = segmentMetadataPayloadLookupState(payload);
        if (state?.byID?.has(segmentID)) {
            const cachedIndex = state.byID.get(segmentID);
            const cachedSegment = payload[cachedIndex];
            return cachedSegment ? segmentMetadataFromLegacyEntry(cachedSegment) : null;
        }
        if (state?.complete === true) {
            return null;
        }
        for (let index = (state?.scannedThrough ?? -1) + 1; index < payload.length; index += 1) {
            const segment = payload[index];
            const metadata = segmentMetadataFromLegacyEntry(segment);
            cacheSegmentMetadataAliases(metadata, index, state);
            if (state) state.scannedThrough = index;
            if (metadata?.i !== segmentID && metadata?.sid !== segmentID) continue;
            return metadata;
        }
        if (state) state.complete = true;
    }
    return null;
};

const lazySegmentMetadataByID = (doc, snapshot) => {
    const hasMatchingSidecars =
        doc.manabiSegmentMetadataSidecarSignature === snapshot.sidecarSignature
        && segmentMetadataSidecarsMatchCache(doc, snapshot);
    if (!hasMatchingSidecars) {
        resetSegmentMetadataCachesForSnapshot(doc, snapshot);
    } else if (!(doc.manabiSegmentMetadataByID instanceof Map)) {
        doc.manabiSegmentMetadataByID = new Map();
    }
    return doc.manabiSegmentMetadataByID;
};

const segmentMetadataBootstrap = (doc) => {
    if (!doc) {
        return { byID: new Map(), idsByEntryID: new Map() };
    }
    const snapshot = segmentMetadataSidecarSnapshot(doc);
    if (
        doc.manabiSegmentMetadataFullyBootstrapped === true
        && doc.manabiSegmentMetadataByID
        && doc.manabiSegmentMetadataSidecarSignature === snapshot.sidecarSignature
        && segmentMetadataSidecarsMatchCache(doc, snapshot)
    ) {
        return {
            byID: doc.manabiSegmentMetadataByID,
            idsByEntryID: doc.manabiSegmentIDsByEntryID || new Map(),
        };
    }
    const byID = new Map();
    const idsByEntryID = new Map();
    const indexEntryIDs = (segmentID, entryIDs) => {
        for (const entryID of entryIDs || []) {
            if (typeof entryID !== 'number' || !Number.isFinite(entryID)) continue;
            const key = String(entryID);
            if (!idsByEntryID.has(key)) idsByEntryID.set(key, new Set());
            idsByEntryID.get(key).add(segmentID);
        }
    };
    for (const payload of segmentMetadataPayloadsForSnapshot(doc, snapshot)) {
        for (const segment of expandSegmentMetadataPayload(payload)) {
            if (!segment?.i) continue;
            byID.set(segment.i, segment);
            if (typeof segment.sid === 'string' && segment.sid.length > 0) {
                byID.set(segment.sid, segment);
            }
            indexEntryIDs(segment.i, segment.j);
            indexEntryIDs(segment.i, segment.n);
            indexEntryIDs(segment.sid, segment.j);
            indexEntryIDs(segment.sid, segment.n);
        }
    }
    doc.manabiSegmentMetadataByID = byID;
    doc.manabiSegmentIDsByEntryID = idsByEntryID;
    doc.manabiSegmentMetadataFullyBootstrapped = true;
    cacheSegmentMetadataSidecarSnapshot(doc, snapshot);
    return { byID, idsByEntryID };
};

const segmentMetadataForNode = (segmentNode) => {
    if (!segmentNode) return null;
    const doc = segmentNode.ownerDocument || document;
    const segmentID = segmentNode.id;
    if (typeof segmentID !== 'string' || segmentID.length === 0 || !doc) return null;
    const snapshot = segmentMetadataSidecarSnapshot(doc);
    const byID = lazySegmentMetadataByID(doc, snapshot);
    if (byID.has(segmentID)) {
        return byID.get(segmentID) || null;
    }
    if (
        doc.manabiSegmentMetadataFullyBootstrapped === true
        && doc.manabiSegmentMetadataSidecarSignature === snapshot.sidecarSignature
        && segmentMetadataSidecarsMatchCache(doc, snapshot)
    ) {
        return null;
    }
    for (const payload of segmentMetadataPayloadsForSnapshot(doc, snapshot)) {
        const metadata = findSegmentMetadataInPayload(payload, segmentID);
        if (!metadata?.i) continue;
        byID.set(segmentID, metadata);
        return metadata;
    }
    return null;
};

const segmentEntryIDsForNode = (segmentNode, kind = 'primary') => {
    const metadata = segmentMetadataForNode(segmentNode);
    const jmdictEntryIds = Array.isArray(metadata?.j) ? metadata.j : [];
    const jmnedictEntryIds = Array.isArray(metadata?.n) ? metadata.n : [];
    if (kind === 'jmdict') return jmdictEntryIds;
    if (kind === 'jmnedict') return jmnedictEntryIds;
    return jmdictEntryIds.length ? jmdictEntryIds : jmnedictEntryIds;
};

const normalizeArticleReadingProgress = (articleReadingProgress = {}) => ({
    sentenceIdentifiersRead: Array.isArray(articleReadingProgress?.sentenceIdentifiersRead)
        ? articleReadingProgress.sentenceIdentifiersRead
        : [],
    readSegmentIdentifiers: Array.isArray(articleReadingProgress?.readSegmentIdentifiers)
        ? articleReadingProgress.readSegmentIdentifiers
        : [],
    articleSentenceCount: Number.isFinite(articleReadingProgress?.articleSentenceCount)
        ? articleReadingProgress.articleSentenceCount
        : null,
    articleMarkedAsFinished: !!articleReadingProgress?.articleMarkedAsFinished,
});

const sentenceIdentifierForNode = (sentenceNode) => {
    return ebookSentenceIdentifier(sentenceNode);
};

const segmentIdentityForNode = (segmentNode) => {
    const metadata = segmentMetadataForNode(segmentNode);
    return ebookSegmentIdentity(segmentNode, metadata);
};

const segmentIdentifierForNode = (segmentNode) => {
    return segmentIdentityForNode(segmentNode).segmentIdentifier;
};

const segmentIdentifierAliasesForNode = (segmentNode) => {
    const metadata = segmentMetadataForNode(segmentNode);
    return ebookSegmentIdentifierAliases(segmentNode, metadata);
};

const buildExampleSentenceForSegment = (segmentNode) => {
    const sentenceNode = segmentNode?.closest?.('mnb-sen');
    if (!(sentenceNode instanceof Element)) {
        return {
            sentenceHTML: null,
            sentenceJMDictIDs: null,
        };
    }
    const sentenceJMDictIDs = new Set();
    for (const nestedSegment of sentenceNode.querySelectorAll('mnb-seg')) {
        for (const entryID of segmentEntryIDsForNode(nestedSegment, 'jmdict')) {
            sentenceJMDictIDs.add(entryID);
        }
    }
    return {
        sentenceHTML: sentenceNode.outerHTML,
        sentenceJMDictIDs: sentenceJMDictIDs.size > 0 ? Array.from(sentenceJMDictIDs) : null,
    };
};

const rectHasPositiveFiniteSize = (rect) => {
    return Number.isFinite(rect?.left)
        && Number.isFinite(rect?.top)
        && Number.isFinite(rect?.right)
        && Number.isFinite(rect?.bottom)
        && Number.isFinite(rect?.width)
        && Number.isFinite(rect?.height)
        && rect.width > 0
        && rect.height > 0;
};

const rectIntersectsViewport = (rect, viewportWidth, viewportHeight) => {
    if (!rectHasPositiveFiniteSize(rect)
        || !Number.isFinite(viewportWidth)
        || !Number.isFinite(viewportHeight)) {
        return false;
    }
    return rect.right > 0
        && rect.bottom > 0
        && rect.left < viewportWidth
        && rect.top < viewportHeight;
};

const rectIntersectsBounds = (rect, bounds) => {
    if (!rectHasPositiveFiniteSize(rect)
        || !Number.isFinite(bounds?.left)
        || !Number.isFinite(bounds?.top)
        || !Number.isFinite(bounds?.right)
        || !Number.isFinite(bounds?.bottom)) {
        return false;
    }
    return rect.right > bounds.left
        && rect.bottom > bounds.top
        && rect.left < bounds.right
        && rect.top < bounds.bottom;
};

const positiveBoundingClientRectForNode = (node) => {
    if (typeof node?.getBoundingClientRect !== 'function') {
        return null;
    }
    const rect = node.getBoundingClientRect();
    return rect && rect.width > 0 && rect.height > 0 ? rect : null;
};

const positiveClientRectsForNode = (node) => {
    if (typeof node?.getClientRects === 'function') {
        const rects = Array.from(node.getClientRects()).filter((rect) => rect && rect.width > 0 && rect.height > 0);
        if (rects.length > 0) {
            return rects;
        }
    }
    const doc = node?.ownerDocument ?? null;
    if (doc?.createRange && node?.childNodes?.length > 0) {
        const range = doc.createRange();
        try {
            range.selectNodeContents(node);
            const rects = Array.from(range.getClientRects?.() ?? [])
                .filter((rect) => rect && rect.width > 0 && rect.height > 0);
            if (rects.length > 0) {
                return rects;
            }
        } catch (_error) {
            // ignore unmeasurable nodes
        } finally {
            range.detach?.();
        }
    }
    const boundingRect = positiveBoundingClientRectForNode(node);
    return boundingRect ? [boundingRect] : [];
};

const visibleClientRectsForNode = (node, bounds) => {
    const boundingRect = positiveBoundingClientRectForNode(node);
    if (!rectIntersectsBounds(boundingRect, bounds)) {
        return [];
    }
    return positiveClientRectsForNode(node).filter((rect) => rectIntersectsBounds(rect, bounds));
};

const viewportBoundsForReaderDocument = (doc) => {
    const frameElement = doc?.defaultView?.frameElement ?? null;
    if (frameElement instanceof HTMLIFrameElement) {
        const viewElement = frameElement.parentElement;
        const paginatorContainer = viewElement?.parentElement ?? null;
        const hasExpectedPaginatorContainer = paginatorContainer?.id === 'container';
        const containerRect = hasExpectedPaginatorContainer
            ? paginatorContainer.getBoundingClientRect()
            : null;
        const frameRect = frameElement.getBoundingClientRect();
        const hasGeometry = containerRect
            && frameRect
            && Number.isFinite(containerRect.width)
            && Number.isFinite(containerRect.height)
            && Number.isFinite(frameRect.left)
            && Number.isFinite(frameRect.top)
            && containerRect.width > 0
            && containerRect.height > 0;
        if (!hasGeometry) {
        return {
            viewportWidth: 0,
            viewportHeight: 0,
            viewportLeft: 0,
            viewportTop: 0,
            visibleBounds: null,
            frameRect,
            containerRect,
                hasExpectedPaginatorContainer,
            };
        }
        return {
            viewportWidth: containerRect.width,
            viewportHeight: containerRect.height,
            viewportLeft: containerRect.left,
            viewportTop: containerRect.top,
            visibleBounds: {
                left: containerRect.left - frameRect.left,
                top: containerRect.top - frameRect.top,
                right: containerRect.right - frameRect.left,
                bottom: containerRect.bottom - frameRect.top,
            },
            frameRect,
            containerRect,
            hasExpectedPaginatorContainer,
        };
    }
    const viewportWidth = doc?.documentElement?.clientWidth || doc?.defaultView?.innerWidth || 0;
    const viewportHeight = doc?.documentElement?.clientHeight || doc?.defaultView?.innerHeight || 0;
    return {
        viewportWidth,
        viewportHeight,
        viewportLeft: 0,
        viewportTop: 0,
        visibleBounds: {
            left: 0,
            top: 0,
            right: viewportWidth,
            bottom: viewportHeight,
        },
        frameRect: null,
        containerRect: null,
        hasExpectedPaginatorContainer: null,
    };
};

const segmentOrderCacheByDocument = new WeakMap();

const isEbookContentDocument = (doc) => {
    const href = doc?.location?.href || doc?.URL || '';
    return doc?.defaultView?.manabi_isEbook === true
        || doc?.body?.dataset?.isEbook === 'true'
        || typeof doc?.body?.dataset?.mnbSourceHref === 'string'
        || href.startsWith('blob:ebook://')
        || href.startsWith('ebook://');
};

const orderedSegmentNodesForDocument = (doc) => {
    const cached = segmentOrderCacheByDocument.get(doc);
    if (cached?.root === doc.body) {
        return cached;
    }
    const nodes = Array.from(doc.querySelectorAll?.('mnb-seg') ?? []);
    const indexByNode = new Map();
    nodes.forEach((node, index) => {
        indexByNode.set(node, index);
    });
    const entry = {
        root: doc.body,
        nodes,
        indexByNode,
    };
    segmentOrderCacheByDocument.set(doc, entry);
    return entry;
};

const rangeBoundarySegmentIndex = (visibleRange, boundary, orderedSegments) => {
    const startElement = visibleRange.startContainer?.nodeType === Node.ELEMENT_NODE
        ? visibleRange.startContainer
        : visibleRange.startContainer?.parentElement;
    const endElement = visibleRange.endContainer?.nodeType === Node.ELEMENT_NODE
        ? visibleRange.endContainer
        : visibleRange.endContainer?.parentElement;
    const element = boundary === 'end' ? endElement : startElement;
    const directSegment = element?.closest?.('mnb-seg');
    if (directSegment && orderedSegments.indexByNode.has(directSegment)) {
        return orderedSegments.indexByNode.get(directSegment);
    }
    const sentence = element?.closest?.('mnb-sen');
    if (sentence?.nodeType === Node.ELEMENT_NODE) {
        const sentenceSegments = Array.from(sentence.querySelectorAll?.('mnb-seg') ?? []);
        const segment = boundary === 'end'
            ? sentenceSegments[sentenceSegments.length - 1]
            : sentenceSegments[0];
        if (segment && orderedSegments.indexByNode.has(segment)) {
            return orderedSegments.indexByNode.get(segment);
        }
    }
    return null;
};

const measureVisibleSegmentsInWindow = (segmentNodes, visibleRange, visibleBounds, {
    assumeInVisibleRange = false,
    includeSegmentMetadata = true,
} = {}) => {
    const visibleSegments = [];
    let hiddenTooltipCount = 0;
    let missingIdentifierCount = 0;
    let outOfViewportCount = 0;
    let visibleRangeCheckCount = 0;
    let visibleRangeErrorCount = 0;
    let rectMeasureCount = 0;
    let rectMeasureElapsedMs = 0;
    let rangeCheckElapsedMs = 0;
    for (const segmentNode of segmentNodes) {
        if (segmentNode.closest('.tippy-box')) {
            hiddenTooltipCount += 1;
            continue;
        }
        const runtimeSegmentIdentifier = segmentNode?.id || segmentNode?.getAttribute?.('id') || null;
        const segmentIdentifier = includeSegmentMetadata
            ? segmentIdentifierForNode(segmentNode)
            : runtimeSegmentIdentifier;
        if (!segmentIdentifier) {
            missingIdentifierCount += 1;
            continue;
        }
        const rectStartedAt = performance.now();
        const rects = visibleClientRectsForNode(segmentNode, visibleBounds);
        const rect = rects[0] ?? null;
        rectMeasureCount += 1;
        rectMeasureElapsedMs += performance.now() - rectStartedAt;
        let isInVisibleRange = assumeInVisibleRange;
        if (!assumeInVisibleRange) {
            const rangeStartedAt = performance.now();
            try {
                visibleRangeCheckCount += 1;
                isInVisibleRange = visibleRange.intersectsNode(segmentNode);
                rangeCheckElapsedMs += performance.now() - rangeStartedAt;
            } catch (_error) {
                visibleRangeErrorCount += 1;
                rangeCheckElapsedMs += performance.now() - rangeStartedAt;
            }
        }
        if (!isInVisibleRange || !rect) {
            outOfViewportCount += 1;
            continue;
        }
        const sentenceNode = segmentNode.closest('mnb-sen');
        visibleSegments.push({
            node: segmentNode,
            rect,
            rects,
            segmentIdentifier,
            segmentIdentifierAliases: includeSegmentMetadata
                ? segmentIdentifierAliasesForNode(segmentNode)
                : [runtimeSegmentIdentifier].filter(Boolean),
            sentenceIdentifier: sentenceIdentifierForNode(sentenceNode),
        });
    }
    return {
        visibleSegments,
        hiddenTooltipCount,
        missingIdentifierCount,
        outOfViewportCount,
        visibleRangeCheckCount,
        visibleRangeErrorCount,
        rectMeasureCount,
        rectMeasureElapsedMs,
        rangeCheckElapsedMs,
    };
};

const isBroadEbookRangeRoot = (root, doc) => {
    if (!root || !isEbookContentDocument(doc)) return false;
    if (root === doc || root === doc.body || root === doc.documentElement) return true;
    const tagName = root?.tagName?.toLowerCase?.() ?? '';
    return tagName === 'body' || tagName === 'html';
};

const collectExpandedRangeSegments = (doc, visibleRange, visibleBounds, {
    includeSegmentMetadata = true,
} = {}) => {
    if (!visibleRange || visibleRange.collapsed === true) {
        return null;
    }
    const commonAncestor = visibleRange.commonAncestorContainer;
    const commonAncestorElement = commonAncestor?.nodeType === Node.ELEMENT_NODE
        ? commonAncestor
        : commonAncestor?.parentElement;
    if (!isBroadEbookRangeRoot(commonAncestorElement, doc)) {
        const rangeSegmentNodes = collectSegmentNodesInVisibleRange(visibleRange);
        if (rangeSegmentNodes?.length > 0) {
            return {
                ...measureVisibleSegmentsInWindow(rangeSegmentNodes, visibleRange, visibleBounds, {
                    assumeInVisibleRange: true,
                    includeSegmentMetadata,
                }),
                segmentNodes: rangeSegmentNodes,
                segmentCandidateSource: 'sentinel-range',
                orderedSegmentCount: rangeSegmentNodes.length,
                boundedByWindow: true,
            };
        }
    }
    if (isEbookContentDocument(doc)) return null;

    const orderedSegments = orderedSegmentNodesForDocument(doc);
    const allSegmentNodes = orderedSegments.nodes;
    if (allSegmentNodes.length === 0) {
        return null;
    }
    const startIndex = rangeBoundarySegmentIndex(visibleRange, 'start', orderedSegments);
    const endIndex = rangeBoundarySegmentIndex(visibleRange, 'end', orderedSegments);
    if (!Number.isFinite(startIndex) && !Number.isFinite(endIndex)) {
        return null;
    }
    const anchorStart = Math.max(0, Math.min(startIndex ?? endIndex, endIndex ?? startIndex));
    const anchorEnd = Math.min(allSegmentNodes.length - 1, Math.max(startIndex ?? endIndex, endIndex ?? startIndex));
    const fullDocumentExpansion = Math.max(anchorStart, allSegmentNodes.length - 1 - anchorEnd);
    const expansionSizes = Array.from(new Set([32, 64, 128, 256, 512, fullDocumentExpansion]))
        .filter((value) => Number.isFinite(value) && value >= 0);
    let best = null;
    for (const expansionSize of expansionSizes) {
        const windowStart = Math.max(0, anchorStart - expansionSize);
        const windowEnd = Math.min(allSegmentNodes.length - 1, anchorEnd + expansionSize);
        const segmentNodes = allSegmentNodes.slice(windowStart, windowEnd + 1);
        const measured = measureVisibleSegmentsInWindow(segmentNodes, visibleRange, visibleBounds, {
            includeSegmentMetadata,
        });
        const visibleIndexes = measured.visibleSegments
            .map((item) => orderedSegments.indexByNode.get(item.node))
            .filter((index) => Number.isFinite(index));
        const firstVisibleIndex = visibleIndexes.length > 0 ? Math.min(...visibleIndexes) : null;
        const lastVisibleIndex = visibleIndexes.length > 0 ? Math.max(...visibleIndexes) : null;
        const hasLeadingMargin = firstVisibleIndex !== null && (firstVisibleIndex > windowStart || windowStart === 0);
        const hasTrailingMargin = lastVisibleIndex !== null && (lastVisibleIndex < windowEnd || windowEnd === allSegmentNodes.length - 1);
        best = {
            ...measured,
            segmentNodes,
            segmentCandidateSource: 'range-window',
            orderedSegmentCount: allSegmentNodes.length,
            anchorStart,
            anchorEnd,
            windowStart,
            windowEnd,
            expansionSize,
            firstVisibleIndex,
            lastVisibleIndex,
            boundedByWindow: hasLeadingMargin && hasTrailingMargin,
        };
        if (best.visibleSegments.length > 0 && best.boundedByWindow) {
            return best;
        }
    }
    return null;
};

const collectVisibleSegmentNodesFromRange = (doc, visibleRange = null, {
    viewportSampleDensity = 'normal',
    includeSegmentMetadata = true,
} = {}) => {
    if (!isDocumentLike(doc)) {
        return {
            visibleSegments: [],
            viewportWidth: 0,
            viewportHeight: 0,
            viewportLeft: 0,
            viewportTop: 0,
            totalSegmentCount: 0,
            hiddenTooltipCount: 0,
            missingIdentifierCount: 0,
            outOfViewportCount: 0,
        };
    }
    const startedAt = performance.now();
    const {
        viewportWidth,
        viewportHeight,
        viewportLeft,
        viewportTop,
        visibleBounds,
        frameRect,
        containerRect,
        hasExpectedPaginatorContainer,
    } = viewportBoundsForReaderDocument(doc);
    const useVisibleRange = !!visibleRange && visibleRange.collapsed !== true;
    const useViewportFallback = !useVisibleRange;
    if (visibleRange?.collapsed === true) {
    }
    const rangeCommonAncestor = visibleRange?.commonAncestorContainer ?? null;
    const rangeCommonAncestorElement = rangeCommonAncestor?.nodeType === Node.ELEMENT_NODE
        ? rangeCommonAncestor
        : (rangeCommonAncestor?.parentElement || null);
    const isEbookDoc = isEbookContentDocument(doc);
    const isBroadEbookRange = isEbookDoc && useVisibleRange
        && isBroadEbookRangeRoot(rangeCommonAncestorElement, doc);
    const expandedRangeResult = useVisibleRange
        ? collectExpandedRangeSegments(doc, visibleRange, visibleBounds, { includeSegmentMetadata })
        : null;
    const viewportSampleSegmentNodes = isEbookDoc && !expandedRangeResult
        ? collectViewportSampleSegmentNodes(doc, visibleBounds, { sampleDensity: viewportSampleDensity })
        : null;
    const boundedSegmentNodes = expandedRangeResult?.segmentNodes ?? viewportSampleSegmentNodes ?? null;
    const segmentSearchRoot = useVisibleRange && !expandedRangeResult && !isBroadEbookRange
        && rangeCommonAncestorElement?.querySelectorAll
        ? rangeCommonAncestorElement
        : doc;
    const allSegmentNodes = boundedSegmentNodes || (isEbookDoc && segmentSearchRoot === doc ? [] : [
            ...(segmentSearchRoot.matches?.('mnb-seg') ? [segmentSearchRoot] : []),
            ...Array.from(segmentSearchRoot.querySelectorAll?.('mnb-seg') ?? []),
        ]);
    const queryCompletedAt = performance.now();
    const ancestorSegmentCandidateCount = segmentSearchRoot === rangeCommonAncestorElement
        ? allSegmentNodes.length
        : null;
    const segmentCandidateSource = expandedRangeResult?.segmentCandidateSource
        || (viewportSampleSegmentNodes ? `viewport-sample-${viewportSampleDensity}` : null)
        || (isBroadEbookRange ? 'ebook-broad-range-empty' : null)
        || (isEbookDoc && segmentSearchRoot === doc ? 'ebook-bounded-empty' : null)
        || (segmentSearchRoot === doc ? 'document' : 'range-ancestor');
    const visibleSegments = expandedRangeResult?.visibleSegments ? [...expandedRangeResult.visibleSegments] : [];
    let totalSegmentCount = expandedRangeResult ? allSegmentNodes.length : 0;
    let hiddenTooltipCount = expandedRangeResult?.hiddenTooltipCount ?? 0;
    let missingIdentifierCount = expandedRangeResult?.missingIdentifierCount ?? 0;
    let outOfViewportCount = expandedRangeResult?.outOfViewportCount ?? 0;
    let visibleRangeCheckCount = expandedRangeResult?.visibleRangeCheckCount ?? 0;
    let visibleRangeErrorCount = expandedRangeResult?.visibleRangeErrorCount ?? 0;
    let rectMeasureCount = expandedRangeResult?.rectMeasureCount ?? 0;
    let rectMeasureElapsedMs = expandedRangeResult?.rectMeasureElapsedMs ?? 0;
    let rangeCheckElapsedMs = expandedRangeResult?.rangeCheckElapsedMs ?? 0;
    for (const segmentNode of expandedRangeResult ? [] : allSegmentNodes) {
        totalSegmentCount += 1;
        if (segmentNode.closest('.tippy-box')) {
            hiddenTooltipCount += 1;
            continue;
        }
        const runtimeSegmentIdentifier = segmentNode?.id || segmentNode?.getAttribute?.('id') || null;
        const segmentIdentifier = includeSegmentMetadata
            ? segmentIdentifierForNode(segmentNode)
            : runtimeSegmentIdentifier;
        if (!segmentIdentifier) {
            missingIdentifierCount += 1;
            continue;
        }
        const rectStartedAt = performance.now();
        const rects = visibleClientRectsForNode(segmentNode, visibleBounds);
        const rect = rects[0] ?? null;
        rectMeasureCount += 1;
        rectMeasureElapsedMs += performance.now() - rectStartedAt;
        const isInVisibleRange = useVisibleRange
            ? (() => {
                const rangeStartedAt = performance.now();
                try {
                    visibleRangeCheckCount += 1;
                    const didIntersect = visibleRange.intersectsNode(segmentNode);
                    rangeCheckElapsedMs += performance.now() - rangeStartedAt;
                    return didIntersect;
                } catch (_error) {
                    visibleRangeErrorCount += 1;
                    rangeCheckElapsedMs += performance.now() - rangeStartedAt;
                    return false;
                }
            })()
            : (useViewportFallback && !!rect);
        if (!isInVisibleRange) {
            outOfViewportCount += 1;
            continue;
        }
        const sentenceNode = segmentNode.closest('mnb-sen');
        visibleSegments.push({
            node: segmentNode,
            rect,
            rects,
            segmentIdentifier,
            segmentIdentifierAliases: includeSegmentMetadata
                ? segmentIdentifierAliasesForNode(segmentNode)
                : [runtimeSegmentIdentifier].filter(Boolean),
            sentenceIdentifier: sentenceIdentifierForNode(sentenceNode),
        });
    }
    if (!isEbookDoc && useVisibleRange && visibleSegments.length === 0 && totalSegmentCount > 0) {
        const fallbackStartedAt = performance.now();
        const fallbackSegments = [];
        let fallbackHiddenTooltipCount = 0;
        let fallbackMissingIdentifierCount = 0;
        let fallbackOutOfViewportCount = 0;
        let fallbackRectMeasureCount = 0;
        let fallbackRectMeasureElapsedMs = 0;
        for (const segmentNode of allSegmentNodes) {
            if (segmentNode.closest('.tippy-box')) {
                fallbackHiddenTooltipCount += 1;
                continue;
            }
            const segmentIdentifier = segmentIdentifierForNode(segmentNode);
            if (!segmentIdentifier) {
                fallbackMissingIdentifierCount += 1;
                continue;
            }
            const rectStartedAt = performance.now();
            const rects = visibleClientRectsForNode(segmentNode, visibleBounds);
            const rect = rects[0] ?? null;
            fallbackRectMeasureCount += 1;
            fallbackRectMeasureElapsedMs += performance.now() - rectStartedAt;
            if (!rect) {
                fallbackOutOfViewportCount += 1;
                continue;
            }
            const sentenceNode = segmentNode.closest('mnb-sen');
            fallbackSegments.push({
                node: segmentNode,
                rect,
                rects,
                segmentIdentifier,
                segmentIdentifierAliases: segmentIdentifierAliasesForNode(segmentNode),
                sentenceIdentifier: sentenceIdentifierForNode(sentenceNode),
            });
        }
        if (fallbackSegments.length > 0) {
            visibleSegments.push(...fallbackSegments);
            hiddenTooltipCount = fallbackHiddenTooltipCount;
            missingIdentifierCount = fallbackMissingIdentifierCount;
            outOfViewportCount = fallbackOutOfViewportCount;
        }
    }
    if (visibleRange?.collapsed === true) {
    }
    const completedAt = performance.now();
    return {
        visibleSegments,
        viewportWidth,
        viewportHeight,
        viewportLeft,
        viewportTop,
        frameLeft: Number.isFinite(frameRect?.left) ? frameRect.left : 0,
        frameTop: Number.isFinite(frameRect?.top) ? frameRect.top : 0,
        totalSegmentCount,
        segmentCandidateSource,
        viewportSampleCount: viewportSampleSegmentNodes?.length ?? 0,
        rectMeasureCount,
        includesSegmentMetadata: includeSegmentMetadata,
        hiddenTooltipCount,
        missingIdentifierCount,
        outOfViewportCount,
    };
};

const visibleSegmentCollectionDocumentIdentity = (doc) => ({
    documentURL: doc?.location?.href || doc?.URL || null,
    sidecarRevision: doc?.getElementById?.('mnb-segment-metadata')?.dataset?.mnbSidecarRevision || null,
});

const buildVisiblePageLookupIndex = (doc, visibleSegmentsResult, reason = 'unspecified') => {
    const view = doc?.defaultView ?? null;
    const byElementID = new Map();
    const bySegmentIdentifier = new Map();
    const idsByEntryID = new Map();
    const addEntryIDs = (elementID, entryIDs) => {
        if (!elementID || !Array.isArray(entryIDs)) { return; }
        for (const entryID of entryIDs) {
            if (entryID === null || entryID === undefined) { continue; }
            const key = String(entryID);
            let ids = idsByEntryID.get(key);
            if (!ids) {
                ids = new Set();
                idsByEntryID.set(key, ids);
            }
            ids.add(elementID);
        }
    };
    const addSegmentNode = (node) => {
        const elementID = node?.getAttribute?.('id') ?? null;
        if (!elementID || byElementID.has(elementID)) { return; }
        const metadata = segmentMetadataForNode(node);
        const segmentIdentifier = segmentIdentifierForNode(node);
        const sentenceNode = node.closest?.('mnb-sen') ?? null;
        const item = {
            node,
            metadata,
            segmentIdentifier,
            sentenceIdentifier: sentenceIdentifierForNode(sentenceNode),
        };
        byElementID.set(elementID, item);
        if (segmentIdentifier) {
            bySegmentIdentifier.set(segmentIdentifier, item);
        }
        for (const alias of segmentIdentifierAliasesForNode(node)) {
            bySegmentIdentifier.set(alias, item);
        }
        addEntryIDs(elementID, metadata?.j);
        addEntryIDs(elementID, metadata?.n);
    };
    const visibleSegments = Array.isArray(visibleSegmentsResult?.visibleSegments)
        ? visibleSegmentsResult.visibleSegments
        : [];
    const visibleElementIDs = [];
    for (const visibleSegment of visibleSegments) {
        const node = visibleSegment?.node ?? null;
        const elementID = node?.getAttribute?.('id') ?? null;
        if (elementID) {
            visibleElementIDs.push(elementID);
        }
        addSegmentNode(node);
        const sentenceNode = node?.closest?.('mnb-sen') ?? null;
        if (!sentenceNode?.querySelectorAll) { continue; }
        for (const sibling of sentenceNode.querySelectorAll('mnb-seg')) {
            addSegmentNode(sibling);
        }
    }
    const index = {
        byElementID,
        bySegmentIdentifier,
        idsByEntryID,
        documentURL: doc?.location?.href || doc?.URL || null,
        sidecarRevision: doc?.getElementById?.('mnb-segment-metadata')?.dataset?.mnbSidecarRevision || null,
        lookupPayloadByElementID: new Map(),
        lookupPayloadPrepared: false,
        reason,
        createdAtMs: performance.now(),
        visibleSegmentCount: visibleSegments.length,
        indexedSegmentCount: byElementID.size,
        visibleElementIDs,
    };
    doc.manabiVisiblePageLookupIndex = index;
    if (view) {
        view.__manabiVisiblePageLookupIndex = index;
        try {
            view.manabi_prepareVisiblePageLookupIndex?.(index);
        } catch (_error) {}
    }
    return index;
};

const postNativeLookupHitTargetsForVisibleSegments = (doc, visibleSegmentsResult, reason = 'unspecified') => {
    const view = doc?.defaultView ?? null;
    const builder = view?.manabi_nativeLookupHitTargetForSegment ?? null;
    const nativeLookupFrameKey = doc?.location?.href || doc?.URL || null;
    const viewportWidth = visibleSegmentsResult?.viewportWidth
        ?? window.visualViewport?.width
        ?? window.innerWidth
        ?? document.documentElement?.clientWidth
        ?? null;
    const viewportHeight = visibleSegmentsResult?.viewportHeight
        ?? window.visualViewport?.height
        ?? window.innerHeight
        ?? document.documentElement?.clientHeight
        ?? null;
    const viewportLeft = visibleSegmentsResult?.viewportLeft ?? 0;
    const viewportTop = visibleSegmentsResult?.viewportTop ?? 0;
    const visualViewportScale = Number.isFinite(window.visualViewport?.scale) ? window.visualViewport.scale : 1;
    const viewportPayload = {
        visualViewportWidth: viewportWidth,
        visualViewportHeight: viewportHeight,
        visualViewportOffsetLeft: 0,
        visualViewportOffsetTop: 0,
        scale: visualViewportScale,
        pageLeft: Number.isFinite(window.visualViewport?.pageLeft) ? window.visualViewport.pageLeft : null,
        pageTop: Number.isFinite(window.visualViewport?.pageTop) ? window.visualViewport.pageTop : null,
    };
    const messageHandlers = view?.webkit?.messageHandlers ?? window.webkit?.messageHandlers ?? null;
    const frameElement = view?.frameElement ?? null;
    const frameRect = frameElement?.getBoundingClientRect?.() ?? null;
    if (globalThis.manabiVerboseLookupPositionTargets === true) {
    }
    if (typeof builder !== 'function') {
        messageHandlers?.nativeLookupHitTargetsUpdated?.postMessage?.({
            targets: [],
            reason,
            nativeLookupFrameKey,
            isExplicitReset: false,
            visualViewportScale,
            viewportWidth,
            viewportHeight,
            viewportLeft,
            viewportTop,
        });
        return;
    }
    view?.manabi_resetNativeLookupHitTargets?.();
    const lookupIndex = visibleSegmentsResult?.lookupIndex
        || buildVisiblePageLookupIndex(doc, visibleSegmentsResult, reason);
    if (lookupIndex && !visibleSegmentsResult.lookupIndex) {
        visibleSegmentsResult.lookupIndex = lookupIndex;
    }
    const frameLeft = visibleSegmentsResult?.frameLeft ?? 0;
    const frameTop = visibleSegmentsResult?.frameTop ?? 0;
    const targets = [];
    for (const item of visibleSegmentsResult?.visibleSegments ?? []) {
        const rects = item?.rects?.length ? item.rects : (item?.rect ? [item.rect] : []);
        if (!item?.node || rects.length === 0) {
            continue;
        }
        const target = builder(item.node, rects.map((rect) => ({
            left: rect.left + frameLeft,
            top: rect.top + frameTop,
            width: rect.width,
            height: rect.height,
        })), viewportPayload);
        if (target) {
            targets.push(target);
        }
    }
    if (globalThis.manabiVerboseLookupPositionTargets === true) {
    }
    messageHandlers?.nativeLookupHitTargetsUpdated?.postMessage?.({
        targets,
        reason,
        nativeLookupFrameKey,
        isExplicitReset: false,
        visualViewportScale,
        viewportWidth,
        viewportHeight,
        viewportLeft,
        viewportTop,
    });
};

const buildVisiblePageTrackingStates = async (doc, articleReadingProgress, visibleRange = null, visibleSegmentsResult = null) => {
    const normalizedProgress = normalizeArticleReadingProgress(articleReadingProgress);
    const readSegmentIdentifiers = new Set(normalizedProgress.readSegmentIdentifiers);
    const readSentenceIdentifiers = new Set(normalizedProgress.sentenceIdentifiersRead);
    const hasAnyMarkedReadContent = readSegmentIdentifiers.size > 0
        || normalizedProgress.sentenceIdentifiersRead.length > 0;
    const {
        visibleSegments,
        viewportWidth,
        viewportHeight,
        totalSegmentCount,
        hiddenTooltipCount,
        missingIdentifierCount,
        outOfViewportCount,
    } = visibleSegmentsResult || collectVisibleSegmentNodesFromRange(doc, visibleRange);
    const clusterAxis = !!doc?.body?.classList?.contains?.('reader-vertical-writing') ? 'block' : 'inline';
    let recoveredTextSearchStringCount = 0;
    let skippedMissingSearchStringCount = 0;
    const dedupedSegments = new Map();
    const visibleSegmentIdentifiers = new Set(
        visibleSegments
            .map((item) => item.segmentIdentifier)
            .filter((identifier) => typeof identifier === 'string' && identifier.length > 0)
    );
    const visibleSegmentItemsByIdentifier = new Map();
    for (const item of visibleSegments) {
        if (typeof item.segmentIdentifier === 'string' && item.segmentIdentifier.length > 0) {
            visibleSegmentItemsByIdentifier.set(item.segmentIdentifier, item);
        }
    }
    const segmentMatchesReadProgress = (segmentIdentifier) => {
        const item = visibleSegmentItemsByIdentifier.get(segmentIdentifier);
        const aliases = Array.isArray(item?.segmentIdentifierAliases) && item.segmentIdentifierAliases.length > 0
            ? item.segmentIdentifierAliases
            : [segmentIdentifier];
        return aliases.some((identifier) => readSegmentIdentifiers.has(identifier));
    };
    const visibleSegmentIdentifierList = Array.from(visibleSegmentIdentifiers);
    const unreadVisibleSegmentIdentifiers = visibleSegmentIdentifierList
        .filter((segmentIdentifier) => !segmentMatchesReadProgress(segmentIdentifier));
    const readVisibleSegmentIdentifiers = visibleSegmentIdentifierList
        .filter((segmentIdentifier) => segmentMatchesReadProgress(segmentIdentifier));
    const unreadVisibleSegmentCount = unreadVisibleSegmentIdentifiers.length;
    const isRead = visibleSegmentIdentifiers.size > 0 && unreadVisibleSegmentCount === 0;
    const readSegmentIdentifierSample = Array.from(readSegmentIdentifiers).slice(0, 5);
    const visibleSegmentIdentifierSample = visibleSegmentIdentifierList.slice(0, 5);
    const visibleSegmentIdentifierAliasSample = visibleSegmentIdentifierList
        .slice(0, 3)
        .map((segmentIdentifier) => {
            const aliases = visibleSegmentItemsByIdentifier.get(segmentIdentifier)?.segmentIdentifierAliases;
            return Array.isArray(aliases) ? aliases.join('|') : segmentIdentifier;
        });
    const unreadVisibleSegmentIdentifierSample = unreadVisibleSegmentIdentifiers.slice(0, 5);
    const readVisibleSegmentIdentifierSample = readVisibleSegmentIdentifiers.slice(0, 5);
    const visibleReadSentenceIntersectionCount = Array.from(new Set(
        visibleSegments
            .map((item) => item.sentenceIdentifier)
            .filter((identifier) => typeof identifier === 'string' && identifier.length > 0)
    ))
        .filter((identifier) => readSentenceIdentifiers.has(identifier))
        .length;
    if (isRead) {
        const states = [{
            id: 'visible-screen',
            payload: {
                segments: [],
                sentenceIdentifiers: [],
            },
            isRead,
            hasAnyMarkedReadContent,
            unreadVisibleSegmentCount,
            visibleSegmentCount: visibleSegmentIdentifiers.size,
            fullLabel: 'Read',
            shortLabel: 'Read',
        }];
        return {
            states,
            diagnostics: {
                documentURL: doc.location?.href || null,
                viewportWidth,
                viewportHeight,
                clusterAxis,
                totalSegmentCount,
                visibleSegmentCount: visibleSegments.length,
                hiddenTooltipCount,
                missingIdentifierCount,
                outOfViewportCount,
                recoveredTextSearchStringCount,
                skippedMissingSearchStringCount,
                clusterCount: 1,
                stateCount: states.length,
                completedStateCount: 1,
                readSegmentCount: readSegmentIdentifiers.size,
                readSentenceCount: normalizedProgress.sentenceIdentifiersRead.length,
                visibleReadIntersectionCount: readVisibleSegmentIdentifiers.length,
                visibleReadSentenceIntersectionCount,
                visibleSegmentIdentifierSample,
                visibleSegmentIdentifierAliasSample,
                readSegmentIdentifierSample,
                unreadVisibleSegmentIdentifierSample,
                readVisibleSegmentIdentifierSample,
            },
        };
    }
    const sentencesByIdentifier = new Map();
    for (const item of visibleSegments) {
        if (!dedupedSegments.has(item.segmentIdentifier)) {
            const metadata = segmentMetadataForNode(item.node);
            let searchString = metadata?.s || metadata?.ns;
            if (typeof searchString !== 'string' || searchString.length === 0) {
                const textSearchString = item.node.textContent?.trim?.() || '';
                if (textSearchString.length === 0) {
                    skippedMissingSearchStringCount += 1;
                    continue;
                }
                searchString = textSearchString;
                recoveredTextSearchStringCount += 1;
            }
            const { sentenceHTML, sentenceJMDictIDs } = buildExampleSentenceForSegment(item.node);
            dedupedSegments.set(item.segmentIdentifier, {
                jmdictEntryIds: segmentEntryIDsForNode(item.node, 'jmdict'),
                jmnedictEntryIds: segmentEntryIDsForNode(item.node, 'jmnedict'),
                searchString,
                displayText: item.node.textContent?.trim?.() || searchString,
                segmentIdentifier: item.segmentIdentifier,
                exampleSentence: sentenceHTML,
                exampleSentenceJMDictIDs: sentenceJMDictIDs,
            });
        }
        if (item.sentenceIdentifier && !sentencesByIdentifier.has(item.sentenceIdentifier)) {
            const sentenceNode = item.node.closest('mnb-sen');
            const allSegmentIdentifierAliasSets = Array.from(sentenceNode?.querySelectorAll?.('mnb-seg') || [])
                .map((segmentNode) => segmentIdentifierAliasesForNode(segmentNode))
                .filter((aliases) => aliases.length > 0);
            sentencesByIdentifier.set(item.sentenceIdentifier, allSegmentIdentifierAliasSets);
        }
    }
    const sentenceIdentifiers = Array.from(sentencesByIdentifier.entries())
        .filter(([, allSegmentIdentifierAliasSets]) => allSegmentIdentifierAliasSets.length > 0
            && allSegmentIdentifierAliasSets.every((aliases) =>
                aliases.some((segmentIdentifier) =>
                    readSegmentIdentifiers.has(segmentIdentifier)
                    || visibleSegmentIdentifiers.has(segmentIdentifier))))
        .map(([sentenceIdentifier]) => sentenceIdentifier);
    const states = dedupedSegments.size > 0 ? [{
        id: 'visible-screen',
        payload: {
            segments: Array.from(dedupedSegments.values()),
            sentenceIdentifiers,
        },
        isRead,
        hasAnyMarkedReadContent,
        unreadVisibleSegmentCount,
        visibleSegmentCount: visibleSegmentIdentifiers.size,
        fullLabel: isRead ? 'Read' : 'Mark Read',
        shortLabel: isRead ? 'Read' : 'Mark Read',
    }] : [];
    return {
        states,
        diagnostics: {
            documentURL: doc.location?.href || null,
            viewportWidth,
            viewportHeight,
            clusterAxis,
            totalSegmentCount,
            visibleSegmentCount: visibleSegments.length,
            hiddenTooltipCount,
            missingIdentifierCount,
            outOfViewportCount,
            recoveredTextSearchStringCount,
            skippedMissingSearchStringCount,
            clusterCount: visibleSegments.length > 0 ? 1 : 0,
            stateCount: states.length,
            completedStateCount: states.filter((state) => state.isRead).length,
            readSegmentCount: readSegmentIdentifiers.size,
            readSentenceCount: normalizedProgress.sentenceIdentifiersRead.length,
            visibleReadIntersectionCount: readVisibleSegmentIdentifiers.length,
            visibleReadSentenceIntersectionCount,
            visibleSegmentIdentifierSample,
            visibleSegmentIdentifierAliasSample,
            readSegmentIdentifierSample,
            unreadVisibleSegmentIdentifierSample,
            readVisibleSegmentIdentifierSample,
        },
    };
};

const isZip = async (file) => {
    const arr = new Uint8Array(await file.slice(0, 4).arrayBuffer())
    return arr[0] === 0x50 && arr[1] === 0x4b && arr[2] === 0x03 && arr[3] === 0x04
}

const makeNativeSource = url => ({ kind: 'native', url })
const makeFileSource = file => ({ kind: 'file', file })

const makeNativeSourceURLQuery = sourceURL =>
    `sourceURL=${encodeURIComponent(sourceURL)}`

const fetchNativeEntries = async (sourceURL) => {
    const response = await fetch(`ebook://ebook/entries?${makeNativeSourceURLQuery(sourceURL)}`, {
        headers: {
            'X-Ebook-Source-URL': sourceURL,
        },
    })
    if (!response.ok) {
        throw new Error(`Failed to load native EPUB entries: ${response.status}`)
    }
    return response.json()
}

const fetchNativeEntryResponse = async (sourceURL, subpath) => {
    const response = await fetch(`ebook://ebook/entry?subpath=${encodeURIComponent(subpath)}&${makeNativeSourceURLQuery(sourceURL)}`, {
        headers: {
            'X-Ebook-Source-URL': sourceURL,
        },
    })
    if (!response.ok) {
        return null
    }
    return response
}

const readNativeEntryText = async (response) => {
    if (!response) return null
    const arrayBuffer = await response.arrayBuffer()
    const charset = response.headers?.get?.('content-type')?.match(/charset=([^;]+)/i)?.[1]?.trim() || 'utf-8'
    let decoder
    try {
        decoder = new TextDecoder(charset)
    } catch (_error) {
        decoder = new TextDecoder('utf-8')
    }
    return decoder.decode(arrayBuffer)
}

const readNativeEntryBlob = async (response) => {
    if (!response) return null
    const arrayBuffer = await response.arrayBuffer()
    const mimeType = response.headers?.get?.('content-type') || ''
    return new Blob([arrayBuffer], mimeType ? { type: mimeType } : undefined)
}

const makeNativeEpubLoader = async (url, isCacheWarmer) => {
    const loaderStartedAt = performanceNowMs();
    const { entries: rawEntries = [] } = await fetchNativeEntries(url)
    const entries = rawEntries.map(function(entry) {
        return {
            filename: entry.path,
            uncompressedSize: entry.size ?? 0,
        };
    })
    const sizeMap = new Map(entries.map(function(entry) { return [entry.filename, entry.uncompressedSize]; }))
    const entryNames = new Set(entries.map(function(entry) { return entry.filename; }))
    const replaceText = makeReplaceText(isCacheWarmer)
    const loadText = async (name) => {
        if (!entryNames.has(name)) {
            return null
        }
        const response = await fetchNativeEntryResponse(url, name)
        return readNativeEntryText(response)
    }
    const replaceURL = makeDirectSectionURLResolver(url, isCacheWarmer, loadText)
    return {
        entries,
        loadText,
        loadBlob: async (name) => {
            if (!entryNames.has(name)) {
                return null
            }
            const response = await fetchNativeEntryResponse(url, name)
            return readNativeEntryBlob(response)
        },
        getSize: name => sizeMap.get(name) ?? 0,
        replaceText,
        replaceURL,
        sourceURL: url,
    }
}

const makeZipLoader = async (file, isCacheWarmer) => {
    const loaderStartedAt = performanceNowMs();
    const {
        configure,
        ZipReader,
        BlobReader,
        TextWriter,
        BlobWriter
    } =
    await import('./vendor/zip.js')
    configure({
        useWebWorkers: false
    })
    const reader = new ZipReader(new BlobReader(file))
    const entries = await reader.getEntries()
    const map = new Map(entries.map(function(entry) { return [entry.filename, entry]; }))
    const load = f => (name, ...args) =>
    map.has(name) ? f(map.get(name), ...args) : null
    const loadText = load(function(entry) { return entry.getData(new TextWriter()); })
    const loadBlob = load(function(entry, type) { return entry.getData(new BlobWriter(type)); })
    const getSize = name => map.get(name)?.uncompressedSize ?? 0
    //    const wrappedReplaceText = ((href, text, mediaType) => {
    //        replaceText(href, text, mediaType, isCacheWarmer)
    //    })
    const replaceText = makeReplaceText(isCacheWarmer)
    return {
        entries,
        loadText,
        loadBlob,
        getSize,
        replaceText
    }
}

async function getFileEntries(entry) {
    if (entry.isFile) return entry;
    const entries = await new Promise((resolve, reject) => {
        entry.createReader().readEntries(resolve, reject);
    });
    return (await Promise.all(Array.from(entries, getFileEntries))).flat();
}

const isCBZ = ({
    name,
    type
}) =>
type === 'application/vnd.comicbook+zip' || name.endsWith('.cbz')

const isFB2 = ({
    name,
    type
}) =>
type === 'application/x-fictionbook+xml' || name.endsWith('.fb2')

const isFBZ = ({
    name,
    type
}) =>
type === 'application/x-zip-compressed-fb2' ||
name.endsWith('.fb2.zip') || name.endsWith('.fbz')

const getView = async (source, isCacheWarmer) => {
    let book
    if (source?.kind === 'native' && source.url) {
        const {
            EPUB
        } = await import('./epub.js')
        const loader = await makeNativeEpubLoader(source.url, isCacheWarmer)
        book = await new EPUB(loader).init()
    } else if (source?.kind === 'file' && source.file?.size) {
        const file = source.file
        if (await isZip(file)) {
            const loader = await makeZipLoader(file, isCacheWarmer)
            if (isCBZ(file)) {
                throw new Error('File format not yet supported')
                //            const { makeComicBook } = await import('./comic-book.js')
                //            book = makeComicBook(loader, file)
            } else if (isFBZ(file)) {
                throw new Error('File format not yet supported')
                //            const { makeFB2 } = await import('./fb2.js')
                //            const { entries } = loader
                //            const entry = entries.find(function(entry) { return entry.filename.endsWith('.fb2'); })
                //            const blob = await loader.loadBlob((entry ?? entries[0]).filename)
                //            book = await makeFB2(blob)
            } else {
                const {
                    EPUB
                } = await import('./epub.js')
                book = await new EPUB(loader).init()
            }
        } else {
            throw new Error('File format not yet supported')
            //        const { isMOBI, MOBI } = await import('./mobi.js')
            //        if (await isMOBI(file)) {
            //            const fflate = await import('./vendor/fflate.js')
            //            book = await new MOBI({ unzlib: fflate.unzlibSync }).open(file)
            //        } else if (isFB2(file)) {
            //            const { makeFB2 } = await import('./fb2.js')
            //            book = await makeFB2(file)
            //        }
        }
    } else {
        throw new Error('File not found')
    }
    if (!book) throw new Error('File type not supported')
    const view = document.createElement('foliate-view')
    view.dataset.isCache = isCacheWarmer;
    view.style.display = isCacheWarmer ? 'none' : 'block';
    view.style.width = isCacheWarmer ? '0px' : '100%';
    view.style.height = isCacheWarmer ? '0px' : '100%';
    view.style.overflow = 'hidden';
    view.style.contain = 'strict';
    view.style.pointerEvents = isCacheWarmer ? 'none' : 'auto';
    const readerStage = document.getElementById('reader-stage');
    (isCacheWarmer ? document.body : (readerStage || document.body)).append(view);
    postReaderVisibilityProbe('getView:appended', view, {
        isCacheWarmer: !!isCacheWarmer,
        parentID: view.parentElement?.id ?? null,
        parentTag: view.parentElement?.tagName ?? null,
    });
    forwardShadowErrors(view.shadowRoot);
    if (isCacheWarmer) {
        view.style.display = 'none'
        view.style.contain = 'strict'
        view.style.position = 'absolute'
        view.style.left = '-9001px'
        view.style.width = 0
        view.style.height = 0
        view.style.pointerEvents = 'none'
    }
    await view.open(book, isCacheWarmer)
    postReaderVisibilityProbe('getView:opened', view, {
        isCacheWarmer: !!isCacheWarmer,
        bookDir: book?.dir || null,
        sectionCount: Array.isArray(book?.sections) ? book.sections.length : null,
    });

    // Hide scrollbars on the scrolling container inside foliate-paginator's shadow DOM
    const paginator = resolveFoliatePaginator(view);
    if (paginator?.shadowRoot) {
        const style = document.createElement('style');
        style.textContent = `
        #container {
            scrollbar-width: none !important;         /* Firefox */
            -ms-overflow-style: none !important;      /* IE/Edge */
        }
        #container::-webkit-scrollbar {
            display: none !important;                 /* WebKit (macOS/iOS) */
            width: 0 !important;
            height: 0 !important;
        }
    `;
        paginator.shadowRoot.appendChild(style);
        postReaderVisibilityProbe('getView:paginator-ready', view, {
            isCacheWarmer: !!isCacheWarmer,
        });

        const sideNavWidth = 32;
        document.documentElement.style.setProperty('--side-nav-width', `${sideNavWidth}px`);
        // Also set --side-nav-width on the inner view, so it propagates into the iframe's shadow DOM.
        const syncSideNavWidth = () => {
            const width = getComputedStyle(document.body)
            .getPropertyValue('--side-nav-width').trim();
            if (view) {
                view.style.setProperty('--side-nav-width', width);
                // Also update the renderer's CSS variable, if setSideNavWidth exists
                if (view.renderer && typeof view.renderer.setSideNavWidth === "function") {
                    view.renderer.setSideNavWidth(width);
                }
            }
        };
        window.addEventListener('resize', syncSideNavWidth);
        syncSideNavWidth();
    }

    return view
}

const getCSSForBookContent = ({
    spacing,
    justify,
    hyphenate
}) => {
    const disableInjectedBookContentCSSForLayoutDiagnosis = true
    if (disableInjectedBookContentCSSForLayoutDiagnosis) return ''

    const parsedSpacing = Number.parseFloat(spacing)
    const rubyReservedSpacing = Number.isFinite(parsedSpacing)
        ? Math.max(parsedSpacing, 1.8)
        : 1.8
    const rubyReservedSegmentPaddingEm = Math.max(rubyReservedSpacing - 1.05, 0)

    return `
    @namespace epub "http://www.idpf.org/2007/ops";
    html {
        color-scheme: light dark;
        cursor: inherit;
    }
    html:lang(ja),
    body:lang(ja),
    :lang(ja),
    body[data-mnb-has-sentences="true"],
    body[data-mnb-has-segments="true"],
    body[data-mnb-has-sentences="true"] mnb-sen,
    body[data-mnb-has-segments="true"] mnb-seg {
        line-break: strict;
        -webkit-line-break: strict;
        word-break: normal;
        overflow-wrap: normal;
        font-feature-settings: "vchw" 1, "chws" 1;
    }
    /* https://github.com/whatwg/html/issues/5426 */
    @media (prefers-color-scheme: dark) {
        a:link {
            color: lightblue;
        }
    }
    p, li, blockquote, dd {
        line-height: ${spacing};
        text-align: start;
        -webkit-text-align-last: auto;
        text-align-last: auto;
        -webkit-hyphens: ${hyphenate ? 'auto' : 'manual'};
        hyphens: ${hyphenate ? 'auto' : 'manual'};
        -webkit-hyphenate-limit-before: 3;
        -webkit-hyphenate-limit-after: 2;
        -webkit-hyphenate-limit-lines: 2;
        hanging-punctuation: allow-end last;
        widows: 2;
    }
    html:lang(ja) :is(p, li, blockquote, dd),
    body:lang(ja) :is(p, li, blockquote, dd),
    :lang(ja):is(p, li, blockquote, dd),
    body[data-mnb-has-sentences="true"] :is(p, li, blockquote, dd),
    body[data-mnb-has-segments="true"] :is(p, li, blockquote, dd),
    body[data-mnb-has-sentences="true"] mnb-sen,
    body[data-mnb-has-segments="true"] mnb-seg {
        /*
           Reserve ruby annotation space even on lines without <rt>. WebKit's
           ruby layout otherwise lets mixed ruby/non-ruby Japanese text fall
           off a consistent line grid.
        */
        --mnb-ruby-reserved-line-height: ${rubyReservedSpacing};
        line-height: ${rubyReservedSpacing} !important;
    }
    /*
       Neutralize book-provided body/p justification as well. Some EPUBs ship
       text-align: justify on body/p, which causes punctuation spacing artifacts.
    */
    body, p, li, blockquote, dd {
        text-align: start !important;
        -webkit-text-align-last: auto !important;
        text-align-last: auto !important;
    }
    /* prevent the above from overriding the align attribute */
    [align="left"] { text-align: left !important; }
    [align="right"] { text-align: right !important; }
    [align="center"] { text-align: center !important; }

    pre {
        white-space: pre-wrap !important;
    }
    aside[epub|type~="endnote"],
    aside[epub|type~="footnote"],
    aside[epub|type~="note"],
    aside[epub|type~="rearnote"] {
        display: none;
    }

    h1, h2, h3, h4, h5, h6 {
        background: inherit !important;
        color: inherit !important;
    }

    mnb-con,
    mnb-sen {
        display: contents !important;
    }

    mnb-sur {
        contain: style paint !important;
    }

    mnb-seg {
        /* Keep book segments atomic so page turns never split a segment across pages. */
        display: inline-block !important;
        contain: style paint !important;
        vertical-align: baseline !important;
        max-inline-size: 100% !important;
        break-inside: avoid !important;
        break-before: avoid !important;
        break-after: avoid !important;
        page-break-inside: avoid !important;
        -webkit-column-break-inside: avoid !important;
    }
    html.vrtl body,
    body.reader-vertical-writing {
        --mnb-highlight-gradient-direction: to right;
    }
    body.reader-vertical-writing [data-mnb-horizontal-writing-island="true"],
    body.reader-vertical-writing mnb-seg[data-mnb-horizontal-writing-island="true"] > mnb-sur,
    body.reader-vertical-writing mnb-sur[data-mnb-horizontal-writing-island="true"] {
        --mnb-highlight-gradient-direction: to bottom;
    }
    body.reader-vertical-writing [data-mnb-display-token="1"] {
        unicode-bidi: isolate;
    }
    body.reader-vertical-writing .mnb-tate-upright {
        text-orientation: upright !important;
    }
    body.reader-vertical-writing .mnb-tate-upright-digit {
        display: inline-block;
        inline-size: 1em;
        max-inline-size: 1em;
        text-align: center;
        line-height: 1;
        font-feature-settings: "halt" 1, "vhal" 1;
        font-variant-numeric: lining-nums proportional-nums;
        direction: ltr;
        unicode-bidi: isolate;
    }
    body.reader-vertical-writing .mnb-tate-upright-latin,
    body.reader-vertical-writing .mnb-tate-upright-stacked-number {
        display: inline-flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        white-space: nowrap;
        inline-size: 1em;
        max-inline-size: 1em;
        direction: ltr;
        unicode-bidi: isolate;
        overflow: clip;
    }
    body.reader-vertical-writing .mnb-tate-upright-stacked-number {
        letter-spacing: -0.02em;
        font-feature-settings: "halt" 1, "vhal" 1;
        font-variant-numeric: lining-nums proportional-nums;
    }
    body.reader-vertical-writing .mnb-tate-upright-char {
        display: inline-block;
        inline-size: 1em;
        max-inline-size: 1em;
        text-align: center;
        line-height: 0.94;
    }
    body.reader-vertical-writing .mnb-tate-sideways-latin {
        display: inline-block;
        writing-mode: horizontal-tb !important;
        text-orientation: mixed !important;
        direction: ltr;
        unicode-bidi: isolate;
        transform-origin: center center;
        white-space: nowrap;
    }
    @property --word-tracking-unknown-highlight-nav-conditional {
        syntax: '<color>';
        inherits: true;
        initial-value: transparent;
    }
    @property --word-tracking-familiar-highlight-nav-conditional {
        syntax: '<color>';
        inherits: true;
        initial-value: transparent;
    }
    @property --word-tracking-learning-highlight-nav-conditional {
        syntax: '<color>';
        inherits: true;
        initial-value: transparent;
    }
    @property --word-tracking-known-highlight-nav-conditional {
        syntax: '<color>';
        inherits: true;
        initial-value: transparent;
    }
    body.reader-vertical-writing ruby > mnb-sur {
        display: inline !important;
    }
    body.reader-vertical-writing mnb-sur {
        /*
           Preserve the ruby-reserved vertical line grid. The app stylesheet
           normally tightens mnb-sur to 1em for highlight bounds, but in vertical
           EPUB layout that can collapse adjacent line boxes after mnb-seg is
           restored.
        */
        line-height: inherit !important;
    }
    body.reader-vertical-writing #reader-content :is(p, figure):has(img, svg, video, object, image),
    body.reader-vertical-writing #reader-content div:not(#reader-content):has(> :is(img, svg, video, object, image)),
    body.reader-vertical-writing #reader-content div:not(#reader-content):has(> a > :is(img, svg, video, object, image)) {
        /*
           Let vertical ebook media wrappers size to their media. Forcing these
           wrappers to one full page can leave an empty page-sized wrapper before
           the image itself when consecutive media pages are columnized.
        */
        block-size: fit-content !important;
        width: fit-content !important;
        max-block-size: 100% !important;
        break-inside: auto !important;
        page-break-inside: auto !important;
        -webkit-column-break-inside: auto !important;
    }
    body.reader-vertical-writing:not([data-is-ebook="true"]) mnb-seg:not(:has(rt)) {
        /*
           In vertical WebKit layout, line-height fixes the paragraph grid, but
           an inline no-ruby segment's own rect still only covers the base glyph.
           Reserve the missing rt lane, but clip tracking backgrounds to the
           base glyph content so learning-status highlights do not fill it.
        */
        padding-right: ${rubyReservedSegmentPaddingEm}em !important;
        background-clip: content-box !important;
        box-decoration-break: clone;
        -webkit-box-decoration-break: clone;
    }
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"] mnb-seg:not(:has(rt)):not(.mnb-selected):not(.mnb-highlighted):is(.mnb-learning, .mnb-read, .mnb-known, .mnb-unseen) {
        background: transparent !important;
    }
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"][data-mnb-subscription-is-active="true"] mnb-seg:not(:has(rt)):not(.mnb-selected):not(.mnb-highlighted):not(.mnb-read):not(.mnb-learning):not(.mnb-known),
    body.reader-vertical-writing:not([data-mnb-subscription-is-active="true"])[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"][data-mnb-ebook-subscription-preview-page="true"] mnb-seg:not(:has(rt)):not(.mnb-selected):not(.mnb-highlighted):not(.mnb-read):not(.mnb-learning):not(.mnb-known) {
        background: transparent !important;
    }
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"] mnb-seg:not(:has(rt)):not(.mnb-selected):not(.mnb-highlighted):is(.mnb-learning, .mnb-read, .mnb-known, .mnb-unseen) > mnb-sur {
        border-radius: var(--segment-match-border-radius);
        box-decoration-break: clone;
        -webkit-box-decoration-break: clone;
    }
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"][data-mnb-subscription-is-active="true"] mnb-seg:not(:has(rt)):not(.mnb-selected):not(.mnb-highlighted):not(.mnb-read):not(.mnb-learning):not(.mnb-known) > mnb-sur,
    body.reader-vertical-writing:not([data-mnb-subscription-is-active="true"])[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"][data-mnb-ebook-subscription-preview-page="true"] mnb-seg:not(:has(rt)):not(.mnb-selected):not(.mnb-highlighted):not(.mnb-read):not(.mnb-learning):not(.mnb-known) > mnb-sur {
        border-radius: var(--segment-match-border-radius);
        box-decoration-break: clone;
        -webkit-box-decoration-break: clone;
        transition:
            --word-tracking-unknown-highlight-nav-conditional 350ms ease,
            --word-tracking-familiar-highlight-nav-conditional 350ms ease,
            --word-tracking-learning-highlight-nav-conditional 350ms ease,
            --word-tracking-known-highlight-nav-conditional 350ms ease;
    }
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"] mnb-seg:not(:has(rt)):not(.mnb-selected):not(.mnb-highlighted):is(.mnb-learning, .mnb-read, .mnb-known, .mnb-unseen) > mnb-sur {
        transition:
            --word-tracking-unknown-highlight-nav-conditional 350ms ease,
            --word-tracking-familiar-highlight-nav-conditional 350ms ease,
            --word-tracking-learning-highlight-nav-conditional 350ms ease,
            --word-tracking-known-highlight-nav-conditional 350ms ease;
    }
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"][data-mnb-subscription-is-active="true"] mnb-seg:not(:has(rt)):not(.mnb-selected):not(.mnb-highlighted):not(.mnb-read):not(.mnb-learning):not(.mnb-known) > mnb-sur,
    body.reader-vertical-writing:not([data-mnb-subscription-is-active="true"])[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"][data-mnb-ebook-subscription-preview-page="true"] mnb-seg:not(:has(rt)):not(.mnb-selected):not(.mnb-highlighted):not(.mnb-read):not(.mnb-learning):not(.mnb-known) > mnb-sur {
        background: linear-gradient(var(--mnb-highlight-gradient-direction, to bottom), var(--word-tracking-unknown-highlight-nav-conditional) 0%, var(--word-tracking-unknown-highlight-nav-conditional) 50%, var(--word-tracking-unknown-highlight, transparent) 100%);
    }
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"][data-mnb-subscription-is-active="true"]:is([data-mnb-status-filter="familiar"], [data-mnb-show-familiar="true"]) mnb-seg:not(:has(rt)):not(.mnb-selected):not(.mnb-highlighted).mnb-read:not(.mnb-learning):not(.mnb-known) > mnb-sur,
    body.reader-vertical-writing:not([data-mnb-subscription-is-active="true"])[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"][data-mnb-ebook-subscription-preview-page="true"]:is([data-mnb-status-filter="familiar"], [data-mnb-show-familiar="true"]) mnb-seg:not(:has(rt)):not(.mnb-selected):not(.mnb-highlighted).mnb-read:not(.mnb-learning):not(.mnb-known) > mnb-sur {
        background: linear-gradient(var(--mnb-highlight-gradient-direction, to bottom), var(--word-tracking-familiar-highlight-nav-conditional) 0%, var(--word-tracking-familiar-highlight-nav-conditional) 50%, var(--word-tracking-familiar-highlight, transparent) 100%);
    }
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"][data-mnb-subscription-is-active="true"] mnb-seg:not(:has(rt)):not(.mnb-selected):not(.mnb-highlighted).mnb-learning > mnb-sur,
    body.reader-vertical-writing:not([data-mnb-subscription-is-active="true"])[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"][data-mnb-ebook-subscription-preview-page="true"] mnb-seg:not(:has(rt)):not(.mnb-selected):not(.mnb-highlighted).mnb-learning > mnb-sur {
        background: linear-gradient(var(--mnb-highlight-gradient-direction, to bottom), var(--word-tracking-learning-highlight-nav-conditional) 0%, var(--word-tracking-learning-highlight-nav-conditional) 50%, var(--word-tracking-learning-highlight, transparent) 100%);
    }
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"][data-mnb-subscription-is-active="true"]:is([data-mnb-status-filter="known"], [data-mnb-show-known="true"]) mnb-seg:not(:has(rt)):not(.mnb-selected):not(.mnb-highlighted).mnb-known > mnb-sur,
    body.reader-vertical-writing:not([data-mnb-subscription-is-active="true"])[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"][data-mnb-ebook-subscription-preview-page="true"]:is([data-mnb-status-filter="known"], [data-mnb-show-known="true"]) mnb-seg:not(:has(rt)):not(.mnb-selected):not(.mnb-highlighted).mnb-known > mnb-sur {
        background: linear-gradient(var(--mnb-highlight-gradient-direction, to bottom), var(--word-tracking-known-highlight-nav-conditional) 0%, var(--word-tracking-known-highlight-nav-conditional) 50%, var(--word-tracking-known-highlight, transparent) 100%);
    }
    body.reader-vertical-writing[data-mnb-lookup-highlight-mode="word"] mnb-seg:not(:has(rt)).mnb-selected {
        background: transparent !important;
        background-color: transparent !important;
        background-image: none !important;
    }
    body.reader-vertical-writing[data-mnb-lookup-highlight-mode="word"] mnb-seg:not(:has(rt)).mnb-selected > mnb-sur {
        background: var(--theme-selection-color) !important;
        background-color: var(--theme-selection-color) !important;
        background-image: none !important;
        border-radius: var(--segment-match-border-radius);
        box-decoration-break: clone;
        -webkit-box-decoration-break: clone;
    }

    mnb-sen ruby.mnb-gen > rt,
    mnb-sen ruby.mbn-src > rt,
    mnb-sen ruby.mbn-src-fwd > rt {
        /*
           Keep Manabi-owned ruby annotations in the historical Japanese sans stack.
           Reader-selected surface fonts such as YuKyokasho should apply to the
           sentence surface text, not to the compact annotation text.
        */
        font-family: "Hiragino Kaku Gothic ProN", "Hiragino Sans", system-ui !important;
    }

    body:not([data-mnb-romaji-mode-enabled="true"]) rt {
        color: var(--theme-secondary-text) !important;
        color: color-mix(in srgb, var(--theme-secondary-text) 85%, var(--theme-text-color) 15%) !important;
    }

    body[data-mnb-romaji-mode-enabled="true"] rt,
    body[data-mnb-romaji-mode-enabled="true"] rt *,
    body[data-mnb-romaji-mode-enabled="true"] rt .tt-outline-char::before,
    body[data-mnb-romaji-mode-enabled="true"] mnb-seg ruby > rt,
    body[data-mnb-romaji-mode-enabled="true"] mnb-seg ruby > rt *,
    body[data-mnb-romaji-mode-enabled="true"] mnb-seg ruby > rt .tt-outline-char::before,
    body[data-mnb-romaji-mode-enabled="true"] ruby.mnb-gen > rt,
    body[data-mnb-romaji-mode-enabled="true"] ruby.mnb-gen > rt *,
    body[data-mnb-romaji-mode-enabled="true"] ruby.mnb-gen > rt .tt-outline-char::before {
        font-family: system-ui !important;
        font-weight: 400 !important;
        letter-spacing: normal !important;
        color: var(--theme-text-color) !important;
    }

    body.reader-is-single-media-element-without-text *:not(.mnb-tracking-container *):not(mnb-seg *) {
        max-height: 99vh;
    }
    body.reader-is-single-media-element-without-text :is(.h-valign-width, .v-valign-height) {
        display: none !important;
        inline-size: 0 !important;
        block-size: 0 !important;
        width: 0 !important;
        height: 0 !important;
    }
    body.reader-is-single-media-element-without-text :is(.inline-height, .inline-width) {
        inline-size: auto !important;
        block-size: auto !important;
        width: auto !important;
        height: auto !important;
    }
    body.reader-is-single-media-element-without-text {
        overflow: hidden !important;
    }
    body.reader-is-single-media-element-without-text :is(p, div, figure):has(> img, > svg, > video, > object, > image) {
        display: grid !important;
        place-items: center !important;
        inline-size: 100% !important;
        block-size: 100% !important;
        width: 100% !important;
        height: 100% !important;
        max-inline-size: 100% !important;
        max-block-size: 100% !important;
        max-width: 100% !important;
        max-height: 100% !important;
        overflow: hidden !important;
    }
    body.reader-is-single-media-element-without-text :is(img, svg, image, picture, video, object) {
        max-inline-size: 100% !important;
        max-block-size: 100% !important;
        max-width: 100% !important;
        max-height: 100vh !important;
        width: auto !important;
        height: auto !important;
        margin: auto !important;
        object-fit: contain !important;
    }
/*
reader-sentinel {
  position: relative;
  display: inline; /*-block;*/
  width: 4px !important;
  height: 4px !important;
  opacity: 1 !important;
  pointer-events: none !important;
  contain: strict;
  background: red !important;
}
*/
    reader-sentinel {
         position: relative !important;
         display: inline-block !important;
         width: 1px !important;
         height: 1px !important;
         padding: 0 !important;
         contain: strict !important;
         pointer-events: none !important;
         opacity: 0 !important;
         vertical-align: bottom !important;
         break-before: avoid !important;
         break-after: avoid !important;
         break-inside: avoid !important;
    }
`
}

// Fetch once while the book is opening. The paginator awaits this resource before
// publishing each parsed foreground section to its load and layout pipeline.
const bookContentStylesheetURL = new URL('./book-content.css', import.meta.url).href
const bookContentStylesPromise = fetch(bookContentStylesheetURL).then(response => {
    if (!response.ok) {
        throw new Error(`Unable to load book content stylesheet (${response.status})`)
    }
    return response.text()
})

const $ = document.querySelector.bind(document)

const locales = 'en'
const percentFormat = new Intl.NumberFormat(locales, {
    style: 'percent'
})

const loadingVisualDelayMs = 200;
const loadingVisualMaximumMs = 3500;
const navSpinnerMaximumMs = 1200;

class Reader {
    #show(btn, show = true) {
        if (show) {
            if (btn.hidden) {
                btn.hidden = false;
            }
            if (btn.style.visibility !== 'visible') {
                btn.style.visibility = 'visible';
            }
        } else {
            if (!btn.hidden) {
                btn.hidden = true;
            }
            if (btn.style.visibility !== 'hidden') {
                btn.style.visibility = 'hidden';
            }
        }
    }
    setLoadingIndicator(visible) {
        const body = document.body;
        if (!body) return;
        const loadingIndicator = document.getElementById('loading-indicator');
        const previousVisible = body.classList.contains('loading');
        const nextVisible = !!visible;
        if (nextVisible) {
            loadingIndicator?.removeAttribute?.('hidden');
            clearTimeout(this.loadingVisualTimer);
            clearTimeout(this.loadingVisualMaximumTimer);
            this.loadingVisualTimer = setTimeout(() => {
                if (document.body?.classList?.contains?.('loading')) {
                    document.body.classList.add('loading-visual');
                }
            }, loadingVisualDelayMs);
            this.loadingVisualMaximumTimer = setTimeout(() => {
                loadingIndicator?.setAttribute?.('hidden', '');
                document.body?.classList?.remove?.('loading-visual');
            }, loadingVisualMaximumMs);
        }
        body.classList.toggle('loading', nextVisible);
        if (previousVisible && !nextVisible) {
            clearTimeout(this.loadingVisualTimer);
            clearTimeout(this.loadingVisualMaximumTimer);
            this.loadingVisualTimer = null;
            this.loadingVisualMaximumTimer = null;
            body.classList.remove('loading-visual');
            loadingIndicator?.setAttribute?.('hidden', '');
        }
        if (previousVisible !== nextVisible) {
        }
    }
    #tocView
    #deferredOpenWork = new DeferredOpenWorkCoordinator()
    #renderReadiness = new EbookRenderReadinessCoordinator()
    renderReadinessGeneration = 0;
    #chevronFadeTimers = {
        l: null,
        r: null
    }
    #mainDocumentSwipeState = null;
    hasLoadedLastPosition = false
    markedAsFinished = false;
    showingCompletionButtons = false;
    completionAction = null;
    completionActionBusy = false;
    lastPercentValue = null;
    articleReadingProgress = normalizeArticleReadingProgress();
    pageTrackingStates = [];
    pageTrackingBusyStateIDs = new Set();
    pageTrackingAnimateReadStateIDs = new Set();
    pageReadMarkerAwaitingPageState = false;
    optimisticReadSegmentIdentifiers = new Set();
    optimisticSentenceIdentifiersRead = new Set();
    markReadSessionID = Math.random().toString(36).slice(2, 10);
    lastPageTrackingVisibility = null;
    lastPageTrackingDiagnosticsKey = null;
    lastBookReadingProgressKey = null;
    pageTrackingRetryHandle = null;
    pageTrackingDeferredHandle = null;
    pageTrackingDeferredFrameHandle = null;
    pageTrackingDeferredRequest = null;
    pageReadMarkerDeferredHandle = null;
    initialPaginatorSettleHandle = null;
    hasSettledInitialPaginatorLayout = false;
    hasFlashedInitialForwardSideNavChevron = false;
    sameIndexGoToDidDisplaySkips = 0;
    lastLayoutDiagnosticsKey = null;
    lastLayoutSnapshot = null;
    lastCFIPersistenceObservation = null;
    unstableCFIs = new Set();
    visiblePageCollectionGeneration = 0;
    visiblePageSegmentSnapshot = null;
    nativeLookupHitTargetRefreshHandle = null;
    displaySettledSequence = 0;
    displaySettledWaiters = [];
    lookupNavigationPageTurnActive = false;
    style = {
        spacing: 1.4,
        justify: true,
        hyphenate: true,
    }
    annotations = new Map()
    annotationsByValue = new Map()
    openSideBar() {
        $('#dimming-overlay').removeAttribute('hidden')
        $('#side-bar').removeAttribute('hidden')
        $('#dimming-overlay').classList.add('show')
        $('#side-bar').classList.add('show')
        if (this.#tocView?.setCurrentHref && this.view?.renderer?.tocItem?.href) {
            this.#tocView.setCurrentHref(this.view.renderer.tocItem.href)
        }
    }
    closeSideBar() {
        $('#dimming-overlay').classList.remove('show')
        $('#side-bar').classList.remove('show')
        setTimeout(() => {
            if (!$('#side-bar').classList.contains('show')) {
                $('#dimming-overlay').setAttribute('hidden', '')
                $('#side-bar').setAttribute('hidden', '')
            }
        }, 360)
    }
    toggleTableOfContents() {
        if ($('#side-bar').classList.contains('show')) {
            this.closeSideBar()
        } else {
            this.openSideBar()
        }
    }
    async _goToDescriptor(descriptor) {
        if (!descriptor || !this.view) return;
        if (
            typeof descriptor.sectionIndex === 'number'
            && typeof descriptor.localSectionIndex === 'number'
            && typeof descriptor.rendererTotal === 'number'
            && descriptor.rendererTotal > 1
            && this.view?.renderer?.goTo
        ) {
            const clampedLocalSectionIndex = Math.max(
                0,
                Math.min(descriptor.rendererTotal - 1, Math.round(descriptor.localSectionIndex))
            );
            const fractionInSection = clampedLocalSectionIndex / (descriptor.rendererTotal - 1);
            await runWithNavigationIntent({
                source: 'goToDescriptor',
                target: 'renderer.goTo',
                sectionIndex: descriptor.sectionIndex,
                localSectionIndex: descriptor.localSectionIndex,
                rendererTotal: descriptor.rendererTotal,
                fractionInSection,
                pageItemKey: descriptor.pageItemKey ?? null,
            }, () => this.view.renderer.goTo({
                index: Math.max(0, Math.round(descriptor.sectionIndex)),
                localPage: clampedLocalSectionIndex,
            })).catch((error) => console.error(error));
            return;
        }
        if (typeof descriptor.cfi === 'string' && descriptor.cfi) {
            await runWithNavigationIntent({
                source: 'goToDescriptor',
                target: 'view.goTo',
                cfiLength: descriptor.cfi.length,
                pageItemKey: descriptor.pageItemKey ?? null,
            }, () => this.view.goTo(descriptor.cfi)).catch((error) => console.error(error));
            return;
        }
        if (typeof descriptor.fraction === 'number' && Number.isFinite(descriptor.fraction)) {
            await runWithNavigationIntent({
                source: 'goToDescriptor',
                target: 'view.goToFraction',
                fraction: descriptor.fraction,
                pageItemKey: descriptor.pageItemKey ?? null,
            }, () => this.view.goToFraction(descriptor.fraction));
        }
    }
    async goToHref(href, source = 'unknown') {
        if (!this.view || typeof href !== 'string' || !href) {
            return false;
        }
        this.navHUD?.requestExplicitRelocateHistoryMutation?.('goToHref');
        await runWithNavigationIntent({
            source: 'goToHref',
            target: 'view.goTo',
            href,
            requestSource: source,
        }, () => this.view.goTo(href));
        return true;
    }
    async goToPercent(percent, source = 'unknown') {
        if (!this.view) {
            return false;
        }
        this.navHUD?.requestExplicitRelocateHistoryMutation?.('goToPercent');
        const numericPercent = Number(percent);
        const clampedPercent = Math.max(0, Math.min(100, numericPercent));
        if (!Number.isFinite(clampedPercent)) {
            return false;
        }
        const fraction = clampedPercent / 100;
        await runWithNavigationIntent({
            source: 'goToPercent',
            target: 'view.goToFraction',
            percent: clampedPercent,
            fraction,
            requestSource: source,
        }, () => this.view.goToFraction(fraction));
        return true;
    }
    async goToLocationNumber(locationNumber, source = 'unknown') {
        if (!this.view) {
            return false;
        }
        this.navHUD?.requestExplicitRelocateHistoryMutation?.('goToLocation');
        const numericLocationNumber = Number(locationNumber);
        const locationTotalHint = this.navHUD?.getLocationTotalHint?.()
            ?? this.navHUD?.currentLocationDescriptor?.locationTotalHint
            ?? this.navHUD?.lastPrimaryLabelDiagnostics?.locationTotal
            ?? null;
        if (!Number.isFinite(numericLocationNumber)) {
            return false;
        }
        const maxLocationNumber = typeof locationTotalHint === 'number' && locationTotalHint > 0
            ? Math.max(1, Math.round(locationTotalHint))
            : Math.max(1, Math.round(numericLocationNumber));
        const clampedLocationNumber = Math.max(1, Math.min(maxLocationNumber, Math.round(numericLocationNumber)));
        const fraction = maxLocationNumber > 1
            ? (clampedLocationNumber - 1) / (maxLocationNumber - 1)
            : 0;
        await runWithNavigationIntent({
            source: 'goToLocationNumber',
            target: 'view.goToFraction',
            locationNumber: clampedLocationNumber,
            locationTotal: maxLocationNumber,
            fraction,
            requestSource: source,
        }, () => this.view.goToFraction(fraction));
        return true;
    }
    async goToPageNumber(pageNumber, source = 'unknown') {
        return await this.goToLocationNumber(pageNumber, source);
    }
    async buildGoToSheetSnapshot() {
        const chapters = buildGoToSnapshotChapters(this.view?.book);
        const linearSectionEntries = buildLinearSectionEntries(this.view?.book);
        const linearSectionStartPercentByHref = buildLinearSectionStartPercentByHref(this.view?.book);
        const currentLocationDescriptor = this.navHUD?.getCurrentLocationDescriptor?.() ?? null;
        const currentFraction = getAuthoritativeReaderFraction({
            navHUD: this.navHUD,
            detail: this.navHUD?.lastRelocateDetail ?? currentLocationDescriptor ?? null,
            fallbackFraction: typeof currentLocationDescriptor?.fraction === 'number'
                ? currentLocationDescriptor.fraction
                : (typeof this.navHUD?._fractionForPercent?.(this.navHUD?.lastRelocateDetail ?? null) === 'number'
                    ? this.navHUD._fractionForPercent(this.navHUD.lastRelocateDetail)
                    : null),
        });
        const currentPercent = currentFraction != null
            ? safeRound(currentFraction * 100, 1)
            : null;
        for (const entry of chapters) {
            const href = entry.href;
            let percent = null;
            let percentSource = null;
            const normalizedHref = normalizeSpineHref(href);
            const sectionStartPercent = normalizedHref != null
                ? (linearSectionStartPercentByHref.get(normalizedHref) ?? null)
                : null;
            if (typeof sectionStartPercent === 'number') {
                percent = sectionStartPercent;
                percentSource = 'linear-section-start';
            }
            entry.percent = percent;
            entry.percentSource = percentSource;
        }
        const relocateSectionIndex = typeof this.navHUD?.lastRelocateDetail?.sectionIndex === 'number'
            ? this.navHUD.lastRelocateDetail.sectionIndex
            : (typeof this.navHUD?.lastRelocateDetail?.index === 'number'
                ? this.navHUD.lastRelocateDetail.index
                : null);
        const rendererCurrentIndex = (() => {
            try {
                const currentIndex = this.view?.renderer?.currentIndex;
                if (typeof currentIndex === 'number') return currentIndex;
                return getPrimaryRendererContentIndex(this.view?.renderer);
            } catch (_) {
                return null;
            }
        })();
        const resolvedSectionIndex = this.navHUD?._resolveSectionIndex?.(this.navHUD?.lastRelocateDetail ?? {}) ?? {
            index: null,
            source: 'nav-hud-unavailable',
        };
        const currentSectionIndex = typeof resolvedSectionIndex?.index === 'number'
            ? resolvedSectionIndex.index
            : null;
        const currentSection = currentSectionIndex != null
            ? this.view?.book?.sections?.[currentSectionIndex] ?? null
            : null;
        const currentSectionHref = typeof currentSection?.id === 'string'
            ? currentSection.id
            : null;
        const normalizedCurrentSectionHref = normalizeSpineHref(currentSectionHref);
        const currentSectionEntry = normalizedCurrentSectionHref
            ? linearSectionEntries.find(function(entry) { return normalizeSpineHref(entry.href) === normalizedCurrentSectionHref; }) ?? null
            : null;
        const currentChapter = currentSectionEntry
            ? null
            : (this.view?.renderer?.tocItem ?? this.view?.lastLocation?.tocItem ?? null);
        const currentChapterHref = typeof currentSectionEntry?.href === 'string'
            ? currentSectionEntry.href
            : (currentSectionHref ?? (typeof currentChapter?.href === 'string' ? currentChapter.href : null));
        const normalizedCurrentChapterHref = normalizeSpineHref(currentChapterHref);
        const currentChapterEntry = normalizedCurrentChapterHref
            ? chapters.find(function(entry) { return normalizeSpineHref(entry.href) === normalizedCurrentChapterHref; })
            : null;
        const currentChapterPercent = typeof currentChapterEntry?.percent === 'number'
            ? currentChapterEntry.percent
            : null;
        const currentChapterIndex = currentChapterEntry
            ? chapters.findIndex(function(entry) { return normalizeSpineHref(entry.href) === normalizeSpineHref(currentChapterEntry.href); })
            : -1;
        const nextChapterPercent = currentChapterIndex >= 0
            ? (chapters.slice(currentChapterIndex + 1).find(function(entry) { return typeof entry.percent === 'number'; })?.percent ?? 100)
            : null;
        const currentChapterPercentSource = typeof currentChapterEntry?.percentSource === 'string'
            ? currentChapterEntry.percentSource
            : null;
        const canJumpBack = !!this.navHUD?._isRelocateButtonVisible?.('back');
        const canJumpForward = !!this.navHUD?._isRelocateButtonVisible?.('forward');
        const backLabel = this.navHUD?.labelForDescriptor?.(this.navHUD?._descriptorForRelocateLabel?.('back'))
            || '';
        const forwardLabel = this.navHUD?.labelForDescriptor?.(this.navHUD?._descriptorForRelocateLabel?.('forward'))
            || '';
        const snapshot = {
            isRTL: !!this.isRTL,
            currentChapterHref,
            currentChapterTitle: typeof currentSectionEntry?.title === 'string'
                ? currentSectionEntry.title
                : (typeof currentChapter?.label === 'string' ? currentChapter.label : null),
            currentPercent,
            canJumpBack,
            canJumpForward,
            backLabel,
            forwardLabel,
            currentSectionIndex,
            currentSectionIndexSource: resolvedSectionIndex?.source ?? null,
            navLastSectionIndexSeen: this.navHUD?.lastSectionIndexSeen ?? null,
            currentSectionHref,
            normalizedCurrentSectionHref,
            chapters,
        };
        return snapshot;
    }
    #applyHideNavigationDueToScrollToBookContent(shouldHide) {
        if (MANABI_DISABLE_NAV_HIDDEN_LAYOUT_CLASSES) {
            return;
        }
        const hidden = !!shouldHide;
        document.body?.classList?.toggle?.('nav-hidden-due-to-scroll', hidden);
        const contents = this.view?.renderer?.getContents?.() || [];
        for (const content of contents) {
            const body = content?.doc?.body;
            if (!body) continue;
            body.classList.toggle('nav-hidden', hidden);
            body.classList.toggle('nav-hidden-due-to-scroll', hidden);
            body.dataset.mnbNavigationHiddenDueToScroll = hidden ? 'true' : 'false';
        }
    }
    constructor() {
        applyStoredChromeInsets('reader.constructor');
        this.navHUD = new NavigationHUD({
            formatPercent: value => percentFormat.format(value),
            getRenderer: () => this.view?.renderer,
            onJumpRequest: descriptor => this._goToDescriptor(descriptor),
            onHideNavigationDueToScrollChange: (hidden, details = {}) => {
                this.#applyHideNavigationDueToScrollToBookContent(hidden);
                if (details?.context?.bridgeSource) {
                    return;
                }
                postEbookNavigationVisibilityToNative(
                    hidden,
                    `navHUD.visibilityChange.${details?.source || 'unknown'}`,
                    {
                        previous: details?.previous ?? null,
                        context: details?.context ?? null,
                    }
                );
            },
        });
        this.scheduleGoToPageNumber = debounce((pageNumber) => {
            this.goToLocationNumber(pageNumber, 'schedule-location-number')
                .catch((error) => console.error(error));
        }, 120);
        this.scheduleGoToFraction = debounce((fraction) => {
            const clampedFraction = Math.max(0, Math.min(1, Number(fraction)));
            if (shouldSkipScheduledReaderFractionGoToForRestoreSettling(clampedFraction)) {
                return false;
            }
            const currentDescriptor = this.navHUD?.getCurrentLocationDescriptor?.() ?? null;
            const targetDescriptor = this.navHUD?._descriptorFromFraction?.(clampedFraction) ?? null;
            const currentFraction = typeof currentDescriptor?.fraction === 'number'
                ? currentDescriptor.fraction
                : this.navHUD?._fractionForPercent?.(this.view?.lastLocation ?? this.navHUD?.lastRelocateDetail ?? null);
            const currentLocationCurrent = typeof currentDescriptor?.location?.current === 'number'
                ? currentDescriptor.location.current
                : null;
            const currentLocationTotal = typeof currentDescriptor?.locationTotalHint === 'number'
                ? currentDescriptor.locationTotalHint
                : null;
            const targetLocationCurrent = typeof targetDescriptor?.location?.current === 'number'
                ? targetDescriptor.location.current
                : null;
            const targetLocationTotal = typeof targetDescriptor?.locationTotalHint === 'number'
                ? targetDescriptor.locationTotalHint
                : null;
            const roundedCurrentPercent = typeof currentFraction === 'number' && Number.isFinite(currentFraction)
                ? Math.round(currentFraction * 100)
                : null;
            const roundedTargetPercent = Number.isFinite(clampedFraction)
                ? Math.round(clampedFraction * 100)
                : null;
            if (!Number.isFinite(clampedFraction) || !this.view) {
                return;
            }
            if (typeof currentFraction === 'number' && Number.isFinite(currentFraction) && Math.abs(currentFraction - clampedFraction) < 0.0005) {
                return;
            }
            if (currentLocationCurrent != null
                && targetLocationCurrent != null
                && currentLocationCurrent === targetLocationCurrent
                && currentLocationTotal != null
                && targetLocationTotal != null
                && currentLocationTotal === targetLocationTotal) {
                return;
            }
            if (roundedCurrentPercent != null && roundedTargetPercent != null && roundedCurrentPercent === roundedTargetPercent) {
                return;
            }
            runWithNavigationIntent({
                source: 'live-schedule',
                target: 'view.goToFraction',
                fraction: clampedFraction,
            }, () => this.view.goToFraction(clampedFraction))
                .then(() => {
                })
                .catch((error) => {
                    console.error(error);
                });
        }, 250);
        document.getElementById('nav-primary-text')?.addEventListener('click', (event) => {
            const wasHidden = !!this.navHUD?.hideNavigationDueToScroll;
            event.preventDefault?.();
            event.stopPropagation?.();
            event.stopImmediatePropagation?.();
            if (wasHidden) {
                ignoreNextIncomingRevealNavigation('nav-primary-text.click');
                postEbookNavigationVisibilityToNative(true, 'nav-primary-text.click.preserve-hidden', {
                    control: 'nav-primary-text',
                    target: event.target?.id || event.target?.tagName || null,
                });
            } else {
                ignoreNextIncomingHideNavigation('nav-primary-text.click');
                postEbookNavigationVisibilityToNative(false, 'nav-primary-text.click.preserve-visible', {
                    control: 'nav-primary-text',
                    target: event.target?.id || event.target?.tagName || null,
                });
            }
            postOpenReaderGoToSheetRequest('nav-primary-text', 'nav-primary-text', {
                preserveHiddenNavigation: wasHidden,
                preserveVisibleNavigation: !wasHidden,
            });
        });
        document.getElementById('nav-hidden-primary-text')?.addEventListener('click', (event) => {
            const wasHidden = !!this.navHUD?.hideNavigationDueToScroll;
            event.preventDefault?.();
            event.stopPropagation?.();
            event.stopImmediatePropagation?.();
            if (wasHidden) {
                ignoreNextIncomingRevealNavigation('nav-hidden-primary-text.click');
                postEbookNavigationVisibilityToNative(true, 'nav-hidden-primary-text.click.preserve-hidden', {
                    control: 'nav-hidden-primary-text',
                    target: event.target?.id || event.target?.tagName || null,
                });
            } else {
                ignoreNextIncomingHideNavigation('nav-hidden-primary-text.click');
                postEbookNavigationVisibilityToNative(false, 'nav-hidden-primary-text.click.preserve-visible', {
                    control: 'nav-hidden-primary-text',
                    target: event.target?.id || event.target?.tagName || null,
                });
            }
            postOpenReaderGoToSheetRequest('nav-hidden-primary-text', 'nav-hidden-primary-text', {
                preserveHiddenNavigation: wasHidden,
                preserveVisibleNavigation: !wasHidden,
            });
        });
        document.getElementById('nav-section-progress-center')?.addEventListener('click', (event) => {
            const wasHidden = !!this.navHUD?.hideNavigationDueToScroll;
            event.preventDefault?.();
            event.stopPropagation?.();
            event.stopImmediatePropagation?.();
            if (wasHidden) {
                ignoreNextIncomingRevealNavigation('nav-section-progress-center.click');
                postEbookNavigationVisibilityToNative(true, 'nav-section-progress-center.click.preserve-hidden', {
                    control: 'nav-section-progress-center',
                    target: event.target?.id || event.target?.tagName || null,
                });
            } else {
                ignoreNextIncomingHideNavigation('nav-section-progress-center.click');
                postEbookNavigationVisibilityToNative(false, 'nav-section-progress-center.click.preserve-visible', {
                    control: 'nav-section-progress-center',
                    target: event.target?.id || event.target?.tagName || null,
                });
            }
            postOpenReaderGoToSheetRequest('nav-section-progress-center', 'nav-section-progress-center', {
                preserveHiddenNavigation: wasHidden,
                preserveVisibleNavigation: !wasHidden,
            });
        });
        document.getElementById('nav-title-location-label')?.addEventListener('click', (event) => {
            const wasHidden = !!this.navHUD?.hideNavigationDueToScroll;
            event.preventDefault?.();
            event.stopPropagation?.();
            event.stopImmediatePropagation?.();
            if (wasHidden) {
                ignoreNextIncomingRevealNavigation('nav-title-location-label.click');
                postEbookNavigationVisibilityToNative(true, 'nav-title-location-label.click.preserve-hidden', {
                    control: 'nav-title-location-label',
                    target: event.target?.id || event.target?.tagName || null,
                });
            } else {
                ignoreNextIncomingHideNavigation('nav-title-location-label.click');
                postEbookNavigationVisibilityToNative(false, 'nav-title-location-label.click.preserve-visible', {
                    control: 'nav-title-location-label',
                    target: event.target?.id || event.target?.tagName || null,
                });
            }
            postOpenReaderGoToSheetRequest('nav-title-location-label', 'nav-title-location-label', {
                preserveHiddenNavigation: wasHidden,
                preserveVisibleNavigation: !wasHidden,
            });
        });
        document.getElementById('nav-bar')?.addEventListener('click', (event) => {
            const target = event.target;
            const excludedTarget = target?.closest?.('button, a, input, textarea, select, [role="button"], [contenteditable="true"], #progress-wrapper, .nav-section-progress') || null;
            const wasHidden = !!this.navHUD?.hideNavigationDueToScroll;
            const shouldHide = !wasHidden;
            const now = Date.now();
            const lastContentBlankToggleAt = Number(globalThis.__manabiLastContentDocumentBlankToggleAtMs || 0);
            if (lastContentBlankToggleAt > 0 && now - lastContentBlankToggleAt >= 0 && now - lastContentBlankToggleAt < 750) {
                return;
            }
            if (excludedTarget) {
                return;
            }
            event.preventDefault?.();
            event.stopPropagation?.();
            event.stopImmediatePropagation?.();
            postEbookNavigationVisibilityToNative(
                shouldHide,
                'toolbar.blankTap',
                {
                    control: 'nav-bar-background',
                    jsWasHidden: wasHidden,
                    jsProposedShouldHide: shouldHide,
                }
            );
        });
        $('#side-bar-close-button').addEventListener('click', () => {
            this.closeSideBar()
        })
        $('#dimming-overlay').addEventListener('click', () => this.closeSideBar())
        const pageTrackingButtonSelector = 'button[data-page-tracking-id], button[data-completion-action]';
        const pageTrackingButtonAcceptsEvent = (event, button) => {
            if (!(button instanceof HTMLElement)) {
                return false;
            }
            if (button.dataset?.completionAction) {
                return true;
            }
            const label = button.querySelector?.('.mnb-tracking-button-label') || null;
            const labelStyle = label instanceof Element ? getComputedStyle(label) : null;
            const labelVisible = label instanceof HTMLElement
                && label.offsetWidth > 1
                && Number(labelStyle?.opacity ?? 0) > 0.01;
            if (labelVisible) {
                return true;
            }
            const circle = button.querySelector?.('.mnb-tracking-button-status') || button;
            const accepted = isEventInsideElementCircle(event, circle);
            if (!accepted) {
            }
            return accepted;
        };
        const absorbPageTrackingButtonEvent = (event) => {
            const button = event.target?.closest?.(pageTrackingButtonSelector);
            if (!button) {
                return false;
            }
            if (!pageTrackingButtonAcceptsEvent(event, button)) {
                event.preventDefault?.();
                event.stopPropagation?.();
                event.stopImmediatePropagation?.();
                return true;
            }
            const wasHidden = !!this.navHUD?.hideNavigationDueToScroll;
            if (wasHidden) {
                globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay = true;
                ignoreNextIncomingRevealNavigation(`page-tracking-button.${event.type}`);
                postEbookNavigationVisibilityToNative(true, `page-tracking-button.${event.type}.preserve-hidden`, {
                    stateID: button.dataset?.pageTrackingId ?? null,
                    completionAction: button.dataset?.completionAction ?? null,
                });
            }
            event.stopPropagation?.();
            event.stopImmediatePropagation?.();
            return true;
        };
        const revealNavigationFromPageTracking = (event, source) => {
            if (event.target?.closest?.(pageTrackingButtonSelector)) {
                return false;
            }
            if (!this.navHUD?.hideNavigationDueToScroll) {
                return false;
            }
            event.preventDefault?.();
            event.stopPropagation?.();
            setNativeHideNavigationState(false, source);
            return true;
        };
        const pageTrackingButtons = document.getElementById('page-tracking-buttons');
        pageTrackingButtons?.addEventListener('touchstart', (event) => {
            if (absorbPageTrackingButtonEvent(event)) {
                return;
            }
            revealNavigationFromPageTracking(event, 'page-tracking-buttons.touchstart.reveal');
        }, { capture: true, passive: false });
        pageTrackingButtons?.addEventListener('pointerdown', (event) => {
            if (absorbPageTrackingButtonEvent(event)) {
                return;
            }
            revealNavigationFromPageTracking(event, 'page-tracking-buttons.pointerdown.reveal');
        }, { capture: true });
        pageTrackingButtons?.addEventListener('click', (event) => {
            const button = event.target?.closest?.(pageTrackingButtonSelector);
            if (!button) {
                return;
            }
            event.preventDefault?.();
            event.stopPropagation?.();
            event.stopImmediatePropagation?.();
            if (!pageTrackingButtonAcceptsEvent(event, button)) {
                return;
            }
            const wasHidden = !!this.navHUD?.hideNavigationDueToScroll;
            const completionAction = button.dataset?.completionAction;
            const stateID = button?.dataset?.pageTrackingId;
            if (wasHidden) {
                globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay = true;
                postEbookNavigationVisibilityToNative(true, 'page-tracking-button.click.preserve-hidden', {
                    stateID: stateID ?? null,
                    completionAction: completionAction ?? null,
                });
                ignoreNextIncomingRevealNavigation('page-tracking-button.click');
            } else {
                if (!completionAction && stateID) {
                    globalThis.__manabiApplyIgnoredHideNavigationOnPageTrackingAdvance = true;
                }
                ignoreNextIncomingHideNavigation('page-tracking-button.click');
            }
            if (revealNavigationFromPageTracking(event, 'page-tracking-buttons.click.reveal')) {
                return;
            }
            if (completionAction) {
                this.#handleCompletionAction(completionAction).catch((error) => console.error(error));
                return;
            }
            if (!stateID) {
                return;
            }
            this.#markPageClusterAsRead(stateID).catch((error) => console.error(error));
        });
        window.manabi_markVisiblePageAsRead = async (source = 'native') => {
            return await this.markVisiblePageAsRead(source);
        };
        window.addEventListener('resize', () => {
            this.#invalidateVisiblePageSegmentSnapshot();
        });
        window.visualViewport?.addEventListener?.('resize', () => {
            this.#invalidateVisiblePageSegmentSnapshot();
        });
        window.manabiInvalidateVisiblePageSegmentSnapshot = (reason = 'manual') => {
            this.#invalidateVisiblePageSegmentSnapshot(reason);
        };
        screen.orientation?.addEventListener?.('change', () => {
            this.#invalidateVisiblePageSegmentSnapshot();
        });
    }
    #invalidateVisiblePageSegmentSnapshot(sourceReason = 'unspecified') {
        this.visiblePageCollectionGeneration += 1;
        this.visiblePageSegmentSnapshot = null;
        window.webkit?.messageHandlers?.nativeLookupHitTargetsUpdated?.postMessage?.({
            targets: [],
            reason: 'visible-page-segment-snapshot.invalidated',
            sourceReason,
            isExplicitReset: true,
            visualViewportScale: Number.isFinite(window.visualViewport?.scale) ? window.visualViewport.scale : 1,
            viewportWidth: window.visualViewport?.width ?? window.innerWidth ?? document.documentElement?.clientWidth ?? null,
            viewportHeight: window.visualViewport?.height ?? window.innerHeight ?? document.documentElement?.clientHeight ?? null,
            viewportLeft: 0,
            viewportTop: 0,
        });
        if (this.pageTrackingRetryHandle) {
            cancelAnimationFrame(this.pageTrackingRetryHandle);
            this.pageTrackingRetryHandle = null;
        }
        if (this.nativeLookupHitTargetRefreshHandle) {
            cancelAnimationFrame(this.nativeLookupHitTargetRefreshHandle);
            this.nativeLookupHitTargetRefreshHandle = null;
        }
        if (this.hasLoadedLastPosition === true) {
            this.#scheduleNativeLookupHitTargetRefreshSettle(`invalidation:${sourceReason}`);
        }
    }
    async #syncPageTrackingButtons(reason = 'unspecified', explicitDoc = null, retryCount = 0) {
        const syncStartedAt = performance.now();
        const isRestorePending =
            reason === 'document-load'
            && globalThis.reader
            && globalThis.reader.hasLoadedLastPosition !== true;
        if (isRestorePending) {
            const diagnosticsKey = `restore-pending:${reason}`;
            if (this.lastPageTrackingDiagnosticsKey !== diagnosticsKey) {
                this.lastPageTrackingDiagnosticsKey = diagnosticsKey;
            }
            this.#queuePageTrackingRetry(reason, explicitDoc, retryCount);
            return;
        }
        const contents = this.view?.renderer?.getContents?.() || [];
        const doc = isDocumentLike(explicitDoc) ? explicitDoc : contents[0]?.doc;
        if (!isDocumentLike(doc)) {
            if (retryCount > 0) {
                const diagnosticsKey = `no-document-retry:${reason}:${contents.length}:${retryCount}`;
                if (this.lastPageTrackingDiagnosticsKey !== diagnosticsKey) {
                    this.lastPageTrackingDiagnosticsKey = diagnosticsKey;
                }
                this.#queuePageTrackingRetry(reason, explicitDoc, retryCount);
                return;
            }
            this.pageTrackingStates = [];
            this.#renderPageTrackingButtons(reason);
            const diagnosticsKey = `no-document:${reason}:${contents.length}`;
            if (this.lastPageTrackingDiagnosticsKey !== diagnosticsKey) {
                this.lastPageTrackingDiagnosticsKey = diagnosticsKey;
            }
            this.#queuePageTrackingRetry(reason, explicitDoc, retryCount);
            return;
        }
        if (this.pageTrackingRetryHandle) {
            cancelAnimationFrame(this.pageTrackingRetryHandle);
            this.pageTrackingRetryHandle = null;
        }
        const syncGeneration = this.visiblePageCollectionGeneration;
        const visibleRangeStartedAt = performanceNowMs();
        const visibleRange = this.#visibleRangeForDocument(doc);
        const visibleRangeElapsedMs = performanceNowMs() - visibleRangeStartedAt;
        if (visibleRange?.collapsed === true && retryCount > 0) {
            this.#queuePageTrackingRetry(reason, doc, retryCount);
            return;
        }
        const visibleSegmentsStartedAt = performanceNowMs();
        const visibleSegmentsResult = this.#visiblePageSegmentResult(doc, visibleRange, `page-tracking:${reason}`);
        const visibleSegmentsElapsedMs = performanceNowMs() - visibleSegmentsStartedAt;
        if (syncGeneration !== this.visiblePageCollectionGeneration) {
            return;
        }
        const buildStatesStartedAt = performanceNowMs();
        const {
            states,
            diagnostics,
        } = await buildVisiblePageTrackingStates(doc, this.articleReadingProgress, visibleRange, visibleSegmentsResult);
        const buildStatesElapsedMs = performanceNowMs() - buildStatesStartedAt;
        if (syncGeneration !== this.visiblePageCollectionGeneration) {
            return;
        }
        const visibleScreenState = states.find((state) => state.id === 'visible-screen') ?? null;
        const shouldRetryEmptyDocument =
            retryCount > 0
            && diagnostics.stateCount === 0
            && diagnostics.totalSegmentCount === 0
            && (
                !Number.isFinite(diagnostics.viewportWidth)
                || !Number.isFinite(diagnostics.viewportHeight)
                || diagnostics.viewportWidth <= 0
                || diagnostics.viewportHeight <= 0
            );
        if (shouldRetryEmptyDocument) {
            const diagnosticsKey = `empty-document:${reason}:${diagnostics.documentURL || 'nil'}`;
            if (this.lastPageTrackingDiagnosticsKey !== diagnosticsKey) {
                this.lastPageTrackingDiagnosticsKey = diagnosticsKey;
            }
            this.#queuePageTrackingRetry(reason, null, retryCount);
            return;
        }
        this.pageTrackingStates = states;
        const renderStartedAt = performanceNowMs();
        this.#renderPageTrackingButtons(reason);
        const renderElapsedMs = performanceNowMs() - renderStartedAt;
        const syncElapsedMs = performanceNowMs() - syncStartedAt;
        if (syncElapsedMs >= 12 || String(reason || '').includes('display') || String(reason || '').includes('document-load') || String(reason || '').includes('nav-buttons')) {
        }
        const diagnosticsKey = JSON.stringify({
            reason,
            documentURL: diagnostics.documentURL,
            clusterAxis: diagnostics.clusterAxis,
            totalSegmentCount: diagnostics.totalSegmentCount,
            visibleSegmentCount: diagnostics.visibleSegmentCount,
            clusterCount: diagnostics.clusterCount,
            stateCount: diagnostics.stateCount,
            completedStateCount: diagnostics.completedStateCount,
            missingIdentifierCount: diagnostics.missingIdentifierCount,
            recoveredTextSearchStringCount: diagnostics.recoveredTextSearchStringCount,
            skippedMissingSearchStringCount: diagnostics.skippedMissingSearchStringCount,
        });
        if (this.lastPageTrackingDiagnosticsKey === diagnosticsKey) {
            return;
        }
        this.lastPageTrackingDiagnosticsKey = diagnosticsKey;
        const hasAnomaly =
            diagnostics.stateCount === 0
            || diagnostics.missingIdentifierCount > 0
            || diagnostics.skippedMissingSearchStringCount > 0
            || diagnostics.outOfViewportCount > 0;
        if (!hasAnomaly) {
            return;
        }
        const event = diagnostics.stateCount === 0
            ? 'ebook.pageTracking.sync.empty'
            : 'ebook.pageTracking.sync.anomaly';
    }
    applyBookReadingProgress(articleReadingProgress, reason = 'unspecified') {
        const incomingProgress = normalizeArticleReadingProgress(articleReadingProgress);
        const incomingReadSegmentCount = incomingProgress.readSegmentIdentifiers.length;
        const incomingSentenceReadCount = incomingProgress.sentenceIdentifiersRead.length;
        const incomingReadSegmentIdentifiers = new Set(incomingProgress.readSegmentIdentifiers);
        const incomingSentenceIdentifiersRead = new Set(incomingProgress.sentenceIdentifiersRead);
        let mergedOptimisticSegmentCount = 0;
        let mergedOptimisticSentenceCount = 0;
        for (const segmentIdentifier of this.optimisticReadSegmentIdentifiers) {
            if (!incomingReadSegmentIdentifiers.has(segmentIdentifier)) {
                mergedOptimisticSegmentCount += 1;
            }
            incomingReadSegmentIdentifiers.add(segmentIdentifier);
        }
        for (const sentenceIdentifier of this.optimisticSentenceIdentifiersRead) {
            if (!incomingSentenceIdentifiersRead.has(sentenceIdentifier)) {
                mergedOptimisticSentenceCount += 1;
            }
            incomingSentenceIdentifiersRead.add(sentenceIdentifier);
        }
        incomingProgress.readSegmentIdentifiers = Array.from(incomingReadSegmentIdentifiers);
        incomingProgress.sentenceIdentifiersRead = Array.from(incomingSentenceIdentifiersRead);
        if (mergedOptimisticSegmentCount > 0 || mergedOptimisticSentenceCount > 0) {
        }
        this.articleReadingProgress = incomingProgress;
        this.markedAsFinished = !!this.articleReadingProgress.articleMarkedAsFinished;
        this.pageTrackingBusyStateIDs.clear();
        this.completionActionBusy = false;
        const progressKey = JSON.stringify({
            articleMarkedAsFinished: this.articleReadingProgress.articleMarkedAsFinished,
            sentenceIdentifiersRead: this.articleReadingProgress.sentenceIdentifiersRead.length,
            readSegmentIdentifiers: this.articleReadingProgress.readSegmentIdentifiers.length,
            articleSentenceCount: this.articleReadingProgress.articleSentenceCount,
        });
        if (this.lastBookReadingProgressKey !== progressKey) {
            this.lastBookReadingProgressKey = progressKey;
        }
        this.#syncPageTrackingButtons('progress-applied', null, 2).catch((error) => console.error(error));
    }
    async #handleCompletionAction(actionType) {
        if (this.completionActionBusy) {
            return;
        }
        this.completionActionBusy = true;
        this.#renderPageTrackingButtons('completion-action-busy');
        try {
            switch (actionType) {
                case 'finish':
                    const sectionReadState = this.#currentSectionReadState();
                    window.webkit.messageHandlers.finishedReadingBook.postMessage({
                        topWindowURL: window.top.location.href,
                        allSectionsRead: sectionReadState.allSectionsRead,
                        currentPageNumber: sectionReadState.currentPageNumber,
                        totalPages: sectionReadState.totalPages,
                        pagesLeft: sectionReadState.pagesLeft,
                        segmentCount: sectionReadState.segmentCount,
                        unreadSegmentCount: sectionReadState.unreadSegmentCount,
                    });
                    break;
                case 'restart':
                    this.#clearOptimisticMarkReadState('restart');
                    window.webkit.messageHandlers.startOver.postMessage({});
                    await this.view?.renderer?.firstSection?.();
                    break;
                default:
                    break;
            }
        } finally {
            if (actionType !== 'finish') {
                this.completionActionBusy = false;
                this.#renderPageTrackingButtons('completion-action-finished');
            }
        }
    }
    #currentSectionReadState() {
        const currentPageNumber = typeof this.navHUD?.rendererPageSnapshot?.current === 'number'
            ? this.navHUD.rendererPageSnapshot.current
            : (typeof this.navHUD?.lastRelocateDetail?.pageNumber === 'number'
                ? this.navHUD.lastRelocateDetail.pageNumber
                : null);
        const totalPages = typeof this.navHUD?.rendererPageSnapshot?.total === 'number'
            ? this.navHUD.rendererPageSnapshot.total
            : (typeof this.navHUD?.lastRelocateDetail?.pageCount === 'number'
                ? this.navHUD.lastRelocateDetail.pageCount
                : null);
        const pagesLeft = typeof currentPageNumber === 'number' && typeof totalPages === 'number'
            ? Math.max(0, totalPages - currentPageNumber)
            : null;
        const contents = this.view?.renderer?.getContents?.() || [];
        const doc = contents[0]?.doc;
        if (!isDocumentLike(doc)) {
            return {
                allSectionsRead: true,
                reason: 'missing-document',
                documentURL: null,
                currentPageNumber,
                totalPages,
                pagesLeft,
                segmentCount: 0,
                readSegmentCount: 0,
                unreadSegmentCount: 0,
                optimisticReadSegmentCount: this.optimisticReadSegmentIdentifiers.size,
            };
        }
        const segmentIdentifiers = Array.from(doc.querySelectorAll('mnb-seg'))
            .map((segmentNode) => segmentIdentifierForNode(segmentNode))
            .filter((identifier) => typeof identifier === 'string' && identifier.length > 0);
        const segmentIdentifierAliasSets = Array.from(doc.querySelectorAll('mnb-seg'))
            .map((segmentNode) => ({
                aliases: segmentIdentifierAliasesForNode(segmentNode),
                sentenceIdentifier: sentenceIdentifierForNode(segmentNode.closest?.('mnb-sen')),
            }))
            .filter((item) => item.aliases.length > 0);
        if (segmentIdentifiers.length === 0) {
            return {
                allSectionsRead: true,
                reason: 'empty-section',
                documentURL: doc.URL || doc.location?.href || null,
                currentPageNumber,
                totalPages,
                pagesLeft,
                segmentCount: 0,
                readSegmentCount: 0,
                unreadSegmentCount: 0,
                optimisticReadSegmentCount: this.optimisticReadSegmentIdentifiers.size,
            };
        }
        const readSegmentIdentifiers = new Set([
            ...normalizeArticleReadingProgress(this.articleReadingProgress).readSegmentIdentifiers,
            ...this.optimisticReadSegmentIdentifiers,
        ]);
        const readSentenceIdentifiers = new Set([
            ...normalizeArticleReadingProgress(this.articleReadingProgress).sentenceIdentifiersRead,
            ...this.optimisticSentenceIdentifiersRead,
        ]);
        const unreadSegmentCount = segmentIdentifierAliasSets
            .filter((item) => !(item.sentenceIdentifier && readSentenceIdentifiers.has(item.sentenceIdentifier))
                && !item.aliases.some((identifier) => readSegmentIdentifiers.has(identifier)))
            .length;
        if (unreadSegmentCount > 0) {
            const unreadSegmentIdentifiers = segmentIdentifierAliasSets
                .filter((item) => !(item.sentenceIdentifier && readSentenceIdentifiers.has(item.sentenceIdentifier))
                    && !item.aliases.some((identifier) => readSegmentIdentifiers.has(identifier)))
                .map((item) => item.aliases[0])
                .filter((identifier) => typeof identifier === 'string' && identifier.length > 0);
        }
        return {
            allSectionsRead: unreadSegmentCount === 0,
            reason: 'segments',
            documentURL: doc.URL || doc.location?.href || null,
            currentPageNumber,
            totalPages,
            pagesLeft,
            segmentCount: segmentIdentifiers.length,
            readSegmentCount: segmentIdentifiers.length - unreadSegmentCount,
            unreadSegmentCount,
            optimisticReadSegmentCount: this.optimisticReadSegmentIdentifiers.size,
        };
    }
    buildMarkAllSectionsAsReadPayload() {
        const contents = this.view?.renderer?.getContents?.() || [];
        const doc = contents[0]?.doc;
        if (!isDocumentLike(doc)) {
            return null;
        }
        const segmentNodes = Array.from(doc.querySelectorAll('mnb-seg'))
            .filter((segmentNode) => !segmentNode.closest('.tippy-box'));
        const segmentsByIdentifier = new Map();
        const sentenceIdentifiers = new Set();
        let skippedMissingIdentifierCount = 0;
        let skippedMissingSearchStringCount = 0;
        for (const segmentNode of segmentNodes) {
            const segmentIdentifier = segmentIdentifierForNode(segmentNode);
            if (typeof segmentIdentifier !== 'string' || segmentIdentifier.length === 0) {
                skippedMissingIdentifierCount += 1;
                continue;
            }
            if (segmentsByIdentifier.has(segmentIdentifier)) {
                continue;
            }
            const metadata = segmentMetadataForNode(segmentNode);
            let searchString = metadata?.s || metadata?.ns;
            if (typeof searchString !== 'string' || searchString.length === 0) {
                searchString = segmentNode.textContent?.trim?.() || '';
            }
            if (searchString.length === 0) {
                skippedMissingSearchStringCount += 1;
                continue;
            }
            const sentenceNode = segmentNode.closest('mnb-sen');
            const sentenceIdentifier = sentenceIdentifierForNode(sentenceNode);
            if (sentenceIdentifier) {
                sentenceIdentifiers.add(sentenceIdentifier);
            }
            const { sentenceHTML, sentenceJMDictIDs } = buildExampleSentenceForSegment(segmentNode);
            segmentsByIdentifier.set(segmentIdentifier, {
                jmdictEntryIds: segmentEntryIDsForNode(segmentNode, 'jmdict'),
                jmnedictEntryIds: segmentEntryIDsForNode(segmentNode, 'jmnedict'),
                searchString,
                displayText: segmentNode.textContent?.trim?.() || searchString,
                segmentIdentifier,
                exampleSentence: sentenceHTML,
                exampleSentenceJMDictIDs: sentenceJMDictIDs,
            });
        }
        const payloadSegments = Array.from(segmentsByIdentifier.values());
        const payloadSentenceIdentifiers = Array.from(sentenceIdentifiers);
        const payloadSegmentIdentifiers = payloadSegments
            .map((segment) => segment.segmentIdentifier)
            .filter((segmentIdentifier) => typeof segmentIdentifier === 'string' && segmentIdentifier.length > 0);
        if (payloadSegments.length === 0) {
            return null;
        }
        return {
            segments: payloadSegments,
            sentenceIdentifiers: payloadSentenceIdentifiers,
        };
    }
    applyOptimisticMarkAllSectionsAsReadPayload(payload) {
        const payloadSegments = Array.isArray(payload?.segments) ? payload.segments : [];
        const payloadSentenceIdentifiers = Array.isArray(payload?.sentenceIdentifiers) ? payload.sentenceIdentifiers : [];
        const payloadSegmentIdentifiers = payloadSegments
            .map((segment) => segment.segmentIdentifier)
            .filter((segmentIdentifier) => typeof segmentIdentifier === 'string' && segmentIdentifier.length > 0);
        for (const segmentIdentifier of payloadSegmentIdentifiers) {
            this.optimisticReadSegmentIdentifiers.add(segmentIdentifier);
        }
        for (const sentenceIdentifier of payloadSentenceIdentifiers) {
            this.optimisticSentenceIdentifiersRead.add(sentenceIdentifier);
        }
        const optimisticProgress = normalizeArticleReadingProgress(this.articleReadingProgress);
        optimisticProgress.readSegmentIdentifiers = Array.from(new Set([
            ...optimisticProgress.readSegmentIdentifiers,
            ...payloadSegmentIdentifiers,
        ]));
        optimisticProgress.sentenceIdentifiersRead = Array.from(new Set([
            ...optimisticProgress.sentenceIdentifiersRead,
            ...payloadSentenceIdentifiers,
        ]));
        this.applyBookReadingProgress(optimisticProgress, 'optimistic-mark-all-read');
        return payloadSegments.length;
    }
    async markAllSectionsAsRead() {
        const payload = this.buildMarkAllSectionsAsReadPayload();
        if (!payload) {
            return 0;
        }
        window.webkit.messageHandlers.markSectionAsRead.postMessage(payload);
        return this.applyOptimisticMarkAllSectionsAsReadPayload(payload);
    }
    async #markPageClusterAsRead(stateID) {
        const pageTrackingState = this.pageTrackingStates.find((state) => state.id === stateID);
        if (!pageTrackingState) {
            return;
        }
        if (pageTrackingState.payload.segments.length === 0) {
            return;
        }
        if (pageTrackingState.isRead) {
            return;
        }
        this.pageTrackingBusyStateIDs.add(stateID);
        this.#renderPageTrackingButtons('mark-read-busy');
        window.webkit.messageHandlers.markSectionAsRead.postMessage(pageTrackingState.payload);
        const payloadSegmentIdentifiers = pageTrackingState.payload.segments
            .map((segment) => segment.segmentIdentifier)
            .filter((segmentIdentifier) => typeof segmentIdentifier === 'string' && segmentIdentifier.length > 0);
        const payloadSentenceIdentifiers = pageTrackingState.payload.sentenceIdentifiers
            .filter((sentenceIdentifier) => typeof sentenceIdentifier === 'string' && sentenceIdentifier.length > 0);
        for (const segmentIdentifier of payloadSegmentIdentifiers) {
            this.optimisticReadSegmentIdentifiers.add(segmentIdentifier);
        }
        for (const sentenceIdentifier of payloadSentenceIdentifiers) {
            this.optimisticSentenceIdentifiersRead.add(sentenceIdentifier);
        }
        const optimisticProgress = normalizeArticleReadingProgress(this.articleReadingProgress);
        optimisticProgress.readSegmentIdentifiers = Array.from(new Set([
            ...optimisticProgress.readSegmentIdentifiers,
            ...payloadSegmentIdentifiers,
        ]));
        optimisticProgress.sentenceIdentifiersRead = Array.from(new Set([
            ...optimisticProgress.sentenceIdentifiersRead,
            ...payloadSentenceIdentifiers,
        ]));
        this.pageTrackingAnimateReadStateIDs.add(stateID);
        this.applyBookReadingProgress(optimisticProgress, 'optimistic-mark-read');
        await this.#advanceAfterMarkRead();
    }
    async markVisiblePageAsRead(source = 'native') {
        const completionAction = this.completionAction;
        if (completionAction) {
            if (this.completionActionBusy) {
                return false;
            }
            const wasHidden = !!this.navHUD?.hideNavigationDueToScroll;
            if (wasHidden) {
                globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay = true;
                postEbookNavigationVisibilityToNative(true, 'native-page-tracking-button.preserve-hidden', {
                    completionAction: completionAction.type ?? null,
                    source,
                });
                ignoreNextIncomingRevealNavigation('native-page-tracking-button');
            } else {
                ignoreNextIncomingHideNavigation('native-page-tracking-button');
            }
            await this.#handleCompletionAction(completionAction.type);
            return true;
        }
        const stateID = 'visible-screen';
        const pageTrackingState = this.pageTrackingStates.find((state) => state.id === stateID);
        if (!pageTrackingState) {
            return false;
        }
        const wasHidden = !!this.navHUD?.hideNavigationDueToScroll;
        if (wasHidden) {
            globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay = true;
            postEbookNavigationVisibilityToNative(true, 'native-page-tracking-button.preserve-hidden', {
                stateID,
                source,
            });
            ignoreNextIncomingRevealNavigation('native-page-tracking-button');
        } else {
            globalThis.__manabiApplyIgnoredHideNavigationOnPageTrackingAdvance = true;
            ignoreNextIncomingHideNavigation('native-page-tracking-button');
        }
        await this.#markPageClusterAsRead(stateID);
        return true;
    }
    #renderPageTrackingButtons(reason = 'unspecified') {
        const container = document.getElementById('page-tracking-container');
        const buttonHost = document.getElementById('page-tracking-buttons');
        const postNativeMarkReadState = (available, state = null, isBusy = false) => {
            try {
                window.webkit?.messageHandlers?.ebookNativeMarkReadState?.postMessage?.({
                    available: !!available,
                    isRead: !!state?.isRead,
                    isBusy: !!isBusy,
                    hasAnyMarkedReadContent: !!state?.hasAnyMarkedReadContent,
                    stateID: state?.id ?? null,
                    reason,
                });
            } catch (_error) {}
        };
        const pageTrackingStates = this.pageTrackingStates || [];
        const hasStates = pageTrackingStates.length > 0;
        const completionAction = this.completionAction;
        const markReadButtonsVisible = document.body?.dataset?.mnbMarkReadButtonsVisible !== 'false';
        const visibleState = pageTrackingStates.find((state) => state.id === 'visible-screen') ?? null;
        const nativeMarkReadState = completionAction
            ? {
                id: `completion-action:${completionAction.type ?? 'unknown'}`,
                isRead: false,
                hasAnyMarkedReadContent: false,
            }
            : visibleState;
        const nativeMarkReadAvailable = markReadButtonsVisible && (!!completionAction || !!nativeMarkReadState);
        const nativeMarkReadBusy = completionAction
            ? !!this.completionActionBusy
            : this.pageTrackingBusyStateIDs.has(nativeMarkReadState?.id);
        const clearHTMLButtons = () => {
            if (container instanceof HTMLElement) container.hidden = true;
            if (buttonHost instanceof HTMLElement) {
                buttonHost.hidden = true;
                buttonHost.innerHTML = '';
            }
            this.lastPageTrackingVisibility = false;
        };

        if (!(container instanceof HTMLElement) || !(buttonHost instanceof HTMLElement)) {
            this.#updatePageReadMarker(reason, visibleState);
            this.navHUD?.refreshAuxiliaryLayout?.();
            postNativeMarkReadState(nativeMarkReadAvailable, nativeMarkReadState, nativeMarkReadBusy);
            return;
        }

        if (!MANABI_ENABLE_EBOOK_PAGE_TRACKING_BUTTONS) {
            clearHTMLButtons();
            this.#updatePageReadMarker(reason, visibleState);
            this.navHUD?.refreshAuxiliaryLayout?.();
            postNativeMarkReadState(nativeMarkReadAvailable, nativeMarkReadState, nativeMarkReadBusy);
            return;
        }

        const shouldShowPageTracking = markReadButtonsVisible && (!!completionAction || hasStates);
        container.hidden = !shouldShowPageTracking;
        buttonHost.hidden = !shouldShowPageTracking;
        this.lastPageTrackingVisibility = shouldShowPageTracking;
        if (!shouldShowPageTracking) {
            buttonHost.innerHTML = '';
            this.#updatePageReadMarker(reason, null);
            this.navHUD?.refreshAuxiliaryLayout?.();
            postNativeMarkReadState(false, visibleState);
            return;
        }
        if (completionAction) {
            const isBusy = !!this.completionActionBusy;
            buttonHost.innerHTML = `
                <button
                    class="page-read-button mnb-tracking-button"
                    data-completion-action="${completionAction.type}"
                    data-completion-tone="${completionAction.tone}"
                    data-mnb-force-expanded="true"
                    aria-label="${completionAction.label}"
                    ${isBusy ? 'disabled' : ''}
                >
                    <span class="mnb-tracking-button-status" aria-hidden="true"></span>
                    <span class="mnb-tracking-button-label" aria-hidden="true">${completionAction.label}</span>
                    <span class="sr-only">${completionAction.label}</span>
                </button>
            `;
            this.#updatePageReadMarker(reason, null);
            this.navHUD?.syncPageTrackingButtonsNavigationDisabled?.();
            this.navHUD?.refreshAuxiliaryLayout?.();
            this.#scheduleInitialPaginatorSettle('page-tracking-render.completion-action');
            postNativeMarkReadState(true, nativeMarkReadState, isBusy);
            return;
        }
        postNativeMarkReadState(
            !!visibleState,
            visibleState,
            this.pageTrackingBusyStateIDs.has('visible-screen')
        );
        buttonHost.innerHTML = pageTrackingStates.map((state) => {
            const isBusy = this.pageTrackingBusyStateIDs.has(state.id);
            const readState = isBusy ? 'pending' : (state.isRead ? 'complete' : 'ready');
            const shouldAnimateRead = this.pageTrackingAnimateReadStateIDs.has(state.id)
                && state.id === 'visible-screen'
                && !!state.isRead
                && !isBusy;
            if (shouldAnimateRead || (this.pageTrackingAnimateReadStateIDs.has(state.id) && !!state.isRead && !isBusy)) {
                this.pageTrackingAnimateReadStateIDs.delete(state.id);
            }
            return `
                <button
                    class="page-read-button mnb-tracking-button"
                    data-page-tracking-id="${state.id}"
                    data-read-state="${readState}"
                    data-mnb-animate-read="${shouldAnimateRead ? 'true' : 'false'}"
                    data-mnb-tracking-section-read="${state.isRead ? 'true' : 'false'}"
                    data-mnb-has-any-marked-read="${state.hasAnyMarkedReadContent ? 'true' : 'false'}"
                    aria-label="${state.fullLabel}"
                    ${state.isRead || isBusy ? 'disabled' : ''}
                >
                    <span class="mnb-tracking-button-status" aria-hidden="true">
                        <span class="mnb-tracking-status-checkmark" aria-hidden="true"></span>
                    </span>
                    <span class="mnb-tracking-button-label" aria-hidden="true">${state.shortLabel}</span>
                    <span class="sr-only">${state.fullLabel}</span>
                </button>
            `;
        }).join('');
        this.#updatePageReadMarker(reason);
        this.navHUD?.syncPageTrackingButtonsNavigationDisabled?.();
        this.navHUD?.refreshAuxiliaryLayout?.();
        this.#scheduleInitialPaginatorSettle('page-tracking-render');
    }
    #pageTurnDirectionForMove(method) {
        if (method === 'goLeft') {
            return this.isRTL ? 'forward' : 'backward';
        }
        if (method === 'goRight') {
            return this.isRTL ? 'backward' : 'forward';
        }
        return null;
    }
    #applyPageTurnNavigationVisibility(method, source) {
        const direction = this.#pageTurnDirectionForMove(method);
        if (direction !== 'forward' && direction !== 'backward') {
            return;
        }
        this.#applyLogicalPageTurnNavigationVisibility(direction, source, { method });
    }
    #applyLogicalPageTurnNavigationVisibility(direction, source, details = {}) {
        if (direction !== 'forward' && direction !== 'backward') {
            return;
        }
        const shouldHide = direction === 'forward';
        try {
            markCacheWarmerForegroundActivity?.(`page-turn.${source}`);
        } catch (_) {}
        try {
            recordPageTurnNavigationIntent?.(direction, source, {
                isRTL: this.isRTL,
                ...details,
            });
        } catch (_) {}
        this.navHUD?.setHideNavigationDueToScroll?.(shouldHide, source, {
            direction,
            isRTL: this.isRTL,
            ...details,
        });
        postEbookNavigationVisibilityToNative?.(shouldHide, source, {
            direction,
            isRTL: this.isRTL,
            ...details,
        });
    }
    #pageReadMarkerTransitionMode(reason = 'unspecified') {
        const value = String(reason || '');
        if (
            value === 'page-turn-start'
            || value.startsWith('relocate')
            || value.startsWith('goTo')
            || value.startsWith('did-display')
            || value.startsWith('page-tracking-visibility.relocate')
        ) {
            return 'instant';
        }
        return 'animated';
    }
    #updatePageReadMarker(reason = 'unspecified', explicitState = null, explicitDoc = null) {
        const transitionMode = this.#pageReadMarkerTransitionMode(reason);
        const state = explicitState || (this.pageTrackingStates || []).find((candidate) => candidate.id === 'visible-screen') || null;
        let isRead = !!state?.isRead && !this.completionAction;
        if (explicitState) {
            this.pageReadMarkerAwaitingPageState = false;
        } else if (this.pageReadMarkerAwaitingPageState && isRead) {
            isRead = false;
        }
        const doc = isDocumentLike(explicitDoc)
            ? explicitDoc
            : (this.view?.renderer?.getContents?.()?.[0]?.doc ?? null);
        const isVertical = !!doc?.body?.classList?.contains?.('reader-vertical-writing');
        const readerStage = document.getElementById('reader-stage');
        const preferredFoliateView = this.view?.isConnected ? this.view : null;
        const liveFoliateView =
            (preferredFoliateView && preferredFoliateView.offsetParent !== null ? preferredFoliateView : null)
            || document.querySelector('foliate-view:not([hidden])')
            || preferredFoliateView
            || null;
        if (readerStage instanceof HTMLElement) {
            readerStage.style.removeProperty('--mnb-ebook-read-marker-top-left');
            readerStage.style.removeProperty('--mnb-ebook-read-marker-top-width');
            const stageRect = readerStage.getBoundingClientRect();
            const viewRect = liveFoliateView?.getBoundingClientRect?.() || null;
            const livePaginator = resolveFoliatePaginator(liveFoliateView);
            const paginatorContainer = livePaginator?.shadowRoot?.getElementById?.('container') || null;
            const containerRect = paginatorContainer?.getBoundingClientRect?.() || null;
            const rootStyle = getComputedStyle(document.documentElement);
            const thickness = parseFloat(rootStyle.getPropertyValue('--mnb-tracking-section-border-size')) || 2;
            const sideNavWidth = parseFloat(rootStyle.getPropertyValue('--side-nav-width')) || 32;
            const containerStyle = containerRect ? getComputedStyle(paginatorContainer) : null;
            const containerTopMargin = parseFloat(containerStyle?.getPropertyValue('--_top-margin')) || 0;
            const containerBottomMargin = parseFloat(containerStyle?.getPropertyValue('--_bottom-margin')) || 0;
            const markerAnchorRect = containerRect && containerRect.width > 0 && containerRect.height > 0
                ? containerRect
                : viewRect;
            if (markerAnchorRect && markerAnchorRect.width > 0 && markerAnchorRect.height > 0 && stageRect.width > 0) {
                const markerLeft = markerAnchorRect.left - stageRect.left - thickness;
                const markerTopInset = markerAnchorRect === containerRect ? containerTopMargin : 0;
                const markerBottomInset = markerAnchorRect === containerRect ? containerBottomMargin : 0;
                const markerHeight = Math.max(0, markerAnchorRect.height - markerTopInset - markerBottomInset);
                readerStage.style.setProperty('--mnb-ebook-read-marker-side-left', `${markerLeft}px`);
                readerStage.style.setProperty('--mnb-ebook-read-marker-side-top', `${Math.max(0, markerAnchorRect.top - stageRect.top + markerTopInset)}px`);
                readerStage.style.setProperty('--mnb-ebook-read-marker-side-height', `${markerHeight}px`);
            } else if (stageRect.width > 0) {
                const markerLeft = Math.max(0, sideNavWidth - thickness);
                readerStage.style.setProperty('--mnb-ebook-read-marker-side-left', `${markerLeft}px`);
                readerStage.style.setProperty('--mnb-ebook-read-marker-side-top', '0px');
                readerStage.style.setProperty('--mnb-ebook-read-marker-side-height', `${stageRect.height}px`);
            } else {
                readerStage.style.removeProperty('--mnb-ebook-read-marker-side-left');
                readerStage.style.removeProperty('--mnb-ebook-read-marker-side-top');
                readerStage.style.removeProperty('--mnb-ebook-read-marker-side-height');
            }
        }
        document.body?.setAttribute?.('data-page-read-marker-transition', transitionMode);
        document.body?.setAttribute?.('data-page-read-marker-read', isRead ? 'true' : 'false');
        document.body?.setAttribute?.('data-page-read-marker-axis', isVertical ? 'block' : 'inline');
    }
    #clearVisiblePageReadChrome(reason = 'unspecified') {
        const isPageTurnStart = reason === 'page-turn-start' || reason === 'lookup-navigation-page-turn-start';
        if (isPageTurnStart) {
            this.#invalidateVisiblePageSegmentSnapshot(reason);
            this.pageReadMarkerAwaitingPageState = true;
        }
        document.body?.setAttribute?.('data-page-read-marker-transition', this.#pageReadMarkerTransitionMode(reason));
        document.body?.setAttribute?.('data-page-read-marker-read', 'false');
    }
    #clearOptimisticMarkReadState(_reason = 'unspecified') {
        this.optimisticReadSegmentIdentifiers.clear();
        this.optimisticSentenceIdentifiersRead.clear();
    }
    #queuePageTrackingRetry(reason, explicitDoc, retryCount) {
        if (retryCount <= 0) {
            return;
        }
        if (this.pageTrackingRetryHandle) {
            cancelAnimationFrame(this.pageTrackingRetryHandle);
        }
        this.pageTrackingRetryHandle = requestAnimationFrame(() => {
            this.pageTrackingRetryHandle = null;
            this.#syncPageTrackingButtons(reason, explicitDoc, retryCount - 1).catch((error) => console.error(error));
        });
    }
    #schedulePageTrackingSync(reason = 'unspecified', explicitDoc = null, retryCount = 0, delayMs = 0) {
        if (this.pageTrackingDeferredHandle) {
            clearTimeout(this.pageTrackingDeferredHandle);
            this.pageTrackingDeferredHandle = null;
        }
        if (this.pageTrackingDeferredFrameHandle) {
            cancelAnimationFrame(this.pageTrackingDeferredFrameHandle);
            this.pageTrackingDeferredFrameHandle = null;
        }
        this.pageTrackingDeferredHandle = setTimeout(() => {
            this.pageTrackingDeferredHandle = null;
            this.pageTrackingDeferredFrameHandle = requestAnimationFrame(() => {
                this.pageTrackingDeferredFrameHandle = null;
                this.#syncPageTrackingButtons(reason, explicitDoc, retryCount).catch((error) => console.error(error));
            });
        }, Math.max(0, Number(delayMs) || 0));
    }
    #visibleRangeForDocument(doc) {
        const range = this.navHUD?.lastRelocateDetail?.range ?? null;
        return range?.commonAncestorContainer?.ownerDocument === doc
            || range?.startContainer?.ownerDocument === doc
            || range?.endContainer?.ownerDocument === doc
            ? range
            : null;
    }
    #visiblePageSegmentResult(doc, visibleRange = null, reason = 'visible-page-segment-result', {
        postIfCached = false,
        postLookupTargets = true,
        prepareLookupIndex = true,
    } = {}) {
        const snapshot = this.visiblePageSegmentSnapshot;
        const documentIdentity = visibleSegmentCollectionDocumentIdentity(doc);
        if (snapshot
            && snapshot.generation === this.visiblePageCollectionGeneration
            && snapshot.doc === doc
            && snapshot.visibleRange === visibleRange
            && snapshot.documentURL === documentIdentity.documentURL
            && snapshot.sidecarRevision === documentIdentity.sidecarRevision) {
            if (prepareLookupIndex && !snapshot.lookupIndex) {
                snapshot.lookupIndex = buildVisiblePageLookupIndex(doc, snapshot.result, reason);
            }
            if (prepareLookupIndex && snapshot.lookupIndex) {
                snapshot.result.lookupIndex = snapshot.lookupIndex;
            }
            if (postLookupTargets && postIfCached) {
                postNativeLookupHitTargetsForVisibleSegments(doc, snapshot.result, reason);
            }
            return snapshot.result;
        }
        const result = collectVisibleSegmentNodesFromRange(doc, visibleRange);
        const lookupIndex = prepareLookupIndex
            ? buildVisiblePageLookupIndex(doc, result, reason)
            : null;
        if (lookupIndex) {
            result.lookupIndex = lookupIndex;
        }
        this.visiblePageSegmentSnapshot = {
            generation: this.visiblePageCollectionGeneration,
            doc,
            visibleRange,
            documentURL: documentIdentity.documentURL,
            sidecarRevision: documentIdentity.sidecarRevision,
            result,
            lookupIndex,
        };
        if (postLookupTargets) {
            postNativeLookupHitTargetsForVisibleSegments(doc, result, reason);
        }
        return result;
    }
    #scheduleNativeLookupHitTargetRefreshSettle(reason = 'unspecified', explicitDoc = null) {
        if (this.nativeLookupHitTargetRefreshHandle) {
            cancelAnimationFrame(this.nativeLookupHitTargetRefreshHandle);
            this.nativeLookupHitTargetRefreshHandle = null;
        }
        this.nativeLookupHitTargetRefreshHandle = requestAnimationFrame(() => {
            this.nativeLookupHitTargetRefreshHandle = null;
            const docs = isDocumentLike(explicitDoc)
                ? [explicitDoc]
                : this.#lookupContentWindows().map((view) => view.document).filter(isDocumentLike);
            for (const doc of docs) {
                const visibleRange = this.#visibleRangeForDocument(doc);
                this.#visiblePageSegmentResult(doc, visibleRange, `scheduled:${reason}`, { postIfCached: true });
            }
        });
    }
    refreshNativeLookupHitTargets(reason = 'manual') {
        this.visiblePageSegmentSnapshot = null;
        this.#scheduleNativeLookupHitTargetRefreshSettle(reason);
        setTimeout(() => {
            this.visiblePageSegmentSnapshot = null;
            this.#scheduleNativeLookupHitTargetRefreshSettle(`${reason}.settled`);
        }, 180);
    }
    #updateEbookSubscriptionPreviewPageState({
        localSectionIndex = null,
    } = {}) {
        const isFirstPageInSection = localSectionIndex === 0;
        const docs = this.view?.renderer?.getContents?.()
            ?.map((content) => content?.doc)
            ?.filter(isDocumentLike) || [];
        for (const doc of docs) {
            const body = doc.body;
            if (!body) continue;
            const isSubscribed = body.getAttribute('data-mnb-subscription-is-active') === 'true'
                || body.getAttribute('data-manabi-subscription-is-active') === 'true';
            const previewValue = !isSubscribed && isFirstPageInSection ? 'true' : 'false';
            if (body.getAttribute('data-mnb-ebook-subscription-preview-page') !== previewValue) {
                body.setAttribute('data-mnb-ebook-subscription-preview-page', previewValue);
            }
            if (body.getAttribute('data-manabi-ebook-subscription-preview-page') !== previewValue) {
                body.setAttribute('data-manabi-ebook-subscription-preview-page', previewValue);
            }
        }
    }
    #postBookInsetSnapshot(_event, _extra = {}) {
    }
    async #waitForAnimationFrames(count = 1) {
        const frameCount = Math.max(0, Number(count) || 0);
        for (let index = 0; index < frameCount; index += 1) {
            await new Promise((resolve) => requestAnimationFrame(() => resolve()));
        }
    }
    async #settleInitialPaginatorLayout(reason = 'unknown', { force = false, forceRender = false } = {}) {
        if (MANABI_DISABLE_INITIAL_PAGINATOR_SETTLE) {
            return { rendered: false, reason: 'initial-paginator-settle-disabled' };
        }
        if (this.hasSettledInitialPaginatorLayout && !force) {
            return { rendered: false, reason: 'already-settled' };
        }
        const renderer = this.view?.renderer;
        if (!renderer || typeof renderer.renderIfContainerSizeChanged !== 'function') {
            return { rendered: false, reason: 'unavailable' };
        }
        try {
            applyStoredChromeInsets?.(`initial-paginator-settle.${reason}`);
            let result = await renderer.renderIfContainerSizeChanged(`initial-paginator-settle.${reason}`);
            if (forceRender && !result?.rendered && typeof renderer.render === 'function') {
                await renderer.render();
                result = { ...(result ?? {}), rendered: true, forcedRender: true };
            }
            this.hasSettledInitialPaginatorLayout = true;
            return result ?? { rendered: false, reason: 'unknown' };
        } catch (error) {
            console.error(error);
            this.hasSettledInitialPaginatorLayout = false;
            return { rendered: false, reason: 'error', message: error?.message ?? String(error) };
        }
    }
    #scheduleInitialPaginatorSettle(reason = 'unknown') {
        if (MANABI_DISABLE_INITIAL_PAGINATOR_SETTLE
            || this.hasSettledInitialPaginatorLayout
            || this.initialPaginatorSettleHandle) {
            return;
        }
        const renderer = this.view?.renderer;
        if (!renderer || typeof renderer.renderIfContainerSizeChanged !== 'function') {
            return;
        }
        this.initialPaginatorSettleHandle = requestAnimationFrame(async () => {
            this.initialPaginatorSettleHandle = null;
            await this.#settleInitialPaginatorLayout(reason);
        });
    }
    async #advanceAfterMarkRead() {
        await new Promise((resolve) => setTimeout(resolve, 430));
        if (this.isRTL) {
            await this.view?.goLeft?.();
        } else {
            await this.view?.goRight?.();
        }
    }
    #flashSideNavChevron(direction) {
        const key = direction === 'left' ? 'l' : 'r';
        const icon = document.querySelector(`#btn-scroll-${direction} .icon`);
        if (!icon) {
            return;
        }
        clearTimeout(this.#chevronFadeTimers[key]);
        this.#chevronFadeTimers[key] = null;
        icon.style.removeProperty('opacity');
        icon.style.removeProperty('visibility');
        icon.classList.add('chevron-visible');
        this.#chevronFadeTimers[key] = setTimeout(() => {
            icon.classList.remove('chevron-visible');
            icon.style.removeProperty('opacity');
            icon.style.removeProperty('visibility');
            this.#chevronFadeTimers[key] = null;
        }, 180);
    }
    #onMainDocumentTouchStart(event) {
        if (window.manabiNativePageTurnOwnsDrag === true) {
            this.#mainDocumentSwipeState = null;
            return;
        }
        if (event.touches?.length !== 1) {
            this.#mainDocumentSwipeState = null;
            return;
        }
        const touch = event.changedTouches?.[0];
        const target = event.target;
        if (!touch || !target || target.ownerDocument !== document) {
            this.#mainDocumentSwipeState = null;
            return;
        }
        const isExcludedTouchTarget = target.closest?.('#reader-stage, #side-bar, #page-tracking-container, #nav-hidden-overlay, .side-nav, input, textarea, select, button, a, [role="button"], [contenteditable="true"]');
        const isInteractiveNavTarget = target.closest?.('#progress-wrapper, #nav-section-progress-center, #nav-primary-text, #nav-hidden-primary-text, #nav-bottom-row input, #nav-bottom-row button, .nav-relocate-button');
        if (isExcludedTouchTarget || isInteractiveNavTarget) {
            this.#mainDocumentSwipeState = null;
            return;
        }
        this.#mainDocumentSwipeState = {
            startX: touch.screenX,
            startY: touch.screenY,
            triggered: false,
            chevronActive: false,
            nativeLookupCancelled: false,
        };
    }
    async #onMainDocumentTouchMove(event) {
        if (window.manabiNativePageTurnOwnsDrag === true) return;
        const state = this.#mainDocumentSwipeState;
        if (!state || state.triggered) {
            return;
        }
        const touch = event.changedTouches?.[0];
        if (!touch) {
            return;
        }
        const dx = touch.screenX - state.startX;
        const dy = touch.screenY - state.startY;
        const minSwipe = 36;
        if (Math.abs(dx) <= Math.abs(dy) || Math.abs(dx) <= 8) {
            if (state.chevronActive) {
                this.view?.dispatchEvent?.(new CustomEvent('sideNavChevronOpacity', {
                    bubbles: true,
                    composed: true,
                    detail: { leftOpacity: '', rightOpacity: '', source: 'ebook-viewer', reason: 'mainDocumentSwipe.move-axis-or-min-dx' },
                }));
                state.chevronActive = false;
            }
            return;
        }
        event.preventDefault();
        const progress = Math.min(1, Math.abs(dx) / minSwipe);
        const swipedLeft = dx < 0;
        const logicalDirection = this.isRTL
            ? (swipedLeft ? 'backward' : 'forward')
            : (swipedLeft ? 'forward' : 'backward');
        const chevronSide = logicalDirection === 'forward'
            ? (this.isRTL ? 'left' : 'right')
            : (this.isRTL ? 'right' : 'left');
        this.view?.dispatchEvent?.(new CustomEvent('sideNavChevronOpacity', {
            bubbles: true,
            composed: true,
            detail: {
                leftOpacity: chevronSide === 'left' ? progress : 0,
                rightOpacity: chevronSide === 'right' ? progress : 0,
                source: 'ebook-viewer',
                reason: 'mainDocumentSwipe.progress',
                logicalDirection,
                chevronSide,
                swipedLeft,
                isRTL: this.isRTL,
            },
        }));
        state.chevronActive = progress > 0;
        if (!state.nativeLookupCancelled && progress >= 0.25) {
            state.nativeLookupCancelled = true;
            this.#invalidateVisiblePageSegmentSnapshot('page-turn-swipe-intent');
        }
        if (Math.abs(dx) <= minSwipe) return;
        state.triggered = true;
        this.#flashSideNavChevron(chevronSide);
        this.#clearVisiblePageReadChrome('page-turn-start');
        this.#applyLogicalPageTurnNavigationVisibility(logicalDirection, 'page-turn.swipe', {
            method: logicalDirection === 'forward' ? 'next' : 'prev',
        });
        if (logicalDirection === 'forward') {
            await this.view?.next?.();
        } else {
            await this.view?.prev?.();
        }
    }
    #onMainDocumentTouchEnd() {
        if (window.manabiNativePageTurnOwnsDrag === true) {
            this.#mainDocumentSwipeState = null;
            return;
        }
        if (this.#mainDocumentSwipeState?.chevronActive) {
            this.view?.dispatchEvent?.(new CustomEvent('sideNavChevronOpacity', {
                bubbles: true,
                composed: true,
                detail: { leftOpacity: '', rightOpacity: '', source: 'ebook-viewer', reason: 'mainDocumentSwipe.touchend' },
            }));
        }
        this.#mainDocumentSwipeState = null;
    }
    async open(file) {
        const openGeneration = this.#deferredOpenWork.beginGeneration()
        this.renderReadinessGeneration = this.#renderReadiness.begin();
        this.setLoadingIndicator(true);
        const readerOpenStartedAt = typeof performance !== 'undefined' && typeof performance.now === 'function'
            ? performance.now()
            : Date.now();

        this.hasLoadedLastPosition = false
        this.lastCFIPersistenceObservation = null;
        this.unstableCFIs.clear();
        if (this.initialPaginatorSettleHandle) {
            cancelAnimationFrame(this.initialPaginatorSettleHandle);
            this.initialPaginatorSettleHandle = null;
        }
        this.hasSettledInitialPaginatorLayout = false;
        this.view = await getView(file, false)
        postReaderVisibilityProbe('reader.open:view-assigned', this.view, null);
        // this.view.renderer.setAttribute('animated', true) // Flows top to bottom instead of like a book...
        if (typeof window.initialLayoutMode !== 'undefined') {
            this.view.renderer.setAttribute('flow', window.initialLayoutMode)
        }
        this.#installVisibleRendererGoToGuard();
        this.view.renderer.addEventListener('goTo', this.#onGoTo.bind(this))
        this.view.renderer.addEventListener('didDisplay', this.#onDidDisplay.bind(this))
        this.view.addEventListener('load', this.#onLoad.bind(this))
        this.view.addEventListener('relocate', this.#onRelocate.bind(this))

        const {
            book
        } = this.view
        this.bookDir = book.dir || 'ltr';
        this.isRTL = this.bookDir === 'rtl';
        document.body.dir = this.bookDir;
        document.body?.setAttribute?.('data-book-dir', this.bookDir);
        this.navHUD?.setIsRTL(this.isRTL);
        this.navHUD?.setPageTargets(book.pageList ?? []);
        this.view.renderer.setBookContentStyles?.(bookContentStylesPromise)
        this.view.renderer.setStyles?.(getCSSForBookContent(this.style))
        this.#applyHideNavigationDueToScrollToBookContent(this.navHUD?.hideNavigationDueToScroll === true);
        applyStoredChromeInsets('reader.open');
        //        this.view.renderer.next()

        $('#nav-bar').style.visibility = 'visible'
        postReaderVisibilityProbe('reader.open:nav-visible', this.view, {
            initialLayoutMode: typeof window.initialLayoutMode !== 'undefined' ? window.initialLayoutMode : null,
        });
        this.buttons = {
            prev: document.getElementById('btn-prev-chapter'),
            next: document.getElementById('btn-next-chapter'),
        };
        // Hide all other nav buttons except spinners
        for (const btn of Object.values(this.buttons)) {
            btn && (btn.hidden = true);
        }

        // Flip chevron icons for RTL books
        if (this.isRTL) {
            const flipChevron = (btn, leftArrow) => {
                const path = btn.querySelector('path');
                if (path) {
                    path.setAttribute('d', leftArrow ?
                                      'M 15 6 L 9 12 L 15 18' // left chevron (◀)
                                      :
                                      'M 9 6 L 15 12 L 9 18'); // right chevron (▶)
                }
            };

            flipChevron(this.buttons.prev, false); // ▶
            flipChevron(this.buttons.next, true); // ◀

            // Swap label/icon order for chapter buttons in RTL
            // Ensure "Next Chapter" shows "< Next Chapter"
            const nextBtn = this.buttons.next;
            const nextLabel = nextBtn.querySelector('.button-label');
            const nextIcon = nextBtn.querySelector('svg');
            if (nextIcon && nextLabel && nextIcon !== nextLabel.previousSibling) {
                nextBtn.insertBefore(nextIcon, nextLabel);
            }

            // Ensure "Previous Chapter" shows "Previous Chapter >"
            const prevBtn = this.buttons.prev;
            const prevLabel = prevBtn.querySelector('.button-label');
            const prevIcon = prevBtn.querySelector('svg');
            if (prevIcon && prevLabel && prevLabel !== prevIcon.previousSibling) {
                prevBtn.insertBefore(prevLabel, prevIcon);
            }

            // Spinner placement logic for RTL
            // For prev: spinner after label (right side, where chevron is)
            // For next: spinner before label (left side, where chevron is)
            if (this.buttons.prev) {
                this.buttons.prev._spinnerAfterLabel = true;
            }
            if (this.buttons.next) {
                this.buttons.next._spinnerAfterLabel = false;
            }
        } else {
            // LTR: spinner replaces icon (before label for prev, after label for next)
            if (this.buttons.prev) {
                this.buttons.prev._spinnerAfterLabel = false;
            }
            if (this.buttons.next) {
                this.buttons.next._spinnerAfterLabel = false;
            }
        }
        Object.values(this.buttons).forEach(btn =>
                                            btn.addEventListener('click', this.#onNavButtonClick.bind(this))
                                            );
        // Side-nav scroll handlers
        const runSideButtonPageTurn = async (side, method, button, eventType) => {
            if (button?.disabled || isCompactNavigationSheetSidePaginationDisabled()) {
                return;
            }
            try {
                this.#clearVisiblePageReadChrome('page-turn-start');
                this.#applyPageTurnNavigationVisibility(method, 'page-turn.side-button');
                if (method === 'goLeft') {
                    await this.view.goLeft();
                } else {
                    await this.view.goRight();
                }
            } catch (error) {
                throw error;
            }
        };
        const leftSideBtn = document.getElementById('btn-scroll-left');
        if (leftSideBtn) leftSideBtn.addEventListener('click', async () => {
            const now = Date.now();
            if (globalThis.__manabiLastSideButtonTouchActivation?.side === 'left'
                && now - globalThis.__manabiLastSideButtonTouchActivation.timestamp < 700) {
                return;
            }
            await runSideButtonPageTurn('left', 'goLeft', leftSideBtn, 'click');
        });
        const rightSideBtn = document.getElementById('btn-scroll-right');
        if (rightSideBtn) rightSideBtn.addEventListener('click', async () => {
            const now = Date.now();
            if (globalThis.__manabiLastSideButtonTouchActivation?.side === 'right'
                && now - globalThis.__manabiLastSideButtonTouchActivation.timestamp < 700) {
                return;
            }
            await runSideButtonPageTurn('right', 'goRight', rightSideBtn, 'click');
        });

        // Immediate tap feedback for side-nav chevrons on iOS/touch
        document.querySelectorAll('.side-nav').forEach(nav => {
            nav.addEventListener('touchstart', (event) => {
                if (nav.disabled || isCompactNavigationSheetSidePaginationDisabled()) return;
                nav.classList.add('pressed');
            }, {
                passive: true
            });
            nav.addEventListener('touchend', (event) => {
                nav.classList.remove('pressed');
                if (nav.disabled || isCompactNavigationSheetSidePaginationDisabled()) return;
                const side = nav.id === 'btn-scroll-left' ? 'left' : (nav.id === 'btn-scroll-right' ? 'right' : null);
                const method = side === 'left' ? 'goLeft' : (side === 'right' ? 'goRight' : null);
                if (side && method) {
                    event.preventDefault?.();
                    globalThis.__manabiLastSideButtonTouchActivation = {
                        side,
                        timestamp: Date.now(),
                    };
                    runSideButtonPageTurn(side, method, nav, 'touchend').catch((error) => console.error(error));
                }
            });
            nav.addEventListener('touchcancel', () => {
                nav.classList.remove('pressed');
            });
        });

        // Side-nav opacity wiring
        this.view.addEventListener('sideNavChevronOpacity', e => {
            const l = document.querySelector('#btn-scroll-left .icon');
            const r = document.querySelector('#btn-scroll-right .icon');

            const FADER_DELAY = 180;
            const fadeWithHold = (elem, value, key) => {
                if (!elem) {
                    return;
                }

                clearTimeout(this.#chevronFadeTimers[key]);
                this.#chevronFadeTimers[key] = null;

                // Show chevron at full opacity
                if (Number(value) >= 1) {
                    elem.style.removeProperty('opacity');
                    elem.style.removeProperty('visibility');
                    elem.classList.add('chevron-visible');
                    return;
                }

                // Show chevron at partial opacity
                if (Number(value) > 0) {
                    elem.classList.remove('chevron-visible');
                    elem.style.opacity = value;
                    elem.style.visibility = 'visible';
                    return;
                }

                // Hide chevron, but only after a delay and only if currently visible
                if (elem.classList.contains('chevron-visible')) {
                    this.#chevronFadeTimers[key] = setTimeout(() => {
                        elem.classList.remove('chevron-visible');
                        elem.style.removeProperty('opacity');
                        elem.style.removeProperty('visibility');
                        this.#chevronFadeTimers[key] = null;
                    }, FADER_DELAY);
                } else {
                    // Already hidden: do nothing
                    elem.style.removeProperty('opacity');
                    elem.style.removeProperty('visibility');
                    elem.classList.remove('chevron-visible');
                }
            };

            fadeWithHold(l, e.detail.leftOpacity, 'l');
            fadeWithHold(r, e.detail.rightOpacity, 'r');
        });
        this.view.addEventListener('foregroundPageTurnActivity', e => {
            const detail = e?.detail ?? {};
            const source = detail.source || 'paginator';
            markCacheWarmerForegroundActivity(source);
        });
        // Listen for resetSideNavChevrons custom event to reset chevrons
        document.addEventListener('resetSideNavChevrons', e => {
            this.#resetSideNavChevrons();
        });

        // Section ticks
        const sizes = book.sections.filter(s => s.linear !== 'no').map(s => s.size)
        const total = sizes.reduce((a, b) => a + b, 0)
        let sum = 0
        // Calculate all tick positions as fractions
        let ticks = [];
        for (const size of sizes.slice(0, -1)) {
            sum += size;
            ticks.push(sum / total);
        }
        if (sizes.length >= 50) {
            // Collapse ticks that are close to each other, never collapse more than those within that window.
            const THRESHOLD = 0.01;
            let collapsed = [];
            let group = [];
            for (let i = 0; i < ticks.length; ++i) {
                group.push(ticks[i]);
                // If next tick is far enough, close group
                if (i === ticks.length - 1 || Math.abs(ticks[i + 1] - ticks[i]) > THRESHOLD) {
                    // Collapse group if there's more than one tick in threshold
                    if (group.length > 1) {
                        // Pick the tick closest to the middle of the group
                        const avg = group.reduce((a, b) => a + b, 0) / group.length;
                        let closest = group[0];
                        let minDist = Math.abs(avg - closest);
                        for (const t of group) {
                            const dist = Math.abs(avg - t);
                            if (dist < minDist) {
                                minDist = dist;
                                closest = t;
                            }
                        }
                        collapsed.push(closest);
                    } else {
                        collapsed.push(group[0]);
                    }
                    group = [];
                }
            }
            ticks = collapsed;
        }
        // Render section ticks into the custom overlay container used by the January toolbar.
        const tickContainer = document.getElementById('progress-ticks');
        if (tickContainer) {
            tickContainer.innerHTML = '';
            for (const tick of ticks) {
                if (!Number.isFinite(tick)) continue;
                const pos = Math.max(0, Math.min(1, tick)) * 100;
                const mark = document.createElement('div');
                mark.className = 'tick';
                mark.style[this.isRTL ? 'right' : 'left'] = `${pos}%`;
                tickContainer.append(mark);
            }
        }

        // Percent jump input/button wiring
        const percentInput = document.getElementById('percent-jump-input');
        const percentButton = document.getElementById('percent-jump-button');

        percentInput.addEventListener('input', () => {
            const value = parseFloat(percentInput.value);
            const valid = !isNaN(value) && value >= 0 && value <= 100 && value !== this.lastPercentValue;
            percentButton.disabled = !valid;
        });

        percentButton.addEventListener('click', () => {
            const value = parseFloat(percentInput.value);
            if (!isNaN(value) && value >= 0 && value <= 100) {
                this.lastPercentValue = value;
                percentButton.disabled = true;
                this.goToPercent(value, 'sidebar-percent-jump-button');
            }
        });

        document.addEventListener('keydown', this.#handleKeydown.bind(this))

        let pendingMainDocumentBlankNavigationTouch = null;
        let lastPostedMainDocumentBlankTouchTap = null;
        const mainDocumentBlankNavigationMoveThreshold = 12;
        const mainDocumentSyntheticMouseAfterTouchSuppressionMs = 900;
        const mainDocumentSyntheticMouseAfterTouchDistanceThreshold = 24;
        const navigationGesturePoint = event => {
            const point = touchPointForNavigationGesture(event);
            if (!point) return null;
            return {
                x: point.screenX ?? point.clientX ?? null,
                y: point.screenY ?? point.clientY ?? null,
            };
        };
        const shouldSuppressMainDocumentSyntheticMouseBlankTap = (event, now) => {
            if (event.type !== 'mousedown' || !lastPostedMainDocumentBlankTouchTap) {
                return false;
            }
            const ageMs = now - lastPostedMainDocumentBlankTouchTap.postedAtMs;
            if (ageMs < 0 || ageMs > mainDocumentSyntheticMouseAfterTouchSuppressionMs) {
                return false;
            }
            const point = navigationGesturePoint(event);
            if (!point || point.x === null || point.y === null) {
                return true;
            }
            const dx = point.x - lastPostedMainDocumentBlankTouchTap.x;
            const dy = point.y - lastPostedMainDocumentBlankTouchTap.y;
            return (dx * dx + dy * dy) <= (mainDocumentSyntheticMouseAfterTouchDistanceThreshold * mainDocumentSyntheticMouseAfterTouchDistanceThreshold);
        };
        const postNoElementNavigationTouchStart = (event, source, touchstartAtMs = Date.now()) => {
            const now = Date.now();
            if (shouldSuppressMainDocumentSyntheticMouseBlankTap(event, now)) {
                return;
            }
            if (window.__manabiLookupPopoverActive === true) {
                window.__manabiSuppressUnhandledTapHideNavigationUntil = now + 750;
            }
            const ebookNavigationHidden =
                globalThis.reader?.navHUD?.hideNavigationDueToScroll === true
                || document?.body?.dataset?.mnbNavigationHiddenDueToScroll === 'true'
                || document?.body?.classList?.contains?.('nav-hidden-due-to-scroll') === true;
            if (event.type === 'touchend') {
                const point = navigationGesturePoint(event);
                lastPostedMainDocumentBlankTouchTap = point && point.x !== null && point.y !== null
                    ? {
                        postedAtMs: now,
                        x: point.x,
                        y: point.y,
                    }
                    : null;
            }
            window.webkit?.messageHandlers?.touchstartCallbackHandler?.postMessage?.({
                touchedEntryWithElementId: null,
                wasAlreadySelected: false,
                touchstartAtMs,
                touchstartEventType: event.type,
                ebookNavigationHidden,
                source,
            });
        };
        const clearPendingMainDocumentBlankNavigationTouch = () => {
            pendingMainDocumentBlankNavigationTouch = null;
        };
        const touchPointForNavigationGesture = event => event.changedTouches?.[0] ?? event.touches?.[0] ?? event;
        const movedPastBlankNavigationTapThreshold = (event, pending) => {
            const point = touchPointForNavigationGesture(event);
            const dx = (point?.screenX ?? point?.clientX ?? pending.startX) - pending.startX;
            const dy = (point?.screenY ?? point?.clientY ?? pending.startY) - pending.startY;
            return (dx * dx + dy * dy) > (mainDocumentBlankNavigationMoveThreshold * mainDocumentBlankNavigationMoveThreshold);
        };
        const processTouchStart = function(event) {
            // Ignore touches inside foliate-js viewer iframe
            const target = event.target;
            if (target && target.ownerDocument !== document) {
                return
            }
            const excludedTarget = target?.closest?.('#side-bar, #page-tracking-container, #nav-bar, #nav-hidden-overlay, .side-nav, input, textarea, select, [contenteditable="true"]');
            if (excludedTarget) {
                clearPendingMainDocumentBlankNavigationTouch();
                return
            }

            if (event.type === 'touchstart') {
                const point = touchPointForNavigationGesture(event);
                pendingMainDocumentBlankNavigationTouch = point
                    ? {
                        startX: point.screenX ?? point.clientX,
                        startY: point.screenY ?? point.clientY,
                        startAtMs: Date.now(),
                    }
                    : null;
                return;
            }
            postNoElementNavigationTouchStart(event, 'main-document.blank')
        }
        const processMainDocumentBlankNavigationTouchMove = function(event) {
            const pending = pendingMainDocumentBlankNavigationTouch;
            if (!pending) {
                return;
            }
            if (movedPastBlankNavigationTapThreshold(event, pending)) {
                clearPendingMainDocumentBlankNavigationTouch();
            }
        }
        const processMainDocumentBlankNavigationTouchEnd = function(event) {
            const pending = pendingMainDocumentBlankNavigationTouch;
            clearPendingMainDocumentBlankNavigationTouch();
            if (!pending || event.type === 'touchcancel') {
                return;
            }
            if (movedPastBlankNavigationTapThreshold(event, pending)) {
                return;
            }
            postNoElementNavigationTouchStart(event, 'main-document.blank', pending.startAtMs)
        }
        let pendingChromeBlankNavigationTouch = null;
        const clearPendingChromeBlankNavigationTouch = () => {
            pendingChromeBlankNavigationTouch = null;
        };
        const beginChromeBlankNavigationTouch = function(event, source) {
            if (event.type === 'touchstart') {
                const point = touchPointForNavigationGesture(event);
                pendingChromeBlankNavigationTouch = point
                    ? {
                        startX: point.screenX ?? point.clientX,
                        startY: point.screenY ?? point.clientY,
                        startAtMs: Date.now(),
                        source,
                    }
                    : null;
                return;
            }
            postNoElementNavigationTouchStart(event, `${source}.mouse`);
        };
        const processChromeBlankNavigationTouchMove = function(event) {
            const pending = pendingChromeBlankNavigationTouch;
            if (!pending) {
                return;
            }
            if (movedPastBlankNavigationTapThreshold(event, pending)) {
                clearPendingChromeBlankNavigationTouch();
            }
        };
        const processChromeBlankNavigationTouchEnd = function(event) {
            const pending = pendingChromeBlankNavigationTouch;
            clearPendingChromeBlankNavigationTouch();
            if (!pending || event.type === 'touchcancel') {
                return;
            }
            if (movedPastBlankNavigationTapThreshold(event, pending)) {
                return;
            }
            postNoElementNavigationTouchStart(event, pending.source, pending.startAtMs);
        };
        const processNavChromeTouchStart = function(event) {
            const target = event.target;
            if (target && target.ownerDocument !== document) {
                return;
            }
            const navBar = target?.closest?.('#nav-bar');
            if (!navBar) {
                return;
            }
            const interactiveTarget = target?.closest?.('a, button, input, textarea, select, [role="button"], [contenteditable="true"], #progress-wrapper');
            if (interactiveTarget) {
                clearPendingChromeBlankNavigationTouch();
                return;
            }
            beginChromeBlankNavigationTouch(event, 'nav-bar.chrome');
        }
        const processPageTrackingChromeTouchStart = function(event) {
            const target = event.target;
            if (target && target.ownerDocument !== document) {
                return;
            }
            const pageTrackingContainer = target?.closest?.('#page-tracking-container');
            if (!pageTrackingContainer) {
                return;
            }
            const pageReadButton = target?.closest?.('.page-read-button');
            if (pageReadButton) {
                clearPendingChromeBlankNavigationTouch();
                return;
            }
            beginChromeBlankNavigationTouch(event, 'page-tracking.chrome');
        }
        document.addEventListener('touchstart', processNavChromeTouchStart, {
            passive: true
        })
        document.addEventListener('mousedown', processNavChromeTouchStart, {
            passive: true
        })
        document.addEventListener('touchstart', processPageTrackingChromeTouchStart, {
            passive: true
        })
        document.addEventListener('mousedown', processPageTrackingChromeTouchStart, {
            passive: true
        })
        document.addEventListener('touchmove', processChromeBlankNavigationTouchMove, {
            passive: true
        })
        document.addEventListener('touchend', processChromeBlankNavigationTouchEnd, {
            passive: true
        })
        document.addEventListener('touchcancel', processChromeBlankNavigationTouchEnd, {
            passive: true
        })
        document.addEventListener('touchstart', processTouchStart, {
            passive: true
        })
        document.addEventListener('touchmove', processMainDocumentBlankNavigationTouchMove, {
            passive: true
        })
        document.addEventListener('touchend', processMainDocumentBlankNavigationTouchEnd, {
            passive: true
        })
        document.addEventListener('touchcancel', processMainDocumentBlankNavigationTouchEnd, {
            passive: true
        })
        document.addEventListener('mousedown', processTouchStart, {
            passive: true
        })
        document.addEventListener('touchstart', this.#onMainDocumentTouchStart.bind(this), {
            passive: true,
        });
        document.addEventListener('touchmove', this.#onMainDocumentTouchMove.bind(this), {
            passive: false,
        });
        document.addEventListener('touchend', this.#onMainDocumentTouchEnd.bind(this), {
            passive: true,
        });
        document.addEventListener('touchcancel', this.#onMainDocumentTouchEnd.bind(this), {
            passive: true,
        });


        const title = book.metadata?.title ?? 'Untitled Book'
        document.title = title
        $('#side-bar-title').innerText = title
        this.navHUD?.setBookTitle?.(title)
        const author = book.metadata?.author
        let authorText = typeof author === 'string' ? author :
        author
        ?.map(author => typeof author === 'string' ? author : author.name)
        ?.join(', ') ??
        ''
        $('#side-bar-author').innerText = authorText
        window.webkit.messageHandlers.pageMetadataUpdated.postMessage({
            'title': title,
            'author': authorText,
            'url': window.top.location.href
        })

        Promise.resolve(book.getCover?.())?.then(blob => {
            blob ? $('#side-bar-cover').src = URL.createObjectURL(blob) : null
        })

        this.#schedulePostInitialOpenWork(book, openGeneration)
    }

    #schedulePostInitialOpenWork(book, generation) {
        void this.#deferredOpenWork.schedule(generation, [
            {
                name: 'toc',
                run: async ({ isCurrent }) => {
                    const toc = book.toc
                    if (!toc || this.#tocView || !isCurrent()) return
                    const tocView = createTOCView(toc, async (href) => {
                        if (!isCurrent()) return
                        await runWithNavigationIntent({
                            source: 'toc',
                            target: 'view.goTo',
                            href,
                        }, () => this.view.goTo(href)).catch(e => console.error(e))
                        if (isCurrent()) this.closeSideBar()
                    })
                    if (!isCurrent()) return
                    this.#tocView = tocView
                    $('#toc-view').append(tocView.element)
                },
            },
            {
                name: 'calibre-bookmarks',
                run: async ({ isCurrent }) => {
                    const bookmarks = await book.getCalibreBookmarks?.()
                    if (!bookmarks || !isCurrent()) return
                    const { fromCalibreHighlight } = await import('./epubcfi.js')
                    if (!isCurrent()) return
                    for (const obj of bookmarks) {
                        if (obj.type !== 'highlight') continue
                        const value = fromCalibreHighlight(obj)
                        const annotation = {
                            value,
                            color: obj.style.which,
                            note: obj.notes,
                        }
                        const list = this.annotations.get(obj.spine_index)
                        if (list) list.push(annotation)
                        else this.annotations.set(obj.spine_index, [annotation])
                        this.annotationsByValue.set(value, annotation)
                    }
                    if (!isCurrent()) return
                    this.view.addEventListener('create-overlay', e => {
                        if (!isCurrent()) return
                        const list = this.annotations.get(e.detail.index)
                        if (list) {
                            for (const annotation of list) this.view.addAnnotation(annotation)
                        }
                    })
                    this.view.addEventListener('draw-annotation', e => {
                        if (!isCurrent()) return
                        e.detail.draw(Overlayer.highlight, { color: e.detail.annotation.color })
                    })
                    this.view.addEventListener('show-annotation', e => {
                        if (!isCurrent()) return
                        const annotation = this.annotationsByValue.get(e.detail.value)
                        if (annotation?.note) alert(annotation.note)
                    })
                },
            },
        ], {
            isOwnerCurrent: () => globalThis.reader === this && this.view?.book === book,
            onError: (task, error) => console.error(`Deferred ebook ${task} failed`, error),
        })
    }

    async updateNavButtons() {
        const navVisibilityBefore = captureNavVisibilityState();
        // Remove any nav-spinner left over from chapter navigation click
        document.querySelectorAll('.ispinner.nav-spinner').forEach(spinner => {
            const btn = spinner.closest('button');
            if (btn && btn._originalIcon) {
                spinner.replaceWith(btn._originalIcon);
                delete btn._originalIcon;
            }
            const label = btn.querySelector('.button-label');
            if (label) label.style.visibility = '';
        });
        if (!this.view?.renderer) return;
        const r = this.view.renderer;
        // Use new section start/end helpers if available
        const atSectionStart = typeof r.isAtSectionStart === "function" ? await r.isAtSectionStart() : false;
        const atSectionEnd = typeof r.isAtSectionEnd === "function" ? await r.isAtSectionEnd() : false;
        // Use public helpers to detect prev/next section
        const hasPrevSection = typeof r.getHasPrevSection === "function" ? await r.getHasPrevSection() : true;
        const hasNextSection = typeof r.getHasNextSection === "function" ? await r.getHasNextSection() : true;
        const sectionIndex = typeof this.navHUD?.lastRelocateDetail?.sectionIndex === 'number'
            ? this.navHUD.lastRelocateDetail.sectionIndex
            : (typeof this.navHUD?.lastRelocateDetail?.index === 'number'
                ? this.navHUD.lastRelocateDetail.index
                : (typeof r.currentIndex === 'number' ? r.currentIndex : null));
        const sectionHref = typeof sectionIndex === 'number'
            ? (typeof this.view?.renderer?.tocItem?.href === 'string'
                ? this.view.renderer.tocItem.href
                : (typeof this.view?.book?.sections?.[sectionIndex]?.id === 'string'
                    ? this.view.book.sections[sectionIndex].id
                    : ''))
            : (typeof this.view?.renderer?.tocItem?.href === 'string'
                ? this.view.renderer.tocItem.href
                : '');
        const isMetadataSection = isLikelyMetadataSectionHref(sectionHref);
        const pageCountFromCache = typeof sectionIndex === 'number' && this.navHUD?.sectionPageCounts instanceof Map
            ? this.navHUD.sectionPageCounts.get(sectionIndex)
            : null;
        const pageCount = typeof pageCountFromCache === 'number' && pageCountFromCache > 0
            ? pageCountFromCache
            : (typeof this.navHUD?.rendererPageSnapshot?.total === 'number' && this.navHUD.rendererPageSnapshot.total > 0
                ? this.navHUD.rendererPageSnapshot.total
                : (typeof this.navHUD?.lastRelocateDetail?.pageCount === 'number'
                    ? this.navHUD.lastRelocateDetail.pageCount
                    : null));
        const isSinglePageMetadataSection = isMetadataSection && pageCount === 1;
        const finishLabel = isSinglePageMetadataSection ? 'Mark Read' : 'Finish Chapter';
        const isRestartHiddenForMiddlePageWhileNavHidden =
            !!this.markedAsFinished
            && !!this.navHUD?.hideNavigationDueToScroll
            && !atSectionStart
            && !atSectionEnd;
        const completionAction = this.markedAsFinished
            ? (isRestartHiddenForMiddlePageWhileNavHidden
                ? null
                : {
                    type: 'restart',
                    label: 'Start Over Chapter',
                    tone: 'restart',
                })
            : (atSectionEnd && !hasNextSection
                ? {
                    type: 'finish',
                    label: finishLabel,
                    tone: 'finish',
                }
                : null);
        this.completionAction = completionAction;
        if (!completionAction) {
            this.completionActionBusy = false;
        }

        this.#show(this.buttons.prev, atSectionStart && hasPrevSection);

        if (atSectionEnd && hasNextSection) {
            this.#show(this.buttons.next, true);
        } else {
            this.#show(this.buttons.next, false);
        }
        const showingCompletion = !!completionAction;
        this.showingCompletionButtons = showingCompletion;
        this.navHUD?._toggleCompletionStack?.(false);

        // RTL/LTR logic for disabling/hiding side chevrons
        const btnScrollLeft = document.getElementById('btn-scroll-left');
        const btnScrollRight = document.getElementById('btn-scroll-right');
        if (btnScrollLeft && btnScrollRight) {
            const compactSheetSidePaginationDisabled = isCompactNavigationSheetSidePaginationDisabled();
            if (this.isRTL) {
                // In RTL, left chevron = go forward, right chevron = go backward
                // Disable left at end, right at start
                btnScrollLeft.disabled = compactSheetSidePaginationDisabled || (atSectionEnd && !hasNextSection);
                btnScrollRight.disabled = compactSheetSidePaginationDisabled || (atSectionStart && !hasPrevSection);
            } else {
                // LTR, left chevron = backward, right chevron = forward
                // Disable left at start, right at end
                btnScrollLeft.disabled = compactSheetSidePaginationDisabled || (atSectionStart && !hasPrevSection);
                btnScrollRight.disabled = compactSheetSidePaginationDisabled || (atSectionEnd && !hasNextSection);
            }
        }

        this.navHUD?.setNavContext({
            atSectionStart,
            atSectionEnd,
            hasPrevSection,
            hasNextSection,
            showingFinish: false,
            showingRestart: false,
            sections: this.view?.book?.sections ?? [],
        });
        if (this.navHUD?.hideNavigationDueToScroll) {
            this.navHUD.setHideNavigationDueToScroll(true, 'reader.updateNavButtons.reapply', {
                atSectionStart,
                atSectionEnd,
                hasPrevSection,
                hasNextSection,
            });
        }
        this.#schedulePageTrackingSync('nav-buttons', null, 1, 96);
    }
    async #handleKeydown(event) {
        const k = event.key;
        const renderer = this.view?.renderer;
        if (!renderer) return;
        const isRTL = this.isRTL;

        if (k === 'ArrowLeft' || k === 'h') {
            if (isRTL && await renderer.atEnd()) {
                this.buttons.next.click();
            } else if (!isRTL && await renderer.atStart()) {
                this.buttons.prev.click();
            } else {
                this.#clearVisiblePageReadChrome('page-turn-start');
                this.#applyPageTurnNavigationVisibility('goLeft', 'page-turn.keydown');
                await this.view.goLeft();
            }
        } else if (k === 'ArrowRight' || k === 'l') {
            if (isRTL && await renderer.atStart()) {
                this.buttons.prev.click();
            } else if (!isRTL && await renderer.atEnd()) {
                this.buttons.next.click();
            } else {
                this.#clearVisiblePageReadChrome('page-turn-start');
                this.#applyPageTurnNavigationVisibility('goRight', 'page-turn.keydown');
                await this.view.goRight();
            }
        }
    }
    async handlePhysicalArrowKey(direction) {
        const key = direction === 'left'
            ? 'ArrowLeft'
            : direction === 'right'
                ? 'ArrowRight'
                : null;
        if (!key) return false;
        await this.#handleKeydown({ key });
        return true;
    }
    #lookupContentWindows() {
        const contents = this.view?.renderer?.getContents?.() || [];
        return contents
            .map((content) => content?.doc?.defaultView || content?.document?.defaultView || null)
            .filter((view) => view && !isCacheWarmerDocument(view.document));
    }
    #lookupNavigationDocuments() {
        return this.#lookupContentWindows().map((view) => view.document).filter(isDocumentLike);
    }
    async #waitForLookupContentFunction(functionName, timeoutMs = 1800) {
        const startedAt = performance.now();
        while (performance.now() - startedAt < timeoutMs) {
            const contentWindow = this.#lookupContentWindows().find((view) => typeof view?.[functionName] === 'function');
            if (contentWindow) return contentWindow;
            await new Promise((resolve) => setTimeout(resolve, 40));
        }
        return this.#lookupContentWindows().find((view) => typeof view?.[functionName] === 'function') ?? null;
    }
    #lookupNavigationVisibleSegmentSummary(doc, result) {
        const visibleSegments = Array.isArray(result?.visibleSegments)
            ? result.visibleSegments
            : [];
        const firstID = visibleSegments[0]?.node?.id ?? null;
        const lastID = visibleSegments[visibleSegments.length - 1]?.node?.id ?? null;
        const href = doc?.location?.href ?? null;
        return {
            href,
            visibleSegmentCount: visibleSegments.length,
            firstVisibleSegmentID: firstID,
            lastVisibleSegmentID: lastID,
            signature: `${href ?? ''}|${visibleSegments.length}|${firstID ?? ''}|${lastID ?? ''}`,
        };
    }
    #lookupNavigationVisibleSegmentSignatureFromRefreshResults(refreshResults = []) {
        if (!Array.isArray(refreshResults) || refreshResults.length === 0) {
            return '';
        }
        return refreshResults
            .map((result) => result?.signature ?? `${result?.href ?? ''}|${result?.visibleSegmentCount ?? 0}|${result?.firstVisibleSegmentID ?? ''}|${result?.lastVisibleSegmentID ?? ''}`)
            .join('||');
    }
    #lookupNavigationVisibleSegmentSnapshot(reason = 'lookup-navigation.visible-snapshot') {
        const refreshResults = [];
        for (const doc of this.#lookupNavigationDocuments()) {
            const visibleRange = this.#visibleRangeForDocument(doc);
            const result = this.#visiblePageSegmentResult(doc, visibleRange, reason, {
                postLookupTargets: false,
                prepareLookupIndex: false,
            });
            refreshResults.push({
                ...this.#lookupNavigationVisibleSegmentSummary(doc, result),
                fontStatus: doc?.fonts?.status ?? null,
            });
        }
        return {
            reason,
            refreshResults,
            signature: this.#lookupNavigationVisibleSegmentSignatureFromRefreshResults(refreshResults),
        };
    }
    #settleAfterLookupPageTurn(reason = 'lookup-navigation.page-turn-settled') {
        const refreshResults = [];
        for (const doc of this.#lookupNavigationDocuments()) {
            const visibleRange = this.#visibleRangeForDocument(doc);
            this.visiblePageSegmentSnapshot = null;
            const result = this.#visiblePageSegmentResult(doc, visibleRange, reason);
            refreshResults.push({
                ...this.#lookupNavigationVisibleSegmentSummary(doc, result),
                fontStatus: doc?.fonts?.status ?? null,
            });
        }
        return {
            reason,
            refreshResults,
            signature: this.#lookupNavigationVisibleSegmentSignatureFromRefreshResults(refreshResults),
        };
    }
    #refreshLookupNavigationVisibleTargets(reason = 'lookup-navigation.visible-target-readiness') {
        const results = [];
        for (const doc of this.#lookupNavigationDocuments()) {
            const visibleRange = this.#visibleRangeForDocument(doc);
            this.visiblePageSegmentSnapshot = null;
            const result = this.#visiblePageSegmentResult(doc, visibleRange, reason, { postIfCached: true });
            results.push({
                ...this.#lookupNavigationVisibleSegmentSummary(doc, result),
                fontStatus: doc?.fonts?.status ?? null,
            });
        }
        return results;
    }
    async #refreshLookupNavigationVisibleTargetsAfterFonts(reason = 'lookup-navigation.visible-target-readiness.fonts') {
        const pendingFontDocs = this.#lookupNavigationDocuments()
            .filter((doc) => doc?.fonts?.status === 'loading' && doc?.fonts?.ready?.then);
        if (pendingFontDocs.length === 0) {
            return { advanced: false, reason: 'fonts-ready-or-unavailable', refreshResults: [] };
        }
        await Promise.all(pendingFontDocs.map((doc) => Promise.resolve(doc.fonts.ready).catch(() => null)));
        return {
            advanced: true,
            reason: 'fonts-ready',
            refreshResults: this.#refreshLookupNavigationVisibleTargets(reason),
        };
    }
    async #refreshLookupNavigationVisibleTargetsAfterRendererSettle(reason = 'lookup-navigation.visible-target-readiness.renderer') {
        const renderer = this.view?.renderer;
        if (!renderer || typeof renderer.renderIfContainerSizeChanged !== 'function') {
            return { advanced: false, reason: 'renderer-unavailable', refreshResults: [] };
        }
        const renderResult = await renderer.renderIfContainerSizeChanged(reason);
        if (renderResult?.rendered !== true) {
            return {
                advanced: false,
                reason: renderResult?.reason ?? 'renderer-did-not-render',
                renderResult,
                refreshResults: [],
            };
        }
        return {
            advanced: true,
            reason: 'renderer-rendered',
            renderResult,
            refreshResults: this.#refreshLookupNavigationVisibleTargets(reason),
        };
    }
    refreshLookupNavigationVisibleTargetsForRelocate(reason = 'lookup-navigation.relocate') {
        return this.#refreshLookupNavigationVisibleTargets(reason);
    }
    async #visibleLookupNavigationReadiness(request) {
        const kind = request?.kind === 'sentence' || request?.kind === 'section' ? request.kind : 'word';
        const direction = request?.direction === 'previous' ? 'previous' : 'next';
        const functionName = 'manabi_visibleLookupNavigationReadiness';
        await this.#waitForLookupContentFunction(functionName);
        const contentWindows = this.#lookupContentWindows()
            .filter((view) => typeof view?.[functionName] === 'function');
        const orderedContentWindows = direction === 'previous'
            ? contentWindows.slice().reverse()
            : contentWindows;
        if (orderedContentWindows.length === 0) {
            return {
                ready: false,
                failureReason: 'missingVisibleLookupReadiness',
                kind,
                direction,
                contentWindowAttempts: [],
            };
        }
        const attempts = [];
        for (const contentWindow of orderedContentWindows) {
            let result = null;
            try {
                result = contentWindow[functionName]({
                    ...(request && typeof request === 'object' ? request : {}),
                    kind,
                    direction,
                });
            } catch (error) {
                result = {
                    ready: false,
                    failureReason: 'visibleLookupReadinessError',
                    error: error?.message || String(error),
                };
            }
            const attempt = {
                windowURL: contentWindow.location?.href ?? null,
                ready: result?.ready === true,
                failureReason: result?.failureReason ?? null,
                targetElementID: result?.target?.id ?? result?.targetElementId ?? null,
                visibleSegmentCount: result?.visibleSegmentCount ?? null,
                visibleElementIDCount: result?.visibleElementIDCount ?? null,
                preparedVisibleElementIDCount: result?.preparedVisibleElementIDCount ?? null,
                hitTargetCount: result?.hitTargetCount ?? null,
            };
            attempts.push(attempt);
            if (result?.ready === true) {
                return {
                    ...(result ?? {}),
                    ready: true,
                    kind,
                    direction,
                    contentWindowURL: contentWindow.location?.href ?? null,
                    contentWindowAttempts: attempts,
                };
            }
        }
        return {
            ready: false,
            failureReason: 'noVisibleTargetAfterPageTurn',
            kind,
            direction,
            contentWindowAttempts: attempts,
        };
    }
    async #waitForVisibleLookupNavigationReadiness(request) {
        const startedAt = performance.now();
        const samples = [];
        const initialRefreshResults = this.#refreshLookupNavigationVisibleTargets('lookup-navigation.visible-target-readiness');
        let readiness = await this.#visibleLookupNavigationReadiness(request);
        samples.push({
            attempt: 0,
            elapsedMs: Math.round(performance.now() - startedAt),
            ready: readiness?.ready === true,
            failureReason: readiness?.failureReason ?? null,
            targetElementID: readiness?.target?.id ?? readiness?.targetElementId ?? null,
            refreshResults: initialRefreshResults,
            contentWindowAttempts: readiness?.contentWindowAttempts ?? [],
        });
        if (readiness?.ready !== true) {
            const fontResult = await this.#refreshLookupNavigationVisibleTargetsAfterFonts();
            if (fontResult.advanced === true) {
                readiness = await this.#visibleLookupNavigationReadiness(request);
            }
            samples.push({
                attempt: samples.length,
                elapsedMs: Math.round(performance.now() - startedAt),
                ready: readiness?.ready === true,
                failureReason: readiness?.failureReason ?? null,
                targetElementID: readiness?.target?.id ?? readiness?.targetElementId ?? null,
                refreshStage: fontResult.reason,
                refreshResults: fontResult.refreshResults,
                contentWindowAttempts: readiness?.contentWindowAttempts ?? [],
            });
        }
        if (readiness?.ready !== true) {
            const rendererResult = await this.#refreshLookupNavigationVisibleTargetsAfterRendererSettle();
            if (rendererResult.advanced === true) {
                readiness = await this.#visibleLookupNavigationReadiness(request);
            }
            samples.push({
                attempt: samples.length,
                elapsedMs: Math.round(performance.now() - startedAt),
                ready: readiness?.ready === true,
                failureReason: readiness?.failureReason ?? null,
                targetElementID: readiness?.target?.id ?? readiness?.targetElementId ?? null,
                refreshStage: rendererResult.reason,
                refreshResults: rendererResult.refreshResults,
                renderResult: rendererResult.renderResult ?? null,
                contentWindowAttempts: readiness?.contentWindowAttempts ?? [],
            });
        }
        return {
            readiness,
            samples,
        };
    }
    async #openVisibleLookupTargetAfterPageTurnWhenReady(request) {
        const readinessResult = await this.#waitForVisibleLookupNavigationReadiness(request);
        const readiness = readinessResult?.readiness ?? null;
        if (readiness?.ready !== true) {
            return {
                opened: false,
                failureReason: readiness?.failureReason ?? 'noVisibleTargetAfterPageTurn',
                kind: request?.kind === 'sentence' || request?.kind === 'section' ? request.kind : 'word',
                direction: request?.direction === 'previous' ? 'previous' : 'next',
                visibleLookupReadiness: readiness,
                visibleLookupReadinessSamples: readinessResult?.samples ?? [],
            };
        }
        const refreshResults = this.#refreshLookupNavigationVisibleTargets('lookup-navigation.visible-target-open');
        const result = await this.#openVisibleLookupTargetAfterPageTurn(request);
        if (result && typeof result === 'object') {
            result.visibleLookupReadiness = readiness;
            result.visibleLookupReadinessSamples = readinessResult?.samples ?? [];
            result.visibleLookupOpenRefreshResults = refreshResults;
        }
        return result;
    }
    #lookupNavigationPositionSnapshot() {
        const renderer = this.view?.renderer ?? null;
        const relocateDetail = this.navHUD?.lastRelocateDetail ?? null;
        return {
            sectionIndex: getPrimaryRendererContentIndex(renderer),
            rendererCurrentIndex: typeof renderer?.currentIndex === 'number' ? renderer.currentIndex : null,
            pageCurrent: typeof this.navHUD?.rendererPageSnapshot?.current === 'number' ? this.navHUD.rendererPageSnapshot.current : null,
            pageTotal: typeof this.navHUD?.rendererPageSnapshot?.total === 'number' ? this.navHUD.rendererPageSnapshot.total : null,
            fraction: typeof relocateDetail?.fraction === 'number' && Number.isFinite(relocateDetail.fraction)
                ? safeRound(relocateDetail.fraction, 6)
                : null,
        };
    }
    #lookupNavigationPositionChanged(before, after) {
        if (!before || !after) return false;
        return before.sectionIndex !== after.sectionIndex
            || before.rendererCurrentIndex !== after.rendererCurrentIndex
            || before.pageCurrent !== after.pageCurrent
            || before.pageTotal !== after.pageTotal
            || before.fraction !== after.fraction;
    }
    async #openVisibleLookupTargetAfterPageTurn(request) {
        const kind = request?.kind === 'sentence' || request?.kind === 'section' ? request.kind : 'word';
        const direction = request?.direction === 'previous' ? 'previous' : 'next';
        const functionName = 'manabi_openVisibleLookupTargetAfterPageTurn';
        await this.#waitForLookupContentFunction(functionName);
        const contentWindows = this.#lookupContentWindows()
            .filter((view) => typeof view?.[functionName] === 'function');
        const orderedContentWindows = direction === 'previous'
            ? contentWindows.slice().reverse()
            : contentWindows;
        if (orderedContentWindows.length === 0) {
            return {
                opened: false,
                failureReason: 'missingVisibleLookupFallback',
                kind,
                direction,
            };
        }
        const attempts = [];
        for (const contentWindow of orderedContentWindows) {
            let result = null;
            try {
                result = await contentWindow[functionName]({
                    ...(request && typeof request === 'object' ? request : {}),
                    kind,
                    direction,
                    allowEbookPageTurn: false,
                });
            } catch (error) {
                result = {
                    opened: false,
                    failureReason: 'visibleLookupFallbackError',
                    error: error?.message || String(error),
                };
            }
            attempts.push({
                windowURL: contentWindow.location?.href ?? null,
                opened: result?.opened === true,
                failureReason: result?.failureReason ?? null,
                targetElementID: result?.target?.id ?? null,
            });
            if (result?.opened === true) {
                result.contentWindowURL = contentWindow.location?.href ?? null;
                result.contentWindowAttempts = attempts;
                return result;
            }
            if (result?.failureReason !== 'noVisibleTargetAfterPageTurn') {
                return {
                    ...(result ?? {}),
                    opened: false,
                    kind,
                    direction,
                    contentWindowURL: contentWindow.location?.href ?? null,
                    contentWindowAttempts: attempts,
                };
            }
        }
        return {
            opened: false,
            failureReason: 'noVisibleTargetAfterPageTurn',
            kind,
            direction,
            contentWindowAttempts: attempts,
        };
    }
    async #turnLookupNavigationPage(direction) {
        const renderer = this.view?.renderer;
        if (!renderer || !this.view) {
            return {
                moved: false,
                failureReason: 'missingRenderer',
            };
        }
        const normalizedDirection = direction === 'previous' ? 'previous' : 'next';
        const atStart = await renderer.atStart?.();
        const atEnd = await renderer.atEnd?.();
        if (normalizedDirection === 'next') {
            if (atEnd === true) {
                this.#clearVisiblePageReadChrome('lookup-navigation-page-turn-start');
                this.#applyLogicalPageTurnNavigationVisibility('forward', 'lookup-navigation.next-section');
                await renderer.nextSection?.();
                return { moved: true, mode: 'nextSection' };
            }
            this.#clearVisiblePageReadChrome('lookup-navigation-page-turn-start');
            this.#applyLogicalPageTurnNavigationVisibility('forward', 'lookup-navigation.page');
            if (this.isRTL) {
                await this.view.goLeft();
                return { moved: true, mode: 'goLeft' };
            }
            await this.view.goRight();
            return { moved: true, mode: 'goRight' };
        }
        if (atStart === true) {
            this.#clearVisiblePageReadChrome('lookup-navigation-page-turn-start');
            this.#applyLogicalPageTurnNavigationVisibility('backward', 'lookup-navigation.previous-section');
            await renderer.prevSection?.();
            return { moved: true, mode: 'prevSection' };
        }
        this.#clearVisiblePageReadChrome('lookup-navigation-page-turn-start');
        this.#applyLogicalPageTurnNavigationVisibility('backward', 'lookup-navigation.page');
        if (this.isRTL) {
            await this.view.goRight();
            return { moved: true, mode: 'goRight' };
        }
        await this.view.goLeft();
        return { moved: true, mode: 'goLeft' };
    }
    async performLookupNavigationPageTurn(request = {}) {
        const token = (this.lookupNavigationPageTurnToken ?? 0) + 1;
        this.lookupNavigationPageTurnToken = token;
        this.lookupNavigationPageTurnActive = true;
        const kind = request?.kind === 'sentence' || request?.kind === 'section' ? request.kind : 'word';
        const direction = request?.direction === 'previous' ? 'previous' : 'next';
        const maxPageTurns = Math.max(1, Math.min(12, Number.isFinite(request?.maxPageTurns) ? Math.round(request.maxPageTurns) : 8));
        const startedAt = performance.now();
        const attempts = [];
        try {
        for (let pageTurnIndex = 0; pageTurnIndex < maxPageTurns; pageTurnIndex += 1) {
            if (this.lookupNavigationPageTurnToken !== token) {
                return {
                    opened: false,
                    failureReason: 'superseded',
                    kind,
                    direction,
                    elapsedMs: Math.round(performance.now() - startedAt),
                    attempts,
                };
            }
            let turnResult = null;
            const positionBeforeTurn = this.#lookupNavigationPositionSnapshot();
            const visiblePositionBeforeTurn = this.#lookupNavigationVisibleSegmentSnapshot('lookup-navigation.page-turn-before');
            const displaySettledSequenceBeforeTurn = this.displaySettledSequence;
            try {
                turnResult = await this.#turnLookupNavigationPage(direction);
            } catch (error) {
                turnResult = {
                    moved: false,
                    failureReason: 'pageTurnError',
                    error: error?.message || String(error),
                };
            }
            if (turnResult) {
                turnResult.positionBefore = positionBeforeTurn;
            }
            if (turnResult?.moved === false) {
                attempts.push({
                    pageTurnIndex,
                    turnResult,
                    visibleTargetOpened: false,
                    visibleTargetFailureReason: turnResult?.failureReason ?? 'pageTurnDidNotMove',
                });
                break;
            }
            let positionAfterTurn = this.#lookupNavigationPositionSnapshot();
            const crossedSection =
                positionBeforeTurn?.sectionIndex !== positionAfterTurn?.sectionIndex
                || positionBeforeTurn?.rendererCurrentIndex !== positionAfterTurn?.rendererCurrentIndex;
            if (crossedSection && this.displaySettledSequence === displaySettledSequenceBeforeTurn) {
                turnResult.displaySettled = await this.waitForNextDisplaySettled('lookup-navigation.page-turn');
                positionAfterTurn = this.#lookupNavigationPositionSnapshot();
            }
            const navigationSettledResult = this.#settleAfterLookupPageTurn('lookup-navigation.page-turn-settled');
            const visiblePositionAfterTurn = {
                reason: navigationSettledResult.reason,
                refreshResults: navigationSettledResult.refreshResults,
                signature: navigationSettledResult.signature,
            };
            const visiblePositionChanged =
                (visiblePositionBeforeTurn.signature || '') !== (visiblePositionAfterTurn.signature || '');
            const positionChanged =
                this.#lookupNavigationPositionChanged(positionBeforeTurn, positionAfterTurn)
                || visiblePositionChanged;
            if (turnResult) {
                turnResult.positionAfter = positionAfterTurn;
                turnResult.positionChanged = positionChanged;
                turnResult.visiblePositionBefore = visiblePositionBeforeTurn;
                turnResult.visiblePositionAfter = visiblePositionAfterTurn;
                turnResult.visiblePositionChanged = visiblePositionChanged;
                turnResult.crossedSection = crossedSection;
                turnResult.navigationSettled = navigationSettledResult;
            }
            if (!positionChanged) {
                attempts.push({
                    pageTurnIndex,
                    turnResult,
                    visibleTargetOpened: false,
                    visibleTargetFailureReason: 'pageTurnDidNotMove',
                });
                break;
            }
            const attempt = {
                pageTurnIndex,
                turnResult,
                visibleTargetOpened: false,
                visibleTargetFailureReason: null,
            };
            attempts.push(attempt);
            let visibleTargetResult = null;
            try {
                visibleTargetResult = await this.#openVisibleLookupTargetAfterPageTurnWhenReady({
                    ...(request && typeof request === 'object' ? request : {}),
                    kind,
                    direction,
                });
            } catch (error) {
                visibleTargetResult = {
                    opened: false,
                    failureReason: 'visibleTargetError',
                    error: error?.message || String(error),
                };
            }
            attempt.visibleTargetOpened = visibleTargetResult?.opened === true;
            attempt.visibleTargetFailureReason = visibleTargetResult?.failureReason ?? null;
            if (visibleTargetResult?.opened === true) {
                return {
                    opened: true,
                    kind,
                    direction,
                    pageTurnIndex,
                    visibleTargetResult,
                    attempts,
                    elapsedMs: Math.round(performance.now() - startedAt),
                };
            }
            if (visibleTargetResult?.failureReason !== 'noVisibleTargetAfterPageTurn') {
                break;
            }
        }
        return {
            opened: false,
            failureReason: 'pageTurnLookupTargetNotFound',
            kind,
            direction,
            attempts,
            elapsedMs: Math.round(performance.now() - startedAt),
        };
        } finally {
            if (this.lookupNavigationPageTurnToken === token) {
                this.lookupNavigationPageTurnActive = false;
            }
        }
    }
    #installVisibleRendererGoToGuard() {
        const renderer = this.view?.renderer;
        if (!renderer || renderer.__manabiVisibleGoToGuardInstalled) return;
        const originalGoTo = renderer.goTo;
        if (typeof originalGoTo !== 'function') return;
        const reader = this;
        renderer.goTo = function guardedVisibleRendererGoTo(target, ...args) {
            const targetIndex = typeof target?.index === 'number' ? Math.max(0, Math.round(target.index)) : null;
            const currentIndex = getPrimaryRendererContentIndex(renderer);
            const currentPage = reader.navHUD?.rendererPageSnapshot?.current ?? null;
            const totalPages = reader.navHUD?.rendererPageSnapshot?.total ?? null;
            const targetAnchor = typeof target?.anchor === 'number' && Number.isFinite(target.anchor)
                ? Math.max(0, Math.min(1, target.anchor))
                : null;
            const targetPage = typeof targetAnchor === 'number'
                && typeof totalPages === 'number'
                && totalPages > 1
                ? Math.max(1, Math.min(totalPages, Math.round(targetAnchor * (totalPages - 1)) + 1))
                : null;
            const sameIndex = typeof targetIndex === 'number'
                && typeof currentIndex === 'number'
                && targetIndex === currentIndex;
            const sameVisiblePage = sameIndex
                && (
                    targetAnchor === null
                    || (
                        typeof targetPage === 'number'
                        && typeof currentPage === 'number'
                        && targetPage === currentPage
                    )
                );
            if (sameVisiblePage) {
                return Promise.resolve();
            }
            return originalGoTo.call(this, target, ...args);
        };
        renderer.__manabiVisibleGoToGuardInstalled = true;
    }
    #resolveDisplaySettledWaiters(reason = 'unspecified') {
        this.displaySettledSequence += 1;
        const waiters = this.displaySettledWaiters.splice(0);
        if (!waiters.length) { return; }
        const result = {
            reason,
            sequence: this.displaySettledSequence,
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
            hasReaderContent: !!document.querySelector?.('foliate-view'),
            renderReady: document.documentElement?.dataset?.manabiReaderRenderReady === '1',
        };
        waiters.forEach((waiter) => waiter?.resolve?.(result));
    }
    resolveDisplaySettledWaiters(reason = 'unspecified') {
        this.#resolveDisplaySettledWaiters(reason);
    }
    async waitForNextDisplaySettled(reason = 'unspecified', {
        timeoutMs = 1800,
    } = {}) {
        let timeoutHandle = null;
        let waiter = null;
        try {
            return await new Promise((resolve) => {
                waiter = { resolve };
                this.displaySettledWaiters.push(waiter);
                if (Number.isFinite(timeoutMs) && timeoutMs > 0) {
                    timeoutHandle = setTimeout(() => {
                        this.displaySettledWaiters = this.displaySettledWaiters.filter((item) => item !== waiter);
                        resolve({
                            reason: `${reason}.timeout`,
                            timedOut: true,
                            sequence: this.displaySettledSequence,
                        });
                    }, timeoutMs);
                }
            });
        } finally {
            if (timeoutHandle !== null) {
                clearTimeout(timeoutHandle);
            }
        }
    }
    #onGoTo(event = {}) {
        const goToDetail = event?.detail ?? event ?? {};
        const willLoadNewIndex = goToDetail.willLoadNewIndex === true;
        if (!willLoadNewIndex) {
            this.sameIndexGoToDidDisplaySkips = Math.max(1, this.sameIndexGoToDidDisplaySkips || 0);
            return;
        }
        this.#clearVisiblePageReadChrome('goTo');
        requestLookupCloseForPageMotion('renderer.goTo', {
            willLoadNewIndex: true,
        });
        this.renderReadinessGeneration = this.#renderReadiness.begin(
            Number.isInteger(goToDetail.index) ? goToDetail.index : null
        );
        this.setLoadingIndicator(true);
    }
    async #onDidDisplay({}) {
        const displayedIndex = getPrimaryRendererContentIndex(this.view?.renderer);
        const renderReadinessGeneration = this.renderReadinessGeneration
            || (this.renderReadinessGeneration = this.#renderReadiness.begin());
        if (!this.#renderReadiness.validate(renderReadinessGeneration, displayedIndex).accepted) {
            return;
        }
        const navVisibilityBefore = captureNavVisibilityState();
        const shouldSkipSameIndexDidDisplay =
            (this.sameIndexGoToDidDisplaySkips || 0) > 0
            && !document.body?.classList?.contains?.('loading');
        if (shouldSkipSameIndexDidDisplay) {
            this.sameIndexGoToDidDisplaySkips = Math.max(0, (this.sameIndexGoToDidDisplaySkips || 0) - 1);
            return;
        }
        this.#postBookInsetSnapshot('didDisplay.begin', {
            beforeNavigationVisibility: navVisibilityBefore,
        });
        applyStoredChromeInsets('reader.didDisplay');
        const initialSettleResult = await this.#settleInitialPaginatorLayout('did-display.pre-clear', {
            allowWhileLoading: true,
        });
        this.#postBookInsetSnapshot('didDisplay.after-initial-settle', {
            initialSettleResult,
        });
        await this.#waitForAnimationFrames(2);
        this.#postBookInsetSnapshot('didDisplay.after-two-frames-before-force', {
            initialSettleResult,
        });
        const shouldRunPostFrameSettle =
            initialSettleResult?.rendered === true
            || initialSettleResult?.reason === 'error';
        const postFrameSettleResult = shouldRunPostFrameSettle
            ? await this.#settleInitialPaginatorLayout('did-display.pre-clear.post-frame', {
                allowWhileLoading: true,
                force: true,
            })
            : {
                rendered: false,
                reason: 'initial-settle-stable',
            };
        this.#postBookInsetSnapshot('didDisplay.after-post-frame-settle', {
            initialSettleResult,
            postFrameSettleResult,
        });
        const initialRenderableProbe = (() => {
            try {
                const renderer = this.view?.renderer ?? null;
                const contents = renderer?.getContents?.() ?? [];
                const currentIndex = getPrimaryRendererContentIndex(renderer);
                const content = typeof currentIndex === 'number'
                    ? contents.find(item => item?.index === currentIndex) ?? contents[0]
                    : contents[0];
                const doc = content?.doc ?? content?.document ?? null;
                if (!isDocumentLike(doc)) return null;
                const visibleSegmentsResult = collectVisibleSegmentNodesFromRange(doc, this.#visibleRangeForDocument(doc), {
                    viewportSampleDensity: 'minimal',
                    includeSegmentMetadata: false,
                });
                return {
                    doc,
                    visibleSegmentsResult,
                    readiness: classifyEbookRenderReadiness(doc, visibleSegmentsResult),
                };
            } catch (_error) {
                return null;
            }
        })();
        let renderReadiness = initialRenderableProbe?.readiness ?? {
            outcome: 'error',
            reason: 'missing-active-document',
            hasRenderableContent: false,
        };
        if (renderReadiness.outcome === 'pending' && initialRenderableProbe?.doc) {
            const signal = await waitForEbookRenderReadinessSignal(initialRenderableProbe.doc);
            if (signal !== 'timeout') {
                const visibleSegmentsResult = collectVisibleSegmentNodesFromRange(
                    initialRenderableProbe.doc,
                    this.#visibleRangeForDocument(initialRenderableProbe.doc),
                    { viewportSampleDensity: 'minimal', includeSegmentMetadata: false }
                );
                renderReadiness = classifyEbookRenderReadiness(initialRenderableProbe.doc, visibleSegmentsResult);
            }
            if (renderReadiness.outcome === 'pending') {
                renderReadiness = {
                    ...renderReadiness,
                    outcome: 'error',
                    reason: signal === 'timeout' ? 'render-readiness-timeout' : 'render-readiness-unresolved',
                };
            }
        }
        if (renderReadiness.hasRenderableContent === true) {
            await this.#waitForAnimationFrames(1);
        }
        const readinessSettlement = this.#renderReadiness.settle(
            renderReadinessGeneration,
            renderReadiness,
            displayedIndex
        );
        if (!readinessSettlement.accepted) {
            return;
        }
        if (document.body?.dataset) {
            document.body.dataset.manabiReaderRenderOutcome = readinessSettlement.outcome;
        }
        this.setLoadingIndicator(false);
        this.#postBookInsetSnapshot('didDisplay.loading-cleared', {
            initialSettleResult,
            postFrameSettleResult,
            renderReadiness,
            readinessSettlement,
            initialRenderableProbe: initialRenderableProbe?.visibleSegmentsResult ? {
                candidateSource: initialRenderableProbe.visibleSegmentsResult.segmentCandidateSource ?? null,
                observedSegmentCount: initialRenderableProbe.visibleSegmentsResult.totalSegmentCount ?? 0,
                visibleSegmentCount: initialRenderableProbe.visibleSegmentsResult.visibleSegments?.length ?? 0,
                measuredSegmentGeometryCount: initialRenderableProbe.visibleSegmentsResult.rectMeasureCount ?? 0,
                includesSegmentMetadata: initialRenderableProbe.visibleSegmentsResult.includesSegmentMetadata === true,
            } : null,
        });
        setTimeout(() => {
            this.#postBookInsetSnapshot('didDisplay.loading-cleared.plus-250ms', {
                initialSettleResult,
                postFrameSettleResult,
            });
        }, 250);
        try {
            globalThis.__manabiFinishEPUBLoadWatchdogs?.('didDisplay.loading-cleared');
        } catch (_error) {}
        markReaderRenderReady('didDisplay.loading-cleared');
        this.#resolveDisplaySettledWaiters('didDisplay.loading-cleared');
        if (globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay === true) {
            this.navHUD?.setHideNavigationDueToScroll?.(true, 'mark-read.didDisplay.preserve-hidden', {
                stage: 'before-raf',
            });
            globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay = false;
            globalThis.__manabiIgnoreNextIncomingRevealNavigationCount = 0;
        }
        if (this.navHUD?.hideNavigationDueToScroll) {
            this.navHUD.setHideNavigationDueToScroll(true, 'reader.didDisplay.reapply', {
                stage: 'before-raf',
            });
        }
        this.#applyHideNavigationDueToScrollToBookContent(this.navHUD?.hideNavigationDueToScroll === true);
        this.#scheduleInitialPaginatorSettle('did-display');
        this.#scheduleNativeLookupHitTargetRefreshSettle('didDisplay');
        postReaderVisibilityProbe('reader.didDisplay', this.view, null);
    }
    #onLoad({
        detail: {
            doc
        }
    }) {
        applyStoredChromeInsets('reader.documentLoad');
        applyLayoutSettingsToEbookDocument(document, doc);
        applyNavigationHiddenStateToEbookDocument(doc, 'document-load');
        const singleMediaInitialLayout = !isCacheWarmerDocument(doc)
            ? classifySingleMediaDocumentForInitialLayout(doc, 'document-load')
            : { applied: false, reason: 'cache-warmer-document' };
        if (!isCacheWarmerDocument(doc)) {
        }
        try {
            window.manabiForwardReaderFontToEbookDocuments?.('document-load', doc);
        } catch (error) {
        }
        try {
            window.manabiApplyReaderThemeToEbookDocuments?.('document-load', doc);
        } catch (_error) {}
        try {
            window.manabiApplyReaderFontSizeToEbookDocuments?.('document-load', doc);
        } catch (error) {
        }
        if (doc?.fonts?.ready?.then) {
            const fontsReadyStartedAt = performanceNowMs();
            doc.fonts.ready.then(() => {

                if (!isCacheWarmerDocument(doc)) {
                }
            }).catch((error) => {
            });
        }
        requestAnimationFrame(() => {
            const sourceHref = doc?.body?.dataset?.mnbSourceHref || null;
            if (!isCacheWarmerDocument(doc)) {
                window.manabi_recordLiveSettledSection?.(sourceHref);
            }
        });
        doc.addEventListener('keydown', this.#handleKeydown.bind(this))
        if (doc && doc.__manabiMay20BlankTapLoggingInstalled !== true) {
            doc.__manabiMay20BlankTapLoggingInstalled = true;
            const blankPointerMoveThreshold = 12;
            let pendingBlankPointerTap = null;
            let lastPostedBlankTouchTap = null;
            const syntheticMouseAfterTouchSuppressionMs = 900;
            const syntheticMouseAfterTouchDistanceThreshold = 24;
            const touchPointForBlankPointer = event => event.changedTouches?.[0] ?? event.touches?.[0] ?? event;
            const blankPointerPoint = event => {
                const point = touchPointForBlankPointer(event);
                if (!point) return null;
                return {
                    x: point.screenX ?? point.clientX ?? null,
                    y: point.screenY ?? point.clientY ?? null,
                };
            };
            const clearPendingBlankPointerTap = () => {
                pendingBlankPointerTap = null;
            };
            const shouldSuppressSyntheticMouseBlankTap = (event, now) => {
                if (event.type !== 'mousedown' || !lastPostedBlankTouchTap) {
                    return false;
                }
                const ageMs = now - lastPostedBlankTouchTap.postedAtMs;
                if (ageMs < 0 || ageMs > syntheticMouseAfterTouchSuppressionMs) {
                    return false;
                }
                const point = blankPointerPoint(event);
                if (!point || point.x === null || point.y === null) {
                    return true;
                }
                const dx = point.x - lastPostedBlankTouchTap.x;
                const dy = point.y - lastPostedBlankTouchTap.y;
                return (dx * dx + dy * dy) <= (syntheticMouseAfterTouchDistanceThreshold * syntheticMouseAfterTouchDistanceThreshold);
            };
            const blankPointerMovedPastTapThreshold = (event, pending) => {
                const point = touchPointForBlankPointer(event);
                const dx = (point?.screenX ?? point?.clientX ?? pending.startX) - pending.startX;
                const dy = (point?.screenY ?? point?.clientY ?? pending.startY) - pending.startY;
                return (dx * dx + dy * dy) > (blankPointerMoveThreshold * blankPointerMoveThreshold);
            };
            const postContentDocumentBlankPointerTap = (event, source, touchstartAtMs = Date.now()) => {
                const target = event.target;
                const excludedTarget = target?.closest?.('a, button, input, textarea, select, [role="button"], [contenteditable="true"], mnb-sur, .mnb-seg, .mnb-sentence, ruby, rt');
                const now = Date.now();
                if (shouldSuppressSyntheticMouseBlankTap(event, now)) {
                    return;
                }
                if (excludedTarget) {
                    return;
                }
                const lastPostedAt = Number(doc.__manabiLastBlankPointerPostAt || 0);
                if (now - lastPostedAt > 350) {
                    doc.__manabiLastBlankPointerPostAt = now;
                    const ebookNavigationHidden =
                        globalThis.reader?.navHUD?.hideNavigationDueToScroll === true
                        || doc?.body?.dataset?.mnbNavigationHiddenDueToScroll === 'true'
                        || doc?.body?.classList?.contains?.('nav-hidden-due-to-scroll') === true;
                    globalThis.__manabiLastContentDocumentBlankToggleAtMs = now;
                    if (event.type === 'touchend') {
                        const point = blankPointerPoint(event);
                        lastPostedBlankTouchTap = point && point.x !== null && point.y !== null
                            ? {
                                postedAtMs: now,
                                x: point.x,
                                y: point.y,
                            }
                            : null;
                    }
                    window.webkit?.messageHandlers?.touchstartCallbackHandler?.postMessage?.({
                        touchedEntryWithElementId: null,
                        wasAlreadySelected: false,
                        touchstartAtMs,
                        touchstartEventType: event.type,
                        ebookNavigationHidden,
                        source,
                    });
                } else {
                }
            };
            const handleBlankPointerTouchStart = (event) => {
                const target = event.target;
                const excludedTarget = target?.closest?.('a, button, input, textarea, select, [role="button"], [contenteditable="true"], mnb-sur, .mnb-seg, .mnb-sentence, ruby, rt');
                if (excludedTarget) {
                    clearPendingBlankPointerTap();
                    return;
                }
                const point = touchPointForBlankPointer(event);
                pendingBlankPointerTap = point
                    ? {
                        startX: point.screenX ?? point.clientX,
                        startY: point.screenY ?? point.clientY,
                        startAtMs: Date.now(),
                    }
                    : null;
            };
            const handleBlankPointerTouchMove = (event) => {
                const pending = pendingBlankPointerTap;
                if (!pending) return;
                if (blankPointerMovedPastTapThreshold(event, pending)) {
                    clearPendingBlankPointerTap();
                }
            };
            const handleBlankPointerTouchEnd = (event) => {
                const pending = pendingBlankPointerTap;
                clearPendingBlankPointerTap();
                if (!pending || event.type === 'touchcancel') {
                    return;
                }
                if (blankPointerMovedPastTapThreshold(event, pending)) {
                    return;
                }
                postContentDocumentBlankPointerTap(event, 'content-document.blank', pending.startAtMs);
            };
            const handleBlankPointerMouseDown = (event) => {
                postContentDocumentBlankPointerTap(event, 'content-document.blank.mouse');
            };
            doc.addEventListener('touchstart', handleBlankPointerTouchStart, { passive: true, capture: true });
            doc.addEventListener('touchmove', handleBlankPointerTouchMove, { passive: true, capture: true });
            doc.addEventListener('touchend', handleBlankPointerTouchEnd, { passive: true, capture: true });
            doc.addEventListener('touchcancel', handleBlankPointerTouchEnd, { passive: true, capture: true });
            doc.addEventListener('mousedown', handleBlankPointerMouseDown, { passive: true, capture: true });
        }
        installRestorePositionSaveUserInputTracking(doc, 'reader-document');
        window.webkit.messageHandlers.updateCurrentContentPage.postMessage({
            topWindowURL: window.top.location.href,
            currentPageURL: doc.location.href,
        })
        this.#schedulePageTrackingSync('document-load', doc, 2, isCacheWarmerDocument(doc) ? 0 : 128);
        postReaderVisibilityProbe('reader.documentLoad', this.view, {
            documentURL: doc?.location?.href || null,
        });
    }

    #resetSideNavChevrons() {
        // Clear any fade timers
        clearTimeout(this.#chevronFadeTimers.l);
        clearTimeout(this.#chevronFadeTimers.r);
        // Remove visible class & reset opacity immediately
        const leftIcon = document.querySelector('#btn-scroll-left .icon');
        const rightIcon = document.querySelector('#btn-scroll-right .icon');
        [
            { icon: leftIcon, key: 'l' },
            { icon: rightIcon, key: 'r' },
        ].forEach(({ icon, key }) => {
            if (!icon) {
                return;
            }
            icon.classList.remove('chevron-visible');
            icon.style.opacity = '';
            icon.style.visibility = '';
        });
    }

    #postUpdateReadingProgressMessage = debounce(({
        fraction,
        cfi,
        reason,
        currentPageNumber,
        totalPages,
        sectionIndex,
    }) => {
        let mainDocumentURL = (window.location != window.parent.location) ? document.referrer : document.location.href
        const contents = this.view?.renderer?.getContents?.() || [];
        const doc = contents[0]?.doc || contents[0]?.document || null;
        const visibleRange = isDocumentLike(doc) ? this.#visibleRangeForDocument(doc) : null;
        const visibleSegmentsResult = isDocumentLike(doc)
            ? this.#visiblePageSegmentResult(doc, visibleRange, 'reading-progress')
            : null;
        const visibleJapaneseTextState = getVisibleJapaneseTextStateForRenderer(
            this.view?.renderer,
            visibleRange,
            visibleSegmentsResult
        );
        window.webkit.messageHandlers.updateReadingProgress.postMessage({
            fractionalCompletion: fraction,
            cfi: cfi,
            reason: reason,
            mainDocumentURL: mainDocumentURL,
            currentPageNumber: currentPageNumber,
            totalPages: totalPages,
            sectionIndex: sectionIndex,
            hasVisibleJapaneseText: visibleJapaneseTextState.hasVisibleJapaneseText,
            visibleSegmentCount: visibleJapaneseTextState.visibleSegmentCount,
            observedSegmentCount: visibleJapaneseTextState.observedSegmentCount,
        })
    }, 400)

    async #onRelocate({
        detail
    }) {
        const {
            fraction,
            location,
            tocItem,
            pageItem,
            cfi,
            reason
        } = detail
        this.#invalidateVisiblePageSegmentSnapshot('renderer.relocate');
        const isLookupNavigationPageTurn = this.lookupNavigationPageTurnActive === true;
        if (!isLookupNavigationPageTurn) {
            requestLookupCloseForPageMotion('renderer.relocate', {
                reason: reason ?? null,
                fraction: safeRound(fraction),
                currentLocation: location?.current ?? null,
                totalLocation: location?.total ?? null,
            });
        }
        await this.navHUD?.handleRelocate(detail);
        if (isLookupNavigationPageTurn) {
            this.refreshLookupNavigationVisibleTargetsForRelocate('lookup-navigation.relocate');
            this.resolveDisplaySettledWaiters('relocate.lookup-navigation');
        } else {
            this.#scheduleNativeLookupHitTargetRefreshSettle('relocate');
        }
        const primaryLabelDiagnostics = this.navHUD?.lastPrimaryLabelDiagnostics ?? null;
        const effectiveFraction = getAuthoritativeReaderFraction({
            navHUD: this.navHUD,
            detail,
            fallbackFraction: fraction,
        });
        const progressFraction = ebookProgressFractionForRelocate({
            relocateFraction: fraction,
            authoritativeFraction: effectiveFraction,
        });
        const currentPercent = typeof primaryLabelDiagnostics?.currentPercent === 'number'
            ? primaryLabelDiagnostics.currentPercent
            : null;
        const sectionIndex =
            typeof detail?.sectionIndex === 'number'
                ? detail.sectionIndex
                : (typeof detail?.index === 'number'
                    ? detail.index
                    : (typeof this.view?.renderer?.currentIndex === 'number'
                        ? this.view.renderer.currentIndex
                        : (typeof getPrimaryRendererContentIndex(this.view?.renderer) === 'number'
                            ? getPrimaryRendererContentIndex(this.view?.renderer)
                        : (typeof this.navHUD?.lastSectionIndexSeen === 'number'
                            ? this.navHUD.lastSectionIndexSeen
                            : null))));
        const localSectionIndex = typeof this.navHUD?.rendererPageSnapshot?.current === 'number'
            ? Math.max(0, this.navHUD.rendererPageSnapshot.current - 1)
            : null;
        const rendererTotal = typeof this.navHUD?.rendererPageSnapshot?.total === 'number'
            ? this.navHUD.rendererPageSnapshot.total
            : null;
        const sectionBaseCFI = typeof sectionIndex === 'number'
            ? (this.view?.book?.sections?.[sectionIndex]?.cfi ?? null)
            : null;
        const cfiLooksSectionBase = typeof cfi === 'string'
            && !!cfi
            && typeof sectionBaseCFI === 'string'
            && cfi === sectionBaseCFI;
        const hasPageScopedObservation = typeof sectionIndex === 'number'
            && typeof localSectionIndex === 'number';
        const priorCFIObservation = this.lastCFIPersistenceObservation;
        let didMarkCFIUnstable = false;
        let cfiIsUnstableAcrossPages = typeof cfi === 'string'
            && !!cfi
            && this.unstableCFIs.has(cfi);
        if (!cfiIsUnstableAcrossPages
            && typeof cfi === 'string'
            && !!cfi
            && hasPageScopedObservation
            && priorCFIObservation?.cfi === cfi
            && (priorCFIObservation.sectionIndex !== sectionIndex
                || priorCFIObservation.localSectionIndex !== localSectionIndex)) {
            this.unstableCFIs.add(cfi);
            cfiIsUnstableAcrossPages = true;
            didMarkCFIUnstable = true;
        }
        this.lastCFIPersistenceObservation = typeof cfi === 'string' && !!cfi && hasPageScopedObservation
            ? {
                cfi,
                sectionIndex,
                localSectionIndex,
                rendererTotal: typeof rendererTotal === 'number' ? rendererTotal : null,
            }
            : null;
        const syntheticRestoreLocator = makeSyntheticRestoreLocator({
            sectionIndex,
            localSectionIndex,
            rendererTotal,
        });
        this.#updateEbookSubscriptionPreviewPageState({
            sectionIndex,
            localSectionIndex,
            rendererTotal,
            reason,
        });
        const shouldPreferSyntheticRestoreLocator = !!syntheticRestoreLocator
            && this.view?.renderer?.localName === 'foliate-paginator';
        const persistedLocator = shouldPreferSyntheticRestoreLocator
            ? syntheticRestoreLocator
            : cfi;
        const progressBridgePayload = {
            reason: reason ?? null,
            effectiveFraction: Number.isFinite(effectiveFraction) ? safeRound(effectiveFraction, 6) : null,
            rawFraction: typeof fraction === 'number' ? safeRound(fraction, 6) : null,
            displayPercent: roundedDisplayPercent(Number.isFinite(effectiveFraction) ? effectiveFraction : fraction),
            currentPercent,
            sectionIndex,
            localSectionIndex,
            rendererTotal,
            rawCFILength: typeof cfi === 'string' ? cfi.length : 0,
            sectionBaseCFILength: typeof sectionBaseCFI === 'string' ? sectionBaseCFI.length : 0,
            cfiLooksSectionBase,
            cfiIsUnstableAcrossPages,
            syntheticRestoreLocator,
            shouldPreferSyntheticRestoreLocator,
            persistedLocatorKind: shouldPreferSyntheticRestoreLocator
                ? 'synthetic'
                : (typeof cfi === 'string' && cfi ? 'cfi' : 'empty'),
            persistedLocatorLength: typeof persistedLocator === 'string' ? persistedLocator.length : 0,
            hasLoadedLastPosition: this.hasLoadedLastPosition,
            restoreInProgress: globalThis.__manabiRestoreInProgress === true,
            suppressNextRestoreRelocateSave: globalThis.__manabiSuppressNextRestoreRelocateSave === true,
            requiresUserInputBeforePositionSave: globalThis.__manabiRequireUserInputBeforePositionSave === true,
            restoreRequestedFraction: Number.isFinite(globalThis.__manabiRequestedRestoreFraction)
                ? safeRound(globalThis.__manabiRequestedRestoreFraction, 6)
                : null,
            restoreRequestedDisplayPercent: roundedDisplayPercent(globalThis.__manabiRequestedRestoreFraction),
        };
        // (removed: setting tocView currentHref here)

        if (this.hasLoadedLastPosition && !globalThis.__manabiRestoreInProgress) {
            if (didMarkCFIUnstable) {
            }
            const normalizedRelocateReason = typeof reason === 'string' ? reason.trim().toLowerCase() : '';
            const shouldSuppressRestoreSettleSave =
                globalThis.__manabiSuppressNextRestoreRelocateSave === true
                && normalizedRelocateReason === 'page';
            if (shouldSuppressRestoreSettleSave) {
                globalThis.__manabiSuppressNextRestoreRelocateSave = false;
            }
            const requiresUserInputBeforePositionSave =
                globalThis.__manabiRequireUserInputBeforePositionSave === true;
            const shouldPersistRelocatePosition =
                normalizedRelocateReason !== 'anchor'
                && !shouldSuppressRestoreSettleSave
                && !requiresUserInputBeforePositionSave;
            if (!shouldPersistRelocatePosition) {
            } else {
                this.#postUpdateReadingProgressMessage({
                    fraction: progressFraction,
                    cfi: persistedLocator,
                    reason,
                    currentPageNumber: typeof this.navHUD?.rendererPageSnapshot?.current === 'number'
                        ? this.navHUD.rendererPageSnapshot.current
                        : null,
                    totalPages: typeof rendererTotal === 'number' ? rendererTotal : null,
                    sectionIndex,
                })
            }
        }

        await this.updateNavButtons();
        if (typeof currentPercent === 'number') {
        }
        postReaderVisibilityProbe('reader.relocate', this.view, {
            reason: detail?.reason || null,
            fraction: safeRound(detail?.fraction),
            currentLocation: detail?.location?.current ?? null,
            totalLocation: detail?.location?.total ?? null,
        });

        // Keep percent-jump input in sync with scroll
        const percentInput = document.getElementById('percent-jump-input');
        const percentButton = document.getElementById('percent-jump-button');
        if (percentInput && percentButton) {
            const pct = Math.round(effectiveFraction * 100);
            percentInput.value = pct;
            this.lastPercentValue = pct;
            percentButton.disabled = true;
        }
    }

    async #onNavButtonClick(e) {
        const btn = e.currentTarget;
        const type = btn.dataset.buttonType;
        markRestorePositionSaveUserInput(`nav-button.${type ?? 'unknown'}`);
        // For spinner placement
        const icon = btn.querySelector('svg');
        const label = btn.querySelector('.button-label');
        // Hide the label while loading
        if (label) label.style.visibility = 'hidden';
        // Replace SVG icon with spinner, respecting spinner placement
        if (icon) {
            btn._originalIcon = icon.cloneNode(true);
            const spinner = document.createElement('div');
            spinner.className = 'ispinner nav-spinner';
            spinner.innerHTML = '<div class="ispinner-blade"></div>'.repeat(8);

            // Improved spinner placement for RTL/LTR
            if (btn._spinnerAfterLabel) {
                if (icon) icon.remove();
                // Find the last visible .button-label (full or short)
                const labels = btn.querySelectorAll('.button-label');
                let targetLabel = null;
                for (const lbl of labels) {
                    if (lbl.offsetParent !== null && getComputedStyle(lbl).display !== 'none') {
                        targetLabel = lbl;
                    }
                }
                if (targetLabel) {
                    targetLabel.after(spinner);
                } else {
                    btn.appendChild(spinner);
                }
            } else {
                // Default: replace icon with spinner
                icon.replaceWith(spinner);
            }
        }
        const restoreIcon = () => {
            const spinner = btn.querySelector('.ispinner.nav-spinner');
            if (spinner && btn._originalIcon) {
                spinner.replaceWith(btn._originalIcon);
                delete btn._originalIcon;
            }
            if (label) label.style.visibility = '';
        };
        const navSpinnerFallbackTimer = setTimeout(restoreIcon, navSpinnerMaximumMs);
        let nav;
        switch (type) {
                // TODO: Clean up, the scroll cases here won't be reached because of above...
            case 'prev':
                // Go to previous section, then jump to its end
                nav = this.view.renderer.prevSection().then(() => {
                    // TODO: Add this here...
                    //this.view.fraction = 1;
                });
                break;
            case 'next':
                nav = this.view.renderer.nextSection();
                break;
        }
        Promise.resolve(nav).finally(() => {
            clearTimeout(navSpinnerFallbackTimer);
            restoreIcon();
        });
    }
}

const canUseNativeCacheWarmerPrewarm = () => {
    return !!window.webkit?.messageHandlers?.ebookNativeCacheWarmerPrewarmSection;
};

class CacheWarmer {
    constructor() {
        this.view
        this.uniqueSentenceIdentifiers = new Set()
        this.lastPostedSentenceCount = null
        this.lastLoadedSectionIndex = null
        this.lastLoadedSectionHref = null
        this.settledSectionHrefs = new Set()
    }
    #isCurrentGeneration(generation) {
        return generation === cacheWarmerWorkGeneration()
    }
    #normalizeSectionHref(href) {
        return normalizeSpineHref(href)
    }
    #bookSections() {
        if (Array.isArray(this.view?.book?.sections)) {
            return this.view.book.sections;
        }
        if (Array.isArray(globalThis.reader?.view?.book?.sections)) {
            return globalThis.reader.view.book.sections;
        }
        return [];
    }
    #mergeSettledSectionHrefs(settledSectionHrefs = []) {
        const foregroundHrefs = foregroundWarmedSectionHrefSet()
        for (const href of foregroundHrefs) {
            const normalizedHref = this.#normalizeSectionHref(href)
            if (normalizedHref) this.settledSectionHrefs.add(normalizedHref)
        }
        for (const href of settledSectionHrefs || []) {
            const normalizedHref = this.#normalizeSectionHref(href)
            if (normalizedHref) this.settledSectionHrefs.add(normalizedHref)
        }
        return Array.from(this.settledSectionHrefs).sort()
    }
    #nextUnsettledSectionIndex(settledSectionHrefs = [], minimumIndex = 0) {
        const sections = this.#bookSections()
        const settled = new Set(
            Array.isArray(settledSectionHrefs)
                ? settledSectionHrefs.map((href) => this.#normalizeSectionHref(href)).filter(Boolean)
                : []
        )
        const activeHref = activeForegroundSectionHref()
        if (activeHref && !Number.isInteger(cacheWarmerPrecedingTargetIndex())) settled.add(activeHref)
        const currentIndex = Number.isInteger(this.lastLoadedSectionIndex) ? this.lastLoadedSectionIndex : -1
        const startIndex = Math.max(currentIndex + 1, Number.isInteger(minimumIndex) ? minimumIndex : 0)
        for (let index = startIndex; index < sections.length; index += 1) {
            const section = sections[index]
            if (section?.linear === 'no') continue
            const normalizedHref = this.#normalizeSectionHref(section?.href ?? section?.id ?? null)
            if (normalizedHref && settled.has(normalizedHref)) continue
            return index
        }
        return null
    }
    nextUnsettledSectionIndexSkippingSettled(settledSectionHrefs = [], minimumIndex = 0) {
        return this.#nextUnsettledSectionIndex(this.#mergeSettledSectionHrefs(settledSectionHrefs), minimumIndex)
    }
    async #prewarmNativeSection(targetIndex, settledSectionHrefs, minimumIndex) {
        const sections = this.#bookSections();
        const section = Number.isInteger(targetIndex) ? sections[targetIndex] : null;
        const sectionHref = this.#normalizeSectionHref(section?.href ?? section?.id ?? null);
        if (!sectionHref) {
            globalThis.__manabiCacheWarmerFinished = true;
            resolveCacheWarmerPrecedingSectionWaiters();
            return;
        }
        this.lastLoadedSectionIndex = targetIndex;
        this.lastLoadedSectionHref = sectionHref;
        globalThis.__manabiNativeCacheWarmerInFlightSectionHref = sectionHref;
        window.webkit.messageHandlers.ebookNativeCacheWarmerPrewarmSection.postMessage({
            topWindowURL: window.top.location.href,
            sectionHref,
            sectionIndex: targetIndex,
            minimumIndex,
            activeSectionIndex: activeForegroundSectionIndex(),
            requiredPrecedingTargetIndex: cacheWarmerPrecedingTargetIndex(),
        });
    }
    async #openFirstUnsettledSection() {
        const generation = cacheWarmerWorkGeneration()
        const settledSectionHrefs = this.#mergeSettledSectionHrefs()
        const precedingTargetIndex = cacheWarmerPrecedingTargetIndex()
        const minimumIndex = Number.isInteger(precedingTargetIndex) ? 0 : activeForegroundSectionIndex()
        const firstUnsettledIndex = this.#nextUnsettledSectionIndex(settledSectionHrefs, minimumIndex)
        const settled = new Set(settledSectionHrefs)
        const activeHref = activeForegroundSectionHref()
        if (activeHref) settled.add(activeHref)
        const sectionSample = (this.view?.book?.sections ?? []).slice(0, 12).map((section, index) => {
            const href = this.#normalizeSectionHref(section?.href ?? section?.id ?? null)
            let skipReason = null
            if (section?.linear === 'no') skipReason = 'non-linear'
            else if (!href) skipReason = 'missing-href'
            else if (href === activeHref) skipReason = 'active-foreground'
            else if (settled.has(href)) skipReason = 'warmed'
            return {
                index,
                href,
                linear: section?.linear ?? null,
                skipReason,
            }
        })
        if (!Number.isInteger(firstUnsettledIndex)) {
            globalThis.__manabiCacheWarmerFinished = true
            resolveCacheWarmerPrecedingSectionWaiters()
            return
        }
        const skippedSettledSectionHrefs = this.view?.book?.sections
            ?.slice(0, firstUnsettledIndex)
            ?.map((section) => this.#normalizeSectionHref(section?.href ?? section?.id ?? null))
            ?.filter((href) => href && settledSectionHrefs.includes(href)) ?? []
        if (firstUnsettledIndex > 0) {
            const targetSection = this.view?.book?.sections?.[firstUnsettledIndex] ?? null
            void targetSection
            void skippedSettledSectionHrefs
        }
        if (canUseNativeCacheWarmerPrewarm()) {
            if (!this.#isCurrentGeneration(generation)) return
            await this.#prewarmNativeSection(firstUnsettledIndex, settledSectionHrefs, minimumIndex)
            return
        }
        await this.view.renderer.goTo({ index: firstUnsettledIndex })
        if (!this.#isCurrentGeneration(generation)) return
    }
    async loadNextSectionSkippingSettled(settledSectionHrefs = [], minimumIndex = 0) {
        const generation = cacheWarmerWorkGeneration()
        settledSectionHrefs = this.#mergeSettledSectionHrefs(settledSectionHrefs)
        const targetIndex = this.#nextUnsettledSectionIndex(settledSectionHrefs, minimumIndex)
        if (!Number.isInteger(targetIndex)) {
            globalThis.__manabiCacheWarmerFinished = true
            resolveCacheWarmerPrecedingSectionWaiters()
            return
        }
        if (canUseNativeCacheWarmerPrewarm()) {
            if (!this.#isCurrentGeneration(generation)) return
            await this.#prewarmNativeSection(targetIndex, settledSectionHrefs, minimumIndex)
            return
        }
        if (Number.isInteger(this.lastLoadedSectionIndex) && targetIndex === this.lastLoadedSectionIndex + 1) {
            await this.view.renderer.nextSection()
            if (!this.#isCurrentGeneration(generation)) return
            return
        }
        const sectionSliceStart = Number.isInteger(this.lastLoadedSectionIndex) ? this.lastLoadedSectionIndex + 1 : 0
        const skippedSettledSectionHrefs = this.view?.book?.sections
            ?.slice(sectionSliceStart, targetIndex)
            ?.map((section) => this.#normalizeSectionHref(section?.href ?? section?.id ?? null))
            ?.filter((href) => href && settledSectionHrefs.includes(href)) ?? []
        void skippedSettledSectionHrefs
        await this.view.renderer.goTo({ index: targetIndex })
        if (!this.#isCurrentGeneration(generation)) return
    }
    destroy() {
        invalidateCacheWarmerWork()
        if (this.view) {
            try {
                this.view.close?.()
            } catch (_error) {}
            this.view.remove?.()
            this.view = null
        }
        this.uniqueSentenceIdentifiers.clear()
        this.lastPostedSentenceCount = null
        this.lastLoadedSectionIndex = null
        this.lastLoadedSectionHref = null
        globalThis.__manabiCacheWarmerReady = false;
        globalThis.__manabiCacheWarmerFinished = false;
        globalThis.__manabiCacheWarmerHighestSectionIndex = null;
        globalThis.__manabiCacheWarmerAdvanceInFlight = false;
    }
    async open(file) {
        this.destroy()
        const generation = invalidateCacheWarmerWork()
        globalThis.__manabiCacheWarmerOpenInFlight = true;
        globalThis.__manabiCacheWarmerReady = false;
        globalThis.__manabiCacheWarmerFinished = false;
        globalThis.__manabiCacheWarmerHighestSectionIndex = null;
        globalThis.__manabiDeferredCacheWarmerLogged = false;
        try {
            this.view = await getView(file, true)
            this.view.addEventListener('load', this.#onLoad.bind(this))

            const {
                book
            } = this.view
            this.view.renderer.setAttribute('flow', 'paginated')
            await this.#openFirstUnsettledSection()
            if (!this.#isCurrentGeneration(generation)) return
            globalThis.__manabiCacheWarmerOpenInFlight = false;
            globalThis.__manabiCacheWarmerReady = true;
        } catch (error) {
            throw error;
        } finally {
            globalThis.__manabiCacheWarmerOpenInFlight = false;
        }
    }

    #finalizeSectionAdvance(advanceState, trigger) {
        if (!advanceState) return;
        const {
            sectionIndex,
            sectionHref,
            atEnd,
            location,
        } = advanceState;
        if (!atEnd) {
            window.webkit.messageHandlers.ebookCacheWarmerReadyToLoadNextSection.postMessage({
                topWindowURL: window.top.location.href,
            })
            return;
        }
        globalThis.__manabiCacheWarmerFinished = true;
        resolveCacheWarmerPrecedingSectionWaiters()
    }

    async #onLoad({
        detail: {
            doc,
            location,
            index,
        }
    }) {
        const sentenceNodes = Array.from(doc?.querySelectorAll?.('mnb-sen') || []);
        const segmentNodes = Array.from(doc?.querySelectorAll?.('mnb-seg') || []);
        const indexedSectionHref =
            Number.isInteger(index)
            ? this.view?.book?.sections?.[index]?.href || null
            : null;
        const sourceHref = doc?.body?.dataset?.mnbSourceHref || indexedSectionHref || null;
        const sectionHref = indexedSectionHref || sourceHref || null;
        this.lastLoadedSectionIndex = Number.isInteger(index) ? index : null;
        this.lastLoadedSectionHref = sectionHref || location || null;
        const normalizedLoadedSectionHref = this.#normalizeSectionHref(sectionHref || location || null);
        if (normalizedLoadedSectionHref) {
            this.settledSectionHrefs.add(normalizedLoadedSectionHref);
        }
        const isLikelyTitlePage = typeof sourceHref === 'string' && /(?:^|\/)(title|cover)\.xhtml$/i.test(sourceHref);
        if (Number.isInteger(index)) {
            globalThis.__manabiCacheWarmerHighestSectionIndex = Math.max(
                globalThis.__manabiCacheWarmerHighestSectionIndex ?? -1,
                index,
            );
            resolveCacheWarmerPrecedingSectionWaiters();
        }
        for (const sentenceNode of sentenceNodes) {
            const sentenceIdentifier = sentenceIdentifierForNode(sentenceNode);
            if (typeof sentenceIdentifier === 'string' && sentenceIdentifier.length > 0) {
                this.uniqueSentenceIdentifiers.add(sentenceIdentifier);
            }
        }
        const shouldDeferSentenceCountUpdate = this.uniqueSentenceIdentifiers.size === 0 && isLikelyTitlePage;
        if (shouldDeferSentenceCountUpdate) {
        } else if (this.lastPostedSentenceCount !== this.uniqueSentenceIdentifiers.size) {
            this.lastPostedSentenceCount = this.uniqueSentenceIdentifiers.size;
            window.webkit.messageHandlers.updateArticleSentenceCount.postMessage({
                windowURL: window.top.location.href,
                articleSentenceCount: this.uniqueSentenceIdentifiers.size,
            });
        }

        window.webkit.messageHandlers.ebookCacheWarmerLoadedSection.postMessage({
            topWindowURL: window.top.location.href,
            frameURL: location,
        })

        const atEnd = await this.view.renderer.atEnd();
        const sectionAdvance = {
            sectionIndex: Number.isInteger(index) ? index : null,
            sectionHref,
            atEnd,
            location,
        };
        this.#finalizeSectionAdvance(sectionAdvance, 'load');
    }

    //    #postUpdateReadingProgressMessage = debounce(({ fraction, cfi }) => {
    //        let mainDocumentURL = (window.location != window.parent.location) ? document.referrer : document.location.href
    //        window.webkit.messageHandlers.updateReadingProgress.postMessage({
    //        fractionalCompletion: fraction,
    //        cfi: cfi,
    //        mainDocumentURL: mainDocumentURL,
    //        })
    //    }, 400)
}

//const open = async (file) => {
//    document.body.removeChild($('#drop-target'))
//    const reader = new Reader()
//    globalThis.reader = reader
//    await reader.open(file)
//}

//const params = new URLSearchParams(location.search)
//const url = params.get('url')
//if (url) fetch(url)
//    .then(res => res.blob())
//    .then(blob => open(new File([blob], new URL(url).pathname)))
//    .catch(e => console.error(e))
//else dropTarget.style.visibility = 'visible'


window.setEbookViewerLayout = (layoutMode) => {
    invalidateCacheWarmerWork()
    // TODO: Add scrolled mode back...
//    globalThis.reader.view.renderer.setAttribute('flow', layoutMode)
    applyStoredChromeInsets('setEbookViewerLayout');
    postEBookSafeAreaTopSnapshot('ebook.safeAreaTop.setLayout', {
        layoutMode,
    });
    globalThis.manabiInvalidateVisiblePageSegmentSnapshot?.('layout-change');
}

window.setEbookViewerWritingDirection = (writingDirection) => {
    invalidateCacheWarmerWork()
    const renderer = globalThis.reader?.view?.renderer ?? null;
    const contents = renderer?.getContents?.() || [];
    const applyWritingDirectionToDocument = (doc) => {
        const body = doc?.body;
        if (!body) return false;
        if (writingDirection === 'vertical') {
            body.dataset.mnbWritingDirection = 'vertical';
        } else if (writingDirection === 'horizontal') {
            body.dataset.mnbWritingDirection = 'horizontal';
        } else {
            body.removeAttribute('data-mnb-writing-direction');
        }
        try {
            doc.defaultView?.manabiApplyVerticalWritingCheck?.();
        } catch (_error) {}
        return true;
    };
    for (const content of contents) {
        applyWritingDirectionToDocument(content?.doc ?? content?.document ?? null);
    }
    globalThis.manabiInvalidateVisiblePageSegmentSnapshot?.('writing-direction-change');
}

window.loadNextCacheWarmerSection = async (settledSectionHrefs = []) => {
    scheduleLoadNextCacheWarmerSection(settledSectionHrefs, 'native-ready');
}

window.loadEBook = ({
    url,
    layoutMode,
    initialRestore,
}) => {
    const requestedURL = typeof url === 'string' ? url : '';
    const initialRestoreRequest = normalizeInitialRestoreRequest(initialRestore);
    if (
        requestedURL.length > 0
        && globalThis.manabiLoadEBookURL === requestedURL
        && globalThis.manabiLoadEBookInFlight === true
    ) {
        const existingStartedAt = Number(globalThis.manabiLoadEBookStartedAt || 0);
        const existingStartedAgeMs = existingStartedAt > 0 ? Date.now() - existingStartedAt : 0;
        if (globalThis.reader?.view?.renderer || existingStartedAgeMs < 2500) {
            globalThis.manabiLoadEBookLastState = 'duplicate-inflight';
            globalThis.manabiPendingInitialRestoreRequest = initialRestoreRequest;
            return globalThis.manabiLoadEBookPromise;
        }
        globalThis.manabiLoadEBookLastState = 'duplicate-inflight-stale-restart';
    }
    if (
        requestedURL.length > 0
        && globalThis.manabiLoadEBookURL === requestedURL
        && globalThis.manabiLoadEBookReady === true
        && globalThis.reader?.view?.renderer
    ) {
        globalThis.manabiLoadEBookLastState = 'duplicate-ready';
        globalThis.manabiPendingLoadEBookArgs = null;
        return;
    }
    const loadToken = (globalThis.manabiLoadEBookToken ?? 0) + 1;
    globalThis.manabiLoadEBookToken = loadToken;
    globalThis.manabiLoadEBookURL = requestedURL;
    globalThis.manabiLoadEBookInFlight = true;
    globalThis.manabiLoadEBookStarted = true;
    globalThis.manabiLoadEBookStartedAt = Date.now();
    globalThis.manabiLoadEBookReady = false;
    globalThis.manabiLoadEBookLastState = 'start';
    globalThis.manabiInitialRestoreResult = null;
    globalThis.manabiPendingLoadEBookArgs = {
        hasURL: typeof url === 'string' && url.length > 0,
        layoutMode: layoutMode || null,
    };
    globalThis.manabiPendingInitialRestoreRequest = initialRestoreRequest;
    try {
        globalThis.__manabiFinishEPUBLoadWatchdogs?.('new-load');
    } catch (_error) {}
    globalThis.__manabiLiveProcessedSectionHrefs = new Set();
    globalThis.__manabiLiveSettledSectionHrefs = new Set();
    globalThis.__manabiFirstLiveSectionHref = null;
    let loadSettled = false;
    const loadWatchdogTimers = [1000, 3000, 8000, 20000, 45000].map(delayMs =>
        setTimeout(() => {
            if (loadSettled) return;
        }, delayMs)
    );
    const finishLoadWatchdogs = () => {
        loadSettled = true;
        for (const timer of loadWatchdogTimers) clearTimeout(timer);
    };
    globalThis.__manabiFinishEPUBLoadWatchdogs = finishLoadWatchdogs;
    const previousReader = globalThis.reader?.view?.renderer ? globalThis.reader : null;
    try {
        globalThis.reader?.view?.close?.()
    } catch (_error) {}
    try {
        globalThis.reader?.view?.remove?.()
    } catch (_error) {}
    try {
        window.cacheWarmer?.destroy?.()
    } catch (_error) {}
    let reader = new Reader()
    globalThis.reader = reader

    window.cacheWarmer = new CacheWarmer()
    window.ebookSource = typeof url === 'string' && url.length > 0 && url.startsWith('ebook://')
        ? makeNativeSource(url)
        : null

    if (url) {
        globalThis.manabiLoadEBookLastState = 'source-start';
        const sourcePromise = window.ebookSource
            ? Promise.resolve(window.ebookSource)
            : fetch(url, {
                headers: {
                    "IS-SWIFTUIWEBVIEW-VIEWER-FILE-REQUEST": "true",
                },
            })
                .then(res => res.blob())
                .then((blob) => {
                    window.blob = blob
                    return makeFileSource(new File([blob], new URL(url).pathname))
                })

        const openPromise = sourcePromise
        .then(async (source) => {
            if (globalThis.manabiLoadEBookToken !== loadToken) return;
            globalThis.manabiLoadEBookLastState = 'source-ready';
            globalThis.manabiPendingLoadEBookArgs = null;
            if (source?.kind === 'native') {
            }
            if (layoutMode) {
                window.initialLayoutMode = layoutMode
            }
            globalThis.manabiLoadEBookLastState = 'reader-open-dispatch';
            await reader.open(source)
            if (globalThis.manabiLoadEBookToken !== loadToken) return;
            if (!reader?.view?.renderer) {
                throw new Error('reader-open-missing-renderer');
            }
            const restoreRequest = globalThis.manabiPendingInitialRestoreRequest;
            globalThis.manabiPendingInitialRestoreRequest = null;
            let restoreSnapshot = null;
            let restoreError = null;
            try {
                restoreSnapshot = await window.loadLastPosition(restoreRequest ?? {
                    cfi: '',
                    fractionalCompletion: 0,
                });
            } catch (error) {
                restoreError = error;
            }
            globalThis.manabiInitialRestoreResult = makeInitialRestoreTerminalResult({
                request: restoreRequest,
                snapshot: restoreSnapshot,
                error: restoreError,
            });
        })
        .then(async () => {
            if (globalThis.manabiLoadEBookToken !== loadToken) return;
            globalThis.reader = reader;
            finishLoadWatchdogs();
            globalThis.manabiLoadEBookReady = true;
            globalThis.manabiLoadEBookLastState = 'reader-open-resolved';
            const probe = globalThis.reader?.collectLayoutGapProbe?.('ebookViewerLoaded', {
                bookDir: globalThis.reader?.bookDir || null,
                isRTL: !!globalThis.reader?.isRTL,
            }) ?? null;
            window.webkit.messageHandlers.ebookViewerLoaded.postMessage({
                probe,
                initialRestoreResult: globalThis.manabiInitialRestoreResult,
            })
        })
        .catch((error) => {
            if (globalThis.manabiLoadEBookToken !== loadToken) {
                return;
            }
            finishLoadWatchdogs();
            globalThis.manabiLoadEBookReady = false;
            globalThis.manabiLoadEBookLastState = `open-error:${error?.message || String(error)}`;
            if (globalThis.reader === reader || !globalThis.reader?.view?.renderer) {
                globalThis.reader = previousReader ?? null;
            }
            try {
                reader?.setLoadingIndicator?.(false);
            } catch (_error) {}
            throw error;
        })
        .finally(() => {
            if (globalThis.manabiLoadEBookToken !== loadToken) return;
            globalThis.manabiLoadEBookInFlight = false;
            globalThis.manabiLoadEBookPromise = null;
        })
        globalThis.manabiLoadEBookPromise = openPromise;
        return openPromise;
    } else {
        finishLoadWatchdogs();
        globalThis.manabiLoadEBookReady = false;
        globalThis.manabiLoadEBookLastState = 'no-url';
        globalThis.manabiPendingLoadEBookArgs = null;
        globalThis.manabiLoadEBookInFlight = false;
        globalThis.manabiLoadEBookPromise = null;
    }
    //.catch(e => console.error(e))
}

const markRestorePositionSaveUserInput = () => {
    if (globalThis.__manabiRequireUserInputBeforePositionSave !== true) {
        return;
    }
    globalThis.__manabiRequireUserInputBeforePositionSave = false;
    globalThis.__manabiSuppressNextRestoreRelocateSave = false;
};

const ensureRestorePositionSaveUserInputTracking = () => {
    if (globalThis.__manabiRestoreUserInputTrackingInstalled === true) {
        return;
    }
    globalThis.__manabiRestoreUserInputTrackingInstalled = true;
    for (const eventName of ['pointerdown', 'touchstart', 'wheel', 'keydown', 'click']) {
        window.addEventListener(eventName, markRestorePositionSaveUserInput, {
            capture: true,
            passive: true,
        });
    }
};

const installRestorePositionSaveUserInputTracking = (target, source) => {
    if (!target?.addEventListener) {
        return;
    }
    for (const eventName of ['pointerdown', 'touchstart', 'wheel', 'keydown', 'click']) {
        target.addEventListener(eventName, (event) => {
            markRestorePositionSaveUserInput(`${source}.${event?.type ?? eventName}`);
        }, {
            capture: true,
            passive: true,
        });
    }
};

window.loadLastPosition = async ({
    cfi,
    fractionalCompletion,
}) => {
    ensureRestorePositionSaveUserInputTracking();
    globalThis.__manabiRequestedRestoreFraction = Number.isFinite(fractionalCompletion)
        ? Math.max(0, Math.min(1, fractionalCompletion))
        : null;
    globalThis.__manabiRestoreInProgress = true;
    const awaitWithTimeout = (promise, timeoutMs) =>
        Promise.race([
            promise,
            new Promise((_, reject) => {
                setTimeout(() => reject(new Error(`Timed out after ${timeoutMs}ms`)), timeoutMs);
            }),
        ]);
    const waitForFrames = async (count = 2) => {
        for (let index = 0; index < count; index += 1) {
            await new Promise((resolve) => requestAnimationFrame(() => resolve()));
        }
    };
    const captureRestoreState = (stage, extra = {}) => {
        const detail = globalThis.reader?.view?.lastLocation ?? null;
        const currentFraction = typeof detail?.fraction === 'number' ? detail.fraction : null;
        const locationCurrent = typeof detail?.location?.current === 'number' ? detail.location.current : null;
        const locationTotal = typeof detail?.location?.total === 'number' ? detail.location.total : null;
        const sectionIndex = typeof detail?.section?.current === 'number'
            ? detail.section.current
            : (typeof detail?.sectionIndex === 'number' ? detail.sectionIndex : null);
        return {
            detail,
            currentFraction,
            locationCurrent,
            locationTotal,
            sectionIndex,
        };
    };
    const hasFractionalCompletion = Number.isFinite(fractionalCompletion) && fractionalCompletion > 0;
    const syntheticRestoreLocator = parseSyntheticRestoreLocator(cfi);
    const restoreLocatorKind = classifyRestoreLocator({ cfi, fractionalCompletion });
    let handledCFI = null;
    const reconcileRestoreFractionIfNeeded = async (restoreState, reason, stageOnReconcile) => {
        if (!hasFractionalCompletion || typeof restoreState?.currentFraction !== 'number') {
            return;
        }
        const delta = Math.abs(restoreState.currentFraction - fractionalCompletion);
        const requestedDisplayPercent = roundedDisplayPercent(fractionalCompletion);
        const landedDisplayPercent = roundedDisplayPercent(restoreState.currentFraction);
        const displayPercentChanged = requestedDisplayPercent != null
            && landedDisplayPercent != null
            && requestedDisplayPercent !== landedDisplayPercent;
        if (delta <= 0.003 && !displayPercentChanged) {
            return;
        }
        const rendererPageCurrent = globalThis.reader?.navHUD?.rendererPageSnapshot?.current ?? null;
        const rendererPageTotal = globalThis.reader?.navHUD?.rendererPageSnapshot?.total ?? null;
        const targetRendererPage = typeof rendererPageTotal === 'number' && rendererPageTotal > 1
            ? Math.max(1, Math.min(rendererPageTotal, Math.round(fractionalCompletion * (rendererPageTotal - 1)) + 1))
            : null;
        if (
            typeof rendererPageCurrent === 'number'
            && typeof targetRendererPage === 'number'
            && rendererPageCurrent === targetRendererPage
        ) {
            return;
        }
        await runWithNavigationIntent({
            source: 'restore.reconcile',
            reason,
            target: 'view.goToFraction',
            fraction: fractionalCompletion,
            stageOnReconcile,
        }, () => globalThis.reader.view.goToFraction(fractionalCompletion));
        await waitForFrames(2);
        const reconciledState = captureRestoreState(stageOnReconcile, {
            drift: safeRound(delta, 6),
        });
    };
    try {
        if (syntheticRestoreLocator) {
            if (typeof globalThis.reader?.displayInitialSection === 'function') {
                await globalThis.reader.displayInitialSection('loadLastPosition.synthetic-locator', {
                    cfi,
                    fractionalCompletion,
                });
            }
            await waitForFrames(2);
            const syntheticState = captureRestoreState('after-synthetic-locator', {
                sectionIndex: syntheticRestoreLocator.sectionIndex,
                localSectionIndex: syntheticRestoreLocator.localSectionIndex,
                rendererTotal: syntheticRestoreLocator.rendererTotal,
            });
            handledCFI = typeof cfi === 'string' && cfi.length > 0 ? cfi : null;
        } else if (cfi.length > 0) {
            const navigationResult = await runRequiredRestoreNavigation(() => runWithNavigationIntent(
                {
                    source: 'restore.cfi',
                    target: 'view.goTo',
                    cfiLength: cfi.length,
                    fraction: hasFractionalCompletion ? fractionalCompletion : null,
                },
                () => globalThis.reader.view.goTo(cfi),
            ));
            if (!navigationResult.ok) {
                throw navigationResult.error ?? new Error('CFI restore navigation failed');
            }
            handledCFI = cfi;
            await waitForFrames(2);
            const cfiState = captureRestoreState('after-cfi');
            await reconcileRestoreFractionIfNeeded(
                cfiState,
                'cfi-fraction-drift',
                'after-cfi-fraction-reconcile',
            );
        } else if (hasFractionalCompletion) {
            const navigationResult = await runRequiredRestoreNavigation(() => runWithNavigationIntent(
                {
                    source: 'restore.fraction',
                    target: 'view.goToFraction',
                    fraction: fractionalCompletion,
                },
                () => globalThis.reader.view.goToFraction(fractionalCompletion),
            ));
            if (!navigationResult.ok) {
                throw navigationResult.error ?? new Error('Fraction restore navigation failed');
            }
            await waitForFrames(2);
            const fractionState = captureRestoreState('after-fraction');
        } else {
            try {
                await awaitWithTimeout(globalThis.reader.view.renderer.next(), 1500);
            } catch (error) {
                await globalThis.reader.view.renderer.nextSection();
            }
            await waitForFrames(2);
            const defaultState = captureRestoreState('after-default-next');
        }
        globalThis.reader.hasLoadedLastPosition = true
        globalThis.reader.refreshNativeLookupHitTargets?.('load-last-position-done');
        const doneState = captureRestoreState('done');
        globalThis.reader?.maybeFlashInitialForwardSideNavChevron?.(doneState);
        markReaderRenderReady('loadLastPosition.done');
        postLandscapeInsetRestoreProbe('done', doneState, {
            hasCFI: typeof cfi === 'string' && cfi.length > 0,
            requestedFraction: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
        });

        // Let the visible section finish rendering before warming secondary sections.
        scheduleDeferredCacheWarmerOpen('load-last-position-done', 2200);
        return {
            handledFractionalCompletion: doneState.currentFraction,
            currentFractionalCompletion: doneState.currentFraction,
            handledCFI,
        };
    } catch (error) {
        if (globalThis.reader) {
            globalThis.reader.hasLoadedLastPosition = false;
        }
        throw error;
    } finally {
        globalThis.__manabiRestoreInProgress = false;
        globalThis.__manabiSuppressNextRestoreRelocateSave = false;
        globalThis.__manabiRequireUserInputBeforePositionSave = true;
    }
}

window.refreshBookReadingProgress = async (articleReadingProgress) => {
    if (!globalThis.reader) {
        return;
    }
    const normalizedProgress = normalizeArticleReadingProgress(articleReadingProgress);
    globalThis.reader.applyBookReadingProgress(articleReadingProgress, 'native-refresh');
    await globalThis.reader.updateNavButtons();
}

window.manabiToggleReaderTableOfContents = () => {
    globalThis.reader?.toggleTableOfContents?.();
}

window.manabiHandlePhysicalArrowKey = async (direction) => {
    return await globalThis.reader?.handlePhysicalArrowKey?.(direction) ?? false;
}

window.manabi_performLookupNavigationPageTurn = async (request = {}) => {
    return await globalThis.reader?.performLookupNavigationPageTurn?.(request) ?? {
        opened: false,
        failureReason: 'missingReader',
    };
}

window.manabiGetReaderGoToSheetSnapshot = async () => {
    return await globalThis.reader?.buildGoToSheetSnapshot?.() ?? {
        isRTL: false,
        currentChapterHref: null,
        currentChapterTitle: null,
        currentPercent: null,
        chapters: [],
    };
}

window.manabiScheduleReaderPageGoTo = (pageNumber) => {
    markRestorePositionSaveUserInput('bridge.scheduleReaderPageGoTo');
    globalThis.reader?.scheduleGoToPageNumber?.(pageNumber);
}

window.manabiGoToReaderPage = async (pageNumber) => {
    markRestorePositionSaveUserInput('bridge.goToReaderPage');
    globalThis.reader?.navHUD?.requestExplicitRelocateHistoryMutation?.('bridge.goToReaderPage');
    return await globalThis.reader?.goToPageNumber?.(pageNumber, 'window.manabiGoToReaderPage');
}

window.manabiScheduleReaderLocationGoTo = (locationNumber) => {
    markRestorePositionSaveUserInput('bridge.scheduleReaderLocationGoTo');
    globalThis.reader?.scheduleGoToPageNumber?.(locationNumber);
}

window.manabiGoToReaderLocation = async (locationNumber) => {
    markRestorePositionSaveUserInput('bridge.goToReaderLocation');
    globalThis.reader?.navHUD?.requestExplicitRelocateHistoryMutation?.('bridge.goToReaderLocation');
    return await globalThis.reader?.goToLocationNumber?.(locationNumber, 'window.manabiGoToReaderLocation');
}

window.manabiGoToReaderPercent = async (percent) => {
    markRestorePositionSaveUserInput('bridge.goToReaderPercent');
    globalThis.reader?.navHUD?.requestExplicitRelocateHistoryMutation?.('bridge.goToReaderPercent');
    return await globalThis.reader?.goToPercent?.(percent, 'window.manabiGoToReaderPercent');
}

window.manabiGoToReaderHref = async (href) => {
    markRestorePositionSaveUserInput('bridge.goToReaderHref');
    globalThis.reader?.navHUD?.requestExplicitRelocateHistoryMutation?.('bridge.goToReaderHref');
    return await globalThis.reader?.goToHref?.(href, 'window.manabiGoToReaderHref');
}

window.manabiScheduleReaderFractionGoTo = (fraction) => {
    const numericFraction = Number(fraction);
    if (shouldSkipScheduledReaderFractionGoToForRestoreSettling(numericFraction)) {
        return false;
    }
    const scheduled = globalThis.reader?.scheduleGoToFraction?.(fraction);
    if (scheduled !== false) {
        markRestorePositionSaveUserInput('bridge.scheduleReaderFractionGoTo');
    }
    return scheduled !== false;
}

window.manabiCancelScheduledReaderFractionGoTo = () => {
    globalThis.reader?.scheduleGoToFraction?.cancel?.();
    return true;
}

window.manabiBeginReaderProgressScrub = () => {
    markRestorePositionSaveUserInput('bridge.beginReaderProgressScrub');
    const navHUD = globalThis.reader?.navHUD;
    if (navHUD?.scrubSession?.active) {
        return true;
    }
    const originDescriptor = navHUD?.getCurrentLocationDescriptor?.() ?? null;
    navHUD?.beginProgressScrubSession?.(originDescriptor);
    return true;
}

window.manabiEndReaderProgressScrub = async (fraction, cancel = false) => {
    markRestorePositionSaveUserInput(cancel ? 'bridge.endReaderProgressScrub.cancel' : 'bridge.endReaderProgressScrub.commit');
    const navHUD = globalThis.reader?.navHUD;
    const view = globalThis.reader?.view;
    globalThis.reader?.scheduleGoToFraction?.cancel?.();
    const numericFraction = Number(fraction);
    const clampedFraction = Number.isFinite(numericFraction)
        ? Math.max(0, Math.min(1, numericFraction))
        : null;
    const finalDescriptor = clampedFraction != null
        ? (navHUD?._descriptorFromFraction?.(clampedFraction) ?? { fraction: clampedFraction })
        : (navHUD?.getCurrentLocationDescriptor?.() ?? null);
    const finalizeScrubSession = () => {
        navHUD?.endProgressScrubSession?.(finalDescriptor, {
            cancel: !!cancel,
            releaseFraction: clampedFraction,
        });
    };
    if (!cancel && Number.isFinite(clampedFraction) && view) {
        try {
            navHUD?.requestExplicitRelocateHistoryMutation?.('scrub-release');
            await runWithNavigationIntent({
                source: 'scrub-release',
                target: 'view.goToFraction',
                fraction: clampedFraction,
            }, () => view.goToFraction(clampedFraction));
            finalizeScrubSession();
        } catch (error) {
            finalizeScrubSession();
            console.error(error);
        }
    } else {
        finalizeScrubSession();
    }
    return true;
}

window.manabiTriggerReaderRelocateJump = async (direction) => {
    const navHUD = globalThis.reader?.navHUD;
    if (direction !== 'back' && direction !== 'forward') {
        return false;
    }
    await navHUD?._handleRelocateJump?.(direction);
    return true;
}

window.manabiScheduleReaderPercentGoTo = (percent) => {
    const numericPercent = Number(percent);
    if (!Number.isFinite(numericPercent)) {
        return false;
    }
    if (shouldSkipScheduledReaderFractionGoToForRestoreSettling(numericPercent / 100)) {
        return false;
    }
    const scheduled = globalThis.reader?.scheduleGoToFraction?.(numericPercent / 100);
    if (scheduled !== false) {
        markRestorePositionSaveUserInput('bridge.scheduleReaderPercentGoTo');
    }
    return scheduled !== false;
}

window.manabiOpenReaderGoToSheet = (source = 'window.manabiOpenReaderGoToSheet') => {
    postOpenReaderGoToSheetRequest(source, null);
}

window.nextSection = async () => {
    const btn = globalThis.reader?.buttons?.next;
    if (btn && btn.offsetParent !== null && getComputedStyle(btn).visibility !== 'hidden') {
        btn.click();
    } else {
        await globalThis.reader?.view?.renderer?.nextSection?.();
    }
}

window.manabi_markAllSectionsAsRead = async () => {
    return await globalThis.reader?.markAllSectionsAsRead?.() ?? 0;
}

window.manabi_buildMarkAllSectionsAsReadPayload = () => {
    return globalThis.reader?.buildMarkAllSectionsAsReadPayload?.() ?? null;
}

window.manabi_applyOptimisticMarkAllSectionsAsReadPayload = (payload) => {
    return globalThis.reader?.applyOptimisticMarkAllSectionsAsReadPayload?.(payload) ?? 0;
}

window.webkit.messageHandlers.ebookViewerInitialized.postMessage({})
