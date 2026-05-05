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

window.onerror = function(msg, source, lineno, colno, error) {
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
    if (!shouldPostReplaceTextPerfLog(event, details)) return;
    if (window.webkit?.messageHandlers?.print) {
        window.webkit.messageHandlers.print.postMessage({
            prefix: '# REPLACETEXT',
            event,
            ...details,
        });
    }
};

const postBookRotateLog = (event, details = {}) => {
    const payload = { event, timestamp: Date.now(), ...details };
    const line = `# BOOKROTATE ${JSON.stringify(payload)}`;
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_error) {
        try { console.log(line); } catch (_) {}
    }
};

const PAGE_NUM_DEDUP_EVENTS = new Set([
    'goto.snapshot',
    'nav.sections.handoff',
    'nav.visibility.updateNavButtons',
]);
const lastPageNumLogSignatureByEvent = new Map();

const postPageNumLog = (event, details = {}) => {
    const payload = { event, ...details };
    if (PAGE_NUM_DEDUP_EVENTS.has(event)) {
        const signature = JSON.stringify(payload);
        if (lastPageNumLogSignatureByEvent.get(event) === signature) {
            return;
        }
        lastPageNumLogSignatureByEvent.set(event, signature);
    }
    const line = `# PAGENUM ${JSON.stringify(payload)}`;
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_error) {
        try { console.log(line); } catch (_) {}
    }
};

const postEbookRestoreLog = (event, details = {}) => {
    const payload = {
        event,
        timestamp: Date.now(),
        ...details,
    };
    const line = `# EBOOKRESTORE ${JSON.stringify(payload)}`;
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
    'hideNavigation.bridge',
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

const postMarkReadLog = (event, details = {}) => {
    if (!MARKREAD_ALLOWED_EVENTS.has(event)) {
        return;
    }
    const compactDetails = compactMarkReadDetails(event, details);
    if (MARKREAD_DEDUP_EVENTS.has(event)) {
        const signature = JSON.stringify(markReadLogSignatureDetails(event, compactDetails));
        if (lastMarkReadLogSignatureByEvent.get(event) === signature) {
            return;
        }
        lastMarkReadLogSignatureByEvent.set(event, signature);
    }
    const payload = {
        event,
        timestamp: Date.now(),
        ...compactDetails,
    };
    const line = `# MARKREAD ${JSON.stringify(payload)}`;
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

const REPLACE_TEXT_RESULT_CACHE_LIMIT = 64;
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
        postEPUBLog('ebook.perf.replace-text.cache-hit', {
            href,
            mediaType,
            isCacheWarmer: !!isCacheWarmer,
            cacheKey,
            sourceCacheKey: resultCacheKey,
            responseTextLength: typeof cachedHTML === 'string' ? cachedHTML.length : null,
            ...captureEPUBOverlapState(),
        });
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
        postEPUBLog('ebook.perf.replace-text.cache-wait', {
            href,
            mediaType,
            isCacheWarmer: !!isCacheWarmer,
            cacheKey,
            sourceCacheKey: inFlightCacheKey,
            ...captureEPUBOverlapState(),
        });
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
        const normalizedHref = normalizeSpineHref(href);
        if (normalizedHref && !firstLiveSectionHref()) {
            globalThis.__manabiFirstLiveSectionHref = normalizedHref;
            postEPUBLog('ebook.perf.live-first-section.recorded', {
                href: normalizedHref,
                ...captureEPUBOverlapState(),
            });
            postReplaceTextPerfLog('live-first-section.recorded', {
                href: normalizedHref,
                ...captureEPUBOverlapState(),
            });
        }
    }
    if (isCacheWarmer) {
        globalThis.__manabiInflightCacheWarmerReplaceTextCount = (globalThis.__manabiInflightCacheWarmerReplaceTextCount ?? 0) + 1;
    }
    postEPUBLog('ebook.perf.replace-text.start', {
        href,
        mediaType,
        isCacheWarmer: !!isCacheWarmer,
        requestTextLength: typeof text === 'string' ? text.length : null,
        ...captureEPUBOverlapState(),
    });
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
        postEPUBLog('ebook.perf.replace-text.response', {
            href,
            mediaType,
            isCacheWarmer: !!isCacheWarmer,
            status: response.status,
            responseOk: response.ok,
            headersElapsedMs: safeRound(performanceNowMs() - replaceTextStartedAt, 1),
            elapsedMs: safeRound(performanceNowMs() - replaceTextStartedAt, 1),
            ...captureEPUBOverlapState(),
        });
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
        postEPUBLog('ebook.perf.replace-text.end', {
            href,
            mediaType,
            isCacheWarmer: !!isCacheWarmer,
            status: response.status,
            sentenceCount,
            segmentCount,
            responseTextLength: html.length,
            responseBodyReadMs: bodyReadElapsedMs,
            responseTransformMs: transformElapsedMs,
            inputToOutputRatio: typeof text === 'string' && text.length > 0
                ? safeRound(html.length / text.length, 3)
                : null,
            responseExpansionRatio: responseTextLength > 0
                ? safeRound(html.length / responseTextLength, 3)
                : null,
            elapsedMs: safeRound(performanceNowMs() - replaceTextStartedAt, 1),
            ...captureEPUBOverlapState(),
        });
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
            markEPUBPerf('replace-text.first-non-cache', {
                href,
                sentenceCount,
                segmentCount,
                responseBodyReadMs: bodyReadElapsedMs,
                responseTransformMs: transformElapsedMs,
                responseTextLength,
                inputToOutputRatio: typeof text === 'string' && text.length > 0
                    ? safeRound(html.length / text.length, 3)
                    : null,
                elapsedMs: safeRound(performanceNowMs() - replaceTextStartedAt, 1),
                ...captureEPUBOverlapState(),
            }, {
                once: true,
            });
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
        postEPUBLog('ebook.perf.replace-text.error', {
            href,
            mediaType,
            isCacheWarmer: !!isCacheWarmer,
            elapsedMs: safeRound(performanceNowMs() - replaceTextStartedAt, 1),
            message: error?.message || String(error),
            ...captureEPUBOverlapState(),
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

const postEPUBLog = (event, details = {}) => {
    if (!manabiDiagnosticsEnabled()) return;
    const payload = {
        prefix: '# EPUB',
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
        if (manabiDiagnosticsEnabled()) console.debug('# EPUB', event, details, error);
    }
};

const postEPUBLoadLog = (event, details = {}) => {
    const payload = {
        event,
        timestamp: Date.now(),
        sessionID: currentEPUBPerfSession?.id ?? null,
        ...details,
    };
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.(`# EPUBLOAD ${JSON.stringify(payload)}`);
    } catch (error) {
        try { console.log('# EPUBLOAD', event, details, error); } catch (_error) {}
    }
};
globalThis.__manabiPostEPUBLoadLog = postEPUBLoadLog;

const postShortLineLog = (event, details = {}) => {
    const payload = {
        event,
        timestamp: Date.now(),
        ...details,
    };
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.(`# SHORTLINE ${JSON.stringify(payload)}`);
    } catch (error) {
        try { console.log('# SHORTLINE', event, details, error); } catch (_error) {}
    }
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
        sessionID: currentEPUBPerfSession?.id ?? null,
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
        readerBodyTextLength: readerBody?.innerText?.length ?? null,
        readerDocumentClientWidth: readerRoot?.clientWidth ?? null,
        readerDocumentClientHeight: readerRoot?.clientHeight ?? null,
        readerDocumentScrollWidth: readerRoot?.scrollWidth ?? null,
        readerDocumentScrollHeight: readerRoot?.scrollHeight ?? null,
        ...extra,
    };
};

const isCacheWarmerDocument = (doc) => doc?.body?.dataset?.isCacheWarmer === 'true';

const captureEPUBOverlapState = () => ({
    inflightReplaceTextCount: globalThis.__manabiInflightReplaceTextCount ?? 0,
    inflightCacheWarmerReplaceTextCount: globalThis.__manabiInflightCacheWarmerReplaceTextCount ?? 0,
    cacheWarmerOpenInFlight: !!globalThis.__manabiCacheWarmerOpenInFlight,
    cacheWarmerReady: !!globalThis.__manabiCacheWarmerReady,
    cacheWarmerFinished: !!globalThis.__manabiCacheWarmerFinished,
    cacheWarmerHighestSectionIndex: globalThis.__manabiCacheWarmerHighestSectionIndex ?? null,
});

const summarizeDocumentFontState = (doc) => ({
    fontStatus: doc?.fonts?.status ?? 'unsupported',
    hasFontsAPI: !!doc?.fonts,
    readyState: doc?.readyState ?? 'nil',
    isCacheWarmerDocument: isCacheWarmerDocument(doc),
});

const captureDocumentFontApplicationState = (doc) => {
    if (!doc?.defaultView) {
        return {
            computedFontFamily: null,
            sampleTag: null,
            sampleText: null,
        };
    }
    const sample =
        doc.body?.querySelector?.('p, li, div, span, ruby, mnb-sen, mnb-seg')
        || doc.body
        || doc.documentElement
        || null;
    let computedFontFamily = null;
    try {
        computedFontFamily = sample
            ? doc.defaultView.getComputedStyle(sample).fontFamily
            : null;
    } catch {}
    return {
        computedFontFamily,
        sampleTag: sample?.tagName || null,
        sampleText: sample?.textContent?.trim?.()?.slice?.(0, 60) || null,
        injectedFontFamily: doc.documentElement?.dataset?.mnbInjectedFontFamily ?? null,
        fontInjected: doc.documentElement?.dataset?.mnbFontInjected ?? null,
    };
};

const postFontLog = (event, details = {}) => {
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.('# FONT ' + JSON.stringify({
            event,
            timestamp: Date.now(),
            ...details,
        }));
    } catch {}
};

const postEPUBFlashLog = (event, details = {}) => {
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.('# EPUBFLASH ' + JSON.stringify({
            event,
            timestamp: Date.now(),
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
            ...details,
        }));
    } catch {}
};

const postMay4Log = (event, details = {}) => {
    if (!globalThis.manabiDebugMay4PageTrackingEnabled) return;
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.('# MAY4 ' + JSON.stringify({
            event,
            timestamp: Date.now(),
            ...details,
        }));
    } catch {}
};

const resolveFoliatePaginator = (view = null) => {
    const renderer = view?.renderer || null;
    if (renderer?.localName === 'foliate-paginator') return renderer;
    return renderer?.querySelector?.('foliate-paginator')
        || view?.shadowRoot?.querySelector?.('foliate-paginator')
        || null;
};

const collectMay4DocumentState = (doc = null) => {
    const body = doc?.body || null;
    const firstSegment = doc?.querySelector?.('mnb-seg') || null;
    const firstTrackingSection = doc?.querySelector?.('.mnb-tracking-section') || null;
    const firstLearningSegment = doc?.querySelector?.('mnb-seg.mnb-tracking-learning') || null;
    const firstHighlightedSegment = doc?.querySelector?.(
        'mnb-seg.mnb-tracking-learning, mnb-seg.mnb-tracking-read, mnb-seg.mnb-tracking-known, mnb-seg.mnb-tracking-unseen-flashcard'
    ) || null;
    const highlightedStyle = firstHighlightedSegment ? doc.defaultView?.getComputedStyle?.(firstHighlightedSegment) : null;
    const firstSegmentMetadata = segmentMetadataForNode(firstSegment);
    return {
        documentURL: doc?.URL || doc?.location?.href || null,
        readyState: doc?.readyState || null,
        bodyClassName: body?.className || null,
        bodyTextLength: body?.innerText?.length ?? null,
        trackingEnabled: body?.getAttribute?.('data-mnb-tracking-enabled') ?? null,
        trackingHighlightsEnabled: body?.getAttribute?.('data-mnb-tracking-highlights-enabled') ?? null,
        subscriptionIsActive: body?.getAttribute?.('data-mnb-subscription-is-active') ?? null,
        learningStatusVisibility: body?.getAttribute?.('data-mnb-learning-status-visibility') ?? null,
        segmentCount: doc?.querySelectorAll?.('mnb-seg')?.length ?? null,
        sentenceCount: doc?.querySelectorAll?.('mnb-sen')?.length ?? null,
        segmentMetadataCount: segmentMetadataBootstrap(doc).byID.size,
        trackingSectionCount: doc?.querySelectorAll?.('.mnb-tracking-section')?.length ?? null,
        learningCount: doc?.querySelectorAll?.('mnb-seg.mnb-tracking-learning')?.length ?? null,
        readCount: doc?.querySelectorAll?.('mnb-seg.mnb-tracking-read')?.length ?? null,
        knownCount: doc?.querySelectorAll?.('mnb-seg.mnb-tracking-known')?.length ?? null,
        unseenFlashcardCount: doc?.querySelectorAll?.('mnb-seg.mnb-tracking-unseen-flashcard')?.length ?? null,
        firstSegmentClassName: firstSegment?.className || null,
        firstSegmentID: firstSegment?.id || null,
        firstSegmentSearchString: firstSegmentMetadata?.s || firstSegmentMetadata?.ns || null,
        firstSegmentEntryIDCount: (firstSegmentMetadata?.j?.length || 0) + (firstSegmentMetadata?.n?.length || 0),
        firstTrackingSectionKind: firstTrackingSection?.getAttribute?.('data-mnb-tracking-section-kind') ?? null,
        firstTrackingSectionRead: firstTrackingSection?.getAttribute?.('data-mnb-tracking-section-read') ?? null,
        firstLearningSegmentClassName: firstLearningSegment?.className || null,
        firstHighlightedSegmentClassName: firstHighlightedSegment?.className || null,
        firstHighlightedBackground: highlightedStyle?.backgroundColor ?? null,
        firstHighlightedBoxShadow: highlightedStyle?.boxShadow ?? null,
    };
};

const collectMay4ButtonState = () => {
    const container = document.getElementById('page-tracking-container');
    const host = document.getElementById('page-tracking-buttons');
    const button = document.querySelector('#page-tracking-buttons .page-read-button[data-page-tracking-id="visible-screen"], #page-tracking-buttons .page-read-button[data-completion-action]');
    const buttonStyle = button instanceof Element ? getComputedStyle(button) : null;
    const label = button?.querySelector?.('.mnb-tracking-button-label') || null;
    const labelStyle = label instanceof Element ? getComputedStyle(label) : null;
    const rootStyle = getComputedStyle(document.documentElement);
    const rect = button?.getBoundingClientRect?.() || null;
    return {
        containerExists: container instanceof HTMLElement,
        hostExists: host instanceof HTMLElement,
        containerHidden: container?.hidden ?? null,
        hostHidden: host?.hidden ?? null,
        buttonExists: button instanceof HTMLElement,
        buttonRect: rect ? {
            x: Math.round(rect.x),
            y: Math.round(rect.y),
            width: Math.round(rect.width),
            height: Math.round(rect.height),
        } : null,
        buttonReadAttr: button?.getAttribute?.('data-mnb-tracking-section-read') ?? null,
        buttonReadState: button?.getAttribute?.('data-read-state') ?? null,
        buttonCompletionAction: button?.getAttribute?.('data-completion-action') ?? null,
        buttonDisabled: button instanceof HTMLButtonElement ? button.disabled : null,
        buttonFontFamily: buttonStyle?.fontFamily ?? null,
        buttonDisplay: buttonStyle?.display ?? null,
        buttonVisibility: buttonStyle?.visibility ?? null,
        buttonOpacity: buttonStyle?.opacity ?? null,
        buttonColor: buttonStyle?.color ?? null,
        buttonBackgroundColor: buttonStyle?.backgroundColor ?? null,
        labelFontFamily: labelStyle?.fontFamily ?? null,
        labelText: label?.textContent ?? null,
        uiFontVariable: rootStyle.getPropertyValue('--mnb-ui-font-family')?.trim?.() || null,
        bodyLoading: !!document.body?.classList?.contains?.('loading'),
        navHiddenDueToScroll: !!document.getElementById('nav-bar')?.classList?.contains?.('nav-hidden-due-to-scroll'),
    };
};

const collectMay4DocumentSummary = (doc = null) => ({
    documentURL: doc?.URL || doc?.location?.href || null,
    bodyClassName: doc?.body?.className || null,
    segmentCount: doc?.querySelectorAll?.('mnb-seg')?.length ?? null,
    trackingSectionCount: doc?.querySelectorAll?.('.mnb-tracking-section')?.length ?? null,
});

const getActiveReaderDocument = () => {
    const contents = globalThis.reader?.view?.renderer?.getContents?.() || [];
    return contents[0]?.doc || null;
};

const collectMay4ButtonSummary = () => {
    const button = collectMay4ButtonState();
    return {
        buttonExists: button.buttonExists,
        buttonLabel: button.labelText,
        buttonHidden: button.hostHidden ?? button.containerHidden ?? null,
        completionAction: button.buttonCompletionAction,
        readState: button.buttonReadState,
    };
};

const captureEPUBFlashVisualState = (view = null) => {
    const safeRect = (el) => {
        if (!el || typeof el.getBoundingClientRect !== 'function') return null;
        const rect = el.getBoundingClientRect();
        return {
            left: Number.isFinite(rect.left) ? Number(rect.left.toFixed(1)) : null,
            top: Number.isFinite(rect.top) ? Number(rect.top.toFixed(1)) : null,
            right: Number.isFinite(rect.right) ? Number(rect.right.toFixed(1)) : null,
            bottom: Number.isFinite(rect.bottom) ? Number(rect.bottom.toFixed(1)) : null,
            width: Number.isFinite(rect.width) ? Number(rect.width.toFixed(1)) : null,
            height: Number.isFinite(rect.height) ? Number(rect.height.toFixed(1)) : null,
        };
    };
    const safeStyle = (el) => {
        if (!el || typeof getComputedStyle !== 'function') return null;
        const style = getComputedStyle(el);
        return {
            display: style.display,
            visibility: style.visibility,
            opacity: style.opacity,
            overflow: style.overflow,
            color: style.color,
            backgroundColor: style.backgroundColor,
        };
    };
    const navBar = document.getElementById('nav-bar');
    const readerStage = document.getElementById('reader-stage');
    const resolvedView = view || globalThis.reader?.view || null;
    const renderer = resolvedView?.renderer || null;
    const paginator = resolveFoliatePaginator(resolvedView);
    const paginatorContainer = paginator?.shadowRoot?.getElementById?.('container') || null;
    const frames = Array.from(paginator?.shadowRoot?.querySelectorAll?.('iframe') ?? []);
    const visibleFrame = frames.find((frame) => {
        const rect = frame?.getBoundingClientRect?.();
        return rect && rect.width > 0 && rect.height > 0;
    }) || frames[0] || null;
    const visibleFrameDoc = visibleFrame?.contentDocument || null;
    const visibleFrameBody = visibleFrameDoc?.body || null;
    const rootStyle = getComputedStyle(document.documentElement);
    const currentIntent = globalThis.__manabiEPUBFlashNavigationIntent ?? null;
    return {
        viewport: `${window.innerWidth}x${window.innerHeight}`,
        visualViewport: globalThis.visualViewport
            ? `${Math.round(globalThis.visualViewport.width)}x${Math.round(globalThis.visualViewport.height)}`
            : null,
        cssObscuredTopInset: rootStyle.getPropertyValue('--mnb-obscured-top-inset')?.trim() || null,
        cssObscuredBottomInset: rootStyle.getPropertyValue('--mnb-obscured-bottom-inset')?.trim() || null,
        cssToolbarBottomOffset: rootStyle.getPropertyValue('--mnb-toolbar-bottom-offset')?.trim() || null,
        navHiddenDueToScrollClass: !!navBar?.classList?.contains?.('nav-hidden-due-to-scroll'),
        navBarRect: safeRect(navBar),
        readerStageRect: safeRect(readerStage),
        foliateViewRect: safeRect(resolvedView),
        rendererLocalName: renderer?.localName ?? null,
        rendererRect: safeRect(renderer),
        paginatorRect: safeRect(paginator),
        paginatorStyle: safeStyle(paginator),
        paginatorContainer: paginatorContainer
            ? `${paginatorContainer.clientWidth}x${paginatorContainer.clientHeight}`
            : null,
        paginatorContainerRect: safeRect(paginatorContainer),
        paginatorContainerScroll: paginatorContainer
            ? `${paginatorContainer.scrollWidth}x${paginatorContainer.scrollHeight}`
            : null,
        iframeCount: frames.length,
        visibleFrameRect: safeRect(visibleFrame),
        visibleFrameSrc: visibleFrame?.src || null,
        visibleFrameReadyState: visibleFrameDoc?.readyState || null,
        visibleFrameBodyTextLength: visibleFrameBody?.innerText?.length ?? null,
        visibleFrameBodyScroll: visibleFrameBody
            ? `${visibleFrameBody.scrollWidth}x${visibleFrameBody.scrollHeight}`
            : null,
        visibleFrameBodyStyle: safeStyle(visibleFrameBody),
        rendererPageCurrent: globalThis.reader?.navHUD?.rendererPageSnapshot?.current ?? null,
        rendererPageTotal: globalThis.reader?.navHUD?.rendererPageSnapshot?.total ?? null,
        intentSource: currentIntent?.source ?? null,
        intentReason: currentIntent?.reason ?? null,
    };
};

const auditEPUBAnimations = (reason = 'unknown') => {
    try {
        const animations = typeof document.getAnimations === 'function'
            ? document.getAnimations({ subtree: true })
            : [];
        postEPUBFlashLog('js.animation.audit', {
            reason,
            animationCount: animations.length,
            runningAnimationCount: animations.filter((animation) => animation.playState === 'running').length,
            animations: animations.slice(0, 12).map((animation) => {
                const target = animation.effect?.target ?? null;
                return {
                    playState: animation.playState,
                    currentTime: typeof animation.currentTime === 'number' ? Math.round(animation.currentTime) : null,
                    targetTag: target?.tagName ?? null,
                    targetID: target?.id ?? null,
                    targetClass: typeof target?.className === 'string' ? target.className : null,
                    animationName: target ? getComputedStyle(target).animationName : null,
                };
            }),
        });
    } catch (error) {
        postEPUBFlashLog('js.animation.audit.error', {
            reason,
            message: error?.message ?? String(error),
        });
    }
};

const auditEPUBCompositing = (reason = 'unknown') => {
    try {
        const viewportUnitRegex = /\b\d+(?:\.\d+)?d[vwhib]/i;
        const cssRuleSuspects = [];
        for (const sheet of Array.from(document.styleSheets)) {
            let rules = [];
            try {
                rules = Array.from(sheet.cssRules || []);
            } catch {
                continue;
            }
            for (const rule of rules) {
                const cssText = rule.cssText || '';
                if (
                    cssText.includes('backdrop-filter')
                    || cssText.includes('-webkit-backdrop-filter')
                    || cssText.includes('filter:')
                    || cssText.includes('box-shadow')
                    || viewportUnitRegex.test(cssText)
                ) {
                    cssRuleSuspects.push(cssText.slice(0, 220));
                }
            }
        }
        const collectComposedElements = (root, depth = 0, output = []) => {
            if (!root || depth > 8) return output;
            const elements = root.querySelectorAll ? Array.from(root.querySelectorAll('*')) : [];
            for (const element of elements) {
                output.push({ element, shadowDepth: depth });
                if (element.shadowRoot) {
                    collectComposedElements(element.shadowRoot, depth + 1, output);
                }
            }
            return output;
        };
        const nodeEntries = collectComposedElements(document);
        const nodes = nodeEntries.map(entry => entry.element);
        const fixed = [];
        const filtered = [];
        const transitions = [];
        const shadows = [];
        const dynamicViewport = [];
        for (const node of nodes) {
            const style = getComputedStyle(node);
            const rect = node.getBoundingClientRect?.();
            const visible = style.display !== 'none'
                && style.visibility !== 'hidden'
                && Number.parseFloat(style.opacity || '1') > 0
                && rect
                && rect.width > 0
                && rect.height > 0;
            const summary = {
                tag: node.tagName,
                id: node.id || null,
                className: typeof node.className === 'string' ? node.className : null,
                visible,
                rect: rect ? `${Math.round(rect.width)}x${Math.round(rect.height)}` : null,
            };
            if (style.position === 'fixed') fixed.push(summary);
            const backdropFilter = style.backdropFilter || style.webkitBackdropFilter || 'none';
            if (style.filter !== 'none' || backdropFilter !== 'none') {
                filtered.push({
                    ...summary,
                    filter: style.filter,
                    backdropFilter,
                });
            }
            if (style.transitionProperty !== 'none') {
                const transitionProperties = style.transitionProperty
                    .split(',')
                    .map((property) => property.trim());
                const expensive = transitionProperties.includes('all')
                    ? ['all']
                    : transitionProperties.filter((property) => ['filter', 'backdrop-filter', '-webkit-backdrop-filter', 'box-shadow', 'transform', 'opacity'].includes(property));
                if (expensive.length > 0) {
                    transitions.push({
                        ...summary,
                        transitionProperty: style.transitionProperty,
                        transitionDuration: style.transitionDuration,
                    transitionDelay: style.transitionDelay,
                    });
                }
            }
            if (style.boxShadow !== 'none') {
                shadows.push({
                    ...summary,
                    boxShadow: style.boxShadow.slice(0, 120),
                });
            }
            const inlineStyle = node.getAttribute?.('style') || '';
            if (viewportUnitRegex.test(inlineStyle)) dynamicViewport.push(summary);
        }
        postEPUBFlashLog('js.compositing.audit', {
            reason,
            fixedCount: fixed.length,
            visibleFixedCount: fixed.filter((entry) => entry.visible).length,
            filteredCount: filtered.length,
            transitionSuspectCount: transitions.length,
            shadowCount: shadows.length,
            dynamicViewportInlineStyleCount: dynamicViewport.length,
            cssRuleSuspectCount: cssRuleSuspects.length,
            fixed: fixed.slice(0, 16),
            filtered: filtered.slice(0, 12),
            transitions: transitions.slice(0, 12),
            shadows: shadows.slice(0, 12),
            dynamicViewport: dynamicViewport.slice(0, 12),
            cssRuleSuspects: cssRuleSuspects.slice(0, 20),
        });
    } catch (error) {
        postEPUBFlashLog('js.compositing.audit.error', {
            reason,
            message: error?.message ?? String(error),
        });
    }
};

const runWithEPUBFlashNavigationIntent = async (intent, operation) => {
    const previousIntent = globalThis.__manabiEPUBFlashNavigationIntent ?? null;
    globalThis.__manabiEPUBFlashNavigationIntent = {
        timestamp: Date.now(),
        ...intent,
    };
    try {
        return await operation();
    } finally {
        globalThis.__manabiEPUBFlashNavigationIntent = previousIntent;
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

const copyCustomReaderFontStyleToDocument = (sourceFontStyle, doc, reason = 'unknown') => {
    if (!doc || doc === document) return false;
    if (!sourceFontStyle) {
        postFontLog('ebook.document.fonts.forward.skip', {
            reason: 'missing-outer-custom-font-style',
            forwardReason: reason,
            documentURL: doc?.location?.href || null,
            outerLocation: document?.location?.href || null,
            ebookHasCustomFontStyle: !!doc?.getElementById?.('mnb-custom-fonts-inline'),
            ebookInjectedFontFamily: doc?.documentElement?.dataset?.mnbInjectedFontFamily ?? null,
            ebookFontInjected: doc?.documentElement?.dataset?.mnbFontInjected ?? null,
        });
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
    postFontLog('ebook.document.fonts.forwarded', {
        reason,
        documentURL: doc?.location?.href || null,
        sourceTag: sourceFontStyle.tagName || null,
        targetTag: targetFontStyle.tagName || null,
        href: targetFontStyle.href || null,
        family: targetFontStyle.dataset?.mnbInjectedFontFamily || null,
        ...captureDocumentFontApplicationState(doc),
    });
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
    postFontLog('ebook.document.fonts.forward.summary', {
        reason,
        documentCount: docs.length,
        forwardedCount,
        outerHasCustomFontStyle: !!sourceFontStyle,
        outerLocation: document?.location?.href || null,
    });
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
            postEPUBLog('ebook.perf.cache-warmer.deferred', {
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                firstLiveHref: firstLiveHref ?? null,
                firstLiveSettled,
                processedSectionCount: liveProcessedSectionHrefSet().size,
                settledSectionCount: liveSettledSectionHrefSet().size,
                ...captureEPUBOverlapState(),
            });
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
        markEPUBPerf('cache-warmer.opened', {
            sourceKind: cacheWarmerSource?.kind || 'nil',
        });
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
    postEPUBLog('ebook.perf.cache-warmer.schedule', {
        reason,
        delayMs,
        initialForegroundNextSectionPending: !!globalThis.__manabiInitialForegroundNextSectionPending,
        ...captureEPUBOverlapState(),
    });
    postReplaceTextPerfLog('cache-warmer.schedule', {
        reason,
        delayMs,
        initialForegroundNextSectionPending: !!globalThis.__manabiInitialForegroundNextSectionPending,
        ...captureEPUBOverlapState(),
    });
    void maybeOpenDeferredCacheWarmer();
};

const postOpenReaderGoToSheetRequest = (source, targetID = null) => {
    postEPUBLog('ebook.goToSheet.request', {
        source,
        targetID,
    });
    try {
        window.webkit?.messageHandlers?.openReaderGoToSheet?.postMessage?.({
            source,
            targetID,
        });
    } catch (error) {
        postEPUBLog('ebook.goToSheet.request.error', {
            source,
            targetID,
            message: error?.message || String(error),
        });
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
    const normalized = !!shouldHide;
    const body = document.body;
    const before = captureNavVisibilityState();
    if (manabiDiagnosticsEnabled()) console.log('# HIDENAV js.bridge.begin', JSON.stringify({
        source,
        requestedHide: normalized,
        before,
        innerHeight: window.innerHeight,
        visualViewportHeight: window.visualViewport?.height ?? null,
        visualViewportOffsetTop: window.visualViewport?.offsetTop ?? null,
    }));
    if (body?.classList?.contains?.('nav-hidden')) {
        body.classList.remove('nav-hidden');
    }
    globalThis.reader?.navHUD?.setHideNavigationDueToScroll?.(normalized, source, {
        bridgeSource: source,
        bodyClassApplied: false,
    });
    const bridgeState = {
        source,
        shouldHide: normalized,
        ...captureNavVisibilityState(),
    };
    const bridgeKey = JSON.stringify(bridgeState);
    if (globalThis.__manabiLastNavigationVisibilityBridgeKey !== bridgeKey) {
        globalThis.__manabiLastNavigationVisibilityBridgeKey = bridgeKey;
        postReaderLog('ebook.navigationVisibility.bridge', bridgeState);
    }
    postPageNumLog('nav.visibility.bridge', {
        source,
        shouldHide: normalized,
        before,
        after: captureNavVisibilityState(),
    });
    postMarkReadLog('hideNavigation.bridge', {
        source,
        requestedHide: normalized,
        beforeHideNavigationDueToScroll: before?.hudHideNavigationDueToScroll ?? null,
        afterHideNavigationDueToScroll: globalThis.reader?.navHUD?.hideNavigationDueToScroll ?? null,
        beforeBodyNavHidden: before?.bodyNavHidden ?? null,
        afterBodyNavHidden: document.body?.classList?.contains?.('nav-hidden') ?? null,
        afterNavHiddenClass: globalThis.reader?.navHUD?.navBar?.classList?.contains?.('nav-hidden') ?? null,
        afterNavHiddenScrollClass: globalThis.reader?.navHUD?.navBar?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null,
    });
    if (manabiDiagnosticsEnabled()) console.log('# HIDENAV js.bridge.finish', JSON.stringify({
        source,
        requestedHide: normalized,
        after: captureNavVisibilityState(),
        innerHeight: window.innerHeight,
        visualViewportHeight: window.visualViewport?.height ?? null,
        visualViewportOffsetTop: window.visualViewport?.offsetTop ?? null,
    }));
    globalThis.reader?.queueLayoutDiagnostics?.('native-hide-bridge', {
        source,
        shouldHide: normalized,
    });
    return normalized;
};

window.manabiSetHideNavigationDueToScroll = (shouldHide) => {
    return setNativeHideNavigationState(shouldHide, 'window.manabiSetHideNavigationDueToScroll');
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
        target.style.setProperty('--mnb-obscured-top-inset', state.obscuredTopInset);
        target.style.setProperty('--mnb-toolbar-bottom-offset', state.toolbarBottomOffset);
        target.style.setProperty('--mnb-obscured-bottom-inset', state.obscuredBottomInset);
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
        bodyCssObscuredBottom: bodyStyle?.getPropertyValue('--mnb-obscured-bottom-inset')?.trim() || null,
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
            postEPUBLog('ebook.chromeInsets.zeroOverwriteSummary', shortOverwriteLog);
            postEPUBLog('ebook.chromeInsets.zeroOverwriteAttempt', overwriteLog);
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
        postEPUBLog('ebook.chromeInsets.reapplied', chromeInsetsLog);
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

let currentEPUBPerfSession = null;
let nextEPUBPerfSessionID = 1;

const beginEPUBPerfSession = (details = {}) => {
    const startedAt = performanceNowMs();
    currentEPUBPerfSession = {
        id: nextEPUBPerfSessionID++,
        startedAt,
        lastAt: startedAt,
        marks: new Map([['start', startedAt]]),
        onceKeys: new Set(),
    };
    postEPUBLog('ebook.perf.session.begin', {
        sessionID: currentEPUBPerfSession.id,
        ...details,
    });
    return currentEPUBPerfSession;
};

const markEPUBPerf = (stage, details = {}, options = {}) => {
    const session = currentEPUBPerfSession;
    if (!session || typeof stage !== 'string' || stage.length === 0) {
        return;
    }
    const {
        once = false,
        key = stage,
        anchor = null,
    } = options;
    const onceKey = `${session.id}:${key}`;
    if (once && session.onceKeys.has(onceKey)) {
        return;
    }
    const now = performanceNowMs();
    const anchorAt = typeof anchor === 'string'
        ? (session.marks.get(anchor) ?? null)
        : null;
    const payload = {
        sessionID: session.id,
        sinceStartMs: safeRound(now - session.startedAt, 1),
        sinceLastMs: safeRound(now - session.lastAt, 1),
        ...details,
    };
    if (anchorAt !== null) {
        payload.anchorStage = anchor;
        payload.sinceAnchorMs = safeRound(now - anchorAt, 1);
    }
    postEPUBLog(`ebook.perf.${stage}`, payload);
    session.lastAt = now;
    session.marks.set(stage, now);
    if (once) {
        session.onceKeys.add(onceKey);
    }
};

globalThis.__manabiPostEPUBLog = postEPUBLog;
globalThis.__manabiMarkEPUBPerf = markEPUBPerf;
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
    if (!(element instanceof Element)) {
        return null;
    }
    const rect = summarizeRect(element.getBoundingClientRect?.());
    const style = window.getComputedStyle?.(element);
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
    if (!doc?.querySelectorAll) {
        return { byID: new Map(), idsByEntryID: new Map() };
    }
    const sidecars = Array.from(doc.querySelectorAll('[data-mnb-seg-meta]'));
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
    const expandSegmentMetadataPayload = (payload) => {
        if (payload?.v === 2 && payload?.t && Array.isArray(payload.s)) {
            const tables = payload.t;
            return payload.s.map((segment) => ({
                i: segment?.[0], // segment element ID
                sid: segment?.[1], // stable selection ID when available
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

const rectIntersectsViewport = (rect, viewportWidth, viewportHeight) => {
    if (!rect || rect.width <= 0 || rect.height <= 0) {
        return false;
    }
    return rect.right > 0
        && rect.bottom > 0
        && rect.left < viewportWidth
        && rect.top < viewportHeight;
};

const rectIntersectsBounds = (rect, bounds) => {
    if (!rect || rect.width <= 0 || rect.height <= 0 || !bounds) {
        return false;
    }
    return rect.right > bounds.left
        && rect.bottom > bounds.top
        && rect.left < bounds.right
        && rect.top < bounds.bottom;
};

const positiveClientRectsForNode = (node) => {
    const rects = [];
    if (typeof node?.getClientRects === 'function') {
        rects.push(...Array.from(node.getClientRects()));
    }
    if (typeof node?.getBoundingClientRect === 'function') {
        rects.push(node.getBoundingClientRect());
    }
    const doc = node?.ownerDocument ?? null;
    if (doc?.createRange && node?.childNodes?.length > 0) {
        const range = doc.createRange();
        try {
            range.selectNodeContents(node);
            rects.push(...Array.from(range.getClientRects?.() ?? []));
        } catch (_error) {
            // ignore unmeasurable nodes
        } finally {
            range.detach?.();
        }
    }
    return rects.filter((rect) => rect && rect.width > 0 && rect.height > 0);
};

const firstVisibleClientRectForNode = (node, bounds) => {
    const rects = positiveClientRectsForNode(node);
    return rects.find((rect) => rectIntersectsBounds(rect, bounds)) ?? null;
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
                visibleBounds: null,
                frameRect,
                containerRect,
                hasExpectedPaginatorContainer,
            };
        }
        return {
            viewportWidth: containerRect.width,
            viewportHeight: containerRect.height,
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
        const rect = firstVisibleClientRectForNode(segmentNode, visibleBounds);
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
            segmentIdentifier,
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
        visibleBounds,
        frameRect,
        containerRect,
        hasExpectedPaginatorContainer,
    } = viewportBoundsForReaderDocument(doc);
    const useVisibleRange = !!visibleRange && visibleRange.collapsed !== true;
    const useViewportFallback = !useVisibleRange;
    if (visibleRange?.collapsed === true) {
        postMarkReadLog('visibleRange.collect.collapsedViewportFallback', {
            documentURL: doc.URL || doc.location?.href || null,
            reason: 'collapsed-range-viewport-fallback',
            rangeStartNode: describeMarkReadNode(visibleRange?.startContainer ?? null),
            rangeEndNode: describeMarkReadNode(visibleRange?.endContainer ?? null),
            viewportWidth,
            viewportHeight,
            visibleLeft: safeRound(visibleBounds.left, 1),
            visibleRight: safeRound(visibleBounds.right, 1),
        });
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
        postMay4Log('visibleRange.collect.collapsedViewportFallback', {
            viewportWidth,
            viewportHeight,
            visibleLeft: safeRound(visibleBounds.left, 1),
            visibleRight: safeRound(visibleBounds.right, 1),
            frameLeft: safeRound(frameRect?.left, 1),
            containerLeft: safeRound(containerRect?.left, 1),
            hasExpectedPaginatorContainer,
            ...collectMay4DocumentSummary(doc),
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
    postMarkReadLog('visibleRange.collect.start', {
        documentURL: doc.URL || doc.location?.href || null,
        hasVisibleRange: !!visibleRange,
        usingVisibleRange: useVisibleRange,
        segmentCandidateCount: allSegmentNodes.length,
        segmentCandidateSource,
        ancestorSegmentCandidateCount,
        viewportWidth,
        viewportHeight,
        queryElapsedMs: safeRound(queryCompletedAt - startedAt, 2),
        rangeStartContainer: visibleRange?.startContainer?.nodeName || null,
        rangeEndContainer: visibleRange?.endContainer?.nodeName || null,
        rangeStartOffset: typeof visibleRange?.startOffset === 'number' ? visibleRange.startOffset : null,
        rangeEndOffset: typeof visibleRange?.endOffset === 'number' ? visibleRange.endOffset : null,
        rangeCollapsed: typeof visibleRange?.collapsed === 'boolean' ? visibleRange.collapsed : null,
        rangeCommonAncestor: describeMarkReadNode(rangeCommonAncestor),
        rangeStartNode: describeMarkReadNode(visibleRange?.startContainer ?? null),
        rangeEndNode: describeMarkReadNode(visibleRange?.endContainer ?? null),
        boundedSegmentCount: boundedSegmentNodes?.length ?? null,
        orderedSegmentCount: expandedRangeResult?.orderedSegmentCount ?? null,
        rangeAnchorStart: expandedRangeResult?.anchorStart ?? null,
        rangeAnchorEnd: expandedRangeResult?.anchorEnd ?? null,
        rangeWindowStart: expandedRangeResult?.windowStart ?? null,
        rangeWindowEnd: expandedRangeResult?.windowEnd ?? null,
        rangeWindowExpansionSize: expandedRangeResult?.expansionSize ?? null,
        rangeWindowBounded: expandedRangeResult?.boundedByWindow ?? null,
        rangeWindowFirstVisibleIndex: expandedRangeResult?.firstVisibleIndex ?? null,
        rangeWindowLastVisibleIndex: expandedRangeResult?.lastVisibleIndex ?? null,
    });
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
        const rect = firstVisibleClientRectForNode(segmentNode, visibleBounds);
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
            segmentIdentifier,
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
            const rect = firstVisibleClientRectForNode(segmentNode, visibleBounds);
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
                segmentIdentifier,
                sentenceIdentifier: sentenceIdentifierForNode(sentenceNode),
            });
        }
        postMarkReadLog('visibleRange.collect.fallback', {
            documentURL: doc.URL || doc.location?.href || null,
            reason: 'range-empty',
            segmentCandidateCount: allSegmentNodes.length,
            fallbackVisibleSegmentCount: fallbackSegments.length,
            fallbackHiddenTooltipCount,
            fallbackMissingIdentifierCount,
            fallbackOutOfViewportCount,
            fallbackRectMeasureCount,
            fallbackRectMeasureElapsedMs: safeRound(fallbackRectMeasureElapsedMs, 2),
            fallbackElapsedMs: safeRound(performance.now() - fallbackStartedAt, 2),
            rangeCollapsed: typeof visibleRange?.collapsed === 'boolean' ? visibleRange.collapsed : null,
            rangeStartNode: describeMarkReadNode(visibleRange?.startContainer ?? null),
            rangeEndNode: describeMarkReadNode(visibleRange?.endContainer ?? null),
        });
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
        postMarkReadLog('visibleRange.collect.collapsedSkipped', {
            documentURL: doc.URL || doc.location?.href || null,
            reason: 'collapsed-range-viewport-fallback',
            segmentCandidateCount: allSegmentNodes.length,
            fallbackVisibleSegmentCount: visibleSegments.length,
            rangeStartNode: describeMarkReadNode(visibleRange?.startContainer ?? null),
            rangeEndNode: describeMarkReadNode(visibleRange?.endContainer ?? null),
        });
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
    postMarkReadLog('visibleRange.collect.end', {
        documentURL: doc.URL || doc.location?.href || null,
        hasVisibleRange: !!visibleRange,
        usingVisibleRange: useVisibleRange,
        segmentCandidateCount: allSegmentNodes.length,
        totalSegmentCount,
        visibleSegmentCount: visibleSegments.length,
        hiddenTooltipCount,
        missingIdentifierCount,
        outOfViewportCount,
        visibleRangeCheckCount,
        visibleRangeErrorCount,
        rectMeasureCount,
        rectMeasureElapsedMs: safeRound(rectMeasureElapsedMs, 2),
        rangeCheckElapsedMs: safeRound(rangeCheckElapsedMs, 2),
        firstVisibleSegmentSample: visibleSegments[0]
            ? {
                segmentIdentifier: visibleSegments[0].segmentIdentifier,
                sentenceIdentifier: visibleSegments[0].sentenceIdentifier,
            }
            : null,
        lastVisibleSegmentSample: visibleSegments.length > 0
            ? {
                segmentIdentifier: visibleSegments[visibleSegments.length - 1].segmentIdentifier,
                sentenceIdentifier: visibleSegments[visibleSegments.length - 1].sentenceIdentifier,
            }
            : null,
        totalElapsedMs: safeRound(completedAt - startedAt, 2),
        loopElapsedMs: safeRound(completedAt - queryCompletedAt, 2),
    });
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
        totalSegmentCount,
        hiddenTooltipCount,
        missingIdentifierCount,
        outOfViewportCount,
    };
};

const buildVisiblePageTrackingStates = async (doc, articleReadingProgress, visibleRange = null) => {
    const normalizedProgress = normalizeArticleReadingProgress(articleReadingProgress);
    const readSegmentIdentifiers = new Set(normalizedProgress.readSegmentIdentifiers);
    const {
        visibleSegments,
        viewportWidth,
        viewportHeight,
        totalSegmentCount,
        hiddenTooltipCount,
        missingIdentifierCount,
        outOfViewportCount,
    } = collectVisibleSegmentNodesFromRange(doc, visibleRange);
    const clusterAxis = !!doc?.body?.classList?.contains?.('reader-vertical-writing') ? 'block' : 'inline';
    let recoveredTextSearchStringCount = 0;
    let skippedMissingSearchStringCount = 0;
    const dedupedSegments = new Map();
    const visibleSegmentIdentifiers = new Set(
        visibleSegments
            .map((item) => item.segmentIdentifier)
            .filter((identifier) => typeof identifier === 'string' && identifier.length > 0)
    );
    const unreadVisibleSegmentCount = Array.from(visibleSegmentIdentifiers)
        .filter((segmentIdentifier) => !readSegmentIdentifiers.has(segmentIdentifier))
        .length;
    const isRead = visibleSegmentIdentifiers.size > 0 && unreadVisibleSegmentCount === 0;
    if (isRead) {
        const states = [{
            id: 'visible-screen',
            payload: {
                segments: [],
                sentenceIdentifiers: [],
            },
            isRead,
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
            const allSegmentIdentifiers = Array.from(sentenceNode?.querySelectorAll?.('mnb-seg') || [])
                .map((segmentNode) => segmentIdentifierForNode(segmentNode))
                .filter((identifier) => typeof identifier === 'string' && identifier.length > 0);
            sentencesByIdentifier.set(item.sentenceIdentifier, allSegmentIdentifiers);
        }
    }
    const sentenceIdentifiers = Array.from(sentencesByIdentifier.entries())
        .filter(([, allSegmentIdentifiers]) => allSegmentIdentifiers.length > 0
            && allSegmentIdentifiers.every((segmentIdentifier) =>
                readSegmentIdentifiers.has(segmentIdentifier)
                || visibleSegmentIdentifiers.has(segmentIdentifier)))
        .map(([sentenceIdentifier]) => sentenceIdentifier);
    const states = dedupedSegments.size > 0 ? [{
        id: 'visible-screen',
        payload: {
            segments: Array.from(dedupedSegments.values()),
            sentenceIdentifiers,
        },
        isRead,
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
    postEPUBLog('ebook.perf.native-loader.ready', {
        sourceURL: url,
        isCacheWarmer: !!isCacheWarmer,
        entryCount: entries.length,
        elapsedMs: safeRound(performanceNowMs() - loaderStartedAt, 1),
    });
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
    postEPUBLog('ebook.perf.zip-loader.ready', {
        fileName: file?.name || 'nil',
        isCacheWarmer: !!isCacheWarmer,
        entryCount: entries.length,
        elapsedMs: safeRound(performanceNowMs() - loaderStartedAt, 1),
    });
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

    mnb-seg {
        /* Keep book segments atomic so page turns never split a segment across pages. */
        display: inline-block !important;
        vertical-align: baseline !important;
        max-inline-size: 100% !important;
        break-inside: avoid !important;
        break-before: avoid !important;
        break-after: avoid !important;
        page-break-inside: avoid !important;
        -webkit-column-break-inside: avoid !important;
    }
    body.reader-vertical-writing mnb-seg {
        /*
           Temporary pagination probe: let vertical text segments participate in
           normal inline layout instead of forcing every segment to inline-block.
        */
        display: inline !important;
        break-inside: auto !important;
        break-before: auto !important;
        break-after: auto !important;
        page-break-inside: auto !important;
        -webkit-column-break-inside: auto !important;
    }
    body.reader-vertical-writing mnb-seg:not(:has(rt)) {
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

    mnb-sen ruby.mnb-gen > rt,
    mnb-sen ruby.mbn-src > rt {
        /*
           Keep Manabi-owned ruby annotations in the historical Japanese sans stack.
           Reader-selected surface fonts such as YuKyokasho should apply to the
           sentence surface text, not to the compact annotation text.
        */
        font-family: "Hiragino Kaku Gothic ProN", "Hiragino Sans", system-ui !important;
    }

    body *:not(.mnb-tracking-container *):not(mnb-seg *) {
        /* prevent height: 100% type values from breaking getBoundingClientRect layout in paginator */
        height: inherit !important;
    }
    body.reader-is-single-media-element-without-text *:not(.mnb-tracking-container *):not(mnb-seg *) {
        max-height: 99vh;
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

const collectShortLineDiagnosticsForDocument = (doc, options = {}) => {
    if (!doc?.body) return { reason: 'missing-document' };
    const round = (value, digits = 2) =>
        Number.isFinite(value) ? Number(value.toFixed(digits)) : null;
    const viewportHeight = doc.defaultView?.innerHeight ?? 0;
    const viewportWidth = doc.defaultView?.innerWidth ?? 0;
    const blocks = Array.from(doc.querySelectorAll('p, li, blockquote, dd, mnb-sen, mnb-seg'))
        .filter(element => {
            const text = element.textContent?.trim() || '';
            if (!text) return false;
            const rect = element.getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0) return false;
            if (viewportHeight > 0 && (rect.bottom < 0 || rect.top > viewportHeight)) return false;
            if (viewportWidth > 0 && (rect.right < 0 || rect.left > viewportWidth)) return false;
            return true;
        })
        .slice(0, 8);
    const samples = blocks.map((element, blockIndex) => {
        const style = doc.defaultView?.getComputedStyle?.(element);
        const writingMode = style?.writingMode || '';
        const vertical = writingMode.startsWith('vertical');
        const range = doc.createRange();
        range.selectNodeContents(element);
        const rects = Array.from(range.getClientRects())
            .filter(rect => rect.width > 0 && rect.height > 0)
            .slice(0, 240);
        range.detach?.();

        const rubyRects = Array.from(element.querySelectorAll('rt'))
            .flatMap(rt => Array.from(rt.getClientRects?.() || []))
            .filter(rect => rect.width > 0 && rect.height > 0);
        const groups = new Map();
        for (const rect of rects) {
            const key = vertical ? Math.round(rect.left) : Math.round(rect.top);
            const existing = groups.get(key) || {
                minBlockStart: vertical ? rect.left : rect.top,
                maxBlockEnd: vertical ? rect.right : rect.bottom,
                minInlineStart: vertical ? rect.top : rect.left,
                maxInlineEnd: vertical ? rect.bottom : rect.right,
                rectCount: 0,
                hasRubyRect: false,
            };
            existing.minBlockStart = Math.min(existing.minBlockStart, vertical ? rect.left : rect.top);
            existing.maxBlockEnd = Math.max(existing.maxBlockEnd, vertical ? rect.right : rect.bottom);
            existing.minInlineStart = Math.min(existing.minInlineStart, vertical ? rect.top : rect.left);
            existing.maxInlineEnd = Math.max(existing.maxInlineEnd, vertical ? rect.bottom : rect.right);
            existing.rectCount += 1;
            existing.hasRubyRect = existing.hasRubyRect || rubyRects.some(rubyRect =>
                !(rubyRect.right < rect.left
                    || rubyRect.left > rect.right
                    || rubyRect.bottom < rect.top
                    || rubyRect.top > rect.bottom)
            );
            groups.set(key, existing);
        }
        const lines = Array.from(groups.values())
            .sort((a, b) => a.minBlockStart - b.minBlockStart)
            .map(line => ({
                blockStart: round(line.minBlockStart),
                advance: round(line.maxBlockEnd - line.minBlockStart),
                inlineSize: round(line.maxInlineEnd - line.minInlineStart),
                rectCount: line.rectCount,
                hasRubyRect: line.hasRubyRect,
            }))
            .slice(0, 12);
        const advances = lines.map(line => line.advance).filter(value => Number.isFinite(value));
        const blockStarts = lines.map(line => line.blockStart).filter(value => Number.isFinite(value));
        const blockDeltas = blockStarts.slice(1).map((value, index) => round(value - blockStarts[index]));
        return {
            blockIndex,
            tagName: element.tagName?.toLowerCase() || null,
            className: typeof element.className === 'string' ? element.className.slice(0, 80) : null,
            text: (element.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 80),
            computedLineHeight: style?.lineHeight || null,
            computedFontSize: style?.fontSize || null,
            writingMode: writingMode || null,
            hasRuby: !!element.querySelector('ruby, rt'),
            rectCount: rects.length,
            rubyRectCount: rubyRects.length,
            minAdvance: advances.length ? round(Math.min(...advances)) : null,
            maxAdvance: advances.length ? round(Math.max(...advances)) : null,
            blockDeltas,
            lines,
        };
    });
    return {
        reason: options.reason || null,
        documentURL: doc.location?.href || doc.URL || null,
        viewportWidth: round(viewportWidth),
        viewportHeight: round(viewportHeight),
        blockCount: blocks.length,
        samples,
    };
};

const $ = document.querySelector.bind(document)

const locales = 'en'
const percentFormat = new Intl.NumberFormat(locales, {
    style: 'percent'
})

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
        }
        body.classList.toggle('loading', nextVisible);
        if (!nextVisible) {
            setTimeout(() => {
                if (!document.body?.classList?.contains?.('loading')) {
                    loadingIndicator?.setAttribute?.('hidden', '');
                }
            }, 360);
        }
        if (previousVisible !== nextVisible) {
            postEPUBLoadLog('loading.class.changed', collectEPUBLoadDiagnostics('loading.class.changed', {
                previous: previousVisible,
                next: nextVisible,
            }));
            postEPUBFlashLog('js.loadingClass.changed', {
                previous: previousVisible,
                next: nextVisible,
                hasReader: !!this.view,
                hasRenderer: !!this.view?.renderer,
                rendererPageCurrent: this.navHUD?.rendererPageSnapshot?.current ?? null,
                rendererPageTotal: this.navHUD?.rendererPageSnapshot?.total ?? null,
                visual: captureEPUBFlashVisualState(this.view),
            });
        }
        if (!nextVisible) {
            requestAnimationFrame(() => {
                auditEPUBAnimations('loading-off.raf');
                auditEPUBCompositing('loading-off.raf');
            });
            setTimeout(() => {
                auditEPUBAnimations('loading-off.750ms');
                auditEPUBCompositing('loading-off.750ms');
                postEPUBFlashLog('js.loadingClass.hiddenSettle', {
                    reason: 'loading-off.750ms',
                    hasReader: !!this.view,
                    hasRenderer: !!this.view?.renderer,
                    visual: captureEPUBFlashVisualState(this.view),
                });
            }, 750);
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
    optimisticReadSegmentIdentifiers = new Set();
    optimisticSentenceIdentifiersRead = new Set();
    markReadSessionID = Math.random().toString(36).slice(2, 10);
    lastPageTrackingVisibility = null;
    lastPageTrackingDiagnosticsKey = null;
    lastBookReadingProgressKey = null;
    pageTrackingRetryHandle = null;
    layoutDiagnosticsHandle = null;
    initialPaginatorSettleHandle = null;
    hasSettledInitialPaginatorLayout = false;
    lastLayoutDiagnosticsKey = null;
    lastLayoutSnapshot = null;
    lastCFIPersistenceObservation = null;
    unstableCFIs = new Set();
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
            await runWithEPUBFlashNavigationIntent({
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
            await runWithEPUBFlashNavigationIntent({
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
            await runWithEPUBFlashNavigationIntent({
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
        postEPUBLog('ebook.goTo.href.request', {
            source,
            href,
        });
        await runWithEPUBFlashNavigationIntent({
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
        postEPUBLog('ebook.goTo.percent.request', {
            source,
            percent: clampedPercent,
            fraction,
        });
        await runWithEPUBFlashNavigationIntent({
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
        await runWithEPUBFlashNavigationIntent({
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
    constructor() {
        applyStoredChromeInsets('reader.constructor');
        this.navHUD = new NavigationHUD({
            formatPercent: value => percentFormat.format(value),
            getRenderer: () => this.view?.renderer,
            onJumpRequest: descriptor => this._goToDescriptor(descriptor),
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
            runWithEPUBFlashNavigationIntent({
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
            event.preventDefault?.();
            postOpenReaderGoToSheetRequest('nav-primary-text', 'nav-primary-text');
        });
        document.getElementById('nav-hidden-primary-text')?.addEventListener('click', (event) => {
            event.preventDefault?.();
            postOpenReaderGoToSheetRequest('nav-hidden-primary-text', 'nav-hidden-primary-text');
        });
        document.getElementById('nav-section-progress-center')?.addEventListener('click', (event) => {
            event.preventDefault?.();
            postOpenReaderGoToSheetRequest('nav-section-progress-center', 'nav-section-progress-center');
        });
        $('#side-bar-close-button').addEventListener('click', () => {
            this.closeSideBar()
        })
        $('#dimming-overlay').addEventListener('click', () => this.closeSideBar())
        const revealNavigationFromPageTracking = (event, source) => {
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
            revealNavigationFromPageTracking(event, 'page-tracking-buttons.touchstart.reveal');
        }, { capture: true, passive: false });
        pageTrackingButtons?.addEventListener('pointerdown', (event) => {
            revealNavigationFromPageTracking(event, 'page-tracking-buttons.pointerdown.reveal');
        }, { capture: true });
        pageTrackingButtons?.addEventListener('click', (event) => {
            const button = event.target?.closest?.('button[data-page-tracking-id], button[data-completion-action]');
            if (!button) {
                return;
            }
            if (revealNavigationFromPageTracking(event, 'page-tracking-buttons.click.reveal')) {
                return;
            }
            const completionAction = button.dataset?.completionAction;
            if (completionAction) {
                this.#handleCompletionAction(completionAction).catch((error) => console.error(error));
                return;
            }
            const stateID = button?.dataset?.pageTrackingId;
            if (!stateID) {
                return;
            }
            this.#markPageClusterAsRead(stateID).catch((error) => console.error(error));
        });
        window.addEventListener('resize', () => {
            postBookRotateLog('window.resize', {
                innerWidth: window.innerWidth ?? null,
                innerHeight: window.innerHeight ?? null,
                visualViewportWidth: window.visualViewport?.width ?? null,
                visualViewportHeight: window.visualViewport?.height ?? null,
                orientationAngle: screen.orientation?.angle ?? window.orientation ?? null,
                orientationType: screen.orientation?.type ?? null,
            });
            this.#updatePageReadMarker('window-resize');
            this.#queueLayoutDiagnostics('window-resize');
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
            this.#updatePageReadMarker('visual-viewport-resize');
            this.#queueLayoutDiagnostics('visual-viewport-resize');
        });
        screen.orientation?.addEventListener?.('change', () => {
            postBookRotateLog('screen.orientation.change', {
                innerWidth: window.innerWidth ?? null,
                innerHeight: window.innerHeight ?? null,
                visualViewportWidth: window.visualViewport?.width ?? null,
                visualViewportHeight: window.visualViewport?.height ?? null,
                orientationAngle: screen.orientation?.angle ?? window.orientation ?? null,
                orientationType: screen.orientation?.type ?? null,
            });
            this.#updatePageReadMarker('screen-orientation-change');
            this.#queueLayoutDiagnostics('screen-orientation-change');
        });
    }
    #logPageTracking(event, details = {}) {
        postReaderLog(event, details);
    }
    #logMarkRead(event, details = {}) {
        postMarkReadLog(event, details);
    }
    #updatePageReadMarker(reason = 'unspecified', explicitState = null, explicitDoc = null) {
        const state = explicitState || (this.pageTrackingStates || []).find((candidate) => candidate.id === 'visible-screen') || null;
        const isRead = !!state?.isRead && !this.completionAction;
        const doc = isDocumentLike(explicitDoc)
            ? explicitDoc
            : (this.view?.renderer?.getContents?.()?.[0]?.doc ?? null);
        const isVertical = !!doc?.body?.classList?.contains?.('reader-vertical-writing');
        const readerStage = document.getElementById('reader-stage');
        const liveFoliateView = Array.from(document.querySelectorAll('foliate-view'))
            .find((element) => element?.isConnected && element.offsetParent !== null) || this.view || null;
        if (isRead && isVertical && readerStage instanceof HTMLElement) {
            const livePaginator = resolveFoliatePaginator(liveFoliateView);
            const paginatorContainer = livePaginator?.shadowRoot?.getElementById?.('container') || null;
            const stageRect = readerStage.getBoundingClientRect();
            const containerRect = paginatorContainer?.getBoundingClientRect?.() || null;
            if (containerRect && containerRect.width > 0 && stageRect.width > 0) {
                readerStage.style.setProperty('--mnb-ebook-read-marker-top-left', `${Math.max(0, containerRect.left - stageRect.left)}px`);
                readerStage.style.setProperty('--mnb-ebook-read-marker-top-width', `${containerRect.width}px`);
            } else {
                readerStage.style.removeProperty('--mnb-ebook-read-marker-top-left');
                readerStage.style.removeProperty('--mnb-ebook-read-marker-top-width');
            }
        } else if (readerStage instanceof HTMLElement) {
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
        document.body?.setAttribute?.('data-page-read-marker-read', isRead ? 'true' : 'false');
        document.body?.setAttribute?.('data-page-read-marker-axis', isVertical ? 'block' : 'inline');
        postMay4Log('pageReadMarker.update', {
            reason,
            isRead,
            hasState: !!state,
            stateCount: this.pageTrackingStates.length,
            hasCompletionAction: !!this.completionAction,
            axis: isVertical ? 'block' : 'inline',
            ...collectMay4DocumentSummary(getActiveReaderDocument()),
            ...collectMay4ButtonSummary(),
        });
        this.#logMarkRead('pageReadMarker.update', {
            reason,
            isRead,
            axis: isVertical ? 'block' : 'inline',
            hasExplicitState: !!explicitState,
            stateCount: this.pageTrackingStates.length,
            bodyReadAttr: document.body?.getAttribute?.('data-page-read-marker-read') ?? null,
            bodyAxisAttr: document.body?.getAttribute?.('data-page-read-marker-axis') ?? null,
            topMarkerLeft: readerStage?.style?.getPropertyValue?.('--mnb-ebook-read-marker-top-left') || null,
            topMarkerWidth: readerStage?.style?.getPropertyValue?.('--mnb-ebook-read-marker-top-width') || null,
            sideMarkerLeft: readerStage?.style?.getPropertyValue?.('--mnb-ebook-read-marker-side-left') || null,
            sideMarkerTop: readerStage?.style?.getPropertyValue?.('--mnb-ebook-read-marker-side-top') || null,
            sideMarkerHeight: readerStage?.style?.getPropertyValue?.('--mnb-ebook-read-marker-side-height') || null,
            timestamp: Math.round(performance.now()),
        });
    }
    #clearVisiblePageReadChrome(reason = 'unspecified') {
        document.body?.setAttribute?.('data-page-read-marker-read', 'false');
        document.querySelectorAll('#page-tracking-buttons .page-read-button[data-page-tracking-id="visible-screen"]').forEach((button) => {
            button.dataset.mnbTrackingSectionRead = 'false';
            button.dataset.readState = 'ready';
            button.disabled = false;
            button.setAttribute('aria-label', 'Mark Read');
            button.querySelectorAll('.mnb-tracking-button-label, .sr-only').forEach((label) => {
                label.textContent = 'Mark Read';
            });
        });
        this.#logMarkRead('pageTracking.clearStaleReadChrome', {
            reason,
            markerReadAttr: document.body?.getAttribute?.('data-page-read-marker-read') ?? null,
            timestamp: Math.round(performance.now()),
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
            this.#logMarkRead('progress.optimisticCleared', {
                reason,
                sessionID: this.markReadSessionID,
                optimisticReadSegmentCount: this.optimisticReadSegmentIdentifiers.size,
                optimisticSentenceReadCount: this.optimisticSentenceIdentifiersRead.size,
            });
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
        this.#logMarkRead('pageTracking.retry.queue', {
            reason,
            retryCount,
            hasExplicitDoc: isDocumentLike(explicitDoc),
            timestamp: Math.round(performance.now()),
        });
        this.pageTrackingRetryHandle = requestAnimationFrame(() => {
            const retryStartedAt = performance.now();
            this.pageTrackingRetryHandle = null;
            this.#logMarkRead('pageTracking.retry.fire', {
                reason,
                retryCount,
                hasExplicitDoc: isDocumentLike(explicitDoc),
                timestamp: Math.round(retryStartedAt),
            });
            this.#syncPageTrackingButtons(reason, explicitDoc, retryCount - 1).catch((error) => console.error(error));
        });
    }
    queueLayoutDiagnostics(reason = 'unknown', extra = null) {
        this.#queueLayoutDiagnostics(reason, extra);
    }
    #queueLayoutDiagnostics(reason = 'unknown', extra = null) {
        postBookRotateLog('layout.queue', {
            reason,
            hadPending: !!this.layoutDiagnosticsHandle,
            extra,
            innerWidth: window.innerWidth ?? null,
            innerHeight: window.innerHeight ?? null,
            visualViewportWidth: window.visualViewport?.width ?? null,
            visualViewportHeight: window.visualViewport?.height ?? null,
            orientationAngle: screen.orientation?.angle ?? window.orientation ?? null,
            orientationType: screen.orientation?.type ?? null,
        });
        if (this.layoutDiagnosticsHandle) {
            cancelAnimationFrame(this.layoutDiagnosticsHandle);
        }
        this.layoutDiagnosticsHandle = requestAnimationFrame(() => {
            this.layoutDiagnosticsHandle = null;
            postBookRotateLog('layout.flush', {
                reason,
                extra,
                innerWidth: window.innerWidth ?? null,
                innerHeight: window.innerHeight ?? null,
                visualViewportWidth: window.visualViewport?.width ?? null,
                visualViewportHeight: window.visualViewport?.height ?? null,
                orientationAngle: screen.orientation?.angle ?? window.orientation ?? null,
                orientationType: screen.orientation?.type ?? null,
            });
            this.#logLayoutDiagnostics(reason, extra);
        });
    }
    async #settleInitialPaginatorLayout(reason = 'unknown', { allowWhileLoading = false } = {}) {
        if (this.hasSettledInitialPaginatorLayout) {
            return { rendered: false, reason: 'already-settled' };
        }
        const renderer = this.view?.renderer;
        if (!renderer || typeof renderer.renderIfContainerSizeChanged !== 'function') {
            return { rendered: false, reason: 'unavailable' };
        }
        try {
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
                return result;
            }
            if (hasGap && typeof renderer.render === 'function') {
                await renderer.render();
                this.#updatePageReadMarker('initial-paginator-settle.forced-render');
                this.hasSettledInitialPaginatorLayout = true;
                this.#queueLayoutDiagnostics('initial-paginator-settle.forced-render', {
                    reason,
                    previousSize: result?.previousSize ?? null,
                    currentSize: result?.currentSize ?? null,
                    renderedBeforeForce: result?.rendered ?? false,
                    toolbarGapPx: snapshot.toolbarGapPx,
                    stageGapPx: snapshot.stageGapPx,
                });
                return { ...result, forcedRender: true };
            }
            if (result?.rendered) {
                this.#updatePageReadMarker('initial-paginator-settle.rendered');
            }
            this.hasSettledInitialPaginatorLayout = true;
            return result;
        } catch (error) {
            console.error(error);
            this.hasSettledInitialPaginatorLayout = false;
            return { rendered: false, reason: 'error', message: error?.message ?? String(error) };
        }
    }
    #scheduleInitialPaginatorSettle(reason = 'unknown') {
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
        if (!a || !b) {
            return null;
        }
        const left = Math.max(a.left ?? -Infinity, b.left ?? -Infinity);
        const top = Math.max(a.top ?? -Infinity, b.top ?? -Infinity);
        const right = Math.min(a.right ?? Infinity, b.right ?? Infinity);
        const bottom = Math.min(a.bottom ?? Infinity, b.bottom ?? Infinity);
        if (!Number.isFinite(left) || !Number.isFinite(top) || !Number.isFinite(right) || !Number.isFinite(bottom)) {
            return null;
        }
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
        const navBar = document.getElementById('nav-bar');
        const readerStage = document.getElementById('reader-stage');
        const navBarRect = navBar?.getBoundingClientRect?.() ?? null;
        const readerStageRect = readerStage?.getBoundingClientRect?.() ?? null;
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
        try {
            const visibleFrame = Array.from(livePaginator?.shadowRoot?.querySelectorAll?.('iframe') ?? []).find((frame) => {
                const rect = frame?.getBoundingClientRect?.();
                return rect && rect.width > 0 && rect.height > 0;
            }) ?? null;
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
                `top=${computedStyle?.getPropertyValue('--mnb-obscured-top-inset')?.trim() || 'nil'}`,
                `toolbar=${computedStyle?.getPropertyValue('--mnb-toolbar-bottom-offset')?.trim() || 'nil'}`,
                `obscured=${computedStyle?.getPropertyValue('--mnb-obscured-bottom-inset')?.trim() || 'nil'}`,
                `system=${computedStyle?.getPropertyValue('--mnb-system-bottom-inset')?.trim() || 'nil'}`,
                `physical=${computedStyle?.getPropertyValue('--mnb-toolbar-physical-bottom-inset')?.trim() || 'nil'}`,
                `stage=${computedStyle?.getPropertyValue('--mnb-reader-stage-bottom-inset')?.trim() || 'nil'}`,
            ].join(' '),
            htmlCssInsets: [
                `top=${window.getComputedStyle(docEl)?.getPropertyValue('--mnb-obscured-top-inset')?.trim() || 'nil'}`,
                `toolbar=${window.getComputedStyle(docEl)?.getPropertyValue('--mnb-toolbar-bottom-offset')?.trim() || 'nil'}`,
                `obscured=${window.getComputedStyle(docEl)?.getPropertyValue('--mnb-obscured-bottom-inset')?.trim() || 'nil'}`,
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
            navBarRect: this.#formatRect(navBarRect),
            readerStageRect: this.#formatRect(readerStageRect),
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
    #logLayoutDiagnostics(reason = 'unknown', extra = null) {
        const layoutSnapshot = this.#buildLayoutSnapshot(reason, extra);
        postBookRotateLog('layout.snapshot', {
            reason,
            currentPercent: layoutSnapshot.currentPercent,
            cssInsets: layoutSnapshot.cssInsets,
            windowInnerBox: layoutSnapshot.windowInnerBox,
            visualViewportBox: layoutSnapshot.visualViewportBox,
            visualViewportOffset: layoutSnapshot.visualViewportOffset,
            documentClientBox: layoutSnapshot.documentClientBox,
            bodyClientBox: layoutSnapshot.bodyClientBox,
            livePaginatorBox: layoutSnapshot.livePaginatorBox,
            navBarRect: layoutSnapshot.navBarRect,
            readerStageRect: layoutSnapshot.readerStageRect,
            liveFoliateViewRect: layoutSnapshot.liveFoliateViewRect,
            livePaginatorRect: layoutSnapshot.livePaginatorRect,
            visibleTextRect: layoutSnapshot.visibleTextRect,
            visibleTextRectCount: layoutSnapshot.visibleTextRectCount,
            toolbarGapPx: layoutSnapshot.toolbarGapPx,
            stageGapPx: layoutSnapshot.stageGapPx,
            navHiddenClass: document.getElementById('nav-bar')?.classList?.contains('nav-hidden-due-to-scroll') ?? null,
            bodyLoading: layoutSnapshot.bodyLoading,
        });
        if (!layoutSnapshot.bodyLoading
            && typeof layoutSnapshot.currentPercent === 'number'
            && layoutSnapshot.livePaginatorBox != null) {
            markEPUBPerf('layout.ready.first', {
                reason,
                currentPercent: layoutSnapshot.currentPercent,
                livePaginatorBox: layoutSnapshot.livePaginatorBox,
                cssInsets: layoutSnapshot.cssInsets,
            }, {
                once: true,
                anchor: 'did-display.first',
            });
        }
        const hasLayoutAnomaly = [
            layoutSnapshot.toolbarGapPx,
            layoutSnapshot.toolbarGapLastRectPx,
            layoutSnapshot.stageGapPx,
        ].some((value) => typeof value === 'number' && Math.abs(value) > 120);
        const shouldLogLayout = !!globalThis.manabiVerboseLayout || hasLayoutAnomaly;
        const key = JSON.stringify(layoutSnapshot);
        if (key === this.lastLayoutDiagnosticsKey) {
            return;
        }
        this.lastLayoutSnapshot = layoutSnapshot;
        this.lastLayoutDiagnosticsKey = key;
        if (shouldLogLayout) {
            postEPUBLog('ebook.layout.diagnostics', layoutSnapshot);
        }
    }
    #renderPageTrackingButtons(reason = 'unspecified') {
        const container = document.getElementById('page-tracking-container');
        const buttonHost = document.getElementById('page-tracking-buttons');
        if (!(container instanceof HTMLElement) || !(buttonHost instanceof HTMLElement)) {
            return;
        }
        const pageTrackingStates = this.pageTrackingStates || [];
        const hasStates = pageTrackingStates.length > 0;
        const completionAction = this.completionAction;
        const shouldShowPageTracking = !!completionAction || hasStates;
        const renderStartedAt = performance.now();
        const visibleState = pageTrackingStates.find((state) => state.id === 'visible-screen') ?? null;
        const buttonBefore = document.querySelector('#page-tracking-buttons .page-read-button[data-page-tracking-id="visible-screen"]');
        this.#logMarkRead('pageTracking.render.beforeDOM', {
            reason,
            shouldShowPageTracking,
            stateCount: pageTrackingStates.length,
            visibleScreenIsRead: visibleState?.isRead ?? null,
            existingButtonReadAttr: buttonBefore?.getAttribute?.('data-mnb-tracking-section-read') ?? null,
            existingButtonReadState: buttonBefore?.getAttribute?.('data-read-state') ?? null,
            containerHiddenBefore: container.hidden,
            buttonHostHiddenBefore: buttonHost.hidden,
            timestamp: Math.round(renderStartedAt),
        });
        postMay4Log('pageTracking.render.beforeDOM', {
            reason,
            shouldShowPageTracking,
            stateCount: pageTrackingStates.length,
            visibleScreenIsRead: visibleState?.isRead ?? null,
            visibleSegmentCount: visibleState?.visibleSegmentCount ?? null,
            unreadVisibleSegmentCount: visibleState?.unreadVisibleSegmentCount ?? null,
            selectedSegmentCount: visibleState?.payload?.segments?.length ?? null,
            selectedSentenceCount: visibleState?.payload?.sentenceIdentifiers?.length ?? null,
            hasCompletionAction: !!completionAction,
            completionActionType: completionAction?.type ?? null,
            ...collectMay4ButtonSummary(),
        });
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
        this.#logMarkRead('pageTracking.render', {
            reason,
            shouldShowPageTracking,
            stateCount: pageTrackingStates.length,
            hasCompletionAction: !!completionAction,
            completionActionType: completionAction?.type ?? null,
            containerHidden: container.hidden,
            buttonHostHidden: buttonHost.hidden,
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
            navHidden: this.navHUD?.navHidden ?? null,
        });
        if (!shouldShowPageTracking) {
            buttonHost.innerHTML = '';
            this.#updatePageReadMarker(reason, null);
            this.navHUD?.refreshAuxiliaryLayout?.();
            postMay4Log('pageTracking.render.hidden', {
                reason,
                stateCount: pageTrackingStates.length,
                hasCompletionAction: !!completionAction,
                ...collectMay4ButtonSummary(),
            });
            this.#logMarkRead('pageTracking.render.timing', {
                reason,
                stateCount: pageTrackingStates.length,
                hasCompletionAction: !!completionAction,
                shouldShowPageTracking,
                elapsedMs: safeRound(performance.now() - renderStartedAt, 2),
            });
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
            postMay4Log('pageTracking.render.completionButton', {
                reason,
                completionActionType: completionAction.type,
                isBusy,
                ...collectMay4ButtonSummary(),
            });
            this.navHUD?.refreshAuxiliaryLayout?.();
            this.#scheduleInitialPaginatorSettle('page-tracking-render.completion-action');
            this.#queueLayoutDiagnostics('page-tracking-render', {
                completionAction: completionAction.type,
                stateCount: 0,
            });
            this.#logMarkRead('pageTracking.render.timing', {
                reason,
                stateCount: 0,
                hasCompletionAction: true,
                completionActionType: completionAction.type,
                shouldShowPageTracking,
                elapsedMs: safeRound(performance.now() - renderStartedAt, 2),
            });
            return;
        }
        buttonHost.innerHTML = pageTrackingStates.map((state) => {
            const isBusy = this.pageTrackingBusyStateIDs.has(state.id);
            const readState = isBusy ? 'pending' : (state.isRead ? 'complete' : 'ready');
            return `
                <button
                    class="page-read-button mnb-tracking-button"
                    data-page-tracking-id="${state.id}"
                    data-read-state="${readState}"
                    data-mnb-tracking-section-read="${state.isRead ? 'true' : 'false'}"
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
        const buttonAfter = document.querySelector('#page-tracking-buttons .page-read-button[data-page-tracking-id="visible-screen"]');
        postMay4Log('pageTracking.render.afterDOM', {
            reason,
            stateCount: pageTrackingStates.length,
            visibleScreenIsRead: visibleState?.isRead ?? null,
            visibleSegmentCount: visibleState?.visibleSegmentCount ?? null,
            unreadVisibleSegmentCount: visibleState?.unreadVisibleSegmentCount ?? null,
            selectedSegmentCount: visibleState?.payload?.segments?.length ?? null,
            selectedSentenceCount: visibleState?.payload?.sentenceIdentifiers?.length ?? null,
            ...collectMay4ButtonSummary(),
        });
        this.#logMarkRead('pageTracking.render.afterDOM', {
            reason,
            stateCount: pageTrackingStates.length,
            visibleScreenIsRead: visibleState?.isRead ?? null,
            buttonReadAttr: buttonAfter?.getAttribute?.('data-mnb-tracking-section-read') ?? null,
            buttonReadState: buttonAfter?.getAttribute?.('data-read-state') ?? null,
            buttonDisabled: buttonAfter instanceof HTMLButtonElement ? buttonAfter.disabled : null,
            markerReadAttr: document.body?.getAttribute?.('data-page-read-marker-read') ?? null,
            markerAxisAttr: document.body?.getAttribute?.('data-page-read-marker-axis') ?? null,
            elapsedMs: safeRound(performance.now() - renderStartedAt, 2),
        });
        requestAnimationFrame(() => {
            const buttonFrame = document.querySelector('#page-tracking-buttons .page-read-button[data-page-tracking-id="visible-screen"]');
            const buttonStyle = buttonFrame instanceof Element ? getComputedStyle(buttonFrame) : null;
            const markerSide = document.querySelector('.page-read-marker-side');
            const markerTop = document.getElementById('page-read-marker-top');
            const sideStyle = markerSide instanceof Element ? getComputedStyle(markerSide) : null;
            const topStyle = markerTop instanceof Element ? getComputedStyle(markerTop) : null;
            this.#logMarkRead('pageTracking.render.raf', {
                reason,
                buttonReadAttr: buttonFrame?.getAttribute?.('data-mnb-tracking-section-read') ?? null,
                buttonReadState: buttonFrame?.getAttribute?.('data-read-state') ?? null,
                buttonBackgroundColor: buttonStyle?.backgroundColor ?? null,
                buttonTransitionDuration: buttonStyle?.transitionDuration ?? null,
                markerReadAttr: document.body?.getAttribute?.('data-page-read-marker-read') ?? null,
                markerAxisAttr: document.body?.getAttribute?.('data-page-read-marker-axis') ?? null,
                sideMarkerVisibility: sideStyle?.visibility ?? null,
                sideMarkerOpacity: sideStyle?.opacity ?? null,
                topMarkerVisibility: topStyle?.visibility ?? null,
                topMarkerOpacity: topStyle?.opacity ?? null,
                elapsedMs: safeRound(performance.now() - renderStartedAt, 2),
            });
            postMay4Log('pageTracking.render.raf', {
                reason,
                stateCount: pageTrackingStates.length,
                visibleScreenIsRead: visibleState?.isRead ?? null,
                ...collectMay4ButtonSummary(),
            });
        });
        this.navHUD?.refreshAuxiliaryLayout?.();
        this.#scheduleInitialPaginatorSettle('page-tracking-render');
        this.#queueLayoutDiagnostics('page-tracking-render', {
            stateCount: pageTrackingStates.length,
        });
        this.#logMarkRead('pageTracking.render.timing', {
            reason,
            stateCount: pageTrackingStates.length,
            completedStateCount: pageTrackingStates.filter((state) => state.isRead).length,
            shouldShowPageTracking,
            elapsedMs: safeRound(performance.now() - renderStartedAt, 2),
        });
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
                this.buttons.next.click();
                return;
            }
        }
        this.#logPageTracking('ebook.pageTracking.markRead.advance', {
            mode: this.isRTL ? 'previous-visual-page' : 'next-visual-page',
        });
        this.#flashForwardSideNavChevron();
        this.#clearVisiblePageReadChrome('page-turn-start');
        if (this.isRTL) {
            await this.view.goLeft();
        } else {
            await this.view.goRight();
        }
    }
    #flashForwardSideNavChevron() {
        this.#flashSideNavChevron(this.isRTL ? 'left' : 'right');
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
        const firstTouch = event.changedTouches?.[0] ?? event.touches?.[0] ?? null;
        const startTarget = event.target;
        const startTargetDescription = startTarget
            ? `${startTarget.tagName || 'unknown'}${startTarget.id ? `#${startTarget.id}` : ''}${startTarget.className ? `.${String(startTarget.className).replace(/\s+/g, '.')}` : ''}`
            : null;
        if (manabiDiagnosticsEnabled()) console.log('# HIDENAV js.mainTouch.start.begin', JSON.stringify({
            touchCount: event.touches?.length ?? null,
            changedTouchCount: event.changedTouches?.length ?? null,
            clientX: firstTouch?.clientX ?? null,
            clientY: firstTouch?.clientY ?? null,
            screenX: firstTouch?.screenX ?? null,
            screenY: firstTouch?.screenY ?? null,
            innerHeight: window.innerHeight,
            visualViewportHeight: window.visualViewport?.height ?? null,
            target: startTargetDescription,
            targetOwnerIsMainDocument: startTarget?.ownerDocument === document,
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
        }));
        if (event.touches?.length !== 1) {
            this.#mainDocumentSwipeState = null;
            if (manabiDiagnosticsEnabled()) console.log('# HIDENAV js.mainTouch.start.skip', JSON.stringify({ reason: 'touch-count', touchCount: event.touches?.length ?? null }));
            return;
        }
        const touch = event.changedTouches?.[0];
        const target = event.target;
        if (!touch || !target || target.ownerDocument !== document) {
            this.#mainDocumentSwipeState = null;
            if (manabiDiagnosticsEnabled()) console.log('# HIDENAV js.mainTouch.start.skip', JSON.stringify({
                reason: 'missing-touch-or-non-main-document',
                hasTouch: !!touch,
                hasTarget: !!target,
                targetOwnerIsMainDocument: target?.ownerDocument === document,
            }));
            return;
        }
        const isExcludedTouchTarget = target.closest?.('#reader-stage, #side-bar, #page-tracking-container, #nav-hidden-overlay, .side-nav, input, textarea, select, button, a, [role="button"], [contenteditable="true"]');
        const isInteractiveNavTarget = target.closest?.('#progress-wrapper, #nav-section-progress-center, #nav-primary-text, #nav-hidden-primary-text, #nav-bottom-row input, #nav-bottom-row button, .nav-relocate-button');
        if (isExcludedTouchTarget || isInteractiveNavTarget) {
            this.#mainDocumentSwipeState = null;
            if (manabiDiagnosticsEnabled()) console.log('# HIDENAV js.mainTouch.start.skip', JSON.stringify({
                reason: 'excluded-target',
                target: startTargetDescription,
                isExcludedTouchTarget: !!isExcludedTouchTarget,
                isInteractiveNavTarget: !!isInteractiveNavTarget,
                insideNavBar: !!target.closest?.('#nav-bar'),
                clientX: touch.clientX,
                clientY: touch.clientY,
                innerHeight: window.innerHeight,
            }));
            return;
        }
        this.#mainDocumentSwipeState = {
            startX: touch.screenX,
            startY: touch.screenY,
            triggered: false,
        };
        if (manabiDiagnosticsEnabled()) console.log('# HIDENAV js.mainTouch.start.accept', JSON.stringify({
            startX: touch.screenX,
            startY: touch.screenY,
            clientX: touch.clientX,
            clientY: touch.clientY,
            distanceFromBottom: window.innerHeight - touch.clientY,
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
            insideNavBar: !!target.closest?.('#nav-bar'),
        }));
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
            return;
        }
        event.preventDefault();
        if (Math.abs(dx) <= minSwipe) {
            return;
        }
        state.triggered = true;
        const swipedLeft = dx < 0;
        const goForward = swipedLeft;
        this.#flashSideNavChevron(goForward
            ? (this.isRTL ? 'left' : 'right')
            : (this.isRTL ? 'right' : 'left'));
        if (goForward) {
            if (this.isRTL) {
                this.#clearVisiblePageReadChrome('page-turn-start');
                await this.view?.prev?.();
            } else {
                this.#clearVisiblePageReadChrome('page-turn-start');
                await this.view?.next?.();
            }
        } else {
            if (this.isRTL) {
                this.#clearVisiblePageReadChrome('page-turn-start');
                await this.view?.next?.();
            } else {
                this.#clearVisiblePageReadChrome('page-turn-start');
                await this.view?.prev?.();
            }
        }
    }
    #onMainDocumentTouchEnd() {
        if (manabiDiagnosticsEnabled()) console.log('# HIDENAV js.mainTouch.end', JSON.stringify({
            hadSwipeState: !!this.#mainDocumentSwipeState,
            triggered: this.#mainDocumentSwipeState?.triggered ?? null,
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
            innerHeight: window.innerHeight,
            visualViewportHeight: window.visualViewport?.height ?? null,
        }));
        this.#mainDocumentSwipeState = null;
    }
    async #syncPageTrackingButtons(reason = 'unspecified', explicitDoc = null, retryCount = 0) {
        const syncStartedAt = performance.now();
        this.#logMarkRead('pageState.sync.timing.start', {
            reason,
            retryCount,
            hasExplicitDoc: isDocumentLike(explicitDoc),
            hasLoadedLastPosition: globalThis.reader?.hasLoadedLastPosition ?? null,
            timestamp: Math.round(syncStartedAt),
        });
        const isRestorePending =
            reason === 'document-load'
            && globalThis.reader
            && globalThis.reader.hasLoadedLastPosition !== true;
        if (isRestorePending) {
            this.#logMarkRead('pageState.sync.timing.defer', {
                reason,
                retryCount,
                deferReason: 'restore-pending',
                elapsedMs: safeRound(performance.now() - syncStartedAt, 2),
            });
            postMay4Log('pageState.sync.defer', {
                reason,
                retryCount,
                deferReason: 'restore-pending',
                hasView: !!this.view,
                hasRenderer: !!this.view?.renderer,
                ...collectMay4ButtonSummary(),
            });
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
            this.pageTrackingStates = [];
            this.#renderPageTrackingButtons(reason);
            this.#logMarkRead('pageState.sync.timing.defer', {
                reason,
                retryCount,
                deferReason: 'no-document',
                contentsCount: contents.length,
                elapsedMs: safeRound(performance.now() - syncStartedAt, 2),
            });
            postMay4Log('pageState.sync.defer', {
                reason,
                retryCount,
                deferReason: 'no-document',
                contentsCount: contents.length,
                hasView: !!this.view,
                hasRenderer: !!this.view?.renderer,
                hasExplicitDoc: isDocumentLike(explicitDoc),
                ...collectMay4ButtonSummary(),
            });
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
        const visibleRange = this.navHUD?.lastRelocateDetail?.range?.commonAncestorContainer?.ownerDocument === doc
            || this.navHUD?.lastRelocateDetail?.range?.startContainer?.ownerDocument === doc
            ? this.navHUD.lastRelocateDetail.range
            : null;
        if (visibleRange?.collapsed === true && retryCount > 0) {
            this.#logMarkRead('pageState.sync.timing.defer', {
                reason,
                retryCount,
                deferReason: 'collapsed-visible-range',
                visibleRangeStartContainer: visibleRange.startContainer?.nodeName || null,
                visibleRangeEndContainer: visibleRange.endContainer?.nodeName || null,
                elapsedMs: safeRound(performance.now() - syncStartedAt, 2),
            });
            postMay4Log('pageState.sync.defer', {
                reason,
                retryCount,
                deferReason: 'collapsed-visible-range',
                ...collectMay4DocumentSummary(doc),
                ...collectMay4ButtonSummary(),
            });
            this.#queuePageTrackingRetry(reason, doc, retryCount);
            return;
        }
        this.#logMarkRead('pageState.sync.start', {
            reason,
            documentURL: doc.URL || doc.location?.href || null,
            retryCount,
            hasVisibleRange: !!visibleRange,
            visibleRangeStartContainer: visibleRange?.startContainer?.nodeName || null,
            visibleRangeEndContainer: visibleRange?.endContainer?.nodeName || null,
        });
        const {
            states,
            diagnostics,
        } = await buildVisiblePageTrackingStates(doc, this.articleReadingProgress, visibleRange);
        this.#logMarkRead('pageState.sync.end', {
            reason,
            documentURL: diagnostics.documentURL,
            retryCount,
            stateCount: diagnostics.stateCount,
            visibleSegmentCount: diagnostics.visibleSegmentCount,
            totalSegmentCount: diagnostics.totalSegmentCount,
            usedFoliateRange: !!visibleRange,
            elapsedMs: safeRound(performance.now() - syncStartedAt, 2),
        });
        const visibleScreenState = states.find((state) => state.id === 'visible-screen') ?? null;
        this.#logMarkRead('pageState.result', {
            reason,
            documentURL: diagnostics.documentURL,
            stateCount: diagnostics.stateCount,
            visibleSegmentCount: diagnostics.visibleSegmentCount,
            unreadVisibleSegmentCount: visibleScreenState?.unreadVisibleSegmentCount ?? 0,
            selectedSegmentCount: visibleScreenState?.payload?.segments?.length ?? 0,
            selectedSentenceCount: visibleScreenState?.payload?.sentenceIdentifiers?.length ?? 0,
            readSegmentCount: diagnostics.readSegmentCount,
            readSentenceCount: diagnostics.readSentenceCount,
            recoveredTextSearchStringCount: diagnostics.recoveredTextSearchStringCount,
            skippedMissingSearchStringCount: diagnostics.skippedMissingSearchStringCount,
            segmentIdentifierSample: (visibleScreenState?.payload?.segments ?? [])
                .map((segment) => segment.segmentIdentifier)
                .slice(0, 3),
            sentenceIdentifierSample: (visibleScreenState?.payload?.sentenceIdentifiers ?? []).slice(0, 3),
            usedFoliateRange: !!visibleRange,
        });
        postMay4Log('pageState.sync.result', {
            reason,
            documentURL: diagnostics.documentURL,
            retryCount,
            stateCount: diagnostics.stateCount,
            visibleSegmentCount: diagnostics.visibleSegmentCount,
            totalSegmentCount: diagnostics.totalSegmentCount,
            unreadVisibleSegmentCount: visibleScreenState?.unreadVisibleSegmentCount ?? null,
            selectedSegmentCount: visibleScreenState?.payload?.segments?.length ?? null,
            selectedSentenceCount: visibleScreenState?.payload?.sentenceIdentifiers?.length ?? null,
            outOfViewportCount: diagnostics.outOfViewportCount,
            viewportWidth: diagnostics.viewportWidth,
            viewportHeight: diagnostics.viewportHeight,
            clusterAxis: diagnostics.clusterAxis,
            usedFoliateRange: !!visibleRange,
            ...collectMay4DocumentSummary(doc),
            ...collectMay4ButtonSummary(),
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
            this.#logMarkRead('pageState.sync.timing.defer', {
                reason,
                retryCount,
                deferReason: 'zero-viewport-empty-document',
                elapsedMs: safeRound(performance.now() - syncStartedAt, 2),
            });
            postMay4Log('pageState.sync.defer', {
                reason,
                retryCount,
                deferReason: 'zero-viewport-empty-document',
                documentURL: diagnostics.documentURL,
                viewportWidth: diagnostics.viewportWidth,
                viewportHeight: diagnostics.viewportHeight,
                totalSegmentCount: diagnostics.totalSegmentCount,
                ...collectMay4DocumentSummary(doc),
                ...collectMay4ButtonSummary(),
            });
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
        const beforeRenderAt = performance.now();
        this.#renderPageTrackingButtons(reason);
        this.#updatePageReadMarker(reason, visibleScreenState, doc);
        this.#logMarkRead('pageState.sync.timing.end', {
            reason,
            retryCount,
            stateCount: diagnostics.stateCount,
            completedStateCount: diagnostics.completedStateCount,
            visibleSegmentCount: diagnostics.visibleSegmentCount,
            totalSegmentCount: diagnostics.totalSegmentCount,
            buildElapsedMs: safeRound(beforeRenderAt - syncStartedAt, 2),
            renderCallElapsedMs: safeRound(performance.now() - beforeRenderAt, 2),
            totalElapsedMs: safeRound(performance.now() - syncStartedAt, 2),
        });
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
        this.#logMarkRead('progress.apply', {
            reason,
            sessionID: this.markReadSessionID,
            documentURL: this.view?.renderer?.getContents?.()?.[0]?.doc?.URL || null,
            incomingReadSegmentCount,
            incomingSentenceReadCount,
            optimisticReadSegmentCount: this.optimisticReadSegmentIdentifiers.size,
            optimisticSentenceReadCount: this.optimisticSentenceIdentifiersRead.size,
            mergedOptimisticSegmentCount,
            mergedOptimisticSentenceCount,
            mergedReadSegmentCount: incomingProgress.readSegmentIdentifiers.length,
            mergedSentenceReadCount: incomingProgress.sentenceIdentifiersRead.length,
        });
        if (mergedOptimisticSegmentCount > 0 || mergedOptimisticSentenceCount > 0) {
            this.#logMarkRead('progress.mergeOptimistic', {
                reason,
                sessionID: this.markReadSessionID,
                documentURL: this.view?.renderer?.getContents?.()?.[0]?.doc?.URL || null,
                incomingReadSegmentCount,
                incomingSentenceReadCount,
                optimisticReadSegmentCount: this.optimisticReadSegmentIdentifiers.size,
                optimisticSentenceReadCount: this.optimisticSentenceIdentifiersRead.size,
                mergedOptimisticSegmentCount,
                mergedOptimisticSentenceCount,
                mergedReadSegmentCount: incomingProgress.readSegmentIdentifiers.length,
                mergedSentenceReadCount: incomingProgress.sentenceIdentifiersRead.length,
            });
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
        }
        this.#syncPageTrackingButtons('progress-applied', null, 2).catch((error) => console.error(error));
        this.#queueLayoutDiagnostics('progress-applied', {
            articleSentenceCount: this.articleReadingProgress.articleSentenceCount,
            readSegmentIdentifiers: this.articleReadingProgress.readSegmentIdentifiers.length,
        });
    }
    async #handleCompletionAction(actionType) {
        if (this.completionActionBusy) {
            this.#logMarkRead('completion.ignored', {
                actionType,
                reason: 'busy',
                currentAction: this.completionAction?.type ?? null,
            });
            return;
        }
        this.#logMarkRead('completion.click', {
            actionType,
            label: this.completionAction?.label ?? null,
            currentAction: this.completionAction?.type ?? null,
            markedAsFinished: this.markedAsFinished,
        });
        this.completionActionBusy = true;
        this.#renderPageTrackingButtons('completion-action-busy');
        this.#logMarkRead('completion.busy', {
            actionType,
            label: this.completionAction?.label ?? null,
        });
        try {
            switch (actionType) {
                case 'finish':
                    const sectionReadState = this.#currentSectionReadState();
                    this.#logMarkRead('completion.finish.readState', sectionReadState);
                    this.#logMarkRead('completion.finish.dispatch', {
                        actionType,
                        label: this.completionAction?.label ?? null,
                        allSectionsRead: sectionReadState.allSectionsRead,
                        currentPageNumber: sectionReadState.currentPageNumber,
                        totalPages: sectionReadState.totalPages,
                        pagesLeft: sectionReadState.pagesLeft,
                        segmentCount: sectionReadState.segmentCount,
                        unreadSegmentCount: sectionReadState.unreadSegmentCount,
                        optimisticReadSegmentCount: sectionReadState.optimisticReadSegmentCount,
                    });
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
                    this.#logMarkRead('completion.restart.dispatch', {
                        actionType,
                        label: this.completionAction?.label ?? null,
                    });
                    this.#clearOptimisticMarkReadState('restart');
                    window.webkit.messageHandlers.startOver.postMessage({});
                    await this.view?.renderer?.firstSection?.();
                    this.#logMarkRead('completion.restart.resetToFirstSection', {
                        actionType,
                    });
                    break;
                default:
                    this.#logMarkRead('completion.unknown', {
                        actionType,
                    });
                    break;
            }
        } finally {
            if (actionType !== 'finish') {
                this.completionActionBusy = false;
                this.#renderPageTrackingButtons('completion-action-finished');
                this.#logMarkRead('completion.idle', {
                    actionType,
                });
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
        const unreadSegmentCount = segmentIdentifiers
            .filter((identifier) => !readSegmentIdentifiers.has(identifier))
            .length;
        if (unreadSegmentCount > 0) {
            const unreadSegmentIdentifiers = segmentIdentifiers
                .filter((identifier) => !readSegmentIdentifiers.has(identifier));
            if (manabiDiagnosticsEnabled()) console.log('# UNREAD', JSON.stringify({
                event: 'js.currentSectionReadState.unreadSegments',
                documentURL: doc.URL || doc.location?.href || null,
                currentPageNumber,
                totalPages,
                pagesLeft,
                segmentCount: segmentIdentifiers.length,
                readSegmentCount: segmentIdentifiers.length - unreadSegmentCount,
                unreadSegmentCount,
                optimisticReadSegmentCount: this.optimisticReadSegmentIdentifiers.size,
                persistedReadSegmentCount: normalizeArticleReadingProgress(this.articleReadingProgress).readSegmentIdentifiers.length,
                unreadSegmentIdentifierSample: unreadSegmentIdentifiers.slice(0, 20),
            }));
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
    async markAllSectionsAsRead() {
        const contents = this.view?.renderer?.getContents?.() || [];
        const doc = contents[0]?.doc;
        if (!isDocumentLike(doc)) {
            if (manabiDiagnosticsEnabled()) console.log('# UNREAD', JSON.stringify({
                event: 'js.ebookMarkAllSectionsAsRead.skipped',
                reason: 'missing-document',
            }));
            return 0;
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
        if (manabiDiagnosticsEnabled()) console.log('# UNREAD', JSON.stringify({
            event: 'js.ebookMarkAllSectionsAsRead.dispatch',
            documentURL: doc.URL || doc.location?.href || null,
            segmentNodeCount: segmentNodes.length,
            payloadSegmentCount: payloadSegments.length,
            sentenceIdentifierCount: payloadSentenceIdentifiers.length,
            skippedMissingIdentifierCount,
            skippedMissingSearchStringCount,
            segmentIdentifierSample: payloadSegmentIdentifiers.slice(0, 20),
            segmentIdentifierTailSample: payloadSegmentIdentifiers.slice(-20),
        }));
        if (payloadSegments.length === 0) {
            return 0;
        }
        window.webkit.messageHandlers.markSectionAsRead.postMessage({
            segments: payloadSegments,
            sentenceIdentifiers: payloadSentenceIdentifiers,
        });
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
        if (manabiDiagnosticsEnabled()) console.log('# UNREAD', JSON.stringify({
            event: 'js.ebookMarkAllSectionsAsRead.optimisticApplied',
            documentURL: doc.URL || doc.location?.href || null,
            optimisticReadSegmentCount: optimisticProgress.readSegmentIdentifiers.length,
            optimisticSentenceReadCount: optimisticProgress.sentenceIdentifiersRead.length,
        }));
        return payloadSegments.length;
    }
    async #markPageClusterAsRead(stateID) {
        const pageTrackingState = this.pageTrackingStates.find((state) => state.id === stateID);
        if (!pageTrackingState) {
            this.#logMarkRead('markRead.skip', {
                reason: 'missing-state',
                stateID,
            });
            this.#logPageTracking('ebook.pageTracking.markRead.skip', {
                reason: 'missing-state',
                stateID,
            });
            return;
        }
        if (pageTrackingState.payload.segments.length === 0) {
            this.#logMarkRead('markRead.skip', {
                reason: 'empty-payload',
                stateID,
            });
            this.#logPageTracking('ebook.pageTracking.markRead.skip', {
                reason: 'empty-payload',
                stateID,
            });
            return;
        }
        if (pageTrackingState.isRead) {
            this.#logMarkRead('markRead.skip', {
                reason: 'already-read',
                stateID,
            });
            this.#logPageTracking('ebook.pageTracking.markRead.skip', {
                reason: 'already-read',
                stateID,
            });
            return;
        }
        this.#logMarkRead('markRead.click', {
            stateID,
            fullLabel: pageTrackingState.fullLabel,
            shortLabel: pageTrackingState.shortLabel,
            visibleSegmentCount: pageTrackingState.visibleSegmentCount,
            unreadVisibleSegmentCount: pageTrackingState.unreadVisibleSegmentCount,
            ...this.#summarizeMarkReadIDs(
                pageTrackingState.payload.segments.map((segment) => segment.segmentIdentifier),
                pageTrackingState.payload.sentenceIdentifiers,
            ),
        });
        this.#logPageTracking('ebook.pageTracking.markRead.start', {
            stateID,
            visibleSegmentCount: pageTrackingState.visibleSegmentCount,
            unreadVisibleSegmentCount: pageTrackingState.unreadVisibleSegmentCount,
            payloadSegmentCount: pageTrackingState.payload.segments.length,
            sentenceIdentifierCount: pageTrackingState.payload.sentenceIdentifiers.length,
        });
        this.pageTrackingBusyStateIDs.add(stateID);
        this.#logMarkRead('markRead.busy', {
            stateID,
            payloadSegmentCount: pageTrackingState.payload.segments.length,
            ...this.#summarizeMarkReadIDs(
                pageTrackingState.payload.segments.map((segment) => segment.segmentIdentifier),
                pageTrackingState.payload.sentenceIdentifiers,
            ),
        });
        this.#renderPageTrackingButtons('mark-read-busy');
        this.#logMarkRead('markRead.dispatch', {
            stateID,
            payloadSegmentCount: pageTrackingState.payload.segments.length,
            ...this.#summarizeMarkReadIDs(
                pageTrackingState.payload.segments.map((segment) => segment.segmentIdentifier),
                pageTrackingState.payload.sentenceIdentifiers,
            ),
        });
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
        this.applyBookReadingProgress(optimisticProgress, 'optimistic-mark-read');
        this.#logMarkRead('markRead.optimisticApplied', {
            stateID,
            readSegmentIdentifiers: optimisticProgress.readSegmentIdentifiers.length,
            sentenceIdentifiersRead: optimisticProgress.sentenceIdentifiersRead.length,
            ...this.#summarizeMarkReadIDs(
                pageTrackingState.payload.segments.map((segment) => segment.segmentIdentifier),
                pageTrackingState.payload.sentenceIdentifiers,
            ),
        });
        this.#logPageTracking('ebook.pageTracking.markRead.optimisticApplied', {
            stateID,
            readSegmentIdentifiers: optimisticProgress.readSegmentIdentifiers.length,
            sentenceIdentifiersRead: optimisticProgress.sentenceIdentifiersRead.length,
        });
        await this.#advanceAfterMarkRead();
    }
    async open(file) {
        postEPUBLoadLog('reader.open.begin', collectEPUBLoadDiagnostics('reader.open.begin', {
            fileKind: file?.kind || 'nil',
            initialLayoutMode: typeof window.initialLayoutMode !== 'undefined' ? window.initialLayoutMode : null,
        }));
        postEPUBFlashLog('js.reader.open.beforeLoading', {
            fileKind: file?.kind || 'nil',
        });
        this.setLoadingIndicator(true);
        const readerOpenStartedAt = typeof performance !== 'undefined' && typeof performance.now === 'function'
            ? performance.now()
            : Date.now();
        markEPUBPerf('reader.open.begin', {
            fileKind: file?.kind || 'nil',
            initialLayoutMode: typeof window.initialLayoutMode !== 'undefined' ? window.initialLayoutMode : null,
        });
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
        postEPUBLoadLog('reader.open.view.ready', collectEPUBLoadDiagnostics('reader.open.view.ready', {
            hasRenderer: !!this.view?.renderer,
            hasBook: !!this.view?.book,
        }));
        markEPUBPerf('view.ready', {
            hasRenderer: !!this.view?.renderer,
            hasBook: !!this.view?.book,
        });
        postReaderVisibilityProbe('reader.open:view-assigned', this.view, null);
        // this.view.renderer.setAttribute('animated', true) // Flows top to bottom instead of like a book...
        if (typeof window.initialLayoutMode !== 'undefined') {
            this.view.renderer.setAttribute('flow', window.initialLayoutMode)
        }
        this.view.renderer.addEventListener('goTo', this.#onGoTo.bind(this))
        this.view.renderer.addEventListener('didDisplay', this.#onDidDisplay.bind(this))
        this.view.addEventListener('load', this.#onLoad.bind(this))
        this.view.addEventListener('relocate', this.#onRelocate.bind(this))
        postEPUBLoadLog('reader.open.listeners.ready', collectEPUBLoadDiagnostics('reader.open.listeners.ready', {
            rendererFlow: this.view.renderer?.getAttribute?.('flow') || null,
        }));
        
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
        applyStoredChromeInsets('reader.open');
        postEPUBLoadLog('reader.open.before-view-open', collectEPUBLoadDiagnostics('reader.open.before-view-open', {
            bookDir: this.bookDir,
            isRTL: this.isRTL,
            sectionCount: Array.isArray(book.sections) ? book.sections.length : null,
            pageListCount: Array.isArray(book.pageList) ? book.pageList.length : null,
        }));
        markEPUBPerf('renderer.ready', {
            bookDir: this.bookDir,
            isRTL: !!this.isRTL,
            sectionCount: Array.isArray(book?.sections) ? book.sections.length : null,
            pageTargetCount: Array.isArray(book?.pageList) ? book.pageList.length : null,
        });
        //        this.view.renderer.next()
        
        $('#nav-bar').style.visibility = 'visible'
        postReaderVisibilityProbe('reader.open:nav-visible', this.view, {
            initialLayoutMode: typeof window.initialLayoutMode !== 'undefined' ? window.initialLayoutMode : null,
        });
        this.#queueLayoutDiagnostics('reader-open', {
            isRTL: this.isRTL,
            bookDir: this.bookDir,
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
        const leftSideBtn = document.getElementById('btn-scroll-left');
        if (leftSideBtn) leftSideBtn.addEventListener('click', async () => {
            this.#clearVisiblePageReadChrome('page-turn-start');
            await this.view.goLeft();
        });
        const rightSideBtn = document.getElementById('btn-scroll-right');
        if (rightSideBtn) rightSideBtn.addEventListener('click', async () => {
            this.#clearVisiblePageReadChrome('page-turn-start');
            await this.view.goRight();
        });
        
        // Immediate tap feedback for side-nav chevrons on iOS/touch
        document.querySelectorAll('.side-nav').forEach(nav => {
            nav.addEventListener('touchstart', () => {
                nav.classList.add('pressed');
            }, {
                passive: true
            });
            nav.addEventListener('touchend', () => {
                nav.classList.remove('pressed');
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
                if (!elem) return;
                
                clearTimeout(this.#chevronFadeTimers[key]);
                this.#chevronFadeTimers[key] = null;
                
                // Show chevron at full opacity
                if (Number(value) >= 1) {
                    elem.style.removeProperty('opacity');
                    elem.classList.add('chevron-visible');
                    return;
                }
                
                // Show chevron at partial opacity
                if (Number(value) > 0) {
                    elem.classList.remove('chevron-visible');
                    elem.style.opacity = value;
                    return;
                }
                
                // Hide chevron, but only after a delay and only if currently visible
                if (elem.classList.contains('chevron-visible')) {
                    this.#chevronFadeTimers[key] = setTimeout(() => {
                        elem.classList.remove('chevron-visible');
                        elem.style.removeProperty('opacity');
                        this.#chevronFadeTimers[key] = null;
                    }, FADER_DELAY);
                } else {
                    // Already hidden: do nothing
                    elem.style.removeProperty('opacity');
                    elem.classList.remove('chevron-visible');
                }
            };
            
            fadeWithHold(l, e.detail.leftOpacity, 'l');
            fadeWithHold(r, e.detail.rightOpacity, 'r');
        });
        // Listen for resetSideNavChevrons custom event to reset chevrons
        document.addEventListener('resetSideNavChevrons', () => this.#resetSideNavChevrons());
        
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
        
        const processTouchStart = function(event) {
            // Ignore touches inside foliate-js viewer iframe
            if (event.target && event.target.ownerDocument !== document) return
            if (event.target?.closest?.('#reader-stage, #side-bar, #page-tracking-container, #nav-bar, #nav-hidden-overlay, .side-nav, input, textarea, select, [contenteditable="true"]')) return
                
                window.webkit?.messageHandlers?.touchstartCallbackHandler?.postMessage?.({
                    touchedEntryWithElementId: null,
                    wasAlreadySelected: false,
                })
                }
        document.addEventListener('touchstart', processTouchStart, {
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
                await runWithEPUBFlashNavigationIntent({
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
        markEPUBPerf('toc.ready', {
            hasTOC: !!toc,
            tocCount: Array.isArray(toc) ? toc.length : 'nil',
            hasTOCView: !!this.#tocView,
        });
        
        // load and show highlights embedded in the file by Calibre
        postReaderLog('ebook.readerOpen.calibreBookmarks.start', {
            hasMethod: typeof book.getCalibreBookmarks === 'function',
        });
        postEPUBLoadLog('reader.open.calibre-bookmarks.start', collectEPUBLoadDiagnostics('reader.open.calibre-bookmarks.start', {
            hasMethod: typeof book.getCalibreBookmarks === 'function',
        }));
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
            postEPUBLoadLog('reader.open.calibre-bookmarks.error', collectEPUBLoadDiagnostics('reader.open.calibre-bookmarks.error', {
                message: error?.message || String(error),
                stack: error?.stack || null,
            }));
            postReaderLog('ebook.readerOpen.calibreBookmarks.error', {
                message: error?.message || String(error),
            });
            throw error;
        }
        clearTimeout(calibreBookmarksPendingTimer);
        postEPUBLoadLog('reader.open.calibre-bookmarks.end', collectEPUBLoadDiagnostics('reader.open.calibre-bookmarks.end', {
            pendingLogged: calibreBookmarksPendingLogged,
            bookmarkCount: Array.isArray(bookmarks) ? bookmarks.length : 'nil',
        }));
        postReaderLog('ebook.readerOpen.calibreBookmarks.end', {
            pendingLogged: calibreBookmarksPendingLogged,
            bookmarkCount: Array.isArray(bookmarks) ? bookmarks.length : 'nil',
        });
        markEPUBPerf('bookmarks.ready', {
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
        postEPUBLoadLog('reader.open.end', collectEPUBLoadDiagnostics('reader.open.end', {
            elapsedMs: Math.round(
                (typeof performance !== 'undefined' && typeof performance.now === 'function'
                    ? performance.now()
                    : Date.now()) - readerOpenStartedAt
            ),
            hasRenderer: !!this.view?.renderer,
            bodyClassName: document.body?.className || 'nil',
        }));
        markEPUBPerf('reader.open.end', {
            elapsedMs: safeRound(
                (typeof performance !== 'undefined' && typeof performance.now === 'function'
                    ? performance.now()
                    : Date.now()) - readerOpenStartedAt,
                1,
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
                    label: 'Start Over',
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
            if (this.isRTL) {
                // In RTL, left chevron = go forward, right chevron = go backward
                // Disable left at end, right at start
                btnScrollLeft.disabled = (atSectionEnd && !hasNextSection);
                btnScrollRight.disabled = (atSectionStart && !hasPrevSection);
            } else {
                // LTR, left chevron = backward, right chevron = forward
                // Disable left at start, right at end
                btnScrollLeft.disabled = (atSectionStart && !hasPrevSection);
                btnScrollRight.disabled = (atSectionEnd && !hasNextSection);
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
            markedAsFinished: this.markedAsFinished,
            restartHiddenForMiddlePageWhileNavHidden: isRestartHiddenForMiddlePageWhileNavHidden,
            showingFinish: !!(completionAction?.type === 'finish'),
            showingRestart: !!(completionAction?.type === 'restart'),
            before: navVisibilityBefore,
            after: captureNavVisibilityState(),
        });
        this.#syncPageTrackingButtons('nav-buttons', null, 1).catch((error) => console.error(error));
        this.#queueLayoutDiagnostics('nav-buttons', {
            markedAsFinished: this.markedAsFinished,
            restartHiddenForMiddlePageWhileNavHidden: isRestartHiddenForMiddlePageWhileNavHidden,
            showingFinish: !!(completionAction?.type === 'finish'),
            showingRestart: !!(completionAction?.type === 'restart'),
            showPrev: !!(this.buttons.prev && !this.buttons.prev.hidden),
            showNext: !!(this.buttons.next && !this.buttons.next.hidden),
        });
    }
    async #handleKeydown(event) {
        const k = event.key;
        const renderer = this.view.renderer;
        const isRTL = this.isRTL;
        
        if (k === 'ArrowLeft' || k === 'h') {
            if (isRTL && await renderer.atEnd()) {
                this.buttons.next.click();
            } else if (!isRTL && await renderer.atStart()) {
                this.buttons.prev.click();
            } else {
                this.#clearVisiblePageReadChrome('page-turn-start');
                await this.view.goLeft();
            }
        } else if (k === 'ArrowRight' || k === 'l') {
            if (isRTL && await renderer.atStart()) {
                this.buttons.prev.click();
            } else if (!isRTL && await renderer.atEnd()) {
                this.buttons.next.click();
            } else {
                this.#clearVisiblePageReadChrome('page-turn-start');
                await this.view.goRight();
            }
        }
    }
    #onGoTo({
        willLoadNewIndex
    }) {
        this.#clearVisiblePageReadChrome('goTo');
        postEPUBFlashLog('js.renderer.goTo', {
            willLoadNewIndex: !!willLoadNewIndex,
            intent: globalThis.__manabiEPUBFlashNavigationIntent ?? null,
        });
        if (!willLoadNewIndex) {
            postEPUBFlashLog('js.renderer.goTo.skipLoading', {
                reason: 'same-index',
                intent: globalThis.__manabiEPUBFlashNavigationIntent ?? null,
            });
            return;
        }
        this.setLoadingIndicator(true);
    }
    async #onDidDisplay({}) {
        const navVisibilityBefore = captureNavVisibilityState();
        postEPUBLoadLog('renderer.didDisplay.begin', collectEPUBLoadDiagnostics('renderer.didDisplay.begin', {
            rendererPageCurrent: this.navHUD?.rendererPageSnapshot?.current ?? null,
            rendererPageTotal: this.navHUD?.rendererPageSnapshot?.total ?? null,
        }));
        postEPUBFlashLog('js.renderer.didDisplay.beforeLoadingClear', {
            rendererPageCurrent: this.navHUD?.rendererPageSnapshot?.current ?? null,
            rendererPageTotal: this.navHUD?.rendererPageSnapshot?.total ?? null,
            visual: captureEPUBFlashVisualState(this.view),
        });
        applyStoredChromeInsets('reader.didDisplay');
        const initialSettleResult = await this.#settleInitialPaginatorLayout('did-display.pre-clear', {
            allowWhileLoading: true,
        });
        if (initialSettleResult?.rendered || initialSettleResult?.forcedRender) {
            postEPUBFlashLog('js.renderer.didDisplay.preClearSettle', {
                result: initialSettleResult,
                rendererPageCurrent: this.navHUD?.rendererPageSnapshot?.current ?? null,
                rendererPageTotal: this.navHUD?.rendererPageSnapshot?.total ?? null,
                visual: captureEPUBFlashVisualState(this.view),
            });
        }
        this.setLoadingIndicator(false);
        try {
            globalThis.__manabiFinishEPUBLoadWatchdogs?.('didDisplay.loading-cleared');
        } catch (_error) {}
        postEPUBLoadLog('renderer.didDisplay.loading-cleared', collectEPUBLoadDiagnostics('renderer.didDisplay.loading-cleared', {
            rendererPageCurrent: this.navHUD?.rendererPageSnapshot?.current ?? null,
            rendererPageTotal: this.navHUD?.rendererPageSnapshot?.total ?? null,
        }));
        postEPUBFlashLog('js.renderer.didDisplay.afterLoadingClear', {
            rendererPageCurrent: this.navHUD?.rendererPageSnapshot?.current ?? null,
            rendererPageTotal: this.navHUD?.rendererPageSnapshot?.total ?? null,
            visual: captureEPUBFlashVisualState(this.view),
        });
        if (this.navHUD?.hideNavigationDueToScroll) {
            this.navHUD.setHideNavigationDueToScroll(true, 'reader.didDisplay.reapply', {
                stage: 'before-raf',
            });
        }
        postPageNumLog('nav.visibility.did-display', {
            before: navVisibilityBefore,
            after: captureNavVisibilityState(),
        });
        this.#scheduleInitialPaginatorSettle('did-display');
        markEPUBPerf('did-display.first', {
            hasRenderer: !!this.view?.renderer,
        }, {
            once: true,
            anchor: 'document.animation-frame.first',
        });
        requestAnimationFrame(() => {
            const livePaginator = resolveFoliatePaginator(this.view);
            const livePaginatorContainer = livePaginator?.shadowRoot?.getElementById?.('container') || null;
            postEPUBFlashLog('js.renderer.didDisplay.raf', {
                rendererPageCurrent: this.navHUD?.rendererPageSnapshot?.current ?? null,
                rendererPageTotal: this.navHUD?.rendererPageSnapshot?.total ?? null,
                visual: captureEPUBFlashVisualState(this.view),
            });
            markEPUBPerf('did-display.raf.first', {
                paginatorClientWidth: livePaginatorContainer?.clientWidth ?? null,
                paginatorClientHeight: livePaginatorContainer?.clientHeight ?? null,
                ...captureEPUBOverlapState(),
            }, {
                once: true,
                anchor: 'did-display.first',
            });
            this.#queueLayoutDiagnostics('did-display', {
                paginatorClientWidth: livePaginatorContainer?.clientWidth ?? null,
                paginatorClientHeight: livePaginatorContainer?.clientHeight ?? null,
            });
            for (const content of this.view?.renderer?.getContents?.() || []) {
                postShortLineLog('did-display.raf', {
                    index: content.index ?? null,
                    ...collectShortLineDiagnosticsForDocument(content.doc, {
                        reason: 'did-display.raf',
                    }),
                });
            }
            this.#updatePageReadMarker('did-display.raf');
            setTimeout(() => {
                for (const content of this.view?.renderer?.getContents?.() || []) {
                    postShortLineLog('did-display.750ms', {
                        index: content.index ?? null,
                        ...collectShortLineDiagnosticsForDocument(content.doc, {
                            reason: 'did-display.750ms',
                        }),
                    });
                }
                postEPUBFlashLog('js.renderer.didDisplay.750ms', {
                    rendererPageCurrent: this.navHUD?.rendererPageSnapshot?.current ?? null,
                    rendererPageTotal: this.navHUD?.rendererPageSnapshot?.total ?? null,
                    visual: captureEPUBFlashVisualState(this.view),
                });
            }, 750);
        });
        postReaderVisibilityProbe('reader.didDisplay', this.view, null);
    }
    #onLoad({
        detail: {
            doc
        }
    }) {
        applyStoredChromeInsets('reader.documentLoad');
        markEPUBPerf('document.load.first', {
            documentURL: doc?.location?.href || null,
            isCacheWarmerDocument: doc?.body?.dataset?.isCacheWarmer === 'true',
        }, {
            once: true,
        });
        if (!isCacheWarmerDocument(doc)) {
            markEPUBPerf('document.load.first-non-cache', {
                documentURL: doc?.location?.href || null,
                ...summarizeDocumentFontState(doc),
                ...captureEPUBOverlapState(),
            }, {
                once: true,
            });
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
                ...captureDocumentFontApplicationState(doc),
                ...captureEPUBOverlapState(),
            });
        }
        postEPUBLog('ebook.perf.document.fonts.state', {
            documentURL: doc?.location?.href || null,
            ...summarizeDocumentFontState(doc),
            ...captureEPUBOverlapState(),
        });
        postFontLog('ebook.document.fonts.state', {
            documentURL: doc?.location?.href || null,
            ...summarizeDocumentFontState(doc),
            outerHasCustomFontStyle: !!document.getElementById('mnb-custom-fonts-inline'),
            ebookHasCustomFontStyle: !!doc?.getElementById?.('mnb-custom-fonts-inline'),
            ebookInjectedFontFamily: doc?.documentElement?.dataset?.mnbInjectedFontFamily ?? null,
            ebookFontInjected: doc?.documentElement?.dataset?.mnbFontInjected ?? null,
            ...captureDocumentFontApplicationState(doc),
        });
        try {
            window.manabiForwardReaderFontToEbookDocuments?.('document-load', doc);
        } catch (error) {
            try {
                window.webkit?.messageHandlers?.print?.postMessage?.('# FONT ' + JSON.stringify({
                    event: 'ebook.document.fonts.forward.error',
                    timestamp: Date.now(),
                    documentURL: doc?.location?.href || null,
                    message: error?.message || String(error),
                }));
            } catch {}
        }
        if (doc?.fonts?.ready?.then) {
            const fontsReadyStartedAt = performanceNowMs();
            doc.fonts.ready.then(() => {
                postEPUBLog('ebook.perf.document.fonts.ready', {
                    documentURL: doc?.location?.href || null,
                    elapsedMs: safeRound(performanceNowMs() - fontsReadyStartedAt, 1),
                    ...summarizeDocumentFontState(doc),
                    bodyTextLength: doc?.body?.innerText?.length ?? null,
                });
                try {
                    window.webkit?.messageHandlers?.print?.postMessage?.('# FONT ' + JSON.stringify({
                        event: 'ebook.document.fonts.ready',
                        timestamp: Date.now(),
                        documentURL: doc?.location?.href || null,
                        elapsedMs: safeRound(performanceNowMs() - fontsReadyStartedAt, 1),
                        ...summarizeDocumentFontState(doc),
                        ...captureDocumentFontApplicationState(doc),
                        bodyTextLength: doc?.body?.innerText?.length ?? null,
                    }));
                } catch {}
                if (!isCacheWarmerDocument(doc)) {
                    markEPUBPerf('document.fonts.ready.first', {
                        documentURL: doc?.location?.href || null,
                        elapsedMs: safeRound(performanceNowMs() - fontsReadyStartedAt, 1),
                        bodyTextLength: doc?.body?.innerText?.length ?? null,
                        ...captureEPUBOverlapState(),
                    }, {
                        once: true,
                    });
                    postReplaceTextPerfLog('document.fonts.ready.first', {
                        documentURL: doc?.location?.href || null,
                        elapsedMs: safeRound(performanceNowMs() - fontsReadyStartedAt, 1),
                        bodyTextLength: doc?.body?.innerText?.length ?? null,
                        bodyScrollHeight: doc?.body?.scrollHeight ?? null,
                        outerHasCustomFontStyle: !!document.getElementById('mnb-custom-fonts-inline'),
                        ebookHasCustomFontStyle: !!doc?.getElementById?.('mnb-custom-fonts-inline'),
                        ebookCustomFontTag: doc?.getElementById?.('mnb-custom-fonts-inline')?.tagName || null,
                        ebookCustomFontHref: doc?.getElementById?.('mnb-custom-fonts-inline')?.href || null,
                        ...summarizeDocumentFontState(doc),
                        ...captureDocumentFontApplicationState(doc),
                        ...captureEPUBOverlapState(),
                    });
                }
            }).catch((error) => {
                postEPUBLog('ebook.perf.document.fonts.ready.error', {
                    documentURL: doc?.location?.href || null,
                    message: error?.message || String(error),
                    ...summarizeDocumentFontState(doc),
                });
            });
        }
        requestAnimationFrame(() => {
            const sourceHref = doc?.body?.dataset?.mnbSourceHref || null;
            postEPUBLog('ebook.perf.document.animation-frame', {
                documentURL: doc?.location?.href || null,
                sourceHref,
                bodyTextLength: doc?.body?.innerText?.length ?? null,
                bodyScrollHeight: doc?.body?.scrollHeight ?? null,
                ...summarizeDocumentFontState(doc),
                ...captureEPUBOverlapState(),
            });
            if (!isCacheWarmerDocument(doc)) {
                window.manabi_recordLiveSettledSection?.(sourceHref);
                markEPUBPerf('document.animation-frame.first', {
                    documentURL: doc?.location?.href || null,
                    sourceHref,
                    bodyTextLength: doc?.body?.innerText?.length ?? null,
                    bodyScrollHeight: doc?.body?.scrollHeight ?? null,
                    ...captureEPUBOverlapState(),
                }, {
                    once: true,
                });
                postReplaceTextPerfLog('document.animation-frame.first', {
                    documentURL: doc?.location?.href || null,
                    sourceHref,
                    bodyTextLength: doc?.body?.innerText?.length ?? null,
                    bodyScrollHeight: doc?.body?.scrollHeight ?? null,
                    ...captureEPUBOverlapState(),
                });
            }
        });
        doc.addEventListener('keydown', this.#handleKeydown.bind(this))
        installRestorePositionSaveUserInputTracking(doc, 'reader-document');
        window.webkit.messageHandlers.updateCurrentContentPage.postMessage({
            topWindowURL: window.top.location.href,
            currentPageURL: doc.location.href,
        })
        requestAnimationFrame(() => this.#syncPageTrackingButtons('document-load', doc, 2).catch((error) => console.error(error)));
        postReaderVisibilityProbe('reader.documentLoad', this.view, {
            documentURL: doc?.location?.href || null,
        });
        this.#queueLayoutDiagnostics('document-load', {
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
        [leftIcon, rightIcon].forEach(icon => {
            if (!icon) return;
            icon.classList.remove('chevron-visible');
            icon.style.opacity = '';
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
        window.webkit.messageHandlers.updateReadingProgress.postMessage({
            fractionalCompletion: fraction,
            cfi: cfi,
            reason: reason,
            mainDocumentURL: mainDocumentURL,
            currentPageNumber: currentPageNumber,
            totalPages: totalPages,
            sectionIndex: sectionIndex,
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
        await this.navHUD?.handleRelocate(detail);
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
        postEbookRestoreLog('js.position.candidate', progressBridgePayload);
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
                postEbookRestoreLog('js.position.save.skip', {
                    ...progressBridgePayload,
                    skipReason: normalizedRelocateReason === 'anchor'
                        ? 'anchor-relocate'
                        : (
                            requiresUserInputBeforePositionSave
                                ? 'restore-awaiting-user-input'
                                : (shouldSuppressRestoreSettleSave ? 'restore-settle-relocate' : 'unknown')
                        ),
                });
                postMarkReadLog('position.save.skip', {
                    reason: reason ?? null,
                    skipReason: normalizedRelocateReason === 'anchor'
                        ? 'anchor-relocate'
                        : (
                            requiresUserInputBeforePositionSave
                                ? 'restore-awaiting-user-input'
                                : (shouldSuppressRestoreSettleSave ? 'restore-settle-relocate' : 'unknown')
                        ),
                    fraction: Number.isFinite(effectiveFraction) ? safeRound(effectiveFraction, 6) : null,
                    rawFraction: typeof fraction === 'number' ? safeRound(fraction, 6) : null,
                    displayPercent: roundedDisplayPercent(Number.isFinite(effectiveFraction) ? effectiveFraction : fraction),
                    currentPercent,
                    sectionIndex,
                    localSectionIndex,
                    rendererTotal,
                    cfiMode: shouldPreferSyntheticRestoreLocator
                        ? 'synthetic'
                        : (typeof cfi === 'string' && cfi ? 'cfi' : 'empty'),
                    hasLoadedLastPosition: this.hasLoadedLastPosition,
                    restoreRequestedFraction: Number.isFinite(globalThis.__manabiRequestedRestoreFraction)
                        ? safeRound(globalThis.__manabiRequestedRestoreFraction, 6)
                        : null,
                    restoreRequestedDisplayPercent: roundedDisplayPercent(globalThis.__manabiRequestedRestoreFraction),
                    suppressNextRestoreRelocateSave: globalThis.__manabiSuppressNextRestoreRelocateSave === true,
                    requiresUserInputBeforePositionSave,
                });
            } else {
                postEbookRestoreLog('js.position.save.dispatch', progressBridgePayload);
                postMarkReadLog('position.save.dispatch', {
                    reason: reason ?? null,
                    fraction: Number.isFinite(effectiveFraction) ? safeRound(effectiveFraction, 6) : null,
                    rawFraction: typeof fraction === 'number' ? safeRound(fraction, 6) : null,
                    displayPercent: roundedDisplayPercent(Number.isFinite(effectiveFraction) ? effectiveFraction : fraction),
                    currentPercent,
                    sectionIndex,
                    localSectionIndex,
                    rendererTotal,
                    cfiMode: shouldPreferSyntheticRestoreLocator
                        ? 'synthetic'
                        : (typeof cfi === 'string' && cfi ? 'cfi' : 'empty'),
                    cfiLooksSectionBase,
                    cfiIsUnstableAcrossPages,
                    hasLoadedLastPosition: this.hasLoadedLastPosition,
                });
                this.#postUpdateReadingProgressMessage({
                    fraction: Number.isFinite(effectiveFraction) ? effectiveFraction : fraction,
                    cfi: persistedLocator,
                    reason,
                    currentPageNumber: null,
                    totalPages: null,
                    sectionIndex,
                })
            }
        }
        
        await this.updateNavButtons();
        markEPUBPerf('relocate.first', {
            reason: detail?.reason || null,
            fraction: safeRound(detail?.fraction),
            currentPercent,
            currentLocation: detail?.location?.current ?? null,
            totalLocation: detail?.location?.total ?? null,
        }, {
            once: true,
            anchor: 'did-display.first',
        });
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
        this.#logMarkRead('relocate.timing', {
            reason: detail?.reason || null,
            hasRange: !!detail?.range,
            currentPercent,
            currentLocation: detail?.location?.current ?? null,
            totalLocation: detail?.location?.total ?? null,
            pageTrackingStateCount: this.pageTrackingStates.length,
            completedPageTrackingStateCount: this.pageTrackingStates.filter((state) => state.isRead).length,
            timestamp: Math.round(performance.now()),
        });
        this.#queueLayoutDiagnostics('relocate', {
            reason: detail?.reason || null,
            currentPercent,
        });
        postReaderVisibilityProbe('reader.relocate', this.view, {
            reason: detail?.reason || null,
            fraction: safeRound(detail?.fraction),
            currentLocation: detail?.location?.current ?? null,
            totalLocation: detail?.location?.total ?? null,
        });
        this.#queueLayoutDiagnostics('relocate', {
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
    #nextUnsettledSectionIndex(settledSectionHrefs = []) {
        const sections = Array.isArray(this.view?.book?.sections) ? this.view.book.sections : []
        const settled = new Set(
            Array.isArray(settledSectionHrefs)
                ? settledSectionHrefs.map((href) => this.#normalizeSectionHref(href)).filter(Boolean)
                : []
        )
        const activeHref = activeForegroundSectionHref()
        if (activeHref) settled.add(activeHref)
        const currentIndex = Number.isInteger(this.lastLoadedSectionIndex) ? this.lastLoadedSectionIndex : -1
        for (let index = currentIndex + 1; index < sections.length; index += 1) {
            const section = sections[index]
            if (section?.linear === 'no') continue
            const normalizedHref = this.#normalizeSectionHref(section?.href ?? section?.id ?? null)
            if (normalizedHref && settled.has(normalizedHref)) continue
            return index
        }
        return null
    }
    async #openFirstUnsettledSection() {
        const settledSectionHrefs = this.#mergeSettledSectionHrefs()
        const firstUnsettledIndex = this.#nextUnsettledSectionIndex(settledSectionHrefs)
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
            settledSectionCount: settledSectionHrefs.length,
            settledSectionHrefs,
            sectionCount: this.view?.book?.sections?.length ?? 0,
            sectionSample,
            ...captureEPUBOverlapState(),
        })
        if (!Number.isInteger(firstUnsettledIndex)) {
            globalThis.__manabiCacheWarmerFinished = true
            postEPUBLog('ebook.perf.cache-warmer.finished', {
                sectionURL: null,
                sectionIndex: null,
                highestSectionIndex: globalThis.__manabiCacheWarmerHighestSectionIndex ?? null,
                uniqueSentenceCount: this.uniqueSentenceIdentifiers.size,
                trigger: 'open-no-unsettled',
                ...captureEPUBOverlapState(),
            })
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
            postEPUBLog('ebook.perf.cache-warmer.skip-settled', {
                trigger: 'open',
                skippedToSectionIndex: firstUnsettledIndex,
                skippedToSectionHref: targetSection?.href ?? targetSection?.id ?? null,
                skippedSettledSectionHrefs,
                settledSectionCount: settledSectionHrefs.length,
                ...captureEPUBOverlapState(),
            })
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
        await runWithEPUBFlashNavigationIntent({
            source: 'cache-warmer.open',
            target: 'renderer.goTo',
            sectionIndex: firstUnsettledIndex,
        }, () => this.view.renderer.goTo({ index: firstUnsettledIndex }))
    }
    async loadNextSectionSkippingSettled(settledSectionHrefs = []) {
        settledSectionHrefs = this.#mergeSettledSectionHrefs(settledSectionHrefs)
        const targetIndex = this.#nextUnsettledSectionIndex(settledSectionHrefs)
        if (!Number.isInteger(targetIndex)) {
            globalThis.__manabiCacheWarmerFinished = true
            postEPUBLog('ebook.perf.cache-warmer.finished', {
                sectionURL: this.lastLoadedSectionHref,
                sectionIndex: this.lastLoadedSectionIndex,
                highestSectionIndex: globalThis.__manabiCacheWarmerHighestSectionIndex ?? null,
                uniqueSentenceCount: this.uniqueSentenceIdentifiers.size,
                trigger: 'skip-settled',
                ...captureEPUBOverlapState(),
            })
            postReplaceTextPerfLog('cache-warmer.finished', {
                sectionURL: this.lastLoadedSectionHref,
                sectionIndex: this.lastLoadedSectionIndex,
                highestSectionIndex: globalThis.__manabiCacheWarmerHighestSectionIndex ?? null,
                uniqueSentenceCount: this.uniqueSentenceIdentifiers.size,
                trigger: 'skip-settled',
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
        postEPUBLog('ebook.perf.cache-warmer.skip-settled', {
            trigger: 'advance',
            currentSectionIndex: this.lastLoadedSectionIndex,
            currentSectionHref: this.lastLoadedSectionHref,
            skippedToSectionIndex: targetIndex,
            skippedToSectionHref: targetSection?.href ?? targetSection?.id ?? null,
            activeForegroundHref: activeForegroundSectionHref(),
            skippedSettledSectionHrefs,
            settledSectionCount: settledSectionHrefs.length,
            ...captureEPUBOverlapState(),
        })
        postReplaceTextPerfLog('cache-warmer.skip-settled', {
            trigger: 'advance',
            currentSectionIndex: this.lastLoadedSectionIndex,
            currentSectionHref: this.lastLoadedSectionHref,
            skippedToSectionIndex: targetIndex,
            skippedToSectionHref: targetSection?.href ?? targetSection?.id ?? null,
            activeForegroundHref: activeForegroundSectionHref(),
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
            skippedSettledSectionHrefs,
            settledSectionCount: settledSectionHrefs.length,
            ...captureEPUBOverlapState(),
        })
        await runWithEPUBFlashNavigationIntent({
            source: 'cache-warmer.advance',
            target: 'renderer.goTo',
            sectionIndex: targetIndex,
        }, () => this.view.renderer.goTo({ index: targetIndex }))
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
        postEPUBLog('ebook.perf.cache-warmer.open.begin', {
            sourceKind: file?.kind || 'nil',
            ...captureEPUBOverlapState(),
        });
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
            postEPUBLog('ebook.perf.cache-warmer.open.end', {
                sourceKind: file?.kind || 'nil',
                ...captureEPUBOverlapState(),
            });
            postReplaceTextPerfLog('cache-warmer.open.end', {
                sourceKind: file?.kind || 'nil',
                ...captureEPUBOverlapState(),
            });
        } catch (error) {
            postEPUBLog('ebook.perf.cache-warmer.open.error', {
                sourceKind: file?.kind || 'nil',
                message: error?.message || String(error),
                ...captureEPUBOverlapState(),
            });
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
            postEPUBLog('ebook.perf.cache-warmer.readyToLoadNextSection.post', {
                trigger,
                sectionIndex,
                sectionHref,
                ...captureEPUBOverlapState(),
            });
            return;
        }
        globalThis.__manabiCacheWarmerFinished = true;
        postEPUBLog('ebook.perf.cache-warmer.finished', {
            sectionURL: location,
            sectionIndex,
            highestSectionIndex: globalThis.__manabiCacheWarmerHighestSectionIndex ?? null,
            uniqueSentenceCount: this.uniqueSentenceIdentifiers.size,
            trigger,
            ...captureEPUBOverlapState(),
        });
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
        postEPUBLog('ebook.perf.cache-warmer.onLoad.begin', {
            sectionIndex: Number.isInteger(index) ? index : null,
            location,
            indexedSectionHref,
            sourceHref,
            sectionHref,
            sentenceCount: sentenceNodes.length,
            segmentCount: segmentNodes.length,
            navHUDReady: !!globalThis.reader?.navHUD,
            ...captureEPUBOverlapState(),
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
        postEPUBLog('ebook.perf.cache-warmer.section', {
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
        markEPUBPerf('cache-warmer.section.first', {
            sectionURL: location,
            sectionIndex: Number.isInteger(index) ? index : null,
            sourceHref: sourceHref || null,
            sentenceCount: sentenceNodes.length,
            segmentCount: segmentNodes.length,
        }, {
            once: true,
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
        postEPUBLog('ebook.perf.cache-warmer.loadedSection.post', {
            sectionIndex: Number.isInteger(index) ? index : null,
            location,
            sectionHref,
            ...captureEPUBOverlapState(),
        });
        
        const atEnd = await this.view.renderer.atEnd();
        postPageNumLog('cacheWarmer.atEnd', {
            sectionIndex: Number.isInteger(index) ? index : null,
            sectionHref,
            atEnd,
        });
        postEPUBLog('ebook.perf.cache-warmer.atEnd', {
            sectionIndex: Number.isInteger(index) ? index : null,
            sectionHref,
            atEnd,
            ...captureEPUBOverlapState(),
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
}

window.setEbookViewerWritingDirection = (layoutMode) => {
    globalThis.reader.view.renderer.setAttribute('flow', layoutMode)
}

window.loadNextCacheWarmerSection = async () => {
    await window.cacheWarmer.loadNextSectionSkippingSettled()
}

window.loadEBook = ({
    url,
    layoutMode,
}) => {
    try {
        globalThis.__manabiFinishEPUBLoadWatchdogs?.('new-load');
    } catch (_error) {}
    globalThis.__manabiLiveProcessedSectionHrefs = new Set();
    globalThis.__manabiLiveSettledSectionHrefs = new Set();
    globalThis.__manabiFirstLiveSectionHref = null;
    beginEPUBPerfSession({
        hasURL: typeof url === 'string' && url.length > 0,
        layoutMode: layoutMode || 'default',
        sourceKind: typeof url === 'string' && url.startsWith('ebook://') ? 'native' : 'remote',
    });
    let loadSettled = false;
    const loadWatchdogTimers = [1000, 3000, 8000, 20000, 45000].map(delayMs =>
        setTimeout(() => {
            if (loadSettled) return;
            postEPUBLoadLog('viewer.load.pending', collectEPUBLoadDiagnostics('viewer.load.pending', {
                delayMs,
                hasURL: typeof url === 'string' && url.length > 0,
                layoutMode: layoutMode || 'default',
                sourceKind: typeof url === 'string' && url.startsWith('ebook://') ? 'native' : 'remote',
            }));
        }, delayMs)
    );
    const finishLoadWatchdogs = () => {
        loadSettled = true;
        for (const timer of loadWatchdogTimers) clearTimeout(timer);
    };
    globalThis.__manabiFinishEPUBLoadWatchdogs = finishLoadWatchdogs;
    postEPUBLoadLog('viewer.load.start', collectEPUBLoadDiagnostics('viewer.load.start', {
        hasURL: typeof url === 'string' && url.length > 0,
        layoutMode: layoutMode || 'default',
        sourceKind: typeof url === 'string' && url.startsWith('ebook://') ? 'native' : 'remote',
    }));
    postReaderLog('ebook.viewer.load.start', {
        hasURL: typeof url === 'string' && url.length > 0,
        layoutMode: layoutMode || 'default',
    });
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
                    postEPUBLoadLog('viewer.load.blob.ready', collectEPUBLoadDiagnostics('viewer.load.blob.ready', {
                        blobSize: blob.size,
                        blobType: blob.type || 'nil',
                    }));
                    markEPUBPerf('source.ready', {
                        sourceKind: 'blob',
                        blobSize: blob.size,
                        blobType: blob.type || 'nil',
                    }, {
                        once: true,
                    });
                    postReaderLog('ebook.viewer.load.blobReady', {
                        blobSize: blob.size,
                        blobType: blob.type || 'nil',
                    });
                    return makeFileSource(new File([blob], new URL(url).pathname))
                })

        sourcePromise
        .then(async (source) => {
            if (source?.kind === 'native') {
                postEPUBLoadLog('viewer.load.native-source.ready', collectEPUBLoadDiagnostics('viewer.load.native-source.ready', {
                    sourceURL: source.url,
                }));
                markEPUBPerf('source.ready', {
                    sourceKind: 'native',
                    sourceURL: source.url,
                }, {
                    once: true,
                });
                postReaderLog('ebook.viewer.load.nativeSource', {
                    sourceURL: source.url,
                });
            }
            if (layoutMode) {
                window.initialLayoutMode = layoutMode
            }
            markEPUBPerf('reader.open.dispatch', {
                fileKind: source?.kind || 'nil',
            });
            postEPUBLoadLog('viewer.reader-open.dispatch', collectEPUBLoadDiagnostics('viewer.reader-open.dispatch', {
                fileKind: source?.kind || 'nil',
            }));
            await reader.open(source)
        })
        .then(async () => {
            markEPUBPerf('reader.open.resolved', {
                hasRenderer: !!globalThis.reader?.view?.renderer,
                bookDir: globalThis.reader?.bookDir || 'nil',
                isRTL: !!globalThis.reader?.isRTL,
            });
            postEPUBLoadLog('viewer.reader-open.resolved', collectEPUBLoadDiagnostics('viewer.reader-open.resolved', {
                hasRenderer: !!globalThis.reader?.view?.renderer,
                bookDir: globalThis.reader?.bookDir || 'nil',
                isRTL: !!globalThis.reader?.isRTL,
            }));
            postReaderLog('ebook.viewer.load.opened', {
                hasRenderer: !!globalThis.reader?.view?.renderer,
                bookDir: globalThis.reader?.bookDir || 'nil',
                isRTL: !!globalThis.reader?.isRTL,
            });
            markEPUBPerf('viewer.loaded.callback');
            const probe = globalThis.reader?.collectLayoutGapProbe?.('ebookViewerLoaded', {
                bookDir: globalThis.reader?.bookDir || null,
                isRTL: !!globalThis.reader?.isRTL,
            }) ?? null;
            window.webkit.messageHandlers.ebookViewerLoaded.postMessage({
                probe,
            })
        })
        .catch((error) => {
            finishLoadWatchdogs();
            try {
                reader?.setLoadingIndicator?.(false);
            } catch (_error) {}
            postEPUBLoadLog('viewer.load.error', collectEPUBLoadDiagnostics('viewer.load.error', {
                message: error?.message || String(error),
                stack: error?.stack || null,
            }));
            markEPUBPerf('load.error', {
                message: error?.message || String(error),
            }, {
                once: true,
            });
            postReaderLog('ebook.viewer.load.error', {
                message: error?.message || String(error),
            });
            throw error;
        })
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
    postEbookRestoreLog('js.restore.userInput', {
        eventType,
        requestedFraction: Number.isFinite(globalThis.__manabiRequestedRestoreFraction)
            ? safeRound(globalThis.__manabiRequestedRestoreFraction, 6)
            : null,
        requestedDisplayPercent: roundedDisplayPercent(globalThis.__manabiRequestedRestoreFraction),
    });
    globalThis.__manabiRequireUserInputBeforePositionSave = false;
    globalThis.__manabiSuppressNextRestoreRelocateSave = false;
    postMarkReadLog('restore.userInput', {
        eventType,
        requestedFraction: Number.isFinite(globalThis.__manabiRequestedRestoreFraction)
            ? safeRound(globalThis.__manabiRequestedRestoreFraction, 6)
            : null,
        requestedDisplayPercent: roundedDisplayPercent(globalThis.__manabiRequestedRestoreFraction),
    });
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
        postEbookRestoreLog('js.restore.state', {
            stage,
            requestedHasCFI: typeof cfi === 'string' && cfi.length > 0,
            requestedCFILength: typeof cfi === 'string' ? cfi.length : 0,
            requestedFraction: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
            requestedDisplayPercent: roundedDisplayPercent(fractionalCompletion),
            landedFraction: typeof currentFraction === 'number' ? safeRound(currentFraction, 6) : null,
            landedDisplayPercent: roundedDisplayPercent(currentFraction),
            landedSectionIndex: sectionIndex,
            landedLocationCurrent: locationCurrent,
            landedLocationTotal: locationTotal,
            landedCFILength: typeof detail?.cfi === 'string' ? detail.cfi.length : 0,
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
        postMarkReadLog('restore.result', {
            stage,
            requestedHasCFI: typeof cfi === 'string' && cfi.length > 0,
            requestedFraction: requestedFraction != null ? safeRound(requestedFraction, 6) : null,
            requestedDisplayPercent: roundedDisplayPercent(requestedFraction),
            landedFraction: landedFraction != null ? safeRound(landedFraction, 6) : null,
            landedDisplayPercent: roundedDisplayPercent(landedFraction),
            landedSectionIndex: restoreState?.sectionIndex ?? null,
            landedLocationCurrent: restoreState?.locationCurrent ?? null,
            landedLocationTotal: restoreState?.locationTotal ?? null,
            ...extra,
        });
    };
    postReaderLog('ebook.viewer.loadLastPosition.start', {
        hasCFI: typeof cfi === 'string' && cfi.length > 0,
        fractionalCompletion: Number.isFinite(fractionalCompletion) ? fractionalCompletion : 'nil',
    });
    postEbookRestoreLog('js.restore.start', {
        hasCFI: typeof cfi === 'string' && cfi.length > 0,
        cfiLength: typeof cfi === 'string' ? cfi.length : 0,
        fractionalCompletion: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
        displayPercent: roundedDisplayPercent(fractionalCompletion),
        currentHref: window.location.href,
        hasReader: !!globalThis.reader,
        hasView: !!globalThis.reader?.view,
        hasRenderer: !!globalThis.reader?.view?.renderer,
    });
    postPageNumLog('restore.request', {
        hasCFI: typeof cfi === 'string' && cfi.length > 0,
        cfiLength: typeof cfi === 'string' ? cfi.length : 0,
        fractionalCompletion: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
    });
    postMarkReadLog('restore.request', {
        hasCFI: typeof cfi === 'string' && cfi.length > 0,
        cfiLength: typeof cfi === 'string' ? cfi.length : 0,
        requestedFraction: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
        requestedDisplayPercent: roundedDisplayPercent(fractionalCompletion),
    });
    markEPUBPerf('restore.start', {
        hasCFI: typeof cfi === 'string' && cfi.length > 0,
        fractionalCompletion: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 4) : 'nil',
    });
    const hasFractionalCompletion = Number.isFinite(fractionalCompletion) && fractionalCompletion > 0;
    const syntheticRestoreLocator = parseSyntheticRestoreLocator(cfi);
    const restoreLocatorKind = syntheticRestoreLocator
        ? 'synthetic'
        : (typeof cfi === 'string' && cfi.length > 0 ? 'cfi' : (hasFractionalCompletion ? 'fraction' : 'none'));
    postMarkReadLog('restore.plan', {
        locatorKind: restoreLocatorKind,
        hasFractionalCompletion,
        requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
        requestedDisplayPercent: roundedDisplayPercent(fractionalCompletion),
        cfiLength: typeof cfi === 'string' ? cfi.length : 0,
        syntheticSectionIndex: syntheticRestoreLocator?.sectionIndex ?? null,
        syntheticLocalSectionIndex: syntheticRestoreLocator?.localSectionIndex ?? null,
        syntheticRendererTotal: syntheticRestoreLocator?.rendererTotal ?? null,
        syntheticFractionInSection: syntheticRestoreLocator
            ? safeRound(syntheticRestoreLocator.fractionInSection, 6)
            : null,
    });
    postEbookRestoreLog('js.restore.plan', {
        locatorKind: restoreLocatorKind,
        hasFractionalCompletion,
        requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
        requestedDisplayPercent: roundedDisplayPercent(fractionalCompletion),
        cfiLength: typeof cfi === 'string' ? cfi.length : 0,
        syntheticSectionIndex: syntheticRestoreLocator?.sectionIndex ?? null,
        syntheticLocalSectionIndex: syntheticRestoreLocator?.localSectionIndex ?? null,
        syntheticRendererTotal: syntheticRestoreLocator?.rendererTotal ?? null,
        syntheticFractionInSection: syntheticRestoreLocator
            ? safeRound(syntheticRestoreLocator.fractionInSection, 6)
            : null,
    });
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
        postMarkReadLog('restore.reconcile', {
            reason,
            drift: safeRound(delta, 6),
            fromFraction: safeRound(restoreState.currentFraction, 6),
            toFraction: safeRound(fractionalCompletion, 6),
            fromDisplayPercent: landedDisplayPercent,
            toDisplayPercent: requestedDisplayPercent,
            displayPercentChanged,
            sectionIndex: restoreState.sectionIndex,
        });
        postEbookRestoreLog('js.restore.reconcile', {
            reason,
            drift: safeRound(delta, 6),
            fromFraction: safeRound(restoreState.currentFraction, 6),
            toFraction: safeRound(fractionalCompletion, 6),
            fromDisplayPercent: landedDisplayPercent,
            toDisplayPercent: requestedDisplayPercent,
            displayPercentChanged,
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
            postEPUBFlashLog('js.restore.reconcile.skipGoTo', {
                reason: 'same-renderer-page',
                reconcileReason: reason,
                rendererPageCurrent,
                rendererPageTotal,
                targetRendererPage,
            });
            postMarkReadLog('restore.reconcile.skip', {
                reason: 'same-renderer-page',
                reconcileReason: reason,
                drift: safeRound(delta, 6),
                fromFraction: safeRound(restoreState.currentFraction, 6),
                toFraction: safeRound(fractionalCompletion, 6),
                rendererPageCurrent,
                rendererPageTotal,
                targetRendererPage,
            });
            return;
        }
        await runWithEPUBFlashNavigationIntent({
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
            postEbookRestoreLog('js.restore.path', {
                mode: 'fraction-for-synthetic-locator',
                requestedFraction: safeRound(fractionalCompletion, 6),
                requestedDisplayPercent: roundedDisplayPercent(fractionalCompletion),
                syntheticSectionIndex: syntheticRestoreLocator.sectionIndex,
                syntheticLocalSectionIndex: syntheticRestoreLocator.localSectionIndex,
                syntheticRendererTotal: syntheticRestoreLocator.rendererTotal,
                syntheticFractionInSection: safeRound(syntheticRestoreLocator.fractionInSection, 6),
            });
            postMarkReadLog('restore.path', {
                mode: 'fraction-for-synthetic-locator',
                requestedFraction: safeRound(fractionalCompletion, 6),
                requestedDisplayPercent: roundedDisplayPercent(fractionalCompletion),
                syntheticSectionIndex: syntheticRestoreLocator.sectionIndex,
                syntheticLocalSectionIndex: syntheticRestoreLocator.localSectionIndex,
                syntheticRendererTotal: syntheticRestoreLocator.rendererTotal,
                syntheticFractionInSection: safeRound(syntheticRestoreLocator.fractionInSection, 6),
            });
            postReaderLog('ebook.viewer.loadLastPosition.path', {
                mode: 'fraction-for-synthetic-locator',
                sectionIndex: syntheticRestoreLocator.sectionIndex,
                localSectionIndex: syntheticRestoreLocator.localSectionIndex,
                rendererTotal: syntheticRestoreLocator.rendererTotal,
                fractionInSection: safeRound(syntheticRestoreLocator.fractionInSection, 6),
            });
            await runWithEPUBFlashNavigationIntent({
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
            postEbookRestoreLog('js.restore.path', {
                mode: 'synthetic-locator',
                requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
                requestedDisplayPercent: roundedDisplayPercent(fractionalCompletion),
                syntheticSectionIndex: syntheticRestoreLocator.sectionIndex,
                syntheticLocalSectionIndex: syntheticRestoreLocator.localSectionIndex,
                syntheticRendererTotal: syntheticRestoreLocator.rendererTotal,
                syntheticFractionInSection: safeRound(syntheticRestoreLocator.fractionInSection, 6),
            });
            postMarkReadLog('restore.path', {
                mode: 'synthetic-locator',
                requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
                requestedDisplayPercent: roundedDisplayPercent(fractionalCompletion),
                syntheticSectionIndex: syntheticRestoreLocator.sectionIndex,
                syntheticLocalSectionIndex: syntheticRestoreLocator.localSectionIndex,
                syntheticRendererTotal: syntheticRestoreLocator.rendererTotal,
                syntheticFractionInSection: safeRound(syntheticRestoreLocator.fractionInSection, 6),
            });
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
            await runWithEPUBFlashNavigationIntent({
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
            postMarkReadLog('restore.reconcile.skip', {
                reason: 'synthetic-locator-is-page-authority',
                requestedFraction: safeRound(fractionalCompletion, 6),
                requestedDisplayPercent: roundedDisplayPercent(fractionalCompletion),
                landedFraction: safeRound(syntheticState.fraction, 6),
                landedDisplayPercent: roundedDisplayPercent(syntheticState.fraction),
            });
        } else if (cfi.length > 0) {
            postEbookRestoreLog('js.restore.path', {
                mode: 'cfi',
                requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
                requestedDisplayPercent: roundedDisplayPercent(fractionalCompletion),
                cfiLength: cfi.length,
            });
            postMarkReadLog('restore.path', {
                mode: 'cfi',
                requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
                requestedDisplayPercent: roundedDisplayPercent(fractionalCompletion),
                cfiLength: cfi.length,
            });
            postReaderLog('ebook.viewer.loadLastPosition.path', {
                mode: 'cfi',
            });
            await runWithEPUBFlashNavigationIntent({
                source: 'restore.cfi',
                target: 'view.goTo',
                cfiLength: cfi.length,
                fraction: hasFractionalCompletion ? fractionalCompletion : null,
            }, () => globalThis.reader.view.goTo(cfi)).catch(async e => {
                postEbookRestoreLog('js.restore.error', {
                    mode: 'cfi',
                    message: e?.message || String(e),
                    fallback: hasFractionalCompletion ? 'fraction-fallback' : null,
                    requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
                    requestedDisplayPercent: roundedDisplayPercent(fractionalCompletion),
                    cfiLength: cfi.length,
                });
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
                    await runWithEPUBFlashNavigationIntent({
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
            postEbookRestoreLog('js.restore.path', {
                mode: 'fraction',
                requestedFraction: safeRound(fractionalCompletion, 6),
                requestedDisplayPercent: roundedDisplayPercent(fractionalCompletion),
            });
            postMarkReadLog('restore.path', {
                mode: 'fraction',
                requestedFraction: safeRound(fractionalCompletion, 6),
                requestedDisplayPercent: roundedDisplayPercent(fractionalCompletion),
            });
            postReaderLog('ebook.viewer.loadLastPosition.path', {
                mode: 'fraction',
            });
            try {
                await runWithEPUBFlashNavigationIntent({
                    source: 'restore.fraction',
                    target: 'view.goToFraction',
                    fraction: fractionalCompletion,
                }, () => globalThis.reader.view.goToFraction(fractionalCompletion));
                await waitForFrames(2);
                const fractionState = captureRestoreState('after-fraction');
                postRestoreMarkReadLog('after-fraction', fractionState);
            } catch (error) {
                postEbookRestoreLog('js.restore.error', {
                    mode: 'fraction',
                    message: error?.message || String(error),
                    fallback: 'default-next',
                    requestedFraction: safeRound(fractionalCompletion, 6),
                    requestedDisplayPercent: roundedDisplayPercent(fractionalCompletion),
                });
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
            postEbookRestoreLog('js.restore.path', {
                mode: 'default-next',
                requestedFraction: null,
                requestedDisplayPercent: null,
                cfiLength: typeof cfi === 'string' ? cfi.length : 0,
            });
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
        postLandscapeInsetRestoreProbe('done', doneState, {
            hasCFI: typeof cfi === 'string' && cfi.length > 0,
            requestedFraction: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
        });
        postRestoreMarkReadLog('done', doneState);
        postEbookRestoreLog('js.restore.done', {
            hasCFI: typeof cfi === 'string' && cfi.length > 0,
            cfiLength: typeof cfi === 'string' ? cfi.length : 0,
            requestedFraction: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
            requestedDisplayPercent: roundedDisplayPercent(fractionalCompletion),
            landedFraction: typeof doneState?.currentFraction === 'number' ? safeRound(doneState.currentFraction, 6) : null,
            landedDisplayPercent: roundedDisplayPercent(doneState?.currentFraction),
            landedSectionIndex: doneState?.sectionIndex ?? null,
            landedLocationCurrent: doneState?.locationCurrent ?? null,
            landedLocationTotal: doneState?.locationTotal ?? null,
        });
        postReaderLog('ebook.viewer.loadLastPosition.done', {
            hasCFI: typeof cfi === 'string' && cfi.length > 0,
        });
        markEPUBPerf('restore.done', {
            hasCFI: typeof cfi === 'string' && cfi.length > 0,
        });
        postReplaceTextPerfLog('restore.done', {
            hasCFI: typeof cfi === 'string' && cfi.length > 0,
            ...captureEPUBOverlapState(),
        });

        // Let the visible section finish rendering before warming secondary sections.
        scheduleDeferredCacheWarmerOpen('load-last-position-done', 600);
    } finally {
        globalThis.__manabiRestoreInProgress = false;
        globalThis.__manabiSuppressNextRestoreRelocateSave = false;
        globalThis.__manabiRequireUserInputBeforePositionSave = true;
        postMarkReadLog('restore.saveSuppression.arm', {
            mode: 'until-user-input',
            requestedFraction: Number.isFinite(globalThis.__manabiRequestedRestoreFraction)
                ? safeRound(globalThis.__manabiRequestedRestoreFraction, 6)
                : null,
            requestedDisplayPercent: roundedDisplayPercent(globalThis.__manabiRequestedRestoreFraction),
        });
        postEbookRestoreLog('js.restore.saveSuppression.arm', {
            mode: 'until-user-input',
            requestedFraction: Number.isFinite(globalThis.__manabiRequestedRestoreFraction)
                ? safeRound(globalThis.__manabiRequestedRestoreFraction, 6)
                : null,
            requestedDisplayPercent: roundedDisplayPercent(globalThis.__manabiRequestedRestoreFraction),
        });
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
            await runWithEPUBFlashNavigationIntent({
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

window.webkit.messageHandlers.ebookViewerInitialized.postMessage({})
postReaderLog('ebook.viewer.js.version', {
    version: 'replace-text-summary-v1',
});
