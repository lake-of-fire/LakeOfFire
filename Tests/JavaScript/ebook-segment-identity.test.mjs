import assert from 'node:assert/strict'
import test from 'node:test'

import {
    ebookSegmentIdentity,
    ebookSegmentIdentifierAliases,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-segment-identity.js'

const segmentNode = id => ({
    id,
    getAttribute: name => name === 'id' ? id : null,
})

test('uses only the explicit sidecar stable ID as the segment identifier', () => {
    const identity = ebookSegmentIdentity(segmentNode('runtime-id'), {
        i: 'metadata-element-id',
        sid: 'stable-id',
        h: 'segment-hash',
    })

    assert.deepEqual(identity, {
        elementID: 'runtime-id',
        metadataElementID: 'metadata-element-id',
        stableID: 'stable-id',
        segmentIdentifier: 'stable-id',
        hasSidecarStableID: true,
    })
    assert.deepEqual(
        ebookSegmentIdentifierAliases(segmentNode('runtime-id'), { sid: 'stable-id' }),
        ['stable-id'],
    )
})

test('does not promote a segment hash or element ID when sidecar identity is missing', () => {
    const identity = ebookSegmentIdentity(segmentNode('runtime-id'), {
        i: 'metadata-element-id',
        h: 'segment-hash',
    })

    assert.equal(identity.segmentIdentifier, null)
    assert.equal(identity.stableID, null)
    assert.equal(identity.hasSidecarStableID, false)
    assert.deepEqual(
        ebookSegmentIdentifierAliases(segmentNode('runtime-id'), {
            i: 'metadata-element-id',
            h: 'segment-hash',
        }),
        [],
    )
})

test('preserves runtime and metadata IDs only as explicit mapping fields', () => {
    const identity = ebookSegmentIdentity(
        { getAttribute: name => name === 'id' ? 'attribute-id' : null },
        { i: 'metadata-element-id', sid: 'stable-id' },
    )

    assert.equal(identity.elementID, 'attribute-id')
    assert.equal(identity.metadataElementID, 'metadata-element-id')
    assert.equal(identity.segmentIdentifier, 'stable-id')
})
