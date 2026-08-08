import assert from 'node:assert/strict'
import test from 'node:test'

import { processedSectionURLForHref } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-direct-section.js'

test('builds a direct processed-section URL without speculative writing metadata', () => {
    const sourceURL = 'ebook://ebook/load/local/Books/日本 語.epub'
    const href = 'OPS/日本語/chapter 1.xhtml'
    const result = processedSectionURLForHref(sourceURL, href)
    const url = new URL(result)

    assert.equal(url.searchParams.get('sourceURL'), sourceURL)
    assert.equal(url.searchParams.get('subpath'), href)
    assert.equal(url.searchParams.get('direct'), '1')
    assert.equal(url.searchParams.has('mnbWritingDirection'), false)
    assert.equal(url.searchParams.has('mnbWritingMode'), false)
})

test('rejects missing direct-section identity', () => {
    assert.equal(processedSectionURLForHref('', 'chapter.xhtml'), null)
    assert.equal(processedSectionURLForHref('ebook://ebook/load/local/book.epub', ''), null)
})
