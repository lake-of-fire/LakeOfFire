import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import vm from 'node:vm'

import { createOwnedAsyncCache } from '../../Sources/LakeOfFireReader/Resources/foliate-js/owned-async-cache.js'
import { ebookProcessTextResponseIsAuthoritative } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-process-text-response.js'

const viewerURL = new URL('../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-viewer.js', import.meta.url)
const viewerSource = await readFile(viewerURL, 'utf8')

// Execute the actual viewer declarations, including its owner, preceding-section
// wait, request/response policy and HTML publication. The complete viewer also
// installs the browser UI; this controlled transport fixture does not mount it.
// Source boundaries only select executable declarations. Assertions below inspect
// runtime results and effects, never implementation text or a copied state machine.
const declarationBlock = (start, end) => {
    const startIndex = viewerSource.indexOf(start)
    const endIndex = viewerSource.indexOf(end, startIndex + start.length)
    if (startIndex < 0 || endIndex < 0) throw new Error(`Missing viewer fixture boundary: ${start}`)
    return viewerSource.slice(startIndex, endIndex)
}

const viewerDeclarations = [
    declarationBlock('const REPLACE_TEXT_RESULT_CACHE_LIMIT =', 'const debounce ='),
    declarationBlock('const firstLiveSectionHref =', 'const nextLinearSectionIndexAfterHref ='),
    declarationBlock('const ensureCacheWarmerPrecedingSectionsForHref =', 'const activeForegroundSectionHrefSet ='),
    declarationBlock('const normalizeSpineHref =', 'const setNativeHideNavigationState ='),
].join('\n')

const deferred = () => {
    let resolve, reject
    const promise = new Promise((yes, no) => { resolve = yes; reject = no })
    return { promise, resolve, reject }
}

const response = (html = '<html><body><m-s>processed</m-s></body></html>', {
    authoritative = true,
    ok = true,
    status = 200,
    read = async () => html,
} = {}) => ({
    ok,
    status,
    headers: { get: name => name === 'x-manabi-processing-authoritative' ? String(authoritative) : null },
    text: read,
})

const makeViewer = ({ transport = () => response(), preceding = null } = {}) => {
    const requests = [], published = [], errors = [], scheduling = []
    const location = { href: 'ebook://book/current' }
    const context = {
        createOwnedAsyncCache,
        ebookProcessTextResponseIsAuthoritative,
        console: { error: (...arguments_) => errors.push(arguments_) },
        fetch: async (url, options) => {
            requests.push({ url, options })
            return transport(options, requests.length)
        },
        reader: {
            view: {
                ownerDocument: { defaultView: { top: { location } } },
                book: { sections: [{ href: 'previous.xhtml' }, { href: 'chapter.xhtml' }] },
            },
        },
        top: { location },
        cacheWarmer: preceding && {
            openRequested: false,
            arePrecedingSectionsComplete: () => false,
            waitForPrecedingSections: index => {
                scheduling.push(['wait', index])
                return preceding.promise
            },
        },
        scheduleDeferredCacheWarmerOpen: (...arguments_) => scheduling.push(['open', ...arguments_]),
        scheduleLoadNextCacheWarmerSection: () => scheduling.push(['advance']),
        maybeOpenDeferredCacheWarmer: () => scheduling.push(['deferred-open']),
        manabi_recordLiveProcessedSection: href => published.push(href),
    }
    context.window = context
    const api = vm.runInNewContext(`${viewerDeclarations}\n({
        makeReplaceText,
        beginReplaceTextCacheGeneration,
    })`, context, { filename: viewerURL.pathname, timeout: 1_000 })
    return { api, context, requests, published, errors, scheduling }
}

const original = '<html><body>original</body></html>'
const mediaType = 'application/xhtml+xml'
const replace = (handler, href = 'chapter.xhtml', text = original) => handler(href, text, mediaType)

const assertIdle = viewer => {
    assert.equal(viewer.context.__manabiInflightReplaceTextCount ?? 0, 0)
    assert.equal(viewer.context.__manabiInflightLiveReplaceTextCount ?? 0, 0)
    assert.equal(viewer.context.__manabiInflightCacheWarmerReplaceTextCount ?? 0, 0)
}

test('live callers share authoritative processing with the selected native request and result contract', async () => {
    const viewer = makeViewer()
    const handler = viewer.api.makeReplaceText(false)
    const [first, follower] = await Promise.all([replace(handler), replace(handler)])

    assert.equal(first, follower)
    assert.match(first, /data-mnb-source-href="chapter.xhtml"/)
    assert.match(first, /data-mnb-has-sentences="true"/)
    assert.equal(await replace(handler), first)
    assert.equal(viewer.requests.length, 1)
    const { url, options } = viewer.requests[0]
    assert.equal(url, 'ebook://ebook/process-text')
    assert.equal(options.method, 'POST')
    assert.equal(options.mode, 'cors')
    assert.equal(options.cache, 'no-cache')
    assert.equal(options.headers['Content-Type'], mediaType)
    assert.equal(options.headers['X-Replaced-Text-Location'], 'chapter.xhtml')
    assert.equal(options.headers['X-Content-Location'], 'ebook://book/current')
    assert.equal(options.headers['X-Is-Cache-Warmer'], undefined)
    assert.equal(options.body, original)
    assert.equal(options.signal.aborted, false)
    assert.deepEqual(viewer.published, ['chapter.xhtml', 'chapter.xhtml', 'chapter.xhtml'])
    assertIdle(viewer)
})

test('processing keys preserve text, chapter and live versus warmer isolation', async () => {
    const viewer = makeViewer()
    const live = viewer.api.makeReplaceText(false)
    const warmer = viewer.api.makeReplaceText(true)
    const liveResult = await replace(live)
    const warmerResult = await replace(warmer)
    assert.notEqual(liveResult, warmerResult)
    assert.match(warmerResult, /data-is-cache-warmer="true"/)
    assert.equal(viewer.requests[1].options.headers['X-Is-Cache-Warmer'], 'true')
    await replace(live, 'other.xhtml')
    await replace(live, 'chapter.xhtml', '<html><body>changed</body></html>')
    assert.equal(viewer.requests.length, 4)
    assert.equal(await replace(live), liveResult)
    assert.equal(await replace(warmer), warmerResult)
    assert.equal(viewer.requests.length, 4)
    assertIdle(viewer)
})

for (const failure of ['network', 'HTTP', 'non-authoritative']) {
    test(`${failure} processing remains retryable before an authoritative result is retained`, async () => {
        const viewer = makeViewer({ transport: (_options, attempt) => {
            if (attempt > 1) return response()
            if (failure === 'network') throw new Error('transient native transport')
            if (failure === 'HTTP') return response('', { ok: false, status: 503 })
            return response(original, { authoritative: false })
        } })
        const handler = viewer.api.makeReplaceText(true)
        const first = await replace(handler)
        if (failure !== 'non-authoritative') assert.equal(first, original)
        const retry = await replace(handler)
        assert.notEqual(retry, first)
        assert.equal(await replace(handler), retry)
        assert.equal(viewer.requests.length, 2)
        assert.equal(viewer.errors.length, failure === 'non-authoritative' ? 0 : 1)
        assertIdle(viewer)
    })
}

test('an empty warmer response remains a non-retained escaped placeholder', async () => {
    const viewer = makeViewer({ transport: () => response('') })
    const handler = viewer.api.makeReplaceText(true)
    const first = await replace(handler, 'chapter&".xhtml')
    assert.equal(first, '<html><body data-is-cache-warmer="true" data-mnb-source-href="chapter&amp;&quot;.xhtml"></body></html>')
    assert.equal(await replace(handler, 'chapter&".xhtml'), first)
    assert.equal(viewer.requests.length, 2)
    assertIdle(viewer)
})

test('retiring queued warmer processing settles original callers without starting native work', async () => {
    const viewer = makeViewer()
    const retired = viewer.api.makeReplaceText(true)
    const settled = Promise.allSettled([replace(retired), replace(retired)])
    viewer.api.beginReplaceTextCacheGeneration()
    const replacement = viewer.api.makeReplaceText(true)
    const fresh = await replace(replacement)
    const results = await settled

    assert.deepEqual(results, [
        { status: 'fulfilled', value: original },
        { status: 'fulfilled', value: original },
    ])
    assert.notEqual(fresh, original)
    assert.equal(await replace(replacement), fresh)
    assert.equal(viewer.requests.length, 1)
    assert.equal(viewer.requests[0].options.signal.aborted, false)
    assert.deepEqual(viewer.published, [])
    assert.deepEqual(viewer.errors, [])
    assertIdle(viewer)
})

test('retiring live work between admission and its factory microtask returns original text', async () => {
    const viewer = makeViewer()
    const retired = viewer.api.makeReplaceText(false)
    const settled = Promise.allSettled([replace(retired)])
    // The live caller first resumes its preceding-section await and admits the
    // cache entry; this normal microtask retires it before the factory runs.
    queueMicrotask(viewer.api.beginReplaceTextCacheGeneration)
    assert.deepEqual(await settled, [{ status: 'fulfilled', value: original }])
    assert.equal(viewer.requests.length, 0)
    assert.deepEqual(viewer.published, [])
    assert.deepEqual(viewer.errors, [])
    assertIdle(viewer)
})

test('a live owner retired during preceding-section warming cannot admit a new native request', async () => {
    const preceding = deferred()
    const viewer = makeViewer({ preceding })
    const retired = viewer.api.makeReplaceText(false)
    const pending = replace(retired)
    assert.deepEqual(viewer.scheduling[0], ['wait', 1])
    viewer.api.beginReplaceTextCacheGeneration()
    preceding.resolve()

    assert.equal(await pending, original)
    assert.equal(viewer.requests.length, 0)
    assert.deepEqual(viewer.published, [])
    assert.equal(viewer.context.__manabiFirstLiveSectionHref, undefined)
    assertIdle(viewer)
})

test('retirement aborts running native work and leaves replacement processing usable', async () => {
    const started = deferred()
    const viewer = makeViewer({ transport: (options, attempt) => {
        if (attempt > 1) return response()
        return new Promise((_resolve, reject) => {
            options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true })
            started.resolve()
        })
    } })
    const pending = replace(viewer.api.makeReplaceText(true))
    await started.promise
    viewer.api.beginReplaceTextCacheGeneration()
    const replacement = viewer.api.makeReplaceText(true)
    const fresh = await replace(replacement)

    assert.equal(await pending, original)
    assert.equal(viewer.requests[0].options.signal.aborted, true)
    assert.equal(viewer.requests[1].options.signal.aborted, false)
    assert.equal(await replace(replacement), fresh)
    assert.equal(viewer.requests.length, 2)
    assert.deepEqual(viewer.errors, [])
    assertIdle(viewer)
})

test('late native success after retirement cannot read or retain stale processed HTML', async () => {
    const started = deferred(), oldResponse = deferred()
    let staleReads = 0
    const viewer = makeViewer({ transport: (_options, attempt) => {
        if (attempt > 1) return response()
        started.resolve()
        return oldResponse.promise
    } })
    const pending = replace(viewer.api.makeReplaceText(true))
    await started.promise
    viewer.api.beginReplaceTextCacheGeneration()
    const replacement = viewer.api.makeReplaceText(true)
    const fresh = await replace(replacement)
    oldResponse.resolve(response('stale', { read: async () => { staleReads++; return 'stale' } }))

    assert.equal(await pending, original)
    assert.equal(staleReads, 0)
    assert.equal(await replace(replacement), fresh)
    assert.equal(viewer.requests.length, 2)
    assert.equal(viewer.requests[0].options.signal.aborted, true)
    assertIdle(viewer)
})

test('retirement during response decoding suppresses late live publication', async () => {
    const decoding = deferred(), oldBody = deferred()
    const viewer = makeViewer({ transport: (_options, attempt) => {
        if (attempt > 1) return response()
        return response('', { read: () => { decoding.resolve(); return oldBody.promise } })
    } })
    const pending = replace(viewer.api.makeReplaceText(false))
    await decoding.promise
    viewer.api.beginReplaceTextCacheGeneration()
    const replacement = viewer.api.makeReplaceText(false)
    const fresh = await replace(replacement)
    oldBody.resolve('<html><body><m-s>stale</m-s></body></html>')

    assert.equal(await pending, original)
    assert.deepEqual(viewer.published, ['chapter.xhtml'])
    assert.equal(await replace(replacement), fresh)
    assert.equal(viewer.requests.length, 2)
    assertIdle(viewer)
})

test('retired callbacks and unsupported media bypass processing', async () => {
    const viewer = makeViewer()
    const retired = viewer.api.makeReplaceText(false)
    viewer.api.beginReplaceTextCacheGeneration()
    assert.equal(await replace(retired), original)
    const current = viewer.api.makeReplaceText(false)
    assert.equal(await current('image.svg', '<svg/>', 'image/svg+xml'), '<svg/>')
    assert.equal(viewer.requests.length, 0)
    assert.deepEqual(viewer.published, [])
    assertIdle(viewer)
})
