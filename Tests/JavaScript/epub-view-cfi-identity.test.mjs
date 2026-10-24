import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import test, { after } from 'node:test'

const require = createRequire(import.meta.url)
const { JSDOM } = require(process.env.JSDOM_MODULE ?? 'jsdom')
const window = new JSDOM('<!doctype html><html><body></body></html>').window
for (const name of [
    'document', 'HTMLElement', 'customElements', 'DOMParser', 'Range', 'Node',
    'NodeFilter', 'Event', 'EventTarget', 'CustomEvent',
]) globalThis[name] = window[name]
after(() => window.close())

const { EPUB } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/epub.js')
const { View } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/view.js')
const CFI = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/epubcfi.js')

const chapter = `<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title></head>
<body><main id="authored"><p id="paragraph">Alpha Beta Gamma</p></main></body></html>`

const openBook = async (t, {
    repeated = false,
    missing = true,
    prefixed = false,
    outsideItemref = false,
} = {}) => {
    const tag = name => prefixed ? `opf:${name}` : name
    const namespace = prefixed
        ? 'xmlns:opf="http://www.idpf.org/2007/opf"'
        : 'xmlns="http://www.idpf.org/2007/opf"'
    const files = new Map([
        ['META-INF/container.xml', `<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>
<rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>`],
        ['OPS/book.opf', `<${tag('package')} ${namespace} version="3.0" unique-identifier="publication">
<${tag('metadata')} xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="publication">view-cfi-identity</dc:identifier>
<dc:title>Identity</dc:title><dc:language>en</dc:language></${tag('metadata')}><${tag('manifest')}>
<${tag('item')} id="one" href="one.xhtml" media-type="application/xhtml+xml"/>
<${tag('item')} id="two" href="two.xhtml" media-type="application/xhtml+xml"/>
${outsideItemref ? `<${tag('itemref')} id="outside-spine" idref="one"/>` : ''}
</${tag('manifest')}><${tag('spine')}>
${missing ? `<${tag('itemref')} id="missing" idref="absent"/>` : ''}
<${tag('itemref')} id="first" idref="one"/><${tag('itemref')} id="second" idref="${repeated ? 'one' : 'two'}"/>
</${tag('spine')}></${tag('package')}>`],
        ['OPS/one.xhtml', chapter],
        ['OPS/two.xhtml', chapter],
    ])
    const book = new EPUB({
        loadText: async path => files.get(path) ?? null,
        loadBlob: async path => files.has(path) ? new Blob([files.get(path)]) : null,
        getSize: path => Buffer.byteLength(files.get(path) ?? ''),
    })
    await book.init()
    t.after(() => book.destroy())
    return book
}

const controlledView = (t, book, goTo = async () => {}) => {
    // This is the actual registered View. Its public book/renderer boundary
    // supplies a controlled renderer; no layout or WKWebView result is claimed.
    const view = new View()
    const renderer = { goTo, destroy() {}, remove() {} }
    view.book = book
    view.renderer = renderer
    t.after(() => view.close())
    return { view, renderer }
}

const held = () => {
    let resolve, reject
    const promise = new Promise((yes, no) => { resolve = yes; reject = no })
    return { promise, resolve, reject }
}

for (const repeated of [false, true]) {
    test(`production View emits and navigates retained section CFI (repeated=${repeated})`, async t => {
        const book = await openBook(t, { repeated })
        const calls = []
        const { view } = controlledView(t, book, async target => {
            calls.push({ index: target.index, anchor: target.anchor(await book.sections[target.index].createDocument()) })
        })
        const target = view.getCFI(1)
        assert.equal(target, book.sections[1].cfi)
        assert.equal(book.resources.cfis.indexOf(target), 2)
        const resolved = await view.goTo(target)
        assert.equal(resolved.index, 1)
        assert.deepEqual(calls, [{ index: 1, anchor: 0 }])
        assert.equal(view.history.canGoBack, false)
    })
}

test('production View joins full range to retained OPF identity without changing offsets', async t => {
    const book = await openBook(t)
    const doc = await book.sections[1].createDocument()
    const text = doc.querySelector('p').firstChild
    const range = doc.createRange()
    range.setStart(text, 2)
    range.setEnd(text, 10)
    const calls = []
    const { view } = controlledView(t, book, async target => {
        const restored = target.anchor(doc)
        calls.push({ index: target.index, text: restored.toString(), start: restored.startOffset, end: restored.endOffset })
    })
    const target = view.getCFI(1, range)
    assert.equal((await view.goTo(target)).index, 1)
    assert.deepEqual(calls, [{ index: 1, text: 'pha Beta', start: 2, end: 10 }])
})

test('production View navigation progress converts section-zero anchor to body start', async t => {
    const book = await openBook(t)
    const { view } = controlledView(t, book)
    const target = view.getCFI(1)
    const progress = await view.getNavigationProgressOf(target)
    assert.equal(progress.index, 1)
    assert.equal(progress.sectionIndex, 1)
    assert.equal(progress.tocItem, null)
    const doc = await book.sections[1].createDocument()
    const range = book.resolveCFI(progress.cfi).anchor(doc)
    assert.equal(range.collapsed, true)
    assert.equal(range.startContainer, doc.body)
    assert.equal(range.startOffset, 0)
})

test('retired View renderer success cannot publish old CFI after replacement', async t => {
    const oldBook = await openBook(t, { repeated: true })
    const oldWork = held()
    const { view } = controlledView(t, oldBook, () => oldWork.promise)
    const oldTarget = view.getCFI(1)
    let historyPublications = 0
    view.history.addEventListener('index-change', () => historyPublications++)
    const oldOperation = view.goTo(oldTarget)
    view.close()
    const newBook = await openBook(t)
    view.book = newBook
    view.renderer = { goTo: async () => {}, destroy() {}, remove() {} }
    const currentTarget = view.getCFI(0)
    assert.equal((await view.goTo(currentTarget)).index, 0)
    oldWork.resolve()
    assert.equal(await oldOperation, null)
    assert.equal(historyPublications, 1)
    assert.equal(view.history.canGoBack, false)
})

test('retired View renderer failure is contained while current failure remains retryable', async t => {
    const book = await openBook(t)
    const work = held()
    const { view } = controlledView(t, book, () => work.promise)
    const operation = view.goTo(view.getCFI(1))
    view.close()
    work.reject(new Error('retired renderer failure'))
    assert.equal(await operation, null)

    const currentBook = await openBook(t)
    const failure = new Error('current renderer failure')
    let fail = true
    view.book = currentBook
    view.renderer = {
        goTo: async () => { if (fail) throw failure },
        destroy() {}, remove() {},
    }
    const target = view.getCFI(1)
    const oldError = console.error
    console.error = () => {}
    try { await assert.rejects(view.goTo(target), error => error === failure) }
    finally { console.error = oldError }
    fail = false
    assert.equal((await view.goTo(target)).index, 1)
    assert.equal(view.history.canGoBack, false)
})

for (const prefixed of [false, true]) {
    test(`saved authored itemref CFI survives an earlier spine insertion (prefixed=${prefixed})`, async t => {
        const oldBook = await openBook(t, { missing: false, prefixed })
        const { view: producer } = controlledView(t, oldBook)
        const savedCFI = producer.getCFI(1)

        const newBook = await openBook(t, { missing: true, prefixed })
        assert.notEqual(savedCFI, newBook.sections[1].cfi)
        const asserted = CFI.toElement(newBook.resources.opf, CFI.parse(savedCFI)[0])
        assert.equal(asserted.localName, 'itemref')
        assert.equal(asserted.namespaceURI, 'http://www.idpf.org/2007/opf')
        assert.equal(asserted.getAttribute('id'), 'second')
        assert.equal(asserted.getAttribute('idref'), 'two')

        const calls = []
        const { view: consumer } = controlledView(t, newBook, async target => {
            const doc = await newBook.sections[target.index].createDocument()
            calls.push({ index: target.index, anchor: target.anchor(doc) })
        })
        const resolved = await consumer.goTo(savedCFI)
        assert.equal(resolved.index, 1)
        assert.deepEqual(calls, [{ index: 1, anchor: 0 }])
    })
}

test('saved authored itemref range preserves its chapter and local offsets after insertion', async t => {
    const oldBook = await openBook(t, { missing: false })
    const { view: producer } = controlledView(t, oldBook)
    const oldDoc = await oldBook.sections[1].createDocument()
    const range = oldDoc.createRange()
    range.setStart(oldDoc.querySelector('p').firstChild, 2)
    range.setEnd(oldDoc.querySelector('p').firstChild, 10)
    const savedCFI = producer.getCFI(1, range)

    const newBook = await openBook(t)
    const calls = []
    const { view: consumer } = controlledView(t, newBook, async target => {
        const doc = await newBook.sections[target.index].createDocument()
        const restored = target.anchor(doc)
        calls.push({
            index: target.index, text: restored.toString(),
            start: restored.startOffset, end: restored.endOffset,
        })
    })
    const resolved = await consumer.goTo(savedCFI)
    assert.equal(resolved.index, 1)
    assert.deepEqual(calls, [{ index: 1, text: 'pha Beta', start: 2, end: 10 }])
})

test('legacy manifest-ID assertions retain numeric fallback and missing-target rejection', async t => {
    const book = await openBook(t)
    const legacyCFI = book.sections[1].cfi.replace('[second]', '[two]')
    const asserted = CFI.toElement(book.resources.opf, CFI.parse(legacyCFI)[0])
    assert.equal(asserted.localName, 'item')
    assert.equal(book.resolveCFI(legacyCFI).index, 1)

    const missingCFI = book.resources.cfis[0].replace('[missing]', '[two]')
    assert.equal(book.resolveCFI(missingCFI).index, -1)
})

test('itemref outside the captured spine retains numeric fallback', async t => {
    // An unexpected itemref outside the spine is accepted input to the existing
    // parser. Its name alone must not grant it the identity of a spine entry.
    const book = await openBook(t, { outsideItemref: true })
    const cfi = book.sections[1].cfi.replace('[second]', '[outside-spine]')
    const asserted = CFI.toElement(book.resources.opf, CFI.parse(cfi)[0])
    assert.equal(asserted.localName, 'itemref')
    assert.equal(asserted.getAttribute('idref'), 'one')
    assert.equal(asserted.parentElement.localName, 'manifest')
    assert.equal(book.resolveCFI(cfi).index, 1)
})
