import assert from 'node:assert/strict'
import test from 'node:test'
import { pathToFileURL } from 'node:url'
const moduleURL = process.env.LAKE_BOOK_ACTION_SOURCE
    ? pathToFileURL(process.env.LAKE_BOOK_ACTION_SOURCE)
    : new URL('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-action-bridge.js', import.meta.url)
const { createBookActionBridge } = await import(moduleURL)

const drain = async () => { for (let index = 0; index < 8; index++) await Promise.resolve() }
const observe = promise => {
    const state = { status: 'pending' }
    promise.then(value => Object.assign(state, { status: 'fulfilled', value }),
        error => Object.assign(state, { status: 'rejected', error }))
    return state
}
function fixture(t) {
    let sequence = 0, timerID = 0
    const messages = [], timers = new Map(), removed = [], hooks = {}
    const bridge = createBookActionBridge({
        postMessage: message => { messages.push(message); hooks.post?.(message) },
        documentStartedAtMs: 1, topWindowURL: 'ebook://book',
        captureContext: () => {
            hooks.context?.()
            return hooks.contextValue ?? { contextID: 'context', locationRevision: 1, scope: { chapterEpochID: null } }
        },
        captureProducerOwner: () => { hooks.producer?.(); return { token: 'producer' } },
        carryProducerOwner: (body, owner) => { hooks.carry?.(); return { ...body, readerArticleProducer: owner } },
        makeRequestID: () => {
            hooks.identifier?.()
            return `00000000-0000-4000-8000-${String(++sequence).padStart(12, '0')}`
        },
        setTimer: callback => {
            const id = ++timerID
            timers.set(id, callback)
            hooks.install?.(id, callback)
            return id
        },
        clearTimer: id => {
            removed.push(id)
            timers.delete(id)
            hooks.clear?.(id)
        },
    })
    bridge.setAccountPresentation('1:1')
    t.after(() => { for (const key of Object.keys(hooks)) delete hooks[key]; bridge.close() })
    const body = (message, extra = {}) => ({ requestID: message.requestID,
        accountPresentation: '1:1', ok: true, committed: true,
        ...(message.action === 'finishBook' ? {} : { navigation: { status: 'completed' } }), ...extra })
    const acknowledge = (message, extra) => bridge.acknowledge(message.deliveryID, body(message, extra))
    const timeout = () => [...timers.values()][0]()
    return { bridge, hooks, messages, timers, removed, body, acknowledge, timeout }
}

for (const outcome of ['committed', 'rejected', 'pending']) {
    test(`throwing timer cleanup cannot strand an authenticated ${outcome} reply`, async t => {
        const f = fixture(t)
        const observed = observe(f.bridge.perform('finishBook')), message = f.messages[0]
        f.hooks.clear = () => { throw new Error('optional host cleanup failed') }
        const extra = outcome === 'committed' ? {} : outcome === 'rejected'
            ? { ok: false, committed: false, error: 'Native rejected this command' }
            : { pending: true }
        assert.doesNotThrow(() => assert.equal(f.acknowledge(message, extra), true))
        await drain()
        assert.equal(observed.status, 'fulfilled', 'Settled native truth must reach the original promise')
        assert.equal(observed.value.ok, outcome !== 'rejected')
        assert.equal(f.timers.size, 0)
        assert.equal(f.acknowledge(message, extra), false)
    })
}
for (const boundary of ['timeout', 'close', 'account']) {
    test(`${boundary} settles despite a timer cleanup exception`, async t => {
        const f = fixture(t)
        const observed = observe(f.bridge.perform('finishBook'))
        f.hooks.clear = () => { throw new Error('cleanup failed') }
        assert.doesNotThrow(() => {
            if (boundary === 'timeout') f.timeout()
            else if (boundary === 'close') f.bridge.close()
            else f.bridge.setAccountPresentation('2:1')
        })
        await drain()
        assert.equal(observed.status, 'rejected')
        assert.equal(observed.error.outcomeUnknown, true)
        if (boundary === 'account') assert.equal(observed.error.presentationSuperseded, true)
        assert.equal(f.messages.length, 1, 'Cleanup never replays a command')
    })
}
for (const status of ['completed', 'failed', 'superseded']) {
    test(`caller mutation cannot rewrite cached ${status} navigation truth`, async t => {
        const f = fixture(t), promise = f.bridge.perform('startBookOver'), message = f.messages[0]
        f.acknowledge(message, { navigation: { status } })
        const result = await promise
        result.ok = false
        result.navigation.status = 'caller-overwrite'
        result.requestID = 'caller-overwrite'
        const recovery = { requestID: message.requestID, action: message.action, kind: 'status' }
        const cached = await f.bridge.recover(recovery)
        assert.equal(cached.ok, true)
        assert.equal(cached.navigation.status, status)
        assert.equal(cached.requestID, message.requestID)
        cached.navigation.status = 'second-overwrite'
        assert.equal((await f.bridge.recover(recovery)).navigation.status, status)
        assert.equal(f.messages.length, 1, 'Cached status must remain read-only')
        if (status === 'failed') assert.equal(f.bridge.recoveryInfo.kind, 'navigate')
    })
}
for (const failure of ['cycle', 'bigint', 'serializer']) {
    test(`${failure} reply copy failure leaves the exact native delivery retryable`, async t => {
        const f = fixture(t), observed = observe(f.bridge.perform('finishBook')), message = f.messages[0]
        const result = f.body(message)
        if (failure === 'cycle') result.extra = result
        if (failure === 'bigint') result.extra = 1n
        if (failure === 'serializer') result.toJSON = () => { throw new Error('could not copy') }
        assert.doesNotThrow(() => assert.equal(f.bridge.acknowledge(message.deliveryID, result), false))
        await drain()
        assert.equal(observed.status, 'pending')
        assert.equal(f.timers.size, 1)
        assert.equal(f.acknowledge(message), true)
        await drain()
        assert.equal(observed.status, 'fulfilled')
        assert.equal(observed.value.committed, true)
    })
}
for (const field of ['requestID', 'accountPresentation', 'committed', 'ok', 'null']) {
    test(`acknowledgement validates copied ${field}, not the serializer's original fields`, async t => {
        const f = fixture(t), observed = observe(f.bridge.perform('finishBook')), message = f.messages[0]
        const copied = f.body(message)
        if (field === 'requestID') copied.requestID = 'wrong-request'
        if (field === 'accountPresentation') copied.accountPresentation = '2:1'
        if (field === 'committed') copied.committed = false
        if (field === 'ok') delete copied.ok
        const result = { ...f.body(message), toJSON: () => field === 'null' ? null : copied }
        assert.equal(f.bridge.acknowledge(message.deliveryID, result), false)
        await drain()
        assert.equal(observed.status, 'pending')
        assert.equal(f.acknowledge(message), true)
        await drain()
        assert.equal(observed.value.committed, true)
    })
}
for (const boundary of ['close', 'account', 'successor-reply']) {
    test(`copy-time ${boundary} supersedes the outer acknowledgement`, async t => {
        const f = fixture(t), observed = observe(f.bridge.perform('finishBook')), message = f.messages[0]
        const result = f.body(message)
        result.toJSON = () => {
            if (boundary === 'close') f.bridge.close()
            if (boundary === 'account') f.bridge.setAccountPresentation('2:1')
            if (boundary === 'successor-reply') assert.equal(f.acknowledge(message, { ok: false, committed: false, error: 'newer' }), true)
            return f.body(message)
        }
        assert.equal(f.bridge.acknowledge(message.deliveryID, result), false)
        await drain()
        assert.equal(observed.status, boundary === 'successor-reply' ? 'fulfilled' : 'rejected')
        if (boundary === 'successor-reply') {
            assert.equal(observed.value.ok, false)
            assert.equal((await f.bridge.recover({ requestID: message.requestID, action: message.action })).error, 'newer')
        }
        assert.equal(f.timers.size, 0)
    })
}

test('terminal truth is cached before cleanup admits the next deliberate command', async t => {
    const f = fixture(t), first = observe(f.bridge.perform('finishBook')), message = f.messages[0]
    let next
    f.hooks.clear = () => {
        delete f.hooks.clear
        next = observe(f.bridge.perform('finishBook'))
    }
    assert.equal(f.acknowledge(message), true)
    await drain()
    assert.equal(first.status, 'fulfilled')
    assert.equal(f.messages.length, 2)
    assert.equal(next.status, 'pending')
    assert.equal(f.bridge.recoveryInfo.requestID, f.messages[1].requestID)
    f.acknowledge(f.messages[1])
    await drain()
    assert.equal(next.status, 'fulfilled')
})

test('late command result and active status settle truthfully across cleanup account replacement', async t => {
    const f = fixture(t), original = observe(f.bridge.perform('finishBook')), message = f.messages[0]
    f.timeout()
    await drain()
    assert.equal(original.status, 'rejected')
    const status = observe(f.bridge.recover())
    f.hooks.clear = () => { delete f.hooks.clear; f.bridge.setAccountPresentation('2:1') }
    assert.equal(f.acknowledge(message), true)
    await drain()
    assert.equal(status.status, 'fulfilled')
    assert.equal(status.value.committed, true)
    assert.equal(f.bridge.recoveryInfo, null)
    assert.equal(f.timers.size, 0)
    assert.deepEqual(f.messages.map(x => x.kind), ['command', 'status'])
})

for (const boundary of ['close', 'account', 'timeout', 'acknowledge']) {
    test(`timer installation ${boundary} cannot publish an orphaned handle or send afterward`, async t => {
        const f = fixture(t)
        f.hooks.install = (_id, callback) => {
            delete f.hooks.install
            if (boundary === 'close') f.bridge.close()
            if (boundary === 'account') f.bridge.setAccountPresentation('2:1')
            if (boundary === 'timeout') callback()
            if (boundary === 'acknowledge') {
                const info = f.bridge.recoveryInfo
                assert.equal(f.bridge.acknowledge(`${info.requestID}:1`, {
                    requestID: info.requestID, ok: true, committed: true, accountPresentation: '1:1',
                }), true)
            }
        }
        const observed = observe(f.bridge.perform('finishBook'))
        await drain()
        assert.equal(observed.status, boundary === 'acknowledge' ? 'fulfilled' : 'rejected')
        assert.equal(f.timers.size, 0, 'The late returned timer must be disposed, not attached to a settled delivery')
        assert.equal(f.messages.length, 0, 'A retired delivery must not post after host timer callbacks')
    })
}

test('throwing timer installation returns a recoverable promise instead of stranding current', async t => {
    const f = fixture(t)
    f.hooks.install = id => { f.timers.delete(id); throw new Error('timers unavailable') }
    let promise
    assert.doesNotThrow(() => { promise = f.bridge.perform('finishBook') })
    const observed = observe(promise)
    await drain()
    assert.equal(observed.status, 'rejected')
    assert.equal(observed.error.outcomeUnknown, true)
    assert.equal(f.messages.length, 0)
    delete f.hooks.install
    const status = observe(f.bridge.recover())
    assert.equal(f.messages[0].kind, 'status')
    f.acknowledge(f.messages[0], { ok: false, committed: false })
    await drain()
    assert.equal(status.status, 'fulfilled')
    assert.equal(f.bridge.recoveryInfo, null)
})

for (const boundary of ['close', 'account']) {
    test(`producer envelope ${boundary} withdraws the original command before dispatch`, async t => {
        const f = fixture(t)
        f.hooks.carry = () => {
            if (boundary === 'close') f.bridge.close()
            else f.bridge.setAccountPresentation('2:1')
        }
        const observed = observe(f.bridge.perform('finishBook'))
        await drain()
        assert.equal(observed.status, 'rejected')
        assert.equal(f.messages.length, 0)
        assert.equal(f.timers.size, 0)
    })
}

for (const seam of ['context', 'producer', 'identifier', 'copy']) {
    for (const boundary of ['close', 'account']) {
        test(`${seam} preparation cannot acquire the ${boundary} successor`, async t => {
            const f = fixture(t)
            const retire = () => boundary === 'close' ? f.bridge.close() : f.bridge.setAccountPresentation('2:1')
            if (seam === 'copy') f.hooks.contextValue = { toJSON: () => { retire(); return { contextID: 'copied' } } }
            else f.hooks[seam] = retire
            const observed = observe(f.bridge.perform('finishBook'))
            await drain()
            assert.equal(observed.status, 'rejected')
            assert.equal(f.bridge.recoveryInfo, null, 'No unsent prepared request survives its account/document')
            assert.equal(f.messages.length, 0)
            assert.equal(f.timers.size, 0)
        })
    }
}

for (const seam of ['context', 'producer', 'identifier', 'copy']) {
    test(`reentrant ${seam} preparation cannot create overlapping semantic commands`, async t => {
        const f = fixture(t)
        let nested
        const reenter = () => {
            delete f.hooks[seam]
            if (seam === 'copy') f.hooks.contextValue = { contextID: 'plain' }
            nested = observe(f.bridge.perform('finishBook'))
        }
        if (seam === 'copy') {
            let entered = false
            f.hooks.contextValue = { toJSON: () => { if (!entered) { entered = true; reenter() }; return { contextID: 'copied' } } }
        } else f.hooks[seam] = reenter
        const outer = observe(f.bridge.perform('finishBook'))
        await drain()
        assert.equal(f.messages.length, 1, 'One synchronous activation may prepare only one semantic request')
        assert.equal(nested.status, 'rejected')
        assert.equal(nested.error.outcomeUnknown, undefined, 'No nested mutation was submitted')
        f.acknowledge(f.messages[0])
        await drain()
        assert.equal(outer.status, 'fulfilled')
    })
}

test('synchronous reply followed by bridge exception preserves accepted native truth', async t => {
    const f = fixture(t)
    f.hooks.post = message => { f.acknowledge(message); throw new Error('wrapper after delivery') }
    const result = await f.bridge.perform('finishBook')
    assert.equal(result.committed, true)
    assert.equal(f.bridge.recoveryInfo, null)
    assert.equal(f.timers.size, 0)
})

test('a failed navigation result retains exactly one navigation-only retry', async t => {
    const f = fixture(t), original = f.bridge.perform('startChapterOver'), command = f.messages[0]
    f.acknowledge(command, { navigation: { status: 'failed' } })
    await original
    const retry = f.bridge.recover()
    assert.equal(f.bridge.recover(), retry)
    assert.equal(f.messages.length, 2)
    f.acknowledge(f.messages[1])
    assert.equal((await retry).navigation.status, 'completed')
    assert.deepEqual(f.messages.map(x => x.kind), ['command', 'navigate'])
})

test('recovery producer capture coalesces a nested active delivery instead of duplicating it', async t => {
    const f = fixture(t), command = observe(f.bridge.perform('finishBook'))
    f.timeout()
    await drain()
    assert.equal(command.status, 'rejected')
    let nested
    f.hooks.producer = () => { delete f.hooks.producer; nested = f.bridge.recover() }
    const outer = f.bridge.recover()
    assert.equal(outer, nested)
    assert.equal(f.messages.length, 2)
    f.acknowledge(f.messages[1])
    await outer
})

for (const value of [null, []]) {
    test(`malformed copied context (${value === null ? 'null' : 'array'}) cannot reserve a native command`, async t => {
        const f = fixture(t)
        f.hooks.contextValue = { toJSON: () => value }
        const rejected = observe(f.bridge.perform('finishBook'))
        await drain()
        assert.equal(rejected.status, 'rejected')
        assert.equal(f.messages.length, 0)
        assert.equal(f.bridge.recoveryInfo, null)
        delete f.hooks.contextValue
        const accepted = observe(f.bridge.perform('finishBook'))
        f.acknowledge(f.messages[0])
        await drain()
        assert.equal(accepted.status, 'fulfilled', 'Rejected preparation must release its local reservation')
    })
}

for (const seam of ['context', 'producer', 'identifier', 'copy']) {
    test(`throwing ${seam} preparation is a rejected promise and releases the reservation`, async t => {
        const f = fixture(t)
        const error = new Error('preparation failed')
        if (seam === 'copy') f.hooks.contextValue = { toJSON: () => { throw error } }
        else f.hooks[seam] = () => { throw error }
        let promise
        assert.doesNotThrow(() => { promise = f.bridge.perform('finishBook') })
        await assert.rejects(promise, candidate => candidate === error)
        assert.equal(f.messages.length, 0)
        assert.equal(f.bridge.recoveryInfo, null)
        delete f.hooks[seam]
        delete f.hooks.contextValue
        const accepted = observe(f.bridge.perform('finishBook'))
        f.acknowledge(f.messages[0])
        await drain()
        assert.equal(accepted.status, 'fulfilled')
    })
}

test('terminal outcome retires retained timers before stale timeout callbacks run again', async t => {
    const f = fixture(t), first = observe(f.bridge.perform('finishBook')), message = f.messages[0]
    const oldTimer = [...f.timers.values()][0]
    f.acknowledge(message)
    const second = observe(f.bridge.perform('finishBook'))
    oldTimer()
    await drain()
    assert.equal(first.status, 'fulfilled')
    assert.equal(second.status, 'pending')
    assert.equal(f.timers.size, 1)
    assert.equal(f.bridge.recoveryInfo.requestID, f.messages[1].requestID)
    f.acknowledge(f.messages[1])
    await drain()
    assert.equal(second.status, 'fulfilled')
})

test('completed cache retains exactly the newest 32 semantic outcomes', async t => {
    const f = fixture(t)
    for (let index = 0; index < 33; index++) {
        const p = f.bridge.perform('finishBook')
        f.acknowledge(f.messages.at(-1))
        await p
    }
    const first = f.messages[0], second = f.messages[1]
    await assert.rejects(f.bridge.recover({ requestID: first.requestID, action: first.action }), e => e.outcomeUnknown)
    assert.equal((await f.bridge.recover({ requestID: second.requestID, action: second.action })).committed, true)
    assert.equal(f.messages.length, 33)
    assert.equal(f.timers.size, 0)
})

test('64-step command/status/account history keeps one mutation per semantic action', async t => {
    const f = fixture(t)
    let account = 1
    for (let index = 0; index < 64; index++) {
        if (index > 0 && index % 16 === 0) {
            assert.equal(f.bridge.setAccountPresentation(`${++account}:1`), true)
            assert.equal(f.bridge.recoveryInfo, null)
        }
        const original = observe(f.bridge.perform(index % 2 ? 'finishBook' : 'startBookOver'))
        const message = f.messages.at(-1)
        const recovery = { requestID: message.requestID, action: message.action, kind: 'status' }
        let active = original
        if (index % 3 === 0) {
            f.timeout()
            await drain()
            assert.equal(original.status, 'rejected')
            active = observe(f.bridge.recover(recovery))
            assert.equal(f.messages.at(-1).kind, 'status')
        }
        const corrupt = f.body(message, { accountPresentation: `${account}:1` })
        corrupt.toJSON = () => { throw new Error('copy failure') }
        assert.equal(f.bridge.acknowledge(message.deliveryID, corrupt), false)
        if (index % 4 === 0) f.hooks.clear = () => { throw new Error('optional cleanup') }
        assert.equal(f.acknowledge(message, { accountPresentation: `${account}:1` }), true)
        delete f.hooks.clear
        await drain()
        assert.equal(active.status, 'fulfilled')
        active.value.ok = false
        assert.equal((await f.bridge.recover(recovery)).committed, true)
        assert.equal(f.bridge.recoveryInfo, null)
        assert.equal(f.timers.size, 0)
    }
    assert.equal(f.messages.filter(message => message.kind === 'command').length, 64)
    assert.equal(new Set(f.messages.filter(message => message.kind === 'command').map(message => message.requestID)).size, 64)
    assert.equal(f.messages.length, 86)
})
