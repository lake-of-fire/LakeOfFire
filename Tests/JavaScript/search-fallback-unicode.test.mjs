import assert from 'node:assert/strict'
import test from 'node:test'
import { search } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/search.js'

const fallbackMatches = (parts, query, options) => {
    const segmenter = Intl.Segmenter
    try {
        Intl.Segmenter = undefined
        return Array.from(search(parts, query, options))
    } finally {
        Intl.Segmenter = segmenter
    }
}

const originalOffsets = (parts, range) => {
    const offset = (index, local) => parts.slice(0, index).join('').length + local
    return [offset(range.startIndex, range.startOffset), offset(range.endIndex, range.endOffset)]
}

for (const [locale, text, query, offsets] of [
    ['en', 'İx', 'x', [[1, 2]]],
    ['en', 'İxİ', 'İ', [[0, 1], [2, 3]]],
    ['en', '😀İx', 'x', [[3, 4]]],
    ['en', 'İaaa', 'aa', [[1, 3], [2, 4]]],
    ['tr', 'I\u0307x', 'i', [[0, 2]]],
    ['tr', 'I\u0323\u0307x', 'x', [[3, 4]]],
    ['tr', 'I\u0301\u0307x', 'x', [[3, 4]]],
    ['lt', 'I\u0301x', 'x', [[2, 3]]],
    ['lt', 'J\u0300x', 'x', [[2, 3]]],
    ['el', 'ΟΣ', 'ος', [[0, 2]]],
    ['el', 'ΟΣx', 'οσx', [[0, 3]]],
    ['en', 'e\u0301x', 'e', [[0, 1]]],
    ['en', 'e\u0301x', '\u0301', [[1, 2]]],
]) {
    test(`fallback maps original spans across every node partition: ${locale} ${JSON.stringify(text)}/${JSON.stringify(query)}`, () => {
        // Include splits inside a surrogate pair and inside casing/mark runs.
        for (let split = 0; split <= text.length; split++) {
            const parts = [text.slice(0, split), '', text.slice(split)]
            const matches = fallbackMatches(parts, query, { locales: locale, sensitivity: 'accent' })
            assert.deepEqual(matches.map(({ range }) => originalOffsets(parts, range)), offsets)
            assert.deepEqual(matches.map(({ excerpt }) => excerpt.match),
                offsets.map(([start, end]) => text.slice(start, end)))
        }
    })
}

test('fallback retains exact case and original offsets for both case-sensitive controls', () => {
    for (const sensitivity of ['case', 'variant']) {
        const matches = fallbackMatches(['İ', 'i', 'x'], 'i', { locales: 'en', sensitivity })
        assert.deepEqual(matches.map(({ range }) => range), [
            { startIndex: 1, startOffset: 0, endIndex: 1, endOffset: 1 },
        ])
        assert.equal(matches[0].excerpt.match, 'i')
    }
})

test('fallback expansion substring maps one complete original character', () => {
    const matches = fallbackMatches(['İ'], 'i', { locales: 'en', sensitivity: 'accent' })
    assert.deepEqual(matches.map(({ range }) => range), [
        { startIndex: 0, startOffset: 0, endIndex: 0, endOffset: 1 },
    ])
    assert.equal(matches[0].excerpt.match, 'İ')
})
