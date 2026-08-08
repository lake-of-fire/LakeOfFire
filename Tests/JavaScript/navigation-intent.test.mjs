import assert from 'node:assert/strict'
import test from 'node:test'

import {
    beginNavigationIntent,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/navigation-intent.js'

const source = target => target.__manabiNavigationIntent?.source ?? null

test('nested navigation intents restore in last-in-first-out order', () => {
    const target = {}
    const outer = beginNavigationIntent({ source: 'outer' }, target)
    const inner = beginNavigationIntent({ source: 'inner' }, target)

    assert.equal(source(target), 'inner')
    assert.equal(inner.release(), true)
    assert.equal(source(target), 'outer')
    assert.equal(outer.release(), true)
    assert.equal(source(target), null)
})

test('out-of-order completion never resurrects a released navigation intent', () => {
    const target = {}
    const first = beginNavigationIntent({ source: 'first' }, target)
    const second = beginNavigationIntent({ source: 'second' }, target)

    assert.equal(first.release(), true)
    assert.equal(source(target), 'second')
    assert.equal(second.release(), true)
    assert.equal(source(target), null)
})

test('three overlapping intents restore the nearest still-active ancestor', () => {
    const target = {}
    const first = beginNavigationIntent({ source: 'first' }, target)
    const second = beginNavigationIntent({ source: 'second' }, target)
    const third = beginNavigationIntent({ source: 'third' }, target)

    assert.equal(second.release(), true)
    assert.equal(source(target), 'third')
    assert.equal(third.release(), true)
    assert.equal(source(target), 'first')
    assert.equal(first.release(), true)
    assert.equal(source(target), null)
})

test('managed intents preserve an unmanaged pre-existing value', () => {
    const baseline = { source: 'external' }
    const target = { __manabiNavigationIntent: baseline }
    const intent = beginNavigationIntent({ source: 'managed' }, target)

    assert.equal(source(target), 'managed')
    intent.release()
    assert.equal(target.__manabiNavigationIntent, baseline)
})

test('release is idempotent and does not overwrite a newer external owner', () => {
    const target = {}
    const intent = beginNavigationIntent({ source: 'managed' }, target)
    const external = { source: 'external' }
    target.__manabiNavigationIntent = external

    assert.equal(intent.release(), true)
    assert.equal(intent.release(), false)
    assert.equal(target.__manabiNavigationIntent, external)
})
