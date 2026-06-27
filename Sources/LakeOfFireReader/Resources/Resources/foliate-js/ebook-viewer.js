// Global timers for side-nav chevron fades
import './view.js'
import {
createTOCView
} from './ui/tree.js'
import { NavigationHUD } from './ebook-viewer-nav.js'
import {
    Overlayer
} from '../foliate-js/overlayer.js'

// Required for EPUB page clipping after iframe/chrome layout settles.
const MANABI_DISABLE_INITIAL_PAGINATOR_SETTLE = false;
const MANABI_ENABLE_DID_DISPLAY_POST_FRAME_SETTLE = false;
const MANABI_DISABLE_NAV_HIDDEN_LAYOUT_CLASSES = false;
const MANABI_DISABLE_DYNAMIC_CHROME_INSETS = true;
const MANABI_ENABLE_EBOOK_PAGE_TRACKING_BUTTONS = false;
const MANABI_SLOW_PROCESS_TEXT_LOG_THRESHOLD_MS = 5000;

const ebookLoadLogNumber = (value) => {
    if (!Number.isFinite(value)) return String(value);
    if (Number.isInteger(value)) return String(value);
    const abs = Math.abs(value);
    const digits = abs > 0 && abs < 1 ? 6 : (abs < 1000 ? 2 : 1);
    return String(Number(value.toFixed(digits)));
};

const ebookLoadLogValue = (value) => {
    if (value == null) return 'nil';
    if (typeof value === 'number') return ebookLoadLogNumber(value);
    if (typeof value === 'boolean') return value ? 'true' : 'false';
    return String(value).replace(/\s+/g, ' ').slice(0, 180);
};

const ebookLoadLog = (event, payload = {}) => {
    try {
        const details = Object.entries(payload)
            .filter(([, value]) => value !== undefined)
            .map(([key, value]) => `${key}=${ebookLoadLogValue(value)}`)
            .join(' ');
        window.webkit?.messageHandlers?.print?.postMessage?.(
            details.length > 0 ? `# EBOOKLOAD js.${event} ${details}` : `# EBOOKLOAD js.${event}`
        );
    } catch (_error) {}
};

const readerLoadLog = (stage, payload = {}) => {
    try {
        const details = Object.entries(payload)
            .filter(([key, value]) => value !== undefined && key !== 'src' && key !== 'url' && key !== 'currentURL')
            .map(([key, value]) => `${key}=${ebookLoadLogValue(value)}`)
            .join(' ');
        window.webkit?.messageHandlers?.print?.postMessage?.(
            details.length > 0 ? `# READERLOAD stage=${stage} ${details}` : `# READERLOAD stage=${stage}`
        );
    } catch (_error) {}
};
globalThis.__manabiReaderLoadLog = readerLoadLog;

const manabiReaderSegmentSelector = 'm-m';
const manabiReaderSurfaceSelector = 'm-t';
const manabiReaderSentenceSelector = 'm-s';
const manabiReaderSegmentTagNames = new Set(['m-m']);
const manabiReaderSurfaceTagNames = new Set(['m-t']);
const manabiReaderSentenceTagNames = new Set(['m-s']);
const manabiReaderTagName = element => element?.tagName?.toLowerCase?.() || '';
const manabiIsReaderSegmentElement = element => manabiReaderSegmentTagNames.has(manabiReaderTagName(element));
const manabiIsReaderSurfaceElement = element => manabiReaderSurfaceTagNames.has(manabiReaderTagName(element));
const manabiIsReaderSentenceElement = element => manabiReaderSentenceTagNames.has(manabiReaderTagName(element));

const MANABI_TEMP_DISABLE_EBOOK_NATIVE_LOOKUP_HIT_TARGETS = false;
globalThis.__manabiEbookNativeLookupHitTargetsDisabled = MANABI_TEMP_DISABLE_EBOOK_NATIVE_LOOKUP_HIT_TARGETS;

const popoverDiagnosticLog = (event, payload = {}) => {
    try {
        const details = Object.entries(payload)
            .filter(([key, value]) => value !== undefined && !popoverDiagnosticShouldRedactKey(key))
            .map(([key, value]) => `${key}=${ebookLoadLogValue(value)}`)
            .join(' ');
        window.webkit?.messageHandlers?.print?.postMessage?.(
            details.length > 0 ? `# POPOVER ${event} ${details}` : `# POPOVER ${event}`
        );
    } catch (_error) {}
};

const popoverDiagnosticShouldRedactKey = (key) => {
    const normalized = String(key ?? '').toLowerCase();
    return normalized === 'url'
        || normalized.endsWith('url')
        || normalized.includes('framekey')
        || normalized === 'nativelookupframekey'
        || normalized === 'locationhref';
};

const highlightStatusLog = (stage, payload = {}) => {
    try {
        const details = Object.entries(payload)
            .filter(([, value]) => value !== undefined)
            .map(([key, value]) => `${key}=${ebookLoadLogValue(value)}`)
            .join(' ');
        const line = details.length > 0
            ? `# HIGHLIGHT stage=${stage} ${details}`
            : `# HIGHLIGHT stage=${stage}`;
        if (globalThis.__manabiLastHighlightStatusViewerLog === line) {
            return;
        }
        globalThis.__manabiLastHighlightStatusViewerLog = line;
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_error) {}
};

const markReaderRenderReady = (reason = 'unspecified') => {
    const html = document.documentElement;
    const body = document.body;
    const wasReady = html?.dataset?.mnbReaderRenderReady === '1'
        || body?.dataset?.mnbReaderRenderReady === '1';
    if (html?.dataset) {
        html.dataset.mnbReaderRenderReady = '1';
    }
    if (body?.dataset) {
        body.dataset.mnbReaderRenderReady = '1';
    }
    if (!wasReady) {
        readerLoadLog('viewer.renderReady.marked', {
            reason,
            hasReaderContent: !!document.querySelector?.('foliate-view'),
            bodyLoading: !!body?.classList?.contains?.('loading'),
        });
    }
    globalThis.__manabiPostReaderDocStateEvent?.(`renderReady.${reason}`);
};

const nextEbookLoadRequestID = (prefix) => {
    globalThis.__manabiEBookLoadRequestSeq = (globalThis.__manabiEBookLoadRequestSeq ?? 0) + 1;
    return `${prefix}-${globalThis.__manabiEBookLoadRequestSeq}`;
};

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
        sentenceIdentifier: sentenceIdentifierForNode(element.closest?.(manabiReaderSentenceSelector) || null),
    };
};

const highlightDiagnosticStyleSnapshot = (doc, element) => {
    if (!doc || !element || !doc.defaultView?.getComputedStyle) return null;
    const style = doc.defaultView.getComputedStyle(element);
    const prop = (name) => style.getPropertyValue(name)?.trim?.() || null;
    const rect = element.getBoundingClientRect?.();
    return {
        tag: element.tagName?.toLowerCase?.() || null,
        id: element.id || null,
        className: typeof element.className === 'string' ? element.className : null,
        writingMode: style.writingMode || null,
        direction: style.direction || null,
        gradientDirection: prop('--mnb-highlight-gradient-direction'),
        trackingAlpha: prop('--mnb-tracking-highlight-alpha'),
        fillOpacity: prop('--mnb-highlight-fill-opacity'),
        learningHighlight: prop('--word-tracking-learning-highlight'),
        learningNav: prop('--word-tracking-learning-highlight-nav-conditional'),
        background: style.background || null,
        backgroundImage: style.backgroundImage || null,
        backgroundOrigin: style.backgroundOrigin || null,
        backgroundClip: style.backgroundClip || null,
        boxDecorationBreak: style.boxDecorationBreak || style.webkitBoxDecorationBreak || null,
        rect: rect ? {
            left: rect.left,
            top: rect.top,
            right: rect.right,
            bottom: rect.bottom,
            width: rect.width,
            height: rect.height,
        } : null,
    };
};

const logHighlightGradientDiagnostic = (reason = 'unspecified', explicitDoc = null) => {
    try {
        const contents = globalThis.reader?.view?.renderer?.getContents?.() || [];
        const doc = isDocumentLike(explicitDoc) ? explicitDoc : contents[0]?.doc;
        if (!isDocumentLike(doc)) return;
        const body = doc.body;
        const root = doc.documentElement;
        const learningSurface = doc.querySelector?.('m-m.mnb-learning > m-t');
        const learningSegment = learningSurface?.closest?.(manabiReaderSegmentSelector) ?? doc.querySelector?.('m-m.mnb-learning');
        const surface = learningSurface ?? learningSegment?.querySelector?.('m-t') ?? null;
        if (!body || !learningSegment) return;
        const bodyStyle = doc.defaultView?.getComputedStyle?.(body);
        const rootStyle = doc.defaultView?.getComputedStyle?.(root);
        const isVerticalBody = body.classList?.contains?.('reader-vertical-writing') === true
            || root?.classList?.contains?.('vrtl') === true
            || String(bodyStyle?.writingMode || rootStyle?.writingMode || '').startsWith('vertical');
        if (!isVerticalBody) return;
        const targetRect = learningSegment.getBoundingClientRect?.();
        const inViewport = targetRect
            && targetRect.bottom >= -200
            && targetRect.top <= ((doc.defaultView?.innerHeight ?? 0) + 200)
            && targetRect.right >= -200
            && targetRect.left <= ((doc.defaultView?.innerWidth ?? 0) + 200);
        if (!inViewport) return;
        const datasetSnapshot = (element) => element?.dataset ? Object.fromEntries(Object.entries(element.dataset)) : null;
        const ancestorChain = [];
        for (let node = learningSegment; node && node !== body && ancestorChain.length < 6; node = node.parentElement) {
            ancestorChain.push({
                tag: node.tagName?.toLowerCase?.() || null,
                id: node.id || null,
                className: typeof node.className === 'string' ? node.className : null,
                horizontalIsland: node.dataset?.mnbHorizontalWritingIsland ?? null,
                displayToken: node.dataset?.mnbDisplayToken ?? null,
            });
        }
        const payload = {
            message: '# HIGHLIGHT ebook.gradient',
            reason,
            documentURL: doc.URL || doc.location?.href || null,
            outerURL: window.location.href,
            bodyClassName: body.className || null,
            rootClassName: root?.className || null,
            bodyDataset: datasetSnapshot(body),
            rootDataset: datasetSnapshot(root),
            bodyStyle: highlightDiagnosticStyleSnapshot(doc, body),
            rootStyle: highlightDiagnosticStyleSnapshot(doc, root),
            segmentStyle: highlightDiagnosticStyleSnapshot(doc, learningSegment),
            surfaceStyle: highlightDiagnosticStyleSnapshot(doc, surface),
            segmentHasRuby: !!learningSegment.querySelector?.('rt'),
            segmentHorizontalIsland: learningSegment.dataset?.mnbHorizontalWritingIsland ?? null,
            surfaceHorizontalIsland: surface?.dataset?.mnbHorizontalWritingIsland ?? null,
            ancestorChain,
            text: learningSegment.textContent?.trim?.().slice?.(0, 48) ?? null,
            navHidden: body.dataset?.mnbNavigationHiddenDueToScroll ?? null,
            contentCount: contents.length,
        };
        const expectedDirection = (payload.segmentHorizontalIsland === 'true' || payload.surfaceHorizontalIsland === 'true')
            ? 'to bottom'
            : 'to right';
        const directionValues = [
            payload.bodyStyle?.gradientDirection,
            payload.segmentStyle?.gradientDirection,
            payload.surfaceStyle?.gradientDirection,
        ].filter((value) => typeof value === 'string' && value.length > 0 && value !== '<null>');
        const hasDirectionAnomaly = directionValues.some((value) => value !== expectedDirection);
        if (!hasDirectionAnomaly) return;
        payload.expectedDirection = expectedDirection;
        payload.directionValues = directionValues;
        const key = JSON.stringify({
            reason,
            documentURL: payload.documentURL,
            id: learningSegment.id || null,
            className: learningSegment.className || null,
            bodyGradient: payload.bodyStyle?.gradientDirection,
            segmentGradient: payload.segmentStyle?.gradientDirection,
            surfaceGradient: payload.surfaceStyle?.gradientDirection,
            surfaceBackgroundImage: payload.surfaceStyle?.backgroundImage,
            navHidden: payload.navHidden,
        });
        if (globalThis.__manabiLastHighlightGradientDiagnosticKey === key) return;
        globalThis.__manabiLastHighlightGradientDiagnosticKey = key;
        window.webkit?.messageHandlers?.print?.postMessage?.(payload);
    } catch (error) {
        window.webkit?.messageHandlers?.print?.postMessage?.({
            message: '# HIGHLIGHT ebook.gradient.error',
            reason,
            error: String(error),
        });
    }
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

const parseSpineOnlyEpubCFI = (value) => {
    if (typeof value !== 'string') return null;
    const match = value.trim().match(/^epubcfi\(\s*\/6\/(\d+)(?:\[[^\]]*\])?\s*\)$/);
    if (!match) return null;
    const spineStep = Number(match[1]);
    if (!Number.isInteger(spineStep) || spineStep <= 0 || spineStep % 2 !== 0) return null;
    return (spineStep / 2) - 1;
};

const coerceRestoreFraction = (...values) => {
    const numbers = values
        .map((value) => {
            if (typeof value === 'number') return value;
            if (typeof value === 'string' && value.trim().length > 0) return Number(value);
            return NaN;
        })
        .filter((value) => Number.isFinite(value))
        .map((value) => Math.max(0, Math.min(1, value)));
    return numbers.find((value) => value > 0) ?? numbers[0] ?? null;
};

const visiblePrimeSignatureForIndex = (index) => {
    const visibleElementIDs = Array.isArray(index?.visibleElementIDs) ? index.visibleElementIDs : [];
    const entryIDs = index?.idsByEntryID instanceof Map ? Array.from(index.idsByEntryID.keys()) : [];
    return `${visibleElementIDs.join(',')}|${entryIDs.join(',')}`;
};

const requestNativeVisibleTrackedWordsPrime = (doc, index, reason = 'visible-prime') => {
    if (!isDocumentLike(doc) || !index || !isEbookContentDocument(doc)) {
        return false;
    }
    const view = doc.defaultView;
    const visibleElementIDs = Array.isArray(index.visibleElementIDs)
        ? Array.from(new Set(index.visibleElementIDs.filter((elementID) => typeof elementID === 'string' && elementID.length > 0)))
        : [];
    if (visibleElementIDs.length === 0 || !(index.idsByEntryID instanceof Map) || index.idsByEntryID.size === 0) {
        return false;
    }
    const signature = visiblePrimeSignatureForIndex(index);
    if (view.__manabiLastNativeVisiblePrimeSignature === signature) {
        return false;
    }
    view.__manabiLastNativeVisiblePrimeSignature = signature;
    const entryIDs = Array.from(index.idsByEntryID.keys())
        .map((entryID) => Number(entryID))
        .filter((entryID) => Number.isFinite(entryID));
    if (entryIDs.length === 0) {
        return false;
    }
    try {
        view.webkit?.messageHandlers?.manabiSegmentsReady?.postMessage?.({
            windowURL: window.top.location.href,
            pageURL: doc.location?.href || doc.URL || '',
            isCacheWarmer: doc.body?.dataset?.isCacheWarmer === 'true',
            isReaderMode: doc.body?.classList?.contains?.('readability-mode') === true,
            reason,
            segmentCount: visibleElementIDs.length,
            force: false,
            uuid: typeof view.manabiCurrentFrameUUID === 'function'
                ? view.manabiCurrentFrameUUID()
                : doc.body?.dataset?.swiftuiwebviewFrameUuid ?? null,
            visiblePrimeOnly: true,
            visibleElementIDs,
            entryIDs,
        });
        return true;
    } catch (_error) {
        return false;
    }
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
const CACHE_WARMER_FOREGROUND_LOOKUP_COOLDOWN_MS = 6000;
const CACHE_WARMER_IDLE_RETRY_MS = 250;
const CACHE_WARMER_ADVANCE_SPACING_MS = 350;
const CACHE_WARMER_MAX_SECTIONS_AHEAD = 2;
const CACHE_WARMER_INITIAL_VISIBLE_READY_FALLBACK_MS = 3000;
const replaceTextResultCache = new Map();
const replaceTextInFlightCache = new Map();
const initialVisibleWorkReadyState = {
    ready: false,
    reason: null,
    waiters: [],
};

const resetInitialVisibleWorkReady = (reason = 'unspecified') => {
    initialVisibleWorkReadyState.ready = false;
    initialVisibleWorkReadyState.reason = null;
    initialVisibleWorkReadyState.waiters = [];
    globalThis.__manabiCacheWarmerWaitsForInitialVisibleWork = false;
    manabiTimelineMark('cacheWarmer.initialVisibleReady.reset', { reason });
};

const shouldWaitForInitialVisibleWorkBeforeCacheWarmer = (reason) => {
    const reasonString = String(reason ?? '');
    return reasonString.startsWith('loadEBook.initialRestoreHandled')
        || reasonString.startsWith('load-last-position')
        || reasonString.startsWith('loadLastPosition');
};

const markInitialVisibleWorkReady = (reason = 'unspecified') => {
    if (initialVisibleWorkReadyState.ready) {
        return;
    }
    initialVisibleWorkReadyState.ready = true;
    initialVisibleWorkReadyState.reason = reason;
    globalThis.__manabiCacheWarmerWaitsForInitialVisibleWork = false;
    manabiTimelineMark('cacheWarmer.initialVisibleReady', { reason });
    const waiters = initialVisibleWorkReadyState.waiters.splice(0);
    for (const waiter of waiters) {
        try {
            waiter({ ready: true, reason });
        } catch (_error) {
        }
    }
    if (globalThis.__manabiCacheWarmerOpenRequested) {
        void maybeOpenDeferredCacheWarmer();
    }
};

const waitForInitialVisibleWorkReady = (reason = 'unspecified', timeoutMs = CACHE_WARMER_INITIAL_VISIBLE_READY_FALLBACK_MS) => {
    if (initialVisibleWorkReadyState.ready) {
        return Promise.resolve({ ready: true, reason: initialVisibleWorkReadyState.reason });
    }
    return new Promise((resolve) => {
        let settled = false;
        const waiter = (result) => finish(result);
        const finish = (result) => {
            if (settled) {
                return;
            }
            settled = true;
            clearTimeout(timeout);
            initialVisibleWorkReadyState.waiters = initialVisibleWorkReadyState.waiters.filter(item => item !== waiter);
            resolve(result);
        };
        const timeout = setTimeout(() => {
            finish({
                ready: false,
                reason: 'timeout',
                requestedReason: reason,
                timeoutMs: Math.max(0, Number(timeoutMs) || 0),
            });
        }, Math.max(0, Number(timeoutMs) || 0));
        initialVisibleWorkReadyState.waiters.push(waiter);
    });
};

const fingerprintReplaceTextInput = (text) => {
    if (typeof text !== 'string') return 'invalid';
    let hash = 2166136261;
    for (let i = 0; i < text.length; i += 1) {
        hash ^= text.charCodeAt(i);
        hash = Math.imul(hash, 16777619);
    }
    return `${text.length}:${(hash >>> 0).toString(16)}`;
};

const makeReplaceTextCacheKey = ({ href, text }) => {
    return `neutral|${href || 'nil'}|${fingerprintReplaceTextInput(text)}`;
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
    const hasSentences = typeof html === 'string' && /<m-s\b/i.test(html);
    const hasSegments = typeof html === 'string' && /<m-m\b/i.test(html);
    return injectBodyDatasetAttributes(html, {
        'data-is-cache-warmer': isCacheWarmer ? 'true' : null,
        'data-mnb-source-href': href,
        'data-mnb-has-sentences': hasSentences ? 'true' : null,
        'data-mnb-has-segments': hasSegments ? 'true' : null,
    });
};

// Factory for replaceText with isCacheWarmer support
const makeReplaceText = (isCacheWarmer, { allowForegroundHTML = true } = {}) => async (href, text, mediaType) => {
    if (mediaType !== 'application/xhtml+xml' && mediaType !== 'text/html' /* && mediaType !== 'application/xml'*/ ) {
        return text;
    }
    if (!isCacheWarmer && !allowForegroundHTML) {
        throw new Error(`Foreground native EPUB section must load through processed-section direct URL: ${href || 'nil'}`);
    }
    const cacheKey = makeReplaceTextCacheKey({
        href,
        text,
    });
    if (replaceTextResultCache.has(cacheKey)) {
        const cachedNeutralHTML = replaceTextResultCache.get(cacheKey);
        const cachedHTML = adaptReplaceTextHTMLForMode(cachedNeutralHTML, { href, isCacheWarmer: !!isCacheWarmer });
        replaceTextResultCache.delete(cacheKey);
        replaceTextResultCache.set(cacheKey, cachedNeutralHTML);
        if (!isCacheWarmer) {
            window.manabi_recordLiveProcessedSection?.(href);
        }
        return cachedHTML;
    }
    if (replaceTextInFlightCache.has(cacheKey)) {
        const neutralHTML = await replaceTextInFlightCache.get(cacheKey);
        const html = adaptReplaceTextHTMLForMode(neutralHTML, { href, isCacheWarmer: !!isCacheWarmer });
        if (!isCacheWarmer) {
            window.manabi_recordLiveProcessedSection?.(href);
        }
        return html;
    }
    const run = async () => {
    const replaceTextStartedAt = performanceNowMs();
    const processTextRequestID = nextEbookLoadRequestID('process-text');
    const sourceURL = globalThis.reader.view.ownerDocument.defaultView.top.location.href;
    const requestBytes = isCacheWarmer ? (text?.length ?? 0) : 0;
    const transport = isCacheWarmer ? 'process-text-post' : 'processed-section-get';
    manabiTimelineMark('processText.start', {
        requestID: processTextRequestID,
        href,
        cacheWarmer: !!isCacheWarmer,
        requestBytes,
        transport,
    });
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
        "X-Replaced-Text-Location": href,
        "X-Content-Location": sourceURL,
        "X-Ebook-Source-URL": sourceURL,
    };
    if (isCacheWarmer) {
        headers["Content-Type"] = mediaType;
        headers['X-Is-Cache-Warmer'] = 'true';
    }
    const requestURL = isCacheWarmer
        ? 'ebook://ebook/process-text'
        : `ebook://ebook/processed-section?sourceURL=${encodeURIComponent(sourceURL)}&subpath=${encodeURIComponent(href)}`;
    const requestOptions = isCacheWarmer
        ? {
            method: "POST",
            mode: "cors",
            cache: "no-cache",
            headers: headers,
            body: text,
        }
        : {
            method: "GET",
            mode: "cors",
            cache: "no-cache",
            headers: headers,
        };
    const fetchStartedAt = performanceNowMs();
    const response = await fetch(requestURL, requestOptions).catch((error) => {
        ebookLoadLog('processText.fetch.error', {
            requestID: processTextRequestID,
            href,
            isCacheWarmer: !!isCacheWarmer,
            transport,
            elapsedMs: performanceNowMs() - replaceTextStartedAt,
            error: error?.message || String(error),
        });
        throw error;
    })
    const responseHeadersElapsedMs = performanceNowMs() - fetchStartedAt;
    if (!isCacheWarmer) {
        manabiTimelineMeasure('processText.fetchHeaders', fetchStartedAt, {
            requestID: processTextRequestID,
            href,
            cacheWarmer: false,
            status: response?.status ?? null,
            transport,
        }, 50);
    }
    try {
        if (!response.ok) {
            throw new Error(`HTTP error, status = ${response.status}`)
        }
        const textStartedAt = performanceNowMs();
        let html = await response.text()
        const responseTextElapsedMs = performanceNowMs() - textStartedAt;
        if (isCacheWarmer && html.length === 0) {
            html = '<html><body></body></html>';
        }
        const responseTextLength = html.length;
        const nativeCacheOutcome = response.headers?.get?.('x-manabi-process-cache') || null;
        const nativeResponseReadyElapsedMs = Number(response.headers?.get?.('x-manabi-response-ready-elapsed-ms'));
        const nativeResponseEncodeElapsedMs = Number(response.headers?.get?.('x-manabi-response-encode-elapsed-ms'));
        const nativeDidCoalesce = response.headers?.get?.('x-manabi-did-coalesce') || null;
        const processTextElapsedMs = performanceNowMs() - replaceTextStartedAt;
        const slowProcessTextLogThresholdMs = typeof MANABI_SLOW_PROCESS_TEXT_LOG_THRESHOLD_MS === 'number'
            ? MANABI_SLOW_PROCESS_TEXT_LOG_THRESHOLD_MS
            : 5000;
        if (!isCacheWarmer && processTextElapsedMs >= slowProcessTextLogThresholdMs) {
            ebookLoadLog('processText.slow', {
                requestID: processTextRequestID,
                href,
                elapsedMs: processTextElapsedMs,
                requestBytes,
                responseBytes: responseTextLength,
                nativeCache: nativeCacheOutcome,
                transport,
                fetchHeadersElapsedMs: responseHeadersElapsedMs,
                responseTextElapsedMs,
                nativeResponseReadyElapsedMs: Number.isFinite(nativeResponseReadyElapsedMs) ? nativeResponseReadyElapsedMs : null,
                nativeResponseEncodeElapsedMs: Number.isFinite(nativeResponseEncodeElapsedMs) ? nativeResponseEncodeElapsedMs : null,
                nativeDidCoalesce,
            });
        }
        if (!isCacheWarmer) {
            manabiTimelineMeasure('processText.responseText', textStartedAt, {
                requestID: processTextRequestID,
                href,
                responseBytes: responseTextLength,
                nativeCache: nativeCacheOutcome,
                transport,
                nativeResponseReadyElapsedMs: Number.isFinite(nativeResponseReadyElapsedMs) ? nativeResponseReadyElapsedMs : null,
                nativeResponseEncodeElapsedMs: Number.isFinite(nativeResponseEncodeElapsedMs) ? nativeResponseEncodeElapsedMs : null,
                nativeDidCoalesce,
            }, 50);
        }
        manabiTimelineMeasure('processText', replaceTextStartedAt, {
            requestID: processTextRequestID,
            href,
            cacheWarmer: !!isCacheWarmer,
            requestBytes,
            responseBytes: responseTextLength,
            nativeCache: nativeCacheOutcome,
            transport,
            fetchHeadersElapsedMs: responseHeadersElapsedMs,
            responseTextElapsedMs,
            nativeResponseReadyElapsedMs: Number.isFinite(nativeResponseReadyElapsedMs) ? nativeResponseReadyElapsedMs : null,
            nativeResponseEncodeElapsedMs: Number.isFinite(nativeResponseEncodeElapsedMs) ? nativeResponseEncodeElapsedMs : null,
            nativeDidCoalesce,
        });
        rememberReplaceTextResult(cacheKey, html);
        return html
    } catch (error) {
        ebookLoadLog('processText.errorFallbackOriginal', {
            requestID: processTextRequestID,
            href,
            isCacheWarmer: !!isCacheWarmer,
            elapsedMs: performanceNowMs() - replaceTextStartedAt,
            error: error?.message || String(error),
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
        const neutralHTML = await promise;
        const html = adaptReplaceTextHTMLForMode(neutralHTML, { href, isCacheWarmer: !!isCacheWarmer });
        if (!isCacheWarmer) {
            window.manabi_recordLiveProcessedSection?.(href);
        }
        return html;
    } finally {
        replaceTextInFlightCache.delete(cacheKey);
    }
}

const processedSectionURLForHref = (sourceURL, href, writingDirection = null) => {
    const params = new URLSearchParams({
        sourceURL,
        subpath: href,
        direct: '1',
    });
    if (writingDirection?.direction) params.set('mnbWritingDirection', writingDirection.direction);
    if (writingDirection?.writingMode) params.set('mnbWritingMode', writingDirection.writingMode);
    return `ebook://ebook/processed-section?${params.toString()}`;
};

const resolveEpubRelativePath = (url, relativeTo) => {
    try {
        if (String(relativeTo || '').includes(':')) return new URL(url, relativeTo).href;
        const root = 'https://invalid.invalid/';
        const obj = new URL(url, root + relativeTo);
        obj.search = '';
        return decodeURI(obj.href.replace(root, ''));
    } catch (_error) {
        return url;
    }
};

const computeRawSectionWritingDirectionFromText = async (href, text, loadText) => {
    if (!text || typeof DOMParser !== 'function') return null;
    const doc = new DOMParser().parseFromString(text, 'application/xhtml+xml');
    if (!doc?.documentElement || doc.querySelector?.('parsererror')) return null;

    const cloneDoc = document.implementation.createHTMLDocument();
    const clonedHead = doc.head?.cloneNode?.(true) ?? cloneDoc.createElement('head');
    clonedHead.querySelectorAll?.('script')?.forEach?.(el => el.remove());

    const stylesheetLinks = Array.from(clonedHead.querySelectorAll?.('link[rel="stylesheet"][href]') ?? []);
    const blobURLs = [];
    for (const link of stylesheetLinks) {
        const stylesheetHref = link.getAttribute('href');
        if (!stylesheetHref || /^(?:https?:|data:|blob:)/i.test(stylesheetHref)) continue;
        const resolvedHref = resolveEpubRelativePath(stylesheetHref, href);
        try {
            const css = await loadText?.(resolvedHref);
            if (!css) continue;
            const blobURL = URL.createObjectURL(new Blob([css], { type: 'text/css' }));
            blobURLs.push(blobURL);
            link.href = blobURL;
        } catch (_error) {}
    }

    const bodyClone = doc.body?.cloneNode?.(false) ?? cloneDoc.createElement('body');
    cloneDoc.head.replaceWith(clonedHead);
    cloneDoc.body.replaceWith(bodyClone);
    for (const { name, value } of Array.from(doc.documentElement?.attributes ?? [])) {
        cloneDoc.documentElement.setAttribute(name, value);
    }

    const iframe = document.createElement('iframe');
    iframe.style.cssText = 'position:fixed;visibility:hidden;width:0;height:0;border:0;contain:strict;';
    document.documentElement.appendChild(iframe);
    const blobURL = URL.createObjectURL(new Blob(
        ['<!doctype html>', cloneDoc.documentElement.outerHTML],
        { type: 'text/html' },
    ));
    blobURLs.push(blobURL);

    try {
        await new Promise(resolve => {
            iframe.onload = resolve;
            iframe.src = blobURL;
        });
        await new Promise(resolve => requestAnimationFrame(resolve));
        const probeDoc = iframe.contentDocument;
        const bodyStyle = iframe.contentWindow?.getComputedStyle?.(probeDoc?.body);
        const rootStyle = iframe.contentWindow?.getComputedStyle?.(probeDoc?.documentElement);
        const writingMode = (
            bodyStyle?.writingMode?.trim?.().toLowerCase?.()
            || rootStyle?.writingMode?.trim?.().toLowerCase?.()
            || ''
        );
        const direction = bodyStyle?.direction?.trim?.().toLowerCase?.() || rootStyle?.direction?.trim?.().toLowerCase?.() || null;
        const hasVerticalWritingClass =
            probeDoc?.body?.classList?.contains?.('reader-vertical-writing') === true
            || probeDoc?.documentElement?.classList?.contains?.('vrtl') === true;
        readerLoadLog('processText.directionProbe.rawComputed', {
            href,
            stylesheetCount: stylesheetLinks.length,
            bodyClass: probeDoc?.body?.className ?? null,
            rootClass: probeDoc?.documentElement?.className ?? null,
            writingMode: writingMode || null,
            direction,
            hasVerticalWritingClass,
        });
        if (writingMode === 'vertical-rl' || writingMode === 'vertical-lr') {
            return { direction: 'vertical', writingMode };
        }
        if (hasVerticalWritingClass) {
            return { direction: 'vertical', writingMode: 'vertical-rl' };
        }
        return null;
    } finally {
        iframe.remove();
        for (const url of blobURLs) {
            try { URL.revokeObjectURL(url); } catch (_error) {}
        }
    }
};

const rawSectionWritingDirectionCache = new Map();
const computeRawSectionWritingDirection = async (sourceURL, href, loadText = null) => {
    const cacheKey = `${sourceURL || ''}|${href || ''}`;
    if (rawSectionWritingDirectionCache.has(cacheKey)) {
        readerLoadLog('processText.directionProbe.cacheHit', { href });
        return rawSectionWritingDirectionCache.get(cacheKey);
    }
    const startedAt = performanceNowMs();
    const probePromise = new Promise((resolve) => {
        if (!sourceURL || !href) {
            resolve(null);
            return;
        }
        const iframe = document.createElement('iframe');
        let settled = false;
        const finish = (value) => {
            if (settled) return;
            settled = true;
            clearTimeout(timeout);
            iframe.remove();
            readerLoadLog('processText.directionProbe.finish', {
                href,
                writingDirection: value?.direction ?? null,
                writingMode: value?.writingMode ?? null,
                elapsedMs: safeRound(performanceNowMs() - startedAt, 1),
            });
            resolve(value);
        };
        const timeout = setTimeout(() => finish(null), 1200);
        const finishWithRawText = async () => {
            if (typeof loadText !== 'function') return false;
            try {
                const rawText = await loadText(href);
                const rawDirection = await computeRawSectionWritingDirectionFromText(href, rawText, loadText);
                if (rawDirection) {
                    finish(rawDirection);
                    return true;
                }
            } catch (_error) {
            }
            return false;
        };
        const startURLProbe = () => {
            if (settled) return;
            iframe.style.cssText = 'position:absolute;width:0;height:0;border:0;visibility:hidden;pointer-events:none;';
            readerLoadLog('processText.directionProbe.start', {
                href,
                sourceScheme: (() => {
                    try { return new URL(sourceURL).protocol.replace(':', ''); } catch (_error) { return 'unknown'; }
                })(),
            });
            iframe.addEventListener('load', () => {
                try {
                    const doc = iframe.contentDocument;
                    const body = doc?.body;
                    const root = doc?.documentElement;
                    const bodyStyle = iframe.contentWindow?.getComputedStyle?.(body);
                    const rootStyle = iframe.contentWindow?.getComputedStyle?.(root);
                    const writingMode = (
                        bodyStyle?.writingMode?.trim?.().toLowerCase?.()
                        || rootStyle?.writingMode?.trim?.().toLowerCase?.()
                        || ''
                    );
                    readerLoadLog('processText.directionProbe.loaded', {
                        href,
                        readyState: doc?.readyState ?? null,
                        bodyClass: body?.className ?? null,
                        rootClass: root?.className ?? null,
                        bodyTextLength: body?.textContent?.length ?? null,
                        writingMode: writingMode || null,
                        direction: bodyStyle?.direction?.trim?.().toLowerCase?.() ?? null,
                        hasReaderShell: !!doc?.querySelector?.('foliate-view, #viewer, #reader'),
                        hasEbookBody: body?.dataset?.isEbook === 'true',
                    });
                    if (writingMode === 'vertical-rl' || writingMode === 'vertical-lr') {
                        finish({ direction: 'vertical', writingMode });
                        return;
                    }
                } catch (_error) {}
                finish(null);
            }, { once: true });
            iframe.addEventListener('error', () => finish(null), { once: true });
            document.documentElement.appendChild(iframe);
            try {
                const sectionURL = new URL(sourceURL);
                sectionURL.searchParams.set('subpath', href);
                sectionURL.searchParams.set('directionProbe', '1');
                iframe.src = sectionURL.toString();
            } catch (_error) {
                readerLoadLog('processText.directionProbe.urlFallback', { href });
                iframe.src = `${sourceURL}?subpath=${encodeURIComponent(href)}&directionProbe=1`;
            }
        };
        void finishWithRawText().then(done => {
            if (!done) startURLProbe();
        });
    });
    rawSectionWritingDirectionCache.set(cacheKey, probePromise);
    return probePromise;
};

function makeReplaceURL(sourceURL, isCacheWarmer, loadText = null) {
    if (isCacheWarmer) {
        return null;
    }
    return async (href, mediaType) => {
        if (mediaType !== 'application/xhtml+xml' && mediaType !== 'text/html') {
            return null;
        }
        if (!href) {
            throw new Error('Direct processed section URL requires a spine href');
        }
        const writingDirection = await computeRawSectionWritingDirection(sourceURL, href, loadText);
        const directURL = processedSectionURLForHref(sourceURL, href, writingDirection);
        window.manabi_recordLiveProcessedSection?.(href);
        manabiTimelineMark('processText.directURL', {
            href,
            mediaType,
            transport: 'processed-section-url',
            requestBytes: 0,
            writingDirection: writingDirection?.direction ?? null,
            writingMode: writingDirection?.writingMode ?? null,
        });
        readerLoadLog('processText.directURL', {
            href,
            mediaType,
            writingDirection: writingDirection?.direction ?? null,
            writingMode: writingDirection?.writingMode ?? null,
        });
        return directURL;
    };
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
    if (globalThis.__manabiAvoidVisibleSegmentCollectionForProgress !== false) {
        return {
            hasVisibleJapaneseText: false,
            visibleSegmentCount: 0,
            observedSegmentCount: 0,
        };
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

const collectEBookLayoutSummary = (view = globalThis.reader?.view ?? null, extra = {}) => {
    const renderer = view?.renderer ?? globalThis.reader?.view?.renderer ?? null;
    const shadowRoot = renderer?.shadowRoot ?? null;
    const container = shadowRoot?.getElementById?.('container') ?? shadowRoot?.querySelector?.('#container') ?? null;
    const top = shadowRoot?.getElementById?.('top') ?? shadowRoot?.querySelector?.('#top') ?? null;
    const body = document.body;
    const bodyStyle = body ? getComputedStyle(body) : null;
    const readerStage = document.getElementById('reader-stage');
    const foliateView = Array.from(document.querySelectorAll('foliate-view'))
        .find((candidate) => candidate?.dataset?.isCache !== 'true') ?? document.querySelector('foliate-view');
    const loadingIndicator = document.getElementById('loading-indicator');
    const readerStageRect = loadRectSnapshot(readerStage);
    const foliateViewRect = loadRectSnapshot(foliateView);
    const rendererRect = loadRectSnapshot(renderer);
    const containerRect = loadRectSnapshot(container);
    const topRect = loadRectSnapshot(top);
    const loadingRect = loadRectSnapshot(loadingIndicator);
    const loadingStyle = loadingIndicator ? getComputedStyle(loadingIndicator) : null;
    return {
        ...extra,
        bodyLoading: !!body?.classList?.contains?.('loading'),
        bodyLoadingVisual: !!body?.classList?.contains?.('loading-visual'),
        bodyClass: body?.className || null,
        windowInnerHeight: roundLayoutNumber(window.innerHeight),
        visualViewportHeight: roundLayoutNumber(window.visualViewport?.height),
        readerStageTopInset: bodyStyle?.getPropertyValue('--mnb-reader-stage-top-inset')?.trim() || null,
        readerStageBottomInset: bodyStyle?.getPropertyValue('--mnb-reader-stage-bottom-inset')?.trim() || null,
        toolbarLayoutBottomInset: bodyStyle?.getPropertyValue('--mnb-toolbar-layout-bottom-inset')?.trim() || null,
        toolbarVisualBottomInset: bodyStyle?.getPropertyValue('--mnb-toolbar-visual-bottom-inset')?.trim() || null,
        readerStageTop: readerStageRect?.top ?? null,
        readerStageHeight: readerStageRect?.height ?? null,
        foliateTop: foliateViewRect?.top ?? null,
        foliateHeight: foliateViewRect?.height ?? null,
        rendererTop: rendererRect?.top ?? null,
        rendererHeight: rendererRect?.height ?? null,
        paginatorTopHeight: topRect?.height ?? null,
        containerTop: containerRect?.top ?? null,
        containerHeight: containerRect?.height ?? null,
        containerClientHeight: roundLayoutNumber(container?.clientHeight),
        containerOffsetHeight: roundLayoutNumber(container?.offsetHeight),
        loadingHidden: loadingIndicator?.hasAttribute?.('hidden') ?? null,
        loadingDisplay: loadingStyle?.display || null,
        loadingVisibility: loadingStyle?.visibility || null,
        loadingRectHeight: loadingRect?.height ?? null,
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
        readerBodySegmentCount: readerDoc?.querySelectorAll?.('m-m')?.length ?? null,
        readerBodySentenceCount: readerDoc?.querySelectorAll?.('m-s')?.length ?? null,
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
    trackedWordsActiveCount: globalThis.__manabiTrackedWordsActiveCount ?? 0,
    visibleStatusHydrationActiveCount: globalThis.__manabiVisibleStatusHydrationActiveCount ?? 0,
    nativeLookupMainFrameTargetsActiveCount: globalThis.__manabiNativeLookupMainFrameTargetsActiveCount ?? 0,
    foregroundNativeResourcePendingCount: globalThis.__manabiForegroundNativeResourcePendingCount ?? 0,
    foregroundCriticalSectionCount: globalThis.__manabiForegroundCriticalSectionCount ?? 0,
    cacheWarmerOpenInFlight: !!globalThis.__manabiCacheWarmerOpenInFlight,
    cacheWarmerReady: !!globalThis.__manabiCacheWarmerReady,
    cacheWarmerFinished: !!globalThis.__manabiCacheWarmerFinished,
    cacheWarmerHighestSectionIndex: globalThis.__manabiCacheWarmerHighestSectionIndex ?? null,
});

const beginForegroundCriticalSection = (reason = 'unspecified') => {
    const token = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    globalThis.__manabiForegroundCriticalSectionTokens ??= new Set();
    globalThis.__manabiForegroundCriticalSectionTokens.add(token);
    globalThis.__manabiForegroundCriticalSectionCount = globalThis.__manabiForegroundCriticalSectionTokens.size;
    manabiTimelineMark('foregroundCriticalSection.start', {
        reason,
        token,
        count: globalThis.__manabiForegroundCriticalSectionCount,
    });
    return token;
};

const finishForegroundCriticalSection = (token, reason = 'unspecified') => {
    if (!token || !(globalThis.__manabiForegroundCriticalSectionTokens instanceof Set)) {
        return;
    }
    const didDelete = globalThis.__manabiForegroundCriticalSectionTokens.delete(token);
    globalThis.__manabiForegroundCriticalSectionCount = globalThis.__manabiForegroundCriticalSectionTokens.size;
    if (didDelete) {
        manabiTimelineMark('foregroundCriticalSection.finish', {
            reason,
            token,
            count: globalThis.__manabiForegroundCriticalSectionCount,
        });
        if (globalThis.__manabiCacheWarmerOpenRequested) {
            void maybeOpenDeferredCacheWarmer();
        }
    }
};

const markCacheWarmerForegroundActivity = (reason = 'unspecified', cooldownMs = CACHE_WARMER_FOREGROUND_PAGE_TURN_COOLDOWN_MS) => {
    const now = performanceNowMs();
    const previousPausedUntil = Number(globalThis.__manabiCacheWarmerPausedUntilMs || 0);
    const nextPausedUntil = Math.max(previousPausedUntil, now + Math.max(0, Number(cooldownMs) || 0));
    globalThis.__manabiCacheWarmerPausedUntilMs = nextPausedUntil;
    globalThis.__manabiCacheWarmerWorkGeneration = (globalThis.__manabiCacheWarmerWorkGeneration || 0) + 1;
    manabiTimelineMark('cacheWarmer.invalidate', {
        reason,
        generation: globalThis.__manabiCacheWarmerWorkGeneration,
    });
};

window.manabi_pauseEbookCacheWarmerForLookup = (reason = 'lookup') => {
    markCacheWarmerForegroundActivity(`lookup.${reason}`, CACHE_WARMER_FOREGROUND_LOOKUP_COOLDOWN_MS);
};

const cacheWarmerWorkGeneration = () => globalThis.__manabiCacheWarmerWorkGeneration || 0;

const invalidateCacheWarmerWork = (reason = 'unspecified') => {
    globalThis.__manabiCacheWarmerWorkGeneration = (globalThis.__manabiCacheWarmerWorkGeneration || 0) + 1;
    manabiTimelineMark('cacheWarmer.invalidate', {
        reason,
        generation: globalThis.__manabiCacheWarmerWorkGeneration,
    });
    return globalThis.__manabiCacheWarmerWorkGeneration;
};

const cacheWarmerForegroundBusyState = () => {
    const now = performanceNowMs();
    const pauseRemainingMs = Math.max(0, Number(globalThis.__manabiCacheWarmerPausedUntilMs || 0) - now);
    const liveReplaceTextCount = globalThis.__manabiInflightLiveReplaceTextCount ?? 0;
    const trackedWordsActiveCount = globalThis.__manabiTrackedWordsActiveCount ?? 0;
    const visibleStatusHydrationActiveCount = globalThis.__manabiVisibleStatusHydrationActiveCount ?? 0;
    const nativeLookupMainFrameTargetsActiveCount = globalThis.__manabiNativeLookupMainFrameTargetsActiveCount ?? 0;
    const foregroundNativeResourcePendingCount = globalThis.__manabiForegroundNativeResourcePendingCount ?? 0;
    const foregroundCriticalSectionCount = globalThis.__manabiForegroundCriticalSectionCount ?? 0;
    const waitsForInitialVisibleWork = globalThis.__manabiCacheWarmerWaitsForInitialVisibleWork === true && !initialVisibleWorkReadyState.ready;
    const reader = globalThis.reader ?? null;
    const foregroundVisibleRefreshPending =
        !!reader?.nativeLookupHitTargetRefreshTimeout
        || !!reader?.nativeLookupHitTargetRefreshHandle
        || !!reader?.nativeLookupHitTargetSettleHandle
        || !!reader?.nativeMarkReadStateRefreshHandle
        || !!reader?.pageTrackingDeferredHandle
        || !!reader?.pageTrackingDeferredFrameHandle
        || !!reader?.pageTrackingRetryHandle;
    if (waitsForInitialVisibleWork || foregroundVisibleRefreshPending) {
        return {
            busy: true,
            reason: waitsForInitialVisibleWork ? 'initial-visible-work' : 'visible-refresh-pending',
            retryMs: CACHE_WARMER_IDLE_RETRY_MS,
            pauseRemainingMs: safeRound(pauseRemainingMs, 1),
            liveReplaceTextCount,
            trackedWordsActiveCount,
            visibleStatusHydrationActiveCount,
            nativeLookupMainFrameTargetsActiveCount,
            foregroundNativeResourcePendingCount,
            foregroundCriticalSectionCount,
        };
    }
    if (foregroundCriticalSectionCount > 0) {
        return {
            busy: true,
            reason: 'foreground-critical-section',
            retryMs: CACHE_WARMER_IDLE_RETRY_MS,
            pauseRemainingMs: safeRound(pauseRemainingMs, 1),
            liveReplaceTextCount,
            trackedWordsActiveCount,
            visibleStatusHydrationActiveCount,
            nativeLookupMainFrameTargetsActiveCount,
            foregroundNativeResourcePendingCount,
            foregroundCriticalSectionCount,
        };
    }
    if (liveReplaceTextCount > 0) {
        return {
            busy: true,
            reason: 'live-replace-text',
            retryMs: CACHE_WARMER_IDLE_RETRY_MS,
            pauseRemainingMs: safeRound(pauseRemainingMs, 1),
            liveReplaceTextCount,
            trackedWordsActiveCount,
            visibleStatusHydrationActiveCount,
            nativeLookupMainFrameTargetsActiveCount,
            foregroundNativeResourcePendingCount,
            foregroundCriticalSectionCount,
        };
    }
    if (trackedWordsActiveCount > 0) {
        return {
            busy: true,
            reason: 'tracked-words',
            retryMs: CACHE_WARMER_IDLE_RETRY_MS,
            pauseRemainingMs: safeRound(pauseRemainingMs, 1),
            liveReplaceTextCount,
            trackedWordsActiveCount,
            visibleStatusHydrationActiveCount,
            nativeLookupMainFrameTargetsActiveCount,
            foregroundNativeResourcePendingCount,
            foregroundCriticalSectionCount,
        };
    }
    if (visibleStatusHydrationActiveCount > 0) {
        return {
            busy: true,
            reason: 'visible-status-hydration',
            retryMs: CACHE_WARMER_IDLE_RETRY_MS,
            pauseRemainingMs: safeRound(pauseRemainingMs, 1),
            liveReplaceTextCount,
            trackedWordsActiveCount,
            visibleStatusHydrationActiveCount,
            nativeLookupMainFrameTargetsActiveCount,
            foregroundNativeResourcePendingCount,
            foregroundCriticalSectionCount,
        };
    }
    if (nativeLookupMainFrameTargetsActiveCount > 0) {
        return {
            busy: true,
            reason: 'native-lookup-targets',
            retryMs: CACHE_WARMER_IDLE_RETRY_MS,
            pauseRemainingMs: safeRound(pauseRemainingMs, 1),
            liveReplaceTextCount,
            trackedWordsActiveCount,
            visibleStatusHydrationActiveCount,
            nativeLookupMainFrameTargetsActiveCount,
            foregroundNativeResourcePendingCount,
            foregroundCriticalSectionCount,
        };
    }
    if (foregroundNativeResourcePendingCount > 0) {
        return {
            busy: true,
            reason: 'foreground-native-resource',
            retryMs: CACHE_WARMER_IDLE_RETRY_MS,
            pauseRemainingMs: safeRound(pauseRemainingMs, 1),
            liveReplaceTextCount,
            trackedWordsActiveCount,
            visibleStatusHydrationActiveCount,
            nativeLookupMainFrameTargetsActiveCount,
            foregroundNativeResourcePendingCount,
            foregroundCriticalSectionCount,
        };
    }
    if (pauseRemainingMs > 0) {
        return {
            busy: true,
            reason: 'foreground-cooldown',
            retryMs: Math.min(Math.max(80, pauseRemainingMs), CACHE_WARMER_FOREGROUND_PAGE_TURN_COOLDOWN_MS),
            pauseRemainingMs: safeRound(pauseRemainingMs, 1),
            liveReplaceTextCount,
            trackedWordsActiveCount,
            visibleStatusHydrationActiveCount,
            nativeLookupMainFrameTargetsActiveCount,
            foregroundNativeResourcePendingCount,
            foregroundCriticalSectionCount,
        };
    }
    return {
        busy: false,
        reason: null,
        retryMs: 0,
        pauseRemainingMs: 0,
        liveReplaceTextCount,
        trackedWordsActiveCount,
        visibleStatusHydrationActiveCount,
        nativeLookupMainFrameTargetsActiveCount,
        foregroundNativeResourcePendingCount,
        foregroundCriticalSectionCount,
    };
};

const latestObservedLongTaskEndMs = () => {
    const tasks = Array.isArray(globalThis.__manabiRecentLongTasks) ? globalThis.__manabiRecentLongTasks : [];
    let latest = 0;
    for (const task of tasks) {
        const duration = Number(task?.durationMs);
        const endMs = Number(task?.endMs);
        if (Number.isFinite(duration) && duration >= 50 && Number.isFinite(endMs)) {
            latest = Math.max(latest, endMs);
        }
    }
    return latest;
};

const waitForCacheWarmerMainThreadQuiet = async (reason = 'unspecified') => {
    const before = latestObservedLongTaskEndMs();
    await new Promise((resolve) => requestAnimationFrame(() => resolve()));
    const middle = latestObservedLongTaskEndMs();
    await new Promise((resolve) => requestAnimationFrame(() => resolve()));
    const after = latestObservedLongTaskEndMs();
    const quiet = before === middle && middle === after;
    globalThis.__manabiCacheWarmerMainThreadQuiet = quiet;
    globalThis.__manabiCacheWarmerLastQuietLongTaskEndMs = after;
    if (!quiet) {
        manabiTimelineMark('cacheWarmer.mainThreadQuiet.wait', {
            reason,
            before,
            middle,
            after,
            quiet,
            force: true,
        });
    }
    return quiet;
};

const scheduleLoadNextCacheWarmerSection = (settledSectionHrefs = [], reason = 'unspecified', options = {}) => {
    if (typeof window.cacheWarmer?.loadNextSectionSkippingSettled !== 'function') {
        return;
    }
    if (globalThis.__manabiNativeCacheWarmerInFlightSectionHref) {
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
    if (!force && globalThis.__manabiCacheWarmerMainThreadQuiet !== true) {
        void waitForCacheWarmerMainThreadQuiet(`advance:${reason}`).then((quiet) => {
            if (quiet) {
                scheduleLoadNextCacheWarmerSection(settledSectionHrefs, `${reason}.quiet`, options);
            } else {
                scheduleLoadNextCacheWarmerSection(settledSectionHrefs, `${reason}.long-task`, options);
            }
        });
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
            if (element.closest('m-m, .mnb-tracking-container')) return false;
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

const runWithNavigationIntent = async (intent, operation, { timeoutMs = null } = {}) => {
    const previousIntent = globalThis.__manabiNavigationIntent ?? null;
    globalThis.__manabiNavigationIntent = {
        timestamp: Date.now(),
        ...intent,
    };
    let timeoutHandle = null;
    try {
        const operationPromise = Promise.resolve().then(operation);
        if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
            return await operationPromise;
        }
        const timeoutPromise = new Promise((_, reject) => {
            timeoutHandle = setTimeout(() => {
                reject(new Error(`Timed out after ${timeoutMs}ms`));
            }, timeoutMs);
        });
        return await Promise.race([
            operationPromise,
            timeoutPromise,
        ]);
    } finally {
        if (timeoutHandle !== null) {
            clearTimeout(timeoutHandle);
        }
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

const applyNavigationHiddenVisualStateToEbookBody = (body, hidden) => {
    if (!body?.style) return false;
    const automaticLearningVisibility = body.dataset?.mnbLearningStatusVisibility === 'automatic';
    const shouldDimHighlights = hidden && automaticLearningVisibility;
    const previousState = body.dataset?.mnbNavigationHiddenDueToScroll ?? null;
    const nextState = hidden ? 'true' : 'false';
    let changed = previousState !== nextState;
    if (body.dataset && previousState !== nextState) {
        body.dataset.mnbNavigationHiddenDueToScroll = nextState;
    }
    for (const className of ['nav-hidden', 'nav-hidden-due-to-scroll']) {
        if (body.classList?.contains?.(className) !== hidden) {
            body.classList?.toggle?.(className, hidden);
            changed = true;
        }
    }
    const desiredValues = shouldDimHighlights
        ? {
            '--mnb-highlight-fill-opacity': '0',
            '--mnb-tracking-highlight-alpha': '0.5',
            '--mnb-jlpt-underline-alpha': '0.4',
            '--mnb-overlay-opacity': '1',
            '--mnb-tracking-highlight-opacity': '0.575',
        }
        : null;
    for (const property of [
        '--mnb-highlight-fill-opacity',
        '--mnb-tracking-highlight-alpha',
        '--mnb-jlpt-underline-alpha',
        '--mnb-overlay-opacity',
        '--mnb-tracking-highlight-opacity',
    ]) {
        const value = desiredValues?.[property] ?? '';
        if (value) {
            if (body.style.getPropertyValue(property) !== value) {
                body.style.setProperty(property, value);
                changed = true;
            }
        } else if (body.style.getPropertyValue(property)) {
            body.style.removeProperty(property);
            changed = true;
        }
    }
    return changed;
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
    const changed = applyNavigationHiddenVisualStateToEbookBody(body, hidden);
    return {
        applied: true,
        hidden,
        changed,
        mode: 'visual-vars',
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
    let changed = false;
    if (desiredTag === 'link') {
        const nextRel = sourceFontStyle.rel || 'stylesheet';
        const nextHref = sourceFontStyle.href;
        if (targetFontStyle.rel !== nextRel) {
            targetFontStyle.rel = nextRel;
            changed = true;
        }
        if (targetFontStyle.href !== nextHref) {
            targetFontStyle.href = nextHref;
            changed = true;
        }
    } else {
        const nextText = sourceFontStyle.textContent || '';
        if (targetFontStyle.textContent !== nextText) {
            targetFontStyle.textContent = nextText;
            changed = true;
        }
    }
    for (const [key, value] of Object.entries(sourceFontStyle.dataset || {})) {
        if (targetFontStyle.dataset[key] !== value) {
            targetFontStyle.dataset[key] = value;
            changed = true;
        }
    }
    if (doc.documentElement && sourceFontStyle.dataset?.mnbInjectedFontFamily) {
        const nextFamily = sourceFontStyle.dataset.mnbInjectedFontFamily;
        if (doc.documentElement.dataset.mnbInjectedFontFamily !== nextFamily) {
            doc.documentElement.dataset.mnbInjectedFontFamily = nextFamily;
            changed = true;
        }
        if (doc.documentElement.dataset.mnbFontInjected !== '1') {
            doc.documentElement.dataset.mnbFontInjected = '1';
            changed = true;
        }
    }
    return changed;
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

const normalizeReaderPresentationState = (settings = null) => {
    if (!settings || typeof settings !== 'object') return null;
    const colorScheme = settings.colorScheme === 'dark' || settings.colorScheme === 'light'
        ? settings.colorScheme
        : null;
    const readerFontSize = Number(settings.readerFontSize);
    const resolvedFontSize = Number.isFinite(readerFontSize) && readerFontSize > 0
        ? readerFontSize
        : null;
    const readerContentRTSize = Number(settings.readerContentRTSize);
    const resolvedRTSize = Number.isFinite(readerContentRTSize) && readerContentRTSize > 0
        ? readerContentRTSize
        : (resolvedFontSize ? resolvedFontSize * 0.46 : null);
    const lightModeTheme = typeof settings.lightModeTheme === 'string' && settings.lightModeTheme.length > 0
        ? settings.lightModeTheme
        : null;
    const darkModeTheme = typeof settings.darkModeTheme === 'string' && settings.darkModeTheme.length > 0
        ? settings.darkModeTheme
        : null;
    const maxWidthOverride = typeof settings.maxWidthOverride === 'string' && settings.maxWidthOverride.length > 0
        ? settings.maxWidthOverride
        : null;
    const writingDirection = 'original';
    return {
        colorScheme,
        lightModeTheme,
        darkModeTheme,
        readerFontSize: resolvedFontSize,
        readerContentRTSize: resolvedRTSize,
        readerFontSizeCSS: resolvedFontSize ? `${resolvedFontSize}px` : null,
        readerContentRTSizeCSS: resolvedRTSize ? `${resolvedRTSize}px` : null,
        readerBoldText: settings.readerBoldText === true,
        maxWidthOverride,
        writingDirection,
    };
};

const applyReaderPresentationStateToDocument = (doc, settings, reason = 'unknown') => {
    const normalized = normalizeReaderPresentationState(settings);
    const body = doc?.body;
    if (!normalized || !body) return false;
    const root = doc.documentElement;
    const signature = JSON.stringify(normalized);
    if (body.dataset.mnbReaderPresentationStateSignature === signature) {
        return false;
    }
    if (normalized.colorScheme) {
        body.dataset.mnbColorScheme = normalized.colorScheme;
        root?.style?.setProperty?.('color-scheme', normalized.colorScheme);
        body.style?.setProperty?.('color-scheme', normalized.colorScheme);
    }
    if (normalized.lightModeTheme) {
        body.dataset.mnbLightTheme = normalized.lightModeTheme;
    }
    if (normalized.darkModeTheme) {
        body.dataset.mnbDarkTheme = normalized.darkModeTheme;
    }
    if (normalized.readerFontSizeCSS) {
        body.style.setProperty('font-size', normalized.readerFontSizeCSS);
        body.style.setProperty('--mnb-reader-content-font-size', normalized.readerFontSizeCSS);
        root?.style?.setProperty?.('--mnb-reader-content-font-size', normalized.readerFontSizeCSS);
    }
    if (normalized.readerContentRTSizeCSS) {
        body.style.setProperty('--mnb-reader-content-rt-size', normalized.readerContentRTSizeCSS);
        root?.style?.setProperty?.('--mnb-reader-content-rt-size', normalized.readerContentRTSizeCSS);
    }
    if (normalized.readerBoldText) {
        body.style.setProperty('font-weight', '600');
    } else {
        body.style.removeProperty('font-weight');
    }
    if (normalized.maxWidthOverride) {
        body.style.setProperty('--mnb-reader-max-width-override', normalized.maxWidthOverride);
        root?.style?.setProperty?.('--mnb-reader-max-width-override', normalized.maxWidthOverride);
    }
    body.dataset.mnbReaderPresentationStateSignature = signature;
    body.dataset.mnbReaderPresentationStateReason = reason;
    return true;
};

const installReaderPresentationState = (settings = null, reason = 'unknown') => {
    const normalized = normalizeReaderPresentationState(settings);
    if (!normalized) return null;
    globalThis.__manabiReaderPresentationState = normalized;
    if (normalized.colorScheme) globalThis.manabiReaderColorScheme = normalized.colorScheme;
    if (normalized.lightModeTheme) globalThis.manabiReaderLightModeTheme = normalized.lightModeTheme;
    if (normalized.darkModeTheme) globalThis.manabiReaderDarkModeTheme = normalized.darkModeTheme;
    if (normalized.readerFontSizeCSS) globalThis.manabiReaderFontSizeCSS = normalized.readerFontSizeCSS;
    if (normalized.maxWidthOverride) globalThis.manabiReaderMaxWidthOverride = normalized.maxWidthOverride;
    if (normalized.writingDirection) globalThis.__manabiEbookViewerWritingDirection = normalized.writingDirection;
    const applied = applyReaderPresentationStateToDocument(document, normalized, reason);
    readerLoadLog('readerPresentationState.applied', {
        reason,
        applied,
        colorScheme: normalized.colorScheme,
        lightModeTheme: normalized.lightModeTheme,
        darkModeTheme: normalized.darkModeTheme,
        readerFontSizeCSS: normalized.readerFontSizeCSS,
        readerBoldText: normalized.readerBoldText,
        maxWidthOverride: normalized.maxWidthOverride,
        writingDirection: normalized.writingDirection,
    });
    return normalized;
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

const requestCacheWarmerPrecedingSectionsForHref = (href, reason = 'foreground') => {
    const targetIndex = sectionIndexForHref(href);
    if (!Number.isInteger(targetIndex) || targetIndex <= 0) return;
    if (isCacheWarmerPrecedingSectionsComplete(targetIndex)) return;
    const existingTarget = cacheWarmerPrecedingTargetIndex();
    const nextTarget = Math.max(existingTarget ?? 0, targetIndex);
    globalThis.__manabiCacheWarmerRequiredPrecedingTargetIndex = nextTarget;
    if (
        !globalThis.__manabiCacheWarmerReady
        && !globalThis.__manabiCacheWarmerOpenInFlight
        && !globalThis.__manabiCacheWarmerOpenRequested
    ) {
        scheduleDeferredCacheWarmerOpen(`preceding-sections-required:${reason}`, 0);
    }
    if (globalThis.__manabiCacheWarmerOpenRequested) {
        void maybeOpenDeferredCacheWarmer();
    }
    scheduleLoadNextCacheWarmerSection([], `preceding-sections-required:${reason}`, { force: true });
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
    if (
        globalThis.__manabiCacheWarmerWaitsForInitialVisibleWork === true
        && !initialVisibleWorkReadyState.ready
    ) {
        return;
    }
    if (!isForegroundReaderIdle()) {
        const firstLiveHref = firstLiveSectionHref();
        const firstLiveSettled = !!firstLiveHref && liveSettledSectionHrefSet().has(firstLiveHref);
        if (!globalThis.__manabiDeferredCacheWarmerLogged) {
            globalThis.__manabiDeferredCacheWarmerLogged = true;
        }
        return;
    }
    if (globalThis.__manabiCacheWarmerMainThreadQuiet !== true) {
        const quiet = await waitForCacheWarmerMainThreadQuiet('open:direct');
        if (!quiet) {
            scheduleDeferredCacheWarmerOpen('direct.long-task');
            return;
        }
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
    const shouldWaitForInitialVisibleWork = shouldWaitForInitialVisibleWorkBeforeCacheWarmer(reason);
    if (shouldWaitForInitialVisibleWork && !initialVisibleWorkReadyState.ready) {
        globalThis.__manabiCacheWarmerWaitsForInitialVisibleWork = true;
    }
    const normalizedDelay = Math.max(0, Number(delayMs) || 0);
    globalThis.__manabiCacheWarmerOpenTimer = setTimeout(async () => {
        globalThis.__manabiCacheWarmerOpenTimer = null;
        if (shouldWaitForInitialVisibleWork && !initialVisibleWorkReadyState.ready) {
            const visibleWorkReady = await waitForInitialVisibleWorkReady(`cache-warmer:${reason}`);
            if (!visibleWorkReady.ready) {
                globalThis.__manabiCacheWarmerWaitsForInitialVisibleWork = false;
                readerLoadLog('cacheWarmer.initialVisibleReady.timeout', {
                    reason,
                    timeoutMs: visibleWorkReady.timeoutMs ?? CACHE_WARMER_INITIAL_VISIBLE_READY_FALLBACK_MS,
                });
            }
        }
        const busyState = cacheWarmerForegroundBusyState();
        if (busyState.busy) {
            scheduleDeferredCacheWarmerOpen(`${reason}.retry`, busyState.retryMs);
            return;
        }
        const quiet = await waitForCacheWarmerMainThreadQuiet(`open:${reason}`);
        if (!quiet) {
            scheduleDeferredCacheWarmerOpen(`${reason}.long-task`);
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
    return getAuthoritativeReaderFractionDiagnostics({ navHUD, detail, fallbackFraction }).fraction;
};

const getAuthoritativeReaderFractionDiagnostics = ({ navHUD = null, detail = null, fallbackFraction = null } = {}) => {
    const primaryLabelFraction = navHUD?.lastPrimaryLabelDiagnostics?.fraction ?? null;
    if (typeof primaryLabelFraction === 'number' && Number.isFinite(primaryLabelFraction)) {
        return {
            fraction: Math.max(0, Math.min(1, primaryLabelFraction)),
            source: 'primary-label',
            primaryLabelFraction,
            scrubberFraction: null,
            fallbackFraction,
        };
    }
    const scrubberFraction = navHUD?.getScrubberFraction?.(detail ?? null) ?? null;
    if (typeof scrubberFraction === 'number' && Number.isFinite(scrubberFraction)) {
        return {
            fraction: Math.max(0, Math.min(1, scrubberFraction)),
            source: 'scrubber',
            primaryLabelFraction,
            scrubberFraction,
            fallbackFraction,
        };
    }
    if (typeof fallbackFraction === 'number' && Number.isFinite(fallbackFraction)) {
        return {
            fraction: Math.max(0, Math.min(1, fallbackFraction)),
            source: 'fallback',
            primaryLabelFraction,
            scrubberFraction,
            fallbackFraction,
        };
    }
    return {
        fraction: null,
        source: 'none',
        primaryLabelFraction,
        scrubberFraction,
        fallbackFraction,
    };
};

const performanceNowMs = () =>
    typeof performance !== 'undefined' && typeof performance.now === 'function'
        ? performance.now()
        : Date.now();

globalThis.__manabiPerformanceNowMs = performanceNowMs;
globalThis.__manabiSafeRound = safeRound;

const manabiSectionIndexFromLocation = (location) => (
    typeof location?.section?.current === 'number'
        ? location.section.current
        : (typeof location?.sectionIndex === 'number' ? location.sectionIndex : null)
);

const manabiFractionFromLocation = (location) => (
    typeof location?.fraction === 'number' && Number.isFinite(location.fraction)
        ? location.fraction
        : null
);

const manabiCreateInitialRestoreResult = ({
    requestID = null,
    terminalState = 'noTarget',
    requestedLocator = null,
    resolvedLocator = null,
    requestedFraction = null,
    requestedCFI = null,
    location = null,
    navigationOk = null,
    reason = null,
    error = null,
    startedAt = null,
    handledFractionalCompletion = undefined,
} = {}) => {
    const currentFraction = manabiFractionFromLocation(location);
    const currentSectionIndex = manabiSectionIndexFromLocation(location);
    const finiteRequestedFraction = Number.isFinite(requestedFraction) ? requestedFraction : null;
    const restoreSatisfied = terminalState === 'satisfied';
    return {
        requestID,
        terminalState,
        requestedLocator,
        resolvedLocator,
        requestedFraction: finiteRequestedFraction,
        currentFraction,
        fractionDelta: finiteRequestedFraction != null && typeof currentFraction === 'number'
            ? Math.abs(currentFraction - finiteRequestedFraction)
            : null,
        handledCFI: restoreSatisfied && typeof requestedCFI === 'string'
            ? requestedCFI
            : null,
        handledFractionalCompletion: restoreSatisfied
            ? (handledFractionalCompletion !== undefined
                ? handledFractionalCompletion
                : (finiteRequestedFraction != null ? finiteRequestedFraction : currentFraction))
            : null,
        currentSectionIndex,
        navigationOk,
        restoreSatisfied,
        error,
        reason,
        elapsedMs: startedAt != null ? safeRound(performanceNowMs() - startedAt, 1) : null,
    };
};

const manabiPublishInitialRestoreResult = (result) => {
    globalThis.__manabiInitialRestoreResult = result;
    globalThis.__manabiRestoreDebugLog?.('ebook.initialRestore.terminalResult', {
        ...result,
        requestedFraction: result.requestedFraction != null ? safeRound(result.requestedFraction, 6) : null,
        currentFraction: result.currentFraction != null ? safeRound(result.currentFraction, 6) : null,
        fractionDelta: result.fractionDelta != null ? safeRound(result.fractionDelta, 6) : null,
        handledFractionalCompletion: result.handledFractionalCompletion != null ? safeRound(result.handledFractionalCompletion, 6) : null,
    });
    return result;
};

const MANABI_TIMELINE_SLOW_THRESHOLD_MS = 1000;
const manabiTimelineValue = value => {
    if (value == null) return 'nil';
    if (typeof value === 'number') return Number.isFinite(value) ? String(safeRound(value, 1)) : String(value);
    if (typeof value === 'boolean') return value ? 'true' : 'false';
    return String(value).replace(/\s+/g, ' ').slice(0, 96);
};
const manabiTimelinePayload = payload => Object.entries(payload || {})
    .filter(([, value]) => value !== undefined)
    .map(([key, value]) => `${key}=${manabiTimelineValue(value)}`)
    .join(' ');
const manabiTimelineShouldEmitMark = (event, payload = {}) => {
    if (globalThis.__manabiTimelineTraceAll === true) return true;
    if (payload?.force === true || payload?.error) return true;
    if (typeof payload?.elapsedMs === 'number') return payload.elapsedMs >= 50;
    const value = String(event || '');
    return value === 'longTask'
        || value.endsWith('.slow')
        || value.endsWith('.error')
        || value.endsWith('.cancel')
        || value.includes('resource.')
        || value.includes('watchdog')
        || value.startsWith('reader.')
        || value.startsWith('viewer.load')
        || value.startsWith('nativeResource.foreground');
};
const manabiTimelineMark = (event, payload = {}) => {
    const details = manabiTimelinePayload(payload);
    const label = details.length > 0 ? `MANABI ${event} ${details}` : `MANABI ${event}`;
    if (!manabiTimelineShouldEmitMark(event, payload)) {
        return label;
    }
    try {
        const eventRecord = {
            event,
            payload,
            label,
            atMs: safeRound(performanceNowMs(), 1),
        };
        const events = globalThis.__manabiTimelineEvents ||= [];
        events.push(eventRecord);
        if (events.length > 200) {
            events.splice(0, events.length - 200);
        }
    } catch (_error) {}
    try {
        performance?.mark?.(label);
    } catch (_error) {}
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.(`# MANABITRACE ${label}`);
    } catch (_error) {}
    return label;
};
const manabiTimelineMeasure = (event, startedAt, payload = {}, thresholdMs = MANABI_TIMELINE_SLOW_THRESHOLD_MS) => {
    const endedAt = performanceNowMs();
    const elapsedMs = endedAt - startedAt;
    if (elapsedMs < thresholdMs && globalThis.__manabiTimelineTraceAll !== true) {
        return elapsedMs;
    }
    const label = manabiTimelineMark(event, { ...payload, elapsedMs });
    try {
        performance?.measure?.(label, { start: startedAt, end: endedAt });
    } catch (_error) {}
    return elapsedMs;
};
globalThis.__manabiTimelineMark = manabiTimelineMark;
globalThis.__manabiTimelineMeasure = manabiTimelineMeasure;

const installManabiLongTaskProbe = () => {
    if (globalThis.__manabiLongTaskProbeInstalled === true) return;
    if (typeof PerformanceObserver !== 'function') return;
    globalThis.__manabiLongTaskProbeInstalled = true;
    globalThis.__manabiRecentLongTasks = globalThis.__manabiRecentLongTasks || [];
    try {
        const observer = new PerformanceObserver((list) => {
            for (const entry of list.getEntries?.() ?? []) {
                const longTaskPayload = {
                    durationMs: entry.duration,
                    startMs: entry.startTime,
                    endMs: entry.startTime + entry.duration,
                    name: entry.name || null,
                    frame: 'ebook-viewer',
                    cacheWarmerReady: !!globalThis.__manabiCacheWarmerReady,
                    inflightReplaceTextCount: globalThis.__manabiInflightReplaceTextCount ?? 0,
                    foregroundNativeResourcePendingCount: globalThis.__manabiForegroundNativeResourcePendingCount ?? 0,
                    foregroundCriticalSectionCount: globalThis.__manabiForegroundCriticalSectionCount ?? 0,
                };
                globalThis.__manabiRecentLongTasks.push(longTaskPayload);
                globalThis.__manabiCacheWarmerMainThreadQuiet = false;
                if (globalThis.__manabiRecentLongTasks.length > 25) {
                    globalThis.__manabiRecentLongTasks.splice(0, globalThis.__manabiRecentLongTasks.length - 25);
                }
                manabiTimelineMark('longTask', longTaskPayload);
            }
        });
        observer.observe({ type: 'longtask', buffered: true });
        globalThis.__manabiLongTaskObserver = observer;
    } catch (_error) {}
};
installManabiLongTaskProbe();

const installManabiResourceTimingProbe = () => {
    if (globalThis.__manabiResourceTimingProbeInstalled === true) return;
    globalThis.__manabiResourceTimingProbeInstalled = true;
    const slowThresholdMs = 1000;
    const describeRecentLongTaskOverlap = (startMs, endMs) => {
        const tasks = Array.isArray(globalThis.__manabiRecentLongTasks) ? globalThis.__manabiRecentLongTasks : [];
        const overlapping = tasks.filter((task) => {
            const taskStart = Number(task?.startMs);
            const taskEnd = Number(task?.endMs);
            return Number.isFinite(taskStart)
                && Number.isFinite(taskEnd)
                && taskStart <= endMs
                && taskEnd >= startMs;
        });
        if (overlapping.length === 0) {
            return null;
        }
        return {
            count: overlapping.length,
            maxDurationMs: Math.max(...overlapping.map((task) => Number(task.durationMs) || 0)),
            latestStartMs: Math.max(...overlapping.map((task) => Number(task.startMs) || 0)),
        };
    };
    const describeResourceURL = (name, initiatorType = '') => {
        const rawName = typeof name === 'string' ? name : '';
        let blobInfo = null;
        try {
            blobInfo = globalThis.__manabiBlobResourceMap?.get?.(rawName) ?? null;
        } catch (_error) {}
        let decodedName = rawName;
        try {
            decodedName = decodeURIComponent(rawName);
        } catch (_error) {}
        let subpath = null;
        try {
            subpath = new URL(rawName).searchParams.get('subpath');
        } catch (_error) {}
        subpath ??= typeof blobInfo?.href === 'string' ? blobInfo.href : null;
        return {
            name: (blobInfo?.href ?? decodedName).slice(0, 160),
            subpath: subpath ? subpath.slice(0, 120) : null,
            isEbook: rawName.startsWith('ebook://') || rawName.startsWith('blob:ebook://'),
            isCSS: /\.css(?:[?#]|$)/i.test(decodedName)
                || /\.css(?:[?#]|$)/i.test(blobInfo?.href ?? '')
                || blobInfo?.type === 'text/css'
                || rawName.includes('manabi-fonts.css')
                || rawName.includes('text/css')
                || initiatorType === 'link',
        };
    };
    const emitResourceTiming = (entry) => {
        if (!entry || typeof entry.name !== 'string') return;
        const timing = describeResourceURL(entry.name, entry.initiatorType || '');
        if (!timing.isEbook && !timing.isCSS) return;
        const duration = Number.isFinite(entry.duration) ? entry.duration : 0;
        if (duration < slowThresholdMs && globalThis.__manabiTimelineTraceAll !== true) return;
        const startMs = Number.isFinite(entry.startTime) ? entry.startTime : null;
        const responseEndMs = Number.isFinite(entry.responseEnd) ? entry.responseEnd : null;
        manabiTimelineMark(timing.isCSS ? 'resource.css.slow' : 'resource.slow', {
            name: timing.name,
            subpath: timing.subpath,
            initiatorType: entry.initiatorType || null,
            durationMs: duration,
            startMs,
            responseStartMs: Number.isFinite(entry.responseStart) ? entry.responseStart : null,
            responseEndMs,
            transferSize: Number.isFinite(entry.transferSize) ? entry.transferSize : null,
            encodedBodySize: Number.isFinite(entry.encodedBodySize) ? entry.encodedBodySize : null,
            decodedBodySize: Number.isFinite(entry.decodedBodySize) ? entry.decodedBodySize : null,
            foregroundCriticalSectionCount: globalThis.__manabiForegroundCriticalSectionCount ?? 0,
            overlappingLongTask: Number.isFinite(startMs) && Number.isFinite(responseEndMs)
                ? describeRecentLongTaskOverlap(startMs, responseEndMs)
                : null,
        });
    };
    try {
        performance?.getEntriesByType?.('resource')?.forEach?.(emitResourceTiming);
    } catch (_error) {}
    try {
        const observer = new PerformanceObserver((list) => {
            list.getEntries?.().forEach?.(emitResourceTiming);
        });
        observer.observe({ type: 'resource', buffered: true });
        globalThis.__manabiResourceTimingObserver = observer;
    } catch (_error) {}
};
installManabiResourceTimingProbe();

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
const emptySegmentMetadataBootstrap = () => ({
    byID: new Map(),
    idsByEntryID: new Map(),
    segments: [],
    aggregates: null,
    sentenceArchive: new Map(),
});

const segmentMetadataSidecarSignature = (sidecarTexts) => (
    sidecarTexts.map((text) => {
        let hash = 2166136261;
        for (let index = 0; index < text.length; index += 1) {
            hash ^= text.charCodeAt(index);
            hash = Math.imul(hash, 16777619);
        }
        return `${text.length}:${(hash >>> 0).toString(36)}`;
    }).join('|')
);

const segmentMetadataSidecarNodesMatch = (sidecars, cachedSidecars) => (
    Array.isArray(cachedSidecars)
    && cachedSidecars.length === sidecars.length
    && sidecars.every((sidecar, index) => sidecar === cachedSidecars[index])
);

const segmentMetadataSidecarSnapshot = (doc) => {
    const startedAt = performanceNowMs();
    const primarySidecar = typeof doc?.getElementById === 'function'
        ? doc.getElementById('mnb-segment-metadata')
        : null;
    const sidecars = primarySidecar
        ? [primarySidecar]
        : Array.from(doc?.getElementsByTagName?.('script') || [])
            .filter((script) => script?.hasAttribute?.('data-mnb-seg-meta'));
    const sidecarTexts = sidecars.map((sidecar) => sidecar.textContent || '');
    const cachedSnapshot = doc?.manabiSegmentMetadataSidecarSnapshot;
    if (
        cachedSnapshot
        && segmentMetadataSidecarNodesMatch(sidecars, cachedSnapshot.sidecars)
        && Array.isArray(cachedSnapshot.sidecarTexts)
        && cachedSnapshot.sidecarTexts.length === sidecarTexts.length
        && sidecarTexts.every((text, index) => text === cachedSnapshot.sidecarTexts[index])
    ) {
        cachedSnapshot.reusedCachedSidecars = true;
        manabiTimelineMeasure('segmentMetadata.sidecarSnapshot.cached', startedAt, {
            sidecarCount: sidecars.length,
        }, 25);
        return cachedSnapshot;
    }
    const sidecarSignature = segmentMetadataSidecarSignature(sidecarTexts);
    const sidecarBytes = sidecarTexts.reduce((total, text) => total + text.length, 0);
    manabiTimelineMeasure('segmentMetadata.sidecarSnapshot.fresh', startedAt, {
        sidecarCount: sidecars.length,
        sidecarBytes,
        primarySidecar: !!primarySidecar,
    }, 25);
    return { sidecars, sidecarTexts, sidecarSignature, reusedCachedSidecars: false };
};

const segmentMetadataAggregateSidecarSnapshot = (doc) => {
    const startedAt = performanceNowMs();
    const primarySidecar = typeof doc?.getElementById === 'function'
        ? doc.getElementById('mnb-segment-metadata-aggregate')
        : null;
    const sidecars = primarySidecar
        ? [primarySidecar]
        : Array.from(doc?.getElementsByTagName?.('script') || [])
            .filter((script) => script?.hasAttribute?.('data-mnb-seg-meta-aggregate'));
    const sidecarTexts = sidecars.map((sidecar) => sidecar.textContent || '');
    const sidecarSignature = segmentMetadataSidecarSignature(sidecarTexts);
    const sidecarBytes = sidecarTexts.reduce((total, text) => total + text.length, 0);
    manabiTimelineMeasure('segmentMetadata.aggregateSidecarSnapshot.fresh', startedAt, {
        sidecarCount: sidecars.length,
        sidecarBytes,
        primarySidecar: !!primarySidecar,
    }, 25);
    return { sidecars, sidecarTexts, sidecarSignature, reusedCachedSidecars: false };
};

const segmentMetadataSidecarsMatchCache = (doc, snapshot) => {
    if (snapshot?.reusedCachedSidecars === true) return true;
    const cachedSidecars = doc.manabiSegmentMetadataSidecars || [];
    const cachedSidecarTexts = doc.manabiSegmentMetadataSidecarTexts || [];
    return (
        cachedSidecars.length === snapshot.sidecars.length
        && snapshot.sidecars.every((sidecar, index) => (
            sidecar === cachedSidecars[index]
            && snapshot.sidecarTexts[index] === cachedSidecarTexts[index]
        ))
    );
};

const cacheSegmentMetadataSidecarSnapshot = (doc, snapshot) => {
    doc.manabiSegmentMetadataSidecars = snapshot.sidecars;
    doc.manabiSegmentMetadataSidecarTexts = snapshot.sidecarTexts;
    doc.manabiSegmentMetadataSidecarSignature = snapshot.sidecarSignature;
    doc.manabiSegmentMetadataSidecarSnapshot = snapshot;
};

const segmentMetadataPayloadsForSnapshot = (doc, snapshot) => {
    const startedAt = performanceNowMs();
    const hasMatchingSidecars =
        doc.manabiSegmentMetadataSidecarSignature === snapshot.sidecarSignature
        && segmentMetadataSidecarsMatchCache(doc, snapshot);
    if (hasMatchingSidecars && Array.isArray(doc.manabiSegmentMetadataSidecarPayloads)) {
        manabiTimelineMeasure('segmentMetadata.payloads.cached', startedAt, {
            payloadCount: doc.manabiSegmentMetadataSidecarPayloads.length,
            sidecarCount: snapshot.sidecars.length,
        }, 25);
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
    manabiTimelineMeasure('segmentMetadata.payloads.parsed', startedAt, {
        payloadCount: payloads.length,
        sidecarCount: snapshot.sidecars.length,
        reusedCachedSidecars: snapshot.reusedCachedSidecars === true,
    }, 25);
    return payloads;
};

const resetSegmentMetadataCachesForSnapshot = (doc, snapshot) => {
    doc.manabiSegmentMetadataByID = new Map();
    doc.manabiSegmentIDsByEntryID = new Map();
    doc.manabiSegmentMetadataSegments = [];
    doc.manabiSegmentMetadataAggregates = null;
    doc.manabiSegmentMetadataSentenceArchive = new Map();
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
    if (version >= 5 && token.startsWith('~')) return `_m${token.slice(1)}`;
    if (version >= 3) return token.startsWith('!') ? token.slice(1) : `mnb-s${token}`;
    return token;
};

const stableSegmentID = (sentenceID, segmentHash) => (
    typeof sentenceID === 'string' && sentenceID.length > 0
    && typeof segmentHash === 'string' && segmentHash.length > 0
        ? `${sentenceID}-${segmentHash}`
        : null
);

const segmentMetadataTableArray = (tables, shortKey, longKey) => (
    Array.isArray(tables?.[shortKey])
        ? tables[shortKey]
        : (Array.isArray(tables?.[longKey]) ? tables[longKey] : [])
);

const compactSegmentMetadataTables = (compactTables) => ({
    h: segmentMetadataTableArray(compactTables, 'h', 'segmentHashes'),
    j: segmentMetadataTableArray(compactTables, 'j', 'jmdictEntryIDs'),
    n: segmentMetadataTableArray(compactTables, 'n', 'jmnedictEntryIDs'),
    s: segmentMetadataTableArray(compactTables, 's', 'jmdictSearchStrings'),
    ns: segmentMetadataTableArray(compactTables, 'ns', 'jmnedictSearchStrings'),
    p: segmentMetadataTableArray(compactTables, 'p', 'partsOfSpeech'),
    x: segmentMetadataTableArray(compactTables, 'x', 'surfaceTexts'),
    sid: segmentMetadataTableArray(compactTables, 'sid', 'sentenceIdentifiers'),
    pid: segmentMetadataTableArray(compactTables, 'pid', 'paragraphIdentifiers'),
});

const segmentMetadataFromCompactTuple = (segment, tables, version) => {
    const segmentHash = version >= 3
        ? segmentMetadataTableValue(tables.h, segment?.[1], null)
        : segment?.[1];
    const sentenceID = version >= 3
        ? segmentMetadataTableValue(tables.sid, segment?.[9], null)
        : null;
    const paragraphID = version >= 6
        ? segmentMetadataTableValue(tables.pid, segment?.[10], null)
        : null;
    const hasRubyIndex = version >= 6 ? 11 : 10;
    return {
        i: expandSegmentIDToken(segment?.[0], version), // segment element ID
        h: segmentHash,
        sid: stableSegmentID(sentenceID, segmentHash),
        j: segmentMetadataTableValue(tables.j, segment?.[2], []), // JMDict entry IDs from table index
        n: segmentMetadataTableValue(tables.n, segment?.[3], []), // JMNEDict entry IDs from table index
        s: segmentMetadataTableValue(tables.s, segment?.[4], null), // JMDict lookup string from table index
        ns: segmentMetadataTableValue(tables.ns, segment?.[5], null), // JMNEDict lookup string from table index
        p: segmentMetadataTableValue(tables.p, segment?.[6], null), // part-of-speech from table index
        l: segment?.[7], // JLPT level, 1..5
        x: segmentMetadataTableValue(tables.x, segment?.[8], null), // surface text from table index
        sentenceID, // sentence identifier from table index
        paragraphID, // paragraph identifier from table index
        pid: paragraphID,
        r: typeof segment?.[hasRubyIndex] === 'boolean' ? segment[hasRubyIndex] : null, // contains ruby
    };
};

const segmentMetadataFromLegacyEntry = (segment) => {
    const paragraphID = typeof segment?.paragraphID === 'string'
        ? segment.paragraphID
        : (typeof segment?.pid === 'string' ? segment.pid : null);
    return {
        i: typeof segment?.i === 'string' ? segment.i : null,
        h: typeof segment?.h === 'string' ? segment.h : null,
        sid: typeof segment?.sid === 'string' ? segment.sid : null,
        j: Array.isArray(segment?.j) ? segment.j : [],
        n: Array.isArray(segment?.n) ? segment.n : [],
        s: typeof segment?.s === 'string' ? segment.s : null,
        ns: typeof segment?.ns === 'string' ? segment.ns : null,
        p: typeof segment?.p === 'string' ? segment.p : null,
        l: Number.isInteger(segment?.l) ? segment.l : null,
        x: typeof segment?.x === 'string' ? segment.x : null,
        sentenceID: typeof segment?.sentenceID === 'string' ? segment.sentenceID : null,
        paragraphID,
        pid: paragraphID,
    };
};

const sentenceArchiveEntriesFromPayload = (payload) => (
    Array.isArray(payload?.e) ? payload.e
        : (Array.isArray(payload?.sentenceArchive) ? payload.sentenceArchive : [])
);

const expandSegmentMetadataPayload = (payload) => {
    const version = payload?.v ?? payload?.version;
    const compactTables = payload?.t ?? payload?.tables;
    const compactSegments = Array.isArray(payload?.s) ? payload.s : payload?.segments;
    if (version >= 2 && version <= 6 && compactTables && Array.isArray(compactSegments)) {
        const tables = compactSegmentMetadataTables(compactTables);
        return compactSegments.map((segment) => segmentMetadataFromCompactTuple(segment, tables, version));
    }
    if (Array.isArray(payload)) {
        return payload.map(segmentMetadataFromLegacyEntry);
    }
    return [];
};

const segmentMetadataAliases = (metadata) => {
    const aliases = [];
    const add = (identifier) => {
        if (typeof identifier !== 'string' || identifier.length === 0) return;
        if (!aliases.includes(identifier)) aliases.push(identifier);
    };
    add(metadata?.i);
    add(metadata?.sid);
    add(stableSegmentID(metadata?.sentenceID, metadata?.h));
    return aliases;
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
    const version = payload?.v ?? payload?.version;
    const compactTables = payload?.t ?? payload?.tables;
    const compactSegments = Array.isArray(payload?.s) ? payload.s : payload?.segments;
    if (version >= 2 && version <= 6 && compactTables && Array.isArray(compactSegments)) {
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
            let matched = false;
            for (const alias of segmentMetadataAliases(metadata)) {
                if (state?.byID && !state.byID.has(alias)) {
                    state.byID.set(alias, index);
                }
                if (alias === segmentID) {
                    matched = true;
                }
            }
            if (state) state.scannedThrough = index;
            if (!matched) continue;
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
            const metadata = segmentMetadataFromLegacyEntry(payload[index]);
            let matched = false;
            for (const alias of segmentMetadataAliases(metadata)) {
                if (state?.byID && !state.byID.has(alias)) {
                    state.byID.set(alias, index);
                }
                if (alias === segmentID) {
                    matched = true;
                }
            }
            if (state) state.scannedThrough = index;
            if (!matched) continue;
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
    const startedAt = performanceNowMs();
    if (!doc) {
        return emptySegmentMetadataBootstrap();
    }
    const snapshot = segmentMetadataSidecarSnapshot(doc);
    const sidecarsMatchCache = segmentMetadataSidecarsMatchCache(doc, snapshot);
    if (
        doc.manabiSegmentMetadataFullyBootstrapped === true
        && doc.manabiSegmentMetadataByID
        && doc.manabiSegmentMetadataSidecarSignature === snapshot.sidecarSignature
        && sidecarsMatchCache
    ) {
        manabiTimelineMeasure('segmentMetadata.bootstrap.cached', startedAt, {
            sidecarCount: snapshot.sidecars.length,
            segmentCount: doc.manabiSegmentMetadataSegments?.length ?? 0,
        }, 25);
        return {
            byID: doc.manabiSegmentMetadataByID,
            idsByEntryID: doc.manabiSegmentIDsByEntryID || new Map(),
            segments: doc.manabiSegmentMetadataSegments || [],
            aggregates: doc.manabiSegmentMetadataAggregates || null,
            sentenceArchive: doc.manabiSegmentMetadataSentenceArchive || new Map(),
        };
    }
    const readerBootstrap = doc.defaultView?.manabi_bootstrapSegmentMetadata;
    if (typeof readerBootstrap === 'function') {
        try {
            const bootstrap = readerBootstrap(doc);
            if (bootstrap?.byID instanceof Map) {
                doc.manabiSegmentMetadataByID = bootstrap.byID;
                doc.manabiSegmentIDsByEntryID = bootstrap.idsByEntryID instanceof Map ? bootstrap.idsByEntryID : new Map();
                doc.manabiSegmentMetadataSegments = Array.isArray(bootstrap.segments) ? bootstrap.segments : [];
                doc.manabiSegmentMetadataAggregates = bootstrap.aggregates || null;
                doc.manabiSegmentMetadataSentenceArchive = bootstrap.sentenceArchive instanceof Map ? bootstrap.sentenceArchive : new Map();
                doc.manabiSegmentMetadataFullyBootstrapped = true;
                cacheSegmentMetadataSidecarSnapshot(doc, snapshot);
                manabiTimelineMeasure('segmentMetadata.bootstrap.readerScript', startedAt, {
                    sidecarCount: snapshot.sidecars.length,
                    segmentCount: doc.manabiSegmentMetadataSegments.length,
                    entryIDKeyCount: doc.manabiSegmentIDsByEntryID.size,
                    sentenceArchiveCount: doc.manabiSegmentMetadataSentenceArchive.size,
                    reusedCachedSidecars: snapshot.reusedCachedSidecars === true,
                }, 25);
                return {
                    byID: doc.manabiSegmentMetadataByID,
                    idsByEntryID: doc.manabiSegmentIDsByEntryID,
                    segments: doc.manabiSegmentMetadataSegments,
                    aggregates: doc.manabiSegmentMetadataAggregates,
                    sentenceArchive: doc.manabiSegmentMetadataSentenceArchive,
                };
            }
        } catch (_error) {}
    }
    const byID = new Map();
    const idsByEntryID = new Map();
    const segments = [];
    const sentenceArchive = new Map();
    const aggregateParts = {
        hasExplicitAggregate: false,
        segmentCount: 0,
        expressions: new Set(),
        primaryEntryIDs: new Set(),
        jmnedictEntryIDs: new Set(),
        kanji: new Set(),
        sentenceIdentifiers: new Set(),
    };
    const indexEntryIDs = (segmentID, entryIDs) => {
        for (const entryID of entryIDs || []) {
            if (typeof entryID !== 'number' || !Number.isFinite(entryID)) continue;
            const key = String(entryID);
            if (!idsByEntryID.has(key)) idsByEntryID.set(key, new Set());
            idsByEntryID.get(key).add(segmentID);
        }
    };
    const isKanjiCodePoint = (codePoint) => (
        (codePoint >= 0x4E00 && codePoint <= 0x9FFF)
        || (codePoint >= 0x3400 && codePoint <= 0x4DBF)
        || (codePoint >= 0x20000 && codePoint <= 0x2A6DF)
        || (codePoint >= 0x2A700 && codePoint <= 0x2B73F)
        || (codePoint >= 0x2B740 && codePoint <= 0x2B81F)
        || (codePoint >= 0x2B820 && codePoint <= 0x2CEAF)
        || (codePoint >= 0xF900 && codePoint <= 0xFAFF)
        || (codePoint >= 0x2F800 && codePoint <= 0x2FA1F)
    );
    const addValues = (target, values) => {
        if (!Array.isArray(values)) return;
        for (const value of values) {
            if (typeof value === 'string' && value.length > 0) {
                target.add(value);
            } else if (typeof value === 'number' && Number.isFinite(value)) {
                target.add(value);
            }
        }
    };
    const addExplicitAggregate = (aggregate) => {
        if (!aggregate || typeof aggregate !== 'object') return;
        aggregateParts.hasExplicitAggregate = true;
        const segmentCount = aggregate.c ?? aggregate.segmentCount;
        if (Number.isFinite(segmentCount)) {
            aggregateParts.segmentCount += segmentCount;
        }
        addValues(aggregateParts.expressions, aggregate.e ?? aggregate.expressions);
        addValues(aggregateParts.primaryEntryIDs, aggregate.j ?? aggregate.primaryEntryIDs);
        addValues(aggregateParts.jmnedictEntryIDs, aggregate.n ?? aggregate.jmnedictEntryIDs);
        addValues(aggregateParts.kanji, aggregate.k ?? aggregate.kanji);
        addValues(aggregateParts.sentenceIdentifiers, aggregate.sid ?? aggregate.sentenceIdentifiers);
    };
    const deriveAggregatesFromSegments = () => {
        aggregateParts.segmentCount = segments.length;
        for (const segment of segments) {
            const expression = segment?.s || segment?.ns || null;
            if (expression) aggregateParts.expressions.add(expression);
            const primaryEntryID = Array.isArray(segment?.j) && segment.j.length > 0
                ? segment.j[0]
                : (Array.isArray(segment?.n) && segment.n.length > 0 ? segment.n[0] : null);
            if (Number.isFinite(primaryEntryID)) aggregateParts.primaryEntryIDs.add(primaryEntryID);
            addValues(aggregateParts.jmnedictEntryIDs, segment?.n);
            const kanjiSource = typeof segment?.x === 'string'
                ? segment.x
                : (typeof expression === 'string' ? expression : null);
            if (kanjiSource) {
                for (const char of kanjiSource) {
                    if (isKanjiCodePoint(char.codePointAt(0))) aggregateParts.kanji.add(char);
                }
            }
            if (typeof segment?.sentenceID === 'string' && segment.sentenceID.length > 0) {
                aggregateParts.sentenceIdentifiers.add(segment.sentenceID);
            }
        }
    };
    for (const payload of segmentMetadataPayloadsForSnapshot(doc, snapshot)) {
        for (const entry of sentenceArchiveEntriesFromPayload(payload)) {
            const sentenceID = typeof entry?.sid === 'string' ? entry.sid
                : (typeof entry?.sentenceIdentifier === 'string' ? entry.sentenceIdentifier : null);
            if (!sentenceID) continue;
            sentenceArchive.set(sentenceID, {
                sentenceHTML: typeof entry?.h === 'string' ? entry.h
                    : (typeof entry?.html === 'string' ? entry.html : null),
                sentenceJMDictIDs: Array.isArray(entry?.j) ? entry.j
                    : (Array.isArray(entry?.jmdictEntryIDs) ? entry.jmdictEntryIDs : null),
                segments: Array.isArray(entry?.s) ? entry.s
                    : (Array.isArray(entry?.segments) ? entry.segments : []),
            });
        }
        for (const segment of expandSegmentMetadataPayload(payload)) {
            if (!segment?.i) continue;
            for (const alias of segmentMetadataAliases(segment)) {
                byID.set(alias, segment);
            }
            segments.push(segment);
            for (const alias of segmentMetadataAliases(segment)) {
                indexEntryIDs(alias, segment.j);
                indexEntryIDs(alias, segment.n);
            }
        }
        addExplicitAggregate(payload?.a ?? payload?.aggregates);
    }
    if (!aggregateParts.hasExplicitAggregate) {
        deriveAggregatesFromSegments();
    }
    const aggregates = {
        segmentCount: aggregateParts.segmentCount,
        expressions: Array.from(aggregateParts.expressions),
        primaryEntryIDs: Array.from(aggregateParts.primaryEntryIDs),
        jmnedictEntryIDs: Array.from(aggregateParts.jmnedictEntryIDs),
        kanji: Array.from(aggregateParts.kanji),
        sentenceIdentifiers: Array.from(aggregateParts.sentenceIdentifiers),
    };
    doc.manabiSegmentMetadataByID = byID;
    doc.manabiSegmentIDsByEntryID = idsByEntryID;
    doc.manabiSegmentMetadataSegments = segments;
    doc.manabiSegmentMetadataAggregates = aggregates;
    doc.manabiSegmentMetadataSentenceArchive = sentenceArchive;
    doc.manabiSegmentMetadataFullyBootstrapped = true;
    cacheSegmentMetadataSidecarSnapshot(doc, snapshot);
    manabiTimelineMeasure('segmentMetadata.bootstrap.built', startedAt, {
        sidecarCount: snapshot.sidecars.length,
        segmentCount: segments.length,
        entryIDKeyCount: idsByEntryID.size,
        reusedCachedSidecars: snapshot.reusedCachedSidecars === true,
    }, 25);
    return { byID, idsByEntryID, segments, aggregates, sentenceArchive };
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
        for (const alias of segmentMetadataAliases(metadata)) {
            byID.set(alias, metadata);
        }
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
    const sentenceIdentifier = sentenceIdentifierForNode(segmentNode?.closest?.(manabiReaderSentenceSelector));
    if (sentenceIdentifier && typeof metadata?.h === 'string' && metadata.h.length > 0) {
        return `${sentenceIdentifier}-${metadata.h}`;
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
    const sentenceIdentifier = sentenceIdentifierForNode(segmentNode?.closest?.(manabiReaderSentenceSelector));
    if (sentenceIdentifier && typeof metadata?.h === 'string' && metadata.h.length > 0) {
        addAlias(`${sentenceIdentifier}-${metadata.h}`);
    }
    if (sentenceIdentifier && typeof metadata?.sid === 'string' && !metadata.sid.includes('-')) {
        addAlias(`${sentenceIdentifier}-${metadata.sid}`);
    }
    addAlias(metadata?.i);
    addAlias(segmentNode?.id);
    return aliases;
};

const buildExampleSentenceForSegment = (segmentNode) => {
    const doc = segmentNode?.ownerDocument || document;
    const metadata = segmentMetadataForNode(segmentNode);
    const sentenceID = metadata?.sentenceID || sentenceIdentifierForNode(segmentNode?.closest?.(manabiReaderSentenceSelector)) || null;
    const sidecarSentence = sentenceID
        ? segmentMetadataBootstrap(doc).sentenceArchive?.get?.(sentenceID)
        : null;
    if (sidecarSentence) {
        return {
            sentenceHTML: sidecarSentence.sentenceHTML ?? null,
            sentenceJMDictIDs: sidecarSentence.sentenceJMDictIDs ?? null,
        };
    }
    const sentenceNode = segmentNode?.closest?.(manabiReaderSentenceSelector);
    if (!(sentenceNode instanceof Element)) {
        return {
            sentenceHTML: null,
            sentenceJMDictIDs: null,
        };
    }
    const sentenceJMDictIDs = new Set();
    for (const nestedSegment of sentenceNode.querySelectorAll(manabiReaderSegmentSelector)) {
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

const visibleClientRectsForNode = (node, bounds, measuredBoundingRect = null) => {
    const boundingRect = measuredBoundingRect || positiveBoundingClientRectForNode(node);
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
    const nodes = Array.from(doc.querySelectorAll?.('m-m') ?? []);
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
    const directSegment = element?.closest?.(manabiReaderSegmentSelector);
    if (directSegment && orderedSegments.indexByNode.has(directSegment)) {
        return orderedSegments.indexByNode.get(directSegment);
    }
    const sentence = element?.closest?.(manabiReaderSentenceSelector);
    if (sentence?.nodeType === Node.ELEMENT_NODE) {
        const sentenceSegments = Array.from(sentence.querySelectorAll?.('m-m') ?? []);
        const segment = boundary === 'end'
            ? sentenceSegments[sentenceSegments.length - 1]
            : sentenceSegments[0];
        if (segment && orderedSegments.indexByNode.has(segment)) {
            return orderedSegments.indexByNode.get(segment);
        }
    }
    return null;
};

const collectSegmentNodesInVisibleRange = (visibleRange) => {
    const doc = visibleRange?.commonAncestorContainer?.ownerDocument
        || visibleRange?.startContainer?.ownerDocument
        || visibleRange?.endContainer?.ownerDocument
        || null;
    if (!doc || !visibleRange?.commonAncestorContainer) {
        return null;
    }
    const root = visibleRange.commonAncestorContainer?.nodeType === Node.ELEMENT_NODE
        ? visibleRange.commonAncestorContainer
        : visibleRange.commonAncestorContainer?.parentElement;
    if (!root) {
        return null;
    }
    const nodes = [];
    const appendSegment = (node) => {
        if (node?.nodeType !== Node.ELEMENT_NODE) return;
        if (node.matches?.(manabiReaderSegmentSelector)) {
            nodes.push(node);
        }
    };
    appendSegment(root);
    const walker = doc.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, {
        acceptNode(node) {
            if (node === root) return NodeFilter.FILTER_SKIP;
            try {
                return visibleRange.intersectsNode(node)
                    ? NodeFilter.FILTER_ACCEPT
                    : NodeFilter.FILTER_REJECT;
            } catch (_error) {
                return NodeFilter.FILTER_REJECT;
            }
        },
    });
    let current = walker.nextNode();
    while (current) {
        appendSegment(current);
        current = walker.nextNode();
    }
    return nodes.length > 0 ? nodes : null;
};

const isBroadEbookRangeRoot = (root, doc) => {
    if (!root || !isEbookContentDocument(doc)) {
        return false;
    }
    if (root === doc || root === doc.body || root === doc.documentElement) {
        return true;
    }
    const tagName = root?.tagName?.toLowerCase?.() ?? '';
    return tagName === 'body' || tagName === 'html';
};

let visibleSegmentCollectionNodeID = 1;
const visibleSegmentCollectionNodeIDs = new WeakMap();
const visibleSegmentCollectionNodeKey = (node) => {
    if (!node || (typeof node !== 'object' && typeof node !== 'function')) {
        return 'nil';
    }
    let key = visibleSegmentCollectionNodeIDs.get(node);
    if (!key) {
        key = visibleSegmentCollectionNodeID++;
        visibleSegmentCollectionNodeIDs.set(node, key);
    }
    return key;
};
const visibleRangeCollectionSignature = (visibleRange) => {
    if (!visibleRange || visibleRange.collapsed === true) {
        return visibleRange?.collapsed === true ? 'collapsed' : 'none';
    }
    return [
        visibleSegmentCollectionNodeKey(visibleRange.startContainer),
        visibleRange.startOffset ?? 0,
        visibleSegmentCollectionNodeKey(visibleRange.endContainer),
        visibleRange.endOffset ?? 0,
        visibleSegmentCollectionNodeKey(visibleRange.commonAncestorContainer),
    ].join(':');
};
const visibleBoundsCollectionSignature = (visibleBounds) => {
    if (!visibleBounds) return 'none';
    return [
        visibleBounds.left,
        visibleBounds.top,
        visibleBounds.right,
        visibleBounds.bottom,
        visibleBounds.width,
        visibleBounds.height,
    ].map((value) => Number.isFinite(value) ? Math.round(value) : 'nil').join(':');
};
const visibleSegmentCollectionCacheKey = (doc, visibleRange, visibleBounds, { includeClientRects = true } = {}) => {
    const view = doc?.defaultView ?? null;
    return [
        view?.__manabiVisibleSegmentCollectionGeneration ?? 0,
        view?.__manabiReaderRenderToken ?? '',
        includeClientRects ? 'rects' : 'bounds',
        visibleRangeCollectionSignature(visibleRange),
        visibleBoundsCollectionSignature(visibleBounds),
    ].join('|');
};
const shouldInvalidateVisibleSegmentGeometryForReason = (sourceReason = 'unspecified') => {
    const reason = String(sourceReason || 'unspecified');
    return reason === 'page-turn-start'
        || reason === 'lookup-navigation-page-turn-start'
        || reason === 'page-turn-swipe-intent'
        || reason === 'document-load'
        || reason === 'font-family-change'
        || reason === 'font-family-change-child'
        || reason === 'font-size-change'
        || reason === 'font-size-change-child'
        || reason === 'layout-change'
        || reason === 'writing-direction-change'
        || reason.includes('resize')
        || reason.includes('orientation')
        || reason.includes('renderer.goTo')
        || reason.includes('renderer.relocate')
        || reason.includes('navigation');
};
const cachedVisibleSegmentCollection = (doc, key) => {
    if (!key || !doc?.__manabiVisibleSegmentCollectionCache) return null;
    const cache = doc.__manabiVisibleSegmentCollectionCache;
    return cache.key === key ? cache.result : null;
};
const cacheVisibleSegmentCollection = (doc, key, result) => {
    if (!key || !isDocumentLike(doc)) return;
    doc.__manabiVisibleSegmentCollectionCache = { key, result };
};

const collectViewportSampleSegmentNodes = (doc, visibleBounds, {
    sampleDensity = 'normal',
} = {}) => {
    if (!isDocumentLike(doc) || !visibleBounds || typeof doc.elementsFromPoint !== 'function') {
        return null;
    }
    const startedAt = performanceNowMs();
    const isEbookDoc = isEbookContentDocument(doc);
    const useSparseSampling = sampleDensity === 'sparse';
    const xFractions = useSparseSampling
        ? [0.5]
        : (isEbookDoc ? [0.12, 0.25, 0.38, 0.5, 0.62, 0.75, 0.88] : [0.08, 0.18, 0.28, 0.38, 0.5, 0.62, 0.72, 0.82, 0.92]);
    const yFractions = useSparseSampling
        ? [0.2, 0.5, 0.8]
        : (isEbookDoc ? [0.12, 0.28, 0.44, 0.6, 0.76, 0.92] : [0.1, 0.22, 0.34, 0.46, 0.58, 0.7, 0.82, 0.94]);
    const candidateSegments = [];
    const candidateLimit = useSparseSampling ? 96 : (isEbookDoc ? 96 : 512);
    const seenSegments = new Set();
    const seenRoots = new Set();
    const left = Math.max(0, Math.floor(visibleBounds.left || 0));
    const top = Math.max(0, Math.floor(visibleBounds.top || 0));
    const right = Math.max(left, Math.ceil(visibleBounds.right || 0));
    const bottom = Math.max(top, Math.ceil(visibleBounds.bottom || 0));
    const width = right - left;
    const height = bottom - top;
    if (width <= 0 || height <= 0) {
        return null;
    }
    const appendSegment = (segment, { allowOverLimit = false } = {}) => {
        if (!allowOverLimit && candidateSegments.length >= candidateLimit) {
            return;
        }
        if (segment?.tagName?.toLowerCase?.() !== 'm-m' || seenSegments.has(segment)) {
            return;
        }
        seenSegments.add(segment);
        candidateSegments.push(segment);
    };
    const appendRootSegments = (root) => {
        if (!(root instanceof Element) || root === doc.body || root === doc.documentElement || seenRoots.has(root)) {
            return;
        }
        seenRoots.add(root);
        if (root.matches?.(manabiReaderSegmentSelector)) {
            appendSegment(root);
            return;
        }
        if (!root.matches?.('m-s, p, li, h1, h2, h3, h4, h5, h6, blockquote, figure')) {
            return;
        }
        for (const segment of root.querySelectorAll?.('m-m') ?? []) {
            appendSegment(segment);
            if (candidateSegments.length >= candidateLimit) {
                break;
            }
        }
    };
    const appendCaretSegment = (x, y) => {
        let node = null;
        try {
            node = doc.caretPositionFromPoint?.(x, y)?.offsetNode ?? null;
        } catch (_error) {}
        if (!node) {
            try {
                node = doc.caretRangeFromPoint?.(x, y)?.startContainer ?? null;
            } catch (_error) {}
        }
        const element = node?.nodeType === Node.ELEMENT_NODE
            ? node
            : node?.parentElement;
        appendSegment(element);
        appendSegment(element?.closest?.(manabiReaderSegmentSelector));
        appendRootSegments(element?.closest?.('m-s, p, li, h1, h2, h3, h4, h5, h6, blockquote, figure'));
    };
    let sampledPointCount = 0;
    let caretSampleCount = 0;
    for (const yFraction of yFractions) {
        const y = Math.min(bottom - 1, Math.max(top, Math.round(top + height * yFraction)));
        for (const xFraction of xFractions) {
            const x = Math.min(right - 1, Math.max(left, Math.round(left + width * xFraction)));
            sampledPointCount += 1;
            appendCaretSegment(x, y);
            caretSampleCount += 1;
            for (const element of doc.elementsFromPoint(x, y) || []) {
                appendSegment(element);
                appendSegment(element?.closest?.(manabiReaderSegmentSelector));
                appendRootSegments(element?.closest?.('m-s, p, li, h1, h2, h3, h4, h5, h6, blockquote, figure'));
                if (candidateSegments.length >= candidateLimit) {
                    break;
                }
            }
        }
    }
    if (isEbookDoc && candidateSegments.length > 0) {
        const allSegments = Array.from(doc.querySelectorAll?.(manabiReaderSegmentSelector) ?? []);
        const candidateExpansionLimit = candidateLimit + 48;
        const appendNearbySegment = (segment) => {
            if (candidateSegments.length >= candidateExpansionLimit) {
                return;
            }
            appendSegment(segment, { allowOverLimit: true });
        };
        for (const segment of [...candidateSegments]) {
            const index = allSegments.indexOf(segment);
            if (index < 0) {
                continue;
            }
            for (let offset = -2; offset <= 2; offset += 1) {
                if (offset === 0) {
                    continue;
                }
                appendNearbySegment(allSegments[index + offset] ?? null);
            }
        }
    }
    candidateSegments.sort((first, second) => {
        if (first === second) return 0;
        const position = first.compareDocumentPosition?.(second) ?? 0;
        if (position & Node.DOCUMENT_POSITION_PRECEDING) return 1;
        if (position & Node.DOCUMENT_POSITION_FOLLOWING) return -1;
        return 0;
    });
    manabiTimelineMeasure('visibleSegments.viewportSample', startedAt, {
        sampleDensity,
        sampledPointCount,
        caretSampleCount,
        rootCount: seenRoots.size,
        candidateCount: candidateSegments.length,
        nearbyExpansionEnabled: isEbookDoc,
    }, 20);
    return candidateSegments.length > 0 ? candidateSegments : null;
};

const measureVisibleSegmentsInWindow = (segmentNodes, visibleRange, visibleBounds, {
    assumeInVisibleRange = false,
    includeClientRects = true,
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
        const segmentIdentifier = segmentIdentifierForNode(segmentNode);
        if (!segmentIdentifier) {
            missingIdentifierCount += 1;
            continue;
        }
        const rectStartedAt = performance.now();
        const boundingRect = positiveBoundingClientRectForNode(segmentNode);
        const boundingIntersects = !!boundingRect && rectIntersectsBounds(boundingRect, visibleBounds);
        const rects = includeClientRects && boundingIntersects
            ? visibleClientRectsForNode(segmentNode, visibleBounds, boundingRect)
            : [];
        const rect = rects[0] ?? (boundingIntersects ? boundingRect : null);
        rectMeasureCount += 1;
        rectMeasureElapsedMs += performance.now() - rectStartedAt;
        let isInVisibleRange = true;
        if (!assumeInVisibleRange) {
            const rangeStartedAt = performance.now();
            isInVisibleRange = false;
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
        const sentenceNode = segmentNode.closest(manabiReaderSentenceSelector);
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

const mergeMeasuredVisibleSegments = (baseSegments, measuredSegments) => {
    const mergedSegments = Array.isArray(baseSegments) ? [...baseSegments] : [];
    const seenNodes = new Set(mergedSegments.map(item => item?.node).filter(Boolean));
    let mergedCount = 0;
    for (const item of measuredSegments ?? []) {
        if (!item?.node || seenNodes.has(item.node)) {
            continue;
        }
        seenNodes.add(item.node);
        mergedSegments.push(item);
        mergedCount += 1;
    }
    mergedSegments.sort((first, second) => {
        const firstNode = first?.node ?? null;
        const secondNode = second?.node ?? null;
        if (!firstNode || !secondNode || firstNode === secondNode) return 0;
        const position = firstNode.compareDocumentPosition?.(secondNode) ?? 0;
        if (position & Node.DOCUMENT_POSITION_PRECEDING) return 1;
        if (position & Node.DOCUMENT_POSITION_FOLLOWING) return -1;
        return 0;
    });
    return { visibleSegments: mergedSegments, mergedCount };
};

const collectExpandedRangeSegments = (doc, visibleRange, visibleBounds, {
    includeClientRects = true,
} = {}) => {
    if (!visibleRange || visibleRange.collapsed === true) {
        return null;
    }
    const isEbookDoc = isEbookContentDocument(doc);
    const rangeCommonAncestor = visibleRange.commonAncestorContainer?.nodeType === Node.ELEMENT_NODE
        ? visibleRange.commonAncestorContainer
        : visibleRange.commonAncestorContainer?.parentElement;
    const rangeSegmentNodes = isBroadEbookRangeRoot(rangeCommonAncestor, doc)
        ? null
        : collectSegmentNodesInVisibleRange(visibleRange);
    if (rangeSegmentNodes?.length > 0 && (!isEbookDoc || rangeSegmentNodes.length > 4)) {
        return {
            ...measureVisibleSegmentsInWindow(rangeSegmentNodes, visibleRange, visibleBounds, {
                assumeInVisibleRange: true,
                includeClientRects,
            }),
            segmentNodes: rangeSegmentNodes,
            segmentCandidateSource: 'sentinel-range',
            orderedSegmentCount: rangeSegmentNodes.length,
            boundedByWindow: true,
        };
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
    const expansionSeeds = isEbookDoc
        ? [64, 128, 256, 512, 1024, 2048, fullDocumentExpansion]
        : [32, 64, 128, 256, 512, fullDocumentExpansion];
    const expansionSizes = Array.from(new Set(expansionSeeds))
        .filter((value) => Number.isFinite(value) && value >= 0);
    let best = null;
    for (const expansionSize of expansionSizes) {
        const windowStart = Math.max(0, anchorStart - expansionSize);
        const windowEnd = Math.min(allSegmentNodes.length - 1, anchorEnd + expansionSize);
        const segmentNodes = allSegmentNodes.slice(windowStart, windowEnd + 1);
        const measured = measureVisibleSegmentsInWindow(segmentNodes, visibleRange, visibleBounds, {
            assumeInVisibleRange: isEbookDoc,
            includeClientRects,
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
        if (isEbookDoc && best.visibleSegments.length >= 48 && expansionSize >= 512) {
            return best;
        }
    }
    return best?.visibleSegments?.length > 0 ? best : null;
};

const collectVisibleSegmentNodesFromRange = (doc, visibleRange = null, {
    includeClientRects = true,
    reason = 'visible-segments',
} = {}) => {
    if (!isDocumentLike(doc)) {
        return {
            visibleSegments: [],
            viewportWidth: 0,
            viewportHeight: 0,
            viewportLeft: 0,
            viewportTop: 0,
            frameLeft: 0,
            frameTop: 0,
            containerLeft: null,
            containerTop: null,
            hasExpectedPaginatorContainer: false,
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
    const isEbookDoc = isEbookContentDocument(doc);
    const useVisibleRange = !!visibleRange && visibleRange.collapsed !== true;
    const useViewportFallback = !useVisibleRange;
    const rangeCommonAncestor = visibleRange?.commonAncestorContainer ?? null;
    const rangeCommonAncestorElement = rangeCommonAncestor?.nodeType === Node.ELEMENT_NODE
        ? rangeCommonAncestor
        : (rangeCommonAncestor?.parentElement || null);
    const isBroadEbookRangeAncestor = isEbookDoc && useVisibleRange && isBroadEbookRangeRoot(rangeCommonAncestorElement, doc);
    const collectionCacheKey = visibleSegmentCollectionCacheKey(doc, visibleRange, visibleBounds, { includeClientRects });
    const cachedCollection = cachedVisibleSegmentCollection(doc, collectionCacheKey);
    if (cachedCollection) {
        manabiTimelineMeasure('visibleSegments.collect.cache', startedAt, {
            source: cachedCollection?.segmentCandidateSource ?? null,
            reason,
            includeClientRects,
            visibleSegmentCount: cachedCollection?.visibleSegments?.length ?? 0,
        }, 50);
        return cachedCollection;
    }
    if (isEbookDoc && visibleBounds) {
        const allSegmentNodes = Array.from(doc.querySelectorAll?.('m-m') ?? []);
        const queryCompletedAt = performance.now();
        const measured = measureVisibleSegmentsInWindow(allSegmentNodes, null, visibleBounds, {
            assumeInVisibleRange: true,
            includeClientRects,
        });
        const completedAt = performance.now();
        manabiTimelineMeasure('visibleSegments.collect', startedAt, {
            source: 'ebook-viewport-rect-scan',
            reason,
            includeClientRects,
            useVisibleRange: false,
            totalSegmentCount: allSegmentNodes.length,
            visibleSegmentCount: measured.visibleSegments.length,
            viewportSampleCount: 0,
            viewportSampleMeasuredCount: 0,
            viewportSampleMergedCount: 0,
            rectMeasureCount: measured.rectMeasureCount,
            hiddenTooltipCount: measured.hiddenTooltipCount,
            missingIdentifierCount: measured.missingIdentifierCount,
            outOfViewportCount: measured.outOfViewportCount,
            queryElapsedMs: queryCompletedAt - startedAt,
            rectMeasureElapsedMs: measured.rectMeasureElapsedMs,
            rangeCheckElapsedMs: measured.rangeCheckElapsedMs,
            broadEbookRangeAncestor: isBroadEbookRangeAncestor,
            elapsedMs: completedAt - startedAt,
        }, 100);
        const result = {
            visibleSegments: measured.visibleSegments,
            viewportWidth,
            viewportHeight,
            viewportLeft,
            viewportTop,
            frameLeft: Number.isFinite(frameRect?.left) ? frameRect.left : 0,
            frameTop: Number.isFinite(frameRect?.top) ? frameRect.top : 0,
            frameWidth: Number.isFinite(frameRect?.width) ? frameRect.width : null,
            frameHeight: Number.isFinite(frameRect?.height) ? frameRect.height : null,
            containerLeft: Number.isFinite(containerRect?.left) ? containerRect.left : null,
            containerTop: Number.isFinite(containerRect?.top) ? containerRect.top : null,
            containerWidth: Number.isFinite(containerRect?.width) ? containerRect.width : null,
            containerHeight: Number.isFinite(containerRect?.height) ? containerRect.height : null,
            hasExpectedPaginatorContainer,
            totalSegmentCount: allSegmentNodes.length,
            segmentCandidateSource: 'ebook-viewport-rect-scan',
            viewportSampleCount: 0,
            viewportSampleMeasuredCount: 0,
            viewportSampleMergedCount: 0,
            hiddenTooltipCount: measured.hiddenTooltipCount,
            missingIdentifierCount: measured.missingIdentifierCount,
            outOfViewportCount: measured.outOfViewportCount,
            includeClientRects,
        };
        cacheVisibleSegmentCollection(doc, collectionCacheKey, result);
        return result;
    }
    const expandedRangeResult = useVisibleRange && !isEbookDoc
        ? collectExpandedRangeSegments(doc, visibleRange, visibleBounds, { includeClientRects })
        : null;
    let viewportSample = null;
    const shouldSampleEbookViewport =
        isEbookDoc
        && !!visibleBounds
        && (!expandedRangeResult || (expandedRangeResult.visibleSegments?.length ?? 0) < 8);
    const shouldSampleViewport = !!visibleBounds && (!useVisibleRange || shouldSampleEbookViewport);
    if (shouldSampleViewport) {
        const primarySampleDensity = shouldSampleEbookViewport ? 'normal' : 'sparse';
        const sparseNodes = collectViewportSampleSegmentNodes(doc, visibleBounds, { sampleDensity: primarySampleDensity });
        viewportSample = sparseNodes?.length > 0
            ? { nodes: sparseNodes, source: `viewport-sample-${primarySampleDensity}` }
            : null;
        if (!viewportSample && !isEbookDoc) {
            const expandedNodes = collectViewportSampleSegmentNodes(doc, visibleBounds, { sampleDensity: 'normal' });
            viewportSample = expandedNodes?.length > 0
                ? { nodes: expandedNodes, source: 'viewport-sample-expanded' }
                : null;
        }
    }
    const viewportSampleSegmentNodes = viewportSample?.nodes ?? null;
    const boundedSegmentNodes = expandedRangeResult?.segmentNodes ?? viewportSampleSegmentNodes ?? null;
    const shouldUseRangeAncestorFallback = !isEbookDoc
        && useVisibleRange
        && !expandedRangeResult
        && !viewportSampleSegmentNodes
        && rangeCommonAncestorElement?.querySelectorAll
        && !isBroadEbookRangeAncestor;
    const segmentSearchRoot = shouldUseRangeAncestorFallback
        ? rangeCommonAncestorElement
        : doc;
    const allSegmentNodes = boundedSegmentNodes || (isEbookDoc && segmentSearchRoot === doc ? [] : [
            ...(segmentSearchRoot.matches?.(manabiReaderSegmentSelector) ? [segmentSearchRoot] : []),
            ...Array.from(segmentSearchRoot.querySelectorAll?.('m-m') ?? []),
        ]);
    const shouldTrustEbookViewportSample = isEbookDoc && !!viewportSampleSegmentNodes && boundedSegmentNodes === viewportSampleSegmentNodes;
    const queryCompletedAt = performance.now();
    const ancestorSegmentCandidateCount = segmentSearchRoot === rangeCommonAncestorElement
        ? allSegmentNodes.length
        : null;
    const segmentCandidateSource = expandedRangeResult?.segmentCandidateSource
        || viewportSample?.source
        || (isBroadEbookRangeAncestor ? 'ebook-broad-range-empty' : null)
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
    let viewportSampleMeasuredCount = 0;
    let viewportSampleMergedCount = 0;
    if (expandedRangeResult && viewportSampleSegmentNodes?.length > 0) {
        const viewportMeasured = measureVisibleSegmentsInWindow(viewportSampleSegmentNodes, visibleRange, visibleBounds, {
            assumeInVisibleRange: true,
            includeClientRects,
        });
        viewportSampleMeasuredCount = viewportMeasured.visibleSegments.length;
        totalSegmentCount += viewportSampleSegmentNodes.length;
        hiddenTooltipCount += viewportMeasured.hiddenTooltipCount;
        missingIdentifierCount += viewportMeasured.missingIdentifierCount;
        outOfViewportCount += viewportMeasured.outOfViewportCount;
        visibleRangeCheckCount += viewportMeasured.visibleRangeCheckCount;
        visibleRangeErrorCount += viewportMeasured.visibleRangeErrorCount;
        rectMeasureCount += viewportMeasured.rectMeasureCount;
        rectMeasureElapsedMs += viewportMeasured.rectMeasureElapsedMs;
        rangeCheckElapsedMs += viewportMeasured.rangeCheckElapsedMs;
        const merged = mergeMeasuredVisibleSegments(visibleSegments, viewportMeasured.visibleSegments);
        visibleSegments.length = 0;
        visibleSegments.push(...merged.visibleSegments);
        viewportSampleMergedCount = merged.mergedCount;
    }
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
        const boundingRect = positiveBoundingClientRectForNode(segmentNode);
        const boundingIntersects = !!boundingRect && rectIntersectsBounds(boundingRect, visibleBounds);
        const rects = includeClientRects && boundingIntersects
            ? visibleClientRectsForNode(segmentNode, visibleBounds, boundingRect)
            : [];
        const rect = rects[0] ?? (boundingIntersects ? boundingRect : null);
        rectMeasureCount += 1;
        rectMeasureElapsedMs += performance.now() - rectStartedAt;
        const isInVisibleRange = shouldTrustEbookViewportSample
            ? !!rect
            : useVisibleRange
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
        const sentenceNode = segmentNode.closest(manabiReaderSentenceSelector);
        visibleSegments.push({
            node: segmentNode,
            rect,
            rects,
            segmentIdentifier,
            segmentIdentifierAliases: segmentIdentifierAliasesForNode(segmentNode),
            sentenceIdentifier: sentenceIdentifierForNode(sentenceNode),
        });
    }
    const completedAt = performance.now();
    manabiTimelineMeasure('visibleSegments.collect', startedAt, {
        source: segmentCandidateSource,
        reason,
        includeClientRects,
        useVisibleRange,
        totalSegmentCount,
        visibleSegmentCount: visibleSegments.length,
        viewportSampleCount: viewportSampleSegmentNodes?.length ?? 0,
        viewportSampleMeasuredCount,
        viewportSampleMergedCount,
        rectMeasureCount,
        hiddenTooltipCount,
        missingIdentifierCount,
        outOfViewportCount,
        queryElapsedMs: queryCompletedAt - startedAt,
        rectMeasureElapsedMs,
        rangeCheckElapsedMs,
        broadEbookRangeAncestor: isBroadEbookRangeAncestor,
    }, 100);
    const result = {
        visibleSegments,
        viewportWidth,
        viewportHeight,
        viewportLeft,
        viewportTop,
        frameLeft: Number.isFinite(frameRect?.left) ? frameRect.left : 0,
        frameTop: Number.isFinite(frameRect?.top) ? frameRect.top : 0,
        frameWidth: Number.isFinite(frameRect?.width) ? frameRect.width : null,
        frameHeight: Number.isFinite(frameRect?.height) ? frameRect.height : null,
        containerLeft: Number.isFinite(containerRect?.left) ? containerRect.left : null,
        containerTop: Number.isFinite(containerRect?.top) ? containerRect.top : null,
        containerWidth: Number.isFinite(containerRect?.width) ? containerRect.width : null,
        containerHeight: Number.isFinite(containerRect?.height) ? containerRect.height : null,
        hasExpectedPaginatorContainer,
        totalSegmentCount,
        segmentCandidateSource,
        viewportSampleCount: viewportSampleSegmentNodes?.length ?? 0,
        viewportSampleMeasuredCount,
        viewportSampleMergedCount,
        hiddenTooltipCount,
        missingIdentifierCount,
        outOfViewportCount,
        includeClientRects,
    };
    cacheVisibleSegmentCollection(doc, collectionCacheKey, result);
    return result;
};

const buildVisiblePageLookupIndex = (doc, visibleSegmentsResult, reason = 'unspecified') => {
    const startedAt = performanceNowMs();
    const byElementID = new Map();
    const bySegmentIdentifier = new Map();
    const idsByEntryID = new Map();
    const visibleElementIDs = [];
    const visibleSegments = Array.isArray(visibleSegmentsResult?.visibleSegments)
        ? visibleSegmentsResult.visibleSegments
        : [];
    const indexedNodes = new Set();
    const sentenceIdentifiers = new Set();
    let rubyPresenceMarkedCount = 0;
    const surfaceTextForLookupSegment = (node) => {
        const surfaceText = Array.from(node?.querySelectorAll?.(manabiReaderSurfaceSelector) ?? [])
            .map(surfaceElement => surfaceElement.textContent || '')
            .join('');
        return surfaceText || null;
    };
    const addMetadataAlias = (metadata, alias) => {
        if (typeof alias !== 'string' || alias.length === 0) return;
        bySegmentIdentifier.set(alias, metadata);
    };
    const addEntryIDs = (segmentID, entryIDs) => {
        if (typeof segmentID !== 'string' || segmentID.length === 0 || !Array.isArray(entryIDs)) return;
        for (const entryID of entryIDs) {
            if (!Number.isFinite(entryID)) continue;
            const key = String(entryID);
            if (!idsByEntryID.has(key)) idsByEntryID.set(key, new Set());
            idsByEntryID.get(key).add(segmentID);
        }
    };
    const indexSegmentNode = (node, item = null, source = 'visible') => {
        if (!node || indexedNodes.has(node)) return;
        indexedNodes.add(node);
        const elementID = node.id || node.getAttribute?.('id') || null;
        const sourceMetadata = segmentMetadataForNode(node) || {};
        if (sourceMetadata.r === true) {
            rubyPresenceMarkedCount += 1;
        }
        const sentenceNode = node.closest?.(manabiReaderSentenceSelector) || null;
        const sentenceIdentifier = item?.sentenceIdentifier
            || sentenceIdentifierForNode(sentenceNode)
            || sourceMetadata.sentenceID
            || null;
        if (typeof sentenceIdentifier === 'string' && sentenceIdentifier.length > 0) {
            sentenceIdentifiers.add(sentenceIdentifier);
        }
        const stableSegmentIdentifier = sourceMetadata.sid
            || item?.segmentIdentifier
            || stableSegmentID(sourceMetadata.sentenceID || sentenceIdentifier, sourceMetadata.h)
            || null;
        const segmentIdentifier = item?.segmentIdentifier
            || segmentIdentifierForNode(node)
            || sourceMetadata.i
            || elementID
            || null;
        const metadata = {
            ...sourceMetadata,
            i: sourceMetadata.i || elementID,
            h: sourceMetadata.h || null,
            sid: sourceMetadata.sid || stableSegmentIdentifier,
            sentenceID: sourceMetadata.sentenceID || sentenceIdentifier,
            sentenceIdentifier,
            segmentIdentifier,
            visibleIndexSource: source,
            x: sourceMetadata.x || surfaceTextForLookupSegment(node),
        };
        if (elementID) {
            byElementID.set(elementID, metadata);
        }
        addMetadataAlias(metadata, segmentIdentifier);
        addMetadataAlias(metadata, metadata.i);
        addMetadataAlias(metadata, metadata.sid);
        for (const alias of item?.segmentIdentifierAliases || []) {
            addMetadataAlias(metadata, alias);
        }
        const entryIndexID = metadata.i || elementID || segmentIdentifier;
        addEntryIDs(entryIndexID, metadata.j);
        addEntryIDs(entryIndexID, metadata.n);
        addEntryIDs(metadata.sid, metadata.j);
        addEntryIDs(metadata.sid, metadata.n);
    };
    for (const item of visibleSegments) {
        const node = item?.node ?? null;
        const elementID = node?.id || node?.getAttribute?.('id') || null;
        if (elementID) {
            visibleElementIDs.push(elementID);
        }
        indexSegmentNode(node, item, 'visible');
    }
    const index = {
        byElementID,
        bySegmentIdentifier,
        idsByEntryID,
        reason,
        visibleSegmentCount: visibleSegments.length,
        indexedSegmentCount: byElementID.size,
        sentenceIdentifierCount: sentenceIdentifiers.size,
        visibleElementIDs,
        builtAt: Date.now(),
    };
    if (doc) {
        doc.manabiVisiblePageLookupIndex = index;
        if (doc.defaultView) {
            doc.defaultView.__manabiVisiblePageLookupIndex = index;
            try {
                doc.defaultView.manabi_prepareVisiblePageLookupIndex?.(index);
            } catch (error) {
                ebookLoadLog('visibleLookup.index.prepare.error', {
                    reason,
                    error: error?.message || String(error),
                });
            }
        }
        requestNativeVisibleTrackedWordsPrime(doc, index, `visible-prime:${reason}`);
    }
    readerLoadLog('viewer.visibleLookup.index.finish', {
        reason,
        elapsedMs: safeRound(performanceNowMs() - startedAt, 1),
        visibleSegmentCount: visibleSegments.length,
        indexedSegmentCount: byElementID.size,
        sentenceIdentifierCount: sentenceIdentifiers.size,
        entryIDKeyCount: idsByEntryID.size,
        payloadPrepared: index.lookupPayloadPrepared === true,
        rubyPresenceMarkedCount,
        firstVisibleElementID: visibleElementIDs[0] ?? null,
    });
    manabiTimelineMeasure('visibleLookup.index.built', startedAt, {
        reason,
        visibleSegmentCount: visibleSegments.length,
        indexedSegmentCount: byElementID.size,
        sentenceIdentifierCount: sentenceIdentifiers.size,
        elementIDCount: byElementID.size,
        aliasCount: bySegmentIdentifier.size,
        entryIDKeyCount: idsByEntryID.size,
        rubyPresenceMarkedCount,
        firstVisibleElementID: visibleElementIDs[0] ?? null,
    }, 25);
    return index;
};

const nativeLookupSharedStylePayloadForDocument = (doc) => {
    const view = doc?.defaultView ?? null;
    const body = doc?.body ?? null;
    const root = doc?.documentElement ?? null;
    const target = body || root;
    if (!view || !target) {
        return null;
    }
    try {
        const signature = [
            body?.className ?? '',
            body?.dataset?.mnbFoliateWritingDirection ?? '',
            body?.dataset?.mnbFoliateWritingMode ?? '',
            root?.className ?? '',
            body?.getAttribute?.('style') ?? '',
            root?.getAttribute?.('style') ?? '',
        ].join('|');
        if (doc.__manabiNativeLookupSharedStylePayloadCache?.signature === signature) {
            return doc.__manabiNativeLookupSharedStylePayloadCache.payload;
        }
        const targetStyle = view.getComputedStyle?.(target);
        const bodyStyle = body ? view.getComputedStyle?.(body) : targetStyle;
        const rootStyle = root ? view.getComputedStyle?.(root) : targetStyle;
        const payload = {
            targetWritingMode: targetStyle?.writingMode ?? null,
            targetDirection: targetStyle?.direction ?? null,
            bodyWritingMode: bodyStyle?.writingMode ?? null,
            bodyDirection: bodyStyle?.direction ?? null,
            rootWritingMode: rootStyle?.writingMode ?? null,
            rootDirection: rootStyle?.direction ?? null,
            isVerticalWriting: (
                body?.classList?.contains?.('reader-vertical-writing') === true
                || body?.dataset?.mnbFoliateWritingDirection === 'vertical'
                || root?.classList?.contains?.('vrtl') === true
                || targetStyle?.writingMode?.startsWith?.('vertical') === true
                || bodyStyle?.writingMode?.startsWith?.('vertical') === true
            ),
        };
        doc.__manabiNativeLookupSharedStylePayloadCache = { signature, payload };
        return payload;
    } catch (_error) {
        return null;
    }
};

const postNativeLookupHitTargetsForVisibleSegments = (doc, visibleSegmentsResult, reason = 'unspecified') => {
    const startedAt = performanceNowMs();
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
    const shouldIncludeTargetDiagnostics = globalThis.manabiVerboseLookupPositionTargets === true;
    const cssInsets = shouldIncludeTargetDiagnostics ? (() => {
        try {
            return view?.manabiCSSInsetDiagnostics?.() ?? globalThis.manabiCSSInsetDiagnostics?.() ?? {};
        } catch (_error) {
            return {};
        }
    })() : {};
    const viewportPayload = {
        visualViewportWidth: viewportWidth,
        visualViewportHeight: viewportHeight,
        visualViewportOffsetLeft: 0,
        visualViewportOffsetTop: 0,
        scale: visualViewportScale,
        pageLeft: Number.isFinite(window.visualViewport?.pageLeft) ? window.visualViewport.pageLeft : null,
        pageTop: Number.isFinite(window.visualViewport?.pageTop) ? window.visualViewport.pageTop : null,
        viewportLeft,
        viewportTop,
        stylePayload: nativeLookupSharedStylePayloadForDocument(doc),
    };
    const messageHandlers = view?.webkit?.messageHandlers ?? window.webkit?.messageHandlers ?? null;
    if (typeof builder !== 'function') {
        if (globalThis.manabiVerboseLookupPositionTargets === true) {
            popoverDiagnosticLog('nativeLookup.targets.skipEmptyPost', {
                reason,
                nativeLookupFrameKey,
                builder: false,
                visibleSegmentCount: visibleSegmentsResult?.visibleSegments?.length ?? 0,
                visualViewportScale,
                viewportWidth,
                viewportHeight,
                viewportLeft,
                viewportTop,
            });
        }
        manabiTimelineMeasure('nativeLookup.targets.post', startedAt, {
            reason,
            builder: false,
            visibleSegmentCount: visibleSegmentsResult?.visibleSegments?.length ?? 0,
            targetCount: 0,
            segmentSource: visibleSegmentsResult?.segmentCandidateSource ?? null,
            frameLeft: visibleSegmentsResult?.frameLeft ?? null,
            frameTop: visibleSegmentsResult?.frameTop ?? null,
            viewportWidth,
            viewportHeight,
        }, 100);
        return;
    }
    const frameLeft = visibleSegmentsResult?.frameLeft ?? 0;
    const frameTop = visibleSegmentsResult?.frameTop ?? 0;
    const targets = [];
    const sampleTargets = [];
    let minTargetLeft = Infinity;
    let minTargetTop = Infinity;
    let maxTargetRight = -Infinity;
    let maxTargetBottom = -Infinity;
    view?.manabi_resetNativeLookupHitTargets?.();
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
            if (sampleTargets.length < 8) {
                const firstRect = target.rects?.[0] ?? null;
                sampleTargets.push({
                    elementId: target.elementId ?? null,
                    surface: item.node?.querySelector?.('m-t')?.textContent ?? item.node?.textContent ?? null,
                    rectCount: target.rects?.length ?? 0,
                    rectLeft: Number.isFinite(Number(firstRect?.left)) ? safeRound(Number(firstRect.left), 2) : null,
                    rectTop: Number.isFinite(Number(firstRect?.top)) ? safeRound(Number(firstRect.top), 2) : null,
                    rectWidth: Number.isFinite(Number(firstRect?.width)) ? safeRound(Number(firstRect.width), 2) : null,
                    rectHeight: Number.isFinite(Number(firstRect?.height)) ? safeRound(Number(firstRect.height), 2) : null,
                    sourceLeft: Number.isFinite(Number(rects[0]?.left)) ? safeRound(Number(rects[0].left), 2) : null,
                    sourceTop: Number.isFinite(Number(rects[0]?.top)) ? safeRound(Number(rects[0].top), 2) : null,
                });
            }
            for (const rect of target.rects ?? []) {
                const left = Number(rect?.left);
                const top = Number(rect?.top);
                const width = Number(rect?.width);
                const height = Number(rect?.height);
                if (!Number.isFinite(left) || !Number.isFinite(top) || !Number.isFinite(width) || !Number.isFinite(height)) {
                    continue;
                }
                minTargetLeft = Math.min(minTargetLeft, left);
                minTargetTop = Math.min(minTargetTop, top);
                maxTargetRight = Math.max(maxTargetRight, left + width);
                maxTargetBottom = Math.max(maxTargetBottom, top + height);
            }
        }
    }
    if (targets.length === 0) {
        popoverDiagnosticLog('nativeLookup.targets.skipEmptyPost', {
            reason,
            nativeLookupFrameKey,
            builder: true,
            visibleSegmentCount: visibleSegmentsResult?.visibleSegments?.length ?? 0,
            segmentSource: visibleSegmentsResult?.segmentCandidateSource ?? null,
            frameLeft,
            frameTop,
            viewportWidth,
            viewportHeight,
            viewportLeft,
            viewportTop,
            firstVisibleSegmentID: visibleSegmentsResult?.visibleSegments?.[0]?.node?.id ?? null,
            firstVisibleSurface: visibleSegmentsResult?.visibleSegments?.[0]?.node?.querySelector?.('m-t')?.textContent ?? null,
        });
        manabiTimelineMeasure('nativeLookup.targets.post', startedAt, {
            reason,
            builder: true,
            skippedEmptyPost: true,
            visibleSegmentCount: visibleSegmentsResult?.visibleSegments?.length ?? 0,
            targetCount: 0,
            frameLeft,
            frameTop,
            viewportWidth,
            viewportHeight,
        }, 100);
        return;
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
    popoverDiagnosticLog('nativeLookup.targets.posted', {
        reason,
        nativeLookupFrameKey,
        targetCount: targets.length,
        visibleSegmentCount: visibleSegmentsResult?.visibleSegments?.length ?? 0,
        segmentSource: visibleSegmentsResult?.segmentCandidateSource ?? null,
        viewportSampleCount: visibleSegmentsResult?.viewportSampleCount ?? null,
        viewportSampleMeasuredCount: visibleSegmentsResult?.viewportSampleMeasuredCount ?? null,
        viewportSampleMergedCount: visibleSegmentsResult?.viewportSampleMergedCount ?? null,
        frameLeft,
        frameTop,
        viewportWidth,
        viewportHeight,
        viewportLeft,
        viewportTop,
        visualViewportOffsetLeft: window.visualViewport?.offsetLeft ?? null,
        visualViewportOffsetTop: window.visualViewport?.offsetTop ?? null,
        visualViewportPageLeft: window.visualViewport?.pageLeft ?? null,
        visualViewportPageTop: window.visualViewport?.pageTop ?? null,
        innerWidth: window.innerWidth,
        innerHeight: window.innerHeight,
        rootClientWidth: document.documentElement?.clientWidth ?? null,
        rootClientHeight: document.documentElement?.clientHeight ?? null,
        ...cssInsets,
        minLeft: Number.isFinite(minTargetLeft) ? safeRound(minTargetLeft, 2) : null,
        minTop: Number.isFinite(minTargetTop) ? safeRound(minTargetTop, 2) : null,
        maxRight: Number.isFinite(maxTargetRight) ? safeRound(maxTargetRight, 2) : null,
        maxBottom: Number.isFinite(maxTargetBottom) ? safeRound(maxTargetBottom, 2) : null,
        sampleTargets: JSON.stringify(sampleTargets ?? []),
    });
    manabiTimelineMeasure('nativeLookup.targets.post', startedAt, {
        reason,
        builder: true,
        visibleSegmentCount: visibleSegmentsResult?.visibleSegments?.length ?? 0,
        targetCount: targets.length,
        frameLeft,
        frameTop,
        frameWidth: visibleSegmentsResult?.frameWidth ?? null,
        frameHeight: visibleSegmentsResult?.frameHeight ?? null,
        containerLeft: visibleSegmentsResult?.containerLeft ?? null,
        containerTop: visibleSegmentsResult?.containerTop ?? null,
        viewportWidth,
        viewportHeight,
        viewportLeft,
        viewportTop,
        segmentSource: visibleSegmentsResult?.segmentCandidateSource ?? null,
        hasExpectedPaginatorContainer: visibleSegmentsResult?.hasExpectedPaginatorContainer === true,
        firstVisibleSegmentID: visibleSegmentsResult?.visibleSegments?.[0]?.node?.id ?? null,
        firstTargetID: targets[0]?.elementId ?? null,
        firstRectLeft: targets[0]?.rects?.[0]?.left ?? null,
        firstRectTop: targets[0]?.rects?.[0]?.top ?? null,
    }, 100);
};

const visibleTrackingSignatureForResult = (doc, visibleSegmentsResult, extraParts = []) => {
    const visibleSegments = visibleSegmentsResult?.visibleSegments ?? [];
    const progress = doc?.manabi_articleReadingProgress || {};
    return [
        visibleSegments
            .map((item) => item?.node?.id || item?.segmentIdentifier || item?.node?.getAttribute?.('id') || '')
            .join(','),
        `trackedInit=${doc?.manabi_trackedWordsInitialized === true}`,
        `ebookTrackedInit=${isEbookContentDocument(doc) ? doc?.manabi_ebookTrackingInitialized === true : 'n/a'}`,
        `trackingEnabled=${doc?.body?.dataset?.mnbTrackingEnabled === 'true'}`,
        `tracking=${doc?.manabi_trackingModelVersion || 0}`,
        `readSeg=${Array.isArray(progress.readSegmentIdentifiers) ? progress.readSegmentIdentifiers.length : 0}`,
        `readSen=${Array.isArray(progress.sentenceIdentifiersRead) ? progress.sentenceIdentifiersRead.length : 0}`,
        `finished=${progress.articleMarkedAsFinished === true}`,
        ...extraParts,
    ].join('|');
};

const hydrationItemForSegmentNode = (segmentNode) => {
    if (segmentNode?.tagName?.toLowerCase?.() !== 'm-m' || segmentNode.closest?.('.tippy-box')) {
        return null;
    }
    const segmentIdentifier = segmentIdentifierForNode(segmentNode);
    if (!segmentIdentifier) {
        return null;
    }
    const sentenceNode = segmentNode.closest(manabiReaderSentenceSelector);
    return {
        node: segmentNode,
        rect: null,
        rects: [],
        segmentIdentifier,
        segmentIdentifierAliases: segmentIdentifierAliasesForNode(segmentNode),
        sentenceIdentifier: sentenceIdentifierForNode(sentenceNode),
    };
};

const expandedVisibleSegmentsResultForStatusHydration = (doc, visibleSegmentsResult, {
    adjacentSegmentCount = 96,
} = {}) => {
    const visibleSegments = visibleSegmentsResult?.visibleSegments ?? [];
    if (!isDocumentLike(doc) || visibleSegments.length === 0 || adjacentSegmentCount <= 0) {
        return visibleSegmentsResult;
    }
    const orderedSegments = orderedSegmentNodesForDocument(doc);
    const indexByNode = orderedSegments.indexByNode;
    const visibleIndexes = visibleSegments
        .map((item) => indexByNode.get(item?.node))
        .filter((index) => Number.isFinite(index));
    if (visibleIndexes.length === 0) {
        return visibleSegmentsResult;
    }
    const firstIndex = Math.min(...visibleIndexes);
    const lastIndex = Math.max(...visibleIndexes);
    const windowStart = Math.max(0, firstIndex - adjacentSegmentCount);
    const windowEnd = Math.min(orderedSegments.nodes.length - 1, lastIndex + adjacentSegmentCount);
    const seenNodes = new Set();
    const expandedSegments = [];
    for (const item of visibleSegments) {
        if (!item?.node || seenNodes.has(item.node)) {
            continue;
        }
        seenNodes.add(item.node);
        expandedSegments.push(item);
    }
    let addedCount = 0;
    for (let index = windowStart; index <= windowEnd; index += 1) {
        const node = orderedSegments.nodes[index];
        if (!node || seenNodes.has(node)) {
            continue;
        }
        const item = hydrationItemForSegmentNode(node);
        if (!item) {
            continue;
        }
        seenNodes.add(node);
        expandedSegments.push(item);
        addedCount += 1;
    }
    if (addedCount === 0) {
        return visibleSegmentsResult;
    }
    expandedSegments.sort((first, second) => {
        const firstIndexForNode = indexByNode.get(first?.node);
        const secondIndexForNode = indexByNode.get(second?.node);
        if (Number.isFinite(firstIndexForNode) && Number.isFinite(secondIndexForNode)) {
            return firstIndexForNode - secondIndexForNode;
        }
        return 0;
    });
    return {
        ...visibleSegmentsResult,
        visibleSegments: expandedSegments,
        hydrationStrictVisibleSegmentCount: visibleSegments.length,
        hydrationExpandedSegmentCount: expandedSegments.length,
        hydrationAdjacentAddedSegmentCount: addedCount,
        hydrationAdjacentSegmentCount: adjacentSegmentCount,
    };
};

const hydrateVisibleTrackingStatusesForVisibleSegments = (doc, visibleSegmentsResult, reason = 'unspecified') => {
    const startedAt = performanceNowMs();
    const view = doc?.defaultView ?? null;
    const hydrator = view?.manabi_hydrateVisibleTrackingStatuses ?? null;
    if (typeof hydrator !== 'function') {
        return null;
    }
    const hydrationResult = expandedVisibleSegmentsResultForStatusHydration(doc, visibleSegmentsResult);
    const visibleSegments = hydrationResult?.visibleSegments ?? [];
    const signature = visibleTrackingSignatureForResult(doc, hydrationResult);
    if (doc.__manabiLastVisibleStatusHydrationRequestSignature === signature) {
        const coverage = {
            visibleSegmentCount: visibleSegments.length,
            skipped: true,
            skippedByParent: true,
            signatureLength: signature.length,
            mutatedCount: 0,
            wouldMutateCount: 0,
        };
        manabiTimelineMeasure('visibleStatusHydration.call', startedAt, {
            reason,
            visibleSegmentCount: visibleSegments.length,
            skipped: true,
            skippedByParent: true,
            signatureLength: signature.length,
        }, 0);
        return coverage;
    }
    doc.__manabiLastVisibleStatusHydrationRequestSignature = signature;
    if (globalThis.__manabiTimelineTraceAll === true) {
        readerLoadLog('viewer.visibleStatusHydration.start', {
            reason,
            visibleSegmentCount: visibleSegments.length,
            strictVisibleSegmentCount: hydrationResult?.hydrationStrictVisibleSegmentCount ?? visibleSegmentsResult?.visibleSegments?.length ?? visibleSegments.length,
            adjacentAddedSegmentCount: hydrationResult?.hydrationAdjacentAddedSegmentCount ?? 0,
            signatureLength: signature.length,
        });
    }
    let coverage = null;
    try {
        coverage = hydrator(visibleSegments, reason) ?? null;
        const elapsedMs = performanceNowMs() - startedAt;
        if (globalThis.__manabiTimelineTraceAll === true || elapsedMs >= 50 || (coverage?.mutatedCount ?? 0) > 0) {
            readerLoadLog('viewer.visibleStatusHydration.finish', {
                reason,
                elapsedMs: safeRound(elapsedMs, 1),
                visibleSegmentCount: visibleSegments.length,
                strictVisibleSegmentCount: hydrationResult?.hydrationStrictVisibleSegmentCount ?? visibleSegmentsResult?.visibleSegments?.length ?? visibleSegments.length,
                adjacentAddedSegmentCount: hydrationResult?.hydrationAdjacentAddedSegmentCount ?? 0,
                skipped: coverage?.skipped ?? null,
                mutatedCount: coverage?.mutatedCount ?? null,
                wouldMutateCount: coverage?.wouldMutateCount ?? null,
            });
        }
        if (
            (coverage?.mutatedCount ?? 0) > 0
            || coverage?.didEnableTracking === true
            || globalThis.__manabiTimelineTraceAll === true
        ) {
            highlightStatusLog('visibleStatusHydration.finish', {
                reason,
                elapsedMs: safeRound(elapsedMs, 1),
                visibleSegmentCount: visibleSegments.length,
                skipped: coverage?.skipped ?? null,
                mutatedCount: coverage?.mutatedCount ?? null,
                wouldMutateCount: coverage?.wouldMutateCount ?? null,
                didEnableTracking: coverage?.didEnableTracking === true,
            });
        }
    } catch (error) {
        if (doc) {
            doc.__manabiLastVisibleStatusHydrationRequestSignature = null;
        }
        readerLoadLog('viewer.visibleStatusHydration.error', {
            reason,
            elapsedMs: safeRound(performanceNowMs() - startedAt, 1),
            error: error?.message || String(error),
        });
        ebookLoadLog('visibleStatusHydration.error', {
            reason,
            error: error?.message || String(error),
        });
        return null;
    } finally {
        manabiTimelineMeasure('visibleStatusHydration.call', startedAt, {
            reason,
            visibleSegmentCount: visibleSegments.length,
            skipped: coverage?.skipped ?? null,
            signatureLength: coverage?.signatureLength ?? null,
            mutatedCount: coverage?.mutatedCount ?? null,
            wouldMutateCount: coverage?.wouldMutateCount ?? null,
        }, coverage?.skipped ? 0 : 50);
    }
    return coverage;
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
            const sentenceNode = item.node.closest(manabiReaderSentenceSelector);
            const allSegmentIdentifierAliasSets = Array.from(sentenceNode?.querySelectorAll?.('m-m') || [])
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

const beginNativeForegroundResourceTrace = ({ kind, sourceURL, subpath = null, isCacheWarmer = false } = {}) => {
    if (isCacheWarmer) return null;
    const startedAt = performanceNowMs();
    const requestID = nextEbookLoadRequestID(kind || 'native-resource');
    globalThis.__manabiForegroundNativeResourcePendingCount =
        (globalThis.__manabiForegroundNativeResourcePendingCount ?? 0) + 1;
    manabiTimelineMark('nativeResource.foreground.start', {
        requestID,
        kind,
        subpath,
        pendingCount: globalThis.__manabiForegroundNativeResourcePendingCount,
    });
    return {
        requestID,
        kind,
        subpath,
        sourceURL,
        startedAt,
        finished: false,
    };
};

const finishNativeForegroundResourceTrace = (trace, stage = 'finish', extra = {}) => {
    if (!trace || trace.finished) return;
    trace.finished = true;
    globalThis.__manabiForegroundNativeResourcePendingCount = Math.max(
        0,
        (globalThis.__manabiForegroundNativeResourcePendingCount ?? 1) - 1
    );
    manabiTimelineMeasure('nativeResource.foreground', trace.startedAt, {
        requestID: trace.requestID,
        kind: trace.kind,
        subpath: trace.subpath,
        stage,
        pendingCount: globalThis.__manabiForegroundNativeResourcePendingCount,
        ...extra,
    }, 0);
    if (globalThis.__manabiCacheWarmerOpenRequested) {
        void maybeOpenDeferredCacheWarmer();
    }
};

const fetchNativeEntries = async (sourceURL, isCacheWarmer = false) => {
    const trace = beginNativeForegroundResourceTrace({
        kind: 'entries',
        sourceURL,
        isCacheWarmer,
    });
    try {
        const response = await fetch(`ebook://ebook/entries?${makeNativeSourceURLQuery(sourceURL)}`, {
            headers: {
                'X-Ebook-Source-URL': sourceURL,
            },
        })
        if (!response.ok) {
            throw new Error(`Failed to load native EPUB entries: ${response.status}`)
        }
        const json = await response.json()
        finishNativeForegroundResourceTrace(trace, 'body', {
            entryCount: Array.isArray(json?.entries) ? json.entries.length : null,
        });
        return json
    } catch (error) {
        finishNativeForegroundResourceTrace(trace, 'error', {
            error: error?.message || String(error),
        });
        throw error
    }
}

const fetchNativeEntryResponse = async (sourceURL, subpath, isCacheWarmer = false) => {
    const trace = beginNativeForegroundResourceTrace({
        kind: 'entry',
        sourceURL,
        subpath,
        isCacheWarmer,
    });
    const readerLoadTrace = !isCacheWarmer
        && String(globalThis.__manabiNavigationIntent?.source || '').startsWith('restore')
        && typeof globalThis.__manabiReaderLoadLog === 'function';
    const readerLoadStartedAt = performanceNowMs();
    if (readerLoadTrace) {
        globalThis.__manabiReaderLoadLog('nativeEntry.fetch.start', {
            subpath,
            pendingCount: globalThis.__manabiForegroundNativeResourcePendingCount ?? 0,
        });
    }
    try {
        const response = await fetch(`ebook://ebook/entry?subpath=${encodeURIComponent(subpath)}&${makeNativeSourceURLQuery(sourceURL)}`, {
            headers: {
                'X-Ebook-Source-URL': sourceURL,
            },
        })
        if (readerLoadTrace) {
            globalThis.__manabiReaderLoadLog('nativeEntry.fetch.response', {
                subpath,
                status: response.status,
                ok: response.ok,
                elapsedMs: Math.round(performanceNowMs() - readerLoadStartedAt),
                pendingCount: globalThis.__manabiForegroundNativeResourcePendingCount ?? 0,
            });
        }
        if (!response.ok) {
            finishNativeForegroundResourceTrace(trace, 'http-not-ok', {
                status: response.status,
            });
            return null
        }
        response.__manabiNativeForegroundResourceTrace = trace;
        return response
    } catch (error) {
        if (readerLoadTrace) {
            globalThis.__manabiReaderLoadLog('nativeEntry.fetch.error', {
                subpath,
                elapsedMs: Math.round(performanceNowMs() - readerLoadStartedAt),
                error: error?.message || String(error),
                pendingCount: globalThis.__manabiForegroundNativeResourcePendingCount ?? 0,
            });
        }
        finishNativeForegroundResourceTrace(trace, 'error', {
            error: error?.message || String(error),
        });
        throw error
    }
}

const readNativeEntryText = async (response) => {
    if (!response) return null
    const trace = response.__manabiNativeForegroundResourceTrace
    const readerLoadTrace = !!trace
        && typeof globalThis.__manabiReaderLoadLog === 'function'
        && String(globalThis.__manabiNavigationIntent?.source || '').startsWith('restore')
    const readerLoadStartedAt = performanceNowMs()
    try {
        const arrayBuffer = await response.arrayBuffer()
        const charset = response.headers?.get?.('content-type')?.match(/charset=([^;]+)/i)?.[1]?.trim() || 'utf-8'
        let decoder
        try {
            decoder = new TextDecoder(charset)
        } catch (_error) {
            decoder = new TextDecoder('utf-8')
        }
        const text = decoder.decode(arrayBuffer)
        if (readerLoadTrace) {
            globalThis.__manabiReaderLoadLog('nativeEntry.body.text', {
                subpath: trace.subpath,
                bytes: arrayBuffer.byteLength,
                chars: text.length,
                elapsedMs: Math.round(performanceNowMs() - readerLoadStartedAt),
                pendingCount: globalThis.__manabiForegroundNativeResourcePendingCount ?? 0,
            })
        }
        return text
    } finally {
        finishNativeForegroundResourceTrace(response.__manabiNativeForegroundResourceTrace, 'body-text')
    }
}

const readNativeEntryBlob = async (response) => {
    if (!response) return null
    try {
        const arrayBuffer = await response.arrayBuffer()
        const mimeType = response.headers?.get?.('content-type') || ''
        return new Blob([arrayBuffer], mimeType ? { type: mimeType } : undefined)
    } finally {
        finishNativeForegroundResourceTrace(response.__manabiNativeForegroundResourceTrace, 'body-blob')
    }
}

const makeNativeEpubLoader = async (url, isCacheWarmer) => {
    const loaderStartedAt = performanceNowMs();
    const { entries: rawEntries = [] } = await fetchNativeEntries(url, isCacheWarmer)
    const entries = rawEntries.map(function(entry) {
        return {
            filename: entry.path,
            uncompressedSize: entry.size ?? 0,
        };
    })
    const sizeMap = new Map(entries.map(function(entry) { return [entry.filename, entry.uncompressedSize]; }))
    const entryNames = new Set(entries.map(function(entry) { return entry.filename; }))
    const replaceText = makeReplaceText(isCacheWarmer, { allowForegroundHTML: false })
    const loadText = async (name) => {
        if (!entryNames.has(name)) {
            return null
        }
        const response = await fetchNativeEntryResponse(url, name, isCacheWarmer)
        return readNativeEntryText(response)
    }
    const replaceURL = makeReplaceURL(url, isCacheWarmer, loadText)
    return {
        entries,
        loadText,
        loadBlob: async (name) => {
            if (!entryNames.has(name)) {
                return null
            }
            const response = await fetchNativeEntryResponse(url, name, isCacheWarmer)
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
    body[data-mnb-has-sentences="true"] m-s,
    body[data-mnb-has-segments="true"] m-m {
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
    body[data-mnb-has-sentences="true"] m-s,
    body[data-mnb-has-segments="true"] m-m {
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

    m-c,
    m-s {
        display: contents !important;
    }

    m-t {
        contain: style paint !important;
    }

    m-m {
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
    body[data-mnb-foliate-writing-direction="vertical"],
    body.reader-vertical-writing {
        --mnb-highlight-gradient-direction: to right;
    }
    html.vrtl body [data-mnb-horizontal-writing-island="true"],
    html.vrtl body m-m[data-mnb-horizontal-writing-island="true"] > m-t,
    html.vrtl body m-t[data-mnb-horizontal-writing-island="true"],
    body[data-mnb-foliate-writing-direction="vertical"] [data-mnb-horizontal-writing-island="true"],
    body[data-mnb-foliate-writing-direction="vertical"] m-m[data-mnb-horizontal-writing-island="true"] > m-t,
    body[data-mnb-foliate-writing-direction="vertical"] m-t[data-mnb-horizontal-writing-island="true"],
    body.reader-vertical-writing [data-mnb-horizontal-writing-island="true"],
    body.reader-vertical-writing m-m[data-mnb-horizontal-writing-island="true"] > m-t,
    body.reader-vertical-writing m-t[data-mnb-horizontal-writing-island="true"] {
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
    body.reader-vertical-writing ruby > m-t {
        display: inline !important;
    }
    body.reader-vertical-writing m-t {
        /*
           Preserve the ruby-reserved vertical line grid. The app stylesheet
           normally tightens m-t to 1em for highlight bounds, but in vertical
           EPUB layout that can collapse adjacent line boxes after m-m is
           restored.
        */
        line-height: inherit !important;
    }
    body.reader-vertical-writing #reader-content .mnb-media-wrapper {
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
    body.reader-vertical-writing:not([data-is-ebook="true"]) m-m > m-t {
        /*
           In vertical WebKit layout, line-height fixes the paragraph grid, but
           an inline no-ruby segment's own rect still only covers the base glyph.
           Reserve the missing rt lane, but clip tracking backgrounds to the
           base glyph content so learning-status highlights do not fill it.
           Target only direct surface children; ruby base text uses ruby > m-t
           and already owns its annotation lane.
        */
        padding-right: ${rubyReservedSegmentPaddingEm}em !important;
        background-clip: content-box !important;
        box-decoration-break: clone;
        -webkit-box-decoration-break: clone;
    }
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"] m-m.mnb-unk,
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"] m-m.mnb-fam,
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"] m-m.mnb-learn,
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"] m-m.mnb-know {
        background: transparent !important;
    }
    body.reader-vertical-writing[data-mnb-tracking-status-applying="true"] m-m.mnb-unk > m-t,
    body.reader-vertical-writing[data-mnb-tracking-status-applying="true"] m-m.mnb-fam > m-t,
    body.reader-vertical-writing[data-mnb-tracking-status-applying="true"] m-m.mnb-learn > m-t,
    body.reader-vertical-writing[data-mnb-tracking-status-applying="true"] m-m.mnb-know > m-t {
        background: transparent !important;
        transition: none !important;
    }
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"] m-m.mnb-unk > m-t,
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"] m-m.mnb-fam > m-t,
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"] m-m.mnb-learn > m-t,
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"] m-m.mnb-know > m-t {
        border-radius: var(--segment-match-border-radius);
        box-decoration-break: clone;
        -webkit-box-decoration-break: clone;
        transition:
            --word-tracking-unknown-highlight-nav-conditional 350ms ease,
            --word-tracking-familiar-highlight-nav-conditional 350ms ease,
            --word-tracking-learning-highlight-nav-conditional 350ms ease,
            --word-tracking-known-highlight-nav-conditional 350ms ease;
    }
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"] m-m.mnb-unk > m-t {
        background: linear-gradient(var(--mnb-highlight-gradient-direction, to bottom), var(--word-tracking-unknown-highlight-nav-conditional) 0%, var(--word-tracking-unknown-highlight-nav-conditional) 50%, var(--word-tracking-unknown-highlight, transparent) 100%);
    }
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"]:is([data-mnb-status-filter="familiar"], [data-mnb-show-familiar="true"]) m-m.mnb-fam > m-t {
        background: linear-gradient(var(--mnb-highlight-gradient-direction, to bottom), var(--word-tracking-familiar-highlight-nav-conditional) 0%, var(--word-tracking-familiar-highlight-nav-conditional) 50%, var(--word-tracking-familiar-highlight, transparent) 100%);
    }
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"] m-m.mnb-learn > m-t {
        background: linear-gradient(var(--mnb-highlight-gradient-direction, to bottom), var(--word-tracking-learning-highlight-nav-conditional) 0%, var(--word-tracking-learning-highlight-nav-conditional) 50%, var(--word-tracking-learning-highlight, transparent) 100%);
    }
    body.reader-vertical-writing[data-mnb-tracking-enabled="true"][data-mnb-tracking-highlights-enabled="true"]:is([data-mnb-status-filter="known"], [data-mnb-show-known="true"]) m-m.mnb-know > m-t {
        background: linear-gradient(var(--mnb-highlight-gradient-direction, to bottom), var(--word-tracking-known-highlight-nav-conditional) 0%, var(--word-tracking-known-highlight-nav-conditional) 50%, var(--word-tracking-known-highlight, transparent) 100%);
    }
    body.reader-vertical-writing[data-mnb-lookup-highlight-mode="word"] m-m.mnb-selected {
        background: transparent !important;
        background-color: transparent !important;
        background-image: none !important;
    }
    body.reader-vertical-writing[data-mnb-lookup-highlight-mode="word"] m-m.mnb-selected > m-t {
        background: var(--theme-selection-color) !important;
        background-color: var(--theme-selection-color) !important;
        background-image: none !important;
        border-radius: var(--segment-match-border-radius);
        box-shadow: 0 0 0 2px var(--theme-selection-color);
        box-decoration-break: clone;
        -webkit-box-decoration-break: clone;
    }

    m-s ruby.mnb-gen > rt,
    m-s ruby.mnb-src > rt,
    m-s ruby.mnb-src-fwd > rt {
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
    body[data-mnb-romaji-mode-enabled="true"] rt .tt-outline-char::before {
        font-family: system-ui !important;
        font-weight: 400 !important;
        letter-spacing: normal !important;
        color: var(--theme-text-color) !important;
    }

    body.reader-is-single-media-element-without-text .mnb-media-wrapper,
    body.reader-is-single-media-element-without-text .mnb-media-wrapper > a,
    body.reader-is-single-media-element-without-text .mnb-media-wrapper :is(img, svg, image, picture, video, object) {
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
    body.reader-is-single-media-element-without-text .mnb-media-wrapper {
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
    setLoadingIndicator(visible, reason = 'unspecified') {
        const body = document.body;
        if (!body) return;
        const loadingIndicator = document.getElementById('loading-indicator');
        const previousVisible = body.classList.contains('loading');
        const nextVisible = !!visible;
        if (nextVisible) {
            loadingIndicator?.removeAttribute?.('hidden');
            clearTimeout(this.loadingVisualTimer);
            this.loadingVisualTimer = setTimeout(() => {
                if (document.body?.classList?.contains?.('loading')) {
                    document.body.classList.add('loading-visual');
                }
            }, loadingVisualDelayMs);
        }
        body.classList.toggle('loading', nextVisible);
        if (previousVisible && !nextVisible) {
            clearTimeout(this.loadingVisualTimer);
            this.loadingVisualTimer = null;
            body.classList.remove('loading-visual');
            loadingIndicator?.setAttribute?.('hidden', '');
        }
        if (!nextVisible) {
            this.#flushPendingNativeLookupHitTargetRefresh('loading-cleared');
            this.#flushPendingBookContentHideNavigationDueToScroll('loading-cleared');
        }
        if (previousVisible !== nextVisible) {
        }
    }
    #tocView
    #bookForSidebarCover = null
    #sidebarCoverLoadPromise = null
    #sidebarCoverObjectURL = null
    #chevronFadeTimers = {
        l: null,
        r: null
    }
    #mainDocumentSwipeState = null;
    initialDisplaySettled = false;
    initialDisplaySettledPromise = null;
    initialDisplaySettledResolve = null;
    displaySettledSequence = 0;
    displaySettledWaiters = [];
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
    lastPageTrackingStateSignature = null;
    lastPageTrackingStateSnapshot = null;
    lastRenderedPageTrackingSignature = null;
    pageTrackingStatesGeneration = -1;
    lastBookReadingProgressKey = null;
    pageTrackingRetryHandle = null;
    pageTrackingDeferredHandle = null;
    pageTrackingDeferredFrameHandle = null;
    pageTrackingDeferredRequest = null;
    nativeMarkReadStateRefreshHandle = null;
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
    nativeLookupHitTargetRefreshTimeout = null;
    nativeLookupHitTargetRefreshHandle = null;
    pendingNativeLookupHitTargetRefresh = null;
    appliedBookContentHideNavigationDueToScroll = null;
    pendingBookContentHideNavigationDueToScroll = null;
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
        void this.#ensureSidebarCoverLoaded()
        if (this.#tocView?.setCurrentHref && this.view?.renderer?.tocItem?.href) {
            this.#tocView.setCurrentHref(this.view.renderer.tocItem.href)
        }
    }
    #ensureSidebarCoverLoaded() {
        if (this.#sidebarCoverLoadPromise) return this.#sidebarCoverLoadPromise
        const coverElement = $('#side-bar-cover')
        if (!coverElement) return Promise.resolve()
        if (coverElement?.getAttribute?.('src')) return Promise.resolve()
        const book = this.#bookForSidebarCover
        if (typeof book?.getCover !== 'function') return Promise.resolve()
        this.#sidebarCoverLoadPromise = Promise.resolve(book.getCover())
            .then(blob => {
                if (!blob) return
                if (this.#sidebarCoverObjectURL) {
                    URL.revokeObjectURL(this.#sidebarCoverObjectURL)
                }
                this.#sidebarCoverObjectURL = URL.createObjectURL(blob)
                coverElement.src = this.#sidebarCoverObjectURL
            })
            .catch(error => {
                readerLoadLog('viewer.coverLoad.error', {
                    error: error?.message || String(error),
                })
            })
        return this.#sidebarCoverLoadPromise
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
                anchor: fractionInSection,
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
    #bookContentReadyForNavigationChrome() {
        return !document.body?.classList?.contains?.('loading')
            && document.documentElement?.dataset?.mnbReaderRenderReady === '1';
    }
    #flushPendingBookContentHideNavigationDueToScroll(reason = 'unspecified') {
        const pending = this.pendingBookContentHideNavigationDueToScroll;
        if (!pending || !this.#bookContentReadyForNavigationChrome()) {
            return;
        }
        this.pendingBookContentHideNavigationDueToScroll = null;
        this.#applyHideNavigationDueToScrollToBookContent(pending.hidden, `${pending.reason}.flush:${reason}`);
    }
    #applyHideNavigationDueToScrollToBookContent(shouldHide, reason = 'unspecified') {
        if (MANABI_DISABLE_NAV_HIDDEN_LAYOUT_CLASSES) {
            return;
        }
        const hidden = !!shouldHide;
        const startedAt = typeof performance !== 'undefined' && typeof performance.now === 'function' ? performance.now() : Date.now();
        const mainBody = document.body;
        if (mainBody?.classList?.contains?.('nav-hidden-due-to-scroll') !== hidden) {
            mainBody?.classList?.toggle?.('nav-hidden-due-to-scroll', hidden);
        }
        if (mainBody?.dataset) {
            mainBody.dataset.mnbHideNavigationDueToScroll = hidden ? 'true' : 'false';
        }
        if (!this.#bookContentReadyForNavigationChrome()) {
            this.pendingBookContentHideNavigationDueToScroll = { hidden, reason };
            return;
        }
        const contents = this.view?.renderer?.getContents?.() || [];
        let changedCount = 0;
        for (const content of contents) {
            const body = content?.doc?.body;
            if (!body) continue;
            if (applyNavigationHiddenVisualStateToEbookBody(body, hidden)) {
                changedCount += 1;
            }
        }
        this.appliedBookContentHideNavigationDueToScroll = hidden;
        const finishedAt = typeof performance !== 'undefined' && typeof performance.now === 'function' ? performance.now() : Date.now();
        readerLoadLog('hideNav.bookContent.apply', {
            hidden,
            reason,
            contents: contents.length,
            changedCount,
            mode: 'visual-vars',
            elapsedMs: Math.round(finishedAt - startedAt),
        });
    }
    constructor() {
        applyStoredChromeInsets('reader.constructor');
        this.navHUD = new NavigationHUD({
            formatPercent: value => percentFormat.format(value),
            getRenderer: () => this.view?.renderer,
            onJumpRequest: descriptor => this._goToDescriptor(descriptor),
            onHideNavigationDueToScrollChange: (hidden, details = {}) => {
                this.#applyHideNavigationDueToScrollToBookContent(hidden, details?.source || 'navHUD.visibilityChange');
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
        window.manabiRefreshVisibleTrackingStatuses = (reason = 'manual') => {
            const docs = this.#lookupContentWindows().map((view) => view.document).filter(isDocumentLike);
            for (const doc of docs) {
                const visibleRange = this.#visibleRangeForDocument(doc);
                this.#visiblePageSegmentResult(doc, visibleRange, `visible-status:${reason}`, {
                    postIfCached: false,
                    includeClientRects: false,
                    postLookupTargets: false,
                    prepareLookupIndex: false,
                    hydrateStatuses: true,
                    finishInitialCritical: false,
                });
            }
        };
        screen.orientation?.addEventListener?.('change', () => {
            this.#invalidateVisiblePageSegmentSnapshot();
        });
    }
    #invalidateVisiblePageSegmentSnapshot(sourceReason = 'unspecified') {
        const shouldResetVisibleGeometry = shouldInvalidateVisibleSegmentGeometryForReason(sourceReason);
        if (shouldResetVisibleGeometry) {
            this.visiblePageCollectionGeneration += 1;
            this.visiblePageSegmentSnapshot = null;
            this.lastPageTrackingStateSignature = null;
            this.lastPageTrackingStateSnapshot = null;
            this.pageTrackingStatesGeneration = -1;
            this.hasSettledInitialPaginatorLayout = false;
            if (this.initialPaginatorSettleHandle) {
                cancelAnimationFrame(this.initialPaginatorSettleHandle);
                this.initialPaginatorSettleHandle = null;
            }
        }
        const shouldResetNativeLookupTargets =
            sourceReason === 'page-turn-start'
            || sourceReason === 'lookup-navigation-page-turn-start'
            || sourceReason === 'page-turn-swipe-intent';
        const contents = this.view?.renderer?.getContents?.() || [];
        for (const content of contents) {
            const doc = content?.doc ?? content?.document ?? null;
            if (!isDocumentLike(doc)) { continue; }
            if (shouldResetVisibleGeometry) {
                doc.__manabiVisibleSegmentCollectionCache = null;
            }
            if (shouldResetNativeLookupTargets) {
                doc.__manabiLastVisibleStatusHydrationRequestSignature = null;
            }
            if (doc.defaultView) {
                doc.defaultView.__manabiVisibleSegmentCollectionGeneration = this.visiblePageCollectionGeneration;
            }
        }
        if (shouldResetNativeLookupTargets) {
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
        } else if (globalThis.manabiVerboseLookupPositionTargets === true) {
            popoverDiagnosticLog('native.targets.reset.skip', {
                sourceReason,
                reason: shouldResetVisibleGeometry ? 'geometry-invalidation' : 'same-document-invalidation',
                visiblePageCollectionGeneration: this.visiblePageCollectionGeneration,
            });
        }
        if (this.pageTrackingRetryHandle) {
            cancelAnimationFrame(this.pageTrackingRetryHandle);
            this.pageTrackingRetryHandle = null;
        }
        if (this.nativeLookupHitTargetRefreshHandle) {
            cancelAnimationFrame(this.nativeLookupHitTargetRefreshHandle);
            this.nativeLookupHitTargetRefreshHandle = null;
        }
        if (this.nativeLookupHitTargetRefreshTimeout) {
            clearTimeout(this.nativeLookupHitTargetRefreshTimeout);
            this.nativeLookupHitTargetRefreshTimeout = null;
        }
        if (this.hasLoadedLastPosition === true && !shouldResetNativeLookupTargets) {
            this.#scheduleNativeLookupHitTargetRefreshSettle(`invalidation:${sourceReason}`);
        } else if (shouldResetNativeLookupTargets && globalThis.__manabiTimelineTraceAll === true) {
            readerLoadLog('viewer.nativeLookup.invalidationRefresh.skip', {
                sourceReason,
                reason: 'transient-page-turn',
            });
        }
    }
    async #syncPageTrackingButtons(reason = 'unspecified', explicitDoc = null, retryCount = 0) {
        const syncStartedAt = performance.now();
        readerLoadLog('viewer.pageTracking.sync.start', {
            reason,
            retryCount,
        });
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
            this.pageTrackingStatesGeneration = -1;
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
        const visibleSegmentsResult = this.#visiblePageSegmentResult(doc, visibleRange, `page-tracking:${reason}`, {
            includeClientRects: false,
            postLookupTargets: false,
            prepareLookupIndex: false,
        });
        const visibleSegmentsElapsedMs = performanceNowMs() - visibleSegmentsStartedAt;
        if (syncGeneration !== this.visiblePageCollectionGeneration) {
            return;
        }
        const pageTrackingSignature = visibleTrackingSignatureForResult(doc, visibleSegmentsResult, [
            `optimisticSeg=${this.optimisticReadSegmentIdentifiers.size}`,
            `optimisticSen=${this.optimisticSentenceIdentifiersRead.size}`,
            `finished=${this.markedAsFinished === true}`,
            `completion=${this.completionAction?.type ?? 'none'}`,
        ]);
        let states = null;
        let diagnostics = null;
        let buildStatesElapsedMs = 0;
        const cachedStateSnapshot =
            this.lastPageTrackingStateSignature === pageTrackingSignature
            ? this.lastPageTrackingStateSnapshot
            : null;
        if (cachedStateSnapshot?.states && cachedStateSnapshot?.diagnostics) {
            states = cachedStateSnapshot.states;
            diagnostics = cachedStateSnapshot.diagnostics;
            manabiTimelineMeasure('pageTracking.buildStates.cache', performanceNowMs(), {
                reason,
                stateCount: states.length,
                signatureLength: pageTrackingSignature.length,
            }, 0);
        } else {
            const buildStatesStartedAt = performanceNowMs();
            const builtState = await buildVisiblePageTrackingStates(doc, this.articleReadingProgress, visibleRange, visibleSegmentsResult);
            states = builtState.states;
            diagnostics = builtState.diagnostics;
            buildStatesElapsedMs = performanceNowMs() - buildStatesStartedAt;
            this.lastPageTrackingStateSignature = pageTrackingSignature;
            this.lastPageTrackingStateSnapshot = { states, diagnostics };
        }
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
        this.pageTrackingStatesGeneration = syncGeneration;
        const renderStartedAt = performanceNowMs();
        this.#renderPageTrackingButtons(reason);
        const renderElapsedMs = performanceNowMs() - renderStartedAt;
        const syncElapsedMs = performanceNowMs() - syncStartedAt;
        readerLoadLog('viewer.pageTracking.sync.finish', {
            reason,
            retryCount,
            elapsedMs: safeRound(syncElapsedMs, 1),
            visibleSegmentsElapsedMs: safeRound(visibleSegmentsElapsedMs, 1),
            buildStatesElapsedMs: safeRound(buildStatesElapsedMs, 1),
            renderElapsedMs: safeRound(renderElapsedMs, 1),
            stateCount: diagnostics.stateCount,
            visibleSegmentCount: diagnostics.visibleSegmentCount,
            totalSegmentCount: diagnostics.totalSegmentCount,
            clusterCount: diagnostics.clusterCount,
        });
        logHighlightGradientDiagnostic(`page-tracking:${reason}`, doc);
        requestAnimationFrame(() => {
            logHighlightGradientDiagnostic(`page-tracking:${reason}:raf`, doc);
        });
        manabiTimelineMeasure('pageTracking.sync', syncStartedAt, {
            reason,
            retryCount,
            visibleRangeElapsedMs,
            visibleSegmentsElapsedMs,
            buildStatesElapsedMs,
            renderElapsedMs,
            stateCount: diagnostics.stateCount,
            visibleSegmentCount: diagnostics.visibleSegmentCount,
            totalSegmentCount: diagnostics.totalSegmentCount,
            clusterCount: diagnostics.clusterCount,
        }, 100);
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
        this.lastPageTrackingStateSignature = null;
        this.lastPageTrackingStateSnapshot = null;
        for (const content of this.view?.renderer?.getContents?.() || []) {
            const doc = content?.doc ?? content?.document ?? null;
            if (isDocumentLike(doc)) {
                doc.__manabiLastVisibleStatusHydrationRequestSignature = null;
            }
        }
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
        logHighlightGradientDiagnostic(`progress-applied:${reason}`);
        requestAnimationFrame(() => {
            logHighlightGradientDiagnostic(`progress-applied:${reason}:raf`);
        });
        if (MANABI_ENABLE_EBOOK_PAGE_TRACKING_BUTTONS) {
            this.#syncPageTrackingButtons('progress-applied', null, 2).catch((error) => console.error(error));
        } else {
            this.pageTrackingStates = [];
            this.#renderPageTrackingButtons('progress-applied.lazy');
            this.#scheduleNativeMarkReadStateRefresh('progress-applied');
        }
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
        const snapshotVisibleSegments = this.visiblePageSegmentSnapshot?.doc === doc
            ? (this.visiblePageSegmentSnapshot?.result?.visibleSegments ?? [])
            : [];
        const segmentNodes = snapshotVisibleSegments.length > 0
            ? snapshotVisibleSegments
                .map((item) => item?.node ?? null)
                .filter((segmentNode) => segmentNode?.tagName?.toLowerCase?.() === 'm-m')
            : Array.from(doc.querySelectorAll(manabiReaderSegmentSelector));
        const segmentIdentifiers = segmentNodes
            .map((segmentNode) => segmentIdentifierForNode(segmentNode))
            .filter((identifier) => typeof identifier === 'string' && identifier.length > 0);
        const segmentIdentifierAliasSets = segmentNodes
            .map((segmentNode) => ({
                aliases: segmentIdentifierAliasesForNode(segmentNode),
                sentenceIdentifier: sentenceIdentifierForNode(segmentNode.closest?.(manabiReaderSentenceSelector)),
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
            segmentSource: snapshotVisibleSegments.length > 0 ? 'visible-snapshot' : 'document-scan',
        };
    }
    buildMarkAllSectionsAsReadPayload() {
        const contents = this.view?.renderer?.getContents?.() || [];
        const doc = contents[0]?.doc;
        if (!isDocumentLike(doc)) {
            return null;
        }
        const segmentNodes = Array.from(doc.querySelectorAll(manabiReaderSegmentSelector))
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
            const sentenceNode = segmentNode.closest(manabiReaderSentenceSelector);
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
        const pageTrackingState = this.pageTrackingStates.find((state) => state.id === stateID)
            ?? await this.#ensureVisiblePageTrackingState(`native-demand:${source}`);
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
    async #ensureVisiblePageTrackingState(reason = 'native-demand', explicitDoc = null) {
        const contents = this.view?.renderer?.getContents?.() || [];
        const doc = isDocumentLike(explicitDoc) ? explicitDoc : contents[0]?.doc;
        if (!isDocumentLike(doc)) {
            this.pageTrackingStates = [];
            this.pageTrackingStatesGeneration = -1;
            this.#renderPageTrackingButtons(`${reason}:no-doc`);
            return null;
        }
        const currentVisibleState = this.pageTrackingStates.find((state) => state.id === 'visible-screen') ?? null;
        if (currentVisibleState && this.pageTrackingStatesGeneration === this.visiblePageCollectionGeneration) {
            return currentVisibleState;
        }
        const syncGeneration = this.visiblePageCollectionGeneration;
        const visibleRange = this.#visibleRangeForDocument(doc);
        if (visibleRange?.collapsed === true) {
            return null;
        }
        const visibleSegmentsResult = this.#visiblePageSegmentResult(
            doc,
            visibleRange,
            `mark-read-state:${reason}`,
            {
                includeClientRects: false,
                postLookupTargets: false,
                prepareLookupIndex: false,
                hydrateStatuses: false,
                finishInitialCritical: false,
            }
        );
        if (syncGeneration !== this.visiblePageCollectionGeneration) {
            return null;
        }
        const pageTrackingSignature = visibleTrackingSignatureForResult(doc, visibleSegmentsResult, [
            `optimisticSeg=${this.optimisticReadSegmentIdentifiers.size}`,
            `optimisticSen=${this.optimisticSentenceIdentifiersRead.size}`,
            `finished=${this.markedAsFinished === true}`,
            `completion=${this.completionAction?.type ?? 'none'}`,
        ]);
        let states = null;
        const cachedStateSnapshot =
            this.lastPageTrackingStateSignature === pageTrackingSignature
            ? this.lastPageTrackingStateSnapshot
            : null;
        if (cachedStateSnapshot?.states) {
            states = cachedStateSnapshot.states;
            manabiTimelineMeasure('pageTracking.ensureState.cache', performanceNowMs(), {
                reason,
                stateCount: states.length,
                signatureLength: pageTrackingSignature.length,
            }, 0);
        } else {
            const builtState = await buildVisiblePageTrackingStates(
                doc,
                this.articleReadingProgress,
                visibleRange,
                visibleSegmentsResult
            );
            states = builtState.states;
            this.lastPageTrackingStateSignature = pageTrackingSignature;
            this.lastPageTrackingStateSnapshot = {
                states,
                diagnostics: builtState.diagnostics,
            };
        }
        if (syncGeneration !== this.visiblePageCollectionGeneration) {
            return null;
        }
        this.pageTrackingStates = states;
        this.pageTrackingStatesGeneration = syncGeneration;
        this.#renderPageTrackingButtons(reason);
        return states.find((state) => state.id === 'visible-screen') ?? null;
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
        const renderSignature = JSON.stringify({
            hasContainer: container instanceof HTMLElement,
            hasButtonHost: buttonHost instanceof HTMLElement,
            visible: markReadButtonsVisible,
            completion: completionAction ? {
                type: completionAction.type ?? null,
                tone: completionAction.tone ?? null,
                label: completionAction.label ?? null,
                busy: !!this.completionActionBusy,
            } : null,
            states: pageTrackingStates.map((state) => ({
                id: state.id,
                isRead: !!state.isRead,
                hasAnyMarkedReadContent: !!state.hasAnyMarkedReadContent,
                shortLabel: state.shortLabel,
                fullLabel: state.fullLabel,
                busy: this.pageTrackingBusyStateIDs.has(state.id),
                animate: this.pageTrackingAnimateReadStateIDs.has(state.id),
            })),
            native: {
                available: !!nativeMarkReadAvailable,
                stateID: nativeMarkReadState?.id ?? null,
                isRead: !!nativeMarkReadState?.isRead,
                isBusy: !!nativeMarkReadBusy,
                hasAnyMarkedReadContent: !!nativeMarkReadState?.hasAnyMarkedReadContent,
            },
        });
        if (this.lastRenderedPageTrackingSignature === renderSignature) {
            return;
        }
        this.lastRenderedPageTrackingSignature = renderSignature;
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
        if (!MANABI_ENABLE_EBOOK_PAGE_TRACKING_BUTTONS) {
            this.#scheduleNativeMarkReadStateRefresh(reason, explicitDoc);
            return;
        }
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
    #scheduleNativeMarkReadStateRefresh(reason = 'unspecified', explicitDoc = null) {
        if (this.nativeMarkReadStateRefreshHandle) {
            cancelAnimationFrame(this.nativeMarkReadStateRefreshHandle);
            this.nativeMarkReadStateRefreshHandle = null;
        }
        this.nativeMarkReadStateRefreshHandle = requestAnimationFrame(() => {
            this.nativeMarkReadStateRefreshHandle = requestAnimationFrame(() => {
                this.nativeMarkReadStateRefreshHandle = null;
                if (globalThis.__manabiRestoreInProgress === true || document.body?.classList?.contains?.('loading') === true) {
                    return;
                }
                this.#ensureVisiblePageTrackingState(`lazy:${reason}`, explicitDoc).catch((error) => console.error(error));
            });
        });
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
        includeClientRects = true,
        postLookupTargets = true,
        prepareLookupIndex = true,
        hydrateStatuses = true,
        finishInitialCritical = true,
    } = {}) {
        const collectionStartedAt = performanceNowMs();
        const effectivePostLookupTargets = postLookupTargets;
        const effectiveIncludeClientRects = includeClientRects && effectivePostLookupTargets;
        const isEbookDoc = isEbookContentDocument(doc);
        const collectionVisibleRange = isEbookDoc ? null : visibleRange;
        if (doc?.defaultView) {
            doc.defaultView.__manabiVisibleSegmentCollectionGeneration = this.visiblePageCollectionGeneration;
        }
        const snapshot = this.visiblePageSegmentSnapshot;
        if (snapshot
            && snapshot.generation === this.visiblePageCollectionGeneration
            && snapshot.doc === doc
            && snapshot.visibleRange === collectionVisibleRange
            && (snapshot.includeClientRects === effectiveIncludeClientRects || (snapshot.includeClientRects === true && effectiveIncludeClientRects === false))) {
            manabiTimelineMeasure('visibleSegments.snapshot', collectionStartedAt, {
                reason,
                hit: true,
                includeClientRects: effectiveIncludeClientRects,
                requestedClientRects: includeClientRects,
                postLookupTargets: effectivePostLookupTargets,
                snapshotIncludesClientRects: snapshot.includeClientRects,
                visibleSegmentCount: snapshot.result?.visibleSegments?.length ?? 0,
                source: snapshot.result?.segmentCandidateSource ?? null,
                frameLeft: snapshot.result?.frameLeft ?? null,
                frameTop: snapshot.result?.frameTop ?? null,
                containerLeft: snapshot.result?.containerLeft ?? null,
                containerTop: snapshot.result?.containerTop ?? null,
                firstVisibleSegmentID: snapshot.result?.visibleSegments?.[0]?.node?.id ?? null,
            }, 50);
            if (effectivePostLookupTargets && postIfCached) {
                postNativeLookupHitTargetsForVisibleSegments(doc, snapshot.result, reason);
            }
            if (prepareLookupIndex && snapshot.lookupIndex) {
                doc.manabiVisiblePageLookupIndex = snapshot.lookupIndex;
                if (doc.defaultView) {
                    doc.defaultView.__manabiVisiblePageLookupIndex = snapshot.lookupIndex;
                }
            } else if (prepareLookupIndex) {
                snapshot.lookupIndex = buildVisiblePageLookupIndex(doc, snapshot.result, `${reason}:cached`);
            }
            if (hydrateStatuses && (snapshot.result?.visibleSegments?.length ?? 0) > 0) {
                hydrateVisibleTrackingStatusesForVisibleSegments(doc, snapshot.result, `${reason}:cached`);
            }
            if (finishInitialCritical && globalThis.__manabiInitialForegroundCriticalSectionToken) {
                if (isEbookContentDocument(doc)) {
                    markInitialVisibleWorkReady(`visible-segments-cached:${reason}`);
                }
                finishForegroundCriticalSection(
                    globalThis.__manabiInitialForegroundCriticalSectionToken,
                    `visible-segments-cached:${reason}`
                );
                globalThis.__manabiInitialForegroundCriticalSectionToken = null;
            }
            return snapshot.result;
        }
        const result = collectVisibleSegmentNodesFromRange(doc, collectionVisibleRange, {
            includeClientRects: effectiveIncludeClientRects,
            reason,
        });
        const isEmptyBroadEbookResult =
            isEbookContentDocument(doc)
            && (result?.visibleSegments?.length ?? 0) === 0
            && (
                result?.segmentCandidateSource === 'ebook-broad-range-empty'
                || result?.segmentCandidateSource === 'ebook-bounded-empty'
            );
        if (isEmptyBroadEbookResult
            && snapshot
            && snapshot.doc === doc
            && (snapshot.result?.visibleSegments?.length ?? 0) > 0) {
            readerLoadLog('viewer.visibleLookup.index.preserveNonEmptySnapshot', {
                reason,
                emptySource: result?.segmentCandidateSource ?? null,
                preservedVisibleSegmentCount: snapshot.result?.visibleSegments?.length ?? 0,
                preservedFirstVisibleElementID: snapshot.result?.visibleSegments?.[0]?.node?.id ?? null,
            });
            if (prepareLookupIndex && snapshot.lookupIndex) {
                doc.manabiVisiblePageLookupIndex = snapshot.lookupIndex;
                if (doc.defaultView) {
                    doc.defaultView.__manabiVisiblePageLookupIndex = snapshot.lookupIndex;
                }
            } else if (prepareLookupIndex) {
                snapshot.lookupIndex = buildVisiblePageLookupIndex(doc, snapshot.result, `${reason}:preserved`);
            }
            if (hydrateStatuses && (snapshot.result?.visibleSegments?.length ?? 0) > 0) {
                hydrateVisibleTrackingStatusesForVisibleSegments(doc, snapshot.result, `${reason}:preserved`);
            }
            if (finishInitialCritical && globalThis.__manabiInitialForegroundCriticalSectionToken) {
                if (isEbookContentDocument(doc)) {
                    markInitialVisibleWorkReady(`visible-segments-preserved:${reason}`);
                }
                finishForegroundCriticalSection(
                    globalThis.__manabiInitialForegroundCriticalSectionToken,
                    `visible-segments-preserved:${reason}`
                );
                globalThis.__manabiInitialForegroundCriticalSectionToken = null;
            }
            return snapshot.result;
        }
        this.visiblePageSegmentSnapshot = {
            generation: this.visiblePageCollectionGeneration,
            doc,
            visibleRange: collectionVisibleRange,
            includeClientRects: effectiveIncludeClientRects,
            result,
            lookupIndex: prepareLookupIndex ? buildVisiblePageLookupIndex(doc, result, reason) : null,
        };
        manabiTimelineMeasure('visibleSegments.snapshot', collectionStartedAt, {
            reason,
            hit: false,
            includeClientRects: effectiveIncludeClientRects,
            requestedClientRects: includeClientRects,
            postLookupTargets: effectivePostLookupTargets,
            visibleSegmentCount: result?.visibleSegments?.length ?? 0,
            totalSegmentCount: result?.totalSegmentCount ?? 0,
            source: result?.segmentCandidateSource ?? null,
            frameLeft: result?.frameLeft ?? null,
            frameTop: result?.frameTop ?? null,
            frameWidth: result?.frameWidth ?? null,
            frameHeight: result?.frameHeight ?? null,
            containerLeft: result?.containerLeft ?? null,
            containerTop: result?.containerTop ?? null,
            containerWidth: result?.containerWidth ?? null,
            containerHeight: result?.containerHeight ?? null,
            hasExpectedPaginatorContainer: result?.hasExpectedPaginatorContainer === true,
            firstVisibleSegmentID: result?.visibleSegments?.[0]?.node?.id ?? null,
        }, 50);
        if (effectivePostLookupTargets) {
            postNativeLookupHitTargetsForVisibleSegments(doc, result, reason);
        }
        if (hydrateStatuses && (result?.visibleSegments?.length ?? 0) > 0) {
            hydrateVisibleTrackingStatusesForVisibleSegments(doc, result, reason);
        }
        if (finishInitialCritical && globalThis.__manabiInitialForegroundCriticalSectionToken) {
            if (isEbookContentDocument(doc)) {
                markInitialVisibleWorkReady(`visible-segments:${reason}`);
            }
            finishForegroundCriticalSection(
                globalThis.__manabiInitialForegroundCriticalSectionToken,
                `visible-segments:${reason}`
            );
            globalThis.__manabiInitialForegroundCriticalSectionToken = null;
        }
        return result;
    }
    #scheduleNativeLookupHitTargetRefreshSettle(reason = 'unspecified', explicitDoc = null) {
        if (this.#shouldDeferNativeLookupHitTargetRefresh(reason)) {
            this.#deferNativeLookupHitTargetRefresh(reason, explicitDoc);
            return;
        }
        if (this.nativeLookupHitTargetRefreshHandle) {
            cancelAnimationFrame(this.nativeLookupHitTargetRefreshHandle);
            this.nativeLookupHitTargetRefreshHandle = null;
        }
        if (this.nativeLookupHitTargetRefreshTimeout) {
            clearTimeout(this.nativeLookupHitTargetRefreshTimeout);
            this.nativeLookupHitTargetRefreshTimeout = null;
        }
        const scheduledAt = performanceNowMs();
        const settleDelayMs = reason === 'manual' ? 0 : 180;
        if (globalThis.__manabiTimelineTraceAll === true) {
            readerLoadLog('viewer.nativeLookup.settle.schedule', {
                reason,
                explicitDoc: isDocumentLike(explicitDoc),
                settleDelayMs,
            });
        }
        this.nativeLookupHitTargetRefreshTimeout = setTimeout(() => {
            this.nativeLookupHitTargetRefreshTimeout = null;
            this.nativeLookupHitTargetRefreshHandle = requestAnimationFrame(() => {
                this.nativeLookupHitTargetRefreshHandle = requestAnimationFrame(() => {
                    const startedAt = performanceNowMs();
                    this.nativeLookupHitTargetRefreshHandle = null;
                    if (this.#shouldDeferNativeLookupHitTargetRefresh(reason)) {
                        this.#deferNativeLookupHitTargetRefresh(reason, explicitDoc);
                        return;
                    }
                    const docs = isDocumentLike(explicitDoc)
                        ? [explicitDoc]
                        : this.#lookupContentWindows().map((view) => view.document).filter(isDocumentLike);
                    for (const doc of docs) {
                        const visibleRange = this.#visibleRangeForDocument(doc);
                        this.#visiblePageSegmentResult(doc, visibleRange, `scheduled:${reason}`, { postIfCached: true });
                    }
                    const elapsedMs = performanceNowMs() - startedAt;
                    if (globalThis.__manabiTimelineTraceAll === true || elapsedMs >= 50) {
                        readerLoadLog('viewer.nativeLookup.settle.finish', {
                            reason,
                            scheduledDelayMs: safeRound(startedAt - scheduledAt, 1),
                            elapsedMs: safeRound(elapsedMs, 1),
                            docCount: docs.length,
                        });
                    }
                });
            });
        }, settleDelayMs);
    }
    #shouldDeferNativeLookupHitTargetRefresh(reason = 'unspecified') {
        if (reason === 'manual') {
            return false;
        }
        return globalThis.__manabiRestoreInProgress === true
            || document.body?.classList?.contains?.('loading') === true
            || this.hasLoadedLastPosition !== true;
    }
    #deferNativeLookupHitTargetRefresh(reason = 'unspecified', explicitDoc = null) {
        this.pendingNativeLookupHitTargetRefresh = {
            reason,
            explicitDoc: isDocumentLike(explicitDoc) && this.hasLoadedLastPosition === true ? explicitDoc : null,
            deferredAtMs: performanceNowMs(),
        };
        readerLoadLog('viewer.nativeLookup.defer', {
            reason,
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
            restoreInProgress: globalThis.__manabiRestoreInProgress === true,
            hasLoadedLastPosition: this.hasLoadedLastPosition === true,
        });
    }
    #flushPendingNativeLookupHitTargetRefresh(reason = 'unspecified') {
        const pending = this.pendingNativeLookupHitTargetRefresh;
        if (!pending || this.#shouldDeferNativeLookupHitTargetRefresh(`${pending.reason}.flush`)) {
            return;
        }
        this.pendingNativeLookupHitTargetRefresh = null;
        this.visiblePageSegmentSnapshot = null;
        readerLoadLog('viewer.nativeLookup.flush', {
            reason,
            pendingReason: pending.reason,
            deferredElapsedMs: safeRound(performanceNowMs() - pending.deferredAtMs, 1),
        });
        this.#scheduleNativeLookupHitTargetRefreshSettle(`${pending.reason}.flush:${reason}`, pending.explicitDoc);
    }
    refreshNativeLookupHitTargets(reason = 'manual') {
        if (this.#shouldDeferNativeLookupHitTargetRefresh(reason)) {
            this.#deferNativeLookupHitTargetRefresh(reason);
            return;
        }
        this.visiblePageSegmentSnapshot = null;
        this.#scheduleNativeLookupHitTargetRefreshSettle(reason);
    }
    refreshNativeMarkReadState(reason = 'manual') {
        this.#scheduleNativeMarkReadStateRefresh(reason);
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
    #mainDocumentTouchPointPayload(touch) {
        if (!touch) {
            return {};
        }
        return {
            clientX: touch.clientX ?? null,
            clientY: touch.clientY ?? null,
            screenX: touch.screenX ?? null,
            screenY: touch.screenY ?? null,
            pageX: touch.pageX ?? null,
            pageY: touch.pageY ?? null,
        };
    }
    #mainDocumentTouchTargetPayload(target) {
        const element = target?.nodeType === Node.ELEMENT_NODE
            ? target
            : target?.parentElement;
        const segment = element?.closest?.(manabiReaderSegmentSelector) ?? null;
        const sentence = element?.closest?.(manabiReaderSentenceSelector) ?? null;
        return {
            targetTagName: element?.tagName?.toLowerCase?.() ?? null,
            targetId: element?.getAttribute?.('id') ?? null,
            targetClass: String(element?.getAttribute?.('class') ?? '').slice(0, 80),
            targetSegmentId: segment?.getAttribute?.('id') ?? null,
            targetSentenceId: sentence?.getAttribute?.('id') ?? null,
            targetClosestRT: element?.closest?.('rt') != null,
            targetOwnerIsMainDocument: target?.ownerDocument === document,
        };
    }
    #onMainDocumentTouchStart(event) {
        if (window.manabiNativePageTurnOwnsDrag === true) {
            this.#mainDocumentSwipeState = null;
            popoverDiagnosticLog('gesture.swipe.skip', {
                reason: 'nativePageTurnOwnsDrag',
                eventType: event.type,
            });
            return;
        }
        if (event.touches?.length !== 1) {
            this.#mainDocumentSwipeState = null;
            popoverDiagnosticLog('gesture.swipe.skip', {
                reason: 'nonSingleTouch',
                eventType: event.type,
                touchCount: event.touches?.length ?? null,
                changedTouchCount: event.changedTouches?.length ?? null,
            });
            return;
        }
        const touch = event.changedTouches?.[0];
        const target = event.target;
        if (!touch || !target || target.ownerDocument !== document) {
            this.#mainDocumentSwipeState = null;
            popoverDiagnosticLog('gesture.swipe.skip', {
                reason: !touch ? 'missingTouch' : (!target ? 'missingTarget' : 'targetOutsideMainDocument'),
                eventType: event.type,
                ...this.#mainDocumentTouchPointPayload(touch),
                ...this.#mainDocumentTouchTargetPayload(target),
            });
            return;
        }
        const isExcludedTouchTarget = target.closest?.('#reader-stage, #side-bar, #page-tracking-container, #nav-hidden-overlay, .side-nav, input, textarea, select, button, a, [role="button"], [contenteditable="true"]');
        const isInteractiveNavTarget = target.closest?.('#progress-wrapper, #nav-section-progress-center, #nav-primary-text, #nav-hidden-primary-text, #nav-bottom-row input, #nav-bottom-row button, .nav-relocate-button');
        if (isExcludedTouchTarget || isInteractiveNavTarget) {
            this.#mainDocumentSwipeState = null;
            popoverDiagnosticLog('gesture.swipe.skip', {
                reason: isExcludedTouchTarget ? 'excludedTarget' : 'interactiveNavTarget',
                eventType: event.type,
                excludedTagName: isExcludedTouchTarget?.tagName?.toLowerCase?.() ?? null,
                excludedId: isExcludedTouchTarget?.getAttribute?.('id') ?? null,
                interactiveTagName: isInteractiveNavTarget?.tagName?.toLowerCase?.() ?? null,
                interactiveId: isInteractiveNavTarget?.getAttribute?.('id') ?? null,
                ...this.#mainDocumentTouchPointPayload(touch),
                ...this.#mainDocumentTouchTargetPayload(target),
            });
            return;
        }
        this.#mainDocumentSwipeState = {
            startX: touch.screenX,
            startY: touch.screenY,
            startClientX: touch.clientX,
            startClientY: touch.clientY,
            startAtMs: Date.now(),
            triggered: false,
            chevronActive: false,
            nativeLookupCancelled: false,
            loggedIntent: false,
            targetPayload: this.#mainDocumentTouchTargetPayload(target),
        };
        popoverDiagnosticLog('gesture.swipe.start', {
            eventType: event.type,
            isRTL: this.isRTL,
            ...this.#mainDocumentTouchPointPayload(touch),
            ...this.#mainDocumentSwipeState.targetPayload,
        });
    }
    async #onMainDocumentTouchMove(event) {
        if (window.manabiNativePageTurnOwnsDrag === true) {
            popoverDiagnosticLog('gesture.swipe.skip', {
                reason: 'nativePageTurnOwnsDrag.move',
                eventType: event.type,
            });
            return;
        }
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
        if (!state.loggedIntent) {
            state.loggedIntent = true;
            popoverDiagnosticLog('gesture.swipe.intent', {
                eventType: event.type,
                dx,
                dy,
                progress,
                minSwipe,
                elapsedMs: Date.now() - state.startAtMs,
                ...this.#mainDocumentTouchPointPayload(touch),
                ...state.targetPayload,
            });
        }
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
            popoverDiagnosticLog('gesture.swipe.lookupTargetsInvalidated', {
                reason: 'page-turn-swipe-intent',
                dx,
                dy,
                progress,
                logicalDirection,
                chevronSide,
                elapsedMs: Date.now() - state.startAtMs,
                ...state.targetPayload,
            });
            this.#invalidateVisiblePageSegmentSnapshot('page-turn-swipe-intent');
        }
        if (Math.abs(dx) <= minSwipe) return;
        state.triggered = true;
        popoverDiagnosticLog('gesture.swipe.pageTurn', {
            dx,
            dy,
            progress,
            logicalDirection,
            chevronSide,
            swipedLeft,
            isRTL: this.isRTL,
            elapsedMs: Date.now() - state.startAtMs,
            nativeLookupCancelled: state.nativeLookupCancelled,
            ...this.#mainDocumentTouchPointPayload(touch),
            ...state.targetPayload,
        });
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
    #onMainDocumentTouchEnd(event) {
        if (window.manabiNativePageTurnOwnsDrag === true) {
            popoverDiagnosticLog('gesture.swipe.end', {
                reason: 'nativePageTurnOwnsDrag',
                eventType: event?.type ?? null,
            });
            this.#mainDocumentSwipeState = null;
            return;
        }
        const state = this.#mainDocumentSwipeState;
        if (state?.chevronActive) {
            this.view?.dispatchEvent?.(new CustomEvent('sideNavChevronOpacity', {
                bubbles: true,
                composed: true,
                detail: { leftOpacity: '', rightOpacity: '', source: 'ebook-viewer', reason: 'mainDocumentSwipe.touchend' },
            }));
        }
        if (state) {
            const touch = event?.changedTouches?.[0] ?? null;
            const dx = touch ? touch.screenX - state.startX : null;
            const dy = touch ? touch.screenY - state.startY : null;
            popoverDiagnosticLog('gesture.swipe.end', {
                eventType: event?.type ?? null,
                triggered: state.triggered,
                nativeLookupCancelled: state.nativeLookupCancelled,
                chevronActive: state.chevronActive,
                loggedIntent: state.loggedIntent,
                dx,
                dy,
                elapsedMs: Date.now() - state.startAtMs,
                ...this.#mainDocumentTouchPointPayload(touch),
                ...state.targetPayload,
            });
        }
        this.#mainDocumentSwipeState = null;
    }
    async open(file, options = {}) {
        this.setLoadingIndicator(true, 'reader.open');
        installReaderPresentationState(options?.readerPresentationState ?? globalThis.__manabiReaderPresentationState, 'reader.open');

        this.hasLoadedLastPosition = false
        this.#resetInitialDisplaySettledPromise();
        this.lastCFIPersistenceObservation = null;
        this.unstableCFIs.clear();
        if (this.initialPaginatorSettleHandle) {
            cancelAnimationFrame(this.initialPaginatorSettleHandle);
            this.initialPaginatorSettleHandle = null;
        }
        this.hasSettledInitialPaginatorLayout = false;
        this.view = await getView(file, false)
        const initialRestore = options?.initialRestore ?? null;
        postReaderVisibilityProbe('reader.open:view-assigned', this.view, null);
        globalThis.__manabiPostReaderDocStateEvent?.('reader.open.viewAssigned');
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
        this.#applyHideNavigationDueToScrollToBookContent(this.navHUD?.hideNavigationDueToScroll === true, 'reader.open');
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
            const compactDisabled = isCompactNavigationSheetSidePaginationDisabled();
            if (button?.disabled || compactDisabled) {
                readerLoadLog('pageTurn.sideButton.skip', {
                    side,
                    method,
                    eventType,
                    buttonDisabled: !!button?.disabled,
                    compactDisabled,
                });
                return;
            }
            const viewSnapshot = () => {
                const renderer = this.view?.renderer ?? null;
                const location = this.view?.lastLocation ?? null;
                const contents = renderer?.getContents?.() ?? [];
                return {
                    hasView: !!this.view,
                    hasRenderer: !!renderer,
                    rendererName: renderer?.constructor?.name ?? null,
                    rendererTag: renderer?.localName ?? null,
                    locationIndex: location?.index ?? null,
                    locationReason: location?.reason ?? null,
                    contentIndex: contents[0]?.index ?? null,
                };
            };
            const startedAt = typeof performance !== 'undefined' && typeof performance.now === 'function' ? performance.now() : Date.now();
            markRestorePositionSavePageTurnInput(`pageTurn.sideButton.${eventType ?? 'unknown'}`);
            readerLoadLog('pageTurn.sideButton.start', {
                side,
                method,
                eventType,
                ...viewSnapshot(),
            });
            try {
                this.#clearVisiblePageReadChrome('page-turn-start');
                this.#applyPageTurnNavigationVisibility(method, 'page-turn.side-button');
                readerLoadLog('pageTurn.sideButton.beforeMove', {
                    side,
                    method,
                    eventType,
                    ...viewSnapshot(),
                });
                if (method === 'goLeft') {
                    await this.view.goLeft();
                } else {
                    await this.view.goRight();
                }
                const finishedAt = typeof performance !== 'undefined' && typeof performance.now === 'function' ? performance.now() : Date.now();
                readerLoadLog('pageTurn.sideButton.finish', {
                    side,
                    method,
                    eventType,
                    elapsedMs: Math.round(finishedAt - startedAt),
                    ...viewSnapshot(),
                });
            } catch (error) {
                readerLoadLog('pageTurn.sideButton.error', {
                    side,
                    method,
                    eventType,
                    name: error?.name ?? null,
                    message: error?.message ?? String(error),
                });
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
        this.#bookForSidebarCover = book
        this.#sidebarCoverLoadPromise = null
        if (this.#sidebarCoverObjectURL) {
            URL.revokeObjectURL(this.#sidebarCoverObjectURL)
            this.#sidebarCoverObjectURL = null
        }
        $('#side-bar-cover')?.removeAttribute?.('src')

        applyStoredChromeInsets('reader.open.beforeInitialDisplay');
        await this.#displayInitialSection('reader.open', initialRestore);
        this.#schedulePostInitialOpenWork(book);
    }

    #schedulePostInitialOpenWork(book) {
        setTimeout(() => {
            void this.#runPostInitialOpenWork(book).catch((error) => {
                readerLoadLog('viewer.postInitialOpenWork.error', {
                    error: error?.message || String(error),
                });
                console.error(error);
            });
        }, 0);
    }

    async #runPostInitialOpenWork(book) {
        const toc = book.toc
        if (toc && !this.#tocView) {
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

        // load and show highlights embedded in the file by Calibre
        let bookmarks;
        try {
            bookmarks = await book.getCalibreBookmarks?.()
        } catch (error) {
            readerLoadLog('viewer.calibreBookmarks.error', {
                error: error?.message || String(error),
            });
            return;
        }
        if (bookmarks) {
            const {
                fromCalibreHighlight
            } = await import('./epubcfi.js')
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
    }

    async #displayInitialSection(reason = 'reader.open', initialRestore = null) {
        const initialRestoreRequestID = typeof initialRestore?.requestID === 'string' && initialRestore.requestID.length > 0
            ? initialRestore.requestID
            : null;
        const requestedLocatorFromBridge = typeof initialRestore?.requestedLocator === 'string'
            ? initialRestore.requestedLocator
            : null;
        const syntheticInitialRestore = parseSyntheticRestoreLocator(initialRestore?.cfi);
        const spineOnlyInitialRestoreSectionIndex = !syntheticInitialRestore
            ? parseSpineOnlyEpubCFI(initialRestore?.cfi)
            : null;
        const hasSpineOnlyInitialRestore = Number.isInteger(spineOnlyInitialRestoreSectionIndex);
        const initialRestoreCFI = !syntheticInitialRestore
            && !hasSpineOnlyInitialRestore
            && typeof initialRestore?.cfi === 'string'
            ? initialRestore.cfi
            : '';
        const hasInitialRestoreCFI = initialRestoreCFI.length > 0;
        const initialRestoreFraction = coerceRestoreFraction(initialRestore?.fractionalCompletion);
        const hasInitialRestoreFraction = initialRestoreFraction != null && initialRestoreFraction > 0;
        const restoreLocatorKind = syntheticInitialRestore
            ? 'synthetic'
            : (hasSpineOnlyInitialRestore ? 'spine-cfi' : (hasInitialRestoreCFI ? 'cfi' : (hasInitialRestoreFraction ? 'fraction' : 'none')));
        const publishInitialRestoreResult = (terminalState, details = {}) => {
            const location = details.location ?? this.view?.lastLocation ?? null;
            return manabiPublishInitialRestoreResult(manabiCreateInitialRestoreResult({
                requestID: initialRestoreRequestID,
                terminalState,
                requestedLocator: requestedLocatorFromBridge ?? restoreLocatorKind,
                resolvedLocator: restoreLocatorKind,
                requestedFraction: hasInitialRestoreFraction ? initialRestoreFraction : null,
                requestedCFI: initialRestore?.cfi,
                location,
                navigationOk: details.navigationOk ?? null,
                error: details.error ?? null,
                reason,
                startedAt: details.startedAt ?? null,
            }));
        };
        if (!this.view?.renderer || this.initialDisplaySettled) {
            globalThis.__manabiRestoreDebugLog?.('ebook.initialDisplay.return', {
                reason,
                path: !this.view?.renderer ? 'missing-renderer' : 'already-settled',
                hasRenderer: !!this.view?.renderer,
                initialDisplaySettled: this.initialDisplaySettled === true,
                hasInitialRestore: !!initialRestore,
            });
            if (initialRestore) {
                publishInitialRestoreResult(!this.view?.renderer ? 'failed' : 'skipped', {
                    error: !this.view?.renderer ? 'missing-renderer' : 'already-settled',
                    startedAt: performanceNowMs(),
                });
            }
            return true;
        }
        const startedAt = performanceNowMs();
        const hasInitialRestoreTarget = !!syntheticInitialRestore
            || hasSpineOnlyInitialRestore
            || hasInitialRestoreCFI
            || hasInitialRestoreFraction;
        const initialNavigationTimeoutMs = hasInitialRestoreTarget ? 120000 : 3000;
        const initialDisplaySettleTimeoutMs = hasInitialRestoreTarget ? 120000 : 3000;
        const runInitialDisplayNavigation = async (intent, operation) => {
            const navigationStartedAt = performanceNowMs();
            readerLoadLog('viewer.initialDisplay.navigation.start', {
                reason,
                restoreLocatorKind,
                source: intent?.source ?? null,
                target: intent?.target ?? null,
                timeoutMs: initialNavigationTimeoutMs,
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                hasReaderContent: !!document.querySelector?.('foliate-view'),
                renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            });
            try {
                const result = await runWithNavigationIntent(intent, operation, {
                    timeoutMs: initialNavigationTimeoutMs,
                });
                readerLoadLog('viewer.initialDisplay.navigation.finish', {
                    reason,
                    restoreLocatorKind,
                    source: intent?.source ?? null,
                    target: intent?.target ?? null,
                    elapsedMs: safeRound(performanceNowMs() - navigationStartedAt, 1),
                    bodyLoading: !!document.body?.classList?.contains?.('loading'),
                    hasReaderContent: !!document.querySelector?.('foliate-view'),
                    renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
                });
                return {
                    ok: true,
                    result,
                };
            } catch (error) {
                readerLoadLog('viewer.initialDisplay.navigation.error', {
                    reason,
                    restoreLocatorKind,
                    source: intent?.source ?? null,
                    target: intent?.target ?? null,
                    elapsedMs: safeRound(performanceNowMs() - navigationStartedAt, 1),
                    error: error?.message || String(error),
                    bodyLoading: !!document.body?.classList?.contains?.('loading'),
                    hasReaderContent: !!document.querySelector?.('foliate-view'),
                    renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
                });
                globalThis.__manabiRestoreDebugLog?.('ebook.initialDisplay.navigation.error', {
                    reason,
                    restoreLocatorKind,
                    source: intent?.source ?? null,
                    target: intent?.target ?? null,
                    timeoutMs: initialNavigationTimeoutMs,
                    error: error?.message || String(error),
                    requestedFraction: hasInitialRestoreFraction ? safeRound(initialRestoreFraction, 6) : null,
                });
                return {
                    ok: false,
                    error,
                };
            }
        };
        readerLoadLog('viewer.initialDisplay.firstSection.start', {
            reason,
            restoreLocatorKind,
            sectionIndex: syntheticInitialRestore?.sectionIndex ?? null,
            spineSectionIndex: spineOnlyInitialRestoreSectionIndex ?? null,
            fraction: hasInitialRestoreFraction ? initialRestoreFraction : null,
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
            hasReaderContent: !!document.querySelector?.('foliate-view'),
            renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
        });
        globalThis.__manabiRestoreDebugLog?.('ebook.initialDisplay.start', {
            reason,
            restoreLocatorKind,
            hasInitialRestore: !!initialRestore,
            initialCFILength: typeof initialRestore?.cfi === 'string' ? initialRestore.cfi.length : 0,
            initialCFIPrefix: hasInitialRestoreCFI ? initialRestoreCFI.slice(0, 24) : null,
            requestedFraction: hasInitialRestoreFraction ? safeRound(initialRestoreFraction, 6) : null,
            syntheticSectionIndex: syntheticInitialRestore?.sectionIndex ?? null,
            syntheticLocalPage: syntheticInitialRestore?.localSectionIndex ?? null,
            spineSectionIndex: spineOnlyInitialRestoreSectionIndex ?? null,
            rawFractionType: typeof initialRestore?.fractionalCompletion,
            rawFractionValue: initialRestore?.fractionalCompletion ?? null,
            initialDisplaySettled: this.initialDisplaySettled === true,
            hasLoadedLastPosition: this.hasLoadedLastPosition === true,
        });
        try {
            let intent;
            let operation;
            if (syntheticInitialRestore) {
                intent = {
                    source: `${reason}.initialRestore`,
                    target: 'renderer.goTo',
                    sectionIndex: syntheticInitialRestore.sectionIndex,
                    localPage: syntheticInitialRestore.localSectionIndex,
                    rendererTotal: syntheticInitialRestore.rendererTotal,
                };
                operation = () => this.view.renderer.goTo?.({
                    index: syntheticInitialRestore.sectionIndex,
                    localPage: syntheticInitialRestore.localSectionIndex,
                });
            } else if (hasSpineOnlyInitialRestore) {
                if (hasInitialRestoreFraction) {
                    intent = {
                        source: `${reason}.initialRestoreSpineCFIFraction`,
                        target: 'view.goToFraction',
                        spineSectionIndex: spineOnlyInitialRestoreSectionIndex,
                        fraction: initialRestoreFraction,
                    };
                    operation = () => this.view.goToFraction(initialRestoreFraction);
                } else {
                    intent = {
                        source: `${reason}.initialRestoreSpineCFI`,
                        target: 'renderer.goTo',
                        sectionIndex: spineOnlyInitialRestoreSectionIndex,
                    };
                    operation = () => this.view.renderer.goTo?.({
                        index: spineOnlyInitialRestoreSectionIndex,
                    });
                }
            } else if (hasInitialRestoreCFI) {
                intent = {
                    source: `${reason}.initialRestoreCFI`,
                    target: 'view.goTo',
                    cfiLength: initialRestoreCFI.length,
                    fraction: hasInitialRestoreFraction ? initialRestoreFraction : null,
                };
                operation = async () => {
                    return await this.view.goTo(initialRestoreCFI);
                };
            } else if (hasInitialRestoreFraction) {
                intent = {
                    source: `${reason}.initialRestoreFraction`,
                    target: 'view.goToFraction',
                    fraction: initialRestoreFraction,
                };
                operation = () => this.view.goToFraction(initialRestoreFraction);
            } else {
                intent = {
                    source: reason,
                    target: 'renderer.firstSection',
                };
                operation = () => this.view.renderer.firstSection?.();
            }
            globalThis.__manabiRestoreDebugLog?.('ebook.initialDisplay.navigationIntent', {
                reason,
                restoreLocatorKind,
                source: intent?.source ?? null,
                target: intent?.target ?? null,
                sectionIndex: intent?.sectionIndex ?? null,
                spineSectionIndex: intent?.spineSectionIndex ?? null,
                localPage: intent?.localPage ?? null,
                cfiLength: intent?.cfiLength ?? null,
                requestedFraction: hasInitialRestoreFraction ? safeRound(initialRestoreFraction, 6) : null,
                rawFractionType: typeof initialRestore?.fractionalCompletion,
                rawFractionValue: initialRestore?.fractionalCompletion ?? null,
            });
            const navigationResult = await runInitialDisplayNavigation(intent, operation);
            const displaySettled = await this.waitForInitialDisplaySettled(`${reason}.initialDisplay`, {
                timeoutMs: initialDisplaySettleTimeoutMs,
            });
            const location = this.view?.lastLocation ?? null;
            const settledSectionIndex = typeof location?.section?.current === 'number'
                ? location.section.current
                : (typeof location?.sectionIndex === 'number' ? location.sectionIndex : null);
            const settledFraction = typeof location?.fraction === 'number' ? location.fraction : null;
            const initialRestoreRequested = hasInitialRestoreTarget;
            const initialRestoreFractionSatisfied = hasInitialRestoreFraction && !syntheticInitialRestore
                ? (
                    typeof settledFraction === 'number'
                    && Math.abs(settledFraction - initialRestoreFraction) <= 0.003
                )
                : navigationResult?.ok === true;
            const spineOnlyRestoreIsPreciseEnough =
                !hasSpineOnlyInitialRestore || hasInitialRestoreFraction;
            const initialRestoreWillBeMarkedHandled =
                initialRestoreRequested
                && initialRestoreFractionSatisfied
                && spineOnlyRestoreIsPreciseEnough;
            const initialRestoreFractionDelta = hasInitialRestoreFraction && typeof settledFraction === 'number'
                ? Math.abs(settledFraction - initialRestoreFraction)
                : null;
            globalThis.__manabiRestoreDebugLog?.('ebook.initialDisplay.settleCheck', {
                reason,
                restoreLocatorKind,
                initialRestoreRequested,
                hasInitialRestoreFraction,
                requestedFraction: hasInitialRestoreFraction ? safeRound(initialRestoreFraction, 6) : null,
                settledFraction: typeof settledFraction === 'number' ? safeRound(settledFraction, 6) : null,
                fractionDelta: initialRestoreFractionDelta != null ? safeRound(initialRestoreFractionDelta, 6) : null,
                navigationOk: navigationResult?.ok === true,
                initialRestoreFractionSatisfied,
                spineOnlyRestoreIsPreciseEnough,
                initialRestoreWillBeMarkedHandled,
                settledSectionIndex,
                settledReason: displaySettled?.reason ?? null,
            });
            readerLoadLog('viewer.initialDisplay.firstSection.finish', {
                reason,
                restoreLocatorKind,
                sectionIndex: syntheticInitialRestore?.sectionIndex ?? settledSectionIndex,
                fraction: hasInitialRestoreFraction ? initialRestoreFraction : null,
                currentFraction: typeof settledFraction === 'number' ? safeRound(settledFraction, 6) : null,
                restoreSatisfied: initialRestoreWillBeMarkedHandled,
                spineOnlyRestoreIsPreciseEnough,
                navigationOk: navigationResult?.ok === true,
                settledReason: displaySettled?.reason ?? null,
                elapsedMs: safeRound(performanceNowMs() - startedAt, 1),
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                hasReaderContent: !!document.querySelector?.('foliate-view'),
                renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            });
            globalThis.__manabiRestoreDebugLog?.('ebook.initialDisplay.finish', {
                reason,
                restoreLocatorKind,
                requestedFraction: hasInitialRestoreFraction ? safeRound(initialRestoreFraction, 6) : null,
                settledSectionIndex,
                lastLocationFraction: typeof settledFraction === 'number' ? safeRound(settledFraction, 6) : null,
                lastLocationCurrent: location?.location?.current ?? null,
                lastLocationTotal: location?.location?.total ?? null,
                initialRestoreWillBeMarkedHandled,
                spineOnlyRestoreIsPreciseEnough,
                navigationOk: navigationResult?.ok === true,
            });
            const terminalRestoreResult = publishInitialRestoreResult(
                initialRestoreWillBeMarkedHandled
                    ? 'satisfied'
                    : (initialRestoreRequested ? 'failed' : 'noTarget'),
                {
                    location,
                    navigationOk: navigationResult?.ok === true,
                    startedAt,
                }
            );
            if (initialRestoreWillBeMarkedHandled) {
                this.hasLoadedLastPosition = true;
                markReaderRenderReady('initialDisplay.restoreSatisfied');
                globalThis.__manabiInitialRestoreHandled = {
                    cfi: typeof initialRestore?.cfi === 'string' ? initialRestore.cfi : '',
                    fractionalCompletion: terminalRestoreResult.handledFractionalCompletion,
                    sectionIndex: syntheticInitialRestore?.sectionIndex ?? settledSectionIndex,
                    localSectionIndex: syntheticInitialRestore?.localSectionIndex ?? null,
                    rendererTotal: syntheticInitialRestore?.rendererTotal ?? null,
                    fractionalAnchorSuppressed: !!syntheticInitialRestore,
                    handledAtMs: Date.now(),
                };
                globalThis.__manabiRestoreDebugLog?.('ebook.initialDisplay.handledSet', {
                    reason,
                    restoreLocatorKind,
                    requestedSectionIndex: syntheticInitialRestore?.sectionIndex ?? null,
                    requestedLocalPage: syntheticInitialRestore?.localSectionIndex ?? null,
                    cfiLength: typeof initialRestore?.cfi === 'string' ? initialRestore.cfi.length : 0,
                    settledSectionIndex,
                    lastLocationFraction: typeof settledFraction === 'number' ? safeRound(settledFraction, 6) : null,
                    lastLocationCurrent: location?.location?.current ?? null,
                    lastLocationTotal: location?.location?.total ?? null,
                });
            } else if (initialRestoreRequested) {
                readerLoadLog('viewer.initialDisplay.restoreNotSatisfied', {
                    reason,
                    restoreLocatorKind,
                    requestedFraction: hasInitialRestoreFraction ? safeRound(initialRestoreFraction, 6) : null,
                    currentFraction: typeof settledFraction === 'number' ? safeRound(settledFraction, 6) : null,
                    settledSectionIndex,
                    locationCurrent: location?.location?.current ?? null,
                    locationTotal: location?.location?.total ?? null,
                });
            }
            return true;
        } catch (error) {
            readerLoadLog('viewer.initialDisplay.firstSection.error', {
                reason,
                restoreLocatorKind,
                sectionIndex: syntheticInitialRestore?.sectionIndex ?? null,
                fraction: hasInitialRestoreFraction ? initialRestoreFraction : null,
                elapsedMs: safeRound(performanceNowMs() - startedAt, 1),
                error: error?.message || String(error),
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                hasReaderContent: !!document.querySelector?.('foliate-view'),
                renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            });
            publishInitialRestoreResult(hasInitialRestoreTarget ? 'failed' : 'noTarget', {
                error: error?.message || String(error),
                navigationOk: false,
                startedAt,
            });
            return false;
        }
    }

    async displayInitialSection(reason = 'external', initialRestore = null) {
        return this.#displayInitialSection(reason, initialRestore);
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
        const pageMetrics = typeof r.pageMetrics === "function" ? await r.pageMetrics() : null;
        // Use new section start/end helpers if available
        const atSectionStart = pageMetrics
            ? pageMetrics.page <= 1
            : (typeof r.isAtSectionStart === "function" ? await r.isAtSectionStart() : false);
        const atSectionEnd = pageMetrics
            ? pageMetrics.page >= pageMetrics.pages - 2
            : (typeof r.isAtSectionEnd === "function" ? await r.isAtSectionEnd() : false);
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
                markRestorePositionSavePageTurnInput(`pageTurn.keydown.${k}`);
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
                markRestorePositionSavePageTurnInput(`pageTurn.keydown.${k}`);
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
    async #waitForLookupContentFunction(functionName, timeoutMs = 1800) {
        const startedAt = performance.now();
        while (performance.now() - startedAt < timeoutMs) {
            const contentWindow = this.#lookupContentWindows().find((view) => typeof view?.[functionName] === 'function');
            if (contentWindow) return contentWindow;
            await new Promise((resolve) => setTimeout(resolve, 40));
        }
        return this.#lookupContentWindows().find((view) => typeof view?.[functionName] === 'function') ?? null;
    }
    async #settleAfterLookupPageTurn() {
        await new Promise((resolve) => setTimeout(resolve, 140));
        await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        const docs = this.#lookupContentWindows().map((view) => view.document).filter(isDocumentLike);
        await Promise.race([
            Promise.all(docs.map((doc) => Promise.resolve(doc.fonts?.ready).catch(() => null))),
            new Promise((resolve) => setTimeout(resolve, 500)),
        ]).catch(() => null);
        for (const doc of docs) {
            const visibleRange = this.#visibleRangeForDocument(doc);
            this.visiblePageSegmentSnapshot = null;
            this.#visiblePageSegmentResult(doc, visibleRange, 'lookup-navigation.page-turn-settled');
        }
        await new Promise((resolve) => requestAnimationFrame(resolve));
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
        console.log('# POPOVER lookup.nav.visibleAfterPageTurn.begin',
            `kind=${kind}`,
            `direction=${direction}`);
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
            console.log('# POPOVER lookup.nav.visibleAfterPageTurn.attempt',
                `kind=${kind}`,
                `direction=${direction}`,
                `opened=${result?.opened === true}`,
                `failureReason=${result?.failureReason ?? 'nil'}`,
                `targetElementID=${result?.target?.id ?? 'nil'}`,
                `attemptCount=${attempts.length}`);
            if (result?.opened === true) {
                result.contentWindowURL = contentWindow.location?.href ?? null;
                result.contentWindowAttempts = attempts;
                console.log('# POPOVER lookup.nav.visibleAfterPageTurn.finish',
                    `kind=${kind}`,
                    `direction=${direction}`,
                    'opened=true',
                    `attemptCount=${attempts.length}`);
                return result;
            }
            if (result?.failureReason !== 'noVisibleTargetAfterPageTurn') {
                console.log('# POPOVER lookup.nav.visibleAfterPageTurn.finish',
                    `kind=${kind}`,
                    `direction=${direction}`,
                    'opened=false',
                    `failureReason=${result?.failureReason ?? 'nil'}`,
                    `attemptCount=${attempts.length}`);
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
        console.log('# POPOVER lookup.nav.visibleAfterPageTurn.finish',
            `kind=${kind}`,
            `direction=${direction}`,
            'opened=false',
            'failureReason=noVisibleTargetAfterPageTurn',
            `attemptCount=${attempts.length}`);
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
            console.log('# POPOVER lookup.nav.pageTurn.step',
                `direction=${direction}`,
                'moved=false',
                'failureReason=missingRenderer');
            return {
                moved: false,
                failureReason: 'missingRenderer',
            };
        }
        const normalizedDirection = direction === 'previous' ? 'previous' : 'next';
        const atStart = await renderer.atStart?.();
        const atEnd = await renderer.atEnd?.();
        const beforePosition = this.#lookupNavigationPositionSnapshot();
        if (normalizedDirection === 'next') {
            if (atEnd === true) {
                this.#clearVisiblePageReadChrome('lookup-navigation-page-turn-start');
                this.#applyLogicalPageTurnNavigationVisibility('forward', 'lookup-navigation.next-section');
                await renderer.nextSection?.();
                console.log('# POPOVER lookup.nav.pageTurn.step',
                    'direction=next',
                    'mode=nextSection',
                    `atStart=${atStart}`,
                    `atEnd=${atEnd}`,
                    `before=${JSON.stringify(beforePosition)}`);
                return { moved: true, mode: 'nextSection' };
            }
            this.#clearVisiblePageReadChrome('lookup-navigation-page-turn-start');
            this.#applyLogicalPageTurnNavigationVisibility('forward', 'lookup-navigation.page');
            if (this.isRTL) {
                await this.view.goLeft();
                console.log('# POPOVER lookup.nav.pageTurn.step',
                    'direction=next',
                    'mode=goLeft',
                    `atStart=${atStart}`,
                    `atEnd=${atEnd}`,
                    `before=${JSON.stringify(beforePosition)}`);
                return { moved: true, mode: 'goLeft' };
            }
            await this.view.goRight();
            console.log('# POPOVER lookup.nav.pageTurn.step',
                'direction=next',
                'mode=goRight',
                `atStart=${atStart}`,
                `atEnd=${atEnd}`,
                `before=${JSON.stringify(beforePosition)}`);
            return { moved: true, mode: 'goRight' };
        }
        if (atStart === true) {
            this.#clearVisiblePageReadChrome('lookup-navigation-page-turn-start');
            this.#applyLogicalPageTurnNavigationVisibility('backward', 'lookup-navigation.previous-section');
            await renderer.prevSection?.();
            console.log('# POPOVER lookup.nav.pageTurn.step',
                'direction=previous',
                'mode=prevSection',
                `atStart=${atStart}`,
                `atEnd=${atEnd}`,
                `before=${JSON.stringify(beforePosition)}`);
            return { moved: true, mode: 'prevSection' };
        }
        this.#clearVisiblePageReadChrome('lookup-navigation-page-turn-start');
        this.#applyLogicalPageTurnNavigationVisibility('backward', 'lookup-navigation.page');
        if (this.isRTL) {
            await this.view.goRight();
            console.log('# POPOVER lookup.nav.pageTurn.step',
                'direction=previous',
                'mode=goRight',
                `atStart=${atStart}`,
                `atEnd=${atEnd}`,
                `before=${JSON.stringify(beforePosition)}`);
            return { moved: true, mode: 'goRight' };
        }
        await this.view.goLeft();
        console.log('# POPOVER lookup.nav.pageTurn.step',
            'direction=previous',
            'mode=goLeft',
            `atStart=${atStart}`,
            `atEnd=${atEnd}`,
            `before=${JSON.stringify(beforePosition)}`);
        return { moved: true, mode: 'goLeft' };
    }
    async performLookupNavigationPageTurn(request = {}) {
        const token = (this.lookupNavigationPageTurnToken ?? 0) + 1;
        this.lookupNavigationPageTurnToken = token;
        const kind = request?.kind === 'sentence' || request?.kind === 'section' ? request.kind : 'word';
        const direction = request?.direction === 'previous' ? 'previous' : 'next';
        const maxPageTurns = Math.max(1, Math.min(12, Number.isFinite(request?.maxPageTurns) ? Math.round(request.maxPageTurns) : 8));
        const startedAt = performance.now();
        const attempts = [];
        console.log('# POPOVER lookup.nav.pageTurn.begin',
            `kind=${kind}`,
            `direction=${direction}`,
            `maxPageTurns=${maxPageTurns}`,
            `failureReason=${request?.failureReason ?? 'nil'}`,
            `currentElementID=${request?.currentElementID ?? 'nil'}`,
            `currentSegmentIdentifier=${request?.currentSegmentIdentifier ?? 'nil'}`);
        for (let pageTurnIndex = 0; pageTurnIndex < maxPageTurns; pageTurnIndex += 1) {
            if (this.lookupNavigationPageTurnToken !== token) {
                console.log('# POPOVER lookup.nav.pageTurn.finish',
                    `kind=${kind}`,
                    `direction=${direction}`,
                    'opened=false',
                    'failureReason=superseded',
                    `attemptCount=${attempts.length}`);
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
            try {
                turnResult = await this.#turnLookupNavigationPage(direction);
                await this.#settleAfterLookupPageTurn();
            } catch (error) {
                turnResult = {
                    moved: false,
                    failureReason: 'pageTurnError',
                    error: error?.message || String(error),
                };
            }
            const positionAfterTurn = this.#lookupNavigationPositionSnapshot();
            const positionChanged = this.#lookupNavigationPositionChanged(positionBeforeTurn, positionAfterTurn);
            if (turnResult) {
                turnResult.positionBefore = positionBeforeTurn;
                turnResult.positionAfter = positionAfterTurn;
                turnResult.positionChanged = positionChanged;
            }
            if (turnResult?.moved === false || !positionChanged) {
                console.log('# POPOVER lookup.nav.pageTurn.attempt',
                    `kind=${kind}`,
                    `direction=${direction}`,
                    `pageTurnIndex=${pageTurnIndex}`,
                    `moved=${turnResult?.moved === true}`,
                    `positionChanged=${positionChanged}`,
                    `turnMode=${turnResult?.mode ?? 'nil'}`,
                    `visibleTargetOpened=false`,
                    `visibleTargetFailureReason=${turnResult?.failureReason ?? (positionChanged ? 'nil' : 'pageTurnDidNotMove')}`);
                attempts.push({
                    pageTurnIndex,
                    turnResult,
                    visibleTargetOpened: false,
                    visibleTargetFailureReason: turnResult?.failureReason ?? (positionChanged ? null : 'pageTurnDidNotMove'),
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
                visibleTargetResult = await this.#openVisibleLookupTargetAfterPageTurn({
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
            console.log('# POPOVER lookup.nav.pageTurn.attempt',
                `kind=${kind}`,
                `direction=${direction}`,
                `pageTurnIndex=${pageTurnIndex}`,
                `moved=${turnResult?.moved === true}`,
                `positionChanged=${positionChanged}`,
                `turnMode=${turnResult?.mode ?? 'nil'}`,
                `visibleTargetOpened=${attempt.visibleTargetOpened}`,
                `visibleTargetFailureReason=${attempt.visibleTargetFailureReason ?? 'nil'}`);
            if (visibleTargetResult?.opened === true) {
                console.log('# POPOVER lookup.nav.pageTurn.finish',
                    `kind=${kind}`,
                    `direction=${direction}`,
                    'opened=true',
                    `pageTurnIndex=${pageTurnIndex}`,
                    `turnMode=${turnResult?.mode ?? 'nil'}`,
                    `attemptCount=${attempts.length}`);
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
        console.log('# POPOVER lookup.nav.pageTurn.finish',
            `kind=${kind}`,
            `direction=${direction}`,
            'opened=false',
            'failureReason=pageTurnLookupTargetNotFound',
            `attemptCount=${attempts.length}`);
        return {
            opened: false,
            failureReason: 'pageTurnLookupTargetNotFound',
            kind,
            direction,
            attempts,
            elapsedMs: Math.round(performance.now() - startedAt),
        };
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
    #resetInitialDisplaySettledPromise() {
        this.initialDisplaySettled = false;
        this.initialDisplaySettledPromise = new Promise((resolve) => {
            this.initialDisplaySettledResolve = resolve;
        });
    }
    #resolveInitialDisplaySettled(reason = 'unspecified') {
        if (this.initialDisplaySettled) return;
        this.initialDisplaySettled = true;
        const resolve = this.initialDisplaySettledResolve;
        this.initialDisplaySettledResolve = null;
        resolve?.({
            reason,
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
            hasReaderContent: !!document.querySelector?.('foliate-view'),
        });
    }
    async waitForInitialDisplaySettled(reason = 'unspecified', {
        timeoutMs = null,
    } = {}) {
        if (this.initialDisplaySettled) {
            readerLoadLog('viewer.initialDisplay.wait.skip', {
                reason,
                settled: true,
                timeoutMs,
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                hasReaderContent: !!document.querySelector?.('foliate-view'),
            });
            return {
                settled: true,
                reason: 'already-settled',
            };
        }
        if (!this.initialDisplaySettledPromise) {
            this.#resetInitialDisplaySettledPromise();
        }
        const startedAt = performanceNowMs();
        let timeoutHandle = null;
        readerLoadLog('viewer.initialDisplay.wait.start', {
            reason,
            timeoutMs,
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
            hasReaderContent: !!document.querySelector?.('foliate-view'),
            hasRenderer: !!this.view?.renderer,
        });
        try {
            const result = await (
                Number.isFinite(timeoutMs) && timeoutMs > 0
                    ? Promise.race([
                        this.initialDisplaySettledPromise,
                        new Promise((_, reject) => {
                            timeoutHandle = setTimeout(() => {
                                reject(new Error(`Timed out after ${timeoutMs}ms`));
                            }, timeoutMs);
                        }),
                    ])
                    : this.initialDisplaySettledPromise
            );
            readerLoadLog('viewer.initialDisplay.wait.finish', {
                reason,
                timeoutMs,
                elapsedMs: safeRound(performanceNowMs() - startedAt, 1),
                settledReason: result?.reason ?? null,
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                hasReaderContent: !!document.querySelector?.('foliate-view'),
            });
            return {
                settled: true,
                ...result,
            };
        } catch (error) {
            readerLoadLog('viewer.initialDisplay.wait.error', {
                reason,
                timeoutMs,
                elapsedMs: safeRound(performanceNowMs() - startedAt, 1),
                error: error?.message || String(error),
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                hasReaderContent: !!document.querySelector?.('foliate-view'),
                hasRenderer: !!this.view?.renderer,
            });
            throw error;
        } finally {
            if (timeoutHandle !== null) {
                clearTimeout(timeoutHandle);
            }
        }
    }
    #resolveDisplaySettledWaiters(reason = 'unspecified') {
        this.displaySettledSequence += 1;
        const waiters = this.displaySettledWaiters.splice(0);
        if (!waiters.length) return;
        const result = {
            reason,
            sequence: this.displaySettledSequence,
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
            hasReaderContent: !!document.querySelector?.('foliate-view'),
            renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
        };
        waiters.forEach((waiter) => {
            if (typeof waiter === 'function') {
                waiter(result);
            } else {
                waiter?.resolve?.(result);
            }
        });
    }
    async waitForNextDisplaySettled(reason = 'unspecified', {
        timeoutMs = null,
    } = {}) {
        const startedAt = performanceNowMs();
        const startedSequence = this.displaySettledSequence;
        let timeoutHandle = null;
        let waiter = null;
        readerLoadLog('viewer.display.wait.start', {
            reason,
            sequence: startedSequence,
            timeoutMs,
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
            hasReaderContent: !!document.querySelector?.('foliate-view'),
            renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
        });
        try {
            const result = await new Promise((resolve, reject) => {
                waiter = { resolve, reject };
                this.displaySettledWaiters.push(waiter);
                if (Number.isFinite(timeoutMs) && timeoutMs > 0) {
                    timeoutHandle = setTimeout(() => {
                        this.displaySettledWaiters = this.displaySettledWaiters.filter((item) => item !== waiter);
                        reject(new Error(`Timed out after ${timeoutMs}ms`));
                    }, timeoutMs);
                }
            });
            readerLoadLog('viewer.display.wait.finish', {
                reason,
                elapsedMs: safeRound(performanceNowMs() - startedAt, 1),
                startedSequence,
                settledSequence: result?.sequence ?? null,
                settledReason: result?.reason ?? null,
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                hasReaderContent: !!document.querySelector?.('foliate-view'),
                renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            });
            return result;
        } catch (error) {
            readerLoadLog('viewer.display.wait.error', {
                reason,
                elapsedMs: safeRound(performanceNowMs() - startedAt, 1),
                error: error?.message || String(error),
                startedSequence,
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                hasReaderContent: !!document.querySelector?.('foliate-view'),
                renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            });
            throw error;
        } finally {
            clearTimeout(timeoutHandle);
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
        this.setLoadingIndicator(true, 'renderer.goTo');
    }
    async #onDidDisplay({}) {
        const didDisplayStartedAt = performanceNowMs();
        const navVisibilityBefore = captureNavVisibilityState();
        const shouldSkipSameIndexDidDisplay =
            (this.sameIndexGoToDidDisplaySkips || 0) > 0
            && !document.body?.classList?.contains?.('loading');
        if (shouldSkipSameIndexDidDisplay) {
            this.sameIndexGoToDidDisplaySkips = Math.max(0, (this.sameIndexGoToDidDisplaySkips || 0) - 1);
            readerLoadLog('viewer.didDisplay.skipSameIndex', {
                elapsedMs: performanceNowMs() - didDisplayStartedAt,
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
            });
            this.#resolveInitialDisplaySettled('didDisplay.skipSameIndex');
            return;
        }
        readerLoadLog('viewer.didDisplay.begin', {
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
            hasRenderer: !!this.view?.renderer,
            renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
        });
        this.#postBookInsetSnapshot('didDisplay.begin', {
            beforeNavigationVisibility: navVisibilityBefore,
        });
        let initialSettleResult = null;
        let postFrameSettleResult = null;
        try {
            applyStoredChromeInsets('reader.didDisplay');
            readerLoadLog('viewer.didDisplay.initialSettle.start', {
                elapsedMs: performanceNowMs() - didDisplayStartedAt,
            });
            initialSettleResult = await this.#settleInitialPaginatorLayout('did-display.pre-clear', {
                allowWhileLoading: true,
            });
            readerLoadLog('viewer.didDisplay.initialSettle.finish', {
                elapsedMs: performanceNowMs() - didDisplayStartedAt,
                rendered: initialSettleResult?.rendered ?? null,
                reason: initialSettleResult?.reason ?? null,
            });
            this.#postBookInsetSnapshot('didDisplay.after-initial-settle', {
                initialSettleResult,
            });
            const shouldRunPostFrameSettle =
                MANABI_ENABLE_DID_DISPLAY_POST_FRAME_SETTLE
                && (
                initialSettleResult?.rendered === true
                || initialSettleResult?.reason === 'error'
                );
            if (shouldRunPostFrameSettle) {
                await this.#waitForAnimationFrames(2);
                this.#postBookInsetSnapshot('didDisplay.after-two-frames-before-force', {
                    initialSettleResult,
                });
                readerLoadLog('viewer.didDisplay.postFrameSettle.start', {
                    elapsedMs: performanceNowMs() - didDisplayStartedAt,
                    initialReason: initialSettleResult?.reason ?? null,
                });
                postFrameSettleResult = await this.#settleInitialPaginatorLayout('did-display.pre-clear.post-frame', {
                    allowWhileLoading: true,
                    force: true,
                });
                readerLoadLog('viewer.didDisplay.postFrameSettle.finish', {
                    elapsedMs: performanceNowMs() - didDisplayStartedAt,
                    rendered: postFrameSettleResult?.rendered ?? null,
                    reason: postFrameSettleResult?.reason ?? null,
                });
            } else {
                postFrameSettleResult = {
                    rendered: false,
                    reason: MANABI_ENABLE_DID_DISPLAY_POST_FRAME_SETTLE
                        ? 'initial-settle-stable'
                        : 'post-frame-settle-disabled',
                };
            }
            this.#postBookInsetSnapshot('didDisplay.after-post-frame-settle', {
                initialSettleResult,
                postFrameSettleResult,
            });
        } catch (error) {
            postFrameSettleResult = {
                rendered: false,
                reason: 'did-display-error',
                message: error?.message ?? String(error),
            };
            readerLoadLog('viewer.didDisplay.error', {
                elapsedMs: performanceNowMs() - didDisplayStartedAt,
                error: error?.message || String(error),
            });
            console.error(error);
        }
        try {
            const doc = this.view?.renderer?.getContents?.()?.[0]?.doc ?? null;
            if (isDocumentLike(doc)) {
                const visibleRange = this.#visibleRangeForDocument(doc);
                let visibleSegmentsResult = this.#visiblePageSegmentResult(
                    doc,
                    visibleRange,
                    'didDisplay.pre-render-ready',
                    {
                        postIfCached: true,
                        includeClientRects: true,
                        postLookupTargets: true,
                        hydrateStatuses: true,
                        finishInitialCritical: true,
                    }
                );
                highlightStatusLog('didDisplay.pre-render-ready', {
                    visibleSegmentCount: visibleSegmentsResult?.visibleSegments?.length ?? 0,
                    totalSegmentCount: visibleSegmentsResult?.totalSegmentCount ?? 0,
                    source: visibleSegmentsResult?.segmentCandidateSource ?? null,
                    bodyTrackingEnabled: doc.body?.dataset?.mnbTrackingEnabled ?? null,
                });
            }
        } catch (error) {
            highlightStatusLog('didDisplay.pre-render-ready.error', {
                error: error?.message || String(error),
            });
        }
        this.setLoadingIndicator(false, 'didDisplay');
        readerLoadLog('viewer.didDisplay.loadingCleared', {
            elapsedMs: performanceNowMs() - didDisplayStartedAt,
            initialReason: initialSettleResult?.reason ?? null,
            postFrameReason: postFrameSettleResult?.reason ?? null,
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
        });
        markReaderRenderReady('didDisplay.loading-cleared');
        this.#postBookInsetSnapshot('didDisplay.loading-cleared', {
            initialSettleResult,
            postFrameSettleResult,
        });
        globalThis.__manabiPostReaderDocStateEvent?.('didDisplay.loadingCleared');
        this.#resolveInitialDisplaySettled('didDisplay.loading-cleared');
        this.#resolveDisplaySettledWaiters('didDisplay.loading-cleared');
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
        this.#applyHideNavigationDueToScrollToBookContent(this.navHUD?.hideNavigationDueToScroll === true, 'reader.didDisplay');
        this.#scheduleInitialPaginatorSettle('did-display');
        postReaderVisibilityProbe('reader.didDisplay', this.view, null);
    }
    #onLoad({
        detail: {
            doc
        }
    }) {
        applyStoredChromeInsets('reader.documentLoad');
        applyReaderPresentationStateToDocument(doc, globalThis.__manabiReaderPresentationState, 'document-load');
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
        if (
            doc
            && doc.__manabiMay20BlankTapLoggingInstalled !== true
            && !(MANABI_TEMP_DISABLE_EBOOK_NATIVE_LOOKUP_HIT_TARGETS && isEbookContentDocument(doc))
        ) {
            doc.__manabiMay20BlankTapLoggingInstalled = true;
            const blankPointerMoveThreshold = 12;
            let pendingBlankPointerTap = null;
            let lastBlankTouchEnd = null;
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
                const lastTouchTap = lastPostedBlankTouchTap || lastBlankTouchEnd;
                if (event.type !== 'mousedown' || !lastTouchTap) {
                    return false;
                }
                const ageMs = now - lastTouchTap.postedAtMs;
                if (ageMs < 0 || ageMs > syntheticMouseAfterTouchSuppressionMs) {
                    return false;
                }
                const point = blankPointerPoint(event);
                if (!point || point.x === null || point.y === null) {
                    return true;
                }
                const dx = point.x - lastTouchTap.x;
                const dy = point.y - lastTouchTap.y;
                return (dx * dx + dy * dy) <= (syntheticMouseAfterTouchDistanceThreshold * syntheticMouseAfterTouchDistanceThreshold);
            };
            const blankPointerMovedPastTapThreshold = (event, pending) => {
                const point = touchPointForBlankPointer(event);
                const dx = (point?.screenX ?? point?.clientX ?? pending.startX) - pending.startX;
                const dy = (point?.screenY ?? point?.clientY ?? pending.startY) - pending.startY;
                return (dx * dx + dy * dy) > (blankPointerMoveThreshold * blankPointerMoveThreshold);
            };
            const closestSegmentForElement = element => {
                if (!element) return null;
                const targetElement = element?.nodeType === 1 ? element : element?.parentElement;
                return targetElement?.closest?.('m-m, .m-m') ?? null;
            };
            const segmentTargetForBlankPointerEvent = (event) => {
                const directSegment = closestSegmentForElement(event.target);
                if (directSegment) return directSegment;
                for (const pathElement of event.composedPath?.() || []) {
                    const pathSegment = closestSegmentForElement(pathElement);
                    if (pathSegment) return pathSegment;
                }
                return null;
            };
            const postContentDocumentBlankPointerTap = (event, source, touchstartAtMs = Date.now()) => {
                const target = event.target;
                const targetElement = target?.nodeType === 1 ? target : target?.parentElement;
                const excludedTarget = targetElement?.closest?.('a, button, input, textarea, select, [role="button"], [contenteditable="true"], m-m, m-s, m-t, .m-m, .m-sentence, ruby, rt');
                const now = Date.now();
                const point = touchPointForBlankPointer(event);
                const segmentTarget = segmentTargetForBlankPointerEvent(event);
                if (segmentTarget) {
                    const payload = {
                        source,
                        eventType: event.type,
                        clientX: point?.clientX ?? null,
                        clientY: point?.clientY ?? null,
                        elementID: segmentTarget?.id || segmentTarget?.getAttribute?.('id') || null,
                    };
                    ebookLoadLog('nativeLookup.blankTap.segmentSuppressed', payload);
                    popoverDiagnosticLog('nativeLookup.blankTap.segmentSuppressed', payload);
                    return;
                }
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
                    const payload = {
                        source,
                        eventType: event.type,
                        clientX: point?.clientX ?? null,
                        clientY: point?.clientY ?? null,
                        excludedTarget: excludedTarget?.tagName ?? null,
                        segmentTarget: segmentTarget?.id ?? null,
                    };
                    ebookLoadLog('nativeLookup.blankTap.postNoElement', payload);
                    popoverDiagnosticLog('nativeLookup.blankTap.postNoElement', payload);
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
                const targetElement = target?.nodeType === 1 ? target : target?.parentElement;
                const excludedTarget = targetElement?.closest?.('a, button, input, textarea, select, [role="button"], [contenteditable="true"], m-m, m-s, m-t, .m-m, .m-sentence, ruby, rt');
                const startSegment = segmentTargetForBlankPointerEvent(event);
                if (excludedTarget && !startSegment) {
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
                const point = blankPointerPoint(event);
                lastBlankTouchEnd = point && point.x !== null && point.y !== null
                    ? {
                        postedAtMs: Date.now(),
                        x: point.x,
                        y: point.y,
                    }
                    : null;
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
        if (MANABI_ENABLE_EBOOK_PAGE_TRACKING_BUTTONS) {
            this.#schedulePageTrackingSync('document-load', doc, 2, isCacheWarmerDocument(doc) ? 0 : 128);
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
        const visibleSnapshot = this.visiblePageSegmentSnapshot;
        const visibleSegmentsResult = isDocumentLike(doc)
            && visibleSnapshot
            && visibleSnapshot.generation === this.visiblePageCollectionGeneration
            && visibleSnapshot.doc === doc
            && visibleSnapshot.visibleRange === visibleRange
            ? visibleSnapshot.result
            : null;
        const visibleJapaneseTextState = getVisibleJapaneseTextStateForRenderer(
            this.view?.renderer,
            visibleRange,
            visibleSegmentsResult
        );
        globalThis.__manabiRestoreDebugLog?.('ebook.updateReadingProgress.post', {
            reason,
            fraction: Number.isFinite(fraction) ? safeRound(fraction, 6) : null,
            cfiLength: typeof cfi === 'string' ? cfi.length : 0,
            currentPageNumber,
            totalPages,
            sectionIndex,
            hasVisibleJapaneseText: visibleJapaneseTextState.hasVisibleJapaneseText,
            visibleSegmentCount: visibleJapaneseTextState.visibleSegmentCount,
            observedSegmentCount: visibleJapaneseTextState.observedSegmentCount,
            hasLoadedLastPosition: this.hasLoadedLastPosition === true,
            restoreInProgress: globalThis.__manabiRestoreInProgress === true,
            suppressNextSave: globalThis.__manabiSuppressNextRestoreRelocateSave === true,
            requireUserInputBeforeSave: globalThis.__manabiRequireUserInputBeforePositionSave === true,
        });
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
        const effectiveFractionDiagnostics = getAuthoritativeReaderFractionDiagnostics({
            navHUD: this.navHUD,
            detail,
            fallbackFraction: fraction,
        });
        const effectiveFraction = effectiveFractionDiagnostics.fraction;
        const progressFraction = typeof fraction === 'number' && Number.isFinite(fraction)
            ? Math.max(0, Math.min(1, fraction))
            : effectiveFraction;
        const progressFractionSource = typeof fraction === 'number' && Number.isFinite(fraction)
            ? 'relocate-detail'
            : effectiveFractionDiagnostics.source;
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
        const sectionBaseCFI = typeof sectionIndex === 'number'
            ? (this.view?.book?.sections?.[sectionIndex]?.cfi ?? null)
            : null;
        const section = typeof sectionIndex === 'number'
            ? (this.view?.book?.sections?.[sectionIndex] ?? null)
            : null;
        let livePageMetrics = null;
        try {
            livePageMetrics = typeof this.view?.renderer?.pageMetrics === 'function'
                ? await this.view.renderer.pageMetrics()
                : null;
        } catch (_error) {
            livePageMetrics = null;
        }
        const liveTextPageTotal = typeof livePageMetrics?.pages === 'number'
            ? Math.max(1, Math.round(livePageMetrics.pages) - 2)
            : null;
        const liveTextPageCurrent = typeof livePageMetrics?.page === 'number' && typeof liveTextPageTotal === 'number'
            ? Math.max(1, Math.min(liveTextPageTotal, Math.round(livePageMetrics.page)))
            : null;
        const snapshotLocalSectionIndex = typeof this.navHUD?.rendererPageSnapshot?.current === 'number'
            ? Math.max(0, this.navHUD.rendererPageSnapshot.current - 1)
            : null;
        const snapshotRendererTotal = typeof this.navHUD?.rendererPageSnapshot?.total === 'number'
            ? this.navHUD.rendererPageSnapshot.total
            : null;
        const localSectionIndex = liveTextPageCurrent != null
            ? liveTextPageCurrent - 1
            : snapshotLocalSectionIndex;
        const rendererTotal = liveTextPageTotal ?? snapshotRendererTotal;
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
            && this.view?.renderer?.localName === 'foliate-paginator'
            && (
                cfiLooksSectionBase
                || cfiIsUnstableAcrossPages
                || typeof cfi !== 'string'
                || cfi.length === 0
            );
        const persistedLocator = shouldPreferSyntheticRestoreLocator
            ? syntheticRestoreLocator
            : cfi;
        readerLoadLog('viewer.restoreLocator.decision', {
            reason: reason ?? null,
            sectionIndex,
            snapshotLocalSectionIndex,
            snapshotRendererTotal,
            liveTextPageCurrent,
            liveTextPageTotal,
            localSectionIndex,
            rendererTotal,
            cfiLooksSectionBase,
            cfiIsUnstableAcrossPages,
            didMarkCFIUnstable,
            hasSyntheticRestoreLocator: !!syntheticRestoreLocator,
            shouldPreferSyntheticRestoreLocator,
            persistedLocatorKind: shouldPreferSyntheticRestoreLocator
                ? 'synthetic'
                : (typeof cfi === 'string' && cfi ? 'cfi' : 'empty'),
        });
        const progressBridgePayload = {
            reason: reason ?? null,
            effectiveFraction: Number.isFinite(effectiveFraction) ? safeRound(effectiveFraction, 6) : null,
            effectiveFractionSource: effectiveFractionDiagnostics.source,
            progressFraction: Number.isFinite(progressFraction) ? safeRound(progressFraction, 6) : null,
            progressFractionSource,
            effectivePrimaryLabelFraction: typeof effectiveFractionDiagnostics.primaryLabelFraction === 'number'
                ? safeRound(effectiveFractionDiagnostics.primaryLabelFraction, 6)
                : null,
            effectiveScrubberFraction: typeof effectiveFractionDiagnostics.scrubberFraction === 'number'
                ? safeRound(effectiveFractionDiagnostics.scrubberFraction, 6)
                : null,
            effectiveFallbackFraction: typeof effectiveFractionDiagnostics.fallbackFraction === 'number'
                ? safeRound(effectiveFractionDiagnostics.fallbackFraction, 6)
                : null,
            rawFraction: typeof fraction === 'number' ? safeRound(fraction, 6) : null,
            displayPercent: roundedDisplayPercent(Number.isFinite(effectiveFraction) ? effectiveFraction : fraction),
            currentPercent,
            primaryLabelSource: primaryLabelDiagnostics?.source ?? null,
            primaryLabelText: primaryLabelDiagnostics?.label ?? null,
            primaryLabelFraction: typeof primaryLabelDiagnostics?.fraction === 'number'
                ? safeRound(primaryLabelDiagnostics.fraction, 6)
                : null,
            primaryLabelSectionIndex: typeof primaryLabelDiagnostics?.sectionIndex === 'number'
                ? primaryLabelDiagnostics.sectionIndex
                : null,
            primaryLabelSectionIndexSource: primaryLabelDiagnostics?.sectionIndexSource ?? null,
            primaryLabelResolvedHref: primaryLabelDiagnostics?.resolvedSectionHref ?? null,
            detailLocationCurrent: typeof detail?.location?.current === 'number'
                ? detail.location.current
                : null,
            detailLocationTotal: typeof detail?.location?.total === 'number'
                ? detail.location.total
                : null,
            detailPageNumber: typeof detail?.pageNumber === 'number' ? detail.pageNumber : null,
            detailPageCount: typeof detail?.pageCount === 'number' ? detail.pageCount : null,
            navRendererPageCurrent: typeof this.navHUD?.rendererPageSnapshot?.current === 'number'
                ? this.navHUD.rendererPageSnapshot.current
                : null,
            navRendererPageTotal: typeof this.navHUD?.rendererPageSnapshot?.total === 'number'
                ? this.navHUD.rendererPageSnapshot.total
                : null,
            liveMetricPage: typeof livePageMetrics?.page === 'number' ? livePageMetrics.page : null,
            liveMetricPages: typeof livePageMetrics?.pages === 'number' ? livePageMetrics.pages : null,
            liveMetricSize: typeof livePageMetrics?.size === 'number' ? safeRound(livePageMetrics.size, 2) : null,
            liveMetricViewSize: typeof livePageMetrics?.viewSize === 'number' ? safeRound(livePageMetrics.viewSize, 2) : null,
            liveMetricStart: typeof livePageMetrics?.start === 'number' ? safeRound(livePageMetrics.start, 2) : null,
            liveMetricSource: livePageMetrics?.metricsSource ?? livePageMetrics?.source ?? null,
            sectionIndex,
            sectionHref: typeof section?.id === 'string' ? section.id : null,
            sectionLinear: section?.linear ?? null,
            sectionSize: typeof section?.size === 'number' ? section.size : null,
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
        manabiTimelineMark('viewer.progress.inputs', progressBridgePayload);
        readerLoadLog('viewer.progress.inputs', progressBridgePayload);
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
                    fraction: Number.isFinite(progressFraction) ? progressFraction : fraction,
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
            if (Number.isFinite(effectiveFraction)) {
                const pct = Math.round(effectiveFraction * 100);
                percentInput.value = pct;
                this.lastPercentValue = pct;
                percentButton.disabled = true;
            } else {
                readerLoadLog('viewer.percent.input.skip', {
                    reason: reason ?? null,
                    effectiveFraction,
                    effectiveFractionSource: effectiveFractionDiagnostics.source,
                    rawFraction: typeof fraction === 'number' ? safeRound(fraction, 6) : null,
                    primaryLabelText: primaryLabelDiagnostics?.label ?? null,
                });
            }
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
    #markCancelled(startedAt, operation, generation, extra = {}) {
        manabiTimelineMeasure(`cacheWarmer.${operation}.cancelled`, startedAt, {
            generation,
            activeGeneration: cacheWarmerWorkGeneration(),
            ...extra,
        }, 0)
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
    markNativeSettledSections(settledSectionHrefs = []) {
        const sections = this.#bookSections();
        const normalizedSettled = new Set(this.#mergeSettledSectionHrefs(settledSectionHrefs));
        for (let index = 0; index < sections.length; index += 1) {
            const section = sections[index];
            const normalizedHref = this.#normalizeSectionHref(section?.href ?? section?.id ?? null);
            if (!normalizedHref || !normalizedSettled.has(normalizedHref)) continue;
            globalThis.__manabiCacheWarmerHighestSectionIndex = Math.max(
                globalThis.__manabiCacheWarmerHighestSectionIndex ?? -1,
                index,
            );
        }
        resolveCacheWarmerPrecedingSectionWaiters();
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
        manabiTimelineMark('cacheWarmer.nativePrewarmSection.start', {
            targetIndex,
            sectionHref,
            minimumIndex,
            settledCount: Array.isArray(settledSectionHrefs) ? settledSectionHrefs.length : 0,
        });
        window.webkit.messageHandlers.ebookNativeCacheWarmerPrewarmSection.postMessage({
            topWindowURL: window.top.location.href,
            sectionHref,
            sectionIndex: targetIndex,
            minimumIndex,
            activeSectionIndex: activeForegroundSectionIndex(),
            requiredPrecedingTargetIndex: cacheWarmerPrecedingTargetIndex(),
            generation: cacheWarmerWorkGeneration(),
        });
    }
    async #openFirstUnsettledSection() {
        const startedAt = performanceNowMs()
        const generation = cacheWarmerWorkGeneration()
        const settledSectionHrefs = this.#mergeSettledSectionHrefs()
        const precedingTargetIndex = cacheWarmerPrecedingTargetIndex()
        const minimumIndex = Number.isInteger(precedingTargetIndex) ? 0 : activeForegroundSectionIndex()
        const firstUnsettledIndex = this.#nextUnsettledSectionIndex(settledSectionHrefs, minimumIndex)
        manabiTimelineMark('cacheWarmer.openFirstUnsettledSection.start', {
            targetIndex: firstUnsettledIndex,
            minimumIndex,
            precedingTargetIndex,
            settledCount: settledSectionHrefs.length,
        })
        try {
            if (!Number.isInteger(firstUnsettledIndex)) {
                globalThis.__manabiCacheWarmerFinished = true
                resolveCacheWarmerPrecedingSectionWaiters()
                return
            }
            await this.view.renderer.goTo({ index: firstUnsettledIndex })
            if (!this.#isCurrentGeneration(generation)) {
                this.#markCancelled(startedAt, 'openFirstUnsettledSection', generation, {
                    targetIndex: firstUnsettledIndex,
                    minimumIndex,
                })
                return
            }
        } finally {
            manabiTimelineMeasure('cacheWarmer.openFirstUnsettledSection', startedAt, {
                targetIndex: firstUnsettledIndex,
                minimumIndex,
                precedingTargetIndex,
                settledCount: settledSectionHrefs.length,
            })
        }
    }
    async loadNextSectionSkippingSettled(settledSectionHrefs = [], minimumIndex = 0) {
        const startedAt = performanceNowMs()
        const generation = cacheWarmerWorkGeneration()
        settledSectionHrefs = this.#mergeSettledSectionHrefs(settledSectionHrefs)
        const targetIndex = this.#nextUnsettledSectionIndex(settledSectionHrefs, minimumIndex)
        manabiTimelineMark('cacheWarmer.loadNextSection.start', {
            targetIndex,
            minimumIndex,
            lastLoadedSectionIndex: this.lastLoadedSectionIndex,
            settledCount: settledSectionHrefs.length,
        })
        let path = 'goTo'
        try {
            if (!Number.isInteger(targetIndex)) {
                path = 'none'
                globalThis.__manabiCacheWarmerFinished = true
                resolveCacheWarmerPrecedingSectionWaiters()
                return
            }
            if (!canUseNativeCacheWarmerPrewarm()) {
                path = 'native-unavailable'
                globalThis.__manabiCacheWarmerFinished = true
                resolveCacheWarmerPrecedingSectionWaiters()
                return
            }
            const busyState = cacheWarmerForegroundBusyState()
            if (busyState.busy) {
                path = `busy:${busyState.reason || 'foreground'}`
                scheduleLoadNextCacheWarmerSection(settledSectionHrefs, `loadNextSection.${path}`)
                return
            }
            path = 'native'
            await this.#prewarmNativeSection(targetIndex, settledSectionHrefs, minimumIndex)
            return
        } finally {
            manabiTimelineMeasure('cacheWarmer.loadNextSection', startedAt, {
                path,
                targetIndex,
                minimumIndex,
                lastLoadedSectionIndex: this.lastLoadedSectionIndex,
                settledCount: settledSectionHrefs.length,
            })
        }
    }
    destroy() {
        invalidateCacheWarmerWork('destroy')
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
        globalThis.__manabiNativeCacheWarmerInFlightSectionHref = null;
        globalThis.__manabiCacheWarmerReady = false;
        globalThis.__manabiCacheWarmerFinished = false;
        globalThis.__manabiCacheWarmerHighestSectionIndex = null;
        globalThis.__manabiCacheWarmerAdvanceInFlight = false;
    }
    async open(file) {
        const startedAt = performanceNowMs()
        this.destroy()
        const generation = invalidateCacheWarmerWork('open')
        manabiTimelineMark('cacheWarmer.open.start', {
            hadView: !!this.view,
            generation,
        })
        globalThis.__manabiCacheWarmerOpenInFlight = true;
        globalThis.__manabiCacheWarmerReady = false;
        globalThis.__manabiCacheWarmerFinished = false;
        globalThis.__manabiCacheWarmerHighestSectionIndex = null;
        globalThis.__manabiDeferredCacheWarmerLogged = false;
        try {
            if (!canUseNativeCacheWarmerPrewarm()) {
                globalThis.__manabiCacheWarmerFinished = true;
                globalThis.__manabiCacheWarmerReady = false;
                resolveCacheWarmerPrecedingSectionWaiters();
                return
            }
            globalThis.__manabiCacheWarmerOpenInFlight = false;
            globalThis.__manabiCacheWarmerReady = true;
            const precedingTargetIndex = cacheWarmerPrecedingTargetIndex()
            const minimumIndex = Number.isInteger(precedingTargetIndex) ? 0 : activeForegroundSectionIndex()
            await this.loadNextSectionSkippingSettled([], minimumIndex)
            return
        } catch (error) {
            ebookLoadLog('cacheWarmer.open.error', {
                error: error?.message || error,
            });
            throw error;
        } finally {
            globalThis.__manabiCacheWarmerOpenInFlight = false;
            manabiTimelineMeasure('cacheWarmer.open', startedAt, {
                ready: !!globalThis.__manabiCacheWarmerReady,
                finished: !!globalThis.__manabiCacheWarmerFinished,
                highestSectionIndex: globalThis.__manabiCacheWarmerHighestSectionIndex ?? null,
            })
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
        const startedAt = performanceNowMs()
        const generation = cacheWarmerWorkGeneration()
        const sentenceNodes = Array.from(doc?.querySelectorAll?.('m-s') || []);
        const indexedSectionHref =
            Number.isInteger(index)
            ? this.view?.book?.sections?.[index]?.href || null
            : null;
        const sourceHref = doc?.body?.dataset?.mnbSourceHref || indexedSectionHref || null;
        const sectionHref = indexedSectionHref || sourceHref || null;
        manabiTimelineMark('cacheWarmer.onLoad.start', {
            sectionIndex: Number.isInteger(index) ? index : null,
            sectionHref,
            location,
        })
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

        let atEnd = null;
        try {
            atEnd = await this.view.renderer.atEnd();
            if (!this.#isCurrentGeneration(generation)) {
                this.#markCancelled(startedAt, 'onLoad', generation, {
                    sectionIndex: Number.isInteger(index) ? index : null,
                    sectionHref,
                    stage: 'after-atEnd',
                })
                return;
            }
            const sectionAdvance = {
                sectionIndex: Number.isInteger(index) ? index : null,
                sectionHref,
                atEnd,
                location,
            };
            this.#finalizeSectionAdvance(sectionAdvance, 'load');
        } finally {
            manabiTimelineMeasure('cacheWarmer.onLoad', startedAt, {
                sectionIndex: Number.isInteger(index) ? index : null,
                sectionHref,
                sentenceCount: sentenceNodes.length,
                uniqueSentenceCount: this.uniqueSentenceIdentifiers.size,
                atEnd,
            })
        }
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
    const normalizedLayoutMode = typeof layoutMode === 'string' && layoutMode.length > 0 ? layoutMode : 'paginated';
    if (globalThis.__manabiEbookViewerLayoutMode === normalizedLayoutMode) {
        applyStoredChromeInsets('setEbookViewerLayout.same');
        return;
    }
    globalThis.__manabiEbookViewerLayoutMode = normalizedLayoutMode;
    invalidateCacheWarmerWork('layout-change')
    // TODO: Add scrolled mode back...
//    globalThis.reader.view.renderer.setAttribute('flow', layoutMode)
    applyStoredChromeInsets('setEbookViewerLayout');
    postEBookSafeAreaTopSnapshot('ebook.safeAreaTop.setLayout', {
        layoutMode,
    });
    globalThis.manabiInvalidateVisiblePageSegmentSnapshot?.('layout-change');
}

window.setEbookViewerWritingDirection = (writingDirection) => {
    const normalizedWritingDirection = 'original';
    if (globalThis.__manabiEbookViewerWritingDirection === normalizedWritingDirection) {
        return;
    }
    globalThis.__manabiEbookViewerWritingDirection = normalizedWritingDirection;
    invalidateCacheWarmerWork('writing-direction-change')
    const renderer = globalThis.reader?.view?.renderer ?? null;
    const contents = renderer?.getContents?.() || [];
    const clearForcedWritingDirection = (doc) => {
        const body = doc?.body;
        if (!body) return false;
        if (body.dataset.mnbForcedWritingDirection) {
            body.classList?.remove?.('reader-vertical-writing');
            doc.documentElement?.classList?.remove?.('vrtl');
            body.removeAttribute('data-mnb-writing-direction');
            body.removeAttribute('data-mnb-foliate-writing-direction');
            body.removeAttribute('data-mnb-foliate-writing-mode');
        }
        body.removeAttribute('data-mnb-forced-writing-direction');
        try {
            doc.defaultView?.manabiApplyVerticalWritingCheck?.();
        } catch (_error) {}
        return true;
    };
    for (const content of contents) {
        clearForcedWritingDirection(content?.doc ?? content?.document ?? null);
    }
    globalThis.manabiInvalidateVisiblePageSegmentSnapshot?.('writing-direction-change');
}

window.loadNextCacheWarmerSection = async (settledSectionHrefs = []) => {
    globalThis.__manabiNativeCacheWarmerInFlightSectionHref = null;
    window.cacheWarmer?.markNativeSettledSections?.(settledSectionHrefs);
    scheduleLoadNextCacheWarmerSection(settledSectionHrefs, 'native-ready');
}

window.loadEBook = ({
    url,
    layoutMode,
    initialRestore,
    readerPresentationState,
}) => {
    const normalizedReaderPresentationState = installReaderPresentationState(readerPresentationState, 'loadEBook');
    const requestedURL = typeof url === 'string' ? url : '';
    globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.incoming', {
        hasInitialRestore: !!initialRestore,
        requestID: typeof initialRestore?.requestID === 'string' ? initialRestore.requestID : null,
        requestedLocator: typeof initialRestore?.requestedLocator === 'string' ? initialRestore.requestedLocator : null,
        incomingFractionType: typeof initialRestore?.fractionalCompletion,
        incomingFractionValue: initialRestore?.fractionalCompletion ?? null,
        incomingCFILength: typeof initialRestore?.cfi === 'string' ? initialRestore.cfi.length : 0,
    });
    const requestedRestoreFraction = coerceRestoreFraction(initialRestore?.fractionalCompletion);
    const effectiveInitialRestore = initialRestore
        ? {
            ...initialRestore,
            ...(requestedRestoreFraction != null ? { fractionalCompletion: requestedRestoreFraction } : {}),
        }
        : null;
    const requestedSyntheticRestore = parseSyntheticRestoreLocator(effectiveInitialRestore?.cfi);
    const requestedSpineOnlySectionIndex = !requestedSyntheticRestore
        ? parseSpineOnlyEpubCFI(effectiveInitialRestore?.cfi)
        : null;
    const hasRequestedSpineOnlyRestore = Number.isInteger(requestedSpineOnlySectionIndex);
    const requestedRestoreCFI = !requestedSyntheticRestore
        && !hasRequestedSpineOnlyRestore
        && typeof effectiveInitialRestore?.cfi === 'string'
        ? effectiveInitialRestore.cfi
        : '';
    const requestedRestoreKind = requestedSyntheticRestore
        ? 'synthetic'
        : (hasRequestedSpineOnlyRestore ? 'spine-cfi' : (requestedRestoreCFI.length > 0 ? 'cfi' : (requestedRestoreFraction != null && requestedRestoreFraction > 0 ? 'fraction' : 'none')));
    globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.normalizedRestore', {
        hasInitialRestore: !!effectiveInitialRestore,
        requestID: typeof effectiveInitialRestore?.requestID === 'string' ? effectiveInitialRestore.requestID : null,
        requestedLocator: typeof effectiveInitialRestore?.requestedLocator === 'string' ? effectiveInitialRestore.requestedLocator : null,
        restoreKind: requestedRestoreKind,
        requestedFraction: requestedRestoreFraction != null ? safeRound(requestedRestoreFraction, 6) : null,
        effectiveFractionType: typeof effectiveInitialRestore?.fractionalCompletion,
        effectiveFractionValue: effectiveInitialRestore?.fractionalCompletion ?? null,
        syntheticSectionIndex: requestedSyntheticRestore?.sectionIndex ?? null,
        spineSectionIndex: requestedSpineOnlySectionIndex ?? null,
        hasSpineOnlyRestore: hasRequestedSpineOnlyRestore,
        hasPreciseCFI: requestedRestoreCFI.length > 0,
    });
    globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.call', {
        hasURL: requestedURL.length > 0,
        layoutMode: layoutMode || null,
        hasInitialRestore: !!effectiveInitialRestore,
        initialCFILength: typeof effectiveInitialRestore?.cfi === 'string' ? effectiveInitialRestore.cfi.length : 0,
        restoreKind: requestedRestoreKind,
        syntheticSectionIndex: requestedSyntheticRestore?.sectionIndex ?? null,
        syntheticLocalPage: requestedSyntheticRestore?.localSectionIndex ?? null,
        syntheticRendererTotal: requestedSyntheticRestore?.rendererTotal ?? null,
        spineSectionIndex: requestedSpineOnlySectionIndex ?? null,
        requestedFraction: requestedRestoreFraction != null ? safeRound(requestedRestoreFraction, 6) : null,
        rawFractionType: typeof initialRestore?.fractionalCompletion,
        rawFractionValue: initialRestore?.fractionalCompletion ?? null,
        existingURLMatches: requestedURL.length > 0 && globalThis.manabiLoadEBookURL === requestedURL,
        existingInFlight: globalThis.manabiLoadEBookInFlight === true,
        existingReady: globalThis.manabiLoadEBookReady === true,
        hasRenderer: !!globalThis.reader?.view?.renderer,
        previousState: globalThis.manabiLoadEBookLastState || null,
    });
    if (
        requestedURL.length > 0
        && globalThis.manabiLoadEBookURL === requestedURL
        && globalThis.manabiLoadEBookInFlight === true
    ) {
        const existingStartedAt = Number(globalThis.manabiLoadEBookStartedAt || 0);
        const existingStartedAgeMs = existingStartedAt > 0 ? Date.now() - existingStartedAt : 0;
        if (globalThis.reader?.view?.renderer || existingStartedAgeMs < 2500) {
            const willQueueInitialRestore = !!effectiveInitialRestore;
            if (willQueueInitialRestore) {
                globalThis.__manabiPendingInitialRestore = effectiveInitialRestore;
            }
            globalThis.manabiLoadEBookLastState = willQueueInitialRestore
                ? 'duplicate-inflight-pending-restore'
                : 'duplicate-inflight';
            globalThis.manabiPendingLoadEBookArgs = null;
            globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.return', {
                path: globalThis.manabiLoadEBookLastState,
                existingStartedAgeMs,
                hasInitialRestore: !!effectiveInitialRestore,
                queuedInitialRestore: willQueueInitialRestore,
                restoreKind: requestedRestoreKind,
                requestedFraction: requestedRestoreFraction != null ? safeRound(requestedRestoreFraction, 6) : null,
                hasRenderer: !!globalThis.reader?.view?.renderer,
            });
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
        globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.return', {
            path: 'duplicate-ready',
            hasInitialRestore: !!effectiveInitialRestore,
            initialRestoreHandled: !!globalThis.__manabiInitialRestoreHandled,
            hasRenderer: !!globalThis.reader?.view?.renderer,
            hasLoadedLastPosition: globalThis.reader?.hasLoadedLastPosition === true,
        });
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
    globalThis.__manabiInitialRestoreResult = null;
    globalThis.manabiPendingLoadEBookArgs = {
        hasURL: typeof url === 'string' && url.length > 0,
        layoutMode: layoutMode || null,
        hasInitialRestore: !!effectiveInitialRestore,
        hasReaderPresentationState: !!normalizedReaderPresentationState,
    };
    resetInitialVisibleWorkReady(`loadEBook:${loadToken}`);
    if (globalThis.__manabiInitialForegroundCriticalSectionToken) {
        finishForegroundCriticalSection(globalThis.__manabiInitialForegroundCriticalSectionToken, 'loadEBook.replace');
        globalThis.__manabiInitialForegroundCriticalSectionToken = null;
    }
    globalThis.__manabiInitialForegroundCriticalSectionToken = beginForegroundCriticalSection(`loadEBook:${loadToken}`);
    const finishInitialForegroundCriticalSection = (reason) => {
        if (globalThis.manabiLoadEBookToken !== loadToken) {
            return;
        }
        const token = globalThis.__manabiInitialForegroundCriticalSectionToken;
        if (!token) {
            return;
        }
        finishForegroundCriticalSection(token, reason);
        if (globalThis.__manabiInitialForegroundCriticalSectionToken === token) {
            globalThis.__manabiInitialForegroundCriticalSectionToken = null;
        }
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
            ebookLoadLog('loadEBook.watchdog', {
                loadToken,
                delayMs,
                lastState: globalThis.manabiLoadEBookLastState || null,
                inFlight: globalThis.manabiLoadEBookInFlight === true,
                ready: globalThis.manabiLoadEBookReady === true,
                hasRenderer: !!globalThis.reader?.view?.renderer,
                inflightReplaceText: globalThis.__manabiInflightReplaceTextCount ?? 0,
                inflightLiveReplaceText: globalThis.__manabiInflightLiveReplaceTextCount ?? 0,
                inflightCacheWarmerReplaceText: globalThis.__manabiInflightCacheWarmerReplaceTextCount ?? 0,
            });
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
            ? Promise.resolve(window.ebookSource).then((source) => {
                return source;
            })
            : fetch(url, {
                headers: {
                    "IS-SWIFTUIWEBVIEW-VIEWER-FILE-REQUEST": "true",
                },
            })
                .then(res => {
                    return res.blob();
                })
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
                globalThis.__manabiEbookViewerLayoutMode = layoutMode
            }
            const pendingInitialRestoreAtOpen = globalThis.__manabiPendingInitialRestore ?? null;
            const initialRestoreForOpen = effectiveInitialRestore;
            globalThis.manabiLoadEBookLastState = 'reader-open-dispatch';
            globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.readerOpen.dispatch', {
                loadToken,
                hasInitialRestore: !!initialRestoreForOpen,
                hasPendingInitialRestore: !!pendingInitialRestoreAtOpen,
                requestID: typeof initialRestoreForOpen?.requestID === 'string' ? initialRestoreForOpen.requestID : null,
                requestedLocator: typeof initialRestoreForOpen?.requestedLocator === 'string' ? initialRestoreForOpen.requestedLocator : null,
                initialCFILength: typeof initialRestoreForOpen?.cfi === 'string' ? initialRestoreForOpen.cfi.length : 0,
                restoreKind: requestedRestoreKind,
                syntheticSectionIndex: requestedSyntheticRestore?.sectionIndex ?? null,
                spineSectionIndex: requestedSpineOnlySectionIndex ?? null,
                requestedFraction: coerceRestoreFraction(initialRestoreForOpen?.fractionalCompletion) != null
                    ? safeRound(coerceRestoreFraction(initialRestoreForOpen?.fractionalCompletion), 6)
                    : null,
            });
            await reader.open(source, {
                initialRestore: initialRestoreForOpen,
                readerPresentationState: normalizedReaderPresentationState,
            })
            if (!reader?.view?.renderer) {
                throw new Error('reader-open-missing-renderer');
            }
            readerLoadLog('viewer.loadEBook.readerOpen.finish', {
                loadToken,
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                hasRenderer: !!reader?.view?.renderer,
                renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            });
            const postOpenLocation = reader?.view?.lastLocation ?? null;
            globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.readerOpen.finish', {
                loadToken,
                hasInitialRestore: !!effectiveInitialRestore,
                initialRestoreHandled: !!globalThis.__manabiInitialRestoreHandled,
                lastLocationFraction: typeof postOpenLocation?.fraction === 'number' ? safeRound(postOpenLocation.fraction, 6) : null,
                lastLocationCurrent: postOpenLocation?.location?.current ?? null,
                lastLocationTotal: postOpenLocation?.location?.total ?? null,
                sectionIndex: typeof postOpenLocation?.section?.current === 'number'
                    ? postOpenLocation.section.current
                    : (typeof postOpenLocation?.sectionIndex === 'number' ? postOpenLocation.sectionIndex : null),
                hasLoadedLastPosition: reader?.hasLoadedLastPosition === true,
            });
            reader.setLoadingIndicator(false, 'readerOpenResolved');
            readerLoadLog('viewer.loadEBook.readerOpen.loadingCleared', {
                loadToken,
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                hasRenderer: !!reader?.view?.renderer,
                renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            });
            if (globalThis.__manabiInitialRestoreHandled) {
                finalizeInitialRestoreHandledWithoutNativeRestore('loadEBook.initialRestoreHandled');
            }
            const pendingInitialRestoreAfterOpen = globalThis.__manabiPendingInitialRestore ?? null;
            if (pendingInitialRestoreAfterOpen) {
                globalThis.__manabiPendingInitialRestore = null;
                const pendingFraction = coerceRestoreFraction(pendingInitialRestoreAfterOpen?.fractionalCompletion);
                globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.pendingRestore.apply', {
                    loadToken,
                    cfiLength: typeof pendingInitialRestoreAfterOpen?.cfi === 'string' ? pendingInitialRestoreAfterOpen.cfi.length : 0,
                    requestedFraction: pendingFraction != null ? safeRound(pendingFraction, 6) : null,
                    initialRestoreHandledBeforeApply: !!globalThis.__manabiInitialRestoreHandled,
                    hasLoadedLastPositionBeforeApply: reader?.hasLoadedLastPosition === true,
                });
                let pendingRestoreSucceeded = false;
                try {
                    await window.loadLastPosition?.({
                        cfi: typeof pendingInitialRestoreAfterOpen?.cfi === 'string' ? pendingInitialRestoreAfterOpen.cfi : '',
                        fractionalCompletion: pendingInitialRestoreAfterOpen?.fractionalCompletion,
                    });
                    pendingRestoreSucceeded = globalThis.reader?.hasLoadedLastPosition === true
                        && !!globalThis.__manabiInitialRestoreHandled;
                } catch (error) {
                    readerLoadLog('viewer.loadEBook.pendingRestore.error', {
                        loadToken,
                        error: error?.message || String(error),
                    });
                }
                globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.pendingRestore.finish', {
                    loadToken,
                    restored: pendingRestoreSucceeded,
                    initialRestoreHandledAfterApply: !!globalThis.__manabiInitialRestoreHandled,
                    hasLoadedLastPositionAfterApply: globalThis.reader?.hasLoadedLastPosition === true,
                    currentFraction: typeof globalThis.reader?.view?.lastLocation?.fraction === 'number'
                        ? safeRound(globalThis.reader.view.lastLocation.fraction, 6)
                        : null,
                });
            }
            if (initialRestoreForOpen && !globalThis.__manabiInitialRestoreHandled) {
                const postOpenLocation = reader?.view?.lastLocation ?? null;
                globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.initialRestore.notHandledAfterOpen', {
                    loadToken,
                    restoreKind: requestedRestoreKind,
                    requestedFraction: requestedRestoreFraction != null ? safeRound(requestedRestoreFraction, 6) : null,
                    currentFraction: typeof postOpenLocation?.fraction === 'number' ? safeRound(postOpenLocation.fraction, 6) : null,
                    currentSectionIndex: typeof postOpenLocation?.section?.current === 'number'
                        ? postOpenLocation.section.current
                        : (typeof postOpenLocation?.sectionIndex === 'number' ? postOpenLocation.sectionIndex : null),
                    hasLoadedLastPosition: reader?.hasLoadedLastPosition === true,
                    action: 'reportOnly',
                });
            }
        })
        .then(async () => {
            if (globalThis.manabiLoadEBookToken !== loadToken) return;
            globalThis.reader = reader;
            finishLoadWatchdogs();
            globalThis.manabiLoadEBookReady = true;
            globalThis.manabiLoadEBookLastState = 'reader-open-resolved';
            const initialRestoreResult = globalThis.__manabiInitialRestoreResult ?? null;
            const liveLoadedFraction = manabiFractionFromLocation(globalThis.reader?.view?.lastLocation ?? null);
            const initialRestoreCurrentFraction = initialRestoreResult?.currentFraction ?? liveLoadedFraction;
            const initialRestoreHandledFraction = initialRestoreResult?.handledFractionalCompletion
                ?? (initialRestoreResult?.restoreSatisfied === true ? initialRestoreCurrentFraction : null);
            const probe = globalThis.reader?.collectLayoutGapProbe?.('ebookViewerLoaded', {
                bookDir: globalThis.reader?.bookDir || null,
                isRTL: !!globalThis.reader?.isRTL,
            }) ?? null;
            window.webkit.messageHandlers.ebookViewerLoaded.postMessage({
                probe,
                initialRestoreResult,
                initialRestoreHandled: initialRestoreResult?.restoreSatisfied ?? false,
                initialRestoreCurrentFractionalCompletion: initialRestoreCurrentFraction,
                initialRestoreFractionalCompletion: initialRestoreHandledFraction,
            })
        })
        .catch((error) => {
            if (globalThis.manabiLoadEBookToken !== loadToken) {
                return;
            }
            finishInitialForegroundCriticalSection('loadEBook.error');
            finishLoadWatchdogs();
            globalThis.manabiLoadEBookReady = false;
            globalThis.manabiLoadEBookLastState = `open-error:${error?.message || String(error)}`;
            ebookLoadLog('loadEBook.error', {
                loadToken,
                requestedURL,
                error: error?.message || String(error),
                lastState: globalThis.manabiLoadEBookLastState,
            });
            readerLoadLog('loadEBook.error', {
                loadToken,
                error: error?.message || String(error),
                errorName: error?.name ?? null,
                lastState: globalThis.manabiLoadEBookLastState,
                stack: typeof error?.stack === 'string' ? error.stack.slice(0, 800) : null,
            });
            if (globalThis.reader === reader || !globalThis.reader?.view?.renderer) {
                globalThis.reader = previousReader ?? null;
            }
            try {
                reader?.setLoadingIndicator?.(false, 'loadEBook.error');
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
        finishInitialForegroundCriticalSection('loadEBook.no-url');
        finishLoadWatchdogs();
        globalThis.manabiLoadEBookReady = false;
        globalThis.manabiLoadEBookLastState = 'no-url';
        globalThis.manabiPendingLoadEBookArgs = null;
        globalThis.manabiLoadEBookInFlight = false;
        globalThis.manabiLoadEBookPromise = null;
    }
    //.catch(e => console.error(e))
}

const markRestorePositionSaveUserInput = (source = 'unknown') => {
    if (globalThis.__manabiRequireUserInputBeforePositionSave !== true) {
        return;
    }
    globalThis.__manabiRequireUserInputBeforePositionSave = false;
    globalThis.__manabiSuppressNextRestoreRelocateSave = false;
};

const markRestorePositionSavePageTurnInput = (source = 'page-turn') => {
    markRestorePositionSaveUserInput(source);
};

const ensureRestorePositionSaveUserInputTracking = () => {
    if (globalThis.__manabiRestoreUserInputTrackingInstalled === true) {
        return;
    }
    globalThis.__manabiRestoreUserInputTrackingInstalled = true;
    for (const eventName of ['pointerdown', 'touchstart', 'wheel', 'keydown', 'click']) {
        window.addEventListener(eventName, (event) => {
            markRestorePositionSaveUserInput(`window.${event?.type ?? eventName}`);
        }, {
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

const finalizeInitialRestoreHandledWithoutNativeRestore = (reason = 'loadEBook.initialRestoreHandled') => {
    const handled = globalThis.__manabiInitialRestoreHandled ?? null;
    if (!handled || !globalThis.reader?.view?.renderer) {
        return false;
    }
    ensureRestorePositionSaveUserInputTracking();
    globalThis.reader.hasLoadedLastPosition = true;
    globalThis.__manabiSuppressNextRestoreRelocateSave = true;
    globalThis.__manabiRequireUserInputBeforePositionSave = true;
    globalThis.__manabiRestoreInProgress = false;
    if (document.querySelector?.('foliate-view')) {
        markReaderRenderReady(reason);
    }
    globalThis.reader.refreshNativeMarkReadState?.(`${reason}.markRead`);
    scheduleDeferredCacheWarmerOpen(`${reason}.cacheWarmer`);
    readerLoadLog('viewer.initialRestore.finalized', {
        reason,
        sectionIndex: handled.sectionIndex ?? null,
        bodyLoading: !!document.body?.classList?.contains?.('loading'),
        hasReaderContent: !!document.querySelector?.('foliate-view'),
        renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
    });
    globalThis.__manabiRestoreDebugLog?.('ebook.initialRestore.finalized', {
        reason,
        sectionIndex: handled.sectionIndex ?? null,
        localSectionIndex: handled.localSectionIndex ?? null,
        rendererTotal: handled.rendererTotal ?? null,
        fractionalCompletion: Number.isFinite(handled.fractionalCompletion) ? safeRound(handled.fractionalCompletion, 6) : null,
        cfiLength: typeof handled.cfi === 'string' ? handled.cfi.length : 0,
        hasLoadedLastPosition: globalThis.reader?.hasLoadedLastPosition === true,
        suppressNextSave: globalThis.__manabiSuppressNextRestoreRelocateSave === true,
        requireUserInputBeforeSave: globalThis.__manabiRequireUserInputBeforePositionSave === true,
    });
    return true;
};

window.loadLastPosition = async ({
    cfi,
    fractionalCompletion,
}) => {
    ensureRestorePositionSaveUserInputTracking();
    globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.incoming', {
        incomingFractionType: typeof fractionalCompletion,
        incomingFractionValue: fractionalCompletion ?? null,
        incomingCFILength: typeof cfi === 'string' ? cfi.length : 0,
    });
    fractionalCompletion = coerceRestoreFraction(fractionalCompletion);
    globalThis.__manabiRequestedRestoreFraction = Number.isFinite(fractionalCompletion)
        ? Math.max(0, Math.min(1, fractionalCompletion))
        : null;
    globalThis.__manabiRestoreInProgress = true;
    const restoreNavigationTimeoutMs = 45000;
    const restoreStateSettleTimeoutMs = 45000;
    const runRestoreNavigation = async (
        intent,
        operation,
        {
            timeoutMs = restoreNavigationTimeoutMs,
            throwOnError = true,
        } = {},
    ) => {
        const startedAt = performanceNowMs();
        readerLoadLog('viewer.loadLastPosition.navigation.start', {
            source: intent?.source ?? null,
            target: intent?.target ?? null,
            timeoutMs,
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
            hasReaderContent: !!document.querySelector?.('foliate-view'),
            renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
        });
        const watchdogDelaysMs = Number.isFinite(timeoutMs) && timeoutMs > 0
            ? []
            : [10000, 30000, 60000, 120000];
        const watchdogHandles = watchdogDelaysMs.map((delayMs) => setTimeout(() => {
            readerLoadLog('viewer.loadLastPosition.navigation.watchdog', {
                source: intent?.source ?? null,
                target: intent?.target ?? null,
                delayMs,
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                hasReaderContent: !!document.querySelector?.('foliate-view'),
                renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            });
        }, delayMs));
        try {
            const result = await runWithNavigationIntent(intent, operation, { timeoutMs });
            readerLoadLog('viewer.loadLastPosition.navigation.finish', {
                source: intent?.source ?? null,
                target: intent?.target ?? null,
                elapsedMs: safeRound(performanceNowMs() - startedAt, 1),
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                hasReaderContent: !!document.querySelector?.('foliate-view'),
                renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            });
            return {
                ok: true,
                result,
            };
        } catch (error) {
            readerLoadLog('viewer.loadLastPosition.navigation.error', {
                source: intent?.source ?? null,
                target: intent?.target ?? null,
                elapsedMs: safeRound(performanceNowMs() - startedAt, 1),
                error: error?.message || String(error),
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                hasReaderContent: !!document.querySelector?.('foliate-view'),
                renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            });
            if (throwOnError) {
                throw error;
            }
            return {
                ok: false,
                error,
            };
        } finally {
            watchdogHandles.forEach((handle) => clearTimeout(handle));
        }
    };
    const waitForFrames = async (count = 2) => {
        for (let index = 0; index < count; index += 1) {
            await new Promise((resolve) => requestAnimationFrame(() => resolve()));
        }
    };
    const waitForPaintAfterNavigation = async () => {
        await waitForFrames(2);
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
    const restoreStateHasUsableLocation = (state) => {
        if (!state) return false;
        if (hasFractionalCompletion) {
            return typeof state.currentFraction === 'number';
        }
        return typeof state.currentFraction === 'number'
            || typeof state.sectionIndex === 'number'
            || typeof state.locationCurrent === 'number';
    };
    const restoreStateFractionSatisfied = (state) => !hasFractionalCompletion
        || (
            typeof state?.currentFraction === 'number'
            && Math.abs(state.currentFraction - fractionalCompletion) <= 0.003
        );
    const waitForRestoreStateIfNeeded = async (
        state,
        reason,
        stage,
        {
            requireFractionSatisfied = false,
            timeoutMs = restoreStateSettleTimeoutMs,
        } = {},
    ) => {
        if (
            restoreStateHasUsableLocation(state)
            && (!requireFractionSatisfied || restoreStateFractionSatisfied(state))
        ) {
            return state;
        }
        globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.restoreState.wait.start', {
            reason,
            stage,
            timeoutMs,
            requireFractionSatisfied,
            requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
            currentFraction: typeof state?.currentFraction === 'number' ? safeRound(state.currentFraction, 6) : null,
            currentSectionIndex: state?.sectionIndex ?? null,
            locationCurrent: state?.locationCurrent ?? null,
            locationTotal: state?.locationTotal ?? null,
            renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
        });
        let waitResult = null;
        if (typeof globalThis.reader?.waitForNextDisplaySettled === 'function') {
            try {
                waitResult = await globalThis.reader.waitForNextDisplaySettled(reason, { timeoutMs });
            } catch (error) {
                readerLoadLog('viewer.loadLastPosition.restoreState.wait.error', {
                    reason,
                    stage,
                    timeoutMs,
                    error: error?.message || String(error),
                    bodyLoading: !!document.body?.classList?.contains?.('loading'),
                    hasReaderContent: !!document.querySelector?.('foliate-view'),
                    renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
                });
            }
        }
        await waitForPaintAfterNavigation();
        const waitedState = captureRestoreState(stage, {
            waitedForDisplay: !!waitResult,
        });
        globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.restoreState.wait.finish', {
            reason,
            stage,
            settledReason: waitResult?.reason ?? null,
            requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
            currentFraction: typeof waitedState.currentFraction === 'number' ? safeRound(waitedState.currentFraction, 6) : null,
            currentSectionIndex: waitedState.sectionIndex ?? null,
            locationCurrent: waitedState.locationCurrent ?? null,
            locationTotal: waitedState.locationTotal ?? null,
            locationUsable: restoreStateHasUsableLocation(waitedState),
            fractionSatisfied: restoreStateFractionSatisfied(waitedState),
            renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
        });
        return waitedState;
    };
    const syntheticRestoreLocator = parseSyntheticRestoreLocator(cfi);
    const spineOnlyRestoreSectionIndex = !syntheticRestoreLocator
        ? parseSpineOnlyEpubCFI(cfi)
        : null;
    const hasPreciseCFI = typeof cfi === 'string'
        && cfi.length > 0
        && !syntheticRestoreLocator
        && !Number.isInteger(spineOnlyRestoreSectionIndex);
    const restoreLocatorKind = syntheticRestoreLocator
        ? 'synthetic'
        : (Number.isInteger(spineOnlyRestoreSectionIndex) ? 'spine-cfi' : (hasPreciseCFI ? 'cfi' : (hasFractionalCompletion ? 'fraction' : 'none')));
    globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.normalizedRestore', {
        restoreLocatorKind,
        cfiLength: typeof cfi === 'string' ? cfi.length : 0,
        requestedFraction: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
        hasFractionalCompletion,
        syntheticSectionIndex: syntheticRestoreLocator?.sectionIndex ?? null,
        syntheticLocalPage: syntheticRestoreLocator?.localSectionIndex ?? null,
        syntheticRendererTotal: syntheticRestoreLocator?.rendererTotal ?? null,
        spineSectionIndex: spineOnlyRestoreSectionIndex ?? null,
        hasPreciseCFI,
        hasSpineOnlyCFI: Number.isInteger(spineOnlyRestoreSectionIndex),
        requestedDisplayPercent: Number.isFinite(fractionalCompletion) ? roundedDisplayPercent(fractionalCompletion) : null,
    });
    globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.start', {
        restoreLocatorKind,
        cfiLength: typeof cfi === 'string' ? cfi.length : 0,
        requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
        syntheticSectionIndex: syntheticRestoreLocator?.sectionIndex ?? null,
        syntheticLocalPage: syntheticRestoreLocator?.localSectionIndex ?? null,
        syntheticRendererTotal: syntheticRestoreLocator?.rendererTotal ?? null,
        spineSectionIndex: spineOnlyRestoreSectionIndex ?? null,
        initialRestoreHandled: !!globalThis.__manabiInitialRestoreHandled,
        hasLoadedLastPosition: globalThis.reader?.hasLoadedLastPosition === true,
        restoreInProgress: globalThis.__manabiRestoreInProgress === true,
    });
    let shouldKeepRestoreSaveGuard = false;
    const releaseDispatchedNavigation = (reason, {
        markReadyReason = null,
    } = {}) => {
        globalThis.reader.hasLoadedLastPosition = true;
        globalThis.__manabiRestoreInProgress = false;
        globalThis.__manabiSuppressNextRestoreRelocateSave = true;
        globalThis.__manabiRequireUserInputBeforePositionSave = true;
        shouldKeepRestoreSaveGuard = true;
        if (markReadyReason && document.querySelector?.('foliate-view')) {
            markReaderRenderReady(markReadyReason);
        }
        globalThis.reader?.setLoadingIndicator?.(false, reason);
        readerLoadLog('viewer.loadLastPosition.dispatchedNavigation.released', {
            reason,
            markReadyReason,
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
            hasReaderContent: !!document.querySelector?.('foliate-view'),
            renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            restoreLocatorKind,
        });
    };
    const clearDispatchedNavigationLoading = (reason) => {
        globalThis.reader?.setLoadingIndicator?.(false, reason);
        readerLoadLog('viewer.loadLastPosition.dispatchedNavigation.loadingCleared', {
            reason,
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
            hasReaderContent: !!document.querySelector?.('foliate-view'),
            renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            restoreLocatorKind,
        });
    };
    const reconcileRestoreFractionIfNeeded = async (restoreState, reason, stageOnReconcile) => {
        if (!hasFractionalCompletion) {
            return;
        }
        const hasCurrentFraction = typeof restoreState?.currentFraction === 'number';
        const delta = hasCurrentFraction
            ? Math.abs(restoreState.currentFraction - fractionalCompletion)
            : Number.POSITIVE_INFINITY;
        const requestedDisplayPercent = roundedDisplayPercent(fractionalCompletion);
        const landedDisplayPercent = hasCurrentFraction
            ? roundedDisplayPercent(restoreState.currentFraction)
            : null;
        const displayPercentChanged = requestedDisplayPercent != null
            && landedDisplayPercent != null
            && requestedDisplayPercent !== landedDisplayPercent;
        if (hasCurrentFraction && delta <= 0.003 && !displayPercentChanged) {
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
        await runRestoreNavigation({
            source: 'restore.reconcile',
            reason,
            target: 'view.goToFraction',
            fraction: fractionalCompletion,
            stageOnReconcile,
        }, () => globalThis.reader.view.goToFraction(fractionalCompletion), {
            throwOnError: false,
        });
        await waitForFrames(2);
        const reconciledState = captureRestoreState(stageOnReconcile, {
            drift: Number.isFinite(delta) ? safeRound(delta, 6) : null,
            missingCurrentFraction: !hasCurrentFraction,
        });
        return waitForRestoreStateIfNeeded(
            reconciledState,
            `restore.reconcile.${reason}`,
            stageOnReconcile,
            { requireFractionSatisfied: true },
        );
    };
    try {
        let syntheticDisplaySettledForRestore = false;
        const initialRestoreHandled = globalThis.__manabiInitialRestoreHandled ?? null;
        const hasExplicitRestoreTarget = !!syntheticRestoreLocator
            || hasFractionalCompletion
            || hasPreciseCFI
            || Number.isInteger(spineOnlyRestoreSectionIndex);
        globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.initialRestoreStaleCheck', {
            hasInitialRestoreHandled: !!initialRestoreHandled,
            hasExplicitRestoreTarget,
            willConsiderStaleNativeCall: !!initialRestoreHandled && !hasExplicitRestoreTarget,
            restoreLocatorKind,
            hasReaderContent: !!document.querySelector?.('foliate-view'),
        });
        if (
            initialRestoreHandled
            && !hasExplicitRestoreTarget
            && document.querySelector?.('foliate-view')
            && finalizeInitialRestoreHandledWithoutNativeRestore('loadLastPosition.initialRestoreStaleNativeCall')
        ) {
            shouldKeepRestoreSaveGuard = true;
            globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.return', {
                path: 'initialRestoreStaleNativeCall',
                restoreLocatorKind,
                handledSectionIndex: initialRestoreHandled.sectionIndex ?? null,
                handledFraction: Number.isFinite(initialRestoreHandled.fractionalCompletion) ? safeRound(initialRestoreHandled.fractionalCompletion, 6) : null,
            });
            readerLoadLog('viewer.loadLastPosition.initialRestoreStaleNativeCall', {
                restoreLocatorKind,
                sectionIndex: initialRestoreHandled.sectionIndex ?? null,
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                hasReaderContent: !!document.querySelector?.('foliate-view'),
                renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            });
            return;
        }
        const initialRestoreCfiMatches = typeof cfi === 'string'
            && cfi.length > 0
            && initialRestoreHandled?.cfi === cfi;
        const initialRestoreFractionMatches = !hasFractionalCompletion
            || (
                Number.isFinite(initialRestoreHandled?.fractionalCompletion)
                && Math.abs(initialRestoreHandled.fractionalCompletion - fractionalCompletion) <= 0.003
            );
        const initialState = initialRestoreHandled
            ? captureRestoreState('initial-restore-already-handled', {
                sectionIndex: initialRestoreHandled.sectionIndex ?? null,
            })
            : null;
        const initialRestoreCurrentFractionMatches = !hasFractionalCompletion
            || (
                typeof initialState?.currentFraction === 'number'
                && Math.abs(initialState.currentFraction - fractionalCompletion) <= 0.003
            );
        const initialRestoreHandledFractionDelta = hasFractionalCompletion && Number.isFinite(initialRestoreHandled?.fractionalCompletion)
            ? Math.abs(initialRestoreHandled.fractionalCompletion - fractionalCompletion)
            : null;
        const initialRestoreCurrentFractionDelta = hasFractionalCompletion && typeof initialState?.currentFraction === 'number'
            ? Math.abs(initialState.currentFraction - fractionalCompletion)
            : null;
        globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.initialRestoreHandledCheck', {
            hasInitialRestoreHandled: !!initialRestoreHandled,
            hasExplicitRestoreTarget,
            cfiMatches: initialRestoreCfiMatches,
            fractionMatches: initialRestoreFractionMatches,
            currentFractionMatches: initialRestoreCurrentFractionMatches,
            handledFraction: Number.isFinite(initialRestoreHandled?.fractionalCompletion) ? safeRound(initialRestoreHandled.fractionalCompletion, 6) : null,
            currentFraction: typeof initialState?.currentFraction === 'number' ? safeRound(initialState.currentFraction, 6) : null,
            requestedFraction: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
            handledFractionDelta: initialRestoreHandledFractionDelta != null ? safeRound(initialRestoreHandledFractionDelta, 6) : null,
            currentFractionDelta: initialRestoreCurrentFractionDelta != null ? safeRound(initialRestoreCurrentFractionDelta, 6) : null,
            currentSectionIndex: initialState?.sectionIndex ?? null,
            handledSectionIndex: initialRestoreHandled?.sectionIndex ?? null,
        });
        if (
            initialRestoreHandled
            && initialRestoreCfiMatches
            && initialRestoreFractionMatches
            && initialRestoreCurrentFractionMatches
            && document.querySelector?.('foliate-view')
        ) {
            globalThis.reader.hasLoadedLastPosition = true;
            globalThis.__manabiSuppressNextRestoreRelocateSave = true;
            globalThis.__manabiRequireUserInputBeforePositionSave = true;
            shouldKeepRestoreSaveGuard = true;
            markReaderRenderReady('loadLastPosition.initialRestoreAlreadyHandled');
            globalThis.reader?.maybeFlashInitialForwardSideNavChevron?.(initialState);
            globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.return', {
                path: 'initialRestoreAlreadyHandled',
                restoreLocatorKind,
                handledSectionIndex: initialRestoreHandled.sectionIndex ?? null,
                handledFraction: Number.isFinite(initialRestoreHandled.fractionalCompletion) ? safeRound(initialRestoreHandled.fractionalCompletion, 6) : null,
                currentFraction: typeof initialState?.currentFraction === 'number' ? safeRound(initialState.currentFraction, 6) : null,
                currentSectionIndex: initialState?.sectionIndex ?? null,
            });
            readerLoadLog('viewer.loadLastPosition.initialRestoreAlreadyHandled', {
                restoreLocatorKind,
                sectionIndex: initialRestoreHandled.sectionIndex ?? null,
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                hasReaderContent: !!document.querySelector?.('foliate-view'),
                renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            });
            scheduleDeferredCacheWarmerOpen('load-last-position-initial-restore-handled');
            return;
        }
        readerLoadLog('viewer.loadLastPosition.initialDisplayBypassed', {
            reason: syntheticRestoreLocator
                ? 'synthetic-restore'
                : (Number.isInteger(spineOnlyRestoreSectionIndex) ? 'spine-cfi-restore' : (hasFractionalCompletion ? 'fraction-restore' : (hasPreciseCFI ? 'cfi-restore' : 'default-position'))),
            initialDisplaySettled: globalThis.reader?.initialDisplaySettled === true,
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
            hasReaderContent: !!document.querySelector?.('foliate-view'),
            renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            restoreLocatorKind,
        });
        if (syntheticRestoreLocator) {
            globalThis.__manabiSuppressNextRestoreRelocateSave = true;
            globalThis.__manabiRequireUserInputBeforePositionSave = true;
            shouldKeepRestoreSaveGuard = true;
            const navigationResult = await runRestoreNavigation({
                source: 'restore.synthetic-locator',
                target: 'renderer.goTo',
                sectionIndex: syntheticRestoreLocator.sectionIndex,
                localPage: syntheticRestoreLocator.localSectionIndex,
                rendererTotal: syntheticRestoreLocator.rendererTotal,
                fraction: hasFractionalCompletion ? fractionalCompletion : null,
            }, () => globalThis.reader.view.renderer.goTo?.({
                index: syntheticRestoreLocator.sectionIndex,
                localPage: syntheticRestoreLocator.localSectionIndex,
            }), {
                throwOnError: false,
            });
            syntheticDisplaySettledForRestore = navigationResult?.ok === true || !!document.querySelector?.('foliate-view');
            readerLoadLog('viewer.loadLastPosition.syntheticLocatorSkipped', {
                reason: 'synthetic-renderer-go-to',
                sectionIndex: syntheticRestoreLocator.sectionIndex,
                suppressedFractionalAnchor: syntheticRestoreLocator.fractionInSection,
                syntheticLocalSectionIndex: syntheticRestoreLocator.localSectionIndex,
                syntheticRendererTotal: syntheticRestoreLocator.rendererTotal,
                fraction: hasFractionalCompletion ? fractionalCompletion : null,
                displayHandled: navigationResult?.ok === true,
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                hasReaderContent: !!document.querySelector?.('foliate-view'),
                renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            });
            await waitForPaintAfterNavigation();
            releaseDispatchedNavigation('loadLastPosition.syntheticNavigation.release', {
                markReadyReason: 'loadLastPosition.syntheticNavigationSettled',
            });
            const syntheticState = captureRestoreState('after-synthetic-locator', {
                sectionIndex: syntheticRestoreLocator.sectionIndex,
                localSectionIndex: syntheticRestoreLocator.localSectionIndex,
                rendererTotal: syntheticRestoreLocator.rendererTotal,
                navigationOk: syntheticDisplaySettledForRestore,
                navigationPending: false,
            });
            globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.path.finish', {
                path: 'synthetic',
                navigationOk: syntheticDisplaySettledForRestore,
                requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
                currentFraction: typeof syntheticState.currentFraction === 'number' ? safeRound(syntheticState.currentFraction, 6) : null,
                currentSectionIndex: syntheticState.sectionIndex ?? null,
                locationCurrent: syntheticState.locationCurrent ?? null,
                locationTotal: syntheticState.locationTotal ?? null,
            });
        } else if (Number.isInteger(spineOnlyRestoreSectionIndex)) {
            globalThis.__manabiSuppressNextRestoreRelocateSave = true;
            globalThis.__manabiRequireUserInputBeforePositionSave = true;
            shouldKeepRestoreSaveGuard = true;
            const navigationResult = await runRestoreNavigation({
                source: hasFractionalCompletion ? 'restore.spine-cfi-fraction' : 'restore.spine-cfi',
                target: hasFractionalCompletion ? 'view.goToFraction' : 'renderer.goTo',
                sectionIndex: spineOnlyRestoreSectionIndex,
                cfiLength: typeof cfi === 'string' ? cfi.length : 0,
                fraction: hasFractionalCompletion ? fractionalCompletion : null,
            }, async () => {
                if (hasFractionalCompletion) {
                    return globalThis.reader.view.goToFraction(fractionalCompletion);
                }
                return globalThis.reader.view.renderer.goTo?.({
                    index: spineOnlyRestoreSectionIndex,
                });
            }, {
                throwOnError: false,
            });
            if (navigationResult?.ok !== true && hasFractionalCompletion) {
                await runRestoreNavigation({
                    source: 'restore.spine-cfi-section-fallback',
                    target: 'renderer.goTo',
                    sectionIndex: spineOnlyRestoreSectionIndex,
                    cfiLength: typeof cfi === 'string' ? cfi.length : 0,
                    fraction: fractionalCompletion,
                }, () => globalThis.reader.view.renderer.goTo?.({
                    index: spineOnlyRestoreSectionIndex,
                }), {
                    throwOnError: false,
                });
            }
            await waitForPaintAfterNavigation();
            const spineState = await waitForRestoreStateIfNeeded(
                captureRestoreState('after-spine-cfi'),
                'restore.spine-cfi.after-navigation',
                'after-spine-cfi',
                { requireFractionSatisfied: hasFractionalCompletion },
            );
            const reconciledSpineState = await reconcileRestoreFractionIfNeeded(
                spineState,
                'spine-cfi-fraction-drift',
                'after-spine-cfi-fraction-reconcile',
            );
            const finalSpineState = await waitForRestoreStateIfNeeded(
                reconciledSpineState ?? captureRestoreState('after-spine-cfi-final'),
                'restore.spine-cfi.final',
                'after-spine-cfi-final',
                { requireFractionSatisfied: hasFractionalCompletion },
            );
            globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.path.finish', {
                path: 'spine-cfi',
                cfiLength: typeof cfi === 'string' ? cfi.length : 0,
                sectionIndex: spineOnlyRestoreSectionIndex,
                requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
                currentFraction: typeof finalSpineState.currentFraction === 'number' ? safeRound(finalSpineState.currentFraction, 6) : null,
                currentSectionIndex: finalSpineState.sectionIndex ?? null,
                locationCurrent: finalSpineState.locationCurrent ?? null,
                locationTotal: finalSpineState.locationTotal ?? null,
            });
        } else if (hasPreciseCFI) {
            globalThis.__manabiSuppressNextRestoreRelocateSave = true;
            globalThis.__manabiRequireUserInputBeforePositionSave = true;
            shouldKeepRestoreSaveGuard = true;
            const navigationResult = await runRestoreNavigation({
                source: 'restore.cfi',
                target: 'view.goTo',
                cfiLength: cfi.length,
                fraction: hasFractionalCompletion ? fractionalCompletion : null,
            }, () => globalThis.reader.view.goTo(cfi), {
                throwOnError: false,
            });
            if (navigationResult?.ok !== true) {
                const error = navigationResult?.error;
                console.error(error)
                globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.cfi.error', {
                    cfiLength: cfi.length,
                    spineSectionIndex: spineOnlyRestoreSectionIndex ?? null,
                    requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
                    error: error?.message || String(error),
                });
                if (Number.isInteger(spineOnlyRestoreSectionIndex)) {
                    await runRestoreNavigation({
                        source: 'restore.cfi-spine-fallback',
                        target: 'renderer.goTo',
                        sectionIndex: spineOnlyRestoreSectionIndex,
                        cfiLength: cfi.length,
                        fraction: hasFractionalCompletion ? fractionalCompletion : null,
                    }, async () => {
                        const result = await globalThis.reader.view.renderer.goTo?.({
                            index: spineOnlyRestoreSectionIndex,
                        });
                        if (hasFractionalCompletion) {
                            await globalThis.reader.view.goToFraction(fractionalCompletion);
                        }
                        return result;
                    }, {
                        throwOnError: false,
                    });
                } else if (hasFractionalCompletion) {
                    await runRestoreNavigation({
                        source: 'restore.cfi-fraction-fallback',
                        target: 'view.goToFraction',
                        fraction: fractionalCompletion,
                    }, () => globalThis.reader.view.goToFraction(fractionalCompletion));
                }
            }
            await waitForPaintAfterNavigation();
            const cfiState = await waitForRestoreStateIfNeeded(
                captureRestoreState('after-cfi'),
                'restore.cfi.after-navigation',
                'after-cfi',
                { requireFractionSatisfied: hasFractionalCompletion },
            );
            const reconciledCfiState = await reconcileRestoreFractionIfNeeded(
                cfiState,
                'cfi-fraction-drift',
                'after-cfi-fraction-reconcile',
            );
            const finalCfiState = await waitForRestoreStateIfNeeded(
                reconciledCfiState ?? captureRestoreState('after-cfi-final'),
                'restore.cfi.final',
                'after-cfi-final',
                { requireFractionSatisfied: hasFractionalCompletion },
            );
            globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.path.finish', {
                path: 'cfi',
                cfiLength: cfi.length,
                requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
                currentFraction: typeof finalCfiState.currentFraction === 'number' ? safeRound(finalCfiState.currentFraction, 6) : null,
                currentSectionIndex: finalCfiState.sectionIndex ?? null,
                locationCurrent: finalCfiState.locationCurrent ?? null,
                locationTotal: finalCfiState.locationTotal ?? null,
            });
        } else if (hasFractionalCompletion) {
            try {
                globalThis.__manabiSuppressNextRestoreRelocateSave = true;
                globalThis.__manabiRequireUserInputBeforePositionSave = true;
                shouldKeepRestoreSaveGuard = true;
                await runRestoreNavigation({
                    source: 'restore.fraction',
                    target: 'view.goToFraction',
                    fraction: fractionalCompletion,
                }, () => globalThis.reader.view.goToFraction(fractionalCompletion));
                await waitForPaintAfterNavigation();
                const fractionState = await waitForRestoreStateIfNeeded(
                    captureRestoreState('after-fraction'),
                    'restore.fraction.after-navigation',
                    'after-fraction',
                    { requireFractionSatisfied: true },
                );
                globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.path.finish', {
                    path: 'fraction',
                    requestedFraction: safeRound(fractionalCompletion, 6),
                    currentFraction: typeof fractionState.currentFraction === 'number' ? safeRound(fractionState.currentFraction, 6) : null,
                    currentSectionIndex: fractionState.sectionIndex ?? null,
                    locationCurrent: fractionState.locationCurrent ?? null,
                    locationTotal: fractionState.locationTotal ?? null,
                });
            } catch (error) {
                readerLoadLog('viewer.loadLastPosition.fractionRestoreSkipped', {
                    reason: 'restore-fraction-failed',
                    error: error?.message || String(error),
                    bodyLoading: !!document.body?.classList?.contains?.('loading'),
                    hasReaderContent: !!document.querySelector?.('foliate-view'),
                    renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
                });
                const fallbackState = captureRestoreState('after-fraction-restore-skipped');
                globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.path.error', {
                    path: 'fraction',
                    error: error?.message || String(error),
                    currentFraction: typeof fallbackState.currentFraction === 'number' ? safeRound(fallbackState.currentFraction, 6) : null,
                    currentSectionIndex: fallbackState.sectionIndex ?? null,
                });
            }
        } else {
            readerLoadLog('viewer.loadLastPosition.noRestoreTarget', {
                bodyLoading: !!document.body?.classList?.contains?.('loading'),
                hasReaderContent: !!document.querySelector?.('foliate-view'),
                renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            });
            await globalThis.reader?.displayInitialSection?.('loadLastPosition.noRestoreTarget');
            const defaultState = captureRestoreState('after-no-restore-target');
            globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.path.finish', {
                path: 'default',
                currentFraction: typeof defaultState.currentFraction === 'number' ? safeRound(defaultState.currentFraction, 6) : null,
                currentSectionIndex: defaultState.sectionIndex ?? null,
                locationCurrent: defaultState.locationCurrent ?? null,
                locationTotal: defaultState.locationTotal ?? null,
            });
        }
        const doneState = await waitForRestoreStateIfNeeded(
            captureRestoreState('done'),
            'loadLastPosition.done',
            'done',
            { requireFractionSatisfied: hasFractionalCompletion },
        );
        const doneHasUsableLocation = restoreStateHasUsableLocation(doneState);
        const doneFractionSatisfied = restoreStateFractionSatisfied(doneState);
        globalThis.reader.hasLoadedLastPosition = !hasExplicitRestoreTarget || doneHasUsableLocation;
        if (globalThis.reader.hasLoadedLastPosition && (!syntheticRestoreLocator || syntheticDisplaySettledForRestore)) {
            markReaderRenderReady('loadLastPosition.done');
        }
        if (globalThis.reader.hasLoadedLastPosition) {
            globalThis.reader.refreshNativeMarkReadState?.('load-last-position-done');
        }
        const restoredExplicitPosition = doneHasUsableLocation && doneFractionSatisfied && (
            !!syntheticRestoreLocator
            || Number.isInteger(spineOnlyRestoreSectionIndex)
            || hasPreciseCFI
            || hasFractionalCompletion
        );
        if (restoredExplicitPosition) {
            globalThis.__manabiInitialRestoreHandled = {
                cfi: typeof cfi === 'string' ? cfi : '',
                fractionalCompletion: typeof doneState.currentFraction === 'number'
                    ? doneState.currentFraction
                    : (Number.isFinite(fractionalCompletion) ? fractionalCompletion : null),
                sectionIndex: doneState.sectionIndex ?? null,
                localSectionIndex: syntheticRestoreLocator?.localSectionIndex ?? null,
                rendererTotal: syntheticRestoreLocator?.rendererTotal ?? null,
                fractionalAnchorSuppressed: !!syntheticRestoreLocator,
                handledAtMs: Date.now(),
                source: 'loadLastPosition',
            };
        }
        if (hasExplicitRestoreTarget) {
            manabiPublishInitialRestoreResult(manabiCreateInitialRestoreResult({
                requestID: null,
                terminalState: restoredExplicitPosition ? 'satisfied' : 'failed',
                requestedLocator: restoreLocatorKind,
                resolvedLocator: restoreLocatorKind,
                requestedFraction: Number.isFinite(fractionalCompletion) ? fractionalCompletion : null,
                requestedCFI: cfi,
                location: {
                    fraction: typeof doneState.currentFraction === 'number' ? doneState.currentFraction : null,
                    sectionIndex: doneState.sectionIndex ?? null,
                },
                handledFractionalCompletion: restoredExplicitPosition
                    ? (typeof doneState.currentFraction === 'number'
                        ? doneState.currentFraction
                        : (Number.isFinite(fractionalCompletion) ? fractionalCompletion : null))
                    : null,
                navigationOk: restoredExplicitPosition,
                error: null,
                reason: 'loadLastPosition',
            }));
        }
        globalThis.reader?.maybeFlashInitialForwardSideNavChevron?.(doneState);
        globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.done', {
            restoreLocatorKind,
            requestedFraction: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
            currentFraction: typeof doneState.currentFraction === 'number' ? safeRound(doneState.currentFraction, 6) : null,
            currentSectionIndex: doneState.sectionIndex ?? null,
            locationCurrent: doneState.locationCurrent ?? null,
            locationTotal: doneState.locationTotal ?? null,
            hasLoadedLastPosition: globalThis.reader?.hasLoadedLastPosition === true,
            locationUsable: doneHasUsableLocation,
            fractionSatisfied: doneFractionSatisfied,
            updatedInitialRestoreHandled: restoredExplicitPosition,
            suppressNextSave: globalThis.__manabiSuppressNextRestoreRelocateSave === true,
            requireUserInputBeforeSave: globalThis.__manabiRequireUserInputBeforePositionSave === true,
        });
        postLandscapeInsetRestoreProbe('done', doneState, {
            hasCFI: typeof cfi === 'string' && cfi.length > 0,
            requestedFraction: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
        });

        scheduleDeferredCacheWarmerOpen('load-last-position-done');
    } catch (error) {
        console.error(error);
        const hasReaderContent = !!document.querySelector?.('foliate-view');
        const hasRenderer = !!globalThis.reader?.view?.renderer;
        readerLoadLog('viewer.loadLastPosition.error', {
            error: error?.message || String(error),
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
            hasReaderContent,
            hasRenderer,
            renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
            hasCFI: typeof cfi === 'string' && cfi.length > 0,
            hasFractionalCompletion,
            restoreLocatorKind,
        });
    } finally {
        globalThis.__manabiRestoreInProgress = false;
        globalThis.reader?.setLoadingIndicator?.(false, 'loadLastPosition.finally');
        if (globalThis.reader?.hasLoadedLastPosition === true) {
            globalThis.reader.refreshNativeMarkReadState?.('load-last-position-finally');
        }
        readerLoadLog('viewer.loadLastPosition.loadingCleared', {
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
            hasReaderContent: !!document.querySelector?.('foliate-view'),
            renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
        });
        if (!shouldKeepRestoreSaveGuard) {
            globalThis.__manabiSuppressNextRestoreRelocateSave = false;
        }
        globalThis.__manabiRequireUserInputBeforePositionSave = true;
        globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.finally', {
            restoreLocatorKind,
            hasLoadedLastPosition: globalThis.reader?.hasLoadedLastPosition === true,
            restoreInProgress: globalThis.__manabiRestoreInProgress === true,
            suppressNextSave: globalThis.__manabiSuppressNextRestoreRelocateSave === true,
            requireUserInputBeforeSave: globalThis.__manabiRequireUserInputBeforePositionSave === true,
        });
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
    markRestorePositionSaveUserInput('bridge.scheduleReaderFractionGoTo');
    globalThis.reader?.scheduleGoToFraction?.(fraction);
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
        return;
    }
    markRestorePositionSaveUserInput('bridge.scheduleReaderPercentGoTo');
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
