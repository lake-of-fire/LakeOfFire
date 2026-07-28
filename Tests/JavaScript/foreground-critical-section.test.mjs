import assert from 'node:assert/strict'
import test from 'node:test'

import {
    ForegroundCriticalSectionCoordinator,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/foreground-critical-section.js'

const makeHarness = () => {
    const messages = []
    const scheduled = new Map()
    const cancelled = []
    let nextHandle = 0
    const coordinator = new ForegroundCriticalSectionCoordinator({
        postMessage: message => messages.push(message),
        scheduleTimeout: callback => {
            const handle = ++nextHandle
            scheduled.set(handle, callback)
            return handle
        },
        cancelTimeout: handle => {
            cancelled.push(handle)
            scheduled.delete(handle)
        },
    })
    return { cancelled, coordinator, messages, scheduled }
}

test('assigns unique tokens and finishes each token exactly once', () => {
    const harness = makeHarness()
    const first = harness.coordinator.begin()
    const second = harness.coordinator.begin()

    assert.notEqual(first, second)
    assert.equal(harness.coordinator.activeCount, 2)
    assert.equal(harness.coordinator.finish(first), true)
    assert.equal(harness.coordinator.finish(first), false)
    assert.equal(harness.coordinator.activeCount, 1)
    assert.deepEqual(harness.messages, [
        { phase: 'begin', token: first },
        { phase: 'begin', token: second },
        { phase: 'end', token: first },
    ])
})

test('timeout ends an abandoned token and cancels no replacement token', () => {
    const harness = makeHarness()
    const first = harness.coordinator.begin()
    const firstTimeout = harness.scheduled.values().next().value
    const second = harness.coordinator.begin()

    firstTimeout()

    assert.equal(harness.coordinator.activeCount, 1)
    assert.equal(harness.coordinator.finish(second), true)
    assert.deepEqual(harness.messages.map(message => [message.phase, message.token]), [
        ['begin', first],
        ['begin', second],
        ['end', first],
        ['end', second],
    ])
})

test('finishAll releases every outstanding token and is idempotent', () => {
    const harness = makeHarness()
    const first = harness.coordinator.begin()
    const second = harness.coordinator.begin()

    harness.coordinator.finishAll()
    harness.coordinator.finishAll()

    assert.equal(harness.coordinator.activeCount, 0)
    assert.deepEqual(harness.messages.slice(-2), [
        { phase: 'end', token: first },
        { phase: 'end', token: second },
    ])
    assert.equal(harness.cancelled.length, 2)
})
