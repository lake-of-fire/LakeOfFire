import assert from 'node:assert/strict'
import test from 'node:test'

import {
    createNativeMarkReadRequestCoordinator,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

const harness = ({ current = true, postThrows = false } = {}) => {
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

test('rejects a reply after the reader owner becomes stale', async () => {
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
    assert.equal(result.success, false)
    assert.equal(result.stale, true)
    assert.equal(result.errorCode, 'staleReaderLifecycle')
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
