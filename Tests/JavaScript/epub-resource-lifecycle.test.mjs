import assert from 'node:assert/strict'
import test from 'node:test'

globalThis.DOMParser = class {}

const { EPUB, Loader } = await import(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/epub.js'
)

const makeSource = destroy => ({
    loadText: async () => null,
    loadBlob: async () => null,
    getSize: () => 0,
    replaceText: value => value,
    replaceURL: value => value,
    destroy,
})

test('EPUB initialization after destruction refuses before reading the source', async () => {
    let loadTextCount = 0
    const book = new EPUB({
        ...makeSource(() => {}),
        loadText: async () => {
            loadTextCount += 1
            return null
        },
    })

    assert.equal(book.destroy(), true)
    await assert.rejects(
        book.init(),
        error => error?.name === 'AbortError' && /destroyed/.test(error.message)
    )
    assert.equal(loadTextCount, 0)
})

test('EPUB destruction while container loading is suspended prevents parsing and initialization', async () => {
    const originalDOMParser = globalThis.DOMParser
    let resolveContainer
    let parseCount = 0
    let sourceDestroyCount = 0
    globalThis.DOMParser = class {
        parseFromString() {
            parseCount += 1
            return null
        }
    }

    try {
        const book = new EPUB({
            ...makeSource(() => { sourceDestroyCount += 1 }),
            loadText: uri => {
                assert.equal(uri, 'META-INF/container.xml')
                return new Promise(resolve => { resolveContainer = resolve })
            },
        })
        const initialization = book.init()
        await Promise.resolve()

        assert.equal(book.destroy(), true)
        resolveContainer('<container/>')

        await assert.rejects(
            initialization,
            error => error?.name === 'AbortError' && /destroyed/.test(error.message)
        )
        assert.equal(parseCount, 0)
        assert.equal(sourceDestroyCount, 1)
    } finally {
        globalThis.DOMParser = originalDOMParser
    }
})

test('EPUB destruction prevents a suspended document load from parsing stale content', async () => {
    const originalDOMParser = globalThis.DOMParser
    let resolveDocument
    let parseCount = 0
    globalThis.DOMParser = class {
        parseFromString() {
            parseCount += 1
            return null
        }
    }

    try {
        const book = new EPUB({
            ...makeSource(() => {}),
            loadText: () => new Promise(resolve => { resolveDocument = resolve }),
        })
        const documentLoad = book.loadDocument({
            href: 'chapter.xhtml',
            mediaType: 'application/xhtml+xml',
        })
        await Promise.resolve()

        assert.equal(book.destroy(), true)
        resolveDocument('<html/>')

        await assert.rejects(
            documentLoad,
            error => error?.name === 'AbortError' && /destroyed/.test(error.message)
        )
        assert.equal(parseCount, 0)
    } finally {
        globalThis.DOMParser = originalDOMParser
    }
})

test('loader destroy revokes owned URLs, clears publication records, and is idempotent', () => {
    const originalURL = globalThis.URL
    const revoked = []
    let nextURL = 0
    globalThis.URL = {
        createObjectURL: () => `blob:test-${++nextURL}`,
        revokeObjectURL: url => revoked.push(url),
    }

    try {
        const loader = new Loader({
            loadText: async () => null,
            loadBlob: async () => null,
            resources: { manifest: [] },
        })
        const blobURL = loader.createURL('chapter.xhtml', '<p>chapter</p>', 'text/html')
        const directURL = loader.createDirectURL('processed.xhtml', 'manabi-reader://processed')

        assert.equal(loader.destroy(), true)
        assert.deepEqual(revoked, [blobURL])
        assert.equal(loader.createURL('late.xhtml', 'late', 'text/html'), '')
        assert.equal(loader.createDirectURL('late-direct.xhtml', directURL), '')
        assert.equal(loader.destroy(), false)
    } finally {
        globalThis.URL = originalURL
    }
})

test('loader destruction prevents late asynchronous resource publication', async () => {
    const originalURL = globalThis.URL
    let createCount = 0
    globalThis.URL = {
        createObjectURL: () => {
            createCount += 1
            return `blob:late-${createCount}`
        },
        revokeObjectURL() {},
    }

    let resolveBlob
    try {
        const item = { href: 'image.png', mediaType: 'image/png' }
        const loader = new Loader({
            loadText: async () => null,
            loadBlob: () => new Promise(resolve => { resolveBlob = resolve }),
            resources: { manifest: [item] },
        })
        const load = loader.loadItem(item)
        await Promise.resolve()
        assert.equal(loader.destroy(), true)
        resolveBlob(new Uint8Array([1, 2, 3]))

        assert.equal(await load, null)
        assert.equal(createCount, 0)
        assert.equal(await loader.loadItem(item), null)
    } finally {
        globalThis.URL = originalURL
    }
})


test('concurrent loads for one item share one cache publication and independent references', async () => {
    const originalURL = globalThis.URL
    const created = []
    const revoked = []
    globalThis.URL = {
        createObjectURL: () => {
            const url = `blob:shared-${created.length + 1}`
            created.push(url)
            return url
        },
        revokeObjectURL: url => revoked.push(url),
    }

    let resolveBlob
    let blobLoadCount = 0
    try {
        const item = { href: 'image.png', mediaType: 'image/png' }
        const loader = new Loader({
            loadText: async () => null,
            loadBlob: () => {
                blobLoadCount += 1
                return new Promise(resolve => { resolveBlob = resolve })
            },
            resources: { manifest: [item] },
        })

        const first = loader.loadItem(item)
        const second = loader.loadItem(item)
        await Promise.resolve()
        assert.equal(blobLoadCount, 1)

        resolveBlob(new TextEncoder().encode('<html/>'))
        const [firstURL, secondURL] = await Promise.all([first, second])
        assert.equal(firstURL, secondURL)
        assert.deepEqual(created, ['blob:shared-1'])

        loader.unloadItem(item)
        assert.deepEqual(revoked, [])
        loader.unloadItem(item)
        assert.deepEqual(revoked, ['blob:shared-1'])
    } finally {
        globalThis.URL = originalURL
    }
})

test('loader destruction releases replacement owners exactly once', () => {
    let replaceTextDestroyCount = 0
    let replaceURLDestroyCount = 0
    const replaceText = async (_href, text) => text
    replaceText.destroy = () => {
        replaceTextDestroyCount += 1
        return replaceTextDestroyCount === 1
    }
    const replaceURL = async () => 'ebook://ebook/processed-section'
    replaceURL.destroy = () => {
        replaceURLDestroyCount += 1
        return replaceURLDestroyCount === 1
    }
    const loader = new Loader({
        loadText: async () => null,
        loadBlob: async () => null,
        resources: { manifest: [] },
        replaceText,
        replaceURL,
    })

    assert.equal(loader.destroy(), true)
    assert.equal(loader.destroy(), false)
    assert.equal(replaceTextDestroyCount, 1)
    assert.equal(replaceURLDestroyCount, 1)
})

test('destroyed loader does not enter replacement after suspended text loading resumes', async () => {
    let releaseText
    let replaceTextCount = 0
    const item = { href: 'chapter.xhtml', mediaType: 'application/xhtml+xml' }
    const loader = new Loader({
        loadText: () => new Promise(resolve => { releaseText = resolve }),
        loadBlob: async () => null,
        resources: { manifest: [item] },
        replaceText: async (_href, text) => {
            replaceTextCount += 1
            return text
        },
    })

    const pendingLoad = loader.loadItem(item)
    await Promise.resolve()
    assert.equal(loader.destroy(), true)
    releaseText('<html><body>stale</body></html>')

    assert.equal(await pendingLoad, null)
    assert.equal(replaceTextCount, 0)
})

test('destroyed loader invalidates a suspended direct replacement owner before its side effect', async () => {
    let releaseReplacement
    let active = true
    let livePublicationCount = 0
    let destroyCount = 0
    const replaceURL = async () => {
        await new Promise(resolve => { releaseReplacement = resolve })
        if (!active) return null
        livePublicationCount += 1
        return 'ebook://ebook/processed-section?sourceURL=old-book'
    }
    replaceURL.destroy = () => {
        if (!active) return false
        active = false
        destroyCount += 1
        return true
    }
    const item = { href: 'chapter.xhtml', mediaType: 'application/xhtml+xml' }
    const loader = new Loader({
        loadText: async () => null,
        loadBlob: async () => null,
        resources: { manifest: [item] },
        replaceURL,
    })

    const pendingLoad = loader.loadItem(item)
    await Promise.resolve()
    assert.equal(loader.destroy(), true)
    releaseReplacement()

    assert.equal(await pendingLoad, null)
    assert.equal(destroyCount, 1)
    assert.equal(livePublicationCount, 0)
})

test('recursive replacement resources do not overwrite or outlive the outer href publication', async () => {
    const originalCreateObjectURL = globalThis.URL.createObjectURL
    const originalRevokeObjectURL = globalThis.URL.revokeObjectURL
    const originalWindow = globalThis.window
    const created = []
    const revoked = []
    globalThis.URL.createObjectURL = () => {
        const url = `blob:recursive-${created.length + 1}`
        created.push(url)
        return url
    }
    globalThis.URL.revokeObjectURL = url => revoked.push(url)
    globalThis.window = { innerWidth: 800, innerHeight: 600 }

    try {
        const item = { href: 'styles/book.css', mediaType: 'text/css' }
        const loader = new Loader({
            loadText: async href => {
                assert.equal(href, item.href)
                return '@import "book.css"; body { color: black; }'
            },
            loadBlob: async href => {
                assert.equal(href, item.href)
                return new TextEncoder().encode('body { color: black; }')
            },
            resources: { manifest: [item] },
        })

        const outerURL = await loader.loadItem(item)
        assert.equal(outerURL, 'blob:recursive-2')
        assert.deepEqual(created, ['blob:recursive-1', 'blob:recursive-2'])

        loader.unloadItem(item)

        assert.deepEqual(revoked, ['blob:recursive-2', 'blob:recursive-1'])
    } finally {
        globalThis.URL.createObjectURL = originalCreateObjectURL
        globalThis.URL.revokeObjectURL = originalRevokeObjectURL
        globalThis.window = originalWindow
    }
})

test('failed parent replacement rolls back child resources created before commit', async () => {
    const originalCreateObjectURL = globalThis.URL.createObjectURL
    const originalRevokeObjectURL = globalThis.URL.revokeObjectURL
    const originalWindow = globalThis.window
    const created = []
    const revoked = []
    globalThis.URL.createObjectURL = () => {
        if (created.length === 1) throw new Error('parent publication failed')
        const url = `blob:rollback-${created.length + 1}`
        created.push(url)
        return url
    }
    globalThis.URL.revokeObjectURL = url => revoked.push(url)
    globalThis.window = { innerWidth: 800, innerHeight: 600 }

    try {
        const parent = { href: 'styles/book.css', mediaType: 'text/css' }
        const child = { href: 'images/background.png', mediaType: 'image/png' }
        const loader = new Loader({
            loadText: async href => {
                assert.equal(href, parent.href)
                return '@import "../images/background.png";'
            },
            loadBlob: async href => {
                assert.equal(href, child.href)
                return new Uint8Array([1, 2, 3])
            },
            resources: { manifest: [parent, child] },
        })

        await assert.rejects(loader.loadItem(parent), /parent publication failed/)
        assert.deepEqual(created, ['blob:rollback-1'])
        assert.deepEqual(revoked, ['blob:rollback-1'])
    } finally {
        globalThis.URL.createObjectURL = originalCreateObjectURL
        globalThis.URL.revokeObjectURL = originalRevokeObjectURL
        globalThis.window = originalWindow
    }
})


const deferred = () => {
    let resolve, reject
    const promise = new Promise((yes, no) => { resolve = yes; reject = no })
    return { promise, resolve, reject }
}

const withURLs = async run => {
    const originalCreate = URL.createObjectURL
    const originalRevoke = URL.revokeObjectURL
    const originalWindow = globalThis.window
    const created = [], revoked = []
    URL.createObjectURL = blob => {
        const url = `blob:owned-${created.length + 1}`
        created.push({ url, blob })
        return url
    }
    URL.revokeObjectURL = url => revoked.push(url)
    globalThis.window = { innerWidth: 800, innerHeight: 600 }
    try { await run({ created, revoked }) }
    finally {
        URL.createObjectURL = originalCreate
        URL.revokeObjectURL = originalRevoke
        globalThis.window = originalWindow
    }
}

const makeLoader = (manifest, options = {}) => new Loader({
    resources: { manifest },
    loadText: async () => null,
    loadBlob: async () => new Uint8Array([1]),
    ...options,
})

test('native direct section URL coalesces without text/blob fallback and survives one unload', async () => {
    await withURLs(async ({ created, revoked }) => {
        const gate = deferred()
        const entered = deferred()
        const item = { href: 'OPS/chapter.xhtml', mediaType: 'application/xhtml+xml' }
        const exactURL = 'ebook://ebook/processed-section?sourceURL=file%3A%2F%2Fbook.epub&section=OPS%2Fchapter.xhtml'
        let calls = 0
        const loader = makeLoader([item], {
            loadText() { throw Error('native direct route read text') },
            loadBlob() { throw Error('native direct route read blob') },
            replaceURL: async (href, type) => {
                calls += 1
                assert.equal(href, item.href)
                assert.equal(type, item.mediaType)
                entered.resolve()
                return gate.promise
            },
        })
        const first = loader.loadItem(item)
        const second = loader.loadItem(item)
        await entered.promise
        gate.resolve(exactURL)
        assert.deepEqual(await Promise.all([first, second]), [exactURL, exactURL])
        assert.equal(calls, 1)
        loader.unloadItem(item)
        assert.equal(await loader.loadItem(item), exactURL)
        assert.equal(calls, 1)
        loader.unloadItem(item)
        loader.unloadItem(item)
        assert.deepEqual(created, [])
        assert.deepEqual(revoked, [])
        loader.destroy()
    })
})

test('failed shared source read releases pending state and retries once', async () => {
    await withURLs(async ({ created, revoked }) => {
        const gate = deferred()
        const item = { href: 'image.png', mediaType: 'image/png' }
        let calls = 0
        const loader = makeLoader([item], {
            loadBlob: () => ++calls === 1 ? gate.promise : new Uint8Array([2]),
        })
        const first = loader.loadItem(item)
        const second = loader.loadItem(item)
        const settled = Promise.allSettled([first, second])
        gate.reject(new Error('read failed'))
        const outcomes = await settled
        assert.deepEqual(outcomes.map(value => value.status), ['rejected', 'rejected'])
        assert.equal(calls, 1)
        const url = await loader.loadItem(item)
        assert.equal(calls, 2)
        assert.equal(created.length, 1)
        loader.unloadItem(item)
        assert.deepEqual(revoked, [url])
        loader.destroy()
    })
})

test('concurrent mutually importing styles settle without canonical cache cycles', { timeout: 1000 }, async () => {
    await withURLs(async ({ created, revoked }) => {
        const a = { href: 'a.css', mediaType: 'text/css' }
        const b = { href: 'b.css', mediaType: 'text/css' }
        const gate = deferred()
        let reads = 0
        const loader = makeLoader([a, b], {
            loadText: async href => {
                if (++reads === 2) gate.resolve()
                await gate.promise
                return href === 'a.css' ? '@import "b.css";' : '@import "a.css";'
            },
        })
        try {
            const [aURL, bURL] = await Promise.all([loader.loadItem(a), loader.loadItem(b)])
            assert.notEqual(aURL, bURL)
            assert.equal(reads, 2)
            assert.equal(created.length, 3)
            assert.equal(await loader.loadItem(a), aURL)
            assert.equal(await loader.loadItem(b), bURL)
            loader.unloadItem(a)
            loader.unloadItem(b)
            assert.deepEqual(revoked, [])
            loader.unloadItem(a)
            loader.unloadItem(b)
            assert.deepEqual(new Set(revoked), new Set(created.map(value => value.url)))
            assert.equal(revoked.length, created.length)
        } finally { loader.destroy() }
    })
})

test('failed recursive replacement rolls back raw escape and retries cleanly', async () => {
    await withURLs(async ({ created, revoked }) => {
        const item = { href: 'loop.css', mediaType: 'text/css' }
        const create = URL.createObjectURL
        let fail = true
        URL.createObjectURL = blob => {
            if (fail && created.length === 1) throw Error('publish failed')
            return create(blob)
        }
        const loader = makeLoader([item], { loadText: async () => '@import "loop.css";' })
        try {
            await assert.rejects(loader.loadItem(item), /publish failed/)
            assert.equal(revoked.length, 1)
            fail = false
            const url = await loader.loadItem(item)
            assert.equal(created.length, 3)
            loader.unloadItem(item)
            assert.equal(revoked[1], url)
            assert.equal(revoked.length, 3)
        } finally { loader.destroy() }
    })
})

test('destruction during text replacement fences publication and isolates async owner cleanup', async () => {
    await withURLs(async ({ created }) => {
        const gate = deferred(), entered = deferred()
        let destroyed = 0
        const replacement = async () => { entered.resolve(); return gate.promise }
        replacement.destroy = async () => { destroyed += 1; throw Error('owner cleanup') }
        const item = { href: 'book.css', mediaType: 'text/css' }
        const loader = makeLoader([item], { loadText: async () => 'body {}', replaceText: replacement })
        const load = loader.loadItem(item)
        await entered.promise
        loader.destroy()
        gate.resolve('body { color: red }')
        assert.equal(await load, null)
        assert.equal(destroyed, 1)
        assert.equal(created.length, 0)
        await new Promise(resolve => setImmediate(resolve))
    })
})

test('EPUB cover and bookmark awaits cannot return stale results after destroy', async () => {
    for (const kind of ['cover', 'bookmarks']) {
        const gate = deferred(), entered = deferred()
        const book = new EPUB({
            ...makeSource(() => {}),
            loadText: () => { entered.resolve(); return gate.promise },
            loadBlob: () => { entered.resolve(); return gate.promise },
        })
        book.resources = { cover: { href: 'cover.png', mediaType: 'image/png' } }
        const load = kind === 'cover' ? book.getCover() : book.getCalibreBookmarks()
        await entered.promise
        book.destroy()
        gate.resolve(kind === 'cover' ? new Uint8Array([1]) : 'encoding=json+base64:e30=')
        await assert.rejects(load, { name: 'AbortError' })
        await assert.rejects(book.loadMediaOverlay({}), { name: 'AbortError' })
    }
})

// Minimal package DOM used by the real Resources/CFI parser; chapter content stays
// on the native direct route and therefore needs no browser DOM implementation.
const packageDocument = () => {
    const element = (localName, attributes = {}, children = []) => ({
        nodeType: 1, localName, children, childNodes: children,
        id: attributes.id,
        getAttribute: name => attributes[name] ?? null,
    })
    const metadata = element('metadata')
    const manifest = element('manifest', {}, [element('item', {
        id: 'chapter', href: 'chapter.xhtml', 'media-type': 'application/xhtml+xml',
    })])
    const spine = element('spine', {}, [element('itemref', { idref: 'chapter', id: 'spine-authored' })])
    const root = element('package', {}, [metadata, manifest, spine])
    const document = {
        documentElement: root,
        lookupNamespaceURI: () => null,
        lookupPrefix: () => null,
        getElementsByTagName: () => [],
        getElementsByTagNameNS: () => [],
        getElementById: () => null,
        querySelector: () => null,
    }
    const attach = (node, parent) => {
        node.parentNode = parent
        node.ownerDocument = document
        for (const child of node.children) attach(child, node)
    }
    attach(root, document)
    return document
}

const containerDocument = () => ({
    querySelector: () => null,
    getElementsByTagNameNS: () => ['First/package.opf', 'Selected/package.opf'].map(path => ({
        getAttribute: name => name === 'full-path' ? path : 'application/oebps-package+xml',
    })),
})

test('EPUB init preserves selected native rendition and section handles cannot revive a destroyed owner', async () => {
    const reads = []
    let replacements = 0, sourceDestroys = 0, replacementDestroys = 0
    const gate = deferred(), entered = deferred()
    const replaceURL = async href => {
        replacements += 1
        assert.equal(href, 'Selected/chapter.xhtml')
        entered.resolve()
        return gate.promise
    }
    replaceURL.destroy = () => { replacementDestroys += 1 }
    const book = new EPUB({
        loadText: async href => { reads.push(href); return href === 'META-INF/encryption.xml' ? null : href },
        loadBlob: async () => { throw Error('direct native chapter must not read blob') },
        getSize: () => 12,
        packageDocumentPath: 'Selected/package.opf',
        replaceURL,
        destroy: () => { sourceDestroys += 1 },
    })
    book.parser = { parseFromString: source => source === 'META-INF/container.xml'
        ? containerDocument() : packageDocument() }
    assert.equal(await book.init(), book)
    assert.deepEqual(reads, ['META-INF/container.xml', 'Selected/package.opf', 'META-INF/encryption.xml'])
    const section = book.sections[0]
    assert.equal(section.id, 'Selected/chapter.xhtml')
    const loads = [section.load(), section.load()]
    await entered.promise
    assert.equal(book.destroy(), true)
    gate.resolve('ebook://ebook/processed-section?exact=selected%2Fchapter.xhtml')
    assert.deepEqual(await Promise.all(loads), [null, null])
    assert.equal(replacements, 1)
    assert.equal(sourceDestroys, 1)
    assert.equal(replacementDestroys, 1)
    assert.equal(await section.load(), null)
    assert.doesNotThrow(() => section.unload())
    await assert.rejects(section.createDocument(), { name: 'AbortError' })
    assert.equal(book.destroy(), false)
})

test('EPUB init still rejects a native package path absent from container declarations', async () => {
    const reads = []
    const book = new EPUB({
        ...makeSource(() => {}),
        packageDocumentPath: 'Missing/package.opf',
        loadText: async href => { reads.push(href); return href },
    })
    book.parser = { parseFromString: () => containerDocument() }
    try {
        await assert.rejects(book.init(), /Native EPUB rendition does not match/)
        assert.deepEqual(reads, ['META-INF/container.xml'])
    } finally { book.destroy() }
})

test('parent rollback preserves an independently held child resource', async () => {
    await withURLs(async ({ created, revoked }) => {
        const child = { href: 'shared.png', mediaType: 'image/png' }
        const parent = { href: 'parent.css', mediaType: 'text/css' }
        const loader = makeLoader([child, parent], { loadText: async () => 'body { background: url("shared.png") }' })
        const childURL = await loader.loadItem(child)
        const create = URL.createObjectURL
        URL.createObjectURL = () => { throw Error('parent failed') }
        try {
            await assert.rejects(loader.loadItem(parent), /parent failed/)
            assert.deepEqual(revoked, [])
            URL.createObjectURL = create
            const parentURL = await loader.loadItem(parent)
            loader.unloadItem(child)
            assert.deepEqual(revoked, [])
            loader.unloadItem(parent)
            assert.deepEqual(revoked, [parentURL, childURL])
            assert.equal(created.length, 2)
        } finally { loader.destroy() }
    })
})

test('one replacement function shared by both hooks is destroyed once', async () => {
    let calls = 0
    const owner = async () => null
    owner.destroy = () => { calls += 1 }
    const loader = makeLoader([], { replaceText: owner, replaceURL: owner })
    assert.equal(loader.destroy(), true)
    assert.equal(loader.destroy(), false)
    assert.equal(calls, 1)
})


test('synchronous source reentry joins the registered owner before loading', async () => {
    await withURLs(async ({ created, revoked }) => {
        const item = { href: 'image.png', mediaType: 'image/png' }
        let calls = 0, reentered
        const loader = makeLoader([item], {
            loadBlob: () => {
                calls += 1
                if (calls === 1) reentered = loader.loadItem(item)
                return new Uint8Array([1])
            },
        })
        try {
            const firstURL = await loader.loadItem(item)
            const secondURL = await reentered
            assert.equal(calls, 1)
            assert.equal(firstURL, secondURL)
            assert.equal(created.length, 1)
            loader.unloadItem(item)
            assert.deepEqual(revoked, [])
            loader.unloadItem(item)
            assert.deepEqual(revoked, [firstURL])
        } finally { loader.destroy() }
    })
})

test('media overlay rejects destruction between XML and public continuations', async () => {
    const gate = deferred()
    const book = new EPUB({ loadText: () => gate.promise })
    book.resources = { getItemByID: () => ({ href: 'overlay.smil' }) }
    let overlayReads = 0
    book.parser = { parseFromString: () => ({
        querySelector: () => null,
        lookupNamespaceURI: () => null,
        lookupPrefix: () => null,
        getElementsByTagName: () => { overlayReads += 1; return [] },
    }) }
    const pending = book.loadMediaOverlay({ mediaOverlay: 'audio' })
    // #loadXML resumes first; destruction then precedes its caller's continuation.
    gate.promise.then(() => book.destroy())
    gate.resolve('<smil/>')
    try {
        await assert.rejects(pending, { name: 'AbortError' })
        assert.equal(overlayReads, 0)
    } finally { book.destroy() }
})
