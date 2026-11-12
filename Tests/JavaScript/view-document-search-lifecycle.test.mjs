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
    '../../Sources/LakeOfFireReader/Resources/foliate-js/view.js'
)

const makeSearchDocument = text => {
    const textNode = { nodeType: 3, nodeValue: text }
    return {
        body: { lang: 'en' },
        documentElement: { lang: 'en' },
        querySelectorAll(selector) {
            assert.equal(selector, 'a[href]')
            return [] // This text-only search document has no anchors.
        },
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

const waitForStage = async predicate => {
    const deadline = Date.now() + 10_000
    while (!predicate()) {
        assert.ok(Date.now() < deadline, 'Lifecycle stage was not reached')
        await new Promise(resolve => setImmediate(resolve))
    }
}

const collectAsync = async iterable => {
    const values = []
    for await (const value of iterable) values.push(value)
    return values
}

// Retained lifecycle regressions exercise the current production View directly.
// Browser/renderer collaborators are controlled here; layout and WKWebView are
// verified separately. Current document retirement uses its pagehide binding.

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

test('View forwards the exact current load receipt and ignores detached renderer receipts', async () => {
    const first = new FakeRenderer(), second = new FakeRenderer(), renderers = [first, second]
    globalThis.__viewRendererFactory = () => renderers.shift()
    const view = new View(), receipts = []
    view.addEventListener('load', event => receipts.push(event.detail))
    const firstDocument = makeLoadedDocument(new FakeAnchor('first.xhtml'))
    const firstReceipt = { doc: firstDocument, index: 0, location: firstDocument.location.href }
    const secondDocument = makeLoadedDocument(new FakeAnchor('second.xhtml'))
    const secondReceipt = { doc: secondDocument, index: 0, location: secondDocument.location.href }
    try {
        await view.open(makeLinkedBook('first', 0))
        first.dispatchEvent(new CustomEvent('load', { detail: firstReceipt }))
        assert.equal(receipts.length, 1)
        assert.equal(receipts[0].doc, firstDocument)
        assert.equal(receipts[0].location, firstReceipt.location)
        assert.equal(receipts[0].index, 0)
        await view.open(makeLinkedBook('second', 0))
        first.dispatchEvent(new CustomEvent('load', { detail: firstReceipt }))
        assert.equal(receipts.length, 1)
        second.dispatchEvent(new CustomEvent('load', { detail: secondReceipt }))
        assert.equal(receipts.length, 2)
        assert.equal(receipts[1].doc, secondDocument)
        assert.equal(receipts[1].location, secondReceipt.location)
        view.close()
        assert.equal(first.listenerCount('load'), 0)
        assert.equal(second.listenerCount('load'), 0)
        second.dispatchEvent(new CustomEvent('load', { detail: secondReceipt }))
        assert.equal(receipts.length, 2)
    } finally { view.close() }
})

test('pagehide removes View-owned link navigation from the detached document', async () => {
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

    doc.dispatchEvent(new Event('pagehide'))
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
    await waitForStage(() => createDocumentCalls >= 1)

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
    await waitForStage(() => createDocumentStarted)
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
    await waitForStage(() => removalStarted)
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


const makePartitionedSearchDocument = (parts, boundary = 'inline') => {
    const doc = makeSearchDocument('')
    doc.body.localName = 'body'
    doc.body.lang = ''
    doc.documentElement.lang = ''
    const first = { localName: 'p', parentElement: doc.body }
    const second = boundary === 'block' ? { localName: 'p', parentElement: doc.body } : first
    const nodes = parts.map((nodeValue, index) => ({ nodeType: 3, nodeValue,
        parentElement: index === 0 ? first : second }))
    doc.searchTextNodes = [...nodes]
    if (boundary === 'line' || boundary === 'empty') nodes.splice(1, 0, { nodeType: 1,
        localName: boundary === 'line' ? 'br' : 'div', parentElement: first })
    doc.createTreeWalker = (_root, _mask, { acceptNode }) => {
        let index = 0
        return { nextNode() {
            while (index < nodes.length) {
                const node = nodes[index++]
                if (acceptNode(node) === NodeFilter.FILTER_ACCEPT) return node
            }
            return null
        } }
    }
    return doc
}

for (const [boundary, query, expected, expectedRange] of [
    ['inline', 'reading', ['reading'], [0, 0, 1, 3]],
    ['inline', 'read', []],
    ['block', 'read', ['read'], [0, 0, 0, 4]],
    ['block', 'reading', []],
    ['line', 'read', ['read'], [0, 0, 0, 4]],
    ['line', 'reading', []],
    ['empty', 'reading', []],
    ['empty', 'read', ['read'], [0, 0, 0, 4]],
    ['empty', 'read ing', ['read\ning'], [0, 0, 1, 3]],
    ['block', 'read ing', ['read\ning'], [0, 0, 1, 3]],
    ['line', 'read ing', ['read\ning'], [0, 0, 1, 3]],
    ['block', ' ing', ['\ning'], [0, 4, 1, 3]],
    ['line', 'read ', ['read\n'], [0, 0, 1, 0]],
]) {
    test(`View whole-word search respects ${boundary} boundaries for ${query}`, async () => {
        globalThis.__viewRendererFactory = () => new FakeRenderer()
        const view = new View()
        const book = makeBook()
        const doc = makePartitionedSearchDocument(['read', 'ing'], boundary)
        book.sections = [{ createDocument: async () => doc }]
        view.getCFI = (_index, range) => {
            assert.ok(expectedRange)
            const [startIndex, startOffset, endIndex, endOffset] = expectedRange
            assert.equal(range.startNode, doc.searchTextNodes[startIndex])
            assert.equal(range.startOffset, startOffset)
            assert.equal(range.endNode, doc.searchTextNodes[endIndex])
            assert.equal(range.endOffset, endOffset)
            return 'matched'
        }
        view.addAnnotation = async () => {}
        try {
            await view.open(book)
            const results = await collectAsync(view.search({ query, index: 0, matchWholeWords: true }))
            assert.deepEqual(results.filter(x => x?.excerpt).map(x => x.excerpt.match), expected)
        } finally { view.close() }
    })
}

for (const [chapterLanguage, query] of [['', 'ı'], ['en', 'i']]) {
    test(`View search uses book language only when chapter language is absent (${chapterLanguage || 'none'})`, async () => {
        globalThis.__viewRendererFactory = () => new FakeRenderer()
        const view = new View()
        const doc = makeSearchDocument('I rest')
        doc.body.lang = chapterLanguage
        doc.documentElement.lang = chapterLanguage
        const book = makeBook()
        book.metadata.language = 'tr'
        book.sections = [{ createDocument: async () => doc }]
        view.getCFI = () => 'matched'
        view.addAnnotation = async () => {}
        try {
            await view.open(book)
            const results = await collectAsync(view.search({ query, index: 0, matchDiacritics: true }))
            assert.deepEqual(results.filter(x => x?.excerpt).map(x => x.excerpt.match), ['I'])
        } finally { view.close() }
    })
}

for (const scope of ['section', 'book']) {
    test(`closing View retires a rejected real EPUB ${scope} search read`, async () => {
        const originalDOMParser = globalThis.DOMParser
        let parseCount = 0
        globalThis.DOMParser = class { parseFromString() { parseCount++; throw new Error('retired content parsed') } }
        const { EPUB } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/epub.js')
        let release
        let started
        const reading = new Promise(resolve => { started = resolve })
        const source = new EPUB({ loadText: () => {
            started()
            return new Promise(resolve => { release = resolve })
        }, loadBlob: async () => null, getSize: () => 0 })
        globalThis.__viewRendererFactory = () => new FakeRenderer()
        const view = new View()
        const book = makeBook()
        book.destroy = () => source.destroy()
        book.sections = [{ createDocument: () => source.loadDocument({ href: 'chapter.xhtml', mediaType: 'application/xhtml+xml' }) }]
        const annotations = []
        view.addAnnotation = async value => { annotations.push(value) }
        try {
            await view.open(book)
            const pending = collectAsync(view.search({ query: 'alpha', ...(scope === 'section' ? { index: 0 } : {}) }))
            await reading
            view.close()
            release('<html/>')
            assert.deepEqual(await pending, [])
            assert.deepEqual(annotations, [])
            assert.equal(parseCount, 0)
        } finally {
            release?.('<html/>')
            view.close()
            source.destroy()
            globalThis.DOMParser = originalDOMParser
        }
    })

    test(`a current ${scope} search still reports its document-load failure`, async () => {
        globalThis.__viewRendererFactory = () => new FakeRenderer()
        const view = new View()
        const failure = new Error('current document read failed')
        const book = makeBook()
        book.sections = [{ createDocument: async () => { throw failure } }]
        try {
            await view.open(book)
            await assert.rejects(collectAsync(view.search({ query: 'alpha', ...(scope === 'section' ? { index: 0 } : {}) })), error => error === failure)
        } finally { view.close() }
    })
}


const makeLanguageElement = ({lang, xmlLang, serializedXMLLang} = {}) => {
    let htmlLanguage = lang
    return {
        get lang() { return htmlLanguage ?? '' },
        set lang(value) { htmlLanguage = value },
        dir: '',
        getAttribute(name) {
            return name === 'lang' ? htmlLanguage ?? null
                : name === 'xml:lang' ? serializedXMLLang ?? xmlLang ?? null : null
        },
        getAttributeNS(namespace, name) {
            return namespace === 'http://www.w3.org/XML/1998/namespace' && name === 'lang'
                ? xmlLang ?? null : null
        },
    }
}

for (const [name, body, html, bookLanguage, expectedQuery, expectedRootLanguage, expectedDirection] of [
    ['XML root', {}, {xmlLang:'en'}, 'tr', 'i', null, 'ltr'],
    ['XML body before HTML root', {xmlLang:'en'}, {lang:'tr'}, 'tr', 'i', 'tr', 'ltr'],
    ['XML wins on the same element', {}, {xmlLang:'en',lang:'tr'}, 'tr', 'i', 'tr', 'ltr'],
    ['explicit unknown XML root', {}, {xmlLang:''}, 'tr', 'i', null, ''],
    ['explicit unknown XML body', {xmlLang:''}, {lang:'tr'}, 'tr', 'i', 'tr', ''],
    ['HTML body before XML root', {lang:'en'}, {xmlLang:'tr'}, 'tr', 'i', null, 'ltr'],
    ['HTML-serialized XML declaration', {}, {serializedXMLLang:'en'}, 'tr', 'i', null, 'ltr'],
    ['package fallback', {}, {}, 'tr', 'ı', 'tr', 'ltr'],
    ['XML Arabic direction', {}, {xmlLang:'ar'}, 'en', 'i', null, 'rtl'],
]) {
    test(`View preserves chapter language and derived direction: ${name}`, async () => {
        const renderer = new FakeRenderer()
        globalThis.__viewRendererFactory = () => renderer
        const view = new View()
        const doc = makeSearchDocument('I')
        doc.body = makeLanguageElement(body)
        doc.documentElement = makeLanguageElement(html)
        const book = makeBook()
        book.metadata.language = bookLanguage
        book.sections = [{createDocument:async () => doc}]
        view.getCFI = (_index, range) => {
            assert.equal(range.startOffset, 0)
            assert.equal(range.endOffset, 1)
            return 'language-match'
        }
        view.addAnnotation = async () => {}
        try {
            await view.open(book)
            for (const query of ['i','ı']) {
                const results = await collectAsync(view.search({query,index:0,matchDiacritics:true}))
                assert.deepEqual(results.filter(x => x?.excerpt).map(x => x.excerpt.match),
                    query === expectedQuery ? ['I'] : [], query)
            }
            renderer.dispatchEvent(new CustomEvent('load', {detail:{doc,index:0}}))
            assert.equal(doc.documentElement.getAttribute('lang'), expectedRootLanguage)
            assert.equal(doc.documentElement.dir, expectedDirection)
        } finally { view.close() }
    })
}
