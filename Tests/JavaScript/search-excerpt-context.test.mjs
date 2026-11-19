import assert from 'node:assert/strict'
import test from 'node:test'
import { search } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/search.js'

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
const verify = (parts, query) => {
    const matches = [...search(parts, query)]
    assert.ok(matches.length)
    for (const {range, excerpt} of matches) assert.deepEqual(excerpt, expectedExcerpt(parts, range))
}
for (const length of [0, 1, 48, 49, 50, 51, 100, 1000]) {
    test(`excerpt keeps threshold and whitespace at ${length} UTF-16 units`, () => {
        for (const context of ['a', ' ', '\t', '\r\n', '\u00a0', '\ufeff', '😀', 'a\t b', 'e\u0301']) {
            const side = context.repeat(length)
            verify([side + 'needle' + side], 'needle')
            verify([side + 'nee', '', 'dle' + side], 'needle')
        }
    })
}
test('seeded mixed contexts match the original excerpt oracle', () => {
    let seed = 314159
    const next = () => (seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0)
    const units = ['a','Z',' ','\t','\r','\n','\u00a0','\u2003','\ufeff','😀','e\u0301','\u200b']
    for (let i = 0; i < 200; i++) {
        const side = () => Array.from({length: next() % 160}, () => units[next() % units.length]).join('')
        const text = side() + 'needle' + side() + 'needle' + side()
        const split = next() % (text.length + 1)
        verify([text], 'needle')
        verify(['', text.slice(0, split), '', text.slice(split), ''], 'needle')
    }
})
