import assert from 'node:assert/strict'
import test from 'node:test'

import {
    PAGE_TURN_MOVEMENT_DISPOSITION,
    observedPageTurnMovementDisposition,
    pageTurnMovementDisposition,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/page-turn-coordination.js'

const disposition = PAGE_TURN_MOVEMENT_DISPOSITION

test('classifies only explicit renderer receipts as authoritative movement or no-move', () => {
    assert.equal(pageTurnMovementDisposition(true), disposition.moved)
    assert.equal(pageTurnMovementDisposition({ moved: true }), disposition.moved)
    assert.equal(pageTurnMovementDisposition(false), disposition.noMove)
    assert.equal(pageTurnMovementDisposition({ authoritativeNoMove: true }), disposition.noMove)
    assert.equal(pageTurnMovementDisposition({ ignored: true, reason: 'pageTurnInFlight' }), disposition.notOwned)
    assert.equal(pageTurnMovementDisposition({ superseded: true }), disposition.notOwned)
    assert.equal(pageTurnMovementDisposition(undefined), disposition.unknown)
    assert.equal(pageTurnMovementDisposition({ moved: false }), disposition.unknown)
})

test('unknown receipts can be promoted only by observed movement', () => {
    assert.equal(observedPageTurnMovementDisposition({
        moveResult: undefined,
        immediatePositionChanged: true,
    }), disposition.moved)
    assert.equal(observedPageTurnMovementDisposition({
        moveResult: undefined,
        immediatePositionChanged: false,
        settledPositionChanged: true,
    }), disposition.moved)
    assert.equal(observedPageTurnMovementDisposition({
        moveResult: undefined,
        immediatePositionChanged: false,
        settledPositionChanged: false,
    }), disposition.unknown)
})

test('truthful receipts outrank unrelated position observations', () => {
    assert.equal(observedPageTurnMovementDisposition({
        moveResult: false,
        immediatePositionChanged: true,
        settledPositionChanged: true,
    }), disposition.noMove)
    assert.equal(observedPageTurnMovementDisposition({
        moveResult: { ignored: true, reason: 'pageTurnInFlight' },
        immediatePositionChanged: true,
    }), disposition.notOwned)
})
