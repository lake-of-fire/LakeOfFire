// TODO: "prevent spread" for column mode: https://github.com/johnfactotum/foliate-js/commit/b7ff640943449e924da11abc9efa2ce6b0fead6d

const MANABI_ENABLE_COLUMNIZATION_OPTIMIZATIONS = false;
const MANABI_NEIGHBOR_PREFETCH_DELAY_MS = 0;
const MANABI_NEIGHBOR_PREFETCH_AFTER_SECTION_DISPLAY_DELAY_MS = 1500;
const CSS_DEFAULTS = MANABI_ENABLE_COLUMNIZATION_OPTIMIZATIONS
    ? {
        gapPct: 5,
        minGapPx: 36,
        topMarginPx: 4,
        bottomMarginPx: 32,
        verticalPaginatedGapPx: 12,
        verticalPaginatedTopMarginPx: 0,
        verticalPaginatedBottomMarginPx: 0,
        sideMarginPx: 32,
        maxInlineSizePx: 720,
        maxBlockSizePx: 1440,
        maxColumnCount: 2,
        maxColumnCountPortrait: 1,
    }
    : {
        gapPct: 7,
        minGapPx: 0,
        topMarginPx: 48,
        bottomMarginPx: 48,
        verticalPaginatedGapPx: 0,
        verticalPaginatedTopMarginPx: 48,
        verticalPaginatedBottomMarginPx: 48,
        sideMarginPx: 0,
        maxInlineSizePx: 720,
        maxBlockSizePx: 1440,
        maxColumnCount: 2,
        maxColumnCountPortrait: 1,
    };

const MANABI_DISABLE_POST_LOAD_RERENDER = false;
const MANABI_ENABLE_NEIGHBOR_PREFETCH = false;
const MANABI_ENABLE_PREFETCH_PROMISE_REUSE = false;
const MANABI_ENABLE_PREFETCH_WAIT_FOR_IN_FLIGHT = false;
const MANABI_ENABLE_SIMPLIFIED_SECTION_LOADING = true;
const MANABI_ENABLE_PAGE_METRICS_CACHE = false;
const MANABI_ENABLE_PAGE_TURN_BLANK_CORRECTION = false;
const MANABI_ENABLE_SINGLE_MEDIA_PAGE_NORMALIZATION = true;
const MANABI_NEIGHBOR_PREFETCH_END_PAGE_THRESHOLD = 5;
const MANABI_MIN_INLINE_CHARS_FOR_MULTICOLUMN = 17;
const MANABI_LOCKED_PAGE_TURN_DUPLICATE_SUPPRESSION_MS = 180;
const MANABI_POST_PAGE_TURN_DUPLICATE_SUPPRESSION_MS = 240;
const manabiLockedPageTurnQueueDecision = ({
    pendingQueueAllowed,
    pendingRequestedPage,
    pendingPageCount,
    pendingDirection,
    queuedDirection,
    queuedStep,
    lockedElapsedMs,
    distance,
}) => {
    const sameDirectionAsPending = pendingDirection === queuedDirection
    if (
        sameDirectionAsPending
        && lockedElapsedMs != null
        && lockedElapsedMs < MANABI_LOCKED_PAGE_TURN_DUPLICATE_SUPPRESSION_MS
        && distance == null
    ) {
        return { shouldQueue: false, reason: 'pageTurnDuplicateDuringLock' }
    }
    if (!pendingQueueAllowed) {
        return { shouldQueue: false, reason: 'pageTurnQueueOutsideSection' }
    }
    if (
        !Number.isFinite(pendingRequestedPage)
        || !Number.isFinite(pendingPageCount)
        || !Number.isFinite(queuedStep)
    ) {
        return { shouldQueue: false, reason: 'pageTurnQueueUnknownSection' }
    }
    const projectedQueuedPage = pendingRequestedPage + queuedStep
    const crossesSection = queuedStep < 0
        ? projectedQueuedPage <= 0
        : projectedQueuedPage >= pendingPageCount - 1
    return crossesSection
        ? { shouldQueue: false, reason: 'pageTurnQueueWouldCrossSection', projectedQueuedPage }
        : { shouldQueue: true, reason: 'pageTurnQueueWithinSection', projectedQueuedPage }
}
const manabiPageTurnBoundaryDecision = ({
    currentPage,
    pageCount,
    step,
    adjacentIndex,
}) => {
    const requestedPage = Number.isFinite(currentPage) && Number.isFinite(step)
        ? currentPage + step
        : null
    const crossesSection = Number.isFinite(requestedPage) && Number.isFinite(pageCount)
        ? (step < 0 ? requestedPage <= 0 : requestedPage >= pageCount - 1)
        : false
    const hasAdjacentSection = adjacentIndex != null
    return {
        requestedPage,
        crossesSection,
        hasAdjacentSection,
        shouldGoToAdjacentSection: crossesSection && hasAdjacentSection,
        shouldScrollWithinSection: !(crossesSection && hasAdjacentSection),
    }
}
export const manabiShouldSuppressPostPageTurnDuplicate = ({
    lastDirection,
    direction,
    distance = null,
    navigationSource = null,
    elapsedMs,
} = {}) => {
    if (distance != null || navigationSource != null) return false;
    if (lastDirection == null || direction == null || lastDirection !== direction) return false;
    return Number.isFinite(elapsedMs)
        && elapsedMs >= 0
        && elapsedMs < MANABI_POST_PAGE_TURN_DUPLICATE_SUPPRESSION_MS;
}
const wait = ms => new Promise(resolve => setTimeout(resolve, ms))
const manabiPerfNow = () =>
    globalThis.__manabiPerformanceNowMs?.()
        ?? (typeof performance !== 'undefined' && typeof performance.now === 'function'
            ? performance.now()
            : Date.now());
const manabiRound = (value, digits = 1) =>
    globalThis.__manabiSafeRound?.(value, digits)
        ?? (typeof value === 'number' && Number.isFinite(value)
            ? Number(value.toFixed(digits))
            : null);
const MANABI_TIMELINE_SLOW_THRESHOLD_MS = 1000;
const manabiTimelineValue = value => {
    if (value == null) return 'nil';
    if (typeof value === 'number') return Number.isFinite(value) ? String(manabiRound(value, 1)) : String(value);
    if (typeof value === 'boolean') return value ? 'true' : 'false';
    return String(value).replace(/\s+/g, ' ').slice(0, 96);
};
const manabiTimelinePayload = payload => Object.entries(payload || {})
    .filter(([, value]) => value !== undefined)
    .map(([key, value]) => `${key}=${manabiTimelineValue(value)}`)
    .join(' ');
const manabiTimelineMark = (event, payload = {}) => {
    const details = manabiTimelinePayload(payload);
    const label = details.length > 0 ? `MANABI ${event} ${details}` : `MANABI ${event}`;
    try {
        performance?.mark?.(label);
    } catch (_error) {}
    return label;
};
const manabiTimelineMeasure = (event, startedAt, payload = {}) => {
    const endedAt = manabiPerfNow();
    const elapsedMs = endedAt - startedAt;
    if (elapsedMs < MANABI_TIMELINE_SLOW_THRESHOLD_MS && globalThis.__manabiTimelineTraceAll !== true) {
        return elapsedMs;
    }
    const label = manabiTimelineMark(event, { ...payload, elapsedMs });
    try {
        performance?.measure?.(label, { start: startedAt, end: endedAt });
    } catch (_error) {}
    return elapsedMs;
};
const manabiShouldLogPaginatorReaderLoad = (cacheWarmer = false) => {
    if (cacheWarmer) return false;
    const source = String(globalThis.__manabiNavigationIntent?.source || '');
    return source.startsWith('restore')
        || source.startsWith('reader.open')
        || source.includes('initialRestore')
        || globalThis.__manabiTracePaginatorLoadBoundaries === true;
};
const manabiWritingDirectionInputsForDocument = doc => {
    const body = doc?.body;
    const documentElement = doc?.documentElement;
    if (!body || !documentElement) return null;
    const bootstrapText = doc.getElementById?.('mnb-writing-direction-bootstrap')?.textContent ?? '';
    const bodyStyle = body.getAttribute('style') ?? '';
    const rootStyle = documentElement.getAttribute('style') ?? '';
    return {
        href: doc.location?.href ?? null,
        bodyDirection: body.getAttribute('data-mnb-writing-direction') ?? null,
        foliateDirection: body.getAttribute('data-mnb-foliate-writing-direction') ?? null,
        foliateWritingMode: body.getAttribute('data-mnb-foliate-writing-mode') ?? null,
        bodyHasVerticalClass: body.classList?.contains?.('reader-vertical-writing') === true,
        rootHasVrtlClass: documentElement.classList?.contains?.('vrtl') === true,
        bodyStyleWritingMode: bodyStyle.match(/writing-mode\s*:\s*([^;]+)/i)?.[1]?.trim?.() ?? null,
        rootStyleWritingMode: rootStyle.match(/writing-mode\s*:\s*([^;]+)/i)?.[1]?.trim?.() ?? null,
        bootstrapWritingMode: bootstrapText.match(/writing-mode\s*:\s*([^;]+)/i)?.[1]?.trim?.() ?? null,
        observedBookWritingMode: globalThis.__manabiObservedBookWritingMode ?? null,
        observedBookDirection: globalThis.__manabiObservedBookWritingDirection ?? null,
    };
};
const manabiDocumentHasLocalWritingDirectionSignal = doc => {
    const inputs = manabiWritingDirectionInputsForDocument(doc);
    if (!inputs) return true;
    return !!(
        inputs.bodyDirection
        || inputs.foliateDirection
        || inputs.foliateWritingMode
        || inputs.bodyHasVerticalClass
        || inputs.rootHasVrtlClass
        || inputs.bodyStyleWritingMode
        || inputs.rootStyleWritingMode
        || inputs.bootstrapWritingMode
    );
};
const manabiApplyPreferredWritingDirectionToDocument = doc => {
    const body = doc?.body;
    const documentElement = doc?.documentElement;
    if (!body?.dataset || !documentElement) return false;
    if (manabiDocumentHasLocalWritingDirectionSignal(doc)) return false;
    const observedDirection = globalThis.__manabiObservedBookWritingDirection;
    const observedWritingMode = globalThis.__manabiObservedBookWritingMode;
    if (observedDirection !== 'vertical') return false;
    const writingMode = observedWritingMode === 'vertical-lr' ? 'vertical-lr' : 'vertical-rl';
    body.dataset.mnbFoliateWritingDirection = 'vertical';
    body.dataset.mnbFoliateWritingMode = writingMode;
    body.classList.add('reader-vertical-writing');
    if (writingMode === 'vertical-rl') {
        documentElement.classList.add('vrtl');
    }
    manabiTimelineMark('paginator.direction.preferredApplied', {
        href: doc.location?.href ?? null,
        observedDirection,
        observedWritingMode,
        appliedWritingMode: writingMode,
    });
    return true;
};
const manabiRememberObservedWritingDirection = (doc, direction) => {
    if (!direction) return;
    const source = direction.source ?? null;
    const writingMode = direction.writingMode ?? null;
    const explicitSource = source && source !== 'computed' && source !== 'bodyless-iframe';
    if (!explicitSource && !direction.vertical) return;
    const nextDirection = direction.vertical ? 'vertical' : 'horizontal';
    if (!direction.vertical && source !== 'attribute' && source !== 'attribute-mode' && source !== 'inline') return;
    if (globalThis.__manabiObservedBookWritingDirection === nextDirection
        && globalThis.__manabiObservedBookWritingMode === writingMode) {
        return;
    }
    globalThis.__manabiObservedBookWritingDirection = nextDirection;
    globalThis.__manabiObservedBookWritingMode = writingMode;
    manabiTimelineMark('paginator.direction.observedBookDirection', {
        href: doc?.location?.href ?? null,
        source,
        writingMode,
        observedDirection: nextDirection,
    });
};
const manabiReaderLoadPayload = (payload = {}) => Object.fromEntries(
    Object.entries(payload).filter(([key, value]) =>
        value !== undefined
        && key !== 'src'
        && key !== 'url'
        && key !== 'currentURL'
        && key !== 'href'
    )
);
const manabiReaderLoadSubpathFromURL = value => {
    const documentURL = String(value ?? '')
    if (!documentURL.includes('subpath=')) return null
    const encodedSubpath = documentURL.split('subpath=')[1]?.split('&')[0] ?? ''
    try {
        return decodeURIComponent(encodedSubpath).slice(0, 96)
    } catch (_error) {
        return encodedSubpath.slice(0, 96)
    }
};
const manabiNormalizeReaderLoadPath = value => {
    if (value == null) return null
    let path = String(value)
    try {
        path = decodeURIComponent(path)
    } catch (_error) {}
    return path
        .split('#')[0]
        .split('?')[0]
        .replace(/^\.?\//, '')
        .replace(/\/{2,}/g, '/')
}
const manabiReaderLoadPathsMatch = (lhs, rhs) => {
    const left = manabiNormalizeReaderLoadPath(lhs)
    const right = manabiNormalizeReaderLoadPath(rhs)
    return left != null && right != null && left === right
}
const manabiShouldEmitPaginatorFallbackReaderLoadLog = stage => {
    if (globalThis.__manabiReaderLoadVerbose === true || globalThis.__manabiPaginatorVerbosePageTurns === true) return true;
    if (typeof stage !== 'string') return false;
    if (stage.includes('error') || stage.includes('fail') || stage.includes('invalid') || stage.includes('watchdog') || stage.includes('slow')) return true;
    return stage === 'paginator.pageTurn.ignoreLocked'
        || stage === 'paginator.pageTurn.dropDuplicate'
        || stage === 'paginator.pageTurn.noMove'
        || stage === 'paginator.pageTurn.anomaly';
}
const manabiPaginatorReaderLoadLog = (stage, payload = {}) => {
    try {
        const readerPayload = manabiReaderLoadPayload(payload);
        if (typeof globalThis.__manabiReaderLoadLog === 'function') {
            globalThis.__manabiReaderLoadLog(stage, readerPayload);
            return;
        }
        if (!manabiShouldEmitPaginatorFallbackReaderLoadLog(stage)) return;
        const details = Object.entries(readerPayload)
            .map(([key, value]) => `${key}=${manabiTimelineValue(value)}`)
            .join(' ');
        window.webkit?.messageHandlers?.print?.postMessage?.(
            details.length > 0 ? `# READERLOAD stage=${stage} ${details}` : `# READERLOAD stage=${stage}`
        );
    } catch (_error) {}
};
const manabiPaginatorVerbosePageTurns = () =>
    globalThis.__manabiPaginatorVerbosePageTurns === true;
const manabiClamp01 = value =>
    Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : 0;
const manabiRectDiagnostics = (prefix, rect) => {
    if (!rect) return {};
    return {
        [`${prefix}X`]: manabiRound(Number(rect.x ?? rect.left) || 0, 2),
        [`${prefix}Y`]: manabiRound(Number(rect.y ?? rect.top) || 0, 2),
        [`${prefix}Width`]: manabiRound(Number(rect.width) || 0, 2),
        [`${prefix}Height`]: manabiRound(Number(rect.height) || 0, 2),
        [`${prefix}Left`]: manabiRound(Number(rect.left) || 0, 2),
        [`${prefix}Top`]: manabiRound(Number(rect.top) || 0, 2),
        [`${prefix}Right`]: manabiRound(Number(rect.right) || 0, 2),
        [`${prefix}Bottom`]: manabiRound(Number(rect.bottom) || 0, 2),
    };
};
const manabiElementDiagnostics = (prefix, element, styleProperties = []) => {
    if (!element) return {};
    const style = element.ownerDocument?.defaultView?.getComputedStyle?.(element) ?? null;
    const stylePayload = {};
    for (const property of styleProperties) {
        const key = property.replace(/-([a-z])/g, (_, char) => char.toUpperCase());
        stylePayload[`${prefix}Style${key[0].toUpperCase()}${key.slice(1)}`] =
            style?.getPropertyValue?.(property) || null;
    }
    return {
        [`${prefix}ClientWidth`]: element.clientWidth ?? null,
        [`${prefix}ClientHeight`]: element.clientHeight ?? null,
        [`${prefix}ScrollWidth`]: element.scrollWidth ?? null,
        [`${prefix}ScrollHeight`]: element.scrollHeight ?? null,
        [`${prefix}OffsetWidth`]: element.offsetWidth ?? null,
        [`${prefix}OffsetHeight`]: element.offsetHeight ?? null,
        ...manabiRectDiagnostics(`${prefix}Rect`, element.getBoundingClientRect?.()),
        ...stylePayload,
    };
};
const manabiDocumentStyleDiagnostics = (doc, phase) => {
    const body = doc?.body;
    const root = doc?.documentElement;
    const bodyStyle = body?.ownerDocument?.defaultView?.getComputedStyle?.(body) ?? null;
    const rootStyle = root?.ownerDocument?.defaultView?.getComputedStyle?.(root) ?? null;
    return {
        phase,
        documentHref: doc?.location?.href ?? null,
        bodyClass: body?.className ?? null,
        rootClass: root?.className ?? null,
        colorScheme: body?.dataset?.mnbColorScheme ?? null,
        lightTheme: body?.dataset?.mnbLightTheme ?? null,
        darkTheme: body?.dataset?.mnbDarkTheme ?? null,
        writingDirection: body?.dataset?.mnbWritingDirection ?? null,
        foliateDirection: body?.dataset?.mnbFoliateWritingDirection ?? null,
        foliateWritingMode: body?.dataset?.mnbFoliateWritingMode ?? null,
        bodyStyleWritingMode: bodyStyle?.getPropertyValue?.('writing-mode') || null,
        rootStyleWritingMode: rootStyle?.getPropertyValue?.('writing-mode') || null,
        bodyStyleBackgroundColor: bodyStyle?.getPropertyValue?.('background-color') || null,
        rootStyleBackgroundColor: rootStyle?.getPropertyValue?.('background-color') || null,
        bodyStyleColor: bodyStyle?.getPropertyValue?.('color') || null,
    };
};
const manabiRunPaginatorBoundary = async (stage, payload, operation, { logReaderLoad = false } = {}) => {
    const startedAt = manabiPerfNow();
    manabiTimelineMark(`${stage}.start`, payload);
    if (logReaderLoad) {
        manabiPaginatorReaderLoadLog(`${stage}.start`, payload);
    }
    try {
        const result = await operation();
        const elapsedMs = manabiRound(manabiPerfNow() - startedAt, 1);
        const finishedPayload = { ...payload, elapsedMs };
        manabiTimelineMark(`${stage}.finish`, finishedPayload);
        if (logReaderLoad) {
            manabiPaginatorReaderLoadLog(`${stage}.finish`, finishedPayload);
        }
        return result;
    } catch (error) {
        const errorPayload = {
            ...payload,
            elapsedMs: manabiRound(manabiPerfNow() - startedAt, 1),
            error: error?.message || String(error),
        };
        manabiTimelineMark(`${stage}.error`, errorPayload);
        if (logReaderLoad) {
            manabiPaginatorReaderLoadLog(`${stage}.error`, errorPayload);
        }
        throw error;
    }
};
const manabiSetStyleIfChanged = (style, property, value) => {
    if (!style || style[property] === value) {
        return false;
    }
    style[property] = value;
    return true;
};
const manabiSetPropertyIfChanged = (style, property, value) => {
    if (!style || style.getPropertyValue?.(property) === value) {
        return false;
    }
    style.setProperty(property, value);
    return true;
};
export const manabiPreparePaginatorLayoutMeasurement = ({
    top,
    vertical,
    flow,
    invalidateSizes,
    enableColumnizationOptimizations = MANABI_ENABLE_COLUMNIZATION_OPTIMIZATIONS,
} = {}) => {
    const usesVerticalPaginatedLayout =
        enableColumnizationOptimizations && vertical === true && flow !== 'scrolled';
    top?.classList?.toggle?.('mnb-vertical-paginated', usesVerticalPaginatedLayout);
    if (typeof invalidateSizes === 'function') {
        invalidateSizes();
    }
    return usesVerticalPaginatedLayout;
};
const manabiBlobResourceInfo = url => {
    try {
        return globalThis.__manabiBlobResourceMap?.get?.(url) ?? null;
    } catch (_error) {
        return null;
    }
};
export const manabiPageSummaryIsVisiblyBlank = summary =>
    !!summary
    && (summary.textCharCount ?? 0) === 0
    && (summary.mediaCount ?? 0) === 0;
export const manabiResolveBlankPageTarget = ({ page, pages, direction = 0, summariesByPage = null } = {}) => {
    if (!Number.isFinite(page) || !Number.isFinite(pages) || !Number.isFinite(direction) || direction === 0) {
        return page;
    }
    const minPage = 1;
    const maxPage = Math.max(minPage, pages - 2);
    let target = Math.max(minPage, Math.min(maxPage, Math.trunc(page)));
    const step = direction > 0 ? 1 : -1;
    const summaryForPage = candidatePage =>
        summariesByPage instanceof Map
            ? (summariesByPage.get(candidatePage) ?? null)
            : (summariesByPage?.[candidatePage] ?? null);
    while (
        target >= minPage
        && target <= maxPage
        && manabiPageSummaryIsVisiblyBlank(summaryForPage(target))
    ) {
        const nextTarget = target + step;
        if (nextTarget < minPage || nextTarget > maxPage) break;
        target = nextTarget;
    }
    return target;
};
export const manabiNormalizeSingleMediaPageTarget = ({ page, pages, isSingleMedia = false } = {}) => {
    if (
        !MANABI_ENABLE_SINGLE_MEDIA_PAGE_NORMALIZATION
        || !isSingleMedia
        || !Number.isFinite(page)
        || pages !== 3
    ) {
        return page;
    }
    return 1;
};
export const manabiPaginatorAnchorForLocalPage = ({ localPage, textPageCount } = {}) => {
    const normalizedTextPageCount = Number.isFinite(textPageCount)
        ? Math.max(1, Math.round(textPageCount))
        : 1;
    const normalizedLocalPage = Number.isFinite(localPage)
        ? Math.max(0, Math.round(localPage))
        : 0;
    const targetLocalPage = Math.min(normalizedTextPageCount - 1, normalizedLocalPage);
    return normalizedTextPageCount > 1
        ? Math.max(0, Math.min(1, targetLocalPage / (normalizedTextPageCount - 1)))
        : 0;
};
// https://learnersbucket.com/examples/interview/debouncing-with-leading-and-trailing-options/
const debounce = (fn, delay) => {
    let timeout;
    let isLeadingInvoked = false;

    return function (...args) {
        const context = this;

        if (!timeout) {
            fn.apply(context, args);
            isLeadingInvoked = true;

            timeout = setTimeout(() => {
                timeout = null;
                if (!isLeadingInvoked) {
                    fn.apply(context, args);
                }
            }, delay);
        } else {
            isLeadingInvoked = false;
        }
    }
};

const lerp = (min, max, x) => x * (max - min) + min
const easeOutQuad = x => 1 - (1 - x) * (1 - x)
const animate = (a, b, duration, ease, render) => new Promise(resolve => {
    let start
    const step = now => {
        start ??= now
        const fraction = Math.min(1, (now - start) / duration)
        render(lerp(a, b, ease(fraction)))
        if (fraction < 1) requestAnimationFrame(step)
        else resolve()
    }
    requestAnimationFrame(step)
})

// collapsed range doesn't return client rects sometimes (or always?)
// try make get a non-collapsed range or element
const uncollapse = range => {
    if (!range?.collapsed) return range
    const {
        endOffset,
        endContainer
    } = range
    if (endContainer.nodeType === 1) {
        const node = endContainer.childNodes[endOffset]
        if (node?.nodeType === 1) return node
        return endContainer
    }
    if (endOffset + 1 < endContainer.length) range.setEnd(endContainer, endOffset + 1)
    else if (endOffset > 1) range.setStart(endContainer, endOffset - 1)
    else return endContainer.parentNode
    return range
}

const {
    SHOW_ELEMENT,
    SHOW_TEXT,
    SHOW_CDATA_SECTION,
    FILTER_ACCEPT,
    FILTER_REJECT,
    FILTER_SKIP
} = NodeFilter

/**
 * Creates a hidden iframe with a cloned document (head and empty body) to compute computed style.
 * @param {Document} sourceDoc - The source document to clone.
 * @returns {Promise<{cs: CSSStyleDeclaration, doc: Document}>} - Computed style and iframe document.
 */
async function getBodylessComputedStyle(sourceDoc) {
    const startedAt = manabiPerfNow();
    // 1. Clone a minimal document
    const cloneDoc = document.implementation.createHTMLDocument();

    // 2. Deep-clone the <head>, stripping unwanted styles/scripts
    const clonedHead = sourceDoc.head.cloneNode(true);
    ['mnb-font-data', 'mnb-custom-fonts'].forEach(id => {
        const el = clonedHead.querySelector(`#${id}`);
        if (el) el.remove();
    });
    // Refresh blob-based CSS
    const stylesheetLinks = Array.from(clonedHead.querySelectorAll('link[rel="stylesheet"][href^="blob:"]'));
    for (const link of stylesheetLinks) {
        const cssFetchStartedAt = manabiPerfNow();
        const originalHref = link.href;
        const originalInfo = manabiBlobResourceInfo(originalHref);
        try {
            const css = await fetch(link.href).then(r => r.text());
            const blobUrl = URL.createObjectURL(new Blob([css], {
                type: 'text/css'
            }));
            try {
                globalThis.__manabiBlobResourceMap?.set?.(blobUrl, {
                    href: originalInfo?.href ?? originalHref,
                    type: 'text/css',
                    parent: originalInfo?.parent ?? null,
                    bytes: css.length,
                    source: 'bodyless-computed-style',
                });
            } catch (_error) {}
            manabiTimelineMeasure('bodylessStyle.cssFetch', cssFetchStartedAt, {
                href: originalInfo?.href ?? originalHref,
                bytes: css.length,
            }, 25);
            link.href = blobUrl;
        } catch {
            manabiTimelineMeasure('bodylessStyle.cssFetch.error', cssFetchStartedAt, {
                href: originalInfo?.href ?? originalHref,
            }, 25);
            link.remove();
        }
    }
    clonedHead.querySelectorAll('script').forEach(el => el.remove());
    cloneDoc.head.replaceWith(clonedHead);

    // 3. Shallow-clone the <body> (to preserve dir, but empty)
    const bodyClone = sourceDoc.body.cloneNode(false);
    cloneDoc.body.replaceWith(bodyClone);
    // Copy all attributes from the source <html> (e.g. xmlns, xml:lang, class, lang)
    for (const { name, value } of sourceDoc.documentElement.attributes) {
        cloneDoc.documentElement.setAttribute(name, value);
    }
    // Override or add the 'dir' attribute explicitly
    cloneDoc.documentElement.setAttribute(
        'dir',
        sourceDoc.documentElement.getAttribute('dir') || ''
    );

    // 4. Serialize the cloneDoc to HTML and create a Blob URL
    const html = '<!doctype html>' + cloneDoc.documentElement.outerHTML;
    const blob = new Blob([html], {
        type: 'text/html'
    });
    const blobUrl = URL.createObjectURL(blob);

    // 5. Create a hidden iframe, append, and wait for load
    const iframe = document.createElement('iframe');
    iframe.style.cssText = 'position:fixed;visibility:hidden;width:0;height:0;border:0;contain:strict;';
    document.documentElement.appendChild(iframe);
    const iframeLoadStartedAt = manabiPerfNow();
    await new Promise(resolve => {
        iframe.onload = resolve;
        iframe.src = blobUrl;
    });
    manabiTimelineMeasure('bodylessStyle.iframeLoad', iframeLoadStartedAt, {
        stylesheetCount: stylesheetLinks.length,
    }, 25);

    // wait a frame for CSS to apply before measuring
    await new Promise(r => requestAnimationFrame(r));

    // 6. Get computed style and doc
    const bodylessDoc = iframe.contentDocument;
    const bodylessStyle = iframe.contentWindow.getComputedStyle(bodylessDoc.body);

    // 7. Cleanup
    URL.revokeObjectURL(blobUrl);
    iframe.remove();

    manabiTimelineMeasure('bodylessStyle.total', startedAt, {
        stylesheetCount: stylesheetLinks.length,
    }, 25);
    return { bodylessStyle, bodylessDoc };
}

/**
 * Determines writing mode and directionality (vertical, verticalRTL, rtl) by using a computed style from a cloned iframe.
 * @param {Document} sourceDoc - The source document to analyze.
 * @returns {Promise<{vertical: boolean, verticalRTL: boolean, rtl: boolean}>}
 */
async function getDirection({ bodylessStyle, bodylessDoc }) {
    const writingMode = bodylessStyle.writingMode;
    const direction = bodylessStyle.direction;
    const vertical = writingMode === 'vertical-rl' || writingMode === 'vertical-lr';
    const verticalRTL = writingMode === 'vertical-rl';
    const rtl =
        bodylessDoc.body.dir === 'rtl' ||
        direction === 'rtl' ||
        bodylessDoc.documentElement.dir === 'rtl';
    return { vertical, verticalRTL, rtl };
}

function getDirectionFromDocument(doc) {
    const body = doc?.body;
    const documentElement = doc?.documentElement;
    if (!body || !documentElement) return null;

    let pageParams = null;
    try {
        pageParams = new URL(doc.location?.href ?? '').searchParams;
    } catch (_error) {}
    const explicitDirection = body.getAttribute('data-mnb-writing-direction')?.trim?.().toLowerCase?.() ?? null;
    const foliateDirection = body.getAttribute('data-mnb-foliate-writing-direction')?.trim?.().toLowerCase?.()
        ?? pageParams?.get?.('mnbWritingDirection')?.trim?.().toLowerCase?.()
        ?? null;
    const foliateWritingMode = body.getAttribute('data-mnb-foliate-writing-mode')?.trim?.().toLowerCase?.()
        ?? pageParams?.get?.('mnbWritingMode')?.trim?.().toLowerCase?.()
        ?? null;
    const styleText = [
        body.getAttribute('style') ?? '',
        documentElement.getAttribute('style') ?? '',
        doc.getElementById?.('mnb-writing-direction-bootstrap')?.textContent ?? '',
    ].join(';');
    const writingModeMatch = styleText.match(/writing-mode\s*:\s*([^;]+)/i);
    const directionMatch = styleText.match(/(?:^|;)\s*direction\s*:\s*([^;]+)/i);
    let writingMode = foliateWritingMode || (writingModeMatch?.[1]?.trim?.().toLowerCase?.() ?? null);
    let direction = directionMatch?.[1]?.trim?.().toLowerCase?.() ?? null;
    let source = foliateWritingMode ? 'attribute-mode' : (writingMode ? 'inline' : null);
    if (!writingMode && (
        explicitDirection === 'vertical'
        || foliateDirection === 'vertical'
        || body.classList?.contains?.('reader-vertical-writing')
        || documentElement.classList?.contains?.('vrtl')
    )) {
        writingMode = 'vertical-rl';
        source = explicitDirection === 'vertical' || foliateDirection === 'vertical' ? 'attribute' : 'class';
    }
    if (!writingMode && (explicitDirection === 'horizontal' || foliateDirection === 'horizontal')) {
        writingMode = 'horizontal-tb';
        source = 'attribute';
    }
    if (!writingMode) {
        try {
            const computedStyle = doc.defaultView?.getComputedStyle?.(body);
            const computedWritingMode = computedStyle?.writingMode?.trim?.().toLowerCase?.() ?? null;
            const isProcessedEBook =
                body.dataset?.isEbook === 'true'
                || body.classList?.contains?.('readability-mode') === true
                || doc.location?.href?.startsWith?.('ebook://ebook/processed-section') === true;
            if (computedWritingMode && !(isProcessedEBook && computedWritingMode === 'horizontal-tb')) {
                writingMode = computedWritingMode;
                direction = computedStyle?.direction?.trim?.().toLowerCase?.() ?? direction;
                source = 'computed';
            }
        } catch (_error) {}
    }
    if (!writingMode) return null;

    const vertical = writingMode === 'vertical-rl' || writingMode === 'vertical-lr';
    const verticalRTL = writingMode === 'vertical-rl';
    const rtl =
        body.dir === 'rtl' ||
        documentElement.dir === 'rtl' ||
        direction === 'rtl';
    return { vertical, verticalRTL, rtl, writingMode, direction, source };
}

const makeMarginals = (length, part) => Array.from({
    length
}, () => {
    const div = document.createElement('div')
    const child = document.createElement('div')
    div.append(child)
    child.setAttribute('part', part)
    return div
})

const setStylesImportant = (el, styles) => {
    const {
        style
    } = el
    for (const [k, v] of Object.entries(styles)) style.setProperty(k, v, 'important')
}

const isJapaneseLanguageTag = value => {
    if (typeof value !== 'string') return false
    const normalized = value.trim().toLowerCase()
    return normalized === 'ja' || normalized.startsWith('ja-')
}

const getJapaneseLayoutFlags = doc => {
    const hasManabiSentences = !!doc?.body?.matches?.('[data-mnb-has-sentences="true"]')
        || !!doc?.querySelector?.('m-s')
    const hasManabiSegments = !!doc?.body?.matches?.('[data-mnb-has-segments="true"]')
        || !!doc?.querySelector?.('m-m')
    const lang =
        doc?.documentElement?.getAttribute?.('lang')
        || doc?.documentElement?.getAttribute?.('xml:lang')
        || doc?.body?.getAttribute?.('lang')
        || doc?.body?.getAttribute?.('xml:lang')
        || ''
    const isJapanese = isJapaneseLanguageTag(lang) || hasManabiSentences || hasManabiSegments
    return {
        isJapanese,
        lang: lang || null,
        hasManabiSentences,
        hasManabiSegments,
    }
}

class View {
    #wait = ms => new Promise(resolve => setTimeout(resolve, ms))
    #debouncedExpand
    #hasResizerObserverTriggered = false
    #lastResizerRect = null
    #styleCache = new WeakMap()
    cachedViewSize = null
    #resizeObserver = new ResizeObserver(entries => {
        if (this.#isCacheWarmer) return;

        const entry = entries[0];
        const rect = entry.contentRect;

        const newSize = {
            width: Math.round(rect.width),
            height: Math.round(rect.height),
            top: Math.round(rect.top),
            left: Math.round(rect.left),
        };

        if (!this.#hasResizerObserverTriggered) {
            this.#hasResizerObserverTriggered = true;
            this.#lastResizerRect = newSize;
            return;
        }

        const old = this.#lastResizerRect;
        const unchanged =
            old &&
            newSize.width === old.width &&
            newSize.height === old.height &&
            newSize.top === old.top &&
            newSize.left === old.left;

        if (unchanged) {
            return
        }

        this.#lastResizerRect = newSize
        this.cachedViewSize = null

        void this.expand()
    })
    #element = document.createElement('div')
    #iframe = document.createElement('iframe')
    #contentRange = document.createRange()
    #overlayer
    #vertical = null
    #verticalRTL = null
    #rtl = null
    #directionReadyResolve = null;
    #directionReady = new Promise(r => (this.#directionReadyResolve = r));
    _column = true
    _size
    #lastRenderSignature = null
    #renderInFlightSignature = null
    #renderInFlightPromise = null
    #lastExpandSignature = null
    #lastExpandedMetrics = null
    layout = {}
    #isCacheWarmer
    #loadCleanup = null
    constructor({
        container,
        onBeforeExpand,
        onExpand,
        isCacheWarmer
    }) {
        this.container = container
        this.#isCacheWarmer = isCacheWarmer
        this.#debouncedExpand = this.expand.bind(this)
        this.onBeforeExpand = onBeforeExpand
        this.onExpand = onExpand
        //        this.#iframe.setAttribute('part', 'filter')
        this.#element.append(this.#iframe)
        Object.assign(this.#element.style, {
            boxSizing: 'content-box',
            position: 'relative',
            overflow: 'hidden',
            flex: '0 0 auto',
            width: '100%',
            height: '100%',
            display: 'flex',
            justifyContent: 'center',
            alignItems: 'center',
        })
        Object.assign(this.#iframe.style, {
            overflow: 'hidden',
            border: '0',
            //            display: 'none',
            display: 'block',
            width: '100%',
            height: '100%',
        })
        // `allow-scripts` is needed for events because of WebKit bug
        // https://bugs.webkit.org/show_bug.cgi?id=218086
        //        this.#iframe.setAttribute('sandbox', 'allow-scripts allow-same-origin allow-popups allow-downloads')
        //this.#iframe.setAttribute('sandbox', 'allow-same-origin allow-scripts') // Breaks font-src data: blobs...
        this.#iframe.setAttribute('scrolling', 'no')
    }
    get element() {
        return this.#element
    }
    get document() {
        return this.#iframe.contentDocument
    }
    get expandedMetrics() {
        return this.#lastExpandedMetrics
    }
    async load(src, afterLoad, beforeRender) {
        if (typeof src !== 'string') throw new Error(`${src} is not string`)
        this.prepareForReuse()
        const loadStartedAt = manabiPerfNow();
        const logReaderLoad = manabiShouldLogPaginatorReaderLoad(this.#isCacheWarmer);
        const basePayload = {
            src,
            cacheWarmer: this.#isCacheWarmer,
        };
        manabiTimelineMark('paginator.view.load.start', basePayload);
        if (!this.#isCacheWarmer) {
            manabiPaginatorReaderLoadLog('paginator.view.lifecycle', {
                phase: 'load.start',
                elapsedMs: 0,
                iframeConnected: this.#iframe.isConnected,
                elementConnected: this.#element.isConnected,
            });
        }
        if (logReaderLoad) {
            manabiPaginatorReaderLoadLog('paginator.view.load.start', basePayload);
        }
        // Reset direction flags and promise before loading a new section
        this.#vertical = this.#verticalRTL = this.#rtl = null;
        this.#directionReady = new Promise(r => (this.#directionReadyResolve = r));
        this.#lastRenderSignature = null
        this.#renderInFlightSignature = null
        this.#renderInFlightPromise = null
        this.#lastExpandSignature = null
        this.#lastExpandedMetrics = null
        return new Promise((resolve, reject) => {
            if (this.#isCacheWarmer) {
                console.log("Don't create View for cache warmers")
                resolve()
            } else {
                const onLoad = async () => {
                    this.#iframe.removeEventListener('error', onError)
                    this.#loadCleanup = null
                    try {
                        const eventPayload = {
                            ...basePayload,
                            elapsedMs: manabiRound(manabiPerfNow() - loadStartedAt, 1),
                            href: this.document?.location?.href ?? null,
                        };
                        manabiTimelineMark('paginator.view.iframeLoad', eventPayload);
                        if (!this.#isCacheWarmer) {
                            manabiPaginatorReaderLoadLog('paginator.view.lifecycle', {
                                phase: 'iframeLoad',
                                elapsedMs: eventPayload.elapsedMs,
                                documentSubpath: manabiReaderLoadSubpathFromURL(this.document?.location?.href),
                                docReadyState: this.document?.readyState ?? null,
                                hasBody: !!this.document?.body,
                                bodyClass: this.document?.body?.className ?? null,
                                mediaCount: this.document?.body?.querySelectorAll?.('img, svg, image, picture, video, object, canvas')?.length ?? null,
                            });
                        }
                        if (logReaderLoad) {
                            manabiPaginatorReaderLoadLog('paginator.view.iframeLoad', eventPayload);
                        }
                        const doc = this.document

                        await manabiRunPaginatorBoundary(
                            'paginator.view.afterLoad',
                            { ...basePayload, href: doc?.location?.href ?? null },
                            () => afterLoad?.(doc),
                            { logReaderLoad }
                        )
                        if (!this.#isCacheWarmer) {
                            manabiPaginatorReaderLoadLog('paginator.view.lifecycle', {
                                phase: 'afterLoad.finish',
                                elapsedMs: manabiRound(manabiPerfNow() - loadStartedAt, 1),
                                documentSubpath: manabiReaderLoadSubpathFromURL(doc?.location?.href),
                                docReadyState: doc?.readyState ?? null,
                                hasBody: !!doc?.body,
                                bodyClass: doc?.body?.className ?? null,
                                bodyTextLength: doc?.body?.textContent?.trim?.().length ?? null,
                                mediaCount: doc?.body?.querySelectorAll?.('img, svg, image, picture, video, object, canvas')?.length ?? null,
                            });
                        }

                        let direction = await manabiRunPaginatorBoundary(
                            'paginator.view.direction.document',
                            {
                                ...basePayload,
                                href: doc?.location?.href ?? null,
                                appliedPreferredDirection: manabiApplyPreferredWritingDirectionToDocument(doc),
                            },
                            () => getDirectionFromDocument(doc),
                            { logReaderLoad }
                        );
                        let directionSource = 'document';
                        if (!direction) {
                            const { bodylessStyle, bodylessDoc } = await manabiRunPaginatorBoundary(
                                'paginator.view.direction.bodylessStyle',
                                { ...basePayload, href: doc?.location?.href ?? null },
                                () => getBodylessComputedStyle(doc),
                                { logReaderLoad }
                            )
                            direction = await manabiRunPaginatorBoundary(
                                'paginator.view.direction.bodyless',
                                { ...basePayload, href: doc?.location?.href ?? null },
                                () => getDirection({ bodylessStyle, bodylessDoc }),
                                { logReaderLoad }
                            );
                            directionSource = 'bodyless-iframe';
                        } else {
                            directionSource = direction.source ?? directionSource;
                        }
                        manabiTimelineMark('paginator.direction.inputs', {
                            ...basePayload,
                            ...manabiWritingDirectionInputsForDocument(doc),
                            resolvedSource: directionSource,
                            resolvedWritingMode: direction?.writingMode ?? null,
                            resolvedDirection: direction?.direction ?? null,
                            resolvedVertical: direction?.vertical === true,
                            resolvedRTL: direction?.rtl === true,
                        });
                        if (logReaderLoad) {
                            manabiPaginatorReaderLoadLog('paginator.direction.resolved', {
                                cacheWarmer: this.#isCacheWarmer,
                                source: directionSource,
                                writingMode: direction?.writingMode ?? null,
                                direction: direction?.direction ?? null,
                                vertical: direction?.vertical === true,
                                verticalRTL: direction?.verticalRTL === true,
                                rtl: direction?.rtl === true,
                                bodyClass: doc?.body?.className ?? null,
                            });
                        }
                        manabiRememberObservedWritingDirection(doc, {
                            ...direction,
                            source: directionSource,
                        });
                        this.#vertical = direction.vertical;
                        this.#verticalRTL = direction.verticalRTL;
                        this.#rtl = direction.rtl;
                        this.#directionReadyResolve?.();
                        if (!this.#isCacheWarmer) {
                            manabiPaginatorReaderLoadLog('paginator.view.lifecycle', {
                                phase: 'direction.resolved',
                                elapsedMs: manabiRound(manabiPerfNow() - loadStartedAt, 1),
                                documentSubpath: manabiReaderLoadSubpathFromURL(doc?.location?.href),
                                directionSource,
                                writingMode: direction?.writingMode ?? null,
                                direction: direction?.direction ?? null,
                                vertical: this.#vertical,
                                verticalRTL: this.#verticalRTL,
                                rtl: this.#rtl,
                                bodyClass: doc?.body?.className ?? null,
                            });
                        }
                        manabiTimelineMark('paginator.direction', {
                            source: directionSource,
                            writingMode: direction.writingMode,
                            direction: direction.direction,
                            vertical: this.#vertical,
                            rtl: this.#rtl,
                            cacheWarmer: this.#isCacheWarmer,
                        });

                        this.#contentRange.selectNodeContents(doc.body)

                        const layout = await manabiRunPaginatorBoundary(
                            'paginator.view.beforeRender',
                            {
                                ...basePayload,
                                href: doc?.location?.href ?? null,
                                vertical: this.#vertical,
                                rtl: this.#rtl,
                            },
                            () => beforeRender?.({
                                vertical: this.#vertical,
                                rtl: this.#rtl,
                            }),
                            { logReaderLoad }
                        )
                        if (!this.#isCacheWarmer) {
                            manabiPaginatorReaderLoadLog('paginator.view.lifecycle', {
                                phase: 'beforeRender.finish',
                                elapsedMs: manabiRound(manabiPerfNow() - loadStartedAt, 1),
                                documentSubpath: manabiReaderLoadSubpathFromURL(doc?.location?.href),
                                flow: layout?.flow ?? null,
                                vertical: this.#vertical,
                                rtl: this.#rtl,
                            });
                        }
                        await manabiRunPaginatorBoundary(
                            'paginator.view.render',
                            {
                                ...basePayload,
                                href: doc?.location?.href ?? null,
                                flow: layout?.flow ?? null,
                                vertical: this.#vertical,
                                rtl: this.#rtl,
                            },
                            () => this.render(layout),
                            { logReaderLoad }
                        )
                        if (!this.#isCacheWarmer) {
                            manabiPaginatorReaderLoadLog('paginator.view.lifecycle', {
                                phase: 'render.finish',
                                elapsedMs: manabiRound(manabiPerfNow() - loadStartedAt, 1),
                                documentSubpath: manabiReaderLoadSubpathFromURL(doc?.location?.href),
                                flow: layout?.flow ?? null,
                                vertical: this.#vertical,
                                rtl: this.#rtl,
                                bodyClass: doc?.body?.className ?? null,
                                docClientWidth: doc?.documentElement?.clientWidth ?? null,
                                docClientHeight: doc?.documentElement?.clientHeight ?? null,
                                docScrollWidth: doc?.documentElement?.scrollWidth ?? null,
                                docScrollHeight: doc?.documentElement?.scrollHeight ?? null,
                                bodyClientWidth: doc?.body?.clientWidth ?? null,
                                bodyClientHeight: doc?.body?.clientHeight ?? null,
                                bodyScrollWidth: doc?.body?.scrollWidth ?? null,
                                bodyScrollHeight: doc?.body?.scrollHeight ?? null,
                            });
                        }

                        this.#resizeObserver.observe(doc.body)
                        if (doc.fonts?.ready && doc.fonts.status !== 'loaded') {
                            doc.fonts.ready.then(() => {
                                void manabiRunPaginatorBoundary(
                                    'paginator.view.fontsReadyExpand',
                                    { ...basePayload, href: doc?.location?.href ?? null },
                                    () => this.expand(),
                                    { logReaderLoad }
                                )
                            })
                        } else {
                            manabiTimelineMark('paginator.view.fontsReadyExpand.skipLoaded', {
                                ...basePayload,
                                href: doc?.location?.href ?? null,
                                fontsStatus: doc.fonts?.status ?? null,
                            });
                        }
                        const finishPayload = {
                            ...basePayload,
                            href: doc?.location?.href ?? null,
                            elapsedMs: manabiRound(manabiPerfNow() - loadStartedAt, 1),
                        };
                        manabiTimelineMark('paginator.view.load.finish', finishPayload);
                        if (!this.#isCacheWarmer) {
                            manabiPaginatorReaderLoadLog('paginator.view.lifecycle', {
                                phase: 'load.finish',
                                elapsedMs: finishPayload.elapsedMs,
                                documentSubpath: manabiReaderLoadSubpathFromURL(doc?.location?.href),
                                fontsStatus: doc.fonts?.status ?? null,
                                hasExpandedMetrics: !!this.#lastExpandedMetrics,
                                expandedSize: this.#lastExpandedMetrics?.expandedSize ?? null,
                                expandedPageCount: this.#lastExpandedMetrics?.pageCount ?? null,
                            });
                        }
                        if (logReaderLoad) {
                            manabiPaginatorReaderLoadLog('paginator.view.load.finish', finishPayload);
                        }
                        resolve()
                    } catch (error) {
                        const errorPayload = {
                            ...basePayload,
                            elapsedMs: manabiRound(manabiPerfNow() - loadStartedAt, 1),
                            error: error?.message || String(error),
                        };
                        manabiTimelineMark('paginator.view.load.error', errorPayload);
                        if (logReaderLoad) {
                            manabiPaginatorReaderLoadLog('paginator.view.load.error', errorPayload);
                        }
                        reject(error)
                    }
                }
                const onError = error => {
                    this.#iframe.removeEventListener('load', onLoad)
                    this.#loadCleanup = null
                    const errorPayload = {
                        ...basePayload,
                        elapsedMs: manabiRound(manabiPerfNow() - loadStartedAt, 1),
                        error: error?.message || String(error),
                    };
                    manabiTimelineMark('paginator.view.iframeError', errorPayload);
                    if (logReaderLoad) {
                        manabiPaginatorReaderLoadLog('paginator.view.iframeError', errorPayload);
                    }
                    reject(error);
                }
                this.#loadCleanup = () => {
                    this.#iframe.removeEventListener('load', onLoad)
                    this.#iframe.removeEventListener('error', onError)
                }
                this.#iframe.addEventListener('load', onLoad, { once: true })
                this.#iframe.addEventListener('error', onError, { once: true })
                manabiTimelineMark('paginator.view.assignSrc', basePayload);
                if (!this.#isCacheWarmer) {
                    manabiPaginatorReaderLoadLog('paginator.view.lifecycle', {
                        phase: 'assignSrc',
                        elapsedMs: manabiRound(manabiPerfNow() - loadStartedAt, 1),
                        iframeConnected: this.#iframe.isConnected,
                        elementConnected: this.#element.isConnected,
                    });
                }
                if (logReaderLoad) {
                    manabiPaginatorReaderLoadLog('paginator.view.assignSrc', basePayload);
                }
                this.#iframe.src = src
            }
        })
    }
    async render(layout) {
        //        console.log("render(layout)...")
        if (!layout) {
            //            console.log("render(layout)... return")
            return
        }
        const logReaderLoad = manabiShouldLogPaginatorReaderLoad(this.#isCacheWarmer);
        const renderPayload = {
            cacheWarmer: this.#isCacheWarmer,
            flow: layout?.flow ?? null,
            vertical: this.#vertical,
            rtl: this.#rtl,
            href: this.document?.location?.href ?? null,
        };
        const doc = this.document
        if (!doc?.documentElement || !doc?.body) {
            return
        }
        if (logReaderLoad) {
            manabiPaginatorReaderLoadLog('paginator.render.styleSnapshot', {
                ...renderPayload,
                ...manabiDocumentStyleDiagnostics(doc, 'beforeFoliateStyle'),
            });
        }
        this._column = layout.flow !== 'scrolled'
        this.layout = layout

        const foliateWritingMode = this.#vertical
            ? (this.#verticalRTL ? 'vertical-rl' : 'vertical-lr')
            : 'horizontal-tb'
        doc.body.dataset.mnbFoliateWritingDirection = this.#vertical ? 'vertical' : 'horizontal'
        doc.body.dataset.mnbFoliateWritingMode = foliateWritingMode
        doc.body.classList.toggle('reader-vertical-writing', this.#vertical)
        if (logReaderLoad) {
            manabiPaginatorReaderLoadLog('paginator.render.styleSnapshot', {
                ...renderPayload,
                ...manabiDocumentStyleDiagnostics(doc, 'afterFoliateStyle'),
            });
        }

        const renderSignature = JSON.stringify({
            flow: layout.flow ?? null,
            width: Math.round(Number(layout.width) || 0),
            height: Math.round(Number(layout.height) || 0),
            gap: manabiRound(Number(layout.gap) || 0, 2),
            columnWidth: manabiRound(Number(layout.columnWidth) || 0, 2),
            divisor: Number(layout.divisor) || 0,
            vertical: !!this.#vertical,
            rtl: !!this.#rtl,
            typography: layout.typographySignature ?? null,
        })
        if (this.#lastRenderSignature === renderSignature) {
            manabiTimelineMark('paginator.view.render.skipSameSignature', renderPayload)
            if (logReaderLoad) {
                manabiPaginatorReaderLoadLog('paginator.view.render.skipSameSignature', {
                    ...renderPayload,
                    renderSignature,
                });
            }
            return
        }
        if (this.#renderInFlightSignature === renderSignature && this.#renderInFlightPromise) {
            manabiTimelineMark('paginator.view.render.awaitSameSignature', renderPayload)
            if (logReaderLoad) {
                manabiPaginatorReaderLoadLog('paginator.view.render.awaitSameSignature', {
                    ...renderPayload,
                    renderSignature,
                });
            }
            await this.#renderInFlightPromise
            return
        }

        const renderWork = this._column
            ? manabiRunPaginatorBoundary(
                'paginator.view.render.columnize',
                renderPayload,
                () => this.columnize(layout),
                { logReaderLoad }
            )
            : manabiRunPaginatorBoundary(
                'paginator.view.render.scrolled',
                renderPayload,
                () => this.scrolled(layout),
                { logReaderLoad }
            )
        this.#renderInFlightSignature = renderSignature
        this.#renderInFlightPromise = renderWork
        try {
            await renderWork
            this.#lastRenderSignature = renderSignature
        } finally {
            if (this.#renderInFlightPromise === renderWork) {
                this.#renderInFlightPromise = null
                this.#renderInFlightSignature = null
            }
        }
    }
    async scrolled({
        gap,
        columnWidth
    }) {
        await this.#awaitDirection();
        const vertical = this.#vertical
        const doc = this.document
        const { isJapanese } = getJapaneseLayoutFlags(doc)
        setStylesImportant(doc.documentElement, {
            'box-sizing': 'border-box',
            'padding': vertical ? `${gap}px 0` : `0 ${gap}px`,
            //            border: `${gap}px solid transparent`,
            //            borderWidth: vertical ? `${gap}px 0` : `0 ${gap}px`,
            'column-width': 'auto',
            'height': 'auto',
            'width': 'auto',

            //            // columnize parity
            // columnGap: '0',
            '--paginator-column-gap': `${gap}px`,
            'column-gap': `${gap}px`,
            'column-fill': 'auto',
            'overflow': 'hidden',
            'overflow-wrap': isJapanese ? 'normal' : 'anywhere',
            'word-break': 'normal',
            'line-break': isJapanese ? 'strict' : 'auto',
            '-webkit-line-break': isJapanese ? 'strict' : 'auto',
            // reset some potentially problematic props
            'position': 'static',
            'border': '0',
            'margin': '0',
            'max-height': 'none',
            'max-width': 'none',
            'min-height': 'none',
            'min-width': 'none',
            // fix glyph clipping in WebKit
            '-webkit-line-box-contain': 'block glyphs replaced',

            // columnize parity
            '--paginator-margin': '30px',
        })
        // columnize parity
        setStylesImportant(doc.body, {
            [vertical ? 'max-height' : 'max-width']: `${columnWidth}px`,
            'margin': 'auto',
        })
        this.setImageSize()
        this.#debouncedExpand()
        //        await this.expand()
    }
    async columnize({
        width,
        height,
        gap,
        columnWidth,
        divisor,
    }) {
        //        console.log("columnize...")
        await this.#awaitDirection();
        //        console.log("columnize... await'd direction")
        const vertical = this.#vertical
        this._size = vertical ? height : width
        //        console.log("columnize _size = ", this._size)

        const doc = this.document
        const { isJapanese } = getJapaneseLayoutFlags(doc)
        const paginationSide = vertical ? 'height' : 'width'
        const paginationOtherSide = paginationSide === 'width' ? 'height' : 'width'
        let preMeasureGeometryChanged = false
        setStylesImportant(doc.documentElement, {
            'box-sizing': 'border-box',
            'column-width': `${Math.trunc(columnWidth)}px`,
            '--paginator-column-gap': `${gap}px`,
            'column-gap': `${gap}px`,
            'column-fill': 'auto',
            'width': `${width}px`,
            'height': `${height}px`,
            'padding': vertical ? `${gap / 2}px 0` : `0 ${gap / 2}px`,
            'overflow': 'hidden',
            'overflow-wrap': isJapanese ? 'normal' : 'break-word',
            'word-break': 'normal',
            'line-break': isJapanese ? 'strict' : 'auto',
            '-webkit-line-break': isJapanese ? 'strict' : 'auto',
            // reset some potentially problematic props
            'position': 'static',
            'border': '0',
            'margin': '0',
            'max-height': 'none',
            'max-width': 'none',
            'min-height': 'none',
            'min-width': 'none',
            // fix glyph clipping in WebKit
            '-webkit-line-box-contain': 'block glyphs replaced',
        })
        manabiSetPropertyIfChanged(doc.documentElement.style, '--paginator-margin', `30px`)
        setStylesImportant(doc.body, {
            'max-height': 'none',
            'max-width': 'none',
            'margin': '0',
        })
        preMeasureGeometryChanged =
            manabiSetStyleIfChanged(this.#iframe.style, paginationSide, `${this._size}px`) || preMeasureGeometryChanged
        preMeasureGeometryChanged =
            manabiSetStyleIfChanged(this.#element.style, paginationSide, `${this._size}px`) || preMeasureGeometryChanged
        preMeasureGeometryChanged =
            manabiSetStyleIfChanged(this.#iframe.style, paginationOtherSide, '100%') || preMeasureGeometryChanged
        preMeasureGeometryChanged =
            manabiSetStyleIfChanged(this.#element.style, paginationOtherSide, '100%') || preMeasureGeometryChanged
        this.setImageSize()
        // Don't infinite loop.
        //        if (!this.needsRenderForMutation) {
        //        console.log("columnize... await expand")
        await this.expand()
        //        console.log("columnize... await'd expand")
        //            //            this.#debouncedExpand()
        //        }
    }
    async #awaitDirection() {
        if (this.#vertical === null) await this.#directionReady;
    }
    setImageSize() {
        const {
            width,
            height,
            topMargin = 0,
            bottomMargin = 0,
            margin = 0,
        } = this.layout || {};
        const vertical = this.#vertical;
        const doc = this.document;
        const numericWidth = Number.isFinite(width) ? width : 0;
        const numericHeight = Number.isFinite(height) ? height : 0;
        const verticalMaxWidth = Math.max(1, numericWidth - margin * 2);
        const horizontalMaxHeight = Math.max(1, numericHeight - topMargin - bottomMargin - margin * 2);
        let imageCount = 0;
        const parentMediaCounts = new WeakMap();
        const mediaOnlyCache = new WeakMap();
        const textNodeType = doc?.defaultView?.Node?.TEXT_NODE ?? 3;
        const nodeFilter = doc?.defaultView?.NodeFilter ?? globalThis.NodeFilter ?? null;
        const showText = nodeFilter?.SHOW_TEXT ?? 4;
        const filterAccept = nodeFilter?.FILTER_ACCEPT ?? 1;
        const filterReject = nodeFilter?.FILTER_REJECT ?? 2;
        const mediaSelector = 'img, svg, image, picture, video, object, iframe, canvas, embed';
        const ignoredTextContainerSelector = `${mediaSelector}, script, style, noscript`;
        const hasSubstantiveDirectText = parent => {
            for (const node of parent?.childNodes || []) {
                if (node.nodeType === textNodeType && /\S/.test(node.textContent || '')) {
                    return true;
                }
            }
            return false;
        };
        const hasSubstantiveTextExcludingMedia = element => {
            if (!element) return false;
            if (mediaOnlyCache.has(element)) {
                return !mediaOnlyCache.get(element);
            }
            const walker = doc.createTreeWalker?.(element, showText, {
                acceptNode: node => {
                    const parent = node?.parentElement;
                    if (!parent || parent.closest?.(ignoredTextContainerSelector)) {
                        return filterReject;
                    }
                    return /\S/.test(node.textContent || '')
                        ? filterAccept
                        : filterReject;
                },
            });
            const hasText = !!walker?.nextNode?.();
            mediaOnlyCache.set(element, !hasText);
            return hasText;
        };
        const applyVerticalMediaWrapperSizing = element => {
            if (!vertical || !element || element === doc.body || element === doc.documentElement) return;
            setStylesImportant(element, {
                'block-size': 'fit-content',
                'width': 'fit-content',
                'max-block-size': '100%',
                'break-inside': 'auto',
                'page-break-inside': 'auto',
                '-webkit-column-break-inside': 'auto',
                'box-sizing': 'border-box',
            });
        };
        for (const el of doc?.body?.querySelectorAll?.('img, svg, video') || []) {
            imageCount += 1;
            const inlineMaxHeight = el.style.maxHeight;
            const inlineMaxWidth = el.style.maxWidth;
            Object.assign(el.style, {
                maxHeight: vertical
                    ? (inlineMaxHeight && inlineMaxHeight !== 'none' && inlineMaxHeight !== '0px' ? inlineMaxHeight : '100%')
                    : `${horizontalMaxHeight}px`,
                maxWidth: vertical
                    ? `${verticalMaxWidth}px`
                    : (inlineMaxWidth && inlineMaxWidth !== 'none' && inlineMaxWidth !== '0px' ? inlineMaxWidth : '100%'),
                objectFit: 'contain',
                pageBreakInside: vertical ? 'auto' : 'avoid',
                breakInside: vertical ? 'auto' : 'avoid',
                boxSizing: 'border-box',
            });
            const parent = el.parentElement;
            let parentMediaCount = parentMediaCounts.get(parent);
            if (parent && parentMediaCount == null) {
                parentMediaCount = parent.querySelectorAll?.('img, svg, video')?.length ?? 0;
                parentMediaCounts.set(parent, parentMediaCount);
            }
            if (parent && parent !== doc.body && !hasSubstantiveDirectText(parent) && parentMediaCount === 1) {
                Object.assign(parent.style, {
                    pageBreakInside: vertical ? 'auto' : 'avoid',
                    breakInside: vertical ? 'auto' : 'avoid',
                    webkitColumnBreakInside: vertical ? 'auto' : 'avoid',
                    boxSizing: 'border-box',
                });
            }
            let ancestor = parent;
            while (vertical && ancestor && ancestor !== doc.body && ancestor !== doc.documentElement) {
                if (ancestor.matches?.('p, figure, div')) {
                    let ancestorMediaCount = parentMediaCounts.get(ancestor);
                    if (ancestorMediaCount == null) {
                        ancestorMediaCount = ancestor.querySelectorAll?.(mediaSelector)?.length ?? 0;
                        parentMediaCounts.set(ancestor, ancestorMediaCount);
                    }
                    if (ancestorMediaCount === 1 && !hasSubstantiveTextExcludingMedia(ancestor)) {
                        applyVerticalMediaWrapperSizing(ancestor);
                    }
                }
                ancestor = ancestor.parentElement;
            }
        }
        if (globalThis.manabiVerboseImageLayout === true) {
        }
    }
    #makeExpandSignature() {
        const doc = this.document
        return JSON.stringify({
            column: !!this._column,
            vertical: !!this.#vertical,
            rtl: !!this.#rtl,
            size: manabiRound(Number(this._size) || 0, 2),
            render: this.#renderInFlightSignature || this.#lastRenderSignature,
            href: doc?.location?.href ?? null,
        })
    }
    #columnizationDiagnostics(extra = {}) {
        const doc = this.document
        const documentElement = doc?.documentElement ?? null
        const body = doc?.body ?? null
        const rootStyleProperties = [
            'width',
            'height',
            'padding-top',
            'padding-bottom',
            'padding-left',
            'padding-right',
            'column-width',
            'column-gap',
            'column-fill',
            'overflow',
            'writing-mode',
            'direction',
        ];
        const bodyStyleProperties = [
            'width',
            'height',
            'max-width',
            'max-height',
            'margin',
            'writing-mode',
            'direction',
        ];
        const elementStyleProperties = [
            'width',
            'height',
            'padding',
            'overflow',
        ];
        return {
            ...extra,
            cacheWarmer: this.#isCacheWarmer,
            column: this._column,
            vertical: this.#vertical,
            rtl: this.#rtl,
            size: this._size,
            topMargin: this.layout?.topMargin ?? null,
            bottomMargin: this.layout?.bottomMargin ?? null,
            layoutWidth: this.layout?.width ?? extra.layoutWidth ?? null,
            layoutHeight: this.layout?.height ?? extra.layoutHeight ?? null,
            layoutGap: this.layout?.gap ?? extra.layoutGap ?? null,
            layoutColumnWidth: this.layout?.columnWidth ?? extra.layoutColumnWidth ?? null,
            layoutDivisor: this.layout?.divisor ?? extra.layoutDivisor ?? null,
            iframeConnected: this.#iframe?.isConnected === true,
            documentReadyState: doc?.readyState ?? null,
            fontsStatus: doc?.fonts?.status ?? null,
            bodyTextLength: body?.textContent?.trim?.().length ?? null,
            ...manabiElementDiagnostics('container', this.container, elementStyleProperties),
            ...manabiElementDiagnostics('view', this.#element, elementStyleProperties),
            ...manabiElementDiagnostics('iframe', this.#iframe, elementStyleProperties),
            ...manabiElementDiagnostics('root', documentElement, rootStyleProperties),
            ...manabiElementDiagnostics('body', body, bodyStyleProperties),
        };
    }
    async expand({ skipIfSignatureUnchanged = false } = {}) {
        const expandStartedAt = manabiPerfNow();
        //        console.log("expand...")
        return new Promise((resolve, reject) => {
            requestAnimationFrame(async () => {
                let expandSignature = null
                try {
                    //                console.log("expand... inside 0")
                    const doc = this.document
                    const documentElement = doc?.documentElement
                    if (!doc?.body || !documentElement || !this.#iframe?.isConnected) {
                        resolve()
                        return
                    }
                    const defaultSide = this.#vertical ? 'height' : 'width'
                    const defaultOtherSide = defaultSide === 'width' ? 'height' : 'width'
                    let expandedMetrics = null
                    expandSignature = this.#makeExpandSignature()
                    if (skipIfSignatureUnchanged
                        && this.#lastExpandSignature === expandSignature
                        && this.#lastExpandedMetrics?.loadingSettled === true) {
                        manabiTimelineMark('paginator.expand.skipSameSignature', {
                            cacheWarmer: this.#isCacheWarmer,
                            column: this._column,
                            vertical: this.#vertical,
                        });
                        resolve()
                        return
                    }
                    await this.onBeforeExpand()
                    if (this._column) {
                        const contentRect = this.#contentRange.getBoundingClientRect()
                        const inlineProgression = this.#usesInlineProgressionForVerticalColumn(contentRect)
                        const side = inlineProgression ? 'width' : defaultSide
                        const otherSide = side === 'width' ? 'height' : 'width'
                        const scrollProp = inlineProgression ? 'scrollLeft' : null
                        // offset caused by column break at the start of the page
                        // which seem to be supported only by WebKit and only for horizontal writing
                        const contentStart = this.#vertical ? 0 : (() => {
                            const rootRect = documentElement.getBoundingClientRect()
                            return this.#rtl ? rootRect.right - contentRect.right : contentRect.left - rootRect.left
                        })()
                        const contentSize = contentStart + contentRect[side]
                        const pageCount = Math.ceil(contentSize / this._size)
                        const expandedSize = pageCount * this._size
                        const remainder = this._size > 0 ? contentSize % this._size : null
                        expandedMetrics = {
                            column: true,
                            side,
                            otherSide,
                            contentRectWidth: contentRect.width,
                            contentRectHeight: contentRect.height,
                            contentSize,
                            expandedSize,
                            pageCount,
                            size: this._size,
                            inlineProgression,
                            scrollProp,
                            contentStart,
                            remainder,
                        }
                        let geometryChanged = false
                        geometryChanged = manabiSetStyleIfChanged(this.#element.style, 'padding', '0') || geometryChanged
                        geometryChanged = manabiSetStyleIfChanged(this.#iframe.style, side, `${expandedSize}px`) || geometryChanged
                        geometryChanged = manabiSetStyleIfChanged(this.#element.style, side, `${expandedSize + this._size * 2}px`) || geometryChanged
                        geometryChanged = manabiSetStyleIfChanged(this.#iframe.style, otherSide, '100%') || geometryChanged
                        geometryChanged = manabiSetStyleIfChanged(this.#element.style, otherSide, '100%') || geometryChanged
                        if (documentElement) {
                            geometryChanged = manabiSetStyleIfChanged(documentElement.style, side, `${this._size}px`) || geometryChanged
                        }
                        if (this.#overlayer) {
                            geometryChanged = manabiSetStyleIfChanged(this.#overlayer.element.style, 'margin', '0') || geometryChanged
                            geometryChanged = manabiSetStyleIfChanged(this.#overlayer.element.style, 'left', this.#vertical ? '0' : `${this._size}px`) || geometryChanged
                            geometryChanged = manabiSetStyleIfChanged(this.#overlayer.element.style, 'top', this.#vertical ? `${this._size}px` : '0') || geometryChanged
                            geometryChanged = manabiSetStyleIfChanged(this.#overlayer.element.style, side, `${expandedSize}px`) || geometryChanged
                            if (geometryChanged) {
                                this.#overlayer.redraw()
                            }
                        }
                        if (!this.#isCacheWarmer) {
                            const appliedContentRect = this.#contentRange.getBoundingClientRect()
                            const appliedContentStart = this.#vertical ? 0 : (() => {
                                const rootRect = documentElement.getBoundingClientRect()
                                return this.#rtl ? rootRect.right - appliedContentRect.right : appliedContentRect.left - rootRect.left
                            })()
                            const appliedContentSize = appliedContentStart + appliedContentRect[side]
                            const appliedRemainder = this._size > 0 ? appliedContentSize % this._size : null
                        }
                    } else {
                        const side = defaultSide
                        const otherSide = defaultOtherSide
                        const contentSize = documentElement.getBoundingClientRect()[side]
                        const expandedSize = contentSize
                        expandedMetrics = {
                            column: false,
                            side,
                            otherSide,
                            contentRectWidth: null,
                            contentRectHeight: null,
                            contentSize,
                            expandedSize,
                            pageCount: this._size > 0 ? Math.max(1, Math.ceil(expandedSize / this._size)) : 0,
                            size: this._size,
                            inlineProgression: false,
                            scrollProp: null,
                        }
                        const {
                            topMargin,
                            bottomMargin
                        } = this.layout
                        //                    const paddingTop = `${marginTop}px`
                        //                    const paddingBottom = `${marginBottom}px`
                        const paddingTop = `${topMargin}px`
                        const paddingBottom = `${bottomMargin}px`
                        if (this.#vertical) {
                            manabiSetStyleIfChanged(this.#element.style, 'paddingLeft', paddingTop)
                            manabiSetStyleIfChanged(this.#element.style, 'paddingRight', paddingBottom)
                            manabiSetStyleIfChanged(this.#element.style, 'paddingTop', '0')
                            manabiSetStyleIfChanged(this.#element.style, 'paddingBottom', '0')
                        } else {
                            manabiSetStyleIfChanged(this.#element.style, 'paddingLeft', '0')
                            manabiSetStyleIfChanged(this.#element.style, 'paddingRight', '0')
                            manabiSetStyleIfChanged(this.#element.style, 'paddingTop', paddingTop)
                            manabiSetStyleIfChanged(this.#element.style, 'paddingBottom', paddingBottom)
                        }
                        manabiSetStyleIfChanged(this.#iframe.style, side, `${expandedSize}px`)
                        manabiSetStyleIfChanged(this.#element.style, side, `${expandedSize}px`)
                        manabiSetStyleIfChanged(this.#iframe.style, otherSide, '100%')
                        manabiSetStyleIfChanged(this.#element.style, otherSide, '100%')
                        if (this.#overlayer) {
                            let overlayerChanged = false
                            if (this.#vertical) {
                                overlayerChanged = manabiSetStyleIfChanged(this.#overlayer.element.style, 'marginLeft', paddingTop) || overlayerChanged
                                overlayerChanged = manabiSetStyleIfChanged(this.#overlayer.element.style, 'marginRight', paddingBottom) || overlayerChanged
                                overlayerChanged = manabiSetStyleIfChanged(this.#overlayer.element.style, 'marginTop', '0') || overlayerChanged
                                overlayerChanged = manabiSetStyleIfChanged(this.#overlayer.element.style, 'marginBottom', '0') || overlayerChanged
                            } else {
                                overlayerChanged = manabiSetStyleIfChanged(this.#overlayer.element.style, 'marginLeft', '0') || overlayerChanged
                                overlayerChanged = manabiSetStyleIfChanged(this.#overlayer.element.style, 'marginRight', '0') || overlayerChanged
                                overlayerChanged = manabiSetStyleIfChanged(this.#overlayer.element.style, 'marginTop', paddingTop) || overlayerChanged
                                overlayerChanged = manabiSetStyleIfChanged(this.#overlayer.element.style, 'marginBottom', paddingBottom) || overlayerChanged
                            }
                            overlayerChanged = manabiSetStyleIfChanged(this.#overlayer.element.style, 'left', '0') || overlayerChanged
                            overlayerChanged = manabiSetStyleIfChanged(this.#overlayer.element.style, 'top', '0') || overlayerChanged
                            overlayerChanged = manabiSetStyleIfChanged(this.#overlayer.element.style, side, `${expandedSize}px`) || overlayerChanged
                            if (overlayerChanged) {
                                this.#overlayer.redraw()
                            }
                        }
                    }
                    //                console.log("expand... call onexpand")
                    this.#lastExpandSignature = expandSignature
                    this.#lastExpandedMetrics = expandedMetrics
                    await this.onExpand(expandedMetrics)
                    if (this.#lastExpandedMetrics) {
                        this.#lastExpandedMetrics.loadingSettled = true
                    }
                    //                console.log("expand... call'd onexpand")
                    resolve()
                } catch (error) {
                    reject(error)
                } finally {
                    manabiTimelineMeasure('paginator.expand.raf', expandStartedAt, {
                        cacheWarmer: this.#isCacheWarmer,
                        column: this._column,
                        scrolled: !this._column,
                        vertical: this.#vertical,
                    });
                }
            })
        })
    }
    set overlayer(overlayer) {
        this.#overlayer = overlayer
        this.#element.append(overlayer.element)
    }
    get overlayer() {
        return this.#overlayer
    }
    #usesInlineProgressionForVerticalColumn(contentRect) {
        if (!this.#vertical || !this._column) return false
        const body = this.document?.body
        if (!body) return false
        const isEBook = body.dataset?.isEbook === 'true' || body.classList?.contains?.('readability-mode')
        const isManabiVertical = body.dataset?.mnbFoliateWritingDirection === 'vertical'
            || body.classList?.contains?.('reader-vertical-writing')
        if (!isEBook || !isManabiVertical) return false
        const rectWidth = Number(contentRect?.width) || 0
        const rectHeight = Number(contentRect?.height) || 0
        const scrollWidth = Number(body.scrollWidth) || 0
        const scrollHeight = Number(body.scrollHeight) || 0
        return rectWidth > rectHeight * 2 && scrollWidth > scrollHeight * 2
    }
    prepareForReuse() {
        this.#loadCleanup?.()
        this.#loadCleanup = null
        const body = this.document?.body
        if (body) this.#resizeObserver.unobserve(body)
        this.#overlayer?.element?.remove?.()
        this.#overlayer = null
    }
    destroy() {
        this.prepareForReuse()
        //        if (this.document) this.#mutationObserver.disconnect()
    }
}

// NOTE: everything here assumes the so-called "negative scroll type" for RTL
export class Paginator extends HTMLElement {
    static observedAttributes = [
        'flow', 'gap', 'marginTop', 'marginBottom',
        'max-inline-size', 'max-block-size', 'max-column-count',
    ]
    #root = this.attachShadow({
        mode: 'closed'
    })
    #debouncedRender = this.render.bind(this)
    #lastResizerRect = null
    #resizeObserver = new ResizeObserver(entries => {
        if (this.#isCacheWarmer) return;

        const entry = entries[0];
        const rect = entry.contentRect;

        const newSize = {
            width: Math.round(rect.width),
            height: Math.round(rect.height),
            top: Math.round(rect.top),
            left: Math.round(rect.left),
        };
        //        console.log("RESIZE OBS...", newSize)

        const old = this.#lastResizerRect
        const unchanged =
            old &&
            newSize.width === old.width &&
            newSize.height === old.height &&
            newSize.top === old.top &&
            newSize.left === old.left

        if (unchanged) {
            return
        }

        this.#lastResizerRect = newSize
        this.#cachedSizes = null
        this.#sizesPromise = null
        //            console.log("sizes() from resize updated to ", this.#cachedSizes)
        this.#cachedStart = null
        this.#invalidateVisibleRangeCache()

        if (this.#isLoading) {
            return
        }

        //        this.render()
        //        requestAnimationFrame(() => {
        this.#debouncedRender();
        //        })
    })
    #top
    #transitioning = false;
    //    #background
    #container
    #header
    #footer
    #view
    #vertical = null
    #verticalRTL = null
    #rtl = null
    #directionReadyResolve = null;
    #directionReady = new Promise(r => (this.#directionReadyResolve = r));
    #topMargin = 0
    #bottomMargin = 0
    #index = -1
    #anchor = 0 // anchor view to a fraction (0-1), Range, or Element
    #justAnchored = false
    #isLoading = false
    #locked = false // while true, prevent any further navigation
    #lockedAt = null
    #queuedPageTurn = null
    #styles
    #styleMap = new WeakMap()
    #scrollBounds
    #touchState
    #touchScrolled
    #isCacheWarmer = false
    #skipTouchEndOpacity = false
    #isAdjustingSelectionHandle = false
    #wheelArmed = true // Hysteresis-based horizontal wheel paging
    #suspendOnExpandAnchor = false
    #prefetchTimer = null
    #prefetchCache = new Map()
    #pendingPageTurnDirection = null
    #pendingPageTurnStep = null
    #pendingPageTurnQueueAllowed = false
    #pendingPageTurnRequestedPage = null
    #pendingPageTurnPageCount = null
    #lastSettledPageTurn = null

    #cachedSizes = null
    #cachedStart = null
    #sizesPromise = null
    #viewSizePromise = null
    #lastRenderContainerSize = null
    #lastTypographyRenderSignature = null
    #renderInFlightTypographySignature = null
    #renderInFlightPromise = null
    #visibleRangeCache = null
    #visibleRangeInFlight = null
    #visibleRangeCacheVersion = 0
    #pageMetricsCache = null
    #lastRelocateDispatchSignature = null
    #elementVisibilityObserver = null
    #elementMutationObserver = null
    #mediaVisualDiagnosticsToken = 0
    #loadingWatchdogToken = 0

    constructor() {
        super()
        const {
            gapPct,
            topMarginPx,
            bottomMarginPx,
            sideMarginPx,
            maxInlineSizePx,
            maxBlockSizePx,
            maxColumnCount,
            maxColumnCountPortrait
        } = CSS_DEFAULTS;
        const topSpacingCSS = MANABI_ENABLE_COLUMNIZATION_OPTIMIZATIONS
            ? `
                --_top-margin: ${topMarginPx}px;
                --_bottom-margin: ${bottomMarginPx}px;
                --_side-margin: var(--side-nav-width, ${sideMarginPx}px);
            `
            : `--_margin: ${topMarginPx}px;`;
        const gridTemplateColumnsCSS = MANABI_ENABLE_COLUMNIZATION_OPTIMIZATIONS
            ? `
                var(--_side-margin)
                1fr
                minmax(0, calc(var(--_max-width) - var(--_gap)))
                1fr
                var(--_side-margin)
            `
            : `
                minmax(var(--_half-gap), 1fr)
                var(--_half-gap)
                minmax(0, calc(var(--_max-width) - var(--_gap)))
                var(--_half-gap)
                minmax(var(--_half-gap), 1fr)
            `;
        const gridTemplateRowsCSS = MANABI_ENABLE_COLUMNIZATION_OPTIMIZATIONS
            ? `
                minmax(var(--_top-margin), 1fr)
                minmax(0, var(--_max-height))
                minmax(var(--_bottom-margin), 1fr)
            `
            : `
                minmax(var(--_margin), 1fr)
                minmax(0, var(--_max-height))
                minmax(var(--_margin), 1fr)
            `;
        const headerFooterHeightCSS = MANABI_ENABLE_COLUMNIZATION_OPTIMIZATIONS
            ? `
                #header {
                    height: var(--_top-margin);
                }
                #footer {
                    height: var(--_bottom-margin);
                }
            `
            : `
                #header, #footer {
                    height: var(--_margin);
                }
            `;
        const verticalPaginatedCSS = MANABI_ENABLE_COLUMNIZATION_OPTIMIZATIONS
            ? `
                #top.mnb-vertical-paginated {
                    grid-template-rows: 0 minmax(0, 1fr) 0;
                }
                #top.mnb-vertical-paginated #container {
                    grid-row: 1 / -1;
                }
                #top.mnb-vertical-paginated #header,
                #top.mnb-vertical-paginated #footer {
                    display: none;
                    height: 0;
                }
            `
            : '';
        this.#root.innerHTML = `<style>
            :host {
                display: block;
                container-type: size;
            }
            :host, #top {
                box-sizing: border-box;
                position: relative;
                overflow: hidden;
                width: 100%;
                height: 100%;
            }
            #top {
                --_gap: ${gapPct}%;
                ${topSpacingCSS}
                --_max-inline-size: ${maxInlineSizePx}px;
                --_max-block-size: ${maxBlockSizePx}px;
                --_max-column-count: ${maxColumnCount};
                --_max-column-count-portrait: ${maxColumnCountPortrait};
                --_max-column-count-spread: var(--_max-column-count);
                --_half-gap: calc(var(--_gap) / 2);
                --_max-width: calc(var(--_max-inline-size) * var(--_max-column-count-spread));
                --_max-height: var(--_max-block-size);
                display: grid;
                grid-template-columns: ${gridTemplateColumnsCSS};
                grid-template-rows: ${gridTemplateRowsCSS};
                &.vertical {
                    --_max-column-count-spread: var(--_max-column-count-portrait);
                    --_max-width: var(--_max-block-size);
                    --_max-height: calc(var(--_max-inline-size) * var(--_max-column-count-spread));
                }
                @container (orientation: portrait) {
                    & {
                        --_max-column-count-spread: var(--_max-column-count-portrait);
                    }
                    &.vertical {
                        --_max-column-count-spread: var(--_max-column-count);
                    }
                }
            }
            #top.reader-loading {
                pointer-events: none;
            }
            /* #background {
                grid-column: 1 / -1;
                grid-row: 1 / -1;
            } */
            #container {
                grid-column: 2 / 5;
                grid-row: 2;
                position: relative;
                overflow: hidden;
            }
            :host([flow="scrolled"]) #container {
                grid-column: 1 / -1;
                grid-row: 1 / -1;
                overflow: auto;
            }
            ${verticalPaginatedCSS}
            #header {
                grid-column: 3 / 4;
                grid-row: 1;
            }
            #footer {
                grid-column: 3 / 4;
                grid-row: 3;
                align-self: end;
            }
            #header, #footer {
                display: grid;
            }
            ${headerFooterHeightCSS}
            :is(#header, #footer) > * {
                display: flex;
                align-items: center;
                min-width: 0;
            }
            :is(#header, #footer) > * > * {
                width: 100%;
                overflow: hidden;
                white-space: nowrap;
                text-overflow: ellipsis;
                text-align: center;
                font-size: .75em;
                opacity: .6;
            }        
            /* For page-turning */
            .view-fade {
                opacity: 0.45;
                /*transition: opacity 0.85s ease-out;*/
            }
            .view-faded {
                opacity: 0.45;
            }
        </style>
        <div id="top">
            <!-- <div id="background" part="filter"></div> -->
            <div id="header"></div>
            <div id="container"></div>
            <div id="footer"></div>
        </div>
        `

        this.#top = this.#root.getElementById('top')
        //        this.#background = this.#root.getElementById('background')
        this.#container = this.#root.getElementById('container')
        this.#header = this.#root.getElementById('header')
        this.#footer = this.#root.getElementById('footer')

        this.#resizeObserver.observe(this.#container)

        this.#container.addEventListener('scroll', () => {
            const cached = this.#pageMetricsCache
            const currentStart = cached?.scrollProp
                ? Math.abs(this.#container[cached.scrollProp] ?? NaN)
                : NaN
            const preservesProgrammaticMetrics = cached
                && Number.isFinite(cached.start)
                && Number.isFinite(currentStart)
                && Math.abs(currentStart - cached.start) < 1
            if (!preservesProgrammaticMetrics) {
                this.#cachedStart = null
                this.#invalidatePageMetricsCache()
            }
            this.dispatchEvent(new Event('scroll'))
        })

        // Continuously fire relocate during scroll
        this.#container.addEventListener('scroll', debounce(async () => {
            if (this.#view.isLoading) return;
            if (this.scrolled && !this.#isCacheWarmer) {
                const index = this.#index;
                let fraction = 0;
                const metrics = await this.pageMetrics();
                if (this.scrolled) {
                    fraction = metrics.viewSize > 0 ? metrics.start / metrics.viewSize : 0;
                } else if (metrics.pages > 0) {
                    const { page, pages } = metrics;
                    fraction = (page - 1) / (pages - 2);
                }
                // Don't include all details, just enough for the slider
                this.dispatchEvent(new CustomEvent('relocate', {
                    detail: {
                        reason: 'live-scroll',
                        index,
                        fraction
                    }
                }));
            }
        }, 450));

        this.#container.addEventListener('scroll', debounce(async () => {
            if (this.scrolled) {
                if (this.#justAnchored) {
                    this.#justAnchored = false
                } else {
                    await this.#afterScroll('scroll')
                }
            }
        }, 450))
    }

    // NOTE: In this foliate-js fork, currently paginator can only open a book once
    open(book, isCacheWarmer = false) {
        // Keep layout measurable; hide visually until first anchor is settled.
        if (isCacheWarmer) {
            this.style.display = 'none'
        } else {
            this.style.display = 'block'
            this.style.visibility = 'hidden'
        }

        this.#isCacheWarmer = isCacheWarmer
        this.bookDir = book.dir
        this.sections = book.sections

        if (!this.#isCacheWarmer) {
            const opts = {
                passive: false
            }
            this.addEventListener('touchstart', this.#onTouchStart.bind(this), opts)
            this.addEventListener('touchmove', this.#onTouchMove.bind(this), opts)
            this.addEventListener('touchend', this.#onTouchEnd.bind(this))
            this.addEventListener('load', ({
                detail: {
                    doc
                }
            }) => {
                doc.addEventListener('touchstart', this.#onTouchStart.bind(this), opts)
                doc.addEventListener('touchmove', this.#onTouchMove.bind(this), opts)
                doc.addEventListener('touchend', this.#onTouchEnd.bind(this))
            })
            this.addEventListener('wheel', this.#onWheel.bind(this), opts);
        }
    }
    setSideNavWidth(widthPx) {
        this.#top?.style?.setProperty('--side-nav-width', typeof widthPx === 'number' ? `${widthPx}px` : widthPx);
    }
    #createView({ replacement = false } = {}) {
        if (this.#view && !replacement) return this.#view
        this.#invalidateVisibleRangeCache()
        const view = new View({
            container: this,
            onBeforeExpand: this.#onBeforeExpand.bind(this),
            onExpand: this.#onExpand.bind(this),
            isCacheWarmer: this.#isCacheWarmer,
            //            onExpand: debounce(() => this.#onExpand.bind(this), 500),
        })
        if (!replacement) this.#view = view
        this.#container.append(view.element)
        return view
    }
    #commitView(view) {
        if (!view) return
        Object.assign(view.element.style, {
            position: 'relative',
            inset: '',
            visibility: '',
            pointerEvents: '',
            zIndex: '',
        })
        this.#view = view
    }
    #discardView(view) {
        if (!view || view === this.#view) return
        view.destroy()
        view.element.remove()
    }
    #installStyleElementsForDocument(doc) {
        if (!doc?.head) return
        if (this.#styleMap.has(doc)) return
        const $styleBefore = doc.createElement('style')
        doc.head.prepend($styleBefore)
        const $style = doc.createElement('style')
        doc.head.append($style)
        this.#styleMap.set(doc, [$styleBefore, $style])
    }
    #applyStylesToDocument(doc, styles = this.#styles) {
        const $$styles = this.#styleMap.get(doc)
        if (!$$styles) return
        const [$beforeStyle, $style] = $$styles
        if (Array.isArray(styles)) {
            const [beforeStyle, style] = styles
            $beforeStyle.textContent = beforeStyle
            $style.textContent = style
        } else {
            $style.textContent = styles ?? ''
        }
    }
    #setLoading(isLoading, reason = 'unknown') {
        if (this.#isLoading === isLoading) return
        this.#isLoading = isLoading;
        if (isLoading) {
            this.#top.classList.add('reader-loading');
        } else {
            this.#top.classList.remove('reader-loading');
        }
        if (!this.#isCacheWarmer) {
            manabiPaginatorReaderLoadLog('paginator.loading.state', this.#displayLifecycleDiagnostics('loading.state', {
                reason,
                isLoading,
            }))
            const token = ++this.#loadingWatchdogToken
            if (isLoading) {
                for (const delayMs of [5000, 30000]) {
                    setTimeout(() => {
                        if (token !== this.#loadingWatchdogToken || !this.#isLoading) return
                        manabiPaginatorReaderLoadLog('paginator.loading.watchdog', this.#displayLifecycleDiagnostics('loading.watchdog', {
                            reason,
                            delayMs,
                            isLoading: this.#isLoading,
                        }))
                    }, delayMs)
                }
            }
        }
    }
    #cacheNeighborPrefetch(index, promise) {
        const entry = {
            promise: null,
            fulfilled: false,
            rejected: false,
            released: false,
            dropped: false,
        }
        entry.promise = Promise.resolve(promise)
            .then(value => {
                entry.fulfilled = true
                if (entry.dropped) this.#releaseNeighborPrefetch(index, entry, false)
                return value
            })
            .catch(error => {
                entry.rejected = true
                if (this.#prefetchCache.get(index) === entry) {
                    this.#prefetchCache.delete(index)
                }
                throw error
            })
        this.#prefetchCache.set(index, entry)
        return entry
    }
    #releaseNeighborPrefetch(index, entry = this.#prefetchCache.get(index), remove = true) {
        if (!entry || entry.released) return
        if (remove && this.#prefetchCache.get(index) === entry) {
            this.#prefetchCache.delete(index)
        }
        if (!entry.fulfilled) {
            entry.dropped = true
            return
        }
        entry.released = true
        this.sections[index]?.unload?.()
    }
    #consumeNeighborPrefetch(index, entry = this.#prefetchCache.get(index)) {
        if (!entry || entry.released) return
        if (this.#prefetchCache.get(index) === entry) {
            this.#prefetchCache.delete(index)
        }
        entry.released = true
        entry.consumed = true
    }
    async #isWithinNeighborPrefetchWindow() {
        if (!this.#view || this.#isCacheWarmer) return false
        try {
            const metrics = await this.pageMetrics()
            const lastReadablePage = Math.max(1, metrics.pages - 2)
            const remainingPages = Math.max(0, lastReadablePage - metrics.page)
            return remainingPages <= MANABI_NEIGHBOR_PREFETCH_END_PAGE_THRESHOLD
        } catch (_error) {
            return false
        }
    }
    #scheduleNeighborPrefetch(reason = 'unknown', delayMs = MANABI_NEIGHBOR_PREFETCH_DELAY_MS) {
        if (!MANABI_ENABLE_NEIGHBOR_PREFETCH || this.#isCacheWarmer) return
        const index = this.#index
        clearTimeout(this.#prefetchTimer)
        this.#prefetchTimer = setTimeout(() => {
            void this.#refreshNeighborPrefetch(index, reason).catch(() => undefined)
        }, delayMs)
    }
    async #refreshNeighborPrefetch(index, reason = 'unknown') {
        if (this.#index !== index) return

        const nextIndex = this.#adjacentIndex(1)
        const withinPrefetchWindow = await this.#isWithinNeighborPrefetchWindow()
        const wanted = withinPrefetchWindow && nextIndex != null ? [nextIndex] : []
        const keep = new Set([index, ...wanted].filter(i => this.#prefetchCache.has(i)))
        for (const [i, entry] of this.#prefetchCache) {
            if (!keep.has(i)) this.#releaseNeighborPrefetch(i, entry)
        }

        wanted.forEach(i => {
            if (
                i >= 0 &&
                i < this.sections.length &&
                this.sections[i].linear !== 'no'
            ) {
                const entry = this.#prefetchCache.get(i)
                    ?? this.#cacheNeighborPrefetch(i, this.sections[i].load())
                void entry.promise.catch(() => undefined)
            }
        })
    }
    async #waitForNeighborPrefetch(index) {
        const entry = this.#prefetchCache.get(index)
        if (!entry?.promise) return null
        try {
            await entry.promise
        } catch (_error) {
            return null
        }
        return entry.fulfilled ? entry : null
    }
    async #onBeforeExpand() {
//        console.log("#onBeforeExpand...", this.style.display)
        this.#view.cachedViewSize = null;
        this.#viewSizePromise = null;
        this.#view.cachedSizes = null;
        this.#cachedStart = null;
        this.#invalidateVisibleRangeCache()
    }
    async #onExpand(expandedMetrics = null) {
//        console.log("#onExpand...", this.style.display)
        this.#view.cachedViewSize = null;
        this.#viewSizePromise = null;
        this.#view.cachedSizes = null;
        this.#cachedStart = null;
        this.#invalidateVisibleRangeCache()
        await this.#rememberExpandedPageMetrics(expandedMetrics)
        if (!this.#suspendOnExpandAnchor) {
            await this.#scrollToAnchor(this.#anchor)
        }

        if (!this.#isLoading) {
            return
        }
        this.#setLoading(false, 'expand.onExpand')
    }
    async #awaitDirection() {
        if (this.#vertical === null) await this.#directionReady;
    }
    #invalidateVisibleRangeCache() {
        this.#visibleRangeCache = null
        this.#visibleRangeInFlight = null
        this.#visibleRangeCacheVersion += 1
        this.#invalidatePageMetricsCache()
    }
    #invalidatePageMetricsCache() {
        this.#pageMetricsCache = null
    }
    #metricsWithStart(metrics, start) {
        if (!metrics || !Number.isFinite(start)) return metrics
        const size = metrics.size
        const end = start + size
        const measuredPage = size > 0 ? Math.floor(((start + end) / 2) / size) : 0
        const page = this.#logicalPageFromMeasuredPage({
            measuredPage,
            pages: metrics.pages,
            rawPages: metrics.rawPages,
        })
        return {
            ...metrics,
            start,
            end,
            page,
        }
    }
    #rememberPageMetrics(metrics) {
        if (!metrics) return
        this.#cachedStart = metrics.start
        this.#pageMetricsCache = metrics
    }
    async #rememberExpandedPageMetrics(expandedMetrics) {
        if (!expandedMetrics || !Number.isFinite(expandedMetrics.size) || expandedMetrics.size <= 0) {
            return
        }
        await this.#awaitDirection()
        const sideProp = expandedMetrics.side ?? await this.sideProp()
        const scrollProp = expandedMetrics.scrollProp ?? await this.scrollProp()
        const size = expandedMetrics.size
        const viewSize = expandedMetrics.column
            ? expandedMetrics.expandedSize + size * 2
            : expandedMetrics.expandedSize
        const rawPages = size > 0 ? Math.round(viewSize / size) : 0
        const pages = this.#normalizePages(rawPages)
        const start = Math.abs(this.#container?.[scrollProp] ?? 0)
        const end = start + size
        const measuredPage = size > 0 ? Math.floor(((start + end) / 2) / size) : 0
        const page = this.#logicalPageFromMeasuredPage({ measuredPage, pages, rawPages })
        this.#rememberPageMetrics({
            index: this.#index,
            scrolled: this.scrolled,
            vertical: this.#vertical,
            rtl: this.#rtl,
            sideProp,
            scrollProp,
            size,
            viewSize,
            start,
            end,
            page,
            pages,
            rawPages,
            source: 'expand',
            inlineProgression: expandedMetrics.inlineProgression === true,
        })
        if (!this.#isCacheWarmer && manabiPaginatorVerbosePageTurns()) {
            manabiPaginatorReaderLoadLog('paginator.expand.metrics', this.#layoutMetricDiagnostics(this.#pageMetricsCache, {
                reason: 'expand',
                contentRectWidth: expandedMetrics.contentRectWidth,
                contentRectHeight: expandedMetrics.contentRectHeight,
                contentSize: expandedMetrics.contentSize,
                pageCount: expandedMetrics.pageCount,
                expandedSize: expandedMetrics.expandedSize,
                normalizedPages: pages,
            }))
        }
    }
    #layoutMetricDiagnostics(metrics = null, extra = {}) {
        const container = this.#container
        const viewElement = this.#view?.element ?? null
        const doc = this.#view?.document ?? this.document ?? null
        const documentElement = doc?.documentElement ?? null
        const body = doc?.body ?? null
        const expanded = this.#view?.expandedMetrics ?? null
        const includeLiveLayoutMetrics =
            globalThis.__manabiPaginatorVerboseLayoutMetrics === true
            || globalThis.__manabiTimelineTraceAll === true
        const size = metrics?.size ?? expanded?.size ?? this._size ?? null
        const viewSize = metrics?.viewSize ?? (
            expanded
                ? (expanded.column ? expanded.expandedSize + expanded.size * 2 : expanded.expandedSize)
                : null
        )
        const rawPages = Number.isFinite(size) && size > 0 && Number.isFinite(viewSize)
            ? Math.round(viewSize / size)
            : null
        return {
            ...extra,
            index: this.#index,
            cacheWarmer: this.#isCacheWarmer,
            scrolled: this.scrolled,
            column: this._column,
            vertical: this.#vertical,
            rtl: this.#rtl,
            sideProp: metrics?.sideProp ?? null,
            scrollProp: metrics?.scrollProp ?? null,
            metricsSource: metrics?.metricsSource ?? metrics?.source ?? null,
            page: metrics?.page ?? null,
            pages: metrics?.pages ?? null,
            rawPages,
            size,
            viewSize,
            start: metrics?.start ?? null,
            end: metrics?.end ?? null,
            expandedColumn: expanded?.column ?? null,
            expandedSide: expanded?.side ?? null,
            expandedInlineProgression: expanded?.inlineProgression ?? null,
            inlineProgression: metrics?.inlineProgression ?? expanded?.inlineProgression ?? null,
            expandedContentSize: expanded?.contentSize ?? null,
            expandedSize: expanded?.expandedSize ?? null,
            expandedPageCount: expanded?.pageCount ?? null,
            ...(includeLiveLayoutMetrics ? {
                containerClientWidth: container?.clientWidth ?? null,
                containerClientHeight: container?.clientHeight ?? null,
                containerScrollWidth: container?.scrollWidth ?? null,
                containerScrollHeight: container?.scrollHeight ?? null,
                viewClientWidth: viewElement?.clientWidth ?? null,
                viewClientHeight: viewElement?.clientHeight ?? null,
                docClientWidth: documentElement?.clientWidth ?? null,
                docClientHeight: documentElement?.clientHeight ?? null,
                docScrollWidth: documentElement?.scrollWidth ?? null,
                docScrollHeight: documentElement?.scrollHeight ?? null,
                bodyClientWidth: body?.clientWidth ?? null,
                bodyClientHeight: body?.clientHeight ?? null,
                bodyScrollWidth: body?.scrollWidth ?? null,
                bodyScrollHeight: body?.scrollHeight ?? null,
                bodyTextLength: body?.textContent?.trim?.().length ?? null,
            } : null),
        }
    }
    #readerLoadDocumentSubpath(doc = this.#view?.document ?? null) {
        return manabiReaderLoadSubpathFromURL(doc?.location?.href)
    }
    #displayLifecycleDiagnostics(phase, extra = {}) {
        const doc = this.#view?.document ?? null
        const body = doc?.body ?? null
        const metrics = this.#pageMetricsCache
        const viewElement = this.#view?.element ?? null
        const mediaCount = body?.querySelectorAll?.('img, svg, image, picture, video, object, canvas')?.length ?? null
        return {
            ...extra,
            phase,
            index: this.#index,
            sectionHref: this.sections?.[this.#index]?.href ?? this.sections?.[this.#index]?.id ?? null,
            documentSubpath: this.#readerLoadDocumentSubpath(doc),
            docReadyState: doc?.readyState ?? null,
            bodyClass: body?.className ?? null,
            bodyTextLength: body?.textContent?.trim?.().length ?? null,
            mediaCount,
            page: metrics?.page ?? null,
            pages: metrics?.pages ?? null,
            start: metrics ? manabiRound(metrics.start, 1) : null,
            pageSize: metrics ? manabiRound(metrics.size, 1) : null,
            viewSize: metrics ? manabiRound(metrics.viewSize, 1) : null,
            metricsSource: metrics?.metricsSource ?? metrics?.source ?? null,
            hasView: !!this.#view,
            viewConnected: viewElement?.isConnected ?? null,
            viewDisplay: viewElement ? getComputedStyle(viewElement).display : null,
            viewVisibility: viewElement ? getComputedStyle(viewElement).visibility : null,
            containerChildCount: this.#container?.children?.length ?? null,
            containerScrollLeft: this.#container ? manabiRound(this.#container.scrollLeft, 1) : null,
            containerScrollTop: this.#container ? manabiRound(this.#container.scrollTop, 1) : null,
            paginatorLoading: this.#isLoading,
            topReaderLoading: this.#top?.classList?.contains?.('reader-loading') === true,
            locked: this.#locked,
            pendingPageTurnDirection: this.#pendingPageTurnDirection,
            pendingPageTurnStep: this.#pendingPageTurnStep,
            inputSource: globalThis.__manabiNavigationIntent?.source ?? null,
        }
    }
    #mediaVisualDiagnostics(metrics = null, extra = {}) {
        const doc = this.#view?.document ?? null
        const win = doc?.defaultView ?? null
        const body = doc?.body ?? null
        if (!doc || !win || !body) return null

        const mediaElements = Array.from(doc.querySelectorAll('img, svg, image, picture, video, object, canvas'))
        const bodyClass = body.className ?? ''
        const documentURL = String(doc.location?.href ?? '')
        const documentSubpath = this.#readerLoadDocumentSubpath(doc)
        const hasImageBody =
            body.classList?.contains?.('p-image') === true
            || body.classList?.contains?.('p-cover') === true
            || body.classList?.contains?.('reader-is-single-media-element-without-text') === true
        if (!mediaElements.length && !hasImageBody) return null

        const viewportWidth = Number(win.innerWidth) || doc.documentElement?.clientWidth || body.clientWidth || null
        const viewportHeight = Number(win.innerHeight) || doc.documentElement?.clientHeight || body.clientHeight || null
        const viewStyle = this.#view?.element ? getComputedStyle(this.#view.element) : null
        let visibleMediaCount = 0
        let loadedImageCount = 0
        let incompleteImageCount = 0
        let zeroRectMediaCount = 0
        let hiddenMediaCount = 0
        let firstMedia = null
        let firstVisibleMedia = null

        for (const element of mediaElements) {
            const rect = element.getBoundingClientRect?.()
            const width = rect ? Math.max(0, rect.width) : 0
            const height = rect ? Math.max(0, rect.height) : 0
            if (width < 0.5 || height < 0.5) zeroRectMediaCount += 1
            const tag = element.tagName?.toLowerCase?.() ?? 'unknown'
            const isImage = tag === 'img' || tag === 'image'
            if (isImage) {
                if (element.complete === true && ((element.naturalWidth ?? 0) > 0 || tag === 'image')) loadedImageCount += 1
                else incompleteImageCount += 1
            }
            const displayStyle = win.getComputedStyle?.(element) ?? null
            if (
                displayStyle?.display === 'none'
                || displayStyle?.visibility === 'hidden'
                || Number(displayStyle?.opacity ?? 1) === 0
            ) {
                hiddenMediaCount += 1
            }
            const intersectionLeft = rect && viewportWidth != null ? Math.max(rect.left, 0) : null
            const intersectionTop = rect && viewportHeight != null ? Math.max(rect.top, 0) : null
            const intersectionRight = rect && viewportWidth != null ? Math.min(rect.right, viewportWidth) : null
            const intersectionBottom = rect && viewportHeight != null ? Math.min(rect.bottom, viewportHeight) : null
            const intersectionWidth = intersectionLeft != null && intersectionRight != null
                ? Math.max(0, intersectionRight - intersectionLeft)
                : null
            const intersectionHeight = intersectionTop != null && intersectionBottom != null
                ? Math.max(0, intersectionBottom - intersectionTop)
                : null
            const intersectsViewport =
                rect
                && viewportWidth != null
                && viewportHeight != null
                && intersectionWidth > 0
                && intersectionHeight > 0
                && displayStyle?.display !== 'none'
                && displayStyle?.visibility !== 'hidden'
                && Number(displayStyle?.opacity ?? 1) !== 0
            if (intersectsViewport) visibleMediaCount += 1
            const clipEdges = rect && viewportWidth != null && viewportHeight != null
                ? [
                    rect.left < 0 ? 'left' : null,
                    rect.top < 0 ? 'top' : null,
                    rect.right > viewportWidth ? 'right' : null,
                    rect.bottom > viewportHeight ? 'bottom' : null,
                ].filter(Boolean).join(',')
                : null
            const sample = {
                tag,
                complete: isImage ? element.complete === true : null,
                naturalWidth: isImage ? (element.naturalWidth ?? null) : null,
                naturalHeight: isImage ? (element.naturalHeight ?? null) : null,
                currentSrcLength: typeof element.currentSrc === 'string' ? element.currentSrc.length : null,
                srcLength: typeof element.src === 'string' ? element.src.length : null,
                left: rect ? manabiRound(rect.left, 1) : null,
                top: rect ? manabiRound(rect.top, 1) : null,
                right: rect ? manabiRound(rect.right, 1) : null,
                bottom: rect ? manabiRound(rect.bottom, 1) : null,
                width: manabiRound(width, 1),
                height: manabiRound(height, 1),
                intersectsViewport,
                intersectionWidth: intersectionWidth == null ? null : manabiRound(intersectionWidth, 1),
                intersectionHeight: intersectionHeight == null ? null : manabiRound(intersectionHeight, 1),
                clipEdges,
                display: displayStyle?.display ?? null,
                visibility: displayStyle?.visibility ?? null,
                opacity: displayStyle?.opacity ?? null,
                objectFit: displayStyle?.objectFit ?? null,
                position: displayStyle?.position ?? null,
                writingMode: displayStyle?.writingMode ?? null,
                transform: displayStyle?.transform && displayStyle.transform !== 'none'
                    ? displayStyle.transform.slice(0, 96)
                    : null,
                maxInlineSize: displayStyle?.maxInlineSize ?? null,
                maxBlockSize: displayStyle?.maxBlockSize ?? null,
                parentClass: element.parentElement?.className ? String(element.parentElement.className).slice(0, 96) : null,
            }
            if (!firstMedia) firstMedia = sample
            if (intersectsViewport && !firstVisibleMedia) firstVisibleMedia = sample
        }

        const first = firstMedia ?? {}
        const firstVisible = firstVisibleMedia ?? {}
        const hasSuspiciousMediaState =
            mediaElements.length > 0
            && (visibleMediaCount === 0 || zeroRectMediaCount > 0 || incompleteImageCount > 0 || hiddenMediaCount > 0)
        const sectionHref = this.sections?.[this.#index]?.href ?? this.sections?.[this.#index]?.id ?? null
        const staleSnapshotPreviousIndex = extra?.staleDocumentSnapshot === true && Number.isInteger(extra?.previousIndex)
            ? extra.previousIndex
            : null
        const documentMatchSectionHref = staleSnapshotPreviousIndex == null
            ? sectionHref
            : (this.sections?.[staleSnapshotPreviousIndex]?.href ?? this.sections?.[staleSnapshotPreviousIndex]?.id ?? null)
        return {
            ...extra,
            index: this.#index,
            sectionHref,
            documentURLLength: documentURL.length,
            documentSubpath,
            documentMatchesSection: documentSubpath == null
                ? null
                : manabiReaderLoadPathsMatch(documentSubpath, documentMatchSectionHref),
            documentMatchSectionHref,
            page: metrics?.page ?? null,
            pages: metrics?.pages ?? null,
            start: metrics ? manabiRound(metrics.start, 1) : null,
            pageSize: metrics ? manabiRound(metrics.size, 1) : null,
            viewSize: metrics ? manabiRound(metrics.viewSize, 1) : null,
            metricsSource: metrics?.metricsSource ?? metrics?.source ?? null,
            bodyClass,
            hasImageBody,
            mediaCount: mediaElements.length,
            visibleMediaCount,
            loadedImageCount,
            incompleteImageCount,
            zeroRectMediaCount,
            hiddenMediaCount,
            suspiciousMediaState: hasSuspiciousMediaState,
            viewportWidth: viewportWidth == null ? null : manabiRound(viewportWidth, 1),
            viewportHeight: viewportHeight == null ? null : manabiRound(viewportHeight, 1),
            docClientWidth: doc.documentElement?.clientWidth ?? null,
            docClientHeight: doc.documentElement?.clientHeight ?? null,
            docScrollWidth: doc.documentElement?.scrollWidth ?? null,
            docScrollHeight: doc.documentElement?.scrollHeight ?? null,
            bodyClientWidth: body.clientWidth ?? null,
            bodyClientHeight: body.clientHeight ?? null,
            bodyScrollWidth: body.scrollWidth ?? null,
            bodyScrollHeight: body.scrollHeight ?? null,
            containerScrollLeft: this.#container ? manabiRound(this.#container.scrollLeft, 1) : null,
            containerScrollTop: this.#container ? manabiRound(this.#container.scrollTop, 1) : null,
            viewConnected: this.#view?.element?.isConnected ?? null,
            viewDisplay: viewStyle?.display ?? null,
            viewVisibility: viewStyle?.visibility ?? null,
            viewOpacity: viewStyle?.opacity ?? null,
            containerChildCount: this.#container?.children?.length ?? null,
            containerClass: this.#container?.className ?? null,
            isLoading: this.#isLoading,
            locked: this.#locked,
            pendingPageTurnDirection: this.#pendingPageTurnDirection,
            inputSource: globalThis.__manabiNavigationIntent?.source ?? null,
            firstTag: first.tag ?? null,
            firstComplete: first.complete ?? null,
            firstNaturalWidth: first.naturalWidth ?? null,
            firstNaturalHeight: first.naturalHeight ?? null,
            firstCurrentSrcLength: first.currentSrcLength ?? null,
            firstSrcLength: first.srcLength ?? null,
            firstLeft: first.left ?? null,
            firstTop: first.top ?? null,
            firstRight: first.right ?? null,
            firstBottom: first.bottom ?? null,
            firstWidth: first.width ?? null,
            firstHeight: first.height ?? null,
            firstIntersectsViewport: first.intersectsViewport ?? null,
            firstIntersectionWidth: first.intersectionWidth ?? null,
            firstIntersectionHeight: first.intersectionHeight ?? null,
            firstClipEdges: first.clipEdges ?? null,
            firstDisplay: first.display ?? null,
            firstVisibility: first.visibility ?? null,
            firstOpacity: first.opacity ?? null,
            firstObjectFit: first.objectFit ?? null,
            firstPosition: first.position ?? null,
            firstWritingMode: first.writingMode ?? null,
            firstTransform: first.transform ?? null,
            firstMaxInlineSize: first.maxInlineSize ?? null,
            firstMaxBlockSize: first.maxBlockSize ?? null,
            firstParentClass: first.parentClass ?? null,
            firstVisibleTag: firstVisible.tag ?? null,
            firstVisibleLeft: firstVisible.left ?? null,
            firstVisibleTop: firstVisible.top ?? null,
            firstVisibleWidth: firstVisible.width ?? null,
            firstVisibleHeight: firstVisible.height ?? null,
        }
    }
    #mediaVisualSignature(snapshot = null) {
        if (!snapshot) return null
        return [
            snapshot.index,
            snapshot.documentSubpath,
            snapshot.page,
            snapshot.pages,
            snapshot.start,
            snapshot.visibleMediaCount,
            snapshot.loadedImageCount,
            snapshot.incompleteImageCount,
            snapshot.zeroRectMediaCount,
            snapshot.hiddenMediaCount,
            snapshot.firstComplete,
            snapshot.firstLeft,
            snapshot.firstTop,
            snapshot.firstWidth,
            snapshot.firstHeight,
            snapshot.firstIntersectsViewport,
            snapshot.firstClipEdges,
            snapshot.bodyClass,
            snapshot.containerScrollLeft,
            snapshot.containerScrollTop,
            snapshot.isLoading,
            snapshot.locked,
        ].join('|')
    }
    #mediaVisualChangedFields(before = null, after = null) {
        if (!before || !after) return null
        const fields = [
            'index',
            'documentSubpath',
            'page',
            'pages',
            'start',
            'visibleMediaCount',
            'loadedImageCount',
            'incompleteImageCount',
            'zeroRectMediaCount',
            'hiddenMediaCount',
            'firstComplete',
            'firstLeft',
            'firstTop',
            'firstWidth',
            'firstHeight',
            'firstIntersectsViewport',
            'firstClipEdges',
            'bodyClass',
            'containerScrollLeft',
            'containerScrollTop',
            'isLoading',
            'locked',
        ]
        const changed = fields.filter(field => before[field] !== after[field])
        return changed.length ? changed.slice(0, 12).join(',') : null
    }
    #scheduleMediaVisualFollowUp(initialSnapshot = null, {
        reason = null,
        phase = null,
        crossedSection = false,
        displayBoundary = false,
    } = {}) {
        if (!this.#shouldLogMediaVisualDiagnostics(initialSnapshot, { crossedSection, displayBoundary })) return
        const token = ++this.#mediaVisualDiagnosticsToken
        const initialSignature = this.#mediaVisualSignature(initialSnapshot)
        const delays = [50, 250, 1000]
        for (const delayMs of delays) {
            setTimeout(async () => {
                if (token !== this.#mediaVisualDiagnosticsToken && delayMs > 50) return
                const snapshot = this.#mediaVisualDiagnostics(this.#pageMetricsCache, {
                    phase: phase ? `${phase}.followUp` : 'followUp',
                    reason,
                    delayMs,
                })
                if (!snapshot) return
                const signature = this.#mediaVisualSignature(snapshot)
                const changed = signature !== initialSignature
                if (!changed && !snapshot.suspiciousMediaState && delayMs < 1000 && !manabiPaginatorVerbosePageTurns()) return
                manabiPaginatorReaderLoadLog('paginator.mediaVisual.followUp', {
                    ...snapshot,
                    changed,
                    changedFields: this.#mediaVisualChangedFields(initialSnapshot, snapshot),
                })
            }, delayMs)
        }
    }
    #installMediaVisualEventDiagnostics(reason = null) {
        const doc = this.#view?.document ?? null
        if (!doc || this.#isCacheWarmer) return
        const mediaElements = Array.from(doc.querySelectorAll('img, video')).slice(0, 6)
        if (!mediaElements.length) return
        for (const [mediaIndex, element] of mediaElements.entries()) {
            if (element.dataset?.manabiMediaVisualDiagnostics === '1') continue
            if (element.dataset) element.dataset.manabiMediaVisualDiagnostics = '1'
            const logEvent = eventType => {
                const metrics = this.#pageMetricsCache
                const snapshot = this.#mediaVisualDiagnostics(metrics, {
                    phase: 'mediaEvent',
                    reason,
                    mediaIndex,
                    eventType,
                })
                if (this.#shouldLogMediaVisualDiagnostics(snapshot, { displayBoundary: true })) {
                    manabiPaginatorReaderLoadLog('paginator.mediaVisual.event', snapshot)
                }
            }
            element.addEventListener?.('load', () => logEvent('load'), { once: true })
            element.addEventListener?.('error', () => logEvent('error'), { once: true })
            element.addEventListener?.('loadedmetadata', () => logEvent('loadedmetadata'), { once: true })
            element.addEventListener?.('loadeddata', () => logEvent('loadeddata'), { once: true })
            if (element.tagName?.toLowerCase?.() === 'img' && element.complete === true) {
                queueMicrotask(() => logEvent('alreadyComplete'))
            }
        }
    }
    #shouldLogMediaVisualDiagnostics(snapshot = null, { crossedSection = false, displayBoundary = false } = {}) {
        if (!snapshot || this.#isCacheWarmer) return false
        if (manabiPaginatorVerbosePageTurns()) return true
        return !!(
            snapshot.suspiciousMediaState
            || (snapshot.hasImageBody && (crossedSection || displayBoundary))
            || (snapshot.mediaCount > 0 && crossedSection)
        )
    }
    async #visibleRangeCacheKey() {
        await this.#awaitDirection()
        const doc = this.#view?.document ?? null
        const container = this.#container
        if (!doc || !container) return null
        const scrollProp = await this.scrollProp()
        const scrollOffset = Math.round(container[scrollProp] || 0)
        return {
            doc,
            key: [
                this.#index,
                this.scrolled ? 'scrolled' : 'paginated',
                this.#vertical ? 'vertical' : 'horizontal',
                this.#rtl ? 'rtl' : 'ltr',
                scrollProp,
                scrollOffset,
                Math.round(container.clientWidth || 0),
                Math.round(container.clientHeight || 0),
                Math.round(container.scrollWidth || 0),
                Math.round(container.scrollHeight || 0),
            ].join('|')
        }
    }
    #cloneRange(range) {
        try {
            return range?.cloneRange?.() ?? range
        } catch {
            return range
        }
    }
    async #getSentinelVisibilities() {
        //        console.log("trackSentinelVisibilities...")
        await new Promise(r => requestAnimationFrame(r));

        let sentinelVisibilityObserver

        return new Promise(resolve => {
            sentinelVisibilityObserver = new IntersectionObserver(entries => {
                const visibleSentinelIDs = []

                for (const entry of entries) {
                    if (entry.intersectionRatio > 0.5) {
                        visibleSentinelIDs.push(entry.target.id)
                    }
                }

                sentinelVisibilityObserver.disconnect()

                const elements = Array.from(this.#view.document.body.getElementsByTagName('reader-sentinel'))
                let visibleIDSet = new Set(visibleSentinelIDs)
                let visibleSource = 'observer'
                if (visibleIDSet.size === 0) {
                    const containerRect = this.#container && typeof this.#container.getBoundingClientRect === 'function'
                        ? this.#container.getBoundingClientRect()
                        : null
                    const frameElement = this.#view?.document?.defaultView?.frameElement ?? null
                    const iframeRect = frameElement && typeof frameElement.getBoundingClientRect === 'function'
                        ? frameElement.getBoundingClientRect()
                        : null
                    if (containerRect && iframeRect) {
                        for (const element of elements) {
                            const rect = element.getBoundingClientRect?.()
                            if (!rect || rect.width <= 0 || rect.height <= 0) continue
                            const translated = {
                                left: iframeRect.left + rect.left,
                                right: iframeRect.left + rect.right,
                                top: iframeRect.top + rect.top,
                                bottom: iframeRect.top + rect.bottom,
                            }
                            if (
                                translated.right > containerRect.left
                                && translated.left < containerRect.right
                                && translated.bottom > containerRect.top
                                && translated.top < containerRect.bottom
                            ) {
                                visibleIDSet.add(element.id)
                            }
                        }
                        visibleSource = 'geometry'
                    }
                }
                const visibleIndexes = elements
                    .map((element, index) => visibleIDSet.has(element.id) ? index : -1)
                    .filter(index => index >= 0)
                let expandedSentinelIDs = Array.from(visibleIDSet)
                if (visibleIndexes.length > 0) {
                    const firstIndex = Math.min(...visibleIndexes)
                    const lastIndex = Math.max(...visibleIndexes)
                    const expandedStart = Math.max(0, firstIndex - 1)
                    const expandedEnd = Math.min(elements.length - 1, lastIndex + 1)
                    expandedSentinelIDs = elements
                        .slice(expandedStart, expandedEnd + 1)
                        .map(element => element.id)
                        .filter(Boolean)
                }

                resolve?.(expandedSentinelIDs)
            }, {
                root: null,
                threshold: [0],
            });

            const elements = this.#view.document.body.getElementsByTagName('reader-sentinel')
            for (let i = 0; i < elements.length; i++) {
                sentinelVisibilityObserver.observe(elements[i])
            }
        })
    }
    #disconnectElementVisibilityObserver() {
        if (this.#elementVisibilityObserver) {
            this.#elementVisibilityObserver.disconnect();
            this.#elementVisibilityObserver = null;
        }
        if (this.#elementMutationObserver) {
            this.#elementMutationObserver.disconnect();
            this.#elementMutationObserver = null;
        }
    }
    #isSingleMediaElementWithoutText() {
        const container = this.#view.document.getElementById('reader-content');
        if (!container) return false;
        const mediaTags = ['img', 'image', 'svg', 'video', 'picture', 'object', 'iframe', 'canvas', 'embed'];
        const selector = mediaTags.join(',');
        const mediaElements = container.querySelectorAll(selector);
        // Must have exactly one media element anywhere
        if (mediaElements.length !== 1) return false;
        // Must have no non-whitespace text nodes
        if (container.textContent.trim() !== '') return false;
        return true;
    }
    #typographyMetrics() {
        const doc = this.#view?.document;
        const inlineBodyStyle = doc?.body?.style ?? null;
        const inlineContainerStyle = this.#container?.style ?? null;
        const cheapBodyFontSize =
            parseFloat(inlineBodyStyle?.fontSize)
            || parseFloat(inlineBodyStyle?.getPropertyValue?.('--mnb-reader-content-font-size'));
        const cheapLineHeight =
            parseFloat(inlineBodyStyle?.lineHeight)
            || parseFloat(inlineBodyStyle?.getPropertyValue?.('--mnb-reader-line-height'));
        const canUseCheapBodyMetrics = Number.isFinite(cheapBodyFontSize);
        const bodyStyle = canUseCheapBodyMetrics
            ? null
            : (doc?.body ? getComputedStyle(doc.body) : null);
        const containerStyle = canUseCheapBodyMetrics
            ? null
            : (this.#container ? getComputedStyle(this.#container) : null);
        const fontSize =
            cheapBodyFontSize
            || parseFloat(bodyStyle?.fontSize)
            || parseFloat(inlineContainerStyle?.fontSize)
            || parseFloat(containerStyle?.fontSize)
            || 20;
        const parsedLineHeight =
            cheapLineHeight
            || parseFloat(bodyStyle?.lineHeight)
            || parseFloat(inlineContainerStyle?.lineHeight)
            || parseFloat(containerStyle?.lineHeight);
        const lineHeight = Number.isFinite(parsedLineHeight)
            ? parsedLineHeight
            : fontSize * 1.5;
        const inlineCharacterAdvance = Math.max(fontSize, Math.min(lineHeight, fontSize * 1.8));
        return {
            fontSize,
            lineHeight,
            inlineCharacterAdvance,
        };
    }
    #intersectsPageRange(mappedRect, pageStart, pageEnd) {
        if (!mappedRect) return false;
        const left = Number(mappedRect.left);
        const right = Number(mappedRect.right);
        if (!Number.isFinite(left) || !Number.isFinite(right)) return false;
        return right > pageStart && left < pageEnd;
    }
    #describeNodeForBlankPage(node) {
        const element = node?.nodeType === Node.ELEMENT_NODE
            ? node
            : node?.parentElement;
        if (!element) return null;
        const id = element.id ? `#${element.id}` : '';
        const className = typeof element.className === 'string' && element.className.trim()
            ? `.${element.className.trim().split(/\s+/).slice(0, 3).join('.')}`
            : '';
        return `${element.localName || element.nodeName}${id}${className}`;
    }
    async #blankPageContentSummary(page, size, rectMapper) {
        const doc = this.#view?.document;
        if (!doc?.body || !Number.isFinite(page) || !Number.isFinite(size) || size <= 0) {
            return null;
        }
        const pageStart = Math.max(0, (page - 1) * size);
        const pageEnd = pageStart + size;
        const summary = {
            page,
            pageStart: manabiRound(pageStart, 1),
            pageEnd: manabiRound(pageEnd, 1),
            textNodeCount: 0,
            textCharCount: 0,
            mediaCount: 0,
            elementBoxCount: 0,
            textSamples: [],
            mediaSamples: [],
            elementSamples: [],
        };

        const walker = doc.createTreeWalker(doc.body, SHOW_TEXT, {
            acceptNode: node => /\S/.test(node.nodeValue || '') ? FILTER_ACCEPT : FILTER_REJECT,
        });
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            const range = doc.createRange();
            try {
                range.selectNodeContents(node);
                const rects = Array.from(range.getClientRects?.() || []);
                if (!rects.some(rect => this.#intersectsPageRange(rectMapper(rect), pageStart, pageEnd))) {
                    continue;
                }
                const text = (node.nodeValue || '').replace(/\s+/g, ' ').trim();
                summary.textNodeCount += 1;
                summary.textCharCount += text.length;
                if (summary.textSamples.length < 3 && text) {
                    summary.textSamples.push(text.slice(0, 80));
                }
            } finally {
                range.detach?.();
            }
        }

        const mediaSelector = 'img,image,svg,video,picture,object,iframe,canvas,embed';
        for (const element of doc.body.querySelectorAll?.(mediaSelector) || []) {
            const rects = Array.from(element.getClientRects?.() || []);
            if (!rects.some(rect => this.#intersectsPageRange(rectMapper(rect), pageStart, pageEnd))) {
                continue;
            }
            summary.mediaCount += 1;
            if (summary.mediaSamples.length < 5) {
                summary.mediaSamples.push({
                    node: this.#describeNodeForBlankPage(element),
                    src: element.currentSrc || element.src || element.href?.baseVal || element.getAttribute?.('src') || element.getAttribute?.('href') || null,
                    alt: element.getAttribute?.('alt') || null,
                    naturalWidth: element.naturalWidth ?? null,
                    naturalHeight: element.naturalHeight ?? null,
                    complete: element.complete ?? null,
                });
            }
        }

        if (summary.textCharCount === 0 && summary.mediaCount === 0) {
            for (const element of doc.body.querySelectorAll?.('body *') || []) {
                const rects = Array.from(element.getClientRects?.() || []);
                const mappedRects = rects
                    .map(rectMapper)
                    .filter(rect => this.#intersectsPageRange(rect, pageStart, pageEnd));
                if (mappedRects.length > 0) {
                    summary.elementBoxCount += 1;
                    if (summary.elementSamples.length < 5) {
                        summary.elementSamples.push({
                            node: this.#describeNodeForBlankPage(element),
                            display: doc.defaultView?.getComputedStyle?.(element)?.display || null,
                            blockSize: doc.defaultView?.getComputedStyle?.(element)?.blockSize || null,
                            inlineSize: doc.defaultView?.getComputedStyle?.(element)?.inlineSize || null,
                            mediaDescendantCount: element.querySelectorAll?.(mediaSelector)?.length ?? 0,
                            textLength: (element.textContent || '').replace(/\s+/g, '').length,
                            rects: mappedRects.slice(0, 3).map(rect => ({
                                left: manabiRound(rect.left, 1),
                                right: manabiRound(rect.right, 1),
                                top: manabiRound(rect.top, 1),
                                bottom: manabiRound(rect.bottom, 1),
                            })),
                        });
                    }
                }
            }
        }

        return summary;
    }
    #blankPageMediaPlacements(size, rectMapper, centerPage) {
        const doc = this.#view?.document;
        if (!doc?.body || !Number.isFinite(size) || size <= 0) return [];
        const mediaSelector = 'img,image,svg,video,picture,object,iframe,canvas,embed';
        const placements = [];
        for (const element of doc.body.querySelectorAll?.(mediaSelector) || []) {
            const mappedRects = Array.from(element.getClientRects?.() || [])
                .map(rectMapper)
                .filter(rect =>
                    rect
                    && Number.isFinite(Number(rect.left))
                    && Number.isFinite(Number(rect.right))
                    && Number(rect.right) > Number(rect.left)
                );
            if (mappedRects.length === 0) continue;
            const minLeft = Math.min(...mappedRects.map(rect => Number(rect.left)));
            const maxRight = Math.max(...mappedRects.map(rect => Number(rect.right)));
            const firstPage = Math.floor(minLeft / size) + 1;
            const lastPage = Math.max(firstPage, Math.ceil(maxRight / size));
            if (Number.isFinite(centerPage) && (lastPage < centerPage - 2 || firstPage > centerPage + 2)) {
                continue;
            }
            placements.push({
                node: this.#describeNodeForBlankPage(element),
                firstPage,
                lastPage,
                left: manabiRound(minLeft, 1),
                right: manabiRound(maxRight, 1),
                src: element.currentSrc || element.src || element.href?.baseVal || element.getAttribute?.('src') || element.getAttribute?.('href') || null,
                naturalWidth: element.naturalWidth ?? null,
                naturalHeight: element.naturalHeight ?? null,
                complete: element.complete ?? null,
            });
            if (placements.length >= 12) break;
        }
        return placements;
    }
    #scheduleBlankPageCorrection({
        index,
        direction,
        metrics,
    }) {
        if (
            this.#isCacheWarmer
            || this.scrolled
            || !this.#view?.document
            || !Number.isFinite(direction)
            || direction === 0
            || !metrics
        ) {
            return;
        }
        const scheduledView = this.#view;
        const scheduledIndex = this.#index;
        const scheduledPage = metrics.page;
        const scheduledPages = metrics.pages;
        const minPage = 1;
        const maxPage = Math.max(minPage, scheduledPages - 2);
        if (!Number.isFinite(scheduledPage) || scheduledPage < minPage || scheduledPage > maxPage) {
            return;
        }
        const run = async () => {
            if (this.#view !== scheduledView || this.#index !== scheduledIndex || this.#index !== index) {
                return;
            }
            const latestMetrics = await this.pageMetrics().catch(() => null);
            if (this.#view !== scheduledView || this.#index !== scheduledIndex || this.#index !== index) {
                return;
            }
            if (
                !latestMetrics
                || latestMetrics.page !== scheduledPage
                || latestMetrics.pages !== scheduledPages
            ) {
                return;
            }
            const size = latestMetrics.size;
            const rectMapper = await this.#getRectMapper(latestMetrics);
            const summariesByPage = new Map();
            let target = scheduledPage;
            let scanCount = 0;
            while (target >= minPage && target <= maxPage && scanCount < 4) {
                summariesByPage.set(target, await this.#blankPageContentSummary(target, size, rectMapper));
                const resolved = manabiResolveBlankPageTarget({
                    page: target,
                    pages: latestMetrics.pages,
                    direction,
                    summariesByPage,
                });
                scanCount += 1;
                if (resolved === target) break;
                target = resolved;
            }
            if (!this.#isCacheWarmer) {
                const summaries = Array.from(summariesByPage.entries()).map(([summaryPage, summary]) => ({
                    page: summaryPage,
                    textNodeCount: summary?.textNodeCount ?? null,
                    textCharCount: summary?.textCharCount ?? null,
                    mediaCount: summary?.mediaCount ?? null,
                    elementBoxCount: summary?.elementBoxCount ?? null,
                    firstTextSample: summary?.textSamples?.[0] ?? null,
                }));
                manabiPaginatorReaderLoadLog('paginator.blankPageCorrection.decision', {
                    index,
                    requestedPage: scheduledPage,
                    resolvedPage: target,
                    direction,
                    minPage,
                    maxPage,
                    scanCount,
                    summaries: JSON.stringify(summaries),
                });
            }
            if (target !== scheduledPage && target >= minPage && target <= maxPage) {
                await this.#scrollToPage(target, 'blank-correction', false, latestMetrics);
            }
        };
        requestAnimationFrame(() => requestAnimationFrame(() => void run()));
    }
    #typographyRenderSignature({
        width,
        height,
        flow = this.getAttribute('flow'),
        vertical = this.#vertical,
        rtl = this.#rtl,
        fontSize,
        lineHeight,
        inlineCharacterAdvance,
    } = {}) {
        const metrics = fontSize == null || lineHeight == null || inlineCharacterAdvance == null
            ? this.#typographyMetrics()
            : { fontSize, lineHeight, inlineCharacterAdvance };
        return [
            flow ?? '',
            vertical ? 'vertical' : 'horizontal',
            rtl ? 'rtl' : 'ltr',
            Math.round(width ?? this.#container?.clientWidth ?? 0),
            Math.round(height ?? this.#container?.clientHeight ?? 0),
            manabiRound(metrics.fontSize, 2),
            manabiRound(metrics.lineHeight, 2),
            manabiRound(metrics.inlineCharacterAdvance, 2),
        ].join('|');
    }
    async renderIfTypographyChanged(reason = 'unspecified') {
        if (MANABI_DISABLE_POST_LOAD_RERENDER) {
            return { rendered: false, reason: 'post-load-rerender-disabled' };
        }
        if (!this.#view || this.#isCacheWarmer) {
            return { rendered: false, reason: 'unavailable' };
        }
        const { width, height } = await this.sizes();
        const signature = this.#typographyRenderSignature({ width, height });
        const previousSignature = this.#lastTypographyRenderSignature;
        if (signature === previousSignature) {
            return { rendered: false, reason: 'unchanged', signature };
        }
        this.#cachedSizes = null;
        this.#sizesPromise = null;
        this.#cachedStart = null;
        this.#view.cachedViewSize = null;
        this.#viewSizePromise = null;
        this.#view.cachedSizes = null;
        this.#invalidateVisibleRangeCache();
        await this.render();
        return { rendered: true, reason, previousSignature, signature };
    }
    async #beforeRender({
        vertical,
        verticalRTL,
        rtl,
        //        background
    }) {
        this.#vertical = vertical
        this.#verticalRTL = verticalRTL
        this.#rtl = rtl
        this.#top.classList.toggle('vertical', vertical)

        // set background to `doc` background
        // this is needed because the iframe does not fill the whole element
        //        this.#background.style.background = background

        if (!this.#isCacheWarmer) {
        }

        const flow = this.getAttribute('flow')
        manabiPreparePaginatorLayoutMeasurement({
            top: this.#top,
            vertical,
            flow,
            invalidateSizes: () => {
                this.#cachedSizes = null
                this.#sizesPromise = null
            },
        })

        const {
            width,
            height
        } = await this.sizes()
        this.#lastRenderContainerSize = { width, height }
        const size = vertical ? height : width
        const typographyMetrics = this.#typographyMetrics()
        this.#lastTypographyRenderSignature = this.#typographyRenderSignature({
            width,
            height,
            flow,
            vertical,
            rtl,
            fontSize: typographyMetrics.fontSize,
            lineHeight: typographyMetrics.lineHeight,
            inlineCharacterAdvance: typographyMetrics.inlineCharacterAdvance,
        })

        let maxInlineSize;
        let maxColumnCountSpread;
        let topMargin;
        let bottomMargin;
        let g;

        if (MANABI_ENABLE_COLUMNIZATION_OPTIMIZATIONS) {
            const {
                maxInlineSizePx,
                maxColumnCount,
                maxColumnCountPortrait,
                topMarginPx,
                bottomMarginPx,
                gapPct,
                verticalPaginatedTopMarginPx,
                verticalPaginatedBottomMarginPx,
            } = CSS_DEFAULTS;
            maxInlineSize = maxInlineSizePx;
            const orientationPortrait = height > width;
            if (orientationPortrait) {
                maxColumnCountSpread = vertical ? maxColumnCount : maxColumnCountPortrait;
            } else {
                maxColumnCountSpread = vertical ? maxColumnCountPortrait : maxColumnCount;
            }
            const isPaginatedVertical = vertical && flow !== 'scrolled';
            topMargin = isPaginatedVertical ? verticalPaginatedTopMarginPx : topMarginPx;
            bottomMargin = isPaginatedVertical ? verticalPaginatedBottomMarginPx : bottomMarginPx;
            g = gapPct / 100;
        } else {
            const style = getComputedStyle(this.#top)
            maxInlineSize = parseFloat(style.getPropertyValue('--_max-inline-size'))
            maxColumnCountSpread = parseInt(style.getPropertyValue('--_max-column-count-spread'))
            topMargin = parseFloat(style.getPropertyValue('--_margin'))
            bottomMargin = topMargin
            g = parseFloat(style.getPropertyValue('--_gap')) / 100
        }

        this.#topMargin = topMargin
        this.#bottomMargin = bottomMargin
        this.#view.document.documentElement.style.setProperty('--_max-inline-size', maxInlineSize)

        // The gap will be a percentage of the #container, not the whole view.
        // This means the outer padding will be bigger than the column gap. Let
        // `a` be the gap percentage. The actual percentage for the column gap
        // will be (1 - a) * a. Let us call this `b`.
        //
        // To make them the same, we start by shrinking the outer padding
        // setting to `b`, but keep the column gap setting the same at `a`. Then
        // the actual size for the column gap will be (1 - b) * a. Repeating the
        // process again and again, we get the sequence
        //     x₁ = (1 - b) * a
        //     x₂ = (1 - x₁) * a
        //     ...
        // which converges to x = (1 - x) * a. Solving for x, x = a / (1 + a).
        // So to make the spacing even, we must shrink the outer padding with
        //     f(x) = x / (1 + x).
        // But we want to keep the outer padding, and make the inner gap bigger.
        // So we apply the inverse, f⁻¹ = -x / (x - 1) to the column gap.
        const rawGap = -g / (g - 1) * size
        const gap = MANABI_ENABLE_COLUMNIZATION_OPTIMIZATIONS
            ? (vertical && flow !== 'scrolled'
                ? CSS_DEFAULTS.verticalPaginatedGapPx
                : Math.max(rawGap, CSS_DEFAULTS.minGapPx))
            : rawGap

        if (flow === 'scrolled') {
            // FIXME: vertical-rl only, not -lr
            //this.setAttribute('dir', vertical ? 'rtl' : 'ltr')
            this.#top.style.padding = '0'
            //            const columnWidth = maxInlineSize
            const columnWidth = maxInlineSize

            this.heads = null
            this.feet = null
            this.#header.replaceChildren()
            this.#footer.replaceChildren()

            return {
                flow,
                topMargin,
                bottomMargin,
                gap,
                columnWidth,
                typographySignature: this.#lastTypographyRenderSignature,
            }
        }

        let divisor;
        let columnWidth;
        const shouldNormalizeSingleMediaPage =
            MANABI_ENABLE_SINGLE_MEDIA_PAGE_NORMALIZATION
            && this.#isSingleMediaElementWithoutText()
        if (shouldNormalizeSingleMediaPage) {
            divisor = 1
            columnWidth = maxInlineSize
            this.#view.document.body?.classList.add('reader-is-single-media-element-without-text')
        } else {
            this.#view.document.body?.classList.remove('reader-is-single-media-element-without-text')
            const shouldForceSpread = MANABI_ENABLE_COLUMNIZATION_OPTIMIZATIONS
                && flow !== 'scrolled'
                && maxColumnCountSpread > 1
                && (vertical || width > height)
            const candidateDivisor = Math.max(1, shouldForceSpread
                ? maxColumnCountSpread
                : Math.min(maxColumnCountSpread, Math.ceil(size / maxInlineSize)))
            const candidateColumnWidth = (size / candidateDivisor) - gap
            const inlineCharsPerColumn = candidateColumnWidth / typographyMetrics.inlineCharacterAdvance
            const shouldDisableMultiColumnForTypography =
                MANABI_ENABLE_COLUMNIZATION_OPTIMIZATIONS
                && candidateDivisor > 1
                && inlineCharsPerColumn < MANABI_MIN_INLINE_CHARS_FOR_MULTICOLUMN
            divisor = shouldDisableMultiColumnForTypography ? 1 : candidateDivisor
            columnWidth = (size / divisor) - gap
        }

        this.setAttribute('dir', rtl ? 'rtl' : 'ltr')

        const marginalDivisor = vertical ?
            Math.min(2, Math.ceil(width / maxInlineSize)) :
            divisor
        const marginalStyle = {
            gridTemplateColumns: `repeat(${marginalDivisor}, 1fr)`,
            gap: `${gap}px`,
            direction: this.bookDir === 'rtl' ? 'rtl' : 'ltr',
        }
        Object.assign(this.#header.style, marginalStyle)
        Object.assign(this.#footer.style, marginalStyle)
        const heads = makeMarginals(marginalDivisor, 'head')
        const feet = makeMarginals(marginalDivisor, 'foot')
        this.heads = heads.map(el => el.children[0])
        this.feet = feet.map(el => el.children[0])
        this.#header.replaceChildren(...heads)
        this.#footer.replaceChildren(...feet)

        return {
            height,
            width,
            topMargin,
            bottomMargin,
            gap,
            columnWidth,
            divisor,
            typographySignature: this.#lastTypographyRenderSignature,
        }
    }
    async render() {
        if (!this.#view) {
            return
        }
        const { width, height } = await this.sizes()
        const flow = this.getAttribute('flow')
        const typographyMetrics = this.#typographyMetrics()
        const signature = this.#typographyRenderSignature({
            width,
            height,
            flow,
            vertical: this.#vertical,
            rtl: this.#rtl,
            fontSize: typographyMetrics.fontSize,
            lineHeight: typographyMetrics.lineHeight,
            inlineCharacterAdvance: typographyMetrics.inlineCharacterAdvance,
        })
        if (this.#lastTypographyRenderSignature === signature && this.#view.layout) {
            manabiTimelineMark('paginator.render.skipSameSignature', {
                index: this.#index,
                signature,
            })
            return
        }
        if (this.#renderInFlightTypographySignature === signature && this.#renderInFlightPromise) {
            manabiTimelineMark('paginator.render.awaitSameSignature', {
                index: this.#index,
                signature,
            })
            await this.#renderInFlightPromise
            return
        }
        this.#invalidateVisibleRangeCache()

        // avoid unwanted triggers
        //        this.#hasResizeObserverTriggered = false
        //        this.#resizeObserver.observe(this.#container);

        const renderWork = (async () => {
            await this.#view.render(await this.#beforeRender({
                vertical: this.#vertical,
                rtl: this.#rtl,
            }))
        })()
        this.#renderInFlightTypographySignature = signature
        this.#renderInFlightPromise = renderWork
        try {
            await renderWork
        } finally {
            if (this.#renderInFlightTypographySignature === signature) {
                this.#renderInFlightTypographySignature = null
                this.#renderInFlightPromise = null
            }
        }
        //            await this.#scrollToAnchor(this.#anchor) // already called via render -> ... -> expand -> onExpand
    }
    async renderIfContainerSizeChanged(reason = 'unspecified') {
        if (MANABI_DISABLE_POST_LOAD_RERENDER) {
            return { rendered: false, reason: 'post-load-rerender-disabled' }
        }
        if (!this.#view || this.#isCacheWarmer) {
            return { rendered: false, reason: 'unavailable' }
        }
        const currentSize = {
            width: Math.round(this.#container?.clientWidth || 0),
            height: Math.round(this.#container?.clientHeight || 0),
        }
        const previousSize = this.#lastRenderContainerSize
        const changed =
            !!previousSize &&
            currentSize.width > 0 &&
            currentSize.height > 0 &&
            (currentSize.width !== previousSize.width || currentSize.height !== previousSize.height)
        if (!changed) {
            return { rendered: false, reason: 'unchanged', previousSize, currentSize }
        }
        const currentSignature = this.#typographyRenderSignature({
            width: currentSize.width,
            height: currentSize.height,
        })
        if (this.#lastTypographyRenderSignature === currentSignature && this.#view.layout) {
            this.#lastRenderContainerSize = currentSize
            manabiTimelineMark('paginator.renderIfContainerSizeChanged.skipSameSignature', {
                reason,
                previousWidth: previousSize?.width ?? null,
                previousHeight: previousSize?.height ?? null,
                currentWidth: currentSize.width,
                currentHeight: currentSize.height,
                signature: currentSignature,
            })
            return {
                rendered: false,
                reason: 'typography-signature-unchanged',
                previousSize,
                currentSize,
                signature: currentSignature,
            }
        }
        manabiTimelineMark('paginator.renderIfContainerSizeChanged.render', {
            reason,
            previousWidth: previousSize?.width ?? null,
            previousHeight: previousSize?.height ?? null,
            currentWidth: currentSize.width,
            currentHeight: currentSize.height,
            previousSignature: this.#lastTypographyRenderSignature,
            currentSignature,
        })
        if (String(reason).includes('initial-paginator-settle') || String(reason).includes('did-display')) {
            manabiPaginatorReaderLoadLog('paginator.renderIfContainerSizeChanged.render', {
                reason,
                previousWidth: previousSize?.width ?? null,
                previousHeight: previousSize?.height ?? null,
                currentWidth: currentSize.width,
                currentHeight: currentSize.height,
                previousSignature: this.#lastTypographyRenderSignature,
                currentSignature,
            })
        }
        this.#cachedSizes = null
        this.#sizesPromise = null
        this.#cachedStart = null
        this.#view.cachedViewSize = null
        this.#viewSizePromise = null
        this.#view.cachedSizes = null
        this.#invalidateVisibleRangeCache()
        await this.render()
        return { rendered: true, previousSize, currentSize }
    }
    get scrolled() {
        return this.getAttribute('flow') === 'scrolled'
    }
    async scrollProp() {
        await this.#awaitDirection();
        const {
            scrolled
        } = this
        if (this.#vertical && !scrolled && this.#view?.expandedMetrics?.inlineProgression === true) {
            return 'scrollLeft'
        }
        return this.#vertical ? (scrolled ? 'scrollLeft' : 'scrollTop') :
            scrolled ? 'scrollTop' : 'scrollLeft'
    }
    async sideProp() {
        await this.#awaitDirection();
        const {
            scrolled
        } = this
        if (this.#vertical && !scrolled && this.#view?.expandedMetrics?.inlineProgression === true) {
            return 'width'
        }
        return this.#vertical ? (scrolled ? 'width' : 'height') :
            scrolled ? 'height' : 'width'
    }
    async sizes() {
        //        await this.#awaitDirection();
        if (this.#isCacheWarmer) return 0
        if (/*true || */this.#cachedSizes === null) {
            if (this.#sizesPromise) {
                return this.#sizesPromise
            }
            this.#sizesPromise = new Promise(resolve => {
                requestAnimationFrame(async () => {
                    //                    const r = this.#container.getBoundingClientRect()
                    //                    this.#cachedSizes = {
                    //                        width: r.width,
                    //                        height: r.height,
                    //                    }
                    //                    resolve(this.#cachedSizes)
                    //                    return ;

                    this.#cachedSizes = {
                        width: this.#container.clientWidth,
                        height: this.#container.clientHeight,
                    }
                    this.#sizesPromise = null
                    resolve(this.#cachedSizes)
                })
            })
            return this.#sizesPromise
            //        } else {
            //                                const r = this.#container.getBoundingClientRect()
            //            console.log("sizes() cached/real", this.#cachedSizes, r)
            //            requestAnimationFrame(() => {
            //                                const r = this.#container.getBoundingClientRect()
            //            console.log("sizes() FRAME cached/real", this.#cachedSizes, r)
            //            })

        }
        return this.#cachedSizes
    }
    async size() {
        return await this.#sizeForSide(await this.sideProp())
    }
    async #sizeForSide(sideProp) {
        const sizes = await this.sizes()
        return sizes?.[sideProp] ?? 0
    }
    async viewSize() {
        return await this.#viewSizeForSide(await this.sideProp())
    }
    async #viewSizeForSide(sideProp) {
        if (this.#isCacheWarmer) return 0
        if (!this.#view) return 0
        if (/*true ||*/ this.#view.cachedViewSize === null) {
            if (this.#viewSizePromise) {
                const cachedViewSize = await this.#viewSizePromise
                return cachedViewSize?.[sideProp] ?? 0
            }
            const view = this.#view
            this.#viewSizePromise = new Promise(resolve => {
                requestAnimationFrame(async () => {
                    //                    const r = this.#view.element.getBoundingClientRect()
                    //                    this.#view.cachedViewSize = {
                    //                        width: r.width,
                    //                        height: r.height,
                    //                    }
                    //                    resolve(this.#view.cachedViewSize[await this.sideProp()])
                    //                    return ;
                    const v = view?.element
                    const cachedViewSize = {
                        width: v.clientWidth,
                        height: v.clientHeight,
                    }
                    if (this.#view === view) {
                        this.#view.cachedViewSize = cachedViewSize
                    }
                    this.#viewSizePromise = null
                    //                                        console.log("viewSize() the rect we chose:", this.#view.cachedViewSize)
                    //                                        console.log("viewSize() the rect magnitude we chose:", this.#view.cachedViewSize[await this.sideProp()])
                    //                                        console.log('viewSize() prev slow but correct implementation rect:', this.#view.element.getBoundingClientRect())
                    //                                        console.log('viewSize() prev slow but correct implementation chosen magnitude:', this.#view.element.getBoundingClientRect()[await this.sideProp()])
                    resolve(cachedViewSize)
                })
            })
            const cachedViewSize = await this.#viewSizePromise
            return cachedViewSize?.[sideProp] ?? 0
        }
        return this.#view.cachedViewSize[sideProp] ?? 0
    }
    #expandedMetricSizesForSide(sideProp) {
        const expanded = this.#view?.expandedMetrics ?? null
        if (!expanded || expanded.side !== sideProp) {
            return null
        }
        const size = Number(expanded.size)
        const expandedSize = Number(expanded.expandedSize)
        if (!Number.isFinite(size) || size <= 0 || !Number.isFinite(expandedSize) || expandedSize <= 0) {
            return null
        }
        return {
            size,
            viewSize: expanded.column ? expandedSize + size * 2 : expandedSize,
        }
    }
    async start() {
        return await this.#startForScrollProp(await this.scrollProp())
    }
    async #startForScrollProp(scrollProp) {
        if (this.#cachedStart === null) {
            const cached = this.#pageMetricsCache
            if (MANABI_ENABLE_PAGE_METRICS_CACHE
                && cached
                && cached.index === this.#index
                && cached.scrolled === this.scrolled
                && cached.vertical === this.#vertical
                && cached.rtl === this.#rtl
                && cached.scrollProp === scrollProp
                && Number.isFinite(cached.start)) {
                this.#cachedStart = cached.start
                return this.#cachedStart
            }
            //        return new Promise(resolve => {
            //            requestAnimationFrame(async () => {
            //                    this.#cachedStart = Math.abs(this.#container[await this.scrollProp()])
            const start = Math.abs(this.#container[scrollProp])
            this.#cachedStart = start
            //        return start
            //                resolve(start)
            //            })
            //        })
        }
        return this.#cachedStart
    }
    async end() {
        //        await this.#awaitDirection();
        return (await this.start()) + (await this.size())
    }
    async page() {
        const metrics = await this.pageMetrics()
        return metrics.page
    }
    async pages() {
        const metrics = await this.pageMetrics()
        return metrics.pages
    }
    #normalizePages(rawPages) {
        if (this.#usesSingleMediaLogicalPage(rawPages)) {
            return 1
        }
        return rawPages
    }
    #usesSingleMediaLogicalPage(rawPages) {
        return MANABI_ENABLE_SINGLE_MEDIA_PAGE_NORMALIZATION
            && rawPages >= 3
            && this.#isSingleMediaElementWithoutText()
    }
    #logicalPageFromMeasuredPage({ measuredPage, pages, rawPages } = {}) {
        if (this.#usesSingleMediaLogicalPage(rawPages)) {
            return 0
        }
        return Number.isFinite(pages) && pages > 0
            ? Math.max(0, Math.min(pages - 1, measuredPage))
            : measuredPage
    }
    #physicalPageForScrollTarget({ page, metrics } = {}) {
        if (
            MANABI_ENABLE_SINGLE_MEDIA_PAGE_NORMALIZATION
            && this.#isSingleMediaElementWithoutText()
            && metrics?.pages === 1
        ) {
            return 1
        }
        return manabiNormalizeSingleMediaPageTarget({
            page,
            pages: metrics?.pages,
            isSingleMedia: this.#isSingleMediaElementWithoutText(),
        })
    }
    async pageMetrics() {
        const startedAt = manabiPerfNow();
        let metrics = null;
        const cached = this.#pageMetricsCache;
        if (MANABI_ENABLE_PAGE_METRICS_CACHE
            && cached
            && cached.index === this.#index
            && cached.scrolled === this.scrolled
            && cached.vertical === this.#vertical
            && cached.rtl === this.#rtl) {
            manabiTimelineMeasure('paginator.pageMetrics', startedAt, {
                cacheHit: true,
                cacheWarmer: this.#isCacheWarmer,
                index: cached.index,
                scrolled: cached.scrolled,
                vertical: cached.vertical,
                sideProp: cached.sideProp,
                scrollProp: cached.scrollProp,
                start: cached.start,
                end: cached.end,
                page: cached.page,
                pages: cached.pages,
                size: cached.size,
                viewSize: cached.viewSize,
                metricsSource: cached.metricsSource,
            }, 50);
            return cached;
        }
        try {
            await this.#awaitDirection()
            const sideProp = await this.sideProp()
            const scrollProp = await this.scrollProp()
            const expandedSizes = this.#expandedMetricSizesForSide(sideProp)
            let size = null
            let viewSize = null
            let start = null
            let metricsSource = 'layout'
            if (expandedSizes) {
                size = expandedSizes.size
                viewSize = expandedSizes.viewSize
                start = await this.#startForScrollProp(scrollProp)
                metricsSource = 'expanded'
            } else {
                [size, viewSize, start] = await Promise.all([
                    this.#sizeForSide(sideProp),
                    this.#viewSizeForSide(sideProp),
                    this.#startForScrollProp(scrollProp),
                ])
            }
            const end = start + size
            const rawPages = size > 0 ? Math.round(viewSize / size) : 0
            const pages = this.#normalizePages(rawPages)
            const measuredPage = size > 0 ? Math.floor(((start + end) / 2) / size) : 0
            const page = this.#logicalPageFromMeasuredPage({ measuredPage, pages, rawPages })
            metrics = {
                index: this.#index,
                scrolled: this.scrolled,
                vertical: this.#vertical,
                rtl: this.#rtl,
                sideProp,
                scrollProp,
                size,
                viewSize,
                start,
                end,
                page,
                pages,
                rawPages,
                metricsSource,
                inlineProgression: this.#view?.expandedMetrics?.inlineProgression === true,
            }
            if (MANABI_ENABLE_PAGE_METRICS_CACHE) {
                this.#pageMetricsCache = metrics
            }
            if (!this.#isCacheWarmer) {
                manabiPaginatorReaderLoadLog('paginator.pageMetrics.compute', this.#layoutMetricDiagnostics(metrics, {
                    cacheHit: false,
                    source: metricsSource,
                    computedSideProp: sideProp,
                    computedScrollProp: scrollProp,
                    normalizedPages: pages,
                }))
            }
            return metrics
        } finally {
            manabiTimelineMeasure('paginator.pageMetrics', startedAt, {
                cacheHit: false,
                cacheWarmer: this.#isCacheWarmer,
                index: this.#index,
                scrolled: metrics?.scrolled ?? this.scrolled,
                vertical: metrics?.vertical ?? this.#vertical,
                sideProp: metrics?.sideProp,
                scrollProp: metrics?.scrollProp,
                start: metrics?.start,
                end: metrics?.end,
                page: metrics?.page,
                pages: metrics?.pages,
                size: metrics?.size,
                viewSize: metrics?.viewSize,
                metricsSource: metrics?.metricsSource,
            });
        }
    }
    async scrollBy(dx, dy) {
        //        await this.#awaitDirection()
        await new Promise(resolve => {
            requestAnimationFrame(async () => {
                const delta = this.#vertical ? dy : dx
                const element = this.#container
                const scrollProp = await this.scrollProp()
                const [offset, a, b] = this.#scrollBounds
                const rtl = this.#rtl
                const min = rtl ? offset - b : offset - a
                const max = rtl ? offset + a : offset + b
                element[scrollProp] = Math.max(min, Math.min(max,
                    element[scrollProp] + delta))
                this.#cachedStart = null; // TODO: Needed here?
                this.#invalidatePageMetricsCache()
                resolve()
            })
        })
    }
    async snap(vx, vy) {
        //        await this.#awaitDirection();
        const velocity = this.#vertical ? vy : vx
        const [offset, a, b] = this.#scrollBounds
        const metrics = await this.pageMetrics()
        const start = metrics.start
        const end = metrics.end
        const pages = metrics.pages
        const size = metrics.size
        const min = Math.abs(offset) - a
        const max = Math.abs(offset) + b
        const d = velocity * (this.#rtl ? -size : size)
        const page = Math.floor(
            Math.max(min, Math.min(max, (start + end) / 2 +
                (isNaN(d) ? 0 : d))) / size)
        const targetPage = manabiNormalizeSingleMediaPageTarget({
            page,
            pages,
            isSingleMedia: this.#isSingleMediaElementWithoutText(),
        })

        await this.#scrollToPage(targetPage, 'snap', undefined, metrics).then(async () => {
            const dir = targetPage <= 0 ? -1 : targetPage >= pages - 1 ? 1 : null
            if (dir) return await this.#goTo({
                index: this.#adjacentIndex(dir),
                anchor: dir < 0 ? () => 1 : () => 0,
            })
        })
    }
    #onTouchStart(e) {
        const touch = e.changedTouches[0];
        // Determine if touch began in host container or inside the iframe’s document
        const target = touch.target;
        const inHost = this.#container.contains(target);
        const inIframe = this.#view?.document && target.ownerDocument === this.#view.document;
        if (!inHost && !inIframe) {
            this.#touchState = null;
            return;
        }
        this.#touchState = {
            startX: touch?.screenX,
            startY: touch?.screenY,
            x: touch?.screenX,
            y: touch?.screenY,
            t: e.timeStamp,
            vx: 0,
            vy: 0,
            pinched: false,
            triggered: false,
        };
        // Only block in paginated mode (not 'scrolled')
        if (!this.scrolled) {
            const sel = this.#view?.document?.getSelection?.();
            if (sel && !sel.isCollapsed && sel.rangeCount) {
                const range = sel.getRangeAt(0);
                const rect = range.getBoundingClientRect();
                const x = touch.clientX,
                    y = touch.clientY;
                const hitTolerance = 30;
                const nearStart = (
                    Math.abs(x - rect.left) <= hitTolerance &&
                    y >= rect.top - hitTolerance && y <= rect.bottom + hitTolerance
                );
                const nearEnd = (
                    Math.abs(x - rect.right) <= hitTolerance &&
                    y >= rect.top - hitTolerance && y <= rect.bottom + hitTolerance
                );
                if (nearStart || nearEnd) {
                    this.#isAdjustingSelectionHandle = true;
                    return;
                }
            }
        }
        this.#isAdjustingSelectionHandle = false;
    }
    async #onTouchMove(e) {
        // If touchStart was ignored or missing, do nothing
        if (!this.#touchState) return;
        if (this.#isAdjustingSelectionHandle) return;
        e.preventDefault();
        const touch = e.changedTouches[0];
        const state = this.#touchState;
        if (state.triggered) return;
        state.x = touch.screenX;
        state.y = touch.screenY;
        const dx = state.x - state.startX;
        const dy = state.y - state.startY;
        const minSwipe = 36; // px threshold

        this.#updateSwipeChevron(dx, minSwipe, { input: 'touch' });

        if (!state.triggered && Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > minSwipe) {
            state.triggered = true;
            this.#dispatchForegroundPageTurnActivity(this.#logicalDirectionForSwipeDelta(dx, 'touch'), {
                input: 'touch',
                source: 'paginator.touchmove',
            });

            if (dx < 0) {
                (this.bookDir === 'rtl') ? await this.prev() : await this.next();
            } else {
                (this.bookDir === 'rtl') ? await this.next() : await this.prev();
            }
        }
    }
    #onTouchEnd(e) {
        const touch = e.changedTouches?.[0] ?? null;
        const touchState = this.#touchState;
        this.#touchState = null;
        // If we just loaded a new section, skip the opacity reset
        if (this.#skipTouchEndOpacity) {
            this.#skipTouchEndOpacity = false
            return
        }
        this.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
            bubbles: true,
            composed: true,
            detail: {
                leftOpacity: '',
                rightOpacity: '',
                source: 'paginator',
                reason: 'paginator.touchEnd',
            }
        }))
    }
    // allows one to process rects as if they were LTR and horizontal
    async #getRectMapper(knownMetrics = null) {
        await this.#awaitDirection();
        const metrics = knownMetrics || await this.pageMetrics()
        if (this.scrolled) {
            const size = metrics.viewSize
            const topMargin = this.#topMargin
            const bottomMargin = this.#bottomMargin
            return this.#vertical ?
                ({
                    left,
                    right
                }) =>
                ({
                    left: size - right - topMargin,
                    right: size - left - bottomMargin
                }) :
                ({
                    top,
                    bottom
                }) => ({
                    left: top + topMargin,
                    right: bottom + bottomMargin
                })
        }
        const pxSize = metrics.pages * metrics.size
        if (metrics.inlineProgression === true) {
            return f => f
        }
        return this.#rtl ?
            ({
                left,
                right
            }) =>
            ({
                left: pxSize - right,
                right: pxSize - left
            }) :
            this.#vertical ?
                ({
                    top,
                    bottom
                }) => ({
                    left: top,
                    right: bottom
                }) :
                f => f
    }
    #wheelCooldown = false;
    #lastWheelDeltaX = 0;
    async #onWheel(e) {
        if (this.scrolled) return;
        e.preventDefault();
        if (Math.abs(e.deltaX) < Math.abs(e.deltaY)) return;

        const TRIGGER_THRESHOLD = 12;
        const RESET_THRESHOLD = 3;
        const REVEAL_CHEVRON_THRESHOLD = 5;

        // Early exit for "momentum falling" (hide chevrons if armed, deltaX dropping, and below threshold)
        if (
            this.#wheelArmed &&
            Math.abs(e.deltaX) < Math.abs(this.#lastWheelDeltaX) &&
            Math.abs(e.deltaX) < TRIGGER_THRESHOLD
        ) {
            this.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
                bubbles: true,
                composed: true,
                detail: {
                    leftOpacity: '',
                    rightOpacity: '',
                    source: 'paginator',
                    reason: 'paginator.wheel.momentum-falling',
                }
            }));
            this.#lastWheelDeltaX = e.deltaX;
            return;
        }

        if (this.#wheelArmed) {
            if (Math.abs(e.deltaX) > REVEAL_CHEVRON_THRESHOLD) {
                this.#updateSwipeChevron(e.deltaX, TRIGGER_THRESHOLD, { input: 'wheel' });
            } else {
                this.#updateSwipeChevron(0, TRIGGER_THRESHOLD, { input: 'wheel' });
            }
        }

        if (this.#wheelArmed && Math.abs(e.deltaX) > TRIGGER_THRESHOLD) {
            this.#wheelArmed = false;
            this.#wheelCooldown = true;
            this.#dispatchForegroundPageTurnActivity(this.#logicalDirectionForSwipeDelta(e.deltaX, 'wheel'), {
                input: 'wheel',
                source: 'paginator.wheel',
            });
            if (e.deltaX > 0) {
                await this.prev();
            } else {
                await this.next();
            }
            this.#updateSwipeChevron(e.deltaX, TRIGGER_THRESHOLD, { input: 'wheel' })
            setTimeout(() => {
                this.#wheelCooldown = false;
            }, 100);
        } else if (!this.#wheelArmed && !this.#wheelCooldown && Math.abs(e.deltaX) < RESET_THRESHOLD) {
            this.#wheelArmed = true;
        }
        this.#lastWheelDeltaX = e.deltaX;
    }
    async #scrollToRect(rect, reason) {
        const metrics = await this.pageMetrics()
        if (this.scrolled) {
            const rectMapper = await this.#getRectMapper(metrics);
            const offset = rectMapper(rect).left - this.#topMargin
            return await this.#scrollTo(offset, reason, undefined, metrics)
        }
        const rectMapper = await this.#getRectMapper(metrics);
        const offset = rectMapper(rect).left
        return await this.#scrollToPage(Math.floor(offset / metrics.size) + (this.#rtl ? -1 : 1), reason, undefined, metrics)
    }
    async #scrollTo(offset, reason, smooth, knownMetrics = null) {
        const startedAt = manabiPerfNow();
        await this.#awaitDirection();
        let scrollMode = 'raf';
        const effectiveSmooth = false;
        try {
            const scroll = async () => {
                const element = this.#container
                const scrollProp = await this.scrollProp()
                const metrics = knownMetrics || await this.pageMetrics()
                const size = metrics.size
                const atStart = this.#adjacentIndex(-1) == null && metrics.page <= 1
                const atEnd = this.#adjacentIndex(1) == null && metrics.page >= metrics.pages - 2
                const targetStart = Math.abs(offset)
                const liveStart = () => Math.abs(element?.[scrollProp] ?? 0)
                const scrolledMetrics = () => this.#metricsWithStart(metrics, liveStart())
                if (
                    knownMetrics
                    && Math.abs((knownMetrics.start ?? 0) - targetStart) < 0.5
                    && Math.abs(liveStart() - targetStart) < 0.5
                ) {
                    this.#scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size]
                    const actualMetrics = scrolledMetrics()
                    this.#rememberPageMetrics(actualMetrics)
                    await this.#afterScroll(reason, actualMetrics)
                    return
                }
                if (!knownMetrics && Math.abs(liveStart() - targetStart) < 0.5) {
                    this.#scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size]
                    const actualMetrics = scrolledMetrics()
                    this.#rememberPageMetrics(actualMetrics)
                    await this.#afterScroll(reason, actualMetrics)
                    return
                }
                // FIXME: vertical-rl only, not -lr
                if (this.scrolled && this.#vertical) offset = -offset
                const rememberScrolledMetrics = () => {
                    const actualStart = liveStart()
                    const actualMetrics = scrolledMetrics()
                    if (!this.#isCacheWarmer && Math.abs(actualStart - targetStart) > 0.5) {
                        manabiPaginatorReaderLoadLog('paginator.scrollTo.actualStartMismatch', {
                            reason,
                            index: this.#index,
                            scrollProp,
                            targetStart: manabiRound(targetStart, 1),
                            actualStart: manabiRound(actualStart, 1),
                            requestedOffset: manabiRound(offset, 1),
                            beforePage: metrics.page ?? null,
                            beforeStart: Number.isFinite(metrics.start) ? manabiRound(metrics.start, 1) : null,
                            actualPage: actualMetrics?.page ?? null,
                            actualPages: actualMetrics?.pages ?? null,
                        })
                    }
                    this.#rememberPageMetrics(actualMetrics)
                    return actualMetrics
                }
                if ((reason === 'snap' || effectiveSmooth) && this.hasAttribute('animated')) return animate(
                    element[scrollProp], offset, 300, easeOutQuad,
                    x => element[scrollProp] = x,
                ).then(async () => {
                    const actualMetrics = rememberScrolledMetrics()
                    this.#scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size]
                    await this.#afterScroll(reason, actualMetrics)
                })
                else {
                    element[scrollProp] = offset
                    const actualMetrics = rememberScrolledMetrics()
                    this.#scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size]
                    await this.#afterScroll(reason, actualMetrics)
                }
            }

            //            // Prevent new transitions while one is running
            //            if (this.#transitioning) {
            //                await scroll();
            //                return;
            //            }

            //            if (
            //                !this.#view ||
            //                document.visibilityState !== 'visible' ||
            //                (reason === 'snap' || reason === 'anchor' || reason === 'selection') ||
            //                typeof document.startViewTransition !== 'function'
            //                ) {
            const shouldUseDirectInitialNavigation =
                (reason === 'navigation'
                    || reason === 'anchor'
                    || reason === 'page'
                    || reason === 'selection'
                    || reason === 'snap'
                    || effectiveSmooth !== smooth)
                && !effectiveSmooth
            if (shouldUseDirectInitialNavigation) {
                scrollMode = 'direct'
                await scroll()
                return
            }
            return await new Promise(resolve => {
                requestAnimationFrame(async () => {
                    const shouldFade = !(reason === 'page' || reason === 'snap' || reason === 'anchor' || reason === 'selection' || reason === 'navigation');
                    if (!shouldFade) {
                        await scroll()
                    } else {
                        this.#container.classList.add('view-fade')
                        // Allow the browser to paint the fade
                        /*await new Promise(r => setTimeout(r, 65));
                         this.#container.classList.add('view-faded')*/
                        await scroll()
                        this.#container.classList.remove('view-faded')
                        this.#container.classList.remove('view-fade')
                    }
                    resolve()
                })
            })
        } finally {
            manabiTimelineMeasure('paginator.scrollTo.raf', startedAt, {
                cacheWarmer: this.#isCacheWarmer,
                index: this.#index,
                reason,
                mode: scrollMode,
                smooth: !!effectiveSmooth,
                scrolled: this.scrolled,
            });
        }
        //                } else {
        //                    let goingForward = offset > this.start;
        //                    let slideFrom, slideTo;
        //
        //                    if (!this.#rtl) {
        //                        if (goingForward) {
        //                            slideFrom = 'slide-from-right';
        //                            slideTo = 'slide-to-left';
        //                        } else {
        //                            slideFrom = 'slide-from-left';
        //                            slideTo = 'slide-to-right';
        //                        }
        //                    } else {
        //                        if (goingForward) {
        //                            slideFrom = 'slide-from-left';
        //                            slideTo = 'slide-to-right';
        //                        } else {
        //                            slideFrom = 'slide-from-right';
        //                            slideTo = 'slide-to-left';
        //                        }
        //                    }
        //
        //                    this.dispatchEvent(new CustomEvent('setViewTransition', {
        //                        bubbles: true,
        //                        composed: true,
        //                        detail: {
        //                            viewTransitionName: 'scroll-to',
        //                            slideFrom,
        //                            slideTo
        //                        }
        //                    }));
        //
        //                    this.#transitioning = true;
        //                    try {
        //                        await document.startViewTransition(scroll);
        //                    } finally {
        //                        this.#transitioning = false;
        //                    }
        //                }
    }
    async #scrollToPage(page, reason, smooth, knownMetrics = null) {
        const metrics = knownMetrics || await this.pageMetrics()
        const size = metrics.size
        const physicalTargetPage = this.#physicalPageForScrollTarget({ page, metrics })
        const normalizedSingleMedia = physicalTargetPage !== page
        const offset = size * (this.#rtl ? -physicalTargetPage : physicalTargetPage)
        if (
            !this.#isCacheWarmer
            && (
                manabiPaginatorVerbosePageTurns()
                || normalizedSingleMedia
                || page <= 0
                || page >= metrics.pages - 1
            )
        ) {
            manabiPaginatorReaderLoadLog('paginator.scrollToPage.target', this.#layoutMetricDiagnostics(metrics, {
                reason,
                requestedPage: page,
                targetPage: physicalTargetPage,
                logicalTargetPage: page,
                normalizedSingleMedia,
                targetOffset: offset,
                smooth: smooth ?? null,
                willBeforeContent: page <= 0,
                willAfterContent: page >= metrics.pages - 1,
            }))
        }
        return await this.#scrollTo(offset, reason, smooth, metrics)
    }
    async scrollToAnchor(anchor, select) {
        //            await new Promise(resolve => requestAnimationFrame(resolve));
        await this.#scrollToAnchor(anchor, select ? 'selection' : 'navigation')
    }
    #schedulePastContentCorrection({
        index,
        anchor,
        anchorKind,
        logReaderLoad,
    }) {
        if (this.#isCacheWarmer || typeof anchor !== 'number' || this.scrolled) {
            return
        }
        const scheduledView = this.#view
        const scheduledIndex = this.#index
        const run = async () => {
            if (this.#view !== scheduledView || this.#index !== scheduledIndex || this.#index !== index) {
                return
            }
            const metrics = await manabiRunPaginatorBoundary(
                'paginator.display.pageMetrics.deferred',
                { index, anchorKind },
                () => this.pageMetrics().catch(() => null),
                { logReaderLoad }
            )
            if (this.#view !== scheduledView || this.#index !== scheduledIndex || this.#index !== index) {
                return
            }
            const pageCurrent = metrics?.page ?? null
            const pageTotal = metrics?.pages ?? null
            if (typeof pageCurrent !== 'number' || typeof pageTotal !== 'number' || pageTotal <= 2) {
                return
            }
            let landedPastContent = false
            if (pageCurrent < pageTotal - 1) {
                const frameRect = this.#view?.element?.querySelector?.('iframe')?.getBoundingClientRect?.() ?? null
                const rootRect = this.#view?.document?.documentElement?.getBoundingClientRect?.() ?? null
                landedPastContent = !!(frameRect && rootRect && frameRect.bottom <= rootRect.top + 1)
            }
            if (pageCurrent >= pageTotal - 1 || landedPastContent) {
                const correctedPage = Math.max(1, pageTotal - 2)
                await manabiRunPaginatorBoundary(
                    'paginator.display.correctPastContentPage.deferred',
                    { index, correctedPage, pageCurrent, pageTotal, landedPastContent },
                    () => this.#scrollToPage(correctedPage, 'navigation', undefined, metrics),
                    { logReaderLoad }
                )
            }
        }
        if (typeof requestAnimationFrame === 'function') {
            requestAnimationFrame(() => requestAnimationFrame(() => void run()))
        } else {
            setTimeout(() => void run(), 0)
        }
    }
    #rectForAnchorNode(anchorNode, reason = 'anchor') {
        if (!anchorNode) return { rect: null, source: 'none' }
        if (anchorNode.nodeType === 1) {
            const rect = anchorNode.getBoundingClientRect?.()
            if (rect && rect.width > 0 && rect.height > 0) {
                return { rect, source: 'element-bounding' }
            }
        }
        if (reason !== 'selection' && typeof anchorNode.getBoundingClientRect === 'function') {
            const rect = anchorNode.getBoundingClientRect()
            if (rect && rect.width > 0 && rect.height > 0) {
                return { rect, source: 'range-bounding' }
            }
        }
        const rects = anchorNode.getClientRects?.()
        if (!rects) return { rect: null, source: 'none' }
        const rect = Array.from(rects)
            .find(r => r.width > 0 && r.height > 0) || rects[0] || null
        return { rect, source: rect ? 'client-rects' : 'none' }
    }
    async #scrollToAnchor(anchor, reason = 'anchor') {
        const startedAt = manabiPerfNow();
        let rectSource = null;
        //        console.log('#scrollToAnchor0...', anchor)
        try {
            this.#anchor = anchor
            const anchorNode = uncollapse(anchor)
            // if anchor is an element or a range
            if (anchorNode?.getBoundingClientRect || anchorNode?.getClientRects) {
                const anchorRect = this.#rectForAnchorNode(anchorNode, reason)
                const rect = anchorRect.rect
                rectSource = anchorRect.source
                if (!rect) return
                await this.#scrollToRect(rect, reason)
                return
            }
            // if anchor is a fraction
            const metrics = await this.pageMetrics()
            if (this.scrolled) {
                await this.#scrollTo(anchor * metrics.viewSize, reason, undefined, metrics)
                return
            }
            if (!metrics.pages) return
            const textPages = metrics.pages - 2
            const newPage = Math.round(anchor * (textPages - 1))
            if (!this.#isCacheWarmer && manabiPaginatorVerbosePageTurns()) {
                manabiPaginatorReaderLoadLog('paginator.scrollToAnchor.fractionTarget', this.#layoutMetricDiagnostics(metrics, {
                    reason,
                    anchor,
                    textPages,
                    targetPage: newPage + 1,
                }))
            }
            await this.#scrollToPage(newPage + 1, reason, undefined, metrics)
        } finally {
            manabiTimelineMeasure('paginator.scrollToAnchor', startedAt, {
                cacheWarmer: this.#isCacheWarmer,
                index: this.#index,
                reason,
                anchorType: anchor instanceof Range ? 'range' : typeof anchor,
                rectSource,
                scrolled: this.scrolled,
            });
        }
    }
    async #NscrollToAnchor(anchor, reason = 'anchor') {
        //        console.log("#scrollToAnchor...cached sizes:", this.#cachedSizes, "real sizes: ", await this.sizes())
        await this.#awaitDirection();

        return new Promise(resolve => {
            requestAnimationFrame(async () => {
                //                console.log("#scrollToAnchor...frames...cached sizes:", this.#cachedSizes, "real sizes: ", await this.sizes())
                this.#anchor = anchor;
                //                console.log('scrollToAnchor: anchor=', anchor);
                // Determine anchor target (could be Range or Element)
                const anchorNode = uncollapse(anchor);

                // OG slow path: use getClientRects for sanity check
                //                const rects = anchorNode?.getClientRects?.();
                ////                console.log('OG clientRects:', rects);
                //                if (rects && rects.length > 0) {
                //                    const ogRect = Array.from(rects).find(r => r.width > 0 && r.height > 0) || rects[0];
                ////                    console.log('OG rect chosen:', ogRect);
                //                    //                        await this.#scrollToRect(ogRect, reason);
                //                    //                        resolve();
                //                    //                        return;
                //                }
                //                console.log('anchorNode=', anchorNode);

                // Fast path: compute offset using offsetLeft/offsetTop chains
                let elNode = anchorNode;
                if (elNode && elNode.startContainer !== undefined) {
                    elNode = elNode.startContainer;
                }
                if (elNode && (elNode.nodeType === Node.ELEMENT_NODE || elNode.nodeType === Node.TEXT_NODE)) {
                    let el = elNode.nodeType === Node.TEXT_NODE ? elNode.parentElement : elNode;
                    if (el && el.nodeType === Node.ELEMENT_NODE) {
                        let left = el.offsetLeft, top = el.offsetTop;
                        const width = el.offsetWidth, height = el.offsetHeight;
                        //                        console.log('initial offsets:', { left, top, width, height });
                        let current = el;
                        let doc = el.ownerDocument;
                        // Traverse offsetParent chain (and iframe chain)
                        while (current && current !== this.#container) {
                            const parent = current.offsetParent;
                            if (!parent) {
                                const frame = doc?.defaultView?.frameElement;
                                if (frame) {
                                    left += frame.offsetLeft;
                                    top += frame.offsetTop;
                                    current = frame;
                                    doc = current.ownerDocument;
                                    continue;
                                }
                                break;
                            }
                            current = parent;
                            if (current !== this.#container) {
                                left += current.offsetLeft;
                                top += current.offsetTop;
                            }
                        }
                        //                        console.log('after traversal offsets:', { left, top });
                        // Re‑create a synthetic rect from the accumulated offsets and
                        // feed it to the normal scroll‑to‑rect path.  This avoids the
                        // heavyweight `getClientRects()` call but still lets the
                        // existing mapper logic figure out the correct offset for both
                        // page‑ and scroll‑modes.
                        const syntheticRect = {
                            left,
                            right: left + width,
                            top,
                            bottom: top + height,
                            width,
                            height
                        };
                        //                        console.log('syntheticRect=', syntheticRect);
                        const rectMapper = await this.#getRectMapper();
                        const mapped = rectMapper(syntheticRect);
                        //                        console.log('mappedRect=', mapped);
                        // Use the same helper that the slow path relies on so we keep
                        // consistent behaviour between modes.
                        await this.#scrollToRect(syntheticRect, reason);
                        resolve();
                        return;
                    }
                }
                // Fraction fallback
                const metrics = await this.pageMetrics();
                if (this.scrolled) {
                    await this.#scrollTo(anchor * metrics.viewSize, reason, undefined, metrics);
                    resolve();
                    return;
                }
                if (!metrics.pages) {
                    resolve();
                    return;
                }
                const textPages = metrics.pages - 2;
                const newPage = Math.round(anchor * (textPages - 1));
                await this.#scrollToPage(newPage + 1, reason, undefined, metrics);
                resolve();
            });
        });
    }
    async #getVisibleRange() {
        //            console.log("getVisibleRange...")
        await this.#awaitDirection();
        const cacheKey = await this.#visibleRangeCacheKey()
        if (cacheKey && this.#visibleRangeCache?.doc === cacheKey.doc && this.#visibleRangeCache?.key === cacheKey.key) {
            return this.#cloneRange(this.#visibleRangeCache.range)
        }
        if (cacheKey && this.#visibleRangeInFlight?.doc === cacheKey.doc && this.#visibleRangeInFlight?.key === cacheKey.key) {
            const range = await this.#visibleRangeInFlight.promise
            return this.#cloneRange(range)
        }
        const cacheVersion = this.#visibleRangeCacheVersion
        const computeVisibleRange = async () => {
        //            console.log("getVisibleRange... await refreshElementVisibilityObserver..")
        const visibleSentinelIDs = await this.#getSentinelVisibilities()
        //            await new Promise(r => requestAnimationFrame(r));

        //            console.log("getVisibleRange... awaited refreshElementVisibilityObserver")
        //            console.log("getVisibleRange... sentinels", this.#visibleSentinelIDs.size)

        // Find the first and last visible content node, skipping <reader-sentinel> and mnb-* elements

        const doc = this.#view.document

        if (visibleSentinelIDs.length === 0) {
            const range = doc.createRange();
            range.selectNodeContents(doc.body);
            range.collapse(true);
            return range
        }

        const isValid = node => {
            return (node &&
                (node.nodeType === Node.TEXT_NODE ||
                    (node.nodeType === Node.ELEMENT_NODE &&
                        node.tagName !== 'reader-sentinel')))
        }

        const visibleSentinels = doc.querySelectorAll(
            visibleSentinelIDs
                .map(id => `#${CSS.escape(id)}`)
                .join(',')
        );
        const firstSentinel = visibleSentinels[0];
        const lastSentinel = visibleSentinels[visibleSentinels.length - 1];

        const findNext = el => {
            let node = el?.nextSibling;
            while (node && !isValid(node)) node = node.nextSibling;
            return node;
        };

        const findPrev = el => {
            let node = el?.previousSibling;
            while (node && !isValid(node)) node = node.previousSibling;
            return node;
        };

        const startNode = firstSentinel ? findNext(firstSentinel) : null;
        const endNode = lastSentinel ? findPrev(lastSentinel) : null;

        const range = doc.createRange();
        if (startNode && endNode) {
            range.setStartBefore(startNode);
            range.setEndAfter(endNode);
        } else {
            range.selectNodeContents(doc.body);
            range.collapse(true);
        }
        return range;
        }
        const promise = computeVisibleRange()
        if (cacheKey) {
            this.#visibleRangeInFlight = {
                doc: cacheKey.doc,
                key: cacheKey.key,
                promise
            }
        }
        try {
            const range = await promise
            if (cacheKey && this.#visibleRangeCacheVersion === cacheVersion) {
                this.#visibleRangeCache = {
                    doc: cacheKey.doc,
                    key: cacheKey.key,
                    range
                }
            }
            return this.#cloneRange(range)
        } finally {
            if (cacheKey && this.#visibleRangeInFlight?.promise === promise) {
                this.#visibleRangeInFlight = null
            }
        }
    }
    async #afterScroll(reason, knownMetrics = null) {
        if (this.#isCacheWarmer) {
            return;
        }
        //            console.log("#afterScroll...")

        const canUseMetricsOnlyRelocate =
            knownMetrics
            && (reason === 'navigation' || reason === 'anchor' || reason === 'page' || reason === 'blank-correction')
        const range = canUseMetricsOnlyRelocate ? null : await this.#getVisibleRange()
        const visibleRangeRect = range?.getBoundingClientRect?.() ?? null
        const visibleRangeDiagnostics = {
            visibleRangeSource: canUseMetricsOnlyRelocate ? 'metrics-only' : (range ? 'range' : 'none'),
            visibleRangeCollapsed: range?.collapsed ?? null,
            visibleRangeRectLeft: visibleRangeRect ? manabiRound(visibleRangeRect.left, 2) : null,
            visibleRangeRectTop: visibleRangeRect ? manabiRound(visibleRangeRect.top, 2) : null,
            visibleRangeRectWidth: visibleRangeRect ? manabiRound(visibleRangeRect.width, 2) : null,
            visibleRangeRectHeight: visibleRangeRect ? manabiRound(visibleRangeRect.height, 2) : null,
        }
        // don't set new anchor if relocation was to scroll to anchor
        if (reason !== 'selection' && reason !== 'navigation' && reason !== 'anchor')
            this.#anchor = range
        else this.#justAnchored = true

        const index = this.#index
        const logProgressInputs = payload => {
            manabiTimelineMark('paginator.relocate.progressInputs', payload);
            if (
                manabiPaginatorVerbosePageTurns()
                || payload.fraction < 0
                || payload.fraction > 1
            ) {
                manabiPaginatorReaderLoadLog('paginator.relocate.progressInputs', payload);
            }
        };
        const detail = {
            reason,
            range,
            index
        }
        let relocationMetrics = null
        if ((reason === 'page' || reason === 'navigation') && this.#pendingPageTurnDirection) {
            detail.pageTurnDirection = this.#pendingPageTurnDirection;
        }

        if (this.scrolled) {
            const metrics = knownMetrics || await this.pageMetrics()
            relocationMetrics = metrics
            detail.fraction = metrics.viewSize > 0 ? metrics.start / metrics.viewSize : 0
            logProgressInputs(this.#layoutMetricDiagnostics(metrics, {
                reason,
                mode: 'scrolled',
                fraction: detail.fraction,
                ...visibleRangeDiagnostics,
            }));
        } else {
            const metrics = knownMetrics || await this.pageMetrics()
            relocationMetrics = metrics
            const { page, pages } = metrics
            if (pages <= 2) {
                detail.fraction = 0;
                detail.size = 1;
                logProgressInputs(this.#layoutMetricDiagnostics(metrics, {
                    reason,
                    mode: 'paginated-degenerate',
                    fraction: detail.fraction,
                    size: detail.size,
                    ...visibleRangeDiagnostics,
                }));
                this.dispatchEvent(new CustomEvent('relocate', {
                    detail
                }))
                return
            }
            this.#header.style.visibility = page > 1 ? 'visible' : 'hidden'
            const contentPageCount = Math.max(1, pages - 2)
            detail.fraction = manabiClamp01((page - 1) / contentPageCount)
            detail.size = 1 / contentPageCount
            logProgressInputs(this.#layoutMetricDiagnostics(metrics, {
                reason,
                mode: 'paginated',
                fraction: detail.fraction,
                size: detail.size,
                ...visibleRangeDiagnostics,
            }));
        }

        const relocateSignature = JSON.stringify({
            index,
            reason,
            fraction: Number.isFinite(detail.fraction) ? Math.round(detail.fraction * 1_000_000) : null,
            size: Number.isFinite(detail.size) ? Math.round(detail.size * 1_000_000) : null,
            page: knownMetrics?.page ?? null,
            pages: knownMetrics?.pages ?? null,
        })
        if (this.#isLoading && this.#lastRelocateDispatchSignature === relocateSignature) {
            manabiTimelineMark('paginator.relocate.skipDuplicate', {
                reason,
                index,
                fraction: detail.fraction,
                size: detail.size,
            })
            manabiPaginatorReaderLoadLog('paginator.relocate.skipDuplicate', {
                reason,
                index,
                fraction: Number.isFinite(detail.fraction) ? manabiRound(detail.fraction, 6) : null,
                size: Number.isFinite(detail.size) ? manabiRound(detail.size, 6) : null,
                page: knownMetrics?.page ?? null,
                pages: knownMetrics?.pages ?? null,
                pageTurnDirection: detail.pageTurnDirection ?? null,
                signature: relocateSignature,
            })
            return
        }
        this.#lastRelocateDispatchSignature = relocateSignature
        this.dispatchEvent(new CustomEvent('relocate', {
            detail
        }))
        if (
            MANABI_ENABLE_PAGE_TURN_BLANK_CORRECTION
            &&
            reason === 'page'
            && knownMetrics
            && !this.scrolled
            && relocationMetrics
            && Number.isFinite(this.#pendingPageTurnStep)
        ) {
            this.#scheduleBlankPageCorrection({
                index,
                direction: this.#pendingPageTurnStep,
                metrics: relocationMetrics,
            })
        }

    }
    #logicalDirectionForSwipeDelta(dx, input = 'touch') {
        if (dx === 0) return null;
        if (input === 'wheel') return dx > 0 ? 'backward' : 'forward';
        const swipedLeft = dx < 0;
        return this.bookDir === 'rtl'
            ? (swipedLeft ? 'backward' : 'forward')
            : (swipedLeft ? 'forward' : 'backward');
    }
    #chevronSideForLogicalDirection(logicalDirection) {
        if (logicalDirection === 'forward') {
            return this.bookDir === 'rtl' ? 'left' : 'right';
        }
        if (logicalDirection === 'backward') {
            return this.bookDir === 'rtl' ? 'right' : 'left';
        }
        return null;
    }
    #dispatchForegroundPageTurnActivity(logicalDirection, { input = 'touch', source = 'paginator' } = {}) {
        if (logicalDirection !== 'forward' && logicalDirection !== 'backward') return;
        if (manabiPaginatorVerbosePageTurns()) {
            manabiPaginatorReaderLoadLog('paginator.pageTurn.activity', {
                input,
                source,
                logicalDirection,
                chevronSide: this.#chevronSideForLogicalDirection(logicalDirection),
                isRTL: this.bookDir === 'rtl',
                index: this.#index,
                pendingPageTurnDirection: this.#pendingPageTurnDirection,
                isLoading: this.#isLoading,
                locked: this.#locked,
            });
        }
        this.dispatchEvent(new CustomEvent('foregroundPageTurnActivity', {
            bubbles: true,
            composed: true,
            detail: {
                input,
                source,
                logicalDirection,
                chevronSide: this.#chevronSideForLogicalDirection(logicalDirection),
                isRTL: this.bookDir === 'rtl',
            },
        }));
    }
    #readerLoadPageTurnSummary(metrics = null) {
        const container = this.#container;
        return {
            index: this.#index,
            pendingPageTurnDirection: this.#pendingPageTurnDirection,
            vertical: this.#vertical,
            rtl: this.#rtl,
            scrollTop: container ? manabiRound(container.scrollTop, 1) : null,
            page: metrics?.page ?? null,
            pages: metrics?.pages ?? null,
            start: metrics ? manabiRound(metrics.start, 1) : null,
            viewSize: metrics ? manabiRound(metrics.viewSize, 1) : null,
            metricsSource: metrics?.metricsSource ?? null,
        };
    }
    #pageTurnContentOffsetDiagnostics(metrics = null, {
        direction = null,
        crossedSection = false,
        expectedCrossSection = false,
        shouldGo = null,
        didMove = null,
        adjacentIndex = null,
        requestedPage = null,
        beforeIndex = null,
        beforePage = null,
        beforePages = null,
        beforeStart = null,
        inputSource = null,
        elapsedMs = null,
    } = {}) {
        const section = this.sections?.[this.#index] ?? null;
        const doc = this.#view?.document ?? this.document ?? null;
        const body = doc?.body ?? null;
        const bodyStyle = body?.ownerDocument?.defaultView?.getComputedStyle?.(body) ?? null;
        const page = metrics?.page ?? null;
        const pages = metrics?.pages ?? null;
        const contentPages = Number.isFinite(pages) ? Math.max(1, pages - 2) : null;
        const contentPage = Number.isFinite(page) && contentPages !== null
            ? Math.max(0, Math.min(contentPages - 1, page - 1))
            : null;
        const contentFraction = contentPages && Number.isFinite(contentPage)
            ? contentPage / contentPages
            : null;
        const epubOffset = Number.isFinite(contentFraction)
            ? this.#index + contentFraction
            : this.#index;
        return {
            index: this.#index,
            sectionHref: section?.href ?? section?.id ?? null,
            direction,
            crossedSection,
            expectedCrossSection,
            shouldGo,
            didMove,
            adjacentIndex,
            requestedPage,
            beforeIndex,
            beforePage,
            beforePages,
            beforeStart: Number.isFinite(beforeStart) ? manabiRound(beforeStart, 1) : null,
            page,
            pages,
            contentPage,
            contentPages,
            contentFraction: Number.isFinite(contentFraction) ? manabiRound(contentFraction, 6) : null,
            epubOffset: Number.isFinite(epubOffset) ? manabiRound(epubOffset, 6) : null,
            scrollStart: metrics ? manabiRound(metrics.start, 1) : null,
            pageSize: metrics ? manabiRound(metrics.size, 1) : null,
            viewSize: metrics ? manabiRound(metrics.viewSize, 1) : null,
            metricsSource: metrics?.metricsSource ?? metrics?.source ?? null,
            inputSource,
            elapsedMs,
            writingMode: bodyStyle?.writingMode ?? null,
            bodyClass: body?.className ?? null,
        };
    }
    #updateSwipeChevron(dx, minSwipe, { input = 'touch' } = {}) {
        const progress = Math.min(1, Math.abs(dx) / minSwipe);
        const logicalDirection = this.#logicalDirectionForSwipeDelta(dx, input);
        const chevronSide = this.#chevronSideForLogicalDirection(logicalDirection);
        const leftOpacity = chevronSide === 'left' ? progress : 0;
        const rightOpacity = chevronSide === 'right' ? progress : 0;
        this.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
            bubbles: true,
            composed: true,
            detail: {
                leftOpacity,
                rightOpacity,
                source: 'paginator',
                reason: 'paginator.swipe.progress',
                input,
                dx,
                logicalDirection,
                chevronSide,
                isRTL: this.bookDir === 'rtl',
            }
        }));
        if (Math.abs(dx) > minSwipe) {
            // Enqueue the reset after meeting threshold
            this.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
                bubbles: true,
                composed: true,
                detail: {
                    leftOpacity: '',
                    rightOpacity: '',
                    source: 'paginator',
                    reason: 'paginator.swipe.threshold',
                }
            }))
        }
    }
    async #display(promise) {
        //            console.log("#display...")
        this.#suspendOnExpandAnchor = false
        this.#setLoading(true, 'display.start')
        const displayStartedAt = manabiPerfNow();
        manabiTimelineMark('paginator.display.start', {
            cacheWarmer: this.#isCacheWarmer,
        });
        let displayIndex = null;
        let displayAnchorKind = null;
        let displayError = null
        const shouldLogReaderLoad = manabiShouldLogPaginatorReaderLoad(this.#isCacheWarmer)
        if (!this.#isCacheWarmer) {
            manabiPaginatorReaderLoadLog('paginator.display.lifecycle', this.#displayLifecycleDiagnostics('display.start', {
                displayIndex,
            }))
        }
        try {
            const {
                index,
                src,
                anchor,
                localPage,
                onLoad,
                select
            } = await manabiRunPaginatorBoundary(
                'paginator.display.input',
                {
                    cacheWarmer: this.#isCacheWarmer,
                },
                () => promise,
                { logReaderLoad: shouldLogReaderLoad }
            )
        displayIndex = index
        displayAnchorKind = Number.isFinite(localPage)
            ? 'localPage'
            : (typeof anchor === 'function'
            ? 'function'
            : (anchor instanceof Range ? 'range' : typeof anchor))
        if (shouldLogReaderLoad) {
            manabiPaginatorReaderLoadLog('paginator.display.promiseResolved', {
                index,
                hasSrc: !!src,
                anchorKind: displayAnchorKind,
                src,
            });
        }
        if (!this.#isCacheWarmer) {
            manabiPaginatorReaderLoadLog('paginator.display.lifecycle', this.#displayLifecycleDiagnostics('display.inputResolved', {
                targetIndex: index,
                currentIndex: this.#index,
                hasSrc: !!src,
                anchorKind: displayAnchorKind,
                localPage: Number.isFinite(localPage) ? localPage : null,
                hasAnchor: !!anchor,
            }))
        }

        //            console.log("#display...awaited promise")
        const previousIndex = this.#index
        this.#index = index
        this.#lastRelocateDispatchSignature = null
        const hasFocus = this.#view?.document?.hasFocus?.()
        let hiddenOldViewForSectionSwap = false
        let previousViewForSectionSwap = null
        if (src) {
            const afterLoad = async (doc) => {
                if (this.#isCacheWarmer) {
                    await onLoad?.({
                        doc,
                        location: doc?.location?.href || src,
                        index,
                    })
                } else {
                    if (doc.head) {
                        this.#installStyleElementsForDocument(doc)
                    }
                    //                    console.log("#display... await onLoad")
                    await onLoad?.({
                        doc,
                        location: doc.location.href,
                        index,
                    })
                    //                    console.log("#display... awaited onLoad")
                }
            }

            if (this.#isCacheWarmer) {
                const response = await manabiRunPaginatorBoundary(
                    'paginator.display.cacheWarmer.fetch',
                    { index, src, cacheWarmer: true },
                    () => fetch(src),
                    { logReaderLoad: shouldLogReaderLoad }
                )
                const text = await manabiRunPaginatorBoundary(
                    'paginator.display.cacheWarmer.text',
                    { index, src, cacheWarmer: true },
                    () => response.text(),
                    { logReaderLoad: shouldLogReaderLoad }
                )
                const contentType = response.headers.get('content-type') || ''
                const parserType = /xml|xhtml/i.test(contentType)
                    ? 'application/xhtml+xml'
                    : 'text/html'
                const doc = new DOMParser().parseFromString(text, parserType)
                await manabiRunPaginatorBoundary(
                    'paginator.display.cacheWarmer.afterLoad',
                    { index, src, cacheWarmer: true, parserType },
                    () => afterLoad(doc),
                    { logReaderLoad: shouldLogReaderLoad }
                )
            } else {
                this.#skipTouchEndOpacity = true
                this.#suspendOnExpandAnchor = true

                this.#cachedSizes = null
                this.#sizesPromise = null
                this.#viewSizePromise = null
                this.#cachedStart = null
                this.#invalidateVisibleRangeCache()

                //                console.log("#display... await load")
                const previousView = this.#view
                const replacingLoadedDocument = previousIndex !== index && !!previousView?.document?.body
                const view = this.#createView({ replacement: replacingLoadedDocument })
                const beforeRender = this.#beforeRender.bind(this)
                if (replacingLoadedDocument) {
                    hiddenOldViewForSectionSwap = true
                    previousViewForSectionSwap = previousView
                    Object.assign(view.element.style, {
                        position: 'absolute',
                        inset: '0',
                        visibility: 'hidden',
                        pointerEvents: 'none',
                        zIndex: '-1',
                    })
                    if (!this.#isCacheWarmer) {
                    manabiPaginatorReaderLoadLog('paginator.display.lifecycle', this.#displayLifecycleDiagnostics('display.prepareReplacementView', {
                        targetIndex: index,
                        previousIndex,
                        previousDocumentSubpath: manabiReaderLoadSubpathFromURL(previousView?.document?.location?.href),
                        targetHref: this.sections?.[index]?.href ?? this.sections?.[index]?.id ?? null,
                        previousViewVisible: previousView?.element ? getComputedStyle(previousView.element).visibility !== 'hidden' : null,
                        replacementViewHidden: getComputedStyle(view.element).visibility === 'hidden',
                        anchorKind: displayAnchorKind,
                    }))
                    }
                }

                if (!this.#isCacheWarmer) {
                }
                if (shouldLogReaderLoad) {
                    manabiPaginatorReaderLoadLog('paginator.display.viewLoad.start', {
                        index,
                        src,
                    });
                }
                if (!this.#isCacheWarmer) {
                    manabiPaginatorReaderLoadLog('paginator.display.lifecycle', this.#displayLifecycleDiagnostics('display.beforeViewLoad', {
                        targetIndex: index,
                        currentIndex: this.#index,
                        replacingExistingView: !!previousView,
                        previousViewHasBody: !!previousView?.document?.body,
                        anchorKind: displayAnchorKind,
                    }))
                }
                if (previousView?.document?.body) {
                    const beforeLoadVisualSnapshot = this.#mediaVisualDiagnostics(this.#pageMetricsCache, {
                        phase: 'beforeViewLoad',
                        targetIndex: index,
                        targetHref: this.sections?.[index]?.href ?? this.sections?.[index]?.id ?? null,
                        previousIndex,
                        previousDocumentSubpath: manabiReaderLoadSubpathFromURL(previousView?.document?.location?.href),
                        staleDocumentSnapshot: previousIndex !== index,
                        currentIndex: this.#index,
                        anchorKind: displayAnchorKind,
                    })
                    if (this.#shouldLogMediaVisualDiagnostics(beforeLoadVisualSnapshot, { crossedSection: index !== this.#index, displayBoundary: true })) {
                        manabiPaginatorReaderLoadLog('paginator.display.visualSnapshot', beforeLoadVisualSnapshot)
                        if (!beforeLoadVisualSnapshot?.staleDocumentSnapshot) {
                            this.#scheduleMediaVisualFollowUp(beforeLoadVisualSnapshot, {
                                reason: 'beforeViewLoad',
                                phase: 'display',
                                crossedSection: index !== this.#index,
                                displayBoundary: true,
                            })
                        }
                    }
                }
                globalThis.manabiApplyChromeInsets?.(null, 'paginator.display.beforeViewLoad')
                try {
                    await view.load(src, afterLoad, beforeRender)
                    this.#commitView(view)
                    if (hiddenOldViewForSectionSwap) {
                        Object.assign(view.element.style, {
                            position: 'absolute',
                            inset: '0',
                            visibility: 'hidden',
                            pointerEvents: 'none',
                            zIndex: '-1',
                        })
                    }
                } catch (error) {
                    if (hiddenOldViewForSectionSwap) {
                        Object.assign(view.element.style, {
                            visibility: '',
                            pointerEvents: '',
                        })
                    }
                    this.#discardView(view)
                    throw error
                }
                if (shouldLogReaderLoad) {
                    manabiPaginatorReaderLoadLog('paginator.display.viewLoad.finish', {
                        index,
                        src,
                    });
                }
                if (!this.#isCacheWarmer) {
                    manabiPaginatorReaderLoadLog('paginator.display.lifecycle', this.#displayLifecycleDiagnostics('display.afterViewLoad', {
                        targetIndex: index,
                        currentIndex: this.#index,
                        anchorKind: displayAnchorKind,
                        elapsedMs: manabiRound(manabiPerfNow() - displayStartedAt, 1),
                    }))
                }
                this.#installMediaVisualEventDiagnostics('display.viewLoad.finish')
                //                console.log("#display... awaited load")
                if (!this.#isCacheWarmer) {
                }

                // Reset chevrons when loading new section
                document.dispatchEvent(new CustomEvent('resetSideNavChevrons', {
                    detail: {
                        source: 'paginator',
                        reason: 'paginator.display-new-section',
                    },
                }));
                //            this.dispatchEvent(new CustomEvent('create-overlayer', {
                //            this.dispatchEvent(new CustomEvent('create-overlayer', {
                //                detail: {
                //                    doc: view.document, index,
                //                    attach: overlayer => view.overlayer = overlayer,
                //                },
                //            }))
                //                this.style.display = 'block'
            }
        }

        //            console.log("#display... call scroll to anchor")

        const scrollToAnchorStartedAt = manabiPerfNow();
        if (!this.#isCacheWarmer) {
        }
        if (shouldLogReaderLoad) {
            manabiPaginatorReaderLoadLog('paginator.display.scrollToAnchor.start', {
                index,
                anchorKind: displayAnchorKind,
            });
        }
        if (!this.#isCacheWarmer) {
            manabiPaginatorReaderLoadLog('paginator.display.lifecycle', this.#displayLifecycleDiagnostics('display.beforeScrollToAnchor', {
                targetIndex: index,
                currentIndex: this.#index,
                anchorKind: displayAnchorKind,
                localPage: Number.isFinite(localPage) ? localPage : null,
            }))
        }
        const resolvedAnchor = (typeof anchor === 'function' ?
            anchor(this.#view.document) : anchor) ?? 0
        const normalizedLocalPage = Number.isFinite(localPage)
            ? Math.max(0, Math.round(localPage))
            : null
        if (normalizedLocalPage !== null) {
            const metrics = await this.pageMetrics()
            const textPageCount = Math.max(1, metrics.pages - 2)
            const targetPage = Math.min(textPageCount - 1, normalizedLocalPage) + 1
            const targetLocalPage = Math.max(0, targetPage - 1)
            this.#anchor = manabiPaginatorAnchorForLocalPage({
                localPage: targetLocalPage,
                textPageCount,
            })
            if (shouldLogReaderLoad) {
                manabiPaginatorReaderLoadLog('paginator.display.localPage.anchorStored', {
                    index,
                    localPage: normalizedLocalPage,
                    targetLocalPage,
                    textPageCount,
                    anchor: this.#anchor,
                });
            }
            const targetStart = metrics.size * (this.#rtl ? -targetPage : targetPage)
            const alreadyAtTargetPage =
                Math.abs((metrics.start ?? 0) - Math.abs(targetStart)) < 0.5
                && metrics.page === targetPage
            if (alreadyAtTargetPage) {
                manabiTimelineMark('paginator.display.localPage.skipSamePage', {
                    index,
                    targetPage,
                    currentPage: metrics.page,
                    start: metrics.start,
                    size: metrics.size,
                    pages: metrics.pages,
                })
                await this.#afterScroll('navigation', metrics)
            } else {
                await this.#scrollToPage(targetPage, 'navigation', undefined, metrics)
            }
        } else {
            await this.scrollToAnchor(resolvedAnchor, select)
        }
        if (shouldLogReaderLoad) {
            manabiPaginatorReaderLoadLog('paginator.display.scrollToAnchor.finish', {
                index,
                anchorKind: displayAnchorKind,
                elapsedMs: manabiRound(manabiPerfNow() - scrollToAnchorStartedAt, 1),
            });
        }
        if (!this.#isCacheWarmer) {
            manabiPaginatorReaderLoadLog('paginator.display.lifecycle', this.#displayLifecycleDiagnostics('display.afterScrollToAnchor', {
                targetIndex: index,
                currentIndex: this.#index,
                anchorKind: displayAnchorKind,
                scrollElapsedMs: manabiRound(manabiPerfNow() - scrollToAnchorStartedAt, 1),
                elapsedMs: manabiRound(manabiPerfNow() - displayStartedAt, 1),
            }))
        }
        this.#suspendOnExpandAnchor = false
        if (hasFocus) this.focusView()
        if (hiddenOldViewForSectionSwap && this.#view?.element) {
            Object.assign(this.#view.element.style, {
                position: 'relative',
                inset: '',
                visibility: '',
                pointerEvents: '',
                zIndex: '',
            })
            if (previousViewForSectionSwap && previousViewForSectionSwap !== this.#view) {
                previousViewForSectionSwap.destroy()
                previousViewForSectionSwap.element.remove()
            }
            if (!this.#isCacheWarmer) {
                manabiPaginatorReaderLoadLog('paginator.display.lifecycle', this.#displayLifecycleDiagnostics('display.revealNewView', {
                    targetIndex: index,
                    previousIndex,
                    anchorKind: displayAnchorKind,
                    elapsedMs: manabiRound(manabiPerfNow() - displayStartedAt, 1),
                }))
            }
        }
        if (!this.#isCacheWarmer && this.style.visibility === 'hidden') {
            this.style.visibility = 'visible'
        }
        if (!this.#isCacheWarmer) {
        }
        if (!this.#isCacheWarmer) {
        }
                manabiTimelineMark('paginator.display.didDisplay.dispatch', {
                    index,
                    anchorKind: displayAnchorKind,
                    cacheWarmer: this.#isCacheWarmer,
                });
        if (!this.#isCacheWarmer) {
            manabiPaginatorReaderLoadLog('paginator.display.lifecycle', this.#displayLifecycleDiagnostics('display.beforeDidDisplay', {
                targetIndex: index,
                currentIndex: this.#index,
                anchorKind: displayAnchorKind,
                elapsedMs: manabiRound(manabiPerfNow() - displayStartedAt, 1),
            }))
        }
        const displayVisualSnapshot = this.#mediaVisualDiagnostics(this.#pageMetricsCache, {
            phase: 'afterScrollBeforeDidDisplay',
            targetIndex: index,
            currentIndex: this.#index,
            anchorKind: displayAnchorKind,
            elapsedMs: manabiRound(manabiPerfNow() - displayStartedAt, 1),
        })
        if (this.#shouldLogMediaVisualDiagnostics(displayVisualSnapshot, { displayBoundary: true })) {
            manabiPaginatorReaderLoadLog('paginator.display.visualSnapshot', displayVisualSnapshot)
            this.#scheduleMediaVisualFollowUp(displayVisualSnapshot, {
                reason: 'afterScrollBeforeDidDisplay',
                phase: 'display',
                displayBoundary: true,
            })
        }
        this.dispatchEvent(new CustomEvent('didDisplay', {}))
        this.#schedulePastContentCorrection({
            index,
            anchor: normalizedLocalPage !== null ? null : resolvedAnchor,
            anchorKind: displayAnchorKind,
            logReaderLoad: shouldLogReaderLoad,
        })
        if (shouldLogReaderLoad) {
            manabiPaginatorReaderLoadLog('paginator.display.didDisplay.dispatched', {
                index,
                anchorKind: displayAnchorKind,
            });
        }
        if (!this.#isCacheWarmer) {
            manabiPaginatorReaderLoadLog('paginator.display.lifecycle', this.#displayLifecycleDiagnostics('display.didDisplayDispatched', {
                targetIndex: index,
                currentIndex: this.#index,
                anchorKind: displayAnchorKind,
                elapsedMs: manabiRound(manabiPerfNow() - displayStartedAt, 1),
            }))
        }
        //            console.log("#display... fin")
        } catch (error) {
            displayError = error
            if (shouldLogReaderLoad) {
                manabiPaginatorReaderLoadLog('paginator.display.error', {
                    index: displayIndex,
                    anchorKind: displayAnchorKind,
                    error: error?.message || String(error),
                });
            }
            if (!this.#isCacheWarmer) {
                manabiPaginatorReaderLoadLog('paginator.display.lifecycle', this.#displayLifecycleDiagnostics('display.error', {
                    targetIndex: displayIndex,
                    anchorKind: displayAnchorKind,
                    error: error?.message || String(error),
                    elapsedMs: manabiRound(manabiPerfNow() - displayStartedAt, 1),
                }))
            }
            throw error
        } finally {
            this.#suspendOnExpandAnchor = false
            this.#setLoading(false, displayError ? 'display.error.finally' : 'display.complete.finally')
            if (!this.#isCacheWarmer) {
                manabiPaginatorReaderLoadLog('paginator.display.lifecycle', this.#displayLifecycleDiagnostics('display.finally', {
                    targetIndex: displayIndex,
                    anchorKind: displayAnchorKind,
                    error: displayError?.message ?? null,
                    elapsedMs: manabiRound(manabiPerfNow() - displayStartedAt, 1),
                }))
            }
            manabiTimelineMeasure('paginator.display', displayStartedAt, {
                cacheWarmer: this.#isCacheWarmer,
                index: displayIndex,
                anchorKind: displayAnchorKind,
                error: displayError?.message,
            });
        }
    }
    #canGoToIndex(index) {
        return index >= 0 && index <= this.sections.length - 1
    }
    async #goTo({
        index,
        anchor,
        localPage,
        select
    }) {
        const goToStartedAt = manabiPerfNow();
        //        console.log("#goTo...", this.style.display, index, anchor)
        const currentIndex = this.#index;
        const willLoadNewIndex = index !== this.#index;
        const anchorKind = Number.isFinite(localPage)
            ? 'localPage'
            : (typeof anchor === 'function'
            ? 'function'
            : (anchor instanceof Range ? 'range' : typeof anchor));
        const shouldLogReaderLoad = manabiShouldLogPaginatorReaderLoad(this.#isCacheWarmer);
        if (shouldLogReaderLoad) {
            manabiPaginatorReaderLoadLog('paginator.goTo.start', {
                fromIndex: currentIndex,
                toIndex: index,
                sectionID: this.sections?.[index]?.id ?? null,
                willLoadNewIndex,
                anchorKind,
            });
        }
        manabiTimelineMark('paginator.goTo.start', {
            cacheWarmer: this.#isCacheWarmer,
            fromIndex: currentIndex,
            toIndex: index,
            willLoadNewIndex,
            anchorKind,
            select: !!select,
        });
        try {
            if (!willLoadNewIndex && anchor == null && !Number.isFinite(localPage) && !select) {
                return
            }
            this.dispatchEvent(new CustomEvent('goTo', {
                detail: {
                    willLoadNewIndex: willLoadNewIndex,
                    index,
                    currentIndex,
                    anchorKind,
                    select: !!select,
                },
            }))
            if (!willLoadNewIndex) {
                try {
                    await this.#display({
                        index,
                        anchor,
                        localPage,
                        select
                    })
                } catch (error) {
                    throw error;
                }
            } else {
                if (MANABI_ENABLE_SIMPLIFIED_SECTION_LOADING) {
                    const oldIndex = this.#index
                    const onLoad = async (detail) => {
                        if (!this.#isCacheWarmer) {
                            this.setStyles(this.#styles)
                        }

                        this.dispatchEvent(new CustomEvent('load', {
                            detail
                        }))
                    }
                    if (shouldLogReaderLoad) {
                        manabiPaginatorReaderLoadLog('paginator.section.load.simplified', {
                            index,
                            sectionID: this.sections?.[index]?.id ?? null,
                        });
                    }
                    await this.#display(Promise.resolve(this.sections[index].load())
                        .then(src => ({
                            index,
                            src,
                            anchor,
                            localPage,
                            onLoad,
                            select
                        }))
                        .catch(error => {
                            throw error
                        }));
                    this.sections[oldIndex]?.unload?.()
                    return
                }
                let prefetchEntry = null
                let usedPrefetchPromise = false
                if (MANABI_ENABLE_PREFETCH_WAIT_FOR_IN_FLIGHT) {
                    prefetchEntry = await manabiRunPaginatorBoundary(
                        'paginator.prefetch.wait',
                        {
                            index,
                            sectionID: this.sections?.[index]?.id ?? null,
                        },
                        () => this.#waitForNeighborPrefetch(index),
                        { logReaderLoad: shouldLogReaderLoad }
                    )
                }

                const oldIndex = this.#index
                const onLoad = async (detail) => {
                    if (!this.#isCacheWarmer) {
                        this.setStyles(this.#styles)
                    }

                    this.dispatchEvent(new CustomEvent('load', {
                        detail
                    }))
                }

                try {
                    let sectionLoadPromise;
                    if (
                        MANABI_ENABLE_PREFETCH_PROMISE_REUSE
                        && prefetchEntry?.promise
                        && this.#prefetchCache.get(index) === prefetchEntry
                    ) {
                        usedPrefetchPromise = true;
                        manabiTimelineMark('paginator.section.load.prefetchReuse', {
                            index,
                            sectionID: this.sections?.[index]?.id ?? null,
                        });
                        if (shouldLogReaderLoad) {
                            manabiPaginatorReaderLoadLog('paginator.section.load.prefetchReuse', {
                                index,
                                sectionID: this.sections?.[index]?.id ?? null,
                            });
                        }
                        sectionLoadPromise = prefetchEntry.promise;
                    } else {
                        if (shouldLogReaderLoad) {
                            manabiPaginatorReaderLoadLog('paginator.section.load.start', {
                                index,
                                sectionID: this.sections?.[index]?.id ?? null,
                            });
                        }
                        sectionLoadPromise = this.sections[index].load()
                            .then(src => {
                                if (shouldLogReaderLoad) {
                                    manabiPaginatorReaderLoadLog('paginator.section.load.finish', {
                                        index,
                                        sectionID: this.sections?.[index]?.id ?? null,
                                        src,
                                    });
                                }
                                return src
                            })
                            .catch(error => {
                                if (shouldLogReaderLoad) {
                                    manabiPaginatorReaderLoadLog('paginator.section.load.error', {
                                        index,
                                        sectionID: this.sections?.[index]?.id ?? null,
                                        error: error?.message || String(error),
                                    });
                                }
                                throw error
                            });
                    }
                    await this.#display(Promise.resolve(sectionLoadPromise)
                        .then(src => ({
                            index,
                            src,
                            anchor,
                            localPage,
                            onLoad,
                            select
                        }))
                        .catch(error => {
                            throw error
                        }));
                    this.sections[oldIndex]?.unload?.()
                } catch (error) {
                    throw error;
                } finally {
                    if (prefetchEntry) {
                        if (usedPrefetchPromise) this.#consumeNeighborPrefetch(index, prefetchEntry)
                        else this.#releaseNeighborPrefetch(index, prefetchEntry)
                    }
                }
                this.#scheduleNeighborPrefetch(
                    'section-display',
                    MANABI_NEIGHBOR_PREFETCH_AFTER_SECTION_DISPLAY_DELAY_MS
                )
            }
        } finally {
            if (shouldLogReaderLoad) {
                manabiPaginatorReaderLoadLog('paginator.goTo.finish', {
                    fromIndex: currentIndex,
                    toIndex: index,
                    sectionID: this.sections?.[index]?.id ?? null,
                    willLoadNewIndex,
                    anchorKind,
                });
            }
            manabiTimelineMeasure('paginator.goTo', goToStartedAt, {
                cacheWarmer: this.#isCacheWarmer,
                fromIndex: currentIndex,
                toIndex: index,
                willLoadNewIndex,
                anchorKind,
                select: !!select,
            });
        }
    }
    async goTo(target) {
        if (this.#locked) return
        const resolved = await target
        if (this.#canGoToIndex(resolved.index)) return await this.#goTo(resolved)
    }
    async #scrollPrev(distance) {
        if (!this.#view) return true
        if (this.scrolled) {
            const style = getComputedStyle(this.#container);
            const lineAdvance = this.#vertical ?
                parseFloat(style.fontSize) || 20 :
                parseFloat(style.lineHeight) || 20;
            const metrics = await this.pageMetrics()
            const scrollDistance = distance ?? (metrics.size - lineAdvance);
            if (metrics.start > 0) {
                return await this.#scrollTo(Math.max(0, metrics.start - scrollDistance), null, true, metrics);
            }
            return true;
        }
        const metrics = await this.pageMetrics()
        const previousSectionIndex = this.#adjacentIndex(-1)
        const blockedAtBookStart = previousSectionIndex == null && metrics.page <= 1
        if (!this.#isCacheWarmer && manabiPaginatorVerbosePageTurns()) {
            manabiPaginatorReaderLoadLog('paginator.pageTurn.prev.decision', this.#layoutMetricDiagnostics(metrics, {
                distance: distance ?? null,
                adjacentIndex: previousSectionIndex ?? null,
                blockedAtBookStart,
                willCrossSectionIfPageBeforeContent: metrics.page - 1 <= 0,
            }))
        }
        if (blockedAtBookStart) return false
        const boundaryDecision = manabiPageTurnBoundaryDecision({
            currentPage: metrics.page,
            pageCount: metrics.pages,
            step: -1,
            adjacentIndex: previousSectionIndex,
        })
        const page = boundaryDecision.requestedPage
        const textPageCount = Math.max(1, metrics.pages - 2)
        const textPage = Math.max(1, Math.min(textPageCount, metrics.page))
        if (!this.#isCacheWarmer && manabiPaginatorVerbosePageTurns()) {
            manabiPaginatorReaderLoadLog('paginator.pageTurn.prev.target', this.#layoutMetricDiagnostics(metrics, {
                requestedPage: metrics.page - 1,
                resolvedPage: page,
                adjacentIndex: previousSectionIndex ?? null,
                willCrossSection: boundaryDecision.crossesSection,
                skipSentinelScroll: boundaryDecision.shouldGoToAdjacentSection,
                textPage,
                textPageCount,
                beforeContentBoundary: metrics.page <= 1,
                afterContentBoundary: metrics.page >= metrics.pages - 2,
            }))
        }
        if (boundaryDecision.shouldGoToAdjacentSection) return true
        return await this.#scrollToPage(page, 'page', false, metrics).then(() => boundaryDecision.crossesSection)
    }
    async #scrollNext(distance) {
        if (!this.#view) return true
        if (this.scrolled) {
            const style = getComputedStyle(this.#container);
            const lineAdvance = this.#vertical ?
                parseFloat(style.fontSize) || 20 :
                parseFloat(style.lineHeight) || 20;
            const metrics = await this.pageMetrics()
            const scrollDistance = distance ?? (metrics.size - lineAdvance);
            if (metrics.viewSize - metrics.end > 2) {
                return await this.#scrollTo(Math.min(metrics.viewSize, metrics.start + scrollDistance), null, true, metrics);
            }
            return true;
        }
        const metrics = await this.pageMetrics()
        const nextSectionIndex = this.#adjacentIndex(1)
        const blockedAtBookEnd = nextSectionIndex == null && metrics.page >= metrics.pages - 2
        if (!this.#isCacheWarmer && manabiPaginatorVerbosePageTurns()) {
            manabiPaginatorReaderLoadLog('paginator.pageTurn.next.decision', this.#layoutMetricDiagnostics(metrics, {
                distance: distance ?? null,
                adjacentIndex: nextSectionIndex ?? null,
                blockedAtBookEnd,
                willCrossSectionIfPageAfterContent: metrics.page + 1 >= metrics.pages - 1,
            }))
        }
        if (blockedAtBookEnd) return false
        const boundaryDecision = manabiPageTurnBoundaryDecision({
            currentPage: metrics.page,
            pageCount: metrics.pages,
            step: 1,
            adjacentIndex: nextSectionIndex,
        })
        const page = boundaryDecision.requestedPage
        const pages = metrics.pages
        const textPageCount = Math.max(1, metrics.pages - 2)
        const textPage = Math.max(1, Math.min(textPageCount, metrics.page))
        if (!this.#isCacheWarmer && manabiPaginatorVerbosePageTurns()) {
            manabiPaginatorReaderLoadLog('paginator.pageTurn.next.target', this.#layoutMetricDiagnostics(metrics, {
                requestedPage: metrics.page + 1,
                resolvedPage: page,
                adjacentIndex: nextSectionIndex ?? null,
                willCrossSection: boundaryDecision.crossesSection,
                skipSentinelScroll: boundaryDecision.shouldGoToAdjacentSection,
                textPage,
                textPageCount,
                beforeContentBoundary: metrics.page <= 1,
                afterContentBoundary: metrics.page >= metrics.pages - 2,
            }))
        }
        if (boundaryDecision.shouldGoToAdjacentSection) return true
        return await this.#scrollToPage(page, 'page', false, metrics).then(() => boundaryDecision.crossesSection)
    }
    async atStart() {
        const metrics = await this.pageMetrics()
        return this.#adjacentIndex(-1) == null && metrics.page <= 1
    }
    async atEnd() {
        const startedAt = manabiPerfNow();
        let metrics = null;
        try {
            metrics = await this.pageMetrics()
            return this.#adjacentIndex(1) == null && metrics.page >= metrics.pages - 2
        } finally {
            manabiTimelineMeasure('paginator.atEnd', startedAt, {
                cacheWarmer: this.#isCacheWarmer,
                index: this.#index,
                page: metrics?.page,
                pages: metrics?.pages,
            });
        }
    }
    #adjacentIndex(dir) {
        for (let index = this.#index + dir; this.#canGoToIndex(index); index += dir)
            if (this.sections[index]?.linear !== 'no') return index
    }
    #shouldSuppressPostPageTurnDuplicate(dir, distance, navigationSource, now = manabiPerfNow()) {
        const lastPageTurn = this.#lastSettledPageTurn
        if (!lastPageTurn) return false
        return manabiShouldSuppressPostPageTurnDuplicate({
            lastDirection: lastPageTurn.direction,
            direction: dir > 0 ? 'forward' : 'backward',
            distance,
            navigationSource,
            elapsedMs: Number.isFinite(lastPageTurn.settledAt) ? now - lastPageTurn.settledAt : null,
        })
    }
    async #turnPage(dir, distance, options = {}) {
        const navigationSource = globalThis.__manabiNavigationIntent?.source ?? null
        const turnStartedAt = manabiPerfNow()
        if (!options.bypassPostTurnDuplicateSuppression && this.#shouldSuppressPostPageTurnDuplicate(dir, distance, navigationSource, turnStartedAt)) {
            const lastPageTurn = this.#lastSettledPageTurn
            if (!this.#isCacheWarmer) {
                manabiPaginatorReaderLoadLog('paginator.pageTurn.dropDuplicate', {
                    index: this.#index,
                    direction: dir > 0 ? 'forward' : 'backward',
                    reason: 'pageTurnDuplicateAfterSettle',
                    elapsedMs: Number.isFinite(lastPageTurn?.settledAt)
                        ? manabiRound(turnStartedAt - lastPageTurn.settledAt, 1)
                        : null,
                    thresholdMs: MANABI_POST_PAGE_TURN_DUPLICATE_SUPPRESSION_MS,
                    previousIndex: lastPageTurn?.index ?? null,
                    previousPage: lastPageTurn?.page ?? null,
                    inputSource: navigationSource,
                })
            }
            return { ignored: true, reason: 'pageTurnDuplicateAfterSettle' }
        }
        if (this.#locked) {
            const lockedElapsedMs = this.#lockedAt == null ? null : manabiRound(manabiPerfNow() - this.#lockedAt, 1)
            const pendingDirection = this.#pendingPageTurnDirection
            const queuedDirection = dir > 0 ? 'forward' : 'backward'
            const queueDecision = manabiLockedPageTurnQueueDecision({
                pendingQueueAllowed: this.#pendingPageTurnQueueAllowed === true,
                pendingRequestedPage: this.#pendingPageTurnRequestedPage,
                pendingPageCount: this.#pendingPageTurnPageCount,
                pendingDirection,
                queuedDirection,
                queuedStep: dir,
                lockedElapsedMs,
                distance,
            })
            if (!queueDecision.shouldQueue) {
                if (!this.#isCacheWarmer) {
                    manabiPaginatorReaderLoadLog(
                        queueDecision.reason === 'pageTurnDuplicateDuringLock'
                            ? 'paginator.pageTurn.dropDuplicate'
                            : 'paginator.pageTurn.ignoreLocked',
                        {
                            index: this.#index,
                            direction: queuedDirection,
                            reason: queueDecision.reason,
                            pendingPageTurnDirection: pendingDirection,
                            pendingPageTurnQueueAllowed: this.#pendingPageTurnQueueAllowed === true,
                            pendingRequestedPage: this.#pendingPageTurnRequestedPage,
                            pendingPageCount: this.#pendingPageTurnPageCount,
                            projectedQueuedPage: queueDecision.projectedQueuedPage ?? null,
                            isLoading: this.#isLoading,
                            lockedElapsedMs,
                            thresholdMs: MANABI_LOCKED_PAGE_TURN_DUPLICATE_SUPPRESSION_MS,
                            inputSource: navigationSource,
                        }
                    )
                }
                return { ignored: true, reason: queueDecision.reason }
            }
            const previousQueuedPageTurn = this.#queuedPageTurn
            previousQueuedPageTurn?.resolve?.({ superseded: true })
            const queuedPromise = new Promise((resolve, reject) => {
                this.#queuedPageTurn = { dir, distance, resolve, reject }
            })
            if (!this.#isCacheWarmer) {
                manabiPaginatorReaderLoadLog('paginator.pageTurn.queued', {
                    index: this.#index,
                    direction: queuedDirection,
                    distance: distance ?? null,
                    queuedDirection,
                    reason: queueDecision.reason,
                    replacedQueuedTurn: !!previousQueuedPageTurn,
                    pendingPageTurnDirection: pendingDirection,
                    pendingRequestedPage: this.#pendingPageTurnRequestedPage,
                    pendingPageCount: this.#pendingPageTurnPageCount,
                    projectedQueuedPage: queueDecision.projectedQueuedPage ?? null,
                    isLoading: this.#isLoading,
                    lockedElapsedMs,
                })
            }
            return await queuedPromise
        }

        this.#locked = true
        this.#lockedAt = manabiPerfNow()
        this.#pendingPageTurnDirection = dir > 0 ? 'forward' : 'backward'
        this.#pendingPageTurnStep = dir
        this.#pendingPageTurnQueueAllowed = false
        this.#pendingPageTurnRequestedPage = null
        this.#pendingPageTurnPageCount = null
        const beforeMetrics = await this.pageMetrics().catch(() => null)
        const beforeIndex = this.#index
        const beforeAdjacentIndex = this.#adjacentIndex(dir)
        const requestedPage = Number.isFinite(beforeMetrics?.page)
            ? beforeMetrics.page + dir
            : null
        const expectedCrossSection = Number.isFinite(requestedPage) && Number.isFinite(beforeMetrics?.pages)
            ? (dir < 0 ? requestedPage <= 0 : requestedPage >= beforeMetrics.pages - 1)
            : false
        this.#pendingPageTurnRequestedPage = requestedPage
        this.#pendingPageTurnPageCount = Number.isFinite(beforeMetrics?.pages) ? beforeMetrics.pages : null
        this.#pendingPageTurnQueueAllowed =
            Number.isFinite(requestedPage)
            && Number.isFinite(beforeMetrics?.pages)
            && !expectedCrossSection
        const beforeVisualSnapshot = this.#mediaVisualDiagnostics(beforeMetrics, {
            phase: 'before',
            direction: dir > 0 ? 'forward' : 'backward',
            adjacentIndex: beforeAdjacentIndex ?? null,
            requestedPage,
        })
        try {
            const prev = dir === -1
            const shouldGo = !!(await (prev ? await this.#scrollPrev(distance) : await this.#scrollNext(distance)))
            if (shouldGo) await this.#goTo({
                index: beforeAdjacentIndex,
                anchor: prev ? () => 1 : () => 0,
            })
            const finalMetrics = await this.pageMetrics().catch(() => null)
            const didMove =
                shouldGo
                || this.#index !== beforeIndex
                || finalMetrics?.page !== beforeMetrics?.page
                || Math.abs((finalMetrics?.start ?? NaN) - (beforeMetrics?.start ?? NaN)) >= 1
            if (didMove) {
                this.#lastSettledPageTurn = {
                    direction: dir > 0 ? 'forward' : 'backward',
                    settledAt: manabiPerfNow(),
                    index: this.#index,
                    page: finalMetrics?.page ?? null,
                }
            }
            if (!this.#isCacheWarmer && didMove) {
                manabiPaginatorReaderLoadLog('paginator.pageTurn.contentOffset', this.#pageTurnContentOffsetDiagnostics(finalMetrics, {
                    direction: dir > 0 ? 'forward' : 'backward',
                    crossedSection: this.#index !== beforeIndex,
                    expectedCrossSection,
                    shouldGo,
                    didMove,
                    adjacentIndex: beforeAdjacentIndex ?? null,
                    requestedPage,
                    beforeIndex,
                    beforePage: beforeMetrics?.page ?? null,
                    beforePages: beforeMetrics?.pages ?? null,
                    beforeStart: beforeMetrics?.start ?? null,
                    inputSource: navigationSource,
                    elapsedMs: this.#lockedAt == null ? null : manabiRound(manabiPerfNow() - this.#lockedAt, 1),
                }))
            }
            const finalVisualSnapshot = this.#mediaVisualDiagnostics(finalMetrics, {
                phase: 'final',
                direction: dir > 0 ? 'forward' : 'backward',
                crossedSection: this.#index !== beforeIndex,
                expectedCrossSection,
                shouldGo,
                didMove,
                adjacentIndex: beforeAdjacentIndex ?? null,
                requestedPage,
                beforeIndex,
                beforePage: beforeMetrics?.page ?? null,
                beforePages: beforeMetrics?.pages ?? null,
                elapsedMs: this.#lockedAt == null ? null : manabiRound(manabiPerfNow() - this.#lockedAt, 1),
            })
            if (this.#shouldLogMediaVisualDiagnostics(beforeVisualSnapshot, { crossedSection: this.#index !== beforeIndex || expectedCrossSection })) {
                manabiPaginatorReaderLoadLog('paginator.pageTurn.visualSnapshot', beforeVisualSnapshot)
                this.#scheduleMediaVisualFollowUp(beforeVisualSnapshot, {
                    reason: 'pageTurn.before',
                    phase: 'pageTurn',
                    crossedSection: this.#index !== beforeIndex || expectedCrossSection,
                })
            }
            if (this.#shouldLogMediaVisualDiagnostics(finalVisualSnapshot, { crossedSection: this.#index !== beforeIndex || expectedCrossSection })) {
                manabiPaginatorReaderLoadLog('paginator.pageTurn.visualSnapshot', finalVisualSnapshot)
                this.#scheduleMediaVisualFollowUp(finalVisualSnapshot, {
                    reason: 'pageTurn.final',
                    phase: 'pageTurn',
                    crossedSection: this.#index !== beforeIndex || expectedCrossSection,
                })
            }
            if (!this.#isCacheWarmer && !didMove) {
                manabiPaginatorReaderLoadLog('paginator.pageTurn.noMove', this.#layoutMetricDiagnostics(finalMetrics ?? beforeMetrics, {
                    direction: dir > 0 ? 'forward' : 'backward',
                    shouldGo,
                    expectedCrossSection,
                    adjacentIndex: beforeAdjacentIndex ?? null,
                    requestedPage,
                    beforeIndex,
                    beforePage: beforeMetrics?.page ?? null,
                    beforePages: beforeMetrics?.pages ?? null,
                    beforeStart: beforeMetrics ? manabiRound(beforeMetrics.start, 1) : null,
                    inputSource: navigationSource,
                    elapsedMs: this.#lockedAt == null ? null : manabiRound(manabiPerfNow() - this.#lockedAt, 1),
                }))
            }
            if (
                !this.#isCacheWarmer
                && (
                    (shouldGo && this.#index === beforeIndex)
                    || (expectedCrossSection && !shouldGo && this.#index === beforeIndex && beforeAdjacentIndex != null)
                    || (Number.isFinite(finalMetrics?.page) && Number.isFinite(finalMetrics?.pages) && (finalMetrics.page < 0 || finalMetrics.page >= finalMetrics.pages))
                )
            ) {
                manabiPaginatorReaderLoadLog('paginator.pageTurn.anomaly', this.#layoutMetricDiagnostics(finalMetrics ?? beforeMetrics, {
                    direction: dir > 0 ? 'forward' : 'backward',
                    shouldGo,
                    didMove,
                    expectedCrossSection,
                    crossedSection: this.#index !== beforeIndex,
                    adjacentIndex: beforeAdjacentIndex ?? null,
                    requestedPage,
                    beforeIndex,
                    beforePage: beforeMetrics?.page ?? null,
                    beforePages: beforeMetrics?.pages ?? null,
                    inputSource: navigationSource,
                }))
            }
            if (
                !this.#isCacheWarmer
                && (
                    manabiPaginatorVerbosePageTurns()
                    || shouldGo
                )
            ) {
                manabiPaginatorReaderLoadLog('paginator.pageTurn.settled', {
                    ...this.#readerLoadPageTurnSummary(finalMetrics),
                    direction: dir,
                    shouldGo,
                    beforePage: beforeMetrics?.page ?? null,
                    beforePages: beforeMetrics?.pages ?? null,
                    beforeStart: beforeMetrics ? manabiRound(beforeMetrics.start, 1) : null,
                    elapsedMs: this.#lockedAt == null ? null : manabiRound(manabiPerfNow() - this.#lockedAt, 1),
                })
            }
            if (shouldGo || !this.hasAttribute('animated')) await wait(100)
            if (!shouldGo) this.#scheduleNeighborPrefetch('page-turn.within-section')
        } finally {
            const lockElapsedMs = this.#lockedAt == null ? null : manabiRound(manabiPerfNow() - this.#lockedAt, 1)
            const queuedPageTurn = this.#queuedPageTurn
            this.#queuedPageTurn = null
            this.#pendingPageTurnDirection = null
            this.#pendingPageTurnStep = null
            this.#pendingPageTurnQueueAllowed = false
            this.#pendingPageTurnRequestedPage = null
            this.#pendingPageTurnPageCount = null
            this.#locked = false
            this.#lockedAt = null
            if (!this.#isCacheWarmer && queuedPageTurn) {
                manabiPaginatorReaderLoadLog('paginator.pageTurn.dequeue', {
                    index: this.#index,
                    direction: queuedPageTurn.dir > 0 ? 'forward' : 'backward',
                    lockElapsedMs,
                    inputSource: navigationSource,
                })
            }
            if (queuedPageTurn) {
                queueMicrotask(() => {
                    this.#turnPage(queuedPageTurn.dir, queuedPageTurn.distance, { bypassPostTurnDuplicateSuppression: true })
                        .then(value => queuedPageTurn.resolve?.(value))
                        .catch(error => queuedPageTurn.reject?.(error))
                })
            }
        }
    }
    async prev(distance) {
        return await this.#turnPage(-1, distance)
    }
    async next(distance) {
        return await this.#turnPage(1, distance)
    }
    async prevSection() {
        return await this.goTo({
            index: this.#adjacentIndex(-1)
        })
    }
    async nextSection() {
        return await this.goTo({
            index: this.#adjacentIndex(1)
        })
    }
    async firstSection() {
        const index = this.sections.findIndex(section => section.linear !== 'no')
        return await this.goTo({
            index
        })
    }
    async lastSection() {
        const index = this.sections.findLastIndex(section => section.linear !== 'no')
        return await this.goTo({
            index
        })
    }
    getContents() {
        if (this.#view) return [{
            index: this.#index,
            overlayer: this.#view.overlayer,
            doc: this.#view.document,
        }]
        return []
    }
    setStyles(styles) {
        this.#styles = styles
        this.#applyStylesToDocument(this.#view?.document, styles)

        //        // NOTE: needs `requestAnimationFrame` in Chromium
        //        requestAnimationFrame(() =>
        //            this.#background.style.background = getBackground(this.#view.document))

        // needed because the resize observer doesn't work in Firefox
        //            this.#view?.document?.fonts?.ready?.then(async () => { await this.#view.expand() })
    }
    focusView() {
        this.#view?.document?.defaultView?.focus?.()
    }
    destroy() {
        this.#disconnectElementVisibilityObserver()
        this.#resizeObserver.unobserve(this)
        this.#setLoading(false, 'paginator.destroy')
        clearTimeout(this.#prefetchTimer)
        this.#prefetchTimer = null
        for (const [index, entry] of this.#prefetchCache) {
            this.#releaseNeighborPrefetch(index, entry)
        }
        this.#prefetchCache = new Map()
        this.#view?.destroy?.()
        this.#view = null
        this.sections[this.#index]?.unload?.()
    }
    // Public navigation edge detection methods
    async canTurnPrev() {
        if (!this.#view) return false;
        if (this.scrolled) {
            return (await this.pageMetrics()).start > 0;
        }
        // If at the start page and no previous section, cannot turn
        const metrics = await this.pageMetrics()
        if (metrics.page <= 1 && this.#adjacentIndex(-1) == null) return false;
        return true;
    }
    async canTurnNext() {
        if (!this.#view) return false;
        if (this.scrolled) {
            const metrics = await this.pageMetrics()
            return metrics.viewSize - metrics.end > 2;
        }
        // If at the end page and no next section, cannot turn
        const metrics = await this.pageMetrics()
        if (metrics.page >= metrics.pages - 2 && this.#adjacentIndex(1) == null) return false;
        return true;
    }

    // Public helpers for adjacent sections
    getHasPrevSection() {
        return this.#adjacentIndex(-1) != null;
    }
    getHasNextSection() {
        return this.#adjacentIndex(1) != null;
    }

    // Public: At first page of current section
    async isAtSectionStart() {
        return (await this.pageMetrics()).page <= 1;
    }
    // Public: At last page of current section
    async isAtSectionEnd() {
        const metrics = await this.pageMetrics()
        return metrics.page >= metrics.pages - 2;
    }
}

customElements.define('foliate-paginator', Paginator)
