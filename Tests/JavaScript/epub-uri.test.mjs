import assert from 'node:assert/strict'
import test from 'node:test'
import { element as el, xmlDocument as xml } from './xml-fixture.mjs'
import { prepareWritingDirectionStylesheets, processedSectionURLForHref } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-direct-section.js'

globalThis.DOMParser = class {}
const { TOCProgress } = await import('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/progress.js')
const { EPUB, Loader } = await import('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/epub.js')
const ns = {
    opf: 'http://www.idpf.org/2007/opf', xhtml: 'http://www.w3.org/1999/xhtml',
    container: 'urn:oasis:names:tc:opendocument:xmlns:container',
    dc: 'http://purl.org/dc/elements/1.1/',
    ncx: 'http://www.daisy.org/z3986/2005/ncx/', smil: 'http://www.w3.org/ns/SMIL',
}
const filenames = ['100%.xhtml', 'literal%20.xhtml', 'literal .xhtml', 'chapter#draft.xhtml', 'chapter?draft.xhtml', 'literal%2F.xhtml']
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

test('stylesheet output retains external URI data without loading matching package paths', async () => {
    const window = globalThis.window
    globalThis.window = { innerWidth: 800, innerHeight: 600 }
    const stylesheet = { href: 'OPS/style.css', mediaType: 'text/css' }
    const manifest = [stylesheet,
        { href: 'OPS/theme.css', mediaType: 'text/css' },
        { href: 'OPS/image.png', mediaType: 'image/png' },
    ]
    const reads = [], blobs = []
    const importHref = '//invalid.invalid/OPS/theme.css?key=a%2Bb#edition'
    const imageHref = '//invalid.invalid/OPS/image.png?size=2#detail'
    const escapedHref = '//assets.example/a%2Fb%5Cc.png?key=x%2By#detail'
    const css = `@import "${importHref}" screen;\n`
        + `.image { background: url(${imageHref}); mask: url('${escapedHref}') }`
    const loader = new Loader({
        resources: { manifest },
        loadText: async href => {
            reads.push(href)
            return href === stylesheet.href ? css : ''
        },
        loadBlob: async href => {
            blobs.push(href)
            return new Blob(['archive asset'])
        },
    })
    try {
        const url = await loader.loadItem(stylesheet)
        const rewritten = await (await fetch(url)).text()
        assert.equal(rewritten, `@import "https:${importHref}" screen;\n`
            + `.image { background: url("https:${imageHref}"); mask: url("https:${escapedHref}") }`)
        assert.deepEqual(reads, [stylesheet.href])
        assert.deepEqual(blobs, [])
    } finally {
        loader.destroy()
        globalThis.window = window
    }
})

test('internal references preserve the fragment and validate the path before dot segments collapse', async () => {
    const f = makeURIFixture({ names: ['chapter.xhtml'] })
    let loader
    try {
        await f.book.init()
        const section = f.book.sections[0]
        assert.equal(section.resolveHref(`chapter.xhtml?edition=2#${encodedFragment}`),
            `OPS/chapter.xhtml#${encodedFragment}`)
        loader = new Loader({ resources: f.book.resources, loadBlob: f.loadBlob, replaceURL: f.book.replaceURL })
        for (const href of ['#glyph', '?edition=2#glyph', 'blob:https://example.com/id#glyph']) {
            assert.equal(await loader.loadHref(href, section.id), href)
        }
        for (const href of ['nested%2F/../chapter.xhtml', 'nested%5C/../chapter.xhtml',
            'nested%2\nf/../chapter.xhtml', String.raw`\\invalid.invalid/OPS/chapter.xhtml`]) {
            assert.throws(() => section.resolveHref(href), URIError)
            assert.equal(await loader.loadHref(href, section.id), href)
        }
        assert.deepEqual(f.processed, [])
        assert.deepEqual(f.blobs, [])
    } finally { loader?.destroy(); f.close() }
})

test('srcset rewrites complete URL tokens and preserves candidate spacing and descriptors', async () => {
    const directory = 'OPS/literal%20'
    const chapter = `${directory}/chapter.xhtml`
    const sharedPath = `${directory}/image#?%2F.png`
    const alternatePath = `${directory}/alt,wide.png`
    const spacedHref = 'page\u3000image.png'
    const spacedPath = `${directory}/${spacedHref}`
    const sharedHref = 'image%23%3F%252F.png'
    const data = 'data:image/png;base64,a,b'
    const external = '//invalid.invalid/OPS/pixel.png?sig=a%2Bb,more#part'
    const owned = 'blob:https://example.com/owned'
    const rejected = 'nested%2F/../would-read.png'
    const authored = ` , ${sharedHref}?rev=2#glyph 1x,  ${data} 2x,\n ${external} 3x, `
        + `${sharedHref} shape(1,//ignored), alt,wide.png,, ${spacedHref}\f1x\t , `
        + `${rejected} 6x, ${owned} 4x, missing.png,other.png 5x`
    const reads = []
    const loader = new Loader({
        resources: { manifest: [sharedPath, alternatePath, spacedPath, `${directory}/would-read.png`, 'OPS/pixel.png', owned]
            .map(href => ({ href, mediaType: 'image/png' })) },
        loadBlob: async href => {
            reads.push(href)
            return new Blob([href], { type: 'image/png' })
        },
    })
    try {
        const output = await loader.replaceSrcset(authored, chapter)
        const [shared, repeated, alternate, spaced, unchanged] = output.match(/blob:[^#,\s]+/g)
        assert.equal(shared, repeated)
        assert.equal(unchanged, owned)
        assert.equal(output, ` , ${shared}#glyph 1x,  ${data} 2x,\n https:${external} 3x, `
            + `${shared} shape(1,//ignored), ${alternate},, ${spaced}\f1x\t , `
            + `${rejected} 6x, ${owned} 4x, missing.png,other.png 5x`)
        assert.deepEqual(reads, [sharedPath, alternatePath, spacedPath])
        assert.equal(await (await fetch(shared)).text(), sharedPath)
        assert.equal(await (await fetch(alternate)).text(), alternatePath)
        assert.equal(await (await fetch(spaced)).text(), spacedPath)
    } finally { loader.destroy() }
})

test('retired srcset work discards a held image read and stops before the next candidate', async () => {
    const reads = []
    const firstRead = Promise.withResolvers()
    const response = Promise.withResolvers()
    const lateImage = new Blob(['late image'])
    const loader = new Loader({
        resources: { manifest: ['OPS/first.png', 'OPS/second.png']
            .map(href => ({ href, mediaType: 'image/png' })) },
        loadBlob: href => {
            reads.push(href)
            firstRead.resolve()
            return response.promise
        },
    })
    const replacing = loader.replaceSrcset('first.png 1x, second.png 2x', 'OPS/chapter.xhtml')
    try {
        await firstRead.promise
        loader.destroy()
        response.resolve(lateImage)
        assert.equal(await replacing, null)
        assert.deepEqual(reads, ['OPS/first.png'])
    } finally {
        loader.destroy()
        response.resolve(lateImage)
        await replacing.catch(() => {})
    }
})

test('direct section writing probe installs only the exact archived stylesheet', async () => {
    const directory = 'OPS/literal%20'
    const chapter = { href: `${directory}/chapter.xhtml`, mediaType: 'application/xhtml+xml' }
    const stylePath = `${directory}/style#?%2F.css`
    const css = 'body { writing-mode: vertical-rl }'
    const entries = new Map([
        [stylePath, css],
        ['OPS/wrong.css', 'body { writing-mode: horizontal-tb }'],
        [`${directory}/wrong.css`, 'body { writing-mode: horizontal-tb }'],
    ])
    const hrefs = [
        'style%23%3F%252F.css?edition=2#theme',
        '  //invalid.invalid/OPS/wrong.css?sig=a%2Bb#part ',
        'https://invalid.invalid/OPS/wrong.css?sig=a%2Bb#part',
        'nested%2F/../wrong.css',
        'nested%5C/../wrong.css',
        '?edition=2#theme',
        '#theme',
        'blob:https://example.com/stylesheet',
    ]
    const links = hrefs.map(href => ({
        href,
        getAttribute(name) { return name === 'href' ? this.href : null },
    }))
    const reads = [], blobURLs = []
    const source = 'ebook://ebook/load/local/book.epub'
    const loader = new Loader({
        resources: { manifest: [chapter] },
        replaceURL: async (href, _mediaType, resolveArchivePath) => {
            await prepareWritingDirectionStylesheets({
                head: { querySelectorAll: () => links },
                loadText: async path => { reads.push(path); return entries.get(path) ?? null },
                resolveArchivePath,
                blobURLs,
            })
            return processedSectionURLForHref(source, href)
        },
    })

    try {
        const directURL = new URL(await loader.loadItem(chapter))
        assert.equal(directURL.searchParams.get('subpath'), chapter.href)
        assert.equal(directURL.searchParams.get('direct'), '1')
        assert.deepEqual(reads, [stylePath])
        assert.deepEqual(blobURLs, [links[0].href])
        assert.equal(await (await fetch(links[0].href)).text(), css)
        assert.deepEqual(links.slice(1).map(link => link.href), hrefs.slice(1))
    } finally {
        loader.destroy()
        for (const url of blobURLs) URL.revokeObjectURL(url)
    }
})

test('an aborted writing probe discards late stylesheet bytes and stops reading links', async () => {
    const hrefs = ['first.css', 'second.css']
    const links = hrefs.map(href => ({
        href,
        getAttribute(name) { return name === 'href' ? this.href : null },
    }))
    const controller = new AbortController()
    const started = Promise.withResolvers()
    const stylesheet = Promise.withResolvers()
    const reads = [], blobURLs = []
    const preparing = prepareWritingDirectionStylesheets({
        head: { querySelectorAll: () => links },
        resolveArchivePath: href => `OPS/${href}`,
        loadText: (path, { signal }) => {
            reads.push({ path, signal })
            started.resolve()
            return stylesheet.promise
        },
        signal: controller.signal,
        blobURLs,
    })

    try {
        await started.promise
        controller.abort()
        stylesheet.resolve('body { writing-mode: vertical-rl }')
        await preparing
        assert.deepEqual(reads.map(({ path }) => path), ['OPS/first.css'])
        assert.equal(reads[0].signal, controller.signal)
        assert.deepEqual(links.map(link => link.href), hrefs)
        assert.deepEqual(blobURLs, [])
    } finally {
        for (const url of blobURLs) URL.revokeObjectURL(url)
    }
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

const withViewLinks = async (hrefs, fixtureOptions, run) => {
    globalThis.HTMLElement = DOMElement
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
    globalThis.NodeFilter = { SHOW_ELEMENT: 1, SHOW_TEXT: 4, SHOW_CDATA_SECTION: 8, FILTER_ACCEPT: 1, FILTER_REJECT: 2, FILTER_SKIP: 3 }
    const renderer = new Renderer()
    globalThis.document = {
        createElement: name => name === 'foliate-fxl' ? renderer : new DOMElement(),
        createTreeWalker: () => ({}),
    }
    const { View } = await import('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/view.js')
    const f = makeURIFixture(fixtureOptions)
    const view = new View()
    try {
        await f.book.init()
        f.book.rendition.layout = 'pre-paginated'
        await view.open(f.book)
        const anchors = hrefs.map(href => {
            const anchor = new DOMElement()
            anchor.setAttribute('href', href)
            return anchor
        })
        const doc = new EventTarget()
        doc.documentElement = { lang: '', dir: '' }
        doc.location = { href: 'ebook://processed/chapter' }
        doc.querySelectorAll = selector => selector === 'a[href]' ? anchors : []
        renderer.dispatchEvent(new CustomEvent('load', { detail: { doc, index: 0, location: doc.location.href } }))
        await run({ f, view, renderer, anchors })
    } finally { view.close(); f.close() }
}

test('real View content links and TOC clicks reach the intended percent/reserved-name sections', async () => {
    const { createTOCView } = await import('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ui/tree.js')
    const hrefs = filenames.map(name => `${encodeURIComponent(name)}#${encodedFragment}`)
    await withViewLinks(hrefs, { directory: 'OPS/literal%20' }, async ({ f, view, renderer, anchors }) => {
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
    })
})

test('real View hands complete external URIs to consumers and respects cancellation', async () => {
    const cases = [
        ['https://example.com/page?title=a%2Bb#part'],
        ['mailto:reader@example.com?subject=Book#part'],
        ['itms-apps://apps.apple.com/app/id123?mt=8#details'],
        ['Web+Reader:book?edition=2#part'],
        ['foo.bar:target?edition=2#part'],
        ['blobster:target?edition=2#part'],
        ['//example.com/a%2Fb%5Cc?token=x%2By#part', 'https://example.com/a%2Fb%5Cc?token=x%2By#part'],
        ['//invalid.invalid/OPS/chapter.xhtml?edition=2#part', 'https://invalid.invalid/OPS/chapter.xhtml?edition=2#part'],
        [' \t//invalid.invalid/OPS/chapter.xhtml?edition=3#part\n', 'https://invalid.invalid/OPS/chapter.xhtml?edition=3#part'],
        ['Web+Reader:cancel?edition=2#part'],
    ]
    const expected = cases.map(([authored, resolved = authored]) => resolved)
    const cancelled = expected.at(-1)
    await withViewLinks(cases.map(([href]) => href), { names: ['chapter.xhtml'] }, async ({ f, view, renderer, anchors }) => {
        const external = [], internal = [], opened = []
        const open = globalThis.open
        globalThis.open = (...args) => opened.push(args)
        view.addEventListener('external-link', event => {
            external.push(event.detail.href)
            if (event.detail.href === cancelled) event.preventDefault()
        })
        view.addEventListener('link', event => internal.push(event.detail.href))
        try {
            for (const [i, anchor] of anchors.entries()) {
                assert.equal(f.book.sections[0].resolveHref(anchor.getAttribute('href')), expected[i])
                assert.equal(anchor.dispatchEvent(new Event('click', { cancelable: true })), false)
            }
            await new Promise(resolve => setImmediate(resolve))
            assert.deepEqual(external, expected)
            assert.deepEqual(opened, expected.slice(0, -1).map(href => [href, '_blank']))
            assert.deepEqual(internal, [])
            assert.deepEqual(renderer.calls, [])
        } finally { globalThis.open = open }
    })
})

test('EPUB scheme classification uses ASCII URI grammar and excludes only blob itself', () => {
    const f = makeURIFixture()
    try {
        for (const href of ['A1+.-:target', 'blobster:target', 'blob+reader:target']) {
            assert.equal(f.book.isExternal(href), true, href)
        }
        for (const href of ['blob:https://example.com/id', 'BLOB:https://example.com/id',
            '1reader:target', 'reader_name:target', './A:B.xhtml', 'OPS/chapter.xhtml#part']) {
            assert.equal(f.book.isExternal(href), false, href)
        }
    } finally { f.close() }
})
