import assert from 'node:assert/strict'
import test from 'node:test'

import { resetReaderTransientState } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/reader-transient-state.js'

const dirtyState = () => ({
    __manabiPreserveHiddenNavigationThroughNextDisplay: true,
    __manabiIgnoreNextIncomingHideNavigationCount: 3,
    __manabiIgnoreNextIncomingRevealNavigationCount: 2,
    __manabiLastForwardPageTurnHideAtMs: 100,
    __manabiLastBackwardPageTurnRevealAtMs: 200,
    __manabiLastExplicitNavigationRevealAtMs: 300,
    __manabiPendingContentDocumentBlankNavigationEcho: { x: 1, y: 2 },
    __manabiObservedBookWritingDirection: 'vertical',
    __manabiObservedBookWritingMode: 'vertical-rl',
    __manabiLastSideButtonTouchActivation: { side: 'left', timestamp: 400 },
    __manabiNavVisibilitySequence: 9,
    unrelated: 'retained',
})

test('clears reader-owned transients without rewinding publication sequence', () => {
    const state = dirtyState()

    assert.equal(resetReaderTransientState(state), true)
    assert.equal(state.__manabiPreserveHiddenNavigationThroughNextDisplay, false)
    assert.equal(state.__manabiIgnoreNextIncomingHideNavigationCount, 0)
    assert.equal(state.__manabiIgnoreNextIncomingRevealNavigationCount, 0)
    assert.equal(state.__manabiLastForwardPageTurnHideAtMs, 0)
    assert.equal(state.__manabiLastBackwardPageTurnRevealAtMs, 0)
    assert.equal(state.__manabiLastExplicitNavigationRevealAtMs, 0)
    assert.equal(state.__manabiPendingContentDocumentBlankNavigationEcho, null)
    assert.equal(state.__manabiObservedBookWritingDirection, null)
    assert.equal(state.__manabiObservedBookWritingMode, null)
    assert.equal(state.__manabiNavVisibilitySequence, 9)
    assert.deepEqual(state.__manabiLastSideButtonTouchActivation, { side: 'left', timestamp: 400 })
    assert.equal(state.unrelated, 'retained')
})

test('an outgoing reader cannot clear replacement reader state', () => {
    const outgoing = {}
    const replacement = {}
    const state = dirtyState()

    assert.equal(resetReaderTransientState(state, {
        owner: outgoing,
        currentOwner: replacement,
    }), false)
    assert.deepEqual(state, dirtyState())
})

test('the current reader owns direct teardown cleanup', () => {
    const reader = {}
    const state = dirtyState()

    assert.equal(resetReaderTransientState(state, {
        owner: reader,
        currentOwner: reader,
    }), true)
    assert.equal(state.__manabiPendingContentDocumentBlankNavigationEcho, null)
    assert.equal(state.__manabiObservedBookWritingDirection, null)
})

test('a missing target is rejected without throwing', () => {
    assert.equal(resetReaderTransientState(null), false)
})
