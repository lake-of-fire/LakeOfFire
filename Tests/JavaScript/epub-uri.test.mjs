import assert from 'node:assert/strict'
import test from 'node:test'
import { element as el, xmlDocument as xml } from './xml-fixture.mjs'

globalThis.DOMParser = class {}
const { TOCProgress } = await import('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/progress.js')
const { EPUB, Loader } = await import('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/epub.js')
const ns = {
    opf: 'http://www.idpf.org/2007/opf', xhtml: 'http://www.w3.org/1999/xhtml',
    container: 'urn:oasis:names:tc:opendocument:xmlns:container',
    dc: 'http://purl.org/dc/elements/1.1/',
    ncx: 'http://www.daisy.org/z3986/2005/ncx/', smil: 'http://www.w3.org/ns/SMIL',
}
const filenames = ['100%.xhtml', ' trailing.xhtml ', 'literal%20.xhtml', 'literal .xhtml', 'chapter#draft.xhtml', 'chapter?draft.xhtml', 'literal%2F.xhtml']
const fragment = 'sentence %20#?'
const encodedFragment = encodeURIComponent(fragment)

const makeURIFixture = ({ directory = 'OPS', ncx = false, names = filenames, manifestRefs = null,
    textFragment = 'sentence-1', navigationRefs = null } = {}) => {
    const path = name => directory ? `${directory}/${name}` : name
    const docs = new Map()
    const reads = [], sizes = [], processed = [], blobs = []
    const texts = new Map([
        ['META-INF/container.xml', 'container'], [path('book.opf'), 'package'],
        [path('nav.xhtml'), 'nav'], [path('toc.ncx'), 'ncx'], [path('overlay.smil'), 'smil'],
        ...names.map((name, i) => [path(name), `chapter-${i}`]),
    ])
    docs.set('container', xml(el('container', ns.container, {}, [el('rootfile', ns.container, {
        'full-path': path('book.opf'), 'media-type': 'application/oebps-package+xml',
    })])))
    docs.set('package', xml(el('package', ns.opf, {}, [el('metadata', ns.opf, {}, [el('language', ns.dc, {}, [], 'en')]),
        el('manifest', ns.opf, {}, [
            ...names.map((name, i) => el('item', ns.opf, { id: `c${i}`, href: manifestRefs?.[i] ?? encodeURIComponent(name),
                'media-type': 'application/xhtml+xml', 'media-overlay': 'overlay' })),
            el('item', ns.opf, { id: 'nav', href: ncx ? 'toc.ncx' : 'nav.xhtml',
                'media-type': ncx ? 'application/x-dtbncx+xml' : 'application/xhtml+xml', properties: ncx ? '' : 'nav' }),
            el('item', ns.opf, { id: 'overlay', href: 'overlay.smil', 'media-type': 'application/smil+xml' }),
            el('item', ns.opf, { id: 'asset', href: 'image%23%3F%2520.png', 'media-type': 'image/png' }),
        ]), el('spine', ns.opf, { toc: ncx ? 'nav' : '' }, names.map((_, i) => el('itemref', ns.opf, { idref: `c${i}` }))),
    ])))
    const nav = el('nav', ns.xhtml, {}, [el('ol', ns.xhtml, {}, names.map((name, i) => el('li', ns.xhtml, {}, [
        el('a', ns.xhtml, { href: navigationRefs?.[i] ?? `${encodeURIComponent(name)}#${encodedFragment}` }, [], name),
    ])))])
    nav.getAttributeNS = () => 'toc'
    docs.set('nav', xml(el('html', ns.xhtml, {}, [nav])))
    docs.set('ncx', xml(el('ncx', ns.ncx, {}, [el('navMap', ns.ncx, {}, names.map((name, i) => el('navPoint', ns.ncx, {}, [
        el('navLabel', ns.ncx, {}, [], name), el('content', ns.ncx, { src: navigationRefs?.[i] ?? `${encodeURIComponent(name)}#${encodedFragment}` }),
    ])))])))
    docs.set('smil', xml(el('smil', ns.smil, {}, names.map(name => el('par', ns.smil, {}, [
        el('text', ns.smil, { src: `${encodeURIComponent(name)}#${encodeURIComponent(textFragment)}` }),
        el('audio', ns.smil, { src: `${encodeURIComponent(name)}.mp3`, clipBegin: '1s', clipEnd: '2s' }),
    ])))))
    names.forEach((_, i) => docs.set(`chapter-${i}`, xml(el('html', ns.xhtml, {}, [el('body', ns.xhtml)]))))
    const globals = { DOMParser: globalThis.DOMParser }
    globalThis.DOMParser = class { parseFromString(text) { assert.ok(docs.has(text), `Missing raw archive entry: ${text}`); return docs.get(text) } }
    const loadBlob = async href => { blobs.push(href); assert.equal(href, path('image#?%20.png')); return new Blob(['asset']) }
    const book = new EPUB({
        loadText: async href => { reads.push(href); return texts.get(href) ?? null }, loadBlob,
        getSize: href => { sizes.push(href); return 123 },
        replaceURL: async href => { processed.push(href); return `ebook://processed/${encodeURIComponent(href)}` },
    })
    return { book, path, reads, sizes, processed, blobs, loadBlob,
        close() { book.destroy(); Object.assign(globalThis, globals) } }
}

for (const ncx of [false, true]) {
    test(`${ncx ? 'NCX' : 'NAV'} canonicalizes equivalent path escape spellings`, async () => {
        const names = ['日本語.xhtml', 'A.xhtml', 'chapter?draft.xhtml']
        const navigationRefs = names.map((name, index) => {
            const path = index === 1 ? '%41.xhtml' : encodeURIComponent(name)
                .replace(/%[0-9A-F]{2}/g, value => value.toLowerCase())
            return `${path}#${encodedFragment}`
        })
        const f = makeURIFixture({ ncx, names, navigationRefs })
        try {
            await f.book.init()
            for (const [index, item] of f.book.toc.entries()) {
                assert.equal(item.href.split('#')[0], f.book.sections[index].href)
                assert.equal(f.book.resolveHref(item.href)?.index, index)
            }
        } finally { f.close() }
    })

    test(`${ncx ? 'NCX' : 'NAV'} keeps valid items when another optional reference is invalid`, async () => {
        const f = makeURIFixture({ ncx, navigationRefs: ['nested%2F..%2Fbad.xhtml'] })
        try {
            await f.book.init()
            assert.equal(f.book.toc?.length, filenames.length)
            assert.equal(f.book.toc[0].href, null)
            for (let i = 1; i < filenames.length; i++) {
                assert.equal(f.book.resolveHref(f.book.toc[i].href)?.index, i)
            }
        } finally { f.close() }
    })

    test(`${ncx ? 'NCX' : 'NAV'} keeps valid peers beside a malformed protocol-relative URL`, async () => {
        const f = makeURIFixture({ ncx, navigationRefs: ['//[invalid'] })
        try {
            await f.book.init()
            assert.equal(f.book.toc?.length, filenames.length)
            assert.equal(f.book.toc[0].href, null)
            for (let i = 1; i < filenames.length; i++) {
                assert.equal(f.book.resolveHref(f.book.toc[i].href)?.index, i)
            }
        } finally { f.close() }
    })

    test(`${ncx ? 'NCX' : 'NAV'} references and content links decode exactly once`, async () => {
        const f = makeURIFixture({ ncx })
        try {
            await f.book.init()
            assert.equal(f.book.toc?.length, filenames.length)
            const progress = new TOCProgress({ toc: f.book.toc, ids: f.book.sections.map(s => s.id),
                splitHref: f.book.splitTOCHref.bind(f.book), getFragment: f.book.getTOCFragment.bind(f.book) })
            for (const [i, name] of filenames.entries()) {
                const expected = `${f.path(encodeURIComponent(name))}#${encodedFragment}`
                assert.equal(f.book.toc[i].href, expected)
                assert.equal(progress.getProgress(i)?.href, expected)
                const resolvedLink = f.book.sections[0].resolveHref(`${encodeURIComponent(name)}#${encodedFragment}`)
                assert.equal(resolvedLink, expected)
                for (const href of [resolvedLink, f.book.toc[i].href]) {
                    const result = f.book.resolveHref(href)
                    assert.equal(result?.index, i, `Wrong target for ${name}`)
                    const target = {}
                    assert.equal(result.anchor({ getElementById: id => { assert.equal(id, fragment); return target } }), target)
                    assert.deepEqual(f.book.splitTOCHref(href), [f.path(name), fragment])
                }
                assert.equal(f.book.sections[i].href, f.path(encodeURIComponent(name)))
            }
        } finally { f.close() }
    })
}

test('a root-relative archive path with a literal colon stays an internal navigation reference', async () => {
    const f = makeURIFixture({ directory: '', names: ['A:B.xhtml'], navigationRefs: ['/A:B.xhtml'] })
    try {
        await f.book.init()
        assert.equal(f.book.sections[0].id, 'A:B.xhtml')
        assert.equal(f.book.toc[0].href, 'A%3AB.xhtml')
        assert.equal(f.book.isExternal(f.book.toc[0].href), false)
        assert.equal(f.book.resolveHref(f.book.toc[0].href)?.index, 0)
    } finally { f.close() }
})

for (const directory of ['OPS', 'OPS/100%', 'OPS/literal%20', 'OPS/draft#?', 'OPS/part:one']) {
    test(`raw storage identity, section loads and relative assets in ${directory}`, async () => {
        const f = makeURIFixture({ directory })
        let loader
        try {
            await f.book.init()
            assert.deepEqual(f.book.sections.map(s => s.id), filenames.map(f.path))
            assert.deepEqual(f.sizes, filenames.map(f.path))
            for (const [i, name] of filenames.entries()) {
                await f.book.sections[i].createDocument()
                assert.equal(f.reads.at(-1), f.path(name))
                await f.book.sections[i].load()
                assert.equal(f.processed.at(-1), f.path(name))
                const href = f.book.sections[i].resolveHref(encodeURIComponent(name))
                assert.equal(f.book.resolveHref(href)?.index, i)
            }
            loader = new Loader({ resources: f.book.resources, loadBlob: f.loadBlob })
            const url = await loader.loadHref('image%23%3F%2520.png?cache=1#glyph%20one', f.book.sections[0].id)
            assert.match(url, /^blob:/)
            assert.ok(url.endsWith('#glyph%20one'))
            assert.deepEqual(f.blobs, [f.path('image#?%20.png')])
        } finally { loader?.destroy(); f.close() }
    })
}

test('section media overlays decode text fragment identity exactly once', async () => {
    const f = makeURIFixture({ textFragment: fragment })
    try {
        await f.book.init()
        const overlay = await f.book.sections[0].loadMediaOverlay()
        assert.deepEqual(overlay.map(item => item.id), filenames.map(() => fragment))
    } finally { f.close() }
})

test('section media overlays retain canonical audio URI references', async () => {
    const f = makeURIFixture({ directory: 'OPS/literal%20' })
    try {
        await f.book.init()
        const overlay = await f.book.sections[0].loadMediaOverlay()
        assert.deepEqual(overlay, filenames.map(name => ({ id: 'sentence-1', audio: {
            src: `OPS/literal%2520/${encodeURIComponent(name)}.mp3`, clipBegin: 1, clipEnd: 2,
        } })))
    } finally { f.close() }
})

for (const bad of ['nested%2Fchapter.xhtml', 'nested%5Cchapter.xhtml', 'nested%2fchapter.xhtml', 'nested%2F/../chapter.xhtml', 'nested%5C/../literal%2520.xhtml', 'bad%zz.xhtml']) {
    test(`invalid manifest URI components are rejected: ${bad}`, async () => {
        const f = makeURIFixture({ names: ['chapter.xhtml'], manifestRefs: [bad] })
        try { await assert.rejects(f.book.init(), URIError) }
        finally { f.close() }
    })
    test(`invalid navigation and asset URI components cannot access storage: ${bad}`, async () => {
        const f = makeURIFixture()
        let loader
        try {
            await f.book.init()
            const readsBefore = f.reads.length
            assert.equal(f.book.resolveHref(`OPS/${bad}`), null)
            assert.deepEqual(f.book.splitTOCHref(`OPS/${bad}#fragment`), [])
            loader = new Loader({ resources: f.book.resources, loadBlob: f.loadBlob, replaceURL: f.book.replaceURL })
            assert.equal(await loader.loadHref(bad, f.book.sections[0].id), bad)
            assert.equal(f.reads.length, readsBefore)
            assert.deepEqual(f.blobs, [])
            assert.deepEqual(f.processed, [])
        } finally { loader?.destroy(); f.close() }
    })
}

test('script resource references cannot confuse a percent-named file with its space-named sibling', async () => {
    const f = makeURIFixture()
    let loader
    try {
        await f.book.init()
        loader = new Loader({ resources: f.book.resources, replaceURL: f.book.replaceURL })
        const references = filenames.map(name => `${encodeURIComponent(name)}?cache=1#glyph`)
        const result = JSON.parse(await loader.replaceString(JSON.stringify(references), f.book.sections[0].id))
        assert.deepEqual(f.processed, filenames.slice(1).map(f.path))
        assert.equal(result[0], references[0], 'Self references remain untouched')
        assert.deepEqual(result.slice(1), filenames.slice(1).map(name => `ebook://processed/${encodeURIComponent(f.path(name))}#glyph`))
    } finally { loader?.destroy(); f.close() }
})

// Only DOM storage and the renderer are doubles. EPUB, View link handling,
// TOC click callbacks, navigation resolution and history run as shipped.
class DOMElement extends EventTarget {
    children = []
    attributes = new Map()
    style = { setProperty() {} }
    dataset = {}
    append(...children) { for (const child of children) { child.parentNode = this; this.children.push(child) } }
    replaceChildren(...children) { this.children = []; this.append(...children) }
    setAttribute(name, value) { this.attributes.set(name, String(value)) }
    getAttribute(name) { return this.attributes.get(name) ?? null }
    attachShadow() { return new DOMElement() }
    remove() {}
}
class Renderer extends DOMElement {
    calls = []
    async open() {}
    async goTo(target) { this.calls.push(target); return true }
    destroy() {}
}

test('real View content links and TOC clicks reach the intended percent/reserved-name sections', async () => {
    globalThis.HTMLElement = DOMElement
    globalThis.ResizeObserver = class { observe() {}; unobserve() {}; disconnect() {} }
    globalThis.CSSStyleSheet = class { replaceSync() {} }
    globalThis.CustomEvent = class extends Event { constructor(type, options = {}) { super(type, options); this.detail = options.detail } }
    globalThis.customElements = { define() {} }
    globalThis.NodeFilter = { SHOW_ELEMENT: 1, SHOW_TEXT: 4, SHOW_CDATA_SECTION: 8, FILTER_ACCEPT: 1, FILTER_REJECT: 2, FILTER_SKIP: 3 }
    const renderer = new Renderer()
    globalThis.document = {
        createElement: name => name === 'foliate-fxl' ? renderer : new DOMElement(),
        createTreeWalker: () => ({}),
    }
    const { View } = await import('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/view.js')
    const { createTOCView } = await import('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ui/tree.js')
    const f = makeURIFixture({ directory: 'OPS/literal%20' })
    const view = new View()
    try {
        await f.book.init()
        f.book.rendition.layout = 'pre-paginated'
        await view.open(f.book)
        const anchors = filenames.map(name => {
            const anchor = new DOMElement()
            anchor.setAttribute('href', `${encodeURIComponent(name)}#${encodedFragment}`)
            return anchor
        })
        const doc = new EventTarget()
        doc.documentElement = { lang: '', dir: '' }
        doc.location = { href: 'ebook://processed/chapter' }
        doc.querySelectorAll = selector => selector === 'a[href]' ? anchors : []
        renderer.dispatchEvent(new CustomEvent('load', { detail: { doc, index: 0, location: doc.location.href } }))
        for (const [i, anchor] of anchors.entries()) {
            anchor.dispatchEvent(new Event('click', { cancelable: true }))
            await new Promise(resolve => setImmediate(resolve))
            assert.equal(renderer.calls.at(-1)?.index, i)
        }
        let jump
        const toc = createTOCView(f.book.toc, href => { jump = view.goTo(href) })
        for (const [i, item] of toc.element.children.entries()) {
            item.children[0].onclick({ preventDefault() {} })
            assert.equal((await jump)?.index, i)
            assert.equal(renderer.calls.at(-1)?.index, i)
        }
    } finally { view.close(); f.close() }
})
