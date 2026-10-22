import assert from 'node:assert/strict'
import test from 'node:test'
import { createBookActionBridge } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-action-bridge.js'
import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'
import {
    captureVisibleMarkReadNavigation, createNativeMarkReadRequestCoordinator,
    refreshCommittedVisibleMarkReadState, committedVisibleMarkReadStateIsPresented,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

// Real bridge, Book-state and pending-Mark modules; native messages, clocks,
// frame navigation receipt and the Reader observer are controlled collaborators.
function fixture(t) {
    const requests = [], reads = [], marks = [], timers = new Map(), observations = []
    let timerID = 0, readID = 0, commandID = 0, navigationIdentity = {}
    const f = { onObservation() {}, beforePost() {}, producer: { required: false },
        requests, reads, marks, timers, observations }
    const scope = { articleProgressID: 'book', articleEpochID: 'pass-1',
        chapterKey: 'a'.repeat(64), chapterEpochID: 'chapter-1' }
    const state = f.state = new BookReadingStateController({
        documentStartedAtMs: 100, topWindowURL: 'ebook://book.epub',
        makeRequestID: () => `read-${++readID}`, postMessage: body => reads.push(body),
        requiresAccountPresentation: true,
    })
    f.publish = (revision = 1, overrides = {}, segments = []) => {
        const selected = { ...scope, ...overrides }
        const request = reads.at(-1)
        return state.apply(request.requestID, {
            ok: true, accountPresentation: state.accountPresentation,
            location: { ...state.location, locationRevision: state.locationRevision },
            state: { revision, ...selected, scope: selected, finished: false,
                bookReadPresence: 'present', chapterReadPresence: 'present',
                readSegmentIdentifiers: segments, sentenceIdentifiersRead: [] },
            context: { contextID: `context-${revision}`, ...selected, scope: selected,
                isEndPage: false, sectionLocation: 'chapter.xhtml' },
        })
    }
    state.setAccountPresentation('1:1')
    state.relocate({ sectionURL: 'ebook://book.epub?subpath=chapter.xhtml' })
    assert.equal(f.publish(), true)
    const frame = {
        manabiCaptureAutomaticScrollNavigation() {
            const captured = navigationIdentity
            return () => navigationIdentity === captured
        },
        manabiObserveAutomaticScrollNavigation() { navigationIdentity = {} },
    }
    f.captureNavigation = () => captureVisibleMarkReadNavigation({ defaultView: frame })
    const bridge = f.bridge = createBookActionBridge({
        postMessage: body => { f.beforePost(body); requests.push(body) },
        documentStartedAtMs: 100, topWindowURL: 'ebook://book.epub',
        captureContext: expected => state.captureContext(expected),
        captureProducerOwner: () => f.producer,
        carryProducerOwner: (body, owner) => owner ? body : null,
        makeRequestID: () => `00000000-0000-4000-8000-${String(++commandID).padStart(12, '0')}`,
        setTimer: callback => { timers.set(++timerID, callback); return timerID },
        clearTimer: id => timers.delete(id),
        onCommandAdmission: () => {
            observations.push(state.locationRevision)
            frame.manabiObserveAutomaticScrollNavigation()
            f.onObservation()
        },
    })
    bridge.setAccountPresentation('1:1')
    const mark = f.mark = createNativeMarkReadRequestCoordinator({
        postMessage: body => marks.push(body), postControlMessage() {},
        makeRequestID: () => 'page-mark', lifecycleTarget: {},
        scheduleTimeout: callback => { timers.set(++timerID, callback); return timerID },
        cancelTimeout: id => timers.delete(id),
    })
    f.reply = (request = requests.at(-1), extra = {}) => ({
        requestID: request.requestID, accountPresentation: '1:1',
        ok: true, committed: true, finished: false,
        articleEpochID: f.successor?.articleEpochID ?? 'pass-1',
        chapterEpochID: f.successor?.chapterEpochID ?? null,
        navigation: { status: 'failed' }, ...extra,
    })
    f.failedNavigation = async (action = 'startChapterOver') => {
        const operation = bridge.perform(action)
        const original = requests.at(-1)
        f.successor = action === 'startBookOver'
            ? { articleEpochID: 'pass-2', chapterEpochID: null }
            : { articleEpochID: 'pass-1', chapterEpochID: 'chapter-2' }
        state.refresh()
        assert.equal(f.publish(2, f.successor), true)
        assert.equal(bridge.acknowledge(original.deliveryID, f.reply(original)), true)
        assert.equal((await operation).committed, true)
        observations.length = 0
        return original
    }
    f.finishRetry = (result = { status: 'completed' }) => {
        const retry = requests.at(-1)
        assert.equal(bridge.acknowledge(retry.deliveryID, f.reply(retry, { navigation: result })), true)
    }
    t.after(() => { bridge.close(); mark.close(); state.close() })
    return f
}

for (const action of ['startChapterOver', 'startBookOver']) {
    test(`${action} navigation retry retires a newer page Mark receipt before native handoff`, async t => {
        const f = fixture(t)
        const original = await f.failedNavigation(action)
        const navigation = f.captureNavigation()
        const marked = f.mark.request({ sectionID: 'page', message: {
            topWindowURL: 'ebook://book.epub', documentStartedAtMs: 100,
            stableSegmentIDs: ['segment'], sentenceIdentifiers: [], desiredState: 'marked',
        } })
        let currentWhenRetryPosted
        f.beforePost = packet => { if (packet.kind === 'navigate') currentWhenRetryPosted = navigation() }
        const retry = f.bridge.recover(f.bridge.recoveryInfo)
        retry.catch(() => {})
        assert.equal(f.requests.length, 2)
        assert.equal(f.requests[1].kind, 'navigate')
        assert.equal(f.requests[1].requestID, original.requestID)
        assert.deepEqual(f.requests[1].context, original.context, 'Recovery retains the original operation')
        // Mark truth/full paint survives; only its automatic navigation is spent.
        const request = f.marks[0]
        assert.equal(f.mark.settle({ requestID: request.requestID, sectionId: 'page',
            manualReadPendingProtocol: 1, manualReadPendingObservationToken: request.manualReadPendingObservationToken,
            manualReadPendingState: 'finished', success: true, stateSnapshotSequence: 3 }), true)
        const outcome = await marked
        assert.equal(outcome.success, true)
        assert.equal(refreshCommittedVisibleMarkReadState({ outcome, state: f.state, isOwnerCurrent: () => true }), true)
        assert.equal(f.publish(3, f.successor, ['segment']), true)
        assert.equal(committedVisibleMarkReadStateIsPresented({ state: f.state, minimumSnapshotSequence: 3,
            stableSegmentIDs: ['segment'], successfulPublicationSequence: 3 }), true)
        f.finishRetry()
        assert.equal((await retry).committed, true)
        assert.equal(currentWhenRetryPosted, false, 'The older page turn must be withdrawn before retry reaches native')
        assert.equal(navigation(), false)
        assert.equal(f.observations.length, 1)
        assert.equal(f.marks.length, 1)
        assert.equal(f.requests.filter(value => value.kind === 'command').length, 1, 'No second reset')
    })
}

test('status-only recovery does not retire current page navigation', async t => {
    const f = fixture(t)
    const original = await f.failedNavigation()
    const navigation = f.captureNavigation()
    const result = await f.bridge.recover({ ...f.bridge.recoveryInfo, kind: 'status' })
    assert.equal(result.requestID, original.requestID)
    assert.equal(result.committed, true)
    assert.equal(f.requests.length, 1)
    assert.equal(f.observations.length, 0)
    assert.equal(navigation(), true)
})

test('stale-location recovery cannot retire the newer page navigation receipt', async t => {
    const f = fixture(t)
    await f.failedNavigation()
    f.state.relocate(f.state.location, { moved: true })
    const navigation = f.captureNavigation()
    const retry = f.bridge.recover(f.bridge.recoveryInfo)
    f.finishRetry({ status: 'superseded' })
    assert.equal((await retry).committed, true)
    assert.equal(navigation(), true)
    assert.equal(f.observations.length, 0)
})

test('a replacement Book pass at the same location cannot be retired by old navigation recovery', async t => {
    const f = fixture(t)
    await f.failedNavigation()
    f.state.refresh()
    assert.equal(f.publish(3, { articleEpochID: 'other-pass', chapterEpochID: null }), true)
    const navigation = f.captureNavigation()
    const retry = f.bridge.recover(f.bridge.recoveryInfo)
    f.finishRetry({ status: 'superseded' })
    assert.equal((await retry).committed, true)
    assert.equal(navigation(), true)
    assert.equal(f.observations.length, 0)
})

test('missing projection still permits read-only native recovery without inventing local navigation authority', async t => {
    const f = fixture(t)
    await f.failedNavigation()
    f.state.refresh()
    assert.equal(f.state.apply(f.reads.at(-1).requestID, { ok: false, accountPresentation: '1:1' }), false)
    assert.equal(f.state.ready, false)
    const retry = f.bridge.recover(f.bridge.recoveryInfo)
    assert.equal(f.requests.at(-1).kind, 'navigate')
    assert.equal(f.observations.length, 0)
    f.finishRetry()
    assert.equal((await retry).committed, true)
})

test('duplicate navigation recovery joins one delivery without retiring a later receipt again', async t => {
    const f = fixture(t)
    await f.failedNavigation()
    const descriptor = f.bridge.recoveryInfo
    const retry = f.bridge.recover(descriptor)
    const afterAdmission = f.captureNavigation()
    assert.equal(f.bridge.recover(descriptor), retry)
    assert.equal(afterAdmission(), true)
    assert.equal(f.requests.length, 2)
    f.finishRetry()
    await retry
    assert.equal(f.observations.length, 1)
})

test('navigation recovery without a producer cannot retire page navigation', async t => {
    const f = fixture(t)
    await f.failedNavigation()
    const navigation = f.captureNavigation()
    f.producer = null
    await assert.rejects(f.bridge.recover(f.bridge.recoveryInfo))
    assert.equal(f.requests.length, 1)
    assert.equal(f.observations.length, 0)
    assert.equal(navigation(), true)
})

test('a newer chapter pass at the same Article and location keeps its own navigation receipt', async t => {
    const f = fixture(t)
    await f.failedNavigation()
    f.state.refresh()
    assert.equal(f.publish(3, { chapterEpochID: 'chapter-3' }), true)
    const navigation = f.captureNavigation()
    const retry = f.bridge.recover(f.bridge.recoveryInfo)
    f.finishRetry({ status: 'superseded' })
    assert.equal((await retry).committed, true)
    assert.equal(navigation(), true)
    assert.equal(f.observations.length, 0)
})

test('recovery observer cannot send the original retry after replacing its account', async t => {
    const f = fixture(t)
    const original = await f.failedNavigation()
    f.onObservation = () => f.bridge.setAccountPresentation('2:1')
    const retry = f.bridge.recover(f.bridge.recoveryInfo)
    retry.catch(() => {})
    const posted = f.requests.length
    // Release the faulty baseline's live transport too; failure must not be a timeout.
    if (posted > 1) f.finishRetry()
    const result = await retry.then(value => ({ value }), error => ({ error }))
    assert.equal(posted, 1)
    assert.equal(result.error?.outcomeUnknown, true)
    assert.equal(result.error?.requestID, original.requestID)
    assert.equal(f.bridge.recoveryInfo, null)
    assert.equal(f.timers.size, 0)
})

test('recovery observer cannot send the original retry after moving to another location', async t => {
    const f = fixture(t)
    const original = await f.failedNavigation()
    f.onObservation = () => f.state.relocate(f.state.location, { moved: true })
    const retry = f.bridge.recover(f.bridge.recoveryInfo)
    retry.catch(() => {})
    const posted = f.requests.length
    if (posted > 1) f.finishRetry()
    const result = await retry.then(value => ({ value }), error => ({ error }))
    assert.equal(posted, 1)
    assert.equal(result.error?.outcomeUnknown, true)
    assert.equal(result.error?.requestID, original.requestID)
    assert.equal(f.timers.size, 0)
    // A failed optional dispatch retains status recovery for the original reset.
    f.onObservation = () => {}
    const status = f.bridge.recover({ ...f.bridge.recoveryInfo, kind: 'status' })
    assert.equal(f.requests.at(-1).kind, 'status')
    assert.equal(f.requests.at(-1).requestID, original.requestID)
    f.finishRetry({ status: 'superseded' })
    assert.equal((await status).committed, true)
    assert.equal(f.requests.filter(value => value.kind === 'command').length, 1)
})

test('observer reentry joins the already-owned retry rather than posting another navigation', async t => {
    const f = fixture(t)
    await f.failedNavigation()
    const descriptor = f.bridge.recoveryInfo
    let joined
    f.onObservation = () => { joined = f.bridge.recover(descriptor) }
    const retry = f.bridge.recover(descriptor)
    assert.equal(f.requests.length, 2)
    f.finishRetry()
    await retry
    assert.equal(joined, retry)
    assert.equal(f.observations.length, 1)
})

test('fresh Book command admission still retires navigation once, before its native command', async t => {
    const f = fixture(t)
    const navigation = f.captureNavigation()
    let currentAtPost
    f.beforePost = () => { currentAtPost = navigation() }
    const command = f.bridge.perform('startChapterOver')
    f.finishRetry()
    assert.equal((await command).committed, true)
    assert.equal(currentAtPost, false)
    assert.equal(f.observations.length, 1)
    assert.equal(f.requests.length, 1)
})

test('a stale menu and an unsupported recovery never retire current navigation', async t => {
    const f = fixture(t)
    const navigation = f.captureNavigation()
    await assert.rejects(f.bridge.perform('startChapterOver', { contextID: 'stale-menu' }))
    await assert.rejects(f.bridge.recover({ requestID: 'missing', action: 'startChapterOver', kind: 'navigate' }))
    assert.equal(navigation(), true)
    assert.equal(f.observations.length, 0)
    assert.equal(f.requests.length, 0)
})
