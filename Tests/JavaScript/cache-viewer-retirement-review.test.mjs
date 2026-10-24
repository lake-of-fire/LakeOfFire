import { CacheWarmerPrecedingSections } from '../../Sources/LakeOfFireReader/Resources/foliate-js/cache-warmer-preceding-sections.js'
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


test('review: a follower admitted from retention receives the same thrown settlement', async () => {
    const failure = new Error('retention refused publication')
    let follower
    let cache
    cache = createOwnedAsyncCache({ shouldRemember() {
        follower = cache.getOrCreate('chapter', () => 'unexpected replacement')
        throw failure
    } })
    const first = cache.getOrCreate('chapter', () => 'factory result')
    const firstResult = await Promise.allSettled([first])
    const followerResult = await Promise.allSettled([follower])
    assert.equal(firstResult[0].status, 'rejected')
    assert.equal(followerResult[0].status, 'rejected')
    assert.equal(firstResult[0].reason, failure)
    assert.equal(followerResult[0].reason, failure)
})

test('review: a throwing retention callback cannot remove its reentrant replacement', async () => {
    const failure = new Error('retired result cannot be retained')
    const next = deferred()
    let replacement
    let cache
    cache = createOwnedAsyncCache({ shouldRemember(value) {
        if (value === 'old') {
            cache.clear()
            replacement = cache.getOrCreate('chapter', () => next.promise)
            throw failure
        }
        return true
    } })
    const first = cache.getOrCreate('chapter', () => 'old')
    const follower = cache.getOrCreate('chapter', () => 'unexpected')
    const oldResults = await Promise.allSettled([first, follower])
    const successorFollower = cache.getOrCreate('chapter', () => 'unexpected successor')
    next.resolve('current')
    const successorResults = await Promise.all([replacement, successorFollower])
    assert.deepEqual(oldResults.map(value => value.status), ['rejected', 'rejected'])
    assert.ok(oldResults.every(value => value.reason === failure))
    assert.deepEqual(successorResults, ['current', 'current'])
    assert.equal(await cache.getOrCreate('chapter', () => 'unexpected cache miss'), 'current')
})

const attachPrecedingSections = (viewer, preceding) => {
    viewer.context.cacheWarmer = {
        openRequested: false,
        arePrecedingSectionsComplete: index => preceding.isComplete(index),
        waitForPrecedingSections: index => preceding.waitFor(index),
    }
}

test('review: closing the actual preceding-section waiter cannot revive a retired viewer request', async () => {
    const preceding = new CacheWarmerPrecedingSections()
    const viewer = makeViewer()
    attachPrecedingSections(viewer, preceding)
    const retired = viewer.api.makeReplaceText(false)
    const pending = replace(retired)
    assert.equal(preceding.requiredTargetIndex, 1)
    assert.equal(viewer.requests.length, 0)
    viewer.api.beginReplaceTextCacheGeneration()
    assert.equal(preceding.close(), true)
    assert.equal(await pending, original)
    assert.equal(viewer.requests.length, 0)
    assert.deepEqual(viewer.published, [])
    assert.equal(preceding.requiredTargetIndex, null)
    assertIdle(viewer)
})

test('review: actual preceding-section completion admits the current viewer exactly once', async () => {
    const preceding = new CacheWarmerPrecedingSections()
    const viewer = makeViewer()
    attachPrecedingSections(viewer, preceding)
    const current = viewer.api.makeReplaceText(false)
    const pending = replace(current)
    assert.equal(preceding.requiredTargetIndex, 1)
    assert.equal(viewer.requests.length, 0)
    assert.equal(preceding.recordLoadedSection(0), true)
    const processed = await pending
    assert.notEqual(processed, original)
    assert.equal(viewer.requests.length, 1)
    assert.deepEqual(viewer.published, ['chapter.xhtml'])
    assert.equal(await replace(current), processed)
    assert.equal(viewer.requests.length, 1)
    assert.equal(preceding.requiredTargetIndex, null)
    assertIdle(viewer)
})

