import assert from 'node:assert/strict'
import test from 'node:test'

import {
    beginOwnedElementOperation,
    finishOwnedElementOperation,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/owned-element-operation.js'

test('starting a new element operation finishes the previous owner exactly once', () => {
    const element = {}
    const cleanups = []
    const first = beginOwnedElementOperation(element, () => cleanups.push('first'))
    const second = beginOwnedElementOperation(element, () => cleanups.push('second'))

    assert.deepEqual(cleanups, ['first'])
    assert.equal(first.active, false)
    assert.equal(second.active, true)
    assert.equal(first.finish(), false)
    assert.equal(second.finish(), true)
    assert.deepEqual(cleanups, ['first', 'second'])
})

test('a stale completion cannot finish a newer element operation', () => {
    const element = {}
    const cleanups = []
    const first = beginOwnedElementOperation(element, () => cleanups.push('first'))
    const second = beginOwnedElementOperation(element, () => cleanups.push('second'))

    assert.equal(first.finish(), false)
    assert.equal(second.active, true)
    assert.deepEqual(cleanups, ['first'])
    assert.equal(finishOwnedElementOperation(element), true)
    assert.deepEqual(cleanups, ['first', 'second'])
    assert.equal(finishOwnedElementOperation(element), false)
})

test('element operation ownership is independent per element', () => {
    const firstElement = {}
    const secondElement = {}
    const cleanups = []
    const first = beginOwnedElementOperation(firstElement, () => cleanups.push('first'))
    const second = beginOwnedElementOperation(secondElement, () => cleanups.push('second'))

    assert.equal(finishOwnedElementOperation(firstElement), true)
    assert.equal(second.active, true)
    assert.deepEqual(cleanups, ['first'])
    assert.equal(second.finish(), true)
    assert.deepEqual(cleanups, ['first', 'second'])
    assert.equal(first.finish(), false)
})
