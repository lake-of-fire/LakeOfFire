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

for (const action of ['finishBook', 'startBookOver', 'startChapterOver']) {
    test(`timer cancellation failure cannot strand committed ${action}`, async t => {
        const f = fixture(t), completion = f.perform(action)
        f.hooks.clearTimer = () => { throw new Error('timer cleanup unavailable') }
        assert.equal(f.ack(), true)
        const outcome = await observe(completion)
        assert.equal(outcome.status, 'fulfilled')
        assert.equal(outcome.value.committed, true)
        assert.equal(f.bridge.recoveryInfo, null)
    })
}

for (const boundary of ['close', 'account']) {
    test(`${boundary} settles every delivery despite timer cleanup failure`, async t => {
        const f = fixture(t), first = f.perform()
        f.timeout()
        assert.equal((await observe(first)).status, 'rejected')
        const second = f.recover()
        f.hooks.clearTimer = () => { throw new Error('cleanup unavailable') }
        assert.doesNotThrow(() => boundary === 'close' ? f.bridge.close() : f.bridge.setAccountPresentation('2:1'))
        assert.equal((await observe(second)).status, 'rejected')
        assert.equal(f.bridge.recoveryInfo, null)
    })
}

test('throwing timer installation retains the existing status-only recovery policy', async t => {
    const f = fixture(t, { setTimer: () => { throw new Error('timer installation failed') } })
    let completion
    assert.doesNotThrow(() => { completion = f.perform('finishBook') })
    assert.equal(f.posts.length, 0)
    assert.equal((await observe(completion)).status, 'rejected')
    f.hooks.setTimer = null
    const status = f.recover()
    assert.equal(f.posts.length, 1)
    assert.equal(f.posts[0].kind, 'status')
    f.ack(f.posts[0], { ok: false, committed: false })
    assert.equal((await observe(status)).status, 'fulfilled')
    assert.equal(f.bridge.recoveryInfo, null)
})

for (const transition of ['close', 'account', 'timeout']) {
    test(`timer installation ${transition} withdraws the unsent delivery and releases its returned handle`, async t => {
        const f = fixture(t)
        f.hooks.setTimer = callback => {
            if (transition === 'close') f.bridge.close()
            if (transition === 'account') f.bridge.setAccountPresentation('2:1')
            if (transition === 'timeout') callback()
            return 99
        }
        const completion = f.perform()
        assert.equal(f.posts.length, 0)
        assert.equal((await observe(completion)).status, 'rejected')
        assert.ok(f.cleared.includes(99), 'The late old timer handle must be disposed')
    })
}

for (const transition of ['close', 'account']) {
    test(`producer envelope ${transition} cannot dispatch an already retired command`, async t => {
        const f = fixture(t)
        f.hooks.carry = body => {
            if (transition === 'close') f.bridge.close()
            else f.bridge.setAccountPresentation('2:1')
            return body
        }
        const completion = f.perform()
        assert.equal(f.posts.length, 0)
        assert.equal((await observe(completion)).status, 'rejected')
    })
}

test('native acknowledgement during envelope preparation prevents a duplicate dispatch', async t => {
    const f = fixture(t)
    f.hooks.carry = body => { assert.equal(f.ack(body), true); return body }
    const completion = f.perform('finishBook')
    assert.equal(f.posts.length, 0)
    assert.equal((await observe(completion)).status, 'fulfilled')
})

for (const transition of ['close', 'account']) {
    test(`recovery producer ${transition} cannot post an old-account observation`, async t => {
        const f = fixture(t), first = f.perform()
        f.timeout()
        await observe(first)
        f.hooks.producer = () => {
            if (transition === 'close') f.bridge.close()
            else f.bridge.setAccountPresentation('2:1')
            return { token: 'replacement' }
        }
        const recovery = f.recover()
        assert.equal(f.posts.length, 1)
        assert.equal((await observe(recovery)).status, 'rejected')
    })
}

test('a committed native response settles all attempts before timer cleanup can close the bridge', async t => {
    const f = fixture(t), original = f.perform()
    const command = f.posts[0]
    f.timeout()
    await observe(original)
    const status = f.recover()
    f.hooks.clearTimer = () => f.bridge.close()
    assert.equal(f.ack(command), true)
    const outcome = await observe(status)
    assert.equal(outcome.status, 'fulfilled')
    assert.equal(outcome.value.committed, true)
    assert.equal(f.bridge.recoveryInfo, null)
})

test('timer-cleanup account switch cannot repopulate an old completed-request cache', async t => {
    const f = fixture(t), original = f.perform()
    const command = f.posts[0]
    f.timeout()
    await observe(original)
    const status = f.recover()
    f.hooks.clearTimer = () => f.bridge.setAccountPresentation('2:1')
    assert.equal(f.ack(command), true)
    assert.equal((await observe(status)).status, 'fulfilled')
    const stale = await observe(f.recover({ requestID: command.requestID, action: command.action }))
    assert.equal(stale.status, 'rejected')
    assert.ok(unknown(stale.error))
    assert.equal(f.posts.length, 2)
})

for (const field of ['circular', 'throwing']) {
    test(`failed ${field} result copy leaves the original delivery available for a valid reply`, async t => {
        const f = fixture(t), completion = f.perform()
        const body = f.posts[0], result = f.reply(body)
        if (field === 'circular') result.self = result
        else result.toJSON = () => { throw new Error('copy failed') }
        assert.equal(f.bridge.acknowledge(body.deliveryID, result), false)
        assert.equal(f.ack(body), true)
        assert.equal((await observe(completion)).status, 'fulfilled')
    })
}

for (const mutation of ['requestID', 'accountPresentation', 'committed']) {
    test(`result serialization cannot replace validated ${mutation}`, async t => {
        const f = fixture(t), completion = f.perform()
        const body = f.posts[0], result = f.reply(body)
        result.toJSON = () => ({ ...f.reply(body), [mutation]: mutation === 'committed' ? false : 'different' })
        assert.equal(f.bridge.acknowledge(body.deliveryID, result), false)
        assert.equal(f.ack(body), true)
        assert.equal((await observe(completion)).status, 'fulfilled')
    })
}

test('a nested native acknowledgement wins over the older result being copied', async t => {
    const f = fixture(t), completion = f.perform()
    const body = f.posts[0], result = f.reply(body, { navigation: { status: 'failed' } })
    result.toJSON = () => {
        assert.equal(f.ack(body), true)
        return f.reply(body, { navigation: { status: 'failed' } })
    }
    assert.equal(f.bridge.acknowledge(body.deliveryID, result), false)
    assert.equal((await observe(completion)).value.navigation.status, 'completed')
    assert.equal(f.bridge.recoveryInfo, null)
})

test('account retirement during result copying rejects the old acknowledgement', async t => {
    const f = fixture(t), completion = f.perform()
    const body = f.posts[0], result = f.reply(body)
    result.toJSON = () => { f.bridge.setAccountPresentation('2:1'); return f.reply(body) }
    assert.equal(f.bridge.acknowledge(body.deliveryID, result), false)
    assert.equal((await observe(completion)).status, 'rejected')
    assert.equal(f.bridge.recoveryInfo, null)
})

test('consumer mutation of a resolved result cannot change cached native truth', async t => {
    const f = fixture(t), completion = f.perform()
    const body = f.posts[0]
    assert.equal(f.ack(body, { navigation: { status: 'failed', message: 'saved' } }), true)
    const result = await completion
    result.ok = false
    result.committed = false
    result.navigation.status = 'completed'
    const cached = await f.recover({ ...f.bridge.recoveryInfo, kind: 'status' })
    assert.equal(cached.ok, true)
    assert.equal(cached.committed, true)
    assert.equal(cached.navigation.status, 'failed')
    assert.equal(f.bridge.recoveryInfo.kind, 'navigate')
})

test('synchronous committed reply followed by bridge throw keeps success', async t => {
    const f = fixture(t)
    f.hooks.post = body => { f.ack(body); throw new Error('post wrapper failed after native reply') }
    const completion = f.perform('finishBook')
    const outcome = await observe(completion)
    assert.equal(outcome.status, 'fulfilled')
    assert.equal(outcome.value.committed, true)
})

test('normal timeout/status navigation recovery sends exactly one mutation', async t => {
    const f = fixture(t), original = f.perform()
    const command = f.posts[0]
    f.timeout()
    assert.equal((await observe(original)).status, 'rejected')
    const status = f.recover()
    assert.equal(f.posts.at(-1).kind, 'status')
    f.ack(f.posts.at(-1), { navigation: { status: 'failed' } })
    assert.equal((await status).committed, true)
    const navigation = f.recover(f.bridge.recoveryInfo)
    assert.equal(f.posts.at(-1).kind, 'navigate')
    f.ack()
    assert.equal((await navigation).navigation.status, 'completed')
    assert.equal(f.posts.filter(p => p.kind === 'command').length, 1)
    assert.ok(f.posts.every(p => p.requestID === command.requestID))
    assert.equal(f.bridge.recoveryInfo, null)
})

for (const boundary of ['context', 'producer', 'id', 'context-copy']) {
    for (const transition of ['close', 'account', 'nested']) {
        test(`command preparation ${boundary}/${transition} preserves current admission policy`, async t => {
            const f = fixture(t)
            let nested, entered = false
            const change = () => {
                if (entered) return
                entered = true
                f.hooks.context = null; f.hooks.producer = null; f.hooks.id = null
                if (transition === 'close') f.bridge.close()
                else if (transition === 'account') f.bridge.setAccountPresentation('2:1')
                else nested = f.perform('finishBook')
            }
            if (boundary === 'context') f.hooks.context = () => { change(); return { contextID: 'old' } }
            if (boundary === 'producer') f.hooks.producer = () => { change(); return { token: 'old' } }
            if (boundary === 'id') f.hooks.id = () => { change(); return uuid(99) }
            if (boundary === 'context-copy') f.hooks.context = () => ({
                toJSON() { change(); return { contextID: 'old' } },
            })
            const original = f.perform()
            assert.equal(entered, true)
            if (transition === 'nested') {
                // Preserve the concurrent synchronous preparation reservation:
                // the original activation owns admission; the nested one rejects.
                assert.equal(f.posts.length, 1)
                assert.equal((await observe(nested)).status, 'rejected')
                assert.equal(f.posts[0].action, 'startBookOver')
                f.ack()
                assert.equal((await observe(original)).status, 'fulfilled')
            } else {
                assert.equal((await observe(original)).status, 'rejected')
                assert.equal(f.posts.length, 0)
            }
            assert.equal(f.bridge.recoveryInfo, null)
        })
    }
}

for (const boundary of ['producer', 'id', 'context-copy']) {
    test(`throwing ${boundary} preparation returns a rejected Promise and leaves no reservation`, async t => {
        const f = fixture(t)
        const fail = () => { throw new Error('preparation failed') }
        if (boundary === 'producer') f.hooks.producer = fail
        if (boundary === 'id') f.hooks.id = fail
        if (boundary === 'context-copy') f.hooks.context = () => ({ toJSON: fail })
        let completion
        assert.doesNotThrow(() => { completion = f.perform() })
        assert.equal((await observe(completion)).status, 'rejected')
        assert.equal(f.posts.length, 0)
        assert.equal(f.bridge.recoveryInfo, null)
        f.hooks.producer = null; f.hooks.id = null; f.hooks.context = null
        const fresh = f.perform('finishBook')
        f.ack()
        assert.equal((await observe(fresh)).status, 'fulfilled')
    })
}

test('cached request ID collision is rejected rather than rewriting native operation identity', async t => {
    const f = fixture(t, { id: () => uuid(1) })
    const first = f.perform('finishBook')
    f.ack()
    await first
    assert.equal((await observe(f.perform('startBookOver'))).status, 'rejected')
    assert.equal(f.posts.length, 1)
    const cached = await f.recover({ requestID: uuid(1), action: 'finishBook', kind: 'status' })
    assert.equal(cached.committed, true)
})

test('nested recovery capture retains the one selected status attempt', async t => {
    const f = fixture(t), first = f.perform()
    f.timeout(); await observe(first)
    let inner
    f.hooks.producer = () => {
        f.hooks.producer = null
        inner = f.recover()
        return { token: 'old-observer' }
    }
    const outer = f.recover()
    assert.equal(outer, inner, 'A reentrant active recovery remains exactly coalesced')
    assert.equal(f.posts.length, 2)
    f.ack()
    assert.equal((await observe(inner)).status, 'fulfilled')
})

test('late native commit frees the resolved operation before cleanup admits a deliberate new action', async t => {
    const f = fixture(t), first = f.perform()
    const command = f.posts[0]
    f.timeout(); await observe(first)
    const status = f.recover()
    let successor
    f.hooks.clearTimer = () => {
        f.hooks.clearTimer = null
        successor = f.perform('finishBook')
    }
    assert.equal(f.ack(command), true)
    assert.equal(f.posts.length, 3, 'Committed operation must no longer block successor admission during cleanup')
    assert.equal(f.bridge.recoveryInfo.requestID, f.posts[2].requestID)
    f.ack(f.posts[2])
    assert.equal((await observe(status)).status, 'fulfilled')
    assert.equal((await observe(successor)).status, 'fulfilled')
})

test('completed outcome cache remains bounded to its existing 32 requests', async t => {
    const f = fixture(t)
    for (let i = 0; i < 33; i++) {
        const completion = f.perform('finishBook')
        f.ack()
        await completion
    }
    assert.equal((await observe(f.recover({ requestID: f.posts[0].requestID, action: 'finishBook' }))).status, 'rejected')
    assert.equal((await f.recover({ requestID: f.posts[1].requestID, action: 'finishBook' })).committed, true)
    assert.equal(f.posts.length, 33)
    assert.equal(f.timers.size, 0)
})

test('error formatting cannot replace a native result acknowledged by the error getter', async t => {
    const f = fixture(t)
    f.hooks.post = body => {
        throw { get message() { f.ack(body); return 'late wrapper error' } }
    }
    const completion = f.perform('finishBook')
    assert.equal((await observe(completion)).value.committed, true)
    assert.equal(f.bridge.recoveryInfo, null)
})

for (const property of ['requestID', 'action', 'kind']) {
    test(`throwing recovery ${property} does not escape Promise delivery or disturb the original attempt`, async t => {
        const f = fixture(t), first = f.perform()
        const descriptor = { ...f.bridge.recoveryInfo }
        Object.defineProperty(descriptor, property, { get() { throw new Error('unreadable recovery field') } })
        let retry
        assert.doesNotThrow(() => { retry = f.recover(descriptor) })
        assert.equal((await observe(retry)).status, 'rejected')
        assert.equal(f.posts.length, 1)
        f.ack()
        assert.equal((await observe(first)).status, 'fulfilled')
    })
}

for (const transition of ['account', 'nested-admission']) {
    test(`recovery descriptor cannot adopt ${transition} performed by its getter`, async t => {
        const f = fixture(t, { id: () => uuid(1) })
        const first = f.perform('finishBook')
        f.ack(); await first
        let nested
        const descriptor = { action: 'finishBook', kind: 'status', get requestID() {
            if (transition === 'account') f.bridge.setAccountPresentation('2:1')
            // For same-account reentry, the successor has a different native ID.
            f.hooks.id = () => transition === 'account' ? uuid(1) : uuid(2)
            nested = f.perform('finishBook')
            f.ack(f.posts.at(-1), { accountPresentation: transition === 'account' ? '2:1' : '1:1' })
            return f.posts.at(-1).requestID
        } }
        assert.equal((await observe(f.recover(descriptor))).status, 'rejected')
        assert.equal((await observe(nested)).status, 'fulfilled')
        assert.equal(f.posts.length, 2)
        assert.equal(f.bridge.recoveryInfo, null)
    })
}

test('a thrown transport error message is sampled once', async t => {
    const f = fixture(t)
    let reads = 0
    f.hooks.post = () => { throw { get message() { reads++; return 'post failed' } } }
    assert.equal((await observe(f.perform())).status, 'rejected')
    assert.equal(reads, 1)
})

for (const field of ['protocolVersion', 'kind', 'action', 'requestID', 'deliveryID', 'context']) {
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

test('envelope serialization retirement cannot send a stale command', async t => {
    const f = fixture(t)
    let serialized = false
    f.hooks.carry = body => ({ ...body, toJSON() {
        serialized = true
        f.bridge.setAccountPresentation('2:1')
        return body
    } })
    const completion = f.perform()
    assert.equal(serialized, true)
    assert.equal(f.posts.length, 0)
    assert.equal((await observe(completion)).status, 'rejected')
})

test('equivalent context key ordering and attached producer evidence remain supported', async t => {
    const f = fixture(t)
    f.hooks.carry = (body, owner) => ({ ...body,
        context: { locationRevision: body.context.locationRevision, contextID: body.context.contextID },
        readerArticleProducer: owner,
    })
    const completion = f.perform()
    assert.equal(f.posts.length, 1)
    assert.equal(f.posts[0].readerArticleProducer.token, 'original')
    f.ack()
    assert.equal((await observe(completion)).status, 'fulfilled')
})

test('the actual compatibility producer adapter can attach evidence in place', async t => {
    const { carryReaderArticleProducerOwner } = await import('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/reader-producer-evidence.js')
    const f = fixture(t)
    f.hooks.carry = (body, owner) => carryReaderArticleProducerOwner(body, owner, { producer: {} })
    const completion = f.perform()
    assert.equal(f.posts.length, 1, 'Evidence added in place is not a semantic command change')
    assert.equal(f.posts[0].readerArticleProducer.token, 'original')
    f.ack()
    assert.equal((await observe(completion)).status, 'fulfilled')
})
