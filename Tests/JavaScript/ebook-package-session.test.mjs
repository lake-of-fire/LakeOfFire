import assert from 'node:assert/strict'
import test from 'node:test'
import { processedSectionURLForHref, makeDirectSectionURLResolver } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-direct-section.js'

test('processed section retains the immutable package capability', () => {
    const url = new URL(processedSectionURLForHref(
        'ebook://ebook/load/local/book.epub', 'OPS/chapter.xhtml', null,
        'ccf92c19-c66e-4dc2-8a1e-87b2b323635c',
    ))
    assert.equal(url.searchParams.get('packageSessionID'), 'ccf92c19-c66e-4dc2-8a1e-87b2b323635c')
    assert.equal(url.searchParams.get('subpath'), 'OPS/chapter.xhtml')
})

test('suspended section resolution keeps its original capability', async () => {
    let release
    const waiting = new Promise(resolve => { release = resolve })
    const resolver = makeDirectSectionURLResolver(
        'ebook://ebook/load/local/book.epub', false,
        async () => { await waiting; return '<html><body>Original</body></html>' },
        'ccf92c19-c66e-4dc2-8a1e-87b2b323635c',
    )
    const pending = resolver('OPS/chapter.xhtml', 'application/xhtml+xml')
    release()
    const url = new URL(await pending)
    assert.equal(url.searchParams.get('packageSessionID'), 'ccf92c19-c66e-4dc2-8a1e-87b2b323635c')
    resolver.destroy()
})
