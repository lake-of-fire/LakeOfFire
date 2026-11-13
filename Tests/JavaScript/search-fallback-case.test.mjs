import assert from 'node:assert/strict'
import test from 'node:test'
import { search, searchMatcher } from '../../Sources/LakeOfFireReader/Resources/foliate-js/search.js'

const withoutSegmenter = callback => {
    const descriptor = Object.getOwnPropertyDescriptor(Intl, 'Segmenter')
    try {
        Object.defineProperty(Intl, 'Segmenter', { ...descriptor, value: undefined })
        callback()
    } finally {
        Object.defineProperty(Intl, 'Segmenter', descriptor)
    }
}
for (const sensitivity of ['base', 'accent', 'case', 'variant']) {
    test(`fallback preserves requested ${sensitivity} case behavior`, () => withoutSegmenter(() => {
        const results = [...search(['Ca', 't ca', 't'], 'cat', { sensitivity })]
        const sensitive = sensitivity === 'case' || sensitivity === 'variant'
        assert.deepEqual(results.map(x => x.excerpt.match), sensitive ? ['cat'] : ['Cat', 'cat'])
        assert.deepEqual(results.at(-1).range,
            { startIndex: 1, startOffset: 2, endIndex: 2, endOffset: 1 })
    }))
}
for (const matchCase of [false, true]) for (const matchDiacritics of [false, true]) {
    test(`matcher fallback maps case=${matchCase}, diacritics=${matchDiacritics}`, () => withoutSegmenter(() => {
        const doc = { body: { lang: '' }, documentElement: { lang: '' } }
        const walker = (_, callback) => callback(['Cat cat'], (...range) => range)
        const result = [...searchMatcher(walker, {
            defaultLocale: 'en', matchCase, matchDiacritics, matchWholeWords: false,
        })(doc, 'cat')]
        assert.deepEqual(result.map(x => x.excerpt.match), matchCase ? ['cat'] : ['Cat', 'cat'])
    }))
}
test('fallback retains literal whitespace, overlap and empty-query semantics', () => withoutSegmenter(() => {
    assert.equal([...search(['a  b'], 'a b')].length, 0)
    assert.equal([...search(['   '], ' ')].length, 3)
    assert.equal([...search(['banana'], 'ana')].length, 2)
    assert.equal([...search(['Cat'], '')].length, 0)
}))

const fallbackMatches = (parts, query, options) => {
    let matches
    withoutSegmenter(() => { matches = Array.from(search(parts, query, options)) })
    return matches
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
