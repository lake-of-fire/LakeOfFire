import assert from 'node:assert/strict'
import test from 'node:test'

import {
    makeRawSectionWritingDirectionResolver,
    rawSectionWritingDirection,
    resolveEbookRelativePath,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-writing-direction.js'

test('resolves EPUB-relative stylesheet paths without allowing external URLs', () => {
    assert.equal(resolveEbookRelativePath('../Styles/book.css#theme', 'OPS/Text/chapter.xhtml'), 'OPS/Styles/book.css')
    assert.equal(resolveEbookRelativePath('local.css?revision=2', 'OPS/chapter.xhtml'), 'OPS/local.css')
    assert.equal(resolveEbookRelativePath('https://example.com/book.css', 'OPS/chapter.xhtml'), null)
})

test('prefers body inline writing mode and normalizes legacy values', async () => {
    const direction = await rawSectionWritingDirection({
        href: 'OPS/chapter.xhtml',
        html: `
            <html style="writing-mode: horizontal-tb">
            <body style="-epub-writing-mode: tb-lr"></body>
            </html>
        `,
    })
    assert.deepEqual(direction, { direction: 'vertical', writingMode: 'vertical-lr' })
})

test('resolves linked and inline styles in document order with CSS precedence', async () => {
    const requested = []
    const direction = await rawSectionWritingDirection({
        href: 'OPS/Text/chapter.xhtml',
        html: `
            <html class="book"><head>
            <link rel="stylesheet" href="../Styles/book.css">
            <style>html.book body.chapter { writing-mode: horizontal-tb; }</style>
            </head><body class="chapter"></body></html>
        `,
        loadText: async href => {
            requested.push(href)
            return 'body.chapter { writing-mode: vertical-rl !important; }'
        },
    })
    assert.deepEqual(requested, ['OPS/Styles/book.css'])
    assert.deepEqual(direction, { direction: 'vertical', writingMode: 'vertical-rl' })
})

test('ignores print and alternate styles while resolving screen media blocks', async () => {
    const direction = await rawSectionWritingDirection({
        href: 'OPS/chapter.xhtml',
        html: `
            <html><head>
            <link rel="alternate stylesheet" href="alternate.css">
            <style media="print">body { writing-mode: horizontal-tb; }</style>
            <style>@media screen { body { writing-mode: vertical-lr; } }</style>
            </head><body></body></html>
        `,
        loadText: async () => 'body { writing-mode: horizontal-tb !important; }',
    })
    assert.deepEqual(direction, { direction: 'vertical', writingMode: 'vertical-lr' })
})

test('uses bounded class conventions when styles are missing or malformed', async () => {
    const vertical = await rawSectionWritingDirection({
        href: 'chapter.xhtml',
        html: '<html class="vrtl"><head><link rel="stylesheet" href="missing.css"></head><body></body></html>',
        loadText: async () => { throw new Error('missing') },
    })
    const horizontal = await rawSectionWritingDirection({
        href: 'chapter.xhtml',
        html: '<html><body class="hltr"></body></html>',
    })
    const unresolved = await rawSectionWritingDirection({
        href: 'chapter.xhtml',
        html: '<html><style>body { writing-mode:</style><body></body></html>',
    })
    assert.deepEqual(vertical, { direction: 'vertical', writingMode: 'vertical-rl' })
    assert.deepEqual(horizontal, { direction: 'horizontal', writingMode: 'horizontal-tb' })
    assert.equal(unresolved, null)
})

test('caches direction only within one loader generation and coalesces requests', async () => {
    let loadCount = 0
    const loadText = async href => {
        loadCount += 1
        assert.equal(href, 'OPS/chapter.xhtml')
        return '<html><body style="writing-mode: vertical-rl"></body></html>'
    }
    const firstGeneration = makeRawSectionWritingDirectionResolver({ loadText })
    const [first, duplicate] = await Promise.all([
        firstGeneration('OPS/chapter.xhtml'),
        firstGeneration('OPS/chapter.xhtml'),
    ])
    assert.deepEqual(first, { direction: 'vertical', writingMode: 'vertical-rl' })
    assert.deepEqual(duplicate, first)
    assert.equal(loadCount, 1)

    const replacementGeneration = makeRawSectionWritingDirectionResolver({ loadText })
    await replacementGeneration('OPS/chapter.xhtml')
    assert.equal(loadCount, 2)
})
