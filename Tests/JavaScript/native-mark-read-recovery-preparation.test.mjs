import assert from 'node:assert/strict'
import test from 'node:test'
import { setImmediate as nextTurn } from 'node:timers/promises'
import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'
import {
    createNativeMarkReadRequestCoordinator,
    presentNativeMarkReadPending,
    refreshNativeMarkReadBookStateForRecovery,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

let namespace = 0
const fixture = (t, hooks = {}) => {
    const messages = [], controls = [], notices = [], queries = [], preparations = [], timers = new Map()
    let timerID = 0
    const coordinator = createNativeMarkReadRequestCoordinator({
        makeRequestID: () => `recovery-preparation-${++namespace}`,
        lifecycleTarget: new EventTarget(),
        postMessage: value => messages.push(value),
        postControlMessage: value => controls.push(value),
        scheduleTimeout: callback => { timers.set(++timerID, callback); return timerID },
        cancelTimeout: id => timers.delete(id),
        onPending: value => { notices.push(value); hooks.notice?.(value) },
        onRecovery: value => { preparations.push(value); return hooks.prepare?.(value) ?? true },
        onRecoveryQuery: proof => { queries.push(proof); return hooks.query?.(proof) ?? true },
        onRecoveryIsCurrent: value => hooks.current?.(value) ?? true,
    })
    t.after(() => coordinator.close())
    const start = (sectionID = 'section') => {
        const previous = messages.length
        const completion = coordinator.request({ sectionID,
            message: { desiredState: 'unmarked', expectedManualSupportRevision: 'original-support',
                topWindowURL: 'ebook://book', documentStartedAtMs: 123 } })
        assert.equal(messages.length, previous + 1)
        const message = messages.at(-1)
        return { completion, message, proof: { requestID: message.requestID,
            observationToken: message.manualReadPendingObservationToken } }
    }
    const finish = (entry, outcome = 'saved') => {
        const envelope = {
            requestID: entry.message.requestID,
            manualReadPendingProtocol: 1,
            manualReadPendingObservationToken: entry.proof.observationToken,
            manualReadPendingHistoryRecovery: true,
            manualReadPendingOutcomeOnly: true,
            manualReadPendingPresentationAllowed: false,
        }
        const result = outcome === 'unavailable'
            ? { ...envelope, manualReadPendingState: 'unavailable', errorCode: 'outcomeUnavailable' }
            : { ...envelope, sectionId: entry.message.sectionId, manualReadPendingState: 'finished',
                success: outcome === 'saved', ...(outcome === 'rejected' ? { errorCode: 'cancelled' } : {}) }
        assert.equal(coordinator.settle(result), true)
        return result
    }
    return { coordinator, start, finish, messages, controls, notices, queries, preparations, timers }
}

for (const failure of ['refusal', 'exception']) {
    for (const outcome of ['saved', 'rejected', 'unavailable']) {
        test(`authorized preparation ${failure} replaces recovering notice without changing ${outcome} outcome`, async t => {
            let calls = 0
            const f = fixture(t, { prepare: () => {
                if (++calls === 1) return true
                if (failure === 'exception') throw new Error('Cannot prepare the current status display')
                return false
            } })
            const entry = f.start()
            const native = f.finish(entry, outcome)
            const committed = await entry.completion
            assert.equal(f.notices.at(-1).phase, 'recovering')
            assert.equal(await f.coordinator.recoverHistoryReadingStatus(entry.proof), false)
            assert.equal(f.queries.length, 0, 'Refused preparation cannot start a native query')
            assert.equal(f.notices.at(-1).phase, 'recovery-failed', 'A completed failed attempt must not look pending')
            assert.equal(f.notices.at(-1).outcomeKnown, outcome !== 'unavailable')
            assert.equal(f.notices.at(-1).success, outcome === 'unavailable' ? undefined : outcome === 'saved')
            assert.equal(committed.nativeResult, native)
            assert.equal(committed.success, outcome === 'unavailable' ? undefined : outcome === 'saved')
            assert.equal(committed.outcomeKnown, outcome !== 'unavailable')
            const count = f.notices.length
            assert.equal(await f.coordinator.recoverHistoryReadingStatus(entry.proof), false)
            assert.equal(calls, 2, 'Duplicate native authorization observes the same failed attempt')
            assert.equal(f.notices.length, count)
            assert.equal(f.messages.length, 1, 'Recovery never repeats Unmark')
            assert.equal(f.controls.length, 0, 'No Cancel or status loop is introduced')
            assert.equal(f.timers.size, 0)
            const blocked = await f.coordinator.request({ sectionID: 'another', message: {} })
            assert.equal(blocked.errorCode, 'pendingCapacityExceeded', 'Failure does not admit actions on stale state')
        })
    }
}

test('initial preparation refusal stays failed without querying or changing saved truth', async t => {
    const f = fixture(t, { prepare: () => false })
    const entry = f.start()
    f.finish(entry)
    assert.equal((await entry.completion).success, true)
    assert.equal(f.notices.at(-1).phase, 'recovery-failed')
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(entry.proof), false)
    assert.equal(f.notices.at(-1).phase, 'recovery-failed')
    assert.equal(f.queries.length, 0)
})

for (const result of ['accepted', 'refused', 'throws']) {
    test(`prepared query still reports ${result} through the existing settlement path`, async t => {
        const f = fixture(t, { query: () => {
            if (result === 'throws') throw new Error('Read failed')
            return result === 'accepted'
        } })
        const entry = f.start()
        f.finish(entry)
        assert.equal((await entry.completion).success, true)
        assert.equal(await f.coordinator.recoverHistoryReadingStatus(entry.proof), result === 'accepted')
        assert.equal(f.notices.at(-1).phase, result === 'accepted' ? 'finished' : 'recovery-failed')
        assert.equal(f.queries.length, 1)
    })
}

test('a no-longer-visible failed preparation removes the old notice instead of reporting into its successor', async t => {
    let visible = true, calls = 0
    const f = fixture(t, { current: () => visible, prepare: () => {
        if (++calls === 1) return true
        visible = false
        return false
    } })
    const entry = f.start()
    f.finish(entry)
    await entry.completion
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(entry.proof), false)
    assert.equal(f.notices.at(-1).phase, 'finished')
    assert.equal(f.queries.length, 0)
    assert.equal(f.coordinator.ownsHistoryReadingStatusRecovery(entry.proof), false)
})

for (const retirement of ['close', 'retireHistoryRecoveries']) {
    test(`preparation ${retirement} cannot resurrect the retired failure notice`, async t => {
        let calls = 0
        const f = fixture(t, { prepare: () => {
            if (++calls === 1) return true
            f.coordinator[retirement]()
            return false
        } })
        const entry = f.start()
        f.finish(entry)
        assert.equal((await entry.completion).success, true)
        assert.equal(await f.coordinator.recoverHistoryReadingStatus(entry.proof), false)
        assert.equal(f.notices.at(-1).phase, 'finished')
        assert.equal(f.notices.some(value => value.phase === 'recovery-failed'), false)
        assert.equal(f.queries.length, 0)
    })
}

test('failure-notice callback errors cannot reopen recovery or replace the native outcome', async t => {
    let calls = 0, failureNotices = 0
    const f = fixture(t, { prepare: () => ++calls === 1, notice: value => {
        if (value.phase === 'recovery-failed') {
            failureNotices++
            throw new Error('Optional notice is unavailable')
        }
    } })
    const entry = f.start()
    f.finish(entry)
    const outcome = await entry.completion
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(entry.proof), false)
    assert.equal(failureNotices, 1)
    assert.equal(outcome.success, true)
    assert.equal(f.queries.length, 0)
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(entry.proof), false)
    assert.equal(failureNotices, 1)
})

test('failed preparation releases its serial turn and a queued sibling can recover', async t => {
    let release
    const held = new Promise(resolve => { release = resolve })
    t.after(() => release(false))
    let refusedID
    const f = fixture(t, {
        prepare: value => value.requestID !== refusedID,
        query: () => f.queries.length === 1 ? held : true,
    })
    const a = f.start('a'), b = f.start('b'), c = f.start('c')
    for (const entry of [a, b, c]) f.finish(entry)
    await Promise.all([a.completion, b.completion, c.completion])
    refusedID = b.message.requestID
    const first = f.coordinator.recoverHistoryReadingStatus(a.proof)
    const second = f.coordinator.recoverHistoryReadingStatus(b.proof)
    const third = f.coordinator.recoverHistoryReadingStatus(c.proof)
    await nextTurn()
    assert.deepEqual(f.queries.map(value => value.requestID), [a.message.requestID])
    release(true)
    assert.deepEqual(await Promise.all([first, second, third]), [true, false, true])
    assert.deepEqual(f.queries.map(value => value.requestID), [a.message.requestID, c.message.requestID])
    assert.equal(f.notices.filter(value => value.requestID === b.message.requestID).at(-1).phase, 'recovery-failed')
    assert.equal(f.messages.length, 3)
    assert.equal(f.controls.length, 0)
})

// Exercise the actual state controller and notice formatter with explicit
// native-message and DOM collaborators. This is not a browser/Realm fixture.
test('Book status transport failure displays recovery guidance despite optional invalidation failure', async t => {
    class Element {
        children = []
        hidden = false
        textContent = ''
        append(...children) {
            for (const child of children) { child.parent = this; this.children.push(child) }
        }
        setAttribute() {}
        addEventListener() {}
        remove() { this.parent.children = this.parent.children.filter(child => child !== this) }
        get firstElementChild() { return this.children[0] }
        get lastElementChild() { return this.children.at(-1) }
    }
    const previous = Object.getOwnPropertyDescriptor(globalThis, 'document')
    const dom = { body: new Element(), createElement: () => new Element() }
    Object.defineProperty(globalThis, 'document', { configurable: true, value: dom })
    const stateRequests = []
    let failInvalidation = false, failRead = false, sequence = 0
    const state = new BookReadingStateController({
        postMessage: value => {
            if (failRead) throw new Error('Native status transport unavailable')
            stateRequests.push(value)
        },
        makeRequestID: () => `state-${++sequence}`,
        documentStartedAtMs: 123, topWindowURL: 'ebook://book',
        onInvalidate: () => { if (failInvalidation) throw new Error('Frame invalidation failed') },
    })
    t.after(() => {
        failInvalidation = false
        state.close()
        if (previous) Object.defineProperty(globalThis, 'document', previous)
        else delete globalThis.document
    })
    state.relocate({ sectionURL: 'chapter' })
    const scope = { articleProgressID: 'book', articleEpochID: 'epoch', chapterKey: 'a'.repeat(64), chapterEpochID: null }
    const f = fixture(t, {
        prepare: value => refreshNativeMarkReadBookStateForRecovery({ state }, scope, value.isCurrent, value.observation),
        query: proof => state.recoverHistoryReadingStatus(proof),
        notice: presentNativeMarkReadPending,
    })
    const entry = f.start()
    f.finish(entry)
    const outcome = await entry.completion
    assert.match(dom.body.firstElementChild.firstElementChild.textContent, /Refreshing reading status/)
    failInvalidation = true
    failRead = true
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(entry.proof), false)
    assert.equal(stateRequests.length, 1, 'Only the initial chapter read was posted')
    assert.equal(f.queries.length, 1, 'Optional invalidation failure does not prevent the authorized native read attempt')
    assert.equal(outcome.success, true, 'A display failure does not undo saved Unmark')
    const notice = dom.body.firstElementChild
    assert.match(notice.firstElementChild.textContent, /The reading change was saved/)
    assert.match(notice.firstElementChild.textContent, /Reading status couldn’t be refreshed\. Close and reopen this book/)
    assert.equal(notice.lastElementChild.hidden, true)
    assert.equal(notice.lastElementChild.disabled, true)
    assert.equal(f.controls.length, 0)
})
