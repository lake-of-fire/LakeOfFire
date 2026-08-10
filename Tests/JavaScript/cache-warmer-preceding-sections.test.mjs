import assert from 'node:assert/strict'
import test from 'node:test'

import {
    CacheWarmerPrecedingSections,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/cache-warmer-preceding-sections.js'

test('loaded sections release only satisfied preceding-section waiters', async () => {
    const coordinator = new CacheWarmerPrecedingSections()
    let earlierResolved = false
    let laterResolved = false
    const earlier = coordinator.waitFor(2).then(() => earlierResolved = true)
    const later = coordinator.waitFor(4).then(() => laterResolved = true)

    assert.equal(coordinator.requiredTargetIndex, 4)
    coordinator.recordLoadedSection(1)
    await earlier
    assert.equal(earlierResolved, true)
    assert.equal(laterResolved, false)
    assert.equal(coordinator.requiredTargetIndex, 4)

    coordinator.recordLoadedSection(3)
    await later
    assert.equal(laterResolved, true)
    assert.equal(coordinator.requiredTargetIndex, null)
})

test('finished warming releases every target without polling', async () => {
    const coordinator = new CacheWarmerPrecedingSections()
    const waiters = [coordinator.waitFor(3), coordinator.waitFor(8)]

    assert.equal(coordinator.finish(), true)
    await Promise.all(waiters)
    assert.equal(coordinator.finished, true)
    assert.equal(coordinator.requiredTargetIndex, null)
    await coordinator.waitFor(100)
})

test('closing a replaced coordinator releases waiters and rejects later state', async () => {
    const coordinator = new CacheWarmerPrecedingSections()
    const waiter = coordinator.waitFor(5)

    assert.equal(coordinator.close(), true)
    await waiter
    assert.equal(coordinator.requiredTargetIndex, null)
    assert.equal(coordinator.recordLoadedSection(5), false)
    assert.equal(coordinator.finish(), false)
    assert.equal(coordinator.close(), false)
})

test('retry resets progress without abandoning an existing requirement', async () => {
    const coordinator = new CacheWarmerPrecedingSections()
    let resolved = false
    const waiter = coordinator.waitFor(4).then(() => resolved = true)
    coordinator.recordLoadedSection(1)

    assert.equal(coordinator.resetProgress(), true)
    assert.equal(coordinator.highestSectionIndex, -1)
    assert.equal(coordinator.requiredTargetIndex, 4)
    coordinator.recordLoadedSection(2)
    await Promise.resolve()
    assert.equal(resolved, false)

    coordinator.recordLoadedSection(3)
    await waiter
    assert.equal(resolved, true)
})
