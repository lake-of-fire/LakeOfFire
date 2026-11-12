import assert from 'node:assert/strict'
import test from 'node:test'
import { search } from '../../Sources/LakeOfFireReader/Resources/foliate-js/search.js'

// Repartitioning cannot change original UTF-16 spans, including when the
// printable-ASCII normalization identity path is available.
for (const [text, query, options, expected] of [
    ['banana', 'ana', {}, [[1, 4], [3, 6]]],
    ['Cat cat', 'cat', { sensitivity: 'case' }, [[4, 7]]],
    ['Cat cat', 'cat', { sensitivity: 'accent' }, [[0, 3], [4, 7]]],
    ['I i', 'i', { locales: 'tr' }, [[2, 3]]],
    [' a b ', 'a b', {}, [[1, 4]]],
    ['a!b.?c', 'b.?', {}, [[2, 5]]],
    ['cats cat', 'cat', { granularity: 'word' }, [[5, 8]]],
    ['cat  dog', 'cat dog', {}, [[0, 8]]],
    ['cat\tdog', 'cat dog', {}, [[0, 7]]],
    ['cat\r\ndog', 'cat dog', {}, [[0, 8]]],
    ['e\u0301x', 'é', {}, [[0, 2]]],
    ['ca\u200bt', 'cat', {}, [[0, 4]]],
]) {
    test(`normalization spans survive every node split: ${JSON.stringify(text)} / ${query}`, () => {
        for (let split = 0; split <= text.length; split++) {
            const parts = ['', text.slice(0, split), '', text.slice(split), '']
            const offset = (index, local) => parts.slice(0, index).join('').length + local
            const results = [...search(parts, query, options)]
            assert.deepEqual(results.map(({ range: r }) => [
                offset(r.startIndex, r.startOffset), offset(r.endIndex, r.endOffset),
            ]), expected)
            assert.deepEqual(results.map(({ excerpt }) => excerpt.match),
                expected.map(([start, end]) => text.slice(start, end)))
        }
    })
}

// A leading format token forces the general normalization path but is omitted
// from comparison text. Remove its source offset to compare both real paths.
test('identity offsets agree with the general map across locales and options', () => {
    for (const text of ['Alpha beta ALPHA', 'aaa', ' a b ', 'I i', 'c-h ch', 'a!b.?c'])
        for (const query of ['a', 'A', ' ', 'a b', 'ab', 'i', 'ch', 'é', 'ss', 'b.'])
            for (const locales of ['en', 'tr', 'de', 'da', 'ja', 'th', 'cs'])
                for (const sensitivity of ['base', 'case', 'accent', 'variant'])
                    for (const granularity of ['grapheme', 'word']) {
                        const options = { locales, sensitivity, granularity }
                        const spans = (input, shift) => [...search([input], query, options)]
                            .map(({ range, excerpt }) => [range.startOffset - shift,
                                range.endOffset - shift, excerpt.match])
                        assert.deepEqual(spans(text, 0), spans('\u200b' + text, 1))
                    }
})
