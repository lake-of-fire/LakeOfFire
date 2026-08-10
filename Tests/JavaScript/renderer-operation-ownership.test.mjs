import assert from 'node:assert/strict'
import test from 'node:test'

import {
    runCurrentRendererOperation,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/renderer-operation-ownership.js'

test('an operation rejected before dispatch does not run', async () => {
    let callCount = 0
    const result = await runCurrentRendererOperation({
        operation: async () => { callCount += 1 },
        isCurrent: () => false,
    })

    assert.equal(callCount, 0)
    assert.equal(result.ignored, true)
})

test('a stale completion cannot publish into a replacement renderer', async () => {
    let current = true
    let release
    const pending = runCurrentRendererOperation({
        operation: () => new Promise(resolve => { release = resolve }),
        isCurrent: () => current,
    })
    await Promise.resolve()

    current = false
    release('old-result')
    assert.equal((await pending).ignored, true)
})

test('a stale failure is suppressed but a current failure propagates', async () => {
    let current = true
    let rejectStale
    const stale = runCurrentRendererOperation({
        operation: () => new Promise((_resolve, reject) => { rejectStale = reject }),
        isCurrent: () => current,
    })
    await Promise.resolve()
    current = false
    rejectStale(new Error('stale failure'))
    assert.equal((await stale).ignored, true)

    await assert.rejects(
        runCurrentRendererOperation({
            operation: async () => { throw new Error('current failure') },
        }),
        /current failure/,
    )
})
