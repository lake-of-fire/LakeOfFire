import assert from 'node:assert/strict'
import test from 'node:test'

import {
    compactEbookSegmentMetadataPayloadIsExactV9,
    compactEbookSegmentRuntimeIDsAreUnique,
    ebookSentenceIdentifier,
    ebookSegmentIdentity,
    ebookSegmentIdentifierAliases,
    expandCompactEbookSegmentIDToken,
    indexUniqueEbookSegmentAlias,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-segment-identity.js'

test('expands only explicit compact v9 segment ID encodings', () => {
    assert.equal(expandCompactEbookSegmentIDToken('Ab09'), 'mnb-sAb09')
    assert.equal(expandCompactEbookSegmentIDToken('!source-segment'), 'source-segment')
    assert.equal(expandCompactEbookSegmentIDToken('~123'), '_m123')
    assert.equal(expandCompactEbookSegmentIDToken('legacy-token'), null)
    assert.equal(expandCompactEbookSegmentIDToken(''), null)
    assert.equal(expandCompactEbookSegmentIDToken('!'), null)
    assert.equal(expandCompactEbookSegmentIDToken('~'), null)
})

test('rejects compact token aliases that expand to the same runtime ID', () => {
    const tuple = token => [token, 0, null, null, null, null, null, null, null, 0, 0]

    assert.equal(compactEbookSegmentRuntimeIDsAreUnique([tuple('Ab09'), tuple('Cd10')]), true)
    assert.equal(compactEbookSegmentRuntimeIDsAreUnique([tuple('Ab09'), tuple('Ab09')]), false)
    assert.equal(compactEbookSegmentRuntimeIDsAreUnique([tuple('Ab09'), tuple('!mnb-sAb09')]), false)
})

test('validates every compact v9 tuple reference without numeric coercion', () => {
    const payload = {
        v: 9,
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
        },
        s: [['Ab09', 0, 0, null, 0, null, 0, null, 0, 0, 0]],
    }

    assert.equal(compactEbookSegmentMetadataPayloadIsExactV9(payload), true)
    assert.equal(compactEbookSegmentMetadataPayloadIsExactV9({
        ...payload,
        s: [['Ab09', 0, 0.5, null, 0, null, 0, null, 0, 0, 0]],
    }), false)
    assert.equal(compactEbookSegmentMetadataPayloadIsExactV9({
        ...payload,
        s: [['Ab09', 0, true, null, 0, null, 0, null, 0, 0, 0]],
    }), false)
    assert.equal(compactEbookSegmentMetadataPayloadIsExactV9({
        ...payload,
        s: [['Ab09', 0, 0, null, 3, null, 0, null, 0, 0, 0]],
    }), false)
    assert.equal(compactEbookSegmentMetadataPayloadIsExactV9({
        ...payload,
        t: { ...payload.t, j: [[0]] },
    }), false)
    assert.equal(compactEbookSegmentMetadataPayloadIsExactV9({
        ...payload,
        s: [['Ab09', 0, 0, null, 0, null, 0, 0, 0, 0, 0]],
    }), false)
    assert.equal(compactEbookSegmentMetadataPayloadIsExactV9({
        ...payload,
        s: [['Ab09', 0, 0, null, 0, null, 0, 6, 0, 0, 0]],
    }), false)
    assert.equal(compactEbookSegmentMetadataPayloadIsExactV9({
        ...payload,
        s: [['Ab09', 0, 0, null, 0, null, 0, 5, 0, 0, 0]],
    }), true)
})

test('uses only explicit sentence identity and never promotes a hash', () => {
    const attributes = { sid: 'sentence-id', h: 'sentence-hash' }
    const sentenceNode = {
        getAttribute: name => attributes[name] ?? null,
    }

    assert.equal(ebookSentenceIdentifier(sentenceNode), 'sentence-id')
    delete attributes.sid
    assert.equal(ebookSentenceIdentifier(sentenceNode), null)
})

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

test('rejects an alias shared by distinct runtime segments', () => {
    const aliases = new Map()
    const ambiguous = new Set()
    const first = { node: segmentNode('runtime-a') }
    const second = { node: segmentNode('runtime-b') }

    assert.equal(indexUniqueEbookSegmentAlias(aliases, ambiguous, 'stable-id', first), true)
    assert.equal(indexUniqueEbookSegmentAlias(aliases, ambiguous, 'stable-id', first), true)
    assert.equal(indexUniqueEbookSegmentAlias(aliases, ambiguous, 'stable-id', second), false)
    assert.equal(aliases.has('stable-id'), false)
    assert.equal(ambiguous.has('stable-id'), true)
    assert.equal(indexUniqueEbookSegmentAlias(aliases, ambiguous, 'stable-id', first), false)
})
