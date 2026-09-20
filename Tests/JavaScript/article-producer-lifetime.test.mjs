import assert from 'node:assert/strict'
import test from 'node:test'

import {
    captureArticleProducerLifetime,
    withArticleProducerLifetime,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/article-producer-lifetime.js'

test('generic host without Manabi provider keeps legacy payload shape', () => {
    const evidence = captureArticleProducerLifetime({})
    assert.deepEqual(evidence, { required: false, token: null })
    assert.deepEqual(
        withArticleProducerLifetime({ value: 1 }, evidence),
        { value: 1 }
    )
})

test('Manabi host captures one immutable producer token', () => {
    let token = 'lifetime-a'
    const host = {
        manabi_captureArticleProducerLifetimeToken() {
            return token
        },
    }
    const evidence = captureArticleProducerLifetime(host)
    token = 'lifetime-b'
    assert.equal(evidence.required, true)
    assert.equal(evidence.token, 'lifetime-a')
    assert.deepEqual(
        withArticleProducerLifetime({ value: 1 }, evidence),
        {
            value: 1,
            articleProducerLifetimeToken: 'lifetime-a',
        }
    )
})

test('required provider without a current token fails closed', () => {
    const evidence = captureArticleProducerLifetime({
        manabi_captureArticleProducerLifetimeToken() {
            return null
        },
    })
    assert.equal(evidence.required, true)
    assert.equal(evidence.token, null)
    assert.equal(withArticleProducerLifetime({ value: 1 }, evidence), null)
})

test('provider failure fails closed without changing the caller payload', () => {
    const payload = { value: 1 }
    const evidence = captureArticleProducerLifetime({
        manabi_captureArticleProducerLifetimeToken() {
            throw new Error('provider unavailable')
        },
    })
    assert.equal(withArticleProducerLifetime(payload, evidence), null)
    assert.deepEqual(payload, { value: 1 })
})
