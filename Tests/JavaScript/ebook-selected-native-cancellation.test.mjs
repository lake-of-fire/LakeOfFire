import assert from 'node:assert/strict'
import test from 'node:test'
import { readFile } from 'node:fs/promises'

import { makeDirectSectionURLResolver } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-direct-section.js'

// Evaluate the selected viewer's actual inline loader declarations. The selected
// target predates ebook-native-loader.js; importing that newer implementation
// here would test a producer that this viewer does not call.
const viewer = await readFile(new URL(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-viewer.js', import.meta.url,
), 'utf8')
const loaderStart = viewer.indexOf('const makeNativeSourceURLQuery =')
const loaderEnd = viewer.indexOf('const closeZipReader =', loaderStart)
if (loaderStart < 0 || loaderEnd < loaderStart) throw new Error('Native loader fixture boundary is unavailable')
const inlineLoaderFactory = new Function(
    'fetch', 'makeDirectSectionURLResolver', 'makeReplaceText', 'performanceNowMs',
    `${viewer.slice(loaderStart, loaderEnd)}\nreturn makeNativeEpubLoader`,
)

const sourceURL = 'ebook://ebook/load/book%20one.epub?revision=1&fragment=%23'
const chapter = 'OPS/Text/chapter.xhtml'
const stylesheet = 'OPS/Styles/main.css'
const importedStylesheet = 'OPS/Styles/nested.css'
const html = '<html><head><link rel="stylesheet" href="../Styles/main.css"></head><body>Reading</body></html>'
const defaultFiles = () => new Map([
    [chapter, { data: html, type: 'application/xhtml+xml; charset=utf-8' }],
    [stylesheet, { data: '@import url("./nested.css");', type: 'text/css' }],
    [importedStylesheet, { data: 'body { writing-mode: vertical-lr; }', type: 'text/css' }],
])
const deferred = () => {
    let resolve, reject
    const promise = new Promise((resolvePromise, rejectPromise) => {
        resolve = resolvePromise
        reject = rejectPromise
    })
    return { promise, resolve, reject }
}
const bytesFor = data => typeof data === 'string' ? new TextEncoder().encode(data) : data
const abortError = () => new DOMException('Native resource request aborted', 'AbortError')

const nativeTransport = ({ files = defaultFiles(), heldPath, phase } = {}) => {
    const entered = deferred()
    const requests = []
    let release = () => {}
    const wait = async request => {
        const gate = deferred()
        release = gate.resolve
        const onAbort = () => {
            request.abortEvents += 1
            gate.reject(abortError())
        }
        request.signal?.addEventListener('abort', onAbort, { once: true })
        if (request.signal?.aborted) onAbort()
        entered.resolve(request)
        try { await gate.promise }
        finally { request.signal?.removeEventListener('abort', onAbort) }
    }
    return {
        requests,
        entered: entered.promise,
        release: () => release(),
        fetch: async (value, options = {}) => {
            const url = new URL(value)
            const path = url.searchParams.get('subpath')
            const request = { url, path, headers: options.headers, signal: options.signal, bodyReads: 0, abortEvents: 0 }
            requests.push(request)
            if (url.pathname === '/entries') {
                return { ok: true, json: async () => ({
                    entries: [...files].map(([path, file]) => ({ path, size: bytesFor(file.data).byteLength })),
                }) }
            }
            if (url.pathname !== '/entry') throw new Error(`Unexpected native route: ${url.pathname}`)
            const file = files.get(path)
            if (!file) return { ok: false, status: 404 }
            if (path === heldPath && phase === 'response') await wait(request)
            return {
                ok: true,
                headers: new Headers({ 'content-type': file.type }),
                arrayBuffer: async () => {
                    request.bodyReads += 1
                    if (path === heldPath && phase === 'body') await wait(request)
                    const bytes = bytesFor(file.data)
                    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
                },
            }
        },
    }
}

const openNativeLoader = async (transport, { warmer = false, isCurrent = () => true } = {}) => {
    const modes = []
    const replacement = async (_href, text) => text
    const makeLoader = inlineLoaderFactory(
        transport.fetch, makeDirectSectionURLResolver,
        isCacheWarmer => { modes.push(isCacheWarmer); return replacement },
        () => 0,
    )
    const loader = await makeLoader(sourceURL, warmer, { isCurrent })
    return { loader, modes, replacement }
}

const assertSource = requests => {
    for (const request of requests) {
        assert.equal(request.url.protocol, 'ebook:')
        assert.equal(request.url.hostname, 'ebook')
        assert.equal(request.url.searchParams.get('sourceURL'), sourceURL)
        assert.equal(request.headers['X-Ebook-Source-URL'], sourceURL)
    }
}

for (const [stage, heldPath] of [['chapter', chapter], ['stylesheet', stylesheet], ['import', importedStylesheet]]) {
    for (const phase of ['response', 'body']) {
        test(`selected native ${stage} ${phase} read receives owner cancellation`, { timeout: 2000 }, async () => {
            const transport = nativeTransport({ heldPath, phase })
            const { loader } = await openNativeLoader(transport)
            const completion = loader.replaceURL(chapter, 'application/xhtml+xml').then(
                value => ({ value }), error => ({ error }),
            )
            try {
                const request = await transport.entered
                assert.equal(loader.destroy(), true)
                assert.equal(loader.destroy(), false)
                transport.release()
                const result = await completion
                assert.equal(request.signal?.aborted, true)
                assert.equal(request.abortEvents, 1)
                assert.equal(request.bodyReads, phase === 'body' ? 1 : 0)
                if (stage === 'chapter') assert.equal(result.error?.name, 'AbortError')
                else assert.deepEqual(result, { value: null })
                assert.equal(await loader.replaceURL(chapter, 'application/xhtml+xml'), null)
                assertSource(transport.requests)
            } finally {
                loader.destroy()
                transport.release()
                await completion
            }
        })
    }
}

test('selected native decoding, source headers and direct route survive signal forwarding', async () => {
    const files = defaultFiles()
    files.set('OPS/latin.txt', { data: new Uint8Array([0xe9]), type: 'text/plain; charset=windows-1252' })
    files.set('OPS/fallback.txt', { data: '日本語', type: 'text/plain; charset=unsupported-encoding' })
    files.set('OPS/audio.mp3', { data: new Uint8Array([1, 2, 3]), type: 'audio/mpeg' })
    const transport = nativeTransport({ files })
    const { loader, modes, replacement } = await openNativeLoader(transport)
    try {
        assert.deepEqual(modes, [false])
        assert.equal(loader.replaceText, replacement)
        assert.equal(await loader.loadText('OPS/latin.txt'), 'é')
        assert.equal(await loader.loadText('OPS/fallback.txt'), '日本語')
        const blob = await loader.loadBlob('OPS/audio.mp3')
        assert.equal(blob.type, 'audio/mpeg')
        assert.deepEqual(new Uint8Array(await blob.arrayBuffer()), new Uint8Array([1, 2, 3]))
        const direct = new URL(await loader.replaceURL(chapter, 'application/xhtml+xml'))
        assert.equal(direct.href.startsWith('ebook://ebook/processed-section?'), true)
        assert.equal(direct.searchParams.get('sourceURL'), sourceURL)
        assert.equal(direct.searchParams.get('subpath'), chapter)
        assert.equal(direct.searchParams.get('direct'), '1')
        assert.equal(direct.searchParams.get('mnbWritingDirection'), 'vertical')
        assert.equal(direct.searchParams.get('mnbWritingMode'), 'vertical-lr')
        const directionRequests = transport.requests.filter(request => [chapter, stylesheet, importedStylesheet].includes(request.path))
        assert.equal(directionRequests.length, 3)
        assert.ok(directionRequests[0].signal instanceof AbortSignal)
        assert.ok(directionRequests.every(request => request.signal === directionRequests[0].signal))
        assert.ok(directionRequests.every(request => !request.signal.aborted))
        assertSource(transport.requests)
    } finally { loader.destroy() }
})

test('selected cache warmer keeps ordinary text and blob access without direct section work', async () => {
    const transport = nativeTransport()
    const { loader, modes, replacement } = await openNativeLoader(transport, { warmer: true })
    assert.deepEqual(modes, [true])
    assert.equal(loader.replaceURL, null)
    assert.equal(loader.replaceText, replacement)
    assert.equal(await loader.loadText(chapter), html)
    assert.equal(await (await loader.loadBlob(chapter)).text(), html)
    assert.equal(loader.getSize(chapter), new TextEncoder().encode(html).byteLength)
    const count = transport.requests.length
    assert.equal(await loader.loadText('absent.xhtml'), null)
    assert.equal(transport.requests.length, count)
    assertSource(transport.requests)
    assert.equal(loader.destroy(), true)
    assert.equal(loader.destroy(), false)
    assert.equal(await loader.loadText(chapter), null)
    assert.equal(await loader.loadBlob(chapter), null)
    assert.equal(loader.getSize(chapter), 0)
    assert.deepEqual(loader.entries, [])
    assert.equal(transport.requests.length, count)
})

test('concurrent selected direct requests share one abortable direction read', { timeout: 2000 }, async () => {
    const transport = nativeTransport({ heldPath: chapter, phase: 'body' })
    const { loader } = await openNativeLoader(transport)
    const first = loader.replaceURL(chapter, 'application/xhtml+xml')
    const second = loader.replaceURL(chapter, 'application/xhtml+xml')
    const completion = Promise.allSettled([first, second])
    try {
        const request = await transport.entered
        loader.destroy()
        transport.release()
        const results = await completion
        assert.equal(transport.requests.filter(request => request.path === chapter).length, 1)
        assert.equal(request.abortEvents, 1)
        assert.deepEqual(results.map(result => [result.status, result.reason?.name]), [
            ['rejected', 'AbortError'], ['rejected', 'AbortError'],
        ])
    } finally {
        loader.destroy()
        transport.release()
        await completion
    }
})
