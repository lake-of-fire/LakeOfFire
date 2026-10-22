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

test('replacement cleanup cannot overwrite a reentrantly admitted successor', () => {
    const element = {}
    const cleanups = []
    let successor
    const first = beginOwnedElementOperation(element, () => {
        cleanups.push('first')
        successor = beginOwnedElementOperation(element, () => cleanups.push('successor'))
    })
    const interrupted = beginOwnedElementOperation(element, () => cleanups.push('interrupted'))

    assert.equal(first.active, false)
    assert.equal(interrupted.active, false, 'the newer admission retires the in-progress replacement')
    assert.equal(successor.active, true)
    assert.deepEqual(cleanups, ['first', 'interrupted'])
    assert.equal(interrupted.finish(), false)
    assert.equal(finishOwnedElementOperation(element), true)
    assert.equal(successor.active, false)
    assert.deepEqual(cleanups, ['first', 'interrupted', 'successor'])
    assert.equal(finishOwnedElementOperation(element), false)
})

test('cleanup can cancel the in-progress replacement without its later resurrection', () => {
    const element = {}
    const cleanups = []
    let cancelled
    beginOwnedElementOperation(element, () => {
        cleanups.push('first')
        cancelled = finishOwnedElementOperation(element)
    })
    const interrupted = beginOwnedElementOperation(element, () => cleanups.push('interrupted'))

    assert.equal(cancelled, true)
    assert.equal(interrupted.active, false)
    assert.equal(finishOwnedElementOperation(element), false)
    assert.deepEqual(cleanups, ['first', 'interrupted'])
})

test('a successor finished during cleanup does not restore the superseded replacement', () => {
    const element = {}
    const cleanups = []
    let successor
    beginOwnedElementOperation(element, () => {
        cleanups.push('first')
        successor = beginOwnedElementOperation(element, () => cleanups.push('successor'))
        successor.finish()
    })
    const interrupted = beginOwnedElementOperation(element, () => cleanups.push('interrupted'))

    assert.equal(interrupted.active, false)
    assert.equal(successor.active, false)
    assert.deepEqual(cleanups, ['first', 'interrupted', 'successor'])
    assert.equal(finishOwnedElementOperation(element), false)
})

test('throwing predecessor cleanup still preserves its reentrant successor', () => {
    const element = {}
    const cleanups = []
    let successor
    beginOwnedElementOperation(element, () => {
        successor = beginOwnedElementOperation(element, () => cleanups.push('successor'))
        throw new Error('optional predecessor cleanup failed')
    })
    const interrupted = beginOwnedElementOperation(element, () => cleanups.push('interrupted'))

    assert.equal(interrupted.active, false)
    assert.equal(successor.active, true)
    assert.equal(finishOwnedElementOperation(element), true)
    assert.equal(successor.active, false)
    assert.deepEqual(cleanups, ['interrupted', 'successor'])
})

test('reentrant admission for a different element preserves both current owners', () => {
    const element = {}, other = {}
    const cleanups = []
    let independent
    beginOwnedElementOperation(element, () => {
        independent = beginOwnedElementOperation(other, () => cleanups.push('independent'))
    })
    const current = beginOwnedElementOperation(element, () => cleanups.push('current'))

    assert.equal(current.active, true)
    assert.equal(independent.active, true)
    assert.equal(finishOwnedElementOperation(element), true)
    assert.equal(independent.active, true)
    assert.equal(finishOwnedElementOperation(other), true)
    assert.deepEqual(cleanups, ['current', 'independent'])
})

test('ordinary finish detaches before cleanup admits a successor', () => {
    const element = {}
    let successor, successorCleanups = 0
    const first = beginOwnedElementOperation(element, () => {
        successor = beginOwnedElementOperation(element, () => successorCleanups++)
    })

    assert.equal(first.finish(), true)
    assert.equal(successor.active, true)
    assert.equal(first.finish(), false)
    assert.equal(successorCleanups, 0)
    assert.equal(finishOwnedElementOperation(element), true)
    assert.equal(successorCleanups, 1)
})

test('invalid replacement inputs do not retire an existing owner', () => {
    const element = {}
    let cleanups = 0
    const current = beginOwnedElementOperation(element, () => cleanups++)

    assert.throws(() => beginOwnedElementOperation(element, null), TypeError)
    assert.throws(() => beginOwnedElementOperation(null, () => {}), TypeError)
    assert.equal(current.active, true)
    assert.equal(cleanups, 0)
    assert.equal(finishOwnedElementOperation(element), true)
    assert.equal(cleanups, 1)
})
