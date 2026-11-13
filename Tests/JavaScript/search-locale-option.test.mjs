import assert from 'node:assert/strict'
import test from 'node:test'
import { searchMatcher } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/search.js'

// Exercise the real matcher and locale selection. The walker controls text
// nodes and records range coordinates; this is not a browser DOM Range test.
const match = (options, bodyLang = '', rootLang = '') => {
    const doc = { body: { lang: bodyLang }, documentElement: { lang: rootLang } }
    const textWalker = (document, callback) => {
        assert.equal(document, doc)
        return callback(['I'], (...coordinates) => coordinates)
    }
    return [...searchMatcher(textWalker, {
        matchCase: false, matchDiacritics: false, matchWholeWords: false,
        ...options,
    })(doc, 'ı')]
}
const expected = [{ range: [0, 0, 0, 1], excerpt: { pre: '', match: 'I', post: '' } }]

test('matcher honors the defaultLocale option supplied by View.search', () => {
    assert.deepEqual(match({ defaultLocale: 'tr' }), expected)
})
test('body language precedes document and caller locale', () => {
    assert.deepEqual(match({ defaultLocale: 'tr' }, 'en', 'tr'), [])
    assert.deepEqual(match({ defaultLocale: 'en' }, 'tr', 'en'), expected)
})
test('document language precedes caller locale when body language is empty', () => {
    assert.deepEqual(match({ defaultLocale: 'tr' }, '', 'en'), [])
    assert.deepEqual(match({ defaultLocale: 'en' }, '', 'tr'), expected)
})
test('correct locale spelling takes priority over legacy spelling', () => {
    assert.deepEqual(match({ defaultLocale: 'en', defalutLocale: 'tr' }), [])
    assert.deepEqual(match({ defaultLocale: 'tr', defalutLocale: 'en' }), expected)
})
test('legacy spelling remains supported when correct spelling is absent or empty', () => {
    assert.deepEqual(match({ defalutLocale: 'tr' }), expected)
    assert.deepEqual(match({ defaultLocale: '', defalutLocale: 'tr' }), expected)
})
test('missing or empty locale keeps English fallback', () => {
    assert.deepEqual(match({}), [])
    assert.deepEqual(match({ defaultLocale: '' }), [])
})
test('locale correction preserves explicit case and diacritic controls', () => {
    assert.deepEqual(match({ defaultLocale: 'tr', matchCase: true, matchDiacritics: true }), [])
})
