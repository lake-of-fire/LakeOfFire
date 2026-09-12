import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import { createNativeMarkReadRequestCoordinator } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

// Execute the actual Reader methods, not a copied cancellation/state machine.
// DOM, renderer, and clock boundaries are doubles; this is not WebKit evidence.
const source = readFileSync(process.env.MANABI_EPUB_VIEWER_SOURCE
    || new URL('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-viewer.js', import.meta.url), 'utf8')
const between = (start, end) => {
    const from = source.indexOf(start)
    const to = source.indexOf(end, from + start.length)
    if (from < 0 || to < 0) throw new Error(`Viewer test extraction failed: ${start}`)
    return source.slice(from, to)
}
const actualMethods = [
    between('    applyBookReadingProgress(', '    async #handleCompletionAction('),
    between('    #markReadOwner(', '    buildMarkAllSectionsAsReadPayload('),
    between('    async markAllSectionsAsRead()', '    async #markPageClusterAsRead('),
    between('    async #advanceAfterMarkRead(', '    #releaseSideNavChevronHoverSuppression('),
].join('\n')
const actualCancellationBinding = between(
    "        this.#bindGlobal(window, 'manabiCancelPendingMarkReadPresentation'",
    "        this.#listen(window, 'resize'",
)
const payload = () => ({
    stableIdentityVersion: 1,
    segments: [{ stableSegmentID: 'segment', jmdictEntryIds: [1], jmnedictEntryIds: [],
        searchString: '語', sentenceIdentifier: 'sentence' }],
    sentenceIdentifiers: ['sentence'],
})
const flush = async () => { for (let i = 0; i < 8; i += 1) await Promise.resolve() }
const harness = () => {
    let timerID = 0
    let requestID = 0
    const timers = new Map()
    const posted = []
    const errors = []
    const doc = { nodeType: 9, location: { href: 'ebook://book/chapter' } }
    const window = { location: { href: 'ebook://book' }, performance: { timeOrigin: 100 } }
    window.top = window
    const setTimeout = (callback, delay) => {
        const id = ++timerID
        timers.set(id, { callback, delay })
        return id
    }
    const context = vm.createContext({
        window, setTimeout,
        console: { error: (...values) => errors.push(values) },
        stableEbookSegmentIdentityVersion: 1,
        MANABI_ENABLE_EBOOK_PAGE_TRACKING_BUTTONS: false,
        isDocumentLike: value => value?.nodeType === 9,
        getCurrentRendererDocument: renderer => renderer.doc,
        getPrimaryRendererContent: renderer => renderer?.doc ? { doc: renderer.doc } : null,
        readerDocumentStartedAtMs: () => 100,
        // This normalizer boundary is deliberately small: the actual methods
        // under test own removal/replacement and must not union old support.
        normalizeArticleReadingProgress: value => ({ ...value,
            readSegmentIdentifiers: [...(value?.readSegmentIdentifiers ?? [])],
            sentenceIdentifiersRead: [...(value?.sentenceIdentifiersRead ?? [])],
        }),
    })
    const Reader = vm.runInContext(`(class Reader {
        #lifecycleGeneration = 1
        #bindGlobal(target, name, callback) { target[name] = callback }
        #isRendererLifecycleCurrent(generation, renderer) {
            return !this.closed && generation === this.#lifecycleGeneration && renderer === this.view.renderer
        }
        #invalidateCompletionAction() { this.completionAction = null }
        async #syncPageTrackingButtons() {}
        #renderPageTrackingButtons() {
            if (this.renderThrows) throw new Error('renderer failed')
            this.renders += 1
        }
        #scheduleNativeMarkReadStateRefresh() {}
        constructor() {
            this.optimisticReadSegmentIdentifiers = new Set()
            this.optimisticSentenceIdentifiersRead = new Set()
            this.pageTrackingBusyStateIDs = new Set()
            this.pageTrackingAnimateReadStateIDs = new Set()
            this.visiblePageCollectionGeneration = 1
            this.articleReadingProgress = { readSegmentIdentifiers: [], sentenceIdentifiersRead: [] }
            this.renders = 0
            ${actualCancellationBinding}
        }
        owner() { return this.#markReadOwner({ document: this.view.renderer.doc, requireVisibleGeneration: true }) }
        submit(payload) {
            return this.#submitMarkReadPayload(payload, {
                sectionID: 'section', owner: this.owner(), reason: 'test', animateStateID: 'visible-screen',
            })
        }
        advance(outcome) {
            return this.#advanceAfterMarkRead({
                ...this.owner(), presentation: outcome.presentation, permitsAutoAdvance: outcome.permitsAutoAdvance,
            })
        }
        buildMarkAllSectionsAsReadPayload() { return this.preparedPayload }
        ${actualMethods}
    })`, context)
    const reader = new Reader()
    let moves = 0
    reader.view = {
        renderer: { doc, getContents: () => [{ doc }] },
        goRight: async () => { moves += 1; return true },
        goLeft: async () => { moves += 1; return true },
    }
    reader.preparedPayload = payload()
    reader.nativeMarkReadRequestCoordinator = createNativeMarkReadRequestCoordinator({
        postMessage: message => posted.push(message),
        makeRequestID: () => `request-${++requestID}`,
        isOwnerCurrent: owner => !reader.closed && reader.view.renderer === owner.renderer
            && reader.view.renderer.doc === owner.document,
        scheduleTimeout: setTimeout,
        cancelTimeout: id => timers.delete(id),
    })
    const reply = (index = posted.length - 1, overrides = {}) => {
        const request = posted[index]
        return reader.applyMarkSectionAsReadResult({
            requestID: request.requestID, sectionId: request.sectionId,
            success: true, permitsPresentation: true, permitsAutoAdvance: true, isMarked: true,
            stateSnapshotSequence: index + 1,
            displayEffectiveStableSegmentIDs: ['segment'],
            displayEffectiveStableSentenceIDs: ['sentence'],
            ...overrides,
        })
    }
    return { reader, window, posted, timers, reply, errors,
        cancel: id => window.manabiCancelPendingMarkReadPresentation(id),
        queuedAdvance: () => [...timers.values()].find(timer => timer.delay === 430)?.callback,
        get moves() { return moves },
    }
}

test('request identity exists during initial native await; cancellation does not fail the commit', async () => {
    const h = harness()
    const pending = h.reader.submit(payload())
    assert.equal(h.reader.pendingMarkReadPresentation.requestID, h.posted[0].requestID)
    assert.equal(h.cancel(h.posted[0].requestID), true)
    assert.equal(h.reader.nativeMarkReadRequestCoordinator.pendingCount, 1)
    h.reply()
    const outcome = await pending
    assert.equal(outcome.success, true)
    assert.equal(outcome.permitsAutoAdvance, false)
    assert.equal(outcome.presentation, null)
    assert.equal(h.reader.renders, 0)
})

test('old cancellation cannot clear a newer request while either native reply is pending', async () => {
    const h = harness()
    const first = h.reader.submit(payload())
    const firstID = h.posted[0].requestID
    const second = h.reader.submit(payload())
    const secondID = h.posted[1].requestID
    assert.equal(h.cancel(firstID), false)
    assert.equal(h.reader.pendingMarkReadPresentation.requestID, secondID)
    h.reply(1)
    const next = await second
    h.reply(0)
    const previous = await first
    assert.equal(previous.success, true)
    assert.equal(previous.presentation, null)
    assert.equal(next.permitsAutoAdvance, true)
    assert.equal(h.reader.renders, 1)
})

test('missing, empty, and foreign cancellation identities are inert', async () => {
    const h = harness()
    const pending = h.reader.submit(payload())
    for (const id of [undefined, null, '', 'foreign-request']) assert.equal(h.cancel(id), false)
    h.reply()
    assert.equal((await pending).permitsAutoAdvance, true)
})

test('fast Undo cancels an already queued EPUB advance without cancelling its saved Mark', async () => {
    const h = harness()
    const pending = h.reader.submit(payload())
    h.reply()
    const outcome = await pending
    const advance = h.reader.advance(outcome)
    const queued = h.queuedAdvance()
    assert.equal(typeof queued, 'function')
    assert.equal(h.cancel(h.posted[0].requestID), true)
    h.reader.applyBookReadingProgress({ readSegmentIdentifiers: [], sentenceIdentifiersRead: [] })
    queued()
    assert.equal(await advance, false)
    assert.equal(outcome.success, true)
    assert.equal(h.moves, 0)
    assert.deepEqual([...h.reader.articleReadingProgress.readSegmentIdentifiers], [])
})

test('old queued advance cannot move a newer pending request', async () => {
    const h = harness()
    const pending = h.reader.submit(payload())
    h.reply()
    const first = await pending
    const advance = h.reader.advance(first)
    const queued = h.queuedAdvance()
    const second = h.reader.submit(payload())
    assert.equal(h.cancel(h.posted[0].requestID), false)
    queued()
    assert.equal(await advance, false)
    assert.equal(h.moves, 0)
    h.reply(1)
    assert.equal((await second).success, true)
})

test('delayed advance rechecks document and visible-page ownership', async () => {
    for (const invalidate of [
        h => { h.reader.closed = true },
        h => { h.reader.view.renderer.doc = { nodeType: 9 } },
        h => { h.reader.visiblePageCollectionGeneration += 1 },
    ]) {
        const h = harness()
        const pending = h.reader.submit(payload())
        h.reply()
        const advance = h.reader.advance(await pending)
        const queued = h.queuedAdvance()
        invalidate(h)
        queued()
        assert.equal(await advance, false)
        assert.equal(h.moves, 0)
    }
})

test('the current permitted EPUB Mark advances exactly once after its timer', async () => {
    const h = harness()
    const pending = h.reader.submit(payload())
    h.reply()
    const advance = h.reader.advance(await pending)
    assert.equal(h.moves, 0)
    h.queuedAdvance()()
    assert.equal(await advance, true)
    assert.equal(h.moves, 1)
})

test('effective-state replacement removes requested support while retaining unrelated identities', async () => {
    const h = harness()
    h.reader.articleReadingProgress = {
        readSegmentIdentifiers: ['segment', 'other-owner'],
        sentenceIdentifiersRead: ['sentence', 'other-sentence'],
    }
    h.reader.optimisticReadSegmentIdentifiers.add('segment')
    const pending = h.reader.submit(payload())
    h.reply(0, { isMarked: false, displayEffectiveStableSegmentIDs: [], displayEffectiveStableSentenceIDs: [] })
    const outcome = await pending
    assert.equal(outcome.success, true)
    assert.equal(outcome.permitsAutoAdvance, false)
    assert.deepEqual([...h.reader.articleReadingProgress.readSegmentIdentifiers], ['other-owner'])
    assert.deepEqual([...h.reader.articleReadingProgress.sentenceIdentifiersRead], ['other-sentence'])
    assert.equal(h.reader.optimisticReadSegmentIdentifiers.size, 0)
})

test('a full native snapshot replaces optimistic support instead of unioning it', () => {
    const h = harness()
    h.reader.optimisticReadSegmentIdentifiers.add('old')
    h.reader.optimisticSentenceIdentifiersRead.add('old-sentence')
    h.reader.applyBookReadingProgress({ readSegmentIdentifiers: ['other-owner'], sentenceIdentifiersRead: [] })
    assert.deepEqual([...h.reader.articleReadingProgress.readSegmentIdentifiers], ['other-owner'])
    assert.equal(h.reader.optimisticReadSegmentIdentifiers.size, 0)
    assert.equal(h.reader.optimisticSentenceIdentifiersRead.size, 0)
})

test('a failed state-bearing reply cannot repaint or advance', async () => {
    const h = harness()
    const pending = h.reader.submit(payload())
    h.reply(0, { success: false, errorCode: 'journalFailure' })
    const outcome = await pending
    assert.equal(outcome.success, false)
    assert.equal(outcome.permitsAutoAdvance, false)
    assert.equal(h.reader.renders, 0)
})

test('a committed stale reply remains successful without repaint or advance', async () => {
    const h = harness()
    const pending = h.reader.submit(payload())
    h.reader.closed = true
    h.reply()
    const outcome = await pending
    assert.equal(outcome.success, true)
    assert.equal(outcome.presentation, null)
    assert.equal(outcome.permitsAutoAdvance, false)
    assert.equal(h.reader.renders, 0)
})

test('presentation and auto-advance permissions are not persistence success', async () => {
    for (const [presentation, advance, expectedRenders, expectedAdvance] of [
        [false, true, 0, false], [true, false, 1, false], [true, true, 1, true],
    ]) {
        const h = harness()
        const pending = h.reader.submit(payload())
        h.reply(0, { permitsPresentation: presentation, permitsAutoAdvance: advance })
        const outcome = await pending
        assert.equal(outcome.success, true)
        assert.equal(outcome.permitsAutoAdvance, expectedAdvance)
        assert.equal(h.reader.renders, expectedRenders)
    }
})

test('invalid or repeated native snapshots do not authorize presentation', async () => {
    for (const overrides of [
        { stateSnapshotSequence: 0 },
        { stateSnapshotSequence: 2.5 },
        { displayEffectiveStableSegmentIDs: ['outside-request'] },
        { displayEffectiveStableSegmentIDs: ['segment', 'segment'] },
        { displayEffectiveStableSentenceIDs: null },
    ]) {
        const h = harness()
        const pending = h.reader.submit(payload())
        h.reply(0, overrides)
        assert.equal((await pending).permitsAutoAdvance, false)
        assert.equal(h.reader.renders, 0)
    }
    const h = harness()
    const first = h.reader.submit(payload())
    h.reply()
    await first
    const second = h.reader.submit(payload())
    h.reply(1, { stateSnapshotSequence: 1 })
    assert.equal((await second).presentation, null)
    assert.equal(h.reader.renders, 1)
})

test('unavailable Mark-All preparation rejects instead of returning an ordinary zero', async () => {
    const h = harness()
    h.reader.preparedPayload = null
    await assert.rejects(h.reader.markAllSectionsAsRead(), /nativeMarkReadPreparationUnavailable/)
    assert.equal(h.posted.length, 0)
})

test('failed nested Mark prevents the awaiting Finish continuation', async () => {
    const h = harness()
    let finishes = 0
    const finish = (async () => {
        await h.reader.markAllSectionsAsRead()
        finishes += 1
    })()
    const rejected = assert.rejects(finish, /journalFailure/)
    h.reply(0, { success: false, errorCode: 'journalFailure' })
    await rejected
    assert.equal(finishes, 0)
})

test('committed no-presentation nested Mark retains its count and allows owned Finish', async () => {
    const h = harness()
    let finishes = 0
    const finish = (async () => {
        const count = await h.reader.markAllSectionsAsRead()
        assert.equal(count, 1)
        finishes += 1
    })()
    h.reply(0, { permitsPresentation: false, permitsAutoAdvance: false })
    await finish
    assert.equal(finishes, 1)
    assert.equal(h.reader.renders, 0)
    assert.equal(h.moves, 0)
})

test('committed Mark-All survives cancellation before reply without presentation', async () => {
    const h = harness()
    const pending = h.reader.markAllSectionsAsRead()
    assert.equal(h.cancel(h.posted[0].requestID), true)
    h.reply()
    assert.equal(await pending, 1)
    assert.equal(h.reader.renders, 0)
})

test('renderer exceptions cannot turn an acknowledged commit into failed Finish', async () => {
    const h = harness()
    h.reader.renderThrows = true
    const pending = h.reader.markAllSectionsAsRead()
    h.reply()
    assert.equal(await pending, 1)
    assert.equal(h.reader.lastNativeMarkReadRequestOutcome, 'committed')
    assert.equal(h.errors.length, 1)
    await flush()
    assert.equal(h.moves, 0)
})
