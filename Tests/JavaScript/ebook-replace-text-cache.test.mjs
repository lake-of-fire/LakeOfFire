import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import vm from 'node:vm'
import { createOwnedAsyncCache } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/owned-async-cache.js'

const viewerURL = new URL('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-viewer.js', import.meta.url)
const viewerSource = await readFile(viewerURL, 'utf8')

// Run the shipping replacement function without the viewer's browser bootstrap.
function declaration(start, end) {
    const first = viewerSource.indexOf(start)
    const last = viewerSource.indexOf(end, first + start.length)
    if (first < 0 || last < 0) throw new Error(`Missing viewer fixture boundary: ${start}`)
    return viewerSource.slice(first, last)
}

const declarations = [
    declaration('const REPLACE_TEXT_RESULT_CACHE_LIMIT =', 'const computeRawSectionWritingDirectionFromText ='),
    declaration('const firstLiveSectionHref =', 'window.manabi_recordLiveProcessedSection ='),
    declaration('const normalizeSpineStoragePath =', 'const setNativeHideNavigationState ='),
].join('\n')

const original = '<html><body>raw chapter</body></html>'
const processed = '<html><body><m-s><m-m>processed chapter</m-m></m-s></body></html>'
const nativeSource = {
    url: 'ebook://ebook/load/native-book.epub',
    packageSessionID: '9c5645c3-a20c-4c5c-9702-465dbe494b82',
}

function makeViewer(responses) {
    const requests = []
    const published = []
    const context = {
        createOwnedAsyncCache,
        performanceNowMs: () => 0,
        nextEbookLoadRequestID: () => 'request',
        manabiTimelineMeasure() {},
        manabiTimelineMark() {},
        manabi_recordLiveProcessedSection: href => published.push(href),
        reader: { view: { ownerDocument: { defaultView: { top: { location: { href: 'file:///zip-book.epub' } } } } } },
        fetch: async url => {
            requests.push(new URL(url))
            const response = responses.shift()
            assert.ok(response, 'unexpected chapter request')
            return response
        },
    }
    context.window = context
    const makeReplaceText = vm.runInNewContext(`${declarations}\nmakeReplaceText`, context, { filename: viewerURL.pathname })
    return { context, makeReplaceText, requests, published }
}

function sectionResponse(html, authority) {
    const headers = authority === undefined ? {} : { 'X-Manabi-Processing-Authoritative': authority }
    return new Response(html, { headers })
}

function assertIdle({ context }) {
    assert.equal(context.__manabiInflightReplaceTextCount, 0)
    assert.equal(context.__manabiInflightLiveReplaceTextCount ?? 0, 0)
}

test('detached native EPUB search retries nonauthoritative chapter responses and reuses authoritative HTML', async () => {
    const viewer = makeViewer([
        sectionResponse(original, 'false'),
        sectionResponse(original),
        sectionResponse(processed, 'true'),
    ])
    const replace = viewer.makeReplaceText({ nativeSource, allowForegroundHTML: false })
    const search = () => replace('chapter.xhtml', original, 'application/xhtml+xml', { forSearch: true })
    try {
        await assert.rejects(search(), /requires authoritative processed structure/)
        assertIdle(viewer)
        await assert.rejects(search(), /requires authoritative processed structure/)
        assertIdle(viewer)
        const html = await search()
        assert.match(html, /<m-m>processed chapter<\/m-m>/)
        assert.equal(await search(), html)
        assert.equal(viewer.requests.length, 3)
        for (const request of viewer.requests) {
            assert.equal(request.pathname, '/processed-section')
            assert.equal(request.searchParams.get('subpath'), 'chapter.xhtml')
            assert.equal(request.searchParams.get('packageSessionID'), nativeSource.packageSessionID)
        }
        assert.equal(viewer.context.__manabiFirstLiveSectionHref, undefined)
        assert.deepEqual(viewer.published, [])
        assertIdle(viewer)
    } finally {
        replace.destroy()
    }
})

test('ZIP EPUB foreground replacement still returns nonauthoritative HTML', async () => {
    const viewer = makeViewer([sectionResponse(original, 'false')])
    const replace = viewer.makeReplaceText()
    try {
        const html = await replace('chapter.xhtml', original, 'application/xhtml+xml')
        assert.match(html, /raw chapter/)
        assert.deepEqual(viewer.published, ['chapter.xhtml'])
        assertIdle(viewer)
    } finally {
        replace.destroy()
    }
})
