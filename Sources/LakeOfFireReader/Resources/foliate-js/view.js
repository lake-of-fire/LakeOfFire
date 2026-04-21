import * as CFI from './epubcfi.js'
import './fixed-layout.js'
import './paginator.js'
import { TOCProgress, SectionProgress } from './progress.js'

const SEARCH_PREFIX = 'foliate-search:'

// pagination logger disabled for noise reduction
const logEBookPagination = () => {}
const logBug = (event, detail = {}) => {
    try {
        return globalThis.logBug?.(event, detail)
    } catch (_error) {
        return undefined
    }
}
const logNavHide = globalThis.logNavHide || ((event, detail = {}) => {
    const payload = { event, ...detail };
    const line = `# EBOOK NAVHIDE ${JSON.stringify(payload)}`;
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_err) {
        try { console.log(line); } catch (_) {}
    }
});

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
    const appliedHide = !!shouldHide;
    logNavHide('view:post-nav-visibility', {
        requested: !!shouldHide,
        applied: appliedHide,
        source: source ?? null,
        direction: direction ?? null,
    });
    try {
        window.webkit?.messageHandlers?.ebookNavigationVisibility?.postMessage?.({
            hideNavigationDueToScroll: appliedHide,
            source: source ?? null,
            direction: direction ?? null,
        });
    } catch (error) {
        console.error('Failed to notify navigation chrome visibility', error);
    }
}

class History extends EventTarget {
    _arr = []
    _index = -1
    _pendingReplaceStateSuppressionCount = 0
    _activeReplaceStateSuppressionCount = 0
    _suppressedReplaceStateCount = 0
    _lastSuppressedReplaceStateReason = null
    pushState(x) {
        const last = this._arr[this._index]
        if (last === x || last?.fraction && last.fraction === x.fraction) return
            this._arr[++this._index] = x
            this._arr.length = this._index + 1
            this.dispatchEvent(new Event('index-change'))
            }
    replaceState(x) {
        if (this._pendingReplaceStateSuppressionCount > 0) {
            this._pendingReplaceStateSuppressionCount -= 1
            this._suppressedReplaceStateCount += 1
            return
        }
        if (this._activeReplaceStateSuppressionCount > 0) {
            this._suppressedReplaceStateCount += 1
            return
        }
        const index = this._index
        this._arr[index] = x
    }
    back() {
        const index = this._index
        if (index <= 0) return
            const detail = { state: this._arr[index - 1] }
        this._index = index - 1
        this.dispatchEvent(new CustomEvent('popstate', { detail }))
        this.dispatchEvent(new Event('index-change'))
    }
    forward() {
        const index = this._index
        if (index >= this._arr.length - 1) return
            const detail = { state: this._arr[index + 1] }
        this._index = index + 1
        this.dispatchEvent(new CustomEvent('popstate', { detail }))
        this.dispatchEvent(new Event('index-change'))
    }
    get canGoBack() {
        return this._index > 0
    }
    get canGoForward() {
        return this._index < this._arr.length - 1
    }
    get index() {
        return this._index
    }
    get length() {
        return this._arr.length
    }
    get pendingReplaceStateSuppressionCount() {
        return this._pendingReplaceStateSuppressionCount + this._activeReplaceStateSuppressionCount
    }
    get suppressedReplaceStateCount() {
        return this._suppressedReplaceStateCount
    }
    get lastSuppressedReplaceStateReason() {
        return this._lastSuppressedReplaceStateReason
    }
    suppressNextReplaceState(reason = 'internal') {
        this._pendingReplaceStateSuppressionCount += 1
        this._lastSuppressedReplaceStateReason = reason ?? null
    }
    beginReplaceStateSuppression(reason = 'internal') {
        this._activeReplaceStateSuppressionCount += 1
        this._lastSuppressedReplaceStateReason = reason ?? null
    }
    endReplaceStateSuppression() {
        this._activeReplaceStateSuppressionCount = Math.max(0, this._activeReplaceStateSuppressionCount - 1)
    }
    clearPendingReplaceStateSuppression() {
        this._pendingReplaceStateSuppressionCount = 0
        this._activeReplaceStateSuppressionCount = 0
    }
    clear() {
        this._arr = []
        this._index = -1
        this._pendingReplaceStateSuppressionCount = 0
        this._activeReplaceStateSuppressionCount = 0
        this._suppressedReplaceStateCount = 0
        this._lastSuppressedReplaceStateReason = null
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
    _root = this.attachShadow({ mode: 'closed' })
    _sectionProgress
    _tocProgress
    _pageProgress
    _isCacheWarmer
    _searchResults = new Map()
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
        this._isCacheWarmer = isCacheWarmer
        const setOpenLoadState = state => {
            if (
                globalThis.reader?.view === this
                && globalThis.manabiLoadEBookReady !== true
            ) {
                globalThis.manabiLoadEBookLastState = state
            }
            return state
        }
        
        if (book.splitTOCHref && book.getTOCFragment) {
            const ids = book.sections.map(s => s.id)
            this._sectionProgress = new SectionProgress(book.sections, 1500, 1600)
            const splitHref = book.splitTOCHref.bind(book)
            const getFragment = book.getTOCFragment.bind(book)
            this._tocProgress = new TOCProgress({
                toc: book.toc ?? [], ids, splitHref, getFragment })
            this._pageProgress = new TOCProgress({
                toc: book.pageList ?? [], ids, splitHref, getFragment })
        }
        
        this.isFixedLayout = this.book.rendition?.layout === 'pre-paginated'
        if (this.isFixedLayout) {
            setOpenLoadState('view-open-fixed-layout-import-ready')
            setOpenLoadState('view-open-fixed-layout-pre-create-renderer')
            this.renderer = document.createElement('foliate-fxl')
        } else {
            setOpenLoadState('view-open-paginator-import-ready')
            setOpenLoadState('view-open-paginator-pre-create-renderer')
            this.renderer = document.createElement('foliate-paginator')
        }
        setOpenLoadState('view-open-renderer-created')
        this.renderer.setAttribute('exportparts', 'head,foot') //,filter')
        this.renderer.addEventListener('load', e => this._onLoad(e.detail))
        this.renderer.addEventListener('relocate', e => this._onRelocate(e.detail))
        // Overlayer support removed
        
        setOpenLoadState('view-open-renderer-open-called')
        this.renderer.open(book, isCacheWarmer)
        setOpenLoadState('view-open-renderer-pre-append')
        this._root.append(this.renderer)
        setOpenLoadState('view-open-renderer-appended')
        const rendererLoadPromise = new Promise(resolve => {
            const onLoad = () => {
                setOpenLoadState('view-open-renderer-load-event');
                resolve('load');
            };
            const onRelocate = () => {
                setOpenLoadState('view-open-renderer-relocate-event');
                resolve('relocate');
            };
            this.renderer.addEventListener('load', onLoad, { once: true })
            this.renderer.addEventListener('relocate', onRelocate, { once: true })
            setTimeout(() => resolve('timeout'), 15000)
        });
        setOpenLoadState('view-open-awaiting-renderer-event')
        rendererLoadPromise.then(rendererReadyEvent => {
            setOpenLoadState(`view-open-renderer-event:${rendererReadyEvent}`)
        })
    }
    close() {
        this.renderer?.destroy()
        this.renderer?.remove()
        this._sectionProgress = null
        this._tocProgress = null
        this._pageProgress = null
        this._searchResults = new Map()
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
            this.history.suppressNextReplaceState('init:lastLocation')
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
    _emit(name, detail, cancelable) {
        return this.dispatchEvent(new CustomEvent(name, { detail, cancelable }))
    }
    _onRelocate(detail) {
        if (!detail) return
        const {
            reason,
            range,
            index,
            fraction,
            size,
            pageNumber,
            pageCount,
            scrolled,
            sizeFraction,
            startOffset,
            pageSize,
            viewSize,
        } = detail
        const progress = this._sectionProgress?.getProgress(index, fraction, size) ?? {}
        const tocItem = this._tocProgress?.getProgress(index, range)
        const pageItem = this._pageProgress?.getProgress(index, range)
        const cfi = this.getCFI(index, range)

        // Preserve the original relocate payload so downstream consumers (NavigationHUD, native layer)
        // can compute accurate page metrics instead of relying on derived estimates.
        this.lastLocation = {
            ...progress,
            tocItem,
            pageItem,
            cfi,
            range,
            reason,
            fraction,
            size,
            pageNumber,
            pageCount,
            scrolled,
            sizeFraction,
            startOffset,
            pageSize,
            viewSize,
        }

        if (reason === 'snap' || reason === 'page' || reason === 'scroll') {
            this.history.replaceState(cfi)
        }
        this._emit('relocate', this.lastLocation)
    }
    _onLoad({ doc, location, index }) {
        if (!this._isCacheWarmer) {
            // set language and dir if not already set
            doc.documentElement.lang ||= this.language.canonical ?? ''
            if (!this.language.isCJK)
                doc.documentElement.dir ||= this.language.direction ?? ''
                
                this._handleLinks(doc, index)
                }
        this._emit('load', { doc, location, index })
    }
    _handleLinks(doc, index) {
        const { book } = this
        const section = book.sections[index]
        const linkRoot = doc.getElementById?.('reader-content') || doc
        for (const a of linkRoot.querySelectorAll('a[href]'))
            a.addEventListener('click', e => {
                e.preventDefault()
                const href_ = a.getAttribute('href')
                const href = section?.resolveHref?.(href_) ?? href_
                if (book?.isExternal?.(href))
                    Promise.resolve(this._emit('external-link', { a, href }, true))
                    .then(x => x ? globalThis.open(href, '_blank') : null)
                    .catch(e => console.error(e))
                    else Promise.resolve(this._emit('link', { a, href }, true))
                        .then(async x => x ? await this.goTo(href) : null)
                        .catch(e => console.error(e))
                        })
            }
    async addAnnotation(annotation, _remove) {
        const { value } = annotation
        const resolved = await this.resolveNavigation(value.startsWith?.(SEARCH_PREFIX) ? value.replace(SEARCH_PREFIX, '') : value)
        const index = resolved?.index
        const label = typeof index === 'number' ? (this._tocProgress?.getProgress(index)?.label ?? '') : ''
        return { index, label }
    }
    deleteAnnotation(annotation) {
        return this.addAnnotation(annotation, true)
    }
    _getOverlayer(_index) {
        return null
    }
    _createOverlayer(_detail) {
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
                const [index, anchor] = this._sectionProgress.getSection(target.fraction)
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
        //        this._emit('is-loading', true)
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
        //        this._emit('is-loading', false)
        //        return resolved
    }
    async goToFraction(frac) {
        const [index, anchor] = this._sectionProgress.getSection(frac)
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
                return this._tocProgress.getProgress(index, range)
                } catch(e) {
                    console.error(e)
                    console.error(`Could not get ${target}`)
                }
    }
    async prev(distance) {
        const useSectionJump =
            distance == null &&
            this.renderer?.getHasPrevSection?.() &&
            await this.renderer?.isAtSectionStart?.()
        logBug?.('view:prev', {
            distance: distance ?? null,
            useSectionJump,
            hasPrevSection: this.renderer?.getHasPrevSection?.() ?? null,
            bookDir: this.book?.dir ?? null,
        })
        if (useSectionJump) {
            logBug?.('view:prev:section-jump', {
                bookDir: this.book?.dir ?? null,
            })
            return await this.renderer.prevSection()
        }
        logBug?.('view:prev:intra-section', {
            distance: distance ?? null,
            bookDir: this.book?.dir ?? null,
        })
        return await this.renderer.prev(distance)
    }
    async next(distance) {
        const useSectionJump =
            distance == null &&
            this.renderer?.getHasNextSection?.() &&
            await this.renderer?.isAtSectionEnd?.()
        logBug?.('view:next', {
            distance: distance ?? null,
            useSectionJump,
            hasNextSection: this.renderer?.getHasNextSection?.() ?? null,
            bookDir: this.book?.dir ?? null,
        })
        if (useSectionJump) {
            logBug?.('view:next:section-jump', {
                bookDir: this.book?.dir ?? null,
            })
            return await this.renderer.nextSection()
        }
        logBug?.('view:next:intra-section', {
            distance: distance ?? null,
            bookDir: this.book?.dir ?? null,
        })
        return await this.renderer.next(distance)
    }
    async goLeft() {
        const isForward = this.book.dir === 'rtl'
        if (!this._isCacheWarmer) {
            postNavigationChromeVisibility(isForward, {
                source: 'swipe-left',
                direction: isForward ? 'forward' : 'backward'
            })
        }
        logNavHide('view:goLeft', {
            dir: this.book.dir,
            requestedHide: isForward,
            cacheWarmer: this._isCacheWarmer,
            navHiddenClass: document?.body?.classList?.contains?.('nav-hidden') ?? null,
        })
        logBug?.('view:goLeft', {
            dir: this.book.dir,
            cacheWarmer: this._isCacheWarmer,
        });
        return this.book.dir === 'rtl' ? await this.next() : await this.prev()
    }
    async goRight() {
        const isForward = this.book.dir !== 'rtl'
        if (!this._isCacheWarmer) {
            postNavigationChromeVisibility(isForward, {
                source: 'swipe-right',
                direction: isForward ? 'forward' : 'backward'
            })
        }
        logNavHide('view:goRight', {
            dir: this.book.dir,
            requestedHide: isForward,
            cacheWarmer: this._isCacheWarmer,
            navHiddenClass: document?.body?.classList?.contains?.('nav-hidden') ?? null,
        })
        logBug?.('view:goRight', {
            dir: this.book.dir,
            cacheWarmer: this._isCacheWarmer,
        });
        return this.book.dir === 'rtl' ? await this.prev() : await this.next()
    }
    async * _searchSection(matcher, query, index) {
        const doc = await this.book.sections[index].createDocument()
        for (const { range, excerpt } of matcher(doc, query))
            yield { cfi: this.getCFI(index, range), excerpt }
    }
    async * _searchBook(matcher, query) {
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
        ? this._searchSection(matcher, query, index)
        : this._searchBook(matcher, query)
        
        const list = []
        this._searchResults.set(index, list)
        
        for await (const result of iter) {
            if (result.subitems){
                const list = result.subitems
                .map(({ cfi }) => ({ value: SEARCH_PREFIX + cfi }))
                this._searchResults.set(result.index, list)
                for (const item of list) this.addAnnotation(item)
                    yield {
                        label: this._tocProgress.getProgress(result.index)?.label ?? '',
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
        for (const list of this._searchResults.values())
            for (const item of list) this.deleteAnnotation(item)
                this._searchResults.clear()
                }
}

customElements.define('foliate-view', View)
