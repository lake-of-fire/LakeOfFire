import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
    createNativeMarkReadRequestCoordinator,
    refreshNativeMarkReadBookStateForRecovery,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'
import {
    BookReadingStateController, bookScopeKey,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'

const topURL = 'ebook://ebook/load/local/book.epub'
const chapterURL = chapter => `https://reader.invalid/${chapter}.xhtml`
const chapterScope = chapter => ({ articleProgressID: 'article', articleEpochID: 'pass',
    chapterKey: (chapter === 'a' ? 'a' : 'b').repeat(64), chapterEpochID: null })
const flush = async () => {
    for (let i = 0; i < 12; i += 1) await Promise.resolve()
}

// Complete production coordinator, Book state controller and recovery adapter.
// Native replies, timers and the Reader's location/notice callbacks are explicit
// collaborators. The onInvalidate -> cancelAll connection mirrors Reader.open;
// this fixture does not execute the full Viewer, WebKit, or native writer.
function fixture(t) {
    const commands = [], controls = [], stateRequests = [], notices = [], queries = []
    const visibleNotices = new Map(), timers = new Map(), listeners = new Map()
    const events = new EventTarget()
    let coordinator, timerID = 0, stateRequestID = 0
    const f = { visible: true, chapter: 'a', onNotice: () => {}, query: null,
        commands, controls, stateRequests, notices, queries, visibleNotices, timers, listeners }
    const state = f.state = new BookReadingStateController({
        documentStartedAtMs: 100, topWindowURL: topURL,
        makeRequestID: () => `state-${++stateRequestID}`,
        requiresAccountPresentation: true,
        postMessage: request => stateRequests.push(request),
        onInvalidate: () => coordinator?.cancelAll(),
    })
    const runtime = { state }
    const current = ({ owner, context, message }) => context.runtime === runtime
        && owner.current && context.account === state.accountPresentation
        && message.pageURL === state.location?.sectionURL
        && (context.recoveryLocation === undefined || context.recoveryLocation === state.locationRevision)
        && (!state.context || bookScopeKey(state.context.scope) === bookScopeKey(owner.scope))
    coordinator = f.coordinator = createNativeMarkReadRequestCoordinator({
        makeRequestID: () => 'retired-recovery',
        lifecycleTarget: {
            addEventListener(name, callback) {
                if (!listeners.has(name)) listeners.set(name, new Set())
                listeners.get(name).add(callback)
                events.addEventListener(name, callback)
            },
            removeEventListener(name, callback) {
                listeners.get(name)?.delete(callback)
                events.removeEventListener(name, callback)
            },
        },
        postMessage: command => commands.push(command),
        postControlMessage: control => controls.push(control),
        isOwnerCurrent: owner => f.visible && owner.current,
        scheduleTimeout: (callback, delay) => {
            timers.set(++timerID, { callback, delay })
            return timerID
        },
        cancelTimeout: id => timers.delete(id),
        onPending: notice => {
            notices.push(notice)
            if (notice.phase === 'finished') visibleNotices.delete(notice.requestID)
            else visibleNotices.set(notice.requestID, notice)
            f.onNotice(notice)
        },
        onRecoveryIsCurrent: current,
        onRecovery: args => {
            if (!current(args)) return false
            args.context.recoveryLocation ??= state.locationRevision
            return refreshNativeMarkReadBookStateForRecovery(runtime, args.owner.scope,
                () => args.isCurrent() && current(args), args.observation)
        },
        onRecoveryQuery: proof => {
            queries.push(proof)
            return f.query ? f.query(proof) : state.recoverHistoryReadingStatus(proof)
        },
    })
    f.response = (request = stateRequests.at(-1), revision = 1) => ({
        ok: true, accountPresentation: state.accountPresentation,
        state: { revision, articleProgressID: 'article', articleEpochID: 'pass',
            scope: chapterScope(f.chapter), finished: false,
            bookReadPresence: 'present', chapterReadPresence: 'present',
            readSegmentIdentifiers: ['segment'], sentenceIdentifiersRead: [] },
        context: { contextID: `context-${request.requestID}`, articleProgressID: 'article',
            articleEpochID: 'pass', scope: chapterScope(f.chapter),
            isEndPage: false, sectionLocation: request.sectionURL },
        ...(request.historyRecoveryObservation ? {
            historyRecoveryObservation: request.historyRecoveryObservation,
            location: { sectionURL: request.sectionURL, isEndPage: false,
                locationRevision: request.locationRevision },
        } : {}),
    })
    f.accept = (request = stateRequests.at(-1), revision = 1) =>
        state.apply(request.requestID, f.response(request, revision))
    state.setAccountPresentation('1:1')
    state.relocate({ sectionURL: chapterURL('a') })
    assert.equal(f.accept(), true)
    f.start = (desiredState = 'unmarked') => {
        const owner = { current: true, scope: chapterScope(f.chapter) }
        const context = { runtime, account: state.accountPresentation }
        const completion = coordinator.request({
            sectionID: `${f.chapter}-${commands.length}`, owner, context,
            message: { desiredState, stableSegmentIDs: ['segment'], sentenceIdentifiers: [],
                topWindowURL: topURL, pageURL: chapterURL(f.chapter), documentStartedAtMs: 100,
                bookReadingScope: owner.scope },
        })
        return { completion, command: commands.at(-1), owner, context }
    }
    f.proof = command => ({ requestID: command.requestID,
        observationToken: command.manualReadPendingObservationToken })
    f.result = (command, success = true, history = false) => ({
        requestID: command.requestID, sectionId: command.sectionId,
        manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: command.manualReadPendingObservationToken,
        manualReadPendingState: 'finished', success,
        errorCode: success ? '' : 'nativeCommitFailed',
        ...(history ? { manualReadPendingHistoryRecovery: true,
            manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false } : {}),
    })
    f.hide = () => {
        f.visible = false
        events.dispatchEvent(new Event('pagehide'))
    }
    f.show = () => {
        f.visible = true
        events.dispatchEvent(new Event('pageshow'))
    }
    f.fireTimers = () => {
        for (const [id, timer] of [...timers]) if (timers.delete(id)) timer.callback()
    }
    f.move = chapter => {
        f.chapter = chapter
        return state.relocate({ sectionURL: chapterURL(chapter) }, { moved: true })
    }
    f.finishHidden = async (success = true) => {
        const request = f.start()
        f.hide()
        assert.equal(coordinator.settle(f.result(request.command, success)), true)
        const outcome = await request.completion
        assert.equal(outcome.success, success)
        assert.equal(outcome.outcomeKnown, true)
        assert.equal(coordinator.pendingCount, 0)
        assert.equal(state.ready, false, 'Recovery withdrew old Book context')
        assert.equal(visibleNotices.get(request.command.requestID)?.phase, 'recovering')
        return { ...request, outcome }
    }
    t.after(() => { f.onNotice = () => {}; coordinator.close(); state.close() })
    return f
}

for (const success of [true, false]) {
    test(`chapter departure removes completed Unmark notice without replacing outcome ${success}`, async t => {
        const f = fixture(t)
        const r = await f.finishHidden(success)
        f.show()
        const controls = f.controls.length
        assert.equal(f.move('b'), true)
        assert.equal(f.visibleNotices.has(r.command.requestID), false,
            'Reader invalidation must retire the completed recovery notice immediately')
        assert.equal(f.timers.size, 0)
        assert.equal(f.listeners.get('pageshow')?.size ?? 0, 0)
        assert.equal(f.controls.length, controls, 'No Cancel or status is sent for the completed write')
        assert.equal(await r.completion, r.outcome)
        assert.equal(f.commands.length, 1)
        assert.equal(f.accept(undefined, 2), true, 'The new chapter keeps its own pending native read')
        assert.equal(await f.coordinator.recoverHistoryReadingStatus(f.proof(r.command)), false)
        assert.equal(f.queries.length, 0)
    })
}

test('the status observation retires a same-chapter move without another invalidation callback', async t => {
    const f = fixture(t)
    const r = await f.finishHidden()
    f.show()
    // A page move changes the revision without clearing the same-chapter cache.
    assert.equal(f.state.relocate({ sectionURL: chapterURL('a') }, { moved: true }), true)
    const controls = f.controls.length
    f.fireTimers()
    assert.equal(f.visibleNotices.has(r.command.requestID), false)
    assert.equal(f.timers.size, 0)
    assert.equal(f.listeners.get('pageshow')?.size ?? 0, 0)
    assert.equal(f.controls.length, controls)
    assert.equal(f.commands.length, 1)
    assert.equal(await r.completion, r.outcome)
})

test('settled account replacement withdraws the old recovery but not native command truth', async t => {
    const f = fixture(t)
    const r = await f.finishHidden(false)
    f.show()
    assert.equal(f.state.setAccountPresentation('2:1'), true)
    assert.equal(f.visibleNotices.has(r.command.requestID), false)
    assert.equal(f.timers.size, 0)
    assert.equal(await r.completion, r.outcome)
    assert.equal(r.outcome.errorCode, 'nativeCommitFailed')
    assert.equal(f.coordinator.cancel(r.command.requestID), false)
})

test('departing a failed recovery removes its failure notice without retrying its read', async t => {
    const f = fixture(t)
    const r = await f.finishHidden()
    f.show()
    f.query = async () => false
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(f.proof(r.command)), false)
    assert.equal(f.visibleNotices.get(r.command.requestID)?.phase, 'recovery-failed')
    f.move('b')
    assert.equal(f.visibleNotices.has(r.command.requestID), false)
    f.fireTimers()
    assert.equal(f.queries.length, 1)
    assert.equal(f.commands.length, 1)
})

test('departure releases an active coordinator wait even when its obsolete query never answers', async t => {
    const f = fixture(t)
    const r = await f.finishHidden()
    f.show()
    let release
    f.query = () => new Promise(resolve => { release = resolve })
    const recovery = f.coordinator.recoverHistoryReadingStatus(f.proof(r.command))
    let settlement = 'pending'
    recovery.then(value => { settlement = value })
    await flush()
    assert.equal(f.queries.length, 1)
    f.move('b')
    await flush()
    // Always release the controlled query after taking the observation, even
    // on the negative control. The assertion is not a test-runner timeout.
    const beforeLateReply = settlement
    release(true)
    await recovery
    assert.equal(beforeLateReply, false, 'Retired presentation callers must not wait for an obsolete transport')
    assert.equal(f.visibleNotices.has(r.command.requestID), false)
    assert.equal(await r.completion, r.outcome)
})

test('ordinary recovery invalidation keeps the same null-context recovery alive', async t => {
    const f = fixture(t)
    const r = await f.finishHidden()
    f.show()
    f.coordinator.cancelAll()
    assert.equal(f.visibleNotices.get(r.command.requestID)?.phase, 'recovering')
    assert.equal(f.coordinator.settle(f.result(r.command, true, true)), true)
    const recovery = f.coordinator.recoverHistoryReadingStatus(f.proof(r.command))
    await flush()
    assert.equal(f.queries.length, 1)
    assert.equal(f.accept(undefined, 2), true)
    assert.equal(await recovery, true)
    assert.equal(f.visibleNotices.has(r.command.requestID), false)
    assert.equal(f.state.ready, true)
    assert.equal(f.commands.length, 1)
})

test('a still-current failed recovery is retained and never automatically retried', async t => {
    const f = fixture(t)
    const r = await f.finishHidden()
    f.show()
    f.query = async () => false
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(f.proof(r.command)), false)
    f.coordinator.cancelAll()
    f.hide()
    f.show()
    f.fireTimers()
    assert.equal(f.visibleNotices.get(r.command.requestID)?.phase, 'recovery-failed')
    assert.equal(f.queries.length, 1)
    assert.equal(f.timers.size, 0)
})

test('ordinary pending commands retain their cancellation and native settlement path', async t => {
    const f = fixture(t)
    const r = f.start()
    f.coordinator.cancelAll()
    assert.equal(f.coordinator.pendingCount, 1)
    assert.equal(f.controls.at(-1).manualReadPendingOperation, 'cancel')
    assert.equal(f.controls.at(-1).requestID, r.command.requestID)
    assert.equal(f.coordinator.settle(f.result(r.command, false)), true)
    assert.equal((await r.completion).success, false)
    assert.equal(f.coordinator.pendingCount, 0)
    assert.equal(f.queries.length, 0)
})

test('notice cleanup cannot retire a successor recovery created by its callback', async t => {
    const f = fixture(t)
    const original = await f.finishHidden()
    f.show()
    let successor
    f.onNotice = notice => {
        if (notice.requestID !== original.command.requestID || notice.phase !== 'finished') return
        f.onNotice = () => {}
        assert.equal(f.state.refresh(), true)
        assert.equal(f.accept(undefined, 2), true)
        successor = f.start('marked')
        f.hide()
        assert.equal(f.coordinator.settle(f.result(successor.command)), true)
    }
    f.move('b')
    assert.ok(successor, 'The outgoing recovery must finish its original notice')
    assert.equal(f.visibleNotices.has(original.command.requestID), false)
    assert.equal(f.visibleNotices.get(successor.command.requestID)?.phase, 'recovering')
    f.show()
    f.fireTimers()
    assert.equal(f.controls.at(-1).requestID, successor.command.requestID)
    assert.equal(f.commands.length, 2, 'Only the two explicit fixture commands were submitted')
    assert.equal((await successor.completion).success, true)
})

test('a successor native sample does not wait for the retired query or adopt its late result', async t => {
    const f = fixture(t)
    const original = await f.finishHidden()
    f.show()
    let releaseOriginal
    f.query = proof => proof.requestID === original.command.requestID
        ? new Promise(resolve => { releaseOriginal = resolve })
        : f.state.recoverHistoryReadingStatus(proof)
    const oldRead = f.coordinator.recoverHistoryReadingStatus(f.proof(original.command))
    await flush()
    f.move('b')
    assert.equal(f.accept(undefined, 2), true)
    const successor = f.start('marked')
    f.hide()
    f.coordinator.settle(f.result(successor.command))
    assert.equal((await successor.completion).success, true)
    f.show()
    const newRead = f.coordinator.recoverHistoryReadingStatus(f.proof(successor.command))
    await flush()
    const beforeOldReply = f.queries.length
    // Capture the decisive observation before releasing the obsolete query;
    // then always release it so a failing negative control cannot hang Node.
    releaseOriginal(true)
    await oldRead
    await flush()
    assert.equal(beforeOldReply, 2, 'The successor must reach native without the obsolete read returning')
    assert.equal(f.accept(undefined, 3), true)
    assert.equal(await newRead, true)
    assert.equal(f.state.captureContext().sectionLocation, chapterURL('b'))
    assert.equal(f.visibleNotices.size, 0)
    assert.equal(await original.completion, original.outcome)
    assert.equal(f.commands.length, 2)
})

test('returning to equal chapter values cannot revive a retired failed-recovery notice', async t => {
    const f = fixture(t)
    const original = await f.finishHidden(false)
    f.show()
    f.query = async () => false
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(f.proof(original.command)), false)
    f.move('b')
    f.accept(undefined, 2)
    f.move('a')
    f.accept(undefined, 3)
    assert.equal(f.visibleNotices.has(original.command.requestID), false)
    assert.equal(f.coordinator.ownsHistoryReadingStatusRecovery(f.proof(original.command)), false)
    assert.equal(f.coordinator.settle(f.result(original.command, false, true)), false)
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(f.proof(original.command)), false)
    assert.equal(f.queries.length, 1)
    assert.equal(f.state.ready, true)
    assert.equal(f.state.captureContext().sectionLocation, chapterURL('a'))
    assert.equal(await original.completion, original.outcome)
})

// Same-chapter movement keeps an ordinary projection, but cannot retain a
// History failure/refresh owned by the previous physical location. The native
// reply for the replacement location is deliberately held in these schedules.
async function rejectRecoveryQuery(f, r) {
    const completion = f.coordinator.recoverHistoryReadingStatus(f.proof(r.command))
    await flush()
    const request = f.stateRequests.at(-1)
    assert.deepEqual(request.historyRecoveryObservation, f.proof(r.command))
    assert.equal(f.state.apply(request.requestID, {
        ...f.response(request, 2), ok: false, error: 'native read failed',
    }), false)
    assert.equal(await completion, false)
    assert.equal(f.visibleNotices.get(r.command.requestID)?.phase, 'recovery-failed')
    assert.equal(f.timers.size, 0, 'Admission stopped the status poll; failed samples do not retry')
    return request
}

for (const success of [true, false]) {
    test(`same-chapter move retires a failed native recovery without changing outcome ${success}`, async t => {
        const f = fixture(t)
        const r = await f.finishHidden(success)
        f.show()
        const oldQuery = await rejectRecoveryQuery(f, r)
        const requests = f.stateRequests.length, controls = f.controls.length
        assert.equal(f.move('a'), true)
        assert.equal(f.visibleNotices.has(r.command.requestID), false,
            'A failed recovery has no timer to clean its notice after location retirement')
        assert.equal(f.stateRequests.length, requests + 1, 'Only the new location requests state')
        assert.equal(f.stateRequests.at(-1).historyRecoveryObservation, undefined)
        assert.equal(f.coordinator.ownsHistoryReadingStatusRecovery(f.proof(r.command)), false)
        assert.equal(await f.coordinator.recoverHistoryReadingStatus(f.proof(r.command)), false)
        assert.equal(f.state.apply(oldQuery.requestID, f.response(oldQuery, 3)), false)
        assert.equal(f.accept(undefined, 4), true, 'Old completion cannot consume the new location read')
        assert.equal(f.state.ready, true)
        assert.equal(f.controls.length, controls, 'No Cancel/status is sent for a completed command')
        assert.equal(f.commands.length, 1, 'Movement never replays the Unmark')
        assert.equal(f.timers.size, 0)
        assert.equal(await r.completion, r.outcome)
    })
}

test('same-chapter move also clears a refused recovery whose query never started', async t => {
    const f = fixture(t)
    const r = await f.finishHidden()
    f.show()
    // The exact native-authorized preparation is refused; no native read posts.
    f.state.beginHistoryReadingStatusRecovery = () => false
    const requests = f.stateRequests.length
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(f.proof(r.command)), false)
    assert.equal(f.queries.length, 0)
    assert.equal(f.stateRequests.length, requests)
    assert.equal(f.visibleNotices.get(r.command.requestID)?.phase, 'recovery-failed')
    assert.equal(f.timers.size, 0)
    assert.equal(f.move('a'), true)
    assert.equal(f.visibleNotices.has(r.command.requestID), false)
    assert.equal(f.stateRequests.length, requests + 1)
    assert.equal(f.accept(undefined, 2), true)
    assert.equal(await r.completion, r.outcome)
})

test('same-chapter movement retires an admitted non-cooperative recovery immediately', async t => {
    const f = fixture(t)
    const r = await f.finishHidden()
    f.show()
    let release
    f.query = () => new Promise(resolve => { release = resolve })
    const completion = f.coordinator.recoverHistoryReadingStatus(f.proof(r.command))
    await flush()
    assert.equal(typeof release, 'function')
    let result
    completion.then(value => { result = value })
    const requests = f.stateRequests.length
    assert.equal(f.move('a'), true)
    await flush()
    const settledOnDeparture = result
    const noticeAfterDeparture = f.visibleNotices.has(r.command.requestID)
    // Release on both sources so a failing negative control leaks no task.
    release(true)
    assert.equal(await completion, false)
    await flush()
    assert.equal(settledOnDeparture, false, 'Location retirement releases the original wait without the old query')
    assert.equal(noticeAfterDeparture, false)
    assert.equal(f.stateRequests.length, requests + 1)
    assert.equal(f.accept(undefined, 3), true)
    assert.equal(f.visibleNotices.has(r.command.requestID), false)
    assert.equal(await r.completion, r.outcome)
})

test('same-chapter movement cleans an unadmitted recovery without waiting for its next poll', async t => {
    const f = fixture(t)
    const r = await f.finishHidden()
    f.show()
    assert.equal(f.timers.size, 1)
    const controls = f.controls.length
    assert.equal(f.move('a'), true)
    assert.equal(f.visibleNotices.has(r.command.requestID), false)
    assert.equal(f.timers.size, 0)
    assert.equal(f.listeners.get('pageshow')?.size ?? 0, 0)
    f.fireTimers()
    assert.equal(f.controls.length, controls)
    assert.equal(f.queries.length, 0)
    assert.equal(await r.completion, r.outcome)
})

test('unchanged location keeps a current failed recovery and does not automatically retry', async t => {
    const f = fixture(t)
    const r = await f.finishHidden()
    f.show()
    await rejectRecoveryQuery(f, r)
    const requests = f.stateRequests.length, queries = f.queries.length
    assert.equal(f.state.relocate({ sectionURL: chapterURL('a') }), false)
    assert.equal(f.visibleNotices.get(r.command.requestID)?.phase, 'recovery-failed')
    assert.equal(f.stateRequests.length, requests)
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(f.proof(r.command)), false)
    assert.equal(f.queries.length, queries)
    assert.equal(f.timers.size, 0)
})

test('ordinary same-chapter movement keeps accepted state and does not cancel an unrelated command', async t => {
    const f = fixture(t)
    const r = f.start('marked')
    const previous = f.state.state, context = f.state.context
    const requests = f.stateRequests.length
    let invalidations = 0
    const invalidate = f.state.onInvalidate
    f.state.onInvalidate = () => { invalidations += 1; invalidate() }
    assert.equal(f.move('a'), true)
    assert.equal(invalidations, 0)
    assert.equal(f.state.ready, true)
    assert.deepEqual(f.state.state, previous)
    assert.deepEqual(f.state.context, context)
    assert.equal(f.stateRequests.length, requests + 1)
    assert.equal(f.coordinator.pendingCount, 1)
    assert.equal(f.controls.length, 0)
    assert.equal(f.coordinator.settle(f.result(r.command)), true)
    const outcome = await r.completion
    assert.equal(outcome.success, true)
    assert.equal(outcome.cancellationRequested, false)
})

test('recovery notice cleanup may request the replacement location without an extra stale refresh', async t => {
    const f = fixture(t)
    const r = await f.finishHidden()
    f.show()
    const oldQuery = await rejectRecoveryQuery(f, r)
    const requests = f.stateRequests.length
    let cleanupCalls = 0
    f.onNotice = notice => {
        if (notice.requestID === r.command.requestID && notice.phase === 'finished') {
            cleanupCalls += 1
            assert.equal(f.state.refresh(), true)
        }
    }
    assert.equal(f.move('a'), true)
    assert.equal(cleanupCalls, 1)
    assert.equal(f.stateRequests.length, requests + 1,
        'The nested replacement refresh owns the slot; outer relocation must not replace it')
    assert.equal(f.state.apply(oldQuery.requestID, f.response(oldQuery, 3)), false)
    assert.equal(f.accept(undefined, 4), true)
    assert.equal(f.state.ready, true)
    assert.equal(f.visibleNotices.has(r.command.requestID), false)
    assert.equal(f.commands.length, 1)
})

test('a successful acknowledged recovery does not withdraw normal same-chapter state later', async t => {
    const f = fixture(t)
    const r = await f.finishHidden()
    f.show()
    const completion = f.coordinator.recoverHistoryReadingStatus(f.proof(r.command))
    await flush()
    assert.equal(f.accept(undefined, 2), true)
    assert.equal(await completion, true)
    const previous = f.state.state
    let invalidations = 0
    const invalidate = f.state.onInvalidate
    f.state.onInvalidate = () => { invalidations += 1; invalidate() }
    assert.equal(f.move('a'), true)
    assert.equal(invalidations, 0)
    assert.deepEqual(f.state.state, previous)
    assert.equal(f.state.ready, true)
    assert.equal(f.visibleNotices.has(r.command.requestID), false)
    assert.equal(f.commands.length, 1)
})
