import assert from 'node:assert/strict';
import test from 'node:test';

import {
    createOwnedAsyncCache,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/owned-async-cache.js';

test('one owner coalesces an in-flight value for the same key', async () => {
    const cache = createOwnedAsyncCache();
    let creationCount = 0;
    let release;
    const gate = new Promise(resolve => { release = resolve; });
    const createValue = async () => {
        creationCount += 1;
        await gate;
        return 'vertical';
    };

    const first = cache.getOrCreate('chapter.xhtml', createValue);
    const second = cache.getOrCreate('chapter.xhtml', createValue);
    release();

    assert.equal(await first, 'vertical');
    assert.equal(await second, 'vertical');
    assert.equal(creationCount, 1);
});

test('separate owners never reuse a same-key value from an outgoing book', async () => {
    const firstBookCache = createOwnedAsyncCache();
    const replacementBookCache = createOwnedAsyncCache();

    assert.equal(
        await firstBookCache.getOrCreate('chapter.xhtml', async () => 'vertical'),
        'vertical'
    );
    assert.equal(
        await replacementBookCache.getOrCreate('chapter.xhtml', async () => 'horizontal'),
        'horizontal'
    );
});

test('clearing one owner permits a fresh value without affecting another owner', async () => {
    const firstBookCache = createOwnedAsyncCache();
    const replacementBookCache = createOwnedAsyncCache();

    assert.equal(
        await firstBookCache.getOrCreate('chapter.xhtml', async () => 'old'),
        'old'
    );
    assert.equal(
        await replacementBookCache.getOrCreate('chapter.xhtml', async () => 'replacement'),
        'replacement'
    );

    firstBookCache.clear();

    assert.equal(
        await firstBookCache.getOrCreate('chapter.xhtml', async () => 'reloaded'),
        'reloaded'
    );
    assert.equal(
        await replacementBookCache.getOrCreate('chapter.xhtml', async () => 'wrong'),
        'replacement'
    );
});

test('a rejected operation is not retained as the owner result', async () => {
    const cache = createOwnedAsyncCache({ limit: 2 });
    await assert.rejects(
        cache.getOrCreate('chapter.xhtml', async () => { throw new Error('transient'); }),
        /transient/
    );
    assert.equal(
        await cache.getOrCreate('chapter.xhtml', async () => 'recovered'),
        'recovered'
    );
});

test('resolved values use bounded least-recently-used retention', async () => {
    const cache = createOwnedAsyncCache({ limit: 2 });
    let firstCreations = 0;

    assert.equal(await cache.getOrCreate('first', async () => {
        firstCreations += 1;
        return 'first-1';
    }), 'first-1');
    assert.equal(await cache.getOrCreate('second', async () => 'second'), 'second');
    assert.equal(await cache.getOrCreate('first', async () => 'wrong'), 'first-1');
    assert.equal(await cache.getOrCreate('third', async () => 'third'), 'third');
    assert.equal(await cache.getOrCreate('second', async () => 'second-2'), 'second-2');
    assert.equal(await cache.getOrCreate('first', async () => {
        firstCreations += 1;
        return 'first-2';
    }), 'first-2');
    assert.equal(firstCreations, 2);
});

test('non-retained results coalesce while in flight but remain retryable', async () => {
    const cache = createOwnedAsyncCache({
        shouldRemember: result => result.authoritative,
    });
    let creationCount = 0;
    let release;
    const gate = new Promise(resolve => { release = resolve; });
    const createFallback = async () => {
        creationCount += 1;
        await gate;
        return { value: 'fallback', authoritative: false };
    };

    const first = cache.getOrCreate('chapter.xhtml', createFallback);
    const second = cache.getOrCreate('chapter.xhtml', createFallback);
    release();

    assert.deepEqual(await first, { value: 'fallback', authoritative: false });
    assert.deepEqual(await second, { value: 'fallback', authoritative: false });
    assert.equal(creationCount, 1);
    assert.deepEqual(
        await cache.getOrCreate('chapter.xhtml', async () => {
            creationCount += 1;
            return { value: 'recovered', authoritative: true };
        }),
        { value: 'recovered', authoritative: true }
    );
    assert.equal(creationCount, 2);
});

test('clearing an owner aborts its exact in-flight producer and permits a fresh retry', async () => {
    const cache = createOwnedAsyncCache()
    let observedSignal = null
    let abortCount = 0
    let release
    const pending = cache.getOrCreate('chapter.xhtml', signal => new Promise((resolve, reject) => {
        observedSignal = signal
        release = resolve
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

    const wasAborted = observedSignal?.aborted === true
    if (!wasAborted) release('stale')
    if (wasAborted) {
        await assert.rejects(pending, error => error?.name === 'AbortError')
    } else {
        await pending
    }
    assert.equal(wasAborted, true)
    assert.equal(abortCount, 1)
    assert.equal(
        await cache.getOrCreate('chapter.xhtml', async () => 'replacement'),
        'replacement'
    )
})
