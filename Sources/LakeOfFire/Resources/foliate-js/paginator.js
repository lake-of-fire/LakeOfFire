// TODO: "prevent spread" for column mode: https://github.com/johnfactotum/foliate-js/commit/b7ff640943449e924da11abc9efa2ce6b0fead6d

const wait = ms => new Promise(resolve => setTimeout(resolve, ms))

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

const makeRange = (doc, node, start, end = start) => {
    const range = doc.createRange()
    range.setStart(node, start)
    range.setEnd(node, end)
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

const filter = SHOW_ELEMENT | SHOW_TEXT | SHOW_CDATA_SECTION

const createRAFBatcher = getter => {
    let queue = [];
    let frameRequested = false;
    return target => new Promise(resolve => {
        queue.push([target, resolve]);
        if (!frameRequested) {
            frameRequested = true;
            requestAnimationFrame(() => {
                const batch = queue;
                console.log("queue'd " + queue.length)
                queue = [];
                frameRequested = false;
                for (const [el, res] of batch) {
                    res(getter(el));
                }
            });
        }
    });
};

const asyncGetBoundingClientRect = createRAFBatcher(el => el.getBoundingClientRect());
const asyncGetClientRects = createRAFBatcher(el => el.getClientRects());

// needed cause there seems to be a bug in `getBoundingClientRect()` in Firefox
// where it fails to include rects that have zero width and non-zero height
// (CSSOM spec says "rectangles [...] of which the height or width is not zero")
// which makes the visible range include an extra space at column boundaries
const getBoundingClientRect = async target => {
    let top = Infinity,
        right = -Infinity,
        left = Infinity,
        bottom = -Infinity
    const rects = await asyncGetClientRects(target);
    for (const rect of rects) {
        left = Math.min(left, rect.left)
        top = Math.min(top, rect.top)
        right = Math.max(right, rect.right)
        bottom = Math.max(bottom, rect.bottom)
    }
    return new DOMRect(left, top, right - left, bottom - top)
}

const getVisibleRange = async (doc, start, end, mapRect) => {
    // Early‑exit, two‑phase scan:
    // 1. Walk forward until we find the first fully‑visible element.
    // 2. Keep going, updating `lastVisible`, but stop as soon as an
    //    element’s left edge is beyond `end` *and* we’ve already seen
    //    at least one visible element.  In most real pages this means
    //    we look at at most a few hundred nodes instead of tens of
    //    thousands.
    //
    // All rAF reads are batched via the helpers defined above.

    const acceptNode = async node => {
        const name = node.localName?.toLowerCase();
        if (name === 'script' || name === 'style') return FILTER_REJECT;

        if (node.nodeType === 1) {
            const {
                left,
                right
            } = mapRect(await asyncGetBoundingClientRect(node));

            // completely off‑screen
            if (right < start || left > end) return FILTER_REJECT
            // elements must be completely in view to be considered visible
            // because you can't specify offsets for elements
            if (left >= start && right <= end) return FILTER_ACCEPT
            // TODO: it should probably allow elements that do not contain text
            // because they can exceed the whole viewport in both directions
            // especially in scrolled mode
        } else {
            // ignore empty text nodes
            if (!node.nodeValue?.trim()) return FILTER_SKIP
            // create range to get rect
            const range = doc.createRange()
            range.selectNodeContents(node)
            const {
                left,
                right
            } = mapRect(range.getBoundingClientRect())
            // it's visible if any part of it is in view
            if (right >= start && left <= end) return FILTER_ACCEPT
        }
        return FILTER_SKIP
    };

    const walker = doc.createTreeWalker(
        doc.body,
        filter,
        null,
    );

    /** the first and last visible element encountered */
    let firstVisible = null;
    let lastVisible = null;

    const MAX_AFTER_LAST = 150; // how many extra nodes to check past end
    let afterLastCount = 0;

    const BATCH_SIZE = 25000;
    const batch = [];

    const flushBatch = async () => {
        if (!batch.length) return;
        // Run acceptElem on the whole batch in parallel
        const results = await Promise.all(batch.map(acceptNode));
        // Update first/last visible based on accepted results
        for (let i = 0; i < results.length; ++i) {
            if (results[i] === FILTER_ACCEPT) {
                firstVisible ??= batch[i];
                lastVisible = batch[i];
            }
        }
        // Clear batch and yield to UI
        batch.length = 0;
        await new Promise(r => setTimeout(r, 0));
    };

    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
        batch.push(n);
        if (batch.length >= BATCH_SIZE) await flushBatch();
        if (afterLastCount >= MAX_AFTER_LAST) break;
    }
    await flushBatch();

    const from = firstVisible ?? doc.body;
    const to = lastVisible ?? from;

    // Fine‑tune the exact offsets for partially‑visible text nodes
    const startOffset = from.nodeType === 1 ? 0 :
        await bisectNodeAsync(doc, from, async (a, b) => {
            const p = mapRect(await getBoundingClientRect(a));
            const q = mapRect(await getBoundingClientRect(b));
            if (p.right < start && q.left > start) return 0;
            return q.left > start ? -1 : 1;
        });

    const endOffset = to.nodeType === 1 ? 0 :
        await bisectNodeAsync(doc, to, async (a, b) => {
            const p = mapRect(await getBoundingClientRect(a));
            const q = mapRect(await getBoundingClientRect(b));
            if (p.right < end && q.left > end) return 0;
            return q.left > end ? -1 : 1;
        });

    const range = doc.createRange();
    range.setStart(from, startOffset);
    range.setEnd(to, endOffset);
    return range;
}

// use binary search to find an offset value in a text node
const bisectNodeAsync = async (doc, node, cb, start = 0, end = node.nodeValue.length) => {
    if (end - start === 1) {
        const result = await cb(makeRange(doc, node, start), makeRange(doc, node, end))
        return result < 0 ? start : end
    }
    const mid = Math.floor(start + (end - start) / 2)
    const result = await cb(makeRange(doc, node, start, mid), makeRange(doc, node, mid, end))
    return result < 0 ? bisectNodeAsync(doc, node, cb, start, mid) :
        result > 0 ? bisectNodeAsync(doc, node, cb, mid, end) : mid
}

const getDirection = doc => {
    const {
        defaultView
    } = doc
    const {
        writingMode,
        direction
    } = defaultView.getComputedStyle(doc.body)
    const vertical = writingMode === 'vertical-rl' ||
        writingMode === 'vertical-lr'
    const rtl = doc.body.dir === 'rtl' ||
        direction === 'rtl' ||
        doc.documentElement.dir === 'rtl'
    const verticalRTL = writingMode === 'vertical-rl'
    return {
        vertical,
        verticalRTL,
        rtl
    }
}

const getBackground = doc => {
    const bodyStyle = doc.defaultView.getComputedStyle(doc.body)
    return bodyStyle.backgroundColor === 'rgba(0, 0, 0, 0)' &&
        bodyStyle.backgroundImage === 'none' ?
        doc.defaultView.getComputedStyle(doc.documentElement).background :
        bodyStyle.background
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

class View {
    #wait = ms => new Promise(resolve => setTimeout(resolve, ms))
    #debouncedExpand
    //    #resizeObserver = new ResizeObserver(() => this.expand())
    #resizeObserver = new ResizeObserver(async () => {
        if (!this.#isCacheWarmer) {
            console.log("VIEW resize Observer expand...")
            this.#debouncedExpand()
        }
        //        this.expand()
    })
    //    #mutationObserver = new MutationObserver(async () => {
    //        //        return ;
    //        if (!this.#isCacheWarmer) {
    //            if (this.#column) {
    //                // TODO: Needed still?
    //                this.needsRenderForMutation = true
    //            }
    //        }
    //    })
    //    needsRenderForMutation = false
    #element = document.createElement('div')
    #iframe = document.createElement('iframe')
    #contentRange = document.createRange()
    #overlayer
    #vertical = false
    #verticalRTL = false
    #rtl = false
    #column = true
    #size
    #layout = {}
    #isCacheWarmer
    constructor({
        container,
        onExpand,
        isCacheWarmer
    }) {
        this.container = container
        this.#isCacheWarmer = isCacheWarmer
        this.#debouncedExpand = debounce(this.expand.bind(this), 999)
        this.onExpand = onExpand
        this.#iframe.setAttribute('part', 'filter')
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
            display: 'none',
            width: '100%',
            height: '100%',
        })
        // `allow-scripts` is needed for events because of WebKit bug
        // https://bugs.webkit.org/show_bug.cgi?id=218086
        this.#iframe.setAttribute('sandbox', 'allow-same-origin allow-scripts') // Breaks font-src data: blobs...
        this.#iframe.setAttribute('scrolling', 'no')
    }
    get element() {
        return this.#element
    }
    get document() {
        return this.#iframe.contentDocument
    }
    async load(src, afterLoad, beforeRender) {
        if (typeof src !== 'string') throw new Error(`${src} is not string`)
        return new Promise(resolve => {
            if (this.#isCacheWarmer) {
                const doc = this.document
                afterLoad?.(doc)
                resolve()
            } else {
                this.#iframe.addEventListener('load', async () => {
                    const doc = this.document
                    afterLoad?.(doc)

                    // it needs to be visible for Firefox to get computed style
                    this.#iframe.style.display = 'block'
                    const {
                        vertical,
                        verticalRTL,
                        rtl
                    } = getDirection(doc)
                    const background = getBackground(doc)
                    this.#iframe.style.display = 'none'

                    this.#vertical = vertical
                    this.#verticalRTL = verticalRTL
                    this.#rtl = rtl

                    this.#contentRange.selectNodeContents(doc.body)

                    const layout = beforeRender ? await beforeRender({
                        vertical,
                        verticalRTL,
                        rtl,
                        background
                    }) : undefined
                    this.#iframe.style.display = 'block'
                    await this.render(layout)

                    this.#resizeObserver.observe(doc.body)
                    //                    this.#mutationObserver.observe(doc.body, {
                    //                        childList: true,
                    //                        subtree: true,
                    //                        attributes: false
                    //                    })

                    // the resize observer above doesn't work in Firefox
                    // (see https://bugzilla.mozilla.org/show_bug.cgi?id=1832939)
                    // until the bug is fixed we can at least account for font load
                    doc.fonts.ready.then(() => this.expand())
                    //                doc.fonts.ready.then(() => this.#debouncedExpand())

                    resolve()
                }, {
                    once: true
                })
                this.#iframe.src = src
            }
        })
    }
    async render(layout) {
        if (!layout) return
        this.#column = layout.flow !== 'scrolled'
        this.#layout = layout
        if (this.#column) await this.columnize(layout)
        else await this.scrolled(layout)
    }
    async scrolled({
        gap,
        columnWidth
    }) {
        const vertical = this.#vertical
        const doc = this.document
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
            'column-gap': `${gap}px`,
            'column-fill': 'auto',
            'overflow': 'hidden',
            // force wrap long words
            'overflow-wrap': 'anywhere',
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
        // columnize parity
        doc.documentElement.style.setProperty('--paginator-margin', `30px`)
        setStylesImportant(doc.body, {
            [vertical ? 'max-height' : 'max-width']: `${columnWidth}px`,
            'margin': 'auto',
        })
        this.setImageSize()
        await new Promise(r => {
            this.#debouncedExpand()
            // small delay to allow debounced call to fire
            setTimeout(r, 0)
        })
        //this.expand()
    }
    async columnize({
        width,
        height,
        gap,
        columnWidth
    }) {
        console.log("columnize...")
        const vertical = this.#vertical
        this.#size = vertical ? height : width

        const doc = this.document
        setStylesImportant(doc.documentElement, {
            'box-sizing': 'border-box',
            'column-width': `${Math.trunc(columnWidth)}px`,
            'column-gap': `${gap}px`,
            'column-fill': 'auto',
            ...(vertical ? {
                'width': `${width}px`
            } : {
                'height': `${height}px`
            }),
            'padding': vertical ? `${gap / 2}px 0` : `0 ${gap / 2}px`,
            'overflow': 'hidden',
            // force wrap long words
            'overflow-wrap': 'break-word', // TODO: anywhere, for japanese?
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
        // Don't infinite loop.
        //        if (!this.needsRenderForMutation) {
        console.log("columnize... expand()")
        await this.expand()
        //            this.#debouncedExpand()
        //        }
    }
    setImageSize() {
        const {
            width,
            height,
            margin
        } = this.#layout
        const vertical = this.#vertical
        const doc = this.document
        for (const el of doc.body.querySelectorAll('img, svg, video')) {
            // preserve max size if they are already set, avoiding ebook stylesheet values
            const {
                maxHeight,
                maxWidth
            } = doc.defaultView.getComputedStyle(el)
            //            const maxHeight = el.style.maxHeight || 'none';
            //            const maxWidth = el.style.maxWidth || 'none';
            setStylesImportant(el, {
                'max-height': vertical ?
                    (maxHeight !== 'none' && maxHeight !== '0px' ? maxHeight : '100%') : `${height - margin * 2}px`,
                'max-width': vertical ?
                    `${width - margin * 2}px` : (maxWidth !== 'none' && maxWidth !== '0px' ? maxWidth : '100%'),
                'object-fit': 'contain',
                'page-break-inside': 'avoid',
                'break-inside': 'avoid',
                'box-sizing': 'border-box',
            })
        }
    }
    async expand() {
        console.log("expand()...")
        //        const { documentElement } = this.document
        const documentElement = this.document?.documentElement
        if (this.#column) {
            const side = this.#vertical ? 'height' : 'width'
            const otherSide = this.#vertical ? 'width' : 'height'
            const contentRect = await asyncGetBoundingClientRect(this.#contentRange);
            let contentSize
            if (documentElement) {
                const rootRect = await asyncGetBoundingClientRect(documentElement);
                // offset caused by column break at the start of the page
                // which seem to be supported only by WebKit and only for horizontal writing
                const contentStart = this.#vertical ? 0 :
                    this.#rtl ? rootRect.right - contentRect.right : contentRect.left - rootRect.left
                contentSize = contentStart + contentRect[side]
            } else {
                const cr = await asyncGetBoundingClientRect(this.#contentRange);
                contentSize = cr[side];
            }
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
            const side = this.#vertical ? 'width' : 'height'
            const otherSide = this.#vertical ? 'height' : 'width'
            const contentSize = documentElement ?
                (await asyncGetBoundingClientRect(documentElement))[side] :
                undefined;
            const expandedSize = contentSize
            const {
                margin
            } = this.#layout
            const padding = this.#vertical ? `0 ${margin}px` : `${margin}px 0`
            this.#element.style.padding = padding
            this.#iframe.style[side] = `${expandedSize}px`
            this.#element.style[side] = `${expandedSize}px`
            this.#iframe.style[otherSide] = '100%'
            this.#element.style[otherSide] = '100%'
            if (this.#overlayer) {
                this.#overlayer.element.style.margin = padding
                this.#overlayer.element.style.left = '0'
                this.#overlayer.element.style.top = '0'
                this.#overlayer.element.style[side] = `${expandedSize}px`
                this.#overlayer.redraw()
            }
        }
        await this.onExpand()
    }
    set overlayer(overlayer) {
        this.#overlayer = overlayer
        this.#element.append(overlayer.element)
    }
    get overlayer() {
        return this.#overlayer
    }
    destroy() {
        if (this.document) this.#resizeObserver.unobserve(this.document.body)
        //        if (this.document) this.#mutationObserver.disconnect()
    }
}

// NOTE: everything here assumes the so-called "negative scroll type" for RTL
export class Paginator extends HTMLElement {
    static observedAttributes = [
        'flow', 'gap', 'margin',
        'max-inline-size', 'max-block-size', 'max-column-count',
    ]
    #root = this.attachShadow({
        mode: 'closed'
    })
    #debouncedRender = debounce(this.render.bind(this), 333)
    #hasResizeObserverTriggered = false
    //    #resizeObserver = new ResizeObserver(() => this.render())
    #resizeObserver = new ResizeObserver(() => {
        if (!this.#isCacheWarmer) {
            if (!this.#hasResizeObserverTriggered) {
                //            // Skip initial observation on start
                this.#hasResizeObserverTriggered = true
                return
            }

            if (this.#isLoading) {
                this.#skippedRenderWhileWorking = true
                return
            }

            console.log("PAGINATOR resize Observer expand...")
            this.#debouncedRender()
            //        this.render()
        }
    })
    #top
    #transitioning = false;
    #background
    #container
    #header
    #footer
    #view
    #vertical = false
    #verticalRTL = false
    #rtl = false
    #margin = 0
    #index = -1
    #anchor = 0 // anchor view to a fraction (0-1), Range, or Element
    #justAnchored = false
    #locked = false // while true, prevent any further navigation
    #styles
    #styleMap = new WeakMap()
    #scrollBounds
    #touchState
    #touchScrolled
    #isCacheWarmer = false
    #prefetchTimer = null
    #prefetchCache = new Map()
    #isLoading = false
    #isRendering = false
    #skipTouchEndOpacity = false
    #isAdjustingSelectionHandle = false
    #skippedRenderWhileWorking = false
    #wheelArmed = true; // Hysteresis-based horizontal wheel paging
    constructor() {
        super()
        // narrowing gap + margin broke images, rendered too tall & scroll mode drifted (worse than usual...)
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
                /*--_gap: 7%;
                --_margin: 48px;*/
                --_gap: 4%;
                --_margin: 30px;
                --_side-margin: var(--side-nav-width, 32px);
                --_max-inline-size: 720px;
                --_max-block-size: 1440px;
                --_max-column-count: 2;
                --_max-column-count-portrait: 1;
                --_max-column-count-spread: var(--_max-column-count);
                --_half-gap: calc(var(--_gap) / 2);
                --_max-width: calc(var(--_max-inline-size) * var(--_max-column-count-spread));
                --_max-height: var(--_max-block-size);
                display: grid;
                grid-template-columns:
                    var(--_side-margin)
                    1fr
                    /*minmax(var(--_half-gap), 1fr)*/
                    /*var(--_half-gap)*/
                    minmax(0, calc(var(--_max-width) - var(--_gap)))
                    /*var(--_half-gap)*/
                    /*minmax(var(--_half-gap), 1fr)*/
                    1fr
                    var(--_side-margin);
                grid-template-rows:
                    /*minmax(var(--_margin), 1fr)*/
                    0
                    minmax(0, var(--_max-height))
                    minmax(var(--_margin), 1fr);
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
            #background {
                grid-column: 1 / -1;
                grid-row: 1 / -1;
            }
            #container {
                grid-column: 3 / 4;
                grid-row: 2;
                overflow: hidden;
            }
            :host([flow="scrolled"]) #container {
                grid-column: 1 / -1;
                grid-row: 1 / -1;
                overflow: auto;
            }
            #header {
                grid-column: 4 / 5;
                grid-row: 1;
            }
            #footer {
                grid-column: 4 / 5;
                grid-row: 3;
                align-self: end;
            }
            #header, #footer {
                display: grid;
                height: var(--_margin);
            }
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
                opacity: 0.4;
                transition: opacity 0.115s ease-out;
            }
            .view-faded {
                opacity: 0.4;
            }
        </style>
        <div id="top">
            <div id="background" part="filter"></div>
            <div id="header"></div>
            <div id="container"></div>
            <div id="footer"></div>
        </div>
        `

        this.#top = this.#root.getElementById('top')
        this.#background = this.#root.getElementById('background')
        this.#container = this.#root.getElementById('container')
        this.#header = this.#root.getElementById('header')
        this.#footer = this.#root.getElementById('footer')

        this.#resizeObserver.observe(this.#container)
        this.#container.addEventListener('scroll', () => this.dispatchEvent(new Event('scroll')))

        // Continuously fire relocate during scroll
        this.#container.addEventListener('scroll', debounce(() => {
            if (this.#isLoading) return;
            if (this.scrolled && !this.#isCacheWarmer) {
                const range = this.#getVisibleRange();
                const index = this.#index;
                let fraction = 0;
                if (this.scrolled) {
                    fraction = this.start / this.viewSize;
                } else if (this.pages > 0) {
                    const {
                        page,
                        pages
                    } = this;
                    fraction = (page - 1) / (pages - 2);
                }
                // Don't include all details, just enough for the slider
                this.dispatchEvent(new CustomEvent('relocate', {
                    detail: {
                        reason: 'live-scroll',
                        range,
                        index,
                        fraction
                    }
                }));
            }
        }, 450));

        this.#container.addEventListener('scroll', debounce(() => {
            if (this.scrolled) {
                if (this.#justAnchored) {
                    this.#justAnchored = false
                } else {
                    this.#afterScroll('scroll')
                }
            }
        }, 450))

        const opts = {
            passive: false
        }
        this.addEventListener('touchstart', this.#onTouchStart.bind(this), opts)
        this.addEventListener('touchmove', this.#onTouchMove.bind(this), opts)
        this.addEventListener('touchend', this.#onTouchEnd.bind(this))
        this.addEventListener('load', async ({
            detail: {
                doc
            }
        }) => {
            doc.addEventListener('touchstart', this.#onTouchStart.bind(this), opts)
            doc.addEventListener('touchmove', this.#onTouchMove.bind(this), opts)
            doc.addEventListener('touchend', this.#onTouchEnd.bind(this))
        })
        this.#isAdjustingSelectionHandle = false;
        this.addEventListener('wheel', this.#onWheel.bind(this), {
            passive: false
        });
    }

    open(book, isCacheWarmer) {
        this.#isCacheWarmer = isCacheWarmer
        this.bookDir = book.dir
        this.sections = book.sections
    }
    setSideNavWidth(widthPx) {
        this.#top?.style?.setProperty('--side-nav-width', typeof widthPx === 'number' ? `${widthPx}px` : widthPx);
    }
    #createView() {
        if (this.#view) {
            this.#view.destroy()
            this.#container.removeChild(this.#view.element)
        }
        this.#view = new View({
            container: this,
            onExpand: this.#onExpand.bind(this),
            isCacheWarmer: this.#isCacheWarmer,
            //            onExpand: debounce(() => this.#onExpand.bind(this), 500),
        })
        this.#container.append(this.#view.element)
        return this.#view
    }
    async #onExpand() {
        console.log('#onExpand')
        await this.#scrollToAnchor(this.#anchor)
        /*
        console.log('#onExpand call render...')
        //                this.#scrollToAnchor.bind(this),
        //        await this.#scrollToAnchor(this.#anchor);
        //        if (this.#view.needsRenderForMutation) {
        await this.#view.render(await this.#beforeRender({
            vertical: this.#vertical,
            rtl: this.#rtl,
        }));
        console.log('scrollToAnchor (needed for mutation)')
        await this.#scrollToAnchor();
        this.#view.needsRenderForMutation = false
        //        }
         */
    }
    async #beforeRender({
        vertical,
        verticalRTL,
        rtl,
        background
    }) {
        this.#vertical = vertical
        this.#verticalRTL = verticalRTL
        this.#rtl = rtl
        this.#top.classList.toggle('vertical', vertical)

        // set background to `doc` background
        // this is needed because the iframe does not fill the whole element
        this.#background.style.background = background

        const rect = await asyncGetBoundingClientRect(this.#container)
        const width = rect.width
        const height = rect.height
        const size = vertical ? height : width

        const style = getComputedStyle(this.#top)
        const maxInlineSize = parseFloat(style.getPropertyValue('--_max-inline-size'))
        const maxColumnCount = parseInt(style.getPropertyValue('--_max-column-count-spread'))
        const margin = parseFloat(style.getPropertyValue('--_margin'))
        this.#margin = margin

        const g = parseFloat(style.getPropertyValue('--_gap')) / 100
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
        const gap = -g / (g - 1) * size

        const flow = this.getAttribute('flow')
        if (flow === 'scrolled') {
            // FIXME: vertical-rl only, not -lr
            //this.setAttribute('dir', vertical ? 'rtl' : 'ltr')
            this.#top.style.padding = '0'
            const columnWidth = maxInlineSize

            this.heads = null
            this.feet = null
            this.#header.replaceChildren()
            this.#footer.replaceChildren()

            return {
                flow,
                margin,
                gap,
                columnWidth
            }
        }

        const divisor = Math.min(maxColumnCount, Math.ceil(size / maxInlineSize))
        const columnWidth = (size / divisor) - gap
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
            margin,
            gap,
            columnWidth
        }
    }
    async render() {
        if (!this.#view) return
        if (this.#isRendering) {
            this.#skippedRenderWhileWorking = true
            return
        }
        this.#isRendering = true
        console.log('render()')
        await this.#view.render(await this.#beforeRender({
            vertical: this.#vertical,
            rtl: this.#rtl,
            background: this.#background.style.background,
        }))
        await this.#scrollToAnchor(this.#anchor)
        this.#isRendering = false
        if (this.#skippedRenderWhileWorking) {
            this.#skippedRenderWhileWorking = false
            this.#debouncedRender()
        }
    }
    get scrolled() {
        return this.getAttribute('flow') === 'scrolled'
    }
    get scrollProp() {
        const {
            scrolled
        } = this
        return this.#vertical ? (scrolled ? 'scrollLeft' : 'scrollTop') :
            scrolled ? 'scrollTop' : 'scrollLeft'
    }
    get sideProp() {
        const {
            scrolled
        } = this
        return this.#vertical ? (scrolled ? 'width' : 'height') :
            scrolled ? 'height' : 'width'
    }
    async size() {
        if (this.#isCacheWarmer) {
            return 0
        }
        const rect = await asyncGetBoundingClientRect(this.#container)
        return rect[this.sideProp]
    }
    async viewSize() {
        if (this.#isCacheWarmer) {
            return 0
        }
        const rect = await asyncGetBoundingClientRect(this.#view.element)
        return rect[this.sideProp]
    }
    async start() {
        return Math.abs(this.#container[this.scrollProp])
    }
    async end() {
        return (await this.start()) + (await this.size())
    }
    async page() {
        const start = await this.start()
        const end = await this.end()
        const size = await this.size()
        return Math.floor(((start + end) / 2) / size)
    }
    async pages() {
        return Math.round((await this.viewSize()) / (await this.size()))
    }
    async scrollBy(dx, dy) {
        const delta = this.#vertical ? dy : dx
        const element = this.#container
        const scrollProp = this.scrollProp
        const [offset, a, b] = this.#scrollBounds
        const rtl = this.#rtl
        const min = rtl ? offset - b : offset - a
        const max = rtl ? offset + a : offset + b
        element[scrollProp] = Math.max(min, Math.min(max,
            element[scrollProp] + delta))
    }
    async snap(vx, vy) {
        const velocity = this.#vertical ? vy : vx
        const [offset, a, b] = this.#scrollBounds
        const start = await this.start()
        const end = await this.end()
        const pages = await this.pages()
        const size = await this.size()
        const min = Math.abs(offset) - a
        const max = Math.abs(offset) + b
        const d = velocity * (this.#rtl ? -size : size)
        const page = Math.floor(
            Math.max(min, Math.min(max, (start + end) / 2 +
                (isNaN(d) ? 0 : d))) / size)

        await this.#scrollToPage(page, 'snap')
        const dir = page <= 0 ? -1 : page >= pages - 1 ? 1 : null
        if (dir) return this.#goTo({
            index: this.#adjacentIndex(dir),
            anchor: dir < 0 ? () => 1 : () => 0,
        })
    }
    async #onTouchStart(e) {
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
                const rect = await asyncGetBoundingClientRect(range);
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
    #onTouchMove(e) {
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

        this.#updateSwipeChevron(dx, minSwipe);

        if (!state.triggered && Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > minSwipe) {
            state.triggered = true;

            if (dx < 0) {
                (this.#rtl || this.#verticalRTL) ? this.next(): this.prev();
            } else {
                (this.#rtl || this.#verticalRTL) ? this.prev(): this.next();
            }
            this.#updateSwipeChevron(dx, minSwipe)
        }
    }
    #onTouchEnd(e) {
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
                rightOpacity: ''
            }
        }))
    }
    // allows one to process rects as if they were LTR and horizontal
    #getRectMapper() {
        if (this.scrolled) {
            const size = this.viewSize
            const margin = this.#margin
            return this.#vertical ?
                ({
                    left,
                    right
                }) =>
                ({
                    left: size - right - margin,
                    right: size - left - margin
                }) :
                ({
                    top,
                    bottom
                }) => ({
                    left: top + margin,
                    right: bottom + margin
                })
        }
        const pxSize = this.pages * this.size
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
                    rightOpacity: ''
                }
            }));
            this.#lastWheelDeltaX = e.deltaX;
            return;
        }

        if (this.#wheelArmed) {
            if (Math.abs(e.deltaX) > REVEAL_CHEVRON_THRESHOLD) {
                this.#updateSwipeChevron(-e.deltaX, TRIGGER_THRESHOLD);
            } else {
                this.#updateSwipeChevron(0, TRIGGER_THRESHOLD);
            }
        }

        if (this.#wheelArmed && Math.abs(e.deltaX) > TRIGGER_THRESHOLD) {
            this.#wheelArmed = false;
            this.#wheelCooldown = true;
            if (e.deltaX > 0) {
                this.prev();
            } else {
                this.next();
            }
            this.#updateSwipeChevron(-e.deltaX, TRIGGER_THRESHOLD)
            setTimeout(() => {
                this.#wheelCooldown = false;
            }, 100);
        } else if (!this.#wheelArmed && !this.#wheelCooldown && Math.abs(e.deltaX) < RESET_THRESHOLD) {
            this.#wheelArmed = true;
        }
        this.#lastWheelDeltaX = e.deltaX;
    }
    async #scrollToRect(rect, reason) {
        console.log("scrollToRect 0")
        if (this.scrolled) {
            const offset = this.#getRectMapper()(rect).left - this.#margin
            console.log("scrollToRect 1")
            return await this.#scrollTo(offset, reason)
        }
        console.log("scrollToRect 2")
        const offset = this.#getRectMapper()(rect).left
        const size = await this.size()
        console.log("scrollToRect 3")
        return await this.#scrollToPage(Math.floor(offset / size) + (this.#rtl ? -1 : 1), reason)
    }
    async #scrollTo(offset, reason, smooth) {
        console.log("#.#scrollTo 0")
        const scroll = async () => {
            const element = this.#container
            const scrollProp = this.scrollProp
            const size = await this.size()
            const atStart = await this.atStart()
            const atEnd = await this.atEnd()
            if (element[scrollProp] === offset) {
                this.#scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size]
                await this.#afterScroll(reason)
                console.log("#.#scrollTo 16")
                return
            }
            console.log("#.#scrollTo 17")
            if (this.scrolled && this.#vertical && this.#verticalRTL) offset = -offset
            if ((reason === 'snap' || smooth) && this.hasAttribute('animated')) return animate(
                element[scrollProp], offset, 300, easeOutQuad,
                x => element[scrollProp] = x,
            ).then(async () => {
                this.#scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size]
                await this.#afterScroll(reason)
            })
            else {
                element[scrollProp] = offset
                this.#scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size]
                await this.#afterScroll(reason)
            }
        }

        if (reason === 'snap' || reason === 'anchor' || reason === 'selection' || reason === 'navigation') {
            await scroll()
        } else {
            this.#container.classList.add('view-fade')
            // Allow the browser to paint the fade
            await new Promise(r => setTimeout(r, 50));
            this.#container.classList.add('view-faded')
            await scroll()
            this.#container.classList.remove('view-faded')
            this.#container.classList.remove('view-fade')
        }
    }
    async #scrollToPage(page, reason, smooth) {
        console.log("#scrollToPage 0")
        const size = await this.size()
        console.log("#scrollToPage 1")
        const offset = size * (this.#rtl ? -page : page)
        console.log("#scrollToPage 2")
        return await this.#scrollTo(offset, reason, smooth)
    }
    async scrollToAnchor(anchor, select) {
        console.log('scrollToAnchor')
        return await this.#scrollToAnchor(anchor, select ? 'selection' : 'navigation')
    }
    async #scrollToAnchor(anchor, reason = 'anchor') {
        console.log("# scrollToAnchor 0")
        this.#anchor = anchor
        const target = uncollapse(anchor);
        let rects = null;
        if (target?.getClientRects) {
            console.log("# scrollToAnchor 1")
            rects = await asyncGetClientRects(target);
        }
        console.log("# scrollToAnchor 2")
        // if anchor is an element or a range
        if (rects) {
            // when the start of the range is immediately after a hyphen in the
            // previous column, there is an extra zero‑width rect in that column
            const rect = Array.from(rects)
                .find(r => r.width > 0 && r.height > 0) || rects[0];
            console.log("# scrollToAnchor 3")
            if (!rect) return;
            console.log("# scrollToAnchor 4")
            await this.#scrollToRect(rect, reason);
            console.log("# scrollToAnchor 5")
            return;
        }
        console.log("# scrollToAnchor 6")
        // if anchor is a fraction
        if (this.scrolled) {
            const viewSize = await this.viewSize()
            await this.#scrollTo(anchor * viewSize, reason)
            return
        }
        console.log("# scrollToAnchor 7")
        const pages = await this.pages()
        console.log("# scrollToAnchor 8")
        if (!pages) return
        const textPages = pages - 2
        const newPage = Math.round(anchor * (textPages - 1))
        await this.#scrollToPage(newPage + 1, reason)
    }
    async #getVisibleRange() {
        if (this.scrolled) {
            const start = await this.start()
            const end = await this.end()
            return await getVisibleRange(this.#view.document,
                start + this.#margin, end - this.#margin, this.#getRectMapper())
        }
        const size = this.#rtl ? -(await this.size()) : await this.size()
        const start = await this.start()
        const end = await this.end()
        return await getVisibleRange(this.#view.document,
            start - size, end - size, this.#getRectMapper())
    }
    async #afterScroll(reason) {
        if (this.#isCacheWarmer) {
            return;
        }

        console.log('#afterScrol 0')
        const range = await this.#getVisibleRange()
        console.log('#afterScrol 1')
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
        console.log('#afterScrol 2')
        if (this.scrolled) {
            const start = await this.start()
            const viewSize = await this.viewSize()
            detail.fraction = start / viewSize
        } else if ((await this.pages()) > 0) {
            console.log('#afterScrol 3')
            const page = await this.page()
            console.log('#afterScrol 4')
            const pages = await this.pages()
            console.log('#afterScrol 5')
            this.#header.style.visibility = page > 1 ? 'visible' : 'hidden'
            detail.fraction = (page - 1) / (pages - 2)
            detail.size = 1 / (pages - 2)
        }

        this.dispatchEvent(new CustomEvent('relocate', {
            detail
        }))

        console.log('#afterScrol 6')
        // Force chevron visible at start of sections (now handled here, not in ebook-viewer.js)
        if (await this.isAtSectionStart()) {
            console.log('#afterScrol 7')
            this.#skipTouchEndOpacity = true
            this.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
                bubbles: true,
                composed: true,
                detail: {
                    leftOpacity: (this.#rtl || this.#verticalRTL) ? 0 : 0.999,
                    rightOpacity: (this.#rtl || this.#verticalRTL) ? 0.999 : 0,
                }
            }));
        }
    }
    #updateSwipeChevron(dx, minSwipe) {
        let leftOpacity = 0,
            rightOpacity = 0;
        if (!(this.#rtl || this.#verticalRTL)) {
            // LTR: dx > 0 is LEFT chevron, dx < 0 is RIGHT chevron
            if (dx > 0) leftOpacity = Math.min(1, dx / minSwipe);
            else if (dx < 0) rightOpacity = Math.min(1, -dx / minSwipe);
        } else {
            // RTL: dx > 0 is RIGHT chevron, dx < 0 is LEFT chevron
            if (dx > 0) rightOpacity = Math.min(1, dx / minSwipe);
            else if (dx < 0) leftOpacity = Math.min(1, -dx / minSwipe);
        }
        this.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
            bubbles: true,
            composed: true,
            detail: {
                leftOpacity,
                rightOpacity
            }
        }));
        if (Math.abs(dx) > minSwipe) {
            // Enqueue the reset after meeting threshold
            this.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
                bubbles: true,
                composed: true,
                detail: {
                    leftOpacity: '',
                    rightOpacity: ''
                }
            }))
        }
    }
    async #display(promise) {
        console.log("# async #display")
        this.#isLoading = true;
        const {
            index,
            src,
            anchor,
            onLoad,
            select
        } = await promise
        this.#index = index
        console.log("# async #display 1")
        if (src) {
            this.#skipTouchEndOpacity = true
            const view = this.#createView()
            console.log("# async #display 2")
            const afterLoad = doc => {
                if (doc.head) {
                    const $styleBefore = doc.createElement('style')
                    doc.head.prepend($styleBefore)
                    const $style = doc.createElement('style')
                    doc.head.append($style)
                    this.#styleMap.set(doc, [$styleBefore, $style])
                }
                onLoad?.({
                    doc,
                    index
                })
            }
            console.log("# async #display 3")
            const beforeRender = this.#beforeRender.bind(this)
            console.log("# async #display 4")
            await view.load(src, afterLoad, beforeRender)
            console.log("# async #display 5")
            // Reset chevrons when loading new section
            document.dispatchEvent(new CustomEvent('resetSideNavChevrons'));
            //            this.dispatchEvent(new CustomEvent('create-overlayer', {
            //                detail: {
            //                    doc: view.document, index,
            //                    attach: overlayer => view.overlayer = overlayer,
            //                },
            //            }))
            this.#view = view
        }
        console.log("# async #display 6")
        await this.scrollToAnchor((typeof anchor === 'function' ?
            anchor(this.#view.document) : anchor) ?? 0, select)
        this.#isLoading = false;
        if (this.#skippedRenderWhileWorking) {
            this.#skippedRenderWhileWorking = false
            this.#debouncedRender()
        }
        console.log("# async #display done loading")
        this.dispatchEvent(new CustomEvent('didDisplay', {}))
    }
    #canGoToIndex(index) {
        return index >= 0 && index <= this.sections.length - 1
    }
    async #goTo({
        index,
        anchor,
        select
    }) {
        const willLoadNewIndex = index !== this.#index;
        this.dispatchEvent(new CustomEvent('goTo', {
            willLoadNewIndex: willLoadNewIndex
        }))
        if (!willLoadNewIndex) {
            await this.#display({
                index,
                anchor,
                select
            })
        } else {
            const oldIndex = this.#index
            const onLoad = detail => {
                this.sections[oldIndex]?.unload?.()
                if (!this.#isCacheWarmer) {
                    this.setStyles(this.#styles)
                }
                this.dispatchEvent(new CustomEvent('load', {
                    detail
                }))
            }

            let loadPromise;
            if (this.#prefetchCache.has(index)) {
                loadPromise = this.#prefetchCache.get(index);
            } else {
                loadPromise = this.sections[index].load();
                this.#prefetchCache.set(index, loadPromise);
            }
            await this.#display(Promise.resolve(loadPromise)
                .then(src => ({
                    index,
                    src,
                    anchor,
                    onLoad,
                    select
                }))
                .catch(error => {
                    console.error(error);
                    console.warn(new Error(`Failed to load section ${index}`));
                    return {};
                }));

            clearTimeout(this.#prefetchTimer);
            this.#prefetchTimer = setTimeout(() => {
                if (this.#index !== index) return; // bail if user has moved on

                const wanted = [index - 1, index + 1];
                // Keep any already cached of these two
                const keep = new Set(wanted.filter(i => this.#prefetchCache.has(i)));
                this.#prefetchCache = new Map(
                    [...this.#prefetchCache].filter(([i]) => keep.has(i))
                );

                // Now prefetch any neighbor not already cached
                wanted.forEach(i => {
                    if (
                        i >= 0 &&
                        i < this.sections.length &&
                        this.sections[i].linear !== 'no' &&
                        !this.#prefetchCache.has(i)
                    ) {
                        const p = this.sections[i].load().catch(() => {});
                        this.#prefetchCache.set(i, p);
                    }
                });
            }, 500);
        }
    }
    async goTo(target) {
        if (this.#locked) return
        const resolved = await target
        if (this.#canGoToIndex(resolved.index)) return this.#goTo(resolved)
    }
    async #scrollPrev(distance) {
        if (!this.#view) return true
        if (this.scrolled) {
            const style = getComputedStyle(this.#container);
            const lineAdvance = this.#vertical ?
                parseFloat(style.fontSize) || 20 :
                parseFloat(style.lineHeight) || 20;
            const size = await this.size()
            const scrollDistance = distance ?? (size - lineAdvance);
            const start = await this.start()
            if (start > 0) {
                return await this.#scrollTo(Math.max(0, start - scrollDistance), null, true);
            }
            return true;
        }
        if (await this.atStart()) return
        const page = (await this.page()) - 1
        return await this.#scrollToPage(page, 'page', true).then(() => page <= 0)
    }
    async #scrollNext(distance) {
        if (!this.#view) return true
        if (this.scrolled) {
            const style = getComputedStyle(this.#container);
            const lineAdvance = this.#vertical ?
                parseFloat(style.fontSize) || 20 :
                parseFloat(style.lineHeight) || 20;
            const size = await this.size()
            const viewSize = await this.viewSize()
            const end = await this.end()
            const scrollDistance = distance ?? (size - lineAdvance);
            if (viewSize - end > 2) {
                const start = await this.start()
                return await this.#scrollTo(Math.min(viewSize, start + scrollDistance), null, true);
            }
            return true;
        }
        if (await this.atEnd()) return
        const page = (await this.page()) + 1
        const pages = await this.pages()
        return await this.#scrollToPage(page, 'page', true).then(() => page >= pages - 1)
    }
    async atStart() {
        return this.#adjacentIndex(-1) == null && (await this.page()) <= 1
    }
    async atEnd() {
        return this.#adjacentIndex(1) == null && (await this.page()) >= (await this.pages()) - 2
    }
    #adjacentIndex(dir) {
        for (let index = this.#index + dir; this.#canGoToIndex(index); index += dir)
            if (this.sections[index]?.linear !== 'no') return index
    }
    async #turnPage(dir, distance) {
        if (this.#locked) return
        this.#locked = true
        const prev = dir === -1
        const shouldGo = await (prev ? this.#scrollPrev(distance) : this.#scrollNext(distance))
        if (shouldGo) await this.#goTo({
            index: this.#adjacentIndex(dir),
            anchor: prev ? () => 1 : () => 0,
        })
        if (shouldGo || !this.hasAttribute('animated')) await wait(100)
        this.#locked = false
    }
    prev(distance) {
        return this.#turnPage(-1, distance)
    }
    next(distance) {
        return this.#turnPage(1, distance)
    }
    prevSection() {
        return this.goTo({
            index: this.#adjacentIndex(-1)
        })
    }
    nextSection() {
        return this.goTo({
            index: this.#adjacentIndex(1)
        })
    }
    firstSection() {
        const index = this.sections.findIndex(section => section.linear !== 'no')
        return this.goTo({
            index
        })
    }
    lastSection() {
        const index = this.sections.findLastIndex(section => section.linear !== 'no')
        return this.goTo({
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
        console.log("set styles...")
        this.#styles = styles
        const $$styles = this.#styleMap.get(this.#view?.document)
        if (!$$styles) return
        const [$beforeStyle, $style] = $$styles
        if (Array.isArray(styles)) {
            const [beforeStyle, style] = styles
            $beforeStyle.textContent = beforeStyle
            $style.textContent = style
        } else $style.textContent = styles

        // NOTE: needs `requestAnimationFrame` in Chromium
        requestAnimationFrame(() =>
            this.#background.style.background = getBackground(this.#view.document))

        // needed because the resize observer doesn't work in Firefox
        this.#view?.document?.fonts?.ready?.then(() => this.#view.expand())
    }
    destroy() {
        this.#resizeObserver.unobserve(this)
        this.#view.destroy()
        this.#view = null
        this.sections[this.#index]?.unload?.()
    }
    // Public navigation edge detection methods
    canTurnPrev() {
        if (!this.#view) return false;
        if (this.scrolled) {
            return this.start > 0;
        }
        // If at the start page and no previous section, cannot turn
        if (this.page <= 1 && this.#adjacentIndex(-1) == null) return false;
        return true;
    }
    canTurnNext() {
        if (!this.#view) return false;
        if (this.scrolled) {
            return this.viewSize - this.end > 2;
        }
        // If at the end page and no next section, cannot turn
        if (this.page >= this.pages - 2 && this.#adjacentIndex(1) == null) return false;
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
        return (await this.page()) <= 1;
    }
    // Public: At last page of current section
    async isAtSectionEnd() {
        return (await this.page()) >= (await this.pages()) - 2;
    }
}

customElements.define('foliate-paginator', Paginator)
