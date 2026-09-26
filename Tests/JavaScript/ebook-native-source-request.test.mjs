import assert from 'node:assert/strict'
import test from 'node:test'
import { makeNativeEbookSource, nativeEbookRequest, normalizeEbookPackageSessionID } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-native-source-request.js'
import { processedSectionURLForHref, makeDirectSectionURLResolver } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-direct-section.js'
import { EbookLoadResources } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-load-resources.js'
import { readFileSync } from 'node:fs'

const sourceURL = 'ebook://ebook/load/local/Books/日本語.epub'
const id = '371cf379-d180-449d-bca2-13b902c3634d'

test('all native fetch routes retain the exact package capability', () => {
    for (const route of ['entries', 'entry']) {
        const request = nativeEbookRequest(route, sourceURL, { packageSessionID: id, subpath: 'OPS/%2F image.png' })
        const url = new URL(request.url)
        assert.equal(url.searchParams.get('sourceURL'), sourceURL)
        assert.equal(url.searchParams.get('packageSessionID'), id)
        assert.equal(url.searchParams.get('subpath'), 'OPS/%2F image.png')
        assert.equal(request.headers['X-Ebook-Package-Session'], id)
    }
})
test('explicit legacy requests do not fabricate a capability', () => {
    const request = nativeEbookRequest('entries', sourceURL)
    assert.equal(new URL(request.url).searchParams.has('packageSessionID'), false)
    assert.equal(request.headers['X-Ebook-Package-Session'], undefined)
})
test('malformed supplied capabilities cannot become legacy', () => {
    for (const value of ['', 'short', id.toUpperCase(), ` ${id}`, [], 5]) {
        assert.throws(() => nativeEbookRequest('entry', sourceURL, { packageSessionID: value }))
        assert.throws(() => processedSectionURLForHref(sourceURL, 'OPS/a.xhtml', null, value))
    }
    assert.equal(normalizeEbookPackageSessionID(undefined), null)
})
test('an immutable source carries its original identity through cache warming', () => {
    const source = makeNativeEbookSource(sourceURL, id)
    const resources = new EbookLoadResources({ nativeSource: source })
    assert.equal(Object.isFrozen(source), true)
    assert.throws(() => { source.packageSessionID = 'another' })
    assert.equal(resources.makeReusableSource({ isNativeSource: true }), source)
    // makeReusableSource's actual contract requires no generator for native data.
    assert.equal(source.packageSessionID, id)
})
test('processed documents carry capability for their relative resource owner', () => {
    const url = new URL(processedSectionURLForHref(sourceURL, 'OPS/chapter.xhtml', { direction: 'vertical' }, id))
    assert.equal(url.searchParams.get('packageSessionID'), id)
    assert.equal(url.searchParams.get('mnbWritingDirection'), 'vertical')
})
test('direct section resolver retains the captured capability across suspension', async () => {
    const resolver = makeDirectSectionURLResolver(sourceURL, false, async () => '<html></html>', id)
    const result = await resolver('OPS/chapter.xhtml', 'application/xhtml+xml')
    assert.equal(new URL(result).searchParams.get('packageSessionID'), id)
    resolver.destroy()
    assert.equal(await resolver('OPS/chapter.xhtml', 'application/xhtml+xml'), null)
})
test('two opens of the same source use separate request identities', () => {
    const other = 'dce2c5c5-2537-42b7-b678-67b57ac0bccb'
    assert.notEqual(nativeEbookRequest('entries', sourceURL, { packageSessionID: id }).url,
        nativeEbookRequest('entries', sourceURL, { packageSessionID: other }).url)
})
test('unsupported routes and nonnative sources reject rather than silently downgrade', () => {
    assert.throws(() => nativeEbookRequest('other', sourceURL))
    assert.throws(() => makeNativeEbookSource('https://example.com/book.epub', id))
})
test('live viewer and cache-warmer call sites both use the captured source', () => {
    // Supplemental wiring audit, not browser execution of the whole viewer.
    const viewer = readFileSync(new URL('../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-viewer.js', import.meta.url), 'utf8')
    assert.match(viewer, /makeNativeEpubLoader\(source, isCacheWarmer/)
    assert.match(viewer, /makeReplaceText\(isCacheWarmer, source\)/)
    assert.match(viewer, /makeDirectSectionURLResolver\(url, isCacheWarmer, loadText, source\.packageSessionID\)/)
    assert.match(viewer, /makeNativeSource\(url, packageSessionID\)/)
    assert.equal((viewer.match(/manabiLoadEBookPackageSessionID === packageSessionID/g) ?? []).length, 2)
})

test('native rendition is not replaced by another OPF in the same archive', async () => {
    const { selectedEbookPackageDocument } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-native-source-request.js')
    const opfs = [{ fullPath: 'A/book.opf' }, { fullPath: 'B/日本語.opf' }]
    assert.equal(selectedEbookPackageDocument(opfs), 'A/book.opf')
    assert.equal(selectedEbookPackageDocument(opfs, 'B/日本語.opf'), 'B/日本語.opf')
    assert.throws(() => selectedEbookPackageDocument(opfs, 'Missing/book.opf'))
    assert.throws(() => selectedEbookPackageDocument(opfs, ''))
    assert.throws(() => selectedEbookPackageDocument(opfs, { fullPath: 'A/book.opf' }))
})
test('canonically similar OPF strings do not borrow a declared native path', async () => {
    const { selectedEbookPackageDocument } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-native-source-request.js')
    assert.throws(() => selectedEbookPackageDocument([{ fullPath: 'caf\u00e9.opf' }], 'cafe\u0301.opf'))
})
