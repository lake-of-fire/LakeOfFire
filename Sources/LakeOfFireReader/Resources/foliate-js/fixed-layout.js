const normalizedViewport = viewport => {
    const width = Number.parseFloat(viewport?.width)
    const height = Number.parseFloat(viewport?.height)
    if (
        !Number.isFinite(width)
        || !Number.isFinite(height)
        || width <= 0
        || height <= 0
    ) return null
    return { width, height }
}

const parseViewport = source => {
    if (typeof source !== 'string') return null
    const entries = source
        .split(/[,;\s]/) // NOTE: technically, only the comma is valid
        .filter(Boolean)
        .map(value => value.split('=', 2).map(component => component.trim()))
        .filter(([key, value]) => key && value)
    if (entries.length === 0) return null
    return normalizedViewport(Object.fromEntries(entries))
}

const getViewport = (doc, viewport) => {
    // use `viewBox` for SVG
    if (doc.documentElement.nodeName === 'svg') {
        const [, , width, height] = doc.documentElement
            .getAttribute('viewBox')?.trim?.().split(/[\s,]+/) ?? []
        const svgViewport = normalizedViewport({ width, height })
        if (svgViewport) return svgViewport
    }

    // get `viewport` `meta` element
    const meta = parseViewport(doc.querySelector('meta[name="viewport"]')
        ?.getAttribute('content'))
    if (meta) return meta

    // fallback to book's viewport
    const bookViewport = typeof viewport === 'string'
        ? parseViewport(viewport)
        : normalizedViewport(viewport)
    if (bookViewport) return bookViewport

    // if no viewport (possibly with image directly in spine), get image size
    const img = doc.querySelector('img')
    const imageViewport = normalizedViewport({
        width: img?.naturalWidth,
        height: img?.naturalHeight,
    })
    if (imageViewport) return imageViewport

    // just show *something*, i guess...
    console.warn(new Error('Missing viewport properties'))
    return { width: 1000, height: 2000 }
}

export const fixedLayoutContentDescriptor = frame => frame?.iframe ? {
    index: frame.index,
    generation: frame.generation,
    doc: frame.iframe.contentDocument,
    iframe: frame.iframe,
    element: frame.element,
} : null

export class FixedLayout extends HTMLElement {
    #root = this.attachShadow({ mode: 'closed' })
    #wait = ms => new Promise(resolve => setTimeout(resolve, ms))
    #resizeObserver = new ResizeObserver(() => this.#render())
//    #mutationObserver = new MutationObserver(async () => {
//        console.log("befre...")
//        await this.#wait(100)
//        requestAnimationFrame(() => {
//        console.log("in...")
//            this.render()
//        })
////        await this.#wait(100)
////        this.#render()
//    })
    #spreads
    #index = -1
    defaultViewport
    spread
    #portrait = false
    #left
    #right
    #center
    #side
    #contentGeneration = 0
    #targetResolutionGeneration = 0
    #pendingFrameLoadCancellations = new Set()
    constructor() {
        super()

        const sheet = new CSSStyleSheet()
        this.#root.adoptedStyleSheets = [sheet]
        sheet.replaceSync(`:host {
            width: 100%;
            height: 100%;
            display: flex;
            justify-content: center;
            align-items: center;
        }`)

        this.#resizeObserver.observe(this)
//        this.#mutationObserver.observe(this.#root, { childList: true, subtree: true, attributes: true })
    }
    async #createFrame({ index, src }, generation) {
        const element = document.createElement('div')
        const iframe = document.createElement('iframe')
        element.append(iframe)
        Object.assign(iframe.style, {
            border: '0',
            display: 'none',
            overflow: 'hidden',
        })
        // `allow-scripts` is needed for events because of WebKit bug
        // https://bugs.webkit.org/show_bug.cgi?id=218086
        iframe.setAttribute('sandbox', 'allow-same-origin allow-scripts')
        iframe.setAttribute('scrolling', 'no')
        iframe.setAttribute('part', 'filter')
        this.#root.append(element)
        if (!src) return { blank: true, element, iframe, index, generation }
        return new Promise(resolve => {
            let settled = false
            let cancel
            const settle = frame => {
                if (settled) return
                settled = true
                iframe.removeEventListener('load', onload)
                this.#pendingFrameLoadCancellations.delete(cancel)
                resolve(frame)
            }
            const onload = () => {
                if (generation !== this.#contentGeneration) {
                    cancel()
                    return
                }
                const doc = iframe.contentDocument
                this.dispatchEvent(new CustomEvent('load', { detail: { doc, index } }))
                const { width, height } = getViewport(doc, this.defaultViewport)
                settle({
                    element, iframe, index, generation,
                    width: parseFloat(width),
                    height: parseFloat(height),
                })
            }
            cancel = () => {
                element.remove()
                settle({ cancelled: true, element, iframe, index, generation })
            }
            this.#pendingFrameLoadCancellations.add(cancel)
            iframe.addEventListener('load', onload)
            iframe.src = src
        })
    }
    #cancelPendingFrameLoads() {
        for (const cancel of [...this.#pendingFrameLoadCancellations]) cancel()
    }
    #render(side = this.#side) {
        if (!side) return
        const left = this.#left ?? {}
        const right = this.#center ?? this.#right
        const target = side === 'left' ? left : right
        const { width, height } = this.getBoundingClientRect()
        const portrait = this.spread !== 'both' && this.spread !== 'portrait'
            && height > width
        this.#portrait = portrait
        const blankWidth = left.width ?? right.width
        const blankHeight = left.height ?? right.height

        const scale = portrait
            ? Math.min(
                width / (target.width ?? blankWidth),
                height / (target.height ?? blankHeight))
            : Math.min(
                width / ((left.width ?? blankWidth) + (right.width ?? blankWidth)),
                height / Math.max(
                    left.height ?? blankHeight,
                    right.height ?? blankHeight))

        const transform = frame => {
            const { element, iframe, width, height } = frame
            Object.assign(iframe.style, {
                width: `${width}px`,
                height: `${height}px`,
                transform: `scale(${scale})`,
                transformOrigin: 'top left',
                display: 'block',
            })
            Object.assign(element.style, {
                width: `${(width ?? blankWidth) * scale}px`,
                height: `${(height ?? blankHeight) * scale}px`,
                overflow: 'hidden',
                display: 'block',
            })
            if (portrait && frame !== target) {
                element.style.display = 'none'
            }
        }
        if (this.#center) {
            transform(this.#center)
        } else {
            transform(left)
            transform(right)
        }
    }
    async #showSpread({ left, right, center, side }, generation) {
        if (generation !== this.#contentGeneration) return false
        this.#root.replaceChildren()
        this.#left = null
        this.#right = null
        this.#center = null
        if (center) {
            const loadedCenter = await this.#createFrame(center, generation)
            if (generation !== this.#contentGeneration) {
                loadedCenter.element.remove()
                return false
            }
            this.#center = loadedCenter
            this.#side = 'center'
            this.#render()
        } else {
            const [loadedLeft, loadedRight] = await Promise.all([
                this.#createFrame(left, generation),
                this.#createFrame(right, generation),
            ])
            if (generation !== this.#contentGeneration) {
                loadedLeft.element.remove()
                loadedRight.element.remove()
                return false
            }
            this.#left = loadedLeft
            this.#right = loadedRight
            this.#side = side
            this.#render()
        }
        return true
    }
    #goLeft() {
        if (this.#center) return
        if (this.#left?.blank) return true
        if (this.#portrait && this.#left?.element?.style?.display === 'none') {
            this.#right.element.style.display = 'none'
            this.#left.element.style.display = 'block'
            this.#side = 'left'
            return true
        }
    }
    #goRight() {
        if (this.#center) return
        if (this.#right?.blank) return true
        if (this.#portrait && this.#right?.element?.style?.display === 'none') {
            this.#left.element.style.display = 'none'
            this.#right.element.style.display = 'block'
            this.#side = 'right'
            return true
        }
    }
    open(book) {
        this.#targetResolutionGeneration += 1
        this.#contentGeneration += 1
        this.#cancelPendingFrameLoads()
        this.#index = -1
        this.#root.replaceChildren()
        this.#left = null
        this.#right = null
        this.#center = null
        this.book = book
        const { rendition } = book
        this.spread = rendition?.spread
        this.defaultViewport = rendition?.viewport

        const rtl = book.dir === 'rtl'
        const ltr = !rtl
        this.rtl = rtl

        if (rendition?.spread === 'none')
            this.#spreads = book.sections.map(section => ({ center: section }))
        else this.#spreads = book.sections.reduce((arr, section) => {
            const last = arr[arr.length - 1]
            const { linear, pageSpread } = section
            if (linear === 'no') return arr
            const newSpread = () => {
                const spread = {}
                arr.push(spread)
                return spread
            }
            if (pageSpread === 'center') newSpread().center = section
            else if (pageSpread === 'left') {
                const spread = last.center || last.left || ltr ? newSpread() : last
                spread.left = section
            }
            else if (pageSpread === 'right') {
                const spread = last.center || last.right || rtl ? newSpread() : last
                spread.right = section
            }
            else if (ltr) {
                if (last.center || last.right) newSpread().left = section
                else if (last.left) last.right = section
                else last.left = section
            }
            else {
                if (last.center || last.left) newSpread().right = section
                else if (last.right) last.left = section
                else last .right = section
            }
            return arr
        }, [{}])
    }
    get index() {
        const spread = this.#spreads[this.#index]
        const section = spread?.center ?? (this.#side === 'left'
            ? spread.left ?? spread.right : spread.right ?? spread.left)
        return this.book.sections.indexOf(section)
    }
    #reportLocation(reason) {
        this.dispatchEvent(new CustomEvent('relocate', { detail:
            { reason, range: null, index: this.index, fraction: 0, size: 1 } }))
    }
    getSpreadOf(section) {
        const spreads = this.#spreads
        for (let index = 0; index < spreads.length; index++) {
            const { left, right, center } = spreads[index]
            if (left === section) return { index, side: 'left' }
            if (right === section) return { index, side: 'right' }
            if (center === section) return { index, side: 'center' }
        }
    }
    async goToSpread(index, side, reason) {
        this.#targetResolutionGeneration += 1
        if (index < 0 || index > this.#spreads.length - 1) return
        if (index === this.#index) {
            this.#side = side
            this.#render(side)
            return
        }
        this.#index = index
        const generation = ++this.#contentGeneration
        this.#cancelPendingFrameLoads()
        const spread = this.#spreads[index]
        let didShowSpread = false
        if (spread.center) {
            const index = this.book.sections.indexOf(spread.center)
            const src = await spread.center?.load?.()
            if (generation !== this.#contentGeneration) return
            didShowSpread = await this.#showSpread({ center: { index, src } }, generation)
        } else {
            const indexL = this.book.sections.indexOf(spread.left)
            const indexR = this.book.sections.indexOf(spread.right)
            const [srcL, srcR] = await Promise.all([
                spread.left?.load?.(),
                spread.right?.load?.(),
            ])
            if (generation !== this.#contentGeneration) return
            const left = { index: indexL, src: srcL }
            const right = { index: indexR, src: srcR }
            didShowSpread = await this.#showSpread({ left, right, side }, generation)
        }
        if (didShowSpread && generation === this.#contentGeneration) {
            this.#reportLocation(reason)
        }
    }
    async select(target) {
        await this.goTo(target)
        // TODO
    }
    async goTo(target) {
        const { book } = this
        const targetResolutionGeneration = ++this.#targetResolutionGeneration
        const resolved = await target
        if (
            book !== this.book
            || targetResolutionGeneration !== this.#targetResolutionGeneration
        ) return
        const section = book.sections[resolved.index]
        if (!section) return
        const spread = this.getSpreadOf(section)
        if (!spread) return
        const { index, side } = spread
        await this.goToSpread(index, side)
    }
    async next() {
        this.#targetResolutionGeneration += 1
        const s = this.rtl ? this.#goLeft() : this.#goRight()
        if (s) this.#reportLocation('page')
        else return this.goToSpread(this.#index + 1, this.rtl ? 'right' : 'left', 'page')
    }
    async prev() {
        this.#targetResolutionGeneration += 1
        const s = this.rtl ? this.#goRight() : this.#goLeft()
        if (s) this.#reportLocation('page')
        else return this.goToSpread(this.#index - 1, this.rtl ? 'left' : 'right', 'page')
    }
    getContents() {
        return [this.#center, this.#left, this.#right]
            .map(fixedLayoutContentDescriptor)
            .filter(Boolean)
    }
    destroy() {
        this.#targetResolutionGeneration += 1
        this.#contentGeneration += 1
        this.#cancelPendingFrameLoads()
        this.#root.replaceChildren()
        this.#left = null
        this.#right = null
        this.#center = null
        this.#resizeObserver.unobserve(this)
//        this.#mutationObserver.unobserve(this.#root)
    }
}

customElements.define('foliate-fxl', FixedLayout)
