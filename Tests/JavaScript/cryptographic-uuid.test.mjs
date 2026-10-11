import assert from 'node:assert/strict'
import test from 'node:test'
import { webcrypto } from 'node:crypto'
import { cryptographicUUID } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/cryptographic-uuid.js'
import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'
import { createBookActionBridge } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-action-bridge.js'
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const withCrypto = async (crypto, body) => {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'crypto')
    Object.defineProperty(globalThis, 'crypto', { configurable: true, value: crypto })
    try { await body() } finally {
        if (descriptor) Object.defineProperty(globalThis, 'crypto', descriptor)
        else delete globalThis.crypto
    }
}
test('secure default uses randomUUID with its receiver and canonicalizes', async () => {
    const crypto = { randomUUID() { assert.equal(this, crypto); return 'ABCDEF01-2345-4678-ABCD-0123456789AB' },
        getRandomValues() { assert.fail('Unexpected fallback') } }
    await withCrypto(crypto, () => assert.equal(cryptographicUUID(), 'abcdef01-2345-4678-abcd-0123456789ab'))
})
test('portable path fills all bytes and sets RFC 4122 version and variant', async () => {
    const crypto = { getRandomValues(bytes) {
        assert.equal(this, crypto); assert.equal(bytes.length, 16)
        bytes.fill(255); return bytes
    } }
    await withCrypto(crypto, () => assert.equal(cryptographicUUID(), 'ffffffff-ffff-4fff-bfff-ffffffffffff'))
})
for (const [name, crypto] of [
    ['absent crypto', undefined], ['no entropy API', {}], ['noncallable APIs', {randomUUID: true, getRandomValues: true}],
    ['entropy failure', {getRandomValues() { throw new Error('entropy failed') }}],
    ['native UUID failure', {randomUUID() { throw new Error('UUID failed') }, getRandomValues() { assert.fail('Do not hide native failure') }}],
]) test(name + ' fails without sending state or command', async () => withCrypto(crypto, async () => {
    assert.throws(cryptographicUUID)
    const posts = []
    const state = new BookReadingStateController({postMessage: p => posts.push(p), documentStartedAtMs: 1, topWindowURL: 'ebook://ebook/load/book.epub'})
    const bridge = createBookActionBridge({postMessage: p => posts.push(p), documentStartedAtMs: 1,
        topWindowURL: 'ebook://ebook/load/book.epub', captureContext: () => ({contextID: 'context', locationRevision: 1})})
    try {
        state.relocate({sectionURL: 'ebook://ebook/chapter.xhtml'})
        assert.equal(state.refresh(), false)
        await assert.rejects(bridge.perform('startBookOver'))
        assert.equal(bridge.recoveryInfo, null)
        assert.deepEqual(posts, [])
    } finally { state.close(); bridge.close() }
}))
test('real getRandomValues supports default state and action identities', async () => withCrypto({
    getRandomValues: bytes => webcrypto.getRandomValues(bytes),
}, async () => {
    const posts = []
    const state = new BookReadingStateController({postMessage: p => posts.push(p), documentStartedAtMs: 1, topWindowURL: 'ebook://ebook/load/book.epub'})
    const bridge = createBookActionBridge({postMessage: p => posts.push(p), documentStartedAtMs: 1,
        topWindowURL: 'ebook://ebook/load/book.epub', captureContext: () => ({contextID: 'context', locationRevision: 1})})
    try {
        state.relocate({sectionURL: 'ebook://ebook/chapter.xhtml'})
        const completion = bridge.perform('startBookOver')
        assert.equal(posts.length, 2)
        for (const post of posts) assert.match(post.requestID, uuid)
        assert.notEqual(posts[0].requestID, posts[1].requestID)
        bridge.acknowledge(posts[1].deliveryID, {requestID: posts[1].requestID, ok: false, error: 'controlled rejection'})
        await completion
    } finally { state.close(); bridge.close() }
}))
