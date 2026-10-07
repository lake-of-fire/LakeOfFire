import assert from 'node:assert/strict'
import test from 'node:test'
import { pathToFileURL } from 'node:url'
const source = process.env.LAKE_ENDCAP_SOURCE
    ? pathToFileURL(process.env.LAKE_ENDCAP_SOURCE)
    : new URL('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-endcap.js', import.meta.url)
const { BookEndcap } = await import(source)

// Real controller and Promise sequencing; only DOM storage/focus are doubles.
class Element extends EventTarget {
    attributes = new Map()
    children = []
    nodes = new Map()
    classes = new Set()
    classList = { add: value => this.classes.add(value), remove: value => this.classes.delete(value) }
    isConnected = true
    hidden = false
    inert = false
    disabled = false
    textContent = ''
    append(child) { this.children.push(child); child.parent = this }
    getAttribute(key) { return this.attributes.get(key) ?? null }
    setAttribute(key, value) { this.attributes.set(key, String(value)) }
    removeAttribute(key) { this.attributes.delete(key) }
    querySelector(key) {
        if (!this.nodes.has(key)) this.nodes.set(key, new Element())
        return this.nodes.get(key)
    }
    focus() { this.onFocus?.() }
    remove() { this.isConnected = false }
    click() { if (!this.disabled) this.dispatchEvent(new Event('click')) }
}
function fixture(t, finished = false) {
    const document = { createElement: () => new Element(), activeElement: new Element() }
    const publication = new Element(), host = new Element(), calls = [], changes = []
    const cap = new BookEndcap({ document, host, publication,
        performAction: async action => { calls.push(action); return { ok: true, committed: true } },
        onChange: visible => changes.push(visible),
    })
    cap.setReady(true)
    cap.setFinished(finished)
    cap.enter()
    t.after(() => { cap.onChange = () => {}; document.activeElement.onFocus = null; cap.destroy() })
    return { cap, publication, host, document, calls, changes }
}
function onceWrite(object, key, callback) {
    let value = object[key]
    Object.defineProperty(object, key, { configurable: true, get: () => value, set(next) {
        value = next
        Object.defineProperty(object, key, { configurable: true, writable: true, value })
        callback(next)
    } })
}
const deferred = () => {
    let resolve, reject
    const promise = new Promise((a, b) => { resolve = a; reject = b })
    return { promise, resolve, reject }
}
for (const finished of [false, true]) {
    for (const seam of ['busy-paint', 'action-lookup']) {
        for (const boundary of ['account', 'destroy', 'leave', 'readiness', 'finished']) {
            test(`${finished ? 'Restart' : 'Finish'} ${seam} cannot dispatch after ${boundary} changes`, async t => {
                const f = fixture(t, finished)
                const retire = () => {
                    if (boundary === 'account') { f.cap.accountDidChange(); f.cap.setReady(true) }
                    if (boundary === 'destroy') f.cap.destroy()
                    if (boundary === 'leave') f.cap.leave()
                    if (boundary === 'readiness') f.cap.setReady(false)
                    if (boundary === 'finished') f.cap.setFinished(!finished)
                }
                if (seam === 'busy-paint') onceWrite(f.cap.button, 'disabled', retire)
                else {
                    const perform = f.cap.performAction
                    Object.defineProperty(f.cap, 'performAction', { configurable: true, get() {
                        Object.defineProperty(f.cap, 'performAction', { configurable: true, writable: true, value: perform })
                        retire()
                        return perform
                    } })
                }
                assert.equal(await f.cap.activate(), false)
                assert.deepEqual(f.calls, [], 'No operation belongs to the retired activation')
                assert.equal(f.cap.busy, false)
            })
        }
    }
}
for (const phase of ['before-dispatch', 'after-result']) {
    for (const field of ['heading', 'button', 'error']) {
        test(`throwing ${field} paint ${phase} cannot strand busy state or reject activate`, async t => {
            const f = fixture(t), pending = deferred()
            f.cap.performAction = action => { f.calls.push(action); return pending.promise }
            const target = f.cap[field]
            let value = target.textContent
            const install = () => Object.defineProperty(target, 'textContent', {
                configurable: true, get: () => value, set() { throw new Error('Optional display failed') },
            })
            if (phase === 'before-dispatch') install()
            const task = f.cap.activate()
            if (phase === 'after-result') install()
            pending.resolve({ ok: true, committed: true })
            assert.equal(await task, true, 'Accepted result is independent of optional paint')
            assert.equal(f.cap.busy, false)
            assert.deepEqual(f.calls, ['finishBook'])
            Object.defineProperty(target, 'textContent', { configurable: true, writable: true, value })
            f.cap.setReady(true)
            assert.equal(f.cap.button.disabled, false)
        })
    }
}
test('teardown is irrevocable before its visibility callback can reenter', t => {
    const f = fixture(t)
    let entered, activation
    f.cap.onChange = visible => {
        if (visible) return
        entered = f.cap.enter()
        activation = f.cap.activate()
        f.cap.setReady(true)
        f.cap.setFinished(true)
    }
    f.cap.destroy()
    assert.equal(entered, false)
    assert.equal(f.cap.visible, false)
    assert.equal(f.publication.inert, false)
    assert.equal(f.publication.classes.has('manabi-endcap-publication-hidden'), false)
    assert.equal(f.cap.element.isConnected, false)
    assert.deepEqual(f.calls, [])
    assert.equal(f.cap.finished, false)
    return activation.then(value => assert.equal(value, false))
})
test('throwing visibility observer cannot prevent teardown or leave publication inert', t => {
    const f = fixture(t)
    f.cap.onChange = () => { throw new Error('observer failed') }
    assert.doesNotThrow(() => f.cap.destroy())
    assert.equal(f.cap.element.isConnected, false)
    assert.equal(f.publication.inert, false)
    assert.equal(f.cap.enter(), false)
})
test('focus-triggered leave cannot be followed by a stale enter notification', t => {
    const f = fixture(t)
    f.cap.leave()
    f.changes.length = 0
    f.cap.heading.onFocus = () => f.cap.leave({ restoreFocus: false })
    f.cap.enter()
    assert.equal(f.cap.visible, false)
    assert.deepEqual(f.changes, [false])
    assert.equal(f.publication.inert, false)
})
test('focus-triggered reentry retains the successor focus receipt and visibility', t => {
    const f = fixture(t)
    const focus = f.document.activeElement
    let count = 0
    focus.onFocus = () => { if (++count === 1) f.cap.enter() }
    f.changes.length = 0
    f.cap.leave()
    assert.equal(f.cap.visible, true)
    assert.deepEqual(f.changes, [true])
    f.cap.leave()
    assert.equal(count, 2, 'Old leave must not erase the new enter focus receipt')
    assert.equal(f.publication.inert, false)
})
test('account replacement during action lookup preserves an admitted successor busy owner', async t => {
    const f = fixture(t), pending = deferred()
    let successor
    Object.defineProperty(f.cap, 'performAction', { configurable: true, get() {
        Object.defineProperty(f.cap, 'performAction', { configurable: true, writable: true,
            value: action => { f.calls.push(action); return pending.promise } })
        f.cap.accountDidChange()
        f.cap.setReady(true)
        successor = f.cap.activate()
        return () => { f.calls.push('retired'); return { ok: true } }
    } })
    assert.equal(await f.cap.activate(), false)
    assert.equal(f.cap.busy, true)
    assert.deepEqual(f.calls, ['finishBook'])
    pending.resolve({ ok: true, committed: true })
    assert.equal(await successor, true)
    assert.equal(f.cap.busy, false)
})
for (const from of ['result', 'error']) {
    test(`${from} preparation cannot publish old recovery into a successor account`, async t => {
        const f = fixture(t)
        const value = from === 'result'
            ? { ok: true, requestID: 'old', navigation: { status: 'failed' } }
            : { outcomeUnknown: true, requestID: 'old', action: 'finishBook' }
        const owner = from === 'result' ? value.navigation : value
        Object.defineProperty(owner, 'message', { get() { f.cap.accountDidChange(); f.cap.setReady(true); return 'retired message' } })
        f.cap.performAction = async () => { if (from === 'error') throw value; return value }
        assert.equal(await f.cap.activate(), false)
        f.cap.setReady(true) // A later ordinary render cannot resurrect stale recovery.
        assert.equal(f.cap.error.hidden, true)
        assert.equal(f.cap.button.textContent, 'Finish Book')
        assert.equal(f.cap.busy, false)
    })
}
test('a recovery callback receives a copy, not the retained recovery descriptor', async t => {
    const f = fixture(t)
    f.cap.performAction = async () => ({ ok: true, requestID: 'original', action: 'startBookOver',
        navigation: { status: 'failed' } })
    await f.cap.activate()
    const deliveries = []
    f.cap.recoverAction = async descriptor => {
        deliveries.push({ ...descriptor })
        descriptor.requestID = 'mutated'
        throw { outcomeUnknown: true, requestID: 'original', action: 'startBookOver', message: 'unknown' }
    }
    await f.cap.activate()
    assert.equal(deliveries[0].requestID, 'original')
    assert.equal(f.cap.button.textContent, 'Check Status')
})

test('a leave-and-return during busy paint cannot adopt the old click', async t => {
    const f = fixture(t)
    onceWrite(f.cap.button, 'disabled', () => { f.cap.leave(); f.cap.enter() })
    assert.equal(await f.cap.activate(), false)
    assert.deepEqual(f.calls, [])
    assert.equal(f.cap.visible, true)
    assert.equal(await f.cap.activate(), true, 'A new explicit activation in the new visit still works')
    assert.deepEqual(f.calls, ['finishBook'])
})
test('focus leave-and-return does not duplicate the successor enter notification', t => {
    const f = fixture(t)
    f.cap.leave()
    f.changes.length = 0
    f.cap.heading.onFocus = () => {
        f.cap.heading.onFocus = null
        f.cap.leave({ restoreFocus: false })
        f.cap.enter()
    }
    assert.equal(f.cap.enter(), false, 'The outer entry lost its visibility receipt')
    assert.deepEqual(f.changes, [false, true])
    assert.equal(f.cap.visible, true)
})
test('an already dispatched action still settles after leaving and returning', async t => {
    const f = fixture(t), pending = deferred()
    f.cap.performAction = action => { f.calls.push(action); return pending.promise }
    const task = f.cap.activate()
    f.cap.leave(); f.cap.enter()
    assert.equal(f.cap.busy, true)
    assert.equal(await f.cap.activate(), false)
    pending.resolve({ ok: true, committed: true, requestID: 'original', action: 'finishBook' })
    assert.equal(await task, true)
    assert.equal(f.cap.busy, false)
    assert.deepEqual(f.calls, ['finishBook'])
})
test('teardown detaches the listener from its original button even after replacement', t => {
    const f = fixture(t), original = f.cap.button
    f.cap.button = new Element()
    f.cap.destroy()
    let activations = 0
    f.cap.activate = async () => { activations++; return true }
    original.dispatchEvent(new Event('click'))
    assert.equal(activations, 0)
})
test('retired busy paint does not resolve the action callback at all', async t => {
    const f = fixture(t)
    onceWrite(f.cap.button, 'disabled', () => f.cap.destroy())
    let lookups = 0
    Object.defineProperty(f.cap, 'performAction', { get() { lookups++; return () => ({ ok: true }) } })
    assert.equal(await f.cap.activate(), false)
    assert.equal(lookups, 0)
})

for (const failure of ['throw', 'reject', 'missing-handler', 'malformed-result']) {
    test(`failed recovery (${failure}) keeps its original operation instead of offering another reset`, async t => {
        const f = fixture(t, true)
        f.cap.performAction = async action => {
            f.calls.push(action)
            return { ok: true, committed: true, requestID: 'original', action,
                navigation: { status: 'failed' } }
        }
        assert.equal(await f.cap.activate(), true)
        f.cap.recoverAction = failure === 'missing-handler' ? null : () => {
            if (failure === 'throw') throw new Error('Recovery wrapper failed')
            if (failure === 'reject') return Promise.reject(new Error('Recovery unavailable'))
            return undefined
        }
        assert.equal(await f.cap.activate(), false)
        assert.equal(f.cap.button.textContent, 'Check Status')
        assert.equal(f.cap.error.hidden, false)
        let observed
        f.cap.recoverAction = async descriptor => {
            observed = descriptor
            return { ok: true, committed: true, navigation: { status: 'completed' } }
        }
        assert.equal(await f.cap.activate(), true)
        assert.deepEqual(observed, { requestID: 'original', action: 'startBookOver', kind: 'status' })
        assert.deepEqual(f.calls, ['startBookOver'], 'Recovery errors must not fall back to another epoch command')
    })
}
test('a throwing recovery callback cannot mutate the retained original descriptor', async t => {
    const f = fixture(t, true)
    f.cap.performAction = async () => ({ ok: true, requestID: 'original', action: 'startBookOver',
        navigation: { status: 'failed' } })
    await f.cap.activate()
    f.cap.recoverAction = descriptor => { descriptor.requestID = 'wrong'; throw new Error('wrapper failed') }
    await f.cap.activate()
    let observed
    f.cap.recoverAction = async descriptor => { observed = descriptor; return { ok: true } }
    await f.cap.activate()
    assert.equal(observed?.requestID, 'original')
})
test('an explicit negative recovery acknowledgement ends recovery without retrying a mutation', async t => {
    const f = fixture(t, true)
    f.cap.performAction = async () => ({ ok: true, requestID: 'original', action: 'startBookOver',
        navigation: { status: 'failed' } })
    await f.cap.activate()
    f.cap.recoverAction = async () => ({ ok: false, error: 'Original action was rejected' })
    assert.equal(await f.cap.activate(), false)
    assert.equal(f.cap.button.textContent, 'Start Book Over')
    assert.equal(f.cap.error.textContent, 'Original action was rejected')
})

test('optional navigation-message failure cannot erase acknowledged reset recovery', async t => {
    const f = fixture(t, true)
    f.cap.performAction = async () => ({ ok: true, committed: true, requestID: 'original',
        action: 'startBookOver', navigation: { status: 'failed', get message() { throw new Error('formatting') } } })
    assert.equal(await f.cap.activate(), true)
    assert.equal(f.cap.button.textContent, 'Go to Beginning')
    let request
    f.cap.recoverAction = async descriptor => { request = descriptor; return { ok: true } }
    await f.cap.activate()
    assert.deepEqual(request, { requestID: 'original', action: 'startBookOver', kind: 'navigate' })
})
test('optional pending-message failure cannot erase the original status request', async t => {
    const f = fixture(t)
    f.cap.performAction = async () => ({ pending: true, requestID: 'original', action: 'finishBook',
        get error() { throw new Error('formatting') } })
    assert.equal(await f.cap.activate(), false)
    assert.equal(f.cap.button.textContent, 'Check Status')
    let request
    f.cap.recoverAction = async descriptor => { request = descriptor; return { ok: true } }
    await f.cap.activate()
    assert.deepEqual(request, { requestID: 'original', action: 'finishBook', kind: 'status' })
})
test('an explicit rejection remains terminal even when its message cannot be read', async t => {
    const f = fixture(t, true)
    f.cap.performAction = async () => ({ ok: true, requestID: 'original', action: 'startBookOver',
        navigation: { status: 'failed' } })
    await f.cap.activate()
    f.cap.recoverAction = async () => ({ ok: false, get error() { throw new Error('formatting') } })
    assert.equal(await f.cap.activate(), false)
    assert.equal(f.cap.button.textContent, 'Start Book Over')
    assert.equal(f.cap.error.hidden, false)
})

for (const field of ['readiness', 'finished']) {
    for (const seam of ['busy-paint', 'action-lookup']) {
        test(`${field} away-and-back during ${seam} retires the original command`, async t => {
            const f = fixture(t)
            const replace = () => {
                if (field === 'readiness') { f.cap.setReady(false); f.cap.setReady(true) }
                else { f.cap.setFinished(true); f.cap.setFinished(false) }
            }
            if (seam === 'busy-paint') onceWrite(f.cap.button, 'disabled', replace)
            else {
                const perform = f.cap.performAction
                Object.defineProperty(f.cap, 'performAction', { configurable: true, get() {
                    Object.defineProperty(f.cap, 'performAction', { configurable: true, writable: true, value: perform })
                    replace()
                    return perform
                } })
            }
            assert.equal(await f.cap.activate(), false)
            assert.deepEqual(f.calls, [])
            assert.equal(f.cap.busy, false)
            assert.equal(await f.cap.activate(), true)
            assert.deepEqual(f.calls, ['finishBook'])
        })
    }
}
for (const seam of ['hidden', 'inert', 'aria']) {
    test(`reentry during ${seam} restoration inherits the original accessibility baseline`, t => {
        const f = fixture(t), focus = f.document.activeElement
        if (seam === 'hidden') onceWrite(f.cap.element, 'hidden', () => f.cap.enter())
        if (seam === 'inert') onceWrite(f.publication, 'inert', () => f.cap.enter())
        if (seam === 'aria') {
            const remove = f.publication.removeAttribute
            f.publication.removeAttribute = function(key) {
                this.removeAttribute = remove
                remove.call(this, key)
                f.cap.enter()
            }
        }
        assert.equal(f.cap.leave(), false)
        assert.equal(f.cap.visible, true)
        assert.equal(f.cap.leave(), true)
        assert.equal(f.publication.inert, false)
        assert.equal(f.publication.getAttribute('aria-hidden'), null)
        assert.equal(f.publication.classes.has('manabi-endcap-publication-hidden'), false)
        let focused = false
        focus.onFocus = () => { focused = true }
        f.cap.enter(); f.cap.leave()
        assert.equal(focused, true)
    })
}
