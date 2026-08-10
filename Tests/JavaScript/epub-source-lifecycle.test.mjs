import assert from 'node:assert/strict'
import test from 'node:test'

globalThis.DOMParser ??= class DOMParser {}

const { EPUB } = await import(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/epub.js'
)

test('destroy releases the EPUB source exactly once', () => {
    let destroyCount = 0
    const epub = new EPUB({
        loadText: async () => null,
        loadBlob: async () => null,
        getSize: () => 0,
        destroy: () => { destroyCount += 1 },
    })

    assert.equal(epub.destroy(), true)
    assert.equal(epub.destroy(), false)
    assert.equal(destroyCount, 1)
})

test('async source cleanup rejection does not escape destroy', async () => {
    const epub = new EPUB({
        loadText: async () => null,
        loadBlob: async () => null,
        getSize: () => 0,
        destroy: async () => { throw new Error('cleanup failed') },
    })

    assert.doesNotThrow(() => epub.destroy())
    await Promise.resolve()
})
