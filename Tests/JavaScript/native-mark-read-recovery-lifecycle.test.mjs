import assert from 'node:assert/strict'
import test from 'node:test'
import {
    createNativeMarkReadRequestCoordinator,
    nativeMarkReadCommandMessage,
    refreshNativeMarkReadBookStateForRecovery,
    refreshCommittedVisibleMarkReadState,
    committedVisibleMarkReadStateIsPresented,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'
import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'

// Complete production modules, including the real producer and UUID imports.
// Native messages, host lifetime changes and timer delivery are controlled seams.
// This is not a browser, native writer or persistent-storage acceptance test.
const chapterURL = 'ebook://book/OPS/chapter.xhtml'
const topWindowURL = 'ebook://ebook/load/local/book.epub'
const scope = Object.freeze({ articleProgressID: 'book', articleEpochID: null,
    chapterKey: 'a'.repeat(64), chapterEpochID: null })
const drain = () => new Promise(resolve => setImmediate(resolve))
const proofFor = message => ({ requestID: message.requestID,
    observationToken: message.manualReadPendingObservationToken })

function sample(revision, readIDs = ['segment']) {
    return { ok: true, accountPresentation: '1:1',
        state: { revision, articleProgressID: 'book', articleEpochID: null, scope,
            finished: false, bookReadPresence: readIDs.length ? 'present' : 'empty',
            chapterReadPresence: readIDs.length ? 'present' : 'empty',
            readSegmentIdentifiers: readIDs, sentenceIdentifiersRead: [] },
        context: { contextID: `context-${revision}`, articleProgressID: 'book',
            articleEpochID: null, scope, sectionLocation: 'OPS/chapter.xhtml', isEndPage: false } }
}

function terminal(message, { success = true, history = false } = {}) {
    return { requestID: message.requestID, sectionId: message.sectionId,
        manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: message.manualReadPendingObservationToken,
        manualReadPendingState: 'finished', success,
        ...(success ? {} : { errorCode: 'cancelled' }),
        ...(history ? { manualReadPendingHistoryRecovery: true,
            manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false } : {}) }
}

function unavailable(message) {
    return { requestID: message.requestID, manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: message.manualReadPendingObservationToken,
        manualReadPendingState: 'unavailable', manualReadPendingHistoryRecovery: true,
        manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false,
        errorCode: 'outcomeUnavailable' }
}

function fixture(t, { initialReadIDs = ['segment'] } = {}) {
    const mutations = [], controls = [], reads = [], notices = [], queries = [], preparations = []
    const timers = new Map(), listeners = new Map(), hooks = {}
    let readID = 0, timerID = 0
    const owner = { current: true, scope }
    const state = new BookReadingStateController({
        postMessage: message => reads.push(message), topWindowURL,
        documentStartedAtMs: 100, requiresAccountPresentation: true,
        makeRequestID: () => `read-${++readID}`,
    })
    state.setAccountPresentation('1:1')
    state.relocate({ sectionURL: chapterURL })
    assert.equal(state.apply(reads[0].requestID, sample(1, initialReadIDs)), true)
    let coordinator
    coordinator = createNativeMarkReadRequestCoordinator({
        makeRequestID: () => 'composition',
        postMessage: message => { mutations.push(message); hooks.post?.(message) },
        postControlMessage: message => { controls.push(message); hooks.control?.(message) },
        isOwnerCurrent: candidate => candidate.current,
        onRecoveryIsCurrent: event => event.owner.current && state.accountPresentation === '1:1',
        onPending: notice => { notices.push(notice); hooks.notice?.(notice) },
        onRecovery: event => {
            preparations.push(event)
            if (hooks.prepare) return hooks.prepare(event)
            return refreshNativeMarkReadBookStateForRecovery(
                { state }, event.owner.scope, event.isCurrent, event.observation)
        },
        onRecoveryQuery: proof => {
            queries.push(proof)
            return state.recoverHistoryReadingStatus(proof)
        },
        scheduleTimeout: (callback, delay) => {
            const id = ++timerID
            timers.set(id, { callback, delay })
            hooks.schedule?.(id)
            return id
        },
        cancelTimeout: id => timers.delete(id),
        lifecycleTarget: {
            addEventListener(name, callback) { listeners.set(name, callback); hooks.register?.(name) },
            removeEventListener(name, callback) {
                if (listeners.get(name) === callback) listeners.delete(name)
            },
        },
    })
    const request = (sectionID = 'section', desiredState = 'unmarked') => coordinator.request({
        sectionID, owner,
        message: nativeMarkReadCommandMessage({ stableIdentityVersion: 1,
            segments: [{ stableSegmentID: 'segment' }], sentenceIdentifiers: [], desiredState },
        { topWindowURL, documentStartedAtMs: 100, bookReadingScope: scope }),
    })
    const nextTimer = () => {
        const entry = timers.entries().next().value
        assert.ok(entry, 'An admitted observation must retain a timer')
        const [id, value] = entry
        timers.delete(id)
        value.callback()
    }
    const publishRecovery = async (message, readIDs = []) => {
        const proof = proofFor(message)
        const completion = coordinator.recoverHistoryReadingStatus(proof)
        await drain()
        const request = reads.at(-1)
        assert.deepEqual(request.historyRecoveryObservation, proof)
        assert.equal(state.apply(request.requestID, {
            ...sample(2, readIDs), historyRecoveryObservation: proof,
            location: { sectionURL: chapterURL, isEndPage: false,
                locationRevision: request.locationRevision },
        }), true)
        return await completion
    }
    t.after(() => { coordinator.close(); state.close() })
    return { coordinator, state, owner, hooks, mutations, controls, reads, notices,
        queries, preparations, timers, listeners, request, nextTimer, publishRecovery }
}

for (const boundary of ['registration', 'timer', 'owner']) {
    test(`retired first-dispatch admission never becomes a recovery command: ${boundary}`, async t => {
        const f = fixture(t)
        if (boundary === 'owner') f.owner.current = false
        else if (boundary === 'registration') {
            f.hooks.register = name => {
                if (name === 'pagehide') { f.coordinator.pause(); f.coordinator.resume() }
            }
        } else {
            f.hooks.schedule = () => { f.hooks.schedule = null; f.coordinator.pause() }
        }
        const completion = f.request()
        assert.equal(f.mutations.length, 0, 'Setup cannot revive the original first handoff')
        const result = await completion
        assert.equal(result.success, false)
        assert.equal(result.outcomeKnown, true)
        assert.equal(result.errorCode, 'requestInvalidatedBeforeSubmission')
        assert.equal(f.coordinator.pendingCount, 0)
        f.coordinator.resume()
        assert.equal(f.controls.length, 0, 'An unsent command needs no native recovery observation')
        assert.equal(f.queries.length, 0)
        assert.equal(f.timers.size, 0)
    })
}

for (const desiredState of ['marked', 'unmarked']) {
    for (const success of [true, false]) {
        test(`hidden ${desiredState === 'marked' ? 'Mark' : 'Unmark'} terminal ${success} resumes one real Book sample`, async t => {
            const initialReadIDs = desiredState === 'marked' ? [] : ['segment']
            const f = fixture(t, { initialReadIDs })
            const completion = f.request('section', desiredState)
            const message = f.mutations[0]
            assert.equal(message.desiredState, desiredState)
            f.coordinator.pause()
            assert.equal(f.coordinator.settle(terminal(message, { success })), true)
            const outcome = await completion
            assert.equal(outcome.success, success)
            assert.equal(outcome.outcomeKnown, true)
            assert.equal(outcome.presentationAllowed, false)
            assert.equal(f.controls.length, 0, 'Do not send the recovery status while hidden')
            assert.equal(f.queries.length, 0, 'Terminal receipt does not admit its own sample')
            assert.equal(f.state.ready, false)
            f.listeners.get('pageshow')?.()
            f.nextTimer()
            assert.equal(f.controls.length, 1)
            assert.equal(f.controls[0].manualReadPendingOperation, 'status')
            assert.equal(f.controls[0].manualReadPendingHistoryRecovery, true)
            assert.equal(f.controls[0].manualReadPendingObservationToken,
                message.manualReadPendingObservationToken)
            // Native admits the sample only after this exact known-outcome
            // acknowledgement, not merely because a timer posted status.
            assert.equal(f.coordinator.settle(terminal(message, { success, history: true })), true)
            const expectedReadIDs = success
                ? (desiredState === 'marked' ? ['segment'] : []) : initialReadIDs
            assert.equal(await f.publishRecovery(message, expectedReadIDs), true)
            assert.equal(f.state.ready, true)
            assert.deepEqual(f.state.state.readSegmentIdentifiers, expectedReadIDs)
            assert.equal(f.queries.length, 1)
            assert.equal(f.mutations.length, 1, 'No replay after either saved or failed terminal')
            assert.equal(f.timers.size, 0, 'Native admission ends the status polling phase')
            f.coordinator.resume()
            assert.equal(f.timers.size, 0)
            assert.equal(f.controls.length, 1)
        })
    }
}

for (const success of [true, false]) {
    test(`expired native retention acknowledges but never changes known terminal ${success}`, async t => {
        const f = fixture(t)
        const completion = f.request()
        const message = f.mutations[0]
        f.coordinator.pause()
        f.coordinator.settle(terminal(message, { success }))
        const outcome = await completion
        f.coordinator.resume()
        assert.equal(f.coordinator.settle(unavailable(message)), true)
        assert.equal(f.queries.length, 0)
        assert.equal(outcome.success, success)
        assert.equal(outcome.outcomeKnown, true)
        assert.equal(await f.publishRecovery(message), true)
        assert.equal(f.queries.length, 1)
        assert.equal(f.mutations.length, 1)
        assert.equal(f.coordinator.settle(unavailable(message)), false,
            'A completed recovery cannot be recreated by another unavailable outcome')
    })
}

for (const mode of ['refused', 'throwing']) {
    test(`authorized ${mode} preparation settles failure after stopping retained polling`, async t => {
        const f = fixture(t)
        const completion = f.request()
        const message = f.mutations[0]
        f.coordinator.pause()
        f.coordinator.settle(terminal(message))
        await completion
        f.coordinator.resume()
        f.hooks.prepare = () => {
            if (mode === 'throwing') throw new Error('Cannot prepare current Book projection')
            return false
        }
        assert.equal(await f.coordinator.recoverHistoryReadingStatus(proofFor(message)), false)
        assert.equal(f.queries.length, 0, 'Unprepared state cannot dispatch a native read')
        assert.equal(f.notices.at(-1).phase, 'recovery-failed')
        assert.equal(f.timers.size, 0)
        f.coordinator.resume()
        assert.equal(f.timers.size, 0, 'Failed native-owned attempt is not an automatic retry')
        assert.equal(f.mutations.length, 1)
    })
}

for (const sameSection of [true, false]) {
    test(`Cancel All cannot absorb a callback-created successor (sameSection=${sameSection})`, async t => {
        const f = fixture(t)
        const originalCompletion = f.request('original')
        const original = f.mutations[0]
        let successorCompletion
        f.hooks.notice = notice => {
            if (notice.requestID !== original.requestID || notice.phase !== 'cancelling') return
            f.hooks.notice = null
            f.coordinator.settle(terminal(original, { success: false }))
            successorCompletion = f.request(sameSection ? 'original' : 'successor')
        }
        f.coordinator.cancelAll()
        assert.equal(f.mutations.length, 2)
        const successor = f.mutations[1]
        assert.notEqual(successor.requestID, original.requestID)
        assert.equal(f.notices.some(notice => notice.requestID === successor.requestID
            && notice.phase === 'cancelling'), false)
        assert.equal(f.controls.some(message => message.requestID === successor.requestID
            && message.manualReadPendingOperation === 'cancel'), false)
        assert.equal(f.coordinator.settle(terminal(successor)), true)
        assert.equal((await originalCompletion).success, false)
        assert.equal((await successorCompletion).success, true)
        assert.equal(f.timers.size, 0)
    })
}

test('newer full publication satisfies a late Mark without stealing a pending chapter read', t => {
    const f = fixture(t)
    f.state.refresh()
    const pending = f.reads.at(-1)
    assert.equal(f.state.apply(null, { ...sample(20), nativeRefresh: true,
        location: { sectionURL: chapterURL, isEndPage: false,
            locationRevision: f.state.locationRevision } }), true)
    const before = f.reads.length
    assert.equal(refreshCommittedVisibleMarkReadState({
        outcome: { success: true, presentationAllowed: true,
            nativeResult: { stateSnapshotSequence: 19 } },
        state: f.state, isOwnerCurrent: () => true,
    }), true)
    assert.equal(f.reads.length, before, 'Reuse ordered full state instead of replacing the pending request')
    assert.equal(committedVisibleMarkReadStateIsPresented({ state: f.state,
        minimumSnapshotSequence: 19, stableSegmentIDs: ['segment'], successfulPublicationSequence: 20 }), true)
    assert.equal(f.state.apply(pending.requestID, sample(21, [])), true)
    assert.deepEqual(f.state.state.readSegmentIdentifiers, [])
})

test('a newer partial Unmark blocks navigation on an older full marked projection', t => {
    const f = fixture(t)
    f.state.refresh()
    assert.equal(f.state.apply(f.reads.at(-1).requestID, sample(20)), true)
    assert.equal(f.state.noteManualReadSnapshot(22), true)
    assert.equal(committedVisibleMarkReadStateIsPresented({ state: f.state,
        minimumSnapshotSequence: 19, stableSegmentIDs: ['segment'], successfulPublicationSequence: 20 }), false)
    assert.equal(refreshCommittedVisibleMarkReadState({
        outcome: { success: true, nativeResult: { stateSnapshotSequence: 19 } },
        state: f.state, isOwnerCurrent: () => true,
    }), false, 'The stale full snapshot cannot lower the partial snapshot watermark')
    f.state.refresh()
    assert.equal(f.state.apply(f.reads.at(-1).requestID, sample(21)), false)
    assert.equal(f.state.apply(f.reads.at(-1).requestID, sample(23, [])), true)
    assert.equal(committedVisibleMarkReadStateIsPresented({ state: f.state,
        minimumSnapshotSequence: 19, stableSegmentIDs: ['segment'], successfulPublicationSequence: 23 }), false)
})

test('account retirement during the admitted Book sample settles only the original recovery', async t => {
    const f = fixture(t)
    const completion = f.request()
    const message = f.mutations[0]
    f.coordinator.pause()
    f.coordinator.settle(terminal(message))
    const outcome = await completion
    f.coordinator.resume()
    const recovery = f.coordinator.recoverHistoryReadingStatus(proofFor(message))
    await drain()
    const oldRead = f.reads.at(-1)
    assert.deepEqual(oldRead.historyRecoveryObservation, proofFor(message))
    assert.equal(f.state.setAccountPresentation('2:1'), true)
    assert.equal(await recovery, false)
    assert.equal(f.state.ready, false)
    assert.equal(f.state.apply(oldRead.requestID, sample(2)), false)
    assert.equal(outcome.success, true, 'Retiring presentation does not rewrite saved native truth')
    assert.equal(f.mutations.length, 1)
    assert.equal(f.queries.length, 1)
})

test('unavailable packets with foreign tokens or success fields cannot admit recovery', async t => {
    const f = fixture(t)
    const completion = f.request()
    const message = f.mutations[0]
    f.coordinator.pause()
    f.coordinator.settle(terminal(message))
    await completion
    assert.equal(f.coordinator.settle({ ...unavailable(message),
        manualReadPendingObservationToken: 'foreign' }), false)
    assert.equal(f.coordinator.settle({ ...unavailable(message), success: false }), false)
    assert.equal(f.queries.length, 0)
    assert.equal(f.mutations.length, 1)
})
