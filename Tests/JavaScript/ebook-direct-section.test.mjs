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

test('carries only normalized vertical source-writing hints', () => {
    const sourceURL = 'ebook://ebook/load/local/book.epub'
    const verticalURL = new URL(processedSectionURLForHref(sourceURL, 'chapter.xhtml', {
        direction: 'vertical',
        writingMode: 'vertical-lr',
    }))
    assert.equal(verticalURL.searchParams.get('mnbWritingDirection'), 'vertical')
    assert.equal(verticalURL.searchParams.get('mnbWritingMode'), 'vertical-lr')

    const horizontalURL = new URL(processedSectionURLForHref(sourceURL, 'chapter.xhtml', {
        direction: 'horizontal',
        writingMode: 'horizontal-tb',
    }))
    assert.equal(horizontalURL.searchParams.has('mnbWritingDirection'), false)
    assert.equal(horizontalURL.searchParams.has('mnbWritingMode'), false)
})

test('rejects missing direct-section identity', () => {
    assert.equal(processedSectionURLForHref('', 'chapter.xhtml'), null)
    assert.equal(processedSectionURLForHref('ebook://ebook/load/local/book.epub', ''), null)
})

test('enables direct transport only for foreground native sections', async () => {
    const sourceURL = 'ebook://ebook/load/local/book.epub'
    const foregroundResolver = makeDirectSectionURLResolver(sourceURL, false, async href => {
        if (href === 'OPS/chapter.xhtml') {
            return '<html><body style="writing-mode: vertical-rl"></body></html>'
        }
        return null
    })

    assert.equal(typeof foregroundResolver, 'function')
    const url = new URL(await foregroundResolver('OPS/chapter.xhtml', 'application/xhtml+xml'))
    assert.equal(url.searchParams.get('subpath'), 'OPS/chapter.xhtml')
    assert.equal(url.searchParams.get('mnbWritingDirection'), 'vertical')
    assert.equal(url.searchParams.get('mnbWritingMode'), 'vertical-rl')
    assert.equal(await foregroundResolver('OPS/image.svg', 'image/svg+xml'), null)
    assert.equal(makeDirectSectionURLResolver(sourceURL, true), null)
})

test('destroy releases pending direct-section direction work', async () => {
    let observedSignal
    const resolver = makeDirectSectionURLResolver(
        'ebook://ebook/load/local/book.epub',
        false,
        (_href, { signal } = {}) => new Promise((resolve, reject) => {
            observedSignal = signal
            signal?.addEventListener('abort', () => {
                const error = new Error('source destroyed')
                error.name = 'AbortError'
                reject(error)
            }, { once: true })
        }),
    )
    const pending = resolver('OPS/chapter.xhtml', 'application/xhtml+xml')
    await Promise.resolve()

    assert.equal(resolver.destroy(), true)
    assert.equal(resolver.destroy(), false)
    assert.equal(observedSignal?.aborted, true)
    await assert.rejects(pending, error => error?.name === 'AbortError')
    assert.equal(await resolver('OPS/chapter.xhtml', 'application/xhtml+xml'), null)
})
