import assert from 'node:assert/strict'
import test from 'node:test'

import {
    ebookSegmentIdentity,
    ebookSegmentIdentifierAliases,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-segment-identity.js'

const segmentNode = id => ({
    id,
    getAttribute: name => name === 'id' ? id : null,
})

test('uses only sidecar sid as durable segment identity', () => {
    const metadata = {
        i: 'metadata-element-id',
        sid: 'stable-id',
        h: 'segment-hash',
    }
    const identity = ebookSegmentIdentity(segmentNode('runtime-id'), metadata)

    assert.equal(identity.segmentIdentifier, 'stable-id')
    assert.equal(identity.hasSidecarStableID, true)
    assert.deepEqual(ebookSegmentIdentifierAliases(segmentNode('runtime-id'), metadata), ['stable-id'])
})

test('does not promote runtime, metadata, or hash IDs when sid is absent', () => {
    const identity = ebookSegmentIdentity(segmentNode('runtime-id'), {
        i: 'metadata-element-id',
        h: 'segment-hash',
    })

    assert.equal(identity.segmentIdentifier, null)
    assert.equal(identity.stableID, null)
    assert.equal(identity.hasSidecarStableID, false)
    assert.deepEqual(ebookSegmentIdentifierAliases(segmentNode('runtime-id'), identity), [])
})
