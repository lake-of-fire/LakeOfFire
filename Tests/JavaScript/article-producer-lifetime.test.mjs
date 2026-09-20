import assert from 'node:assert/strict'
import test from 'node:test'

import {
    captureArticleMutationProducer,
    withArticleMutationProducer,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/article-producer-lifetime.js'

test('generic host without Manabi provider keeps legacy payload shape', () => {
    const evidence = captureArticleMutationProducer({})
    assert.deepEqual(evidence, { required: false, token: null })
    assert.deepEqual(
        withArticleMutationProducer({ value: 1 }, evidence),
        { value: 1 }
    )
})

test('Manabi host captures one immutable producer token', () => {
    let token = 'lifetime-a'
    const host = {
        manabi_captureArticleMutationProducerToken() {
            return token
        },
    }
    const evidence = captureArticleMutationProducer(host)
    token = 'lifetime-b'
    assert.equal(evidence.required, true)
    assert.equal(evidence.token, 'lifetime-a')
    assert.deepEqual(
        withArticleMutationProducer({ value: 1 }, evidence),
        {
            value: 1,
            articleMutationProducerToken: 'lifetime-a',
        }
    )
})

test('required provider without a current token fails closed', () => {
    const evidence = captureArticleMutationProducer({
        manabi_captureArticleMutationProducerToken() {
            return null
        },
    })
    assert.equal(evidence.required, true)
    assert.equal(evidence.token, null)
    assert.equal(withArticleMutationProducer({ value: 1 }, evidence), null)
})

test('provider failure fails closed without changing the caller payload', () => {
    const payload = { value: 1 }
    const evidence = captureArticleMutationProducer({
        manabi_captureArticleMutationProducerToken() {
            throw new Error('provider unavailable')
        },
    })
    assert.equal(withArticleMutationProducer(payload, evidence), null)
    assert.deepEqual(payload, { value: 1 })
})
