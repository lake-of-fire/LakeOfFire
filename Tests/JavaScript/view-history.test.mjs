import assert from 'node:assert/strict'
import test from 'node:test'

import {
    ViewHistory,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/view-history.js'

test('deduplicates equal zero-fraction locations', () => {
    const history = new ViewHistory()
    let changeCount = 0
    history.addEventListener('index-change', () => changeCount++)

    history.pushState({ fraction: 0 })
    history.pushState({ fraction: 0 })

    assert.equal(history.canGoBack, false)
    assert.equal(changeCount, 1)
})

test('replace establishes the initial history entry', () => {
    const history = new ViewHistory()
    const poppedStates = []
    history.addEventListener('popstate', event => poppedStates.push(event.detail.state))

    history.replaceState('initial')
    history.pushState('next')
    history.back()

    assert.deepEqual(poppedStates, ['initial'])
    assert.equal(history.canGoBack, false)
    assert.equal(history.canGoForward, true)
})

test('push after back discards the forward branch', () => {
    const history = new ViewHistory()
    history.pushState('first')
    history.pushState('second')
    history.pushState('third')
    history.back()
    history.pushState('replacement')

    assert.equal(history.canGoBack, true)
    assert.equal(history.canGoForward, false)
})
