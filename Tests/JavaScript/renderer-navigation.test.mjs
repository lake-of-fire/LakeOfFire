import assert from 'node:assert/strict'
import test from 'node:test'

import {
    advanceCurrentRendererSection,
    rendererNavigationAccepted,
    runCurrentRendererNavigation,
    waitForCurrentRendererIndexChange,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/renderer-navigation.js'

test('renderer navigation accepts only an explicit successful receipt', () => {
    assert.equal(rendererNavigationAccepted(true), true)
    assert.equal(rendererNavigationAccepted(undefined), false)
    assert.equal(rendererNavigationAccepted(null), false)
    assert.equal(rendererNavigationAccepted({ movementDisposition: 'moved' }), false)
    assert.equal(rendererNavigationAccepted({ movementDisposition: 'unknown' }), false)
})

test('renderer navigation rejects proved no-op and non-owning receipts', () => {
    assert.equal(rendererNavigationAccepted(false), false)
    assert.equal(rendererNavigationAccepted({ ignored: true }), false)
    assert.equal(rendererNavigationAccepted({ superseded: true }), false)
    assert.equal(rendererNavigationAccepted({
        ignored: true,
        superseded: true,
        reason: 'fixedLayoutNavigationSuperseded',
    }), false)
    assert.equal(rendererNavigationAccepted({ movementDisposition: 'no-move' }), false)
    assert.equal(rendererNavigationAccepted({ movementDisposition: 'not-owned' }), false)
})


test('renderer navigation retains results only for the current renderer owner', async () => {
    let current = true
    assert.equal(await runCurrentRendererNavigation({
        operation: async () => true,
        isCurrent: () => current,
    }), true)

    assert.deepEqual(await runCurrentRendererNavigation({
        operation: async () => {
            current = false
            return true
        },
        isCurrent: () => current,
    }), {
        ignored: true,
        reason: 'viewRendererSuperseded',
    })
})

test('renderer errors are non-owning only after exact ownership changes', async () => {
    const failure = new Error('current renderer failed')
    await assert.rejects(runCurrentRendererNavigation({
        operation: async () => { throw failure },
    }), failure)

    let current = true
    assert.deepEqual(await runCurrentRendererNavigation({
        operation: async () => {
            current = false
            throw failure
        },
        isCurrent: () => current,
    }), {
        ignored: true,
        reason: 'viewRendererSuperseded',
    })
})

test('renderer navigation ownership probes are conservative and receipts are non-owning', async () => {
    const {
        rendererNavigationInFlight,
        rendererNavigationNotOwned,
    } = await import('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/renderer-navigation.js')

    assert.equal(rendererNavigationInFlight({ navigationInFlight: true }), true)
    assert.equal(rendererNavigationInFlight({ navigationInFlight: false }), false)
    assert.equal(rendererNavigationInFlight(null), false)
    assert.equal(rendererNavigationInFlight({
        get navigationInFlight() { throw new Error('stale renderer') },
    }), true)
    assert.deepEqual(rendererNavigationNotOwned('rendererNavigationInFlight'), {
        ignored: true,
        reason: 'rendererNavigationInFlight',
    })
})

test('renderer index polling stops as soon as ownership changes', async () => {
    let current = true
    let sleepCount = 0
    const result = await waitForCurrentRendererIndexChange({
        originalIndex: 2,
        getCurrentIndex: () => 2,
        isCurrent: () => current,
        attempts: 80,
        sleep: async () => {
            sleepCount += 1
            current = false
        },
    })

    assert.equal(result, false)
    assert.equal(sleepCount, 1)
})

test('renderer index polling accepts only a current finite index change', async () => {
    const indexes = [4, Number.NaN, 5]
    let index = 0
    const result = await waitForCurrentRendererIndexChange({
        originalIndex: 4,
        getCurrentIndex: () => indexes[index],
        attempts: indexes.length,
        intervalMs: 0,
        sleep: async () => {
            index += 1
        },
    })

    assert.equal(result, true)
    assert.equal(index, 2)
})

test('renderer index polling rejects a reentrant ownership loss before publishing movement', async () => {
    let current = true
    const result = await waitForCurrentRendererIndexChange({
        originalIndex: 2,
        getCurrentIndex: () => {
            current = false
            return 3
        },
        isCurrent: () => current,
        attempts: 1,
    })

    assert.equal(result, false)
})

test('read-aloud section advance rejects missing and refused renderer operations without polling', async () => {
    let waitCount = 0
    const waitForIndexChange = async () => {
        waitCount += 1
        return true
    }

    assert.equal(await advanceCurrentRendererSection({
        renderer: {},
        getCurrentIndex: () => 1,
        waitForIndexChange,
    }), false)

    assert.equal(await advanceCurrentRendererSection({
        renderer: { nextSection: async () => false },
        getCurrentIndex: () => 1,
        waitForIndexChange,
    }), false)

    assert.equal(waitCount, 0)
})

test('read-aloud section advance publishes only an accepted current index change', async () => {
    let index = 2
    const renderer = {
        nextSection: async () => {
            index = 3
            return true
        },
    }

    assert.equal(await advanceCurrentRendererSection({
        renderer,
        getCurrentIndex: () => index,
        waitForIndexChange: waitForCurrentRendererIndexChange,
    }), true)

    let current = true
    index = 4
    assert.equal(await advanceCurrentRendererSection({
        renderer: {
            nextSection: async () => {
                current = false
                index = 5
                return true
            },
        },
        getCurrentIndex: () => index,
        isCurrent: () => current,
    }), false)
})
