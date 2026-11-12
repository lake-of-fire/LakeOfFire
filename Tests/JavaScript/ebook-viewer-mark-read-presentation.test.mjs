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

for (const kind of ['page', 'all']) {
    for (const transition of ['reader', 'renderer', 'document', 'sidecar', 'closed reader',
        ...(kind === 'page' ? ['visible generation'] : [])]) {
        test(`${kind} keeps settled success without publication after ${transition} replacement`, async () => {
            const f = fixture(), completion = f.start(kind)
            assert.equal(f.requests.length, 1)
            assert.equal(f.deliver(), true)
            // Deliberately replace ownership synchronously after settlement,
            // before the awaited Reader continuation can run.
            f.replace(transition)
            const packetCount = f.packets.length
            const result = await f.finish(completion)
            assert.equal(result.error, undefined)
            assert.equal(result.value, kind === 'all' ? 1 : true)
            assert.deepEqual(Array.from(f.reader.optimisticSentenceIdentifiersRead), [])
            assert.deepEqual(Array.from(f.reader.articleReadingProgress.sentenceIdentifiersRead), [])
            assert.deepEqual(f.moves, [])
            assert.equal(f.packets.length, packetCount, 'Old cleanup must not publish into a successor')
            assert.equal(f.reader.pageTrackingBusyStateIDs.size, 0)
            assert.equal(f.requests.length, 1)
        })
    }
    for (const success of [false, true]) {
        test(`${kind} retains current native ${success ? 'success' : 'failure'} behavior`, async () => {
            const f = fixture(), completion = f.start(kind)
            assert.equal(f.deliver(0, { success, errorCode: success ? null : 'persistenceFailed' }), true)
            const result = await f.finish(completion)
            assert.equal(result.error, undefined)
            assert.equal(result.value, kind === 'all' ? (success ? 1 : 0) : success)
            assert.deepEqual(Array.from(f.reader.articleReadingProgress.sentenceIdentifiersRead),
                success ? ['current-page'] : [])
            assert.deepEqual(f.moves, success && kind === 'page' ? ['right'] : [])
            assert.equal(f.reader.lastNativeMarkReadRequestOutcome, success ? 'committed' : 'failed')
            assert.equal(f.reader.lastNativeMarkReadRequestErrorCode, success ? '' : 'persistenceFailed')
            assert.equal(f.reader.pageTrackingBusyStateIDs.size, 0)
            assert.equal(f.errors.length, 0)
        })
    }
}

for (const success of [false, true]) {
    test(`older ${success ? 'success' : 'failure'} cannot overwrite a newer same-page attempt`, async () => {
        const f = fixture(), first = f.start()
        assert.equal(f.deliver(0, { success, errorCode: success ? null : 'oldFailure' }), true)
        const second = f.start()
        const packetCount = f.packets.length
        const firstResult = await f.finish(first)
        assert.equal(firstResult.error, undefined)
        assert.equal(firstResult.value, success)
        assert.equal(f.reader.lastNativeMarkReadRequestOutcome, 'pending')
        assert.equal(f.reader.lastNativeMarkReadRequestErrorCode, '')
        assert.equal(f.reader.pageTrackingBusyStateIDs.has('visible-screen'), true)
        assert.equal(f.packets.length, packetCount)
        assert.deepEqual(Array.from(f.reader.optimisticSentenceIdentifiersRead), [])
        assert.equal(f.deliver(1), true)
        const secondResult = await f.finish(second)
        assert.equal(secondResult.error, undefined)
        assert.equal(secondResult.value, true)
        assert.equal(f.reader.pageTrackingBusyStateIDs.size, 0)
        assert.deepEqual(f.moves, ['right'])
        assert.equal(f.reader.lastNativeMarkReadRequestOutcome, 'committed')
    })
}

test('newer page attempt keeps its busy flag when the old document finishes', async () => {
    const f = fixture(), first = f.start()
    assert.equal(f.deliver(), true)
    f.replace('document')
    const second = f.start()
    const packetCount = f.packets.length
    const firstResult = await f.finish(first)
    assert.equal(firstResult.error, undefined)
    assert.equal(firstResult.value, true)
    assert.equal(f.reader.pageTrackingBusyStateIDs.has('visible-screen'), true)
    assert.equal(f.reader.lastNativeMarkReadRequestOutcome, 'pending')
    assert.equal(f.packets.length, packetCount)
    assert.equal(f.deliver(1, { success: false, errorCode: 'secondFailed' }), true)
    assert.equal((await f.finish(second)).value, false)
    assert.equal(f.reader.pageTrackingBusyStateIDs.size, 0)
})

test('a newer same-page command retires the older delayed automatic advance', async () => {
    const f = fixture(), first = f.start()
    assert.equal(f.deliver(), true)
    await f.flush()
    const oldAdvance = [...f.timers.entries()].find(([, timer]) => timer.delay === 430)
    assert.ok(oldAdvance)
    const second = f.start()
    f.timers.delete(oldAdvance[0])
    oldAdvance[1].callback()
    const firstResult = await first
    assert.equal(firstResult.error, undefined)
    assert.equal(firstResult.value, true)
    assert.deepEqual(f.moves, [])
    assert.equal(f.reader.pageTrackingBusyStateIDs.has('visible-screen'), true)
    assert.equal(f.reader.lastNativeMarkReadRequestOutcome, 'pending')
    assert.equal(f.deliver(1), true)
    assert.equal((await f.finish(second)).value, true)
    assert.deepEqual(f.moves, ['right'])
})

test('Mark All remains eligible when only visible-page geometry changes', async () => {
    const f = fixture(), completion = f.start('all')
    assert.equal(f.deliver(), true)
    f.replace('visible generation')
    const result = await f.finish(completion)
    assert.equal(result.error, undefined)
    assert.equal(result.value, 1)
    assert.deepEqual(Array.from(f.reader.articleReadingProgress.sentenceIdentifiersRead), ['current-page'])
})

test('coordinator rejection of an owner stale before settlement is unchanged', async () => {
    const f = fixture(), completion = f.start()
    f.replace('document')
    assert.equal(f.deliver(), true)
    const result = await f.finish(completion)
    assert.equal(result.error, undefined)
    assert.equal(result.value, false)
    assert.deepEqual(Array.from(f.reader.articleReadingProgress.sentenceIdentifiersRead), [])
    assert.deepEqual(f.moves, [])
})

test('projection failure retains known success and records its optional failure', async () => {
    const f = fixture(), completion = f.start()
    f.reader.applyBookReadingProgress = () => { throw new Error('projection unavailable') }
    assert.equal(f.deliver(), true)
    const result = await f.finish(completion)
    assert.equal(result.error, undefined)
    assert.equal(result.value, true)
    assert.equal(f.reader.lastNativeMarkReadRequestOutcome, 'committed')
    assert.deepEqual(f.moves, [])
    assert.equal(f.errors.length, 1)
    assert.match(f.errors[0][0], /projectionFailed/)
})

for (const direction of ['left', 'right']) {
    for (const asynchronous of [false, true]) {
        test(`${direction} ${asynchronous ? 'rejected' : 'throwing'} page turn retains known success`, async () => {
            const f = fixture()
            f.reader.isRTL = direction === 'left'
            const fail = () => { throw new Error('navigation unavailable') }
            f.reader.view[direction === 'left' ? 'goLeft' : 'goRight'] = asynchronous
                ? async () => fail() : fail
            const completion = f.start()
            assert.equal(f.deliver(), true)
            const result = await f.finish(completion)
            assert.equal(result.error, undefined)
            assert.equal(result.value, true)
            assert.equal(f.reader.lastNativeMarkReadRequestOutcome, 'committed')
            assert.equal(f.reader.pageTrackingBusyStateIDs.size, 0)
            assert.equal(f.errors.length, 1)
            assert.match(f.errors[0][0], /navigationFailed/)
        })
    }
}

test('optional terminal chrome failure cannot replace known success', async () => {
    const f = fixture(), completion = f.start()
    assert.equal(f.deliver(), true)
    await f.flush()
    f.reader.navHUD.refreshAuxiliaryLayout = () => { throw new Error('chrome unavailable') }
    const result = await f.finish(completion)
    assert.equal(result.error, undefined)
    assert.equal(result.value, true)
    assert.equal(f.reader.pageTrackingBusyStateIDs.size, 0)
    assert.equal(f.errors.length, 1)
    assert.match(f.errors[0][0], /chromeFailed/)
})

test('pre-reply submission exceptions remain exceptions and release original busy state', async () => {
    const f = fixture()
    f.reader.nativeMarkReadRequestCoordinator.request = async () => { throw new Error('request unavailable') }
    const result = await f.finish(f.start())
    assert.match(result.error?.message, /request unavailable/)
    assert.equal(f.reader.pageTrackingBusyStateIDs.size, 0)
    assert.equal(f.requests.length, 0)
    assert.deepEqual(f.moves, [])
})
