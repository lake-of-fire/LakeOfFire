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
    for (const sensitivity of ['base', 'accent', 'case', 'variant']) {
        for (const [parts, query, expected] of [
            [['cat  ', 'dog'], 'cat  dog', [0, 0, 1, 3]],
            [['cat\t\n', 'dog'], 'cat dog', [0, 0, 1, 3]],
            [['ca\u00AD', 't'], 'ca\u00ADt', [0, 0, 1, 1]],
            [['ca\u00AD', 't'], 'cat', [0, 0, 1, 1]],
            [['cat', '   '], 'cat ', [0, 0, 1, 3]],
            [['  ', '\t\n'], ' ', [0, 0, 1, 2]],
        ]) {
            test(`${granularity}/${sensitivity} search normalizes both sides and preserves full spans: ${JSON.stringify(parts)} / ${query}`, () => {
                const [startIndex, startOffset, endIndex, endOffset] = expected
                assert.deepEqual(matches(parts, query, {granularity, sensitivity}).map(x => x.range),
                    [{startIndex, startOffset, endIndex, endOffset}])
            })
        }
        test(`${granularity}/${sensitivity} search ignores an empty normalized query`, () => {
            assert.deepEqual(matches(['a\u00ADb'], '\u00AD', {granularity, sensitivity}), [])
        })
    }
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


for (const [parts, query, locale] of [
    [['c','œ','ur'], 'coeur', 'fr'],
    [['co','eu','r'], 'cœur', 'fr'],
    [['c','æ','lum'], 'caelum', 'en'],
    [['cae','lum'], 'cælum', 'en'],
]) {
    test(`substring search includes complete-word collation expansions: ${parts.join('')} / ${query}`, () => {
        assert.equal(new Intl.Collator(locale, {sensitivity:'base'}).compare(parts.join(''), query), 0)
        const options = {locales:locale,sensitivity:'base'}
        const expected = [{startIndex:0,startOffset:0,endIndex:parts.length-1,endOffset:parts.at(-1).length}]
        assert.deepEqual(matches(parts,query,{...options,granularity:'word'}).map(x => x.range), expected)
        assert.deepEqual(matches(parts,query,options).map(x => x.range), expected)
    })
}

test('complete-word expansion candidates retain accent sensitivity', () => {
    const options = {locales:'fr',sensitivity:'accent'}
    const equal = new Intl.Collator('fr',options).compare('cœur','coeur') === 0
    assert.equal(matches(['cœur'],'coeur',options).length, equal ? 1 : 0)
})


for (const [parts, query, expected] of [
    [['e', '\u0301', '猫'], 'é', { startIndex:0, startOffset:0, endIndex:1, endOffset:1 }],
    [['é', '猫'], 'e\u0301', { startIndex:0, startOffset:0, endIndex:0, endOffset:1 }],
]) {
    test(`variant search accepts canonical Unicode spelling with original spans: ${parts.join('')} / ${query}`, () => {
        assert.deepEqual(matches(parts, query, {locales:'fr', sensitivity:'variant'}).map(x => x.range), [expected])
    })
}

test('variant search retains independent overlapping spans through omitted format tokens', () => {
    const results = matches(['a', '\u00ADa', 'a', 'a', 'a', '!'], 'aaa', {sensitivity:'variant'})
    assert.deepEqual(results.map(x => x.range), [
        {startIndex:0, startOffset:0, endIndex:2, endOffset:1},
        {startIndex:1, startOffset:1, endIndex:3, endOffset:1},
        {startIndex:2, startOffset:0, endIndex:4, endOffset:1},
    ])
    assert.deepEqual(results.map(x => x.excerpt.match), ['a\u00ADaa', 'aaa', 'aaa'])
})

for (const [text, query] of [['Cat', 'cat'], ['é', 'e'], ['É', 'é'], ['cafe\u0301', 'cafe']]) {
    test(`variant search preserves case and diacritic distinctions: ${text} / ${query}`, () => {
        assert.deepEqual(matches([text], query, {locales:'fr', sensitivity:'variant'}), [])
    })
}

for (const [text, query, locale, start, end] of [
    ['xœx', 'oe', 'fr', 1, 2],
    ['xoex', 'œ', 'fr', 1, 3],
    ['xæx', 'ae', 'en', 1, 2],
    ['xaex', 'æ', 'en', 1, 3],
    ['xœx', 'oex', 'fr', 1, 3],
    ['xoex', 'œx', 'fr', 1, 4],
    ['xæx', 'aex', 'en', 1, 3],
    ['xaex', 'æx', 'en', 1, 4],
    ['😀xœx', 'oe', 'fr', 3, 4],
    ['😀xaex', 'æ', 'en', 3, 5],
    ['xǽx', 'ae', 'en', 1, 2],
]) {
    for (const sensitivity of ['base', 'case']) {
        test(sensitivity + ' search discovers partial ligature expansions: ' + text + ' / ' + query, () => {
            assert.equal(new Intl.Collator(locale, { sensitivity }).compare(text.slice(start, end), query), 0)
            const results = matches([text], query, { locales: locale, sensitivity })
            assert.deepEqual(results.map(({ range }) => range),
                [{ startIndex: 0, startOffset: start, endIndex: 0, endOffset: end }])
            assert.equal(results[0].excerpt.match, text.slice(start, end))
        })
    }
}

for (const [parts, query, locale, expected] of [
    [['😀x', 'œ', 'x'], 'oe', 'fr',
        { startIndex: 1, startOffset: 0, endIndex: 1, endOffset: 1 }],
    [['😀x', 'o', 'e', 'x'], 'œ', 'fr',
        { startIndex: 1, startOffset: 0, endIndex: 2, endOffset: 1 }],
    [['x', 'æ', 'x'], 'ae', 'en',
        { startIndex: 1, startOffset: 0, endIndex: 1, endOffset: 1 }],
    [['x', 'a', 'e', 'x'], 'æ', 'en',
        { startIndex: 1, startOffset: 0, endIndex: 2, endOffset: 1 }],
    [['x', 'œ', '\u0301', 'x'], 'oe', 'fr',
        { startIndex: 1, startOffset: 0, endIndex: 2, endOffset: 1 }],
]) {
    test('ligature substring ranges preserve inline-node and grapheme spans: ' + parts.join('') + ' / ' + query, () => {
        assert.deepEqual(matches(parts, query, { locales: locale, sensitivity: 'base' }).map(({ range }) => range),
            [expected])
    })
}

test('ligature candidates stay ordered and unique alongside complete-word candidates', () => {
    const results = matches(['xœx œ oe'], 'oe', { locales: 'fr', sensitivity: 'base' })
    assert.deepEqual(results.map(({ range }) => range), [
        { startIndex: 0, startOffset: 1, endIndex: 0, endOffset: 2 },
        { startIndex: 0, startOffset: 4, endIndex: 0, endOffset: 5 },
        { startIndex: 0, startOffset: 6, endIndex: 0, endOffset: 8 },
    ])
    assert.deepEqual(results.map(({ excerpt }) => excerpt.match), ['œ', 'œ', 'oe'])
})

for (const [text, query, locale] of [
    ['xœx', 'oe', 'fr'], ['xoex', 'œ', 'fr'],
    ['xæx', 'ae', 'en'], ['xaex', 'æ', 'en'],
]) {
    test('whole-word boundaries reject partial ligature candidates: ' + text + ' / ' + query, () => {
        assert.deepEqual(matches([text], query,
            { locales: locale, sensitivity: 'base', granularity: 'word' }), [])
    })
    test('whole-word search retains a complete ligature match: ' + text + ' / ' + query, () => {
        const word = text.slice(1, -1)
        assert.deepEqual(matches([word], query,
            { locales: locale, sensitivity: 'base', granularity: 'word' }).map(({ range }) => range),
            [{ startIndex: 0, startOffset: 0, endIndex: 0, endOffset: word.length }])
    })
}

for (const [text, query] of [
    ['xœx', 'o'], ['xœx', 'e'], ['xœex', 'ee'],
    ['xæx', 'a'], ['xæx', 'e'], ['xæax', 'ea'],
]) {
    test('a partial expanded ligature cannot supply a substring match: ' + text + ' / ' + query, () => {
        assert.deepEqual(matches([text], query, { locales: 'en', sensitivity: 'base' }), [])
    })
}

for (const [text, query, locales, sensitivity] of [
    ['xæx', 'ae', 'da', 'base'],
    ['xaex', 'æ', 'da', 'base'],
    ['xœx', 'oe', 'fr', 'accent'],
    ['xæx', 'ae', 'en', 'accent'],
    ['xŒx', 'oe', 'fr', 'case'],
    ['xÆx', 'ae', 'en', 'case'],
    ['xœx', 'OE', 'fr', 'variant'],
    ['xæx', 'ae', 'en', 'variant'],
    ['xœx', 'óe', 'fr', 'accent'],
]) {
    test('ligature candidates retain locale, case and accent distinctions: ' + text + ' / ' + query + ' (' + locales + '/' + sensitivity + ')', () => {
        assert.notEqual(new Intl.Collator(locales, { sensitivity }).compare(text.slice(1, -1), query), 0)
        assert.deepEqual(matches([text], query, { locales, sensitivity }), [])
    })
}
