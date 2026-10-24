import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import { createNativeMarkReadRequestCoordinator } from '../../Sources/LakeOfFireReader/Resources/foliate-js/native-mark-read-request.js'

// Run the shipping Reader class and its real native request coordinator. The
// module-startup adapter and DOM/native collaborators are the only substitutes.
const source = readFileSync(process.env.READER_SOURCE_PATH || new URL(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-viewer.js', import.meta.url
), 'utf8')
const classStart = source.indexOf('class Reader {')
const classEnd = source.indexOf('\n}\n', classStart) + 2
const payloadHelpers = source.slice(source.indexOf('const nativeMarkReadPayloadLimits'),
    source.indexOf('const ignoredWindowErrorMessages'))

function fixture() {
    const requests = [], packets = [], errors = [], moves = [], timers = new Map()
    const attributes = new Map()
    let timerID = 0, requestID = 0
    const makeDocument = () => ({
        URL: 'ebook://fixture/chapter.xhtml', sidecarRevision: 'sidecar-a',
        body: {}, defaultView: {}, sentences: [{ id: 'current-page' }],
        querySelectorAll(selector) { return selector === 'm-s' ? this.sentences : [] },
    })
    let doc = makeDocument()
    const initialDocument = doc
    const schedule = (callback, delay) => {
        const id = ++timerID
        timers.set(id, { callback, delay })
        return id
    }
    class Element {}
    class Bindings {
        listen() {}
        bind(target, key, value) { target[key] = value }
        clear() {}
    }
    const context = vm.createContext({
        console: { ...console, error: (...args) => errors.push(args) },
        Map, Set, Promise, TextEncoder, HTMLElement: Element, Element,
        performance: { now: () => 0 }, performanceNowMs: () => 0,
        document: {
            body: { dataset: {}, setAttribute: (key, value) => attributes.set(key, value),
                classList: { contains: () => false, toggle() {}, remove() {} } },
            getElementById: () => null, querySelector: () => null,
        },
        screen: { orientation: {} }, $: () => null,
        normalizeArticleReadingProgress: value => ({
            readSegmentIdentifiers: [], sentenceIdentifiersRead: [], ...value,
        }),
        OwnedEventBindings: Bindings, OwnedEventBindingScopes: Bindings,
        OwnedObjectURL: class { clear() {} },
        DeferredOpenWorkCoordinator: class { cancel() {} },
        EbookRenderReadinessCoordinator: class { begin() {} },
        debounce: callback => callback, applyStoredChromeInsets() {},
        NavigationHUD: class { refreshAuxiliaryLayout() {} },
        createNativeMarkReadRequestCoordinator: options => createNativeMarkReadRequestCoordinator({
            ...options, makeRequestID: () => `request-${++requestID}`,
            scheduleTimeout: schedule, cancelTimeout: id => timers.delete(id),
        }),
        stableEbookSegmentIdentityVersion: 1,
        isDocumentLike: value => !!value?.querySelectorAll,
        segmentIdentifierForNode: node => node.id,
        sentenceIdentifierForNode: node => node.id,
        ebookSegmentSidecarRevision: value => value.sidecarRevision,
        getPrimaryRendererContent: renderer => renderer?.getContents?.()[0] ?? null,
        getCurrentRendererDocument: renderer => renderer?.getContents?.()[0]?.doc ?? null,
        ignoreNextIncomingHideNavigation() {}, ignoreNextIncomingRevealNavigation() {},
        MANABI_ENABLE_EBOOK_PAGE_TRACKING_BUTTONS: false,
        setTimeout: schedule, clearTimeout: id => timers.delete(id),
        requestAnimationFrame: callback => schedule(callback, 'frame'),
        cancelAnimationFrame: id => timers.delete(id),
    })
    context.window = context
    context.top = context
    context.location = { href: 'ebook://fixture/book.epub' }
    context.webkit = { messageHandlers: {
        markSectionAsRead: { postMessage: message => requests.push(message) },
        ebookNativeMarkReadState: { postMessage: packet => packets.push(packet) },
        nativeLookupHitTargetsUpdated: { postMessage() {} },
    } }
    const Reader = vm.runInContext(`${payloadHelpers}\n${source.slice(classStart, classEnd)}\nReader`, context)
    const reader = new Reader()
    context.reader = reader
    const renderer = () => ({ getContents: () => [{ doc }] })
    reader.view = { renderer: renderer(),
        goRight: async () => { moves.push('right'); return true },
        goLeft: async () => { moves.push('left'); return true } }
    // A collapsed range keeps optional geometry refresh queued while the test
    // drives only the command, publication, and delayed navigation boundaries.
    reader.navHUD.lastRelocateDetail = { range: {
        collapsed: true, commonAncestorContainer: { ownerDocument: doc },
    } }
    reader.pageTrackingStates = [{ id: 'visible-screen', isRead: false,
        payload: { stableIdentityVersion: 1, segments: [], sentenceIdentifiers: ['current-page'] } }]
    const start = (kind = 'page') => {
        const operation = kind === 'all' ? reader.markAllSectionsAsRead() : reader.markVisiblePageAsRead()
        return operation.then(value => ({ value }), error => ({ error }))
    }
    const deliver = (index = 0, extra = {}) => reader.applyMarkSectionAsReadResult({
        requestID: requests[index].requestID, sectionId: requests[index].sectionId,
        success: true, ...extra,
    })
    const flush = () => new Promise(resolve => setImmediate(resolve))
    const finish = async completion => {
        await flush()
        for (const [id, timer] of [...timers]) {
            if (timer.delay === 430) { timers.delete(id); timer.callback() }
        }
        return await completion
    }
    const replace = kind => {
        if (kind === 'reader') context.reader = { isClosed: false }
        else if (kind === 'renderer') reader.view.renderer = renderer()
        else if (kind === 'document') doc = makeDocument()
        else if (kind === 'sidecar') doc.sidecarRevision = 'sidecar-b'
        else if (kind === 'visible generation') reader.visiblePageCollectionGeneration += 1
        else if (kind === 'closed reader') reader.close('test-replacement')
    }
    return { reader, requests, packets, errors, moves, timers, attributes, context,
        initialDocument, start, deliver, finish, flush, replace }
}

for (const oldSuccess of [false, true]) {
    test(`Mark All owns projection after an older page reply (${oldSuccess})`, async () => {
        const f = fixture(), page = f.start(), all = f.start('all')
        assert.equal(f.requests.length, 2)
        assert.equal(f.deliver(1), true)
        assert.equal((await f.finish(all)).value, 1)
        const packetCount = f.packets.length
        assert.equal(f.deliver(0, { success: oldSuccess, errorCode: oldSuccess ? null : 'oldFailure' }), true)
        assert.equal((await f.finish(page)).value, oldSuccess)
        assert.equal(f.reader.lastNativeMarkReadRequestOutcome, 'committed')
        assert.equal(f.reader.lastNativeMarkReadRequestErrorCode, '')
        assert.deepEqual(Array.from(f.reader.optimisticSentenceIdentifiersRead), ['current-page'])
        assert.deepEqual(f.moves, [])
        assert.equal(f.reader.pageTrackingBusyStateIDs.size, 0)
        assert.equal(f.packets.slice(packetCount).every(packet => packet.requestOutcome === 'committed'), true)
        assert.equal(f.reader.nativeMarkReadRequestCoordinator.pendingCount, 0)
    })
}

for (const transition of ['close', 'document URL']) {
    test(`${transition} during the settled page delay suppresses navigation`, async () => {
        const f = fixture(), page = f.start()
        assert.equal(f.deliver(), true)
        await f.flush()
        const advance = [...f.timers.entries()].find(([, timer]) => timer.delay === 430)
        assert.ok(advance)
        if (transition === 'close') f.reader.close('during-settled-advance')
        else f.initialDocument.URL = 'ebook://fixture/another.xhtml'
        const packetCount = f.packets.length
        f.timers.delete(advance[0])
        advance[1].callback()
        assert.equal((await page).value, true)
        assert.deepEqual(f.moves, [])
        assert.equal(f.packets.length, packetCount)
        assert.equal(f.reader.pageTrackingBusyStateIDs.size, 0)
    })
}

test('a newer invalid page command retires an already scheduled advance', async () => {
    const f = fixture(), first = f.start()
    assert.equal(f.deliver(), true)
    await f.flush()
    assert.ok([...f.timers.values()].some(timer => timer.delay === 430))
    f.reader.pageTrackingStates[0].payload.stableIdentityVersion = 99
    assert.equal((await f.finish(f.start())).value, false)
    assert.equal((await first).value, true)
    assert.equal(f.requests.length, 1)
    assert.equal(f.reader.lastNativeMarkReadRequestOutcome, 'failed')
    assert.equal(f.reader.lastNativeMarkReadRequestErrorCode, 'invalidPayload')
    assert.equal(f.reader.pageTrackingBusyStateIDs.size, 0)
    assert.deepEqual(f.moves, [])
})

test('Mark All during a scheduled page advance keeps its pending outcome', async () => {
    const f = fixture(), page = f.start()
    assert.equal(f.deliver(), true)
    await f.flush()
    const all = f.start('all')
    assert.equal((await f.finish(page)).value, true)
    assert.equal(f.reader.lastNativeMarkReadRequestOutcome, 'pending')
    assert.deepEqual(f.moves, [])
    assert.equal(f.deliver(1, { success: false, errorCode: 'allRejected' }), true)
    assert.equal((await f.finish(all)).value, 0)
    assert.equal(f.reader.lastNativeMarkReadRequestOutcome, 'failed')
    assert.equal(f.reader.lastNativeMarkReadRequestErrorCode, 'allRejected')
    assert.deepEqual(Array.from(f.reader.optimisticSentenceIdentifiersRead), ['current-page'])
    assert.equal(f.reader.nativeMarkReadRequestCoordinator.pendingCount, 0)
})
