import assert from 'node:assert/strict'
import test from 'node:test'
import { createBookActionBridge } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-action-bridge.js'
import { carryReaderArticleProducerOwner } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/reader-producer-evidence.js'

const fixture = (t, options = {}) => {
    const messages = [], timers = new Map(), prepared = []
    let requestSequence = 0, timerSequence = 0
    const hooks = {
        carry: body => body,
        timer: null,
        clear: null,
        post: null,
        ...options,
    }
    const owner = Object.freeze({ token: 'native-producer', frameURL: 'ebook://book', documentStartedAtMs: 123 })
    const bridge = createBookActionBridge({
        topWindowURL: 'ebook://book', documentStartedAtMs: 123,
        captureContext: () => ({ contextID: 'current-context', locationRevision: 1 }),
        captureProducerOwner: () => owner,
        makeRequestID: () => `10000000-0000-4000-8000-${String(++requestSequence).padStart(12, '0')}`,
        carryProducerOwner: body => {
            prepared.push({ requestID: body.requestID, deliveryID: body.deliveryID })
            return hooks.carry(body, owner)
        },
        setTimer: callback => {
            hooks.timer?.()
            const id = ++timerSequence
            timers.set(id, callback)
            return id
        },
        clearTimer: id => {
            timers.delete(id)
            hooks.clear?.()
        },
        postMessage: body => {
            messages.push(body)
            hooks.post?.(body)
        },
    })
    t.after(() => bridge.close())
    const acknowledge = (message = messages.at(-1), extra = {}) => bridge.acknowledge(message.deliveryID, {
        requestID: message.requestID, ok: true, committed: true,
        ...(message.action === 'finishBook' ? {} : { navigation: { status: 'completed' } }),
        ...extra,
    })
    const expire = () => {
        const callback = timers.values().next().value
        assert.equal(typeof callback, 'function')
        callback()
    }
    return { bridge, hooks, messages, prepared, timers, acknowledge, expire }
}

const preparationFailures = {
    'unavailable producer envelope': f => {
        // The actual producer adapter converts a rejected Core owner to null.
        f.hooks.carry = (body, owner) => carryReaderArticleProducerOwner(body, owner, {
            producer: { own() { throw new Error('The producer was retired') } },
        })
    },
    'throwing envelope adapter': f => {
        f.hooks.carry = () => { throw new Error('Cannot prepare the envelope') }
    },
    'unserializable envelope': f => {
        f.hooks.carry = body => { body.cycle = body; return body }
    },
    'changed semantic command': f => {
        f.hooks.carry = body => ({ ...body, action: 'finishBook' })
    },
    'failed timer installation': f => {
        f.hooks.timer = () => { throw new Error('Timer installation failed') }
    },
}

for (const [name, fail] of Object.entries(preparationFailures)) {
    test(`fresh command can be retried after ${name}, without a phantom status request`, async t => {
        const f = fixture(t)
        fail(f)
        const first = f.bridge.perform('startBookOver')
        // Observe rejection before inspecting state, including on the baseline.
        let failure
        await assert.rejects(first, error => { failure = error; return true })
        assert.equal(f.messages.length, 0, 'No mutation reached the transport boundary')
        assert.equal(failure.outcomeUnknown === true, false, 'An unsent command has no unknown native outcome')
        assert.equal(f.bridge.recoveryInfo, null, 'A local rejection cannot reserve Check Status indefinitely')
        assert.equal(f.timers.size, 0)
        const abandoned = f.prepared[0]
        f.hooks.carry = body => body
        f.hooks.timer = null
        const retry = f.bridge.perform('startBookOver')
        retry.catch(() => {})
        assert.equal(f.messages.length, 1, 'Only the new deliberate action is sent')
        assert.equal(f.messages[0].kind, 'command')
        if (abandoned) {
            assert.notEqual(f.messages[0].requestID, abandoned.requestID)
            assert.equal(f.acknowledge(abandoned), false, 'Local-abort delivery no longer owns a reply slot')
        }
        assert.equal(f.acknowledge(), true)
        assert.equal((await retry).committed, true)
        assert.equal(f.bridge.recoveryInfo, null)
    })
}

test('a throw after entering native transport keeps outcome recovery and forbids a second command', async t => {
    const f = fixture(t, { post: () => { throw new Error('Transport did not acknowledge') } })
    await assert.rejects(f.bridge.perform('startBookOver'), error => error.outcomeUnknown === true)
    const original = f.messages[0]
    assert.equal(f.bridge.recoveryInfo.requestID, original.requestID)
    await assert.rejects(f.bridge.perform('startBookOver'), error => error.outcomeUnknown === true)
    f.hooks.post = null
    const status = f.bridge.recover()
    assert.deepEqual(f.messages.map(x => x.kind), ['command', 'status'])
    assert.equal(f.messages[1].requestID, original.requestID)
    assert.equal(f.acknowledge(original), true, 'The late original native result is still authoritative')
    assert.equal((await status).committed, true)
})

test('a real delivery timeout retains the immutable original operation', async t => {
    const f = fixture(t)
    const first = f.bridge.perform('finishBook')
    const rejected = assert.rejects(first, error => error.outcomeUnknown === true)
    f.expire()
    await rejected
    const original = f.messages[0]
    const status = f.bridge.recover()
    assert.deepEqual(f.messages.map(x => x.kind), ['command', 'status'])
    assert.equal(f.messages[1].requestID, original.requestID)
    assert.equal(f.acknowledge(original), true)
    assert.equal((await status).committed, true)
})

test('acknowledgement inside a throwing transport wrapper still wins', async t => {
    const f = fixture(t)
    f.hooks.post = message => {
        assert.equal(f.acknowledge(message), true)
        throw new Error('Optional wrapper failed after native completion')
    }
    assert.equal((await f.bridge.perform('finishBook')).committed, true)
    assert.equal(f.bridge.recoveryInfo, null)
    assert.equal(f.timers.size, 0)
})

for (const kind of ['status', 'navigate']) {
    test(`${kind} preparation failure cannot forget a previously submitted operation`, async t => {
        const f = fixture(t)
        const first = f.bridge.perform('startBookOver')
        const original = f.messages[0]
        if (kind === 'navigate') {
            f.acknowledge(original, { navigation: { status: 'failed' } })
            await first
        } else {
            const rejected = assert.rejects(first, error => error.outcomeUnknown === true)
            f.expire()
            await rejected
        }
        f.hooks.carry = () => null
        await assert.rejects(f.bridge.recover(), error => error.outcomeUnknown === true)
        assert.equal(f.bridge.recoveryInfo.requestID, original.requestID)
        assert.equal(f.messages.length, 1, 'The failed recovery never posts')
        await assert.rejects(f.bridge.perform('startBookOver'), error => error.outcomeUnknown === true)
        f.hooks.carry = body => body
        const recovery = f.bridge.recover()
        assert.equal(f.messages.at(-1).kind, 'status')
        assert.equal(f.messages.at(-1).requestID, original.requestID)
        f.acknowledge()
        assert.equal((await recovery).committed, true)
    })
}

test('local-abort timer cleanup cannot erase a newly admitted action', async t => {
    const f = fixture(t, { carry: () => null })
    let successor
    f.hooks.clear = () => {
        f.hooks.clear = null
        f.hooks.carry = body => body
        successor = f.bridge.perform('finishBook')
        successor.catch(() => {})
    }
    await assert.rejects(f.bridge.perform('startBookOver'))
    assert.equal(f.messages.length, 1, 'The old reservation is removed before optional timer cleanup')
    assert.equal(f.bridge.recoveryInfo.requestID, f.messages[0].requestID)
    assert.equal(f.acknowledge(), true)
    assert.equal((await successor).committed, true)
    assert.equal(f.timers.size, 0)
})
