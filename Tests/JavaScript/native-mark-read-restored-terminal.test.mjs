import assert from 'node:assert/strict'
import { test } from 'node:test'
import { setImmediate as nextTurn } from 'node:timers/promises'
import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'
import { createNativeMarkReadRequestCoordinator, refreshNativeMarkReadBookStateForRecovery } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

function fixture(t) {
    const lifecycle = new EventTarget()
    const listeners = new Map()
    const lifecycleTarget = {
        addEventListener(name, callback) {
            if (!listeners.has(name)) listeners.set(name, new Set())
            listeners.get(name).add(callback)
            lifecycle.addEventListener(name, callback)
        },
        removeEventListener(name, callback) {
            listeners.get(name)?.delete(callback)
            lifecycle.removeEventListener(name, callback)
        },
    }
    const commands = [], controls = [], notices = [], queries = []
    const timers = new Map()
    const owner = {}, context = {}
    let timerID = 0
    const f = {
        commands, controls, notices, queries, timers, listeners,
        visible: true,
        recoveryIsCurrent: () => true,
        onControl: () => {},
        onQuery: async () => true,
        onPrepare: () => true,
        hide() {
            f.visible = false
            lifecycle.dispatchEvent(new Event('pagehide'))
        },
        show() {
            f.visible = true
            lifecycle.dispatchEvent(new Event('pageshow'))
            for (const [id, timer] of [...timers]) {
                if (timer.delay !== 0 || !timers.delete(id)) continue
                timer.callback()
            }
        },
    }
    const coordinator = f.coordinator = createNativeMarkReadRequestCoordinator({
        lifecycleTarget,
        makeRequestID: () => 'restored-terminal',
        postMessage: message => commands.push(message),
        postControlMessage: message => {
            controls.push({ ...message, deliveredWhileVisible: f.visible })
            f.onControl(message)
        },
        isOwnerCurrent: candidate => candidate === owner && f.visible,
        scheduleTimeout: (callback, delay) => {
            timers.set(++timerID, { callback, delay })
            return timerID
        },
        cancelTimeout: id => timers.delete(id),
        onPending: notice => notices.push(notice),
        onRecovery: value => f.onPrepare(value),
        onRecoveryIsCurrent: () => f.recoveryIsCurrent(),
        onRecoveryQuery: proof => {
            queries.push(proof)
            return f.onQuery(proof)
        },
    })
    t.after(() => coordinator.close())
    f.start = (desiredState = 'unmarked', sectionID = 'section') => {
        const completion = coordinator.request({
            sectionID, owner, context,
            message: { desiredState, stableSegmentIDs: ['segment'], sentenceIdentifiers: [],
                topWindowURL: 'ebook://ebook/load/local/book.epub',
                pageURL: 'https://reader.invalid/chapter.xhtml', documentStartedAtMs: 100 },
        })
        return { completion, command: commands.at(-1) }
    }
    f.result = (command, success = true, history = false) => ({
        requestID: command.requestID, sectionId: command.sectionId,
        manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: command.manualReadPendingObservationToken,
        manualReadPendingState: 'finished', success,
        errorCode: success ? '' : 'nativeCommitFailed',
        ...(history ? { manualReadPendingHistoryRecovery: true,
            manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false } : {}),
    })
    f.proof = command => ({ requestID: command.requestID,
        observationToken: command.manualReadPendingObservationToken })
    f.visibleStatuses = () => controls.filter(packet => packet.deliveredWhileVisible
        && packet.manualReadPendingOperation === 'status')
    f.finishHidden = async (success = true, desiredState = 'unmarked') => {
        const request = f.start(desiredState)
        f.hide()
        assert.equal(coordinator.settle(f.result(request.command, success)), true)
        const outcome = await request.completion
        assert.equal(outcome.success, success)
        assert.equal(outcome.outcomeKnown, true)
        assert.equal(outcome.presentationAllowed, false)
        assert.equal(coordinator.pendingCount, 0)
        return request
    }
    return f
}

for (const desiredState of ['marked', 'unmarked']) {
    for (const success of [true, false]) {
        test(`${desiredState}: hidden terminal ${success} retains a read-only handoff for pageshow`, async t => {
            const f = fixture(t)
            const { command, completion } = await f.finishHidden(success, desiredState)
            f.show()
            const statuses = f.visibleStatuses()
            assert.equal(statuses.length, 1, 'The joined command still needs native recovery admission on return')
            assert.equal(statuses[0].requestID, command.requestID)
            assert.equal(statuses[0].manualReadPendingObservationToken, command.manualReadPendingObservationToken)
            assert.equal(statuses[0].manualReadPendingHistoryRecovery, true)
            assert.equal(statuses[0].manualReadPendingKind, 'section')
            assert.equal(statuses[0].topWindowURL, command.topWindowURL)
            assert.equal(statuses[0].documentStartedAtMs, command.documentStartedAtMs)
            assert.equal(f.commands.length, 1, 'Returning cannot resend the mutation')
            assert.equal(f.queries.length, 0, 'Only native can authorize the fresh reading-state query')
            assert.equal(f.coordinator.cancel(command.requestID), false)
            assert.equal((await completion).success, success, 'Recovery does not replace the terminal truth')
        })
    }
}

test('a missing first handoff remains observable on a second return', async t => {
    const f = fixture(t)
    const { command } = await f.finishHidden()
    f.onControl = () => { throw new Error('Transport unavailable during restoration') }
    f.show()
    assert.equal(f.visibleStatuses().length, 1)
    f.hide()
    f.onControl = () => {}
    f.show()
    assert.equal(f.visibleStatuses().length, 2)
    assert.ok(f.visibleStatuses().every(packet => packet.requestID === command.requestID))
    assert.equal(f.commands.length, 1)
    assert.equal(f.queries.length, 0)
})

test('terminal arriving just after pageshow keeps lifecycle observation until native handoff', async t => {
    const f = fixture(t)
    const { command, completion } = f.start()
    f.hide()
    f.show()
    assert.equal(f.coordinator.settle(f.result(command)), true)
    await completion
    const before = f.visibleStatuses().length
    assert.ok(before >= 1)
    f.hide()
    f.show()
    assert.equal(f.visibleStatuses().length, before + 1)
    assert.equal(f.commands.length, 1)
})

test('native-authorized recovery is not restarted by another pageshow', async t => {
    const f = fixture(t)
    const { command } = await f.finishHidden()
    f.show()
    assert.equal(f.coordinator.settle(f.result(command, true, true)), true)
    let finishQuery
    f.onQuery = () => new Promise(resolve => { finishQuery = resolve })
    const recovery = f.coordinator.recoverHistoryReadingStatus(f.proof(command))
    await Promise.resolve()
    assert.equal(f.queries.length, 1)
    const statusCount = f.visibleStatuses().length
    f.hide()
    f.show()
    assert.equal(f.visibleStatuses().length, statusCount)
    assert.equal(f.queries.length, 1)
    finishQuery(true)
    assert.equal(await recovery, true)
    assert.equal(f.listeners.get('pageshow')?.size ?? 0, 0)
    assert.equal(f.listeners.get('pagehide')?.size ?? 0, 0)
    const next = f.start('marked', 'another-section')
    assert.equal(f.commands.length, 2, 'A successful fresh sample releases the old recovery barrier')
    f.coordinator.settle(f.result(next.command))
    assert.equal((await next.completion).success, true)
})

test('a failed native-authorized sample is not retried automatically', async t => {
    const f = fixture(t)
    const { command } = await f.finishHidden()
    f.show()
    f.onQuery = async () => false
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(f.proof(command)), false)
    const statusCount = f.visibleStatuses().length
    f.hide()
    f.show()
    assert.equal(f.visibleStatuses().length, statusCount)
    assert.equal(f.queries.length, 1)
    assert.equal(f.notices.at(-1).phase, 'recovery-failed')
})

test('a retired chapter or account cannot request its former recovery on return', async t => {
    const f = fixture(t)
    await f.finishHidden()
    f.recoveryIsCurrent = () => false
    f.show()
    assert.equal(f.visibleStatuses().length, 0)
    assert.equal(f.commands.length, 1)
    assert.equal(f.queries.length, 0)
})

test('closing from the recovery ownership check suppresses the old status post', async t => {
    const f = fixture(t)
    await f.finishHidden()
    f.recoveryIsCurrent = () => {
        f.coordinator.close()
        return true
    }
    f.show()
    assert.equal(f.visibleStatuses().length, 0)
    assert.equal(f.listeners.get('pageshow')?.size ?? 0, 0)
    assert.equal(f.commands.length, 1)
})

test('explicit recovery retirement releases the return listener without a status post', async t => {
    const f = fixture(t)
    await f.finishHidden()
    f.show()
    f.coordinator.retireHistoryRecoveries()
    assert.equal(f.listeners.get('pageshow')?.size ?? 0, 0)
    const statusCount = f.visibleStatuses().length
    f.hide()
    f.show()
    assert.equal(f.visibleStatuses().length, statusCount)
    assert.equal(f.commands.length, 1)
})

test('a mismatched terminal capability cannot authorize the retained recovery', async t => {
    const f = fixture(t)
    const { command } = await f.finishHidden()
    f.show()
    assert.equal(f.coordinator.settle({ ...f.result(command, true, true),
        manualReadPendingObservationToken: 'wrong' }), false)
    assert.equal(await f.coordinator.recoverHistoryReadingStatus({ ...f.proof(command),
        observationToken: 'wrong' }), false)
    assert.equal(f.queries.length, 0)
    assert.equal(f.coordinator.settle(f.result(command, true, true)), true)
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(f.proof(command)), true)
    assert.equal(f.queries.length, 1)
    assert.equal(f.commands.length, 1)
})

test('retained unavailable outcome can acknowledge its exact status again after return', async t => {
    const f = fixture(t)
    const { command, completion } = f.start()
    f.hide()
    const result = {
        requestID: command.requestID,
        manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: command.manualReadPendingObservationToken,
        manualReadPendingState: 'unavailable',
        manualReadPendingHistoryRecovery: true,
        manualReadPendingOutcomeOnly: true,
        manualReadPendingPresentationAllowed: false,
        errorCode: 'outcomeUnavailable',
    }
    // A terminal delivery and the native request to start recovery are separate
    // callbacks. The second may be suppressed when the document departs.
    assert.equal(f.coordinator.settle(result), true)
    assert.equal((await completion).outcomeKnown, false)
    f.show()
    assert.equal(f.coordinator.settle({ ...result, success: false }), false,
        'Unavailable does not mean the mutation failed')
    assert.equal(f.coordinator.settle({ ...result, manualReadPendingObservationToken: 'wrong' }), false)
    assert.equal(f.coordinator.settle(result), true,
        'An exact duplicate terminal may acknowledge the existing barrier, not settle the command again')
    assert.equal((await completion).outcomeKnown, false)
    assert.equal((await completion).success, undefined)
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(f.proof(command)), true)
    assert.equal(f.queries.length, 1)
    assert.equal(f.commands.length, 1)
    assert.equal(f.coordinator.settle(result), false, 'Completed recovery cannot be recreated')
})


test('an early restored status can be observed again without another mutation or read attempt', async t => {
    const f = fixture(t)
    const { command } = await f.finishHidden()
    f.show()
    assert.equal(f.visibleStatuses().length, 1)
    // Model native rejecting the first status because its original document
    // has not yet completed restoration admission. No reply was accepted.
    const next = f.timers.entries().next().value
    assert.ok(next, 'Unacknowledged recovery retains the existing observation timer')
    const [id, timer] = next
    assert.equal(timer.delay, 5000, 'Use the existing status polling cadence')
    f.timers.delete(id)
    timer.callback()
    assert.equal(f.visibleStatuses().length, 2)
    assert.equal(f.commands.length, 1)
    assert.equal(f.queries.length, 0)
    assert.equal(f.coordinator.settle(f.result(command, true, true)), true)
    assert.equal(await f.coordinator.recoverHistoryReadingStatus(f.proof(command)), true)
    assert.equal(f.queries.length, 1)
    assert.equal(f.timers.size, 0)
    assert.equal((await f.coordinator.recoverHistoryReadingStatus(f.proof(command))), false)
    assert.equal(f.commands.length, 1)
})


for (const success of [true, false]) {
    test(`restored Unmark ${success} waits for the real Book-state recovery before restoring controls`, async t => {
        const f = fixture(t)
        const messages = []
        let serial = 0
        const scope = { articleProgressID: 'article', articleEpochID: 'epoch',
            chapterKey: 'a'.repeat(64), chapterEpochID: null }
        const state = new BookReadingStateController({
            postMessage: message => messages.push(message),
            topWindowURL: 'ebook://ebook/load/local/book.epub', documentStartedAtMs: 100,
            requiresAccountPresentation: true, makeRequestID: () => `sample-${++serial}`,
        })
        t.after(() => state.close())
        state.setAccountPresentation('1:1')
        state.relocate({ sectionURL: 'https://reader.invalid/chapter.xhtml' })
        const response = (revision, readIDs) => ({
            ok: true, accountPresentation: '1:1',
            location: { ...state.location, locationRevision: state.locationRevision },
            state: { revision, articleProgressID: 'article', articleEpochID: 'epoch', scope,
                finished: false, bookReadPresence: readIDs.length ? 'present' : 'empty',
                chapterReadPresence: readIDs.length ? 'present' : 'empty',
                readSegmentIdentifiers: readIDs, sentenceIdentifiersRead: [] },
            context: { contextID: `context-${revision}`, articleProgressID: 'article',
                articleEpochID: 'epoch', scope, isEndPage: false, sectionLocation: 'chapter.xhtml' },
        })
        assert.equal(state.apply(messages[0].requestID, response(1, ['segment'])), true)
        f.onPrepare = ({ observation, isCurrent }) => refreshNativeMarkReadBookStateForRecovery(
            { state }, scope, isCurrent, observation)
        f.onQuery = proof => state.recoverHistoryReadingStatus(proof)
        const { command, completion } = await f.finishHidden(success)
        assert.equal(state.ready, false, 'Terminal truth alone cannot retain the old Book context')
        assert.equal(messages.length, 1, 'Preparation withdraws state but cannot start the native query')
        f.show()
        assert.equal(f.visibleStatuses().length, 1, 'Return requests admission for the original recovery')
        assert.equal(messages.length, 1)
        assert.equal(f.coordinator.settle(f.result(command, success, true)), true)
        const recovery = f.coordinator.recoverHistoryReadingStatus(f.proof(command))
        await nextTurn()
        assert.equal(messages.length, 2)
        const query = messages.at(-1)
        assert.deepEqual(query.historyRecoveryObservation, f.proof(command))
        assert.equal(query.historyRecoveryAccountPresentation, '1:1')
        assert.equal(state.ready, false)
        const readIDs = success ? [] : ['segment']
        assert.equal(state.apply(query.requestID, { ...response(2, readIDs),
            historyRecoveryObservation: f.proof(command) }), true)
        assert.equal(await recovery, true)
        assert.equal(state.ready, true)
        assert.deepEqual(state.state.readSegmentIdentifiers, readIDs)
        assert.equal((await completion).success, success, 'The sample does not change the native command outcome')
        assert.equal(f.notices.at(-1).phase, 'finished')
        assert.equal(f.timers.size, 0)
        f.hide()
        f.show()
        assert.equal(messages.length, 2, 'Another return cannot repeat a completed read')
        assert.equal(f.commands.length, 1, 'No Mark/Unmark replay')
        assert.equal(f.queries.length, 1)
    })
}
