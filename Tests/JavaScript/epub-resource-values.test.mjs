import assert from 'node:assert/strict'
import test from 'node:test'
import { Loader } from '../../Sources/LakeOfFireReader/Resources/foliate-js/epub.js'

const loaderFor = (manifest, options = {}) => new Loader({
    resources: { manifest }, loadText: async () => null,
    loadBlob: async () => new Uint8Array([1, 2, 3]), ...options,
})

test('manifest lookup ignores query and retains the exact fragment on its owned URL', async () => {
    const item = { href: 'OPS/fonts/font.otf', mediaType: 'font/otf' }
    const reads = []
    const loader = loaderFor([item], { loadBlob: async href => { reads.push(href); return new Uint8Array([1]) } })
    try {
        const first = await loader.loadHref('../fonts/font.otf?v=2#Face%20One', 'OPS/text/chapter.xhtml')
        const second = await loader.loadHref('../fonts/font.otf#FaceTwo', 'OPS/text/chapter.xhtml')
        assert.ok(first.startsWith('blob:'))
        assert.equal(first.slice(first.indexOf('#')), '#Face%20One')
        assert.equal(first.split('#')[0], second.split('#')[0])
        assert.deepEqual(reads, [item.href])
        assert.equal((await (await fetch(first)).arrayBuffer()).byteLength, 1)
    } finally { loader.destroy() }
})

test('fragment-only, query-only, empty, external and missing references preserve their identity', async () => {
    let calls = 0
    const loader = loaderFor([], { loadBlob: async () => { calls += 1; throw Error('unexpected read') } })
    try {
        for (const value of ['#local', '?view=one#local', '', null, undefined,
            'https://example.org/image.svg?v=2#icon', 'data:image/png;base64,AA==',
            '../missing.svg?v=2#icon']) {
            assert.equal(await loader.loadHref(value, 'OPS/chapter.xhtml'), value)
        }
        assert.equal(calls, 0)
    } finally { loader.destroy() }
})

test('encoded filename separators stay part of the manifest filename', async () => {
    const item = { href: 'OPS/image%23one.png', mediaType: 'image/png' }
    const reads = []
    const loader = loaderFor([item], { loadBlob: async href => { reads.push(href); return new Uint8Array([1]) } })
    try {
        const value = await loader.loadHref('image%23one.png#icon', 'OPS/chapter.xhtml')
        assert.ok(value.startsWith('blob:'))
        assert.ok(value.endsWith('#icon'))
        assert.deepEqual(reads, [item.href])
    } finally { loader.destroy() }
})

test('empty CSS is a successful owned resource and can be shared and released', async () => {
    const priorWindow = globalThis.window
    globalThis.window = { innerWidth: 800, innerHeight: 600 }
    const item = { href: 'empty.css', mediaType: 'text/css' }
    let reads = 0
    const loader = loaderFor([item], { loadText: async () => { reads += 1; return '' } })
    try {
        const [a,b] = await Promise.all([loader.loadItem(item),loader.loadItem(item)])
        assert.ok(a?.startsWith('blob:'))
        assert.equal(a,b)
        assert.equal(reads,1)
        assert.equal(await (await fetch(a)).text(),'')
        loader.unloadItem(item)
        assert.equal(await (await fetch(a)).text(),'')
        loader.unloadItem(item)
        await assert.rejects(fetch(a))
    } finally { loader.destroy(); globalThis.window = priorWindow }
})

test('empty replacement text is content while null is an absent resource', async () => {
    const priorWindow = globalThis.window
    globalThis.window = { innerWidth: 800, innerHeight: 600 }
    const item = { href: 'style.css', mediaType: 'text/css' }
    const loader = loaderFor([item], { loadText: async () => 'body {}', replaceText: async () => '' })
    const absent = loaderFor([item])
    try {
        const url = await loader.loadItem(item)
        assert.ok(url?.startsWith('blob:'))
        assert.equal(await (await fetch(url)).text(),'')
        assert.equal(await absent.loadItem(item),null)
    } finally { loader.destroy(); absent.destroy(); globalThis.window = priorWindow }
})

test('XHTML fallback commits MIME only after the replacement blob is published', async () => {
    const originals = { DOMParser: globalThis.DOMParser, XMLSerializer: globalThis.XMLSerializer,
        ProcessingInstruction: globalThis.ProcessingInstruction, warn: console.warn }
    let failSerialization = true
    globalThis.DOMParser = class {
        parseFromString(_text, type) {
            return { firstChild: null,
                querySelector: () => type === 'application/xhtml+xml' ? { innerText: 'invalid XHTML' } : null,
                querySelectorAll: () => [], getElementsByTagName: () => [] }
        }
    }
    globalThis.ProcessingInstruction = class {}
    globalThis.XMLSerializer = class {
        serializeToString() { if (failSerialization) throw Error('serialization failed'); return '<html>ok</html>' }
    }
    console.warn = () => {}
    const item = { href: 'chapter.xhtml', mediaType: 'application/xhtml+xml' }
    const loader = loaderFor([item], { loadText: async () => '<html>broken' })
    try {
        await assert.rejects(loader.loadItem(item), /serialization failed/)
        assert.equal(item.mediaType,'application/xhtml+xml')
        failSerialization = false
        const url = await loader.loadItem(item)
        assert.equal(item.mediaType,'text/html')
        assert.equal((await fetch(url)).headers.get('content-type'),'text/html')
    } finally {
        loader.destroy()
        Object.assign(globalThis, { DOMParser: originals.DOMParser, XMLSerializer: originals.XMLSerializer,
            ProcessingInstruction: originals.ProcessingInstruction })
        console.warn = originals.warn
    }
})


test('retirement before href completion cannot return a revoked fragment URL', async () => {
    const originalCreate = URL.createObjectURL
    const item = { href: 'image.png', mediaType: 'image/png' }
    const loader = loaderFor([item])
    URL.createObjectURL = blob => {
        const url = originalCreate(blob)
        queueMicrotask(() => loader.destroy())
        return url
    }
    try {
        assert.equal(await loader.loadHref('image.png#icon', 'chapter.xhtml'), null)
    } finally { loader.destroy(); URL.createObjectURL = originalCreate }
})

test('failed blob publication leaves fallback MIME unchanged for retry', async () => {
    const originalCreate = URL.createObjectURL
    const originals = { DOMParser: globalThis.DOMParser, XMLSerializer: globalThis.XMLSerializer,
        ProcessingInstruction: globalThis.ProcessingInstruction, warn: console.warn }
    globalThis.DOMParser = class {
        parseFromString(_text, type) {
            return { firstChild: null,
                querySelector: () => type === 'application/xhtml+xml' ? { innerText: 'invalid XHTML' } : null,
                querySelectorAll: () => [], getElementsByTagName: () => [] }
        }
    }
    globalThis.ProcessingInstruction = class {}
    globalThis.XMLSerializer = class { serializeToString() { return '<html>ok</html>' } }
    console.warn = () => {}
    const item = { href: 'chapter.xhtml', mediaType: 'application/xhtml+xml' }
    const loader = loaderFor([item], { loadText: async () => '<html>broken' })
    URL.createObjectURL = () => { throw Error('publication failed') }
    try {
        await assert.rejects(loader.loadItem(item), /publication failed/)
        assert.equal(item.mediaType,'application/xhtml+xml')
        URL.createObjectURL = originalCreate
        const url = await loader.loadItem(item)
        assert.equal((await fetch(url)).headers.get('content-type'),'text/html')
        assert.equal(item.mediaType,'text/html')
    } finally {
        loader.destroy(); URL.createObjectURL = originalCreate
        Object.assign(globalThis, { DOMParser: originals.DOMParser, XMLSerializer: originals.XMLSerializer,
            ProcessingInstruction: originals.ProcessingInstruction })
        console.warn = originals.warn
    }
})
