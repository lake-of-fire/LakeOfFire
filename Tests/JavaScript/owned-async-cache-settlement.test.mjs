import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

// Import the complete shipping module, not a copied declaration or a mock cache.
const resource = process.env.LAKE_OWNED_ASYNC_CACHE_SOURCE
    || new URL('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/owned-async-cache.js', import.meta.url)
const source = await readFile(resource, 'utf8')
const { createOwnedAsyncCache } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)

const deferred = () => {
    let resolve, reject
    const promise = new Promise((yes, no) => { resolve = yes; reject = no })
    return { promise, resolve, reject }
}

test('clear during retention cannot repopulate the retired cache', async () => {
    let cache
    let decisions = 0
    cache = createOwnedAsyncCache({ shouldRemember() {
        if (++decisions === 1) cache.clear()
        return true
    } })
    assert.equal(await cache.getOrCreate('chapter', () => 'old'), 'old')
    assert.equal(await cache.getOrCreate('chapter', () => 'new'), 'new')
    assert.equal(decisions, 2)
})

test('a result property getter cannot retain a cleared processing result', async () => {
    // Same retention callback as makeReplaceText; the accessor controls the
    // invalidation schedule, not the native processing or WebKit runtime.
    const cache = createOwnedAsyncCache({
        shouldRemember: value => value?.isAuthoritativelyProcessed === true,
    })
    const old = { get isAuthoritativelyProcessed() { cache.clear(); return true } }
    assert.equal(await cache.getOrCreate('chapter', () => old), old)
    const next = { isAuthoritativelyProcessed: true }
    assert.equal(await cache.getOrCreate('chapter', () => next), next)
})

test('reentrant replacement retains its own in-flight slot and result', async () => {
    const next = deferred()
    let replacement
    let cache
    cache = createOwnedAsyncCache({ shouldRemember(value) {
        if (value === 'old') {
            cache.clear()
            replacement = cache.getOrCreate('chapter', () => next.promise)
        }
        return true
    } })
    assert.equal(await cache.getOrCreate('chapter', () => 'old'), 'old')
    let unexpectedCreates = 0
    const follower = cache.getOrCreate('chapter', () => { unexpectedCreates++; return 'unexpected' })
    next.resolve('new')
    assert.equal(await replacement, 'new')
    assert.equal(await follower, 'new')
    assert.equal(unexpectedCreates, 0)
    assert.equal(await cache.getOrCreate('chapter', () => 'unexpected'), 'new')
})

test('coalesced callers share a retention failure and a later request retries', async () => {
    const load = deferred()
    const failure = new Error('retention failed')
    let shouldFail = true
    let creates = 0
    const cache = createOwnedAsyncCache({ shouldRemember() {
        if (shouldFail) throw failure
        return true
    } })
    const first = cache.getOrCreate('chapter', () => { creates++; return load.promise })
    const second = cache.getOrCreate('chapter', () => { creates++; return 'wrong' })
    const outcomes = Promise.allSettled([first, second])
    load.resolve('old')
    const results = await outcomes
    assert.deepEqual(results.map(result => result.status), ['rejected', 'rejected'])
    assert.equal(results[0].reason, failure)
    assert.equal(results[1].reason, failure)
    assert.equal(creates, 1)
    shouldFail = false
    assert.equal(await cache.getOrCreate('chapter', () => 'new'), 'new')
})

test('ordinary concurrent callers share one factory and retained result', async () => {
    const load = deferred()
    let creates = 0, decisions = 0
    const cache = createOwnedAsyncCache({ shouldRemember() { decisions++; return true } })
    const first = cache.getOrCreate('chapter', () => { creates++; return load.promise })
    const second = cache.getOrCreate('chapter', () => { creates++; return 'wrong' })
    load.resolve('value')
    assert.deepEqual(await Promise.all([first, second]), ['value', 'value'])
    assert.equal(await cache.getOrCreate('chapter', () => 'wrong'), 'value')
    assert.equal(creates, 1)
    assert.equal(decisions, 1)
})

test('late success after clear resolves original callers but cannot displace a replacement', async () => {
    const load = deferred()
    let signal
    const cache = createOwnedAsyncCache()
    const first = cache.getOrCreate('chapter', value => { signal = value; return load.promise })
    const second = cache.getOrCreate('chapter', () => 'wrong')
    await Promise.resolve()
    cache.clear()
    assert.equal(signal.aborted, true)
    assert.equal(await cache.getOrCreate('chapter', () => 'new'), 'new')
    load.resolve('old')
    assert.deepEqual(await Promise.all([first, second]), ['old', 'old'])
    assert.equal(await cache.getOrCreate('chapter', () => 'wrong'), 'new')
})

test('late rejection after clear does not release the replacement producer', async () => {
    const old = deferred(), next = deferred()
    const failure = new Error('old failed')
    const cache = createOwnedAsyncCache()
    const first = cache.getOrCreate('chapter', () => old.promise)
    const checked = assert.rejects(first, error => error === failure)
    cache.clear()
    const replacement = cache.getOrCreate('chapter', () => next.promise)
    old.reject(failure)
    await checked
    let creates = 0
    const follower = cache.getOrCreate('chapter', () => { creates++; return 'wrong' })
    next.resolve('new')
    assert.deepEqual(await Promise.all([replacement, follower]), ['new', 'new'])
    assert.equal(creates, 0)
})

test('synchronous factory errors reach all coalesced callers and leave a retryable key', async () => {
    const failure = new Error('factory failed')
    const cache = createOwnedAsyncCache()
    const first = cache.getOrCreate('chapter', () => { throw failure })
    const second = cache.getOrCreate('chapter', () => 'wrong')
    const results = await Promise.allSettled([first, second])
    assert.deepEqual(results.map(result => result.status), ['rejected', 'rejected'])
    assert.ok(results.every(result => result.reason === failure))
    assert.equal(await cache.getOrCreate('chapter', () => 'new'), 'new')
})

test('retention rejection does not cache a successful result', async () => {
    const cache = createOwnedAsyncCache({ shouldRemember: value => value !== 'uncached' })
    assert.equal(await cache.getOrCreate('chapter', () => 'uncached'), 'uncached')
    assert.equal(await cache.getOrCreate('chapter', () => 'retained'), 'retained')
    assert.equal(await cache.getOrCreate('chapter', () => 'wrong'), 'retained')
})

test('zero retention still coalesces in-flight work', async () => {
    const cache = createOwnedAsyncCache({ limit: 0 })
    const load = deferred()
    const first = cache.getOrCreate('chapter', () => load.promise)
    const second = cache.getOrCreate('chapter', () => 'wrong')
    load.resolve('old')
    assert.deepEqual(await Promise.all([first, second]), ['old', 'old'])
    assert.equal(await cache.getOrCreate('chapter', () => 'new'), 'new')
})

test('LRU eviction preserves the most recently used entry', async () => {
    const cache = createOwnedAsyncCache({ limit: 2 })
    await cache.getOrCreate('a', () => 'a1')
    await cache.getOrCreate('b', () => 'b1')
    assert.equal(await cache.getOrCreate('a', () => 'wrong'), 'a1')
    await cache.getOrCreate('c', () => 'c1')
    assert.equal(await cache.getOrCreate('a', () => 'wrong'), 'a1')
    assert.equal(await cache.getOrCreate('b', () => 'b2'), 'b2')
})

test('undefined is a cacheable value', async () => {
    let creates = 0
    const cache = createOwnedAsyncCache()
    await cache.getOrCreate('chapter', () => { creates++; return undefined })
    assert.equal(await cache.getOrCreate('chapter', () => { creates++; return 'wrong' }), undefined)
    assert.equal(creates, 1)
})
