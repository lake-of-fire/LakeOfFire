import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import { readerDocumentStartedAtMs } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/reader-document-clock.js'

// Run the shipped viewer callbacks with a recording WebKit bridge and the
// actual document clock. No book renderer is needed for these three routes.
const source = readFileSync(process.env.MANABI_EBOOK_VIEWER_SOURCE || new URL(
    '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-viewer.js', import.meta.url,
), 'utf8')

function viewerRegion(first, next) {
    const start = source.indexOf(first)
    const end = source.indexOf(next, start + first.length)
    if (start < 0 || end < 0) throw new Error(`Cannot load viewer fixture region ${first}`)
    return source.slice(start, end)
}

const callbacks = new vm.Script(`
    ${viewerRegion('const manabiBlankNavigationMoveThreshold =', 'const resetRestoreTransactionGlobals =')}
    ${viewerRegion('const manabiEventScreenPoint =', 'const manabiSegmentSidecarParserVersion =')}
    ${viewerRegion('const requestLookupCloseForPageMotion =', 'const resolveFoliatePaginator =')}
    ${viewerRegion('        let pendingMainDocumentBlankNavigationTouch =', '        const clearPendingMainDocumentBlankNavigationTouch =')}
    ${viewerRegion('            let pendingBlankPointerTap =', "            this.#listenInDocumentScope(scope, doc, 'touchstart', handleBlankPointerTouchStart")}
    ({ requestLookupCloseForPageMotion, postNoElementNavigationTouchStart, postContentDocumentBlankPointerTap,
       handleBlankPointerTouchStart, handleBlankPointerTouchEnd, handleBlankPointerMouseDown })
`)

function fixture(origin) {
    const location = { href: 'ebook://ebook/load/local/book.epub' }
    const document = { location, body: {} }
    const child = { body: {} }
    Object.defineProperty(child, 'manabiDocumentStartedAtMs', { value: 250 })
    const posts = []
    let clockReads = 0
    const window = {
        document,
        performance: { get timeOrigin() { clockReads++; return origin } },
        webkit: { messageHandlers: { touchstartCallbackHandler: { postMessage: payload => posts.push(payload) } } },
    }
    const viewer = callbacks.runInNewContext({
        window, document, doc: child, globalThis: window, readerDocumentStartedAtMs,
        LatestRestoreTransactionCoordinator: class {},
    })
    return {
        viewer, posts, window, document, child,
        setOrigin: value => { origin = value },
        clockReads: () => clockReads,
        replaceDocument: () => { window.document = { location, body: {} } },
    }
}

const blankTap = {
    type: 'mousedown', screenX: 4, screenY: 5,
    target: { nodeType: 1, closest: () => null },
}
const blankTouchStart = { ...blankTap, type: 'touchstart' }
const blankTouchEnd = { ...blankTap, type: 'touchend' }

const callers = {
    'renderer motion': {
        trigger: viewer => viewer.requestLookupCloseForPageMotion('renderer.goTo'),
        expected: { lookupCloseReason: 'renderer.goTo' },
    },
    'viewer blank tap': {
        trigger: (viewer, at, event = blankTap) => viewer.postNoElementNavigationTouchStart(event, 'blank.viewer', at),
        expected: { source: 'blank.viewer', touchstartEventType: 'mousedown', ebookNavigationHidden: false },
    },
    'forwarded iframe blank tap': {
        trigger: (viewer, at, event = blankTap) => viewer.postContentDocumentBlankPointerTap(event, 'blank.iframe', at),
        expected: { source: 'blank.iframe', touchstartEventType: 'mousedown', ebookNavigationHidden: false },
    },
}

for (const [route, { trigger, expected }] of Object.entries(callers)) {
    test(`${route} carries the stable viewer clock and preserves the route payload`, () => {
        const f = fixture(12345)
        trigger(f.viewer, 500)
        f.setOrigin(67890)
        trigger(f.viewer, 90000)
        assert.equal(f.posts.length, 2)
        for (const post of f.posts) {
            assert.equal(post.documentStartedAtMs, 12345)
            assert.equal(post.touchedEntryWithElementId, null)
            assert.equal(post.wasAlreadySelected, false)
            assert.ok(Number.isFinite(post.touchstartAtMs))
            for (const [key, value] of Object.entries(expected)) assert.equal(post[key], value)
        }
        assert.equal(f.clockReads(), 1)
        assert.equal(f.child.manabiDocumentStartedAtMs, 250)
    })

    test(`${route} retained by a replaced document cannot post through the same URL`, () => {
        const f = fixture(12345)
        trigger(f.viewer, 500)
        const oldPostKey = f.child.__manabiLastBlankPointerPostKey
        f.replaceDocument()
        f.setOrigin(67890)
        const successorEcho = { x: 8, y: 9, source: 'successor' }
        f.window.__manabiPendingContentDocumentBlankNavigationEcho = successorEcho
        assert.equal(f.window.document.location.href, f.document.location.href)
        trigger(f.viewer, 600, blankTouchEnd)
        assert.equal(f.window.__manabiPendingContentDocumentBlankNavigationEcho, successorEcho)
        trigger(f.viewer, 700, blankTap)
        assert.equal(f.window.__manabiPendingContentDocumentBlankNavigationEcho, successorEcho)
        assert.equal(f.child.__manabiLastBlankPointerPostKey, oldPostKey)
        assert.equal(f.posts.length, 1)
        assert.equal(f.clockReads(), 1)
        assert.equal(f.window.document.manabiDocumentStartedAtMs, undefined)
    })
}

for (const route of ['viewer blank tap', 'forwarded iframe blank tap']) {
    const { trigger } = callers[route]
    test(`${route} still suppresses the synthetic mouse event after a touch`, () => {
        const f = fixture(12345)
        trigger(f.viewer, 500, blankTouchEnd)
        trigger(f.viewer, 550, blankTap)
        assert.equal(f.posts.length, 1)
        assert.equal(f.posts[0].touchstartEventType, 'touchend')
        trigger(f.viewer, 600, { ...blankTap, screenX: 200 })
        assert.equal(f.posts.length, 2)
        assert.equal(f.posts[1].touchstartEventType, 'mousedown')
    })
}

test('a touch waits for a clock installed later on the same physical document', () => {
    const f = fixture(undefined)
    const { trigger } = callers['viewer blank tap']
    trigger(f.viewer, 500, blankTouchEnd)
    f.setOrigin(67890)
    trigger(f.viewer, 600)
    assert.equal(f.posts.length, 0)
    assert.equal(f.clockReads(), 1)
    Object.defineProperty(f.document, 'manabiDocumentStartedAtMs', { value: 12345 })
    trigger(f.viewer, 700)
    assert.equal(f.posts.length, 1)
    assert.equal(f.posts[0].documentStartedAtMs, 12345)
    assert.equal(f.clockReads(), 1)
})

test('a clockless iframe touch cannot consume its deduplication key or change the echo', () => {
    const f = fixture(undefined)
    const { trigger } = callers['forwarded iframe blank tap']
    const priorEcho = { x: 8, y: 9, source: 'prior' }
    f.window.__manabiPendingContentDocumentBlankNavigationEcho = priorEcho
    trigger(f.viewer, 500, blankTouchEnd)
    assert.equal(f.posts.length, 0)
    assert.equal(f.window.__manabiPendingContentDocumentBlankNavigationEcho, priorEcho)
    assert.equal(f.child.__manabiLastBlankPointerPostKey, undefined)
    Object.defineProperty(f.document, 'manabiDocumentStartedAtMs', { value: 12345 })
    trigger(f.viewer, 500, blankTouchEnd)
    assert.equal(f.posts.length, 1)
    assert.equal(f.posts[0].documentStartedAtMs, 12345)
    assert.equal(f.window.__manabiPendingContentDocumentBlankNavigationEcho.touchstartAtMs, 500)
    assert.equal(f.clockReads(), 1)
})

test('a clockless iframe touch end cannot suppress a real mouse event after clock installation', () => {
    const f = fixture(undefined)
    f.viewer.handleBlankPointerTouchStart(blankTouchStart)
    f.viewer.handleBlankPointerTouchEnd(blankTouchEnd)
    assert.equal(f.posts.length, 0)
    Object.defineProperty(f.document, 'manabiDocumentStartedAtMs', { value: 12345 })
    f.viewer.handleBlankPointerMouseDown(blankTap)
    assert.equal(f.posts.length, 1)
    assert.equal(f.posts[0].touchstartEventType, 'mousedown')
    assert.equal(f.posts[0].documentStartedAtMs, 12345)
})

test('the iframe touch listeners suppress the synthetic mouse event after a valid touch end', () => {
    const f = fixture(12345)
    f.viewer.handleBlankPointerTouchStart(blankTouchStart)
    f.viewer.handleBlankPointerTouchEnd(blankTouchEnd)
    f.viewer.handleBlankPointerMouseDown(blankTap)
    assert.equal(f.posts.length, 1)
    assert.equal(f.posts[0].touchstartEventType, 'touchend')
    assert.equal(f.posts[0].documentStartedAtMs, 12345)
})

test('a retained iframe touch-end listener cannot overwrite a same-URL successor echo', () => {
    const f = fixture(12345)
    f.viewer.handleBlankPointerTouchStart(blankTouchStart)
    f.replaceDocument()
    f.setOrigin(67890)
    const successorEcho = { x: 8, y: 9, source: 'successor' }
    f.window.__manabiPendingContentDocumentBlankNavigationEcho = successorEcho
    f.viewer.handleBlankPointerTouchEnd(blankTouchEnd)
    assert.equal(f.posts.length, 0)
    assert.equal(f.clockReads(), 0)
    assert.equal(f.window.__manabiPendingContentDocumentBlankNavigationEcho, successorEcho)
})

test('the viewer inherits an existing immutable clock without sampling performance', () => {
    const f = fixture(67890)
    Object.defineProperty(f.document, 'manabiDocumentStartedAtMs', { value: 12345 })
    callers['forwarded iframe blank tap'].trigger(f.viewer, 500)
    assert.equal(f.posts.length, 1)
    assert.equal(f.posts[0].documentStartedAtMs, 12345)
    assert.equal(f.clockReads(), 0)
})

test('a malformed or nonpositive clock does not produce a native message', () => {
    const { trigger } = callers['viewer blank tap']
    const malformed = fixture(12345)
    Object.defineProperty(malformed.document, 'manabiDocumentStartedAtMs', { value: 12345, writable: true })
    trigger(malformed.viewer, 500)
    assert.equal(malformed.posts.length, 0)
    for (const origin of [0, -1, NaN, Infinity, '12345']) {
        const f = fixture(origin)
        trigger(f.viewer, 500)
        assert.equal(f.posts.length, 0)
    }
})
