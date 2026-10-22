import assert from 'node:assert/strict'
import test from 'node:test'
import { createNativeMarkReadRequestCoordinator } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

function fixture(t) {
    const commands = [], controls = [], notices = [], queries = []
    const timers = new Map()
    let serial = 0
    const f = { commands, controls, notices, queries, timers, current: true,
        query: async () => true }
    const coordinator = f.coordinator = createNativeMarkReadRequestCoordinator({
        makeRequestID: () => 'expired-outcome', lifecycleTarget: new EventTarget(),
        postMessage: message => commands.push(message),
        postControlMessage: message => controls.push(message),
        scheduleTimeout: callback => { timers.set(++serial, callback); return serial },
        cancelTimeout: handle => timers.delete(handle),
        onPending: notice => notices.push(notice),
        onRecovery: () => true,
        onRecoveryIsCurrent: () => f.current,
        onRecoveryQuery: proof => { queries.push(proof); return f.query(proof) },
    })
    t.after(() => coordinator.close())
    f.start = (desiredState = 'unmarked') => {
        const completion = coordinator.request({ sectionID: 'original',
            message: { desiredState, topWindowURL: 'ebook://ebook/load/book.epub',
                documentStartedAtMs: 1 } })
        const command = commands.at(-1)
        const proof = { requestID: command.requestID,
            observationToken: command.manualReadPendingObservationToken }
        return { completion, command, proof }
    }
    f.terminal = (command, success) => ({
        requestID: command.requestID, sectionId: command.sectionId,
        manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: command.manualReadPendingObservationToken,
        manualReadPendingState: 'finished', success,
        ...(success ? {} : { errorCode: 'nativeCommitFailed' }),
    })
    // The actual ReaderPendingManualReadRestoredOutcome nil-status contract,
    // including the protocol and token added by the delivery adapter. Native
    // retention/expiry is modeled by this response, not an executed Realm run.
    f.unavailable = command => ({
        requestID: command.requestID, manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: command.manualReadPendingObservationToken,
        manualReadPendingState: 'unavailable', manualReadPendingHistoryRecovery: true,
        manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false,
        errorCode: 'outcomeUnavailable',
    })
    f.finishWhileAway = async (success = true, desiredState = 'unmarked') => {
        const request = f.start(desiredState)
        coordinator.pause()
        assert.equal(coordinator.settle(f.terminal(request.command, success)), true)
        const outcome = await request.completion
        assert.equal(outcome.outcomeKnown, true)
        assert.equal(outcome.success, success)
        coordinator.resume()
        return { ...request, outcome }
    }
    return f
}

for (const desiredState of ['marked', 'unmarked']) {
    for (const success of [true, false]) {
        test(`${desiredState}: expired native retention admits recovery without replacing known ${success}`, async t => {
            const f = fixture(t)
            const { command, proof, completion, outcome } = await f.finishWhileAway(success, desiredState)
            assert.equal(f.coordinator.pendingCount, 0)
            const response = f.unavailable(command)
            // Production native code starts the read-only recovery only after
            // the terminal callback acknowledges its existing local barrier.
            assert.equal(f.coordinator.settle(response), true,
                'Native expiry is lost retention, not a contradictory command outcome')
            assert.equal(await f.coordinator.recoverHistoryReadingStatus(proof), true)
            assert.strictEqual(await completion, outcome, 'The original promise must retain its native result')
            assert.equal(outcome.success, success)
            assert.equal(outcome.outcomeKnown, true)
            assert.equal(outcome.errorCode, success ? null : 'nativeCommitFailed')
            assert.equal(f.queries.length, 1)
            assert.equal(f.commands.length, 1, 'Neither a second Mark nor an Unmark may be sent')
            assert.equal(f.timers.size, 0)
            assert.equal(f.notices.at(-1).phase, 'finished')
            assert.equal(f.notices.at(-1).outcomeKnown, true)
            assert.equal(f.notices.at(-1).success, success)
            assert.equal(f.coordinator.settle(response), false, 'Do not recreate a completed barrier')
        })
    }
}

test('unavailable handoff still rejects malformed, enriched and foreign capabilities', async t => {
    const f = fixture(t)
    const { command, proof, outcome } = await f.finishWhileAway()
    const response = f.unavailable(command)
    for (const change of [
        { manualReadPendingProtocol: 2 },
        { manualReadPendingObservationToken: 'another-token' },
        { requestID: 'another-request' },
        { manualReadPendingHistoryRecovery: false },
        { manualReadPendingOutcomeOnly: false },
        { manualReadPendingPresentationAllowed: true },
        { errorCode: 'cancelled' },
        { manualReadPendingState: 'unknown' },
        { success: false },
        { success: true },
        { stateSnapshotSequence: 100 },
        { recentMarkUndoAvailable: true },
        { displayEffectiveStableSegmentIDs: ['foreign'] },
    ]) assert.equal(f.coordinator.settle({ ...response, ...change }), false)
    assert.equal(f.queries.length, 0)
    assert.equal(outcome.success, true)
    assert.equal(f.coordinator.settle(response), true)
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(proof), true)
})

test('a contradictory known terminal is not disguised as retention expiry', async t => {
    const f = fixture(t)
    const { command, proof, outcome } = await f.finishWhileAway(true)
    const conflicting = { ...f.terminal(command, false),
        manualReadPendingHistoryRecovery: true, manualReadPendingOutcomeOnly: true,
        manualReadPendingPresentationAllowed: false }
    assert.equal(f.coordinator.settle(conflicting), false)
    assert.equal(outcome.success, true)
    assert.equal(f.coordinator.settle(f.unavailable(command)), true)
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(proof), true)
})

test('retired account or chapter cannot use lost retention to obtain recovery', async t => {
    const f = fixture(t)
    const { command, outcome } = await f.finishWhileAway()
    f.current = false
    assert.equal(f.coordinator.settle(f.unavailable(command)), false)
    assert.equal(f.queries.length, 0)
    f.coordinator.retireHistoryRecoveries()
    f.current = true
    assert.equal(f.coordinator.settle(f.unavailable(command)), false)
    assert.equal(outcome.success, true)
    assert.equal(f.commands.length, 1)
})

test('repeated expiry notifications join the original sample and preserve known failure', async t => {
    const f = fixture(t)
    const { command, proof, completion, outcome } = await f.finishWhileAway(false)
    let resolve
    const held = new Promise(done => { resolve = done })
    t.after(() => resolve(false))
    f.query = () => held
    assert.equal(f.coordinator.settle(f.unavailable(command)), true)
    const first = f.coordinator.recoverHistoryReadingStatus(proof)
    assert.equal(f.coordinator.settle(f.unavailable(command)), true)
    const duplicate = f.coordinator.recoverHistoryReadingStatus(proof)
    await new Promise(done => setImmediate(done))
    assert.equal(f.queries.length, 1)
    resolve(true)
    assert.deepEqual(await Promise.all([first, duplicate]), [true, true])
    assert.strictEqual(await completion, outcome)
    assert.equal(outcome.success, false)
    assert.equal(outcome.errorCode, 'nativeCommitFailed')
    assert.equal(f.commands.length, 1)
})

test('failed current-state recovery does not downgrade saved truth or authorize automatic retries', async t => {
    const f = fixture(t)
    const { command, proof, completion, outcome } = await f.finishWhileAway(true)
    f.query = async () => false
    assert.equal(f.coordinator.settle(f.unavailable(command)), true)
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(proof), false)
    assert.equal(f.notices.at(-1).phase, 'recovery-failed')
    assert.equal(f.notices.at(-1).outcomeKnown, true)
    assert.equal(f.notices.at(-1).success, true)
    assert.equal(f.coordinator.settle(f.unavailable(command)), true)
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(proof), false)
    assert.equal(f.queries.length, 1)
    assert.equal(f.timers.size, 0)
    assert.strictEqual(await completion, outcome)
    assert.equal(outcome.success, true)
})

test('an originally unavailable outcome remains unknown after repeated lost-retention acknowledgements', async t => {
    const f = fixture(t)
    const { command, proof, completion } = f.start()
    f.coordinator.pause()
    assert.equal(f.coordinator.settle(f.unavailable(command)), true)
    const outcome = await completion
    f.coordinator.resume()
    assert.equal(f.coordinator.settle(f.unavailable(command)), true)
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(proof), true)
    assert.equal(outcome.outcomeKnown, false)
    assert.equal(outcome.success, undefined)
    assert.equal(outcome.errorCode, 'outcomeUnavailable')
    assert.equal(f.commands.length, 1)
})
