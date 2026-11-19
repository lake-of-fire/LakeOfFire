import assert from 'node:assert/strict'
import test from 'node:test'
import { search, searchMatcher } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/search.js'

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
