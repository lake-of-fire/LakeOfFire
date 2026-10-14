import assert from 'node:assert/strict'
import test from 'node:test'
import { setImmediate as nextTurn } from 'node:timers/promises'
import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'
import { createNativeMarkReadRequestCoordinator, refreshNativeMarkReadBookStateForRecovery } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

const deferred = () => {
    let resolve
    const promise = new Promise(done => { resolve = done })
    return { promise, resolve }
}
const proofFor = request => ({ requestID: request.requestID,
    observationToken: request.manualReadPendingObservationToken })
const terminalFor = (request, history = false) => ({
    requestID: request.requestID, sectionId: request.sectionId,
    manualReadPendingProtocol: 1,
    manualReadPendingObservationToken: request.manualReadPendingObservationToken,
    manualReadPendingState: 'finished', success: true,
    ...(history ? { manualReadPendingHistoryRecovery: true,
        manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false } : {}),
})
function fixture(t, options = {}) {
    const posted = [], controls = [], notices = [], queries = [], timers = new Map()
    let serial = 0
    const coordinator = createNativeMarkReadRequestCoordinator({
        makeRequestID: () => 'queue-test', lifecycleTarget: new EventTarget(),
        postMessage: value => posted.push(value),
        postControlMessage: value => controls.push(value),
        scheduleTimeout: callback => { timers.set(++serial, callback); return serial },
        cancelTimeout: id => timers.delete(id),
        onPending: value => notices.push(value),
        onRecovery: value => options.prepare?.(value) ?? true,
        onRecoveryQuery: proof => { queries.push(proof.requestID); return options.query?.(proof) ?? true },
        onRecoveryIsCurrent: value => options.current?.(value) ?? true,
    })
    t.after(() => coordinator.close())
    const request = (sectionID, { desiredState = 'unmarked', owner = null } = {}) => {
        const count = posted.length
        const completion = coordinator.request({ sectionID, owner, message: { desiredState } })
        assert.equal(posted.length, count + 1, 'fixture request must actually reach native handoff')
        return { completion, message: posted.at(-1), proof: proofFor(posted.at(-1)) }
    }
    return { coordinator, posted, controls, notices, queries, timers, request }
}

test('retired queued recovery cannot wait on a newer ordinary request or block later recovery', async t => {
    const held = deferred(), entered = deferred()
    t.after(() => held.resolve(false))
    const f = fixture(t, { query: () => {
        if (f.queries.length === 1) { entered.resolve(); return held.promise }
        return true
    } })
    const a = f.request('a'), b = f.request('b')
    f.coordinator.settle(terminalFor(a.message, true))
    f.coordinator.settle(terminalFor(b.message, true))
    assert.equal((await a.completion).success, true)
    assert.equal((await b.completion).success, true)
    const active = f.coordinator.recoverHistoryReadingStatus(a.proof)
    await entered.promise
    let queuedResult = 'pending'
    f.coordinator.recoverHistoryReadingStatus(b.proof).then(value => { queuedResult = value })
    f.coordinator.retireHistoryRecoveries()
    const c = f.request('c')
    assert.equal(f.coordinator.pendingCount, 1)
    held.resolve(false)
    assert.equal(await active, false)
    await nextTurn()
    const beforeOrdinaryCompletion = queuedResult
    f.coordinator.settle(terminalFor(c.message))
    assert.equal((await c.completion).success, true)
    const d = f.request('d')
    f.coordinator.settle(terminalFor(d.message, true))
    assert.equal((await d.completion).success, true)
    let laterResult = 'pending'
    f.coordinator.recoverHistoryReadingStatus(d.proof).then(value => { laterResult = value })
    await nextTurn()
    assert.deepEqual({ beforeOrdinaryCompletion, queuedResult, laterResult }, {
        beforeOrdinaryCompletion: false, queuedResult: false, laterResult: true,
    })
    assert.deepEqual(f.queries, [a.message.requestID, d.message.requestID])
    assert.equal(f.posted.length, 4, 'status recovery never replays a mutation')
    assert.equal(f.controls.length, 0, 'retirement never sends Cancel')
    assert.equal(f.timers.size, 0)
})

// A task turn drains the real Promise chain. It is not a production timeout,
// a fake recovery result, or permission to release an unresolved native writer.
for (const desiredState of ['marked', 'unmarked']) {
    for (const retirement of ['explicit', 'request-pruning']) {
        test(`${retirement} retirement before the first queue turn preserves a newer ${desiredState} command`, async t => {
            let current = true
            const f = fixture(t, { current: () => current })
            const a = f.request('old')
            f.coordinator.settle(terminalFor(a.message, true))
            assert.equal((await a.completion).success, true)
            let result = 'pending'
            f.coordinator.recoverHistoryReadingStatus(a.proof).then(value => { result = value })
            if (retirement === 'explicit') f.coordinator.retireHistoryRecoveries()
            else current = false // request() prunes this old recovery before admitting the new command.
            const b = f.request('current', { desiredState })
            current = true
            await nextTurn()
            assert.equal(result, false, 'retired recovery settles while the new writer is still pending')
            assert.equal(f.coordinator.pendingCount, 1)
            assert.equal(f.coordinator.hasOrdinaryPendingRequests, true)
            assert.equal(f.queries.length, 0)
            assert.equal(f.controls.length, 0)
            assert.equal(f.timers.size, 1)
            assert.equal(f.coordinator.ownsHistoryReadingStatusRecovery(a.proof), false)
            f.coordinator.settle(terminalFor(b.message))
            const outcome = await b.completion
            assert.equal(outcome.success, true)
            assert.equal(outcome.presentationAllowed, true)
            assert.equal(f.timers.size, 0)
            assert.equal(await f.coordinator.recoverHistoryReadingStatus(a.proof), false)
        })
    }
}

for (const retiredQueryResult of [true, false]) {
    test(`pruning queued recoveries ignores late ${retiredQueryResult} and keeps a fresh recovery usable`, async t => {
        const held = deferred(), entered = deferred()
        t.after(() => held.resolve(false))
        let current = true
        const f = fixture(t, { current: () => current,
            query: () => {
                if (f.queries.length === 1) { entered.resolve(); return held.promise }
                return true
            } })
        const requests = Array.from({ length: 4 }, (_, index) => f.request(`old-${index}`))
        for (const entry of requests) f.coordinator.settle(terminalFor(entry.message, true))
        assert.ok((await Promise.all(requests.map(entry => entry.completion))).every(value => value.success))
        const active = f.coordinator.recoverHistoryReadingStatus(requests[0].proof)
        await entered.promise
        const values = new Array(3).fill('pending')
        requests.slice(1).forEach((entry, index) => {
            f.coordinator.recoverHistoryReadingStatus(entry.proof).then(value => { values[index] = value })
        })
        current = false
        const ordinary = f.request('new')
        current = true
        held.resolve(retiredQueryResult)
        assert.equal(await active, false)
        await nextTurn()
        assert.deepEqual(values, [false, false, false])
        assert.equal(f.queries.length, 1)
        assert.equal(f.coordinator.pendingCount, 1)
        f.coordinator.settle(terminalFor(ordinary.message, true))
        assert.equal((await ordinary.completion).success, true)
        assert.equal(await f.coordinator.recoverHistoryReadingStatus(ordinary.proof), true)
        assert.deepEqual(f.queries, [requests[0].message.requestID, ordinary.message.requestID])
        assert.equal(f.controls.length, 0)
        assert.equal(f.posted.length, 5)
    })
}

for (const success of [true, false]) {
    test(`a live recovery still waits for its concurrent ordinary command, success=${success}`, async t => {
        const f = fixture(t)
        const old = f.request('old'), ordinary = f.request('ordinary')
        f.coordinator.settle(terminalFor(old.message, true))
        assert.equal((await old.completion).success, true)
        let result = 'pending'
        const recovery = f.coordinator.recoverHistoryReadingStatus(old.proof)
        recovery.then(value => { result = value })
        await nextTurn()
        assert.equal(result, 'pending')
        assert.equal(f.queries.length, 0)
        assert.equal(f.coordinator.pendingCount, 1)
        const native = { ...terminalFor(ordinary.message), success,
            ...(success ? {} : { errorCode: 'cancelled' }) }
        f.coordinator.settle(native)
        const outcome = await ordinary.completion
        assert.equal(outcome.success, success)
        assert.equal(outcome.nativeResult, native)
        assert.equal(outcome.presentationAllowed, false)
        assert.equal(await recovery, true)
        assert.deepEqual(f.queries, [old.message.requestID])
        assert.equal(f.controls.length, 0)
    })
}

test('live queries remain serial and duplicate observations join their exact original sample', async t => {
    const held = deferred(), entered = deferred()
    t.after(() => held.resolve(false))
    const f = fixture(t, { query: () => {
        if (f.queries.length === 1) { entered.resolve(); return held.promise }
        return true
    } })
    const a = f.request('a'), b = f.request('b')
    f.coordinator.settle(terminalFor(a.message, true))
    f.coordinator.settle(terminalFor(b.message, true))
    await Promise.all([a.completion, b.completion])
    const first = f.coordinator.recoverHistoryReadingStatus(a.proof)
    await entered.promise
    const duplicate = f.coordinator.recoverHistoryReadingStatus(a.proof)
    const second = f.coordinator.recoverHistoryReadingStatus(b.proof)
    await nextTurn()
    assert.deepEqual(f.queries, [a.message.requestID])
    const denied = await f.coordinator.request({ sectionID: 'new', message: {} })
    assert.equal(denied.errorCode, 'pendingCapacityExceeded')
    assert.equal(f.posted.length, 2)
    held.resolve(true)
    assert.deepEqual(await Promise.all([first, duplicate, second]), [true, true, true])
    assert.deepEqual(f.queries, [a.message.requestID, b.message.requestID])
    assert.equal(f.coordinator.ownsHistoryReadingStatusRecovery(b.proof), true)
})

test('retirement of an already waiting recovery still releases its existing join', async t => {
    const f = fixture(t)
    const a = f.request('a'), b = f.request('b')
    f.coordinator.settle(terminalFor(a.message, true))
    await a.completion
    let result = 'pending'
    f.coordinator.recoverHistoryReadingStatus(a.proof).then(value => { result = value })
    await nextTurn()
    assert.equal(result, 'pending')
    f.coordinator.retireHistoryRecoveries()
    await nextTurn()
    assert.equal(result, false)
    assert.equal(f.coordinator.pendingCount, 1)
    assert.equal(f.queries.length, 0)
    f.coordinator.settle(terminalFor(b.message))
    assert.equal((await b.completion).success, true)
    const c = f.request('c')
    f.coordinator.settle(terminalFor(c.message, true))
    await c.completion
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(c.proof), true)
})

test('close while queued preserves joined outcomes and cannot start another native query', async t => {
    const held = deferred(), entered = deferred()
    t.after(() => held.resolve(false))
    const f = fixture(t, { query: () => { entered.resolve(); return held.promise } })
    const a = f.request('a'), b = f.request('b')
    f.coordinator.settle(terminalFor(a.message, true))
    f.coordinator.settle(terminalFor(b.message, true))
    const outcomes = await Promise.all([a.completion, b.completion])
    const first = f.coordinator.recoverHistoryReadingStatus(a.proof)
    await entered.promise
    const second = f.coordinator.recoverHistoryReadingStatus(b.proof)
    assert.equal(f.coordinator.close(), true)
    held.resolve(true)
    assert.deepEqual(await Promise.all([first, second]), [false, false])
    assert.ok(outcomes.every(value => value.success && value.outcomeKnown))
    assert.equal(f.queries.length, 1)
    assert.equal(f.controls.length, 0)
    assert.equal(f.timers.size, 0)
})

test('Book relocation retires a real in-flight status query without stranding its queued successor', async t => {
    const messages = []
    let sequence = 0, chapter = 'a'
    const state = new BookReadingStateController({
        postMessage: value => messages.push(value), documentStartedAtMs: 42,
        topWindowURL: 'ebook://book/viewer', makeRequestID: () => `book-${++sequence}`,
    })
    t.after(() => state.close())
    const scope = () => ({ articleProgressID: 'book', articleEpochID: 'E1',
        chapterKey: chapter.repeat(64), chapterEpochID: null })
    const response = revision => ({ ok: true, accountPresentation: '1:1',
        location: { ...state.location, locationRevision: state.locationRevision },
        state: { revision, articleProgressID: 'book', articleEpochID: 'E1', scope: scope(),
            finished: false, bookReadPresence: 'present', chapterReadPresence: 'present',
            readSegmentIdentifiers: [`segment-${chapter}`], sentenceIdentifiersRead: [] },
        context: { contextID: `context-${revision}`, articleProgressID: 'book', articleEpochID: 'E1',
            scope: scope(), sectionLocation: `${chapter}.xhtml`, isEndPage: false },
    })
    state.relocate({ sectionURL: 'a.xhtml' })
    assert.equal(state.apply(messages.at(-1).requestID, response(1)), true)
    const f = fixture(t, {
        prepare: ({ isCurrent, observation }) => refreshNativeMarkReadBookStateForRecovery(
            { state }, scope(), isCurrent, observation),
        query: proof => state.recoverHistoryReadingStatus(proof),
    })
    const a = f.request('old-a'), b = f.request('old-b')
    f.coordinator.settle(terminalFor(a.message, true))
    f.coordinator.settle(terminalFor(b.message, true))
    await Promise.all([a.completion, b.completion])
    const active = f.coordinator.recoverHistoryReadingStatus(a.proof)
    await nextTurn()
    assert.equal(messages.length, 2)
    const oldQuery = messages.at(-1)
    assert.deepEqual(oldQuery.historyRecoveryObservation, a.proof)
    let queued = 'pending'
    f.coordinator.recoverHistoryReadingStatus(b.proof).then(value => { queued = value })
    chapter = 'b'
    // Real Book retirement resolves its query, not a fabricated completion.
    // The viewer's separate coordinator-retirement call follows in this turn.
    state.relocate({ sectionURL: 'b.xhtml' })
    f.coordinator.retireHistoryRecoveries()
    assert.equal(state.apply(messages.at(-1).requestID, response(2)), true)
    const c = f.request('chapter-b')
    assert.equal(await active, false)
    await nextTurn()
    assert.equal(queued, false)
    assert.equal(state.ready, true)
    assert.equal(state.captureScope('b.xhtml').chapterKey, 'b'.repeat(64))
    assert.equal(state.apply(oldQuery.requestID, { ...response(1),
        historyRecoveryObservation: a.proof }), false)
    f.coordinator.settle(terminalFor(c.message, true))
    assert.equal((await c.completion).success, true)
    let recovered = 'pending'
    f.coordinator.recoverHistoryReadingStatus(c.proof).then(value => { recovered = value })
    await nextTurn()
    const currentQuery = messages.at(-1)
    assert.deepEqual(currentQuery.historyRecoveryObservation, c.proof)
    assert.equal(state.apply(currentQuery.requestID, { ...response(3),
        historyRecoveryObservation: c.proof }), true)
    await nextTurn()
    assert.equal(recovered, true)
    assert.equal(state.ready, true)
    assert.deepEqual(state.state.readSegmentIdentifiers, ['segment-b'])
    assert.equal(f.posted.length, 3)
    assert.equal(f.controls.length, 0)
    assert.deepEqual(f.queries, [a.message.requestID, c.message.requestID])
})
