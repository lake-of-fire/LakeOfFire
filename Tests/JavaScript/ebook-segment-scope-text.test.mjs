import assert from 'node:assert/strict'
import test from 'node:test'
import { createEbookSegmentMetadataBootstrap } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-segment-metadata.js'

const payloadForContributions = contributions => ({
    v: 14,
    t: {
        h: ['hash-a', 'hash-b'], j: [[1001]], n: [],
        s: ['読む', '本'], ns: [], p: [],
        x: ['読む', '本', ...contributions], sid: ['sentence'], pid: ['paragraph'],
    },
    s: [
        ['!runtime-a', 0, 0, null, 0, null, null, null, 0, 0, 0, null, 2, null],
        ['!runtime-b', 1, 0, null, 1, null, null, null, 1, 0, 0, null, 3, null],
    ],
})

const bootstrap = payload => {
    const document = {
        manabiExternalSegmentSidecar: { payload, signature: 'scope-fixture' },
        getElementById: () => null,
        querySelectorAll() { assert.fail('native scope text must not be rebuilt from DOM text') },
    }
    return createEbookSegmentMetadataBootstrap({ nativeSchemaVersion: 14 }).bootstrap(document)
}

test('lazy sentence archive uses native contributions including unannotated text and exact Unicode', () => {
    const payload = payloadForContributions(['前😀 読む。 e\u0301 & <', '本！ "末尾"'])
    const result = bootstrap(payload)
    assert.equal(result.byID.materializedSegmentCount, 0)
    assert.equal(result.sentenceArchive.size, 0)
    const entry = result.sentenceArchive.get('sentence')
    assert.equal(entry.sentenceHTML, '前😀 読む。 e\u0301 &amp; &lt;本！ &quot;末尾&quot;')
    assert.deepEqual(entry.sentenceJMDictIDs, [1001])
    assert.equal(result.sentenceArchive.get('sentence'), entry)
    assert.equal(result.byID.materializedSegmentCount, 2)
    assert.equal(result.byID.get('runtime-a').x, '読む')
})

test('scope contribution absence preserves individual surface and legacy eleven-field fallback', () => {
    const payload = payloadForContributions(['前 読む。', '本！'])
    payload.s[1][12] = null
    assert.equal(bootstrap(payload).sentenceArchive.get('sentence').sentenceHTML, '前 読む。本')
    payload.s = payload.s.map(tuple => tuple.slice(0, 11))
    assert.equal(bootstrap(payload).sentenceArchive.get('sentence').sentenceHTML, '読む本')
})

test('scope contribution truncation preserves a surrogate pair across the segment boundary', () => {
    const payload = payloadForContributions(['あ'.repeat(6999), '😀discarded'])
    const entry = bootstrap(payload).sentenceArchive.get('sentence')
    assert.equal(entry.sentenceHTML, 'あ'.repeat(6999) + '😀')
    assert.equal(Array.from(entry.sentenceHTML).length, 7000)
})
