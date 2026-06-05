// Global timers for side-nav chevron fades
import './view.js'
import {
createTOCView
} from './ui/tree.js'
import { NavigationHUD } from './ebook-viewer-nav.js'
import {
    Overlayer
} from '../foliate-js/overlayer.js'

const manabiDiagnosticsEnabled = () => !!globalThis.manabi_debugDiagnosticsEnabled;
const manabiEPUBLoadVerboseLoggingEnabled = () => !!globalThis.manabi_epubLoadVerboseLoggingEnabled;
const MANABI_DISABLE_INITIAL_PAGINATOR_SETTLE = false;
const MANABI_DISABLE_NAV_HIDDEN_LAYOUT_CLASSES = false;
const MANABI_DISABLE_DYNAMIC_CHROME_INSETS = true;

const ignoredWindowErrorMessages = new Set([
    'ResizeObserver loop completed with undelivered notifications.',
]);

const shouldIgnoreWindowError = message => ignoredWindowErrorMessages.has(String(message ?? ''));

const postEarlyEPUBLoadLog = (event, details = {}) => {
};

window.onerror = function(msg, source, lineno, colno, error) {
    if (shouldIgnoreWindowError(msg)) return true;
    postEarlyEPUBLoadLog('js.window.onerror', {
        message: String(msg),
        source: String(source ?? ''),
        lineno: lineno ?? null,
        colno: colno ?? null,
        error: error?.stack ?? String(error)
    });
    window.webkit?.messageHandlers?.readerOnError?.postMessage?.({
        message: msg,
        source: source,
        lineno: lineno,
        colno: colno,
        error: String(error)
    });
};

window.onunhandledrejection = function(event) {
    postEarlyEPUBLoadLog('js.window.unhandledrejection', {
        message: event.reason?.message ?? "Unhandled rejection",
        source: window.location.href,
        error: event.reason?.stack ?? String(event.reason)
    });
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

const replaceTextPerfLogEvents = new Set([
    'end',
    'error',
    'cache-hit',
    'cache-wait-resolved',
    'live-first-section.recorded',
    'first-live-section.settled',
    'cache-warmer.schedule',
    'cache-warmer.finished',
    'cache-warmer.open.error',
]);

const shouldPostReplaceTextPerfLog = (event, details = {}) => {
    if (replaceTextPerfLogEvents.has(event)) return true;
    if (typeof details?.elapsedMs === 'number' && details.elapsedMs >= 1000) return true;
    if (typeof details?.networkElapsedMs === 'number' && details.networkElapsedMs >= 1000) return true;
    if (details?.responseOk === false || details?.status >= 400) return true;
    return false;
};

const postReplaceTextPerfLog = (event, details = {}) => {
};

const postBookRotateLog = (event, details = {}) => {
    void event;
    void details;
};

const postBookInsetLog = (event, details = {}) => {
    void event;
    void details;
};

const postPageTrackingBookLayoutLog = (event, details = {}) => {
    void event;
    void details;
};

const PAGE_NUM_DEDUP_EVENTS = new Set([
    'goto.snapshot',
    'nav.sections.handoff',
    'nav.visibility.updateNavButtons',
]);
const lastPageNumLogSignatureByEvent = new Map();

const postPageNumLog = (event, details = {}) => {
    void event;
    void details;
};

const MARKREAD_ALLOWED_EVENTS = new Set([
    'pageState.result',
    'markRead.skip',
    'markRead.click',
    'markRead.dispatch',
    'markRead.optimisticApplied',
    'progress.apply',
    'progress.optimisticCleared',
    'progress.mergeOptimistic',
    'position.save.dispatch',
    'restore.request',
    'restore.result',
    'restore.reconcile',
    'completion.ignored',
    'completion.click',
    'completion.finish.dispatch',
    'completion.finish.readState',
    'completion.restart.dispatch',
    'completion.restart.resetToFirstSection',
    'completion.unknown',
    'completion.idle',
    'relocate.timing',
    'pageState.sync.timing.start',
    'pageState.sync.timing.defer',
    'pageState.sync.timing.end',
    'pageTracking.retry.queue',
    'pageTracking.retry.fire',
    'pageTracking.render.beforeDOM',
    'pageTracking.render.afterDOM',
    'pageTracking.render.raf',
    'pageTracking.render.timing',
    'pageReadMarker.update',
    'pageTracking.clearStaleReadChrome',
    'visibleRange.collect.start',
    'visibleRange.collect.end',
    'visibleRange.collect.fallback',
    'visibleRange.collect.collapsedSkipped',
]);
const MARKREAD_DEDUP_EVENTS = new Set([
    'pageState.result',
    'progress.apply',
    'progress.mergeOptimistic',
    'position.save.dispatch',
    'restore.result',
]);
const lastMarkReadLogSignatureByEvent = new Map();

const compactMarkReadDetails = (event, details = {}) => {
    if (event !== 'pageState.result') {
        return details;
    }
    return {
        reason: details.reason ?? null,
        stateCount: details.stateCount ?? 0,
        visibleSegmentCount: details.visibleSegmentCount ?? 0,
        unreadVisibleSegmentCount: details.unreadVisibleSegmentCount ?? 0,
        selectedSegmentCount: details.selectedSegmentCount ?? 0,
        selectedSentenceCount: details.selectedSentenceCount ?? 0,
        readSegmentCount: details.readSegmentCount ?? 0,
        readSentenceCount: details.readSentenceCount ?? 0,
        recoveredTextSearchStringCount: details.recoveredTextSearchStringCount ?? 0,
        skippedMissingSearchStringCount: details.skippedMissingSearchStringCount ?? 0,
        segmentIdentifierSample: details.segmentIdentifierSample ?? [],
        sentenceIdentifierSample: details.sentenceIdentifierSample ?? [],
        usedFoliateRange: details.usedFoliateRange ?? false,
        documentURL: details.documentURL ?? null,
    };
};

const markReadLogSignatureDetails = (event, details = {}) => {
    if (event !== 'pageState.result') {
        return details;
    }
    const {
        reason: _reason,
        ...signatureDetails
    } = details;
    return signatureDetails;
};

const postMarkReadGoneLog = (event, details = {}) => {
    const payload = {
        event,
        timestamp: Date.now(),
        ...details,
    };
    const line = `# MARKREADGONE ${JSON.stringify(payload)}`;
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_error) {
        // optional native logger
    }
    try {
        console.log(line);
    } catch (_error) {
        // optional console logger
    }
};

const roundedDisplayPercent = value => {
    if (typeof value !== 'number' || !Number.isFinite(value)) {
        return null;
    }
    return Math.round(Math.max(0, Math.min(1, value)) * 100);
};

const postVisibleRangeLog = (event, details = {}) => {
    const payload = {
        event,
        timestamp: Date.now(),
        ...details,
    };
    const line = `# VISIBLERANGE ${JSON.stringify(payload)}`;
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_error) {
        // optional native logger
    }
    try {
        console.log(line);
    } catch (_error) {
        // optional console logger
    }
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

const MANABI_RESTORE_LOCATOR_PREFIX = 'mnb-loc-v1:';

const makeSyntheticRestoreLocator = ({ sectionIndex, localSectionIndex, rendererTotal }) => {
    if (![sectionIndex, localSectionIndex, rendererTotal].every((value) => Number.isFinite(value))) {
        return null;
    }
    const normalizedSectionIndex = Math.max(0, Math.round(sectionIndex));
    const normalizedRendererTotal = Math.max(1, Math.round(rendererTotal));
    const normalizedLocalSectionIndex = Math.max(
        0,
        Math.min(normalizedRendererTotal - 1, Math.round(localSectionIndex))
    );
    return `${MANABI_RESTORE_LOCATOR_PREFIX}${normalizedSectionIndex}:${normalizedLocalSectionIndex}:${normalizedRendererTotal}`;
};

const parseSyntheticRestoreLocator = (value) => {
    if (typeof value !== 'string' || !value.startsWith(MANABI_RESTORE_LOCATOR_PREFIX)) return null;
    const parts = value.slice(MANABI_RESTORE_LOCATOR_PREFIX.length).split(':');
    if (parts.length !== 3) return null;
    const [sectionIndexRaw, localSectionIndexRaw, rendererTotalRaw] = parts.map((part) => Number(part));
    if (![sectionIndexRaw, localSectionIndexRaw, rendererTotalRaw].every((value) => Number.isFinite(value))) {
        return null;
    }
    const sectionIndex = Math.max(0, Math.round(sectionIndexRaw));
    const rendererTotal = Math.max(1, Math.round(rendererTotalRaw));
    const localSectionIndex = Math.max(0, Math.min(rendererTotal - 1, Math.round(localSectionIndexRaw)));
    const fractionInSection = rendererTotal > 1 ? localSectionIndex / (rendererTotal - 1) : 0;
    return {
        sectionIndex,
        localSectionIndex,
        rendererTotal,
        fractionInSection,
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

const logMay15 = (event, detail = {}) => {
};

const may15Stack = () => {
    try {
        return String(new Error().stack || '')
            .split('\n')
            .slice(2, 9)
            .map(line => line.trim())
            .filter(Boolean);
    } catch (_err) {
        return [];
    }
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
        postReplaceTextPerfLog('cache-hit', {
            href,
            mediaType,
            isCacheWarmer: !!isCacheWarmer,
            cacheKey,
            sourceCacheKey: resultCacheKey,
            responseTextLength: typeof cachedHTML === 'string' ? cachedHTML.length : null,
            ...captureEPUBOverlapState(),
        });
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
        postReplaceTextPerfLog('cache-wait', {
            href,
            mediaType,
            isCacheWarmer: !!isCacheWarmer,
            cacheKey,
            sourceCacheKey: inFlightCacheKey,
            ...captureEPUBOverlapState(),
        });
        const sourceHTML = await replaceTextInFlightCache.get(inFlightCacheKey);
        const html = inFlightCacheKey === cacheKey
            ? sourceHTML
            : adaptReplaceTextHTMLForMode(sourceHTML, { href, isCacheWarmer: !!isCacheWarmer });
        postReplaceTextPerfLog('cache-wait-resolved', {
            href,
            mediaType,
            isCacheWarmer: !!isCacheWarmer,
            cacheKey,
            sourceCacheKey: inFlightCacheKey,
            waitElapsedMs: safeRound(performanceNowMs() - cacheWaitStartedAt, 1),
            responseTextLength: typeof html === 'string' ? html.length : null,
            ...captureEPUBOverlapState(),
        });
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
            postReplaceTextPerfLog('live-first-section.recorded', {
                href: normalizedHref,
                ...captureEPUBOverlapState(),
            });
        }
    }
    if (isCacheWarmer) {
        globalThis.__manabiInflightCacheWarmerReplaceTextCount = (globalThis.__manabiInflightCacheWarmerReplaceTextCount ?? 0) + 1;
    }
    postReplaceTextPerfLog('start', {
        href,
        mediaType,
        isCacheWarmer: !!isCacheWarmer,
        cacheKey,
        requestTextLength: typeof text === 'string' ? text.length : null,
        ...captureEPUBOverlapState(),
    });
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
        postReplaceTextPerfLog('response', {
            href,
            mediaType,
            isCacheWarmer: !!isCacheWarmer,
            cacheKey,
            status: response.status,
            responseOk: response.ok,
            headersElapsedMs: safeRound(performanceNowMs() - replaceTextStartedAt, 1),
            ...captureEPUBOverlapState(),
        });
        if (!response.ok) {
            throw new Error(`HTTP error, status = ${response.status}`)
        }
        const bodyReadStartedAt = performanceNowMs();
        let html = await response.text()
        const bodyReadElapsedMs = safeRound(performanceNowMs() - bodyReadStartedAt, 1);
        const responseTextLength = html.length;
        const transformStartedAt = performanceNowMs();
        postReaderLog('ebook.replaceText.responseSummary', {
            href,
            isCacheWarmer: !!isCacheWarmer,
            containsSegmentTag: html.includes('<mnb-seg'),
            containsSentenceTag: html.includes('<mnb-sen'),
            firstSegmentIndex: html.indexOf('<mnb-seg'),
            firstSentenceIndex: html.indexOf('<mnb-sen'),
        });
        const sentenceCount = (html.match(/<mnb-sen\b/g) || []).length;
        const segmentCount = (html.match(/<mnb-seg\b/g) || []).length;
        html = injectBodyDatasetAttributes(html, {
            'data-is-cache-warmer': isCacheWarmer ? 'true' : null,
            'data-mnb-source-href': href,
            'data-mnb-has-sentences': sentenceCount > 0 ? 'true' : null,
            'data-mnb-has-segments': segmentCount > 0 ? 'true' : null,
        });
        const transformElapsedMs = safeRound(performanceNowMs() - transformStartedAt, 1);
        logReplaceTextOnce(
            sentenceCount > 0 || segmentCount > 0
                ? 'ebook.replaceText.processed'
                : 'ebook.replaceText.processedEmpty',
            {
                href,
                mediaType,
                isCacheWarmer: !!isCacheWarmer,
                status: response.status,
                sentenceCount,
                segmentCount,
            },
        );
        postReplaceTextPerfLog('end', {
            href,
            mediaType,
            isCacheWarmer: !!isCacheWarmer,
            cacheKey,
            status: response.status,
            sentenceCount,
            segmentCount,
            requestTextLength: typeof text === 'string' ? text.length : null,
            responseTextLength: html.length,
            responseBodyReadMs: bodyReadElapsedMs,
            responseTransformMs: transformElapsedMs,
            networkElapsedMs: safeRound((performanceNowMs() - replaceTextStartedAt) - (bodyReadElapsedMs ?? 0) - (transformElapsedMs ?? 0), 1),
            elapsedMs: safeRound(performanceNowMs() - replaceTextStartedAt, 1),
            inputToOutputRatio: typeof text === 'string' && text.length > 0
                ? safeRound(html.length / text.length, 3)
                : null,
            ...captureEPUBOverlapState(),
        });
        if (!isCacheWarmer) {
            window.manabi_recordLiveProcessedSection?.(href);
        }
        if (!isCacheWarmer) {
        }
        rememberReplaceTextResult(cacheKey, html);
        return html
    } catch (error) {
        logReplaceTextOnce('ebook.replaceText.error', {
            href,
            mediaType: mediaType || 'nil',
            isCacheWarmer: !!isCacheWarmer,
            reason: error?.message || String(error),
        });
        postReplaceTextPerfLog('error', {
            href,
            mediaType,
            isCacheWarmer: !!isCacheWarmer,
            cacheKey,
            elapsedMs: safeRound(performanceNowMs() - replaceTextStartedAt, 1),
            message: error?.message || String(error),
            ...captureEPUBOverlapState(),
        });
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

const postReaderLog = (event, details = {}) => {
    if (!manabiDiagnosticsEnabled()) return;
    const payload = {
        prefix: '# READER',
        event,
    };
    for (const [key, value] of Object.entries(details)) {
        if (value === undefined || value === null) {
            continue;
        }
        payload[key] = value;
    }
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.(payload);
    } catch (error) {
        if (manabiDiagnosticsEnabled()) console.debug('# READER', event, details, error);
    }
};

const postLookupPositionLog = (event, details = {}) => {
    void event;
    void details;
};

const postEBookBugLog = (event, details = {}) => {
    void event;
    void details;
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
    postLookupPositionLog(event, payload);
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

const lastLayoutLogSignatureByEvent = new Map();

const collectEBookLayoutSnapshot = (view = globalThis.reader?.view ?? null, extra = {}) => {
    const renderer = view?.renderer ?? globalThis.reader?.view?.renderer ?? null;
    const shadowRoot = renderer?.shadowRoot ?? null;
    const container = shadowRoot?.getElementById?.('container') ?? shadowRoot?.querySelector?.('#container') ?? null;
    const top = shadowRoot?.getElementById?.('top') ?? shadowRoot?.querySelector?.('#top') ?? null;
    const header = shadowRoot?.getElementById?.('header') ?? shadowRoot?.querySelector?.('#header') ?? null;
    const footer = shadowRoot?.getElementById?.('footer') ?? shadowRoot?.querySelector?.('#footer') ?? null;
    const readerDoc = renderer?.view?.document ?? renderer?.view?.doc ?? null;
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

const layoutLogSignature = details => JSON.stringify({
    reason: details.reason ?? null,
    fraction: details.fraction ?? null,
    currentLocation: details.currentLocation ?? null,
    totalLocation: details.totalLocation ?? null,
    sectionIndex: details.sectionIndex ?? null,
    localSectionIndex: details.localSectionIndex ?? null,
    rendererTotal: details.rendererTotal ?? null,
    rendererFlow: details.rendererFlow ?? null,
    rendererDir: details.rendererDir ?? null,
    rendererLocalName: details.rendererLocalName ?? null,
    windowInnerWidth: details.windowInnerWidth ?? null,
    windowInnerHeight: details.windowInnerHeight ?? null,
    visualViewportHeight: details.visualViewportHeight ?? null,
    visualViewportOffsetTop: details.visualViewportOffsetTop ?? null,
    containerScrollLeft: details.containerSnapshot?.scrollLeft ?? null,
    containerScrollTop: details.containerSnapshot?.scrollTop ?? null,
    containerScrollWidth: details.containerSnapshot?.scrollWidth ?? null,
    containerScrollHeight: details.containerSnapshot?.scrollHeight ?? null,
    readerBodyScrollWidth: details.readerBodyScrollWidth ?? null,
    readerBodyScrollHeight: details.readerBodyScrollHeight ?? null,
});

const postLayoutLog = (event, details = {}) => {
    void event;
    void details;
};

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

const scheduleLoadNextCacheWarmerSection = (settledSectionHrefs = [], reason = 'unspecified') => {
    if (typeof window.cacheWarmer?.loadNextSectionSkippingSettled !== 'function') {
        return;
    }
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
    if (busyState.busy) {
        clearTimeout(globalThis.__manabiCacheWarmerLoadNextTimer);
        globalThis.__manabiCacheWarmerLoadNextTimer = setTimeout(() => {
            globalThis.__manabiCacheWarmerLoadNextTimer = null;
            scheduleLoadNextCacheWarmerSection(settledSectionHrefs, `${reason}.retry`);
        }, busyState.retryMs);
        return;
    }
    const now = performanceNowMs();
    const lastAdvanceStartedAt = Number(globalThis.__manabiCacheWarmerLastAdvanceStartedAtMs || 0);
    const spacingRemainingMs = Math.max(0, lastAdvanceStartedAt + CACHE_WARMER_ADVANCE_SPACING_MS - now);
    if (spacingRemainingMs > 0) {
        clearTimeout(globalThis.__manabiCacheWarmerLoadNextTimer);
        globalThis.__manabiCacheWarmerLoadNextTimer = setTimeout(() => {
            globalThis.__manabiCacheWarmerLoadNextTimer = null;
            scheduleLoadNextCacheWarmerSection(settledSectionHrefs, `${reason}.spacing`);
        }, spacingRemainingMs);
        return;
    }
    const activeIndex = activeForegroundSectionIndex();
    const targetIndex = window.cacheWarmer?.nextUnsettledSectionIndexSkippingSettled?.(settledSectionHrefs, activeIndex);
    const windowLimitState = cacheWarmerWindowLimitState(targetIndex);
    if (!windowLimitState.isWithinWindow) {
        return;
    }
    globalThis.__manabiCacheWarmerLastAdvanceStartedAtMs = performanceNowMs();
    window.cacheWarmer?.loadNextSectionSkippingSettled?.(settledSectionHrefs, activeIndex)
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

const postReaderBridgeDebug = (message, details = {}) => {
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.({
            message,
            ...details,
        });
    } catch (_error) {}
};

const postEbookNavigationVisibilityToNative = (shouldHide, source, details = {}) => {
    const requestedHide = !!shouldHide;
    postReaderBridgeDebug('# HIDENAV js.ebookNavigationVisibility.post', {
        requestedHide,
        source,
        navHUDHidden: globalThis.reader?.navHUD?.hideNavigationDueToScroll ?? null,
        bodyDatasetHidden: document?.body?.dataset?.mnbNavigationHiddenDueToScroll ?? null,
        bodyClassHidden: document?.body?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null,
        ...details,
    });
    try {
        window.webkit?.messageHandlers?.ebookNavigationVisibility?.postMessage?.({
            hideNavigationDueToScroll: requestedHide,
            source,
            ...details,
        });
        postReaderBridgeDebug('# HIDENAV js.ebookNavigationVisibility.sent', {
            requestedHide,
            source,
        });
        return true;
    } catch (error) {
        postReaderBridgeDebug('# HIDENAV js.ebookNavigationVisibility.error', {
            requestedHide,
            source,
            error: error?.message || String(error),
        });
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
    body.classList.toggle('nav-hidden', hidden);
    body.classList.toggle('nav-hidden-due-to-scroll', hidden);
    body.dataset.mnbNavigationHiddenDueToScroll = hidden ? 'true' : 'false';
    return {
        applied: true,
        hidden,
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

const copyCustomReaderFontStyleToDocument = (sourceFontStyle, doc, reason = 'unknown') => {
    if (!doc || doc === document) return false;
    if (!sourceFontStyle) {
        return false;
    }
    let targetFontStyle = doc.getElementById('mnb-custom-fonts-inline');
    const sourceTag = sourceFontStyle.tagName?.toLowerCase();
    const desiredTag = sourceTag === 'link' ? 'link' : 'style';
    if (targetFontStyle && targetFontStyle.tagName?.toLowerCase() !== desiredTag) {
        targetFontStyle.remove();
        targetFontStyle = null;
    }
    if (!targetFontStyle) {
        targetFontStyle = doc.createElement(desiredTag);
        targetFontStyle.id = 'mnb-custom-fonts-inline';
        (doc.head || doc.documentElement).appendChild(targetFontStyle);
    }
    if (desiredTag === 'link') {
        targetFontStyle.rel = sourceFontStyle.rel || 'stylesheet';
        targetFontStyle.href = sourceFontStyle.href;
    } else {
        targetFontStyle.textContent = sourceFontStyle.textContent || '';
    }
    for (const [key, value] of Object.entries(sourceFontStyle.dataset || {})) {
        targetFontStyle.dataset[key] = value;
    }
    if (doc.documentElement && sourceFontStyle.dataset?.mnbInjectedFontFamily) {
        doc.documentElement.dataset.mnbInjectedFontFamily = sourceFontStyle.dataset.mnbInjectedFontFamily;
        doc.documentElement.dataset.mnbFontInjected = '1';
    }
    return true;
};

window.manabiForwardReaderFontToEbookDocuments = (reason = 'manual', explicitDoc = null) => {
    const docs = getLoadedEbookDocuments(explicitDoc);
    const sourceFontStyle = document.getElementById('mnb-custom-fonts-inline')
        || docs.map((doc) => doc?.getElementById?.('mnb-custom-fonts-inline')).find(Boolean)
        || null;
    let forwardedCount = 0;
    for (const doc of docs) {
        if (copyCustomReaderFontStyleToDocument(sourceFontStyle, doc, reason)) {
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
        postReplaceTextPerfLog('live-section.processed', {
            href: normalizedHref,
            processedSectionCount: processedSet.size,
            isFirstLiveSection: normalizedHref === firstLiveHref,
            ...captureEPUBOverlapState(),
        });
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
        postReplaceTextPerfLog('live-section.settled', {
            href: normalizedHref,
            settledSectionCount: settledSet.size,
            processedSectionCount: liveProcessedSectionHrefSet().size,
            isFirstLiveSection: normalizedHref === firstLiveHref,
            ...captureEPUBOverlapState(),
        });
        scheduleLoadNextCacheWarmerSection(Array.from(settledSet).sort(), 'live-section.settled');
    }
    if (normalizedHref === firstLiveHref) {
        postReplaceTextPerfLog('first-live-section.settled', {
            href: normalizedHref,
            settledSectionCount: settledSet.size,
            processedSectionCount: liveProcessedSectionHrefSet().size,
            ...captureEPUBOverlapState(),
        });
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
    postReplaceTextPerfLog('live-sections.synced', {
        firstLiveHref: nextFirstLiveHref,
        processedSectionCount: nextSettledSectionHrefs.length,
        processedSectionHrefs: nextSettledSectionHrefs,
        ...captureEPUBOverlapState(),
    });
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
            postReplaceTextPerfLog('cache-warmer.deferred', {
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                firstLiveHref: firstLiveHref ?? null,
                firstLiveSettled,
                processedSectionCount: liveProcessedSectionHrefSet().size,
                settledSectionCount: liveSettledSectionHrefSet().size,
                ...captureEPUBOverlapState(),
            });
        }
        return;
    }
    const preflightScan = cacheWarmerSectionScan();
    const nextUsefulIndex = preflightScan.targetIndex;
    if (shouldDeferInitialCacheWarmerTarget(preflightScan)) {
        postReplaceTextPerfLog('cache-warmer.deferred', {
            reason: 'initial-foreground-next-section',
            firstLiveHref: firstLiveSectionHref(),
            expectedForegroundSectionIndex: nextUsefulIndex,
            expectedForegroundSectionHref: preflightScan.targetHref,
            processedSectionCount: liveProcessedSectionHrefSet().size,
            settledSectionCount: liveSettledSectionHrefSet().size,
            ...captureEPUBOverlapState(),
        });
        return;
    }
    postReplaceTextPerfLog('cache-warmer.preflight.scan', {
        firstLiveHref: firstLiveSectionHref(),
        processedSectionCount: liveProcessedSectionHrefSet().size,
        processedSectionHrefs: Array.from(liveProcessedSectionHrefSet()).sort(),
        settledSectionCount: liveSettledSectionHrefSet().size,
        settledSectionHrefs: Array.from(liveSettledSectionHrefSet()).sort(),
        targetSectionIndex: preflightScan.targetIndex,
        targetSectionHref: preflightScan.targetHref,
        startIndex: preflightScan.startIndex,
        activeForegroundHref: preflightScan.activeForegroundHref,
        sectionCount: preflightScan.sectionCount,
        sectionSample: preflightScan.sample,
        ...captureEPUBOverlapState(),
    });
    if (!Number.isInteger(nextUsefulIndex)) {
        globalThis.__manabiCacheWarmerOpenRequested = false;
        globalThis.__manabiCacheWarmerFinished = true;
        globalThis.__manabiCacheWarmerReady = true;
        postReplaceTextPerfLog('cache-warmer.finished', {
            trigger: 'preflight-no-unsettled',
            sectionURL: null,
            sectionIndex: null,
            highestSectionIndex: globalThis.__manabiCacheWarmerHighestSectionIndex ?? null,
            uniqueSentenceCount: 0,
            firstLiveHref: firstLiveSectionHref(),
            processedSectionCount: liveProcessedSectionHrefSet().size,
            settledSectionCount: liveSettledSectionHrefSet().size,
            ...captureEPUBOverlapState(),
        });
        return;
    }
    const cacheWarmerSource = cacheWarmerSourceForCurrentBook();
    globalThis.__manabiCacheWarmerOpenRequested = false;
    postReplaceTextPerfLog('cache-warmer.unblocked', {
        firstLiveHref: firstLiveSectionHref(),
        targetSectionIndex: nextUsefulIndex,
        processedSectionCount: liveProcessedSectionHrefSet().size,
        settledSectionCount: liveSettledSectionHrefSet().size,
        sourceKind: cacheWarmerSource?.kind || 'nil',
        ...captureEPUBOverlapState(),
    });
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
    postReplaceTextPerfLog('cache-warmer.schedule', {
        reason,
        delayMs,
        initialForegroundNextSectionPending: !!globalThis.__manabiInitialForegroundNextSectionPending,
        ...captureEPUBOverlapState(),
    });
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
    const contentSectionEntries = sectionEntries.filter((entry) => !isLikelyMetadataSectionHref(entry?.href));
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
    logMay15('ebook.navBridge.setNative.entered', {
        sequence,
        source,
        requestedHide: normalized,
        before,
        stack: may15Stack(),
    });
    if (body?.classList?.contains?.('nav-hidden')) {
        body.classList.remove('nav-hidden');
    }
    globalThis.reader?.navHUD?.setHideNavigationDueToScroll?.(normalized, source, {
        bridgeSource: source,
        bodyClassApplied: false,
    });
    const afterSetHide = captureNavVisibilityState();
    logMay15('ebook.navBridge.setNative.afterHUD', {
        sequence,
        source,
        requestedHide: normalized,
        beforeHudHideNavigationDueToScroll: before.hudHideNavigationDueToScroll ?? null,
        afterHudHideNavigationDueToScroll: afterSetHide.hudHideNavigationDueToScroll ?? null,
        afterNavHiddenScrollClass: afterSetHide.navHiddenScrollClass ?? null,
        afterBodyNavHiddenClass: afterSetHide.bodyNavHiddenClass ?? null,
    });
    const bridgeState = {
        sequence,
        source,
        shouldHide: normalized,
        beforeHudHideNavigationDueToScroll: before.hudHideNavigationDueToScroll ?? null,
        beforeLabelVariant: before.labelVariant ?? null,
        ...captureNavVisibilityState(),
    };
    postReaderLog('ebook.navigationVisibility.bridge', bridgeState);
    postPageNumLog('nav.visibility.bridge', {
        sequence,
        source,
        shouldHide: normalized,
        before,
        after: captureNavVisibilityState(),
    });
    logMay15('ebook.navBridge.setNative.finished', {
        sequence,
        source,
        requestedHide: normalized,
    });
    return normalized;
};

window.manabiSetHideNavigationDueToScroll = (shouldHide, source = 'window.manabiSetHideNavigationDueToScroll') => {
    const requestedHide = !!shouldHide;
    logMay15('ebook.navBridge.windowRequest', {
        source,
        requestedHide,
        currentState: captureNavVisibilityState(),
        stack: may15Stack(),
    });
    if (requestedHide) {
        const ignoreCount = Number(globalThis.__manabiIgnoreNextIncomingHideNavigationCount || 0);
        if (ignoreCount > 0) {
            globalThis.__manabiIgnoreNextIncomingHideNavigationCount = ignoreCount - 1;
            logMay15('ebook.navBridge.windowReturn', {
                source,
                requestedHide,
                verdict: 'ignoredHideCount',
                remainingHideIgnoreCount: globalThis.__manabiIgnoreNextIncomingHideNavigationCount,
            });
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
            logMay15('ebook.navBridge.windowReturn', {
                source,
                requestedHide,
                verdict: 'staleSwiftRevealAfterForwardPageTurn',
                now,
                lastForwardPageTurnHideAtMs,
                lastBackwardPageTurnRevealAtMs,
            });
            return true;
        }
        if (globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay === true) {
            logMay15('ebook.navBridge.windowReturn', {
                source,
                requestedHide,
                verdict: 'preserveHiddenThroughNextDisplay',
            });
            return true;
        }
        const ignoreCount = Number(globalThis.__manabiIgnoreNextIncomingRevealNavigationCount || 0);
        if (ignoreCount > 0) {
            globalThis.__manabiIgnoreNextIncomingRevealNavigationCount = ignoreCount - 1;
            logMay15('ebook.navBridge.windowReturn', {
                source,
                requestedHide,
                verdict: 'ignoredRevealCount',
                remainingRevealIgnoreCount: globalThis.__manabiIgnoreNextIncomingRevealNavigationCount,
            });
            return true;
        }
    }
    const result = setNativeHideNavigationState(requestedHide, source);
    logMay15('ebook.navBridge.windowReturn', {
        source,
        requestedHide,
        verdict: 'applied',
        result,
    });
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
            window.webkit?.messageHandlers?.print?.postMessage?.('# LANDSCAPEINSET ' + JSON.stringify(payload));
        }
    } catch {}
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
        try {
            window.webkit?.messageHandlers?.print?.postMessage?.('# LANDSCAPEINSET ' + JSON.stringify({
                stage: 'ebookChromeInsets.appliedChanged',
                reason,
                incomingObscuredTopInset: incomingState?.obscuredTopInset ?? null,
                appliedObscuredTopInset: nextState.obscuredTopInset,
                appliedToolbarBottomOffset: nextState.toolbarBottomOffset,
                appliedObscuredBottomInset: nextState.obscuredBottomInset,
                source: nextState.source,
                revision: nextState.revision,
                inheritedAncestorSource: shouldInheritPositiveAncestorState ? ancestorPositiveState?.source ?? null : null,
                layout: captureLandscapeInsetLayoutProbe(),
            }));
        } catch {}
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
    return applyStoredChromeInsets(reason, rawState);
};

document.addEventListener('DOMContentLoaded', () => {
    applyStoredChromeInsets('dom-content-loaded');
});

window.addEventListener('load', () => {
    applyStoredChromeInsets('window-load');
});

const replaceTextLogKeys = new Set();
const logReplaceTextOnce = (event, details = {}) => {
    const key = JSON.stringify({
        event,
        href: details.href || 'nil',
        isCacheWarmer: !!details.isCacheWarmer,
        mediaType: details.mediaType || 'nil',
        status: details.status || 'nil',
        reason: details.reason || 'nil',
    });
    if (replaceTextLogKeys.has(key)) {
        return;
    }
    replaceTextLogKeys.add(key);
    postReaderLog(event, details);
};

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
const segmentMetadataBootstrap = (doc) => {
    if (!doc) {
        return { byID: new Map(), idsByEntryID: new Map() };
    }
    const primarySidecar = typeof doc.getElementById === 'function'
        ? doc.getElementById('mnb-segment-metadata')
        : null;
    const sidecars = primarySidecar
        ? [primarySidecar]
        : Array.from(doc.getElementsByTagName?.('script') || [])
            .filter((script) => script?.hasAttribute?.('data-mnb-seg-meta'));
    const sidecarSignature = sidecars
        .map((sidecar) => String((sidecar.textContent || '').length))
        .join('|');
    if (doc.manabiSegmentMetadataByID && doc.manabiSegmentMetadataSidecarSignature === sidecarSignature) {
        return {
            byID: doc.manabiSegmentMetadataByID,
            idsByEntryID: doc.manabiSegmentIDsByEntryID || new Map(),
        };
    }
    const byID = new Map();
    const idsByEntryID = new Map();
    const tableValue = (table, index, fallback = null) => (
        Number.isInteger(index) && Array.isArray(table) && index >= 0 && index < table.length
            ? table[index]
            : fallback
    );
    const expandSegmentIDToken = (token, version) => {
        if (typeof token !== 'string' || token.length === 0) return null;
        if (version === 3) return token.startsWith('!') ? token.slice(1) : `mnb-s${token}`;
        return token;
    };
    const expandSegmentMetadataPayload = (payload) => {
        const version = payload?.v ?? payload?.version;
        if ((version === 2 || version === 3) && payload?.t && Array.isArray(payload.s)) {
            const tables = payload.t;
            return payload.s.map((segment) => ({
                i: expandSegmentIDToken(segment?.[0], version), // segment element ID
                sid: version === 3 ? tableValue(tables.h, segment?.[1], null) : segment?.[1], // stable selection ID when available
                j: tableValue(tables.j, segment?.[2], []), // JMDict entry IDs from table index
                n: tableValue(tables.n, segment?.[3], []), // JMNEDict entry IDs from table index
                s: tableValue(tables.s, segment?.[4], null), // JMDict lookup string from table index
                ns: tableValue(tables.ns, segment?.[5], null), // JMNEDict lookup string from table index
                p: tableValue(tables.p, segment?.[6], null), // part-of-speech from table index
                l: segment?.[7], // JLPT level, 1..5
            }));
        }
        return [];
    };
    const indexEntryIDs = (segmentID, entryIDs) => {
        for (const entryID of entryIDs || []) {
            if (typeof entryID !== 'number' || !Number.isFinite(entryID)) continue;
            const key = String(entryID);
            if (!idsByEntryID.has(key)) idsByEntryID.set(key, new Set());
            idsByEntryID.get(key).add(segmentID);
        }
    };
    for (const sidecar of sidecars) {
        try {
            const payload = JSON.parse(sidecar.textContent || '{}');
            for (const segment of expandSegmentMetadataPayload(payload)) {
                if (!segment?.i) continue;
                byID.set(segment.i, segment);
                indexEntryIDs(segment.i, segment.j);
                indexEntryIDs(segment.i, segment.n);
            }
        } catch (_error) {}
    }
    doc.manabiSegmentMetadataByID = byID;
    doc.manabiSegmentIDsByEntryID = idsByEntryID;
    doc.manabiSegmentMetadataSidecarSignature = sidecarSignature;
    return { byID, idsByEntryID };
};

const segmentMetadataForNode = (segmentNode) => {
    if (!segmentNode) return null;
    const doc = segmentNode.ownerDocument || document;
    return segmentMetadataBootstrap(doc).byID.get(segmentNode.id) || null;
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
    const sentenceIdentifier = sentenceNode?.getAttribute?.('sid') || sentenceNode?.getAttribute?.('h');
    return typeof sentenceIdentifier === 'string' && sentenceIdentifier.length > 0
        ? sentenceIdentifier
        : null;
};

const segmentIdentifierForNode = (segmentNode) => {
    const metadata = segmentMetadataForNode(segmentNode);
    if (metadata?.sid) {
        return metadata.sid;
    }
    return segmentNode?.id || null;
};

const segmentIdentifierAliasesForNode = (segmentNode) => {
    const metadata = segmentMetadataForNode(segmentNode);
    const aliases = [];
    const addAlias = (identifier) => {
        if (typeof identifier !== 'string' || identifier.length === 0) return;
        if (!aliases.includes(identifier)) aliases.push(identifier);
    };
    addAlias(metadata?.sid);
    const sentenceIdentifier = sentenceIdentifierForNode(segmentNode?.closest?.('mnb-sen'));
    if (sentenceIdentifier && typeof metadata?.sid === 'string' && !metadata.sid.includes('-')) {
        addAlias(`${sentenceIdentifier}-${metadata.sid}`);
    }
    addAlias(metadata?.i);
    addAlias(segmentNode?.id);
    return aliases;
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

const measureVisibleSegmentsInWindow = (segmentNodes, visibleRange, visibleBounds) => {
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
        const segmentIdentifier = segmentIdentifierForNode(segmentNode);
        if (!segmentIdentifier) {
            missingIdentifierCount += 1;
            continue;
        }
        const rectStartedAt = performance.now();
        const rects = visibleClientRectsForNode(segmentNode, visibleBounds);
        const rect = rects[0] ?? null;
        rectMeasureCount += 1;
        rectMeasureElapsedMs += performance.now() - rectStartedAt;
        const rangeStartedAt = performance.now();
        let isInVisibleRange = false;
        try {
            visibleRangeCheckCount += 1;
            isInVisibleRange = visibleRange.intersectsNode(segmentNode);
            rangeCheckElapsedMs += performance.now() - rangeStartedAt;
        } catch (_error) {
            visibleRangeErrorCount += 1;
            rangeCheckElapsedMs += performance.now() - rangeStartedAt;
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
            segmentIdentifierAliases: segmentIdentifierAliasesForNode(segmentNode),
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

const collectExpandedRangeSegments = (doc, visibleRange, visibleBounds) => {
    if (!visibleRange || visibleRange.collapsed === true) {
        return null;
    }
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
        const measured = measureVisibleSegmentsInWindow(segmentNodes, visibleRange, visibleBounds);
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

const collectVisibleSegmentNodesFromRange = (doc, visibleRange = null) => {
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
        postVisibleRangeLog('collect.collapsedViewportFallback', {
            documentURL: doc.URL || doc.location?.href || null,
            reason: 'collapsed-range-viewport-fallback',
            rangeStartNode: describeMarkReadNode(visibleRange?.startContainer ?? null),
            rangeEndNode: describeMarkReadNode(visibleRange?.endContainer ?? null),
            viewportWidth,
            viewportHeight,
            visibleLeft: safeRound(visibleBounds.left, 1),
            visibleRight: safeRound(visibleBounds.right, 1),
        });
    }
    const rangeCommonAncestor = visibleRange?.commonAncestorContainer ?? null;
    const rangeCommonAncestorElement = rangeCommonAncestor?.nodeType === Node.ELEMENT_NODE
        ? rangeCommonAncestor
        : (rangeCommonAncestor?.parentElement || null);
    const expandedRangeResult = useVisibleRange
        ? collectExpandedRangeSegments(doc, visibleRange, visibleBounds)
        : null;
    const boundedSegmentNodes = expandedRangeResult?.segmentNodes ?? null;
    const segmentSearchRoot = useVisibleRange && !expandedRangeResult && rangeCommonAncestorElement?.querySelectorAll
        ? rangeCommonAncestorElement
        : doc;
    const allSegmentNodes = boundedSegmentNodes || [
            ...(segmentSearchRoot.matches?.('mnb-seg') ? [segmentSearchRoot] : []),
            ...Array.from(segmentSearchRoot.querySelectorAll?.('mnb-seg') ?? []),
        ];
    const queryCompletedAt = performance.now();
    const ancestorSegmentCandidateCount = segmentSearchRoot === rangeCommonAncestorElement
        ? allSegmentNodes.length
        : null;
    const segmentCandidateSource = expandedRangeResult?.segmentCandidateSource
        || (segmentSearchRoot === doc ? 'document' : 'range-ancestor');
    postVisibleRangeLog('collect.start', {
        documentURL: doc.URL || doc.location?.href || null,
        hasVisibleRange: !!visibleRange,
        usingVisibleRange: useVisibleRange,
        rangeCollapsed: typeof visibleRange?.collapsed === 'boolean' ? visibleRange.collapsed : null,
        segmentCandidateCount: allSegmentNodes.length,
        segmentCandidateSource,
        ancestorSegmentCandidateCount,
        viewportWidth,
        viewportHeight,
        rangeStartContainer: visibleRange?.startContainer?.nodeName || null,
        rangeEndContainer: visibleRange?.endContainer?.nodeName || null,
        rangeCommonAncestor: describeMarkReadNode(rangeCommonAncestor),
        boundedSegmentCount: boundedSegmentNodes?.length ?? null,
        orderedSegmentCount: expandedRangeResult?.orderedSegmentCount ?? null,
        rangeWindowExpansionSize: expandedRangeResult?.expansionSize ?? null,
        rangeWindowBounded: expandedRangeResult?.boundedByWindow ?? null,
    });
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
        const segmentIdentifier = segmentIdentifierForNode(segmentNode);
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
            segmentIdentifierAliases: segmentIdentifierAliasesForNode(segmentNode),
            sentenceIdentifier: sentenceIdentifierForNode(sentenceNode),
        });
    }
    if (useVisibleRange && visibleSegments.length === 0 && totalSegmentCount > 0) {
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
        postVisibleRangeLog('collect.fallback', {
            documentURL: doc.URL || doc.location?.href || null,
            reason: 'range-empty',
            fallbackVisibleSegmentCount: fallbackSegments.length,
            fallbackOutOfViewportCount,
            fallbackElapsedMs: safeRound(performance.now() - fallbackStartedAt, 2),
            rangeCollapsed: typeof visibleRange?.collapsed === 'boolean' ? visibleRange.collapsed : null,
        });
        if (fallbackSegments.length > 0) {
            visibleSegments.push(...fallbackSegments);
            hiddenTooltipCount = fallbackHiddenTooltipCount;
            missingIdentifierCount = fallbackMissingIdentifierCount;
            outOfViewportCount = fallbackOutOfViewportCount;
        }
    }
    if (visibleRange?.collapsed === true) {
        postVisibleRangeLog('collect.collapsedSkipped', {
            documentURL: doc.URL || doc.location?.href || null,
            reason: 'collapsed-range-viewport-fallback',
            segmentCandidateCount: allSegmentNodes.length,
            fallbackVisibleSegmentCount: visibleSegments.length,
            rangeStartNode: describeMarkReadNode(visibleRange?.startContainer ?? null),
            rangeEndNode: describeMarkReadNode(visibleRange?.endContainer ?? null),
        });
    }
    const completedAt = performance.now();
    postVisibleRangeLog('collect.end', {
        documentURL: doc.URL || doc.location?.href || null,
        hasVisibleRange: !!visibleRange,
        usingVisibleRange: useVisibleRange,
        rangeCollapsed: typeof visibleRange?.collapsed === 'boolean' ? visibleRange.collapsed : null,
        segmentCandidateCount: allSegmentNodes.length,
        visibleSegmentCount: visibleSegments.length,
        outOfViewportCount,
        visibleRangeCheckCount,
        visibleRangeErrorCount,
        rectMeasureCount,
        rectMeasureElapsedMs: safeRound(rectMeasureElapsedMs, 2),
        rangeCheckElapsedMs: safeRound(rangeCheckElapsedMs, 2),
        totalElapsedMs: safeRound(completedAt - startedAt, 2),
    });
    return {
        visibleSegments,
        viewportWidth,
        viewportHeight,
        viewportLeft,
        viewportTop,
        frameLeft: Number.isFinite(frameRect?.left) ? frameRect.left : 0,
        frameTop: Number.isFinite(frameRect?.top) ? frameRect.top : 0,
        totalSegmentCount,
        hiddenTooltipCount,
        missingIdentifierCount,
        outOfViewportCount,
    };
};

const postNativeLookupHitTargetsForVisibleSegments = (doc, visibleSegmentsResult, reason = 'unspecified') => {
    const view = doc?.defaultView ?? null;
    const builder = view?.manabi_nativeLookupHitTargetForSegment ?? null;
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
    const messageHandlers = view?.webkit?.messageHandlers ?? window.webkit?.messageHandlers ?? null;
    const frameElement = view?.frameElement ?? null;
    const frameRect = frameElement?.getBoundingClientRect?.() ?? null;
    if (globalThis.manabiVerboseLookupPositionTargets === true) {
        postLookupPositionLog('ebook.nativeTargets.collect.begin', {
            reason,
            hasBuilder: typeof builder === 'function',
            docURL: doc?.location?.href ?? null,
            topURL: window.location?.href ?? null,
            visibleSegmentCount: visibleSegmentsResult?.visibleSegments?.length ?? 0,
            totalSegmentCount: visibleSegmentsResult?.totalSegmentCount ?? null,
            viewportWidth,
            viewportHeight,
            viewportLeft,
            viewportTop,
            resultFrameLeft: visibleSegmentsResult?.frameLeft ?? null,
            resultFrameTop: visibleSegmentsResult?.frameTop ?? null,
            frameRect: lookupPositionRectSnapshot(frameRect),
            visualViewportScale: Number.isFinite(window.visualViewport?.scale) ? window.visualViewport.scale : 1,
            visualViewportOffsetLeft: Number.isFinite(window.visualViewport?.offsetLeft) ? window.visualViewport.offsetLeft : null,
            visualViewportOffsetTop: Number.isFinite(window.visualViewport?.offsetTop) ? window.visualViewport.offsetTop : null,
        });
    }
    if (typeof builder !== 'function') {
        messageHandlers?.nativeLookupHitTargetsUpdated?.postMessage?.({
            targets: [],
            reason,
            isExplicitReset: false,
            visualViewportScale: Number.isFinite(window.visualViewport?.scale) ? window.visualViewport.scale : 1,
            viewportWidth,
            viewportHeight,
            viewportLeft,
            viewportTop,
        });
        return;
    }
    view?.manabi_resetNativeLookupHitTargets?.();
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
        })));
        if (target) {
            targets.push(target);
        }
    }
    if (globalThis.manabiVerboseLookupPositionTargets === true) {
        postLookupPositionLog('ebook.nativeTargets.collect.end', {
            reason,
            targetCount: targets.length,
            frameLeft,
            frameTop,
            viewportWidth,
            viewportHeight,
            viewportLeft,
            viewportTop,
            firstTargetElementId: targets[0]?.elementId ?? null,
            firstTargetRectCount: targets[0]?.rects?.length ?? null,
            firstTargetRects: targets[0]?.rects?.slice?.(0, 4)?.map?.(lookupPositionRectSnapshot) ?? null,
        });
    }
    messageHandlers?.nativeLookupHitTargetsUpdated?.postMessage?.({
        targets,
        reason,
        isExplicitReset: false,
        visualViewportScale: Number.isFinite(window.visualViewport?.scale) ? window.visualViewport.scale : 1,
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
        if (item?.sentenceIdentifier && readSentenceIdentifiers.has(item.sentenceIdentifier)) {
            return true;
        }
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

const isZip = async file => {
    const arr = new Uint8Array(await file.slice(0, 4).arrayBuffer())
    return arr[0] === 0x50 && arr[1] === 0x4b && arr[2] === 0x03 && arr[3] === 0x04
}

const makeNativeSource = url => ({ kind: 'native', url })
const makeFileSource = file => ({ kind: 'file', file })

const makeNativeSourceURLQuery = sourceURL =>
    `sourceURL=${encodeURIComponent(sourceURL)}`

const fetchNativeEntries = async sourceURL => {
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
    const entries = rawEntries.map(entry => ({
        filename: entry.path,
        uncompressedSize: entry.size ?? 0,
    }))
    const sizeMap = new Map(entries.map(entry => [entry.filename, entry.uncompressedSize]))
    const entryNames = new Set(entries.map(entry => entry.filename))
    const replaceText = makeReplaceText(isCacheWarmer)
    return {
        entries,
        loadText: async name => {
            if (!entryNames.has(name)) {
                return null
            }
            const response = await fetchNativeEntryResponse(url, name)
            return readNativeEntryText(response)
        },
        loadBlob: async name => {
            if (!entryNames.has(name)) {
                return null
            }
            const response = await fetchNativeEntryResponse(url, name)
            return readNativeEntryBlob(response)
        },
        getSize: name => sizeMap.get(name) ?? 0,
        replaceText,
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
    const map = new Map(entries.map(entry => [entry.filename, entry]))
    const load = f => (name, ...args) =>
    map.has(name) ? f(map.get(name), ...args) : null
    const loadText = load(entry => entry.getData(new TextWriter()))
    const loadBlob = load((entry, type) => entry.getData(new BlobWriter(type)))
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

const getFileEntries = async entry => entry.isFile ? entry :
(await Promise.all(Array.from(
                              await new Promise((resolve, reject) => entry.createReader()
                                                .readEntries(entries => resolve(entries), error => reject(error))),
                              getFileEntries))).flat()

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
                //            const entry = entries.find(entry => entry.filename.endsWith('.fb2'))
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
    mnb-sen ruby.mbn-src > rt {
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
            btn.hidden = false;
            btn.style.visibility = 'visible';
        } else {
            btn.hidden = true;
            btn.style.visibility = 'hidden';
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
            postPageNumLog('jump.goToDescriptor', {
                path: 'renderer-goTo-anchor',
                fraction: typeof descriptor.fraction === 'number' ? safeRound(descriptor.fraction, 6) : null,
                cfi: descriptor.cfi ?? null,
                sectionIndex: descriptor.sectionIndex,
                localSectionIndex: descriptor.localSectionIndex,
                rendererTotal: descriptor.rendererTotal,
                fractionInSection: safeRound(fractionInSection, 6),
                pageItemKey: descriptor.pageItemKey ?? null,
            });
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
                anchor: fractionInSection,
            })).catch((error) => console.error(error));
            return;
        }
        if (typeof descriptor.cfi === 'string' && descriptor.cfi) {
            postPageNumLog('jump.goToDescriptor', {
                path: 'view-goTo-cfi',
                fraction: typeof descriptor.fraction === 'number' ? safeRound(descriptor.fraction, 6) : null,
                cfi: descriptor.cfi ?? null,
                sectionIndex: typeof descriptor.sectionIndex === 'number' ? descriptor.sectionIndex : null,
                localSectionIndex: typeof descriptor.localSectionIndex === 'number' ? descriptor.localSectionIndex : null,
                rendererTotal: typeof descriptor.rendererTotal === 'number' ? descriptor.rendererTotal : null,
                pageItemKey: descriptor.pageItemKey ?? null,
            });
            await runWithNavigationIntent({
                source: 'goToDescriptor',
                target: 'view.goTo',
                cfiLength: descriptor.cfi.length,
                pageItemKey: descriptor.pageItemKey ?? null,
            }, () => this.view.goTo(descriptor.cfi)).catch((error) => console.error(error));
            return;
        }
        if (typeof descriptor.fraction === 'number' && Number.isFinite(descriptor.fraction)) {
            postPageNumLog('jump.goToDescriptor', {
                path: 'view-goToFraction',
                fraction: safeRound(descriptor.fraction, 6),
                cfi: descriptor.cfi ?? null,
                sectionIndex: typeof descriptor.sectionIndex === 'number' ? descriptor.sectionIndex : null,
                localSectionIndex: typeof descriptor.localSectionIndex === 'number' ? descriptor.localSectionIndex : null,
                rendererTotal: typeof descriptor.rendererTotal === 'number' ? descriptor.rendererTotal : null,
                pageItemKey: descriptor.pageItemKey ?? null,
            });
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
        postPageNumLog('goto.location.request', {
            source,
            locationNumber: clampedLocationNumber,
            locationTotal: maxLocationNumber,
            fraction: safeRound(fraction, 6),
            isRTL: !!this.isRTL,
        });
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
            ? linearSectionEntries.find((entry) => normalizeSpineHref(entry.href) === normalizedCurrentSectionHref) ?? null
            : null;
        const currentChapter = currentSectionEntry
            ? null
            : (this.view?.renderer?.tocItem ?? this.view?.lastLocation?.tocItem ?? null);
        const currentChapterHref = typeof currentSectionEntry?.href === 'string'
            ? currentSectionEntry.href
            : (currentSectionHref ?? (typeof currentChapter?.href === 'string' ? currentChapter.href : null));
        const normalizedCurrentChapterHref = normalizeSpineHref(currentChapterHref);
        const currentChapterEntry = normalizedCurrentChapterHref
            ? chapters.find((entry) => normalizeSpineHref(entry.href) === normalizedCurrentChapterHref)
            : null;
        const currentChapterPercent = typeof currentChapterEntry?.percent === 'number'
            ? currentChapterEntry.percent
            : null;
        const currentChapterIndex = currentChapterEntry
            ? chapters.findIndex((entry) => normalizeSpineHref(entry.href) === normalizeSpineHref(currentChapterEntry.href))
            : -1;
        const nextChapterPercent = currentChapterIndex >= 0
            ? (chapters.slice(currentChapterIndex + 1).find((entry) => typeof entry.percent === 'number')?.percent ?? 100)
            : null;
        const currentChapterPercentSource = typeof currentChapterEntry?.percentSource === 'string'
            ? currentChapterEntry.percentSource
            : null;
        const canJumpBack = !!this.navHUD?._isRelocateButtonVisible?.('back');
        const canJumpForward = !!this.navHUD?._isRelocateButtonVisible?.('forward');
        const backLabel = this.navHUD?.navRelocateLabels?.back?.textContent
            || this.navHUD?.labelForDescriptor?.(this.navHUD?._descriptorForRelocateLabel?.('back'))
            || '';
        const forwardLabel = this.navHUD?.navRelocateLabels?.forward?.textContent
            || this.navHUD?.labelForDescriptor?.(this.navHUD?._descriptorForRelocateLabel?.('forward'))
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
        postPageNumLog('goto.snapshot', {
            isRTL: snapshot.isRTL,
            chapterCount: chapters.length,
            currentChapterHref: snapshot.currentChapterHref,
            currentChapterTitle: snapshot.currentChapterTitle,
            currentSectionIndex,
            currentSectionIndexSource: resolvedSectionIndex?.source ?? null,
            rendererCurrentIndex,
            relocateSectionIndex,
            navLastSectionIndexSeen: this.navHUD?.lastSectionIndexSeen ?? null,
            currentSectionHref,
            normalizedCurrentSectionHref,
            currentChapterPercent,
            nextChapterPercent,
            currentChapterPercentSource,
            currentPercent: snapshot.currentPercent,
            currentPercentReady: currentPercent != null,
            canJumpBack,
            canJumpForward,
            backLabel,
            forwardLabel,
            chapterPreview: chapters.slice(0, 8).map((entry) => ({
                href: entry.href,
                title: entry.title,
                percent: entry.percent,
                percentSource: entry.percentSource ?? null,
            })),
        });
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
        requestAnimationFrame(() => this.#logPageTrackingLayout(
            'hide-navigation-due-to-scroll',
            hidden ? 'nav-hidden' : 'nav-visible',
            null,
            null
        ));
    }
    constructor() {
        applyStoredChromeInsets('reader.constructor');
        this.navHUD = new NavigationHUD({
            formatPercent: value => percentFormat.format(value),
            getRenderer: () => this.view?.renderer,
            onJumpRequest: descriptor => this._goToDescriptor(descriptor),
            onHideNavigationDueToScrollChange: (hidden, details = {}) => {
                this.#applyHideNavigationDueToScrollToBookContent(hidden);
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
            postPageNumLog('goto.live-schedule.fire', {
                requestedFraction: typeof fraction === 'number' && Number.isFinite(fraction) ? fraction : null,
                clampedFraction: Number.isFinite(clampedFraction) ? clampedFraction : null,
                hasView: !!this.view,
                navLabel: this.navHUD?.latestPrimaryLabel ?? '',
                hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
                currentFraction: typeof currentFraction === 'number' && Number.isFinite(currentFraction) ? safeRound(currentFraction, 6) : null,
                currentLocationCurrent,
                targetLocationCurrent,
            });
            if (!Number.isFinite(clampedFraction) || !this.view) {
                postPageNumLog('goto.live-schedule.skipped', {
                    requestedFraction: typeof fraction === 'number' && Number.isFinite(fraction) ? fraction : null,
                    clampedFraction: Number.isFinite(clampedFraction) ? clampedFraction : null,
                    hasView: !!this.view,
                    reason: !Number.isFinite(clampedFraction) ? 'invalid-fraction' : 'missing-view',
                });
                return;
            }
            if (typeof currentFraction === 'number' && Number.isFinite(currentFraction) && Math.abs(currentFraction - clampedFraction) < 0.0005) {
                postPageNumLog('goto.live-schedule.skipped', {
                    requestedFraction: typeof fraction === 'number' && Number.isFinite(fraction) ? fraction : null,
                    clampedFraction,
                    hasView: !!this.view,
                    reason: 'already-at-fraction',
                    currentFraction: safeRound(currentFraction, 6),
                });
                return;
            }
            if (currentLocationCurrent != null
                && targetLocationCurrent != null
                && currentLocationCurrent === targetLocationCurrent
                && currentLocationTotal != null
                && targetLocationTotal != null
                && currentLocationTotal === targetLocationTotal) {
                postPageNumLog('goto.live-schedule.skipped', {
                    requestedFraction: typeof fraction === 'number' && Number.isFinite(fraction) ? fraction : null,
                    clampedFraction,
                    hasView: !!this.view,
                    reason: 'already-at-location-index',
                    currentLocationCurrent,
                    targetLocationCurrent,
                    locationTotal: currentLocationTotal,
                });
                return;
            }
            if (roundedCurrentPercent != null && roundedTargetPercent != null && roundedCurrentPercent === roundedTargetPercent) {
                postPageNumLog('goto.live-schedule.skipped', {
                    requestedFraction: typeof fraction === 'number' && Number.isFinite(fraction) ? fraction : null,
                    clampedFraction,
                    hasView: !!this.view,
                    reason: 'already-at-rounded-percent',
                    currentFraction: safeRound(currentFraction, 6),
                    roundedPercent: roundedCurrentPercent,
                });
                return;
            }
            runWithNavigationIntent({
                source: 'live-schedule',
                target: 'view.goToFraction',
                fraction: clampedFraction,
            }, () => this.view.goToFraction(clampedFraction))
                .then(() => {
                    postPageNumLog('goto.live-schedule.resolved', {
                        clampedFraction,
                        navLabel: this.navHUD?.latestPrimaryLabel ?? '',
                    });
                })
                .catch((error) => {
                    postPageNumLog('goto.live-schedule.error', {
                        clampedFraction,
                        message: error?.message ?? String(error),
                    });
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
            const excludedTarget = target?.closest?.('button, a, input, textarea, select, [role="button"], [contenteditable="true"], #progress-wrapper, .nav-relocate-button, .nav-section-progress') || null;
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
            postBookRotateLog('window.resize', {
                innerWidth: window.innerWidth ?? null,
                innerHeight: window.innerHeight ?? null,
                visualViewportWidth: window.visualViewport?.width ?? null,
                visualViewportHeight: window.visualViewport?.height ?? null,
                orientationAngle: screen.orientation?.angle ?? window.orientation ?? null,
                orientationType: screen.orientation?.type ?? null,
            });
            this.#invalidateVisiblePageSegmentSnapshot();
            this.#updatePageReadMarker('window-resize');
            requestAnimationFrame(() => this.#syncPageTrackingButtons('window-resize', null, 1).catch((error) => console.error(error)));
        });
        window.visualViewport?.addEventListener?.('resize', () => {
            postBookRotateLog('visualViewport.resize', {
                innerWidth: window.innerWidth ?? null,
                innerHeight: window.innerHeight ?? null,
                visualViewportWidth: window.visualViewport?.width ?? null,
                visualViewportHeight: window.visualViewport?.height ?? null,
                visualViewportOffsetLeft: window.visualViewport?.offsetLeft ?? null,
                visualViewportOffsetTop: window.visualViewport?.offsetTop ?? null,
                orientationAngle: screen.orientation?.angle ?? window.orientation ?? null,
                orientationType: screen.orientation?.type ?? null,
            });
            this.#invalidateVisiblePageSegmentSnapshot();
            this.#updatePageReadMarker('visual-viewport-resize');
            requestAnimationFrame(() => this.#syncPageTrackingButtons('visual-viewport-resize', null, 1).catch((error) => console.error(error)));
        });
        window.manabiInvalidateVisiblePageSegmentSnapshot = (reason = 'manual') => {
            this.#invalidateVisiblePageSegmentSnapshot(reason);
            requestAnimationFrame(() => this.#syncPageTrackingButtons(reason, null, 1).catch((error) => console.error(error)));
        };
        screen.orientation?.addEventListener?.('change', () => {
            postBookRotateLog('screen.orientation.change', {
                innerWidth: window.innerWidth ?? null,
                innerHeight: window.innerHeight ?? null,
                visualViewportWidth: window.visualViewport?.width ?? null,
                visualViewportHeight: window.visualViewport?.height ?? null,
                orientationAngle: screen.orientation?.angle ?? window.orientation ?? null,
                orientationType: screen.orientation?.type ?? null,
            });
            this.#invalidateVisiblePageSegmentSnapshot();
            this.#updatePageReadMarker('screen-orientation-change');
            requestAnimationFrame(() => this.#syncPageTrackingButtons('screen-orientation-change', null, 1).catch((error) => console.error(error)));
        });
    }
    #logPageTracking(event, details = {}) {
        postReaderLog(event, details);
    }
    #logRead(event, details = {}) {
        void event;
        void details;
    }
    #logPageTrackingLayout(reason, phase, container, buttonHost) {
        const button = buttonHost instanceof HTMLElement
            ? buttonHost.querySelector('.page-read-button')
            : null;
        const navBar = document.getElementById('nav-bar');
        const navPrimaryText = document.getElementById('nav-primary-text');
        const navTitleLocationLabel = document.getElementById('nav-title-location-label');
        const computedStyle = window.getComputedStyle(document.body ?? document.documentElement);
        const docStyle = window.getComputedStyle(document.documentElement);
        const navPrimaryStyle = navPrimaryText instanceof Element ? window.getComputedStyle(navPrimaryText) : null;
        const navTitleLocationStyle = navTitleLocationLabel instanceof Element ? window.getComputedStyle(navTitleLocationLabel) : null;
        const navBarStyle = navBar instanceof Element ? window.getComputedStyle(navBar) : null;
        const viewportHeight = window.visualViewport?.height ?? window.innerHeight ?? null;
        const viewportWidth = window.visualViewport?.width ?? window.innerWidth ?? null;
        const controlSize = parseFloat(computedStyle?.getPropertyValue('--mnb-floating-control-size')) || 43;
        const iconSize = parseFloat(computedStyle?.getPropertyValue('--mnb-floating-icon-size')) || 21;
        const edgeInset = parseFloat(computedStyle?.getPropertyValue('--mnb-corner-control-edge-inset')) || 27;
        const percentLabelHeight = parseFloat(computedStyle?.getPropertyValue('--mnb-floating-percent-label-height')) || 12;
        const hiddenHeightReduction = parseFloat(computedStyle?.getPropertyValue('--mnb-floating-mark-read-hidden-height-reduction')) || 7;
        const hiddenMarkReadHeight = parseFloat(computedStyle?.getPropertyValue('--mnb-floating-mark-read-hidden-height'))
            || Math.max(0, controlSize - hiddenHeightReduction);
        const buttonRect = button instanceof Element ? button.getBoundingClientRect() : null;
        const navBarRect = navBar instanceof Element ? navBar.getBoundingClientRect() : null;
        const navPrimaryTextRect = navPrimaryText instanceof Element ? navPrimaryText.getBoundingClientRect() : null;
        const navTitleLocationRect = navTitleLocationLabel instanceof Element ? navTitleLocationLabel.getBoundingClientRect() : null;
        const navHidden = navBar?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null;
        const expectedMarkReadHeight = navHidden ? hiddenMarkReadHeight : controlSize;
        const expectedMarkReadRect = Number.isFinite(viewportHeight) && Number.isFinite(viewportWidth)
            ? {
                x: safeRound((viewportWidth - controlSize) / 2, 1),
                y: safeRound(viewportHeight - edgeInset - expectedMarkReadHeight, 1),
                w: safeRound(controlSize, 1),
                h: safeRound(expectedMarkReadHeight, 1),
            }
            : null;
        const expectedCornerRect = Number.isFinite(viewportHeight) && Number.isFinite(viewportWidth)
            ? {
                x: safeRound(viewportWidth - edgeInset - controlSize, 1),
                y: safeRound(viewportHeight - edgeInset - controlSize, 1),
                w: safeRound(controlSize, 1),
                h: safeRound(controlSize, 1),
            }
            : null;
        const expectedMarkReadIconRect = expectedMarkReadRect
            ? {
                x: safeRound(expectedMarkReadRect.x + ((expectedMarkReadRect.w - iconSize) / 2), 1),
                y: safeRound(expectedMarkReadRect.y + ((expectedMarkReadRect.h - iconSize) / 2), 1),
                w: safeRound(iconSize, 1),
                h: safeRound(iconSize, 1),
            }
            : null;
        const expectedPercentGap = expectedMarkReadRect && navPrimaryTextRect
            ? safeRound(expectedMarkReadRect.y - navPrimaryTextRect.bottom, 1)
            : null;
        const expectedIconPercentGap = expectedMarkReadIconRect && navPrimaryTextRect
            ? safeRound(expectedMarkReadIconRect.y - navPrimaryTextRect.bottom, 1)
            : null;
        const payload = {
            reason,
            phase,
            stateCount: this.pageTrackingStates?.length ?? 0,
            hasCompletionAction: !!this.completionAction,
            markReadButtonsVisible: document.body?.dataset?.mnbMarkReadButtonsVisible ?? null,
            navHidden,
            bodyDatasetNavigationHidden: document.body?.dataset?.mnbNavigationHiddenDueToScroll ?? null,
            cssToolbarBottom: computedStyle?.getPropertyValue('--mnb-toolbar-bottom-offset')?.trim() || null,
            cssToolbarContentGap: computedStyle?.getPropertyValue('--mnb-toolbar-content-gap')?.trim() || null,
            cssToolbarVisualDrop: computedStyle?.getPropertyValue('--mnb-toolbar-visual-drop')?.trim() || null,
            cssToolbarVisualBottom: computedStyle?.getPropertyValue('--mnb-toolbar-visual-bottom-inset')?.trim() || null,
            cssSystemBottom: computedStyle?.getPropertyValue('--mnb-system-bottom-inset')?.trim() || null,
            cssPhysicalBottom: computedStyle?.getPropertyValue('--mnb-toolbar-physical-bottom-inset')?.trim() || null,
            cssPageTrackingBottom: computedStyle?.getPropertyValue('--mnb-page-tracking-bottom-inset')?.trim() || null,
            cssPageTrackingToolbarBottom: computedStyle?.getPropertyValue('--mnb-page-tracking-toolbar-bottom-inset')?.trim() || null,
            cssStageBottom: computedStyle?.getPropertyValue('--mnb-reader-stage-bottom-inset')?.trim() || null,
            cssCornerEdgeInset: computedStyle?.getPropertyValue('--mnb-corner-control-edge-inset')?.trim()
                || docStyle?.getPropertyValue('--mnb-corner-control-edge-inset')?.trim()
                || null,
            cssPageReadButtonHeight: computedStyle?.getPropertyValue('--page-read-button-height')?.trim()
                || docStyle?.getPropertyValue('--page-read-button-height')?.trim()
                || null,
            cssFloatingControlSize: computedStyle?.getPropertyValue('--mnb-floating-control-size')?.trim()
                || docStyle?.getPropertyValue('--mnb-floating-control-size')?.trim()
                || null,
            cssFloatingIconSize: computedStyle?.getPropertyValue('--mnb-floating-icon-size')?.trim()
                || docStyle?.getPropertyValue('--mnb-floating-icon-size')?.trim()
                || null,
            cssFloatingVisibleIconTopAdjustment: computedStyle?.getPropertyValue('--mnb-floating-visible-icon-top-adjustment')?.trim()
                || docStyle?.getPropertyValue('--mnb-floating-visible-icon-top-adjustment')?.trim()
                || null,
            cssFloatingPercentLabelHeight: computedStyle?.getPropertyValue('--mnb-floating-percent-label-height')?.trim()
                || docStyle?.getPropertyValue('--mnb-floating-percent-label-height')?.trim()
                || null,
            cssFloatingPercentLabelGap: computedStyle?.getPropertyValue('--mnb-floating-percent-label-gap')?.trim()
                || docStyle?.getPropertyValue('--mnb-floating-percent-label-gap')?.trim()
                || null,
            cssFloatingHiddenMarkReadHeightReduction: computedStyle?.getPropertyValue('--mnb-floating-mark-read-hidden-height-reduction')?.trim()
                || docStyle?.getPropertyValue('--mnb-floating-mark-read-hidden-height-reduction')?.trim()
                || null,
            cssFloatingHiddenMarkReadHeight: computedStyle?.getPropertyValue('--mnb-floating-mark-read-hidden-height')?.trim()
                || docStyle?.getPropertyValue('--mnb-floating-mark-read-hidden-height')?.trim()
                || null,
            windowInnerHeight: window.innerHeight ?? null,
            windowInnerWidth: window.innerWidth ?? null,
            visualViewportHeight: window.visualViewport?.height ?? null,
            visualViewportWidth: window.visualViewport?.width ?? null,
            containerRect: this.#formatRect(container?.getBoundingClientRect?.()),
            buttonRect: this.#formatRect(buttonRect),
            navBarRect: this.#formatRect(navBarRect),
            navBarComputedBottom: navBarStyle?.bottom ?? null,
            navBarComputedHeight: navBarStyle?.height ?? null,
            navBarCurrentMarkReadHeight: navBarStyle?.getPropertyValue('--mnb-floating-mark-read-current-height')?.trim() || null,
            navPrimaryTextRect: this.#formatRect(navPrimaryTextRect),
            expectedNativeMarkReadRect: expectedMarkReadRect ? `x=${expectedMarkReadRect.x} y=${expectedMarkReadRect.y} w=${expectedMarkReadRect.w} h=${expectedMarkReadRect.h}` : null,
            expectedNativeMarkReadIconRect: expectedMarkReadIconRect ? `x=${expectedMarkReadIconRect.x} y=${expectedMarkReadIconRect.y} w=${expectedMarkReadIconRect.w} h=${expectedMarkReadIconRect.h}` : null,
            expectedNativeCornerRect: expectedCornerRect ? `x=${expectedCornerRect.x} y=${expectedCornerRect.y} w=${expectedCornerRect.w} h=${expectedCornerRect.h}` : null,
            expectedPercentGap,
            expectedIconPercentGap,
            navPrimaryFontFamily: navPrimaryStyle?.fontFamily ?? null,
            navPrimaryFontSize: navPrimaryStyle?.fontSize ?? null,
            navPrimaryFontWeight: navPrimaryStyle?.fontWeight ?? null,
            navPrimaryLineHeight: navPrimaryStyle?.lineHeight ?? null,
            navTitleLocationText: navTitleLocationLabel?.dataset?.titleLocationText
                ?? navTitleLocationLabel?.textContent
                ?? null,
            navTitleLocationRect: this.#formatRect(navTitleLocationRect),
            navTitleLocationFontFamily: navTitleLocationStyle?.fontFamily ?? null,
            navTitleLocationFontSize: navTitleLocationStyle?.fontSize ?? null,
            navTitleLocationFontWeight: navTitleLocationStyle?.fontWeight ?? null,
            navTitleLocationLineHeight: navTitleLocationStyle?.lineHeight ?? null,
            containerBottomGapToViewport: container instanceof Element && Number.isFinite(viewportHeight)
                ? safeRound(viewportHeight - container.getBoundingClientRect().bottom, 1)
                : null,
            buttonBottomGapToViewport: buttonRect && Number.isFinite(viewportHeight)
                ? safeRound(viewportHeight - buttonRect.bottom, 1)
                : null,
            navBarBottomGapToViewport: navBarRect && Number.isFinite(viewportHeight)
                ? safeRound(viewportHeight - navBarRect.bottom, 1)
                : null,
        };
        const logKey = [
            navHidden,
            phase,
            payload.navBarRect,
            payload.navPrimaryTextRect,
            payload.expectedNativeMarkReadRect,
            payload.expectedNativeMarkReadIconRect,
            payload.expectedNativeCornerRect,
            payload.expectedPercentGap,
            payload.expectedIconPercentGap,
        ].join('|');
        const now = performanceNowMs();
        if (this.lastToolbarLayoutLogKey === logKey && now - (this.lastToolbarLayoutLogAt ?? 0) < 1000) {
            return;
        }
        this.lastToolbarLayoutLogKey = logKey;
        this.lastToolbarLayoutLogAt = now;
        postPageTrackingBookLayoutLog('ebook.pageTracking.layout', payload);
        postReaderBridgeDebug('# TOOLBAR js.pageTracking.layout', payload);
    }
    #pageReadMarkerDiagnosticState(details = {}) {
        const readerStage = document.getElementById('reader-stage');
        const topMarker = document.getElementById('page-read-marker-top');
        const sideMarker = document.getElementById('page-read-marker-side');
        const topStyle = topMarker instanceof Element ? getComputedStyle(topMarker) : null;
        const sideStyle = sideMarker instanceof Element ? getComputedStyle(sideMarker) : null;
        const visibleScreenState = (this.pageTrackingStates || []).find((candidate) => candidate.id === 'visible-screen') || null;
        return {
            ...details,
            bodyReadAttr: document.body?.getAttribute?.('data-page-read-marker-read') ?? null,
            bodyTransitionAttr: document.body?.getAttribute?.('data-page-read-marker-transition') ?? null,
            bodyAxisAttr: document.body?.getAttribute?.('data-page-read-marker-axis') ?? null,
            visibleStateIsRead: visibleScreenState?.isRead ?? null,
            visibleStateReadState: visibleScreenState?.readState ?? null,
            pageTrackingStateCount: this.pageTrackingStates?.length ?? 0,
            hasCompletionAction: !!this.completionAction,
            completionAction: this.completionAction ?? null,
            markReadSessionID: this.markReadSessionID ?? null,
            topDisplay: topStyle?.display ?? null,
            topOpacity: topStyle?.opacity ?? null,
            topVisibility: topStyle?.visibility ?? null,
            topRect: this.#formatRect(topMarker?.getBoundingClientRect?.()),
            topOffsetWidth: topMarker instanceof HTMLElement ? topMarker.offsetWidth : null,
            sideDisplay: sideStyle?.display ?? null,
            sideOpacity: sideStyle?.opacity ?? null,
            sideVisibility: sideStyle?.visibility ?? null,
            sideRect: this.#formatRect(sideMarker?.getBoundingClientRect?.()),
            sideOffsetHeight: sideMarker instanceof HTMLElement ? sideMarker.offsetHeight : null,
            topMarkerLeft: readerStage?.style?.getPropertyValue?.('--mnb-ebook-read-marker-top-left') || null,
            topMarkerWidth: readerStage?.style?.getPropertyValue?.('--mnb-ebook-read-marker-top-width') || null,
            sideMarkerLeft: readerStage?.style?.getPropertyValue?.('--mnb-ebook-read-marker-side-left') || null,
            sideMarkerTop: readerStage?.style?.getPropertyValue?.('--mnb-ebook-read-marker-side-top') || null,
            sideMarkerHeight: readerStage?.style?.getPropertyValue?.('--mnb-ebook-read-marker-side-height') || null,
        };
    }
    #pageReadMarkerTransitionMode(reason = 'unspecified') {
        const value = String(reason || '');
        if (
            value === 'page-turn-start'
            || value.startsWith('relocate')
            || value.startsWith('goTo')
            || value.startsWith('did-display')
        ) {
            return 'instant';
        }
        if (value.startsWith('page-tracking-visibility.relocate')) {
            return 'instant';
        }
        return 'animated';
    }
    #updatePageReadMarker(reason = 'unspecified', explicitState = null, explicitDoc = null) {
        const updateStartedAt = performanceNowMs();
        const transitionMode = this.#pageReadMarkerTransitionMode(reason);
        const state = explicitState || (this.pageTrackingStates || []).find((candidate) => candidate.id === 'visible-screen') || null;
        const rawIsRead = !!state?.isRead && !this.completionAction;
        let isRead = rawIsRead;
        const hasExplicitPageState = !!explicitState;
        if (hasExplicitPageState) {
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
        }
        if (readerStage instanceof HTMLElement) {
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
        } else if (readerStage instanceof HTMLElement) {
            readerStage.style.removeProperty('--mnb-ebook-read-marker-side-left');
            readerStage.style.removeProperty('--mnb-ebook-read-marker-side-top');
            readerStage.style.removeProperty('--mnb-ebook-read-marker-side-height');
        }
        document.body?.setAttribute?.('data-page-read-marker-transition', transitionMode);
        document.body?.setAttribute?.('data-page-read-marker-read', isRead ? 'true' : 'false');
        document.body?.setAttribute?.('data-page-read-marker-axis', isVertical ? 'block' : 'inline');
        if (isRead) {
            const topMarker = document.getElementById('page-read-marker-top');
            const topStyle = topMarker instanceof Element ? getComputedStyle(topMarker) : null;
            const stageStyle = readerStage instanceof Element ? getComputedStyle(readerStage) : null;
            const rootStyle = getComputedStyle(document.documentElement);
            const leftButton = document.getElementById('btn-scroll-left');
            const rightButton = document.getElementById('btn-scroll-right');
            const logPaginator = resolveFoliatePaginator(liveFoliateView);
        }
        const elapsedMs = performanceNowMs() - updateStartedAt;
        if (elapsedMs >= 8 || String(reason || '').includes('display') || String(reason || '').includes('document-load')) {
        }
    }
    #clearVisiblePageReadChrome(reason = 'unspecified') {
        const transitionMode = this.#pageReadMarkerTransitionMode(reason);
        const visibleButtons = Array.from(document.querySelectorAll('#page-tracking-buttons .page-read-button[data-page-tracking-id="visible-screen"]'));
        if (reason === 'page-turn-start') {
            this.#invalidateVisiblePageSegmentSnapshot(reason);
            this.pageReadMarkerAwaitingPageState = true;
        }
        document.body?.setAttribute?.('data-page-read-marker-transition', transitionMode);
        document.body?.setAttribute?.('data-page-read-marker-read', 'false');
        if (reason === 'page-turn-start') {
            return;
        }
        visibleButtons.forEach((button) => {
            button.dataset.mnbTrackingSectionRead = 'false';
            button.dataset.readState = 'ready';
            button.disabled = false;
            button.setAttribute('aria-label', 'Mark Read');
            button.querySelectorAll('.mnb-tracking-button-label, .sr-only').forEach((label) => {
                label.textContent = 'Mark Read';
            });
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
        this.#postUpdateReadingProgressMessage?.cancel?.();
        if (this.pageTrackingRetryHandle) {
            cancelAnimationFrame(this.pageTrackingRetryHandle);
            this.pageTrackingRetryHandle = null;
        }
        this.#clearScheduledPageTrackingSync();
        this.#clearDeferredPageReadMarkerUpdate();
        if (this.nativeLookupHitTargetRefreshHandle) {
            cancelAnimationFrame(this.nativeLookupHitTargetRefreshHandle);
            this.nativeLookupHitTargetRefreshHandle = null;
        }
    }
    #visibleRangeForDocument(doc) {
        const range = this.navHUD?.lastRelocateDetail?.range ?? null;
        return range?.commonAncestorContainer?.ownerDocument === doc
            || range?.startContainer?.ownerDocument === doc
            || range?.endContainer?.ownerDocument === doc
            ? range
            : null;
    }
    #visiblePageSegmentResult(doc, visibleRange = null, reason = 'visible-page-segment-result') {
        const snapshot = this.visiblePageSegmentSnapshot;
        if (
            snapshot
            && snapshot.generation === this.visiblePageCollectionGeneration
            && snapshot.doc === doc
            && snapshot.visibleRange === visibleRange
        ) {
            return snapshot.result;
        }
        const result = collectVisibleSegmentNodesFromRange(doc, visibleRange);
        this.visiblePageSegmentSnapshot = {
            generation: this.visiblePageCollectionGeneration,
            doc,
            visibleRange,
            result,
        };
        postNativeLookupHitTargetsForVisibleSegments(doc, result, reason);
        return result;
    }
    #scheduleNativeLookupHitTargetRefresh(reason = 'unspecified', frameDelay = 2, explicitDoc = null) {
        if (this.nativeLookupHitTargetRefreshHandle) {
            cancelAnimationFrame(this.nativeLookupHitTargetRefreshHandle);
            this.nativeLookupHitTargetRefreshHandle = null;
        }
        const generation = this.visiblePageCollectionGeneration;
        const remainingFrames = Math.max(1, Math.round(frameDelay));
        const runAfterFrame = (framesRemaining) => {
            this.nativeLookupHitTargetRefreshHandle = requestAnimationFrame(() => {
                if (generation !== this.visiblePageCollectionGeneration) {
                    this.nativeLookupHitTargetRefreshHandle = null;
                    return;
                }
                if (framesRemaining > 1) {
                    runAfterFrame(framesRemaining - 1);
                    return;
                }
                this.nativeLookupHitTargetRefreshHandle = null;
                const doc = isDocumentLike(explicitDoc)
                    ? explicitDoc
                    : (this.view?.renderer?.getContents?.()?.[0]?.doc ?? null);
                if (!isDocumentLike(doc)) {
                    return;
                }
                const visibleRange = this.#visibleRangeForDocument(doc);
                postVisibleRangeLog('nativeHitTargets.deferredRefresh', {
                    reason,
                    generation,
                    frameDelay: remainingFrames,
                    hasVisibleRange: !!visibleRange,
                    rangeCollapsed: typeof visibleRange?.collapsed === 'boolean' ? visibleRange.collapsed : null,
                });
                this.visiblePageSegmentSnapshot = null;
                this.#visiblePageSegmentResult(doc, visibleRange, `scheduled:${reason}`);
            });
        };
        runAfterFrame(remainingFrames);
    }
    #scheduleNativeLookupHitTargetRefreshSettle(reason = 'unspecified', explicitDoc = null) {
        this.#scheduleNativeLookupHitTargetRefresh(`${reason}.raf`, 1, explicitDoc);
        const scheduleLater = (delayMs, label, frameDelay = 1) => {
            setTimeout(() => {
                const doc = isDocumentLike(explicitDoc)
                    ? explicitDoc
                    : (this.view?.renderer?.getContents?.()?.[0]?.doc ?? null);
                if (!isDocumentLike(doc) || isCacheWarmerDocument(doc)) {
                    return;
                }
                this.#scheduleNativeLookupHitTargetRefresh(`${reason}.${label}`, frameDelay, doc);
            }, delayMs);
        };
        scheduleLater(120, 'settled-120ms', 1);
        scheduleLater(360, 'settled-360ms', 1);
        try {
            explicitDoc?.fonts?.ready?.then?.(() => {
                if (!isCacheWarmerDocument(explicitDoc)) {
                    this.#scheduleNativeLookupHitTargetRefresh(`${reason}.fonts-ready`, 1, explicitDoc);
                }
            });
        } catch (_error) {}
    }
    #updateEbookSubscriptionPreviewPageState({
        sectionIndex = null,
        localSectionIndex = null,
        rendererTotal = null,
        reason = null,
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
            const shouldShowPreviewHighlights = !isSubscribed && isFirstPageInSection;
            body.setAttribute('data-mnb-ebook-subscription-preview-page', shouldShowPreviewHighlights ? 'true' : 'false');
            body.setAttribute('data-manabi-ebook-subscription-preview-page', shouldShowPreviewHighlights ? 'true' : 'false');
        }
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
        markCacheWarmerForegroundActivity(`page-turn.${source}`);
        const shouldHide = direction === 'forward';
        recordPageTurnNavigationIntent(direction, source, {
            isRTL: this.isRTL,
            ...details,
        });
        if (shouldHide) {
            this.navHUD?.setHideNavigationDueToScroll?.(true, source, {
                direction,
                isRTL: this.isRTL,
                ...details,
            });
        } else {
            this.navHUD?.setHideNavigationDueToScroll?.(false, source, {
                direction,
                isRTL: this.isRTL,
                ...details,
            });
        }
        postEbookNavigationVisibilityToNative(shouldHide, source, {
            direction,
            isRTL: this.isRTL,
            ...details,
        });
    }
    #summarizeMarkReadIDs(segmentIdentifiers = [], sentenceIdentifiers = []) {
        const safeSegments = Array.isArray(segmentIdentifiers) ? segmentIdentifiers : [];
        const safeSentences = Array.isArray(sentenceIdentifiers) ? sentenceIdentifiers : [];
        return {
            segmentIdentifierCount: safeSegments.length,
            segmentIdentifierSample: safeSegments.slice(0, 3),
            sentenceIdentifierCount: safeSentences.length,
            sentenceIdentifierSample: safeSentences.slice(0, 3),
        };
    }
    #clearOptimisticMarkReadState(reason) {
        if (this.optimisticReadSegmentIdentifiers.size > 0 || this.optimisticSentenceIdentifiersRead.size > 0) {
        }
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
            const retryStartedAt = performance.now();
            this.pageTrackingRetryHandle = null;
            this.#syncPageTrackingButtons(reason, explicitDoc, retryCount - 1).catch((error) => console.error(error));
        });
    }
    #clearScheduledPageTrackingSync() {
        if (this.pageTrackingDeferredHandle) {
            clearTimeout(this.pageTrackingDeferredHandle);
            this.pageTrackingDeferredHandle = null;
        }
        if (this.pageTrackingDeferredFrameHandle) {
            cancelAnimationFrame(this.pageTrackingDeferredFrameHandle);
            this.pageTrackingDeferredFrameHandle = null;
        }
        this.pageTrackingDeferredRequest = null;
    }
    #schedulePageTrackingSync(reason = 'unspecified', explicitDoc = null, retryCount = 0, delayMs = 0) {
        this.#clearScheduledPageTrackingSync();
        const requestedAt = performanceNowMs();
        const request = {
            reason,
            explicitDoc,
            retryCount,
            delayMs: Math.max(0, Number(delayMs) || 0),
        };
        this.pageTrackingDeferredRequest = request;
        const scheduleFrame = () => {
            this.pageTrackingDeferredHandle = null;
            this.pageTrackingDeferredFrameHandle = requestAnimationFrame(() => {
                this.pageTrackingDeferredFrameHandle = null;
                if (this.pageTrackingDeferredRequest !== request) {
                    return;
                }
                this.pageTrackingDeferredRequest = null;
                const currentDoc = this.view?.renderer?.getContents?.()?.[0]?.doc ?? null;
                if (isDocumentLike(explicitDoc) && isDocumentLike(currentDoc) && explicitDoc !== currentDoc) {
                    return;
                }
                this.#syncPageTrackingButtons(reason, explicitDoc, retryCount).catch((error) => console.error(error));
            });
        };
        if (request.delayMs > 0) {
            this.pageTrackingDeferredHandle = setTimeout(scheduleFrame, request.delayMs);
        } else {
            scheduleFrame();
        }
    }
    #clearDeferredPageReadMarkerUpdate() {
        if (this.pageReadMarkerDeferredHandle) {
            clearTimeout(this.pageReadMarkerDeferredHandle);
            this.pageReadMarkerDeferredHandle = null;
        }
    }
    #schedulePageReadMarkerUpdate(reason = 'unspecified', delayMs = 0) {
        this.#clearDeferredPageReadMarkerUpdate();
        const requestedAt = performanceNowMs();
        const normalizedDelay = Math.max(0, Number(delayMs) || 0);
        this.pageReadMarkerDeferredHandle = setTimeout(() => {
            this.pageReadMarkerDeferredHandle = null;
            this.#updatePageReadMarker(reason);
        }, normalizedDelay);
    }
    async #waitForAnimationFrames(count = 1) {
        const frameCount = Math.max(0, Number(count) || 0);
        for (let index = 0; index < frameCount; index += 1) {
            await new Promise((resolve) => requestAnimationFrame(() => resolve()));
        }
    }
    async #settleInitialPaginatorLayout(reason = 'unknown', { allowWhileLoading = false, force = false, forceRender = false } = {}) {
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
            this.#postBookInsetSnapshot('settle.begin', {
                reason,
                allowWhileLoading,
                force,
                forceRender,
                hasSettledInitialPaginatorLayout: this.hasSettledInitialPaginatorLayout,
            });
            applyStoredChromeInsets(`initial-paginator-settle.${reason}`);
            const result = await renderer.renderIfContainerSizeChanged(`initial-paginator-settle.${reason}`);
            const snapshot = this.#buildLayoutSnapshot(`initial-paginator-settle.${reason}`, {
                previousSize: result?.previousSize ?? null,
                currentSize: result?.currentSize ?? null,
                rendered: result?.rendered ?? false,
                resultReason: result?.reason ?? null,
            });
            const hasGap = [
                snapshot.toolbarGapPx,
                snapshot.stageGapPx,
            ].some((value) => typeof value === 'number' && Math.abs(value) > 2);
            const isReady = (allowWhileLoading || !snapshot.bodyLoading)
                && typeof snapshot.currentPercent === 'number'
                && snapshot.livePaginatorBox != null;
            if (!isReady) {
                this.#postBookInsetSnapshot('settle.not-ready', {
                    reason,
                    allowWhileLoading,
                    force,
                    forceRender,
                    result,
                    isReady,
                    hasGap,
                });
                return result;
            }
            const shouldForceRender = forceRender && !result?.rendered;
            if ((hasGap || shouldForceRender) && typeof renderer.render === 'function') {
                await renderer.render();
                this.#updatePageReadMarker(shouldForceRender ? 'initial-paginator-settle.post-frame-forced-render' : 'initial-paginator-settle.forced-render');
                this.hasSettledInitialPaginatorLayout = true;
                const forcedResult = { ...result, forcedRender: true, forceRender: shouldForceRender };
                this.#postBookInsetSnapshot('settle.forced-rendered', {
                    reason,
                    allowWhileLoading,
                    force,
                    forceRender,
                    result: forcedResult,
                    hasGap,
                    shouldForceRender,
                });
                return forcedResult;
            }
            if (result?.rendered) {
                this.#updatePageReadMarker('initial-paginator-settle.rendered');
            }
            this.hasSettledInitialPaginatorLayout = true;
            this.#postBookInsetSnapshot('settle.finished', {
                reason,
                allowWhileLoading,
                force,
                forceRender,
                result,
                hasGap,
                shouldForceRender,
            });
            return result;
        } catch (error) {
            console.error(error);
            this.hasSettledInitialPaginatorLayout = false;
            return { rendered: false, reason: 'error', message: error?.message ?? String(error) };
        }
    }
    #scheduleInitialPaginatorSettle(reason = 'unknown') {
        if (MANABI_DISABLE_INITIAL_PAGINATOR_SETTLE) {
            return;
        }
        if (
            this.hasSettledInitialPaginatorLayout ||
            this.initialPaginatorSettleHandle
        ) {
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
    #formatTransition(before, after) {
        return before === after ? null : `${before ?? 'nil'} -> ${after ?? 'nil'}`;
    }
    #formatBox(width, height) {
        if (![width, height].some((value) => value !== null && value !== undefined)) {
            return null;
        }
        return `${width ?? 'nil'}x${height ?? 'nil'}`;
    }
    #formatScrollBox(client, scroll) {
        if (![client, scroll].some((value) => value !== null && value !== undefined)) {
            return null;
        }
        return `${client ?? 'nil'}/${scroll ?? 'nil'}`;
    }
    #formatRect(rect) {
        if (!rect) {
            return null;
        }
        const x = Number.isFinite(rect.left) ? safeRound(rect.left, 1) : null;
        const y = Number.isFinite(rect.top) ? safeRound(rect.top, 1) : null;
        const width = Number.isFinite(rect.width) ? safeRound(rect.width, 1) : null;
        const height = Number.isFinite(rect.height) ? safeRound(rect.height, 1) : null;
        if (![x, y, width, height].some((value) => value !== null)) {
            return null;
        }
        return `x=${x ?? 'nil'} y=${y ?? 'nil'} w=${width ?? 'nil'} h=${height ?? 'nil'}`;
    }
    #intersectRects(a, b) {
        if (!Number.isFinite(a?.left)
            || !Number.isFinite(a?.top)
            || !Number.isFinite(a?.right)
            || !Number.isFinite(a?.bottom)
            || !Number.isFinite(b?.left)
            || !Number.isFinite(b?.top)
            || !Number.isFinite(b?.right)
            || !Number.isFinite(b?.bottom)) {
            return null;
        }
        const left = Math.max(a.left, b.left);
        const top = Math.max(a.top, b.top);
        const right = Math.min(a.right, b.right);
        const bottom = Math.min(a.bottom, b.bottom);
        if (right <= left || bottom <= top) {
            return null;
        }
        return {
            left,
            top,
            right,
            bottom,
            width: right - left,
            height: bottom - top,
        };
    }
    #rectBottomGap(containerRect, contentRect) {
        const containerBottom = Number.isFinite(containerRect?.bottom) ? containerRect.bottom : null;
        const contentBottom = Number.isFinite(contentRect?.bottom) ? contentRect.bottom : null;
        return containerBottom != null && contentBottom != null
            ? safeRound(containerBottom - contentBottom, 1)
            : null;
    }
    #logLayoutTransition(_reason, _previousSnapshot, _nextSnapshot) {}
    #buildLayoutSnapshot(reason = 'unknown', extra = null) {
        const body = document.body;
        const docEl = document.documentElement;
        const computedStyle = window.getComputedStyle(body || docEl);
        const liveFoliateView = Array.from(document.querySelectorAll('foliate-view'))
            .find((view) => view?.dataset?.isCache !== 'true') || null;
        const livePaginator = resolveFoliatePaginator(liveFoliateView);
        const livePaginatorContainer = livePaginator?.shadowRoot?.getElementById?.('container') || null;
        const renderer = liveFoliateView?.renderer || null;
        const summarizeChildren = (root) => Array.from(root?.children ?? []).slice(0, 8).map((child) => {
            const id = child.id ? `#${child.id}` : '';
            const className = typeof child.className === 'string' && child.className.trim()
                ? `.${child.className.trim().replace(/\s+/g, '.')}`
                : '';
            return `${child.localName || child.tagName || 'unknown'}${id}${className}`;
        }).join('|') || null;
        const frameSources = [
            ['paginatorShadow', livePaginator?.shadowRoot],
            ['paginatorContainer', livePaginatorContainer],
            ['viewShadow', liveFoliateView?.shadowRoot],
            ['rendererShadow', renderer?.shadowRoot],
            ['document', document],
        ];
        const frameCandidates = frameSources.flatMap(([source, root]) => Array.from(root?.querySelectorAll?.('iframe') ?? []).map((frame) => ({
            source,
            frame,
        })));
        const navBar = document.getElementById('nav-bar');
        const readerStage = document.getElementById('reader-stage');
        const pageTrackingContainer = document.getElementById('page-tracking-container');
        const pageReadButton = document.querySelector('#page-tracking-buttons .page-read-button[data-page-tracking-id="visible-screen"], #page-tracking-buttons .page-read-button[data-completion-action]');
        const pagesLeftLabel = document.getElementById('nav-section-progress-center');
        const navBarRect = navBar?.getBoundingClientRect?.() ?? null;
        const readerStageRect = readerStage?.getBoundingClientRect?.() ?? null;
        const pageTrackingRect = pageTrackingContainer?.getBoundingClientRect?.() ?? null;
        const pageReadButtonRect = pageReadButton?.getBoundingClientRect?.() ?? null;
        const pagesLeftLabelRect = pagesLeftLabel?.getBoundingClientRect?.() ?? null;
        const liveFoliateViewRect = liveFoliateView?.getBoundingClientRect?.() ?? null;
        const livePaginatorRect = livePaginator?.getBoundingClientRect?.() ?? null;
        let visibleFrameRect = null;
        let visibleDocumentRect = null;
        let visibleBodyRect = null;
        let visibleTextRect = null;
        let viewportVisibleTextRect = null;
        let firstVisibleTextRect = null;
        let lastVisibleTextRect = null;
        let visibleTextRectCount = null;
        let viewportVisibleTextRectCount = null;
        let iframeWritingMode = null;
        let iframeBodyScrollBox = null;
        let iframeBodyClientBox = null;
        let iframeMargins = null;
        let iframePadding = null;
        let iframeCount = frameCandidates.length;
        let iframeSearchSources = frameSources.map(([source, root]) => `${source}:${root?.querySelectorAll?.('iframe')?.length ?? 0}`).join(' ');
        let iframeCandidateRects = null;
        let iframeAccessError = null;
        try {
            iframeCandidateRects = frameCandidates.slice(0, 8).map(({ source, frame }) => {
                const rect = frame?.getBoundingClientRect?.() ?? null;
                return `${source}:${this.#formatRect(rect)}:${frame?.src || frame?.getAttribute?.('src') || 'no-src'}`;
            }).join('|') || null;
            const visibleFrame = frameCandidates.find(({ frame }) => {
                const rect = frame?.getBoundingClientRect?.();
                return rect && rect.width > 0 && rect.height > 0;
            })?.frame ?? null;
            if (visibleFrame) {
                const frameRect = visibleFrame.getBoundingClientRect();
                visibleFrameRect = frameRect;
                const frameDoc = visibleFrame.contentDocument ?? null;
                const frameDocEl = frameDoc?.documentElement ?? null;
                const frameBody = frameDoc?.body ?? null;
                const frameView = visibleFrame.contentWindow ?? null;
                const frameBodyStyle = frameBody && frameView ? frameView.getComputedStyle(frameBody) : null;
                iframeWritingMode = frameBodyStyle?.writingMode ?? null;
                iframeMargins = frameBodyStyle
                    ? `m=${frameBodyStyle.marginTop}/${frameBodyStyle.marginRight}/${frameBodyStyle.marginBottom}/${frameBodyStyle.marginLeft}`
                    : null;
                iframePadding = frameBodyStyle
                    ? `p=${frameBodyStyle.paddingTop}/${frameBodyStyle.paddingRight}/${frameBodyStyle.paddingBottom}/${frameBodyStyle.paddingLeft}`
                    : null;
                iframeBodyScrollBox = this.#formatScrollBox(frameBody?.clientHeight ?? null, frameBody?.scrollHeight ?? null);
                iframeBodyClientBox = this.#formatBox(frameBody?.clientWidth ?? null, frameBody?.clientHeight ?? null);
                if (frameDocEl) {
                    const rect = frameDocEl.getBoundingClientRect();
                    visibleDocumentRect = {
                        left: frameRect.left + rect.left,
                        top: frameRect.top + rect.top,
                        width: rect.width,
                        height: rect.height,
                        bottom: frameRect.top + rect.bottom,
                    };
                }
                if (frameBody) {
                    const rect = frameBody.getBoundingClientRect();
                    visibleBodyRect = {
                        left: frameRect.left + rect.left,
                        top: frameRect.top + rect.top,
                        width: rect.width,
                        height: rect.height,
                        bottom: frameRect.top + rect.bottom,
                    };
                    const range = frameDoc?.createRange?.();
                    if (range) {
                        range.selectNodeContents(frameBody);
                        const rects = Array.from(range.getClientRects?.() ?? []).filter((rect) => rect.width > 0 && rect.height > 0);
                        if (rects.length > 0) {
                            visibleTextRectCount = rects.length;
                            const union = rects.reduce((acc, rect) => ({
                                left: Math.min(acc.left, rect.left),
                                top: Math.min(acc.top, rect.top),
                                right: Math.max(acc.right, rect.right),
                                bottom: Math.max(acc.bottom, rect.bottom),
                            }), {
                                left: rects[0].left,
                                top: rects[0].top,
                                right: rects[0].right,
                                bottom: rects[0].bottom,
                            });
                            visibleTextRect = {
                                left: frameRect.left + union.left,
                                top: frameRect.top + union.top,
                                width: union.right - union.left,
                                height: union.bottom - union.top,
                                bottom: frameRect.top + union.bottom,
                            };
                            const rectsByTop = [...rects].sort((a, b) => (a.top - b.top) || (a.left - b.left));
                            const rectsByBottom = [...rects].sort((a, b) => (b.bottom - a.bottom) || (b.right - a.right));
                            const firstRect = rectsByTop[0];
                            const lastRect = rectsByBottom[0];
                            if (firstRect) {
                                firstVisibleTextRect = {
                                    left: frameRect.left + firstRect.left,
                                    top: frameRect.top + firstRect.top,
                                    width: firstRect.width,
                                    height: firstRect.height,
                                    bottom: frameRect.top + firstRect.bottom,
                                };
                            }
                            if (lastRect) {
                                lastVisibleTextRect = {
                                    left: frameRect.left + lastRect.left,
                                    top: frameRect.top + lastRect.top,
                                    width: lastRect.width,
                                    height: lastRect.height,
                                    bottom: frameRect.top + lastRect.bottom,
                                };
                            }
                            const viewportRect = {
                                left: frameRect.left,
                                top: frameRect.top,
                                right: frameRect.right,
                                bottom: frameRect.bottom,
                            };
                            const clippedRects = rects
                                .map((rect) => this.#intersectRects(
                                    {
                                        left: frameRect.left + rect.left,
                                        top: frameRect.top + rect.top,
                                        right: frameRect.left + rect.right,
                                        bottom: frameRect.top + rect.bottom,
                                    },
                                    viewportRect,
                                ))
                                .filter(Boolean);
                            if (clippedRects.length > 0) {
                                viewportVisibleTextRectCount = clippedRects.length;
                                const viewportUnion = clippedRects.reduce((acc, rect) => ({
                                    left: Math.min(acc.left, rect.left),
                                    top: Math.min(acc.top, rect.top),
                                    right: Math.max(acc.right, rect.right),
                                    bottom: Math.max(acc.bottom, rect.bottom),
                                }), {
                                    left: clippedRects[0].left,
                                    top: clippedRects[0].top,
                                    right: clippedRects[0].right,
                                    bottom: clippedRects[0].bottom,
                                });
                                viewportVisibleTextRect = {
                                    left: viewportUnion.left,
                                    top: viewportUnion.top,
                                    width: viewportUnion.right - viewportUnion.left,
                                    height: viewportUnion.bottom - viewportUnion.top,
                                    bottom: viewportUnion.bottom,
                                };
                            }
                        }
                    }
                }
            }
        } catch (_error) {
            iframeAccessError = _error?.message || String(_error);
            // best-effort diagnostics only
        }
        const visibleTextBottom = Number.isFinite(visibleTextRect?.bottom) ? visibleTextRect.bottom : null;
        const lastVisibleTextBottom = Number.isFinite(lastVisibleTextRect?.bottom) ? lastVisibleTextRect.bottom : null;
        const navBarTop = Number.isFinite(navBarRect?.top) ? navBarRect.top : null;
        const readerStageBottom = Number.isFinite(readerStageRect?.bottom) ? readerStageRect.bottom : null;
        const frameBottom = Number.isFinite(visibleFrameRect?.bottom) ? visibleFrameRect.bottom : null;
        const documentBottom = Number.isFinite(visibleDocumentRect?.bottom) ? visibleDocumentRect.bottom : null;
        const bodyBottom = Number.isFinite(visibleBodyRect?.bottom) ? visibleBodyRect.bottom : null;
        const primaryLabelDiagnostics = this.navHUD?.lastPrimaryLabelDiagnostics ?? null;
        const navBarBottom = Number.isFinite(navBarRect?.bottom) ? navBarRect.bottom : null;
        const viewportHeight = window.visualViewport?.height ?? window.innerHeight ?? null;
        return {
            reason,
            extra,
            currentPercent: typeof primaryLabelDiagnostics?.currentPercent === 'number' ? primaryLabelDiagnostics.currentPercent : null,
            cssInsets: [
                `toolbar=${computedStyle?.getPropertyValue('--mnb-toolbar-bottom-offset')?.trim() || 'nil'}`,
                `system=${computedStyle?.getPropertyValue('--mnb-system-bottom-inset')?.trim() || 'nil'}`,
                `physical=${computedStyle?.getPropertyValue('--mnb-toolbar-physical-bottom-inset')?.trim() || 'nil'}`,
                `stage=${computedStyle?.getPropertyValue('--mnb-reader-stage-bottom-inset')?.trim() || 'nil'}`,
            ].join(' '),
            htmlCssInsets: [
                `toolbar=${window.getComputedStyle(docEl)?.getPropertyValue('--mnb-toolbar-bottom-offset')?.trim() || 'nil'}`,
                `system=${window.getComputedStyle(docEl)?.getPropertyValue('--mnb-system-bottom-inset')?.trim() || 'nil'}`,
                `physical=${window.getComputedStyle(docEl)?.getPropertyValue('--mnb-toolbar-physical-bottom-inset')?.trim() || 'nil'}`,
                `stage=${window.getComputedStyle(docEl)?.getPropertyValue('--mnb-reader-stage-bottom-inset')?.trim() || 'nil'}`,
            ].join(' '),
            windowInnerBox: this.#formatBox(window.innerWidth ?? null, window.innerHeight ?? null),
            visualViewportBox: this.#formatBox(window.visualViewport?.width ?? null, window.visualViewport?.height ?? null),
            visualViewportOffset: window.visualViewport
                ? `x=${safeRound(window.visualViewport.offsetLeft ?? 0, 1)} y=${safeRound(window.visualViewport.offsetTop ?? 0, 1)}`
                : null,
            documentClientBox: this.#formatBox(docEl?.clientWidth ?? null, docEl?.clientHeight ?? null),
            bodyClientBox: this.#formatBox(body?.clientWidth ?? null, body?.clientHeight ?? null),
            livePaginatorBox: this.#formatBox(
                livePaginatorContainer?.clientWidth ?? null,
                livePaginatorContainer?.clientHeight ?? null,
            ),
            foliateViewLocalName: liveFoliateView?.localName ?? null,
            rendererLocalName: renderer?.localName ?? null,
            rendererRect: this.#formatRect(renderer?.getBoundingClientRect?.()),
            paginatorShadowChildren: summarizeChildren(livePaginator?.shadowRoot),
            paginatorContainerChildren: summarizeChildren(livePaginatorContainer),
            foliateViewShadowChildren: summarizeChildren(liveFoliateView?.shadowRoot),
            iframeCount,
            iframeSearchSources,
            iframeCandidateRects,
            iframeAccessError,
            navBarRect: this.#formatRect(navBarRect),
            readerStageRect: this.#formatRect(readerStageRect),
            pageTrackingRect: this.#formatRect(pageTrackingRect),
            pageReadButtonRect: this.#formatRect(pageReadButtonRect),
            pagesLeftLabelRect: this.#formatRect(pagesLeftLabelRect),
            pagesLeftLabelHidden: pagesLeftLabel?.hidden ?? null,
            pagesLeftLabelVisibleAttr: pagesLeftLabel?.dataset?.pagesLeftVisible ?? null,
            pagesLeftLabelText: pagesLeftLabel?.textContent ?? null,
            navBarBottomGapToViewport: navBarBottom != null && Number.isFinite(viewportHeight)
                ? safeRound(viewportHeight - navBarBottom, 1)
                : null,
            readerStageBottomGapToViewport: readerStageBottom != null && Number.isFinite(viewportHeight)
                ? safeRound(viewportHeight - readerStageBottom, 1)
                : null,
            liveFoliateViewRect: this.#formatRect(liveFoliateViewRect),
            livePaginatorRect: this.#formatRect(livePaginatorRect),
            visibleFrameRect: this.#formatRect(visibleFrameRect),
            visibleDocumentRect: this.#formatRect(visibleDocumentRect),
            visibleBodyRect: this.#formatRect(visibleBodyRect),
            visibleTextRect: this.#formatRect(visibleTextRect),
            viewportVisibleTextRect: this.#formatRect(viewportVisibleTextRect),
            firstVisibleTextRect: this.#formatRect(firstVisibleTextRect),
            lastVisibleTextRect: this.#formatRect(lastVisibleTextRect),
            visibleTextRectCount,
            viewportVisibleTextRectCount,
            toolbarGapPx: visibleTextBottom != null && navBarTop != null
                ? safeRound(navBarTop - visibleTextBottom, 1)
                : null,
            toolbarGapLastRectPx: lastVisibleTextBottom != null && navBarTop != null
                ? safeRound(navBarTop - lastVisibleTextBottom, 1)
                : null,
            toolbarGapViewportTextPx: Number.isFinite(viewportVisibleTextRect?.bottom) && navBarTop != null
                ? safeRound(navBarTop - viewportVisibleTextRect.bottom, 1)
                : null,
            stageGapPx: visibleTextBottom != null && readerStageBottom != null
                ? safeRound(readerStageBottom - visibleTextBottom, 1)
                : null,
            frameBottomToTextBottomPx: frameBottom != null && visibleTextBottom != null
                ? safeRound(frameBottom - visibleTextBottom, 1)
                : null,
            documentBottomToTextBottomPx: documentBottom != null && visibleTextBottom != null
                ? safeRound(documentBottom - visibleTextBottom, 1)
                : null,
            bodyBottomToTextBottomPx: bodyBottom != null && visibleTextBottom != null
                ? safeRound(bodyBottom - visibleTextBottom, 1)
                : null,
            frameBottomToLastTextBottomPx: frameBottom != null && lastVisibleTextBottom != null
                ? safeRound(frameBottom - lastVisibleTextBottom, 1)
                : null,
            documentBottomToLastTextBottomPx: documentBottom != null && lastVisibleTextBottom != null
                ? safeRound(documentBottom - lastVisibleTextBottom, 1)
                : null,
            bodyBottomToLastTextBottomPx: bodyBottom != null && lastVisibleTextBottom != null
                ? safeRound(bodyBottom - lastVisibleTextBottom, 1)
                : null,
            viewportFrameBottomToTextBottomPx: this.#rectBottomGap(visibleFrameRect, viewportVisibleTextRect),
            viewportDocumentBottomToTextBottomPx: this.#rectBottomGap(visibleDocumentRect, viewportVisibleTextRect),
            viewportBodyBottomToTextBottomPx: this.#rectBottomGap(visibleBodyRect, viewportVisibleTextRect),
            iframeWritingMode,
            iframeBodyClientBox,
            iframeBodyScrollBox,
            iframeMargins,
            iframePadding,
            bodyLoading: !!body?.classList?.contains?.('loading'),
        };
    }
    collectLayoutGapProbe(reason = 'unknown', extra = null) {
        return this.#buildLayoutSnapshot(reason, extra);
    }
    #postBookInsetSnapshot(event, extra = {}) {
        let snapshot = null;
        try {
            snapshot = this.#buildLayoutSnapshot(`book-inset.${event}`, extra);
        } catch (error) {
            postBookInsetLog(event, {
                ...extra,
                snapshotError: error?.message ?? String(error),
            });
            return;
        }
        postBookInsetLog(event, {
            ...extra,
            snapshot,
        });
    }
    refreshPageTrackingVisibility(reason = 'settings-changed') {
        this.#renderPageTrackingButtons(reason);
        requestAnimationFrame(async () => {
            const renderer = this.view?.renderer;
            if (renderer && typeof renderer.renderIfContainerSizeChanged === 'function') {
                try {
                    await renderer.renderIfContainerSizeChanged(`page-tracking-visibility.${reason}`);
                } catch (error) {
                    console.error(error);
                }
            }
            this.#updatePageReadMarker(`page-tracking-visibility.${reason}`);
        });
    }

    #renderPageTrackingButtons(reason = 'unspecified') {
        const container = document.getElementById('page-tracking-container');
        const buttonHost = document.getElementById('page-tracking-buttons');
        const postNativeMarkReadState = (available, state = null, isBusy = false) => {
            this.#logRead('nativeMarkReadState', {
                reason,
                available: !!available,
                isRead: !!state?.isRead,
                isBusy: !!isBusy,
                stateID: state?.id ?? null,
                hasAnyMarkedReadContent: !!state?.hasAnyMarkedReadContent,
            });
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
        if (!(container instanceof HTMLElement) || !(buttonHost instanceof HTMLElement)) {
            this.lastPageTrackingVisibility = false;
            this.#updatePageReadMarker(reason, null);
            this.navHUD?.refreshAuxiliaryLayout?.();
            this.#logPageTrackingLayout(reason, 'native-overlay-no-html-container', container, buttonHost);
            postNativeMarkReadState(nativeMarkReadAvailable, nativeMarkReadState, nativeMarkReadBusy);
            return;
        }
        const shouldShowPageTracking = markReadButtonsVisible && (!!completionAction || hasStates);
        const buttonBefore = document.querySelector('#page-tracking-buttons .page-read-button[data-page-tracking-id="visible-screen"]');
        container.hidden = !shouldShowPageTracking;
        buttonHost.hidden = !shouldShowPageTracking;
        if (this.lastPageTrackingVisibility !== null && this.lastPageTrackingVisibility && !shouldShowPageTracking) {
            postMarkReadGoneLog('pageTracking.hidden', {
                reason,
                stateCount: pageTrackingStates.length,
                hasCompletionAction: !!completionAction,
                completionActionType: completionAction?.type ?? null,
                containerHidden: container.hidden,
                buttonHostHidden: buttonHost.hidden,
                hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
                navHidden: this.navHUD?.navHidden ?? null,
                pageTrackingBusyCount: this.pageTrackingBusyStateIDs.size,
            });
        }
        this.lastPageTrackingVisibility = shouldShowPageTracking;
        if (!shouldShowPageTracking) {
            buttonHost.innerHTML = '';
            this.#updatePageReadMarker(reason, null);
            this.navHUD?.refreshAuxiliaryLayout?.();
            this.#logPageTrackingLayout(reason, 'hidden', container, buttonHost);
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
            requestAnimationFrame(() => this.#logPageTrackingLayout(reason, 'completion-action', container, buttonHost));
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
            const existingReadAttr = state.id === 'visible-screen'
                ? buttonBefore?.getAttribute?.('data-mnb-tracking-section-read') ?? null
                : null;
            const shouldAnimateRead = this.pageTrackingAnimateReadStateIDs.has(state.id)
                && state.id === 'visible-screen'
                && buttonBefore instanceof HTMLElement
                && existingReadAttr !== 'true'
                && !!state.isRead
                && !isBusy;
            if (shouldAnimateRead || (this.pageTrackingAnimateReadStateIDs.has(state.id) && !!state.isRead && !isBusy)) {
                this.pageTrackingAnimateReadStateIDs.delete(state.id);
            }
            if (shouldAnimateRead) {
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
        const buttonAfter = document.querySelector('#page-tracking-buttons .page-read-button[data-page-tracking-id="visible-screen"]');
        requestAnimationFrame(() => {
            const buttonFrame = document.querySelector('#page-tracking-buttons .page-read-button[data-page-tracking-id="visible-screen"]');
            const buttonStyle = buttonFrame instanceof Element ? getComputedStyle(buttonFrame) : null;
            const markerSide = document.querySelector('.page-read-marker-side');
            const markerTop = document.getElementById('page-read-marker-top');
            const sideStyle = markerSide instanceof Element ? getComputedStyle(markerSide) : null;
            const topStyle = markerTop instanceof Element ? getComputedStyle(markerTop) : null;
            this.#logPageTrackingLayout(reason, 'visible-page', container, buttonHost);
        });
        this.navHUD?.refreshAuxiliaryLayout?.();
        this.#scheduleInitialPaginatorSettle('page-tracking-render');
    }
    async #advanceAfterMarkRead() {
        if (!this.view?.renderer) {
            return;
        }
        await new Promise((resolve) => setTimeout(resolve, 430));
        const renderer = this.view.renderer;
        const isAtForwardSectionBoundary = await renderer.atEnd();
        if (isAtForwardSectionBoundary) {
            const nextButtonVisible = this.buttons?.next && !this.buttons.next.hidden && !this.buttons.next.disabled;
            if (nextButtonVisible) {
                this.#logPageTracking('ebook.pageTracking.markRead.advance', {
                    mode: 'next-section',
                });
                globalThis.__manabiIgnoreNextIncomingHideNavigationCount = 0;
                this.#applyDeferredHideNavigationForMarkReadAdvance('next-section');
                this.buttons.next.click();
                this.#completeMarkReadAdvancePreserveHidden('next-section');
                return;
            }
        }
        this.#logPageTracking('ebook.pageTracking.markRead.advance', {
            mode: this.isRTL ? 'previous-visual-page' : 'next-visual-page',
        });
        globalThis.__manabiIgnoreNextIncomingHideNavigationCount = 0;
        this.#applyDeferredHideNavigationForMarkReadAdvance(this.isRTL ? 'previous-visual-page' : 'next-visual-page');
        this.#flashForwardSideNavChevron();
        this.#clearVisiblePageReadChrome('page-turn-start');
        if (this.isRTL) {
            await this.view.goLeft();
        } else {
            await this.view.goRight();
        }
        this.#completeMarkReadAdvancePreserveHidden('visual-page');
    }
    #applyDeferredHideNavigationForMarkReadAdvance(mode) {
        if (globalThis.__manabiApplyIgnoredHideNavigationOnPageTrackingAdvance !== true) {
            return;
        }
        globalThis.__manabiApplyIgnoredHideNavigationOnPageTrackingAdvance = false;
        this.navHUD?.setHideNavigationDueToScroll?.(true, 'page-tracking-button.advance.deferred-hide', {
            mode,
        });
        postEbookNavigationVisibilityToNative(true, 'page-tracking-button.advance.deferred-hide', {
            mode,
        });
    }
    #completeMarkReadAdvancePreserveHidden(mode) {
        if (globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay !== true) {
            return;
        }
        this.navHUD?.setHideNavigationDueToScroll?.(true, 'page-tracking-button.advance.complete', {
            mode,
        });
        postEbookNavigationVisibilityToNative(true, 'page-tracking-button.advance.complete', {
            mode,
        });
        globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay = false;
        globalThis.__manabiIgnoreNextIncomingRevealNavigationCount = 0;
    }
    #flashForwardSideNavChevron() {
        const direction = this.isRTL ? 'left' : 'right';
        this.#flashSideNavChevron(direction);
    }
    maybeFlashInitialForwardSideNavChevron(restoreState = null) {
        if (this.hasFlashedInitialForwardSideNavChevron) {
            return;
        }
        const sectionIndex = typeof restoreState?.sectionIndex === 'number'
            ? restoreState.sectionIndex
            : null;
        const locationCurrent = typeof restoreState?.locationCurrent === 'number'
            ? restoreState.locationCurrent
            : null;
        const currentFraction = typeof restoreState?.currentFraction === 'number'
            ? restoreState.currentFraction
            : null;
        const rendererPageCurrent = typeof this.navHUD?.rendererPageSnapshot?.current === 'number'
            ? this.navHUD.rendererPageSnapshot.current
            : null;
        const onFirstSection = sectionIndex == null || sectionIndex === 0;
        const onFirstPage = (locationCurrent == null || locationCurrent <= 1)
            && (rendererPageCurrent == null || rendererPageCurrent <= 1)
            && (currentFraction == null || currentFraction <= 0.003);
        if (!onFirstSection || !onFirstPage) {
            return;
        }
        this.hasFlashedInitialForwardSideNavChevron = true;
        this.#flashForwardSideNavChevron();
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
        icon.classList.add('chevron-visible');
        this.#chevronFadeTimers[key] = setTimeout(() => {
            icon.classList.remove('chevron-visible');
            icon.style.removeProperty('opacity');
            this.#chevronFadeTimers[key] = null;
        }, 180);
    }
    #onMainDocumentTouchStart(event) {
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
            lastLoggedProgressBucket: null,
        };
    }
    async #onMainDocumentTouchMove(event) {
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
                    detail: {
                        leftOpacity: '',
                        rightOpacity: '',
                        source: 'ebook-viewer',
                        reason: 'mainDocumentSwipe.move-axis-or-min-dx',
                    },
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
        const leftOpacity = chevronSide === 'left' ? progress : 0;
        const rightOpacity = chevronSide === 'right' ? progress : 0;
        this.view?.dispatchEvent?.(new CustomEvent('sideNavChevronOpacity', {
            bubbles: true,
            composed: true,
            detail: {
                leftOpacity,
                rightOpacity,
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
        const progressBucket = Math.floor(progress * 4);
        if (state.lastLoggedProgressBucket !== progressBucket || progress >= 1) {
            state.lastLoggedProgressBucket = progressBucket;
        }
        if (Math.abs(dx) <= minSwipe) return;
        state.triggered = true;
        this.#flashSideNavChevron(chevronSide);
        if (logicalDirection === 'forward') {
            this.#clearVisiblePageReadChrome('page-turn-start');
            this.#applyLogicalPageTurnNavigationVisibility('forward', 'page-turn.swipe', { method: 'next' });
            await this.view?.next?.();
        } else {
            this.#clearVisiblePageReadChrome('page-turn-start');
            this.#applyLogicalPageTurnNavigationVisibility('backward', 'page-turn.swipe', { method: 'prev' });
            await this.view?.prev?.();
        }
    }
    #onMainDocumentTouchEnd() {
        if (this.#mainDocumentSwipeState?.chevronActive) {
            this.view?.dispatchEvent?.(new CustomEvent('sideNavChevronOpacity', {
                bubbles: true,
                composed: true,
                detail: {
                    leftOpacity: '',
                    rightOpacity: '',
                    source: 'ebook-viewer',
                    reason: 'mainDocumentSwipe.touchend',
                },
            }));
        }
        this.#mainDocumentSwipeState = null;
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
                this.#logPageTracking('ebook.pageTracking.sync.noDocument', {
                    reason,
                    retryCount,
                    hasView: !!this.view,
                    hasRenderer: !!this.view?.renderer,
                    hasExplicitDoc: isDocumentLike(explicitDoc),
                    pendingReason: 'restore-pending',
                });
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
                    this.#logPageTracking('ebook.pageTracking.sync.noDocument', {
                        reason,
                        contentsCount: contents.length,
                        hasView: !!this.view,
                        hasRenderer: !!this.view?.renderer,
                        hasExplicitDoc: isDocumentLike(explicitDoc),
                        retryCount,
                        pendingReason: 'retry-before-clear',
                    });
                }
                this.#queuePageTrackingRetry(reason, explicitDoc, retryCount);
                return;
            }
            this.pageTrackingStates = [];
            this.#renderPageTrackingButtons(reason);
            const diagnosticsKey = `no-document:${reason}:${contents.length}`;
            if (this.lastPageTrackingDiagnosticsKey !== diagnosticsKey) {
                this.lastPageTrackingDiagnosticsKey = diagnosticsKey;
                this.#logPageTracking('ebook.pageTracking.sync.noDocument', {
                    reason,
                    contentsCount: contents.length,
                    hasView: !!this.view,
                    hasRenderer: !!this.view?.renderer,
                    hasExplicitDoc: isDocumentLike(explicitDoc),
                    retryCount,
                });
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
        this.#logRead('visibleStateComputed', {
            reason,
            documentURL: diagnostics.documentURL,
            stateCount: diagnostics.stateCount,
            isRead: visibleScreenState?.isRead ?? null,
            unreadVisibleSegmentCount: visibleScreenState?.unreadVisibleSegmentCount ?? null,
            visibleSegmentCount: visibleScreenState?.visibleSegmentCount ?? null,
            readSegmentCount: diagnostics.readSegmentCount,
            readSentenceCount: diagnostics.readSentenceCount,
            visibleReadIntersectionCount: diagnostics.visibleReadIntersectionCount,
            visibleReadSentenceIntersectionCount: diagnostics.visibleReadSentenceIntersectionCount,
            visibleSegmentIdentifierSample: diagnostics.visibleSegmentIdentifierSample?.join(',') ?? '',
            visibleSegmentIdentifierAliasSample: diagnostics.visibleSegmentIdentifierAliasSample?.join(',') ?? '',
            readSegmentIdentifierSample: diagnostics.readSegmentIdentifierSample?.join(',') ?? '',
            unreadVisibleSegmentIdentifierSample: diagnostics.unreadVisibleSegmentIdentifierSample?.join(',') ?? '',
            readVisibleSegmentIdentifierSample: diagnostics.readVisibleSegmentIdentifierSample?.join(',') ?? '',
            articleMarkedAsFinished: this.articleReadingProgress?.articleMarkedAsFinished ?? false,
            retryCount,
        });
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
                this.#logPageTracking('ebook.pageTracking.sync.noDocument', {
                    reason,
                    retryCount,
                    hasView: !!this.view,
                    hasRenderer: !!this.view?.renderer,
                    hasExplicitDoc: isDocumentLike(explicitDoc),
                    contentsCount: contents.length,
                    documentURL: diagnostics.documentURL,
                    viewportWidth: diagnostics.viewportWidth,
                    viewportHeight: diagnostics.viewportHeight,
                    pendingReason: 'zero-viewport-empty-document',
                });
            }
            this.#queuePageTrackingRetry(reason, null, retryCount);
            return;
        }
        this.pageTrackingStates = states;
        const renderStartedAt = performanceNowMs();
        this.#renderPageTrackingButtons(reason);
        const renderElapsedMs = performanceNowMs() - renderStartedAt;
        this.#updatePageReadMarker(reason, visibleScreenState, doc);
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
        this.#logPageTracking(event, {
            reason,
            documentURL: diagnostics.documentURL,
            clusterAxis: diagnostics.clusterAxis,
            viewportWidth: diagnostics.viewportWidth,
            viewportHeight: diagnostics.viewportHeight,
            totalSegmentCount: diagnostics.totalSegmentCount,
            visibleSegmentCount: diagnostics.visibleSegmentCount,
            hiddenTooltipCount: diagnostics.hiddenTooltipCount,
            missingIdentifierCount: diagnostics.missingIdentifierCount,
            outOfViewportCount: diagnostics.outOfViewportCount,
            recoveredTextSearchStringCount: diagnostics.recoveredTextSearchStringCount,
            skippedMissingSearchStringCount: diagnostics.skippedMissingSearchStringCount,
            clusterCount: diagnostics.clusterCount,
            stateCount: diagnostics.stateCount,
            completedStateCount: diagnostics.completedStateCount,
            readSegmentCount: diagnostics.readSegmentCount,
            readSentenceCount: diagnostics.readSentenceCount,
        });
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
            this.#logPageTracking('ebook.pageTracking.progressApplied', {
                articleMarkedAsFinished: this.articleReadingProgress.articleMarkedAsFinished,
                sentenceIdentifiersRead: this.articleReadingProgress.sentenceIdentifiersRead.length,
                readSegmentIdentifiers: this.articleReadingProgress.readSegmentIdentifiers.length,
                articleSentenceCount: this.articleReadingProgress.articleSentenceCount,
            });
            this.#logRead('progressApplied', {
                reason,
                articleMarkedAsFinished: this.articleReadingProgress.articleMarkedAsFinished,
                sentenceIdentifiersRead: this.articleReadingProgress.sentenceIdentifiersRead.length,
                readSegmentIdentifiers: this.articleReadingProgress.readSegmentIdentifiers.length,
                readSegmentIdentifierSample: this.articleReadingProgress.readSegmentIdentifiers.slice(0, 5).join(','),
                articleSentenceCount: this.articleReadingProgress.articleSentenceCount,
                mergedOptimisticSegmentCount,
                mergedOptimisticSentenceCount,
            });
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
            this.#logPageTracking('ebook.pageTracking.markRead.skip', {
                reason: 'missing-state',
                stateID,
            });
            return;
        }
        if (pageTrackingState.payload.segments.length === 0) {
            this.#logPageTracking('ebook.pageTracking.markRead.skip', {
                reason: 'empty-payload',
                stateID,
            });
            return;
        }
        if (pageTrackingState.isRead) {
            this.#logPageTracking('ebook.pageTracking.markRead.skip', {
                reason: 'already-read',
                stateID,
            });
            return;
        }
        this.#logPageTracking('ebook.pageTracking.markRead.start', {
            stateID,
            visibleSegmentCount: pageTrackingState.visibleSegmentCount,
            unreadVisibleSegmentCount: pageTrackingState.unreadVisibleSegmentCount,
            payloadSegmentCount: pageTrackingState.payload.segments.length,
            sentenceIdentifierCount: pageTrackingState.payload.sentenceIdentifiers.length,
        });
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
        this.#logPageTracking('ebook.pageTracking.markRead.optimisticApplied', {
            stateID,
            readSegmentIdentifiers: optimisticProgress.readSegmentIdentifiers.length,
            sentenceIdentifiersRead: optimisticProgress.sentenceIdentifiersRead.length,
        });
        await this.#advanceAfterMarkRead();
    }
    async markVisiblePageAsRead(source = 'native') {
        const completionAction = this.completionAction;
        if (completionAction) {
            if (this.completionActionBusy) {
                this.#logPageTracking('ebook.pageTracking.markRead.skip', {
                    reason: 'completion-action-busy',
                    source,
                    completionAction: completionAction.type ?? null,
                });
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
            this.#logPageTracking('ebook.pageTracking.markRead.skip', {
                reason: 'missing-visible-screen-state',
                source,
            });
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
    async open(file) {
        this.setLoadingIndicator(true);
        const readerOpenStartedAt = typeof performance !== 'undefined' && typeof performance.now === 'function'
            ? performance.now()
            : Date.now();
        postReaderLog('ebook.readerOpen.begin', {
            fileKind: file?.kind || 'nil',
            initialLayoutMode: typeof window.initialLayoutMode !== 'undefined' ? window.initialLayoutMode : null,
        });

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
        this.view.renderer.setStyles?.(getCSSForBookContent(this.style))
        this.#applyHideNavigationDueToScrollToBookContent(this.navHUD?.hideNavigationDueToScroll === true);
        applyStoredChromeInsets('reader.open');
        postLayoutLog('reader.open', collectEBookLayoutSnapshot(this.view, {
            initialLayoutMode: typeof window.initialLayoutMode !== 'undefined' ? window.initialLayoutMode : null,
            bookDir: this.bookDir,
            isRTL: this.isRTL,
        }));
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
                postLayoutLog('pageTurn.sideButton.skip', collectEBookLayoutSnapshot(this.view, {
                    side,
                    method,
                    eventType,
                    disabled: button?.disabled ?? null,
                    compactSheetSidePaginationDisabled: isCompactNavigationSheetSidePaginationDisabled(),
                    compactSheetDetentKind: document.body?.dataset?.mnbCompactNavigationSheetDetentKind ?? null,
                }));
                return;
            }
            postLayoutLog('pageTurn.sideButton.begin', collectEBookLayoutSnapshot(this.view, {
                side,
                method,
                eventType,
            }));
            try {
                this.#clearVisiblePageReadChrome('page-turn-start');
                this.#applyPageTurnNavigationVisibility(method, 'page-turn.side-button');
                if (method === 'goLeft') {
                    await this.view.goLeft();
                } else {
                    await this.view.goRight();
                }
                postLayoutLog('pageTurn.sideButton.end', collectEBookLayoutSnapshot(this.view, {
                    side,
                    method,
                    eventType,
                }));
            } catch (error) {
                postLayoutLog('pageTurn.sideButton.error', collectEBookLayoutSnapshot(this.view, {
                    side,
                    method,
                    eventType,
                    error: error?.message || String(error),
                }));
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
            postLayoutLog('foregroundPageTurnActivity', collectEBookLayoutSnapshot(this.view, {
                source,
                direction: detail.direction ?? null,
                reason: detail.reason ?? null,
            }));
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
                postNavigationTouchDebug(event, 'main-document.skip.syntheticMouseAfterTouch', {
                    ageMs: now - lastPostedMainDocumentBlankTouchTap.postedAtMs,
                });
                return;
            }
            if (window.__manabiLookupPopoverActive === true) {
                window.__manabiSuppressUnhandledTapHideNavigationUntil = now + 750;
            }
            const ebookNavigationHidden =
                globalThis.reader?.navHUD?.hideNavigationDueToScroll === true
                || document?.body?.dataset?.mnbNavigationHiddenDueToScroll === 'true'
                || document?.body?.classList?.contains?.('nav-hidden-due-to-scroll') === true;
            postReaderBridgeDebug('# HIDENAV js.noElement.post', {
                source,
                eventType: event.type,
                touchstartAtMs,
                ebookNavigationHidden,
                lookupPopoverActive: window.__manabiLookupPopoverActive === true,
            });
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
        const postNavigationTouchDebug = (event, stage, extra = {}) => {
            const target = event.target;
            const point = event.changedTouches?.[0] ?? event.touches?.[0] ?? event;
            const targetElement = target instanceof Element ? target : target?.parentElement;
            const rectFor = element => {
                if (!(element instanceof Element)) return null;
                const rect = element.getBoundingClientRect();
                return {
                    x: roundLayoutNumber(rect.x),
                    y: roundLayoutNumber(rect.y),
                    width: roundLayoutNumber(rect.width),
                    height: roundLayoutNumber(rect.height),
                    bottom: roundLayoutNumber(rect.bottom),
                };
            };
            window.webkit?.messageHandlers?.print?.postMessage?.({
                message: '# HIDENAV js.blankTouch',
                stage,
                eventType: event.type,
                x: roundLayoutNumber(point?.clientX),
                y: roundLayoutNumber(point?.clientY),
                targetTag: target?.tagName || target?.nodeName || null,
                targetID: target?.id || null,
                targetClass: typeof target?.className === 'string' ? target.className : null,
                closestNavBar: !!targetElement?.closest?.('#nav-bar'),
                closestPageTracking: !!targetElement?.closest?.('#page-tracking-container'),
                closestPageTrackingButtons: !!targetElement?.closest?.('#page-tracking-buttons'),
                closestButton: targetElement?.closest?.('button')?.id || null,
                navHidden: globalThis.reader?.navHUD?.hideNavigationDueToScroll === true
                    || document?.body?.dataset?.mnbNavigationHiddenDueToScroll === 'true'
                    || document?.body?.classList?.contains?.('nav-hidden-due-to-scroll') === true,
                navBarRect: rectFor(document.getElementById('nav-bar')),
                pageTrackingRect: rectFor(document.getElementById('page-tracking-container')),
                pageTrackingButtonsRect: rectFor(document.getElementById('page-tracking-buttons')),
                progressWrapperRect: rectFor(document.getElementById('progress-wrapper')),
                ...extra,
            });
        };
        const processTouchStart = function(event) {
            // Ignore touches inside foliate-js viewer iframe
            const target = event.target;
            const targetSummary = {
                eventType: event.type,
                tagName: target?.tagName || target?.nodeName || null,
                id: target?.id || null,
                className: target?.className || null,
                ownerIsMainDocument: !target || target.ownerDocument === document,
            };
            if (target && target.ownerDocument !== document) {
                postNavigationTouchDebug(event, 'main-document.skip.foreignDocument', targetSummary);
                return
            }
            const excludedTarget = target?.closest?.('#side-bar, #page-tracking-container, #nav-bar, #nav-hidden-overlay, .side-nav, input, textarea, select, [contenteditable="true"]');
            if (excludedTarget) {
                postNavigationTouchDebug(event, 'main-document.skip.excludedTarget', {
                    ...targetSummary,
                    excludedID: excludedTarget?.id || null,
                    excludedClass: typeof excludedTarget?.className === 'string' ? excludedTarget.className : null,
                });
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
                postNavigationTouchDebug(event, 'main-document.pending', {
                    ...targetSummary,
                    hasPending: !!pendingMainDocumentBlankNavigationTouch,
                });
                return;
            }
            postNavigationTouchDebug(event, 'main-document.post.mouse', targetSummary);
            postNoElementNavigationTouchStart(event, 'main-document.blank')
        }
        const processMainDocumentBlankNavigationTouchMove = function(event) {
            const pending = pendingMainDocumentBlankNavigationTouch;
            if (!pending) {
                return;
            }
            if (movedPastBlankNavigationTapThreshold(event, pending)) {
                postNavigationTouchDebug(event, 'main-document.skip.moved', {
                    startAtMs: pending.startAtMs,
                });
                clearPendingMainDocumentBlankNavigationTouch();
            }
        }
        const processMainDocumentBlankNavigationTouchEnd = function(event) {
            const pending = pendingMainDocumentBlankNavigationTouch;
            clearPendingMainDocumentBlankNavigationTouch();
            if (!pending || event.type === 'touchcancel') {
                postNavigationTouchDebug(event, 'main-document.skip.noPendingOrCancel', {
                    hadPending: !!pending,
                });
                return;
            }
            if (movedPastBlankNavigationTapThreshold(event, pending)) {
                postNavigationTouchDebug(event, 'main-document.skip.endMoved', {
                    startAtMs: pending.startAtMs,
                });
                return;
            }
            postNavigationTouchDebug(event, 'main-document.post.touchend', {
                startAtMs: pending.startAtMs,
            });
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
            const interactiveTarget = target?.closest?.('a, button, input, textarea, select, [role="button"], [contenteditable="true"], #progress-wrapper, .nav-relocate-button');
            postNavigationTouchDebug(event, 'nav-bar.touchstart', {
                interactive: !!interactiveTarget,
                interactiveID: interactiveTarget?.id || null,
                interactiveTag: interactiveTarget?.tagName || null,
            });
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
            postNavigationTouchDebug(event, 'page-tracking.touchstart', {
                interactive: !!pageReadButton,
                interactiveID: pageReadButton?.id || null,
                trackingID: pageReadButton?.dataset?.pageTrackingId || null,
                completionAction: pageReadButton?.dataset?.completionAction || null,
            });
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
        
        const toc = book.toc
        postReaderLog('ebook.readerOpen.toc.start', {
            hasTOC: !!toc,
            tocCount: Array.isArray(toc) ? toc.length : 'nil',
        });
        if (toc) {
            this.#tocView = createTOCView(toc, async (href) => {
                await runWithNavigationIntent({
                    source: 'toc',
                    target: 'view.goTo',
                    href,
                }, () => this.view.goTo(href)).catch(e => console.error(e))
                this.closeSideBar()
            })
            $('#toc-view').append(this.#tocView.element)
        }
        postReaderLog('ebook.readerOpen.toc.end', {
            hasTOCView: !!this.#tocView,
        });
        
        // load and show highlights embedded in the file by Calibre
        postReaderLog('ebook.readerOpen.calibreBookmarks.start', {
            hasMethod: typeof book.getCalibreBookmarks === 'function',
        });
        let calibreBookmarksPendingLogged = false;
        const calibreBookmarksPendingTimer = setTimeout(() => {
            calibreBookmarksPendingLogged = true;
            postReaderLog('ebook.readerOpen.calibreBookmarks.pending', {
                elapsedMs: Math.round(
                    (typeof performance !== 'undefined' && typeof performance.now === 'function'
                        ? performance.now()
                        : Date.now()) - readerOpenStartedAt
                ),
            });
        }, 1000);
        let bookmarks;
        try {
            bookmarks = await book.getCalibreBookmarks?.()
        } catch (error) {
            clearTimeout(calibreBookmarksPendingTimer);
            postReaderLog('ebook.readerOpen.calibreBookmarks.error', {
                message: error?.message || String(error),
            });
            throw error;
        }
        clearTimeout(calibreBookmarksPendingTimer);
        postReaderLog('ebook.readerOpen.calibreBookmarks.end', {
            pendingLogged: calibreBookmarksPendingLogged,
            bookmarkCount: Array.isArray(bookmarks) ? bookmarks.length : 'nil',
        });
        if (bookmarks) {
            postReaderLog('ebook.readerOpen.calibreBookmarks.import.start', {
                bookmarkCount: bookmarks.length,
            });
            const {
                fromCalibreHighlight
            } = await import('./epubcfi.js')
            postReaderLog('ebook.readerOpen.calibreBookmarks.import.end', {
                bookmarkCount: bookmarks.length,
            });
            for (const obj of bookmarks) {
                if (obj.type === 'highlight') {
                    const value = fromCalibreHighlight(obj)
                    const color = obj.style.which
                    const note = obj.notes
                    const annotation = {
                        value,
                        color,
                        note
                    }
                    const list = this.annotations.get(obj.spine_index)
                    if (list) list.push(annotation)
                        else this.annotations.set(obj.spine_index, [annotation])
                            this.annotationsByValue.set(value, annotation)
                            }
            }
            this.view.addEventListener('create-overlay', e => {
                const {
                    index
                } = e.detail
                const list = this.annotations.get(index)
                if (list)
                    for (const annotation of list)
                        this.view.addAnnotation(annotation)
                        })
            this.view.addEventListener('draw-annotation', e => {
                const {
                    draw,
                    annotation
                } = e.detail
                const {
                    color
                } = annotation
                draw(Overlayer.highlight, {
                    color
                })
            })
            this.view.addEventListener('show-annotation', e => {
                const annotation = this.annotationsByValue.get(e.detail.value)
                if (annotation.note) alert(annotation.note)
                    })
        }
        postReaderLog('ebook.readerOpen.end', {
            elapsedMs: Math.round(
                (typeof performance !== 'undefined' && typeof performance.now === 'function'
                    ? performance.now()
                    : Date.now()) - readerOpenStartedAt
            ),
            hasRenderer: !!this.view?.renderer,
            bodyClassName: document.body?.className || 'nil',
        });
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
        postPageNumLog('nav.sections.handoff', {
            sectionCount: Array.isArray(this.view?.book?.sections) ? this.view.book.sections.length : 0,
            pageTargetCount: Array.isArray(this.navHUD?.pageTargets) ? this.navHUD.pageTargets.length : 0,
            sectionPreview: Array.isArray(this.view?.book?.sections)
                ? this.view.book.sections.slice(0, 8).map((section, idx) => ({
                    index: idx,
                    href: section?.href ?? null,
                    linear: section?.linear ?? null,
                }))
                : [],
        });
        if (this.navHUD?.hideNavigationDueToScroll) {
            this.navHUD.setHideNavigationDueToScroll(true, 'reader.updateNavButtons.reapply', {
                atSectionStart,
                atSectionEnd,
                hasPrevSection,
                hasNextSection,
            });
        }
        postPageNumLog('nav.visibility.updateNavButtons', {
            atSectionStart,
            atSectionEnd,
            hasPrevSection,
            hasNextSection,
            compactSheetSidePaginationDisabled: isCompactNavigationSheetSidePaginationDisabled(),
            compactSheetDetentKind: document.body?.dataset?.mnbCompactNavigationSheetDetentKind ?? null,
            markedAsFinished: this.markedAsFinished,
            restartHiddenForMiddlePageWhileNavHidden: isRestartHiddenForMiddlePageWhileNavHidden,
            showingFinish: !!(completionAction?.type === 'finish'),
            showingRestart: !!(completionAction?.type === 'restart'),
            before: navVisibilityBefore,
            after: captureNavVisibilityState(),
        });
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
        this.setLoadingIndicator(true);
    }
    async #onDidDisplay({}) {
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
        const postFrameSettleResult = await this.#settleInitialPaginatorLayout('did-display.pre-clear.post-frame', {
            allowWhileLoading: true,
            force: true,
            forceRender: true,
        });
        this.#postBookInsetSnapshot('didDisplay.after-post-frame-settle', {
            initialSettleResult,
            postFrameSettleResult,
        });
        this.setLoadingIndicator(false);
        this.#postBookInsetSnapshot('didDisplay.loading-cleared', {
            initialSettleResult,
            postFrameSettleResult,
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
        postPageNumLog('nav.visibility.did-display', {
            before: navVisibilityBefore,
            after: captureNavVisibilityState(),
        });
        this.#scheduleInitialPaginatorSettle('did-display');
        this.#syncPageTrackingButtons('did-display.immediate', null, 0).catch((error) => console.error(error));
        requestAnimationFrame(() => {
            const livePaginator = resolveFoliatePaginator(this.view);
            const livePaginatorContainer = livePaginator?.shadowRoot?.getElementById?.('container') || null;
            this.#schedulePageReadMarkerUpdate('did-display.raf', 64);
        });
        postReaderVisibilityProbe('reader.didDisplay', this.view, null);
    }
    #onLoad({
        detail: {
            doc
        }
    }) {
        applyStoredChromeInsets('reader.documentLoad');
        applyNavigationHiddenStateToEbookDocument(doc, 'document-load');
        const singleMediaInitialLayout = !isCacheWarmerDocument(doc)
            ? classifySingleMediaDocumentForInitialLayout(doc, 'document-load')
            : { applied: false, reason: 'cache-warmer-document' };
        if (!isCacheWarmerDocument(doc)) {
            postReplaceTextPerfLog('document.load.first-non-cache', {
                documentURL: doc?.location?.href || null,
                ...summarizeDocumentFontState(doc),
                ...captureEPUBOverlapState(),
            });
            postReplaceTextPerfLog('document.fonts.state.first-non-cache', {
                documentURL: doc?.location?.href || null,
                outerHasCustomFontStyle: !!document.getElementById('mnb-custom-fonts-inline'),
                ebookHasCustomFontStyle: !!doc?.getElementById?.('mnb-custom-fonts-inline'),
                ebookCustomFontTag: doc?.getElementById?.('mnb-custom-fonts-inline')?.tagName || null,
                ebookCustomFontHref: doc?.getElementById?.('mnb-custom-fonts-inline')?.href || null,
                ...summarizeDocumentFontState(doc),
                ...captureEPUBOverlapState(),
            });
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
                    postReplaceTextPerfLog('document.fonts.ready.first', {
                        documentURL: doc?.location?.href || null,
                        elapsedMs: safeRound(performanceNowMs() - fontsReadyStartedAt, 1),
                        outerHasCustomFontStyle: !!document.getElementById('mnb-custom-fonts-inline'),
                        ebookHasCustomFontStyle: !!doc?.getElementById?.('mnb-custom-fonts-inline'),
                        ebookCustomFontTag: doc?.getElementById?.('mnb-custom-fonts-inline')?.tagName || null,
                        ebookCustomFontHref: doc?.getElementById?.('mnb-custom-fonts-inline')?.href || null,
                        ...captureEPUBOverlapState(),
                    });
                }
            }).catch((error) => {
            });
        }
        requestAnimationFrame(() => {
            const sourceHref = doc?.body?.dataset?.mnbSourceHref || null;
            if (!isCacheWarmerDocument(doc)) {
                window.manabi_recordLiveSettledSection?.(sourceHref);
                postReplaceTextPerfLog('document.animation-frame.first', {
                    documentURL: doc?.location?.href || null,
                    sourceHref,
                    ...captureEPUBOverlapState(),
                });
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
                    postReaderBridgeDebug('# HIDENAV js.contentBlank.skip.syntheticMouseAfterTouch', {
                        source,
                        eventType: event.type,
                        ageMs: now - lastPostedBlankTouchTap.postedAtMs,
                    });
                    return;
                }
                if (excludedTarget) {
                    postReaderBridgeDebug('# HIDENAV js.contentBlank.skip.excludedTarget', {
                        source,
                        eventType: event.type,
                        targetTag: target?.tagName || target?.nodeName || null,
                        targetID: target?.id || null,
                        excludedTag: excludedTarget?.tagName || excludedTarget?.nodeName || null,
                        excludedID: excludedTarget?.id || null,
                        excludedClass: typeof excludedTarget?.className === 'string' ? excludedTarget.className : null,
                    });
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
                    postReaderBridgeDebug('# HIDENAV js.contentBlank.post', {
                        source,
                        eventType: event.type,
                        touchstartAtMs,
                        ebookNavigationHidden,
                        targetTag: target?.tagName || target?.nodeName || null,
                        targetID: target?.id || null,
                        targetClass: typeof target?.className === 'string' ? target.className : null,
                    });
                    window.webkit?.messageHandlers?.touchstartCallbackHandler?.postMessage?.({
                        touchedEntryWithElementId: null,
                        wasAlreadySelected: false,
                        touchstartAtMs,
                        touchstartEventType: event.type,
                        ebookNavigationHidden,
                        source,
                    });
                } else {
                    postReaderBridgeDebug('# HIDENAV js.contentBlank.skip.debounce', {
                        source,
                        eventType: event.type,
                        ageMs: now - lastPostedAt,
                    });
                }
            };
            const handleBlankPointerTouchStart = (event) => {
                const target = event.target;
                const excludedTarget = target?.closest?.('a, button, input, textarea, select, [role="button"], [contenteditable="true"], mnb-sur, .mnb-seg, .mnb-sentence, ruby, rt');
                if (excludedTarget) {
                    postReaderBridgeDebug('# HIDENAV js.contentBlank.touchstart.excludedTarget', {
                        eventType: event.type,
                        targetTag: target?.tagName || target?.nodeName || null,
                        targetID: target?.id || null,
                        excludedTag: excludedTarget?.tagName || excludedTarget?.nodeName || null,
                        excludedID: excludedTarget?.id || null,
                    });
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
                postReaderBridgeDebug('# HIDENAV js.contentBlank.touchstart.pending', {
                    eventType: event.type,
                    hasPending: !!pendingBlankPointerTap,
                    targetTag: target?.tagName || target?.nodeName || null,
                    targetID: target?.id || null,
                    x: roundLayoutNumber(point?.clientX),
                    y: roundLayoutNumber(point?.clientY),
                });
            };
            const handleBlankPointerTouchMove = (event) => {
                const pending = pendingBlankPointerTap;
                if (!pending) return;
                if (blankPointerMovedPastTapThreshold(event, pending)) {
                    postReaderBridgeDebug('# HIDENAV js.contentBlank.skip.moved', {
                        eventType: event.type,
                        startAtMs: pending.startAtMs,
                    });
                    clearPendingBlankPointerTap();
                }
            };
            const handleBlankPointerTouchEnd = (event) => {
                const pending = pendingBlankPointerTap;
                clearPendingBlankPointerTap();
                if (!pending || event.type === 'touchcancel') {
                    postReaderBridgeDebug('# HIDENAV js.contentBlank.skip.noPendingOrCancel', {
                        eventType: event.type,
                        hadPending: !!pending,
                    });
                    return;
                }
                if (blankPointerMovedPastTapThreshold(event, pending)) {
                    postReaderBridgeDebug('# HIDENAV js.contentBlank.skip.endMoved', {
                        eventType: event.type,
                        startAtMs: pending.startAtMs,
                    });
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
        if (!isCacheWarmerDocument(doc)) {
            this.#scheduleNativeLookupHitTargetRefreshSettle('document-load', doc);
        }
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
        this.#invalidateVisiblePageSegmentSnapshot();
        const {
            fraction,
            location,
            tocItem,
            pageItem,
            cfi,
            reason
        } = detail
        requestLookupCloseForPageMotion('renderer.relocate', {
            reason: reason ?? null,
            fraction: safeRound(fraction),
            currentLocation: location?.current ?? null,
            totalLocation: location?.total ?? null,
        });
        await this.navHUD?.handleRelocate(detail);
        this.#scheduleNativeLookupHitTargetRefreshSettle('relocate');
        const primaryLabelDiagnostics = this.navHUD?.lastPrimaryLabelDiagnostics ?? null;
        const effectiveFraction = getAuthoritativeReaderFraction({
            navHUD: this.navHUD,
            detail,
            fallbackFraction: fraction,
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
        postLayoutLog('reader.relocate', collectEBookLayoutSnapshot(this.view, {
            reason: reason ?? null,
            fraction: safeRound(fraction),
            effectiveFraction: Number.isFinite(effectiveFraction) ? safeRound(effectiveFraction, 6) : null,
            currentLocation: location?.current ?? null,
            totalLocation: location?.total ?? null,
            sectionIndex,
            localSectionIndex,
            rendererTotal,
            cfiLength: typeof cfi === 'string' ? cfi.length : 0,
        }));
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
        postPageNumLog('bridge.updateReadingProgress.locator-decision', {
            reason: reason ?? null,
            effectiveFraction: Number.isFinite(effectiveFraction) ? safeRound(effectiveFraction, 6) : null,
            rawFraction: typeof fraction === 'number' ? safeRound(fraction, 6) : null,
            sectionIndex,
            localSectionIndex,
            rendererTotal,
            rawCFI: cfi ?? null,
            sectionBaseCFI,
            cfiLooksSectionBase,
            cfiIsUnstableAcrossPages,
            syntheticRestoreLocator,
            shouldPreferSyntheticRestoreLocator,
            persistedLocator,
        });
        // (removed: setting tocView currentHref here)
        
        if (this.hasLoadedLastPosition && !globalThis.__manabiRestoreInProgress) {
            if (didMarkCFIUnstable) {
                postPageNumLog('bridge.updateReadingProgress.cfi-unstable', {
                    rawCFI: cfi ?? null,
                    sectionIndex,
                    localSectionIndex,
                    previousSectionIndex: priorCFIObservation?.sectionIndex ?? null,
                    previousLocalSectionIndex: priorCFIObservation?.localSectionIndex ?? null,
                    rendererTotal,
                    syntheticRestoreLocator,
                });
            }
            postPageNumLog('bridge.updateReadingProgress', {
                reason: reason ?? null,
                fraction: Number.isFinite(effectiveFraction) ? safeRound(effectiveFraction, 6) : null,
                currentPercent,
                sectionIndex,
                localSectionIndex,
                rendererTotal,
                rawCFI: cfi ?? null,
                sectionBaseCFI,
                cfiLooksSectionBase,
                cfiIsUnstableAcrossPages,
                syntheticRestoreLocator,
                persistedLocator,
            });
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
                    fraction: Number.isFinite(effectiveFraction) ? effectiveFraction : fraction,
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
        await this.#syncPageTrackingButtons('relocate.immediate', null, 0);
        if (typeof currentPercent === 'number') {
            postReplaceTextPerfLog('relocate.first', {
                reason: detail?.reason || null,
                fraction: safeRound(detail?.fraction),
                currentPercent,
                currentLocation: detail?.location?.current ?? null,
                totalLocation: detail?.location?.total ?? null,
                ...captureEPUBOverlapState(),
            });
        }
        postBookRotateLog('reader.relocate', {
            reason: detail?.reason || null,
            fraction: safeRound(detail?.fraction),
            currentPercent,
            currentLocation: detail?.location?.current ?? null,
            totalLocation: detail?.location?.total ?? null,
            orientationAngle: screen.orientation?.angle ?? window.orientation ?? null,
            orientationType: screen.orientation?.type ?? null,
        });
        postReaderVisibilityProbe('reader.relocate', this.view, {
            reason: detail?.reason || null,
            fraction: safeRound(detail?.fraction),
            currentLocation: detail?.location?.current ?? null,
            totalLocation: detail?.location?.total ?? null,
        });
        this.#updatePageReadMarker('relocate');
        
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

class CacheWarmer {
    constructor() {
        this.view
        this.uniqueSentenceIdentifiers = new Set()
        this.lastPostedSentenceCount = null
        this.lastLoadedSectionIndex = null
        this.lastLoadedSectionHref = null
        this.settledSectionHrefs = new Set()
    }
    #normalizeSectionHref(href) {
        return normalizeSpineHref(href)
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
        const sections = Array.isArray(this.view?.book?.sections) ? this.view.book.sections : []
        const settled = new Set(
            Array.isArray(settledSectionHrefs)
                ? settledSectionHrefs.map((href) => this.#normalizeSectionHref(href)).filter(Boolean)
                : []
        )
        const activeHref = activeForegroundSectionHref()
        if (activeHref) settled.add(activeHref)
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
    async #openFirstUnsettledSection() {
        const settledSectionHrefs = this.#mergeSettledSectionHrefs()
        const minimumIndex = activeForegroundSectionIndex()
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
        postReplaceTextPerfLog('cache-warmer.open.scan', {
            targetSectionIndex: firstUnsettledIndex,
            targetSectionHref: Number.isInteger(firstUnsettledIndex)
                ? this.#normalizeSectionHref(this.view?.book?.sections?.[firstUnsettledIndex]?.href ?? this.view?.book?.sections?.[firstUnsettledIndex]?.id ?? null)
                : null,
            activeForegroundHref: activeHref,
            minimumIndex: Number.isInteger(minimumIndex) ? minimumIndex : null,
            settledSectionCount: settledSectionHrefs.length,
            settledSectionHrefs,
            sectionCount: this.view?.book?.sections?.length ?? 0,
            sectionSample,
            ...captureEPUBOverlapState(),
        })
        if (!Number.isInteger(firstUnsettledIndex)) {
            globalThis.__manabiCacheWarmerFinished = true
            postReplaceTextPerfLog('cache-warmer.finished', {
                sectionURL: null,
                sectionIndex: null,
                highestSectionIndex: globalThis.__manabiCacheWarmerHighestSectionIndex ?? null,
                uniqueSentenceCount: this.uniqueSentenceIdentifiers.size,
                trigger: 'open-no-unsettled',
                ...captureEPUBOverlapState(),
            })
            return
        }
        const skippedSettledSectionHrefs = this.view?.book?.sections
            ?.slice(0, firstUnsettledIndex)
            ?.map((section) => this.#normalizeSectionHref(section?.href ?? section?.id ?? null))
            ?.filter((href) => href && settledSectionHrefs.includes(href)) ?? []
        if (firstUnsettledIndex > 0) {
            const targetSection = this.view?.book?.sections?.[firstUnsettledIndex] ?? null
            postReplaceTextPerfLog('cache-warmer.skip-settled', {
                trigger: 'open',
                skippedToSectionIndex: firstUnsettledIndex,
                skippedToSectionHref: targetSection?.href ?? targetSection?.id ?? null,
                skippedSettledSectionHrefs,
                settledSectionCount: settledSectionHrefs.length,
                ...captureEPUBOverlapState(),
            })
        }
        const targetSection = this.view?.book?.sections?.[firstUnsettledIndex] ?? null
        postReplaceTextPerfLog('cache-warmer.target-unsettled', {
            trigger: 'open',
            targetSectionIndex: firstUnsettledIndex,
            targetSectionHref: targetSection?.href ?? targetSection?.id ?? null,
            skippedSettledSectionHrefs,
            settledSectionCount: settledSectionHrefs.length,
            ...captureEPUBOverlapState(),
        })
        await this.view.renderer.goTo({ index: firstUnsettledIndex })
    }
    async loadNextSectionSkippingSettled(settledSectionHrefs = [], minimumIndex = 0) {
        settledSectionHrefs = this.#mergeSettledSectionHrefs(settledSectionHrefs)
        const targetIndex = this.#nextUnsettledSectionIndex(settledSectionHrefs, minimumIndex)
        if (!Number.isInteger(targetIndex)) {
            globalThis.__manabiCacheWarmerFinished = true
            postReplaceTextPerfLog('cache-warmer.finished', {
                sectionURL: this.lastLoadedSectionHref,
                sectionIndex: this.lastLoadedSectionIndex,
                highestSectionIndex: globalThis.__manabiCacheWarmerHighestSectionIndex ?? null,
                uniqueSentenceCount: this.uniqueSentenceIdentifiers.size,
                trigger: 'skip-settled',
                minimumIndex: Number.isInteger(minimumIndex) ? minimumIndex : null,
                ...captureEPUBOverlapState(),
            })
            return
        }
        if (Number.isInteger(this.lastLoadedSectionIndex) && targetIndex === this.lastLoadedSectionIndex + 1) {
            const targetSection = this.view?.book?.sections?.[targetIndex] ?? null
            postReplaceTextPerfLog('cache-warmer.target-unsettled', {
                trigger: 'advance-adjacent',
                currentSectionIndex: this.lastLoadedSectionIndex,
                currentSectionHref: this.lastLoadedSectionHref,
                targetSectionIndex: targetIndex,
                targetSectionHref: targetSection?.href ?? targetSection?.id ?? null,
                activeForegroundHref: activeForegroundSectionHref(),
                minimumIndex: Number.isInteger(minimumIndex) ? minimumIndex : null,
                skippedSettledSectionHrefs: [],
                settledSectionCount: settledSectionHrefs.length,
                ...captureEPUBOverlapState(),
            })
            await this.view.renderer.nextSection()
            return
        }
        const targetSection = this.view?.book?.sections?.[targetIndex] ?? null
        const sectionSliceStart = Number.isInteger(this.lastLoadedSectionIndex) ? this.lastLoadedSectionIndex + 1 : 0
        const skippedSettledSectionHrefs = this.view?.book?.sections
            ?.slice(sectionSliceStart, targetIndex)
            ?.map((section) => this.#normalizeSectionHref(section?.href ?? section?.id ?? null))
            ?.filter((href) => href && settledSectionHrefs.includes(href)) ?? []
        postReplaceTextPerfLog('cache-warmer.skip-settled', {
            trigger: 'advance',
            currentSectionIndex: this.lastLoadedSectionIndex,
            currentSectionHref: this.lastLoadedSectionHref,
            skippedToSectionIndex: targetIndex,
            skippedToSectionHref: targetSection?.href ?? targetSection?.id ?? null,
            activeForegroundHref: activeForegroundSectionHref(),
            minimumIndex: Number.isInteger(minimumIndex) ? minimumIndex : null,
            skippedSettledSectionHrefs,
            settledSectionCount: settledSectionHrefs.length,
            ...captureEPUBOverlapState(),
        })
        postReplaceTextPerfLog('cache-warmer.target-unsettled', {
            trigger: 'advance',
            currentSectionIndex: this.lastLoadedSectionIndex,
            currentSectionHref: this.lastLoadedSectionHref,
            targetSectionIndex: targetIndex,
            targetSectionHref: targetSection?.href ?? targetSection?.id ?? null,
            activeForegroundHref: activeForegroundSectionHref(),
            minimumIndex: Number.isInteger(minimumIndex) ? minimumIndex : null,
            skippedSettledSectionHrefs,
            settledSectionCount: settledSectionHrefs.length,
            ...captureEPUBOverlapState(),
        })
        await this.view.renderer.goTo({ index: targetIndex })
    }
    destroy() {
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
    }
    async open(file) {
        this.destroy()
        globalThis.__manabiCacheWarmerOpenInFlight = true;
        globalThis.__manabiCacheWarmerReady = false;
        globalThis.__manabiCacheWarmerFinished = false;
        globalThis.__manabiCacheWarmerHighestSectionIndex = null;
        globalThis.__manabiDeferredCacheWarmerLogged = false;
        postReplaceTextPerfLog('cache-warmer.open.begin', {
            sourceKind: file?.kind || 'nil',
            ...captureEPUBOverlapState(),
        });
        try {
            this.view = await getView(file, true)
            this.view.addEventListener('load', this.#onLoad.bind(this))
            
            const {
                book
            } = this.view
            this.view.renderer.setAttribute('flow', 'paginated')
            await this.#openFirstUnsettledSection()
            globalThis.__manabiCacheWarmerOpenInFlight = false;
            globalThis.__manabiCacheWarmerReady = true;
            postReplaceTextPerfLog('cache-warmer.open.end', {
                sourceKind: file?.kind || 'nil',
                ...captureEPUBOverlapState(),
            });
        } catch (error) {
            postReplaceTextPerfLog('cache-warmer.open.error', {
                sourceKind: file?.kind || 'nil',
                message: error?.message || String(error),
                ...captureEPUBOverlapState(),
            });
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
            postPageNumLog('cacheWarmer.readyToLoadNextSection.post', {
                trigger,
                sectionIndex,
                sectionHref,
            });
            return;
        }
        globalThis.__manabiCacheWarmerFinished = true;
        postReplaceTextPerfLog('cache-warmer.finished', {
            sectionURL: location,
            sectionIndex,
            highestSectionIndex: globalThis.__manabiCacheWarmerHighestSectionIndex ?? null,
            uniqueSentenceCount: this.uniqueSentenceIdentifiers.size,
            trigger,
            ...captureEPUBOverlapState(),
        });
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
        }
        postPageNumLog('cacheWarmer.onLoad.begin', {
            sectionIndex: Number.isInteger(index) ? index : null,
            location,
            indexedSectionHref,
            sourceHref,
            sectionHref,
            sentenceCount: sentenceNodes.length,
            segmentCount: segmentNodes.length,
            navHUDReady: !!globalThis.reader?.navHUD,
        });
        postReaderLog('ebook.cacheWarmer.sectionLoaded', {
            sectionURL: location,
            documentURL: doc?.location?.href || 'nil',
            sectionIndex: Number.isInteger(index) ? index : 'nil',
            sourceHref: sourceHref || 'nil',
            sectionHref: sectionHref || 'nil',
            sentenceCount: sentenceNodes.length,
            segmentCount: segmentNodes.length,
            isCacheWarmerDocument: doc?.body?.dataset?.isCacheWarmer === 'true',
            isLikelyTitlePage,
        });
        postReplaceTextPerfLog('cache-warmer.section', {
            sectionURL: location,
            sectionIndex: Number.isInteger(index) ? index : null,
            highestSectionIndex: globalThis.__manabiCacheWarmerHighestSectionIndex ?? null,
            sourceHref: sourceHref || null,
            sentenceCount: sentenceNodes.length,
            segmentCount: segmentNodes.length,
            isLikelyTitlePage,
            ...summarizeDocumentFontState(doc),
            ...captureEPUBOverlapState(),
        });
        for (const sentenceNode of sentenceNodes) {
            const sentenceIdentifier = sentenceIdentifierForNode(sentenceNode);
            if (typeof sentenceIdentifier === 'string' && sentenceIdentifier.length > 0) {
                this.uniqueSentenceIdentifiers.add(sentenceIdentifier);
            }
        }
        const shouldDeferSentenceCountUpdate = this.uniqueSentenceIdentifiers.size === 0 && isLikelyTitlePage;
        if (shouldDeferSentenceCountUpdate) {
            postReaderLog('ebook.cacheWarmer.sentenceCountDeferred', {
                sectionURL: location,
                sectionIndex: Number.isInteger(index) ? index : 'nil',
                sourceHref: sourceHref || 'nil',
                reason: 'title-page-without-sentences',
            });
        } else if (this.lastPostedSentenceCount !== this.uniqueSentenceIdentifiers.size) {
            this.lastPostedSentenceCount = this.uniqueSentenceIdentifiers.size;
            postReaderLog('ebook.cacheWarmer.sentenceCountUpdate', {
                sectionURL: location,
                sectionIndex: Number.isInteger(index) ? index : 'nil',
                sourceHref: sourceHref || 'nil',
                articleSentenceCount: this.uniqueSentenceIdentifiers.size,
            });
            window.webkit.messageHandlers.updateArticleSentenceCount.postMessage({
                windowURL: window.top.location.href,
                articleSentenceCount: this.uniqueSentenceIdentifiers.size,
            });
        }

        window.webkit.messageHandlers.ebookCacheWarmerLoadedSection.postMessage({
            topWindowURL: window.top.location.href,
            frameURL: location,
        })
        postPageNumLog('cacheWarmer.loadedSection.post', {
            sectionIndex: Number.isInteger(index) ? index : null,
            location,
            sectionHref,
        });
        
        const atEnd = await this.view.renderer.atEnd();
        postPageNumLog('cacheWarmer.atEnd', {
            sectionIndex: Number.isInteger(index) ? index : null,
            sectionHref,
            atEnd,
        });
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

//const open = async file => {
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
    // TODO: Add scrolled mode back...
//    globalThis.reader.view.renderer.setAttribute('flow', layoutMode)
    applyStoredChromeInsets('setEbookViewerLayout');
    postEBookSafeAreaTopSnapshot('ebook.safeAreaTop.setLayout', {
        layoutMode,
    });
    postLayoutLog('setEbookViewerLayout', collectEBookLayoutSnapshot(globalThis.reader?.view, {
        layoutMode,
    }));
    globalThis.manabiInvalidateVisiblePageSegmentSnapshot?.('layout-change');
}

window.setEbookViewerWritingDirection = (writingDirection) => {
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
    postLayoutLog('setEbookViewerWritingDirection', collectEBookLayoutSnapshot(globalThis.reader?.view, {
        writingDirection,
    }));
    globalThis.manabiInvalidateVisiblePageSegmentSnapshot?.('writing-direction-change');
}

window.loadNextCacheWarmerSection = async (settledSectionHrefs = []) => {
    scheduleLoadNextCacheWarmerSection(settledSectionHrefs, 'native-ready');
}

window.loadEBook = ({
    url,
    layoutMode,
}) => {
    const requestedURL = typeof url === 'string' ? url : '';
    if (
        requestedURL.length > 0
        && globalThis.manabiLoadEBookURL === requestedURL
        && globalThis.manabiLoadEBookInFlight === true
    ) {
        const existingStartedAt = Number(globalThis.manabiLoadEBookStartedAt || 0);
        const existingStartedAgeMs = existingStartedAt > 0 ? Date.now() - existingStartedAt : 0;
        if (globalThis.reader?.view?.renderer || existingStartedAgeMs < 2500) {
            globalThis.manabiLoadEBookLastState = 'duplicate-inflight';
            globalThis.manabiPendingLoadEBookArgs = null;
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
    globalThis.manabiPendingLoadEBookArgs = {
        hasURL: typeof url === 'string' && url.length > 0,
        layoutMode: layoutMode || null,
    };
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
    postReaderLog('ebook.viewer.load.start', {
        hasURL: typeof url === 'string' && url.length > 0,
        layoutMode: layoutMode || 'default',
    });
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
                    postReaderLog('ebook.viewer.load.blobReady', {
                        blobSize: blob.size,
                        blobType: blob.type || 'nil',
                    });
                    return makeFileSource(new File([blob], new URL(url).pathname))
                })

        const openPromise = sourcePromise
        .then(async (source) => {
            if (globalThis.manabiLoadEBookToken !== loadToken) return;
            globalThis.manabiLoadEBookLastState = 'source-ready';
            globalThis.manabiPendingLoadEBookArgs = null;
            if (source?.kind === 'native') {
                postReaderLog('ebook.viewer.load.nativeSource', {
                    sourceURL: source.url,
                });
            }
            if (layoutMode) {
                window.initialLayoutMode = layoutMode
            }
            globalThis.manabiLoadEBookLastState = 'reader-open-dispatch';
            await reader.open(source)
            if (!reader?.view?.renderer) {
                throw new Error('reader-open-missing-renderer');
            }
        })
        .then(async () => {
            if (globalThis.manabiLoadEBookToken !== loadToken) return;
            globalThis.reader = reader;
            finishLoadWatchdogs();
            globalThis.manabiLoadEBookReady = true;
            globalThis.manabiLoadEBookLastState = 'reader-open-resolved';
            postReaderLog('ebook.viewer.load.opened', {
                hasRenderer: !!globalThis.reader?.view?.renderer,
                bookDir: globalThis.reader?.bookDir || 'nil',
                isRTL: !!globalThis.reader?.isRTL,
            });
            const probe = globalThis.reader?.collectLayoutGapProbe?.('ebookViewerLoaded', {
                bookDir: globalThis.reader?.bookDir || null,
                isRTL: !!globalThis.reader?.isRTL,
            }) ?? null;
            window.webkit.messageHandlers.ebookViewerLoaded.postMessage({
                probe,
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
            postReaderLog('ebook.viewer.load.error', {
                message: error?.message || String(error),
            });
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

const markRestorePositionSaveUserInput = (eventOrSource) => {
    if (globalThis.__manabiRequireUserInputBeforePositionSave !== true) {
        return;
    }
    const eventType = typeof eventOrSource === 'string'
        ? eventOrSource
        : (eventOrSource?.type ?? null);
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
        postPageNumLog('restore.last-position', {
            stage,
            requestedHasCFI: typeof cfi === 'string' && cfi.length > 0,
            requestedFraction: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
            landedFraction: typeof currentFraction === 'number' ? safeRound(currentFraction, 6) : null,
            landedSectionIndex: sectionIndex,
            landedLocationCurrent: locationCurrent,
            landedLocationTotal: locationTotal,
            landedCFI: detail?.cfi ?? null,
            ...extra,
        });
        return {
            detail,
            currentFraction,
            locationCurrent,
            locationTotal,
            sectionIndex,
        };
    };
    const postRestoreMarkReadLog = (stage, restoreState, extra = {}) => {
        const requestedFraction = Number.isFinite(fractionalCompletion)
            ? Math.max(0, Math.min(1, fractionalCompletion))
            : null;
        const landedFraction = typeof restoreState?.currentFraction === 'number'
            ? Math.max(0, Math.min(1, restoreState.currentFraction))
            : null;
    };
    postReaderLog('ebook.viewer.loadLastPosition.start', {
        hasCFI: typeof cfi === 'string' && cfi.length > 0,
        fractionalCompletion: Number.isFinite(fractionalCompletion) ? fractionalCompletion : 'nil',
    });
    postPageNumLog('restore.request', {
        hasCFI: typeof cfi === 'string' && cfi.length > 0,
        cfiLength: typeof cfi === 'string' ? cfi.length : 0,
        fractionalCompletion: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
    });
    const hasFractionalCompletion = Number.isFinite(fractionalCompletion) && fractionalCompletion > 0;
    const syntheticRestoreLocator = parseSyntheticRestoreLocator(cfi);
    const restoreLocatorKind = syntheticRestoreLocator
        ? 'synthetic'
        : (typeof cfi === 'string' && cfi.length > 0 ? 'cfi' : (hasFractionalCompletion ? 'fraction' : 'none'));
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
        postPageNumLog('restore.reconcile.fraction', {
            reason,
            drift: safeRound(delta, 6),
            fromFraction: safeRound(restoreState.currentFraction, 6),
            toFraction: safeRound(fractionalCompletion, 6),
            sectionIndex: restoreState.sectionIndex,
        });
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
        postRestoreMarkReadLog(stageOnReconcile, reconciledState, {
            reconciled: true,
            drift: safeRound(delta, 6),
        });
    };
    try {
        if (syntheticRestoreLocator && hasFractionalCompletion) {
            postReaderLog('ebook.viewer.loadLastPosition.path', {
                mode: 'fraction-for-synthetic-locator',
                sectionIndex: syntheticRestoreLocator.sectionIndex,
                localSectionIndex: syntheticRestoreLocator.localSectionIndex,
                rendererTotal: syntheticRestoreLocator.rendererTotal,
                fractionInSection: safeRound(syntheticRestoreLocator.fractionInSection, 6),
            });
            await runWithNavigationIntent({
                source: 'restore.synthetic-fraction',
                target: 'view.goToFraction',
                fraction: fractionalCompletion,
                syntheticSectionIndex: syntheticRestoreLocator.sectionIndex,
                syntheticLocalSectionIndex: syntheticRestoreLocator.localSectionIndex,
                syntheticRendererTotal: syntheticRestoreLocator.rendererTotal,
            }, () => globalThis.reader.view.goToFraction(fractionalCompletion));
            await waitForFrames(2);
            const fractionState = captureRestoreState('after-synthetic-fraction', {
                sectionIndex: syntheticRestoreLocator.sectionIndex,
                localSectionIndex: syntheticRestoreLocator.localSectionIndex,
                rendererTotal: syntheticRestoreLocator.rendererTotal,
            });
            postRestoreMarkReadLog('after-synthetic-fraction', fractionState);
        } else if (syntheticRestoreLocator) {
            postReaderLog('ebook.viewer.loadLastPosition.path', {
                mode: 'synthetic-locator',
                sectionIndex: syntheticRestoreLocator.sectionIndex,
                localSectionIndex: syntheticRestoreLocator.localSectionIndex,
                rendererTotal: syntheticRestoreLocator.rendererTotal,
                fractionInSection: safeRound(syntheticRestoreLocator.fractionInSection, 6),
            });
            postPageNumLog('restore.synthetic-locator', {
                sectionIndex: syntheticRestoreLocator.sectionIndex,
                localSectionIndex: syntheticRestoreLocator.localSectionIndex,
                rendererTotal: syntheticRestoreLocator.rendererTotal,
                fractionInSection: safeRound(syntheticRestoreLocator.fractionInSection, 6),
            });
            await runWithNavigationIntent({
                source: 'restore.synthetic-locator',
                target: 'renderer.goTo',
                sectionIndex: syntheticRestoreLocator.sectionIndex,
                anchor: syntheticRestoreLocator.fractionInSection,
                syntheticLocalSectionIndex: syntheticRestoreLocator.localSectionIndex,
                syntheticRendererTotal: syntheticRestoreLocator.rendererTotal,
            }, () => globalThis.reader.view.renderer.goTo({
                index: syntheticRestoreLocator.sectionIndex,
                anchor: syntheticRestoreLocator.fractionInSection,
            }));
            await waitForFrames(2);
            const syntheticState = captureRestoreState('after-synthetic-locator', {
                sectionIndex: syntheticRestoreLocator.sectionIndex,
                localSectionIndex: syntheticRestoreLocator.localSectionIndex,
                rendererTotal: syntheticRestoreLocator.rendererTotal,
            });
            postRestoreMarkReadLog('after-synthetic-locator', syntheticState);
        } else if (cfi.length > 0) {
            postReaderLog('ebook.viewer.loadLastPosition.path', {
                mode: 'cfi',
            });
            await runWithNavigationIntent({
                source: 'restore.cfi',
                target: 'view.goTo',
                cfiLength: cfi.length,
                fraction: hasFractionalCompletion ? fractionalCompletion : null,
            }, () => globalThis.reader.view.goTo(cfi)).catch(async e => {
                postPageNumLog('restore.cfi.error', {
                    message: e?.message || String(e),
                    fallback: hasFractionalCompletion ? 'fraction-fallback' : null,
                });
                postReaderLog('ebook.viewer.loadLastPosition.goToError', {
                    hasCFI: true,
                    message: e?.message || String(e),
                });
                console.error(e)
                if (hasFractionalCompletion) {
                    postReaderLog('ebook.viewer.loadLastPosition.path', {
                        mode: 'fraction-fallback',
                    });
                    await runWithNavigationIntent({
                        source: 'restore.cfi-fallback',
                        target: 'view.goToFraction',
                        fraction: fractionalCompletion,
                    }, () => globalThis.reader.view.goToFraction(fractionalCompletion))
                }
            });
            await waitForFrames(2);
            const cfiState = captureRestoreState('after-cfi');
            postRestoreMarkReadLog('after-cfi', cfiState);
            await reconcileRestoreFractionIfNeeded(
                cfiState,
                'cfi-fraction-drift',
                'after-cfi-fraction-reconcile',
            );
        } else if (hasFractionalCompletion) {
            postReaderLog('ebook.viewer.loadLastPosition.path', {
                mode: 'fraction',
            });
            try {
                await runWithNavigationIntent({
                    source: 'restore.fraction',
                    target: 'view.goToFraction',
                    fraction: fractionalCompletion,
                }, () => globalThis.reader.view.goToFraction(fractionalCompletion));
                await waitForFrames(2);
                const fractionState = captureRestoreState('after-fraction');
                postRestoreMarkReadLog('after-fraction', fractionState);
            } catch (error) {
                postPageNumLog('restore.fraction.error', {
                    message: error?.message || String(error),
                    fallback: 'default-next',
                });
                postReaderLog('ebook.viewer.loadLastPosition.goToError', {
                    hasCFI: false,
                    mode: 'fraction',
                    message: error?.message || String(error),
                    fallback: 'default-next',
                });
                try {
                    await awaitWithTimeout(globalThis.reader.view.renderer.next(), 1500);
                } catch (nextError) {
                    postReaderLog('ebook.viewer.loadLastPosition.goToError', {
                        hasCFI: false,
                        mode: 'default-next',
                        message: nextError?.message || String(nextError),
                        fallback: 'nextSection',
                    });
                    await globalThis.reader.view.renderer.nextSection();
                }
                postReaderLog('ebook.viewer.loadLastPosition.afterNext', {
                    mode: 'default-next',
                });
                await waitForFrames(2);
                const fallbackState = captureRestoreState('after-default-next-fallback');
                postRestoreMarkReadLog('after-default-next-fallback', fallbackState);
            }
        } else {
            postReaderLog('ebook.viewer.loadLastPosition.path', {
                mode: 'default-next',
            });
            try {
                await awaitWithTimeout(globalThis.reader.view.renderer.next(), 1500);
            } catch (error) {
                postReaderLog('ebook.viewer.loadLastPosition.goToError', {
                    hasCFI: false,
                    mode: 'default-next',
                    message: error?.message || String(error),
                    fallback: 'nextSection',
                });
                await globalThis.reader.view.renderer.nextSection();
            }
            postReaderLog('ebook.viewer.loadLastPosition.afterNext', {
                mode: 'default-next',
            });
            await waitForFrames(2);
            const defaultState = captureRestoreState('after-default-next');
            postRestoreMarkReadLog('after-default-next', defaultState);
        }
        globalThis.reader.hasLoadedLastPosition = true
        const doneState = captureRestoreState('done');
        globalThis.reader?.maybeFlashInitialForwardSideNavChevron?.(doneState);
        postLandscapeInsetRestoreProbe('done', doneState, {
            hasCFI: typeof cfi === 'string' && cfi.length > 0,
            requestedFraction: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
        });
        postRestoreMarkReadLog('done', doneState);
        postReaderLog('ebook.viewer.loadLastPosition.done', {
            hasCFI: typeof cfi === 'string' && cfi.length > 0,
        });
        postReplaceTextPerfLog('restore.done', {
            hasCFI: typeof cfi === 'string' && cfi.length > 0,
            ...captureEPUBOverlapState(),
        });

        // Let the visible section finish rendering before warming secondary sections.
        scheduleDeferredCacheWarmerOpen('load-last-position-done', 2200);
    } finally {
        globalThis.__manabiRestoreInProgress = false;
        globalThis.__manabiSuppressNextRestoreRelocateSave = false;
        globalThis.__manabiRequireUserInputBeforePositionSave = true;
    }
}

window.refreshBookReadingProgress = async (articleReadingProgress) => {
    if (!globalThis.reader) {
        postReaderLog('ebook.pageTracking.progressRefresh.skip', {
            reason: 'missing-reader',
        });
        return;
    }
    const normalizedProgress = normalizeArticleReadingProgress(articleReadingProgress);
    postReaderLog('ebook.pageTracking.progressRefresh.received', {
        articleMarkedAsFinished: normalizedProgress.articleMarkedAsFinished,
        sentenceIdentifiersRead: normalizedProgress.sentenceIdentifiersRead.length,
        readSegmentIdentifiers: normalizedProgress.readSegmentIdentifiers.length,
        articleSentenceCount: normalizedProgress.articleSentenceCount,
    });
    globalThis.reader.applyBookReadingProgress(articleReadingProgress, 'native-refresh');
    await globalThis.reader.updateNavButtons();
}

window.manabiToggleReaderTableOfContents = () => {
    globalThis.reader?.toggleTableOfContents?.();
}

window.manabiHandlePhysicalArrowKey = async (direction) => {
    return await globalThis.reader?.handlePhysicalArrowKey?.(direction) ?? false;
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
    markRestorePositionSaveUserInput('bridge.scheduleReaderFractionGoTo');
    postPageNumLog('goto.live-schedule.request', {
        requestedFraction: typeof fraction === 'number' && Number.isFinite(fraction) ? fraction : null,
    });
    globalThis.reader?.scheduleGoToFraction?.(fraction);
}

window.manabiCancelScheduledReaderFractionGoTo = () => {
    globalThis.reader?.scheduleGoToFraction?.cancel?.();
    postPageNumLog('goto.live-schedule.cancel', {
        navLabel: globalThis.reader?.navHUD?.latestPrimaryLabel ?? '',
    });
    return true;
}

const postEBookJumpLog = (event, payload = {}) => {
    const cleanedEntries = Object.entries({
        timestamp: Date.now(),
        ...payload,
    }).filter(([, value]) => value !== undefined && value !== null);
    const metadata = cleanedEntries.length ? JSON.stringify(Object.fromEntries(cleanedEntries)) : '';
    const line = metadata ? `# EBOOKJUMP ${event} ${metadata}` : `# EBOOKJUMP ${event}`;
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_error) {
        // optional handler
    }
    try {
        console.log(line);
    } catch (_error) {
        // optional console
    }
};

window.manabiBeginReaderProgressScrub = () => {
    markRestorePositionSaveUserInput('bridge.beginReaderProgressScrub');
    const navHUD = globalThis.reader?.navHUD;
    if (navHUD?.scrubSession?.active) {
        postEBookJumpLog('scrub-begin-request', {
            skipped: true,
            reason: 'already-active',
            currentDescriptor: navHUD?._serializeDescriptorForJumpLog?.(navHUD?.getCurrentLocationDescriptor?.() ?? null) ?? null,
            backDepth: navHUD?.relocateStacks?.back?.length ?? 0,
            forwardDepth: navHUD?.relocateStacks?.forward?.length ?? 0,
        });
        postPageNumLog('goto.live-scrub.begin.skipped', {
            reason: 'already-active',
            backDepth: navHUD?.relocateStacks?.back?.length ?? 0,
            forwardDepth: navHUD?.relocateStacks?.forward?.length ?? 0,
        });
        return true;
    }
    const originDescriptor = navHUD?.getCurrentLocationDescriptor?.() ?? null;
    postEBookJumpLog('scrub-begin-request', {
        skipped: false,
        originDescriptor: navHUD?._serializeDescriptorForJumpLog?.(originDescriptor) ?? null,
        currentDescriptor: navHUD?._serializeDescriptorForJumpLog?.(navHUD?.currentLocationDescriptor ?? null) ?? null,
        backDepth: navHUD?.relocateStacks?.back?.length ?? 0,
        forwardDepth: navHUD?.relocateStacks?.forward?.length ?? 0,
    });
    postPageNumLog('goto.live-scrub.begin', {
        originFraction: typeof originDescriptor?.fraction === 'number' ? safeRound(originDescriptor.fraction, 6) : null,
        backDepth: navHUD?.relocateStacks?.back?.length ?? 0,
        forwardDepth: navHUD?.relocateStacks?.forward?.length ?? 0,
    });
    navHUD?.beginProgressScrubSession?.(originDescriptor);
    return true;
}

window.manabiEndReaderProgressScrub = async (fraction, cancel = false) => {
    markRestorePositionSaveUserInput(cancel ? 'bridge.endReaderProgressScrub.cancel' : 'bridge.endReaderProgressScrub.commit');
    const navHUD = globalThis.reader?.navHUD;
    const view = globalThis.reader?.view;
    globalThis.reader?.scheduleGoToFraction?.cancel?.();
    postPageNumLog('goto.live-schedule.cancel', {
        navLabel: globalThis.reader?.navHUD?.latestPrimaryLabel ?? '',
        reason: 'scrub-end',
    });
    const numericFraction = Number(fraction);
    const clampedFraction = Number.isFinite(numericFraction)
        ? Math.max(0, Math.min(1, numericFraction))
        : null;
    const finalDescriptor = clampedFraction != null
        ? (navHUD?._descriptorFromFraction?.(clampedFraction) ?? { fraction: clampedFraction })
        : (navHUD?.getCurrentLocationDescriptor?.() ?? null);
    postEBookJumpLog('scrub-end-request', {
        cancel: !!cancel,
        requestedFraction: clampedFraction,
        currentDescriptor: navHUD?._serializeDescriptorForJumpLog?.(navHUD?.getCurrentLocationDescriptor?.() ?? null) ?? null,
        finalDescriptor: navHUD?._serializeDescriptorForJumpLog?.(finalDescriptor) ?? null,
        pendingReleasedScrubDescriptor: navHUD?._serializeDescriptorForJumpLog?.(navHUD?.pendingReleasedScrubDescriptor ?? null) ?? null,
        scrubActive: !!navHUD?.scrubSession?.active,
        backDepth: navHUD?.relocateStacks?.back?.length ?? 0,
        forwardDepth: navHUD?.relocateStacks?.forward?.length ?? 0,
    });
    postPageNumLog('goto.live-scrub.end', {
        requestedFraction: clampedFraction,
        cancel: !!cancel,
        backDepthBefore: navHUD?.relocateStacks?.back?.length ?? 0,
        forwardDepthBefore: navHUD?.relocateStacks?.forward?.length ?? 0,
    });
    const finalizeScrubSession = () => {
        postEBookJumpLog('scrub-end-finalize', {
            cancel: !!cancel,
            requestedFraction: clampedFraction,
            currentDescriptor: navHUD?._serializeDescriptorForJumpLog?.(navHUD?.getCurrentLocationDescriptor?.() ?? null) ?? null,
            pendingReleasedScrubDescriptor: navHUD?._serializeDescriptorForJumpLog?.(navHUD?.pendingReleasedScrubDescriptor ?? null) ?? null,
            scrubActive: !!navHUD?.scrubSession?.active,
            backDepth: navHUD?.relocateStacks?.back?.length ?? 0,
            forwardDepth: navHUD?.relocateStacks?.forward?.length ?? 0,
        });
        navHUD?.endProgressScrubSession?.(finalDescriptor, {
            cancel: !!cancel,
            releaseFraction: clampedFraction,
        });
    };
    if (!cancel && Number.isFinite(clampedFraction) && view) {
        postEBookJumpLog('scrub-release-request', {
            requestedFraction: clampedFraction,
            currentDescriptor: navHUD?._serializeDescriptorForJumpLog?.(navHUD?.getCurrentLocationDescriptor?.() ?? null) ?? null,
            targetDescriptor: navHUD?._serializeDescriptorForJumpLog?.(finalDescriptor) ?? null,
            backDepth: navHUD?.relocateStacks?.back?.length ?? 0,
            forwardDepth: navHUD?.relocateStacks?.forward?.length ?? 0,
        });
        try {
            navHUD?.requestExplicitRelocateHistoryMutation?.('scrub-release');
            await runWithNavigationIntent({
                source: 'scrub-release',
                target: 'view.goToFraction',
                fraction: clampedFraction,
            }, () => view.goToFraction(clampedFraction));
            postEBookJumpLog('scrub-release-resolved', {
                requestedFraction: clampedFraction,
                currentDescriptor: navHUD?._serializeDescriptorForJumpLog?.(navHUD?.getCurrentLocationDescriptor?.() ?? null) ?? null,
                pendingReleasedScrubDescriptor: navHUD?._serializeDescriptorForJumpLog?.(navHUD?.pendingReleasedScrubDescriptor ?? null) ?? null,
                backDepth: navHUD?.relocateStacks?.back?.length ?? 0,
                forwardDepth: navHUD?.relocateStacks?.forward?.length ?? 0,
            });
            postPageNumLog('goto.live-scrub.release.resolved', {
                requestedFraction: clampedFraction,
                navLabel: navHUD?.latestPrimaryLabel ?? '',
            });
            finalizeScrubSession();
        } catch (error) {
            postEBookJumpLog('scrub-release-error', {
                requestedFraction: clampedFraction,
                message: error?.message ?? String(error),
                currentDescriptor: navHUD?._serializeDescriptorForJumpLog?.(navHUD?.getCurrentLocationDescriptor?.() ?? null) ?? null,
                backDepth: navHUD?.relocateStacks?.back?.length ?? 0,
                forwardDepth: navHUD?.relocateStacks?.forward?.length ?? 0,
            });
            postPageNumLog('goto.live-scrub.release.error', {
                requestedFraction: clampedFraction,
                message: error?.message ?? String(error),
            });
            finalizeScrubSession();
            console.error(error);
        }
    } else {
        finalizeScrubSession();
    }
    postPageNumLog('goto.live-scrub.end.result', {
        requestedFraction: clampedFraction,
        cancel: !!cancel,
        backDepthAfter: navHUD?.relocateStacks?.back?.length ?? 0,
        forwardDepthAfter: navHUD?.relocateStacks?.forward?.length ?? 0,
        canJumpBack: !!navHUD?._isRelocateButtonVisible?.('back'),
        canJumpForward: !!navHUD?._isRelocateButtonVisible?.('forward'),
    });
    return true;
}

window.manabiTriggerReaderRelocateJump = async (direction) => {
    const navHUD = globalThis.reader?.navHUD;
    postPageNumLog('goto.sheet.relocate-jump.request', {
        direction: typeof direction === 'string' ? direction : null,
        backDepth: navHUD?.relocateStacks?.back?.length ?? 0,
        forwardDepth: navHUD?.relocateStacks?.forward?.length ?? 0,
        canJumpBack: !!navHUD?._isRelocateButtonVisible?.('back'),
        canJumpForward: !!navHUD?._isRelocateButtonVisible?.('forward'),
    });
    if (direction !== 'back' && direction !== 'forward') {
        return false;
    }
    await navHUD?._handleRelocateJump?.(direction);
    postPageNumLog('goto.sheet.relocate-jump.result', {
        direction,
        backDepth: navHUD?.relocateStacks?.back?.length ?? 0,
        forwardDepth: navHUD?.relocateStacks?.forward?.length ?? 0,
        canJumpBack: !!navHUD?._isRelocateButtonVisible?.('back'),
        canJumpForward: !!navHUD?._isRelocateButtonVisible?.('forward'),
    });
    return true;
}

window.manabiScheduleReaderPercentGoTo = (percent) => {
    const numericPercent = Number(percent);
    if (!Number.isFinite(numericPercent)) {
        return;
    }
    postPageNumLog('goto.live-schedule.request-percent', {
        requestedPercent: numericPercent,
        requestedFraction: numericPercent / 100,
    });
    globalThis.reader?.scheduleGoToFraction?.(numericPercent / 100);
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
postReaderLog('ebook.viewer.js.version', {
    version: 'replace-text-summary-v1',
});
