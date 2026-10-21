import assert from 'node:assert/strict'
import test from 'node:test'
import { createNativeMarkReadRequestCoordinator } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

// Complete production coordinator and ordinary production imports. The host,
// transport and timers are controlled collaborators, not native persistence.
function fixture(t) {
    const mutations = [], controls = [], notices = [], timers = new Map(), hooks = {}
    let timerID = 0
    const coordinator = createNativeMarkReadRequestCoordinator({
        makeRequestID: () => 'control-composition',
        postMessage(message) { mutations.push(message); hooks.post?.(message) },
        postControlMessage(message) { controls.push(message); hooks.control?.(message) },
        isOwnerCurrent: owner => owner?.current === true,
        onRecoveryIsCurrent: event => event.owner?.current === true,
        onRecovery: event => { hooks.recovery?.(event); return true },
        onRecoveryQuery: () => true,
        onPending: notice => notices.push(notice),
        scheduleTimeout(callback, delay) { const id = ++timerID; timers.set(id, { callback, delay }); return id },
        cancelTimeout(id) { timers.delete(id) },
        lifecycleTarget: { addEventListener() {}, removeEventListener() {} },
    })
    const owner = { current: true }
    const message = desiredState => ({ desiredState, stableSegmentIDs: ['one'],
        topWindowURL: 'ebook://original/book', documentStartedAtMs: 123,
        bookReadingScope: { articleProgressID: 'article', articleEpochID: 'pass',
            chapterKey: 'a'.repeat(64), chapterEpochID: null } })
    const request = (body = message('unmarked'), sectionID = 'section') =>
        coordinator.request({ sectionID, message: body, owner })
    const tick = () => {
        const [id, { callback }] = timers.entries().next().value
        timers.delete(id)
        callback()
    }
    const terminal = (sent, success = true) => ({ requestID: sent.requestID,
        sectionId: sent.sectionId, manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: sent.manualReadPendingObservationToken,
        manualReadPendingState: 'finished', success,
        ...(success ? {} : { errorCode: 'cancelled' }) })
    t.after(() => coordinator.close())
    return { coordinator, mutations, controls, notices, timers, hooks, owner, message, request, tick, terminal }
}

const unreadableError = () => Object.create(null, {
    message: { get() { throw new Error('unreadable diagnostic') } },
    toString: { value() { throw new Error('unprintable diagnostic') } },
})

for (const desiredState of ['marked', 'unmarked']) {
    test(`one ${desiredState} snapshot owns coalescing and every control envelope`, async t => {
        const f = fixture(t)
        let reads = 0
        const original = f.message(desiredState)
        Object.defineProperty(original, 'desiredState', { enumerable: true,
            get() { reads++; return reads === 1 ? desiredState : 'changed-after-capture' } })
        const completion = f.request(original)
        const sent = f.mutations[0]
        assert.equal(reads, 1)
        assert.equal(sent.desiredState, desiredState)
        assert.equal(f.request(f.message(desiredState)), completion)
        const opposite = desiredState === 'marked' ? 'unmarked' : 'marked'
        assert.equal((await f.request(f.message(opposite))).errorCode, 'pendingTargetBusy')
        original.topWindowURL = 'ebook://replacement/book'
        original.documentStartedAtMs = 456
        original.stableSegmentIDs.push('replacement')
        f.tick()
        assert.equal(f.coordinator.cancel(sent.requestID), true)
        for (const [index, operation] of ['status', 'cancel'].entries()) {
            assert.deepEqual(f.controls[index], { requestID: sent.requestID,
                manualReadPendingProtocol: 1,
                manualReadPendingObservationToken: sent.manualReadPendingObservationToken,
                manualReadPendingOperation: operation, manualReadPendingKind: 'section',
                topWindowURL: 'ebook://original/book', documentStartedAtMs: 123 })
        }
        assert.deepEqual(sent.stableSegmentIDs, ['one'])
        assert.equal(f.coordinator.settle(f.terminal(sent)), true)
        assert.equal((await completion).success, true, 'Cancel does not rewrite a native commit-winning result')
        assert.equal(f.mutations.length, 1)
        assert.equal(f.timers.size, 0)
    })
}

test('root serialization cannot replace the request capability used by status or Close', async t => {
    const f = fixture(t)
    let serializations = 0
    const completion = f.request({ toJSON() {
        serializations++
        return { ...f.message('unmarked'), requestID: 'forged', sectionId: 'other',
            manualReadPendingProtocol: 99, manualReadPendingObservationToken: 'forged' }
    } })
    const sent = f.mutations[0]
    assert.equal(serializations, 1)
    assert.notEqual(sent.requestID, 'forged')
    assert.equal(sent.sectionId, 'section')
    assert.equal(sent.manualReadPendingProtocol, 1)
    assert.match(sent.manualReadPendingObservationToken, /^[0-9a-f]{32}$/)
    f.tick()
    assert.equal(f.coordinator.close(), true)
    assert.equal(f.controls.length, 2)
    assert.deepEqual(f.controls.map(value => value.manualReadPendingOperation), ['status', 'cancel'])
    for (const control of f.controls) {
        assert.equal(control.requestID, sent.requestID)
        assert.equal(control.manualReadPendingObservationToken, sent.manualReadPendingObservationToken)
        assert.equal(control.manualReadPendingHistoryRecovery, undefined)
    }
    await assert.rejects(completion, error => error.code === 'readerClosed' && error.outcomeUnknown === true)
})

for (const boundary of ['status', 'cancel']) {
    test(`${boundary} transport formatting failure retains observation and the original result`, async t => {
        const f = fixture(t), completion = f.request(), sent = f.mutations[0]
        f.hooks.control = () => { throw unreadableError() }
        assert.doesNotThrow(() => boundary === 'status' ? f.tick() : f.coordinator.cancel(sent.requestID))
        assert.equal(f.timers.size, 1)
        assert.equal(f.coordinator.pendingCount, 1)
        f.hooks.control = null
        assert.equal(f.coordinator.settle(f.terminal(sent)), true)
        assert.equal((await completion).success, true)
        assert.equal(f.timers.size, 0)
        assert.equal(f.mutations.length, 1)
    })
}

for (const success of [true, false]) {
    test(`a synchronous native ${success} beats a throwing transport wrapper`, async t => {
        const f = fixture(t)
        f.hooks.post = message => {
            assert.equal(f.coordinator.settle(f.terminal(message, success)), true)
            throw unreadableError()
        }
        let completion
        assert.doesNotThrow(() => { completion = f.request() })
        assert.equal((await completion).success, success)
        assert.equal(f.coordinator.pendingCount, 0)
        assert.equal(f.timers.size, 0)
        assert.equal(f.controls.length, 0)
    })
}

test('an unreadable initial transport failure releases the slot for an explicit retry', async t => {
    const f = fixture(t)
    f.hooks.post = () => { throw unreadableError() }
    let completion
    assert.doesNotThrow(() => { completion = f.request() })
    assert.equal((await completion).errorCode, 'nativePostFailed')
    assert.equal(f.coordinator.pendingCount, 0)
    assert.equal(f.timers.size, 0)
    f.hooks.post = null
    const retry = f.request()
    assert.equal(f.mutations.length, 2)
    assert.notEqual(f.mutations[0].requestID, f.mutations[1].requestID)
    assert.equal(f.coordinator.settle(f.terminal(f.mutations[1])), true)
    assert.equal((await retry).success, true)
})

test('retained hidden terminal recovery keeps original identity after transport mutation and failure', async t => {
    const f = fixture(t), completion = f.request(), sent = f.mutations[0]
    f.coordinator.pause()
    assert.equal(f.coordinator.settle(f.terminal(sent)), true)
    assert.equal((await completion).success, true)
    assert.equal(f.controls.length, 0)
    f.hooks.control = value => {
        value.manualReadPendingObservationToken = 'transport-edited'
        value.topWindowURL = 'ebook://wrong/book'
        throw unreadableError()
    }
    f.coordinator.resume()
    assert.doesNotThrow(f.tick)
    assert.equal(f.timers.size, 1)
    f.hooks.control = null
    f.tick()
    const status = f.controls.at(-1)
    assert.equal(status.manualReadPendingObservationToken, sent.manualReadPendingObservationToken)
    assert.equal(status.topWindowURL, sent.topWindowURL)
    assert.equal(status.manualReadPendingOperation, 'status')
    assert.equal(status.manualReadPendingHistoryRecovery, true)
    const acknowledgement = { ...f.terminal(sent), manualReadPendingHistoryRecovery: true,
        manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false }
    assert.equal(f.coordinator.settle(acknowledgement), true)
    assert.equal(await f.coordinator.recoverHistoryReadingStatus({ requestID: sent.requestID,
        observationToken: sent.manualReadPendingObservationToken }), true)
    assert.equal(f.timers.size, 0)
    assert.equal(f.mutations.length, 1)
})

test('Close cannot turn a departed observation into Cancel', async t => {
    const f = fixture(t), completion = f.request(), sent = f.mutations[0]
    f.coordinator.pause()
    f.coordinator.resume()
    f.tick()
    assert.equal(f.controls.length, 1)
    assert.equal(f.controls[0].manualReadPendingOperation, 'status')
    assert.equal(f.controls[0].manualReadPendingObservationToken, sent.manualReadPendingObservationToken)
    f.coordinator.close()
    assert.equal(f.controls.length, 1)
    await assert.rejects(completion, error => error.code === 'readerClosed')
})

for (const boundary of ['transport', 'diagnostic']) {
    test(`a local post failure during ${boundary} departure cannot create an unrecoverable native barrier`, async t => {
        const f = fixture(t)
        f.hooks.post = () => {
            if (boundary === 'transport') {
                f.coordinator.pause()
                throw new Error('nativePostFailed')
            }
            throw { get message() { f.coordinator.pause(); return 'nativePostFailed' } }
        }
        const outcome = await f.request()
        assert.equal(outcome.success, false)
        assert.equal(outcome.presentationAllowed, false)
        assert.equal(f.coordinator.pendingCount, 0)
        f.coordinator.resume()
        assert.equal(f.timers.size, 0, 'Native cannot acknowledge a command that never reached it')
        assert.equal(outcome.outcomeKnown, true, 'The existing no-enqueue failure is a local known outcome')
        assert.equal(f.controls.length, 0)
        f.hooks.post = null
        const retry = f.request()
        assert.equal(f.mutations.length, 2, 'An explicit retry must not be blocked by a fabricated recovery')
        assert.equal(f.coordinator.settle(f.terminal(f.mutations[1])), true)
        assert.equal((await retry).success, true)
    })
}

for (const success of [true, false]) {
    test(`local post failure cannot replace a received hidden native ${success} or retire its recovery`, async t => {
        const f = fixture(t)
        f.hooks.post = message => {
            f.coordinator.pause()
            assert.equal(f.coordinator.settle(f.terminal(message, success)), true)
            throw unreadableError()
        }
        const outcome = await f.request(), sent = f.mutations[0]
        assert.equal(outcome.outcomeKnown, true)
        assert.equal(outcome.success, success)
        assert.equal(outcome.errorCode, success ? null : 'cancelled')
        f.coordinator.resume()
        f.tick()
        assert.equal(f.controls[0].manualReadPendingHistoryRecovery, true)
        assert.equal(f.controls[0].manualReadPendingObservationToken, sent.manualReadPendingObservationToken)
        const acknowledgement = { ...f.terminal(sent, success), manualReadPendingHistoryRecovery: true,
            manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false }
        assert.equal(f.coordinator.settle(acknowledgement), true)
        assert.equal(await f.coordinator.recoverHistoryReadingStatus({ requestID: sent.requestID,
            observationToken: sent.manualReadPendingObservationToken }), true)
        assert.equal(f.timers.size, 0)
        assert.equal(f.mutations.length, 1)
    })
}


test('a local failure still releases a different recovery waiting for ordinary requests', async t => {
    const f = fixture(t), prepared = []
    f.hooks.recovery = event => prepared.push(event.requestID)
    const original = f.request(f.message('unmarked'), 'original')
    const sent = f.mutations[0]
    f.hooks.post = () => {
        assert.equal(f.coordinator.settle({ ...f.terminal(sent),
            manualReadPendingHistoryRecovery: true, manualReadPendingOutcomeOnly: true,
            manualReadPendingPresentationAllowed: false }), true)
        assert.deepEqual(prepared, [], 'The other ordinary request still owns its turn')
        throw new Error('nativePostFailed')
    }
    const failed = await f.request(f.message('marked'), 'other')
    assert.equal(failed.success, false)
    assert.equal(failed.outcomeKnown, true)
    assert.equal((await original).success, true)
    assert.deepEqual(prepared, [sent.requestID], 'Only the original native recovery is prepared')
    assert.equal(f.coordinator.pendingCount, 0)
    assert.equal(await f.coordinator.recoverHistoryReadingStatus({ requestID: sent.requestID,
        observationToken: sent.manualReadPendingObservationToken }), true)
    assert.equal(f.timers.size, 0)
    assert.equal(f.controls.length, 0)
    assert.equal(f.mutations.length, 2, 'Recovery does not resubmit either mutation')
})
