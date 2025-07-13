
const getVisibleRange = (doc, start, end, mapRect) => {
    // first get all visible nodes
    const acceptNode = node => {
        const name = node.localName?.toLowerCase()
        // ignore all scripts, styles, and their children
        if (name === 'script' || name === 'style') return FILTER_REJECT
        if (node.nodeType === 1) {
            const { left, right } = mapRect(node.getBoundingClientRect())
            // no need to check child nodes if it's completely out of view
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
            const { left, right } = mapRect(range.getBoundingClientRect())
            // it's visible if any part of it is in view
            if (right >= start && left <= end) return FILTER_ACCEPT
        }
        return FILTER_SKIP
    }
    const walker = doc.createTreeWalker(doc.body, filter, { acceptNode })
    const nodes = []
    for (let node = walker.nextNode(); node; node = walker.nextNode())
        nodes.push(node)

    // we're only interested in the first and last visible nodes
    const from = nodes[0] ?? doc.body
    const to = nodes[nodes.length - 1] ?? from

    // find the offset at which visibility changes
    const startOffset = from.nodeType === 1 ? 0
        : bisectNode(doc, from, (a, b) => {
            const p = mapRect(getBoundingClientRect(a))
            const q = mapRect(getBoundingClientRect(b))
            if (p.right < start && q.left > start) return 0
            return q.left > start ? -1 : 1
        })
    const endOffset = to.nodeType === 1 ? 0
        : bisectNode(doc, to, (a, b) => {
            const p = mapRect(getBoundingClientRect(a))
            const q = mapRect(getBoundingClientRect(b))
            if (p.right < end && q.left > end) return 0
            return q.left > end ? -1 : 1
        })

    const range = doc.createRange()
    range.setStart(from, startOffset)
    range.setEnd(to, endOffset)
    return range
}


// TODO: "prevent spread" for column mode: https://github.com/johnfactotum/foliate-js/commit/b7ff640943449e924da11abc9efa2ce6b0fead6d

const wait = ms => new Promise(resolve => setTimeout(resolve, ms))

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

const makeRange = (doc, node, start, end = start) => {
    const range = doc.createRange()
    range.setStart(node, start)
    //    range.setEnd(node, end)
    range.setEnd(node, start)
    return range
}

// use binary search to find an offset value in a text node
const bisectNode = (doc, node, cb, start = 0, end = node.nodeValue.length) => {
    if (end - start === 1) {
        const result = cb(makeRange(doc, node, start), makeRange(doc, node, end))
        return result < 0 ? start : end
    }
    const mid = Math.floor(start + (end - start) / 2)
    const result = cb(makeRange(doc, node, start, mid), makeRange(doc, node, mid, end))
    return result < 0 ? bisectNode(doc, node, cb, start, mid) :
        result > 0 ? bisectNode(doc, node, cb, mid, end) : mid
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

// needed cause there seems to be a bug in `getBoundingClientRect()` in Firefox
// where it fails to include rects that have zero width and non-zero height
// (CSSOM spec says "rectangles [...] of which the height or width is not zero")
// which makes the visible range include an extra space at column boundaries
const getBoundingClientRect = target => {
    let top = Infinity,
        right = -Infinity,
        left = Infinity,
        bottom = -Infinity
    for (const rect of target.getClientRects()) {
        left = Math.min(left, rect.left)
        top = Math.min(top, rect.top)
        right = Math.max(right, rect.right)
        bottom = Math.max(bottom, rect.bottom)
    }
    return new DOMRect(left, top, right - left, bottom - top)
}

// Determine vertical/RTL by cloning only head and empty body in hidden iframe
const getDirection = async (sourceDoc) => {
    // 1. Clone a minimal document
    const cloneDoc = document.implementation.createHTMLDocument();

    // 2. Deep-clone the <head>, stripping unwanted styles/scripts
    const clonedHead = sourceDoc.head.cloneNode(true);
    ['manabi-font-data', 'manabi-custom-fonts'].forEach(id => {
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
    for (const {
        name,
        value
    }
        of sourceDoc.documentElement.attributes) {
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
    iframe.style.cssText = 'position:fixed;visibility:hidden;width:0;height:0;border:0;';
    document.documentElement.appendChild(iframe);
    await new Promise(resolve => {
        iframe.onload = resolve;
        iframe.src = blobUrl;
    });

    // 6. Compute writing-mode and direction
    const doc = iframe.contentDocument;
    const cs = iframe.contentWindow.getComputedStyle(doc.body);
    const writingMode = cs.writingMode;
    const direction = cs.direction;
    const vertical = writingMode === 'vertical-rl' || writingMode === 'vertical-lr';
    const verticalRTL = writingMode === 'vertical-rl';
    const rtl =
        doc.body.dir === 'rtl' ||
        direction === 'rtl' ||
        doc.documentElement.dir === 'rtl';

    // 7. Cleanup
    URL.revokeObjectURL(blobUrl);
    iframe.remove();

    return {
        vertical,
        verticalRTL,
        rtl
    };
};

//const getBackground = doc => {
//    const bodyStyle = doc.defaultView.getComputedStyle(doc.body)
//    return bodyStyle.backgroundColor === 'rgba(0, 0, 0, 0)' &&
//        bodyStyle.backgroundImage === 'none' ?
//        doc.defaultView.getComputedStyle(doc.documentElement).background :
//        bodyStyle.background
//}

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
    #hasResizerObserverTriggered = false
    #lastResizerRect = null
    #cachedContentRangeRect = null
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

        this.cachedViewSize = {
            width: newSize.width,
            height: newSize.height,
        }
        console.log("RESIZE OBS #view UPDATED... " + newSize.width + "x" + newSize.height)
        // TODO: remove lastResizerRect nowt hatw e have cachedViewSize
        this.#lastResizerRect = newSize
        this.#cachedContentRangeRect = null

        requestAnimationFrame(() => {
            this.#debouncedExpand();
        })
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
    #vertical = null
    #verticalRTL = null
    #rtl = null
    #directionReadyResolve = null;
    #directionReady = new Promise(r => (this.#directionReadyResolve = r));
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
        // Reset direction flags and promise before loading a new section
        this.#vertical = this.#verticalRTL = this.#rtl = null;
        this.#directionReady = new Promise(r => (this.#directionReadyResolve = r));
        return new Promise(async (resolve) => {
            if (this.#isCacheWarmer) {
                const doc = this.document
                await afterLoad?.(doc)
                resolve()
            } else {
                this.#iframe.addEventListener('load', async () => {
                    const doc = this.document

                    await afterLoad?.(doc)

                    // it needs to be visible for Firefox to get computed style
                    this.#iframe.style.display = 'block'

                    const direction = await getDirection(doc);
                    this.#vertical = direction.vertical;
                    this.#verticalRTL = direction.verticalRTL;
                    this.#rtl = direction.rtl;
                    this.#directionReadyResolve?.();

//                    const background = getBackground(doc)
                    this.#iframe.style.display = 'none'

                    this.#contentRange.selectNodeContents(doc.body)
                    this.#cachedContentRangeRect = null

                    this.#resizeObserver.observe(doc.body)

                    const layout = await beforeRender?.({
                        vertical: this.#vertical,
                        rtl: this.#rtl,
//                        background
                    })
                    this.#iframe.style.display = 'block'

                    await this.render(layout)

                    //                    this.#resizeObserver.observe(doc.body)
                    //                    this.#mutationObserver.observe(doc.body, {
                    //                        childList: true,
                    //                        subtree: true,
                    //                        attributes: false
                    //                    })

                    // the resize observer above doesn't work in Firefox
                    // (see https://bugzilla.mozilla.org/show_bug.cgi?id=1832939)
                    // until the bug is fixed we can at least account for font load
                    //                    doc.fonts.ready.then(async () => { await this.expand() })
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
        console.log("View render(layout)...")
        if (!layout) {
            return
        }
        this.#column = layout.flow !== 'scrolled'
        this.#layout = layout
        if (this.#column) await this.columnize(layout)
        else await this.scrolled(layout)
    }
    async scrolled({
        gap,
        columnWidth
    }) {
        await this.#awaitDirection();
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
            
            // columnize parity
            '--paginator-margin': '30px',
        })
        // columnize parity
        setStylesImportant(doc.body, {
            [vertical ? 'max-height' : 'max-width']: `${columnWidth}px`,
            'margin': 'auto',
        })
//        await this.setImageSizes()
        //        this.#debouncedExpand()
        await this.expand()
    }
    async columnize({
        width,
        height,
        gap,
        columnWidth
    }) {
        console.log("columnize...")
        await this.#awaitDirection();
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
//        await this.setImageSizes()
        // Don't infinite loop.
        //        if (!this.needsRenderForMutation) {
        await this.expand()
        //            //            this.#debouncedExpand()
        //        }
    }
    /*
    async setImageSizes() {
        await this.#awaitDirection();
        const {
            width,
            height,
            topMargin,
            bottomMargin
        } = this.#layout
        const vertical = this.#vertical
        const doc = this.document
        const availableHeight = height - topMargin - bottomMargin;
        // Add style cache for computed styles
        for (const el of doc.body.querySelectorAll('img, svg, video')) {
            // Temporarily remove our inline max-height to get the CSS value
            const previousInline = el.style.getPropertyValue('max-height')
            el.style.removeProperty('max-height')
            // Use cached computed style if available, otherwise compute and cache it
            const computed = this.#styleCache.get(el) || doc.defaultView.getComputedStyle(el)
            if (!this.#styleCache.has(el)) this.#styleCache.set(el, computed)
            const existingMaxHeight = computed.getPropertyValue('max-height')
            // Restore previous inline max-height if needed (not strictly necessary, setStylesImportant below will override)
            // (We do not restore it because setStylesImportant will always set it.)
            const maxHeightValue = (existingMaxHeight && existingMaxHeight !== 'none') ?
                `min(${existingMaxHeight}, ${availableHeight}px)` :
                `${availableHeight}px`;
            const maxWidth = computed.getPropertyValue('max-width');
            setStylesImportant(el, {
                'max-height': maxHeightValue,
                'height': 'auto',
                'max-width': vertical ?
                    `${width - topMargin - bottomMargin}px` : (maxWidth !== 'none' && maxWidth !== '0px' ? maxWidth : '100%'),
                'object-fit': 'contain',
                'page-break-inside': 'avoid',
                'break-inside': 'avoid',
                'box-sizing': 'border-box',
            });
        }
    }
     */
    async #awaitDirection() {
        if (this.#vertical === null) await this.#directionReady;
    }
    async expand() {
        return new Promise(resolve => {
            requestAnimationFrame(async () => {
                console.log("expand()...")
                //        const { documentElement } = this.document
                const documentElement = this.document?.documentElement
                if (this.#column) {
                    const side = this.#vertical ? 'height' : 'width'
                    const otherSide = this.#vertical ? 'width' : 'height'
                    const contentRect = this.#cachedContentRangeRect ?? this.#contentRange.getBoundingClientRect()
                    let contentSize
                    if (documentElement) {
                        const rootRect = documentElement.getBoundingClientRect()
                        // offset caused by column break at the start of the page
                        // which seem to be supported only by WebKit and only for horizontal writing
                        const contentStart = this.#vertical ? 0 :
                            this.#rtl ? rootRect.right - contentRect.right : contentRect.left - rootRect.left
                        contentSize = contentStart + contentRect[side]
                    } else {
                        contentSize = contentRect[side]
                    }
                    const pageCount = Math.ceil(contentSize / this.#size)
                    const expandedSize = pageCount * await this.#size
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
                    const contentSize = documentElement?.getBoundingClientRect()?.[side]
                    const expandedSize = contentSize
                    const {
                        topMargin,
                        bottomMargin
                    } = this.#layout
                    const paddingTop = `${marginTop}px`
                    const paddingBottom = `${marginBottom}px`
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
                await this.onExpand()
                resolve()
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
    destroy() {
        if (this.document) this.#resizeObserver.unobserve(this.document.body)
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
    #debouncedRender = debounce(this.render.bind(this), 333)
    #hasResizeObserverTriggered = false
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

        const old = this.#lastResizerRect
        const unchanged =
            old &&
            newSize.width === old.width &&
            newSize.height === old.height &&
            newSize.top === old.top &&
            newSize.left === old.left

        if (!unchanged) {
            this.#lastResizerRect = newSize
            this.#cachedSizes = {
                width: newSize.width,
                height: newSize.height,
            }
        }

        if (!this.#hasResizeObserverTriggered) {
            this.#hasResizeObserverTriggered = true
            return
        }

        if (unchanged) {
            return
        }

        console.log("RESIZE OBS pagiantor UPDATED... " + newSize.width + "x" + newSize.height)

        requestAnimationFrame(() => {
            this.#debouncedRender();
        })
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
    #skipTouchEndOpacity = false
    #isAdjustingSelectionHandle = false
    #wheelArmed = true // Hysteresis-based horizontal wheel paging
    #cachedSizes = null

    #visibleElements = new WeakSet()
    #visibleSentinelIDs = new Set()
    #nonVisibleElements = new WeakSet()
    #elementVisibilityObserver = null
    #elementVisibilityObserverLoading = null
    #elementVisibilityObserverLoadingResolve = null

    #elementMutationObserver = null
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
                contain: strict;
        
                /*--_gap: 7%;
                --_margin: 48px;*/
                --_gap: 4%;
                --_top-margin: 12px;
                --_bottom-margin: 32px;
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
                    /*
                    minmax(var(--_half-gap), 1fr)
                    var(--_half-gap)
                    minmax(0, calc(var(--_max-width) - var(--_gap)))
                    var(--_half-gap)
                    minmax(var(--_half-gap), 1fr);
                    */
                    var(--_side-margin)
                    1fr
                    minmax(0, calc(var(--_max-width) - var(--_gap)))
                    1fr
                    var(--_side-margin); 
                grid-template-rows:
                    minmax(var(--_top-margin), 1fr)
                    minmax(0, var(--_max-height))
                    minmax(var(--_bottom-margin), 1fr);
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
                opacity: 0;
                pointer-events: none;
            }
            /*#background {
                grid-column: 1 / -1;
                grid-row: 1 / -1;
            }*/
            #container {
                grid-column: 2 / 5;
                grid-row: 2;
                overflow: hidden;
        
                contain: strict;
                will-change: transform;
                transform: translateZ(0);
            }
            :host([flow="scrolled"]) #container {
                grid-column: 1 / -1;
                grid-row: 1 / -1;
                overflow: auto;
            }
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
            #header {
                height: var(--_top-margin);
            }
            #footer {
                height: var(--_bottom-margin);
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
        this.#background = this.#root.getElementById('background')
        this.#container = this.#root.getElementById('container')
        this.#header = this.#root.getElementById('header')
        this.#footer = this.#root.getElementById('footer')

        this.#resizeObserver.observe(this.#container)

        this.#container.addEventListener('scroll', () => this.dispatchEvent(new Event('scroll')))

        // Continuously fire relocate during scroll
        this.#container.addEventListener('scroll', debounce(async () => {
            if (this.#isLoading) return;
            if (this.scrolled && !this.#isCacheWarmer) {
                const range = await this.#getVisibleRange();
                const index = this.#index;
                let fraction = 0;
                if (this.scrolled) {
                    fraction = (await this.start()) / (await this.viewSize());
                } else if ((await this.pages()) > 0) {
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

        this.#container.addEventListener('scroll', debounce(async () => {
            if (this.scrolled) {
                if (this.#justAnchored) {
                    this.#justAnchored = false
                } else {
                    await this.#afterScroll('scroll')
                }
            }
        }, 450))
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
        console.log("onExpand...")
        this.#elementVisibilityObserverLoading = new Promise(r => (this.#elementVisibilityObserverLoadingResolve = r))
        this.#view.cachedViewSize = null
        await this.#scrollToAnchor(this.#anchor)
    }
    async #awaitDirection() {
        if (this.#vertical === null) await this.#directionReady;
    }
    #trackElementVisibilities() {
        this.#disconnectElementVisibilityObserver();

        this.#visibleSentinelIDs = new Set()
        this.#visibleElements = new WeakSet()
        this.#nonVisibleElements = new WeakSet()

        this.#elementVisibilityObserver = new IntersectionObserver(entries => {
            console.log("Interesection obs..." + entries.length)
            for (const entry of entries) {
                const el = entry.target;
                if (entry.isIntersecting) {
                    if (el.tagName === 'reader-sentinel') {
                        this.#visibleSentinelIDs.add(el.id)
                    }
                    this.#visibleElements.add(el);
                    el.classList.remove('manabi-off-screen');
                    this.#nonVisibleElements.delete(el);
                } else {
                    if (el.tagName === 'reader-sentinel') {
                        this.#visibleSentinelIDs.delete(el.id)
                    }
                    this.#nonVisibleElements.add(el);
                    el.classList.add('manabi-off-screen');
                    this.#visibleElements.delete(el);
                }
            }

            this.#elementVisibilityObserverLoadingResolve?.()
            this.#elementVisibilityObserverLoading = null
            this.#elementVisibilityObserverLoadingResolve = null
        }, {
            root: null,
            threshold: [0],
            //rootMargin: '100%'
        });

        const selector = '#reader-content > *, manabi-tracking-section, manabi-container, reader-sentinel';

        this.#elementMutationObserver = new MutationObserver(mutations => {
            for (const mutation of mutations) {
                for (const node of mutation.addedNodes) {
                    if (node instanceof Element && node.matches(selector)) {
                        this.#elementVisibilityObserver.observe(node);
                    }
                }
                for (const node of mutation.removedNodes) {
                    if (node instanceof Element && node.matches(selector)) {
                        this.#elementVisibilityObserver.unobserve(node);
                        this.#visibleElements.delete(node);
                        this.#nonVisibleElements.delete(node);
                    }
                }
            }
        });

        this.#view.document.body.querySelectorAll(selector).forEach(el => this.#elementVisibilityObserver.observe(el));
        this.#elementMutationObserver.observe(this.#view.document.body, {
            childList: true,
            subtree: true
        });
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
        let mediaElement = null;

        for (const node of container.childNodes) {
            if (node.nodeType === Node.ELEMENT_NODE) {
                const tag = node.tagName?.toLowerCase();
                const isMedia = mediaTags.includes(tag);

                if (isMedia) {
                    if (mediaElement) return false; // more than one media element
                    mediaElement = node;
                } else {
                    if (node.textContent.trim() !== '') return false;
                }
            } else if (node.nodeType === Node.TEXT_NODE && node.textContent.trim() !== '') {
                return false;
            }
        }

        return !!mediaElement;
    }
    async #beforeRender({
        vertical,
        verticalRTL,
        rtl,
//        background
    }) {
        console.log("# before render...")
        this.#vertical = vertical
        this.#verticalRTL = verticalRTL
        this.#rtl = rtl
        this.#top.classList.toggle('vertical', vertical)
        this.#directionReady = new Promise(r => (this.#directionReadyResolve = r));

        // set background to `doc` background
        // this is needed because the iframe does not fill the whole element
//        this.#background.style.background = background

        const {
            width,
            height
        } = await this.sizes()
        const size = vertical ? height : width

        const style = getComputedStyle(this.#top)
        const maxInlineSize = parseFloat(style.getPropertyValue('--_max-inline-size'))
        const maxColumnCount = parseInt(style.getPropertyValue('--_max-column-count-spread'))
        const topMargin = parseFloat(style.getPropertyValue('--_top-margin'))
        const bottomMargin = parseFloat(style.getPropertyValue('--_bottom-margin'))
        this.#topMargin = topMargin
        this.#bottomMargin = bottomMargin

        this.#view.document.documentElement.style.setProperty('--_max-inline-size', maxInlineSize)
        
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
                topMargin,
                bottomMargin,
                gap,
                columnWidth
            }
        }

        let divisor, columnWidth
        if (this.#isSingleMediaElementWithoutText()) {
            columnWidth = maxInlineSize
        } else {
            divisor = Math.min(maxColumnCount, Math.ceil(size / maxInlineSize))
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

        //        console.log("# before render... await apply sentinels")
        //        await this.#applyVisibilitySentinels()
        //        console.log("# before render... await apply sentinels...done")
        //        this.#trackElementVisibilities()

        return {
            height,
            width,
            topMargin,
            bottomMargin,
            gap,
            columnWidth
        }
    }
    async render() {
        if (!this.#view) {
            return
        }
        console.log("render()...")

        // avoid unwanted triggers
        this.#hasResizeObserverTriggered = false
        //        this.#resizeObserver.observe(this.#container);

        try {
            await this.#view.render(await this.#beforeRender({
                vertical: this.#vertical,
                rtl: this.#rtl,
            }))
            //            await this.#scrollToAnchor(this.#anchor) // already called via render -> ... -> expand -> onExpand
        } finally {
            this.#hasResizeObserverTriggered = false
        }
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
    async sizes() {
        await this.#awaitDirection();
        if (this.#isCacheWarmer) return 0
        if (true || this.#cachedSizes === null) {
            return new Promise(resolve => {
                requestAnimationFrame(() => {
                    const rect = this.#container.getBoundingClientRect()
                    if ((this.#cachedSizes?.width && this.#cachedSizes.width != rect.width) || (this.#cachedSizes?.height && this.#cachedSizes.height != rect.height)) {
                        console.log("Sizes(): old: " + this.#cachedSizes?.width + "x" + this.#cachedSizes?.height + "; New: " + rect.width + "x" + rect.height)
                    }
                    this.#cachedSizes = {
                        width: rect.width,
                        height: rect.height,
                    }
                    resolve(this.#cachedSizes)
                })
            })
        }
        return this.#cachedSizes
    }
    async size() {
        return (await this.sizes())[await this.sideProp()]
    }
    async viewSize() {
        await this.#awaitDirection();
        if (this.#isCacheWarmer) return 0
        if (true || this.#view.cachedViewSize === null) {
            return new Promise(resolve => {
                requestAnimationFrame(async () => {
                    const newSize = this.#view.element.getBoundingClientRect()
                    this.#view.cachedViewSize = {
                        width: newSize.width,
                        height: newSize.height,
                    }
                    resolve(this.#view.cachedViewSize[await this.sideProp()])
                })
            })
        }
        return this.#view.cachedViewSize[await this.sideProp()]
    }
    async start() {
        await this.#awaitDirection();
        return Math.abs(this.#container[await this.scrollProp()])
    }
    async end() {
        await this.#awaitDirection();
        return (await this.start()) + (await this.size())
    }
    async page() {
        await this.#awaitDirection();
        return Math.floor(((await this.start() + await this.end()) / 2) / (await this.size()))
    }
    async pages() {
        await this.#awaitDirection();
        return Math.round((await this.viewSize()) / (await this.size()))
    }
    async scrollBy(dx, dy) {
        await this.#awaitDirection();
        const delta = this.#vertical ? dy : dx
        const element = this.#container
        const scrollProp = await this.scrollProp()
        const [offset, a, b] = this.#scrollBounds
        const rtl = this.#rtl
        const min = rtl ? offset - b : offset - a
        const max = rtl ? offset + a : offset + b
        element[scrollProp] = Math.max(min, Math.min(max,
            element[scrollProp] + delta))
    }
    async snap(vx, vy) {
        await this.#awaitDirection();
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

        await this.#scrollToPage(page, 'snap').then(async () => {
            const dir = page <= 0 ? -1 : page >= pages - 1 ? 1 : null
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

        this.#updateSwipeChevron(dx, minSwipe);

        if (!state.triggered && Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > minSwipe) {
            state.triggered = true;

            if (dx < 0) {
                (this.bookDir === 'rtl') ? await this.prev() : await this.next();
            } else {
                (this.bookDir === 'rtl') ? await this.next() : await this.prev();
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
    async #getRectMapper() {
        await this.#awaitDirection();
        if (this.scrolled) {
            const size = await this.viewSize()
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
        const pxSize = (await this.pages()) * (await this.size())
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
                await this.prev();
            } else {
                await this.next();
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
        if (this.scrolled) {
            const rectMapper = await this.#getRectMapper();
            const offset = rectMapper(rect).left - this.#topMargin
            return await this.#scrollTo(offset, reason)
        }
        const rectMapper = await this.#getRectMapper();
        const offset = rectMapper(rect).left
        return await this.#scrollToPage(Math.floor(offset / (await this.size())) + (this.#rtl ? -1 : 1), reason)
    }
    async #scrollTo(offset, reason, smooth) {
        await this.#awaitDirection();
        const scroll = async () => {
            const element = this.#container
            const scrollProp = await this.scrollProp()
            const size = await this.size()
            const atStart = await this.atStart()
            const atEnd = await this.atEnd()
            if (element[scrollProp] === offset) {
                this.#scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size]
                await this.#afterScroll(reason)
                return
            }
            // FIXME: vertical-rl only, not -lr
            if (this.scrolled && this.#vertical) offset = -offset
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
        if (reason === 'snap' || reason === 'anchor' || reason === 'selection' || reason === 'navigation') {
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
    async #scrollToPage(page, reason, smooth) {
        const size = await this.size()
        const offset = size * (this.#rtl ? -page : page)
        return await this.#scrollTo(offset, reason, smooth)
    }
    async scrollToAnchor(anchor, select) {
        return await this.#scrollToAnchor(anchor, select ? 'selection' : 'navigation')
    }
    async #scrollToAnchor(anchor, reason = 'anchor') {
        await this.#awaitDirection();

        return new Promise(resolve => {
            requestAnimationFrame(async () => {
                console.log("SCROLL to ANCHOR")
                this.#anchor = anchor
                const rects = uncollapse(anchor)?.getClientRects?.()
                // if anchor is an element or a range
                if (rects) {
                    // when the start of the range is immediately after a hyphen in the
                    // previous column, there is an extra zero width rect in that column
                    const rect = Array.from(rects)
                        .find(r => r.width > 0 && r.height > 0) || rects[0]
                    if (!rect) {
                        resolve()
                        return
                    }
                    await this.#scrollToRect(rect, reason)
                    resolve()
                    return
                }
                // if anchor is a fraction
                if (this.scrolled) {
                    await this.#scrollTo(anchor * (await this.viewSize()), reason)
                    resolve()
                    return
                }
                const pages = await this.pages()
                if (!pages) {
                    resolve()
                    return
                }
                const textPages = pages - 2
                const newPage = Math.round(anchor * (textPages - 1))
                await this.#scrollToPage(newPage + 1, reason)
                resolve()
            })
        })
    }
    /**
     * Adds `reader-sentinel` to either an existing short element or an inserted span
     * every `interval` characters in the body.
     * - Short elements (<= interval characters) starting within the window are preferred.
     * - If none exist, a sentinel span is inserted at the target text offset.
     */
    async #applyVisibilitySentinels() {
        return new Promise(resolve => {
            requestAnimationFrame(() => {
                const doc = this.#view?.document;
                if (!doc) return resolve();
                const body = doc.body;

                if (body.querySelector('reader-sentinel')) {
                    // Already applied
                    return
                }

                const interval = 8;

                function findSplitOffset(text, desiredOffset, maxDistance) {
                    function category(ch) {
                        if (!ch || typeof ch !== 'string') return 'other';
                        const cp = ch.codePointAt(0);
                        if (/\s/.test(ch)) return 'ws';
                        if (/[、。．，？！：；…‥ー－「」『』【】〔〕（）［］｛｝〈〉《》“”‘’『』《》·・／＼—〜～〃々〆ゝゞ]/.test(ch)) return 'punct';
                        if ((cp >= 0x4E00 && cp <= 0x9FFF) ||
                            (cp >= 0x3400 && cp <= 0x4DBF) ||
                            (cp >= 0x20000 && cp <= 0x2A6DF) ||
                            (cp >= 0x2A700 && cp <= 0x2B73F)) return 'cjk';
                        if (cp >= 0x3040 && cp <= 0x309F) return 'hiragana';
                        if (cp >= 0x30A0 && cp <= 0x30FF) return 'katakana';
                        return 'other';
                    }
                    const len = text.length;
                    // Do not split at start or end of text node
                    if (desiredOffset <= 0 || desiredOffset >= len) return desiredOffset;

                    let bestOffset = desiredOffset;
                    let bestScore = -Infinity;

                    // Scan outward from desiredOffset (prioritize close, prefer "good" break)
                    for (let dist = 0; dist <= maxDistance; dist++) {
                        for (const offset of [desiredOffset - dist, desiredOffset + dist]) {
                            if (offset <= 0 || offset >= len) continue;
                            const ch = text[offset];
                            const prev = text[offset - 1];
                            // Prefer:
                            // - At whitespace or punctuation,
                            // - At element boundary (not directly detectable here),
                            // - At transition: kanji <-> kana, hiragana <-> katakana, kana <-> other, etc.
                            let score = 0;
                            if (/\s/.test(ch) || /\s/.test(prev)) score += 3;
                            if (/[、。．，？！：；…‥ー－「」『』【】〔〕（）［］｛｝〈〉《》“”‘’『』《》·・／＼—〜～〃々〆ゝゞ]/.test(ch) ||
                                /[、。．，？！：；…‥ー－「」『』【】〔〕（）［］｛｝〈〉《》“”‘’『』《》·・／＼—〜～〃々〆ゝゞ]/.test(prev)) score += 3;
                            if (category(prev) !== category(ch)) score += 2;
                            // Prefer to avoid splitting in the middle of CJK words (kanji->kanji)
                            if (category(prev) === 'cjk' && category(ch) === 'cjk') score -= 2;
                            // Avoid splitting mid-latin word
                            if (category(prev) === 'other' && category(ch) === 'other' &&
                                /[a-zA-Z0-9]/.test(prev) && /[a-zA-Z0-9]/.test(ch)) score -= 4;
                            // Strongly avoid start/end of node
                            if (offset === 0 || offset === len) score -= 5;
                            // Penalty for distance
                            score -= Math.abs(offset - desiredOffset) * 0.5;

                            if (score > bestScore) {
                                bestScore = score;
                                bestOffset = offset;
                            }
                            if (bestScore >= 3) break; // Early out for "good enough" score
                        }
                    }
                    return bestOffset;
                }

                var idx = 0;
                let charCount = 0;
                let nextThreshold = interval;
                // Walk only text nodes, splitting in-place for sentinel insertion
                const walker = doc.createTreeWalker(body, NodeFilter.SHOW_TEXT, null);
                let textNode;
                while ((textNode = walker.nextNode())) {
                    let remainingText = textNode.nodeValue || "";
                    let offsetInNode = 0;
                    while (charCount + (remainingText.length - offsetInNode) >= nextThreshold) {
                        const desiredOffset = nextThreshold - charCount - offsetInNode;
                        const bestOffset = findSplitOffset(remainingText, desiredOffset, interval * 2);
                        const postSplit = textNode.splitText(bestOffset);
                        const sentinel = doc.createElement("reader-sentinel")
                        sentinel.id = `reader-sentinel-${idx}`
                        idx++
                        postSplit.parentNode.insertBefore(sentinel, postSplit);
                        // Advance counters past the inserted sentinel
                        textNode = postSplit;
                        offsetInNode = 0;
                        charCount = nextThreshold;
                        nextThreshold += interval;
                        remainingText = textNode.nodeValue || "";
                    }
                    charCount += remainingText.length - offsetInNode;
                }
                resolve();
            });
        });
    }
    async #getVisibleRange() {
        await this.#awaitDirection();
        // Find the first and last visible content node, skipping <reader-sentinel> and manabi-* elements

        const doc = this.#view.document
            
        if (this.#elementVisibilityObserverLoading) {
            await this.#elementVisibilityObserverLoading
        }

        if (this.#visibleSentinelIDs.size === 0) {
            const range = doc.createRange();
            range.selectNodeContents(doc.body);
            range.collapse(true);
            return range
        }

        const isValid = node =>
            node &&
            (node.nodeType === Node.TEXT_NODE ||
                (node.nodeType === Node.ELEMENT_NODE &&
                    node.tagName !== 'reader-sentinel'));

        const visibleSentinels = doc.querySelectorAll(
            Array.from(this.#visibleSentinelIDs)
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
    async #afterScroll(reason) {
        await this.#awaitDirection();
        if (this.#isCacheWarmer) {
            return;
        }

        const range = await this.#getVisibleRange()
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
        if (this.scrolled) detail.fraction = (await this.start()) / (await this.viewSize())
        else if ((await this.pages()) > 0) {
            const page = await this.page()
            const pages = await this.pages()
            this.#header.style.visibility = page > 1 ? 'visible' : 'hidden'
            detail.fraction = (page - 1) / (pages - 2)
            detail.size = 1 / (pages - 2)
        }

        this.dispatchEvent(new CustomEvent('relocate', {
            detail
        }))

        // Force chevron visible at start of sections (now handled here, not in ebook-viewer.js)
        if (await this.isAtSectionStart()) {
            this.#skipTouchEndOpacity = true
            this.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
                bubbles: true,
                composed: true,
                detail: {
                    leftOpacity: this.bookDir === 'rtl' ? 0.999 : 0,
                    rightOpacity: this.bookDir === 'rtl' ? 0 : 0.999,
                }
            }));
        }
    }
    #updateSwipeChevron(dx, minSwipe) {
        let leftOpacity = 0,
            rightOpacity = 0;
        if (dx > 0) leftOpacity = Math.min(1, dx / minSwipe);
        else if (dx < 0) rightOpacity = Math.min(1, -dx / minSwipe);
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
        this.#isLoading = true;
        this.#top.classList.add('reader-loading');
        const {
            index,
            src,
            anchor,
            onLoad,
            select
        } = await promise
        this.#index = index
        if (src) {
            this.#skipTouchEndOpacity = true
            const view = this.#createView()

            const afterLoad = async (doc) => {
                if (doc.head) {
                    const $styleBefore = doc.createElement('style')
                    doc.head.prepend($styleBefore)
                    const $style = doc.createElement('style')
                    doc.head.append($style)
                    this.#styleMap.set(doc, [$styleBefore, $style])
                }
                await onLoad?.({
                    doc,
                    index
                })
            }
            const beforeRender = this.#beforeRender.bind(this)

            this.#cachedSizes = null

            await view.load(src, afterLoad, beforeRender)
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
        await this.scrollToAnchor((typeof anchor === 'function' ?
            anchor(this.#view.document) : anchor) ?? 0, select)
        this.#top.classList.remove('reader-loading');
        this.#isLoading = false;
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
            // Reset direction flags and promise before loading a new section
            this.#vertical = this.#verticalRTL = this.#rtl = null;
            this.#directionReady = new Promise(r => (this.#directionReadyResolve = r));
            const onLoad = async (detail) => {
                this.sections[oldIndex]?.unload?.()
                if (!this.#isCacheWarmer) {
                    this.setStyles(this.#styles)
                }

                await this.#applyVisibilitySentinels()
                this.#trackElementVisibilities()

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
                        const p = this.sections[i].load().catch(() => { });
                        this.#prefetchCache.set(i, p);
                    }
                });
            }, 500);
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
            const scrollDistance = distance ?? (this.size - lineAdvance);
            if ((await this.start()) > 0) {
                return await this.#scrollTo(Math.max(0, this.start - scrollDistance), null, true);
            }
            return true;
        }
        if (await this.atStart()) return
        const page = await this.page() - 1
        return await this.#scrollToPage(page, 'page', true).then(() => page <= 0)
    }
    async #scrollNext(distance) {
        if (!this.#view) return true
        if (this.scrolled) {
            const style = getComputedStyle(this.#container);
            const lineAdvance = this.#vertical ?
                parseFloat(style.fontSize) || 20 :
                parseFloat(style.lineHeight) || 20;
            const scrollDistance = distance ?? (this.size - lineAdvance);
            if ((await this.viewSize()) - (await this.end()) > 2) {
                return await this.#scrollTo(Math.min(await this.viewSize(), (await this.start()) + scrollDistance), null, true);
            }
            return true;
        }
        if (await this.atEnd()) return
        const page = await this.page() + 1
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
        const shouldGo = await (prev ? await this.#scrollPrev(distance) : await this.#scrollNext(distance))
        if (shouldGo) await this.#goTo({
            index: this.#adjacentIndex(dir),
            anchor: prev ? () => 1 : () => 0,
        })
        if (shouldGo || !this.hasAttribute('animated')) await wait(100)
        this.#locked = false
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
        const $$styles = this.#styleMap.get(this.#view?.document)
        if (!$$styles) return
        const [$beforeStyle, $style] = $$styles
        if (Array.isArray(styles)) {
            const [beforeStyle, style] = styles
            $beforeStyle.textContent = beforeStyle
            $style.textContent = style
        } else $style.textContent = styles

//        // NOTE: needs `requestAnimationFrame` in Chromium
//        requestAnimationFrame(() =>
//            this.#background.style.background = getBackground(this.#view.document))

        // needed because the resize observer doesn't work in Firefox
        //            this.#view?.document?.fonts?.ready?.then(async () => { await this.#view.expand() })
    }
    destroy() {
        this.#disconnectElementVisibilityObserver()
        this.#resizeObserver.unobserve(this)
        this.#view.destroy()
        this.#view = null
        this.sections[this.#index]?.unload?.()
    }
    // Public navigation edge detection methods
    async canTurnPrev() {
        if (!this.#view) return false;
        if (this.scrolled) {
            return this.start > 0;
        }
        // If at the start page and no previous section, cannot turn
        if ((await this.page()) <= 1 && this.#adjacentIndex(-1) == null) return false;
        return true;
    }
    async canTurnNext() {
        if (!this.#view) return false;
        if (this.scrolled) {
            return this.viewSize - this.end > 2;
        }
        // If at the end page and no next section, cannot turn
        if ((await this.page()) >= (await this.pages()) - 2 && this.#adjacentIndex(1) == null) return false;
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
