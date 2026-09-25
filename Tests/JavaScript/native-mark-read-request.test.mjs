import assert from 'node:assert/strict'
import test from 'node:test'

import {
    createNativeMarkReadRequestCoordinator,
    nativeMarkReadCommandMessage,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

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

const harness = ({ current = true, postThrows = false } = {}) => {
    const posted = []
    const controls = []
    const pendingStates = []
    const timeouts = new Map()
    const timeoutDelays = new Map()
    let timeoutSequence = 0
    let requestSequence = 0
    const coordinator = createNativeMarkReadRequestCoordinator({
        postMessage: message => {
            if (postThrows) throw new Error('bridge unavailable')
            posted.push(message)
        },
        postControlMessage: message => controls.push(message),
        onPending: state => pendingStates.push({
            requestID: state.requestID,
            phase: state.phase,
        }),
        isOwnerCurrent: () => current,
        makeRequestID: () => `request-${++requestSequence}`,
        scheduleTimeout: (callback, delay) => {
            const id = ++timeoutSequence
            timeouts.set(id, callback)
            timeoutDelays.set(id, delay)
            return id
        },
        cancelTimeout: id => {
            timeoutDelays.delete(id)
            return timeouts.delete(id)
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
