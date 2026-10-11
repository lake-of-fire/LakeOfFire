import assert from 'node:assert/strict'
import test from 'node:test'
import { pathToFileURL } from 'node:url'

const source = process.env.BOOK_ACTION_BRIDGE_SOURCE
    ? pathToFileURL(process.env.BOOK_ACTION_BRIDGE_SOURCE).href
    : new URL('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-action-bridge.js', import.meta.url).href
const { createBookActionBridge } = await import(source)
const uuid = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`
const unknown = error => error?.outcomeUnknown === true
const observe = promise => Promise.race([
    promise.then(value => ({ status: 'fulfilled', value }), error => ({ status: 'rejected', error })),
    new Promise(resolve => setImmediate(() => resolve({ status: 'pending' }))),
])

function fixture(t, options = {}) {
    const posts = [], timers = new Map(), cleared = []
    let serial = 0, timer = 0
    const hooks = { ...options }
    const bridge = createBookActionBridge({
        topWindowURL: 'ebook://book', documentStartedAtMs: 1,
        captureContext: () => hooks.context ? hooks.context() : { contextID: 'context', locationRevision: 1 },
        makeRequestID: () => hooks.id ? hooks.id() : uuid(++serial),
        captureProducerOwner: () => hooks.producer ? hooks.producer() : { token: 'original' },
        carryProducerOwner: (body, owner) => hooks.carry ? hooks.carry(body, owner) : body,
        postMessage(body) { posts.push(body); hooks.post?.(body) },
        setTimer(callback) {
            if (hooks.setTimer) return hooks.setTimer(callback)
            const handle = ++timer
            timers.set(handle, callback)
            return handle
        },
        clearTimer(handle) {
            cleared.push(handle)
            if (hooks.clearTimer) return hooks.clearTimer(handle)
            timers.delete(handle)
        },
    })
    bridge.setAccountPresentation('1:1')
    t.after(() => { hooks.clearTimer = null; hooks.setTimer = null; if (hooks.closeAfter !== false) bridge.close() })
    const perform = (action = 'startBookOver') => {
        const completion = bridge.perform(action)
        completion.catch(() => {})
        return completion
    }
    const recover = info => {
        const completion = bridge.recover(info)
        completion.catch(() => {})
        return completion
    }
    const reply = (body = posts.at(-1), extra = {}) => ({
        requestID: body.requestID, accountPresentation: '1:1',
        ok: true, committed: true, navigation: { status: 'completed' }, ...extra,
    })
    const ack = (body = posts.at(-1), extra = {}) => bridge.acknowledge(body.deliveryID, reply(body, extra))
    const timeout = () => { const [handle, callback] = timers.entries().next().value; timers.delete(handle); callback() }
    return { bridge, posts, timers, cleared, hooks, perform, recover, reply, ack, timeout }
}

for (const field of ['topWindowURL', 'documentStartedAtMs']) {
    for (const serialize of [false, true]) {
        test(`producer envelope cannot change ${field} ${serialize ? 'during serialization' : 'before serialization'}`, async t => {
            const f = fixture(t)
            f.hooks.carry = body => {
                const replacement = { ...body, [field]: field === 'context' ? { contextID: 'another-chapter' }
                    : field === 'protocolVersion' ? 3 : 'changed' }
                return serialize ? { ...body, toJSON: () => replacement } : replacement
            }
            const completion = f.perform()
            assert.equal(f.posts.length, 0, 'Wire command must match the originally reserved operation')
            assert.equal((await observe(completion)).status, 'rejected')
        })
    }
}
