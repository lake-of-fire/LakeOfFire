import assert from 'node:assert/strict'
import test from 'node:test'
import { createNativeMarkReadRequestCoordinator } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

const unreadableMessage = () => Object.defineProperty({}, 'message', {
    get() { throw new Error('diagnostic getter failed') },
})
const unreadableString = () => ({ toString() { throw new Error('diagnostic conversion failed') } })
const nullPrototype = () => Object.create(null)
const terminal = (message, success = true) => ({
    requestID: message.requestID, sectionId: message.sectionId,
    manualReadPendingProtocol: 1,
    manualReadPendingObservationToken: message.manualReadPendingObservationToken,
    manualReadPendingState: 'finished', success,
    ...(success ? {} : { errorCode: 'cancelled' }),
})

function fixture(t, options = {}) {
    const posted = [], controls = [], notices = [], timers = new Map()
    let sequence = 0
    const coordinator = createNativeMarkReadRequestCoordinator({
        makeRequestID: () => 'transport-errors', lifecycleTarget: new EventTarget(),
        postMessage: message => {
            posted.push(message)
            options.post?.(message)
        },
        postControlMessage: message => {
            controls.push(message)
            options.control?.(message)
        },
        onPending: notice => notices.push(notice),
        scheduleTimeout: callback => { timers.set(++sequence, callback); return sequence },
        cancelTimeout: id => timers.delete(id),
    })
    t.after(() => coordinator.close())
    return { coordinator, posted, controls, notices, timers,
        fire() {
            const [id, callback] = timers.entries().next().value ?? []
            assert.equal(typeof callback, 'function', 'A live observation must retain its timer')
            timers.delete(id)
            callback()
        },
        request(desiredState = 'unmarked') {
            return coordinator.request({ sectionID: 'original', message: { desiredState } })
        },
    }
}

for (const desiredState of ['marked', 'unmarked']) {
    for (const [name, makeError] of [
        ['throwing message', unreadableMessage],
        ['throwing conversion', unreadableString],
        ['null-prototype error', nullPrototype],
    ]) {
        test(`${desiredState}: ${name} cannot escape initial transport settlement`, async t => {
            const f = fixture(t, { post: () => { throw makeError() } })
            let completion
            assert.doesNotThrow(() => { completion = f.request(desiredState) })
            const result = await completion
            assert.equal(result.success, false)
            assert.equal(result.errorCode, 'nativePostFailed')
            assert.equal(result.presentationAllowed, false)
            assert.equal(f.coordinator.pendingCount, 0)
            assert.equal(f.timers.size, 0)
            assert.equal(f.notices.at(-1).phase, 'finished')
            assert.equal(f.controls.length, 0)
        })
    }
}

for (const [name, makeError] of [['ordinary error', () => new Error('bridge unavailable')],
    ['string', () => 'bridge unavailable'], ['null', () => null]]) {
    test(`initial transport retains its established ${name} error code`, async t => {
        const f = fixture(t, { post: () => { throw makeError() } })
        const result = await f.request()
        assert.equal(result.success, false)
        assert.equal(result.errorCode, name === 'null' ? 'nativePostFailed' : 'bridge unavailable')
        assert.equal(f.coordinator.pendingCount, 0)
        assert.equal(f.timers.size, 0)
    })
}

for (const kind of ['status', 'cancel']) {
    test(`${kind}: unreadable error cannot stop observation of an already-submitted command`, async t => {
        let throws = true
        const f = fixture(t, { control: () => { if (throws) throw unreadableString() } })
        const completion = f.request()
        const original = f.posted[0]
        if (kind === 'cancel') {
            assert.doesNotThrow(() => assert.equal(f.coordinator.cancel(original.requestID), true))
        } else assert.doesNotThrow(() => f.fire())
        assert.equal(f.coordinator.pendingCount, 1, 'A control error is not a native outcome')
        assert.equal(f.timers.size, 1, 'The original status loop must remain scheduled')
        assert.equal(f.controls.at(-1).manualReadPendingOperation, kind)
        throws = false
        f.fire()
        assert.equal(f.controls.length, 2)
        assert.equal(f.controls[1].requestID, original.requestID)
        assert.equal(f.posted.length, 1, 'Observation must not replay Mark or Unmark')
        assert.equal(f.coordinator.settle(terminal(original)), true)
        assert.equal((await completion).success, true, 'A native commit can win over Cancel')
        assert.equal(f.timers.size, 0)
    })
}

for (const success of [true, false]) {
    test(`synchronous native ${success} reply wins over an unreadable later wrapper error`, async t => {
        const f = fixture(t, { post: message => {
            f.coordinator.settle(terminal(message, success))
            throw unreadableMessage()
        } })
        let completion
        assert.doesNotThrow(() => { completion = f.request() })
        const result = await completion
        assert.equal(result.success, success)
        assert.equal(result.errorCode, success ? null : 'cancelled')
        assert.equal(f.coordinator.pendingCount, 0)
        assert.equal(f.timers.size, 0)
        assert.equal(f.controls.length, 0)
    })
}

test('a formatting callback that closes cannot convert unknown submission into failure', async t => {
    const f = fixture(t, { post: () => {
        throw Object.defineProperty({}, 'message', { get() {
            f.coordinator.close()
            throw new Error('formatting after close')
        } })
    } })
    let completion
    assert.doesNotThrow(() => { completion = f.request() })
    await assert.rejects(completion, error => error.code === 'readerClosed' && error.outcomeUnknown === true)
    assert.equal(f.coordinator.pendingCount, 0)
    assert.equal(f.timers.size, 0)
})
