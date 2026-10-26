import assert from 'node:assert/strict'
import test from 'node:test'

import {
    createEbookSegmentMetadataBootstrap,
    emptySegmentMetadataBootstrap,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-segment-metadata.js'

const makePayload = () => ({
    v: 14,
    t: {
        h: ['hash-a', 'hash-b', 'hash-c'],
        j: [[1001, 1002], [3001]],
        n: [[2001, 2002]],
        s: ['読む', '愛', '次'],
        ns: ['よむ', 'あい'],
        p: ['動詞', '名詞'],
        x: ['読む', '愛', '次', '  読む', '  読む愛。\n', '次。', '愛。\n'],
        sid: ['sentence-a', 'sentence-b'],
        pid: ['paragraph-a', 'paragraph-b'],
        res: [
            { se: { namespace: 'jmdict', entryID: 1002 }, s: '読む' },
            { se: { namespace: 'jmnedict', entryID: 2002 }, s: '愛' },
            { se: { namespace: 'jmdict', entryID: 3001 }, s: '次' },
        ],
    },
    s: [
        ['!runtime-a', 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 3, 4],
        ['!runtime-b', 1, 0, 0, 1, 1, 1, 3, 1, 0, 0, 1, 6, null],
        ['!runtime-c', 2, 1, null, 2, null, 1, null, 2, 1, 1, 2, 5, 5],
    ],
})

const makeCanonical = payload => ({ textContent: JSON.stringify(payload) })

const makeDocument = (canonical = null) => ({
    canonical,
    getElementById(id) {
        return id === 'mnb-segment-metadata' ? this.canonical : null
    },
    querySelectorAll() {
        assert.fail('the EPUB metadata bootstrap must not reconstruct metadata from DOM nodes')
    },
})

const makeBootstrap = nativeSchemaVersion => createEbookSegmentMetadataBootstrap({
    nativeSchemaVersion: nativeSchemaVersion ?? 14,
})

const assertEmpty = result => {
    assert.equal(result.byID.size, 0)
    assert.equal(result.byID.get('runtime-a'), undefined)
    assert.equal(result.byID.get('sentence-a-hash-a'), undefined)
    assert.equal(result.hasEntryIDs, false)
    assert.equal(result.segmentIDsBySentenceID?.get('sentence-a'), undefined)
    assert.equal(result.segmentIDsByParagraphID?.get('paragraph-a'), undefined)
    assert.equal(result.sentenceArchive.get('sentence-a'), undefined)
    assert.deepEqual(result.segments, [])
}

test('empty and missing documents expose the empty metadata contract', () => {
    assertEmpty(emptySegmentMetadataBootstrap())
    assertEmpty(makeBootstrap().bootstrap(null))
    assertEmpty(makeBootstrap().bootstrap(makeDocument()))
})

test('an absent sidecar hydrates from the actual Core external payload contract after a cached miss', () => {
    const { bootstrap } = makeBootstrap()
    const doc = makeDocument()
    assertEmpty(bootstrap(doc))
    doc.manabiExternalSegmentSidecar = { payload: makePayload(), signature: 'external-a' }
    const hydrated = bootstrap(doc)
    assert.equal(hydrated.byID.get('runtime-a').selectedEntryID, 1002)
    assert.equal(hydrated.hasEntryIDs, true)
    assert.equal(bootstrap(doc).byID, hydrated.byID)
})

test('an incompatible native schema fails closed before any document is warm', () => {
    const { bootstrap, schemaDiagnostics } = makeBootstrap(13)
    assert.equal(schemaDiagnostics.parserVersion, 14)
    assert.equal(schemaDiagnostics.nativeVersion, 13)
    assert.equal(schemaDiagnostics.nativeSchemaIsCompatible, false)
    assert.equal(schemaDiagnostics.acceptsPayload(makePayload()), false)
    assertEmpty(bootstrap(makeDocument(makeCanonical(makePayload()))))
})

test('a compatible warm document cache cannot bypass a later incompatible bootstrap', () => {
    const doc = makeDocument(makeCanonical(makePayload()))
    const compatible = makeBootstrap()
    const warm = compatible.bootstrap(doc)
    assert.equal(warm.byID.get('runtime-a').selectedEntryID, 1002)
    assertEmpty(makeBootstrap(13).bootstrap(doc))
    assert.equal(compatible.bootstrap(doc).byID.get('runtime-a').selectedEntryID, 1002)
})

test('an incompatible first bootstrap does not poison a later compatible document cache', () => {
    const doc = makeDocument(makeCanonical(makePayload()))
    assertEmpty(makeBootstrap(13).bootstrap(doc))
    assert.equal(makeBootstrap().bootstrap(doc).byID.get('runtime-a').selectedEntryID, 1002)
})

test('documents with identical runtime IDs retain independent metadata', () => {
    const { bootstrap } = makeBootstrap()
    const firstPayload = makePayload()
    const secondPayload = makePayload()
    secondPayload.t.h[0] = 'different-hash'
    const first = bootstrap(makeDocument(makeCanonical(firstPayload)))
    const second = bootstrap(makeDocument(makeCanonical(secondPayload)))
    assert.notEqual(first.byID, second.byID)
    assert.equal(first.byID.get('runtime-a').sid, 'sentence-a-hash-a')
    assert.equal(second.byID.get('runtime-a').sid, 'sentence-a-different-hash')
})

test('canonical node replacement retires both metadata and sentence archive caches', () => {
    const { bootstrap } = makeBootstrap()
    const doc = makeDocument(makeCanonical(makePayload()))
    const first = bootstrap(doc)
    const firstArchive = first.sentenceArchive.get('sentence-a')
    const replacement = makePayload()
    replacement.t.x[0] = '新しい'
    replacement.t.x[3] = '  新しい'
    replacement.t.h[0] = 'replacement-hash'
    doc.canonical = makeCanonical(replacement)
    const second = bootstrap(doc)
    assert.notEqual(second.byID, first.byID)
    assert.notEqual(second.sentenceArchive, first.sentenceArchive)
    assert.equal(second.byID.get('runtime-a').sid, 'sentence-a-replacement-hash')
    assert.equal(second.sentenceArchive.get('sentence-a').sentenceHTML, '  新しい愛。\n')
    assert.equal(firstArchive.sentenceHTML, '  読む愛。\n')
})

test('canonical ownership suppresses external payload until canonical removal', () => {
    const { bootstrap } = makeBootstrap()
    const externalPayload = makePayload()
    externalPayload.t.h[0] = 'external-hash'
    const doc = makeDocument(makeCanonical(makePayload()))
    doc.manabiExternalSegmentSidecar = { payload: externalPayload, signature: 'external-a' }
    assert.equal(bootstrap(doc).byID.get('runtime-a').h, 'hash-a')
    doc.canonical = null
    assert.equal(bootstrap(doc).byID.get('runtime-a').h, 'external-hash')
    delete doc.manabiExternalSegmentSidecar
    assertEmpty(bootstrap(doc))
})

test('external entry replacement activates the new payload without a synthetic script', () => {
    const { bootstrap } = makeBootstrap()
    const doc = makeDocument()
    doc.manabiExternalSegmentSidecar = { payload: makePayload(), signature: 'external-a' }
    const first = bootstrap(doc)
    const replacement = makePayload()
    replacement.t.h[0] = 'external-replacement'
    doc.manabiExternalSegmentSidecar = { payload: replacement, signature: 'external-b' }
    const second = bootstrap(doc)
    assert.notEqual(second.byID, first.byID)
    assert.equal(second.byID.get('runtime-a').h, 'external-replacement')
})

test('malformed canonical JSON stays empty and does not fall through to external or DOM metadata', () => {
    const doc = makeDocument({ textContent: '{not-json' })
    doc.manabiExternalSegmentSidecar = { payload: makePayload(), signature: 'external-a' }
    assertEmpty(makeBootstrap().bootstrap(doc))
})

test('wrong schema, duplicate runtime IDs, and invalid committed selections fail closed', () => {
    const wrongSchema = makePayload()
    wrongSchema.v = 13
    const duplicateID = makePayload()
    duplicateID.s[1][0] = '!runtime-a'
    const invalidSelection = makePayload()
    invalidSelection.t.res[0].se.entryID = 9999
    for (const payload of [wrongSchema, duplicateID, invalidSelection]) {
        assertEmpty(makeBootstrap().bootstrap(makeDocument(makeCanonical(payload))))
    }
})

test('full tuples preserve typed selection, canonical search, and exact scope text', () => {
    const result = makeBootstrap().bootstrap(makeDocument(makeCanonical(makePayload())))
    const first = result.byID.get('runtime-a')
    assert.deepEqual(first, {
        i: 'runtime-a', h: 'hash-a', sid: 'sentence-a-hash-a',
        sentenceID: 'sentence-a', paragraphID: 'paragraph-a', pid: 'paragraph-a',
        j: [1001, 1002], n: [2001, 2002], s: '読む', ns: 'よむ', p: '動詞',
        l: 2, x: '読む', scopeText: '  読む', paragraphScopeText: '  読む愛。\n',
        selectedLexicon: 'jmdict', selectedEntryID: 1002, canonicalSearchString: '読む',
        requiresCommittedDictionarySelection: true,
    })
    const second = result.byID.get('runtime-b')
    assert.equal(second.selectedLexicon, 'jmnedict')
    assert.equal(second.selectedEntryID, 2002)
    assert.equal(second.canonicalSearchString, '愛')
    assert.equal(second.scopeText, '愛。\n')
    assert.equal(second.paragraphScopeText, null)
    assert.deepEqual(second.j, [1001, 1002])
    assert.deepEqual(second.n, [2001, 2002])
})

test('runtime and stable aliases share lazy objects and scope/archive indexes retain tuple order', () => {
    const result = makeBootstrap().bootstrap(makeDocument(makeCanonical(makePayload())))
    assert.equal(result.byID.materializedSegmentCount, 0)
    assert.equal(result.segmentIDsBySentenceID.isIndexed, false)
    assert.equal(result.segmentIDsByParagraphID.isIndexed, false)
    assert.equal(result.sentenceArchive.size, 0)
    const later = result.byID.get('runtime-c')
    assert.equal(result.byID.materializedSegmentCount, 1)
    assert.equal(result.byID.get('sentence-b-hash-c'), later)
    assert.equal(result.byID.get('runtime-c'), later)
    assert.equal(result.byID.materializedSegmentCount, 1)
    const first = result.byID.get('sentence-a-hash-a')
    assert.equal(result.byID.get('runtime-a'), first)
    assert.equal(result.byID.get('sentence-b-hash-c'), later)
    assert.equal(result.byID.get('runtime-c'), later)
    assert.equal(result.byID.materializedSegmentCount, 2)
    assert.deepEqual(result.segmentIDsBySentenceID.get('sentence-a'), ['runtime-a', 'runtime-b'])
    assert.deepEqual(result.segmentIDsByParagraphID.get('paragraph-a'), ['runtime-a', 'runtime-b'])
    const archive = result.sentenceArchive.get('sentence-a')
    assert.equal(result.sentenceArchive.get('sentence-a'), archive)
    assert.equal(result.byID.materializedSegmentCount, 3)
    assert.deepEqual(archive.segments.map(segment => segment.segmentIdentifier), [
        'sentence-a-hash-a', 'sentence-a-hash-b',
    ])
    assert.equal(result.byID.get('absent'), undefined)
    assert.equal(result.sentenceArchive.get('absent'), undefined)
    assert.equal(result.byID.materializedSegmentCount, 3)
})

test('full stable alias indexing preserves the last tuple winner for a shared stable ID', () => {
    const payload = makePayload()
    payload.s[1][1] = payload.s[0][1]
    const result = makeBootstrap().bootstrap(makeDocument(makeCanonical(payload)))
    const first = result.byID.get('runtime-a')
    const distinct = result.byID.get('runtime-c')
    assert.equal(result.byID.get('absent'), undefined)
    const winner = result.byID.get('sentence-a-hash-a')
    assert.equal(winner.i, 'runtime-b')
    assert.equal(winner.selectedLexicon, 'jmnedict')
    assert.equal(result.byID.get('runtime-b'), winner)
    assert.equal(result.byID.get('runtime-a'), first)
    assert.equal(result.byID.get('sentence-b-hash-c'), distinct)
    assert.equal(result.byID.materializedSegmentCount, 3)
})

for (const [name, accessOrder] of [
    ['cold runtime lookup before stable lookup', ['runtime-a', 'sentence-a-hash-a']],
    ['full alias indexing before runtime lookup', ['absent', 'runtime-a', 'sentence-a-hash-a']],
    ['stable winner before losing runtime lookup', ['sentence-a-hash-a', 'runtime-a', 'sentence-a-hash-a']],
    ['winning runtime before losing runtime lookup', ['runtime-b', 'runtime-a', 'sentence-a-hash-a']],
]) {
    test(`shared stable aliases retain the last tuple winner: ${name}`, () => {
        const payload = makePayload()
        payload.s[1][1] = payload.s[0][1]
        const { byID } = makeBootstrap().bootstrap(makeDocument(makeCanonical(payload)))
        const firstHits = new Map()
        for (const identifier of accessOrder) {
            const metadata = byID.get(identifier)
            if (identifier === 'absent') {
                assert.equal(metadata, undefined)
            } else if (!firstHits.has(identifier)) {
                firstHits.set(identifier, metadata)
            }
        }
        const winner = byID.get('sentence-a-hash-a')
        assert.equal(winner.i, 'runtime-b')
        assert.equal(winner.selectedLexicon, 'jmnedict')
        assert.equal(winner.selectedEntryID, 2002)
        assert.equal(byID.get('runtime-a'), firstHits.get('runtime-a'))
        assert.equal(byID.get('runtime-a').i, 'runtime-a')
        assert.equal(byID.get('runtime-b'), winner)
        if (firstHits.has('runtime-b')) {
            assert.equal(byID.get('runtime-b'), firstHits.get('runtime-b'))
        }
        assert.equal(firstHits.get('sentence-a-hash-a'), winner)
        assert.equal(byID.get('sentence-a-hash-a'), winner)
        assert.equal(byID.get('sentence-a-hash-a'), winner)
        assert.equal(byID.materializedSegmentCount, 2)
    })
}

test('sentence archives escape text, preserve both typed alternatives, and deduplicate primary JMDict IDs', () => {
    const payload = makePayload()
    payload.t.x[0] = `<読む&"'`
    payload.t.x[1] = '>愛'
    payload.t.x[3] = payload.t.x[0]
    payload.t.x[6] = payload.t.x[1]
    const result = makeBootstrap().bootstrap(makeDocument(makeCanonical(payload)))
    const archive = result.sentenceArchive.get('sentence-a')
    assert.equal(archive.sentenceHTML, '&lt;読む&amp;&quot;&#39;&gt;愛')
    assert.deepEqual(archive.sentenceJMDictIDs, [1001])
    assert.deepEqual(archive.vocabularyCandidateGroups, [
        { jmdictEntryIds: [1001, 1002], jmnedictEntryIds: [2001, 2002] },
        { jmdictEntryIds: [1001, 1002], jmnedictEntryIds: [2001, 2002] },
    ])
    for (const segment of archive.segments) {
        assert.equal(segment.exampleSentence, archive.sentenceHTML)
        assert.deepEqual(segment.exampleSentenceJMDictIDs, [1001])
        assert.deepEqual(segment.jmnedictEntryIds, [2001, 2002])
    }
})

test('sentence archive truncation counts Unicode codepoints and preserves a boundary surrogate pair', () => {
    const payload = makePayload()
    payload.t.x[0] = 'あ'.repeat(6999) + '😀' + 'discarded'
    payload.t.x[1] = 'also discarded'
    payload.t.x[3] = payload.t.x[0]
    payload.t.x[6] = payload.t.x[1]
    const archive = makeBootstrap().bootstrap(makeDocument(makeCanonical(payload)))
        .sentenceArchive.get('sentence-a')
    assert.equal(archive.sentenceHTML, 'あ'.repeat(6999) + '😀')
    assert.equal(Array.from(archive.sentenceHTML).length, 7000)
    assert.equal(archive.sentenceHTML.length, 7001)
})

test('repeated hits reuse an immutable canonical node without rereading its JSON text', () => {
    const text = JSON.stringify(makePayload())
    let reads = 0
    const canonical = {
        get textContent() {
            reads += 1
            return text
        },
    }
    const doc = makeDocument(canonical)
    const { bootstrap } = makeBootstrap()
    const first = bootstrap(doc)
    const metadata = first.byID.get('runtime-a')
    for (let index = 0; index < 4; index += 1) {
        const next = bootstrap(doc)
        assert.equal(next.byID, first.byID)
        assert.equal(next.byID.get('runtime-a'), metadata)
    }
    assert.equal(reads, 1)
})
