import assert from 'node:assert/strict'
import test from 'node:test'
import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'

import {
    createNativeMarkReadRequestCoordinator,
    nativeMarkReadCommandMessage,
    presentNativeMarkReadPending,
    refreshNativeMarkReadBookStateForRecovery,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

test('carries a native tap account presentation stamp into the immutable command', () => {
    const message = nativeMarkReadCommandMessage({
        stableIdentityVersion: 1,
        segments: [{ stableSegmentID: 'segment-a' }],
        sentenceIdentifiers: [],
    }, {
        topWindowURL: 'file:///book.epub',
        manualReadOriginAccountPresentation: '42:1',
    })

    assert.equal(message.manualReadOriginAccountPresentation, '42:1')
    assert.equal(message.topWindowURL, 'file:///book.epub')
})

test('projects semantic renderer payload onto durable native subject identifiers', () => {
    const message = nativeMarkReadCommandMessage({
        stableIdentityVersion: 1,
        nativeSidecarContentFingerprint: 'fingerprint-a',
        segments: [{
            stableSegmentID: 'segment-a',
            searchString: '読む',
            jmdictEntryIds: [1],
        }, {
            stableSegmentID: 'segment-b',
            searchString: '本',
            jmdictEntryIds: [2],
        }],
        sentenceIdentifiers: ['sentence-a'],
    }, {
        topWindowURL: 'file:///book.epub',
        pageURL: 'foliate://chapter-1',
        documentStartedAtMs: 42,
    })

    assert.deepEqual(message, {
        stableIdentityVersion: 1,
        nativeSidecarContentFingerprint: 'fingerprint-a',
        stableSegmentIDs: ['segment-a', 'segment-b'],
        sentenceIdentifiers: ['sentence-a'],
        topWindowURL: 'file:///book.epub',
        pageURL: 'foliate://chapter-1',
        documentStartedAtMs: 42,
    })
    assert.equal('segments' in message, false)
})

test('carries the immutable Core producer ticket through Mark projection', () => {
    const producerOwner = Object.freeze({
        token: 'producer-token-a',
        frameURL: 'foliate://chapter-1',
        documentStartedAtMs: 42,
    })
    const message = nativeMarkReadCommandMessage({
        stableIdentityVersion: 1,
        segments: [{ stableSegmentID: 'segment-a' }],
        sentenceIdentifiers: [],
    }, { producerOwner })

    assert.deepEqual(message.readerArticleProducer, producerOwner)
    assert.notStrictEqual(message.readerArticleProducer, producerOwner)
    assert.equal(Object.getOwnPropertyDescriptor(message, 'readerArticleProducer').writable, false)
})

const terminalFor = (message, result = {}) => ({
    requestID: message.requestID,
    sectionId: message.sectionId,
    manualReadPendingProtocol: 1,
    manualReadPendingObservationToken: message.manualReadPendingObservationToken,
    manualReadPendingState: 'finished',
    success: true,
    ...result,
})

const harness = ({ current = true, postThrows = false, lifecycleTarget, onRecovery, onRecoveryQuery, onRecoveryIsCurrent, onTimerCancelled } = {}) => {
    const posted = []
    const controls = []
    const pendingStates = []
    const timeouts = new Map()
    const timeoutDelays = new Map()
    let timeoutSequence = 0
    const coordinator = createNativeMarkReadRequestCoordinator({
        postMessage: message => {
            if (postThrows) throw new Error('bridge unavailable')
            posted.push(message)
        },
        postControlMessage: message => controls.push(message),
        onPending: state => pendingStates.push({
            requestID: state.requestID,
            phase: state.phase,
            recoveryOnly: state.recoveryOnly,
            cancel: state.cancel,
        }),
        lifecycleTarget,
        onRecovery,
        onRecoveryQuery,
        onRecoveryIsCurrent,
        isOwnerCurrent: () => current,
        makeRequestID: () => 'request',
        scheduleTimeout: (callback, delay) => {
            const id = ++timeoutSequence
            timeouts.set(id, () => {
                // Model real setTimeout: a fired one-shot handle is no longer
                // pending before its callback schedules any follow-up poll.
                timeouts.delete(id)
                timeoutDelays.delete(id)
                callback()
            })
            timeoutDelays.set(id, delay)
            return id
        },
        cancelTimeout: id => {
            timeoutDelays.delete(id)
            const removed = timeouts.delete(id)
            onTimerCancelled?.()
            return removed
        },
    })
    return {
        coordinator,
        posted,
        controls,
        pendingStates,
        timeouts,
        timeoutDelays,
        setCurrent(value) {
            current = value
        },
    }
}

test('command, status and cancellation retain the captured producer document timestamp', async () => {
    const h = harness()
    const producerOwner = Object.freeze({
        token: 'producer-token-a',
        frameURL: 'ebook://book/viewer',
        documentStartedAtMs: 42,
    })
    const message = nativeMarkReadCommandMessage({
        stableIdentityVersion: 1,
        segments: [{ stableSegmentID: 'segment-a' }],
        sentenceIdentifiers: [],
    }, {
        topWindowURL: 'ebook://book/viewer',
        documentStartedAtMs: 43,
        producerOwner,
    })
    const completion = h.coordinator.request({ sectionID: 'section-a', message })
    const posted = h.posted[0]
    assert.equal(posted.documentStartedAtMs, producerOwner.documentStartedAtMs)
    assert.deepEqual(posted.readerArticleProducer, producerOwner)

    const slowCallback = [...h.timeouts.values()][0]
    slowCallback()
    assert.equal(h.controls[0].manualReadPendingOperation, 'status')
    assert.equal(h.controls[0].documentStartedAtMs, producerOwner.documentStartedAtMs)
    h.coordinator.cancel(posted.requestID)
    assert.equal(h.controls.at(-1).manualReadPendingOperation, 'cancel')
    assert.equal(h.controls.at(-1).documentStartedAtMs, producerOwner.documentStartedAtMs)
    assert.equal(h.controls.at(-1).manualReadPendingObservationToken,
        posted.manualReadPendingObservationToken)

    h.coordinator.settle(terminalFor(posted, { success: false, errorCode: 'cancelled' }))
    assert.equal((await completion).success, false)
    assert.equal(h.coordinator.pendingCount, 0)
})

test('publishes success only after the exact pending-protocol native reply', async () => {
    const h = harness()
    const completion = h.coordinator.request({
        sectionID: 'section-a',
        message: {
            segments: [{ stableSegmentID: 'segment-a' }],
            topWindowURL: 'file:///book.epub',
            documentStartedAtMs: 42,
        },
        context: { stateID: 'visible-screen' },
    })

    assert.equal(h.posted.length, 1)
    assert.equal(h.posted[0].requestID, 'request-1')
    assert.equal(h.posted[0].sectionId, 'section-a')
    assert.equal(h.posted[0].manualReadPendingProtocol, 1)
    assert.equal(h.posted[0].manualReadPendingObservationToken.length, 32)
    assert.equal(h.coordinator.pendingCount, 1)

    const nativeResult = terminalFor(h.posted[0])
    assert.equal(h.coordinator.settle(nativeResult), true)

    assert.deepEqual(await completion, {
        requestID: 'request-1',
        context: { stateID: 'visible-screen' },
        success: true,
        outcomeKnown: true,
        stale: false,
        presentationAllowed: true,
        errorCode: null,
        nativeResult,
    })
    assert.equal(h.coordinator.pendingCount, 0)
    assert.equal(h.timeouts.size, 0)
})

test('15 seconds observes the original request instead of expiring it', async () => {
    const h = harness()
    let completed = false
    const completion = h.coordinator.request({
        sectionID: 'section-a',
        message: {
            segments: [],
            topWindowURL: 'file:///book.epub',
            documentStartedAtMs: 42,
        },
    }).then(result => {
        completed = true
        return result
    })

    assert.deepEqual([...h.timeoutDelays.values()], [15_000])
    const slowCallback = [...h.timeouts.values()][0]
    slowCallback()
    await Promise.resolve()

    assert.equal(completed, false)
    assert.equal(h.coordinator.pendingCount, 1)
    assert.equal(h.controls.length, 1)
    assert.equal(h.controls[0].requestID, 'request-1')
    assert.equal(h.controls[0].manualReadPendingOperation, 'status')
    assert.equal(h.controls[0].manualReadPendingObservationToken,
        h.posted[0].manualReadPendingObservationToken)
    assert.deepEqual([...h.timeoutDelays.values()], [5_000])

    assert.equal(h.coordinator.settle(terminalFor(h.posted[0])), true)
    assert.equal((await completion).success, true)
})

test('committed success remains success after the renderer owner becomes stale', async () => {
    const h = harness()
    const completion = h.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [] },
        owner: { lifecycle: 1 },
    })
    h.setCurrent(false)

    assert.equal(h.coordinator.settle(terminalFor(h.posted[0])), true)
    const result = await completion
    assert.equal(result.success, true)
    assert.equal(result.stale, true)
    assert.equal(result.presentationAllowed, false)
    assert.equal(result.errorCode, null)
})

test('mismatched section cannot settle the real request and duplicate terminal replies are inert', async () => {
    const h = harness()
    const completion = h.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [] },
    })

    assert.equal(h.coordinator.settle(terminalFor(h.posted[0], {
        sectionId: 'section-b',
    })), false)
    assert.equal(h.coordinator.pendingCount, 1)

    assert.equal(h.coordinator.settle(terminalFor(h.posted[0])), true)
    assert.equal((await completion).success, true)
    assert.equal(h.coordinator.settle(terminalFor(h.posted[0])), false)
})

test('synchronous bridge failure is terminal because native never received the mutation', async () => {
    const h = harness({ postThrows: true })
    const result = await h.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [] },
    })

    assert.equal(result.success, false)
    assert.equal(result.stale, false)
    assert.equal(result.presentationAllowed, false)
    assert.match(result.errorCode, /bridge unavailable/)
    assert.equal(h.coordinator.pendingCount, 0)
    assert.equal(h.timeouts.size, 0)
    assert.equal(h.controls.length, 0)
})

test('slow observation accepts a later native completion instead of manufacturing timeout failure', async () => {
    const h = harness()
    let completed = false
    const completion = h.coordinator.request({
        sectionID: 'section-a',
        message: {
            segments: [],
            topWindowURL: 'file:///book.epub',
            documentStartedAtMs: 42,
        },
    }).then(result => {
        completed = true
        return result
    })
    const retainedSlowCallback = [...h.timeouts.values()][0]
    retainedSlowCallback()
    await Promise.resolve()

    assert.equal(completed, false)
    assert.equal(h.coordinator.pendingCount, 1)
    assert.equal(h.controls.at(-1).manualReadPendingOperation, 'status')

    assert.equal(h.coordinator.settle(terminalFor(h.posted[0])), true)
    const result = await completion
    assert.equal(result.success, true)
    assert.equal(result.errorCode, null)
    assert.equal(h.coordinator.pendingCount, 0)
    assert.equal(h.timeouts.size, 0)
})

test('cancellation waits for native outcome and retained callbacks are inert after join', async () => {
    const h = harness()
    let completionCount = 0
    let completed = false
    const completion = h.coordinator.request({
        sectionID: 'section-b',
        message: {
            segments: [],
            topWindowURL: 'file:///book.epub',
            documentStartedAtMs: 42,
        },
    }).then(result => {
        completed = true
        completionCount += 1
        return result
    })
    const retainedTimeoutCallback = [...h.timeouts.values()][0]

    h.coordinator.cancelAll()
    await Promise.resolve()
    assert.equal(completed, false)
    assert.equal(h.coordinator.pendingCount, 1)
    assert.equal(h.controls.at(-1).manualReadPendingOperation, 'cancel')
    assert.equal(h.controls.at(-1).requestID, 'request-1')

    assert.equal(h.coordinator.settle(terminalFor(h.posted[0], {
        success: false,
        errorCode: 'cancelled',
    })), true)
    const cancelled = await completion
    assert.equal(cancelled.success, false)
    assert.equal(cancelled.stale, false)
    assert.equal(cancelled.errorCode, 'cancelled')
    assert.equal(h.coordinator.pendingCount, 0)
    assert.equal(h.timeouts.size, 0)

    const controlCount = h.controls.length
    retainedTimeoutCallback()
    assert.equal(h.controls.length, controlCount)
    assert.equal(h.timeouts.size, 0)
    assert.equal(h.coordinator.settle(terminalFor(h.posted[0])), false)
    assert.strictEqual(await completion, cancelled)
    await Promise.resolve()
    assert.equal(completionCount, 1)
})

test('coalesces the exact pending intent without replaying native mutation', async () => {
    const h = harness()
    const message = { segments: [{ stableSegmentID: 'segment-a' }], desiredState: 'marked' }
    const first = h.coordinator.request({ sectionID: 'section-a', message })
    const second = h.coordinator.request({ sectionID: 'section-a', message })

    assert.strictEqual(second, first)
    assert.equal(h.posted.length, 1)
    assert.equal(h.coordinator.pendingCount, 1)

    assert.equal(h.coordinator.settle(terminalFor(h.posted[0])), true)
    assert.strictEqual(await first, await second)
})

test('long sessions keep admitting requests without reusing old identities', async () => {
    const h = harness()
    let firstReply
    for (let index = 0; index < 2_050; index += 1) {
        const completion = h.coordinator.request({
            sectionID: 'section-a',
            message: { segments: [], desiredState: index % 2 ? 'unmarked' : 'marked' },
        })
        const posted = h.posted.at(-1)
        assert.equal(posted.requestID, `request-${index + 1}`)
        const reply = terminalFor(posted)
        if (index === 0) firstReply = reply
        assert.equal(h.coordinator.settle(reply), true)
        assert.equal((await completion).success, true)
    }

    const next = h.coordinator.request({
        sectionID: 'section-a', message: { segments: [], desiredState: 'unmarked' },
    })
    assert.equal(h.posted.at(-1).requestID, 'request-2051')
    assert.equal(h.coordinator.settle(firstReply), false)
    assert.equal(h.coordinator.pendingCount, 1)
    assert.equal(h.coordinator.settle(terminalFor(h.posted.at(-1))), true)
    assert.equal((await next).success, true)
})

test('rejects a conflicting intent while the target remains owned by the first request', async () => {
    const h = harness()
    const first = h.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [{ stableSegmentID: 'segment-a' }], desiredState: 'marked' },
    })
    const conflicting = await h.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [{ stableSegmentID: 'segment-a' }], desiredState: 'unmarked' },
    })

    assert.equal(conflicting.success, false)
    assert.equal(conflicting.errorCode, 'pendingTargetBusy')
    assert.equal(conflicting.presentationAllowed, false)
    assert.equal(h.posted.length, 1)
    assert.equal(h.coordinator.pendingCount, 1)

    h.coordinator.settle(terminalFor(h.posted[0]))
    assert.equal((await first).success, true)
})

test('wrong observation capability cannot settle or cancel the real request', async () => {
    const h = harness()
    const completion = h.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [] },
    })

    assert.equal(h.coordinator.settle({
        ...terminalFor(h.posted[0]),
        manualReadPendingObservationToken: '0'.repeat(32),
    }), false)
    assert.equal(h.coordinator.pendingCount, 1)

    assert.equal(h.coordinator.settle(terminalFor(h.posted[0])), true)
    assert.equal((await completion).success, true)
})

test('pending and unknown status packets are observations, never terminal failures', async () => {
    const h = harness()
    let completed = false
    const completion = h.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [] },
    }).then(result => {
        completed = true
        return result
    })
    const identity = {
        requestID: h.posted[0].requestID,
        manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: h.posted[0].manualReadPendingObservationToken,
    }

    assert.equal(h.coordinator.settle({
        ...identity,
        manualReadPendingState: 'pending',
    }), false)
    assert.equal(h.coordinator.settle({
        ...identity,
        manualReadPendingState: 'unknown',
    }), false)
    await Promise.resolve()
    assert.equal(completed, false)
    assert.equal(h.coordinator.pendingCount, 1)

    h.coordinator.settle(terminalFor(h.posted[0]))
    assert.equal((await completion).success, true)
})

const unavailableFor = message => ({
    requestID: message.requestID,
    manualReadPendingProtocol: 1,
    manualReadPendingObservationToken: message.manualReadPendingObservationToken,
    manualReadPendingState: 'unavailable',
    manualReadPendingHistoryRecovery: true,
    manualReadPendingOutcomeOnly: true,
    manualReadPendingPresentationAllowed: false,
    errorCode: 'outcomeUnavailable',
})

for (const success of [true, false]) {
    test(`retained ${success ? 'success' : 'failure'} acknowledges only its exact history receipt`, async () => {
        let current = true, preparations = 0, queries = 0
        const h = harness({ onRecovery: () => { preparations++; return true },
            onRecoveryQuery: () => { queries++; return true },
            onRecoveryIsCurrent: () => current })
        const completion = h.coordinator.request({ sectionID: 'section-a', message: {} })
        const message = h.posted[0]
        h.coordinator.pause()
        const terminal = terminalFor(message, { success,
            ...(success ? {} : { errorCode: 'cancelled' }) })
        assert.equal(h.coordinator.settle(terminal), true)
        assert.equal((await completion).success, success)
        assert.equal(h.controls.length, 1)
        assert.equal(h.controls[0].manualReadPendingHistoryRecovery, true)
        h.coordinator.resume()
        const history = { ...terminal, manualReadPendingHistoryRecovery: true,
            manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false }
        for (const invalid of [terminal,
            { ...history, requestID: 'other' },
            { ...history, manualReadPendingProtocol: 2 },
            { ...history, manualReadPendingObservationToken: 'foreign' },
            { ...history, manualReadPendingHistoryRecovery: false },
            { ...history, manualReadPendingOutcomeOnly: false },
            { ...history, manualReadPendingPresentationAllowed: true },
            { ...history, manualReadPendingState: 'pending' },
            { ...history, success: !success },
            { ...history, success: 1 },
            ...(success ? [] : [{ ...history, errorCode: 'different-failure' }]),
        ]) assert.equal(h.coordinator.settle(invalid), false)
        current = false
        assert.equal(h.coordinator.settle(history), false)
        current = true
        assert.equal(h.coordinator.settle(history), true)
        assert.equal(h.coordinator.settle(history), true)
        assert.equal(preparations, 1)
        assert.equal(queries, 0)
        assert.equal(h.posted.length, 1)
        assert.equal(h.controls.length, 1)
        assert.equal(h.coordinator.pendingCount, 0)
        assert.equal(await h.coordinator.recoverHistoryReadingStatus({ requestID: message.requestID,
            observationToken: message.manualReadPendingObservationToken }), true)
        assert.equal(queries, 1)
        assert.equal(h.coordinator.settle(history), false)
    })
}

test('retiring during retained receipt ownership check cannot acknowledge a removed barrier', async () => {
    let retire = false
    const h = harness({ onRecovery: () => true, onRecoveryIsCurrent: () => {
        if (retire) h.coordinator.retireHistoryRecoveries()
        return true
    } })
    const completion = h.coordinator.request({ sectionID: 'section-a', message: {} })
    h.coordinator.pause()
    const terminal = terminalFor(h.posted[0])
    assert.equal(h.coordinator.settle(terminal), true)
    await completion
    retire = true
    assert.equal(h.coordinator.settle({ ...terminal, manualReadPendingHistoryRecovery: true,
        manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false }), false)
})

test('restored viewer observes history and cannot send an old Cancel or replay a command', async () => {
    const listeners = new Map()
    const h = harness({ lifecycleTarget: {
        addEventListener: (name, callback) => listeners.set(name, callback),
        removeEventListener: name => listeners.delete(name),
    } })
    const completion = h.coordinator.request({ sectionID: 'section-a', message: {
        topWindowURL: 'file:///book.epub', documentStartedAtMs: 42,
    } })
    const staleTimer = [...h.timeouts.values()][0]
    listeners.get('pagehide')()
    assert.equal(h.pendingStates.at(-1).recoveryOnly, true)
    assert.equal(h.coordinator.cancel(h.posted[0].requestID), false)
    staleTimer()
    assert.equal(h.controls.length, 0)
    listeners.get('pageshow')()
    ;[...h.timeouts.values()][0]()
    assert.equal(h.controls[0].manualReadPendingOperation, 'status')
    assert.equal(h.controls[0].manualReadPendingHistoryRecovery, true)
    assert.equal(h.controls[0].manualReadPendingObservationToken,
        h.posted[0].manualReadPendingObservationToken)
    assert.equal(h.posted.length, 1)
    assert.equal(h.coordinator.settle(unavailableFor(h.posted[0])), true)
    const outcome = await completion
    assert.equal(outcome.outcomeKnown, false)
    assert.equal(outcome.success, undefined)
    assert.equal(outcome.presentationAllowed, false)
    assert.equal(h.coordinator.pendingCount, 0)
})

test('authenticated unavailable settles exact history truth without inventing failure', async () => {
    const h = harness()
    const completion = h.coordinator.request({ sectionID: 'section-a', message: {} })
    const unavailable = unavailableFor(h.posted[0])
    for (const invalid of [
        { ...unavailable, manualReadPendingObservationToken: 'foreign' },
        { ...unavailable, manualReadPendingHistoryRecovery: false },
        { ...unavailable, manualReadPendingOutcomeOnly: false },
        { ...unavailable, manualReadPendingPresentationAllowed: true },
        { ...unavailable, errorCode: 'nativeCommitFailed' },
        { ...unavailable, success: false },
    ]) {
        assert.equal(h.coordinator.settle(invalid), false)
        assert.equal(h.coordinator.pendingCount, 1)
    }
    assert.equal(h.coordinator.settle(unavailable), true)
    assert.equal((await completion).outcomeKnown, false)
    assert.equal(h.coordinator.settle(unavailable), false)
})

test('native retired history success preserves outcome while declining old presentation', async () => {
    const h = harness()
    const completion = h.coordinator.request({ sectionID: 'section-a', message: {} })
    assert.equal(h.coordinator.settle(terminalFor(h.posted[0], {
        manualReadPendingHistoryRecovery: true,
        manualReadPendingOutcomeOnly: true,
        manualReadPendingPresentationAllowed: false,
    })), true)
    const outcome = await completion
    assert.equal(outcome.outcomeKnown, true)
    assert.equal(outcome.success, true)
    assert.equal(outcome.presentationAllowed, false)
})

test('ordinary unknown keeps observing ordinary admission rather than sealing history', async () => {
    const h = harness()
    const completion = h.coordinator.request({ sectionID: 'section-a', message: {} })
    assert.equal(h.coordinator.settle({
        ...terminalFor(h.posted[0]), manualReadPendingState: 'unknown',
    }), false)
    ;[...h.timeouts.values()][0]()
    assert.equal(h.controls.at(-1).manualReadPendingHistoryRecovery, undefined)
    assert.equal(h.coordinator.cancel(h.posted[0].requestID), true)
    h.coordinator.settle(terminalFor(h.posted[0], { success: false }))
    await completion
})

test('restored native pending notice visibly withdraws Cancel until exact outcome', () => {
    const previous = globalThis.document
    const element = () => ({
        children: [], attributes: {}, listeners: {},
        append(...children) { this.children.push(...children) },
        setAttribute(name, value) { this.attributes[name] = value },
        addEventListener(name, callback) { this.listeners[name] = callback },
        remove() { this.removed = true },
        get firstElementChild() { return this.children[0] },
        get lastElementChild() { return this.children.at(-1) },
    })
    const body = element()
    globalThis.document = { body, createElement: element }
    try {
        const state = { requestID: 'history-notice', phase: 'pending', cancel() {} }
        presentNativeMarkReadPending(state)
        const notice = body.children[0]
        presentNativeMarkReadPending({ ...state, recoveryOnly: true })
        assert.equal(notice.lastElementChild.hidden, true)
        assert.equal(notice.lastElementChild.disabled, true)
        assert.match(notice.firstElementChild.textContent, /Recovering/)
        presentNativeMarkReadPending({ ...state, phase: 'recovery-failed', recoveryOnly: true,
            outcomeKnown: true, success: true })
        assert.match(notice.firstElementChild.textContent, /reading change was saved/)
        assert.match(notice.firstElementChild.textContent, /Close and reopen this book to continue/)
        assert.equal(notice.lastElementChild.hidden, true)
        assert.equal(notice.lastElementChild.disabled, true)
        assert.doesNotMatch(notice.firstElementChild.textContent, /Still saving|Waiting for/)
        presentNativeMarkReadPending({ ...state, phase: 'recovery-failed', recoveryOnly: true,
            outcomeKnown: false })
        assert.match(notice.firstElementChild.textContent, /outcome is unavailable/)
        assert.doesNotMatch(notice.firstElementChild.textContent, /wasn’t saved/)
        presentNativeMarkReadPending({ ...state, phase: 'finished' })
        assert.equal(notice.removed, true)
    } finally { globalThis.document = previous }
})

test('restored outcome joins while existing book state waits for a matching fresh context', async () => {
    const messages = []
    let sequence = 0
    const state = new BookReadingStateController({
        postMessage: message => messages.push(message),
        documentStartedAtMs: 42, topWindowURL: 'file:///book.epub',
        makeRequestID: () => 'state-' + ++sequence,
    })
    const scope = { articleProgressID: 'book', articleEpochID: 'E1',
        chapterKey: 'a'.repeat(64), chapterEpochID: null }
    const response = revision => ({ ok: true, accountPresentation: '0:1',
        location: { sectionURL: 'chapter.xhtml', isEndPage: false, locationRevision: state.locationRevision },
        state: { revision, articleProgressID: 'book', articleEpochID: 'E1', scope,
            finished: false, bookReadPresence: 'present', chapterReadPresence: 'present',
            readSegmentIdentifiers: ['segment'], sentenceIdentifiersRead: [] },
        context: { contextID: 'context-' + revision, articleProgressID: 'book',
            articleEpochID: 'E1', scope, sectionLocation: 'chapter.xhtml', isEndPage: false },
    })
    state.relocate({ sectionURL: 'chapter.xhtml' })
    const previous = messages[0]
    assert.equal(state.apply(previous.requestID, response(1)), true)
    const h = harness({ onRecovery: ({ isCurrent, observation }) =>
        refreshNativeMarkReadBookStateForRecovery({ state }, scope, isCurrent, observation),
        onRecoveryQuery: observation => state.recoverHistoryReadingStatus(observation) })
    const completion = h.coordinator.request({ sectionID: 'section-a', message: {} })
    h.coordinator.pause()
    h.coordinator.resume()
    assert.equal(h.coordinator.settle(unavailableFor(h.posted[0])), true)
    assert.equal((await completion).outcomeKnown, false)
    assert.equal(state.ready, false)
    assert.equal(state.captureScope('chapter.xhtml'), null)
    assert.equal(messages.length, 1, 'Terminal delivery only withdraws stale authority')
    const acknowledged = h.coordinator.recoverHistoryReadingStatus({ requestID: h.posted[0].requestID,
        observationToken: h.posted[0].manualReadPendingObservationToken })
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(messages.length, 2)
    assert.equal(state.apply(previous.requestID, response(2)), false)
    assert.equal(state.ready, false)
    assert.equal(state.apply(messages[1].requestID, { ...response(2),
        historyRecoveryObservation: messages[1].historyRecoveryObservation }), true)
    assert.equal(await acknowledged, true)
    assert.equal(state.ready, true)
})

test('history recovery callback failure cannot erase joined native success', async () => {
    for (const error of [new Error('projection failed'), Object.create(null)]) {
        const h = harness({ onRecovery: () => { throw error } })
        const completion = h.coordinator.request({ sectionID: 'section-a', message: {} })
        h.coordinator.pause()
        h.coordinator.resume()
        assert.equal(h.coordinator.settle(terminalFor(h.posted[0], {
            manualReadPendingHistoryRecovery: true,
            manualReadPendingOutcomeOnly: true,
            manualReadPendingPresentationAllowed: false,
        })), true)
        assert.equal((await completion).success, true)
        assert.equal(h.coordinator.pendingCount, 0)
        assert.equal(h.pendingStates.at(-1).phase, 'recovery-failed')
    }
})
test('retired native recovery cannot leave failure chrome on its replacement owner', async () => {
    const h = harness({ onRecovery: () => false, onRecoveryIsCurrent: () => false })
    const completion = h.coordinator.request({ sectionID: 'old-section', message: {} })
    h.coordinator.pause(); h.coordinator.resume()
    assert.equal(h.coordinator.settle(unavailableFor(h.posted[0])), true)
    assert.equal((await completion).outcomeKnown, false)
    assert.equal(h.pendingStates.at(-1).phase, 'finished')
    assert.equal(h.pendingStates.at(-1).recoveryOnly, false)
})

test('recovery callback cannot admit a fresh mutation from the retired presentation', async () => {
    let successor
    const h = harness({ onRecovery: () => {
        successor ??= h.coordinator.request({ sectionID: 'section-a', message: { edition: 2 } })
    } })
    const completion = h.coordinator.request({ sectionID: 'section-a', message: { edition: 1 } })
    const old = h.posted[0]
    const retainedTimer = [...h.timeouts.values()][0]
    h.coordinator.pause()
    h.coordinator.resume()
    assert.equal(h.coordinator.settle(terminalFor(old, {
        manualReadPendingHistoryRecovery: true,
        manualReadPendingOutcomeOnly: true,
        manualReadPendingPresentationAllowed: false,
    })), true)
    assert.equal((await completion).success, true)
    assert.equal(h.coordinator.pendingCount, 0)
    assert.equal(h.posted.length, 1)
    retainedTimer()
    assert.equal(h.controls.length, 0)
    assert.equal(h.coordinator.cancel(old.requestID), false)
    assert.equal((await successor).success, false)
    assert.equal((await successor).errorCode, 'pendingCapacityExceeded')
    assert.equal(h.coordinator.pendingCount, 0)
})

test('pause cleanup cannot resurrect a notice after terminal reentry', async () => {
    const h = harness({ onTimerCancelled: () => {
        h.coordinator.settle(terminalFor(h.posted[0]))
    } })
    const completion = h.coordinator.request({ sectionID: 'section-a', message: {} })
    h.coordinator.pause()
    assert.equal((await completion).success, true)
    assert.equal(h.coordinator.pendingCount, 0)
    assert.equal(h.pendingStates.at(-1).phase, 'recovery-failed')
    assert.equal(h.pendingStates.at(-1).recoveryOnly, true)
})

test('pause cleanup retains a timer installed by reentrant resume', async () => {
    let resumed = false
    const h = harness({ onTimerCancelled: () => {
        if (!resumed) { resumed = true; h.coordinator.resume() }
    } })
    const completion = h.coordinator.request({ sectionID: 'section-a', message: {} })
    h.coordinator.pause()
    assert.equal(h.timeouts.size, 1)
    h.coordinator.pause()
    assert.equal(h.timeouts.size, 0)
    h.coordinator.settle(terminalFor(h.posted[0]))
    await completion
})

test('recovery defers to an ordinary successor and suppresses its old optional paint', async () => {
    let recoveries = 0
    const h = harness({ onRecovery: () => { recoveries++ } })
    const original = h.coordinator.request({ sectionID: 'section-a', message: {} })
    const old = h.posted[0]
    h.coordinator.pause()
    h.coordinator.resume()
    const successor = h.coordinator.request({ sectionID: 'section-b', message: {} })
    assert.equal(h.coordinator.settle(unavailableFor(old)), true)
    assert.equal((await original).outcomeKnown, false)
    assert.equal(recoveries, 0)
    assert.equal(h.coordinator.pendingCount, 1)
    assert.equal(h.controls.length, 0, 'Recovery must not send Cancel to a newer command')
    assert.equal(h.coordinator.settle(terminalFor(h.posted[1])), true)
    const outcome = await successor
    assert.equal(outcome.success, true)
    assert.equal(outcome.presentationAllowed, false)
    assert.equal(recoveries, 1)
    assert.equal(h.coordinator.pendingCount, 0)
})

test('chapter history recovery cannot adopt an accepted or pending end-page context', () => {
    const messages = []
    let sequence = 0
    const state = new BookReadingStateController({
        postMessage: message => messages.push(message), documentStartedAtMs: 42,
        topWindowURL: 'file:///book.epub', makeRequestID: () => 'state-' + ++sequence,
    })
    state.relocate({ isEndPage: true })
    assert.equal(state.apply(messages[0].requestID, { ok: true,
        state: { revision: 1, articleProgressID: 'book', articleEpochID: 'E1', scope: null,
            finished: false, bookReadPresence: 'present', chapterReadPresence: 'empty',
            readSegmentIdentifiers: [], sentenceIdentifiersRead: [] },
        context: { contextID: 'end-page', articleProgressID: 'book', articleEpochID: 'E1',
            scope: null, sectionLocation: null, isEndPage: true },
    }), true)
    const chapterScope = { articleProgressID: 'book', articleEpochID: 'E1',
        chapterKey: 'a'.repeat(64), chapterEpochID: null }
    assert.equal(refreshNativeMarkReadBookStateForRecovery({ state }, chapterScope), false)
    assert.equal(state.ready, true)
    assert.equal(messages.length, 1)
    state.relocate(state.location, { replaced: true })
    assert.equal(state.context, null)
    assert.equal(refreshNativeMarkReadBookStateForRecovery({ state }, chapterScope), false)
    assert.equal(state.ready, false)
    assert.equal(messages.length, 2)
})

test('throwing terminal timer cleanup cannot strand received native truth', async () => {
    const h = harness({ onTimerCancelled: () => { throw new Error('cleanup failed') } })
    const completion = h.coordinator.request({ sectionID: 'section-a', message: {} })
    assert.equal(h.coordinator.settle(terminalFor(h.posted[0])), true)
    assert.equal((await completion).success, true)
    assert.equal(h.coordinator.pendingCount, 0)
    assert.equal(h.pendingStates.at(-1).phase, 'finished')
})

test('outcome-only recovery preserves committed success without presentation authority', async () => {
    const h = harness()
    const completion = h.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [] },
    })

    assert.equal(h.coordinator.settle(terminalFor(h.posted[0], {
        sectionId: 'not-the-original-target',
        manualReadPendingOutcomeOnly: true,
        manualReadPendingPresentationAllowed: false,
    })), true)

    const result = await completion
    assert.equal(result.success, true)
    assert.equal(result.stale, false)
    assert.equal(result.presentationAllowed, false)
})

test('pause suppresses observation and resume observes the same request identity', async () => {
    let preparations = 0, queries = 0
    const h = harness({
        onRecovery: () => { preparations++; return true },
        onRecoveryQuery: () => { queries++; return true },
        onRecoveryIsCurrent: () => true,
    })
    const completion = h.coordinator.request({
        sectionID: 'section-a',
        message: {
            segments: [],
            topWindowURL: 'file:///book.epub',
            documentStartedAtMs: 42,
        },
    })
    const requestID = h.posted[0].requestID
    const token = h.posted[0].manualReadPendingObservationToken

    h.coordinator.pause()
    assert.equal(h.coordinator.pendingCount, 1)
    assert.equal(h.timeouts.size, 0)
    assert.equal(h.controls.length, 0)

    h.coordinator.resume()
    assert.deepEqual([...h.timeoutDelays.values()], [0])
    const resumedObservation = [...h.timeouts.values()][0]
    resumedObservation()
    assert.equal(h.controls.length, 1)
    assert.equal(h.controls[0].requestID, requestID)
    assert.equal(h.controls[0].manualReadPendingObservationToken, token)
    assert.equal(h.controls[0].manualReadPendingOperation, 'status')

    assert.equal(h.controls[0].manualReadPendingHistoryRecovery, true)
    assert.equal(h.coordinator.settle(terminalFor(h.posted[0])), true,
        'The delayed original reply retains its immutable native outcome')
    const outcome = await completion
    assert.equal(outcome.success, true)
    assert.equal(outcome.outcomeKnown, true)
    assert.equal(outcome.presentationAllowed, false)
    assert.equal(queries, 0, 'Receiving the original outcome cannot authorize a new query')
    const history = terminalFor(h.posted[0], {
        manualReadPendingHistoryRecovery: true,
        manualReadPendingOutcomeOnly: true,
        manualReadPendingPresentationAllowed: false,
    })
    assert.equal(h.coordinator.settle(history), true)
    assert.equal(preparations, 1)
    assert.equal(queries, 0, 'An exact history receipt still waits for native query delegation')
    const proof = { requestID, observationToken: token }
    assert.equal(await h.coordinator.recoverHistoryReadingStatus(proof), true)
    assert.equal(queries, 1)
    assert.equal(h.coordinator.settle(history), false)
    assert.equal(h.coordinator.pendingCount, 0)
    assert.equal(h.posted.length, 1, 'Recovery observes state without replaying the mutation')
})


