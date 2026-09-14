import assert from 'node:assert/strict'
import test from 'node:test'

globalThis.DOMParser ??= class DOMParser {}
globalThis.window ??= { innerWidth: 800, innerHeight: 600 }
const { Loader } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/epub.js')

const deferred = () => {
    let resolve
    let reject
    const promise = new Promise((success, failure) => {
        resolve = success
        reject = failure
    })
    return { promise, resolve, reject }
}

async function withTrackedURLs(operation) {
    const originalCreate = URL.createObjectURL
    const originalRevoke = URL.revokeObjectURL
    const created = new Map()
    const revoked = []
    URL.createObjectURL = blob => {
        const url = `blob:ownership-${created.size}`
        created.set(url, blob)
        return url
    }
    URL.revokeObjectURL = url => revoked.push(url)
    try {
        await operation({ created, revoked })
    } finally {
        URL.createObjectURL = originalCreate
        URL.revokeObjectURL = originalRevoke
    }
}

test('concurrent consumers share one resource until the last unload', async () => {
    await withTrackedURLs(async ({ created, revoked }) => {
        const item = { href: 'image.png', mediaType: 'image/png' }
        const gate = deferred()
        let calls = 0
        const loader = new Loader({
            resources: { manifest: [item] },
            loadBlob: () => { calls += 1; return gate.promise },
        })
        try {
            const first = loader.loadItem(item)
            const second = loader.loadItem(item)
            gate.resolve(new Blob(['image']))
            const urls = await Promise.all([first, second])
            assert.equal(calls, 1)
            assert.equal(created.size, 1)
            assert.equal(urls[0], urls[1])
            loader.unloadItem(item)
            assert.equal(revoked.length, 0)
            loader.unloadItem(item)
            assert.deepEqual(revoked, [urls[0]])
        } finally { loader.destroy() }
    })
})

test('unload between publication and consumer resumption preserves the other reservation', async () => {
    await withTrackedURLs(async ({ created, revoked }) => {
        const item = { href: 'image.png', mediaType: 'image/png' }
        const gate = deferred()
        const loader = new Loader({
            resources: { manifest: [item] },
            loadBlob: () => gate.promise,
        })
        try {
            const first = loader.loadItem(item)
            const second = loader.loadItem(item)
            gate.resolve(new Blob(['image']))
            await Promise.resolve()
            await Promise.resolve()
            loader.unloadItem(item)
            const urls = await Promise.all([first, second])
            assert.equal(created.size, 1)
            assert.equal(urls.filter(Boolean).length, 1)
            assert.equal(revoked.length, 0)
            loader.unloadItem(item)
            assert.deepEqual(revoked, [...created.keys()])
        } finally { loader.destroy() }
    })
})

test('disabled scripts cannot be acquired from the cache', async () => {
    await withTrackedURLs(async ({ revoked }) => {
        const item = { href: 'script.js', mediaType: 'application/javascript' }
        const loader = new Loader({
            resources: { manifest: [item] },
            loadText: async () => 'const answer = 42;',
        })
        try {
            loader.allowScript = true
            const url = await loader.loadItem(item)
            assert.ok(url)
            loader.allowScript = false
            assert.equal(await loader.loadItem(item), null)
            loader.unloadItem(item)
            assert.deepEqual(revoked, [url])
        } finally { loader.destroy() }
    })
})

test('destroy rejects a late direct section publication', async () => {
    const item = { href: 'section.xhtml', mediaType: 'application/xhtml+xml' }
    const gate = deferred()
    const loader = new Loader({
        resources: { manifest: [item] },
        replaceURL: () => gate.promise,
    })
    const result = loader.loadItem(item)
    assert.equal(loader.destroy(), true)
    gate.resolve('reader-file://processed/section.xhtml')
    assert.equal(await result, null)
    assert.equal(await loader.loadItem(item), null)
    assert.equal(loader.destroy(), false)
})

test('failed parent releases acquired children and can retry', async () => {
    await withTrackedURLs(async ({ created, revoked }) => {
        const parent = { href: 'style.css', mediaType: 'text/css' }
        const manifest = [parent, ...['first.png', 'second.png'].map(href => ({
            href, mediaType: 'image/png',
        }))]
        let fail = true
        const loader = new Loader({
            resources: { manifest },
            loadText: async () => 'a { background: url(first.png) } b { background: url(second.png) }',
            loadBlob: async href => {
                if (fail && href === 'second.png') throw new Error('unavailable child')
                return new Blob([href])
            },
        })
        try {
            await assert.rejects(loader.loadItem(parent), /unavailable child/)
            assert.equal(created.size, 1)
            assert.deepEqual(revoked, [...created.keys()])
            fail = false
            assert.ok(await loader.loadItem(parent))
            loader.unloadItem(parent)
            assert.equal(new Set(revoked).size, created.size)
            assert.equal(revoked.length, created.size)
        } finally { loader.destroy() }
    })
})

test('reciprocal CSS loads retain separate raw-cycle ownership', { timeout: 2000 }, async () => {
    await withTrackedURLs(async ({ created, revoked }) => {
        const manifest = ['a.css', 'b.css'].map(href => ({ href, mediaType: 'text/css' }))
        const loader = new Loader({
            resources: { manifest },
            loadText: async href => `@import "${href === 'a.css' ? 'b.css' : 'a.css'}";`,
            loadBlob: async href => new Blob([href]),
        })
        try {
            const urls = await Promise.all(manifest.map(item => loader.loadItem(item)))
            assert.ok(urls.every(Boolean))
            assert.notEqual(urls[0], urls[1])
            assert.equal(created.size, 3)
            loader.unloadItem(manifest[0])
            assert.ok(!revoked.includes(urls[1]))
            loader.unloadItem(manifest[1])
            assert.equal(new Set(revoked).size, created.size)
            assert.equal(revoked.length, created.size)
        } finally { loader.destroy() }
    })
})
