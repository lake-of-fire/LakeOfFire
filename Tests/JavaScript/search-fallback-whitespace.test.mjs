import assert from 'node:assert/strict'
import test from 'node:test'
import { search } from '../../Sources/LakeOfFireReader/Resources/foliate-js/search.js'

// Preserve the previous excerpt implementation as an independent oracle.
const expectedExcerpt = (parts, { startIndex, startOffset, endIndex, endOffset }) => {
    const start = parts[startIndex], end = parts[endIndex]
    const match = startIndex === endIndex ? start.slice(startOffset, endOffset)
        : start.slice(startOffset) + parts.slice(startIndex + 1, endIndex).join('') + end.slice(0, endOffset)
    const before = start.slice(0, startOffset).replace(/\s+/g, ' ').trimStart()
    const after = end.slice(endOffset).replace(/\s+/g, ' ').trimEnd()
    return { pre: (before.length < 50 ? '' : '…') + before.slice(-50), match,
        post: after.slice(0, 50) + (after.length < 50 ? '' : '…') }
}
const withoutSegmenter = callback => {
    const descriptor = Object.getOwnPropertyDescriptor(Intl, 'Segmenter')
    try {
        Object.defineProperty(Intl, 'Segmenter', { ...descriptor, value: undefined })
        callback()
    } finally { Object.defineProperty(Intl, 'Segmenter', descriptor) }
}
for (const whitespace of [' ', '\t', '\r\n', '\u00a0', '\ufeff']) {
    test(`literal fallback excerpts preserve runs of ${JSON.stringify(whitespace)}`, () => withoutSegmenter(() => {
        const text = 'prefix' + whitespace.repeat(200) + 'middle' + whitespace.repeat(100) + 'suffix'
        for (const parts of [[text], ['', text.slice(0, 47), '', text.slice(47), '']]) {
            const hits = [...search(parts, whitespace, { sensitivity: 'variant' })]
            assert.equal(hits.length, 300)
            for (const { range, excerpt } of hits)
                assert.deepEqual(excerpt, expectedExcerpt(parts, range))
        }
    }))
}
test('fallback whitespace-only nodes keep every literal hit and empty contexts', () => withoutSegmenter(() => {
    const hits = [...search(['', ' '.repeat(5000), ''], ' ', { sensitivity: 'case' })]
    assert.equal(hits.length, 5000)
    for (let i = 0; i < hits.length; i++) {
        assert.deepEqual(hits[i].range, { startIndex: 1, startOffset: i, endIndex: 1, endOffset: i + 1 })
        assert.deepEqual(hits[i].excerpt, { pre: '', match: ' ', post: '' })
    }
}))
test('fallback whitespace indexes are isolated between searches', () => withoutSegmenter(() => {
    for (const text of ['a b', 'a       b', 'c d', '\tq\t']) {
        const parts = [text]
        for (const { range, excerpt } of search(parts, text.trim().slice(0, 1)))
            assert.deepEqual(excerpt, expectedExcerpt(parts, range))
    }
}))
for (const length of [63, 64, 65, 128]) {
    test(`fallback run cache preserves threshold ${length}`, () => withoutSegmenter(() => {
        const parts = ['a' + ' '.repeat(length) + 'b\t' + ' '.repeat(length) + 'c']
        for (const { range, excerpt } of search(parts, ' ', { sensitivity: 'variant' }))
            assert.deepEqual(excerpt, expectedExcerpt(parts, range))
    }))
}
test('fallback discards cached boundaries when a yielded node changes', () => withoutSegmenter(() => {
    const parts = ['a' + ' '.repeat(100) + 'a']
    const iterator = search(parts, 'a', { sensitivity: 'variant' })
    const first = iterator.next().value
    assert.deepEqual(first.excerpt, expectedExcerpt(parts, first.range))
    parts[0] = 'a' + ' x'.repeat(50) + 'a'
    const second = iterator.next().value
    assert.deepEqual(second.excerpt, expectedExcerpt(parts, second.range))
    assert.equal(iterator.next().done, true)
}))
