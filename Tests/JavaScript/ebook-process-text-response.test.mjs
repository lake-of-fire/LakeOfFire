import assert from 'node:assert/strict'
import test from 'node:test'

import {
    ebookProcessTextResponseIsAuthoritative,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-process-text-response.js'

const responseWithHeader = value => ({
    headers: {
        get: name => name === 'x-manabi-processing-authoritative' ? value : null,
    },
})

test('accepts only an explicitly authoritative processing response', () => {
    assert.equal(ebookProcessTextResponseIsAuthoritative(responseWithHeader('true')), true)
    assert.equal(ebookProcessTextResponseIsAuthoritative(responseWithHeader('false')), false)
    assert.equal(ebookProcessTextResponseIsAuthoritative(responseWithHeader(null)), false)
    assert.equal(ebookProcessTextResponseIsAuthoritative(responseWithHeader('TRUE')), false)
    assert.equal(ebookProcessTextResponseIsAuthoritative(null), false)
})
