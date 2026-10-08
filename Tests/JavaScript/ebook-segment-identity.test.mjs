import assert from 'node:assert/strict'
import test from 'node:test'

import {
    compactEbookSegmentMetadataPayloadIsCurrent,
    compactEbookSegmentSidecarVersion,
    expandCompactEbookSegmentResolution,
    ebookSegmentIdentity,
    ebookSegmentIdentifierAliases,
    stableEbookSegmentIdentityVersion,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-segment-identity.js'

test('accepts only exact current-schema segment tuples', () => {
    const payload = {
        v: 12,
        t: {
            h: ['hash'],
            j: [[1001]],
            n: [],
            s: ['読む'],
            ns: [],
            p: ['動詞'],
            x: ['読む'],
            sid: ['sentence'],
            pid: ['paragraph'],
            res: [{ se: { namespace: 'jmdict', entryID: 1001 }, s: '読む' }],
        },
        s: [['Ab09', 0, 0, null, 0, null, 0, null, 0, 0, 0, 0]],
    }

    assert.equal(compactEbookSegmentSidecarVersion, 12)
    assert.equal(stableEbookSegmentIdentityVersion, 1)
    assert.equal(compactEbookSegmentMetadataPayloadIsCurrent(payload), true)
    assert.equal(compactEbookSegmentMetadataPayloadIsCurrent({ ...payload, v: 9 }), false)
    assert.equal(compactEbookSegmentMetadataPayloadIsCurrent({
        ...payload,
        s: [[...payload.s[0], false]],
    }), false)
    assert.equal(compactEbookSegmentMetadataPayloadIsCurrent({
        ...payload,
        s: [['Ab09', 0, true, null, 0, null, 0, null, 0, 0, 0, 0]],
    }), false)
    assert.equal(compactEbookSegmentMetadataPayloadIsCurrent({
        ...payload,
        s: [payload.s[0], ['!mnb-sAb09', 0, 0, null, 0, null, 0, null, 0, 0, 0, 0]],
    }), false)

    assert.deepEqual(
        expandCompactEbookSegmentResolution(payload.t.res[0], [1001], []),
        {
            selectedLexicon: 'jmdict',
            selectedEntryID: 1001,
            canonicalSearchString: '読む',
        }
    )
    assert.deepEqual(
        expandCompactEbookSegmentResolution(
            { se: { namespace: 'jmnedict', entryID: 2001 }, s: '愛' },
            [1001],
            [2001]
        ),
        {
            selectedLexicon: 'jmnedict',
            selectedEntryID: 2001,
            canonicalSearchString: '愛',
        }
    )
    assert.equal(compactEbookSegmentMetadataPayloadIsCurrent({
        ...payload,
        t: {
            ...payload.t,
            res: [{ se: { namespace: 'jmnedict', entryID: 2001 }, s: '愛' }],
        },
    }), false)
})

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
