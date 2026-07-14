import assert from 'node:assert/strict'
import test from 'node:test'

import { DeferredOpenWorkCoordinator } from '../../Sources/LakeOfFireReader/Resources/foliate-js/deferred-open-work.js'

const immediateScheduler = callback => {
    queueMicrotask(callback)
    return callback
}

test('defers work and coalesces repeated scheduling for one generation', async () => {
    const coordinator = new DeferredOpenWorkCoordinator()
    const generation = coordinator.beginGeneration()
    const events = []
    const tasks = [{ name: 'toc', run: async () => { events.push('toc') } }]

    const first = coordinator.schedule(generation, tasks, { scheduleTask: immediateScheduler })
    const repeated = coordinator.schedule(generation, tasks, { scheduleTask: immediateScheduler })

    assert.equal(first, repeated)
    assert.equal(await first, true)
    assert.deepEqual(events, ['toc'])
})

test('isolates task failure so later optional work still runs', async () => {
    const coordinator = new DeferredOpenWorkCoordinator()
    const generation = coordinator.beginGeneration()
    const events = []
    const errors = []

    const completed = await coordinator.schedule(generation, [
        { name: 'toc', run: async () => { throw new Error('bad toc') } },
        { name: 'bookmarks', run: async () => { events.push('bookmarks') } },
    ], {
        scheduleTask: immediateScheduler,
        onError: (name, error) => errors.push([name, error.message]),
    })

    assert.equal(completed, true)
    assert.deepEqual(events, ['bookmarks'])
    assert.deepEqual(errors, [['toc', 'bad toc']])
})

test('rejects stale completion after a replacement generation begins', async () => {
    const coordinator = new DeferredOpenWorkCoordinator()
    const generation = coordinator.beginGeneration()
    let resumeSlowTask
    const slowTask = new Promise(resolve => { resumeSlowTask = resolve })
    const events = []

    const completion = coordinator.schedule(generation, [
        {
            name: 'bookmarks',
            run: async ({ isCurrent }) => {
                await slowTask
                if (isCurrent()) events.push('stale mutation')
            },
        },
        { name: 'after-bookmarks', run: async () => { events.push('after') } },
    ], { scheduleTask: immediateScheduler })
    await Promise.resolve()

    coordinator.beginGeneration()
    resumeSlowTask()

    assert.equal(await completion, false)
    assert.deepEqual(events, [])
})

test('owner invalidation prevents scheduled work from starting', async () => {
    const coordinator = new DeferredOpenWorkCoordinator()
    const generation = coordinator.beginGeneration()
    let ownerIsCurrent = true
    let didRun = false

    const completion = coordinator.schedule(generation, [
        { name: 'toc', run: async () => { didRun = true } },
    ], {
        isOwnerCurrent: () => ownerIsCurrent,
        scheduleTask: immediateScheduler,
    })
    ownerIsCurrent = false

    assert.equal(await completion, false)
    assert.equal(didRun, false)
})

test('a replacement generation cancels work that has not started', async () => {
    const coordinator = new DeferredOpenWorkCoordinator()
    const generation = coordinator.beginGeneration()
    let scheduledCallback
    let didCancel = false
    let didRun = false

    const completion = coordinator.schedule(generation, [
        { name: 'toc', run: async () => { didRun = true } },
    ], {
        scheduleTask: callback => {
            scheduledCallback = callback
            return 42
        },
        cancelTask: handle => { didCancel = handle === 42 },
    })

    coordinator.beginGeneration()
    await scheduledCallback()

    assert.equal(await completion, false)
    assert.equal(didCancel, true)
    assert.equal(didRun, false)
})
