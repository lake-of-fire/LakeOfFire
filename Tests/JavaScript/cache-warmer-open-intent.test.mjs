import assert from 'node:assert/strict'
import test from 'node:test'

import {
    CacheWarmerOpenIntent,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/cache-warmer-open-intent.js'

test('open intent coalesces requests and is consumed once', () => {
    const intent = new CacheWarmerOpenIntent()

    assert.equal(intent.request(), true)
    assert.equal(intent.request(), true)
    assert.equal(intent.requested, true)
    assert.equal(intent.consume(), true)
    assert.equal(intent.consume(), false)
    assert.equal(intent.requested, false)
})

test('closing a replaced owner clears and rejects stale intent', () => {
    const intent = new CacheWarmerOpenIntent()
    intent.request()

    assert.equal(intent.close(), true)
    assert.equal(intent.requested, false)
    assert.equal(intent.request(), false)
    assert.equal(intent.consume(), false)
    assert.equal(intent.close(), false)
})
