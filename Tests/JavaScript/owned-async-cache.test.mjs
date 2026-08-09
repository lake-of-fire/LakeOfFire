import assert from 'node:assert/strict'
import test from 'node:test'

import {
    createOwnedAsyncCache,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/owned-async-cache.js'

test('one owner coalesces an in-flight value for the same key', async () => {
    const cache = createOwnedAsyncCache()
    let creationCount = 0
    let release
    const gate = new Promise(resolve => { release = resolve })
    const createValue = async () => {
        creationCount += 1
        await gate
        return 'vertical'
    }

    const first = cache.getOrCreate('chapter.xhtml', createValue)
    const second = cache.getOrCreate('chapter.xhtml', createValue)
    release()

    assert.equal(await first, 'vertical')
    assert.equal(await second, 'vertical')
    assert.equal(creationCount, 1)
})

test('separate owners never reuse a same-key value', async () => {
    const firstCache = createOwnedAsyncCache()
    const replacementCache = createOwnedAsyncCache()

    assert.equal(await firstCache.getOrCreate('chapter.xhtml', async () => 'vertical'), 'vertical')
    assert.equal(await replacementCache.getOrCreate('chapter.xhtml', async () => 'horizontal'), 'horizontal')
})

test('a rejected operation is not retained as the owner result', async () => {
    const cache = createOwnedAsyncCache({ limit: 2 })
    await assert.rejects(
        cache.getOrCreate('chapter.xhtml', async () => { throw new Error('transient') }),
        /transient/,
    )
    assert.equal(await cache.getOrCreate('chapter.xhtml', async () => 'recovered'), 'recovered')
})

test('resolved values use bounded least-recently-used retention', async () => {
    const cache = createOwnedAsyncCache({ limit: 2 })
    let firstCreations = 0

    assert.equal(await cache.getOrCreate('first', async () => {
        firstCreations += 1
        return `first-${firstCreations}`
    }), 'first-1')
    assert.equal(await cache.getOrCreate('second', async () => 'second'), 'second')
    assert.equal(await cache.getOrCreate('first', async () => 'wrong'), 'first-1')
    assert.equal(await cache.getOrCreate('third', async () => 'third'), 'third')
    assert.equal(await cache.getOrCreate('second', async () => 'second-2'), 'second-2')
    assert.equal(await cache.getOrCreate('first', async () => {
        firstCreations += 1
        return `first-${firstCreations}`
    }), 'first-2')
})

test('non-retained results coalesce while in flight but remain retryable', async () => {
    const cache = createOwnedAsyncCache({ shouldRemember: result => result.authoritative })
    let creationCount = 0
    let release
    const gate = new Promise(resolve => { release = resolve })
    const createFallback = async () => {
        creationCount += 1
        await gate
        return { value: 'fallback', authoritative: false }
    }

    const first = cache.getOrCreate('chapter.xhtml', createFallback)
    const second = cache.getOrCreate('chapter.xhtml', createFallback)
    release()

    assert.deepEqual(await first, { value: 'fallback', authoritative: false })
    assert.deepEqual(await second, { value: 'fallback', authoritative: false })
    assert.deepEqual(
        await cache.getOrCreate('chapter.xhtml', async () => {
            creationCount += 1
            return { value: 'recovered', authoritative: true }
        }),
        { value: 'recovered', authoritative: true },
    )
    assert.equal(creationCount, 2)
})

test('clearing an owner aborts its exact in-flight producer once', async () => {
    const cache = createOwnedAsyncCache()
    let abortCount = 0
    let observedSignal
    const pending = cache.getOrCreate('chapter.xhtml', signal => new Promise((resolve, reject) => {
        observedSignal = signal
        signal?.addEventListener('abort', () => {
            abortCount += 1
            const error = new Error('owner cleared')
            error.name = 'AbortError'
            reject(error)
        }, { once: true })
    }))

    await Promise.resolve()
    cache.clear()
    cache.clear()

    assert.equal(observedSignal?.aborted, true)
    await assert.rejects(pending, error => error?.name === 'AbortError')
    assert.equal(abortCount, 1)
    assert.equal(await cache.getOrCreate('chapter.xhtml', async () => 'replacement'), 'replacement')
})
