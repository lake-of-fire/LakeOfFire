// Exact reviewed production: Lake #293 1690e95eac31cf75070c61db23a92c58a350d368.
// Requires Node 24 and externally available jsdom 26.1.0; no package provisioning.
// JSDOM_MODULE=/path/to/jsdom node --test --test-isolation=none --test-reporter=tap \
//   Tests/JavaScript/epub-view-missing-target-admission.test.mjs
//
// Runs complete EPUB, View, Paginator/FixedLayout admission and restore helpers.
// Package reads are controlled in-memory transport. ResizeObserver is inert:
// no resize callback, iframe load, geometry, browser or native result is claimed.

import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import test, { after } from 'node:test'

const require = createRequire(import.meta.url)
const { JSDOM } = require(process.env.JSDOM_MODULE ?? 'jsdom')
const window = new JSDOM('<!doctype html><html><body></body></html>').window
for (const name of [
    'window', 'document', 'HTMLElement', 'customElements', 'DOMParser',
    'Range', 'Node', 'NodeFilter', 'Event', 'EventTarget', 'CustomEvent',
]) globalThis[name] = name === 'window' ? window : window[name]
globalThis.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
}
after(() => window.close())

const { EPUB } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/epub.js')
const { View } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/view.js')
const CFI = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/epubcfi.js')
const { runRequiredRestoreNavigation } = await import(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-restore-coordination.js'
)

const chapter = `<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title></head>
<body><p id="paragraph">A retained chapter</p></body></html>`

const openBook = async (t, {
    missingLeading = false,
    secondManifest = true,
    fixedLayout = false,
    foreignItemref = false,
} = {}) => {
    const files = new Map([
        ['META-INF/container.xml', `<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>
<rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>`],
        ['OPS/book.opf', `<package xmlns="http://www.idpf.org/2007/opf" xmlns:foreign="urn:foreign:opf" version="3.0" unique-identifier="publication">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="publication">missing-target-admission</dc:identifier>
<dc:title>Missing target</dc:title><dc:language>en</dc:language>
${fixedLayout ? '<meta property="rendition:layout">pre-paginated</meta>' : ''}
</metadata><manifest>
<item id="one" href="one.xhtml" media-type="application/xhtml+xml"/>
${secondManifest ? '<item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>' : ''}
<item id="not-in-spine" href="orphan.xhtml" media-type="application/xhtml+xml"/>
</manifest><spine>
${missingLeading ? '<itemref id="missing" idref="absent"/>' : ''}
<itemref id="first" idref="one"/>
${foreignItemref ? '<foreign:itemref id="foreign-target" idref="one"/>' : ''}
<itemref id="second" idref="two"/>
</spine></package>`],
        ['OPS/one.xhtml', chapter],
        ['OPS/two.xhtml', chapter],
        ['OPS/orphan.xhtml', chapter],
    ])
    const reads = []
    const book = new EPUB({
        loadText: async path => {
            reads.push(['text', path])
            return files.get(path) ?? null
        },
        loadBlob: async path => {
            reads.push(['blob', path])
            return files.has(path) ? new Blob([files.get(path)]) : null
        },
        getSize: path => Buffer.byteLength(files.get(path) ?? ''),
    })
    await book.init()
    t.after(() => book.destroy())
    return { book, reads }
}

const openView = async (t, book) => {
    const view = new View()
    await view.open(book, false)
    t.after(() => view.close())
    return view
}

const saveSecondSectionCFI = async (t, options = {}) => {
    const { book } = await openBook(t, options)
    const view = await openView(t, book)
    const cfi = view.getCFI(1)
    assert.equal(cfi, book.sections[1].cfi)
    return cfi
}

test('captured missing-manifest itemref retains its authored identity instead of another chapter', async t => {
    const saved = await saveSecondSectionCFI(t)
    const { book } = await openBook(t, { missingLeading: true, secondManifest: false })
    const asserted = CFI.toElement(book.resources.opf, CFI.parse(saved)[0])
    assert.equal(asserted.getAttribute('id'), 'second')
    assert.equal(asserted.getAttribute('idref'), 'two')
    assert.equal(book.sections.length, 1)
    assert.equal(book.sections[0].id, 'OPS/one.xhtml')
    assert.equal(book.resolveCFI(saved).index, -1)
})

test('foreign-namespace itemref cannot acquire captured OPF spine membership', async t => {
    const { book } = await openBook(t, { foreignItemref: true })
    const view = await openView(t, book)
    const saved = view.getCFI(1).replace('[second]', '[foreign-target]')
    const asserted = CFI.toElement(book.resources.opf, CFI.parse(saved)[0])
    assert.equal(asserted.localName, 'itemref')
    assert.equal(asserted.namespaceURI, 'urn:foreign:opf')
    assert.equal(asserted.parentElement.localName, 'spine')
    assert.equal(book.resources.spine.length, 2)
    assert.equal(book.resolveCFI(saved).index, 1)
})

for (const fixedLayout of [false, true]) {
    test(`missing authored chapter must fail restore without history through actual ${fixedLayout ? 'FixedLayout' : 'Paginator'} admission`, async t => {
        const saved = await saveSecondSectionCFI(t, { fixedLayout })
        const { book, reads } = await openBook(t, {
            fixedLayout,
            missingLeading: true,
            secondManifest: false,
        })
        assert.equal(book.resolveCFI(saved).index, -1)
        const view = await openView(t, book)
        assert.equal(view.renderer.localName, fixedLayout ? 'foliate-fxl' : 'foliate-paginator')

        // Seed the real public history with the retained reading location.
        // The invalid destination must not create another history entry.
        view.history.pushState(view.getCFI(0))
        let historyPublications = 0
        view.history.addEventListener('index-change', () => historyPublications++)
        const beforeReads = reads.length
        const outcome = await runRequiredRestoreNavigation(() => view.goTo(saved))

        assert.equal(reads.length, beforeReads, 'the missing chapter never reaches package resource loading')
        assert.equal(view.renderer.getContents().length, 0, 'no iframe/document was created')
        assert.deepEqual({
            ok: outcome.ok,
            value: outcome.value,
            historyPublications,
            canGoBack: view.history.canGoBack,
        }, {
            ok: false,
            value: null,
            historyPublications: 0,
            canGoBack: false,
        })
    })
}

test('manifest-only href must reject navigation without history through actual Paginator admission', async t => {
    const { book, reads } = await openBook(t)
    assert.equal(book.resolveHref('OPS/orphan.xhtml').index, -1)
    const view = await openView(t, book)
    view.history.pushState(view.getCFI(0))
    let historyPublications = 0
    view.history.addEventListener('index-change', () => historyPublications++)
    const beforeReads = reads.length
    const outcome = await view.goTo('OPS/orphan.xhtml').then(
        value => ({ value, error: null }),
        error => ({ value: null, error }),
    )

    assert.equal(reads.length, beforeReads)
    assert.equal(view.renderer.getContents().length, 0)
    assert.deepEqual({
        rejected: outcome.error instanceof Error || outcome.value === null,
        value: outcome.value,
        historyPublications,
        canGoBack: view.history.canGoBack,
    }, {
        rejected: true,
        value: null,
        historyPublications: 0,
        canGoBack: false,
    })
})
