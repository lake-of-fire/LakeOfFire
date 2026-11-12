import * as CFI from './epubcfi.js'
import { getDocumentLanguage } from './content-language.js'
import { TOCProgress, SectionProgress } from './progress.js'
import { Overlayer } from './overlayer.js'
import { buildRelocateLocation } from './relocate-location.js'
import { OwnedEventBindings } from './owned-event-bindings.js'
import { runCurrentRendererOperation } from './renderer-operation-ownership.js'
import { ViewHistory } from './view-history.js'

const SEARCH_PREFIX = 'foliate-search:'

// Parsed search documents have no rendered layout. Preserve semantic HTML
// block boundaries without asking a detached document for computed styles.
const SEARCH_BLOCK_ELEMENTS = new Set([
    'address', 'article', 'aside', 'blockquote', 'dd', 'details', 'dialog', 'div',
    'dl', 'dt', 'fieldset', 'figcaption', 'figure', 'footer', 'form', 'h1', 'h2',
    'h3', 'h4', 'h5', 'h6', 'header', 'li', 'main', 'nav', 'ol', 'p', 'pre',
    'section', 'summary', 'table', 'tbody', 'td', 'tfoot', 'th', 'thead', 'tr', 'ul',
])
const SVG_NAMESPACE = 'http://www.w3.org/2000/svg'
const IGNORED_SVG_ELEMENTS = new Set(['title', 'desc', 'metadata', 'defs', 'symbol'])
const isSearchBlock = element => {
    const name = element.localName?.toLowerCase()
    return SEARCH_BLOCK_ELEMENTS.has(name)
        || (element.namespaceURI === SVG_NAMESPACE && name === 'text')
}
const searchBlockForNode = (node, root) => {
    for (let parent = node.parentElement; parent && parent !== root; parent = parent.parentElement) {
        const name = parent.localName?.toLowerCase()
        if (name === 'script' || name === 'style' || name === 'rt' || name === 'rp' || name === 'rtc')
            continue
        if (parent.namespaceURI === SVG_NAMESPACE && IGNORED_SVG_ELEMENTS.has(name)) continue
        if (isSearchBlock(parent)) return parent
    }
    return root
}

const textWalker = function* (doc, func) {
    const filter = NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT
    | NodeFilter.SHOW_CDATA_SECTION
    const { FILTER_ACCEPT, FILTER_REJECT, FILTER_SKIP } = NodeFilter
    const root = doc.body ?? doc.documentElement
    if (!root) return
    const acceptNode = node => {
        const name = node.localName?.toLowerCase()
        if (name === 'script' || name === 'style' || name === 'rt' || name === 'rp' || name === 'rtc')
            return FILTER_REJECT
        if (node.namespaceURI === SVG_NAMESPACE && IGNORED_SVG_ELEMENTS.has(name)) return FILTER_REJECT
        if (name === 'br' || name === 'hr' || isSearchBlock(node)) return FILTER_ACCEPT
            if (node.nodeType === 1) return FILTER_SKIP
                return FILTER_ACCEPT
                }
    const walker = doc.createTreeWalker(root, filter, { acceptNode })
    const entries = []
    let previousNode, previousBlock, lineBreak = false
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        if (node.nodeType === 1) {
            lineBreak = true
            continue
        }
        const block = searchBlockForNode(node, root)
        if (previousNode && (lineBreak || block !== previousBlock)) {
            entries.push({ before: previousNode, after: node })
        }
        entries.push({ node })
        previousNode = node
        previousBlock = block
        lineBreak = false
    }
    const strs = entries.map(entry => entry.node?.nodeValue ?? '\n')
    const rangePoint = (index, offset) => {
        const entry = entries[index]
        if (entry.node) return [entry.node, offset]
        return offset === 0 ? [entry.before, entry.before.nodeValue.length] : [entry.after, 0]
    }
    const makeRange = (startIndex, startOffset, endIndex, endOffset) => {
        const range = doc.createRange()
        range.setStart(...rangePoint(startIndex, startOffset))
        range.setEnd(...rangePoint(endIndex, endOffset))
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
    #searchGeneration = 0
    #searchCleanup = Promise.resolve()
    #rendererBindings = null
    #documentBindings = new Map()
    #openGeneration = 0
    #disposedRenderers = new WeakSet()
    #disposedBooks = new WeakSet()
    #externalCleanups = new Set()
    #navigationGeneration = 0
    #firstPageRestoreReceipts = new WeakMap()
    #navigationReceipts = new WeakMap()
    isFixedLayout = false
    lastLocation
    history = new ViewHistory()
    constructor() {
        super()
        this.history.addEventListener('popstate', ({ detail }) => {
            // EventTarget does not consume rejected promises. History traversal
            // shares command ownership but must not append another history entry.
            void this.#navigate(detail.state, { recordHistory: false }).catch(error => {
                console.error(error)
            })
        })
    }
    #disposeRenderer(renderer) {
        if (!renderer || this.#disposedRenderers.has(renderer)) return
        this.#disposedRenderers.add(renderer)
        try { renderer.destroy?.() } catch (_) {}
        try { renderer.remove?.() } catch (_) {}
    }
    #disposeBook(book) {
        // A teardown callback may have opened this same book in a successor.
        if (!book || (typeof book !== 'object' && typeof book !== 'function')
            || this.book === book || this.#disposedBooks.has(book)) return
        this.#disposedBooks.add(book)
        try { book.destroy?.() } catch (_) {}
    }
    #withdrawRendererState() {
        const renderer = this.renderer
        const book = this.book
        const bindings = this.#rendererBindings
        const documents = [...this.#documentBindings.values()]
        const cleanups = [...this.#externalCleanups]
        this.#externalCleanups.clear()
        this.renderer = null
        this.book = null
        this.#rendererBindings = null
        this.#documentBindings.clear()
        this.language = null
        this.isFixedLayout = false
        this.#sectionProgress = null
        this.#tocProgress = null
        this.#pageProgress = null
        this.#searchResults = new Map()
        this.lastLocation = null
        this.history.clear()
        // Remove only the captured bindings, even if cleanup reenters open.
        bindings?.clear()
        for (const documentBindings of documents) documentBindings.clear()
        for (const cleanup of cleanups) {
            try { cleanup() } catch (_) {}
        }
        return { renderer, book }
    }
    registerCleanup(cleanup) {
        if (typeof cleanup !== 'function') return () => {}
        let active = true
        const release = () => {
            if (!active) return
            active = false
            this.#externalCleanups.delete(release)
            cleanup()
        }
        if (this.renderer && this.book) this.#externalCleanups.add(release)
        else release()
        return release
    }
    async open(book, isCacheWarmer) {
        return await this.beginOpen(book, isCacheWarmer).completion
    }
    beginOpen(book, isCacheWarmer) {
        const openGeneration = ++this.#openGeneration
        const completion = this.#openBook(book, isCacheWarmer, openGeneration)
        return {
            completion,
            isCurrent: () => this.#openGeneration === openGeneration && this.book === book,
            retire: () => {
                if (this.#openGeneration === openGeneration) this.close()
                this.#disposeBook(book)
                // A closed/failed opening may leave an empty host to remove.
                // A live successor owns that host, even when it reused the book.
                return !this.book && !this.renderer
            },
        }
    }
    async #openBook(book, isCacheWarmer, openGeneration) {
        const previous = this.#withdrawRendererState()
        const isCurrent = () => this.#openGeneration === openGeneration && this.book === book
        // Withdrawal may invoke browser collaborators which start another open.
        if (this.#openGeneration !== openGeneration) {
            this.#disposeRenderer(previous.renderer)
            this.#disposeBook(previous.book)
            this.#disposeBook(book)
            return false
        }
        this.book = book
        this.#isCacheWarmer = isCacheWarmer
        this.#disposeRenderer(previous.renderer)
        if (previous.book !== book) this.#disposeBook(previous.book)
        if (!isCurrent()) return false
        let renderer = null
        try {
            this.language = languageInfo(book.metadata?.language)
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
            const isFixedLayout = book.rendition?.layout === 'pre-paginated'
            this.isFixedLayout = isFixedLayout
            if (isFixedLayout) await import('./fixed-layout.js')
            else await import('./paginator.js')
            if (!isCurrent()) return false
            renderer = document.createElement(isFixedLayout ? 'foliate-fxl' : 'foliate-paginator')
            if (!isCurrent()) {
                this.#disposeRenderer(renderer)
                return false
            }
            this.renderer = renderer
            renderer.setAttribute('exportparts', 'head,foot')
            const bindings = new OwnedEventBindings()
            this.#rendererBindings = bindings
            const listen = (name, callback) => bindings.listen(renderer, name, event => {
                if (isCurrent() && this.renderer === renderer) callback(event)
            })
            listen('load', event => this.#onLoad(event.detail))
            listen('relocate', event => this.#onRelocate(event.detail))
            if (!isCacheWarmer) listen('create-overlayer', event =>
                event.detail.attach(this.#createOverlayer(event.detail)))
            await renderer.open(book, isCacheWarmer)
            if (!isCurrent() || this.renderer !== renderer) {
                this.#disposeRenderer(renderer)
                return false
            }
            this.#root.append(renderer)
            return isCurrent() && this.renderer === renderer
        } catch (error) {
            if (isCurrent()) this.close()
            else this.#disposeRenderer(renderer)
            throw error
        }
    }
    close() {
        this.#openGeneration += 1
        const { renderer, book } = this.#withdrawRendererState()
        this.#disposeRenderer(renderer)
        this.#disposeBook(book)
    }
    async goToTextStart() {
        return await this.goTo(this.book.landmarks
                               ?.find(m => m.type.includes('bodymatter') || m.type.includes('text'))
                               ?.href ?? this.book.sections.findIndex(s => s.linear !== 'no'))
    }
    async init({ lastLocation, showTextStart }) {
        const resolved = lastLocation ? this.resolveNavigation(lastLocation) : null
        if (resolved) {
            await this.goTo(lastLocation)
        }
        else if (showTextStart) await this.goToTextStart()
            else {
                this.history.pushState(0)
                await this.next()
            }
    }
    #emit(name, detail, cancelable) {
        return this.dispatchEvent(new CustomEvent(name, { detail, cancelable }))
    }
    #onRelocate({ reason, range, index, fraction, size, pageTurnDirection }) {
        this.lastLocation = buildRelocateLocation({
            reason,
            range,
            index,
            fraction,
            size,
            pageTurnDirection,
        }, {
            sectionCount: this.book?.sections?.length ?? 0,
            sectionProgress: this.#sectionProgress,
            tocProgress: this.#tocProgress,
            pageProgress: this.#pageProgress,
            cfiProvider: this,
        })
        if (reason === 'snap' || reason === 'page' || reason === 'scroll')
            this.history.replaceState(this.lastLocation.cfi)
            this.#emit('relocate', this.lastLocation)
            }
    #onLoad({ doc, location, index }) {
        const bindings = this.#bindingsForDocument(doc)
        if (!this.#isCacheWarmer) {
            const declaredLanguage = getDocumentLanguage(doc)
            const language = languageInfo(declaredLanguage ?? this.language?.canonical)
            if (declaredLanguage == null && language.canonical)
                doc.documentElement.lang = language.canonical
            if (!language.isCJK && language.direction)
                doc.documentElement.dir ||= language.direction
            this.#handleLinks(doc, index, bindings)
        }
        this.#emit('load', { doc, location, index })
    }
    #bindingsForDocument(doc) {
        if (!doc?.addEventListener) return null
        const existing = this.#documentBindings.get(doc)
        if (existing) return existing
        const bindings = new OwnedEventBindings()
        this.#documentBindings.set(doc, bindings)
        bindings.listen(doc, 'pagehide', () => {
            if (this.#documentBindings.get(doc) !== bindings) return
            this.#documentBindings.delete(doc)
            bindings.clear()
        }, { once: true })
        return bindings
    }
    #isCurrentDocument(doc, bindings, book) {
        return this.book === book && this.#documentBindings.get(doc) === bindings
    }
    #handleLinks(doc, index, bindings) {
        const { book } = this
        const section = book.sections[index]
        for (const a of doc.querySelectorAll('a[href]')) {
            bindings?.listen(a, 'click', e => {
                if (!this.#isCurrentDocument(doc, bindings, book)) return
                e.preventDefault()
                const href_ = a.getAttribute('href')
                const href = section?.resolveHref?.(href_) ?? href_
                if (book?.isExternal?.(href)) {
                    Promise.resolve(this.#emit('external-link', { a, href }, true))
                        .then(x => this.#isCurrentDocument(doc, bindings, book) && x
                            ? globalThis.open(href, '_blank')
                            : null)
                        .catch(e => console.error(e))
                } else {
                    Promise.resolve(this.#emit('link', { a, href }, true))
                        .then(async x => this.#isCurrentDocument(doc, bindings, book) && x
                            ? await this.goTo(href)
                            : null)
                        .catch(e => console.error(e))
                }
            })
        }
    }
    #isOpenGenerationCurrent(openGeneration, renderer, book) {
        return this.#openGeneration === openGeneration
            && this.renderer === renderer
            && this.book === book
    }
    async addAnnotation(annotation, remove, expectedOpenGeneration = this.#openGeneration, operationIsCurrent = null) {
        const renderer = this.renderer
        const book = this.book
        const isCurrent = () =>
            this.#isOpenGenerationCurrent(expectedOpenGeneration, renderer, book)
            && (!operationIsCurrent || operationIsCurrent())
        if (!renderer || !book || !isCurrent()) return
        const { value } = annotation
        if (value.startsWith(SEARCH_PREFIX)) {
            const cfi = value.replace(SEARCH_PREFIX, '')
            const resolved = await this.resolveNavigation(cfi)
            if (!isCurrent() || !resolved) return
            const { index, anchor } = resolved
            const obj = this.#getOverlayer(index, renderer)
            if (obj) {
                const { overlayer, doc } = obj
                if (remove) {
                    overlayer.remove(value)
                    return
                }
                const range = doc ? anchor(doc) : anchor
                overlayer.add(value, range, Overlayer.outline)
            }
            return
        }
        const resolved = await this.resolveNavigation(value)
        if (!isCurrent() || !resolved) return
        const { index, anchor } = resolved
        const obj = this.#getOverlayer(index, renderer)
        if (obj) {
            const { overlayer, doc } = obj
            overlayer.remove(value)
            if (!remove) {
                const range = doc ? anchor(doc) : anchor
                const draw = (func, opts) => overlayer.add(value, range, func, opts)
                this.#emit('draw-annotation', { draw, annotation, doc, range })
            }
        }
        if (!isCurrent()) return
        const label = this.#tocProgress?.getProgress(index)?.label ?? ''
        return { index, label }
    }
    deleteAnnotation(annotation) {
        return this.addAnnotation(annotation, true)
    }
    #getOverlayer(index, renderer = this.renderer) {
        return renderer?.getContents?.()
            .find(x => x.index === index && x.overlayer)
    }
    #createOverlayer({ doc, index }) {
        const overlayer = new Overlayer()
        const bindings = this.#bindingsForDocument(doc)
        const book = this.book
        bindings?.listen(doc, 'click', e => {
            if (!this.#isCurrentDocument(doc, bindings, book)) return
            const [value, range] = overlayer.hitTest(e)
            if (value && !value.startsWith(SEARCH_PREFIX)) {
                this.#emit('show-annotation', { value, range })
            }
        }, false)

        const list = this.#searchResults.get(index)
        if (list) {
            for (const item of list) this.addAnnotation(item)
        }

        this.#emit('create-overlay', { index })
        return overlayer
    }
    async showAnnotation(annotation) {
        const { value } = annotation
        const resolved = await this.goTo(value)
        if (resolved) {
            const { index, anchor } = resolved
            const { doc } =  this.#getOverlayer(index)
            const range = anchor(doc)
            this.#emit('show-annotation', { value, range })
        }
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
            if (target && Number.isInteger(target.index)) return target
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
    async #navigate(target, { select = false, recordHistory = true, requiresPositionReceipt = false, requiresNavigationReceipt = false } = {}) {
        const navigationGeneration = ++this.#navigationGeneration
        const renderer = this.renderer
        const book = this.book
        const openGeneration = this.#openGeneration
        if (!renderer || !book) return null
        const resolved = this.resolveNavigation(target)
        // A renderer may silently ignore an invalid section. Never publish that
        // as successful navigation or an acknowledged saved-position restore.
        if (!resolved || !Number.isInteger(resolved.index)
            || resolved.index < 0 || resolved.index >= book.sections.length) return null
        const isCurrent = () => this.renderer === renderer && this.book === book
            && this.#openGeneration === openGeneration
            && this.#navigationGeneration === navigationGeneration
        const result = await runCurrentRendererOperation({
            operation: () => requiresPositionReceipt || requiresNavigationReceipt
                ? renderer.goTo(resolved, { requiresPositionReceipt, requiresNavigationReceipt })
                : renderer.goTo(select ? { ...resolved, select: true } : resolved),
            isCurrent,
        })
        if (result.ignored || result.value === null || result.value === false
            || result.value?.ignored === true) return null
        // Successful renderers can return void. Only their explicit rejection
        // values, or loss of ownership, mean that this command was not applied.
        if (requiresPositionReceipt) {
            const receipt = result.value
            if (resolved.anchor !== 0 || !renderer.isPositionReceiptCurrent?.(receipt) || !isCurrent()) return null
            this.#firstPageRestoreReceipts.set(receipt, {
                renderer, book, openGeneration, navigationGeneration, target: resolved,
            })
            if (recordHistory) this.history.pushState(target)
            return receipt
        }
        if (requiresNavigationReceipt) {
            const receipt = result.value
            if (!renderer.isNavigationReceiptCurrent?.(receipt) || !isCurrent()) return null
            this.#navigationReceipts.set(receipt, { renderer, book, openGeneration, navigationGeneration })
            if (recordHistory) this.history.pushState(target)
            return receipt
        }
        if (recordHistory) this.history.pushState(target)
        return resolved
    }
    async goTo(target, options) {
        try {
            return await this.#navigate(target, options)
        } catch (error) {
            console.error(error)
            console.error(`Could not go to ${target}`)
            throw error
        }
    }
    async goToFirstPageForRestore() {
        return this.#navigate({ fraction: 0 }, { requiresPositionReceipt: true })
    }
    captureFirstPageRestoreGeometry(receipt) {
        const owner = receipt && this.#firstPageRestoreReceipts.get(receipt)
        if (!owner || this.renderer !== owner.renderer || this.book !== owner.book
            || this.#openGeneration !== owner.openGeneration
            || this.#navigationGeneration !== owner.navigationGeneration) return null
        const proof = owner.renderer.capturePositionProof?.(receipt)
        if (!proof || !owner.renderer.isPositionProofCurrent?.(proof)) return null
        return { kind: 'paginated-first-page-v1', targetSectionIndex: owner.target.index,
            targetAnchor: owner.target.anchor, sectionIndex: proof.sectionIndex,
            fractionInSection: proof.fractionInSection, pageFraction: proof.pageFraction }
    }
    isNavigationReceiptCurrent(receipt) {
        const owner = receipt && this.#navigationReceipts.get(receipt)
        return !!owner && this.renderer === owner.renderer && this.book === owner.book
            && this.#openGeneration === owner.openGeneration
            && this.#navigationGeneration === owner.navigationGeneration
            && owner.renderer.isNavigationReceiptCurrent?.(receipt) === true
    }
    async #navigateSection(direction, options = {}) {
        const renderer = this.renderer, book = this.book
        const openGeneration = this.#openGeneration
        const navigationGeneration = ++this.#navigationGeneration
        if (!renderer || !book) return null
        const isCurrent = () => this.renderer === renderer && this.book === book
            && this.#openGeneration === openGeneration
            && this.#navigationGeneration === navigationGeneration
        const result = await runCurrentRendererOperation({
            operation: () => renderer[direction](options), isCurrent,
        })
        if (result.ignored || result.value === null || result.value === false || result.value?.ignored) return null
        if (!options.requiresNavigationReceipt) return result.value
        const receipt = result.value
        if (!renderer.isNavigationReceiptCurrent?.(receipt) || !isCurrent()) return null
        this.#navigationReceipts.set(receipt, { renderer, book, openGeneration, navigationGeneration })
        return receipt
    }
    async prevSection(options) { return this.#navigateSection('prevSection', options) }
    async nextSection(options) { return this.#navigateSection('nextSection', options) }
    async goToFraction(fraction, options) {
        if (!Number.isFinite(fraction) || fraction < 0 || fraction > 1) return null
        // Use the same renderer/load/command fence as CFI and href navigation.
        return this.goTo({ fraction }, options)
    }
    async select(target) {
        try {
            return await this.#navigate(target, { select: true }) != null
        } catch (error) {
            console.error(error)
            console.error(`Could not go to ${target}`)
            return false
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
    async getNavigationProgressOf(target) {
        try {
            const { index, anchor } = await this.resolveNavigation(target)
            const doc = await this.book.sections[index].createDocument()
            let range = null
            if (typeof anchor === 'function') {
                const frag = anchor(doc)
                if (frag === 0) {
                    range = doc.createRange()
                    range.selectNodeContents(doc.body ?? doc.documentElement)
                    range.collapse(true)
                } else if (frag instanceof Range) {
                    range = frag
                } else if (frag instanceof Node) {
                    range = doc.createRange()
                    try {
                        range.selectNodeContents(frag)
                    } catch (_error) {
                        range.selectNode(frag)
                    }
                }
            }
            if (!range) {
                range = doc.createRange()
                range.selectNodeContents(doc.body ?? doc.documentElement)
                range.collapse(true)
            }
            const tocItem = this.#tocProgress?.getProgress(index, range) ?? null
            const pageItem = this.#pageProgress?.getProgress(index, range) ?? null
            const cfi = this.getCFI(index, range)
            return {
                index,
                sectionIndex: index,
                tocItem,
                pageItem,
                cfi,
            }
        } catch (e) {
            console.error(e)
            console.error(`Could not get navigation progress for ${target}`)
            return null
        }
    }
    async prev(distance) {
        this.#navigationGeneration += 1
        await this.renderer?.prev(distance)
    }
    async next(distance) {
        this.#navigationGeneration += 1
        await this.renderer?.next(distance)
    }
    async goLeft() {
        return this.book.dir === 'rtl' ? await this.next() : await this.prev()
    }
    async goRight() {
        return this.book.dir === 'rtl' ? await this.prev() : await this.next()
    }
    #isSearchCurrent(owner) {
        return owner.generation === this.#searchGeneration
            && owner.openGeneration === this.#openGeneration
            && owner.book === this.book
            && owner.renderer === this.renderer
    }
    async #createSearchDocument(section, owner) {
        try {
            return await section.createDocument()
        } catch (error) {
            if (this.#isSearchCurrent(owner)) throw error
            return null
        }
    }
    async * #searchSection(matcher, query, index, owner) {
        const section = owner.book?.sections?.[index]
        if (!section?.createDocument) return
        const doc = await this.#createSearchDocument(section, owner)
        if (!this.#isSearchCurrent(owner)) return
        for (const { range, excerpt } of matcher(doc, query)) {
            if (!this.#isSearchCurrent(owner)) return
            yield { cfi: this.getCFI(index, range), excerpt }
        }
    }
    async * #searchBook(matcher, query, owner) {
        const { sections } = owner.book
        for (const [index, section] of sections.entries()) {
            if (!this.#isSearchCurrent(owner)) return
            if (!section.createDocument) continue
            const doc = await this.#createSearchDocument(section, owner)
            if (!this.#isSearchCurrent(owner)) return
            const subitems = Array.from(matcher(doc, query), ({ range, excerpt }) =>
                ({ cfi: this.getCFI(index, range), excerpt }))
            const progress = (index + 1) / sections.length
            yield { progress }
            if (!this.#isSearchCurrent(owner)) return
            if (subitems.length) yield { index, subitems }
        }
    }
    async * search(opts) {
        const cleanup = this.clearSearch()
        const owner = {
            generation: this.#searchGeneration,
            openGeneration: this.#openGeneration,
            book: this.book,
            renderer: this.renderer,
        }
        await cleanup
        if (!this.#isSearchCurrent(owner)) return
        const { searchMatcher } = await import('./search.js')
        if (!this.#isSearchCurrent(owner)) return
        const { query, index } = opts
        const matcher = searchMatcher(textWalker,
            { defaultLocale: this.language?.canonical, ...opts })
        const iter = index != null
            ? this.#searchSection(matcher, query, index, owner)
            : this.#searchBook(matcher, query, owner)
        const isCurrent = () => this.#isSearchCurrent(owner)

        const list = []
        this.#searchResults.set(index, list)

        for await (const result of iter) {
            if (!isCurrent()) return
            if (result.subitems) {
                const resultList = result.subitems
                    .map(({ cfi }) => ({ value: SEARCH_PREFIX + cfi }))
                this.#searchResults.set(result.index, resultList)
                for (const item of resultList) {
                    await this.addAnnotation(item, false, owner.openGeneration, isCurrent)
                    if (!isCurrent()) return
                }
                yield {
                    label: this.#tocProgress.getProgress(result.index)?.label ?? '',
                    subitems: result.subitems,
                }
            } else {
                if (result.cfi) {
                    const item = { value: SEARCH_PREFIX + result.cfi }
                    list.push(item)
                    await this.addAnnotation(item, false, owner.openGeneration, isCurrent)
                    if (!isCurrent()) return
                }
                yield result
            }
        }
        if (isCurrent()) yield 'done'
    }
    clearSearch() {
        this.#searchGeneration += 1
        const openGeneration = this.#openGeneration
        const book = this.book
        const renderer = this.renderer
        const items = Array.from(this.#searchResults.values()).flat()
        this.#searchResults.clear()
        const isCurrentRenderer = () =>
            this.#openGeneration === openGeneration
            && this.book === book
            && this.renderer === renderer
        const cleanup = this.#searchCleanup.then(async () => {
            if (!isCurrentRenderer()) return
            for (const item of items) {
                await this.addAnnotation(item, true, openGeneration, isCurrentRenderer)
                if (!isCurrentRenderer()) return
            }
        })
        const settledCleanup = cleanup.catch(error => console.error(error))
        this.#searchCleanup = settledCleanup
        return settledCleanup
    }
}

customElements.define('foliate-view', View)
