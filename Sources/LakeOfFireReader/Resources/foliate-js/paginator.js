// TODO: "prevent spread" for column mode: https://github.com/johnfactotum/foliate-js/commit/b7ff640943449e924da11abc9efa2ce6b0fead6d

import { installBookContentStyles } from './book-content-style.js'
import {
    applyPaginatorWritingDirectionOverride,
    normalizePaginatorWritingDirection,
    paginatorDirectionFromDocument,
} from './ebook-paginator-writing-direction.js'
import {
    lockedPageTurnQueueDecision as manabiLockedPageTurnQueueDecision,
    normalizeSingleMediaPageTarget as manabiNormalizeSingleMediaPageTarget,
    pageSummaryIsVisiblyBlank as manabiPageSummaryIsVisiblyBlank,
    pageTurnBoundaryDecision as manabiPageTurnBoundaryDecision,
    paginatorAnchorForLocalPage as manabiPaginatorAnchorForLocalPage,
    revealPaginatorDocument as manabiRevealPaginatorDocument,
    resolveBlankPageTarget as manabiResolveBlankPageTarget,
    shouldSuppressPostPageTurnDuplicate as manabiShouldSuppressPostPageTurnDuplicate,
} from './paginator-decisions.js'

const MANABI_ENABLE_COLUMNIZATION_OPTIMIZATIONS = true;
const MANABI_NEIGHBOR_PREFETCH_DELAY_MS = 0;
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
const MANABI_ENABLE_NEIGHBOR_PREFETCH = true;
const MANABI_ENABLE_PREFETCH_PROMISE_REUSE = true;
const MANABI_ENABLE_PREFETCH_WAIT_FOR_IN_FLIGHT = true;
const MANABI_NEIGHBOR_PREFETCH_END_PAGE_THRESHOLD = 5;
const MANABI_MIN_INLINE_CHARS_FOR_MULTICOLUMN = 17;
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
    // 1. Clone a minimal document
    const cloneDoc = document.implementation.createHTMLDocument();

    // 2. Deep-clone the <head>, stripping unwanted styles/scripts
    const clonedHead = sourceDoc.head.cloneNode(true);
    ['mnb-font-data', 'mnb-custom-fonts'].forEach(id => {
        const el = clonedHead.querySelector(`#${id}`);
        if (el) el.remove();
    });
    // Refresh blob-based CSS
    for (const link of clonedHead.querySelectorAll('link[rel="stylesheet"][href^="blob:"]')) {
        try {
            const css = await fetch(link.href).then(r => r.text());
            const blobUrl = URL.createObjectURL(new Blob([css], {
                type: 'text/css'
            }));
            link.href = blobUrl;
        } catch {
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
    await new Promise(resolve => {
        iframe.onload = resolve;
        iframe.src = blobUrl;
    });

    // wait a frame for CSS to apply before measuring
    await new Promise(r => requestAnimationFrame(r));

    // 6. Get computed style and doc
    const bodylessDoc = iframe.contentDocument;
    const bodylessStyle = iframe.contentWindow.getComputedStyle(bodylessDoc.body);

    // 7. Cleanup
    URL.revokeObjectURL(blobUrl);
    iframe.remove();

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

const resolvedPaginatorDirectionForDocument = async doc => {
    const directDirection = paginatorDirectionFromDocument(doc)
    if (directDirection) return directDirection
    const { bodylessStyle, bodylessDoc } = await getBodylessComputedStyle(doc)
    return getDirection({ bodylessStyle, bodylessDoc })
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
    #closed = false
    #loadGeneration = 0
    #layoutGeneration = 0
    #pendingGeometry = new Set()
    #pendingLoadCancel = null
    #currentDocument = null
    #wait = ms => new Promise(resolve => setTimeout(resolve, ms))
    #debouncedExpand
    #hasResizerObserverTriggered = false
    #lastResizerRect = null
    #styleCache = new WeakMap()
    cachedViewSize = null
    #resizeObserver = new ResizeObserver(entries => {
        if (this.#closed || this.#isCacheWarmer) return;

        const entry = entries[0];
        if (entry.target && entry.target !== this.#currentDocument?.body) return
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
    #column = true
    #size
    layout = {}
    #isCacheWarmer
    constructor({
        container,
        onBeforeExpand,
        onExpand,
        beginPositionActivity,
        captureGeometryOwner = () => () => true,
        isCacheWarmer
    }) {
        this.container = container
        this.#isCacheWarmer = isCacheWarmer
        this.#debouncedExpand = this.expand.bind(this)
        this.onBeforeExpand = onBeforeExpand
        this.onExpand = onExpand
        this.beginPositionActivity = beginPositionActivity
        this.captureGeometryOwner = captureGeometryOwner
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
    #retireGeometry() {
        for (const operation of this.#pendingGeometry) operation.retire()
        this.#pendingGeometry.clear()
    }
    retireLayout() {
        this.#layoutGeneration += 1
        this.#retireGeometry()
        this.cachedViewSize = null
    }
    #withGeometryOwner(callback, replacesLayout = false) {
        if (this.#closed) return Promise.resolve()
        if (replacesLayout) {
            this.retireLayout()
        }
        const doc = this.document
        const loadGeneration = this.#loadGeneration
        const layoutGeneration = this.#layoutGeneration
        const ownsContainer = this.captureGeometryOwner()
        let retire
        const retired = new Promise(resolve => { retire = resolve })
        const isCurrent = () => !this.#closed && this.#loadGeneration === loadGeneration
            && this.#layoutGeneration === layoutGeneration && this.document === doc && ownsContainer()
        const operation = {
            document: doc, isCurrent, retire,
            wait: promise => Promise.race([promise, retired]),
            context: { view: this, document: doc, isCurrent },
        }
        this.#pendingGeometry.add(operation)
        const finish = this.beginPositionActivity()
        return operation.wait(Promise.resolve().then(() => {
            if (isCurrent()) return callback(operation)
        })).finally(() => {
            this.#pendingGeometry.delete(operation)
            finish()
        })
    }
    async load(src, afterLoad, beforeRender, isCurrent = () => true) {
        if (typeof src !== 'string') throw new Error(`${src} is not string`)
        const cancelled = () => Object.assign(new Error('Paginator document load retired'), { name: 'AbortError' })
        if (this.#closed) throw cancelled()
        this.#pendingLoadCancel?.()
        this.#retireGeometry()
        this.#resizeObserver.disconnect()
        this.#hasResizerObserverTriggered = false
        this.#lastResizerRect = null
        this.cachedViewSize = null
        this.#currentDocument = null
        const generation = ++this.#loadGeneration
        const ownsLoad = () => !this.#closed && this.#loadGeneration === generation && isCurrent()
        this.#directionReadyResolve?.()
        this.#vertical = this.#verticalRTL = this.#rtl = null
        this.#directionReady = new Promise(resolve => { this.#directionReadyResolve = resolve })
        if (this.#isCacheWarmer) return
        return new Promise((resolve, reject) => {
            let settled = false
            const settle = error => {
                if (settled) return
                settled = true
                this.#iframe.removeEventListener('load', onLoad)
                this.#iframe.removeEventListener('error', onError)
                if (this.#pendingLoadCancel === cancel) this.#pendingLoadCancel = null
                // An iframe error can arrive while document preparation or
                // layout is suspended. Retire that work before allowing retry.
                if (error && this.#loadGeneration === generation) {
                    this.#loadGeneration += 1
                    this.#retireGeometry()
                    this.#resizeObserver.disconnect()
                    this.#directionReadyResolve?.()
                    this.#currentDocument = null
                }
                if (error) reject(error)
                else resolve()
            }
            const cancel = () => settle(cancelled())
            const requireOwner = doc => { if (!ownsLoad() || (doc && doc !== this.document)) throw cancelled() }
            const onError = error => settle(error)
            const onLoad = async () => {
                try {
                    requireOwner()
                    const doc = this.document
                    this.#currentDocument = doc
                    await afterLoad?.(doc)
                    requireOwner(doc)
                    await doc?.defaultView?.manabi_waitForExternalSegmentSidecar?.()
                    requireOwner(doc)
                    const direction = await resolvedPaginatorDirectionForDocument(doc)
                    requireOwner(doc)
                    this.setDirection(direction)
                    this.#contentRange.selectNodeContents(doc.body)
                    const layout = await beforeRender?.({ vertical: this.#vertical, verticalRTL: this.#verticalRTL, rtl: this.#rtl })
                    requireOwner(doc)
                    await this.render(layout)
                    requireOwner(doc)
                    this.#resizeObserver.observe(doc.body)
                    if (doc.fonts?.ready) {
                        Promise.resolve(doc.fonts.ready).then(() => {
                            if (ownsLoad() && this.document === doc) return this.expand()
                        }).catch(() => {})
                    }
                    settle()
                } catch (error) { settle(error) }
            }
            this.#pendingLoadCancel = cancel
            this.#iframe.addEventListener('load', onLoad, { once: true })
            this.#iframe.addEventListener('error', onError, { once: true })
            this.#iframe.src = src
        })
    }
    async render(layout) {
        if (this.#closed || !layout || !this.document?.body) return
        return this.#withGeometryOwner(owner => this.#renderOwned(layout, owner), true)
    }
    async #renderOwned(layout, owner) {
        await owner.wait(this.#awaitDirection())
        if (!owner.isCurrent()) return
        //        console.log("render(layout)...")
        if (!layout) {
            //            console.log("render(layout)... return")
            return
        }
        const doc = owner.document
        if (!doc?.documentElement || !doc?.body) {
            return
        }
        this.#column = layout.flow !== 'scrolled'
        this.layout = layout

        this.__manabiViewportMetricsGeneration = (this.__manabiViewportMetricsGeneration ?? 0) + 1
        doc.defaultView?.manabi_seedViewportMetrics?.({
            width: Number(layout.width) || 0,
            height: Number(layout.height) || 0,
            documentURL: doc.location?.href || doc.URL || null,
            generation: this.__manabiViewportMetricsGeneration,
        })

        doc.body.dataset.mnbFoliateWritingDirection = this.#vertical ? 'vertical' : 'horizontal'
        doc.body.classList.toggle('reader-vertical-writing', this.#vertical)

        if (this.#column) {
            //            console.log("render(layout)... await columnize(layout)")
            await this.columnize(layout, owner)
            //            console.log("render(layout)... await'd columnize(layout)")
        } else {
            //            console.log("render(layout)... await scrolled")
            await this.scrolled(layout, owner)
            //            console.log("render(layout)... await'd scrolled")
        }
    }
    async scrolled(layout, owner = null) {
        if (!owner) return this.#withGeometryOwner(operation => this.scrolled(layout, operation), true)
        const { gap, columnWidth } = layout
        await owner.wait(this.#awaitDirection())
        if (!owner.isCurrent()) return
        const vertical = this.#vertical
        const doc = owner.document
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
        manabiRevealPaginatorDocument(doc)
        await this.#debouncedExpand()
        //        await this.expand()
    }
    async columnize(layout, owner = null) {
        if (!owner) return this.#withGeometryOwner(operation => this.columnize(layout, operation), true)
        const { width, height, gap, columnWidth, divisor } = layout
        //        console.log("columnize...")
        await owner.wait(this.#awaitDirection())
        if (!owner.isCurrent()) return
        //        console.log("columnize... await'd direction")
        const vertical = this.#vertical
        this.#size = vertical ? height : width
        //        console.log("columnize #size = ", this.#size)

        const doc = owner.document
        const { isJapanese } = getJapaneseLayoutFlags(doc)
        setStylesImportant(doc.documentElement, {
            'box-sizing': 'border-box',
            'column-width': `${Math.trunc(columnWidth)}px`,
            '--paginator-column-gap': `${gap}px`,
            'column-gap': `${gap}px`,
            'column-fill': 'auto',
            ...(vertical ? {
                'width': `${width}px`
            } : {
                'height': `${height}px`
            }),
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
        doc.documentElement.style.setProperty('--paginator-margin', `30px`)
        setStylesImportant(doc.body, {
            'max-height': 'none',
            'max-width': 'none',
            'margin': '0',
        })
        this.setImageSize()
        manabiRevealPaginatorDocument(doc)
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
        const textNodeType = doc?.defaultView?.Node?.TEXT_NODE ?? 3;
        const mediaSelector = 'img, svg, image, picture, video, object, iframe, canvas, embed';
        const hasSubstantiveDirectText = parent => {
            for (const node of parent?.childNodes || []) {
                if (node.nodeType === textNodeType && /\S/.test(node.textContent || '')) {
                    return true;
                }
            }
            return false;
        };
        const hasSubstantiveTextExcludingMedia = element => {
            const clone = element?.cloneNode?.(true);
            for (const media of clone?.querySelectorAll?.(mediaSelector) || []) {
                media.remove();
            }
            return /\S/.test(clone?.textContent || '');
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
                    const ancestorMediaCount = ancestor.querySelectorAll?.(mediaSelector)?.length ?? 0;
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
    async expand() {
        if (this.#closed || !this.document?.body) return
        return this.#withGeometryOwner(async owner => {
            await owner.wait(this.onBeforeExpand?.(owner.context))
            if (!owner.isCurrent()) return
            return new Promise((resolve, reject) => {
                requestAnimationFrame(async () => {
                    try {
                        if (!owner.isCurrent()) { resolve(); return }
                        const doc = owner.document
                        const documentElement = doc?.documentElement
                        if (!doc?.body || !documentElement || !this.#iframe?.isConnected) {
                            resolve()
                            return
                        }
                        const side = this.#vertical ? 'height' : 'width'
                        const otherSide = side === 'width' ? 'height' : 'width'
                        if (this.#column) {
                            const contentRect = this.#contentRange.getBoundingClientRect()
                            // offset caused by column break at the start of the page
                            // which seem to be supported only by WebKit and only for horizontal writing
                            const contentStart = this.#vertical ? 0 : (() => {
                                const rootRect = documentElement.getBoundingClientRect()
                                return this.#rtl ? rootRect.right - contentRect.right : contentRect.left - rootRect.left
                            })()
                            const contentSize = contentStart + contentRect[side]
                            const pageCount = Math.ceil(contentSize / this.#size)
                            const expandedSize = pageCount * this.#size
                            this.#element.style.padding = '0'
                            this.#iframe.style[side] = `${expandedSize}px`
                            this.#element.style[side] = `${expandedSize + this.#size * 2}px`
                            this.#iframe.style[otherSide] = '100%'
                            this.#element.style[otherSide] = '100%'
                            if (documentElement) {
                                documentElement.style[side] = `${this.#size}px`
                            }
                            if (this.#overlayer) {
                                this.#overlayer.element.style.margin = '0'
                                this.#overlayer.element.style.left = this.#vertical ? '0' : `${this.#size}px`
                                this.#overlayer.element.style.top = this.#vertical ? `${this.#size}px` : '0'
                                this.#overlayer.element.style[side] = `${expandedSize}px`
                                this.#overlayer.redraw()
                            }
                        } else {
                            const contentSize = documentElement.getBoundingClientRect()[side]
                            const expandedSize = contentSize
                            const {
                                topMargin,
                                bottomMargin
                            } = this.layout
                            //                    const paddingTop = `${marginTop}px`
                            //                    const paddingBottom = `${marginBottom}px`
                            const paddingTop = `${topMargin}px`
                            const paddingBottom = `${bottomMargin}px`
                            if (this.#vertical) {
                                this.#element.style.paddingLeft = paddingTop
                                this.#element.style.paddingRight = paddingBottom
                                this.#element.style.paddingTop = '0'
                                this.#element.style.paddingBottom = '0'
                            } else {
                                this.#element.style.paddingLeft = '0'
                                this.#element.style.paddingRight = '0'
                                this.#element.style.paddingTop = paddingTop
                                this.#element.style.paddingBottom = paddingBottom
                            }
                            this.#iframe.style[side] = `${expandedSize}px`
                            this.#element.style[side] = `${expandedSize}px`
                            this.#iframe.style[otherSide] = '100%'
                            this.#element.style[otherSide] = '100%'
                            if (this.#overlayer) {
                                if (this.#vertical) {
                                    this.#overlayer.element.style.marginLeft = paddingTop
                                    this.#overlayer.element.style.marginRight = paddingBottom
                                    this.#overlayer.element.style.marginTop = '0'
                                    this.#overlayer.element.style.marginBottom = '0'
                                } else {
                                    this.#overlayer.element.style.marginLeft = '0'
                                    this.#overlayer.element.style.marginRight = '0'
                                    this.#overlayer.element.style.marginTop = paddingTop
                                    this.#overlayer.element.style.marginBottom = paddingBottom
                                }
                                this.#overlayer.element.style.left = '0'
                                this.#overlayer.element.style.top = '0'
                                this.#overlayer.element.style[side] = `${expandedSize}px`
                                this.#overlayer.redraw()
                            }
                        }
                        //                console.log("expand... call onexpand")
                        if (owner.isCurrent()) await owner.wait(this.onExpand?.(owner.context))
                        //                console.log("expand... call'd onexpand")
                        resolve()
                    } catch (error) {
                        reject(error)
                    }
                })
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
    setDirection({ vertical, verticalRTL, rtl }) {
        if (this.#vertical !== null && (vertical !== this.#vertical || verticalRTL !== this.#verticalRTL || rtl !== this.#rtl)) {
            this.retireLayout()
        }
        this.#vertical = vertical
        this.#verticalRTL = verticalRTL
        this.#rtl = rtl
        this.#directionReadyResolve?.()
    }
    destroy() {
        if (this.#closed) return false
        this.#closed = true
        this.#loadGeneration += 1
        this.#retireGeometry()
        this.#pendingLoadCancel?.()
        this.#directionReadyResolve?.()
        this.#resizeObserver.disconnect()
        this.#currentDocument = null
        this.onBeforeExpand = this.onExpand = null
        return true
    }

}

// NOTE: everything here assumes the so-called "negative scroll type" for RTL
export class Paginator extends HTMLElement {
    #geometryGeneration = 0
    #renderGeneration = 0
    #pendingRender = null
    #pendingSizeCancel = null
    #pendingViewSizeCancel = null
    #pendingScrollFrames = new Set()
    static observedAttributes = [
        'flow', 'gap', 'margintop', 'marginbottom',
        'max-inline-size', 'max-block-size', 'max-column-count',
    ]
    // Command ownership survives its own render; a settled proof also binds layout and live dimensions.
    #positionCommand = null
    #positionRevision = null
    #positionActivities = new Set()
    #positionReceipts = new WeakMap()
    #navigationReceipts = new WeakMap()
    #positionProofs = new WeakMap()
    #positionDestroyed = false
    #displayOwner = null
    #beginPositionActivity() {
        const activity = {}
        this.#positionActivities.add(activity)
        this.#positionRevision = {}
        return () => {
            if (this.#positionActivities.delete(activity)) this.#positionRevision = {}
        }
    }
    #beginPositionCommand() {
        const command = { identity: {}, finish: this.#beginPositionActivity() }
        this.#positionCommand = command.identity
        return command
    }
    #isPositionCommandCurrent(command) {
        return !this.#positionDestroyed && this.#positionCommand === command?.identity
    }
    attributeChangedCallback(_name, oldValue, newValue) {
        if (oldValue !== newValue) this.#positionRevision = {}
    }
    isNavigationReceiptCurrent(receipt) {
        const command = receipt && this.#navigationReceipts.get(receipt)
        return !!command && this.#isPositionCommandCurrent(command)
    }
    isPositionReceiptCurrent(receipt) {
        const command = receipt && this.#positionReceipts.get(receipt)
        return !!command && this.#isPositionCommandCurrent(command)
    }
    #livePosition() {
        if (this.#positionDestroyed || this.#positionActivities.size || !this.#view?.document
            || this.#vertical == null || this.#rtl == null || this.scrolled) return null
        const sideProp = this.#vertical ? 'height' : 'width'
        const scrollProp = this.#vertical ? 'scrollTop' : 'scrollLeft'
        const container = this.#container
        const element = this.#view.element
        const size = sideProp === 'height' ? container.clientHeight : container.clientWidth
        const viewSize = sideProp === 'height' ? element.clientHeight : element.clientWidth
        const start = Math.abs(container[scrollProp])
        if (![size, viewSize, start].every(Number.isFinite) || size <= 0 || viewSize <= 0) return null
        // Read live dimensions: cached metrics can predate an undelivered resize/scroll event.
        const metrics = this.#pageMetricsFromValues({ sideProp, scrollProp, size, viewSize, start })
        return {
            ...metrics, index: this.#index, document: this.#view.document,
            verticalRTL: this.#verticalRTL,
            containerWidth: container.clientWidth, containerHeight: container.clientHeight,
            viewWidth: element.clientWidth, viewHeight: element.clientHeight,
            scrollLeft: container.scrollLeft, scrollTop: container.scrollTop,
        }
    }
    capturePositionProof(receipt) {
        if (!this.isPositionReceiptCurrent(receipt)) return null
        const revision = this.#positionRevision
        const position = this.#livePosition()
        if (!position || position.page !== 1 || position.pages <= 2
            || position.index !== receipt.index || receipt.anchor !== 0) return null
        const proof = Object.freeze({ sectionIndex: position.index,
            fractionInSection: 0, pageFraction: 1 / (position.pages - 2) })
        this.#positionProofs.set(proof, { receipt, revision, position })
        return this.isPositionProofCurrent(proof) ? proof : null
    }
    isPositionProofCurrent(proof) {
        const record = proof && this.#positionProofs.get(proof)
        if (!record || !this.isPositionReceiptCurrent(record.receipt)
            || record.revision !== this.#positionRevision) return false
        const position = this.#livePosition()
        return !!position && Object.keys(record.position).every(key =>
            Object.is(record.position[key], position[key]))
    }
    #root = this.attachShadow({
        mode: 'closed'
    })
    #debouncedRender = this.render.bind(this)
    #lastResizerRect = null
    #resizeObserver = new ResizeObserver(entries => {
        if (this.#positionDestroyed || this.#isCacheWarmer) return;

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

        this.#positionRevision = {}
        this.#lastResizerRect = newSize
        this.#cachedSizes = null
        this.#invalidateContainerGeometry()
        //            console.log("sizes() from resize updated to ", this.#cachedSizes)
        this.#cachedStart = null
        this.#invalidateVisibleRangeCache()

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
    #styles
    #writingDirectionOverride = 'original'
    #writingDirectionUpdate = Promise.resolve()
    #bookContentStylesPromise = null
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
    #queuedPageTurn = null
    #lockedAt = null
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
    #visibleRangeCache = null
    #visibleRangeInFlight = null
    #visibleRangeCacheVersion = 0
    #elementVisibilityObserver = null
    #elementMutationObserver = null

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

        this.#container.addEventListener('scroll', () => this.dispatchEvent(new Event('scroll')))

        // Continuously fire relocate during scroll
        this.#container.addEventListener('scroll', debounce(async () => {
            const view = this.#view
            if (this.#positionDestroyed || !view || view.isLoading) return;
            if (this.scrolled && !this.#isCacheWarmer) {
                const index = this.#index;
                const metrics = await this.pageMetrics();
                if (this.#positionDestroyed || this.#view !== view) return
                const fraction = metrics.viewSize > 0 ? metrics.start / metrics.viewSize : 0;
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
            if (this.#positionDestroyed || !this.#view) return
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
    open(book, isCacheWarmer) {
        this.#retireScrollFrames()
        this.#geometryGeneration += 1
        this.#renderGeneration += 1
        this.#invalidateContainerGeometry()
        this.#invalidateViewGeometry()
        this.#directionReadyResolve?.()
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
        this.#positionRevision = {}
        this.#top?.style?.setProperty('--side-nav-width', typeof widthPx === 'number' ? `${widthPx}px` : widthPx);
    }
    #createView() {
        this.#retireScrollFrames()
        this.#geometryGeneration += 1
        this.#renderGeneration += 1
        this.#invalidateContainerGeometry()
        this.#invalidateViewGeometry()
        this.#directionReadyResolve?.()
        this.#vertical = this.#verticalRTL = this.#rtl = null
        this.#directionReady = new Promise(resolve => { this.#directionReadyResolve = resolve })
        if (this.#view) {
            this.#view.destroy()
            this.#container.removeChild(this.#view.element)
        }
        this.#invalidateVisibleRangeCache()
        const geometryGeneration = this.#geometryGeneration
        this.#view = new View({
            container: this,
            onBeforeExpand: owner => this.#onBeforeExpand({ ...owner, geometryGeneration }),
            onExpand: owner => this.#onExpand({ ...owner, geometryGeneration }),
            beginPositionActivity: this.#beginPositionActivity.bind(this),
            captureGeometryOwner: this.#geometryOwner.bind(this),
            isCacheWarmer: this.#isCacheWarmer,
            //            onExpand: debounce(() => this.#onExpand.bind(this), 500),
        })
        this.#container.append(this.#view.element)
        return this.#view
    }
    async #installStyleElementsForDocument(doc) {
        if (!doc?.head) return
        await installBookContentStyles(doc, this.#bookContentStylesPromise)
        if (!this.#styleMap.has(doc)) {
            const $styleBefore = doc.createElement('style')
            doc.head.prepend($styleBefore)
            const $style = doc.createElement('style')
            doc.head.append($style)
            this.#styleMap.set(doc, [$styleBefore, $style])
        }
        this.#applyStylesToDocument(doc)
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
            const { page, pages } = await this.pageMetrics()
            const lastReadablePage = Math.max(1, pages - 2)
            const remainingPages = Math.max(0, lastReadablePage - page)
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
    #ownsExpansion(owner) {
        return !this.#positionDestroyed && owner.geometryGeneration === this.#geometryGeneration && owner.isCurrent()
            && this.#view === owner.view && this.#view?.document === owner.document
    }
    async #onBeforeExpand(owner) {
        if (!this.#ownsExpansion(owner)) return
        this.#view.cachedViewSize = null;
        this.#view.cachedSizes = null;
        this.#invalidateViewGeometry();
        this.#cachedStart = null;
        this.#invalidateVisibleRangeCache()
    }
    async #onExpand(owner) {
        if (!this.#ownsExpansion(owner)) return
        const command = this.#positionCommand
        const anchor = this.#anchor
        // Reflow may preserve the current anchor, but cannot lend that anchor
        // to a later navigation. A command admitted before this callback can
        // also still be resolving its target, so retain the anchor identity.
        const ownsAnchor = () => this.#ownsExpansion(owner)
            && this.#positionCommand === command && Object.is(this.#anchor, anchor)
        this.#view.cachedViewSize = null;
        this.#view.cachedSizes = null;
        this.#invalidateViewGeometry();
        this.#cachedStart = null;
        this.#invalidateVisibleRangeCache()
        if (!this.#suspendOnExpandAnchor) {
            await this.#scrollToAnchor(anchor, 'anchor', ownsAnchor)
        }

        if (!ownsAnchor()) return
        if (!this.#isLoading) return
        this.#setLoading(false, 'expand.onExpand')
    }
    async #awaitDirection() {
        if (this.#vertical === null) await this.#directionReady;
    }
    #invalidateVisibleRangeCache() {
        this.#visibleRangeCache = null
        this.#visibleRangeInFlight = null
        this.#visibleRangeCacheVersion += 1
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

        const elements = this.#view?.document?.body?.getElementsByTagName('reader-sentinel')
        // An observer with no targets never calls back. Let the existing
        // visible-range empty-result path handle ordinary unprocessed sections.
        if (!elements?.length) return []
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
        const bodyStyle = doc?.body ? getComputedStyle(doc.body) : null;
        const containerStyle = this.#container ? getComputedStyle(this.#container) : null;
        const fontSize =
            parseFloat(bodyStyle?.fontSize)
            || parseFloat(containerStyle?.fontSize)
            || 20;
        const parsedLineHeight =
            parseFloat(bodyStyle?.lineHeight)
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
    async #resolveBlankPageTarget(page, direction, reason = 'unknown') {
        if (
            this.#isCacheWarmer
            || this.scrolled
            || !this.#view?.document
            || !Number.isFinite(page)
            || !Number.isFinite(direction)
            || direction === 0
        ) {
            return page;
        }
        const metrics = await this.pageMetrics();
        const pages = metrics.pages;
        const minPage = 1;
        const maxPage = Math.max(minPage, pages - 2);
        if (page < minPage || page > maxPage) {
            return page;
        }

        const size = metrics.size;
        const rectMapper = await this.#getRectMapper(metrics);
        const summariesByPage = new Map();
        let target = page;

        while (target >= minPage && target <= maxPage) {
            summariesByPage.set(target, await this.#blankPageContentSummary(target, size, rectMapper));
            const resolved = manabiResolveBlankPageTarget({
                page: target,
                pages,
                direction,
                summariesByPage,
            });
            if (resolved === target) break;
            target = resolved;
        }

        if (target !== page) {
        }
        return target;
    }
    #typographyRenderSignature({
        width,
        height,
        flow = this.getAttribute('flow'),
        vertical = this.#vertical,
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
            Math.round(width ?? this.#container?.clientWidth ?? 0),
            Math.round(height ?? this.#container?.clientHeight ?? 0),
            manabiRound(metrics.fontSize, 2),
            manabiRound(metrics.lineHeight, 2),
            manabiRound(metrics.inlineCharacterAdvance, 2),
        ].join('|');
    }
    #isCurrentRenderView(view, doc) {
        return !this.#positionDestroyed && !!view && this.#view === view
            && !!doc?.documentElement && !!doc?.body && view.document === doc
    }
    async renderIfTypographyChanged(reason = 'unspecified') {
        if (MANABI_DISABLE_POST_LOAD_RERENDER) {
            return { rendered: false, reason: 'post-load-rerender-disabled' };
        }
        const view = this.#view
        const doc = view?.document
        if (!this.#isCurrentRenderView(view, doc) || this.#isCacheWarmer) {
            return { rendered: false, reason: 'unavailable' };
        }
        const measured = await this.sizes();
        if (!measured) return { rendered: false, reason: 'replaced' }
        const { width, height } = measured;
        if (!this.#isCurrentRenderView(view, doc)) return { rendered: false, reason: 'replaced' }
        const signature = this.#typographyRenderSignature({ width, height });
        const previousSignature = this.#lastTypographyRenderSignature;
        if (signature === previousSignature) {
            return { rendered: false, reason: 'unchanged', signature };
        }
        const finish = this.#beginPositionActivity()
        try {
            this.#cachedSizes = null;
            this.#invalidateContainerGeometry();
            this.#cachedStart = null;
            this.#invalidateViewGeometry();
            this.#view.cachedViewSize = null;
            this.#view.cachedSizes = null;
            this.#invalidateVisibleRangeCache();
            await this.render();
            if (!this.#isCurrentRenderView(view, doc)) return { rendered: false, reason: 'replaced' }
            return { rendered: true, reason, previousSignature, signature };
        } finally { finish() }
    }
    async #beforeRender({
        vertical,
        verticalRTL,
        rtl,
        //        background
    }, view = this.#view, isCurrent = () => true) {
        const doc = view?.document
        const generation = ++this.#renderGeneration
        this.#retireScrollFrames()
        const ownsRender = () => isCurrent() && this.#renderGeneration === generation
            && this.#isCurrentRenderView(view, doc)
        if (!ownsRender()) return null
        view.retireLayout()
        this.#invalidateContainerGeometry()
        this.#invalidateViewGeometry()

        // set background to `doc` background
        // this is needed because the iframe does not fill the whole element
        //        this.#background.style.background = background

        if (!this.#isCacheWarmer) {
        }

        let measured = await this.sizes()
        while (!measured && ownsRender()) measured = await this.sizes()
        if (!ownsRender() || !measured) return null
        const { width, height } = measured
        this.#vertical = vertical
        this.#verticalRTL = verticalRTL
        this.#rtl = rtl
        this.#top.classList.toggle('vertical', vertical)
        this.#directionReadyResolve?.()
        this.#lastRenderContainerSize = { width, height }
        const size = vertical ? height : width
        const flow = this.getAttribute('flow')
        const typographyMetrics = this.#typographyMetrics()
        this.#lastTypographyRenderSignature = this.#typographyRenderSignature({
            width,
            height,
            flow,
            vertical,
            fontSize: typographyMetrics.fontSize,
            lineHeight: typographyMetrics.lineHeight,
            inlineCharacterAdvance: typographyMetrics.inlineCharacterAdvance,
        })
        this.#top.classList.toggle(
            'mnb-vertical-paginated',
            MANABI_ENABLE_COLUMNIZATION_OPTIMIZATIONS && vertical && flow !== 'scrolled'
        )

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
        doc.documentElement.style.setProperty('--_max-inline-size', maxInlineSize)

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
            }
        }

        let divisor;
        let columnWidth;
        if (MANABI_ENABLE_COLUMNIZATION_OPTIMIZATIONS && this.#isSingleMediaElementWithoutText()) {
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
        }
    }
    async #waitForCurrentRender(isCurrent) {
        while (isCurrent() && this.#pendingRender) {
            const render = this.#pendingRender
            await render.completion
            if (isCurrent() && render.generation === this.#renderGeneration && render.error) {
                throw render.error
            }
        }
    }
    async render() {
        const finish = this.#beginPositionActivity()
        let resolve
        const render = { completion: new Promise(settle => { resolve = settle }),
            generation: null, error: null }
        this.#pendingRender = render
        try {
            const view = this.#view
            const doc = view?.document
            if (!this.#isCurrentRenderView(view, doc)) return
            this.#invalidateVisibleRangeCache()

            // avoid unwanted triggers
            //        this.#hasResizeObserverTriggered = false
            //        this.#resizeObserver.observe(this.#container);

            const pendingLayout = this.#beforeRender({
                vertical: this.#vertical,
                verticalRTL: this.#verticalRTL,
                rtl: this.#rtl,
            }, view)
            render.generation = this.#renderGeneration
            const layout = await pendingLayout
            if (!layout || !this.#isCurrentRenderView(view, doc)) return
            await view.render(layout)
            //            await this.#scrollToAnchor(this.#anchor) // already called via render -> ... -> expand -> onExpand
        } catch (error) {
            render.error = error
            throw error
        } finally {
            if (this.#pendingRender === render) this.#pendingRender = null
            finish()
            resolve()
        }
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
        const finish = this.#beginPositionActivity()
        try {
            this.#cachedSizes = null
            this.#invalidateContainerGeometry()
            this.#cachedStart = null
            this.#invalidateViewGeometry()
            this.#view.cachedViewSize = null
            this.#view.cachedSizes = null
            this.#invalidateVisibleRangeCache()
            await this.render()
            return { rendered: true, previousSize, currentSize }
        } finally { finish() }
    }
    get scrolled() {
        return this.getAttribute('flow') === 'scrolled'
    }
    async scrollProp() {
        await this.#awaitDirection();
        const {
            scrolled
        } = this
        return this.#vertical ? (scrolled ? 'scrollLeft' : 'scrollTop') :
            scrolled ? 'scrollTop' : 'scrollLeft'
    }
    async sideProp() {
        await this.#awaitDirection();
        const {
            scrolled
        } = this
        return this.#vertical ? (scrolled ? 'width' : 'height') :
            scrolled ? 'height' : 'width'
    }
    #invalidateContainerGeometry() {
        this.#pendingSizeCancel?.()
        this.#pendingSizeCancel = null
        this.#sizesPromise = null
        this.#cachedSizes = null
    }
    #invalidateViewGeometry() {
        this.#pendingViewSizeCancel?.()
        this.#pendingViewSizeCancel = null
        this.#viewSizePromise = null
        if (this.#view) this.#view.cachedViewSize = null
    }
    #geometryOwner(permitsContinuation = () => true) {
        const generation = this.#geometryGeneration
        const renderGeneration = this.#renderGeneration
        const view = this.#view
        const doc = view?.document
        return () => !this.#positionDestroyed && this.#geometryGeneration === generation
            && this.#renderGeneration === renderGeneration && permitsContinuation()
            && this.#view === view && this.#view?.document === doc
    }
    async sizes() {
        if (this.#positionDestroyed) return null
        if (this.#isCacheWarmer) return 0
        if (this.#cachedSizes !== null) return this.#cachedSizes
        if (this.#sizesPromise) return this.#sizesPromise
        const isCurrent = this.#geometryOwner()
        let resolve
        const promise = new Promise(settle => { resolve = settle })
        const cancel = () => {
            if (this.#sizesPromise === promise) this.#sizesPromise = null
            if (this.#pendingSizeCancel === cancel) this.#pendingSizeCancel = null
            resolve(null)
        }
        this.#sizesPromise = promise
        this.#pendingSizeCancel = cancel
        requestAnimationFrame(() => {
            if (!isCurrent() || this.#sizesPromise !== promise) { cancel(); return }
            const sizes = { width: this.#container.clientWidth, height: this.#container.clientHeight }
            this.#cachedSizes = sizes
            this.#sizesPromise = null
            if (this.#pendingSizeCancel === cancel) this.#pendingSizeCancel = null
            resolve(sizes)
        })
        return promise
    }
    async size() {
        const isCurrent = this.#geometryOwner()
        const sideProp = await this.sideProp()
        if (!isCurrent()) return 0
        return await this.#sizeForSide(sideProp)
    }
    async viewSize() {
        const isCurrent = this.#geometryOwner()
        const sideProp = await this.sideProp()
        if (!isCurrent()) return 0
        return await this.#viewSizeForSide(sideProp)
    }
    async #sizeForSide(sideProp) {
        const isCurrent = this.#geometryOwner()
        const sizes = await this.sizes()
        return isCurrent() ? sizes?.[sideProp] ?? 0 : 0
    }
    async #viewSizeForSide(sideProp) {
        if (this.#positionDestroyed || this.#isCacheWarmer || !this.#view) return 0
        const isCurrent = this.#geometryOwner()
        const view = this.#view
        if (view.cachedViewSize !== null) return view.cachedViewSize?.[sideProp] ?? 0
        let promise = this.#viewSizePromise
        if (!promise) {
            let resolve
            promise = new Promise(settle => { resolve = settle })
            const pending = promise
            const cancel = () => {
                if (this.#viewSizePromise === pending) this.#viewSizePromise = null
                if (this.#pendingViewSizeCancel === cancel) this.#pendingViewSizeCancel = null
                resolve(null)
            }
            this.#viewSizePromise = pending
            this.#pendingViewSizeCancel = cancel
            requestAnimationFrame(() => {
                if (!isCurrent() || this.#viewSizePromise !== pending) { cancel(); return }
                const sizes = { width: view.element.clientWidth, height: view.element.clientHeight }
                view.cachedViewSize = sizes
                this.#viewSizePromise = null
                if (this.#pendingViewSizeCancel === cancel) this.#pendingViewSizeCancel = null
                resolve(sizes)
            })
        }
        const sizes = await promise
        return isCurrent() ? sizes?.[sideProp] ?? 0 : 0
    }
    async start() {
        const isCurrent = this.#geometryOwner()
        const scrollProp = await this.scrollProp()
        if (!isCurrent()) return 0
        return await this.#startForScrollProp(scrollProp)
    }
    async #startForScrollProp(scrollProp) {
        if (this.#positionDestroyed) return 0
        if (this.#cachedStart === null) {
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
        if (
            rawPages > 3
            && this.#isSingleMediaElementWithoutText()
        ) {
            return 3
        }
        return rawPages
    }
    #retiredPageMetrics() {
        return { scrolled: this.scrolled, vertical: false, rtl: false, sideProp: 'width', scrollProp: 'scrollLeft',
            size: 0, viewSize: 0, start: 0, end: 0, page: 0, pages: 0 }
    }
    async pageMetrics() {
        const isCurrent = this.#geometryOwner()
        await this.#awaitDirection()
        if (!isCurrent()) return this.#retiredPageMetrics()
        const sideProp = await this.sideProp()
        if (!isCurrent()) return this.#retiredPageMetrics()
        const scrollProp = await this.scrollProp()
        if (!isCurrent()) return this.#retiredPageMetrics()
        const [size, viewSize, start] = await Promise.all([
            this.#sizeForSide(sideProp),
            this.#viewSizeForSide(sideProp),
            this.#startForScrollProp(scrollProp),
        ])
        if (!isCurrent()) return this.#retiredPageMetrics()
        return this.#pageMetricsFromValues({ sideProp, scrollProp, size, viewSize, start })
    }
    #pageMetricsFromValues({ sideProp, scrollProp, size, viewSize, start }) {
        const end = start + size
        const rawPages = size > 0 ? Math.round(viewSize / size) : 0
        const pages = this.#normalizePages(rawPages)
        const page = size > 0 ? Math.floor(((start + end) / 2) / size) : 0
        return {
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
        }
    }
    async scrollBy(dx, dy) {
        const command = this.#beginPositionCommand()
        const isCurrent = this.#geometryOwner(() => this.#isPositionCommandCurrent(command))
        try {
            //        await this.#awaitDirection()
            return await this.#runScrollFrame(isCurrent, async () => {
                const delta = this.#vertical ? dy : dx
                const element = this.#container
                const scrollProp = await this.scrollProp()
                if (!isCurrent()) return null
                const [offset, a, b] = this.#scrollBounds
                const rtl = this.#rtl
                const min = rtl ? offset - b : offset - a
                const max = rtl ? offset + a : offset + b
                element[scrollProp] = Math.max(min, Math.min(max,
                    element[scrollProp] + delta))
                this.#cachedStart = null; // TODO: Needed here?
            })
        } finally { command.finish() }
    }
    async snap(vx, vy) {
        const command = this.#beginPositionCommand()
        const isCurrent = () => this.#isPositionCommandCurrent(command)
        const ownsGeometry = this.#geometryOwner(isCurrent)
        try {
            //        await this.#awaitDirection();
            const velocity = this.#vertical ? vy : vx
            const [offset, a, b] = this.#scrollBounds
            const metrics = await this.pageMetrics()
            if (!ownsGeometry()) return null
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

            return await this.#scrollToPage(targetPage, 'snap', undefined, metrics, ownsGeometry).then(async result => {
                if (result === null || !ownsGeometry()) return null
                const dir = targetPage <= 0 ? -1 : targetPage >= pages - 1 ? 1 : null
                if (dir) return await this.#goTo({
                    index: this.#adjacentIndex(dir),
                    anchor: dir < 0 ? () => 1 : () => 0,
                }, isCurrent)
            })
        } finally { command.finish() }
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
            const foregroundActivity = this.#dispatchForegroundPageTurnActivity(this.#logicalDirectionForSwipeDelta(dx, 'touch'), {
                input: 'touch',
                source: 'paginator.touchmove',
            });
            if (!foregroundActivity) return;

            if (dx < 0) {
                (this.bookDir === 'rtl') ? await this.prev(undefined, { foregroundActivity }) : await this.next(undefined, { foregroundActivity });
            } else {
                (this.bookDir === 'rtl') ? await this.next(undefined, { foregroundActivity }) : await this.prev(undefined, { foregroundActivity });
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
            const foregroundActivity = this.#dispatchForegroundPageTurnActivity(this.#logicalDirectionForSwipeDelta(e.deltaX, 'wheel'), {
                input: 'wheel',
                source: 'paginator.wheel',
            });
            if (!foregroundActivity) { this.#wheelCooldown = false; return; }
            if (e.deltaX > 0) {
                await this.prev(undefined, { foregroundActivity });
            } else {
                await this.next(undefined, { foregroundActivity });
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
    #retireScrollFrames() {
        for (const cancel of this.#pendingScrollFrames) cancel()
        this.#pendingScrollFrames.clear()
    }
    #runScrollFrame(isCurrent, callback) {
        return new Promise((resolve, reject) => {
            let settled = false
            const finish = (error, value) => {
                if (settled) return
                settled = true
                this.#pendingScrollFrames.delete(cancel)
                if (error) reject(error)
                else resolve(value)
            }
            const cancel = () => finish(null, null)
            this.#pendingScrollFrames.add(cancel)
            requestAnimationFrame(async () => {
                if (settled || !isCurrent()) { cancel(); return }
                try { finish(null, await callback()) }
                catch (error) { finish(error) }
            })
        })
    }
    async #scrollToRect(rect, reason, isCurrent = this.#geometryOwner()) {
        isCurrent = this.#geometryOwner(isCurrent)
        const metrics = await this.pageMetrics()
        if (!isCurrent()) return null
        if (this.scrolled) {
            const rectMapper = await this.#getRectMapper(metrics);
            if (!isCurrent()) return null
            const offset = rectMapper(rect).left - this.#topMargin
            return await this.#scrollTo(offset, reason, undefined, metrics, isCurrent)
        }
        const rectMapper = await this.#getRectMapper(metrics);
        if (!isCurrent()) return null
        const offset = rectMapper(rect).left
        return await this.#scrollToPage(Math.floor(offset / metrics.size) + (this.#rtl ? -1 : 1), reason, undefined, metrics, isCurrent)
    }
    async #scrollTo(offset, reason, smooth, knownMetrics = null, isCurrent = this.#geometryOwner()) {
        isCurrent = this.#geometryOwner(isCurrent)
        await this.#awaitDirection();
        if (!isCurrent()) return null
        const scroll = async () => {
            if (!isCurrent()) return null
            this.#cachedStart = null;
            const element = this.#container
            const scrollProp = await this.scrollProp()
            if (!isCurrent()) return null
            const metrics = knownMetrics || await this.pageMetrics()
            if (!isCurrent()) return null
            const size = metrics.size
            const atStart = this.#adjacentIndex(-1) == null && metrics.page <= 1
            const atEnd = this.#adjacentIndex(1) == null && metrics.page >= metrics.pages - 2
            if (element[scrollProp] === offset) {
                this.#scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size]
                await this.#afterScroll(reason, isCurrent)
                return
            }
            // FIXME: vertical-rl only, not -lr
            if (this.scrolled && this.#vertical) offset = -offset
            if ((reason === 'snap' || smooth) && this.hasAttribute('animated')) return animate(
                element[scrollProp], offset, 300, easeOutQuad,
                x => { if (isCurrent()) element[scrollProp] = x },
            ).then(async () => {
                if (!isCurrent()) return null
                this.#scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size]
                await this.#afterScroll(reason, isCurrent)
            })
            else {
                element[scrollProp] = offset
                this.#scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size]
                await this.#afterScroll(reason, isCurrent)
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
        return this.#runScrollFrame(isCurrent, async () => {
            const shouldFade = !(reason === 'page' || reason === 'snap' || reason === 'anchor' || reason === 'selection' || reason === 'navigation')
            if (shouldFade) this.#container.classList.add('view-fade')
            const result = await scroll()
            if (!isCurrent()) return null
            if (shouldFade) {
                this.#container.classList.remove('view-faded')
                this.#container.classList.remove('view-fade')
            }
            return result
        })
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
    async #scrollToPage(page, reason, smooth, knownMetrics = null, isCurrent = this.#geometryOwner()) {
        isCurrent = this.#geometryOwner(isCurrent)
        const metrics = knownMetrics || await this.pageMetrics()
        if (!isCurrent()) return null
        const targetPage = manabiNormalizeSingleMediaPageTarget({
            page,
            pages: metrics.pages,
            isSingleMedia: this.#isSingleMediaElementWithoutText(),
        })
        const offset = metrics.size * (this.#rtl ? -targetPage : targetPage)
        return await this.#scrollTo(offset, reason, smooth, metrics, isCurrent)
    }
    async scrollToAnchor(anchor, select) {
        const command = this.#beginPositionCommand()
        try {
            //            await new Promise(resolve => requestAnimationFrame(resolve));
            return await this.#scrollToAnchor(anchor, select ? 'selection' : 'navigation',
                () => this.#isPositionCommandCurrent(command))
        } finally { command.finish() }
    }
    // TODO: Fix newer way and stop using this one that calculates getClientRects
    async #scrollToAnchor(anchor, reason = 'anchor', isCurrent = this.#geometryOwner()) {
        isCurrent = this.#geometryOwner(isCurrent)
        if (!isCurrent()) return null
        //        console.log('#scrollToAnchor0...', anchor)
        this.#anchor = anchor
        const rects = uncollapse(anchor)?.getClientRects?.()
        // if anchor is an element or a range
        if (rects) {
            // when the start of the range is immediately after a hyphen in the
            // previous column, there is an extra zero width rect in that column
            const rect = Array.from(rects)
                .find(r => r.width > 0 && r.height > 0) || rects[0]
            if (!rect) return
            return await this.#scrollToRect(rect, reason, isCurrent)
        }
        // if anchor is a fraction
        const metrics = await this.pageMetrics()
        if (!isCurrent()) return null
        if (this.scrolled) {
            return await this.#scrollTo(anchor * metrics.viewSize, reason, undefined, metrics, isCurrent)
        }
        if (!metrics.pages) return
        const textPages = metrics.pages - 2
        const newPage = Math.round(anchor * (textPages - 1))
        return await this.#scrollToPage(newPage + 1, reason, undefined, metrics, isCurrent)
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
                if (this.scrolled) {
                    await this.#scrollTo(anchor * (await this.viewSize()), reason);
                    resolve();
                    return;
                }
                const _pages = await this.pages();
                if (!_pages) {
                    resolve();
                    return;
                }
                const textPages = _pages - 2;
                const newPage = Math.round(anchor * (textPages - 1));
                await this.#scrollToPage(newPage + 1, reason);
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
    async #afterScroll(reason, isCurrent = this.#geometryOwner()) {
        if (!isCurrent() || this.#isCacheWarmer) {
            return;
        }
        //            console.log("#afterScroll...")

        this.#cachedStart = null;
        const range = await this.#getVisibleRange()
        if (!isCurrent()) return
        // don't set new anchor if relocation was to scroll to anchor
        if (reason !== 'selection' && reason !== 'navigation' && reason !== 'anchor')
            this.#anchor = range
        else this.#justAnchored = true

        const index = this.#index
        const detail = {
            reason,
            range,
            index
        }
        if ((reason === 'page' || reason === 'navigation') && this.#pendingPageTurnDirection) {
            detail.pageTurnDirection = this.#pendingPageTurnDirection;
        }

        const metrics = await this.pageMetrics()
        if (!isCurrent()) return
        if (this.scrolled) {
            detail.fraction = metrics.viewSize > 0 ? metrics.start / metrics.viewSize : 0
        } else if (metrics.pages > 0) {
            const page = metrics.page
            const pages = metrics.pages
            this.#header.style.visibility = page > 1 ? 'visible' : 'hidden'
            detail.fraction = (page - 1) / (pages - 2)
            detail.size = 1 / (pages - 2)
        }

        this.dispatchEvent(new CustomEvent('relocate', {
            detail
        }))

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
        if (logicalDirection !== 'forward' && logicalDirection !== 'backward') return null;
        const marker = {}
        this.#positionCommand = marker
        this.#positionRevision = {}
        const detail = {
            activity: marker, input, source, logicalDirection,
            chevronSide: this.#chevronSideForLogicalDirection(logicalDirection),
            isRTL: this.bookDir === 'rtl',
        }
        this.dispatchEvent(new CustomEvent('foregroundPageTurnActivity', {
            bubbles: true, composed: true, detail,
        }));
        return !this.#positionDestroyed && this.#positionCommand === marker
            && detail.isCurrent?.() !== false ? marker : null
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
    async #display(promise, isCurrent, { requiresSource = false } = {}) {
        if (!isCurrent()) {
            // Section loaders can synchronously start a successor before they
            // return their promise. Still observe any late rejection.
            void Promise.resolve(promise).catch(() => {})
            return null
        }
        const previousDisplayOwner = this.#displayOwner
        const owner = { ready: false }
        this.#displayOwner = owner
        let displayView = this.#view
        let displayDocument = null
        const ownsDisplay = () => this.#displayOwner === owner && isCurrent()
            && (this.#isCacheWarmer || (this.#view === displayView
                && (!displayDocument || displayView?.document === displayDocument)))
        //            console.log("#display...")
        this.#suspendOnExpandAnchor = false
        this.#setLoading(true, 'display.start')
        const displayStartedAt = manabiPerfNow();
        let displayError = null
        let sourceAdmitted = false
        if (!this.#isCacheWarmer) {
        }
        try {
            const {
                index,
                src,
                anchor,
                localPage,
                onLoad,
                select
            } = await promise
        if (!ownsDisplay()) return null
        if (requiresSource) {
            if (!src) throw new Error(`Missing paginator source for section ${index}`)
            sourceAdmitted = true
            // Retain the visible document until a required source is available.
            // Same-index reposition intentionally does not acquire a source.
            if (!this.#isCacheWarmer) this.style.visibility = 'hidden'
        }
        if (!this.#isCacheWarmer) {
        }

        //            console.log("#display...awaited promise")
        this.#index = index
        const hasFocus = this.#view?.document?.hasFocus?.()
        if (src) {
            const afterLoad = async (doc) => {
                if (!ownsDisplay()) return
                displayDocument = doc
                if (this.#isCacheWarmer) {
                    await onLoad?.({
                        doc,
                        location: doc?.location?.href || src,
                        index,
                    })
                } else {
                    await this.#installStyleElementsForDocument(doc)
                    if (!ownsDisplay()) return
                    applyPaginatorWritingDirectionOverride(
                        doc,
                        this.#writingDirectionOverride,
                    )
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
                const response = await fetch(src)
                if (!ownsDisplay()) return null
                const text = await response.text()
                if (!ownsDisplay()) return null
                const contentType = response.headers.get('content-type') || ''
                const parserType = /xml|xhtml/i.test(contentType)
                    ? 'application/xhtml+xml'
                    : 'text/html'
                const doc = new DOMParser().parseFromString(text, parserType)
                await afterLoad(doc)
                if (!ownsDisplay()) return null
            } else {
                this.#skipTouchEndOpacity = true
                this.#suspendOnExpandAnchor = true

                this.#cachedSizes = null
                this.#invalidateContainerGeometry()
                this.#invalidateViewGeometry()
                this.#cachedStart = null
                this.#invalidateVisibleRangeCache()

                //                console.log("#display... await load")
                const view = this.#createView()
                displayView = view
                const beforeRender = direction => this.#beforeRender(direction, view, ownsDisplay)

                if (!this.#isCacheWarmer) {
                }
                try {
                    await view.load(src, afterLoad, beforeRender, ownsDisplay)
                } catch (error) {
                    // Retiring an iframe settles its pending load immediately.
                    // Keep the selected navigation contract for an old display;
                    // current load errors and section-source errors still reject.
                    if (error?.name === 'AbortError' && !ownsDisplay()) return null
                    throw error
                }
                if (!ownsDisplay()) return null
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
                if (!ownsDisplay()) return null
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
        const normalizedLocalPage = Number.isFinite(localPage)
            ? Math.max(0, Math.round(localPage))
            : null
        // An absolute target still belongs to this display across a reflow.
        // Join that render and measure again; never lend it a newer command.
        while (ownsDisplay()) {
            await this.#waitForCurrentRender(ownsDisplay)
            if (!ownsDisplay()) return null
            const ownsGeometry = this.#geometryOwner(ownsDisplay)
            let result
            if (normalizedLocalPage !== null && !this.scrolled) {
                const metrics = await this.pageMetrics()
                if (!ownsGeometry()) continue
                const textPageCount = Math.max(1, metrics.pages - 2)
                const targetPage = Math.min(textPageCount - 1, normalizedLocalPage) + 1
                const targetLocalPage = Math.max(0, targetPage - 1)
                this.#anchor = manabiPaginatorAnchorForLocalPage({
                    localPage: targetLocalPage,
                    textPageCount,
                })
                const targetStart = metrics.size * (this.#rtl ? -targetPage : targetPage)
                const alreadyAtTargetPage =
                    Math.abs((metrics.start ?? 0) - Math.abs(targetStart)) < 0.5
                    && metrics.page === targetPage
                if (alreadyAtTargetPage) {
                    result = await this.#afterScroll('navigation', ownsGeometry)
                } else {
                    result = await this.#scrollToPage(targetPage, 'navigation', undefined, metrics, ownsGeometry)
                }
            } else {
                result = await this.#scrollToAnchor((typeof anchor === 'function' ?
                    anchor(this.#view.document) : anchor) ?? 0, select ? 'selection' : 'navigation', ownsGeometry)
            }
            if (result !== null && ownsGeometry()) break
        }
        if (!ownsDisplay()) return null
        if (!this.#isCacheWarmer && typeof anchor === 'number' && !this.scrolled) {
            const metrics = await this.pageMetrics().catch(() => null)
            if (!ownsDisplay()) return null
            const pageCurrent = metrics?.page ?? null
            const pageTotal = metrics?.pages ?? null
            const frameRect = this.#view?.element?.querySelector?.('iframe')?.getBoundingClientRect?.() ?? null
            const rootRect = this.#view?.document?.documentElement?.getBoundingClientRect?.() ?? null
            const landedPastContent = frameRect && rootRect && frameRect.bottom <= rootRect.top + 1
            if (
                typeof pageCurrent === 'number'
                && typeof pageTotal === 'number'
                && pageTotal > 2
                && (pageCurrent >= pageTotal - 1 || landedPastContent)
            ) {
                const correctedPage = Math.max(1, pageTotal - 2)
                await this.#scrollToPage(correctedPage, 'navigation', undefined, metrics, ownsDisplay)
            }
        }
        if (!ownsDisplay()) return null
        this.#suspendOnExpandAnchor = false
        if (hasFocus) this.focusView()
        if (!ownsDisplay()) return null
        if (!this.#isCacheWarmer && this.style.visibility === 'hidden') {
            this.style.visibility = 'visible'
        }
        if (!this.#isCacheWarmer) {
        }
        if (!this.#isCacheWarmer) {
        }
        owner.ready = true
        this.dispatchEvent(new CustomEvent('didDisplay', {}))
        //            console.log("#display... fin")
        } catch (error) {
            displayError = error
            throw error
        } finally {
            if (this.#displayOwner === owner) {
                this.#suspendOnExpandAnchor = false
                this.#setLoading(false, displayError ? 'display.error.finally' : 'display.complete.finally')
                if (displayError && requiresSource && !sourceAdmitted
                    && previousDisplayOwner?.ready && ownsDisplay()) {
                    this.#displayOwner = previousDisplayOwner
                }
            }
        }
    }
    #canGoToIndex(index) {
        return Number.isInteger(index) && index >= 0 && index < (this.sections?.length ?? 0)
    }
    async #goTo({
        index,
        anchor,
        localPage,
        select
    }, permitsContinuation = null) {
        const command = this.#positionCommand
        const isCurrent = permitsContinuation ?? (() =>
            !this.#positionDestroyed && this.#positionCommand === command)
        if (!isCurrent()) return null
        //        console.log("#goTo...", this.style.display, index, anchor)
        // A successor cannot reuse an iframe whose obsolete initialization
        // still owns direction/style preparation, even at the same index.
        const willLoadNewIndex = index !== this.#index
            || (this.#displayOwner != null && !this.#displayOwner.ready);
        const anchorKind = Number.isFinite(localPage)
            ? 'localPage'
            : (typeof anchor === 'function'
                ? 'function'
                : (anchor instanceof Range ? 'range' : typeof anchor));
        if (!willLoadNewIndex && anchor == null && !Number.isFinite(localPage) && !select) {
            return
        }
        const eventCommand = this.#positionCommand
        this.dispatchEvent(new CustomEvent('goTo', {
            detail: {
                willLoadNewIndex: willLoadNewIndex,
                index,
                currentIndex: this.#index,
                anchorKind,
                select: !!select,
            },
        }))
        if (!isCurrent() || (permitsContinuation == null && eventCommand !== this.#positionCommand)) return null
        if (!willLoadNewIndex) {
            try {
                const result = await this.#display({
                    index,
                    anchor,
                    localPage,
                    select
                }, isCurrent)
                if (result === null || !isCurrent()) return null
            } catch (error) {
                throw error;
            }
        } else {
            let prefetchEntry = null
            let usedPrefetchPromise = false
            if (MANABI_ENABLE_PREFETCH_WAIT_FOR_IN_FLIGHT) {
                prefetchEntry = await this.#waitForNeighborPrefetch(index)
            }
            if (!isCurrent()) return null

            const oldIndex = this.#index
            const onLoad = async (detail) => {
                if (!isCurrent()) return
                this.sections[oldIndex]?.unload?.()
                if (!isCurrent()) return

                if (!this.#isCacheWarmer) {
                    this.setStyles(this.#styles)
                }
                if (!isCurrent()) return

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
                    sectionLoadPromise = prefetchEntry.promise;
                } else {
                    sectionLoadPromise = this.sections[index].load()
                        .then(src => {
                            return src
                        })
                        .catch(error => {
                            throw error
                        });
                }
                const result = await this.#display(Promise.resolve(sectionLoadPromise)
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
                    }), isCurrent, { requiresSource: true });
                if (result === null || !isCurrent()) return null
            } catch (error) {
                throw error;
            } finally {
                if (prefetchEntry) {
                    if (usedPrefetchPromise) this.#consumeNeighborPrefetch(index, prefetchEntry)
                    else this.#releaseNeighborPrefetch(index, prefetchEntry)
                }
            }
            if (isCurrent()) this.#scheduleNeighborPrefetch('section-display')
        }
    }
    async goTo(target, { requiresPositionReceipt = false, requiresNavigationReceipt = false } = {}) {
        if (this.#locked || this.#positionDestroyed) return null
        const command = this.#beginPositionCommand()
        try {
            const resolved = await target
            if (!this.#isPositionCommandCurrent(command) || this.#locked
                || !this.#canGoToIndex(resolved?.index)) return null
            const acceptedTarget = { index: resolved.index, anchor: resolved.anchor }
            const result = await this.#goTo(resolved)
            if (!requiresPositionReceipt && !requiresNavigationReceipt) return result
            if (result === null || result === false || result?.ignored === true
                || !this.#isPositionCommandCurrent(command)
                || (requiresPositionReceipt && acceptedTarget.anchor !== 0)) return null
            const receipt = Object.freeze(acceptedTarget)
            this.#navigationReceipts.set(receipt, command)
            if (requiresPositionReceipt) this.#positionReceipts.set(receipt, command)
            return receipt
        } finally { command.finish() }
    }
    async #scrollPrev(distance, knownMetrics = null, isCurrent = this.#geometryOwner()) {
        if (!this.#view) return true
        const metrics = knownMetrics || await this.pageMetrics()
        if (!isCurrent()) return null
        if (this.scrolled) {
            const style = getComputedStyle(this.#container);
            const lineAdvance = this.#vertical ?
                parseFloat(style.fontSize) || 20 :
                parseFloat(style.lineHeight) || 20;
            const scrollDistance = distance ?? (metrics.size - lineAdvance);
            if (metrics.start > 0) {
                return await this.#scrollTo(Math.max(0, metrics.start - scrollDistance), null, true, metrics, isCurrent);
            }
            return true;
        }
        const previousSectionIndex = this.#adjacentIndex(-1)
        if (previousSectionIndex == null && metrics.page <= 1) return false
        const boundaryDecision = manabiPageTurnBoundaryDecision({
            currentPage: metrics.page,
            pageCount: metrics.pages,
            step: -1,
            adjacentIndex: previousSectionIndex,
        })
        if (boundaryDecision.shouldGoToAdjacentSection) return true
        const page = await this.#resolveBlankPageTarget(boundaryDecision.requestedPage, -1, 'page-turn.prev')
        if (!isCurrent()) return null
        return await this.#scrollToPage(page, 'page', false, metrics, isCurrent)
            .then(result => result === null ? null : boundaryDecision.crossesSection || page <= 0)
    }
    async #scrollNext(distance, knownMetrics = null, isCurrent = this.#geometryOwner()) {
        if (!this.#view) return true
        const metrics = knownMetrics || await this.pageMetrics()
        if (!isCurrent()) return null
        if (this.scrolled) {
            const style = getComputedStyle(this.#container);
            const lineAdvance = this.#vertical ?
                parseFloat(style.fontSize) || 20 :
                parseFloat(style.lineHeight) || 20;
            const scrollDistance = distance ?? (metrics.size - lineAdvance);
            if (metrics.viewSize - metrics.end > 2) {
                return await this.#scrollTo(Math.min(metrics.viewSize, metrics.start + scrollDistance), null, true, metrics, isCurrent);
            }
            return true;
        }
        const nextSectionIndex = this.#adjacentIndex(1)
        if (nextSectionIndex == null && metrics.page >= metrics.pages - 2) return false
        const boundaryDecision = manabiPageTurnBoundaryDecision({
            currentPage: metrics.page,
            pageCount: metrics.pages,
            step: 1,
            adjacentIndex: nextSectionIndex,
        })
        if (boundaryDecision.shouldGoToAdjacentSection) return true
        const page = await this.#resolveBlankPageTarget(boundaryDecision.requestedPage, 1, 'page-turn.next')
        if (!isCurrent()) return null
        return await this.#scrollToPage(page, 'page', false, metrics, isCurrent)
            .then(result => result === null ? null : boundaryDecision.crossesSection || page >= metrics.pages - 1)
    }
    async atStart() {
        const metrics = await this.pageMetrics()
        return this.#adjacentIndex(-1) == null && metrics.page <= 1
    }
    async atEnd() {
        const metrics = await this.pageMetrics()
        return this.#adjacentIndex(1) == null && metrics.page >= metrics.pages - 2
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
        if (this.#positionDestroyed || (options.positionCommand
            && !this.#isPositionCommandCurrent(options.positionCommand))) {
            options.positionCommand?.finish()
            return { ignored: true, reason: 'superseded' }
        }
        const navigationSource = globalThis.__manabiNavigationIntent?.source ?? null
        const turnStartedAt = manabiPerfNow()
        if (
            !options.bypassPostTurnDuplicateSuppression
            && this.#shouldSuppressPostPageTurnDuplicate(dir, distance, navigationSource, turnStartedAt)
        ) {
            return { ignored: true, reason: 'pageTurnDuplicateAfterSettle' }
        }
        if (this.#locked) {
            const queueDecision = manabiLockedPageTurnQueueDecision({
                pendingQueueAllowed: this.#pendingPageTurnQueueAllowed === true,
                pendingRequestedPage: this.#pendingPageTurnRequestedPage,
                pendingPageCount: this.#pendingPageTurnPageCount,
                pendingDirection: this.#pendingPageTurnDirection,
                queuedDirection: dir > 0 ? 'forward' : 'backward',
                queuedStep: dir,
                lockedElapsedMs: this.#lockedAt == null ? null : manabiPerfNow() - this.#lockedAt,
                distance,
            })
            if (!queueDecision.shouldQueue) {
                return { ignored: true, reason: queueDecision.reason }
            }
            const command = this.#beginPositionCommand()
            const previousQueuedPageTurn = this.#queuedPageTurn
            previousQueuedPageTurn?.command?.finish()
            previousQueuedPageTurn?.resolve?.({ superseded: true })
            return await new Promise((resolve, reject) => {
                this.#queuedPageTurn = { dir, distance, resolve, reject, command,
                    requiresNavigationReceipt: options.requiresNavigationReceipt,
                    foregroundActivity: options.foregroundActivity }
            })
        }

        const command = options.positionCommand ?? this.#beginPositionCommand()
        if (!this.#isPositionCommandCurrent(command)) {
            command.finish()
            return { superseded: true }
        }
        let acceptedReceipt = null
        const ownsGeometry = this.#geometryOwner()
        try {
            this.#locked = true
            this.#lockedAt = manabiPerfNow()
            this.#pendingPageTurnDirection = dir > 0 ? 'forward' : 'backward'
            this.#pendingPageTurnQueueAllowed = false
            this.#pendingPageTurnRequestedPage = null
            this.#pendingPageTurnPageCount = null
            const beforeMetrics = await this.pageMetrics().catch(() => null)
            const beforeIndex = this.#index
            const beforeAdjacentIndex = this.#adjacentIndex(dir)
            const boundaryDecision = manabiPageTurnBoundaryDecision({
                currentPage: beforeMetrics?.page,
                pageCount: beforeMetrics?.pages,
                step: dir,
                adjacentIndex: beforeAdjacentIndex,
            })
            this.#pendingPageTurnRequestedPage = boundaryDecision.requestedPage
            this.#pendingPageTurnPageCount = Number.isFinite(beforeMetrics?.pages) ? beforeMetrics.pages : null
            this.#pendingPageTurnQueueAllowed =
                Number.isFinite(boundaryDecision.requestedPage)
                && Number.isFinite(beforeMetrics?.pages)
                && !boundaryDecision.crossesSection
            try {
                if (!ownsGeometry()) return null
                const prev = dir === -1
                const scrollResult = await (prev
                    ? await this.#scrollPrev(distance, beforeMetrics, ownsGeometry)
                    : await this.#scrollNext(distance, beforeMetrics, ownsGeometry))
                if (scrollResult === null) return null
                const shouldGo = !!scrollResult
                if (shouldGo) await this.#goTo({
                    index: beforeAdjacentIndex,
                    anchor: prev ? () => 1 : () => 0,
                }, () => !this.#positionDestroyed && this.#locked)
                const ownsFinalGeometry = shouldGo ? this.#geometryOwner() : ownsGeometry
                const finalMetrics = await this.pageMetrics().catch(() => null)
                if (!ownsFinalGeometry()) return null
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
                if (shouldGo || !this.hasAttribute('animated')) await wait(100)
                if (!shouldGo) this.#scheduleNeighborPrefetch('page-turn.within-section')
                if ((options.requiresNavigationReceipt || options.foregroundActivity)
                    && this.#isPositionCommandCurrent(command) && this.#view?.document
                    && this.#canGoToIndex(this.#index)
                    && Number.isFinite(finalMetrics?.size) && finalMetrics.size > 0
                    && Number.isFinite(finalMetrics?.start)) {
                    const moved = this.#index !== beforeIndex
                        || (Number.isFinite(beforeMetrics?.page) && Number.isFinite(finalMetrics.page)
                            && finalMetrics.page !== beforeMetrics.page)
                        || (Number.isFinite(beforeMetrics?.start)
                            && Math.abs(finalMetrics.start - beforeMetrics.start) >= 1)
                    // At a proven book boundary a completed turn is a valid
                    // no-op. Ignored/queued-rejected commands never reach here.
                    const atBoundary = beforeAdjacentIndex == null && (this.scrolled
                        ? (dir < 0 ? beforeMetrics?.start <= 0
                            : beforeMetrics?.viewSize - beforeMetrics?.end <= 2)
                        : (dir < 0 ? beforeMetrics?.page <= 1
                            : beforeMetrics?.page >= beforeMetrics?.pages - 2))
                    const boundaryNoOp = atBoundary && this.#index === beforeIndex
                        && Number.isFinite(beforeMetrics?.start)
                        && Math.abs(finalMetrics.start - beforeMetrics.start) < 1
                    if (moved || boundaryNoOp) {
                        acceptedReceipt = Object.freeze({ index: this.#index, moved })
                        this.#navigationReceipts.set(acceptedReceipt, command)
                    }
                }
            } finally {
                this.#pendingPageTurnDirection = null
                this.#pendingPageTurnQueueAllowed = false
                this.#pendingPageTurnRequestedPage = null
                this.#pendingPageTurnPageCount = null
                this.#locked = false
                this.#lockedAt = null
                const queuedPageTurn = this.#queuedPageTurn
                this.#queuedPageTurn = null
                if (queuedPageTurn) {
                    queueMicrotask(() => {
                        this.#turnPage(
                            queuedPageTurn.dir,
                            queuedPageTurn.distance,
                            { bypassPostTurnDuplicateSuppression: true, positionCommand: queuedPageTurn.command,
                                requiresNavigationReceipt: queuedPageTurn.requiresNavigationReceipt,
                                foregroundActivity: queuedPageTurn.foregroundActivity }
                        )
                            .then(value => queuedPageTurn.resolve?.(value))
                            .catch(error => queuedPageTurn.reject?.(error))
                    })
                }
            }
        } finally { command.finish() }
        if (acceptedReceipt && this.isNavigationReceiptCurrent(acceptedReceipt)
            && options.foregroundActivity) {
            this.dispatchEvent(new CustomEvent('foregroundNavigationAccepted', {
                detail: { activity: options.foregroundActivity, receipt: acceptedReceipt },
            }))
        }
        if (options.requiresNavigationReceipt) {
            return this.isNavigationReceiptCurrent(acceptedReceipt) ? acceptedReceipt : null
        }
    }
    async prev(distance, options) {
        return await this.#turnPage(-1, distance, options)
    }
    async next(distance, options) {
        return await this.#turnPage(1, distance, options)
    }
    async prevSection(options) {
        return await this.goTo({
            index: this.#adjacentIndex(-1)
        }, options)
    }
    async nextSection(options) {
        return await this.goTo({
            index: this.#adjacentIndex(1)
        }, options)
    }
    async firstSection() {
        const index = this.sections.findIndex(section => section.linear !== 'no')
        return await this.goTo({
            index
        })
    }
    async lastSection() {
        let index = -1
        for (let candidate = this.sections.length - 1; candidate >= 0; candidate -= 1) {
            if (this.sections[candidate].linear !== 'no') {
                index = candidate
                break
            }
        }
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
    setWritingDirectionOverride(value) {
        const writingDirection = normalizePaginatorWritingDirection(value)
        const finish = this.#beginPositionActivity()
        this.#writingDirectionOverride = writingDirection
        const update = this.#writingDirectionUpdate.then(
            () => this.#applyWritingDirectionOverride(writingDirection),
        ).finally(finish)
        this.#writingDirectionUpdate = update.catch(() => {})
        return update
    }
    async #applyWritingDirectionOverride(writingDirection) {
        const view = this.#view
        const doc = view?.document
        if (!doc) return { rendered: false, writingDirection }

        applyPaginatorWritingDirectionOverride(doc, writingDirection)
        const direction = await resolvedPaginatorDirectionForDocument(doc)
        if (view !== this.#view || doc !== this.#view?.document) {
            return { rendered: false, reason: 'replaced', writingDirection }
        }

        const changed =
            direction.vertical !== this.#vertical
            || direction.verticalRTL !== this.#verticalRTL
            || direction.rtl !== this.#rtl
        this.#vertical = direction.vertical
        this.#verticalRTL = direction.verticalRTL
        this.#rtl = direction.rtl
        if (!changed) return { rendered: false, reason: 'unchanged', writingDirection }

        view.setDirection(direction)
        this.#cachedSizes = null
        this.#invalidateContainerGeometry()
        this.#cachedStart = null
        this.#invalidateViewGeometry()
        this.#view.cachedViewSize = null
        this.#view.cachedSizes = null
        this.#invalidateVisibleRangeCache()
        await this.render()
        return { rendered: true, writingDirection }
    }
    setStyles(styles) {
        const finish = this.#beginPositionActivity()
        try {
            this.#styles = styles
            this.#applyStylesToDocument(this.#view?.document, styles)

            //        // NOTE: needs `requestAnimationFrame` in Chromium
            //        requestAnimationFrame(() =>
            //            this.#background.style.background = getBackground(this.#view.document))

            // needed because the resize observer doesn't work in Firefox
            //            this.#view?.document?.fonts?.ready?.then(async () => { await this.#view.expand() })
        } finally { finish() }
    }
    async setBookContentStyles(stylesPromise) {
        const finish = this.#beginPositionActivity()
        try {
            this.#bookContentStylesPromise = Promise.resolve(stylesPromise)
            return await installBookContentStyles(this.#view?.document, this.#bookContentStylesPromise)
        } finally { finish() }
    }
    focusView() {
        this.#view?.document?.defaultView?.focus?.()
    }
    destroy() {
        this.#positionDestroyed = true
        this.#retireScrollFrames()
        this.#geometryGeneration += 1
        this.#renderGeneration += 1
        this.#invalidateContainerGeometry()
        this.#invalidateViewGeometry()
        this.#directionReadyResolve?.()
        this.#displayOwner = null
        this.#positionCommand = null
        this.#positionRevision = {}
        this.#queuedPageTurn?.command?.finish()
        this.#queuedPageTurn?.resolve?.({ superseded: true })
        this.#queuedPageTurn = null
        this.#disconnectElementVisibilityObserver()
        this.#resizeObserver.unobserve(this.#container)
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
        const metrics = await this.pageMetrics();
        if (this.scrolled) {
            return metrics.start > 0;
        }
        // If at the start page and no previous section, cannot turn
        if (metrics.page <= 1 && this.#adjacentIndex(-1) == null) return false;
        return true;
    }
    async canTurnNext() {
        if (!this.#view) return false;
        const metrics = await this.pageMetrics();
        if (this.scrolled) {
            return metrics.viewSize - metrics.end > 2;
        }
        // If at the end page and no next section, cannot turn
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
        const metrics = await this.pageMetrics();
        return metrics.page >= metrics.pages - 2;
    }
}

customElements.define('foliate-paginator', Paginator)

export { View as PaginatorContentView }
