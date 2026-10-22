import assert from 'node:assert/strict'
import test from 'node:test'
import { search } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/search.js'

const matches = (parts, query, options = {}) => Array.from(search(parts, query, options))

test('search keeps the full excerpt when a match spans several text nodes', () => {
    assert.deepEqual(matches(['前文猫', 'と', '犬後文'], '猫と犬'), [{
        range: { startIndex: 0, startOffset: 2, endIndex: 2, endOffset: 1 },
        excerpt: { pre: '前文', match: '猫と犬', post: '後文' },
    }])
})

test('equal text in different nodes still contributes to a spanning excerpt', () => {
    assert.deepEqual(matches(['ab', 'ab', '!'], 'bab'), [{
        range: { startIndex: 0, startOffset: 1, endIndex: 1, endOffset: 2 },
        excerpt: { pre: 'a', match: 'bab', post: '' },
    }])
})

for (const sensitivity of ['variant', 'accent']) {
    test(`${sensitivity} search accepts a match at the very end of the document`, () => {
        assert.deepEqual(matches(['前文', '猫'], '猫', { sensitivity }), [{
            range: { startIndex: 1, startOffset: 0, endIndex: 1, endOffset: 1 },
            excerpt: { pre: '', match: '猫', post: '' },
        }])
    })
}

test('exact search ends its range in the node containing the last matched character', () => {
    assert.deepEqual(matches(['猫', '', '犬'], '猫', { sensitivity: 'variant' }), [{
        range: { startIndex: 0, startOffset: 0, endIndex: 0, endOffset: 1 },
        excerpt: { pre: '', match: '猫', post: '' },
    }])
})

test('overlapping exact matches retain independent offsets across inline text nodes', () => {
    const result = matches(['a', 'a', 'a', 'a', 'a', '!'], 'aaa', { sensitivity: 'variant' })
    assert.deepEqual(result.map(({ range }) => range), [
        { startIndex: 0, startOffset: 0, endIndex: 2, endOffset: 1 },
        { startIndex: 1, startOffset: 0, endIndex: 3, endOffset: 1 },
        { startIndex: 2, startOffset: 0, endIndex: 4, endOffset: 1 },
    ])
    assert.deepEqual(result.map(({ excerpt }) => excerpt.match), ['aaa', 'aaa', 'aaa'])
})

test('exact search skips empty text nodes without moving beyond the document', () => {
    assert.deepEqual(matches(['', '猫', '', 'と', '', '犬', ''], '猫と犬', {
        sensitivity: 'variant',
    }), [{
        range: { startIndex: 1, startOffset: 0, endIndex: 5, endOffset: 1 },
        excerpt: { pre: '', match: '猫と犬', post: '' },
    }])
})

for (const options of [{}, { sensitivity: 'variant' }, { granularity: 'word' }]) {
    test(`empty queries have no matches (${JSON.stringify(options)})`, () => {
        assert.deepEqual(matches(['猫', '犬'], '', options), [])
        assert.deepEqual(matches([], '', options), [])
    })
}

test('empty text has no matches', () => {
    for (const parts of [[], [''], ['', '']]) {
        assert.deepEqual(matches(parts, '猫'), [])
        assert.deepEqual(matches(parts, '猫', { sensitivity: 'variant' }), [])
    }
})

// Locale folding may expand a code point. Case-insensitive searches must use
// the collator's original text boundaries rather than folded-string offsets.
test('accent search retains original offsets after an expanding Unicode fold', () => {
    assert.deepEqual(matches(['İ', '猫'], '猫', { sensitivity: 'accent', locales: 'en' }), [{
        range: { startIndex: 1, startOffset: 0, endIndex: 1, endOffset: 1 },
        excerpt: { pre: '', match: '猫', post: '' },
    }])
})

test('accent search preserves a spanning match containing an expanding Unicode fold', () => {
    assert.deepEqual(matches(['İ', '猫'], 'İ猫', { sensitivity: 'accent', locales: 'en' }), [{
        range: { startIndex: 0, startOffset: 0, endIndex: 1, endOffset: 1 },
        excerpt: { pre: '', match: 'İ猫', post: '' },
    }])
})

test('accent search retains Lithuanian contextual-casing offsets', () => {
    assert.deepEqual(matches(['I\u0301', '猫'], '猫', { sensitivity: 'accent', locales: 'lt' }), [{
        range: { startIndex: 1, startOffset: 0, endIndex: 1, endOffset: 1 },
        excerpt: { pre: '', match: '猫', post: '' },
    }])
})

test('accent search still distinguishes dotted and undotted letters', () => {
    assert.deepEqual(matches(['İ'], 'i', { sensitivity: 'accent', locales: 'en' }), [])
})

test('accent search preserves a combining sequence split across inline nodes', () => {
    assert.deepEqual(matches(['e', '\u0301', '猫'], 'é', { sensitivity: 'accent', locales: 'fr' }), [{
        range: { startIndex: 0, startOffset: 0, endIndex: 1, endOffset: 1 },
        excerpt: { pre: '', match: 'e\u0301', post: '' },
    }])
})
