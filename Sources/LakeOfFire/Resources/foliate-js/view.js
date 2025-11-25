import * as CFI from './epubcfi.js'
import { TOCProgress, SectionProgress } from './progress.js'

const SEARCH_PREFIX = 'foliate-search:'

// pagination logger disabled for noise reduction
const logEBookPagination = () => {}

const summarizeAnchor = anchor => {
    if (anchor == null) return 'null'
    if (typeof anchor === 'number') return `fraction:${Number(anchor).toFixed(6)}`
    if (typeof anchor === 'function') return 'function'
    if (anchor?.startContainer) return 'range'
    if (anchor?.nodeType === Node.ELEMENT_NODE) return `element:${anchor.tagName ?? 'unknown'}`
    if (anchor?.nodeType) return `nodeType:${anchor.nodeType}`
    return typeof anchor
}

const summarizeNavigationTarget = target => {
    if (!target) return null
    return {
        index: typeof target.index === 'number' ? target.index : null,
        anchor: summarizeAnchor(target.anchor),
        hasSelect: !!target.select,
        reason: target.reason ?? null,
    }
}

const postNavigationChromeVisibility = (shouldHide, { source, direction } = {}) => {
    try {
        window.webkit?.messageHandlers?.ebookNavigationVisibility?.postMessage?.({
            hideNavigationDueToScroll: !!shouldHide,
            source: source ?? null,
            direction: direction ?? null,
        });
    } catch (error) {
        console.error('Failed to notify navigation chrome visibility', error);
    }
}

class History extends EventTarget {
    #arr = []
    #index = -1
    pushState(x) {
        const last = this.#arr[this.#index]
        if (last === x || last?.fraction && last.fraction === x.fraction) return
            this.#arr[++this.#index] = x
            this.#arr.length = this.#index + 1
            this.dispatchEvent(new Event('index-change'))
            }
    replaceState(x) {
        const index = this.#index
        this.#arr[index] = x
    }
    back() {
        const index = this.#index
        if (index <= 0) return
            const detail = { state: this.#arr[index - 1] }
        this.#index = index - 1
        this.dispatchEvent(new CustomEvent('popstate', { detail }))
        this.dispatchEvent(new Event('index-change'))
    }
    forward() {
        const index = this.#index
        if (index >= this.#arr.length - 1) return
            const detail = { state: this.#arr[index + 1] }
        this.#index = index + 1
        this.dispatchEvent(new CustomEvent('popstate', { detail }))
        this.dispatchEvent(new Event('index-change'))
    }
    get canGoBack() {
        return this.#index > 0
    }
    get canGoForward() {
        return this.#index < this.#arr.length - 1
    }
    clear() {
        this.#arr = []
        this.#index = -1
    }
}

const textWalker = function* (doc, func) {
    const filter = NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT
    | NodeFilter.SHOW_CDATA_SECTION
    const { FILTER_ACCEPT, FILTER_REJECT, FILTER_SKIP } = NodeFilter
    const acceptNode = node => {
        const name = node.localName?.toLowerCase()
        if (name === 'script' || name === 'style') return FILTER_REJECT
            if (node.nodeType === 1) return FILTER_SKIP
                return FILTER_ACCEPT
                }
    const walker = doc.createTreeWalker(doc.body, filter, { acceptNode })
    const nodes = []
    for (let node = walker.nextNode(); node; node = walker.nextNode())
        nodes.push(node)
        const strs = nodes.map(node => node.nodeValue)
        const makeRange = (startIndex, startOffset, endIndex, endOffset) => {
            const range = doc.createRange()
            range.setStart(nodes[startIndex], startOffset)
            range.setEnd(nodes[endIndex], endOffset)
            return range
        }
    for (const match of func(strs, makeRange)) yield match
        }

const languageInfo = lang => {
    if (!lang) return {}
    try {
        const canonical = Intl.getCanonicalLocales(lang)[0]
        const locale = new Intl.Locale(canonical)
        const isCJK = ['zh', 'ja', 'kr'].includes(locale.language)
        const direction = (locale.getTextInfo?.() ?? locale.textInfo)?.direction
        return { canonical, locale, isCJK, direction }
    } catch (e) {
        console.warn(e)
        return {}
    }
}

export class View extends HTMLElement {
    #root = this.attachShadow({ mode: 'closed' })
    #sectionProgress
    #tocProgress
    #pageProgress
    #isCacheWarmer
    #searchResults = new Map()
    isFixedLayout = false
    lastLocation
    history = new History()
    constructor() {
        super()
        this.history.addEventListener('popstate', async ({ detail }) => {
            const resolved = this.resolveNavigation(detail.state)
            await this.renderer.goTo(resolved)
        })
    }
    async open(book, isCacheWarmer) {
        this.book = book
        this.language = languageInfo(book.metadata?.language)
        this.#isCacheWarmer = isCacheWarmer
        
        if (book.splitTOCHref && book.getTOCFragment) {
            const ids = book.sections.map(s => s.id)
            this.#sectionProgress = new SectionProgress(book.sections, 1500, 1600)
            const splitHref = book.splitTOCHref.bind(book)
            const getFragment = book.getTOCFragment.bind(book)
            this.#tocProgress = new TOCProgress({
                toc: book.toc ?? [], ids, splitHref, getFragment })
            this.#pageProgress = new TOCProgress({
                toc: book.pageList ?? [], ids, splitHref, getFragment })
        }
        
        this.isFixedLayout = this.book.rendition?.layout === 'pre-paginated'
        if (this.isFixedLayout) {
            await import('./fixed-layout.js')
            this.renderer = document.createElement('foliate-fxl')
        } else {
            await import('./paginator.js')
            this.renderer = document.createElement('foliate-paginator')
        }
        this.renderer.setAttribute('exportparts', 'head,foot') //,filter')
        this.renderer.addEventListener('load', e => this.#onLoad(e.detail))
        this.renderer.addEventListener('relocate', e => this.#onRelocate(e.detail))
        // Overlayer support removed
        
        this.renderer.open(book, isCacheWarmer)
        this.#root.append(this.renderer)
    }
    close() {
        this.renderer?.destroy()
        this.renderer?.remove()
        this.#sectionProgress = null
        this.#tocProgress = null
        this.#pageProgress = null
        this.#searchResults = new Map()
        this.lastLocation = null
        this.history.clear()
    }
    async goToTextStart() {
        return await this.goTo(this.book.landmarks
                               ?.find(m => m.type.includes('bodymatter') || m.type.includes('text'))
                               ?.href ?? this.book.sections.findIndex(s => s.linear !== 'no'))
    }
    async init({ lastLocation, showTextStart }) {
        const resolved = lastLocation ? this.resolveNavigation(lastLocation) : null
        if (resolved) {
            await this.renderer.goTo(resolved)
            this.history.pushState(lastLocation)
        }
        else if (showTextStart) {
            await this.goToTextStart()
        } else {
            this.history.pushState(0)
            await this.next()
        }
    }
    #emit(name, detail, cancelable) {
        return this.dispatchEvent(new CustomEvent(name, { detail, cancelable }))
    }
    #onRelocate({ reason, range, index, fraction, size }) {
        const progress = this.#sectionProgress?.getProgress(index, fraction, size) ?? {}
        const tocItem = this.#tocProgress?.getProgress(index, range)
        const pageItem = this.#pageProgress?.getProgress(index, range)
        const cfi = this.getCFI(index, range)
        this.lastLocation = { ...progress, tocItem, pageItem, cfi, range, reason }
        if (reason === 'snap' || reason === 'page' || reason === 'scroll')
            this.history.replaceState(cfi)
            this.#emit('relocate', this.lastLocation)
            }
    #onLoad({ doc, location, index }) {
        if (!this.#isCacheWarmer) {
            // set language and dir if not already set
            doc.documentElement.lang ||= this.language.canonical ?? ''
            if (!this.language.isCJK)
                doc.documentElement.dir ||= this.language.direction ?? ''
                
                this.#handleLinks(doc, index)
                }
        this.#emit('load', { doc, location, index })
    }
    #handleLinks(doc, index) {
        const { book } = this
        const section = book.sections[index]
        for (const a of doc.querySelectorAll('a[href]'))
            a.addEventListener('click', e => {
                e.preventDefault()
                const href_ = a.getAttribute('href')
                const href = section?.resolveHref?.(href_) ?? href_
                if (book?.isExternal?.(href))
                    Promise.resolve(this.#emit('external-link', { a, href }, true))
                    .then(x => x ? globalThis.open(href, '_blank') : null)
                    .catch(e => console.error(e))
                    else Promise.resolve(this.#emit('link', { a, href }, true))
                        .then(async x => x ? await this.goTo(href) : null)
                        .catch(e => console.error(e))
                        })
            }
    async addAnnotation(annotation, _remove) {
        const { value } = annotation
        const resolved = await this.resolveNavigation(value.startsWith?.(SEARCH_PREFIX) ? value.replace(SEARCH_PREFIX, '') : value)
        const index = resolved?.index
        const label = typeof index === 'number' ? (this.#tocProgress?.getProgress(index)?.label ?? '') : ''
        return { index, label }
    }
    deleteAnnotation(annotation) {
        return this.addAnnotation(annotation, true)
    }
    #getOverlayer(_index) {
        return null
    }
    #createOverlayer(_detail) {
        return null
    }
    async showAnnotation(_annotation) {
        return
    }
    getCFI(index, range) {
        const baseCFI = this.book.sections[index].cfi ?? CFI.fake.fromIndex(index)
        if (!range) return baseCFI
            return CFI.joinIndir(baseCFI, CFI.fromRange(range))
            }
    resolveCFI(cfi) {
        if (this.book.resolveCFI)
            return this.book.resolveCFI(cfi)
            else {
                const parts = CFI.parse(cfi)
                const index = CFI.fake.toIndex((parts.parent ?? parts).shift())
                const anchor = doc => CFI.toRange(doc, parts)
                return { index, anchor }
            }
    }
    resolveNavigation(target) {
        try {
            if (typeof target === 'number') {
                return { index: target }
            }
            if (typeof target.fraction === 'number') {
                const [index, anchor] = this.#sectionProgress.getSection(target.fraction)
                return { index, anchor }
            }
            if (CFI.isCFI.test(target)) {
                return this.resolveCFI(target)
            }
            return this.book.resolveHref(target)
        } catch (e) {
            console.error(e)
            console.error(`Could not resolve target ${target}`)
        }
    }
    async goTo(target) {
        //        this.#emit('is-loading', true)
        const resolved = this.resolveNavigation(target)
        try {
            await this.renderer.goTo(resolved)
            this.history.pushState(target)
            return resolved
        } catch(e) {
            console.error(e)
            console.error(`Could not go to ${target}`)
            throw e
            //            return
        }
        //        this.#emit('is-loading', false)
        //        return resolved
    }
    async goToFraction(frac) {
        const [index, anchor] = this.#sectionProgress.getSection(frac)
        await this.renderer.goTo({ index, anchor })
        this.history.pushState({ fraction: frac })
    }
    async select(target) {
        try {
            const obj = await this.resolveNavigation(target)
            await this.renderer.goTo({ ...obj, select: true })
            this.history.pushState(target)
        } catch(e) {
            console.error(e)
            console.error(`Could not go to ${target}`)
        }
    }
    deselect() {
        for (const { doc } of this.renderer.getContents())
            doc.defaultView.getSelection().removeAllRanges()
            }
    async getTOCItemOf(target) {
        try {
            const { index, anchor } = await this.resolveNavigation(target)
            const doc = await this.book.sections[index].createDocument()
            const frag = anchor(doc)
            const isRange = frag instanceof Range
            const range = isRange ? frag : doc.createRange()
            if (!isRange) range.selectNodeContents(frag)
                return this.#tocProgress.getProgress(index, range)
                } catch(e) {
                    console.error(e)
                    console.error(`Could not get ${target}`)
                }
    }
    async prev(distance) {
        await this.renderer.prev(distance)
    }
    async next(distance) {
        await this.renderer.next(distance)
    }
    async goLeft() {
        const isForward = this.book.dir === 'rtl'
        if (!this.#isCacheWarmer) {
            postNavigationChromeVisibility(isForward, {
                source: 'swipe-left',
                direction: isForward ? 'forward' : 'backward'
            })
        }
        return this.book.dir === 'rtl' ? await this.next() : await this.prev()
    }
    async goRight() {
        const isForward = this.book.dir !== 'rtl'
        if (!this.#isCacheWarmer) {
            postNavigationChromeVisibility(isForward, {
                source: 'swipe-right',
                direction: isForward ? 'forward' : 'backward'
            })
        }
        return this.book.dir === 'rtl' ? await this.prev() : await this.next()
    }
    async * #searchSection(matcher, query, index) {
        const doc = await this.book.sections[index].createDocument()
        for (const { range, excerpt } of matcher(doc, query))
            yield { cfi: this.getCFI(index, range), excerpt }
    }
    async * #searchBook(matcher, query) {
        const { sections } = this.book
        for (const [index, { createDocument }] of sections.entries()) {
            if (!createDocument) continue
                const doc = await createDocument()
                const subitems = Array.from(matcher(doc, query), ({ range, excerpt }) =>
                                            ({ cfi: this.getCFI(index, range), excerpt }))
                const progress = (index + 1) / sections.length
                yield { progress }
            if (subitems.length) yield { index, subitems }
        }
    }
    async * search(opts) {
        this.clearSearch()
        const { searchMatcher } = await import('./search.js')
        const { query, index } = opts
        const matcher = searchMatcher(textWalker,
                                      { defaultLocale: this.language, ...opts })
        const iter = index != null
        ? this.#searchSection(matcher, query, index)
        : this.#searchBook(matcher, query)
        
        const list = []
        this.#searchResults.set(index, list)
        
        for await (const result of iter) {
            if (result.subitems){
                const list = result.subitems
                .map(({ cfi }) => ({ value: SEARCH_PREFIX + cfi }))
                this.#searchResults.set(result.index, list)
                for (const item of list) this.addAnnotation(item)
                    yield {
                        label: this.#tocProgress.getProgress(result.index)?.label ?? '',
                        subitems: result.subitems,
                    }
            }
            else {
                if (result.cfi) {
                    const item = { value: SEARCH_PREFIX + result.cfi }
                    list.push(item)
                    this.addAnnotation(item)
                }
                yield result
            }
        }
        yield 'done'
    }
    clearSearch() {
        for (const list of this.#searchResults.values())
            for (const item of list) this.deleteAnnotation(item)
                this.#searchResults.clear()
                }
}

customElements.define('foliate-view', View)
