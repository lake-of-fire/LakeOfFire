import assert from 'node:assert/strict'
import test from 'node:test'

class FakeNode extends EventTarget {
    constructor() {
        super()
        this.children = []
        this.parentElement = null
        this.style = { setProperty() {} }
        this.dataset = {}
        this.attributes = new Map()
    }
    append(...children) {
        for (const child of children) {
            child.parentElement = this
            this.children.push(child)
        }
    }
    remove() {
        if (this.parentElement) {
            this.parentElement.children = this.parentElement.children.filter(
                child => child !== this
            )
            this.parentElement = null
        }
        this.removed = true
    }
    setAttribute(name, value) { this.attributes.set(name, String(value)) }
    getAttribute(name) { return this.attributes.get(name) ?? null }
}

class FakeShadowRoot extends FakeNode {}

class FakeHTMLElement extends FakeNode {
    attachShadow() {
        this.shadowRoot = new FakeShadowRoot()
        return this.shadowRoot
    }
}

class FakeRenderer extends FakeHTMLElement {
    constructor(openOperation = null) {
        super()
        this.openOperation = openOperation
        this.goToOperation = async () => true
        this.nextOperation = async () => true
        this.goToCalls = []
        this.destroyed = false
        this.listeners = new Map()
    }
    addEventListener(type, listener, options) {
        super.addEventListener(type, listener, options)
        const listeners = this.listeners.get(type) ?? new Set()
        listeners.add(listener)
        this.listeners.set(type, listeners)
    }
    removeEventListener(type, listener, options) {
        super.removeEventListener(type, listener, options)
        this.listeners.get(type)?.delete(listener)
    }
    listenerCount(type) { return this.listeners.get(type)?.size ?? 0 }
    async open(book) {
        this.book = book
        await this.openOperation?.()
    }
    async goTo(target) {
        this.goToCalls.push(target)
        return await this.goToOperation(target)
    }
    async next(distance, options) {
        return await this.nextOperation(distance, options)
    }
    destroy() { this.destroyed = true }
}

class FakeAnchor extends FakeNode {
    constructor(href) {
        super()
        this.href = href
    }
    getAttribute(name) {
        if (name === 'href') return this.href
        return super.getAttribute(name)
    }
}

const makeLoadedDocument = (anchor, href = 'ebook://book/section.xhtml') => {
    const doc = new EventTarget()
    doc.documentElement = { lang: '', dir: '' }
    doc.location = { href }
    doc.querySelectorAll = selector => selector === 'a[href]' ? [anchor] : []
    return doc
}

globalThis.HTMLElement = FakeHTMLElement
globalThis.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
}
globalThis.CSSStyleSheet = class { replaceSync() {} }
globalThis.CustomEvent = class extends Event {
    constructor(type, options = {}) {
        super(type, options)
        this.detail = options.detail
    }
}
globalThis.customElements = { define() {} }
globalThis.NodeFilter = {
    SHOW_ELEMENT: 1,
    SHOW_TEXT: 4,
    SHOW_CDATA_SECTION: 8,
    FILTER_ACCEPT: 1,
    FILTER_REJECT: 2,
    FILTER_SKIP: 3,
}

globalThis.__viewRendererFactory = () => new FakeRenderer()
globalThis.document = {
    createElement(name) {
        if (name === 'foliate-fxl') return globalThis.__viewRendererFactory()
        return new FakeNode()
    },
}

const { View } = await import(
    '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/view.js'
)

const makeSearchDocument = text => {
    const textNode = { nodeType: 3, nodeValue: text }
    return {
        body: { lang: 'en' },
        documentElement: { lang: 'en' },
        createTreeWalker() {
            let returned = false
            return {
                nextNode() {
                    if (returned) return null
                    returned = true
                    return textNode
                },
            }
        },
        createRange() {
            return {
                setStart(node, offset) {
                    this.startNode = node
                    this.startOffset = offset
                },
                setEnd(node, offset) {
                    this.endNode = node
                    this.endOffset = offset
                },
            }
        },
    }
}

const collectAsync = async iterable => {
    const values = []
    for await (const value of iterable) values.push(value)
    return values
}

test('history deduplicates a repeated zero fraction', async () => {
    const view = new View()
    const visited = []
    view.resolveNavigation = state => state
    view.renderer = {
        goTo: async state => {
            visited.push(state)
            return true
        },
    }

    view.history.pushState({ fraction: 0 })
    view.history.pushState({ fraction: 0 })
    view.history.pushState({ fraction: 0.5 })

    assert.equal(await view.history.back(), true)
    assert.deepEqual(visited, [{ fraction: 0 }])
    assert.equal(view.history.canGoBack, false)
    assert.equal(view.history.canGoForward, true)
    view.close()
})

const makeBook = () => ({
    metadata: { language: 'en' },
    destroyCount: 0,
    destroy() { this.destroyCount += 1 },
    sections: [],
    rendition: {
        layout: 'pre-paginated',
        spread: 'none',
        viewport: { width: 1000, height: 1000 },
    },
})

const makeLinkedBook = (name, index) => {
    const book = makeBook()
    book.sections = [{
        resolveHref: href => `${name}:${href}`,
    }]
    book.isExternal = () => false
    book.resolveHref = href => ({ index, href })
    return book
}

test('view close detaches renderer listeners and clears renderer ownership', async () => {
    const renderer = new FakeRenderer()
    globalThis.__viewRendererFactory = () => renderer
    const view = new View()
    const book = makeBook()
    let externalCleanupCount = 0

    assert.equal(await view.open(book), true)
    view.registerCleanup(() => { externalCleanupCount += 1 })
    assert.equal(renderer.listenerCount('load'), 1)
    assert.equal(renderer.listenerCount('document-committed'), 1)
    assert.equal(renderer.listenerCount('document-unload'), 1)
    assert.equal(renderer.listenerCount('relocate'), 1)
    assert.equal(renderer.listenerCount('create-overlayer'), 1)

    view.close()

    assert.equal(view.renderer, null)
    assert.equal(renderer.destroyed, true)
    assert.equal(renderer.removed, true)
    assert.equal(renderer.listenerCount('load'), 0)
    assert.equal(renderer.listenerCount('document-committed'), 0)
    assert.equal(renderer.listenerCount('document-unload'), 0)
    assert.equal(renderer.listenerCount('relocate'), 0)
    assert.equal(renderer.listenerCount('create-overlayer'), 0)
    assert.equal(externalCleanupCount, 1)
    assert.equal(book.destroyCount, 1)
})

test('view close supersedes a pending renderer open', async () => {
    let releaseOpen
    const renderer = new FakeRenderer(() => new Promise(resolve => {
        releaseOpen = resolve
    }))
    globalThis.__viewRendererFactory = () => renderer
    const view = new View()
    const book = makeBook()

    const openPromise = view.open(book)
    while (!releaseOpen) await new Promise(resolve => setImmediate(resolve))

    view.close()
    releaseOpen()

    assert.equal(await openPromise, false)
    assert.equal(view.renderer, null)
    assert.equal(renderer.destroyed, true)
    assert.equal(renderer.removed, true)
    assert.equal(view.shadowRoot.children.length, 0)
    assert.equal(book.destroyCount, 1)
})

test('reopening a view transfers renderer ownership exactly once', async () => {
    const firstRenderer = new FakeRenderer()
    const secondRenderer = new FakeRenderer()
    const renderers = [firstRenderer, secondRenderer]
    globalThis.__viewRendererFactory = () => renderers.shift()
    const view = new View()
    const firstBook = makeBook()
    const secondBook = makeBook()

    assert.equal(await view.open(firstBook), true)
    assert.equal(firstRenderer.listenerCount('load'), 1)
    assert.equal(await view.open(secondBook), true)

    assert.equal(firstRenderer.listenerCount('load'), 0)
    assert.equal(firstRenderer.destroyed, true)
    assert.equal(firstBook.destroyCount, 1)
    assert.equal(secondBook.destroyCount, 0)
    assert.equal(secondRenderer.listenerCount('load'), 1)
    assert.equal(secondRenderer.listenerCount('relocate'), 1)
    assert.equal(view.renderer, secondRenderer)
})

test('view forwards exact document commit and unload events only from its current renderer', async () => {
    const firstRenderer = new FakeRenderer()
    const secondRenderer = new FakeRenderer()
    const renderers = [firstRenderer, secondRenderer]
    globalThis.__viewRendererFactory = () => renderers.shift()
    const view = new View()
    const events = []
    view.addEventListener('document-committed', event => {
        events.push(['committed', event.detail])
    })
    view.addEventListener('document-unload', event => {
        events.push(['unload', event.detail])
    })

    assert.equal(await view.open(makeBook()), true)
    const firstDetail = { doc: {}, index: 0 }
    firstRenderer.dispatchEvent(new CustomEvent('document-committed', {
        detail: firstDetail,
    }))
    firstRenderer.dispatchEvent(new CustomEvent('document-unload', {
        detail: { ...firstDetail, reason: 'first-replaced' },
    }))

    assert.equal(await view.open(makeBook()), true)
    firstRenderer.dispatchEvent(new CustomEvent('document-committed', {
        detail: { doc: {}, index: 99 },
    }))
    const secondDetail = { doc: {}, index: 1 }
    secondRenderer.dispatchEvent(new CustomEvent('document-committed', {
        detail: secondDetail,
    }))
    secondRenderer.dispatchEvent(new CustomEvent('document-unload', {
        detail: { ...secondDetail, reason: 'second-closed' },
    }))

    assert.deepEqual(events, [
        ['committed', firstDetail],
        ['unload', { ...firstDetail, reason: 'first-replaced' }],
        ['committed', secondDetail],
        ['unload', { ...secondDetail, reason: 'second-closed' }],
    ])
})

test('document unload removes View-owned link navigation from the detached document', async () => {
    const renderer = new FakeRenderer()
    globalThis.__viewRendererFactory = () => renderer
    const view = new View()
    const anchor = new FakeAnchor('next.xhtml')
    const doc = makeLoadedDocument(anchor)
    let linkEvents = 0
    view.addEventListener('link', () => { linkEvents += 1 })

    assert.equal(await view.open(makeLinkedBook('first', 0)), true)
    renderer.dispatchEvent(new CustomEvent('load', {
        detail: { doc, index: 0, location: doc.location.href },
    }))
    anchor.dispatchEvent(new Event('click', { cancelable: true }))
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(linkEvents, 1)
    assert.deepEqual(renderer.goToCalls, [{ index: 0, href: 'first:next.xhtml' }])

    renderer.dispatchEvent(new CustomEvent('document-unload', {
        detail: { doc, index: 0, location: doc.location.href },
    }))
    anchor.dispatchEvent(new Event('click', { cancelable: true }))
    await new Promise(resolve => setImmediate(resolve))

    assert.equal(linkEvents, 1)
    assert.equal(renderer.goToCalls.length, 1)
    view.close()
})

test('reopening View prevents a detached old document from navigating the replacement book', async () => {
    const firstRenderer = new FakeRenderer()
    const secondRenderer = new FakeRenderer()
    const renderers = [firstRenderer, secondRenderer]
    globalThis.__viewRendererFactory = () => renderers.shift()
    const view = new View()
    const anchor = new FakeAnchor('old-target.xhtml')
    const doc = makeLoadedDocument(anchor)
    let linkEvents = 0
    view.addEventListener('link', () => { linkEvents += 1 })

    assert.equal(await view.open(makeLinkedBook('first', 0)), true)
    firstRenderer.dispatchEvent(new CustomEvent('load', {
        detail: { doc, index: 0, location: doc.location.href },
    }))
    assert.equal(await view.open(makeLinkedBook('second', 1)), true)

    anchor.dispatchEvent(new Event('click', { cancelable: true }))
    await new Promise(resolve => setImmediate(resolve))

    assert.equal(linkEvents, 0)
    assert.deepEqual(secondRenderer.goToCalls, [])
    view.close()
})

test('closing View fences an already queued external-link continuation', async () => {
    const renderer = new FakeRenderer()
    globalThis.__viewRendererFactory = () => renderer
    const view = new View()
    const anchor = new FakeAnchor('https://example.invalid/stale')
    const doc = makeLoadedDocument(anchor)
    const book = makeLinkedBook('first', 0)
    book.isExternal = () => true
    const opened = []
    const originalOpen = globalThis.open
    globalThis.open = (...args) => { opened.push(args) }

    try {
        assert.equal(await view.open(book), true)
        renderer.dispatchEvent(new CustomEvent('load', {
            detail: { doc, index: 0, location: doc.location.href },
        }))
        anchor.dispatchEvent(new Event('click', { cancelable: true }))
        view.close()
        await new Promise(resolve => setImmediate(resolve))

        assert.deepEqual(opened, [])
    } finally {
        globalThis.open = originalOpen
        view.close()
    }
})

test('a suspended annotation operation cannot publish into a replacement renderer', async () => {
    const firstRenderer = new FakeRenderer()
    const secondRenderer = new FakeRenderer()
    const renderers = [firstRenderer, secondRenderer]
    globalThis.__viewRendererFactory = () => renderers.shift()
    const view = new View()
    let releaseResolution = null
    const resolutionGate = new Promise(resolve => { releaseResolution = resolve })
    let replacementRemovals = 0
    secondRenderer.getContents = () => [{
        index: 0,
        doc: {},
        overlayer: {
            remove() { replacementRemovals += 1 },
        },
    }]
    view.resolveNavigation = async () => {
        await resolutionGate
        return { index: 0, anchor: () => ({}) }
    }

    assert.equal(await view.open(makeBook()), true)
    const pendingAnnotation = view.addAnnotation({ value: 'old-book-target' })
    assert.equal(await view.open(makeBook()), true)
    releaseResolution?.()
    await pendingAnnotation

    assert.equal(replacementRemovals, 0)
    view.close()
})


test('book metadata setup failure releases the exact book ownership', async () => {
    const failure = new Error('book metadata failed')
    const book = makeBook()
    Object.defineProperty(book, 'metadata', {
        get() { throw failure },
    })
    const view = new View()

    await assert.rejects(view.open(book), failure)

    assert.equal(view.renderer, null)
    assert.equal(view.book, null)
    assert.equal(book.destroyCount, 1)
})

test('renderer construction failure releases the exact book ownership', async () => {
    const failure = new Error('renderer construction failed')
    globalThis.__viewRendererFactory = () => { throw failure }
    const view = new View()
    const book = makeBook()

    await assert.rejects(view.open(book), failure)

    assert.equal(view.renderer, null)
    assert.equal(view.book, null)
    assert.equal(book.destroyCount, 1)
    assert.equal(view.shadowRoot.children.length, 0)
})

test('failed renderer open releases renderer and book ownership', async () => {
    const failure = new Error('renderer open failed')
    const renderer = new FakeRenderer(async () => { throw failure })
    globalThis.__viewRendererFactory = () => renderer
    const view = new View()
    const book = makeBook()

    await assert.rejects(view.open(book), failure)

    assert.equal(view.renderer, null)
    assert.equal(view.book, null)
    assert.equal(renderer.destroyed, true)
    assert.equal(renderer.removed, true)
    assert.equal(renderer.listenerCount('load'), 0)
    assert.equal(book.destroyCount, 1)
})

test('physical navigation without a current view is explicitly non-owning', async () => {
    const view = new View()
    assert.deepEqual(await view.goLeft(), {
        ignored: true,
        reason: 'viewRendererUnavailable',
    })
    assert.deepEqual(await view.goRight(), {
        ignored: true,
        reason: 'viewRendererUnavailable',
    })
})

test('physical navigation from an outgoing renderer is reported as non-owning', async () => {
    const firstRenderer = new FakeRenderer()
    const secondRenderer = new FakeRenderer()
    const renderers = [firstRenderer, secondRenderer]
    globalThis.__viewRendererFactory = () => renderers.shift()
    const view = new View()

    assert.equal(await view.open(makeBook()), true)
    firstRenderer.nextOperation = async () => {
        assert.equal(await view.open(makeBook()), true)
        return true
    }

    assert.deepEqual(await view.next(), {
        ignored: true,
        reason: 'viewRendererSuperseded',
    })
    assert.equal(view.renderer, secondRenderer)
})

test('accepted navigation from an outgoing renderer cannot enter replacement history', async () => {
    const firstRenderer = new FakeRenderer()
    const secondRenderer = new FakeRenderer()
    const renderers = [firstRenderer, secondRenderer]
    globalThis.__viewRendererFactory = () => renderers.shift()
    const view = new View()

    assert.equal(await view.open(makeBook()), true)
    firstRenderer.goToOperation = async () => {
        assert.equal(await view.open(makeBook()), true)
        return true
    }

    assert.equal(await view.goTo(0), null)
    assert.equal(view.renderer, secondRenderer)
    view.history.pushState(1)
    assert.equal(view.history.canGoBack, false)
})

test('history commits only after the current renderer accepts navigation', async () => {
    const renderer = new FakeRenderer()
    globalThis.__viewRendererFactory = () => renderer
    const view = new View()
    assert.equal(await view.open(makeBook()), true)
    view.history.pushState(0)
    view.history.pushState(1)
    let indexChanges = 0
    view.history.addEventListener('index-change', () => { indexChanges += 1 })

    renderer.goToOperation = async () => undefined
    assert.equal(await view.history.back(), false)
    assert.equal(view.history.canGoBack, true)
    assert.equal(view.history.canGoForward, false)
    assert.equal(indexChanges, 0)

    const originalConsoleError = console.error
    console.error = () => {}
    renderer.goToOperation = async () => { throw new Error('history refused') }
    try {
        assert.equal(await view.history.back(), false)
    } finally {
        console.error = originalConsoleError
    }
    assert.equal(view.history.canGoBack, true)
    assert.equal(view.history.canGoForward, false)
    assert.equal(indexChanges, 0)

    renderer.goToOperation = async () => true
    assert.equal(await view.history.back(), true)
    assert.equal(view.history.canGoBack, false)
    assert.equal(view.history.canGoForward, true)
    assert.equal(indexChanges, 1)
})

test('a newer opposite history request prevents stale completion from committing', async () => {
    const renderer = new FakeRenderer()
    globalThis.__viewRendererFactory = () => renderer
    const view = new View()
    assert.equal(await view.open(makeBook()), true)
    view.history.pushState(0)
    view.history.pushState(1)

    const pending = []
    renderer.goToOperation = target => new Promise(resolve => {
        pending.push({ target, resolve })
    })

    const olderBack = view.history.back()
    while (pending.length < 1) await new Promise(resolve => setImmediate(resolve))
    const newerForward = view.history.forward()
    while (pending.length < 2) await new Promise(resolve => setImmediate(resolve))

    assert.equal(await olderBack, false)
    pending[0].resolve(true)
    pending[1].resolve(true)
    assert.equal(await newerForward, true)
    assert.deepEqual(renderer.goToCalls, [{ index: 0 }, { index: 1 }])
    assert.equal(view.history.canGoBack, true)
    assert.equal(view.history.canGoForward, false)
})


test('a newer search supersedes suspended search publication', async () => {
    const renderer = new FakeRenderer()
    globalThis.__viewRendererFactory = () => renderer
    const view = new View()
    let releaseFirstDocument
    const firstDocumentGate = new Promise(resolve => {
        releaseFirstDocument = resolve
    })
    let createDocumentCalls = 0
    const book = makeBook()
    book.sections = [{
        async createDocument() {
            createDocumentCalls += 1
            if (createDocumentCalls === 1) {
                await firstDocumentGate
                return makeSearchDocument('alpha suffix')
            }
            return makeSearchDocument('beta suffix')
        },
    }]
    const annotations = []
    view.getCFI = (_index, range) => `cfi-${range.startNode.nodeValue}`
    view.addAnnotation = async annotation => { annotations.push(annotation.value) }

    assert.equal(await view.open(book), true)
    const older = collectAsync(view.search({
        query: 'alpha',
        index: 0,
        matchCase: true,
        matchDiacritics: true,
    }))
    while (createDocumentCalls < 1) {
        await new Promise(resolve => setImmediate(resolve))
    }

    const newer = collectAsync(view.search({
        query: 'beta',
        index: 0,
        matchCase: true,
        matchDiacritics: true,
    }))
    const newerResults = await newer
    releaseFirstDocument?.()
    const olderResults = await older

    assert.deepEqual(olderResults, [])
    assert.deepEqual(annotations, ['foliate-search:cfi-beta suffix'])
    assert.equal(newerResults.at(-1), 'done')
    view.close()
})

test('reopening View prevents a suspended old-book search from publishing', async () => {
    const firstRenderer = new FakeRenderer()
    const secondRenderer = new FakeRenderer()
    const renderers = [firstRenderer, secondRenderer]
    globalThis.__viewRendererFactory = () => renderers.shift()
    const view = new View()
    let releaseDocument
    let createDocumentStarted = false
    const documentGate = new Promise(resolve => { releaseDocument = resolve })
    const firstBook = makeBook()
    firstBook.sections = [{
        async createDocument() {
            createDocumentStarted = true
            await documentGate
            return makeSearchDocument('alpha suffix')
        },
    }]
    const annotations = []
    view.getCFI = (_index, range) => `cfi-${range.startNode.nodeValue}`
    view.addAnnotation = async annotation => { annotations.push(annotation.value) }

    assert.equal(await view.open(firstBook), true)
    const pending = collectAsync(view.search({
        query: 'alpha',
        index: 0,
        matchCase: true,
        matchDiacritics: true,
    }))
    while (!createDocumentStarted) {
        await new Promise(resolve => setImmediate(resolve))
    }
    assert.equal(await view.open(makeBook()), true)
    releaseDocument?.()

    assert.deepEqual(await pending, [])
    assert.deepEqual(annotations, [])
    assert.equal(view.renderer, secondRenderer)
    view.close()
})

test('a replacement search waits for prior annotation cleanup before publishing', async () => {
    const renderer = new FakeRenderer()
    globalThis.__viewRendererFactory = () => renderer
    const view = new View()
    let createDocumentCalls = 0
    const book = makeBook()
    book.sections = [{
        async createDocument() {
            createDocumentCalls += 1
            return makeSearchDocument(
                createDocumentCalls === 1 ? 'alpha suffix' : 'beta suffix'
            )
        },
    }]
    view.getCFI = (_index, range) => `cfi-${range.startNode.nodeValue}`

    let releaseRemoval
    let removalStarted = false
    const removalGate = new Promise(resolve => { releaseRemoval = resolve })
    const events = []
    view.addAnnotation = async (annotation, remove) => {
        if (remove) {
            removalStarted = true
            await removalGate
            events.push(`remove:${annotation.value}`)
        } else {
            events.push(`add:${annotation.value}`)
        }
    }

    assert.equal(await view.open(book), true)
    await collectAsync(view.search({
        query: 'alpha',
        index: 0,
        matchCase: true,
        matchDiacritics: true,
    }))
    assert.deepEqual(events, ['add:foliate-search:cfi-alpha suffix'])

    const replacement = collectAsync(view.search({
        query: 'beta',
        index: 0,
        matchCase: true,
        matchDiacritics: true,
    }))
    while (!removalStarted) {
        await new Promise(resolve => setImmediate(resolve))
    }
    await new Promise(resolve => setImmediate(resolve))

    assert.equal(createDocumentCalls, 1)
    assert.deepEqual(events, ['add:foliate-search:cfi-alpha suffix'])
    releaseRemoval?.()
    await replacement

    assert.deepEqual(events, [
        'add:foliate-search:cfi-alpha suffix',
        'remove:foliate-search:cfi-alpha suffix',
        'add:foliate-search:cfi-beta suffix',
    ])
    view.close()
})
