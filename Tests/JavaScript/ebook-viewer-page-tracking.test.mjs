import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import { installBookReadingRuntime } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-runtime.js'

// Evaluate the complete shipping Reader class. Only the module/startup adapter
// and DOM/native collaborators are replaced; no command or render method is
// copied into a second implementation.
const source = readFileSync(new URL(
    '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-viewer.js', import.meta.url
), 'utf8')
const classStart = source.indexOf('class Reader {')
const classEnd = source.indexOf('\n}\n', classStart)
const readerClass = source.slice(classStart, classEnd)

function fixture() {
    const packets = [], requests = [], attributes = new Map(), timers = new Map(), moves = []
    const doc = { location: { href: 'ebook://fixture/chapter.xhtml' }, defaultView: {}, body: {} }
    const visibleRange = { collapsed: false }
    const producerOwner = { required: false }
    class Element {}
    const context = vm.createContext({
        console, Map, Set, Promise, HTMLElement: Element, Element,
        performance: { now: () => 0 },
        performanceNowMs: () => 0,
        document: {
            body: { dataset: {}, setAttribute: (key, value) => attributes.set(key, value) },
            getElementById: () => null, querySelector: () => null,
        },
        screen: { orientation: {} },
        $: () => null,
        normalizeArticleReadingProgress: value => ({ readSegmentIdentifiers: [], sentenceIdentifiersRead: [], ...value }),
        debounce: callback => callback,
        applyStoredChromeInsets() {},
        NavigationHUD: class { refreshAuxiliaryLayout() {} },
        createNativeMarkReadRequestCoordinator: () => ({ request: async request => {
            requests.push(request)
            return { success: false, errorCode: 'fixture-rejection' }
        } }),
        presentNativeMarkReadPending() {},
        nativeMarkReadCommandMessage: (payload, identity) => ({ ...identity,
            stableSegmentIDs: payload.segments.map(segment => segment.stableSegmentID),
            sentenceIdentifiers: payload.sentenceIdentifiers }),
        stableEbookSegmentIdentityVersion: 1,
        readerDocumentStartedAtMs: () => 1,
        captureReaderArticleProducerOwner: () => producerOwner,
        readerArticleProducerOwnerIsCurrent: () => true,
        ignoreNextIncomingHideNavigation() {},
        ignoreNextIncomingRevealNavigation() {},
        isDocumentLike: value => value === doc,
        getCurrentRendererDocument: renderer => renderer?.getContents?.()[0]?.doc ?? null,
        getPrimaryRendererContent: renderer => renderer?.getContents?.()[0] ?? null,
        visibleRangeForNavigationHUDDocument: () => visibleRange,
        visiblePageSegmentCollectionOptions: (_mode, options) => options,
        visibleTrackingSignatureForResult: (_doc, result) => result.signature,
        buildVisiblePageTrackingStates: (_doc, _progress, _range, result) => ({
            states: result.states, diagnostics: {},
        }),
        shouldInvalidateVisibleSegmentGeometryForReason: () => true,
        MANABI_ENABLE_EBOOK_PAGE_TRACKING_BUTTONS: false,
        manabiTimelineMeasure() {}, cancelAnimationFrame() {}, clearTimeout() {},
        requestAnimationFrame: () => 1,
        setTimeout: (callback, delay) => { const id = timers.size + 1; timers.set(id, { callback, delay }); return id },
    })
    context.window = context
    context.top = context
    context.location = { href: 'ebook://fixture/book.epub' }
    context.webkit = { messageHandlers: {
        ebookNativeMarkReadState: { postMessage: packet => packets.push(packet) },
        nativeLookupHitTargetsUpdated: { postMessage() {} },
    } }
    const Reader = vm.runInContext(`${readerClass}
        testRender(reason) { this.#renderPageTrackingButtons(reason) }
        testInvalidate() { this.#invalidateVisiblePageSegmentSnapshot('renderer.relocate') }
        testMarkCluster() { return this.#markPageClusterAsRead('visible-screen') }
    }; Reader`, context)
    const reader = new Reader()
    context.reader = reader
    reader.view = { renderer: { displayedIndex: 0, getContents: () => [{ index: 0, doc }] },
        goRight: async () => { moves.push('right'); return true },
        goLeft: async () => { moves.push('left'); return true } }
    const state = (sentence, isRead = false) => ({ id: 'visible-screen', isRead,
        payload: { stableIdentityVersion: 1, segments: [], sentenceIdentifiers: [sentence] } })
    const installPage = (sentence, isRead = false) => {
        const states = [state(sentence, isRead)]
        reader.visiblePageSegmentSnapshot = {
            doc, visibleRange, generation: reader.visiblePageCollectionGeneration,
            includeSegmentMetadata: true, includeClientRects: false,
            result: { signature: sentence, states, visibleSegments: [] },
        }
        return states
    }
    const seedPage = (sentence, isRead = false) => {
        reader.pageTrackingStates = installPage(sentence, isRead)
        reader.pageTrackingStatesGeneration = reader.visiblePageCollectionGeneration
        reader.testRender('fixture-current-page')
    }
    return { reader, packets, requests, attributes, seedPage, installPage, visibleRange,
        context, doc, timers, moves }
}

function bookRuntimeFixture(f) {
    class Element extends EventTarget {
        attributes = new Map()
        classList = { add() {}, remove() {} }
        isConnected = true
        hidden = false
        append() {}
        setAttribute(key, value) { this.attributes.set(key, value) }
        getAttribute(key) { return this.attributes.get(key) ?? null }
        removeAttribute(key) { this.attributes.delete(key) }
        querySelector(key) {
            this.nodes ??= new Map()
            if (!this.nodes.has(key)) this.nodes.set(key, new Element())
            return this.nodes.get(key)
        }
        focus() {}
        remove() { this.isConnected = false }
    }
    const requests = [], host = new Element()
    f.doc.defaultView.manabi_applyBookReadingPresentation = () => true
    f.doc.defaultView.manabi_invalidateBookReadingScope = () => {
        f.doc.defaultView.manabi_bookReadingScope = null
    }
    f.context.webkit.messageHandlers.ebookBookAction = { postMessage() {} }
    f.context.webkit.messageHandlers.ebookBookReadingState = { postMessage: request => requests.push(request) }
    const runtime = installBookReadingRuntime({ reader: f.reader, view: f.reader.view,
        document: { createElement: () => new Element(), getElementById: () => host },
        window: f.context, documentStartedAtMs: 1,
        applyProjection: state => f.reader.applyBookReadingProgress({
            readSegmentIdentifiers: state.readSegmentIdentifiers,
            sentenceIdentifiersRead: state.sentenceIdentifiersRead,
            articleMarkedAsFinished: state.finished,
        }, 'native-chapter-publication', true),
        invalidateProjection: () => f.reader.applyBookReadingProgress({}, 'chapter-state-unavailable', true),
        onVisibility() {},
    })
    f.reader.bookReadingRuntime = runtime
    runtime.updateLocation()
    const response = (revision = 1, accountPresentation = runtime.state.accountPresentation ?? '1:1') => {
        const scope = { articleProgressID: 'book', articleEpochID: 'pass',
            chapterKey: 'a'.repeat(64), chapterEpochID: null }
        return { ok: true, accountPresentation,
            state: { revision, articleProgressID: 'book', articleEpochID: 'pass', scope,
                finished: false, readSegmentIdentifiers: [], sentenceIdentifiersRead: [],
                bookReadPresence: 'empty', chapterReadPresence: 'empty' },
            context: { contextID: `context-${revision}`, articleProgressID: 'book', articleEpochID: 'pass', scope,
                isEndPage: false, sectionLocation: 'chapter.xhtml' } }
    }
    const publish = (revision = 1) => runtime.state.apply(requests.at(-1).requestID, response(revision))
    const native = (revision = 2) => runtime.state.apply('native', { ...response(revision), nativeRefresh: true,
        location: { ...runtime.state.location, locationRevision: runtime.state.locationRevision } })
    assert.equal(publish(), true)
    return { runtime, requests, publish, native, response }
}

test('invalidating a read page immediately withdraws native read controls and marker', () => {
    const f = fixture()
    f.seedPage('previous-page', true)
    assert.equal(f.packets.at(-1).isRead, true)
    f.reader.testInvalidate()
    assert.equal(f.packets.at(-1).available, false)
    assert.equal(f.packets.at(-1).isRead, false)
    assert.equal(f.attributes.get('data-page-read-marker-read'), 'false')
})

test('a Mark tap after invalidation hydrates the current page instead of posting previous subjects', async () => {
    const f = fixture()
    f.seedPage('previous-page')
    f.reader.testInvalidate()
    f.installPage('current-page')
    await f.reader.markVisiblePageAsRead()
    assert.equal(f.requests.length, 1)
    assert.deepEqual(Array.from(f.requests[0].message.sentenceIdentifiers), ['current-page'])
})

test('a Mark tap cannot report an invalidated read page as the current page when fresh geometry is unavailable', async () => {
    const f = fixture()
    f.seedPage('previous-page', true)
    f.reader.testInvalidate()
    f.visibleRange.collapsed = true
    assert.equal(await f.reader.markVisiblePageAsRead(), false)
    assert.equal(f.requests.length, 0)
})

test('late Mark completion cannot republish an invalidated page before its replacement sample', async () => {
    const f = fixture()
    f.seedPage('previous-page')
    let settle
    f.reader.nativeMarkReadRequestCoordinator.request = request => {
        f.requests.push(request)
        return new Promise(resolve => { settle = resolve })
    }
    const operation = f.reader.testMarkCluster()
    assert.equal(f.requests.length, 1)
    f.reader.testInvalidate()
    settle({ success: false, stale: true, errorCode: 'cancelled' })
    await operation
    assert.equal(f.packets.at(-1).available, false)
    assert.equal(f.packets.at(-1).isBusy, false)
    assert.equal(f.attributes.get('data-page-read-marker-read'), 'false')
})

test('a page turn during demand hydration cannot retarget the original tap to a populated successor page', async () => {
    const f = fixture()
    f.installPage('original-page')
    const operation = f.reader.markVisiblePageAsRead()
    // The demand read returned its original sample, but its async continuation
    // has not resumed. A same-chapter relocation retains producer/book scope.
    f.reader.testInvalidate()
    f.seedPage('successor-page')
    assert.equal(await operation, false)
    assert.equal(f.requests.length, 0)
})

test('a current page and independent completion action retain their presentation', async () => {
    const f = fixture()
    f.seedPage('current-page', true)
    assert.equal(await f.reader.markVisiblePageAsRead(), true)
    assert.equal(f.requests.length, 0)
    f.reader.completionAction = { type: 'finish', label: 'Finish' }
    f.reader.completionActionBusy = true
    f.reader.testInvalidate()
    f.reader.testRender('fixture-completion')
    assert.equal(f.packets.at(-1).available, true)
    assert.equal(f.packets.at(-1).stateID, 'completion-action:finish')
    assert.equal(f.packets.at(-1).isBusy, true)
})

async function successfulMarkAwaitingAdvance(f) {
    f.seedPage('current-page')
    f.reader.nativeMarkReadRequestCoordinator.request = async request => {
        f.requests.push(request)
        return { success: true, stale: false, presentationAllowed: true,
            nativeResult: { stateSnapshotSequence: 2 }, context: request.context }
    }
    const operation = f.reader.markVisiblePageAsRead()
    // Let the VM's async command cross its Promise realm and reach the held
    // timer without firing that timer or introducing a wall-clock delay.
    await new Promise(resolve => setImmediate(resolve))
    const advance = [...f.timers.values()].find(timer => timer.delay === 430)
    assert.ok(advance, 'Successful Mark must reach its existing delayed advance')
    return { operation, advance }
}

for (const continuation of ['unchanged scope', 'same-scope progress', 'producer retirement']) {
    test(`successful Mark retains automatic advance after ${continuation}`, async t => {
        const f = fixture(), book = bookRuntimeFixture(f)
        t.after(() => book.runtime.close())
        const event = book.runtime.captureEvent(f.doc)
        assert.ok(event)
        const { operation, advance } = await successfulMarkAwaitingAdvance(f)
        if (continuation === 'same-scope progress') assert.equal(book.native(2), true)
        if (continuation === 'producer retirement') {
            f.context.readerArticleProducerOwnerIsCurrent = () => false
        }
        assert.equal(book.runtime.isEventCurrent(event), true)
        advance.callback()
        assert.equal(await operation, true, 'The durable Mark outcome remains successful')
        assert.deepEqual(f.moves, ['right'])
    })
}

for (const transition of ['account invalidation', 'unavailable chapter scope', 'runtime replacement']) {
    test(`successful Mark suppresses delayed automatic advance after ${transition}`, async t => {
        const f = fixture(), book = bookRuntimeFixture(f)
        t.after(() => book.runtime.close())
        const event = book.runtime.captureEvent(f.doc)
        assert.ok(event)
        const { operation, advance } = await successfulMarkAwaitingAdvance(f)
        if (transition === 'account invalidation') {
            assert.equal(book.runtime.accountDidChange('2:1'), true)
        } else if (transition === 'unavailable chapter scope') {
            assert.equal(book.runtime.state.apply('native', {
                ...book.response(2), ok: false, nativeRefresh: true,
                location: { ...book.runtime.state.location,
                    locationRevision: book.runtime.state.locationRevision },
            }), false)
        } else {
            const replacement = bookRuntimeFixture(f)
            t.after(() => replacement.runtime.close())
        }
        assert.equal(f.reader.bookReadingRuntime.isEventCurrent(event), false)
        advance.callback()
        assert.equal(await operation, true, 'Blocked optional navigation must not discard committed success')
        assert.deepEqual(f.moves, [])
    })
}

for (const failure of ['synchronous LTR', 'rejected LTR', 'rejected RTL']) {
    test(`a ${failure} optional page turn cannot reject an already committed Mark`, async t => {
        const f = fixture(), book = bookRuntimeFixture(f)
        t.after(() => book.runtime.close())
        f.reader.isRTL = failure.endsWith('RTL')
        const method = f.reader.isRTL ? 'goLeft' : 'goRight'
        f.reader.view[method] = failure.startsWith('synchronous')
            ? () => { throw new Error('renderer navigation failed') }
            : async () => { throw new Error('renderer navigation failed') }
        const { operation, advance } = await successfulMarkAwaitingAdvance(f)
        advance.callback()
        assert.equal(await operation, true)
        assert.equal(f.reader.lastNativeMarkReadRequestOutcome, 'committed')
        assert.equal(f.requests.length, 1)
    })
}
