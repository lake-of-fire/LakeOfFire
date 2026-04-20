// Global timers for side-nav chevron fades
import './view.js'
import {
createTOCView
} from './ui/tree.js'
import { NavigationHUD } from './ebook-viewer-nav.js'
import {
    Overlayer
} from '../foliate-js/overlayer.js'

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

// Factory for replaceText with isCacheWarmer support
const makeReplaceText = (isCacheWarmer) => async (href, text, mediaType) => {
    if (mediaType !== 'application/xhtml+xml' && mediaType !== 'text/html' /* && mediaType !== 'application/xml'*/ ) {
        return text;
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
        let html = await response.text()
        postReaderLog('ebook.replaceText.responseSummary', {
            href,
            isCacheWarmer: !!isCacheWarmer,
            containsSegmentTag: html.includes('<manabi-segment'),
            containsSentenceTag: html.includes('<manabi-sentence'),
            firstSegmentIndex: html.indexOf('<manabi-segment'),
            firstSentenceIndex: html.indexOf('<manabi-sentence'),
        });
        const sentenceCount = (html.match(/<manabi-sentence\b/g) || []).length;
        const segmentCount = (html.match(/<manabi-segment\b/g) || []).length;
        html = injectBodyDatasetAttributes(html, {
            'data-is-cache-warmer': isCacheWarmer ? 'true' : null,
            'data-manabi-source-href': href,
        });
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
        return html
    } catch (error) {
        logReplaceTextOnce('ebook.replaceText.error', {
            href,
            mediaType: mediaType || 'nil',
            isCacheWarmer: !!isCacheWarmer,
            reason: error?.message || String(error),
        });
        console.error("Error replacing text:", error)
        return text
    }
}

// https://learnersbucket.com/examples/interview/debouncing-with-leading-and-trailing-options/
const debounce = (fn, delay) => {
    let timeout;
    let isLeadingInvoked = false;
    
    return function(...args) {
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

const postReaderLog = (event, details = {}) => {
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
        console.debug('# READER', event, details, error);
    }
};

const postEPUBLog = (event, details = {}) => {
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
        console.debug('# EPUB', event, details, error);
    }
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

const buildGoToSnapshotChapters = (book) => {
    const chapters = [];
    const seenHrefs = new Set();
    const tocEntries = flattenTOCEntries(book?.toc ?? []);
    const tocTitleByHref = new Map();
    for (const entry of tocEntries) {
        const href = typeof entry?.href === 'string' ? entry.href : null;
        const title = typeof entry?.label === 'string' ? entry.label.trim() : '';
        if (!href || !title) {
            continue;
        }
        if (!tocTitleByHref.has(href)) {
            tocTitleByHref.set(href, title);
        }
        if (seenHrefs.has(href)) {
            continue;
        }
        seenHrefs.add(href);
        chapters.push({
            href,
            title,
            pageNumber: null,
        });
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
    if (sectionEntries.length > chapters.length) {
        return sectionEntries;
    }
    return chapters;
};

const injectBodyDatasetAttributes = (html, attributes) => {
    if (typeof html !== 'string' || !html.replace) {
        return html;
    }
    const serializedAttributes = Object.entries(attributes)
        .filter(([, value]) => value !== undefined && value !== null && value !== '')
        .map(([key, value]) => ` ${key}="${String(value).replace(/"/g, '&quot;')}"`)
        .join('');
    if (!serializedAttributes) {
        return html;
    }
    return html.replace(/<body\b/i, `<body${serializedAttributes}`);
};

const setNativeHideNavigationState = (shouldHide, source = 'native-bridge') => {
    const normalized = !!shouldHide;
    const body = document.body;
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
        bodyHasNavHiddenClass: body?.classList?.contains?.('nav-hidden') ?? null,
        hudHideNavigationDueToScroll: !!globalThis.reader?.navHUD?.hideNavigationDueToScroll,
        hudNavHidden: !!globalThis.reader?.navHUD?.navHidden,
    };
    const bridgeKey = JSON.stringify(bridgeState);
    if (globalThis.__manabiLastNavigationVisibilityBridgeKey !== bridgeKey) {
        globalThis.__manabiLastNavigationVisibilityBridgeKey = bridgeKey;
        postReaderLog('ebook.navigationVisibility.bridge', bridgeState);
    }
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

const applyStoredChromeInsets = (reason = 'unknown', rawInsets = globalThis.__manabiChromeInsets) => {
    if (!rawInsets) {
        return null;
    }
    const toolbarBottomOffset = normalizeChromeInsetCSSValue(rawInsets.toolbarBottomOffset);
    const obscuredBottomInset = normalizeChromeInsetCSSValue(rawInsets.obscuredBottomInset);
    const appliedInsets = {
        toolbarBottomOffset,
        obscuredBottomInset,
    };
    globalThis.__manabiChromeInsets = appliedInsets;
    for (const target of [document.documentElement, document.body].filter(Boolean)) {
        target.style.setProperty('--manabi-toolbar-bottom-offset', toolbarBottomOffset);
        target.style.setProperty('--manabi-obscured-bottom-inset', obscuredBottomInset);
    }
    const chromeInsetsLog = {
        reason,
        toolbarBottomOffset,
        obscuredBottomInset,
        bodyReady: !!document.body,
    };
    const chromeInsetsKey = JSON.stringify({
        toolbarBottomOffset,
        obscuredBottomInset,
        bodyReady: !!document.body,
    });
    if (globalThis.__manabiLastChromeInsetsLogKey !== chromeInsetsKey) {
        globalThis.__manabiLastChromeInsetsLogKey = chromeInsetsKey;
        postEPUBLog('ebook.chromeInsets.reapplied', chromeInsetsLog);
    }
    return appliedInsets;
};

window.manabiApplyChromeInsets = (rawInsets, reason = 'window.manabiApplyChromeInsets') => {
    return applyStoredChromeInsets(reason, rawInsets);
};

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

const summarizeFoliateViewLayout = (view) => {
    const summary = summarizeElementLayout(view);
    if (!summary) {
        return null;
    }
    const paginator = view.shadowRoot?.querySelector?.('foliate-paginator') || null;
    const paginatorTop = paginator?.shadowRoot?.getElementById?.('top') || null;
    const paginatorContainer = paginator?.shadowRoot?.getElementById?.('container') || null;
    return {
        ...summary,
        parentTag: view.parentElement?.tagName ?? null,
        parentID: view.parentElement?.id ?? null,
        datasetIsCache: view.dataset?.isCache ?? null,
        paginator: summarizeElementLayout(paginator),
        paginatorTop: summarizeElementLayout(paginatorTop),
        paginatorContainer: summarizeElementLayout(paginatorContainer),
    };
};

const postReaderVisibilityProbe = (stage, view = null, extra = null) => {
    if (extra?.isCacheWarmer || view?.dataset?.isCache === 'true') {
        return;
    }
    const readerStage = document.getElementById('reader-stage');
    const liveView = summarizeFoliateViewLayout(view);
    const paginatorContainerWidth = liveView?.paginatorContainer?.clientWidth ?? null;
    const paginatorContainerHeight = liveView?.paginatorContainer?.clientHeight ?? null;
    const shouldLog =
        !liveView
        || !liveView.paginator
        || (typeof liveView?.clientWidth === 'number' && liveView.clientWidth <= 0)
        || (typeof liveView?.clientHeight === 'number' && liveView.clientHeight <= 0)
        || (typeof paginatorContainerWidth === 'number' && paginatorContainerWidth <= 0)
        || (typeof paginatorContainerHeight === 'number' && paginatorContainerHeight <= 0);
    const shouldLogAtStage =
        stage === 'reader.documentLoad'
        || !!extra?.documentURL;
    if (!shouldLog || !shouldLogAtStage) {
        return;
    }
    postEPUBLog('ebook.visibilityProbe', {
        stage,
        readyState: document.readyState,
        childCount: readerStage?.children?.length ?? 0,
        viewMissing: !liveView,
        paginatorMissing: !liveView?.paginator,
        viewWidth: liveView?.clientWidth ?? null,
        viewHeight: liveView?.clientHeight ?? null,
        pagerWidth: paginatorContainerWidth,
        pagerHeight: paginatorContainerHeight,
        extra,
    });
};

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
    const sentenceIdentifier = sentenceNode?.dataset?.sentenceIdentifier || sentenceNode?.dataset?.textHash;
    return typeof sentenceIdentifier === 'string' && sentenceIdentifier.length > 0
        ? sentenceIdentifier
        : null;
};

const segmentIdentifierForNode = (segmentNode) => {
    const sentenceNode = segmentNode?.closest?.('manabi-sentence');
    const sentenceIdentifier = sentenceIdentifierForNode(sentenceNode);
    const segmentHash = segmentNode?.dataset?.segmentHash;
    if (typeof sentenceIdentifier !== 'string' || sentenceIdentifier.length === 0) {
        return null;
    }
    if (typeof segmentHash !== 'string' || segmentHash.length === 0) {
        return null;
    }
    return `${sentenceIdentifier}-${segmentHash}`;
};

const buildExampleSentenceForSegment = (segmentNode) => {
    const sentenceNode = segmentNode?.closest?.('manabi-sentence');
    if (!(sentenceNode instanceof Element)) {
        return {
            sentenceHTML: null,
            sentenceJMDictIDs: null,
        };
    }
    const sentenceJMDictIDs = new Set();
    for (const nestedSegment of sentenceNode.querySelectorAll('manabi-segment')) {
        for (const entryID of parseEntryIDs(nestedSegment.dataset?.jmdictEntryIds || '[]')) {
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

const collectVisibleSegmentNodes = (doc) => {
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
    const viewportWidth = doc.documentElement?.clientWidth || doc.defaultView?.innerWidth || 0;
    const viewportHeight = doc.documentElement?.clientHeight || doc.defaultView?.innerHeight || 0;
    const visibleSegments = [];
    let totalSegmentCount = 0;
    let hiddenTooltipCount = 0;
    let missingIdentifierCount = 0;
    let outOfViewportCount = 0;
    for (const segmentNode of doc.querySelectorAll('manabi-segment')) {
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
        const rect = segmentNode.getBoundingClientRect();
        if (!rectIntersectsViewport(rect, viewportWidth, viewportHeight)) {
            outOfViewportCount += 1;
            continue;
        }
        const sentenceNode = segmentNode.closest('manabi-sentence');
        visibleSegments.push({
            node: segmentNode,
            rect,
            segmentIdentifier,
            sentenceIdentifier: sentenceIdentifierForNode(sentenceNode),
        });
    }
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

const buildVisiblePageTrackingStates = (doc, articleReadingProgress) => {
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
    } = collectVisibleSegmentNodes(doc);
    const clusterAxis = !!doc?.body?.classList?.contains?.('reader-vertical-writing') ? 'block' : 'inline';
    let skippedMissingSearchStringCount = 0;
    const dedupedSegments = new Map();
    const visibleSegmentIdentifiers = new Set();
    const sentencesByIdentifier = new Map();
    for (const item of visibleSegments) {
        if (!dedupedSegments.has(item.segmentIdentifier)) {
            const searchString = item.node.dataset?.jmdictSearchString || item.node.dataset?.jmnedictSearchString;
            if (typeof searchString !== 'string' || searchString.length === 0) {
                skippedMissingSearchStringCount += 1;
                continue;
            }
            visibleSegmentIdentifiers.add(item.segmentIdentifier);
            const { sentenceHTML, sentenceJMDictIDs } = buildExampleSentenceForSegment(item.node);
            dedupedSegments.set(item.segmentIdentifier, {
                jmdictEntryIds: parseEntryIDs(item.node.dataset?.jmdictEntryIds || '[]'),
                jmnedictEntryIds: parseEntryIDs(item.node.dataset?.jmnedictEntryIds || '[]'),
                searchString,
                displayText: item.node.textContent?.trim?.() || searchString,
                segmentIdentifier: item.segmentIdentifier,
                exampleSentence: sentenceHTML,
                exampleSentenceJMDictIDs: sentenceJMDictIDs,
            });
        }
        if (item.sentenceIdentifier && !sentencesByIdentifier.has(item.sentenceIdentifier)) {
            const sentenceNode = item.node.closest('manabi-sentence');
            const allSegmentIdentifiers = Array.from(sentenceNode?.querySelectorAll?.('manabi-segment') || [])
                .map((segmentNode) => segmentIdentifierForNode(segmentNode))
                .filter((identifier) => typeof identifier === 'string' && identifier.length > 0);
            sentencesByIdentifier.set(item.sentenceIdentifier, allSegmentIdentifiers);
        }
    }
    const unreadVisibleSegmentCount = Array.from(visibleSegmentIdentifiers)
        .filter((segmentIdentifier) => !readSegmentIdentifiers.has(segmentIdentifier))
        .length;
    const sentenceIdentifiers = Array.from(sentencesByIdentifier.entries())
        .filter(([, allSegmentIdentifiers]) => allSegmentIdentifiers.length > 0
            && allSegmentIdentifiers.every((segmentIdentifier) =>
                readSegmentIdentifiers.has(segmentIdentifier)
                || visibleSegmentIdentifiers.has(segmentIdentifier)))
        .map(([sentenceIdentifier]) => sentenceIdentifier);
    const isRead = visibleSegmentIdentifiers.size > 0 && unreadVisibleSegmentCount === 0;
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
    const paginator = view.shadowRoot?.querySelector('foliate-paginator');
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
}) => `
    @namespace epub "http://www.idpf.org/2007/ops";
    html {
        color-scheme: light dark;
        cursor: inherit;
    }
    /* https://github.com/whatwg/html/issues/5426 */
    @media (prefers-color-scheme: dark) {
        a:link {
            color: lightblue;
        }
    }
    p, li, blockquote, dd {
        line-height: ${spacing};
        text-align: ${justify ? 'justify' : 'start'};
        -webkit-hyphens: ${hyphenate ? 'auto' : 'manual'};
        hyphens: ${hyphenate ? 'auto' : 'manual'};
        -webkit-hyphenate-limit-before: 3;
        -webkit-hyphenate-limit-after: 2;
        -webkit-hyphenate-limit-lines: 2;
        hanging-punctuation: allow-end last;
        widows: 2;
    }
    /* prevent the above from overriding the align attribute */
    [align="left"] { text-align: left; }
    [align="right"] { text-align: right; }
    [align="center"] { text-align: center; }
    [align="justify"] { text-align: justify; }

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

    manabi-segment {
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

    body *:not(.manabi-tracking-container *):not(manabi-segment *) {
        /* prevent height: 100% type values from breaking getBoundingClientRect layout in paginator */
        height: inherit !important;
    }
    body.reader-is-single-media-element-without-text *:not(.manabi-tracking-container *):not(manabi-segment *) {
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
         width: 0 !important;
         height: 0 !important;
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
        const nextVisible = !!visible;
        const previousVisible = body.classList.contains('loading');
        body.classList.toggle('loading', nextVisible);
        if (previousVisible !== nextVisible) {
            postEPUBLog('ebook.loadingIndicator.state', {
                visible: nextVisible,
                previous: previousVisible,
                bodyClassName: body.className || '',
                navHiddenClass: body.classList.contains('nav-hidden'),
                navHiddenScrollClass: document.getElementById('nav-bar')?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null,
                currentPageURL: window.location.href,
                hasRenderer: !!this.view?.renderer,
                hasLoadedLastPosition: !!this.hasLoadedLastPosition,
                articleMarkedAsFinished: !!this.markedAsFinished,
            });
        }
    }
    #tocView
    #chevronFadeTimers = {
        l: null,
        r: null
    }
    hasLoadedLastPosition = false
    markedAsFinished = false;
    lastPercentValue = null;
    articleReadingProgress = normalizeArticleReadingProgress();
    pageTrackingStates = [];
    pageTrackingBusyStateIDs = new Set();
    lastPageTrackingDiagnosticsKey = null;
    lastBookReadingProgressKey = null;
    pageTrackingRetryHandle = null;
    layoutDiagnosticsHandle = null;
    lastLayoutDiagnosticsKey = null;
    lastLayoutSnapshot = null;
    style = {
        spacing: 1.4,
        justify: true,
        hyphenate: true,
    }
    annotations = new Map()
    annotationsByValue = new Map()
    openSideBar() {
        $('#dimming-overlay').classList.add('show')
        $('#side-bar').classList.add('show')
        if (this.#tocView?.setCurrentHref && this.view?.renderer?.tocItem?.href) {
            this.#tocView.setCurrentHref(this.view.renderer.tocItem.href)
        }
    }
    closeSideBar() {
        $('#dimming-overlay').classList.remove('show')
        $('#side-bar').classList.remove('show')
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
        if (typeof descriptor.cfi === 'string' && descriptor.cfi) {
            await this.view.goTo(descriptor.cfi).catch((error) => console.error(error));
            return;
        }
        if (typeof descriptor.fraction === 'number' && Number.isFinite(descriptor.fraction)) {
            await this.view.goToFraction(descriptor.fraction);
        }
    }
    async goToHref(href, source = 'unknown') {
        if (!this.view || typeof href !== 'string' || !href) {
            return false;
        }
        postEPUBLog('ebook.goTo.href.request', {
            source,
            href,
        });
        await this.view.goTo(href);
        return true;
    }
    async goToPercent(percent, source = 'unknown') {
        if (!this.view) {
            return false;
        }
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
        await this.view.goToFraction(fraction);
        return true;
    }
    async goToPageNumber(pageNumber, source = 'unknown') {
        if (!this.view) {
            return false;
        }
        const numericPageNumber = Number(pageNumber);
        const totalPages = this.navHUD?.lastPageMetricsSnapshot?.totalPages
            ?? this.navHUD?.totalPageCount
            ?? this.navHUD?.fallbackTotalPageCount
            ?? null;
        if (!Number.isFinite(numericPageNumber)) {
            return false;
        }
        const maxPageNumber = typeof totalPages === 'number' && totalPages > 0
            ? totalPages
            : Math.max(1, Math.round(numericPageNumber));
        const clampedPageNumber = Math.max(1, Math.min(maxPageNumber, Math.round(numericPageNumber)));
        const pageTarget = this.navHUD?.pageTargets?.[clampedPageNumber - 1] ?? null;
        postEPUBLog('ebook.goTo.page.request', {
            source,
            pageNumber: clampedPageNumber,
            totalPages,
            hasPageTarget: !!pageTarget,
            targetHref: typeof pageTarget?.href === 'string' ? pageTarget.href : null,
        });
        if (typeof pageTarget?.href === 'string' && pageTarget.href) {
            await this.view.goTo(pageTarget.href);
            return true;
        }
        if (typeof totalPages === 'number' && totalPages > 1) {
            const fraction = (clampedPageNumber - 1) / (totalPages - 1);
            await this.view.goToFraction(fraction);
            return true;
        }
        if (clampedPageNumber <= 1) {
            await this.view.goToFraction(0);
            return true;
        }
        return false;
    }
    async buildGoToSheetSnapshot() {
        const chapters = buildGoToSnapshotChapters(this.view?.book);
        for (const entry of chapters) {
            const href = entry.href;
            let pageNumber = null;
            try {
                const progress = await this.view?.getNavigationProgressOf?.(href);
                const metrics = progress ? this.navHUD?._computePageMetrics?.(progress) : null;
                if (typeof metrics?.currentPageNumber === 'number' && metrics.currentPageNumber > 0) {
                    pageNumber = metrics.currentPageNumber;
                }
            } catch (error) {
                postEPUBLog('ebook.goTo.snapshot.chapter.error', {
                    href,
                    title: entry.title,
                    message: error?.message || String(error),
                });
            }
            entry.pageNumber = pageNumber;
        }
        const currentChapter = this.view?.renderer?.tocItem ?? this.view?.lastLocation?.tocItem ?? null;
        const snapshot = {
            isRTL: !!this.isRTL,
            currentChapterHref: typeof currentChapter?.href === 'string' ? currentChapter.href : null,
            currentChapterTitle: typeof currentChapter?.label === 'string' ? currentChapter.label : null,
            currentPageNumber: this.navHUD?.lastPageMetricsSnapshot?.currentPageNumber ?? null,
            totalPages: this.navHUD?.lastPageMetricsSnapshot?.totalPages ?? null,
            chapters,
        };
        postEPUBLog('ebook.goTo.snapshot', {
            isRTL: snapshot.isRTL,
            chapterCount: chapters.length,
            currentChapterHref: snapshot.currentChapterHref,
            currentPageNumber: snapshot.currentPageNumber,
            totalPages: snapshot.totalPages,
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
            this.goToPageNumber(pageNumber, 'schedule-page-number')
                .catch((error) => console.error(error));
        }, 120);
        this.scheduleGoToFraction = debounce((fraction) => {
            const clampedFraction = Math.max(0, Math.min(1, Number(fraction)));
            if (!Number.isFinite(clampedFraction) || !this.view) {
                return;
            }
            this.view.goToFraction(clampedFraction).catch((error) => console.error(error));
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
        document.getElementById('page-tracking-buttons')?.addEventListener('click', (event) => {
            const button = event.target?.closest?.('button[data-page-tracking-id]');
            const stateID = button?.dataset?.pageTrackingId;
            if (!stateID) {
                return;
            }
            this.#markPageClusterAsRead(stateID).catch((error) => console.error(error));
        });
        window.addEventListener('resize', () => this.#queueLayoutDiagnostics('window-resize'));
        window.visualViewport?.addEventListener?.('resize', () => this.#queueLayoutDiagnostics('visual-viewport-resize'));
    }
    #logPageTracking(event, details = {}) {
        postReaderLog(event, details);
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
            this.#syncPageTrackingButtons(reason, explicitDoc, retryCount - 1);
        });
    }
    queueLayoutDiagnostics(reason = 'unknown', extra = null) {
        this.#queueLayoutDiagnostics(reason, extra);
    }
    #queueLayoutDiagnostics(reason = 'unknown', extra = null) {
        if (this.layoutDiagnosticsHandle) {
            cancelAnimationFrame(this.layoutDiagnosticsHandle);
        }
        this.layoutDiagnosticsHandle = requestAnimationFrame(() => {
            this.layoutDiagnosticsHandle = null;
            this.#logLayoutDiagnostics(reason, extra);
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
    #logLayoutTransition(reason, previousSnapshot, nextSnapshot) {
        if (!previousSnapshot || !nextSnapshot) {
            return;
        }
        const navToggle =
            previousSnapshot.hideNavigationDueToScroll !== nextSnapshot.hideNavigationDueToScroll
            || previousSnapshot.bodyNavHidden !== nextSnapshot.bodyNavHidden;
        const pageMetricsChanged =
            previousSnapshot.currentPageNumber !== nextSnapshot.currentPageNumber
            || previousSnapshot.totalPages !== nextSnapshot.totalPages;
        const paginatorChanged =
            previousSnapshot.livePaginatorBox !== nextSnapshot.livePaginatorBox
            || previousSnapshot.livePaginatorScrollBox !== nextSnapshot.livePaginatorScrollBox
            || previousSnapshot.scrollingWidth !== nextSnapshot.scrollingWidth;
        const insetsChanged =
            previousSnapshot.cssInsets !== nextSnapshot.cssInsets
            || previousSnapshot.navBarBottom !== nextSnapshot.navBarBottom;
        if (!navToggle && !pageMetricsChanged && !paginatorChanged && !insetsChanged) {
            return;
        }
        const transition = {
            reason,
            navToggle,
            pageMetricsChanged,
            paginatorChanged,
            insetsChanged,
            repaginationOnNavToggle: navToggle && previousSnapshot.totalPages !== nextSnapshot.totalPages,
            overflowWhilePaginated: !!nextSnapshot.horizontalOverflowScrolling,
            hideNavigationDueToScroll: this.#formatTransition(
                previousSnapshot.hideNavigationDueToScroll,
                nextSnapshot.hideNavigationDueToScroll,
            ),
            bodyNavHidden: this.#formatTransition(
                previousSnapshot.bodyNavHidden,
                nextSnapshot.bodyNavHidden,
            ),
            totalPages: this.#formatTransition(previousSnapshot.totalPages, nextSnapshot.totalPages),
            currentPageNumber: this.#formatTransition(
                previousSnapshot.currentPageNumber,
                nextSnapshot.currentPageNumber,
            ),
            scrollingWidth: this.#formatTransition(
                previousSnapshot.scrollingWidth,
                nextSnapshot.scrollingWidth,
            ),
            paginatorBox: this.#formatTransition(
                previousSnapshot.livePaginatorBox,
                nextSnapshot.livePaginatorBox,
            ),
            paginatorScrollBox: this.#formatTransition(
                previousSnapshot.livePaginatorScrollBox,
                nextSnapshot.livePaginatorScrollBox,
            ),
            cssInsets: this.#formatTransition(previousSnapshot.cssInsets, nextSnapshot.cssInsets),
            navBarBottom: this.#formatTransition(previousSnapshot.navBarBottom, nextSnapshot.navBarBottom),
            paginatorViewportBottomClip: nextSnapshot.paginatorViewportBottomClip,
            sectionProgressOffscreen: nextSnapshot.sectionProgressOffscreen,
            hiddenOverlayMismatch: nextSnapshot.hiddenOverlayExpected && !nextSnapshot.hiddenOverlayVisible,
        };
        Object.keys(transition).forEach((key) => {
            if (transition[key] === null || transition[key] === false) {
                delete transition[key];
            }
        });
        postReaderLog('ebook.layout.transition', transition);
    }
    #logLayoutDiagnostics(reason = 'unknown', extra = null) {
        const body = document.body;
        const docEl = document.documentElement;
        const bodyStyle = body ? window.getComputedStyle(body) : null;
        const docElStyle = docEl ? window.getComputedStyle(docEl) : null;
        const scrollingElement = document.scrollingElement || docEl;
        const navBar = document.getElementById('nav-bar');
        const pageTrackingContainer = document.getElementById('page-tracking-container');
        const pageTrackingButtons = document.getElementById('page-tracking-buttons');
        const firstPageReadButton = pageTrackingButtons?.querySelector?.('.page-read-button') || null;
        const pageTrackingContainerRect = pageTrackingContainer?.getBoundingClientRect?.() || null;
        const pageTrackingButtonsRect = pageTrackingButtons?.getBoundingClientRect?.() || null;
        const firstPageReadButtonRect = firstPageReadButton?.getBoundingClientRect?.() || null;
        const firstPageReadButtonStyle = firstPageReadButton ? window.getComputedStyle(firstPageReadButton) : null;
        const pageTrackingContainerStyle = pageTrackingContainer ? window.getComputedStyle(pageTrackingContainer) : null;
        const pageTrackingButtonsStyle = pageTrackingButtons ? window.getComputedStyle(pageTrackingButtons) : null;
        const readerStage = document.getElementById('reader-stage');
        const allFoliateViews = Array.from(document.querySelectorAll('foliate-view'));
        const liveFoliateView = allFoliateViews.find((view) => view?.dataset?.isCache !== 'true') || null;
        const cacheFoliateView = allFoliateViews.find((view) => view?.dataset?.isCache === 'true') || null;
        const livePaginator = liveFoliateView?.shadowRoot?.querySelector?.('foliate-paginator') || null;
        const livePaginatorContainer = livePaginator?.shadowRoot?.getElementById?.('container') || null;
        const navBarRect = navBar?.getBoundingClientRect?.() || null;
        const livePaginatorRect = livePaginatorContainer?.getBoundingClientRect?.() || null;
        const locationLabel = document.getElementById('nav-primary-text');
        const hiddenOverlayLocationLabel = document.getElementById('nav-hidden-primary-text');
        const hiddenOverlayPercentLabel = document.getElementById('nav-hidden-primary-percent');
        const sectionProgressCenter = document.getElementById('nav-section-progress-center');
        const currentPageMetrics = this.navHUD?.lastPageMetricsSnapshot ?? null;
        const bodyNavHidden = !!body?.classList?.contains?.('nav-hidden');
        const hudNavHidden = !!this.navHUD?.navHidden;
        const hiddenOverlayLocationRect = hiddenOverlayLocationLabel?.getBoundingClientRect?.() || null;
        const hiddenOverlayPercentRect = hiddenOverlayPercentLabel?.getBoundingClientRect?.() || null;
        const hiddenOverlayLocationStyle = hiddenOverlayLocationLabel ? window.getComputedStyle(hiddenOverlayLocationLabel) : null;
        const hiddenOverlayPercentStyle = hiddenOverlayPercentLabel ? window.getComputedStyle(hiddenOverlayPercentLabel) : null;
        const hiddenOverlayLocationVisible = !!(
            hiddenOverlayLocationLabel
            && !hiddenOverlayLocationLabel.hidden
            && hiddenOverlayLocationLabel.offsetWidth > 0
            && window.getComputedStyle(hiddenOverlayLocationLabel).opacity !== '0'
        );
        const hiddenOverlayPercentVisible = !!(
            hiddenOverlayPercentLabel
            && !hiddenOverlayPercentLabel.hidden
            && hiddenOverlayPercentLabel.offsetWidth > 0
            && window.getComputedStyle(hiddenOverlayPercentLabel).opacity !== '0'
        );
        const locationLabelCollapsed = !!(
            locationLabel
            && !locationLabel.hidden
            && (locationLabel.textContent || '').trim().length > 0
            && locationLabel.offsetWidth <= 0
        );
        const sectionProgressCenterViewportBottomGap = (() => {
            if (!sectionProgressCenter) return null;
            const rect = sectionProgressCenter.getBoundingClientRect();
            return safeRound(window.innerHeight - rect.bottom);
        })();
        const sectionProgressOffscreen = typeof sectionProgressCenterViewportBottomGap === 'number'
            && sectionProgressCenterViewportBottomGap >= (window.innerHeight - 1);
        const hiddenOverlayVisible = hiddenOverlayLocationVisible || hiddenOverlayPercentVisible;
        const layoutSnapshot = {
            reason,
            extra,
            hideNavigationDueToScroll: !!this.navHUD?.hideNavigationDueToScroll,
            bodyNavHidden,
            hudNavHidden,
            navVisibilityMismatch: bodyNavHidden !== hudNavHidden,
            currentPageNumber: typeof currentPageMetrics?.currentPageNumber === 'number' ? currentPageMetrics.currentPageNumber : null,
            totalPages: typeof currentPageMetrics?.totalPages === 'number' ? currentPageMetrics.totalPages : null,
            viewport: this.#formatBox(safeRound(window.innerWidth), safeRound(window.innerHeight)),
            scrollingWidth: this.#formatScrollBox(
                scrollingElement?.clientWidth ?? null,
                scrollingElement?.scrollWidth ?? null,
            ),
            horizontalOverflowScrolling: (scrollingElement?.scrollWidth ?? 0) > (scrollingElement?.clientWidth ?? 0) + 1,
            cssInsets: [
                `toolbar=${(bodyStyle || docElStyle)?.getPropertyValue('--manabi-toolbar-bottom-offset')?.trim() || 'nil'}`,
                `obscured=${(bodyStyle || docElStyle)?.getPropertyValue('--manabi-obscured-bottom-inset')?.trim() || 'nil'}`,
                `stage=${(bodyStyle || docElStyle)?.getPropertyValue('--manabi-reader-stage-bottom-inset')?.trim() || 'nil'}`,
            ].join(' '),
            navBarBottom: navBar ? window.getComputedStyle(navBar).bottom : null,
            readerStageViewportBottomGap: readerStage ? safeRound(window.innerHeight - readerStage.getBoundingClientRect().bottom) : null,
            paginatorBottomGapToToolbar: navBarRect && livePaginatorRect
                ? safeRound(navBarRect.top - livePaginatorRect.bottom)
                : null,
            paginatorBottomOverlapWithToolbar: navBarRect && livePaginatorRect
                ? Math.max(0, safeRound(livePaginatorRect.bottom - navBarRect.top))
                : null,
            livePaginatorBox: this.#formatBox(
                livePaginatorContainer?.clientWidth ?? null,
                livePaginatorContainer?.clientHeight ?? null,
            ),
            livePaginatorScrollBox: this.#formatScrollBox(
                livePaginatorContainer?.clientWidth ?? null,
                livePaginatorContainer?.scrollWidth ?? null,
            ),
            livePaginatorScrollHeightBox: this.#formatScrollBox(
                livePaginatorContainer?.clientHeight ?? null,
                livePaginatorContainer?.scrollHeight ?? null,
            ),
            paginatorViewportBottomGap: livePaginatorRect
                ? safeRound(window.innerHeight - livePaginatorRect.bottom)
                : null,
            paginatorViewportBottomClip: livePaginatorRect
                ? Math.max(0, safeRound(livePaginatorRect.bottom - window.innerHeight))
                : null,
            locationLabelCollapsed,
            hiddenOverlayExpected: locationLabelCollapsed || !!this.navHUD?.hideNavigationDueToScroll,
            hiddenOverlayVisible,
            hiddenOverlayLocationVisible,
            hiddenOverlayPercentVisible,
            hiddenOverlayLocationHidden: hiddenOverlayLocationLabel?.hidden ?? null,
            hiddenOverlayPercentHidden: hiddenOverlayPercentLabel?.hidden ?? null,
            hiddenOverlayLocationDisplay: hiddenOverlayLocationStyle?.display ?? null,
            hiddenOverlayLocationVisibility: hiddenOverlayLocationStyle?.visibility ?? null,
            hiddenOverlayLocationOpacity: hiddenOverlayLocationStyle?.opacity ?? null,
            hiddenOverlayPercentDisplay: hiddenOverlayPercentStyle?.display ?? null,
            hiddenOverlayPercentVisibility: hiddenOverlayPercentStyle?.visibility ?? null,
            hiddenOverlayPercentOpacity: hiddenOverlayPercentStyle?.opacity ?? null,
            hiddenOverlayOwnedByMainDocument: !!(
                hiddenOverlayLocationLabel
                && hiddenOverlayLocationLabel.ownerDocument === document
            ),
            hiddenOverlayContainedByReaderStage: !!(
                hiddenOverlayLocationLabel
                && readerStage
                && readerStage.contains(hiddenOverlayLocationLabel)
            ),
            hiddenOverlayLocationText: (hiddenOverlayLocationLabel?.textContent || '').trim(),
            hiddenOverlayPercentText: (hiddenOverlayPercentLabel?.textContent || '').trim(),
            hiddenOverlayLocationWidth: hiddenOverlayLocationLabel?.offsetWidth ?? null,
            hiddenOverlayPercentWidth: hiddenOverlayPercentLabel?.offsetWidth ?? null,
            hiddenOverlayLocationBottomGap: hiddenOverlayLocationRect
                ? safeRound(window.innerHeight - hiddenOverlayLocationRect.bottom)
                : null,
            hiddenOverlayPercentBottomGap: hiddenOverlayPercentRect
                ? safeRound(window.innerHeight - hiddenOverlayPercentRect.bottom)
                : null,
            locationLabelText: (locationLabel?.textContent || '').trim(),
            locationLabelWidth: locationLabel?.offsetWidth ?? null,
            sectionProgressCenterViewportBottomGap,
            sectionProgressCenterBottomClip: (() => {
                const element = sectionProgressCenter;
                if (!element) return null;
                const rect = element.getBoundingClientRect();
                const navRect = navBar?.getBoundingClientRect?.();
                if (!navRect) return null;
                return safeRound(rect.bottom - navRect.bottom);
            })(),
            sectionProgressOffscreen,
            pageTrackingVisible: !!(
                pageTrackingContainer
                && !pageTrackingContainer.hidden
                && pageTrackingContainer.offsetWidth > 0
                && pageTrackingButtons
                && !pageTrackingButtons.hidden
            ),
            pageTrackingButtonCount: pageTrackingButtons?.childElementCount ?? 0,
            pageTrackingContainerHidden: pageTrackingContainer?.hidden ?? null,
            pageTrackingButtonsHidden: pageTrackingButtons?.hidden ?? null,
            pageTrackingContainerDisplay: pageTrackingContainerStyle?.display ?? null,
            pageTrackingContainerVisibility: pageTrackingContainerStyle?.visibility ?? null,
            pageTrackingButtonsDisplay: pageTrackingButtonsStyle?.display ?? null,
            pageTrackingButtonsVisibility: pageTrackingButtonsStyle?.visibility ?? null,
            pageTrackingOwnedByMainDocument: !!(
                pageTrackingContainer
                && pageTrackingContainer.ownerDocument === document
            ),
            pageTrackingContainedByReaderStage: !!(
                pageTrackingContainer
                && readerStage
                && readerStage.contains(pageTrackingContainer)
            ),
            pageTrackingContainedByFoliateView: !!(
                pageTrackingContainer
                && liveFoliateView
                && liveFoliateView.contains(pageTrackingContainer)
            ),
            firstPageReadButtonVisible: !!(
                firstPageReadButton
                && !firstPageReadButton.hidden
                && firstPageReadButton.offsetWidth > 0
            ),
            firstPageReadButtonHidden: firstPageReadButton?.hidden ?? null,
            firstPageReadButtonOwnerDocumentIsMain: !!(
                firstPageReadButton
                && firstPageReadButton.ownerDocument === document
            ),
            pageTrackingContainerRect: pageTrackingContainerRect ? {
                x: safeRound(pageTrackingContainerRect.x),
                y: safeRound(pageTrackingContainerRect.y),
                width: safeRound(pageTrackingContainerRect.width),
                height: safeRound(pageTrackingContainerRect.height),
            } : null,
            pageTrackingButtonsRect: pageTrackingButtonsRect ? {
                x: safeRound(pageTrackingButtonsRect.x),
                y: safeRound(pageTrackingButtonsRect.y),
                width: safeRound(pageTrackingButtonsRect.width),
                height: safeRound(pageTrackingButtonsRect.height),
            } : null,
            firstPageReadButtonRect: firstPageReadButtonRect ? {
                x: safeRound(firstPageReadButtonRect.x),
                y: safeRound(firstPageReadButtonRect.y),
                width: safeRound(firstPageReadButtonRect.width),
                height: safeRound(firstPageReadButtonRect.height),
            } : null,
            firstPageReadButtonLabel: (firstPageReadButton?.textContent || '').trim(),
            firstPageReadButtonDisplay: firstPageReadButtonStyle?.display ?? null,
            firstPageReadButtonVisibility: firstPageReadButtonStyle?.visibility ?? null,
            firstPageReadButtonOpacity: firstPageReadButtonStyle?.opacity ?? null,
            firstPageReadButtonViewportVisible: !!(
                firstPageReadButtonRect
                && firstPageReadButtonRect.width > 1
                && firstPageReadButtonRect.height > 1
                && firstPageReadButtonRect.right > 0
                && firstPageReadButtonRect.bottom > 0
                && firstPageReadButtonRect.left < window.innerWidth
                && firstPageReadButtonRect.top < window.innerHeight
            ),
            bodyLoading: !!body?.classList?.contains?.('loading'),
        };
        const hasIssue =
            layoutSnapshot.horizontalOverflowScrolling
            || (layoutSnapshot.paginatorViewportBottomClip ?? 0) > 0
            || (layoutSnapshot.paginatorBottomOverlapWithToolbar ?? 0) > 0
            || layoutSnapshot.navVisibilityMismatch
            || layoutSnapshot.sectionProgressOffscreen
            || (layoutSnapshot.hiddenOverlayExpected && !layoutSnapshot.hiddenOverlayVisible);
        const shouldLogSnapshot =
            hasIssue
            || reason === 'reader-open'
            || reason === 'document-load'
            || reason === 'native-hide-bridge'
            || reason === 'relocate';
        const key = JSON.stringify(layoutSnapshot);
        if (key === this.lastLayoutDiagnosticsKey) {
            return;
        }
        this.#logLayoutTransition(reason, this.lastLayoutSnapshot, layoutSnapshot);
        this.lastLayoutSnapshot = layoutSnapshot;
        this.lastLayoutDiagnosticsKey = key;
        if (shouldLogSnapshot) {
            postReaderLog('ebook.layout.snapshot', layoutSnapshot);
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
        container.hidden = !hasStates;
        buttonHost.hidden = !hasStates;
        if (!hasStates) {
            buttonHost.innerHTML = '';
            this.navHUD?.refreshAuxiliaryLayout?.();
            return;
        }
        buttonHost.innerHTML = pageTrackingStates.map((state) => {
            const isBusy = this.pageTrackingBusyStateIDs.has(state.id);
            const readState = isBusy ? 'pending' : (state.isRead ? 'complete' : 'ready');
            return `
                <button
                    class="page-read-button"
                    data-page-tracking-id="${state.id}"
                    data-read-state="${readState}"
                    aria-label="${state.fullLabel}"
                    ${state.isRead || isBusy ? 'disabled' : ''}
                >
                    <span class="page-read-button-icon" aria-hidden="true">
                        <svg viewBox="0 0 24 24" focusable="false" aria-hidden="true">
                            <path d="M9.2 16.4 5.8 13l-1.4 1.4 4.8 4.8L19.6 8.8l-1.4-1.4z"></path>
                        </svg>
                    </span>
                    <span class="sr-only">${state.fullLabel}</span>
                </button>
            `;
        }).join('');
        this.#logPageTracking('ebook.pageTracking.surfaceOwnership', {
            reason,
            stateCount: pageTrackingStates.length,
            containerOwnedByMainDocument: container.ownerDocument === document,
            containerContainedByReaderStage: !!document.getElementById('reader-stage')?.contains(container),
            containerContainedByFoliateView: !!this.view?.contains?.(container),
            buttonHostOwnedByMainDocument: buttonHost.ownerDocument === document,
            firstButtonOwnedByMainDocument: buttonHost.querySelector('.page-read-button')?.ownerDocument === document,
        });
        this.navHUD?.refreshAuxiliaryLayout?.();
        this.#queueLayoutDiagnostics('page-tracking-render', {
            stateCount: pageTrackingStates.length,
        });
    }
    async #advanceAfterMarkRead() {
        if (!this.view?.renderer) {
            return;
        }
        await new Promise((resolve) => setTimeout(resolve, 180));
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
        if (this.isRTL) {
            await this.view.goLeft();
        } else {
            await this.view.goRight();
        }
    }
    #syncPageTrackingButtons(reason = 'unspecified', explicitDoc = null, retryCount = 0) {
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
        const {
            states,
            diagnostics,
        } = buildVisiblePageTrackingStates(doc, this.articleReadingProgress);
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
        this.#renderPageTrackingButtons(reason);
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
            skippedMissingSearchStringCount: diagnostics.skippedMissingSearchStringCount,
            clusterCount: diagnostics.clusterCount,
            stateCount: diagnostics.stateCount,
            completedStateCount: diagnostics.completedStateCount,
            readSegmentCount: diagnostics.readSegmentCount,
            readSentenceCount: diagnostics.readSentenceCount,
        });
    }
    applyBookReadingProgress(articleReadingProgress) {
        this.articleReadingProgress = normalizeArticleReadingProgress(articleReadingProgress);
        this.markedAsFinished = !!this.articleReadingProgress.articleMarkedAsFinished;
        this.pageTrackingBusyStateIDs.clear();
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
        this.#syncPageTrackingButtons('progress-applied', null, 2);
        this.#queueLayoutDiagnostics('progress-applied', {
            articleSentenceCount: this.articleReadingProgress.articleSentenceCount,
            readSegmentIdentifiers: this.articleReadingProgress.readSegmentIdentifiers.length,
        });
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
        const optimisticProgress = normalizeArticleReadingProgress(this.articleReadingProgress);
        optimisticProgress.readSegmentIdentifiers = Array.from(new Set([
            ...optimisticProgress.readSegmentIdentifiers,
            ...pageTrackingState.payload.segments.map((segment) => segment.segmentIdentifier),
        ]));
        optimisticProgress.sentenceIdentifiersRead = Array.from(new Set([
            ...optimisticProgress.sentenceIdentifiersRead,
            ...pageTrackingState.payload.sentenceIdentifiers,
        ]));
        this.applyBookReadingProgress(optimisticProgress);
        this.#logPageTracking('ebook.pageTracking.markRead.optimisticApplied', {
            stateID,
            readSegmentIdentifiers: optimisticProgress.readSegmentIdentifiers.length,
            sentenceIdentifiersRead: optimisticProgress.sentenceIdentifiersRead.length,
        });
        await this.#advanceAfterMarkRead();
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
        this.view = await getView(file, false)
        postReaderVisibilityProbe('reader.open:view-assigned', this.view, null);
        // this.view.renderer.setAttribute('animated', true) // Flows top to bottom instead of like a book...
        if (typeof window.initialLayoutMode !== 'undefined') {
            this.view.renderer.setAttribute('flow', window.initialLayoutMode)
        }
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
        applyStoredChromeInsets('reader.open');
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
            finish: document.getElementById('btn-finish'),
            restart: document.getElementById('btn-restart'),
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
        if (leftSideBtn) leftSideBtn.addEventListener('click', async () => await this.view.goLeft());
        const rightSideBtn = document.getElementById('btn-scroll-right');
        if (rightSideBtn) rightSideBtn.addEventListener('click', async () => await this.view.goRight());
        
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
                this.view.goToFraction(value / 100);
            }
        });
        
        document.addEventListener('keydown', this.#handleKeydown.bind(this))
        
        const processTouchStart = function(event) {
            // Ignore touches inside foliate-js viewer iframe
            if (event.target && event.target.ownerDocument !== document) return
                
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
                await this.view.goTo(href).catch(e => console.error(e))
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
        // Remove any nav-spinner left over from finish/restart click
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
        
        this.#show(this.buttons.prev, atSectionStart && hasPrevSection);
        
        if (atSectionEnd && hasNextSection) {
            this.#show(this.buttons.next, true);
            this.#show(this.buttons.finish, false);
            this.#show(this.buttons.restart, false);
        } else if (atSectionEnd && !hasNextSection) {
            this.#show(this.buttons.next, false);
            if (this.markedAsFinished) {
                this.#show(this.buttons.restart, true);
                this.#show(this.buttons.finish, false);
            } else {
                this.#show(this.buttons.finish, true);
                this.#show(this.buttons.restart, false);
            }
        } else {
            this.#show(this.buttons.next, false);
            this.#show(this.buttons.finish, false);
            this.#show(this.buttons.restart, false);
        }
        const showingCompletion = !!(this.buttons.finish && !this.buttons.finish.hidden)
            || !!(this.buttons.restart && !this.buttons.restart.hidden);
        this.navHUD?._toggleCompletionStack?.(showingCompletion);
        
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
        
        // Consolidate restart icon SVG path update
        const restartBtn = this.buttons.restart;
        if (restartBtn) {
            const iconPath = restartBtn.querySelector('svg path');
            if (iconPath) {
                iconPath.setAttribute('d', 'M13 3a9 9 0 1 0 9 9h-2a7 7 0 1 1-7-7v3l4-4-4-4v3z');
                iconPath.setAttribute('fill', 'currentColor');
                iconPath.setAttribute('stroke', 'none');
            }
        }
        this.navHUD?.setNavContext({
            atSectionStart,
            atSectionEnd,
            hasPrevSection,
            hasNextSection,
            showingFinish: !!(this.buttons.finish && !this.buttons.finish.hidden),
            showingRestart: !!(this.buttons.restart && !this.buttons.restart.hidden),
            sections: this.view?.book?.sections ?? [],
        });
        this.#syncPageTrackingButtons('nav-buttons', null, 1);
        this.#queueLayoutDiagnostics('nav-buttons', {
            showingFinish: !!(this.buttons.finish && !this.buttons.finish.hidden),
            showingRestart: !!(this.buttons.restart && !this.buttons.restart.hidden),
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
                await this.view.goLeft();
            }
        } else if (k === 'ArrowRight' || k === 'l') {
            if (isRTL && await renderer.atStart()) {
                this.buttons.prev.click();
            } else if (!isRTL && await renderer.atEnd()) {
                this.buttons.next.click();
            } else {
                await this.view.goRight();
            }
        }
    }
    #onGoTo({
        willLoadNewIndex
    }) {
        this.setLoadingIndicator(true);
    }
    #onDidDisplay({}) {
        this.setLoadingIndicator(false);
        applyStoredChromeInsets('reader.didDisplay');
        postReaderVisibilityProbe('reader.didDisplay', this.view, null);
    }
    #onLoad({
        detail: {
            doc
        }
    }) {
        applyStoredChromeInsets('reader.documentLoad');
        doc.addEventListener('keydown', this.#handleKeydown.bind(this))
        window.webkit.messageHandlers.updateCurrentContentPage.postMessage({
            topWindowURL: window.top.location.href,
            currentPageURL: doc.location.href,
        })
        requestAnimationFrame(() => this.#syncPageTrackingButtons('document-load', doc, 2));
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
    }) => {
        let mainDocumentURL = (window.location != window.parent.location) ? document.referrer : document.location.href
        window.webkit.messageHandlers.updateReadingProgress.postMessage({
            fractionalCompletion: fraction,
            cfi: cfi,
            reason: reason,
            mainDocumentURL: mainDocumentURL,
            currentPageNumber: currentPageNumber,
            totalPages: totalPages,
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
        const scrubFraction = this.navHUD?.getScrubberFraction(detail) ?? null;
        const effectiveFraction = Number.isFinite(scrubFraction) ? scrubFraction : fraction;
        const pageMetrics = this.navHUD?.lastPageMetricsSnapshot ?? null;
        const currentPageNumber = typeof pageMetrics?.currentPageNumber === 'number'
            ? pageMetrics.currentPageNumber
            : null;
        const totalPages = typeof pageMetrics?.totalPages === 'number'
            ? pageMetrics.totalPages
            : null;
        // (removed: setting tocView currentHref here)
        
        if (this.hasLoadedLastPosition) {
            this.#postUpdateReadingProgressMessage({
                fraction,
                cfi,
                reason,
                currentPageNumber,
                totalPages,
            })
        }
        
        await this.updateNavButtons();
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
            case 'finish':
                window.webkit.messageHandlers.finishedReadingBook.postMessage({
                    topWindowURL: window.top.location.href,
                });
                nav = Promise.resolve();
                break;
            case 'restart':
                window.webkit.messageHandlers.startOver.postMessage({});
                await this.view.renderer.firstSection();
                nav = Promise.resolve();
                break;
        }
        Promise.resolve(nav).finally(() => {
            // Keep spinner for 'finish' or 'restart' – Swift layer will handle refresh
            if (type === 'finish' || type === 'restart') return;
            restoreIcon();
        });
    }
}

class CacheWarmer {
    constructor() {
        this.view
        this.uniqueSentenceIdentifiers = new Set()
        this.lastPostedSentenceCount = null
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
    }
    async open(file) {
        this.destroy()
        this.view = await getView(file, true)
        this.view.addEventListener('load', this.#onLoad.bind(this))
        
        const {
            book
        } = this.view
        this.view.renderer.setAttribute('flow', 'paginated')
        //        this.view.renderer.next()
        
        await this.view.renderer.firstSection()
    }
    
    async #onLoad({
        detail: {
            doc,
            location,
            index,
        }
    }) {
        const sentenceNodes = Array.from(doc?.querySelectorAll?.('manabi-sentence') || []);
        const segmentNodes = Array.from(doc?.querySelectorAll?.('manabi-segment') || []);
        const indexedSectionHref =
            Number.isInteger(index)
            ? this.view?.book?.sections?.[index]?.href || null
            : null;
        const sourceHref = doc?.body?.dataset?.manabiSourceHref || indexedSectionHref || null;
        const sectionHref = indexedSectionHref || sourceHref || null;
        const isLikelyTitlePage = typeof sourceHref === 'string' && /(?:^|\/)(title|cover)\.xhtml$/i.test(sourceHref);
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
        
        if (!(await this.view.renderer.atEnd())) {
            window.webkit.messageHandlers.ebookCacheWarmerReadyToLoadNextSection.postMessage({
                topWindowURL: window.top.location.href,
            })
        } else {
            //            this.view.remove()
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
    await window.cacheWarmer.view.renderer.nextSection()
}

window.loadEBook = ({
    url,
    layoutMode,
}) => {
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
                    postReaderLog('ebook.viewer.load.blobReady', {
                        blobSize: blob.size,
                        blobType: blob.type || 'nil',
                    });
                    return makeFileSource(new File([blob], new URL(url).pathname))
                })

        sourcePromise
        .then(async (source) => {
            if (source?.kind === 'native') {
                postReaderLog('ebook.viewer.load.nativeSource', {
                    sourceURL: source.url,
                });
            }
            if (layoutMode) {
                window.initialLayoutMode = layoutMode
            }
            await reader.open(source)
        })
        .then(async () => {
            postReaderLog('ebook.viewer.load.opened', {
                hasRenderer: !!globalThis.reader?.view?.renderer,
                bookDir: globalThis.reader?.bookDir || 'nil',
                isRTL: !!globalThis.reader?.isRTL,
            });
            window.webkit.messageHandlers.ebookViewerLoaded.postMessage({})
        })
        .catch((error) => {
            postReaderLog('ebook.viewer.load.error', {
                message: error?.message || String(error),
            });
            throw error;
        })
    }
    //.catch(e => console.error(e))
}

window.loadLastPosition = async ({
    cfi,
    fractionalCompletion,
}) => {
    const awaitWithTimeout = (promise, timeoutMs) =>
        Promise.race([
            promise,
            new Promise((_, reject) => {
                setTimeout(() => reject(new Error(`Timed out after ${timeoutMs}ms`)), timeoutMs);
            }),
        ]);
    postReaderLog('ebook.viewer.loadLastPosition.start', {
        hasCFI: typeof cfi === 'string' && cfi.length > 0,
        fractionalCompletion: Number.isFinite(fractionalCompletion) ? fractionalCompletion : 'nil',
    });
    const hasFractionalCompletion = Number.isFinite(fractionalCompletion) && fractionalCompletion > 0;
    if (cfi.length > 0) {
        postReaderLog('ebook.viewer.loadLastPosition.path', {
            mode: 'cfi',
        });
        await globalThis.reader.view.goTo(cfi).catch(async e => {
            postReaderLog('ebook.viewer.loadLastPosition.goToError', {
                hasCFI: true,
                message: e?.message || String(e),
            });
            console.error(e)
            if (hasFractionalCompletion) {
                postReaderLog('ebook.viewer.loadLastPosition.path', {
                    mode: 'fraction-fallback',
                });
                await globalThis.reader.view.goToFraction(fractionalCompletion)
            }
        })
    } else if (hasFractionalCompletion) {
        postReaderLog('ebook.viewer.loadLastPosition.path', {
            mode: 'fraction',
        });
        try {
            await globalThis.reader.view.goToFraction(fractionalCompletion);
        } catch (error) {
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
    }
    globalThis.reader.hasLoadedLastPosition = true
    postReaderLog('ebook.viewer.loadLastPosition.done', {
        hasCFI: typeof cfi === 'string' && cfi.length > 0,
    });
    
    // Don't overlap cache warming with initial page load
    const cacheWarmerSource = window.ebookSource
        || makeFileSource(new File([window.blob], new URL(globalThis.reader.view.ownerDocument.defaultView.top.location.href).pathname))
    await window.cacheWarmer.open(cacheWarmerSource)
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
    globalThis.reader.applyBookReadingProgress(articleReadingProgress);
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
        currentPageNumber: null,
        totalPages: null,
        chapters: [],
    };
}

window.manabiScheduleReaderPageGoTo = (pageNumber) => {
    globalThis.reader?.scheduleGoToPageNumber?.(pageNumber);
}

window.manabiGoToReaderPage = async (pageNumber) => {
    return await globalThis.reader?.goToPageNumber?.(pageNumber, 'window.manabiGoToReaderPage');
}

window.manabiGoToReaderPercent = async (percent) => {
    return await globalThis.reader?.goToPercent?.(percent, 'window.manabiGoToReaderPercent');
}

window.manabiGoToReaderHref = async (href) => {
    return await globalThis.reader?.goToHref?.(href, 'window.manabiGoToReaderHref');
}

window.manabiScheduleReaderFractionGoTo = (fraction) => {
    globalThis.reader?.scheduleGoToFraction?.(fraction);
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

window.webkit.messageHandlers.ebookViewerInitialized.postMessage({})
postReaderLog('ebook.viewer.js.version', {
    version: 'replace-text-summary-v1',
});
