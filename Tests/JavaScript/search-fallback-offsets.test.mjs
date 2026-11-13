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

for (const [text, locales, start, end] of [
    ['İcat', 'en', 1, 4],
    ['😀İcat', 'en', 3, 6],
    ['I\u0307cat', 'tr', 2, 5],
    ['I\u0301cat', 'lt', 2, 5],
    ['İI\u0307cat', 'tr', 3, 6],
    // Keep repeated changed spans independent and preserve every later match.
    ['İcatI\u0307cat', 'lt', 1, 4],
]) {
    test(`fallback maps original offsets through ${locales} casing: ${JSON.stringify(text)}`, () => withoutSegmenter(() => {
        for (let split = 0; split <= text.length; split++) {
            const parts = ['', text.slice(0, split), '', text.slice(split), '']
            const results = [...search(parts, 'cat', { locales })]
            const result = results[0]
            assert.ok(result)
            const offset = (index, local) => parts.slice(0, index).join('').length + local
            assert.equal(offset(result.range.startIndex, result.range.startOffset), start)
            assert.equal(offset(result.range.endIndex, result.range.endOffset), end)
            for (const { range, excerpt } of results) {
                assert.ok(range.startOffset >= 0 && range.startOffset <= parts[range.startIndex].length)
                assert.ok(range.endOffset >= 0 && range.endOffset <= parts[range.endIndex].length)
                assert.equal(excerpt.match, 'cat')
            }
        }
    }))
}

test('fallback maps a length-changing match to the complete original character', () => withoutSegmenter(() => {
    assert.deepEqual([...search(['İ'], 'i\u0307', { locales: 'en' })], [{
        range: { startIndex: 0, startOffset: 0, endIndex: 0, endOffset: 1 },
        excerpt: { pre: '', match: 'İ', post: '' },
    }])
    assert.deepEqual([...search(['I', '\u0307'], 'i', { locales: 'tr' })], [{
        range: { startIndex: 0, startOffset: 0, endIndex: 1, endOffset: 1 },
        excerpt: { pre: '', match: 'I\u0307', post: '' },
    }])
}))

test('matcher passes original cross-node offsets to the range factory', () => withoutSegmenter(() => {
    const doc = { body: { lang: 'en' }, documentElement: { lang: '' } }
    const walker = (_, callback) => callback(['😀İca', 't'], (...coordinates) => coordinates)
    const results = [...searchMatcher(walker, {
        matchCase: false, matchDiacritics: true, matchWholeWords: false,
    })(doc, 'cat')]
    assert.deepEqual(results, [{
        range: [0, 3, 1, 1],
        excerpt: { pre: '😀İ', match: 'cat', post: '' },
    }])
}))

test('fallback retains whole-string contextual Greek casing', () => withoutSegmenter(() => {
    assert.deepEqual([...search(['Ο', 'Σ cat'], 'ος', { locales: 'el' })].map(x => x.excerpt.match), ['ΟΣ'])
}))

test('contextual casing prefixes never shift an unchanged suffix across node partitions', () => withoutSegmenter(() => {
    const units = ['İ', 'I\u0307', 'I\u0301', 'J\u0301', '\u012e\u0301',
        'I\u0323\u0307', 'I\u0301\u0307', '😀', 'ΟΣ', '\u0307']
    for (const locales of ['en', 'tr', 'az', 'lt']) for (const first of units) for (const second of units) {
        const prefix = first + second + ' '
        const text = prefix + 'needle tail'
        for (let split = 0; split <= text.length; split++) {
            const parts = ['', text.slice(0, split), '', text.slice(split), '']
            const results = [...search(parts, 'needle', { locales })]
            assert.equal(results.length, 1, `${locales}: ${JSON.stringify(parts)}`)
            const { range, excerpt } = results[0]
            const offset = (index, local) => parts.slice(0, index).join('').length + local
            assert.equal(offset(range.startIndex, range.startOffset), prefix.length)
            assert.equal(offset(range.endIndex, range.endOffset), prefix.length + 'needle'.length)
            assert.equal(excerpt.match, 'needle')
        }
    }
}))
