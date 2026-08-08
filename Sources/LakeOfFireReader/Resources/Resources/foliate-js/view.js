import * as CFI from './epubcfi.js'
import { TOCProgress, SectionProgress } from './progress.js'
import { Overlayer } from './overlayer.js'
import {
    rendererNavigationAccepted,
    rendererNavigationNotOwned,
    runCurrentRendererNavigation,
} from './renderer-navigation.js'
import {
    readerNavigationResultReachedTarget,
    readerNavigationResultWasCommitted,
    readerRelocationDetailWithNavigationIntent,
    snapshotReaderNavigationIntent,
} from './ebook-restore-coordination.js'

export { readerRelocationDetailWithNavigationIntent }

export const destroyReaderBook = book => {
    if (!book) return false
    try {
        book.destroy?.()
        return true
    } catch (error) {
        console.error(error)
        return false
    }
}

const SEARCH_PREFIX = 'foliate-search:'
class History extends EventTarget {
    #arr = []
    #index = -1
    #pending = null
    #cancelPending() {
        this.#pending?.complete(false)
    }
    #navigationIndex() {
        return this.#pending?.targetIndex ?? this.#index
    }
    pushState(x) {
        this.#cancelPending()
        const last = this.#arr[this.#index]
        const repeatsFraction = Number.isFinite(last?.fraction)
            && Number.isFinite(x?.fraction)
            && last.fraction === x.fraction
        if (last === x || repeatsFraction) return
        this.#arr[++this.#index] = x
        this.#arr.length = this.#index + 1
        this.dispatchEvent(new Event('index-change'))
    }
    replaceState(x) {
        const index = this.#pending?.targetIndex ?? this.#index
        if (index < 0) return
        this.#arr[index] = x
    }
    #moveTo(targetIndex) {
        if (targetIndex < 0 || targetIndex >= this.#arr.length) {
            return Promise.resolve(false)
        }
        this.#cancelPending()
        let resolve
        const promise = new Promise(r => { resolve = r })
        const operation = {
            targetIndex,
            complete: accepted => {
                if (this.#pending !== operation) return false
                this.#pending = null
                const didAccept = accepted === true
                if (didAccept) {
                    this.#index = targetIndex
                    this.dispatchEvent(new Event('index-change'))
                }
                resolve(didAccept)
                return didAccept
            },
        }
        this.#pending = operation
        const detail = {
            state: this.#arr[targetIndex],
            complete: operation.complete,
        }
        this.dispatchEvent(new CustomEvent('popstate', { detail }))
        return promise
    }
    back() {
        const index = this.#navigationIndex()
        if (index <= 0) return Promise.resolve(false)
        return this.#moveTo(index - 1)
    }
    forward() {
        const index = this.#navigationIndex()
        if (index >= this.#arr.length - 1) return Promise.resolve(false)
        return this.#moveTo(index + 1)
    }
    get canGoBack() {
        return this.#index > 0
    }
    get canGoForward() {
        return this.#index < this.#arr.length - 1
    }
    clear() {
        this.#cancelPending()
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
    #searchResults = new Map()
    #searchGeneration = 0
    #searchCleanup = Promise.resolve()
    #openGeneration = 0
    #rendererListenerCleanups = []
    #externalCleanups = []
    #documentScopes = new Map()
    isFixedLayout = false
    lastLocation
    history = new History()
    async #runRendererNavigation(operation) {
        const renderer = this.renderer
        const openGeneration = this.#openGeneration
        if (!renderer) return rendererNavigationNotOwned('viewRendererUnavailable')
        return await runCurrentRendererNavigation({
            operation: () => operation(renderer),
            isCurrent: () =>
                this.renderer === renderer && this.#openGeneration === openGeneration,
        })
    }
    async #navigateAndPush(operation, state) {
        const result = await this.#runRendererNavigation(operation)
        if (!rendererNavigationAccepted(result)) return false
        this.history.pushState(state)
        return true
    }
    constructor() {
        super()
        this.history.addEventListener('popstate', ({ detail }) => {
            const renderer = this.renderer
            if (!renderer) {
                detail.complete(false)
                return
            }
            void (async () => {
                try {
                    const resolved = this.resolveNavigation(detail.state)
                    if (!resolved) {
                        detail.complete(false)
                        return
                    }
                    detail.complete(await renderer.goTo(resolved) === true)
                } catch (error) {
                    console.error(error)
                    detail.complete(false)
                }
            })()
        })
    }
    #listenToRenderer(renderer, type, listener, options) {
        const guardedListener = event => {
            if (this.renderer !== renderer) return
            listener(event)
        }
        renderer.addEventListener(type, guardedListener, options)
        this.#rendererListenerCleanups.push(() => {
            renderer.removeEventListener(type, guardedListener, options)
        })
    }
    #removeRendererListeners() {
        for (const cleanup of this.#rendererListenerCleanups.splice(0)) {
            try {
                cleanup()
            } catch (_error) {}
        }
    }
    #documentScope(doc) {
        if (!doc?.addEventListener) return null
        const current = this.#documentScopes.get(doc)
        if (
            current
            && current.openGeneration === this.#openGeneration
            && current.book === this.book
        ) {
            return current
        }
        this.#releaseDocumentScope(doc)
        const scope = {
            doc,
            book: this.book,
            openGeneration: this.#openGeneration,
            cleanups: new Set(),
        }
        this.#documentScopes.set(doc, scope)
        return scope
    }
    #isDocumentScopeCurrent(scope) {
        return !!scope
            && this.#documentScopes.get(scope.doc) === scope
            && scope.openGeneration === this.#openGeneration
            && scope.book === this.book
    }
    #listenInDocumentScope(scope, target, type, listener, options) {
        if (!scope || !target?.addEventListener || typeof listener !== 'function') {
            return () => {}
        }
        target.addEventListener(type, listener, options)
        let active = true
        const cleanup = () => {
            if (!active) return
            active = false
            scope.cleanups.delete(cleanup)
            target.removeEventListener?.(type, listener, options)
        }
        scope.cleanups.add(cleanup)
        return cleanup
    }
    #releaseDocumentScope(doc) {
        const scope = doc ? this.#documentScopes.get(doc) : null
        if (!scope) return false
        this.#documentScopes.delete(doc)
        for (const cleanup of [...scope.cleanups]) {
            try {
                cleanup()
            } catch (_error) {}
        }
        scope.cleanups.clear()
        return true
    }
    #releaseAllDocumentScopes() {
        for (const doc of [...this.#documentScopes.keys()]) {
            this.#releaseDocumentScope(doc)
        }
    }
    #disposeRenderer(renderer) {
        if (!renderer) return
        try {
            renderer.destroy?.()
        } catch (_error) {}
        try {
            renderer.remove?.()
        } catch (_error) {}
    }
    #disposeBook(book) {
        destroyReaderBook(book)
    }
    registerCleanup(cleanup) {
        if (typeof cleanup !== 'function') return () => {}
        let active = true
        const ownedCleanup = () => {
            if (!active) return
            active = false
            const index = this.#externalCleanups.indexOf(ownedCleanup)
            if (index >= 0) this.#externalCleanups.splice(index, 1)
            cleanup()
        }
        this.#externalCleanups.push(ownedCleanup)
        return ownedCleanup
    }
    async open(book) {
        this.close()
        const openGeneration = this.#openGeneration
        this.book = book
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

            this.isFixedLayout = this.book.rendition?.layout === 'pre-paginated'
            if (this.isFixedLayout) {
                await import('./fixed-layout.js')
            } else {
                await import('./paginator.js')
            }
            if (openGeneration !== this.#openGeneration) return false
            renderer = document.createElement(
                this.isFixedLayout ? 'foliate-fxl' : 'foliate-paginator'
            )
            this.renderer = renderer
            renderer.setAttribute('exportparts', 'head,foot') //,filter')
            this.#listenToRenderer(renderer, 'load', e => this.#onLoad(e.detail))
            this.#listenToRenderer(renderer, 'document-committed', e =>
                this.#emit('document-committed', e.detail))
            this.#listenToRenderer(renderer, 'document-unload', e => {
                this.#releaseDocumentScope(e.detail?.doc)
                this.#emit('document-unload', e.detail)
            })
            this.#listenToRenderer(renderer, 'relocate', e => this.#onRelocate(e.detail))
            this.#listenToRenderer(renderer, 'create-overlayer', e =>
                e.detail.attach(this.#createOverlayer(e.detail)))
            //        this.renderer.addEventListener('setViewTransition', e => {
            //            // Workaround for WebKit bug: https://lists.webkit.org/pipermail/webkit-unassigned/2025-April/1218207.html
            //            this.style.setProperty('display', 'block');
            //            this.style.setProperty('width', '100%');
            //            this.style.setProperty('height', '100%');
            //
            //            this.style.viewTransitionName = e.detail.viewTransitionName;
            //            this.style.setProperty('--slide-from', e.detail.slideFrom);
            //            this.style.setProperty('--slide-to', e.detail.slideTo);
            ////            document.documentElement.style.viewTransitionName = e.detail.viewTransitionName;
            ////            document.documentElement.style.setProperty('--slide-from', e.detail.slideFrom);
            ////            document.documentElement.style.setProperty('--slide-to', e.detail.slideTo);
            //        });

            const rendererOpened = await renderer.open(book)
            if (rendererOpened === false) {
                const error = new Error('Reader renderer rejected publication ownership')
                error.name = 'InvalidStateError'
                throw error
            }
            if (openGeneration !== this.#openGeneration || this.renderer !== renderer) {
                this.#disposeRenderer(renderer)
                return false
            }
            this.#root.append(renderer)
            return true
        } catch (error) {
            if (
                openGeneration === this.#openGeneration
                && this.renderer === renderer
                && this.book === book
            ) {
                this.close()
            } else {
                if (renderer && this.renderer === renderer) {
                    this.renderer = null
                    this.#removeRendererListeners()
                }
                this.#disposeRenderer(renderer)
            }
            throw error
        }
    }
    close() {
        this.#openGeneration += 1
        const renderer = this.renderer
        const book = this.book
        this.renderer = null
        this.book = null
        this.#removeRendererListeners()
        this.#releaseAllDocumentScopes()
        this.#disposeRenderer(renderer)
        this.#disposeBook(book)
        for (const cleanup of this.#externalCleanups.splice(0)) {
            try {
                cleanup()
            } catch (_error) {}
        }
        this.language = null
        this.isFixedLayout = false
        this.#sectionProgress = null
        this.#tocProgress = null
        this.#pageProgress = null
        this.#searchGeneration += 1
        this.#searchResults = new Map()
        this.#searchCleanup = Promise.resolve()
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
            const result = await this.#runRendererNavigation(
                renderer => renderer.goTo(resolved)
            )
            if (!readerNavigationResultWasCommitted(result)) return false
            this.history.pushState(lastLocation)
            return true
        }
        if (showTextStart) return await this.goToTextStart()
        this.history.pushState(0)
        try {
            const result = await this.next()
            if (!readerNavigationResultWasCommitted(result)) {
                this.history.clear()
                return false
            }
            return true
        } catch (error) {
            this.history.clear()
            throw error
        }
    }
    #emit(name, detail, cancelable) {
        return this.dispatchEvent(new CustomEvent(name, { detail, cancelable }))
    }
    #onRelocate(rendererDetail) {
        const ownedRendererDetail = readerRelocationDetailWithNavigationIntent({
            rendererDetail,
        })
        const { reason, range, index, fraction, size } = ownedRendererDetail
        const progress = this.#sectionProgress?.getProgress(index, fraction, size) ?? {}
        const tocItem = this.#tocProgress?.getProgress(index, range)
        const pageItem = this.#pageProgress?.getProgress(index, range)
        const cfi = this.getCFI(index, range)
        this.lastLocation = {
            ...ownedRendererDetail,
            ...progress,
            index,
            sectionIndex: index,
            tocItem,
            pageItem,
            cfi,
            range,
            reason,
            pageTurnDirection: ownedRendererDetail.pageTurnDirection,
            relocationID: ownedRendererDetail.relocationID,
        }
        if (reason === 'snap' || reason === 'page' || reason === 'scroll')
            this.history.replaceState(cfi)
            this.#emit('relocate', this.lastLocation)
            }
    #onLoad({ doc, location, index }) {
        // set language and dir if not already set
        doc.documentElement.lang ||= this.language.canonical ?? ''
        if (!this.language.isCJK)
            doc.documentElement.dir ||= this.language.direction ?? ''

        this.#handleLinks(doc, index)
        this.#emit('load', { doc, location, index })
    }
    #handleLinks(doc, index) {
        const scope = this.#documentScope(doc)
        if (!scope) return
        const { book } = this
        const section = book.sections[index]
        for (const a of doc.querySelectorAll('a[href]'))
            this.#listenInDocumentScope(scope, a, 'click', e => {
                if (!this.#isDocumentScopeCurrent(scope)) return
                e.preventDefault()
                const href_ = a.getAttribute('href')
                const href = section?.resolveHref?.(href_) ?? href_
                if (book?.isExternal?.(href))
                    Promise.resolve(this.#emit('external-link', { a, href }, true))
                    .then(x => this.#isDocumentScopeCurrent(scope) && x
                        ? globalThis.open(href, '_blank')
                        : null)
                    .catch(e => console.error(e))
                    else Promise.resolve(this.#emit('link', { a, href }, true))
                        .then(async x => this.#isDocumentScopeCurrent(scope) && x
                            ? await this.goTo(href)
                            : null)
                        .catch(e => console.error(e))
                        }, false)
            }
    async addAnnotation(
        annotation,
        remove,
        documentScope = null,
        operationIsCurrent = null
    ) {
        const openGeneration = this.#openGeneration
        const isCurrent = () =>
            this.#openGeneration === openGeneration
            && (!documentScope || this.#isDocumentScopeCurrent(documentScope))
            && (!operationIsCurrent || operationIsCurrent())
        if (!isCurrent()) return
        const { value } = annotation
        if (value.startsWith(SEARCH_PREFIX)) {
            const cfi = value.replace(SEARCH_PREFIX, '')
            const { index, anchor } = await this.resolveNavigation(cfi)
            if (!isCurrent()) return
            const obj = this.#getOverlayer(index)
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
        const { index, anchor } = await this.resolveNavigation(value)
        if (!isCurrent()) return
        const obj = this.#getOverlayer(index)
        if (obj) {
            const { overlayer, doc } = obj
            overlayer.remove(value)
            if (!remove) {
                const range = doc ? anchor(doc) : anchor
                const draw = (func, opts) => overlayer.add(value, range, func, opts)
                this.#emit('draw-annotation', { draw, annotation, doc, range })
            }
        }
        const label = this.#tocProgress.getProgress(index)?.label ?? ''
        return { index, label }
    }
    deleteAnnotation(annotation) {
        return this.addAnnotation(annotation, true)
    }
    #getOverlayer(index) {
        return this.renderer.getContents()
        .find(x => x.index === index && x.overlayer)
    }
    #createOverlayer({ doc, index }) {
        const scope = this.#documentScope(doc)
        const overlayer = new Overlayer()
        this.#listenInDocumentScope(scope, doc, 'click', e => {
            if (!this.#isDocumentScopeCurrent(scope)) return
            const [value, range] = overlayer.hitTest(e)
            if (value && !value.startsWith(SEARCH_PREFIX)) {
                this.#emit('show-annotation', { value, range })
            }
        }, false)

        const list = this.#searchResults.get(index)
        if (list) for (const item of list) {
            void this.addAnnotation(item, false, scope)
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
    async goTo(target, {
        returnMovementResult = false,
        isCurrent = () => true,
        navigationIntent = null,
        ...rendererOptions
    } = {}) {
        //        this.#emit('is-loading', true)
        const rejectedResult = returnMovementResult ? false : null
        if (!isCurrent()) return rejectedResult
        const resolved = this.resolveNavigation(target)
        if (!resolved || !isCurrent()) return rejectedResult
        const rendererNavigationIntent = snapshotReaderNavigationIntent(navigationIntent)
        try {
            const result = await this.#runRendererNavigation(
                renderer => renderer.goTo(resolved, {
                    ...rendererOptions,
                    navigationIntent: rendererNavigationIntent,
                    navigationIsCurrent: isCurrent,
                })
            )
            if (!readerNavigationResultReachedTarget(result) || !isCurrent()) {
                return rejectedResult
            }
            if (readerNavigationResultWasCommitted(result)) {
                this.history.pushState(target)
            }
            return returnMovementResult ? result : resolved
        } catch(e) {
            console.error(e)
            console.error(`Could not go to ${target}`)
            throw e
            //            return
        }
        //        this.#emit('is-loading', false)
        //        return resolved
    }
    async goToFraction(frac, {
        returnMovementResult = false,
        isCurrent = () => true,
        navigationIntent = null,
        ...rendererOptions
    } = {}) {
        if (!isCurrent()) return false
        const [index, anchor] = this.#sectionProgress.getSection(frac)
        const rendererNavigationIntent = snapshotReaderNavigationIntent(navigationIntent)
        const result = await this.#runRendererNavigation(
            renderer => renderer.goTo({ index, anchor }, {
                ...rendererOptions,
                navigationIntent: rendererNavigationIntent,
                navigationIsCurrent: isCurrent,
            })
        )
        if (!readerNavigationResultReachedTarget(result) || !isCurrent()) return false
        if (readerNavigationResultWasCommitted(result)) {
            this.history.pushState({ fraction: frac })
        }
        return returnMovementResult ? result : true
    }
    async select(target, options = {}) {
        try {
            const obj = await this.resolveNavigation(target)
            return await this.#navigateAndPush(
                renderer => renderer.goTo({ ...obj, select: true }, options),
                target
            )
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
    async getNavigationProgressOf(target) {
        try {
            const { index, anchor } = await this.resolveNavigation(target)
            const doc = await this.book.sections[index].createDocument()
            let range = null
            if (typeof anchor === 'function') {
                const frag = anchor(doc)
                if (frag instanceof Range) {
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
    async prev(distance, options = {}) {
        return await this.#runRendererNavigation(renderer =>
            renderer.prev(distance, options))
    }
    async next(distance, options = {}) {
        return await this.#runRendererNavigation(renderer =>
            renderer.next(distance, options))
    }
    async goLeft(options = {}) {
        const book = this.book
        if (!book) return rendererNavigationNotOwned('viewRendererUnavailable')
        const method = book.dir === 'rtl' ? 'next' : 'prev'
        return method === 'next'
            ? await this.next(undefined, options)
            : await this.prev(undefined, options)
    }
    async goRight(options = {}) {
        const book = this.book
        if (!book) return rendererNavigationNotOwned('viewRendererUnavailable')
        const method = book.dir === 'rtl' ? 'prev' : 'next'
        return method === 'prev'
            ? await this.prev(undefined, options)
            : await this.next(undefined, options)
    }
    #isSearchCurrent(owner) {
        return owner.generation === this.#searchGeneration
            && owner.openGeneration === this.#openGeneration
            && owner.book === this.book
            && owner.renderer === this.renderer
    }
    async * #searchSection(matcher, query, index, owner) {
        const section = owner.book?.sections?.[index]
        if (!section?.createDocument) return
        const doc = await section.createDocument()
        if (!this.#isSearchCurrent(owner)) return
        for (const { range, excerpt } of matcher(doc, query)) {
            if (!this.#isSearchCurrent(owner)) return
            yield { cfi: this.getCFI(index, range), excerpt }
        }
    }
    async * #searchBook(matcher, query, owner) {
        const { sections } = owner.book
        for (const [index, { createDocument }] of sections.entries()) {
            if (!this.#isSearchCurrent(owner)) return
            if (!createDocument) continue
            const doc = await createDocument()
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
            { defaultLocale: this.language, ...opts })
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
                    await this.addAnnotation(item, false, null, isCurrent)
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
                    await this.addAnnotation(item, false, null, isCurrent)
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
                await this.addAnnotation(item, true, null, isCurrentRenderer)
                if (!isCurrentRenderer()) return
            }
        })
        const settledCleanup = cleanup.catch(error => console.error(error))
        this.#searchCleanup = settledCleanup
        return settledCleanup
    }
}

customElements.define('foliate-view', View)
