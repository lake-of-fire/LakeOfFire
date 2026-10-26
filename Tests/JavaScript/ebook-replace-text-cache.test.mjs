import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import vm from 'node:vm'

const resources = new URL('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/', import.meta.url)
const cacheSource = await readFile(new URL('owned-async-cache.js', resources), 'utf8')
const { createOwnedAsyncCache } = await import(`data:text/javascript;base64,${Buffer.from(cacheSource).toString('base64')}`)
const viewerURL = new URL('ebook-viewer.js', resources)
const viewerSource = await readFile(viewerURL, 'utf8')

// Select shipping declarations without importing the browser bootstrap. Assertions
// exercise results, native request options and publication, never source spelling.
const declaration = (start, end) => {
    const first = viewerSource.indexOf(start)
    const last = viewerSource.indexOf(end, first + start.length)
    if (first < 0 || last < 0) throw new Error(`Missing viewer fixture boundary: ${start}`)
    return viewerSource.slice(first, last)
}
const declarations = [
    declaration('const REPLACE_TEXT_RESULT_CACHE_LIMIT =', 'const resolveEpubRelativePath ='),
    declaration('const firstLiveSectionHref =', 'window.manabi_recordLiveProcessedSection ='),
    declaration('const normalizeSpineHref =', 'const setNativeHideNavigationState ='),
].join('\n')

const deferred = () => {
    let resolve
    const promise = new Promise(yes => { resolve = yes })
    return { promise, resolve }
}
const startedWithinTurn = promise => Promise.race([
    promise,
    new Promise((_resolve, reject) => setImmediate(() => reject(new Error('Expected native processing to start by the next event-loop turn')))),
])
const original = '<html><body>original</body></html>'
const processed = '<html><body><m-s><m-m>processed</m-m></m-s></body></html>'
const sourceURL = 'ebook://book/source.epub'
const response = ({ html = processed, authoritative = true, read = async () => html, ok = true } = {}) => ({
    ok,
    status: ok ? 200 : 503,
    headers: { get: name => name === 'x-manabi-processing-authoritative' ? String(authoritative) : null },
    text: read,
})
const makeViewer = (transport = async () => response()) => {
    const requests = [], published = [], errors = []
    const context = {
        createOwnedAsyncCache,
        performanceNowMs: () => 0,
        nextEbookLoadRequestID: () => 'request',
        manabiTimelineMark: () => {},
        manabiTimelineMeasure: () => {},
        console: { error: (...args) => errors.push(args) },
        fetch: (url, options) => {
            requests.push({ url, options })
            return transport(options, requests.length)
        },
        manabi_recordLiveProcessedSection: href => published.push(href),
    }
    context.window = context
    const { makeReplaceText } = vm.runInNewContext(`${declarations}\n({ makeReplaceText })`, context, { filename: viewerURL.pathname, timeout: 1000 })
    const makeOwner = (options = {}) => makeReplaceText({ nativeSource: { url: sourceURL, packageSessionID: 'session' }, ...options })
    return { context, requests, published, errors, makeOwner }
}
const replace = owner => owner('chapter.xhtml', original, 'application/xhtml+xml')
const assertIdle = viewer => {
    assert.equal(viewer.context.__manabiInflightReplaceTextCount ?? 0, 0)
    assert.equal(viewer.context.__manabiInflightLiveReplaceTextCount ?? 0, 0)
}

test('current loader coalesces and retains authoritative processed-section GET results', async () => {
    const viewer = makeViewer()
    const owner = viewer.makeOwner()
    const [first, follower] = await Promise.all([replace(owner), replace(owner)])
    assert.equal(first, follower)
    assert.match(first, /data-mnb-source-href="chapter.xhtml"/)
    assert.match(first, /data-mnb-has-sentences="true"/)
    assert.match(first, /data-mnb-has-segments="true"/)
    assert.equal(await replace(owner), first)
    assert.equal(viewer.requests.length, 1)
    const { url, options } = viewer.requests[0]
    assert.equal(new URL(url).pathname, '/processed-section')
    assert.equal(new URL(url).searchParams.get('sourceURL'), sourceURL)
    assert.equal(new URL(url).searchParams.get('subpath'), 'chapter.xhtml')
    assert.equal(new URL(url).searchParams.get('packageSessionID'), 'session')
    assert.equal(options.method, 'GET')
    assert.equal(options.headers['X-Ebook-Package-Session'], 'session')
    assert.equal(options.headers['X-Content-Location'], sourceURL)
    assert.equal(options.body, undefined)
    assert.equal(options.signal.aborted, false)
    assert.deepEqual(viewer.published, ['chapter.xhtml', 'chapter.xhtml', 'chapter.xhtml'])
    assertIdle(viewer)
})

test('destroy before the factory microtask settles every waiter without native work and isolates a successor', async () => {
    const viewer = makeViewer()
    const owner = viewer.makeOwner()
    const settled = Promise.allSettled([replace(owner), replace(owner)])
    assert.equal(owner.destroy(), true)
    assert.equal(owner.destroy(), false)
    const successor = viewer.makeOwner()
    const fresh = await replace(successor)
    const results = await settled
    assert.deepEqual(results, [{ status: 'fulfilled', value: null }, { status: 'fulfilled', value: null }])
    assert.notEqual(fresh, original)
    assert.equal(await replace(successor), fresh)
    assert.equal(await replace(owner), null)
    assert.equal(viewer.requests.length, 1)
    assert.deepEqual(viewer.errors, [])
    assert.deepEqual(viewer.published, ['chapter.xhtml', 'chapter.xhtml'])
    assertIdle(viewer)
})

for (const abortAware of [true, false]) {
    test(`destroy fences running ${abortAware ? 'abort-aware' : 'abort-ignoring'} processing and preserves a successor`, async () => {
        const started = deferred(), finishOld = deferred()
        let oldReads = 0
        const viewer = makeViewer((options, attempt) => {
            if (attempt > 1) return response()
            started.resolve()
            if (!abortAware) return finishOld.promise
            return new Promise((resolve, reject) => {
                options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true })
                finishOld.promise.then(resolve, reject)
            })
        })
        const owner = viewer.makeOwner()
        const pending = replace(owner)
        await startedWithinTurn(started.promise)
        owner.destroy()
        const successor = viewer.makeOwner()
        const freshPending = replace(successor)
        // Always release and join pending work before assertions.
        finishOld.resolve(response({ read: async () => { oldReads++; return processed } }))
        const [old, fresh] = await Promise.all([pending, freshPending])
        assert.equal(old, null)
        assert.equal(oldReads, 0)
        assert.equal(viewer.requests[0].options.signal.aborted, true)
        assert.equal(viewer.requests[1].options.signal.aborted, false)
        assert.equal(await replace(successor), fresh)
        assert.equal(viewer.requests.length, 2)
        assert.deepEqual(viewer.errors, [])
        assert.deepEqual(viewer.published, ['chapter.xhtml', 'chapter.xhtml'])
        assertIdle(viewer)
    })
}

test('destroy during response decoding suppresses late HTML and publication without poisoning the next owner', async () => {
    const decoding = deferred(), decoded = deferred()
    const viewer = makeViewer((_options, attempt) => response(attempt === 1 ? { read: () => { decoding.resolve(); return decoded.promise } } : {}))
    const owner = viewer.makeOwner()
    const pending = replace(owner)
    await startedWithinTurn(decoding.promise)
    owner.destroy()
    const successor = viewer.makeOwner()
    const freshPending = replace(successor)
    decoded.resolve(processed)
    const [old, fresh] = await Promise.all([pending, freshPending])
    assert.equal(old, null)
    assert.equal(await replace(successor), fresh)
    assert.equal(viewer.requests.length, 2)
    assert.deepEqual(viewer.published, ['chapter.xhtml', 'chapter.xhtml'])
    assert.deepEqual(viewer.errors, [])
    assertIdle(viewer)
})

for (const failure of ['network', 'HTTP', 'non-authoritative']) {
    test(`${failure} current-owner results remain retryable before authoritative retention`, async () => {
        const viewer = makeViewer((_options, attempt) => {
            if (attempt > 1) return response()
            if (failure === 'network') throw new Error('transient')
            return response(failure === 'HTTP' ? { ok: false } : { html: original, authoritative: false })
        })
        const owner = viewer.makeOwner()
        const fallback = await replace(owner)
        const fresh = await replace(owner)
        assert.notEqual(fresh, fallback)
        assert.equal(await replace(owner), fresh)
        assert.equal(viewer.requests.length, 2)
        assert.equal(viewer.errors.length, failure === 'non-authoritative' ? 0 : 1)
        assertIdle(viewer)
    })
}

test('native direct-section owners reject foreground HTML while unsupported media bypasses processing', async () => {
    const viewer = makeViewer()
    const owner = viewer.makeOwner({ allowForegroundHTML: false })
    await assert.rejects(replace(owner), /must load through processed-section direct URL/)
    assert.equal(await owner('style.css', 'body {}', 'text/css'), 'body {}')
    owner.destroy()
    assert.equal(await replace(owner), null)
    assert.equal(viewer.requests.length, 0)
    assert.deepEqual(viewer.published, [])
    assertIdle(viewer)
})

test('load-session retirement without destroy fences a late decode and a successor still processes', async () => {
    const decoding = deferred(), decoded = deferred()
    let current = true
    const viewer = makeViewer((_options, attempt) => response(attempt === 1 ? { read: () => { decoding.resolve(); return decoded.promise } } : {}))
    const owner = viewer.makeOwner({ isCurrent: () => current })
    const pending = replace(owner)
    await startedWithinTurn(decoding.promise)
    current = false
    const successor = viewer.makeOwner()
    const freshPending = replace(successor)
    decoded.resolve(processed)
    const [old, fresh] = await Promise.all([pending, freshPending])
    assert.equal(old, null)
    assert.equal(await replace(owner), null)
    assert.equal(await replace(successor), fresh)
    assert.equal(viewer.requests.length, 2)
    assert.deepEqual(viewer.published, ['chapter.xhtml', 'chapter.xhtml'])
    assert.deepEqual(viewer.errors, [])
    assertIdle(viewer)
    owner.destroy()
    successor.destroy()
})
