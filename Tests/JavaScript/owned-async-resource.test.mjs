import assert from 'node:assert/strict'
import test from 'node:test'

import {
    OwnedAsyncResource,
    OwnedScheduledTask,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/owned-async-resource.js'

test('a resource acquired after close is disposed instead of published', () => {
    const disposed = []
    const owner = new OwnedAsyncResource(value => disposed.push(value))
    const token = owner.begin()

    assert.equal(owner.close(), true)
    assert.equal(owner.publish(token, 'late-view'), false)
    assert.equal(owner.current, null)
    assert.deepEqual(disposed, ['late-view'])
})

test('a replacement acquisition disposes both the prior and stale resources', () => {
    const disposed = []
    const owner = new OwnedAsyncResource(value => disposed.push(value))
    const firstToken = owner.begin()
    assert.equal(owner.publish(firstToken, 'first-view'), true)

    const secondToken = owner.begin()
    assert.deepEqual(disposed, ['first-view'])
    assert.equal(owner.publish(firstToken, 'stale-view'), false)
    assert.equal(owner.publish(secondToken, 'second-view'), true)
    assert.equal(owner.current, 'second-view')
    assert.deepEqual(disposed, ['first-view', 'stale-view'])
})

test('close is idempotent and prevents another acquisition', () => {
    const owner = new OwnedAsyncResource(() => {})

    assert.equal(owner.close(), true)
    assert.equal(owner.close(), false)
    assert.equal(owner.begin(), null)
})

test('scheduling replacement work cancels the prior handle', () => {
    const callbacks = new Map()
    const cancelled = []
    let nextHandle = 0
    const task = new OwnedScheduledTask({
        schedule: callback => {
            const handle = ++nextHandle
            callbacks.set(handle, callback)
            return handle
        },
        cancel: handle => {
            cancelled.push(handle)
            callbacks.delete(handle)
        },
    })
    let calls = 0

    task.schedule(() => calls += 1)
    task.schedule(() => calls += 10)
    assert.deepEqual(cancelled, [1])
    callbacks.get(2)()
    assert.equal(calls, 10)
})

test('closing scheduled work prevents a captured stale callback', () => {
    let capturedCallback = null
    const task = new OwnedScheduledTask({
        schedule: callback => {
            capturedCallback = callback
            return 1
        },
        cancel: () => {},
    })
    let calls = 0

    task.schedule(() => calls += 1)
    task.close()
    capturedCallback()
    assert.equal(calls, 0)
})
