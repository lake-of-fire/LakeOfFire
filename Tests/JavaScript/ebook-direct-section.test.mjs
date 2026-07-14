import assert from 'node:assert/strict'
import test from 'node:test'

import { processedSectionURLForHref } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-direct-section.js'

test('builds a direct processed-section URL without losing encoded path data', () => {
    const sourceURL = 'ebook://ebook/load/local/Books/日本 語.epub'
    const href = 'OPS/日本語/chapter 1.xhtml'
    const result = processedSectionURLForHref(sourceURL, href, {
        direction: 'vertical',
        writingMode: 'vertical-rl',
    })
    const url = new URL(result)

    assert.equal(url.searchParams.get('sourceURL'), sourceURL)
    assert.equal(url.searchParams.get('subpath'), href)
    assert.equal(url.searchParams.get('direct'), '1')
    assert.equal(url.searchParams.get('mnbWritingDirection'), 'vertical')
    assert.equal(url.searchParams.get('mnbWritingMode'), 'vertical-rl')
})

test('rejects missing direct-section identity', () => {
    assert.equal(processedSectionURLForHref('', 'chapter.xhtml'), null)
    assert.equal(processedSectionURLForHref('ebook://ebook/load/local/book.epub', ''), null)
})
