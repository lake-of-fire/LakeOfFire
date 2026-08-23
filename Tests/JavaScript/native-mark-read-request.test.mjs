import assert from 'node:assert/strict'
import test from 'node:test'

import {
    createNativeMarkReadRequestCoordinator,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/native-mark-read-request.js'

const harness = ({
    current = true,
    postThrows = false,
    requestID = null,
    timeoutThrows = false,
} = {}) => {
    const posted = []
    const timeouts = new Map()
    let timeoutSequence = 0
    let requestSequence = 0
    const coordinator = createNativeMarkReadRequestCoordinator({
        postMessage: message => {
            if (postThrows) throw new Error('bridge unavailable')
            posted.push(message)
        },
        isOwnerCurrent: () => current,
        makeRequestID: () => requestID ?? `request-${++requestSequence}`,
        maximumRequestIDAttempts: 3,
        scheduleTimeout: callback => {
            if (timeoutThrows) throw new Error('timer unavailable')
            const identifier = ++timeoutSequence
            timeouts.set(identifier, callback)
            return identifier
        },
        cancelTimeout: identifier => timeouts.delete(identifier),
    })
    return {
        coordinator,
        posted,
        timeouts,
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

    const result = await completion
    assert.equal(result.success, true)
    assert.equal(result.errorCode, null)
    assert.deepEqual(result.context, { stateID: 'visible-screen' })
    assert.equal(h.coordinator.pendingCount, 0)
})

test('rejects stale owners, mismatched sections, missing sections, and duplicate replies', async () => {
    const stale = harness()
    const staleCompletion = stale.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [] },
    })
    stale.setCurrent(false)
    assert.equal(stale.coordinator.settle({
        requestID: 'request-1',
        sectionId: 'section-a',
        success: true,
    }), true)
    assert.equal((await staleCompletion).errorCode, 'staleReaderLifecycle')

    for (const sectionId of ['section-b', undefined]) {
        const mismatch = harness()
        const completion = mismatch.coordinator.request({
            sectionID: 'section-a',
            message: { segments: [] },
        })
        assert.equal(mismatch.coordinator.settle({
            requestID: 'request-1',
            sectionId,
            success: true,
        }), true)
        assert.equal((await completion).errorCode, 'sectionMismatch')
        assert.equal(mismatch.coordinator.settle({
            requestID: 'request-1',
            sectionId: 'section-a',
            success: true,
        }), false)
    }
})

test('bridge and timeout setup failures settle without pending work', async () => {
    const bridge = harness({ postThrows: true })
    const bridgeResult = await bridge.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [] },
    })
    assert.equal(bridgeResult.success, false)
    assert.match(bridgeResult.errorCode, /bridge unavailable/)
    assert.equal(bridge.coordinator.pendingCount, 0)

    const timer = harness({ timeoutThrows: true })
    const timerResult = await timer.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [] },
    })
    assert.equal(timerResult.errorCode, 'nativeTimeoutUnavailable')
    assert.equal(timer.posted.length, 0)
    assert.equal(timer.coordinator.pendingCount, 0)
})

test('timeout and cancellation fail closed', async () => {
    const timeout = harness()
    const timedCompletion = timeout.coordinator.request({
        sectionID: 'section-a',
        message: { segments: [] },
    })
    const timeoutCallback = [...timeout.timeouts.values()][0]
    timeoutCallback()
    assert.equal((await timedCompletion).errorCode, 'nativeCommitTimeout')

    const cancelled = harness()
    const cancelledCompletion = cancelled.coordinator.request({
        sectionID: 'section-b',
        message: { segments: [] },
    })
    cancelled.coordinator.cancelAll('readerReplaced')
    const result = await cancelledCompletion
    assert.equal(result.success, false)
    assert.equal(result.stale, true)
    assert.equal(result.errorCode, 'readerReplaced')
    assert.equal(cancelled.coordinator.pendingCount, 0)
})

test('invalid inputs and exhausted request IDs fail without posting', async () => {
    const invalid = harness()
    assert.equal((await invalid.coordinator.request({
        sectionID: ' section-a ',
        message: {},
    })).errorCode, 'invalidSectionID')
    assert.equal((await invalid.coordinator.request({
        sectionID: 'section-a',
        message: [],
    })).errorCode, 'invalidMessage')
    assert.equal((await invalid.coordinator.request({
        sectionID: 's'.repeat(513),
        message: {},
    })).errorCode, 'invalidSectionID')

    const exhausted = harness({ requestID: ' ' })
    assert.equal((await exhausted.coordinator.request({
        sectionID: 'section-a',
        message: {},
    })).errorCode, 'requestIDUnavailable')
    assert.equal(exhausted.posted.length, 0)

    const oversizedRequestID = harness({ requestID: 'r'.repeat(129) })
    assert.equal((await oversizedRequestID.coordinator.request({
        sectionID: 'section-a',
        message: {},
    })).errorCode, 'requestIDUnavailable')
    assert.equal(oversizedRequestID.posted.length, 0)
})
