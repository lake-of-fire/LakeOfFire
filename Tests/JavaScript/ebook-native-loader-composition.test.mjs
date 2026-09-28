import assert from 'node:assert/strict'
import test from 'node:test'
import { createNativeEpubLoader } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-native-loader.js'
import { makeNativeEbookSource, selectedEbookPackageDocument } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-native-source-request.js'
import { createEbookLoadHandlers, createNavigationIntentRunner } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-load-coordinator.js'

const url = 'ebook://ebook/load/local/Books/日本語.epub'
const firstID = '371cf379-d180-449d-bca2-13b902c3634d'
const secondID = 'dce2c5c5-2537-42b7-b678-67b57ac0bccb'
const opf = 'B/日本語.opf', chapter = 'B/本文.xhtml', image = 'B/%2F image.png'
const text = '<html><head></head><body>本文<ruby>漢字<rt>かんじ</rt></ruby></body></html>'
const entries = [{ path: 'A/book.opf', size: 40 }, { path: opf, size: 40 }, { path: chapter, size: 90 }, { path: image, size: 3 }]
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r }); return { promise, resolve } }
const until = async predicate => {
    for (let n = 0; n < 100; ++n) { if (predicate()) return; await Promise.resolve() }
    assert.fail('Stage was not reached')
}
function fixture({ session = firstID, path = opf, fetch = null } = {}) {
    const requests = [], factories = []
    const options = {
        fetch: async (requestURL, options) => {
            const parsed = new URL(requestURL)
            requests.push({ url: parsed, headers: options.headers })
            if (fetch) return fetch(parsed, options)
            if (parsed.pathname === '/entries') return { ok: true, json: async () => ({ entries, packageDocumentPath: path }) }
            return new Response(parsed.searchParams.get('subpath') === image ? new Uint8Array([1, 2, 3]) : text,
                { headers: { 'content-type': parsed.searchParams.get('subpath') === image ? 'image/png' : 'application/xhtml+xml; charset=utf-8' } })
        },
        makeReplaceText: (warm, source) => { factories.push({ warm, source }); return async (_href, value) => value },
    }
    return { requests, factories, options, source: makeNativeEbookSource(url, session) }
}

test('composed native catalog, text and blobs preserve one source and capability', async () => {
    const f = fixture(), loader = await createNativeEpubLoader(f.source, false, f.options)
    assert.equal(await loader.loadText(chapter), text)
    const blob = await loader.loadBlob(image)
    assert.equal(blob.type, 'image/png'); assert.deepEqual([...new Uint8Array(await blob.arrayBuffer())], [1, 2, 3])
    for (const request of f.requests) {
        assert.equal(request.url.searchParams.get('sourceURL'), url)
        assert.equal(request.url.searchParams.get('packageSessionID'), firstID)
        assert.equal(request.headers['X-Ebook-Package-Session'], firstID)
        assert.equal(request.headers['X-Ebook-Source-URL'], url)
    }
    assert.equal(f.requests[2].url.searchParams.get('subpath'), image)
    assert.equal(loader.packageDocumentPath, opf)
    assert.equal(selectedEbookPackageDocument([{ fullPath: 'A/book.opf' }, { fullPath: opf }], loader.packageDocumentPath), opf)
})

test('processed sections and text processing receive the same captured capability', async () => {
    const f = fixture(), loader = await createNativeEpubLoader(f.source, false, f.options)
    const result = new URL(await loader.replaceURL(chapter, 'application/xhtml+xml'))
    assert.equal(result.searchParams.get('packageSessionID'), firstID)
    assert.equal(result.searchParams.get('sourceURL'), url)
    assert.equal(f.factories[0].source.packageSessionID, firstID)
    assert.equal(Object.isFrozen(f.factories[0].source), true)
    assert.equal(f.factories[0].warm, false)
})

test('warm and live native loaders keep the same rendition but different processing modes', async () => {
    const f = fixture()
    const live = await createNativeEpubLoader(f.source, false, f.options)
    const warm = await createNativeEpubLoader(f.source, true, f.options)
    assert.equal(warm.packageDocumentPath, live.packageDocumentPath)
    assert.equal(warm.replaceURL, null)
    assert.deepEqual(f.factories.map(x => x.warm), [false, true])
    assert.equal(await warm.loadText(chapter), text)
    assert.equal(f.requests.at(-1).headers['X-Ebook-Package-Session'], firstID)
})

test('two live capabilities at the same pathname never borrow each other', async () => {
    const f = fixture()
    const a = await createNativeEpubLoader(f.source, false, f.options)
    const b = await createNativeEpubLoader(makeNativeEbookSource(url, secondID), false, f.options)
    await a.loadText(chapter); await b.loadText(chapter)
    assert.deepEqual(f.requests.map(x => x.headers['X-Ebook-Package-Session']), [firstID, secondID, firstID, secondID])
})

test('bound catalog cannot omit, invent or normalize the selected OPF', async () => {
    for (const path of [null, '', 'missing.opf', 'B/日 本語.opf', ['A/book.opf']]) {
        const f = fixture({ path })
        await assert.rejects(createNativeEpubLoader(f.source, false, f.options), /Missing native EPUB rendition/)
        assert.equal(f.factories.length, 0)
    }
})

test('legacy catalog remains legacy and does not force an undeclared native rendition', async () => {
    const f = fixture({ session: null }), loader = await createNativeEpubLoader(f.source, false, f.options)
    assert.equal(loader.packageDocumentPath, null)
    assert.equal(f.requests[0].url.searchParams.has('packageSessionID'), false)
    assert.equal(f.requests[0].headers['X-Ebook-Package-Session'], undefined)
    assert.equal(await loader.loadText(chapter), text)
})

test('malformed explicit capabilities reject without fetching', async () => {
    const f = fixture()
    for (const id of ['', firstID.toUpperCase(), 7]) {
        await assert.rejects(createNativeEpubLoader({ url, packageSessionID: id }, false, f.options), TypeError)
    }
    assert.equal(f.requests.length, 0)
})

test('catalog HTTP failure cannot produce an empty successful package', async () => {
    const f = fixture({ fetch: async () => ({ ok: false, status: 410, json: () => assert.fail('Must not parse errors') }) })
    await assert.rejects(createNativeEpubLoader(f.source, false, f.options), /410/)
    assert.equal(f.factories.length, 0)
})

test('missing entry and unauthorized entry response never fall back to an unbound fetch', async () => {
    const f = fixture({ fetch: async parsed => parsed.pathname === '/entries'
        ? { ok: true, json: async () => ({ entries, packageDocumentPath: opf }) }
        : { ok: false, status: 403, arrayBuffer: () => assert.fail('Must not read forbidden bytes') } })
    const loader = await createNativeEpubLoader(f.source, false, f.options)
    assert.equal(await loader.loadText('not-in-catalog'), null)
    assert.equal(await loader.loadBlob(image), null)
    assert.equal(f.requests.length, 2)
    assert.equal(f.requests[1].headers['X-Ebook-Package-Session'], firstID)
})

test('close during catalog decoding cannot publish a native loader', async () => {
    let current = true
    const gate = deferred(), f = fixture({ fetch: async () => ({ ok: true, json: () => gate.promise }) })
    const result = createNativeEpubLoader(f.source, false, { ...f.options, isCurrent: () => current })
    await until(() => f.requests.length === 1)
    current = false; gate.resolve({ entries, packageDocumentPath: opf })
    await assert.rejects(result, { code: 'reader-open-superseded' })
    assert.equal(f.factories.length, 0)
})

test('destroy during resource decoding discards bytes and invalidates direct sections', async () => {
    const gate = deferred()
    const f = fixture({ fetch: async parsed => parsed.pathname === '/entries'
        ? { ok: true, json: async () => ({ entries, packageDocumentPath: opf }) }
        : { ok: true, headers: new Headers(), arrayBuffer: () => gate.promise } })
    const loader = await createNativeEpubLoader(f.source, false, f.options)
    const pending = loader.loadText(chapter)
    await until(() => f.requests.length === 2)
    assert.equal(loader.destroy(), true); assert.equal(loader.destroy(), false)
    gate.resolve(new TextEncoder().encode(text).buffer)
    assert.equal(await pending, null)
    assert.equal(await loader.replaceURL(chapter, 'application/xhtml+xml'), null)
    assert.equal(await loader.loadBlob(image), null)
    assert.equal(loader.getSize(chapter), 0)
    assert.equal(loader.entries.length, 0)
})

test('captured descriptor does not track later caller mutation', async () => {
    const f = fixture(), mutable = { url, packageSessionID: firstID }
    const loader = await createNativeEpubLoader(mutable, false, f.options)
    mutable.packageSessionID = secondID; mutable.url = 'ebook://ebook/load/local/other.epub'
    await loader.loadText(chapter)
    assert.equal(f.requests.at(-1).headers['X-Ebook-Package-Session'], firstID)
    assert.equal(f.requests.at(-1).headers['X-Ebook-Source-URL'], url)
})

test('top-level load and cache warming actually open through the bound resource loader', async () => {
    const f = fixture(), readers = [], messages = []
    let warmer, token = 0
    const host = { document: {}, location: { href: 'https://reader.invalid' }, setTimeout, clearTimeout,
        requestAnimationFrame: callback => setTimeout(callback, 0), cancelAnimationFrame: clearTimeout,
        webkit: { messageHandlers: { ebookViewerLoaded: { postMessage: message => messages.push(message) } } } }
    class Reader {
        constructor() { readers.push(this); this.isClosed = false }
        async open(source) {
            this.loader = await createNativeEpubLoader(source, false, { ...f.options, isCurrent: () => !this.isClosed })
            this.view = { lastLocation: { fraction: 0 }, renderer: {},
                goToFraction: value => { this.view.lastLocation = { fraction: value } } }
        }
        completeLastPositionLoad() { this.hasLoadedLastPosition = true }
        completeLastPositionLoadAttempt() {}
        close() { this.isClosed = true; this.onLoadClosed?.(); this.loader?.destroy() }
    }
    class CacheWarmer {
        constructor({ loadResources }) { this.resources = loadResources; warmer = this }
        destroy() { this.resources.close() }
    }
    const handlers = createEbookLoadHandlers({ host, Reader, CacheWarmer, makeNativeSource: makeNativeEbookSource,
        makeFileSource: () => assert.fail('Bound open cannot use a file fallback'),
        installReaderPresentationState() {}, beginReplaceTextCacheGeneration() {},
        beginForegroundCriticalSection: () => ++token, finishForegroundCriticalSection() {},
        ensureRestorePositionSaveUserInputTracking() {}, runWithNavigationIntent: createNavigationIntentRunner(host),
        markReaderRenderReady() {}, postLandscapeInsetRestoreProbe() {}, scheduleDeferredCacheWarmerOpen() {} })
    const opening = id => ({ url, packageSessionID: id, initialRestore: { requestID: id, cfi: '', fractionalCompletion: 0 } })
    await handlers.loadEBook(opening(firstID))
    assert.equal(readers[0].hasLoadedLastPosition, true)
    assert.equal(messages[0].initialRestoreResult.restoreSatisfied, true)
    const warm = await createNativeEpubLoader(warmer.resources.makeReusableSource({ isNativeSource: true }), true, f.options)
    assert.equal(warm.packageDocumentPath, opf)
    await warm.loadText(chapter)
    assert.equal(f.requests.at(-1).headers['X-Ebook-Package-Session'], firstID)
    await handlers.loadEBook(opening(secondID))
    assert.equal(readers[0].isClosed, true)
    assert.equal(readers[1].loader.packageDocumentPath, opf)
    assert.equal(messages[1].initialRestoreResult.requestID, secondID)
    assert.equal(f.requests.at(-1).headers['X-Ebook-Package-Session'], secondID)
    warm.destroy(); readers[1].close()
})
