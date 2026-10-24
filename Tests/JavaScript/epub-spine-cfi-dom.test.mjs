import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import test, { after } from 'node:test'

// Run with an installed jsdom package or JSDOM_MODULE=/path/to/jsdom.
// This exercises the production EPUB constructor/parser and real DOM Ranges.
const require = createRequire(import.meta.url)
const { JSDOM } = require(process.env.JSDOM_MODULE ?? 'jsdom')
const window = new JSDOM('').window
globalThis.DOMParser = window.DOMParser
after(() => window.close())

const { EPUB } = await import(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/epub.js'
)
const CFI = await import(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/epubcfi.js'
)

const chapter = `<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title></head>
<body><main id="authored-chapter"><p id="_m1x2">Alpha Beta Gamma</p></main></body></html>`

const openBook = async (t, {
    missing = false,
    manifest = '<item id="one" href="one.xhtml" media-type="application/xhtml+xml"/>'
        + '<item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>',
    spine = '<itemref id="spine-one" idref="one"/><itemref id="spine-two" idref="two"/>',
} = {}) => {
    const files = new Map([
        ['META-INF/container.xml', `<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>`],
        ['OPS/book.opf', `<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="publication">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="publication">spine-regression</dc:identifier>
<dc:title>Spine regression</dc:title><dc:language>en</dc:language></metadata>
<manifest>${manifest}</manifest><spine>${missing ? '<itemref id="missing-reference" idref="missing"/>' : ''}${spine}</spine></package>`],
        ['OPS/one.xhtml', chapter],
        ['OPS/two.xhtml', chapter],
        ['OPS/shared.xhtml', chapter],
    ])
    const book = new EPUB({
        loadText: async path => files.get(path) ?? null,
        loadBlob: async path => files.has(path) ? new Blob([files.get(path)]) : null,
        getSize: path => Buffer.byteLength(files.get(path) ?? ''),
    })
    t.after(() => book.destroy())
    await book.init()
    return book
}

const chapterDocument = book => book.loadDocument(book.resources.getItemByID('one'))

test('actual OPF parsing maps href and CFI targets to surviving sections', async t => {
    const book = await openBook(t, { missing: true })
    assert.deepEqual(book.sections.map(section => section.id), ['OPS/one.xhtml', 'OPS/two.xhtml'])
    assert.deepEqual(book.sections.map(section => book.resources.cfis.indexOf(section.cfi)), [1, 2])
    assert.equal(book.resolveHref('OPS/one.xhtml').index, 0)
    assert.equal(book.resolveHref('OPS/two.xhtml').index, 1)
    assert.deepEqual(book.sections.map(section => book.resolveCFI(section.cfi).index), [0, 1])
})

test('actual section-only CFIs resolve to the section start', async t => {
    const book = await openBook(t)
    const doc = await chapterDocument(book)
    for (const [index, section] of book.sections.entries()) {
        const resolved = book.resolveCFI(section.cfi)
        assert.equal(resolved.index, index)
        assert.equal(resolved.anchor(doc), 0)
    }
})

for (const missing of [false, true]) {
    test(`actual full-range CFI preserves authored assertions and offsets (missing=${missing})`, async t => {
        const book = await openBook(t, { missing })
        const doc = await chapterDocument(book)
        const text = doc.querySelector('p').firstChild
        const range = doc.createRange()
        range.setStart(text, 2)
        range.setEnd(text, 10)
        const localCFI = CFI.fromRange(range)
        const parsed = CFI.parse(localCFI)
        const ids = parsed.parent.flat().map(part => part.id).filter(Boolean)
        assert.ok(ids.includes('authored-chapter'))
        assert.ok(ids.includes('_m1x2'))
        const fullCFI = CFI.joinIndir(book.sections[0].cfi, localCFI)
        const resolved = book.resolveCFI(fullCFI)
        assert.equal(resolved.index, 0)
        const restored = resolved.anchor(doc)
        assert.equal(restored.startContainer, text)
        assert.equal(restored.endContainer, text)
        assert.deepEqual([restored.startOffset, restored.endOffset], [2, 10])
        assert.equal(restored.toString(), 'pha Beta')
    })
}

test('actual same-href manifest items retain first-manifest identity across skipped entries', async t => {
    const book = await openBook(t, {
        missing: true,
        manifest: '<item id="first" href="shared.xhtml" media-type="application/xhtml+xml"/>'
            + '<item id="second" href="shared.xhtml" media-type="application/xhtml+xml"/>',
        spine: '<itemref id="spine-second" idref="second"/>'
            + '<itemref id="spine-first" idref="first"/>',
    })
    assert.deepEqual(book.sections.map(section => section.id), ['OPS/shared.xhtml', 'OPS/shared.xhtml'])
    assert.equal(book.resolveHref('OPS/shared.xhtml').index, 1)
    assert.deepEqual(book.sections.map(section => book.resolveCFI(section.cfi).index), [0, 1])
})

test('actual repeated idrefs resolve each retained OPF occurrence by its own CFI', async t => {
    // Preserve each occurrence that the selected initializer retains; no format-conformance claim.
    const book = await openBook(t, {
        missing: true,
        spine: '<itemref id="first-occurrence" idref="one"/>'
            + '<itemref id="second-occurrence" idref="one"/>',
    })
    assert.equal(book.sections.length, 2)
    assert.notEqual(book.sections[0].cfi, book.sections[1].cfi)
    assert.equal(book.resolveHref('OPS/one.xhtml').index, 0)
    assert.deepEqual(book.sections.map(section => book.resolveCFI(section.cfi).index), [0, 1])
})

test('actual skipped itemrefs remain inadmissible instead of selecting the following section', async t => {
    const book = await openBook(t, { missing: true })
    assert.equal(book.resolveCFI(book.resources.cfis[0]).index, -1)
    assert.equal(book.resolveHref('OPS/absent.xhtml'), null)
})

test('actual legacy manifest-ID assertions preserve the existing numeric-path retry', async t => {
    const book = await openBook(t)
    const malformedAssertion = book.sections[1].cfi.replace('[spine-two]', '[two]')
    assert.notEqual(malformedAssertion, book.sections[1].cfi)
    assert.equal(book.resolveCFI(malformedAssertion).index, 1)
})
