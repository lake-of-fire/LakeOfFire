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


test('whole-word search treats inline text nodes as one word', () => {
    assert.deepEqual(matches(['read', 'ing'], 'reading', { granularity: 'word' }), [{
        range: { startIndex: 0, startOffset: 0, endIndex: 1, endOffset: 3 },
        excerpt: { pre: '', match: 'reading', post: '' },
    }])
    assert.deepEqual(matches(['read', 'ing'], 'read', { granularity: 'word' }), [])
})

test('whole-word search keeps apostrophes across inline nodes', () => {
    assert.deepEqual(matches(['I', "'", 'm'], "I'm", { granularity: 'word' }).map(x => x.range), [
        { startIndex: 0, startOffset: 0, endIndex: 2, endOffset: 1 },
    ])
})

test('whole-word search segments Japanese across inline nodes', () => {
    assert.deepEqual(matches(['日本', '語'], '日本語', { granularity: 'word', locales: 'ja' }).map(x => x.range), [
        { startIndex: 0, startOffset: 0, endIndex: 1, endOffset: 1 },
    ])
})

for (const sensitivity of ['base', 'case']) {
    test(`${sensitivity} search keeps a split grapheme attached to a following match`, () => {
        assert.deepEqual(matches(['e', '\u0301', '猫'], 'é猫', { sensitivity }), [{
            range: { startIndex: 0, startOffset: 0, endIndex: 2, endOffset: 1 },
            excerpt: { pre: '', match: 'e\u0301猫', post: '' },
        }])
    })
}


for (const granularity of ['grapheme', 'word']) {
    for (const [parts, query, expected] of [
        [['cat  ', 'dog'], 'cat  dog', [0, 0, 1, 3]],
        [['cat\t\n', 'dog'], 'cat dog', [0, 0, 1, 3]],
        [['ca\u00AD', 't'], 'ca\u00ADt', [0, 0, 1, 1]],
        [['ca\u00AD', 't'], 'cat', [0, 0, 1, 1]],
        [['cat', '   '], 'cat ', [0, 0, 1, 3]],
        [['  ', '\t\n'], ' ', [0, 0, 1, 2]],
    ]) {
        test(`${granularity} search normalizes both sides and preserves full spans: ${JSON.stringify(parts)} / ${query}`, () => {
            const [startIndex, startOffset, endIndex, endOffset] = expected
            assert.deepEqual(matches(parts, query, {granularity, sensitivity:'base'}).map(x => x.range),
                [{startIndex, startOffset, endIndex, endOffset}])
        })
    }
    test(`${granularity} search ignores an empty normalized query`, () => {
        assert.deepEqual(matches(['a\u00ADb'], '\u00AD', {granularity}), [])
    })
}

for (const [parts, query, locale, expected] of [
    [['Stra', 'ße'], 'strasse', 'de', [0, 0, 1, 2]],
    [['stras', 'se'], 'straße', 'de', [0, 0, 1, 2]],
    [['STRA', 'ẞE'], 'strasse', 'de', [0, 0, 1, 2]],
    [['o', 'ﬃ', 'ce'], 'office', 'en', [0, 0, 2, 2]],
    [['off', 'ice'], 'oﬃce', 'en', [0, 0, 1, 3]],
    [['xStra', 'ße!'], 'strasse', 'de', [0, 1, 1, 2]],
    [['Stra', 'sse!'], 'straße', 'de', [0, 0, 1, 3]],
]) {
    test(`base search discovers length-changing Unicode spelling and preserves offsets: ${parts.join('')} / ${query}`, () => {
        assert.equal(new Intl.Collator(locale, {sensitivity:'base'}).compare(parts.join('').slice(expected[1], expected[3] + parts.slice(0, expected[2]).join('').length), query), 0)
        const [startIndex, startOffset, endIndex, endOffset] = expected
        assert.deepEqual(matches(parts, query, {locales:locale, sensitivity:'base'}).map(x => x.range),
            [{startIndex, startOffset, endIndex, endOffset}])
    })
}

for (const [text, query] of [['ß','s'], ['ﬃ','f'], ['Straße','strase'], ['office','ofice']]) {
    test(`Unicode candidate discovery rejects partial expansions and near misses: ${text} / ${query}`, () => {
        assert.deepEqual(matches([text], query, {locales:'de', sensitivity:'base'}), [])
    })
}

test('accent-sensitive search preserves its distinction for sharp S', () => {
    assert.notEqual(new Intl.Collator('de', {sensitivity:'accent'}).compare('Straße', 'strasse'), 0)
    assert.deepEqual(matches(['Straße'], 'strasse', {locales:'de', sensitivity:'accent'}), [])
})

test('case-sensitive search verifies the original spelling after candidate folding', () => {
    assert.deepEqual(matches(['straße'], 'STRASSE', {locales:'de', sensitivity:'case'}), [])
})

test('whole-word boundaries reject a matching substring discovered by Unicode folding', () => {
    assert.deepEqual(matches(['xStraße'], 'strasse', {locales:'de', granularity:'word'}), [])
})


test('merged search candidates stay ordered and unique around expansions', () => {
    assert.deepEqual(matches(['ß', 'ssß'], 'ss', {locales:'de'}).map(x => x.range), [
        {startIndex:0, startOffset:0, endIndex:0, endOffset:1},
        {startIndex:1, startOffset:0, endIndex:1, endOffset:2},
        {startIndex:1, startOffset:2, endIndex:1, endOffset:3},
    ])
})
