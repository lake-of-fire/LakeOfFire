import assert from 'node:assert/strict'
import test from 'node:test'
import { Loader } from '../../Sources/LakeOfFireReader/Resources/foliate-js/epub.js'

const withURLs = async run => {
    const create = URL.createObjectURL
    const revoke = URL.revokeObjectURL
    const previousWindow = globalThis.window
    const created = []
    const revoked = []
    globalThis.window = { innerWidth: 800, innerHeight: 600 }
    URL.createObjectURL = () => {
        const url = `blob:resource-review-${created.length + 1}`
        created.push(url)
        return url
    }
    URL.revokeObjectURL = url => revoked.push(url)
    try { await run({ created, revoked }) }
    finally {
        URL.createObjectURL = create
        URL.revokeObjectURL = revoke
        if (previousWindow === undefined) delete globalThis.window
        else globalThis.window = previousWindow
    }
}

test('three concurrent circular stylesheet owners settle and release exactly once', { timeout: 1000 }, async () => {
    await withURLs(async ({ created, revoked }) => {
        const manifest = ['a.css', 'b.css', 'c.css'].map(href => ({ href, mediaType: 'text/css' }))
        const files = {
            'a.css': '@import "b.css";',
            'b.css': '@import "c.css";',
            'c.css': '@import "a.css";',
        }
        const loader = new Loader({
            resources: { manifest },
            loadText: async href => files[href],
            loadBlob: async href => files[href],
        })
        try {
            const values = await Promise.all(manifest.map(item => loader.loadItem(item)))
            assert.ok(values.every(value => value?.startsWith('blob:')))
            assert.equal(new Set(values).size, 3)
            assert.equal(revoked.length, 0)
            for (const item of manifest) loader.unloadItem(item)
            assert.deepEqual([...revoked].sort(), [...created].sort())
        } finally { loader.destroy() }
        assert.equal(new Set(revoked).size, revoked.length)
    })
})

test('first settled caller can release while a coalesced caller retains its URL', async () => {
    await withURLs(async ({ created, revoked }) => {
        let release
        let entered
        const began = new Promise(resolve => { entered = resolve })
        const item = { href: 'cover.png', mediaType: 'image/png' }
        const loader = new Loader({
            resources: { manifest: [item] },
            loadBlob: () => {
                entered()
                return new Promise(resolve => { release = resolve })
            },
        })
        try {
            const first = loader.loadItem(item).then(value => {
                loader.unloadItem(item)
                return value
            })
            await began
            const second = loader.loadItem(item)
            release(new Uint8Array([1]))
            const [firstURL, secondURL] = await Promise.all([first, second])
            assert.equal(firstURL, secondURL)
            assert.ok(secondURL?.startsWith('blob:'))
            assert.equal(created.length, 1)
            assert.equal(revoked.length, 0)
            loader.unloadItem(item)
            assert.deepEqual(revoked, created)
        } finally { loader.destroy() }
    })
})
