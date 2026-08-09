import assert from 'node:assert/strict'
import test from 'node:test'

import {
    scheduleFrameWithTimeoutFallback,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/frame-timeout-scheduler.js'

const makeScheduler = () => {
    const frames = new Map()
    const timers = new Map()
    let nextHandle = 1
    return {
        frames,
        timers,
        requestFrame(callback) {
            const handle = nextHandle++
            frames.set(handle, callback)
            return handle
        },
        cancelFrame(handle) {
            frames.delete(handle)
        },
        setTimer(callback) {
            const handle = nextHandle++
            timers.set(handle, callback)
            return handle
        },
        clearTimer(handle) {
            timers.delete(handle)
        },
    }
}

test('runs once when the animation frame wins the race', () => {
    const scheduler = makeScheduler()
    let runCount = 0
    const task = scheduleFrameWithTimeoutFallback({
        ...scheduler,
        callback: () => { runCount += 1 },
    })

    scheduler.frames.get(task.frameHandle)()

    assert.equal(runCount, 1)
    assert.equal(scheduler.frames.size, 0)
    assert.equal(scheduler.timers.size, 0)
})

test('runs once when animation frames are withheld', () => {
    const scheduler = makeScheduler()
    let runCount = 0
    const task = scheduleFrameWithTimeoutFallback({
        ...scheduler,
        callback: () => { runCount += 1 },
    })

    scheduler.timers.get(task.timeoutHandle)()

    assert.equal(runCount, 1)
    assert.equal(scheduler.frames.size, 0)
    assert.equal(scheduler.timers.size, 0)
})

test('cancellation prevents either race participant from running', () => {
    const scheduler = makeScheduler()
    let runCount = 0
    const task = scheduleFrameWithTimeoutFallback({
        ...scheduler,
        callback: () => { runCount += 1 },
    })

    task.cancel()

    assert.equal(runCount, 0)
    assert.equal(scheduler.frames.size, 0)
    assert.equal(scheduler.timers.size, 0)
})
