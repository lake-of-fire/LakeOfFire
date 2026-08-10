import assert from 'node:assert/strict'
import test from 'node:test'

import {
    OwnedEventBindings,
    OwnedEventBindingScopes,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/owned-event-bindings.js'

test('clear removes every owned listener exactly once', () => {
    const bindings = new OwnedEventBindings()
    const target = new EventTarget()
    let calls = 0

    bindings.listen(target, 'change', () => calls += 1)
    target.dispatchEvent(new Event('change'))
    assert.equal(calls, 1)

    assert.equal(bindings.clear(), true)
    assert.equal(bindings.clear(), false)
    target.dispatchEvent(new Event('change'))
    assert.equal(calls, 1)
})

test('clearing a binding restores the value it replaced', () => {
    const bindings = new OwnedEventBindings()
    const target = { callback: 'original' }

    bindings.bind(target, 'callback', 'reader')
    assert.equal(target.callback, 'reader')

    bindings.clear()
    assert.equal(target.callback, 'original')
})

test('an obsolete owner cannot erase a newer global binding', () => {
    const firstBindings = new OwnedEventBindings()
    const secondBindings = new OwnedEventBindings()
    const target = {}

    firstBindings.bind(target, 'callback', 'first')
    secondBindings.bind(target, 'callback', 'second')
    firstBindings.clear()

    assert.equal(target.callback, 'second')
    secondBindings.clear()
    assert.equal(Object.hasOwn(target, 'callback'), false)
})

test('invalid listener targets and binding keys are ignored', () => {
    const bindings = new OwnedEventBindings()

    assert.equal(bindings.listen(null, 'change', () => {}), false)
    assert.equal(bindings.listen({}, 'change', () => {}), false)
    assert.equal(bindings.bind(null, 'callback', 'value'), false)
    assert.equal(bindings.bind({}, '', 'value'), false)
    assert.equal(bindings.clear(), true)
})

test('clear runs an arbitrary owned cleanup exactly once', () => {
    const bindings = new OwnedEventBindings()
    let cleanupCalls = 0

    assert.equal(bindings.addCleanup(() => cleanupCalls += 1), true)
    assert.equal(bindings.clear(), true)
    assert.equal(bindings.clear(), false)
    assert.equal(cleanupCalls, 1)
    assert.equal(bindings.addCleanup(() => cleanupCalls += 1), false)
})

test('one failing cleanup does not prevent later cleanup', () => {
    const bindings = new OwnedEventBindings()
    let cleanupCalls = 0

    bindings.addCleanup(() => { throw new Error('expected cleanup failure') })
    bindings.addCleanup(() => cleanupCalls += 1)

    assert.equal(bindings.clear(), true)
    assert.equal(cleanupCalls, 1)
})

test('an external overwrite retires stale ownership metadata', () => {
    const firstBindings = new OwnedEventBindings()
    const target = {}

    firstBindings.bind(target, 'callback', 'reader')
    target.callback = 'external'
    firstBindings.clear()
    assert.equal(target.callback, 'external')

    const secondBindings = new OwnedEventBindings()
    secondBindings.bind(target, 'callback', 'replacement-reader')
    secondBindings.clear()
    assert.equal(target.callback, 'external')
})

test('starting a replacement scope clears the prior owner', () => {
    const scopes = new OwnedEventBindingScopes()
    const owner = {}
    const target = new EventTarget()
    let firstCalls = 0
    let secondCalls = 0

    const first = scopes.begin(owner)
    first.listen(target, 'change', () => firstCalls += 1)
    const second = scopes.begin(owner)
    second.listen(target, 'change', () => secondCalls += 1)
    target.dispatchEvent(new Event('change'))

    assert.equal(scopes.isCurrent(owner, first), false)
    assert.equal(scopes.isCurrent(owner, second), true)
    assert.equal(firstCalls, 0)
    assert.equal(secondCalls, 1)
})

test('scope release and clear remove only live owners', () => {
    const scopes = new OwnedEventBindingScopes()
    const firstOwner = {}
    const secondOwner = {}
    const first = scopes.begin(firstOwner)
    const second = scopes.begin(secondOwner)

    assert.equal(scopes.release(firstOwner), true)
    assert.equal(scopes.release(firstOwner), false)
    assert.equal(scopes.isCurrent(firstOwner, first), false)
    assert.equal(scopes.isCurrent(secondOwner, second), true)
    assert.equal(scopes.clear(), true)
    assert.equal(scopes.clear(), false)
    assert.equal(scopes.isCurrent(secondOwner, second), false)
})
