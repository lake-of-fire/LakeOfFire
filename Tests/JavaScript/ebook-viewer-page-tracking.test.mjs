import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import { installBookReadingRuntime } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-runtime.js'
import { bookScopeKey } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'
import { applyBookReadingProjection } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-projection.js'
import { createNativeMarkReadRequestCoordinator, refreshCommittedVisibleMarkReadState, committedVisibleMarkReadStateIsPresented, captureVisibleMarkReadNavigation } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'
import { refreshNativeMarkReadBookStateForRecovery } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

// Evaluate the complete shipping Reader class. Only the module/startup adapter
// and DOM/native collaborators are replaced; no command or render method is
// copied into a second implementation.
const source = readFileSync(process.env.MANABI_EBOOK_VIEWER_SOURCE || new URL(
    '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-viewer.js', import.meta.url
), 'utf8')
const classStart = source.indexOf('class Reader {')
const classEnd = source.indexOf('\n}\n', classStart)
const readerClass = source.slice(classStart, classEnd)

function fixture({ realCoordinator = false, onControl } = {}) {
    const packets = [], requests = [], controls = [], attributes = new Map(), timers = new Map(), moves = []
    const lifecycle = new EventTarget()
    let coordinatorSequence = 0
    const doc = { location: { href: 'ebook://fixture/chapter.xhtml' }, defaultView: {}, body: {} }
    let navigationCurrent = true
    doc.defaultView.manabiCaptureAutomaticScrollNavigation = () => () => navigationCurrent
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
        applyBookReadingProjection,
        refreshCommittedVisibleMarkReadState,
        committedVisibleMarkReadStateIsPresented,
        captureVisibleMarkReadNavigation,
        debounce: callback => callback,
        applyStoredChromeInsets() {},
        NavigationHUD: class { refreshAuxiliaryLayout() {} },
        createNativeMarkReadRequestCoordinator: options => realCoordinator
            ? createNativeMarkReadRequestCoordinator({ ...options, lifecycleTarget: lifecycle,
                makeRequestID: () => 'viewer-fixture-' + ++coordinatorSequence,
                postMessage: message => requests.push({ message }),
                postControlMessage: message => { controls.push(message); onControl?.(message) },
                scheduleTimeout: (callback, delay) => {
                    const id = timers.size + 1
                    timers.set(id, { callback, delay })
                    return id
                },
                cancelTimeout: id => timers.delete(id),
            })
            : ({ cancelAll() {}, request: async request => {
                requests.push(request)
                return { success: false, errorCode: 'fixture-rejection' }
            } }),
        presentNativeMarkReadPending() {},
        refreshNativeMarkReadBookStateForRecovery,
        bookScopeKey,
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
        isCacheWarmerDocument: () => false,
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
        lastPositionRestoreCoordinator: { current: null },
        resetReaderTransientState() {},
        PAGE_TURN_MOVEMENT_DISPOSITION: { notOwned: 'not-owned' },
        requestAnimationFrame: () => 1,
        setTimeout: (callback, delay) => { const id = timers.size + 1; timers.set(id, { callback, delay }); return id },
    })
    context.window = context
    context.addEventListener = lifecycle.addEventListener.bind(lifecycle)
    context.removeEventListener = lifecycle.removeEventListener.bind(lifecycle)
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
        testCommitDocumentScope(doc) {
            return this.#commitDocumentScope(this.#beginDocumentScope({ doc, index: 0 }), 'fixture-document-committed')
        }
        testNativeBookReadProjection(state, details = { passChanged: false }) { return this.#applyNativeBookReadProjection(state, details) }
        testSuccessfulPublication() { return this.#successfulBookReadPublication }
        testInvalidateBookPublication() { this.#successfulBookReadPublication = null }
    }; Reader`, context)
    const reader = new Reader()
    context.reader = reader
    reader.view = { renderer: { displayedIndex: 0, getContents: () => [{ index: 0, doc }] },
        goRight: async () => { moves.push('right'); return true },
        goLeft: async () => { moves.push('left'); return true } }
    reader.refreshNativeLookupHitTargets = () => {}
    const state = (sentence, isRead = false) => ({ id: 'visible-screen', isRead,
        payload: { stableIdentityVersion: 1, segments: [{ stableSegmentID: `${sentence}-segment`,
            jmdictEntryIds: [1], jmnedictEntryIds: [], searchString: 'word', sentenceIdentifier: sentence }], sentenceIdentifiers: [] } })
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
    return { reader, Reader, packets, requests, controls, attributes, seedPage, installPage, visibleRange,
        context, doc, timers, moves, lifecycle, retireNavigation: () => { navigationCurrent = false } }
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
        applyProjection: (state, details) => f.reader.testNativeBookReadProjection(state, details),
        invalidateProjection: () => {
            f.reader.testInvalidateBookPublication()
            f.reader.optimisticReadSegmentIdentifiers.clear()
            f.reader.optimisticSentenceIdentifiersRead.clear()
            f.reader.applyBookReadingProgress({}, 'chapter-state-unavailable', true)
        },
        onVisibility() {},
    })
    f.reader.bookReadingRuntime = runtime
    runtime.updateLocation()
    const response = (revision = 1, accountPresentation = runtime.state.accountPresentation ?? '1:1',
        readSegmentIdentifiers = runtime.state.state?.readSegmentIdentifiers ?? [],
        sentenceIdentifiersRead = runtime.state.state?.sentenceIdentifiersRead ?? []) => {
        const scope = { articleProgressID: 'book', articleEpochID: 'pass',
            chapterKey: 'a'.repeat(64), chapterEpochID: null }
        return { ok: true, accountPresentation,
            state: { revision, articleProgressID: 'book', articleEpochID: 'pass', scope,
                finished: false, readSegmentIdentifiers, sentenceIdentifiersRead,
                bookReadPresence: 'empty', chapterReadPresence: 'empty' },
            context: { contextID: `context-${revision}`, articleProgressID: 'book', articleEpochID: 'pass', scope,
                isEndPage: false, sectionLocation: 'chapter.xhtml' } }
    }
    const publish = (revision = 1, segments, sentences) => {
        const request = requests.at(-1)
        return runtime.state.apply(request.requestID, { ...response(revision, undefined, segments, sentences),
            location: { sectionURL: request.sectionURL, isEndPage: request.isEndPage, locationRevision: request.locationRevision },
            ...(request.historyRecoveryObservation ? { historyRecoveryObservation: request.historyRecoveryObservation } : {}) })
    }
    const native = (revision = 2) => runtime.state.apply('native', { ...response(revision), nativeRefresh: true,
        location: { ...runtime.state.location, locationRevision: runtime.state.locationRevision } })
    assert.equal(publish(), true)
    const book = { runtime, requests, publish, native, response }
    f.book = book
    return book
}

test('closing the shipping Reader retires unresolved Mark transport before reopening', async () => {
    let reentrantClose
    const f = fixture({ realCoordinator: true,
        onControl: () => { reentrantClose = f.reader.close('fixture-reentrant-close') } })
    const book = bookRuntimeFixture(f)
    f.seedPage('closing-page')
    assert.equal(f.reader.testCommitDocumentScope(f.doc), true,
        'Closing must retain transport ownership for an actual committed chapter scope')
    const oldReader = f.reader, view = oldReader.view
    const page = oldReader.visiblePageSegmentSnapshot, states = oldReader.pageTrackingStates
    const completion = oldReader.markVisiblePageAsRead()
    const joined = completion.then(value => ({ value }), error => ({ error }))
    const original = f.requests[0].message
    const retainedTimer = [...f.timers.values()].find(timer => timer.delay === 15_000)
    assert.ok(retainedTimer)
    assert.equal(oldReader.close('fixture-reopen'), true)
    assert.equal(oldReader.nativeMarkReadRequestCoordinator.pendingCount, 0)
    assert.equal(f.controls.length, 1)
    assert.equal(f.controls[0].manualReadPendingOperation, 'cancel')
    assert.equal(f.controls[0].manualReadPendingObservationToken, original.manualReadPendingObservationToken)
    assert.equal(reentrantClose, false, 'Reader ownership is already closed before native cancellation callouts')
    const outcome = await joined
    assert.equal(outcome.value, undefined)
    assert.equal(outcome.error?.code, 'readerClosed')
    assert.equal(outcome.error?.outcomeUnknown, true)
    assert.equal(oldReader.close('fixture-duplicate-close'), false)

    const replacement = new f.Reader()
    f.context.reader = replacement
    replacement.view = view
    const currentBook = bookRuntimeFixture({ ...f, reader: replacement })
    replacement.visiblePageSegmentSnapshot = { ...page,
        generation: replacement.visiblePageCollectionGeneration }
    replacement.pageTrackingStates = states
    replacement.pageTrackingStatesGeneration = replacement.visiblePageCollectionGeneration
    const currentScope = f.doc.defaultView.manabi_bookReadingScope
    const successor = replacement.markVisiblePageAsRead()
    assert.equal(f.requests.length, 2, 'The reopened Reader owns its own valid pending Mark')
    const current = f.requests.at(-1).message
    assert.notEqual(current.manualReadPendingObservationToken, original.manualReadPendingObservationToken)
    retainedTimer.callback()
    f.lifecycle.dispatchEvent(new Event('pageshow'))
    oldReader.nativeMarkReadRequestCoordinator.resume()
    assert.equal(f.controls.length, 1, 'Closed transport cannot poll or cancel after reopen')
    assert.equal(oldReader.applyMarkSectionAsReadResult({ ...original,
        manualReadPendingState: 'finished', success: true }), false)
    assert.equal(replacement.nativeMarkReadRequestCoordinator.pendingCount, 1)
    assert.strictEqual(f.doc.defaultView.manabi_bookReadingScope, currentScope)
    assert.equal(replacement.applyMarkSectionAsReadResult({ ...current,
        manualReadPendingState: 'finished', success: true }), true)
    assert.equal(await successor, true)
    currentBook.runtime.close()
    book.runtime.close()
})

test('closing the shipping Reader cannot cancel a departed chapter owner', async () => {
    const f = fixture({ realCoordinator: true }), book = bookRuntimeFixture(f)
    f.seedPage('departing-page')
    const completion = f.reader.markVisiblePageAsRead()
    const joined = completion.then(value => ({ value }), error => ({ error }))
    const original = f.requests[0].message
    const retainedTimer = [...f.timers.values()].find(timer => timer.delay === 15_000)
    book.runtime.state.relocate({ sectionURL: 'different-chapter.xhtml', isEndPage: false })
    const controlsBeforeClose = f.controls.length
    assert.equal(f.reader.close('fixture-departed-close'), true)
    assert.equal(f.controls.length, controlsBeforeClose, 'Close retains no departed cancellation permission')
    const outcome = await joined
    assert.equal(outcome.error?.code, 'readerClosed')
    assert.equal(outcome.error?.outcomeUnknown, true)
    retainedTimer.callback()
    f.lifecycle.dispatchEvent(new Event('pageshow'))
    assert.equal(f.controls.length, controlsBeforeClose)
    assert.equal(f.reader.applyMarkSectionAsReadResult({ ...original,
        manualReadPendingState: 'finished', success: true }), false)
    assert.equal(f.reader.nativeMarkReadRequestCoordinator.pendingCount, 0)
    book.runtime.close()
})

test('shipping Reader treats a running history receipt without section ID as status-only', async () => {
    const f = fixture({ realCoordinator: true }), book = bookRuntimeFixture(f)
    f.seedPage('running-history-page')
    const completion = f.reader.markVisiblePageAsRead(), message = f.requests[0].message
    const history = { requestID: message.requestID, manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: message.manualReadPendingObservationToken,
        manualReadPendingHistoryRecovery: true, manualReadPendingOutcomeOnly: true,
        manualReadPendingPresentationAllowed: false }
    assert.equal(f.reader.applyMarkSectionAsReadResult({ ...history,
        manualReadPendingState: 'cancelling' }), false)
    assert.equal(f.reader.nativeMarkReadRequestCoordinator.pendingCount, 1)
    assert.equal(f.reader.nativeMarkReadRequestCoordinator.cancel(message.requestID), false)
    assert.equal(book.requests.length, 1, 'A running history receipt cannot authorize a fresh native query')
    const timer = [...f.timers.values()].find(value => value.delay === 15_000)
    assert.ok(timer)
    timer.callback()
    assert.equal(f.controls.length, 1)
    assert.equal(f.controls[0].manualReadPendingOperation, 'status')
    assert.equal(f.controls[0].manualReadPendingHistoryRecovery, true)
    assert.equal(f.controls[0].manualReadPendingObservationToken, message.manualReadPendingObservationToken)
    assert.equal(f.requests.length, 1, 'History observation cannot replay the original mutation')
    assert.equal(f.reader.applyMarkSectionAsReadResult({ ...history,
        manualReadPendingState: 'finished', success: true }), true)
    assert.equal(await completion, true)
    assert.equal(book.requests.length, 1, 'Terminal truth still waits for native recovery delegation')
    assert.deepEqual(f.moves, [])
    book.runtime.close()
})

test('native Mark success accepted before Reader close retains its original outcome', async () => {
    const f = fixture({ realCoordinator: true }), book = bookRuntimeFixture(f)
    f.seedPage('terminal-before-close')
    const completion = f.reader.markVisiblePageAsRead(), message = f.requests[0].message
    assert.equal(f.reader.applyMarkSectionAsReadResult({ ...message,
        manualReadPendingState: 'finished', success: true }), true)
    assert.equal(f.reader.close('fixture-terminal-won'), true)
    assert.equal(await completion, true)
    assert.equal(f.controls.length, 0, 'An accepted terminal cannot become an unresolved Cancel')
    assert.equal(f.reader.nativeMarkReadRequestCoordinator.pendingCount, 0)
    assert.deepEqual(f.moves, [], 'Closing retires optional advancement after native success')
    book.runtime.close()
})

test('restored shipping Reader refreshes readonly status without reviving its pagehide presentation lifetime', async () => {
    const f = fixture({ realCoordinator: true }), book = bookRuntimeFixture(f)
    f.seedPage('restored-page')
    const completion = f.reader.markVisiblePageAsRead(), message = f.requests[0].message
    f.lifecycle.dispatchEvent(new Event('pagehide'))
    f.lifecycle.dispatchEvent(new Event('pageshow'))
    const proof = { requestID: message.requestID, observationToken: message.manualReadPendingObservationToken }
    assert.equal(f.reader.applyMarkSectionAsReadResult({ requestID: message.requestID,
        manualReadPendingProtocol: 1, manualReadPendingObservationToken: proof.observationToken,
        manualReadPendingState: 'finished', manualReadPendingHistoryRecovery: true,
        manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false, success: true }), true)
    await completion
    assert.equal(book.runtime.state.ready, false)
    assert.equal(book.requests.length, 1, 'A terminal result does not authorize its own fresh query')
    const acknowledged = f.reader.recoverHistoryReadingStatus(proof)
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(book.requests.length, 2)
    assert.deepEqual(book.requests.at(-1).historyRecoveryObservation, proof)
    assert.equal(book.publish(2), true)
    assert.equal(await acknowledged, true)
    assert.equal(book.runtime.state.ready, true)
    assert.equal(f.reader.reacknowledgeHistoryReadingStatus(proof), true)
    assert.equal(f.reader.applyMarkSectionAsReadResult({ requestID: message.requestID,
        manualReadPendingProtocol: 1, manualReadPendingObservationToken: proof.observationToken,
        manualReadPendingState: 'finished', manualReadPendingHistoryRecovery: true,
        manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false, success: true }), false)
    assert.equal(book.runtime.state.ready, true, 'Duplicate terminal delivery cannot recreate an old barrier')
    assert.equal(book.requests.length, 2)
    assert.deepEqual(f.moves, [], 'Readonly recovery cannot auto-advance the old Mark')
    assert.equal(f.requests.length, 1, 'The committed mutation is never replayed')
    f.reader.bookReadingRuntime = { ...book.runtime }
    assert.equal(f.reader.failHistoryReadingStatusRecovery(proof), false,
        'An equal-valued replacement runtime cannot inherit the old rejection')
    assert.equal(book.runtime.state.ready, true)
    assert.equal(f.reader.reacknowledgeHistoryReadingStatus(proof), false)
    book.runtime.close()
})

test('ordinary terminal after pagehide acknowledges the subsequent native history receipt', async () => {
    const f = fixture({ realCoordinator: true }), book = bookRuntimeFixture(f)
    f.seedPage('restored-page')
    const completion = f.reader.markVisiblePageAsRead(), message = f.requests[0].message
    f.lifecycle.dispatchEvent(new Event('pagehide'))
    const terminal = { requestID: message.requestID, sectionId: message.sectionId,
        manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: message.manualReadPendingObservationToken,
        manualReadPendingState: 'finished', success: true }
    assert.equal(f.reader.applyMarkSectionAsReadResult(terminal), true)
    await completion
    f.lifecycle.dispatchEvent(new Event('pageshow'))
    const historyTerminal = { ...terminal, manualReadPendingHistoryRecovery: true,
        manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false }
    // Core's actual terminalAccepted guard requires this Boolean before it
    // invokes the sole automatic recoverHistoryReadingStatus call.
    assert.equal(f.reader.applyMarkSectionAsReadResult(historyTerminal), true)
    assert.equal(book.requests.length, 1)
    const proof = { requestID: message.requestID,
        observationToken: message.manualReadPendingObservationToken }
    const acknowledged = f.reader.recoverHistoryReadingStatus(proof)
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(book.requests.length, 2)
    assert.equal(book.publish(2), true)
    assert.equal(await acknowledged, true)
    assert.equal(book.runtime.state.ready, true)
    assert.equal(f.reader.applyMarkSectionAsReadResult(historyTerminal), false)
    assert.equal(f.requests.length, 1)
    assert.deepEqual(f.moves, [])
    book.runtime.close()
})

function restoredBookPassFixture(replacement) {
    const f = fixture({ realCoordinator: true }), book = bookRuntimeFixture(f)
    f.seedPage('previous-pass-page')
    const completion = f.reader.markVisiblePageAsRead(), message = f.requests[0].message
    f.lifecycle.dispatchEvent(new Event('pagehide'))
    f.lifecycle.dispatchEvent(new Event('pageshow'))
    const publication = book.response(2)
    if (replacement === 'book') {
        for (const value of [publication.state, publication.context]) {
            value.articleEpochID = 'successor-book-pass'
            value.scope.articleEpochID = 'successor-book-pass'
        }
    } else if (replacement === 'chapter') {
        publication.state.scope.chapterEpochID = 'successor-chapter-pass'
    }
    assert.equal(book.runtime.state.apply('native-successor', { ...publication, nativeRefresh: true,
        location: { ...book.runtime.state.location, locationRevision: book.runtime.state.locationRevision } }), true)
    const terminal = { requestID: message.requestID, sectionId: message.sectionId,
        manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: message.manualReadPendingObservationToken,
        manualReadPendingState: 'finished', success: true }
    const historyTerminal = { ...terminal, manualReadPendingHistoryRecovery: true,
        manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false }
    return { f, book, completion, message, terminal, historyTerminal,
        proof: { requestID: message.requestID, observationToken: message.manualReadPendingObservationToken } }
}

test('Book recovery relocation admits a fresh Mark after a current same-chapter sample', async t => {
    const { f, book, completion, historyTerminal, proof } = restoredBookPassFixture('unchanged')
    t.after(() => book.runtime.close())
    assert.equal(f.reader.applyMarkSectionAsReadResult(historyTerminal), true)
    assert.equal(await completion, true)
    const recovery = f.reader.recoverHistoryReadingStatus(proof)
    await new Promise(resolve => setImmediate(resolve))
    const historyRequest = book.requests.at(-1)
    assert.deepEqual(historyRequest.historyRecoveryObservation, proof)
    assert.equal(book.runtime.state.ready, false)

    // Reader's real relocate handler calls this runtime entry point for a
    // page turn, including movement within the same chapter Document.
    assert.equal(book.runtime.updateLocation(true), true)
    const currentRequest = book.requests.at(-1)
    assert.equal(currentRequest.sectionURL, historyRequest.sectionURL)
    assert.ok(currentRequest.locationRevision > historyRequest.locationRevision)
    assert.equal(currentRequest.historyRecoveryObservation, undefined)
    assert.equal(await recovery, false, 'Relocation retires the old native query')
    assert.equal(book.publish(3), true, 'The current ordinary location query supplies fresh native facts')
    assert.equal(book.runtime.state.ready, true)
    const currentContext = book.runtime.state.context
    assert.equal(f.reader.failHistoryReadingStatusRecovery(proof), false,
        'A late native failure cannot withdraw the successor location publication')
    assert.deepEqual(book.runtime.state.context, currentContext)

    f.seedPage('current-location-page')
    const successor = f.reader.markVisiblePageAsRead()
    const fresh = f.requests[1]?.message
    if (fresh) f.reader.applyMarkSectionAsReadResult({ ...fresh,
        manualReadPendingState: 'finished', success: false, errorCode: 'fixture-complete' })
    await successor
    assert.equal(f.requests.length, 2,
        'A retired recovery cannot reject the ready current page as pendingCapacityExceeded')
    assert.deepEqual(fresh.bookReadingScope, currentContext.scope)
    assert.equal(f.reader.failHistoryReadingStatusRecovery(proof), false)
    assert.equal(book.runtime.state.ready, true)
    assert.deepEqual(f.moves, [], 'Read-only recovery does not advance the original page')
})

test('Book recovery relocation leaves unchanged-location failure blocked', async t => {
    const { f, book, completion, historyTerminal, proof } = restoredBookPassFixture('unchanged')
    t.after(() => book.runtime.close())
    assert.equal(f.reader.applyMarkSectionAsReadResult(historyTerminal), true)
    assert.equal(await completion, true)
    const recovery = f.reader.recoverHistoryReadingStatus(proof)
    await new Promise(resolve => setImmediate(resolve))
    const request = book.requests.at(-1)
    assert.equal(book.runtime.state.apply(request.requestID, {
        ok: false, accountPresentation: book.runtime.state.accountPresentation,
        location: { sectionURL: request.sectionURL, isEndPage: request.isEndPage,
            locationRevision: request.locationRevision },
        historyRecoveryObservation: proof,
    }), false)
    assert.equal(await recovery, false)
    assert.equal(book.runtime.state.ready, false)
    assert.equal(book.native(3), false, 'An unsolicited ordinary sample cannot bypass the retained barrier')
    f.seedPage('unreconciled-page')
    assert.equal(await f.reader.markVisiblePageAsRead(), false)
    assert.equal(f.requests.length, 1)
    assert.equal(f.reader.failHistoryReadingStatusRecovery(proof), true)
})

test('Book recovery relocation before the delegated query cannot rebase the old receipt', async t => {
    const { f, book, completion, historyTerminal, proof } = restoredBookPassFixture('unchanged')
    t.after(() => book.runtime.close())
    assert.equal(f.reader.applyMarkSectionAsReadResult(historyTerminal), true)
    assert.equal(await completion, true)
    assert.equal(book.runtime.state.ready, false)
    assert.equal(book.runtime.updateLocation(true), true)
    assert.equal(book.publish(3), true)
    const currentContext = book.runtime.state.context
    const requestCount = book.requests.length

    const recovery = f.reader.recoverHistoryReadingStatus(proof)
    await new Promise(resolve => setImmediate(resolve))
    if (book.requests.length > requestCount) {
        // Drain any incorrectly reissued read so the baseline fails on the
        // ownership assertion instead of leaving an unresolved test promise.
        const request = book.requests.at(-1)
        book.runtime.state.apply(request.requestID, { ok: false,
            accountPresentation: book.runtime.state.accountPresentation,
            location: { sectionURL: request.sectionURL, isEndPage: request.isEndPage,
                locationRevision: request.locationRevision },
            historyRecoveryObservation: request.historyRecoveryObservation,
        })
    }
    assert.equal(await recovery, false)
    assert.equal(book.requests.length, requestCount,
        'A delayed native delegation cannot reprepare recovery at the successor location')
    assert.equal(book.runtime.state.ready, true)
    assert.deepEqual(book.runtime.state.context, currentContext)
    f.seedPage('current-before-delegation')
    const successor = f.reader.markVisiblePageAsRead()
    const fresh = f.requests[1]?.message
    if (fresh) f.reader.applyMarkSectionAsReadResult({ ...fresh,
        manualReadPendingState: 'finished', success: false, errorCode: 'fixture-complete' })
    await successor
    assert.equal(f.requests.length, 2)
    assert.equal(f.reader.failHistoryReadingStatusRecovery(proof), false)
    assert.equal(book.runtime.state.ready, true)
})

test('Book recovery relocation before terminal retains the later correlated recovery', async t => {
    const { f, book, completion, historyTerminal, proof } = restoredBookPassFixture('unchanged')
    t.after(() => book.runtime.close())
    assert.equal(book.runtime.updateLocation(true), true)
    assert.equal(book.publish(3), true)
    assert.equal(book.runtime.state.ready, true)
    const movedRevision = book.runtime.state.locationRevision
    assert.equal(f.reader.applyMarkSectionAsReadResult(historyTerminal), true)
    assert.equal(await completion, true)
    assert.equal(book.runtime.state.ready, false,
        'Movement before the terminal cannot excuse its required reading-status recovery')
    const recovery = f.reader.recoverHistoryReadingStatus(proof)
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(book.requests.at(-1).locationRevision, movedRevision)
    assert.deepEqual(book.requests.at(-1).historyRecoveryObservation, proof)
    assert.equal(book.publish(4), true)
    assert.equal(await recovery, true)
    assert.equal(f.reader.reacknowledgeHistoryReadingStatus(proof), true)
    assert.equal(book.runtime.state.ready, true)
    assert.equal(f.requests.length, 1, 'Recovery observes the original mutation without replaying it')
})

for (const replacement of ['book', 'chapter']) {
    for (const delivery of ['ordinary', 'history']) {
        test(`a successor Book pass admits a fresh Mark after the previous ${replacement} pass ${delivery} terminal`, async () => {
            const { f, book, completion, message, terminal, historyTerminal } = restoredBookPassFixture(replacement)
            f.reader.applyMarkSectionAsReadResult(delivery === 'history' ? historyTerminal : terminal)
            assert.equal(await completion, true, 'The original native commit remains successful')
            assert.equal(book.runtime.state.ready, true, 'Recovery must preserve the accepted successor context')
            f.seedPage('successor-pass-page')
            const successor = f.reader.markVisiblePageAsRead()
            const fresh = f.requests[1]?.message
            if (fresh) f.reader.applyMarkSectionAsReadResult({ ...fresh,
                manualReadPendingState: 'finished', success: false, errorCode: 'fixture-complete' })
            await successor
            assert.equal(f.requests.length, 2,
                'The old recovery must not keep rejecting the ready successor as pendingCapacityExceeded')
            assert.notEqual(fresh.requestID, message.requestID)
            assert.deepEqual(fresh.bookReadingScope, book.runtime.state.context.scope)
            assert.deepEqual(f.moves, [], 'An old pass cannot advance the successor page')
            book.runtime.close()
        })
    }

    test(`a successor Book pass refuses native recovery withdrawal for the previous ${replacement} pass terminal`, async () => {
        const { f, book, completion, historyTerminal, proof } = restoredBookPassFixture(replacement)
        const accepted = f.reader.applyMarkSectionAsReadResult(historyTerminal)
        assert.equal(await completion, true, 'Outcome truth is independent of recovery acknowledgement')
        assert.equal(accepted, false,
            'Core may withdraw native Book actions only when this terminal owns current recovery')
        assert.equal(book.runtime.state.ready, true)
        assert.equal(await f.reader.recoverHistoryReadingStatus(proof), false)
        assert.equal(book.requests.length, 1, 'An old pass cannot request another native sample')
        book.runtime.close()
    })
}

test('a same-pass publication still requires and accepts correlated Book history recovery', async () => {
    const { f, book, completion, historyTerminal, proof } = restoredBookPassFixture('unchanged')
    assert.equal(f.reader.applyMarkSectionAsReadResult(historyTerminal), true)
    assert.equal(await completion, true)
    assert.equal(book.runtime.state.ready, false)
    const recovery = f.reader.recoverHistoryReadingStatus(proof)
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(book.requests.length, 2)
    assert.deepEqual(book.requests.at(-1).historyRecoveryObservation, proof)
    assert.equal(book.publish(3), true)
    assert.equal(await recovery, true)
    assert.equal(book.runtime.state.ready, true)
    assert.equal(f.requests.length, 1, 'Recovery does not replay the original mutation')
    book.runtime.close()
})

for (const outcome of ['failed', 'unavailable']) {
    test(`a successor Book pass retains the original ${outcome} outcome without authorizing old recovery`, async () => {
        const { f, book, completion, message, historyTerminal } = restoredBookPassFixture('chapter')
        const terminal = outcome === 'failed'
            ? { ...historyTerminal, success: false, errorCode: 'cancelled' }
            : { requestID: message.requestID, manualReadPendingProtocol: 1,
                manualReadPendingObservationToken: message.manualReadPendingObservationToken,
                manualReadPendingState: 'unavailable', manualReadPendingHistoryRecovery: true,
                manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false,
                errorCode: 'outcomeUnavailable' }
        const accepted = f.reader.applyMarkSectionAsReadResult(terminal)
        assert.equal(await completion, false)
        assert.equal(f.reader.lastNativeMarkReadRequestOutcome, outcome)
        assert.equal(f.reader.lastNativeMarkReadRequestErrorCode,
            outcome === 'failed' ? 'cancelled' : 'outcomeUnavailable')
        assert.equal(accepted, false)
        assert.equal(book.runtime.state.ready, true)
        f.seedPage('successor-after-terminal')
        const successor = f.reader.markVisiblePageAsRead(), fresh = f.requests[1]?.message
        if (fresh) f.reader.applyMarkSectionAsReadResult({ ...fresh,
            manualReadPendingState: 'finished', success: false, errorCode: 'fixture-complete' })
        await successor
        assert.equal(f.requests.length, 2, 'A retired recovery does not block the current pass')
        assert.deepEqual(fresh.bookReadingScope, book.runtime.state.context.scope)
        book.runtime.close()
    })
}

for (const replacement of ['account', 'chapter']) {
    test(`retained history receipt cannot acknowledge a replacement ${replacement}`, async () => {
        const f = fixture({ realCoordinator: true }), book = bookRuntimeFixture(f)
        f.seedPage('restored-page')
        const completion = f.reader.markVisiblePageAsRead(), message = f.requests[0].message
        f.lifecycle.dispatchEvent(new Event('pagehide'))
        const terminal = { requestID: message.requestID, sectionId: message.sectionId,
            manualReadPendingProtocol: 1,
            manualReadPendingObservationToken: message.manualReadPendingObservationToken,
            manualReadPendingState: 'finished', success: true }
        assert.equal(f.reader.applyMarkSectionAsReadResult(terminal), true)
        await completion
        if (replacement === 'account') book.runtime.state.setAccountPresentation('2:1')
        else book.runtime.state.relocate({ sectionURL: 'ebook://fixture/other.xhtml' })
        const requests = book.requests.length
        assert.equal(f.reader.applyMarkSectionAsReadResult({ ...terminal,
            manualReadPendingHistoryRecovery: true, manualReadPendingOutcomeOnly: true,
            manualReadPendingPresentationAllowed: false }), false)
        assert.equal(book.requests.length, requests)
        assert.equal(f.requests.length, 1)
        book.runtime.close()
    })
}

test('late native recovery rejection cannot invalidate an admitted fresh Reader mutation', async () => {
    const f = fixture({ realCoordinator: true }), book = bookRuntimeFixture(f)
    f.seedPage('recovered-page')
    const first = f.reader.markVisiblePageAsRead(), message = f.requests[0].message
    f.lifecycle.dispatchEvent(new Event('pagehide'))
    f.lifecycle.dispatchEvent(new Event('pageshow'))
    const proof = { requestID: message.requestID, observationToken: message.manualReadPendingObservationToken }
    f.reader.applyMarkSectionAsReadResult({ requestID: message.requestID, manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: proof.observationToken, manualReadPendingState: 'finished',
        manualReadPendingHistoryRecovery: true, manualReadPendingOutcomeOnly: true,
        manualReadPendingPresentationAllowed: false, success: true })
    await first
    const acknowledged = f.reader.recoverHistoryReadingStatus(proof)
    await new Promise(resolve => setImmediate(resolve))
    book.publish(2)
    assert.equal(await acknowledged, true)
    f.seedPage('fresh-page')
    const successor = f.reader.markVisiblePageAsRead(), next = f.requests[1].message
    assert.equal(f.reader.nativeMarkReadRequestCoordinator.hasOrdinaryPendingRequests, true)
    assert.equal(f.reader.failHistoryReadingStatusRecovery(proof), false)
    assert.equal(book.runtime.state.ready, true)
    assert.equal(f.reader.nativeMarkReadRequestCoordinator.pendingCount, 1)
    assert.equal(f.reader.applyMarkSectionAsReadResult({ requestID: next.requestID, sectionId: next.sectionId,
        manualReadPendingProtocol: 1, manualReadPendingObservationToken: next.manualReadPendingObservationToken,
        manualReadPendingState: 'finished', success: false, errorCode: 'fixture-rejection' }), true)
    await successor
    book.runtime.close()
})

for (const boundary of ['reader', 'renderer', 'chapter', 'account', 'runtime']) {
    test(`shipping Reader refuses restored status after ${boundary} replacement`, async () => {
        const f = fixture({ realCoordinator: true }), book = bookRuntimeFixture(f)
        f.seedPage('old-page')
        const completion = f.reader.markVisiblePageAsRead(), message = f.requests[0].message
        f.lifecycle.dispatchEvent(new Event('pagehide'))
        f.lifecycle.dispatchEvent(new Event('pageshow'))
        const proof = { requestID: message.requestID, observationToken: message.manualReadPendingObservationToken }
        if (boundary === 'reader') f.context.reader = {}
        else if (boundary === 'renderer') f.reader.view.renderer = { getContents: () => [] }
        else if (boundary === 'chapter') {
            f.doc.location.href = 'ebook://fixture/replacement.xhtml'
            book.runtime.updateLocation(true)
        } else if (boundary === 'account') book.runtime.state.setAccountPresentation('2:1')
        else f.reader.bookReadingRuntime = { ...book.runtime }
        const queries = book.requests.length
        assert.equal(f.reader.applyMarkSectionAsReadResult({ requestID: message.requestID,
            manualReadPendingProtocol: 1, manualReadPendingObservationToken: proof.observationToken,
            manualReadPendingState: 'finished', manualReadPendingHistoryRecovery: true,
            manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false, success: true }), false)
        assert.equal(await completion, true, 'Retired recovery does not rewrite the committed outcome')
        assert.equal(await f.reader.recoverHistoryReadingStatus(proof), false)
        assert.equal(book.requests.length, queries)
        assert.deepEqual(f.moves, [])
        book.runtime.close()
    })
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
    assert.deepEqual(Array.from(f.requests[0].message.stableSegmentIDs), ['current-page-segment'])
    assert.deepEqual(Array.from(f.requests[0].message.sentenceIdentifiers), [])
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
        f.nextMarkSequence = (f.nextMarkSequence ?? 1) + 1
        return { success: true, stale: false, presentationAllowed: true,
            nativeResult: { stateSnapshotSequence: f.nextMarkSequence }, context: request.context }
    }
    const operation = f.reader.markVisiblePageAsRead()
    // Let the VM's async command cross its Promise realm and reach the held
    // timer without firing that timer or introducing a wall-clock delay.
    await new Promise(resolve => setImmediate(resolve))
    const advance = [...f.timers.values()].filter(timer => timer.delay === 430).at(-1)
    assert.ok(advance, 'Successful Mark must reach its existing delayed advance')
    assert.equal(f.book.publish(f.nextMarkSequence, ['current-page-segment'], ['native-completed-current-page']), true)
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

test('same-page native lookup navigation vetoes pending automatic advance without changing native success', async t => {
    const f = fixture(), book = bookRuntimeFixture(f)
    t.after(() => book.runtime.close())
    const { operation, advance } = await successfulMarkAwaitingAdvance(f)
    f.retireNavigation()
    advance.callback()
    assert.equal(await operation, true)
    assert.deepEqual(f.moves, [])
})

for (const unavailable of ['missing', 'throwing']) {
    test(`a ${unavailable} navigation-veto capture disables only automatic advance`, async t => {
        const f = fixture(), book = bookRuntimeFixture(f)
        t.after(() => book.runtime.close())
        f.doc.defaultView.manabiCaptureAutomaticScrollNavigation = unavailable === 'missing'
            ? undefined : () => { throw new Error('capture unavailable') }
        const { operation, advance } = await successfulMarkAwaitingAdvance(f)
        advance.callback()
        assert.equal(await operation, true)
        assert.deepEqual(f.moves, [])
        assert.equal(f.requests.length, 1)
    })
}

test('the navigation-veto receipt comes from the actual owner document frame', async t => {
    const f = fixture(), book = bookRuntimeFixture(f)
    t.after(() => book.runtime.close())
    let captures = 0
    f.context.manabiCaptureAutomaticScrollNavigation = () => { throw new Error('top viewer must not supply receipt') }
    f.doc.defaultView.manabiCaptureAutomaticScrollNavigation = function () {
        assert.equal(this, f.doc.defaultView)
        captures += 1
        return () => true
    }
    const { operation, advance } = await successfulMarkAwaitingAdvance(f)
    advance.callback()
    assert.equal(await operation, true)
    assert.deepEqual(f.moves, ['right'])
    assert.equal(captures, 1)
})

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

for (const restored of [false, true]) {
    test(`an older Mark cannot automatically advance after pagehide${restored ? ' and pageshow' : ''}`, async t => {
        const f = fixture(), book = bookRuntimeFixture(f)
        t.after(() => book.runtime.close())
        const event = book.runtime.captureEvent(f.doc)
        const { operation, advance } = await successfulMarkAwaitingAdvance(f)
        f.lifecycle.dispatchEvent(new Event('pagehide'))
        f.context.readerArticleProducerOwnerIsCurrent = () => false
        if (restored) f.lifecycle.dispatchEvent(new Event('pageshow'))
        assert.equal(book.runtime.isEventCurrent(event), true,
            'A retained same-account chapter may keep its book scope despite the navigation lifetime changing')
        advance.callback()
        assert.equal(await operation, true)
        assert.equal(f.reader.lastNativeMarkReadRequestOutcome, 'committed')
        assert.deepEqual(f.moves, [])
    })
}

test('a fresh Mark after restoration can advance in its own page lifetime', async t => {
    const f = fixture(), book = bookRuntimeFixture(f)
    t.after(() => book.runtime.close())
    const original = await successfulMarkAwaitingAdvance(f)
    f.lifecycle.dispatchEvent(new Event('pagehide'))
    f.lifecycle.dispatchEvent(new Event('pageshow'))
    original.advance.callback()
    assert.equal(await original.operation, true)
    const restored = await successfulMarkAwaitingAdvance(f)
    restored.advance.callback()
    assert.equal(await restored.operation, true)
    assert.deepEqual(f.moves, ['right'])
    assert.equal(f.requests.length, 2)
})

function pendingNativeMark(t) {
    const f = fixture({ realCoordinator: true }), book = bookRuntimeFixture(f)
    t.after(() => book.runtime.close())
    f.seedPage('current-page')
    const operation = f.reader.markVisiblePageAsRead()
    // Observe rejection immediately while the test controls delivery/actor
    // continuations; the original operation still preserves its own result.
    const completion = operation.then(value => ({ value }), error => ({ error }))
    assert.equal(f.requests.length, 1)
    const command = f.requests[0].message
    const deliver = (extra = {}) => f.reader.nativeMarkReadRequestCoordinator.settle({
        requestID: command.requestID, sectionId: command.sectionId,
        manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: command.manualReadPendingObservationToken,
        manualReadPendingState: 'finished', success: true,
        stateSnapshotSequence: 2, ...extra,
    })
    const join = async ({ publish = false } = {}) => {
        await new Promise(resolve => setImmediate(resolve))
        if (publish) assert.equal(book.publish(2, ['current-page-segment'], ['native-completed-current-page']), true)
        const advance = [...f.timers.values()].filter(timer => timer.delay === 430).at(-1)
        advance?.callback()
        return await completion
    }
    const withdrawScope = () => book.runtime.state.apply('native', {
        ...book.response(2), ok: false, nativeRefresh: true,
        location: { ...book.runtime.state.location,
            locationRevision: book.runtime.state.locationRevision },
    })
    return { ...f, book, deliver, join, withdrawScope }
}

for (const transition of ['account before delivery', 'scope before delivery',
    'account after delivery', 'scope after delivery', 'page after delivery',
    'lifetime after delivery', 'reader after delivery']) {
    test(`native Mark success survives ${transition} without projecting or advancing`, async t => {
        const f = pendingNativeMark(t)
        const replace = () => {
            if (transition.startsWith('account')) f.book.runtime.accountDidChange('2:1')
            else if (transition.startsWith('scope')) f.withdrawScope()
            else if (transition.startsWith('page')) f.reader.testInvalidate()
            else if (transition.startsWith('lifetime')) {
                f.lifecycle.dispatchEvent(new Event('pagehide'))
                f.lifecycle.dispatchEvent(new Event('pageshow'))
            }
            else f.context.reader = { isClosed: false }
        }
        if (transition.includes('before')) replace()
        assert.equal(f.deliver(), true)
        if (transition.includes('after')) replace()
        const result = await f.join()
        assert.equal(result.error, undefined)
        assert.equal(result.value, true)
        assert.deepEqual(Array.from(f.reader.optimisticSentenceIdentifiersRead), [])
        assert.deepEqual(Array.from(f.reader.articleReadingProgress.sentenceIdentifiersRead), [])
        assert.deepEqual(f.moves, [])
        assert.equal(f.requests.length, 1)
    })
}

test('a newer accepted native snapshot suppresses old Mark presentation without discarding its success', async t => {
    const f = pendingNativeMark(t)
    assert.equal(f.book.runtime.state.noteManualReadSnapshot(3), true)
    assert.equal(f.deliver(), true)
    const result = await f.join()
    assert.equal(result.value, true)
    assert.equal(result.error, undefined)
    assert.deepEqual(Array.from(f.reader.optimisticSentenceIdentifiersRead), [])
    assert.deepEqual(f.moves, [])
})

test('an authenticated outcome-only native success resolves without Mark projection or automatic advance', async t => {
    const f = pendingNativeMark(t)
    assert.equal(f.deliver({ manualReadPendingOutcomeOnly: true,
        manualReadPendingPresentationAllowed: false }), true)
    const result = await f.join()
    assert.equal(result.value, true)
    assert.equal(result.error, undefined)
    assert.deepEqual(Array.from(f.reader.optimisticSentenceIdentifiersRead), [])
    assert.deepEqual(f.moves, [])
})

test('a projection exception cannot reject a successfully committed native Mark', async t => {
    const f = pendingNativeMark(t)
    f.reader.applyBookReadingProgress = () => { throw new Error('projection unavailable') }
    assert.equal(f.deliver(), true)
    await new Promise(resolve => setImmediate(resolve))
    assert.throws(() => f.book.publish(2, ['current-page-segment'], ['native-completed-current-page']), /projection unavailable/)
    const result = await f.join()
    assert.equal(result.value, true)
    assert.equal(result.error, undefined)
    assert.equal(f.reader.lastNativeMarkReadRequestOutcome, 'committed')
    assert.deepEqual(f.moves, [])
})

test('an authenticated native failure remains false and never projects or advances', async t => {
    const f = pendingNativeMark(t)
    assert.equal(f.deliver({ success: false, errorCode: 'authorityUnavailable' }), true)
    const result = await f.join()
    assert.equal(result.value, false)
    assert.equal(result.error, undefined)
    assert.deepEqual(Array.from(f.reader.optimisticSentenceIdentifiersRead), [])
    assert.deepEqual(f.moves, [])
})

test('a native request exception remains an exception before any committed result', async t => {
    const f = fixture({ realCoordinator: true }), book = bookRuntimeFixture(f)
    t.after(() => book.runtime.close())
    f.seedPage('current-page')
    f.reader.nativeMarkReadRequestCoordinator.request = async () => { throw new Error('native request unavailable') }
    await assert.rejects(f.reader.markVisiblePageAsRead(), /native request unavailable/)
    assert.equal(f.requests.length, 0)
    assert.deepEqual(Array.from(f.reader.optimisticSentenceIdentifiersRead), [])
    assert.deepEqual(f.moves, [])
})

test('a current authenticated native Mark success still projects and advances once', async t => {
    const f = pendingNativeMark(t)
    assert.equal(f.deliver(), true)
    const result = await f.join({ publish: true })
    assert.equal(result.value, true)
    assert.equal(result.error, undefined)
    assert.deepEqual(Array.from(f.reader.optimisticSentenceIdentifiersRead), [])
    assert.deepEqual(Array.from(f.reader.articleReadingProgress.readSegmentIdentifiers), ['current-page-segment'])
    assert.deepEqual(Array.from(f.reader.articleReadingProgress.sentenceIdentifiersRead), ['native-completed-current-page'])
    assert.deepEqual(f.moves, ['right'])
    assert.equal(f.requests.length, 1)
})

test('a terminal book publication preserves finished progress without a chapter-scope receipt', t => {
    const f = fixture(), book = bookRuntimeFixture(f)
    t.after(() => book.runtime.close())
    assert.equal(book.runtime.state.relocate({ sectionURL: null, isEndPage: true }), true)
    const terminal = book.response(2)
    terminal.state.scope = null
    terminal.state.finished = true
    terminal.context.scope = null
    terminal.context.isEndPage = true
    terminal.context.sectionLocation = null
    assert.equal(book.runtime.state.apply(book.requests.at(-1).requestID, terminal), true)
    assert.equal(f.reader.articleReadingProgress.articleMarkedAsFinished, true)
    assert.equal(f.reader.testSuccessfulPublication(), null)
})

test('a full native publication throwing after the viewer model changes cannot advance or discard committed success', async t => {
    const f = pendingNativeMark(t)
    assert.equal(f.deliver(), true)
    await new Promise(resolve => setImmediate(resolve))
    const originalEndcap = f.reader.bookEndcap
    f.reader.bookEndcap = { setFinished() { throw new Error('endcap publication failed') } }
    assert.throws(() => f.book.publish(2, ['current-page-segment'], ['native-completed-current-page']),
        /endcap publication failed/)
    assert.deepEqual(Array.from(f.reader.articleReadingProgress.readSegmentIdentifiers), [])
    assert.equal(f.book.runtime.state.state, null)
    assert.equal(f.book.runtime.state.context, null)
    assert.equal(f.book.runtime.state.ready, false)
    assert.equal(f.reader.testSuccessfulPublication(), null)
    const result = await f.join()
    assert.equal(result.value, true)
    assert.equal(result.error, undefined)
    assert.deepEqual(f.moves, [])
    f.reader.bookEndcap = originalEndcap
    assert.equal(f.book.runtime.state.refresh(), true)
    assert.equal(f.book.publish(3, ['current-page-segment'], ['native-completed-current-page']), true)
    assert.deepEqual(Array.from(f.reader.articleReadingProgress.readSegmentIdentifiers), ['current-page-segment'])
    assert.equal(f.book.runtime.state.ready, true)
    assert.deepEqual(f.moves, [], 'A fresh display must not replay navigation for the already committed command')
})

for (const succeeded of [false, true]) {
    test(`Mark All returns the native ${succeeded ? 'success count' : 'failure count'} with outcome-only delivery`, async t => {
        const f = fixture({ realCoordinator: true }), book = bookRuntimeFixture(f)
        t.after(() => book.runtime.close())
        f.reader.buildMarkAllSectionsAsReadPayload = () => ({
            stableIdentityVersion: 1, segments: [], sentenceIdentifiers: ['entire-chapter'],
        })
        const operation = f.reader.markAllSectionsAsRead()
        const command = f.requests[0].message
        assert.equal(f.reader.nativeMarkReadRequestCoordinator.settle({
            requestID: command.requestID, sectionId: command.sectionId,
            manualReadPendingProtocol: 1,
            manualReadPendingObservationToken: command.manualReadPendingObservationToken,
            manualReadPendingState: 'finished', success: succeeded,
            stateSnapshotSequence: 2, manualReadPendingOutcomeOnly: true,
            manualReadPendingPresentationAllowed: false,
        }), true)
        assert.equal(await operation, succeeded ? 1 : 0)
        assert.deepEqual(Array.from(f.reader.optimisticSentenceIdentifiersRead), [])
        assert.deepEqual(f.moves, [])
    })
}

for (const cancelled of [false, true]) {
    test(`native Mark ${cancelled ? 'Cancel losing the commit race' : 'without cancellation'} preserves saved state ${cancelled ? 'without' : 'with'} automatic advance`, async t => {
        const f = pendingNativeMark(t)
        if (cancelled) {
            assert.equal(f.reader.nativeMarkReadRequestCoordinator.cancel(f.requests[0].message.requestID), true)
            assert.equal(f.controls.at(-1).manualReadPendingOperation, 'cancel')
        }
        assert.equal(f.deliver(), true)
        const result = await f.join({ publish: true })
        assert.equal(result.error, undefined)
        assert.equal(result.value, true, 'Cancel cannot change an authenticated committed success')
        assert.equal(f.reader.lastNativeMarkReadRequestOutcome, 'committed')
        assert.deepEqual(Array.from(f.reader.articleReadingProgress.readSegmentIdentifiers), ['current-page-segment'])
        assert.deepEqual(Array.from(f.reader.articleReadingProgress.sentenceIdentifiersRead), ['native-completed-current-page'])
        assert.deepEqual(f.moves, cancelled ? [] : ['right'])
    })
}
