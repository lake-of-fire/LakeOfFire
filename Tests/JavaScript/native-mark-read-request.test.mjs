import assert from 'node:assert/strict'
import test from 'node:test'

import {
    createNativeMarkReadRequestCoordinator,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

const harness = ({ current = true, postThrows = false, ownerProbeThrows = false } = {}) => {
    const posted = []
    const timeouts = new Map()
    const timeoutDelays = new Map()
    let timeoutSequence = 0
    let requestSequence = 0
    const coordinator = createNativeMarkReadRequestCoordinator({
        postMessage: message => {
            if (postThrows) throw new Error('bridge unavailable')
            posted.push(message)
        },
        isOwnerCurrent: () => {
            if (ownerProbeThrows) throw new Error('detached renderer')
            return current
        },
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
        timeouts,
        timeoutDelays,
        setCurrent(value) {
            current = value
        },
    }
}

test('publishes success only after the exact native reply', async () => {
    const h = harness()
    const completion = h.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [{ stableSegmentID: 'segment-a' }] },
        context: { stateID: 'visible-screen' },
    })

    assert.equal(h.posted.length, 1)
    assert.equal(h.posted[0].requestID, 'request-1')
    assert.equal(h.posted[0].sectionId, 'section-a')
    assert.equal(h.coordinator.pendingCount, 1)

    assert.equal(h.coordinator.settle({
        requestID: 'request-1',
        sectionId: 'section-a',
        success: true,
    }), true)

    assert.deepEqual(await completion, {
        requestID: 'request-1',
        context: { stateID: 'visible-screen' },
        success: true,
        stale: false,
        errorCode: null,
        nativeResult: {
            requestID: 'request-1',
            sectionId: 'section-a',
            success: true,
        },
    })
    assert.equal(h.coordinator.pendingCount, 0)
    assert.equal(h.timeouts.size, 0)
})

test('uses the 15-second request/reply observation deadline', async () => {
    const h = harness()
    const completion = h.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [] },
    })

    assert.deepEqual([...h.timeoutDelays.values()], [15_000])

    h.coordinator.cancelAll()
    await completion
})

test('preserves committed success when the reader owner becomes stale', async () => {
    const h = harness()
    const completion = h.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [] },
        owner: { lifecycle: 1 },
    })
    h.setCurrent(false)

    h.coordinator.settle({
        requestID: 'request-1',
        sectionId: 'section-a',
        success: true,
    })

    const result = await completion
    assert.equal(result.success, true)
    assert.equal(result.stale, true)
    assert.equal(result.errorCode, null)
})

test('rejects a mismatched section and ignores duplicate replies', async () => {
    const h = harness()
    const completion = h.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [] },
    })

    assert.equal(h.coordinator.settle({
        requestID: 'request-1',
        sectionId: 'section-b',
        success: true,
    }), true)
    assert.equal((await completion).errorCode, 'sectionMismatch')
    assert.equal(h.coordinator.settle({
        requestID: 'request-1',
        sectionId: 'section-a',
        success: true,
    }), false)
})

test('bridge failure resolves without leaving pending work', async () => {
    const h = harness({ postThrows: true })
    const result = await h.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [] },
    })

    assert.equal(result.success, false)
    assert.match(result.errorCode, /bridge unavailable/)
    assert.equal(h.coordinator.pendingCount, 0)
    assert.equal(h.timeouts.size, 0)
})

test('timeout fails closed and ignores late native completion', async () => {
    const timeoutHarness = harness()
    const timedCompletion = timeoutHarness.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [] },
    })
    const timeoutCallback = [...timeoutHarness.timeouts.values()][0]
    timeoutCallback()
    const timedResult = await timedCompletion
    assert.equal(timedResult.success, false)
    assert.equal(timedResult.errorCode, 'nativeCommitTimeout')
    assert.equal(timeoutHarness.coordinator.pendingCount, 0)
    assert.equal(timeoutHarness.timeouts.size, 0)
    assert.equal(timeoutHarness.coordinator.settle({
        requestID: 'request-1',
        sectionId: 'section-a',
        success: true,
    }), false)
})

test('cancellation completes once and makes retained timeout/reply callbacks inert', async () => {
    const cancelledHarness = harness()
    let completionCount = 0
    const cancelledCompletion = cancelledHarness.coordinator.request({
        sectionID: 'section-b',
        message: { segments: [] },
    })
    const observedCompletion = cancelledCompletion.then(result => {
        completionCount += 1
        return result
    })
    const lateTimeoutCallback = [...cancelledHarness.timeouts.values()][0]
    cancelledHarness.coordinator.cancelAll('readerReplaced')
    const cancelled = await observedCompletion
    assert.equal(cancelled.success, false)
    assert.equal(cancelled.stale, true)
    assert.equal(cancelled.errorCode, 'readerReplaced')
    assert.equal(cancelledHarness.coordinator.pendingCount, 0)
    assert.equal(cancelledHarness.timeouts.size, 0)

    lateTimeoutCallback()
    assert.equal(cancelledHarness.coordinator.settle({
        requestID: 'request-1',
        sectionId: 'section-b',
        success: true,
    }), false)
    assert.strictEqual(await cancelledCompletion, cancelled)
    await Promise.resolve()
    assert.equal(completionCount, 1)
})


test('installs request identity before posting and before a synchronous reply', async () => {
    let installedID = null
    let postedID = null
    const coordinator = createNativeMarkReadRequestCoordinator({
        makeRequestID: () => 'synchronous-request',
        postMessage: message => {
            postedID = message.requestID
            assert.equal(installedID, message.requestID)
            assert.equal(coordinator.pendingCount, 1)
            coordinator.settle({ ...message, success: true })
        },
    })
    const result = await coordinator.request({
        sectionID: 'section', message: {},
        onRequestID: requestID => { installedID = requestID },
    })
    assert.equal(installedID, 'synchronous-request')
    assert.equal(postedID, installedID)
    assert.equal(result.requestID, installedID)
    assert.equal(result.success, true)
    assert.equal(coordinator.pendingCount, 0)
})

test('identity publication failure does not post or leave a pending request', async () => {
    const h = harness()
    const result = await h.coordinator.request({
        sectionID: 'section', message: {},
        onRequestID: () => { throw new Error('identity installation failed') },
    })
    assert.equal(result.success, false)
    assert.equal(result.errorCode, 'identity installation failed')
    assert.equal(h.posted.length, 0)
    assert.equal(h.timeouts.size, 0)
    assert.equal(h.coordinator.pendingCount, 0)
})

test('invalid preparation never publishes an identity or posts', async () => {
    const h = harness()
    let publications = 0
    const onRequestID = () => { publications += 1 }
    assert.equal((await h.coordinator.request({
        sectionID: '', message: {}, onRequestID,
    })).errorCode, 'invalidSectionID')
    assert.equal((await h.coordinator.request({
        sectionID: 'section', message: null, onRequestID,
    })).errorCode, 'invalidMessage')
    assert.equal(publications, 0)
    assert.equal(h.posted.length, 0)
})

test('a queued timeout from a completed request cannot clear a newer request', async () => {
    const h = harness()
    const first = h.coordinator.request({ sectionID: 'section', message: {} })
    const queuedTimeout = [...h.timeouts.values()][0]
    h.coordinator.settle({ requestID: 'request-1', sectionId: 'section', success: true })
    const second = h.coordinator.request({ sectionID: 'section', message: {} })
    queuedTimeout()
    assert.equal(h.coordinator.pendingCount, 1)
    assert.equal((await first).success, true)
    h.coordinator.settle({ requestID: 'request-2', sectionId: 'section', success: true })
    assert.equal((await second).success, true)
    assert.equal(h.coordinator.pendingCount, 0)
})


test('owner-check exception cannot hide an exact committed native reply', async () => {
    const h = harness({ ownerProbeThrows: true })
    const pending = h.coordinator.request({ sectionID: 'section', message: {} })
    assert.equal(h.coordinator.settle({
        requestID: 'request-1', sectionId: 'section', success: true,
    }), true)
    const result = await pending
    assert.equal(result.success, true)
    assert.equal(result.stale, true)
    assert.equal(result.errorCode, null)
    assert.equal(h.coordinator.pendingCount, 0)
    assert.equal(h.timeouts.size, 0)
})

test('owner-check exception cannot strand a failed bridge request', async () => {
    const h = harness({ postThrows: true, ownerProbeThrows: true })
    const result = await h.coordinator.request({ sectionID: 'section', message: {} })
    assert.equal(result.success, false)
    assert.equal(result.stale, true)
    assert.match(result.errorCode, /bridge unavailable/)
    assert.equal(h.coordinator.pendingCount, 0)
    assert.equal(h.timeouts.size, 0)
})

test('owner-check exception cannot prevent timeout cleanup', async () => {
    const h = harness({ ownerProbeThrows: true })
    const pending = h.coordinator.request({ sectionID: 'section', message: {} })
    const timeout = [...h.timeouts.values()][0]
    timeout()
    const result = await pending
    assert.equal(result.success, false)
    assert.equal(result.stale, true)
    assert.equal(result.errorCode, 'nativeCommitTimeout')
    assert.equal(h.coordinator.pendingCount, 0)
    assert.equal(h.timeouts.size, 0)
})
