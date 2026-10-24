import assert from 'node:assert/strict'
import test from 'node:test'

globalThis.DOMParser ??= class DOMParser {}

const { EPUB } = await import(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/epub.js'
)

const makeSource = destroy => ({
    loadText: async () => null,
    loadBlob: async () => null,
    getSize: () => 0,
    replaceText: value => value,
    replaceURL: value => value,
    destroy,
})

test('EPUB href navigation addresses retained sections after an unresolved spine reference', () => {
    const book = new EPUB(makeSource(() => {}))
    const manifest = [
        { id: 'one', href: 'OPS/one.xhtml' },
        { id: 'two', href: 'OPS/two.xhtml' },
        { id: 'cover', href: 'OPS/cover.svg' },
    ]
    const cfis = ['epubcfi(/6/2)', 'epubcfi(/6/4)', 'epubcfi(/6/6)']
    book.resources = {
        spine: [{ idref: 'missing' }, { idref: 'one' }, { idref: 'two' }],
        cfis,
        getItemByHref: href => manifest.find(item => item.href === href),
    }
    book.sections = manifest.slice(0, 2).map((item, index) => ({
        id: item.href,
        cfi: cfis[index + 1],
    }))

    assert.equal(book.resolveHref('OPS/one.xhtml').index, 0)
    assert.equal(book.resolveHref('OPS/two.xhtml').index, 1)
    assert.equal(book.resolveHref('OPS/cover.svg').index, -1)
    assert.equal(book.resolveHref('OPS/absent.xhtml'), null)
    book.destroy()
})

test('EPUB href navigation preserves manifest identity when spine entries share an href', () => {
    const book = new EPUB(makeSource(() => {}))
    const manifest = [
        { id: 'first-manifest-item', href: 'OPS/shared.xhtml' },
        { id: 'second-manifest-item', href: 'OPS/shared.xhtml' },
    ]
    const cfis = ['epubcfi(/6/2)', 'epubcfi(/6/4)']
    book.resources = {
        spine: [{ idref: 'second-manifest-item' }, { idref: 'first-manifest-item' }],
        cfis,
        getItemByHref: href => manifest.find(item => item.href === href),
    }
    book.sections = cfis.map(cfi => ({ id: 'OPS/shared.xhtml', cfi }))

    assert.equal(book.resolveHref('OPS/shared.xhtml').index, 1)
    book.destroy()
})

test('EPUB CFI navigation maps original spine steps without admitting a skipped reference', () => {
    const book = new EPUB(makeSource(() => {}))
    const cfis = ['epubcfi(/6/2)', 'epubcfi(/6/4)', 'epubcfi(/6/6)']
    const anchor = () => 0
    // Resources owns parsing the original OPF spine ordinal. This boundary
    // fixture supplies its result; the adjacent DOM suite exercises real XML/CFI parsing.
    book.resources = {
        cfis,
        resolveCFI: cfi => ({ index: cfis.indexOf(cfi), anchor }),
    }
    book.sections = [
        { id: 'OPS/one.xhtml', cfi: cfis[1] },
        { id: 'OPS/two.xhtml', cfi: cfis[2] },
    ]

    assert.deepEqual(book.resolveCFI(cfis[1]), { index: 0, anchor })
    assert.deepEqual(book.resolveCFI(cfis[2]), { index: 1, anchor })
    assert.deepEqual(book.resolveCFI(cfis[0]), { index: -1, anchor })
    assert.deepEqual(book.resolveCFI('epubcfi(/6/8)'), { index: -1, anchor })
    book.destroy()
})
