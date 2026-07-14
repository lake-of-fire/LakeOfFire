import assert from 'node:assert/strict'
import test from 'node:test'

import {
    makeDirectSectionURLResolver,
    processedSectionURLForHref,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-direct-section.js'

test('builds a direct processed-section URL without losing encoded or Unicode path data', () => {
    const sourceURL = 'ebook://ebook/load/local/Books/日本 語.epub'
    const href = 'OPS/日本語/chapter 1.xhtml'
    const result = processedSectionURLForHref(sourceURL, href)
    const url = new URL(result)

    assert.equal(url.protocol, 'ebook:')
    assert.equal(url.pathname, '/processed-section')
    assert.equal(url.searchParams.get('sourceURL'), sourceURL)
    assert.equal(url.searchParams.get('subpath'), href)
    assert.equal(url.searchParams.get('direct'), '1')
})

test('rejects missing direct-section identity', () => {
    assert.equal(processedSectionURLForHref('', 'chapter.xhtml'), null)
    assert.equal(processedSectionURLForHref('ebook://ebook/load/local/book.epub', ''), null)
})

test('enables direct transport only for foreground native sections', async () => {
    const sourceURL = 'ebook://ebook/load/local/book.epub'
    const foregroundResolver = makeDirectSectionURLResolver(sourceURL, false)

    assert.equal(typeof foregroundResolver, 'function')
    assert.equal(
        new URL(await foregroundResolver('OPS/chapter.xhtml')).searchParams.get('subpath'),
        'OPS/chapter.xhtml',
    )
    assert.equal(makeDirectSectionURLResolver(sourceURL, true), null)
})
