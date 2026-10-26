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
        v: 14,
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

    assert.equal(compactEbookSegmentSidecarVersion, 14)
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


test('schema 14 accepts scope text tuples and rejects malformed or old layouts', () => {
    const payload = {
        v: 14,
        t: { h: ['hash'], j: [], n: [], s: [], ns: [], p: [],
            x: ['桃', '  桃。\n隣の文。  '], sid: ['sentence'], pid: ['paragraph'] },
        s: [['!runtime', 0, null, null, null, null, null, null, 0, 0, 0, null, 1, 1]],
    }
    assert.equal(compactEbookSegmentMetadataPayloadIsCurrent(payload), true)
    for (const version of [12, 13, 15]) {
        assert.equal(compactEbookSegmentMetadataPayloadIsCurrent({ ...payload, v: version }), false)
    }
    for (const size of [11, 12, 13, 14]) {
        assert.equal(compactEbookSegmentMetadataPayloadIsCurrent({ ...payload,
            s: [payload.s[0].slice(0, size)] }), true)
    }
    for (const index of [12, 13]) {
        for (const invalid of [true, -1, 2, 0.5, '1']) {
            const tuple = payload.s[0].slice()
            tuple[index] = invalid
            assert.equal(compactEbookSegmentMetadataPayloadIsCurrent({ ...payload, s: [tuple] }), false)
        }
    }
    assert.equal(compactEbookSegmentMetadataPayloadIsCurrent({ ...payload,
        s: [[...payload.s[0], null]] }), false)
})

const committedSelectionPayload = resolution => ({
    v: 14,
    t: {
        h: ['hash'], j: [[1001, 1002]], n: [[2001, 2002]],
        s: ['読む'], ns: ['あい'], p: ['動詞'], x: ['読む'],
        sid: ['sentence'], pid: ['paragraph'], res: [resolution],
    },
    s: [['!runtime', 0, 0, 0, 0, 0, 0, null, 0, 0, 0, 0]],
})

const expandSelection = resolution => expandCompactEbookSegmentResolution(
    resolution, [1001, 1002], [2001, 2002]
)

for (const [name, legacyID] of [
    ['zero', 0], ['negative', -1], ['fractional', 1001.5],
    ['string', '1001'], ['boolean', true], ['object', {}],
    ['array', []], ['unsafe integer', Number.MAX_SAFE_INTEGER + 1],
]) {
    for (const [selectionName, selection] of [
        ['legacy only', undefined],
        ['typed JMDict', { namespace: 'jmdict', entryID: 1002 }],
        ['typed JMnedict', { namespace: 'jmnedict', entryID: 2002 }],
    ]) {
        test(`rejects ${name} legacy selection with ${selectionName}`, () => {
            const resolution = { e: legacyID, s: '読む' }
            if (selection !== undefined) resolution.se = selection
            assert.equal(expandSelection(resolution), null)
            assert.equal(compactEbookSegmentMetadataPayloadIsCurrent(
                committedSelectionPayload(resolution)
            ), false)
        })
    }
}

for (const [name, selection] of [
    ['string', 'jmdict'], ['boolean', false], ['array', []], ['empty object', {}],
    ['unknown namespace', { namespace: 'other', entryID: 1001 }],
    ['missing namespace', { entryID: 1001 }],
    ['missing entry ID', { namespace: 'jmdict' }],
    ['zero JMDict ID', { namespace: 'jmdict', entryID: 0 }],
    ['zero JMnedict ID', { namespace: 'jmnedict', entryID: 0 }],
    ['negative ID', { namespace: 'jmdict', entryID: -1 }],
    ['fractional ID', { namespace: 'jmdict', entryID: 1001.5 }],
    ['string ID', { namespace: 'jmdict', entryID: '1001' }],
    ['unsafe ID', { namespace: 'jmnedict', entryID: Number.MAX_SAFE_INTEGER + 1 }],
]) {
    for (const legacyID of [undefined, 1001]) {
        test(`rejects ${name} typed selection ${legacyID === undefined ? 'without' : 'with'} legacy fallback`, () => {
            const resolution = { se: selection, s: '読む' }
            if (legacyID !== undefined) resolution.e = legacyID
            assert.equal(expandSelection(resolution), null)
            assert.equal(compactEbookSegmentMetadataPayloadIsCurrent(
                committedSelectionPayload(resolution)
            ), false)
        })
    }
}

for (const [name, identity, namespace, entryID] of [
    ['legacy only', { e: 1001 }, 'jmdict', 1001],
    ['null typed identity', { se: null, e: 1001 }, 'jmdict', 1001],
    ['typed JMDict', { se: { namespace: 'jmdict', entryID: 1002 } }, 'jmdict', 1002],
    ['null legacy identity', { se: { namespace: 'jmnedict', entryID: 2002 }, e: null }, 'jmnedict', 2002],
    ['typed JMDict precedence', { se: { namespace: 'jmdict', entryID: 1002 }, e: 1001 }, 'jmdict', 1002],
    ['typed JMnedict precedence', { se: { namespace: 'jmnedict', entryID: 2002 }, e: 1001 }, 'jmnedict', 2002],
    ['valid unused legacy identity', { se: { namespace: 'jmnedict', entryID: 2002 }, e: 9999 }, 'jmnedict', 2002],
]) {
    test(`retains ${name} selection compatibility`, () => {
        const resolution = { ...identity, s: '読む' }
        assert.deepEqual(expandSelection(resolution), {
            selectedLexicon: namespace, selectedEntryID: entryID,
            canonicalSearchString: '読む',
        })
        assert.equal(compactEbookSegmentMetadataPayloadIsCurrent(
            committedSelectionPayload(resolution)
        ), true)
    })
}

test('absent or null optional identities retain an unselected resolution', () => {
    for (const resolution of [{}, { se: null }, { e: null }, { se: null, e: null }]) {
        assert.deepEqual(expandSelection(resolution), {
            selectedLexicon: null, selectedEntryID: null, canonicalSearchString: null,
        })
        assert.equal(compactEbookSegmentMetadataPayloadIsCurrent(
            committedSelectionPayload(resolution)
        ), true)
    }
})

test('typed selection still requires membership without borrowing a legacy candidate', () => {
    for (const selection of [
        { namespace: 'jmdict', entryID: 9999 },
        { namespace: 'jmnedict', entryID: 1001 },
    ]) {
        const resolution = { se: selection, e: 1001, s: '読む' }
        assert.equal(expandSelection(resolution), null)
        assert.equal(compactEbookSegmentMetadataPayloadIsCurrent(
            committedSelectionPayload(resolution)
        ), false)
    }
})
