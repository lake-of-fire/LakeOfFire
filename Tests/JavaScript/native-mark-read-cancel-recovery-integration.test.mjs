import assert from 'node:assert/strict'
import test from 'node:test'
import {
    createNativeMarkReadRequestCoordinator,
    refreshNativeMarkReadBookStateForRecovery,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'
import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'

const scope = { articleProgressID: 'book', articleEpochID: 'epoch',
    chapterKey: 'a'.repeat(64), chapterEpochID: null }
const sectionURL = 'ebook://fixture/book.epub?subpath=chapter.xhtml'
const drain = async () => { for (let i = 0; i < 8; i += 1) await Promise.resolve() }
const sample = (revision, observation = undefined) => ({
    ok: true, accountPresentation: '1:1',
    ...(observation ? { historyRecoveryObservation: observation } : {}),
    state: { revision, articleProgressID: 'book', articleEpochID: 'epoch', finished: false,
        bookReadPresence: 'present', chapterReadPresence: 'present', scope,
        readSegmentIdentifiers: ['segment'], sentenceIdentifiersRead: [] },
    context: { contextID: 'native-context', articleProgressID: 'book', articleEpochID: 'epoch',
        scope, isEndPage: false, sectionLocation: 'chapter.xhtml' },
})
const fixture = ({ queryAccepted = true, prepareAccepted = true, onPost, onControl, onPending,
    onSchedule, ownerIsCurrent } = {}) => {
    const messages = [], controls = [], notices = [], queries = [], timers = new Map()
    const lifecycle = new EventTarget()
    let nextTimer = 0, id = 0, current = true, coordinator
    const state = new BookReadingStateController({
        documentStartedAtMs: 11, topWindowURL: 'ebook://fixture/book.epub',
        postMessage: body => queries.push(body), makeRequestID: () => `query-${++id}`,
        onState: () => {}, requiresAccountPresentation: true,
    })
    state.relocate({ sectionURL })
    assert.equal(state.apply(queries.at(-1).requestID, sample(1)), true)
    let queryCalls = 0
    coordinator = createNativeMarkReadRequestCoordinator({
        makeRequestID: () => 'integration', lifecycleTarget: lifecycle,
        postMessage: body => { messages.push(body); onPost?.(body, coordinator) },
        postControlMessage: body => { controls.push(body); onControl?.(body, coordinator) },
        isOwnerCurrent: owner => ownerIsCurrent ? ownerIsCurrent(owner, coordinator) : current,
        onPending: notice => { notices.push(notice); onPending?.(notice, coordinator) },
        onRecoveryIsCurrent: () => current,
        onRecovery: data => prepareAccepted && refreshNativeMarkReadBookStateForRecovery(
            { state }, scope, () => current && data.isCurrent(), data.observation),
        onRecoveryQuery: observation => {
            queryCalls += 1
            return queryAccepted ? state.recoverHistoryReadingStatus(observation) : Promise.resolve(false)
        },
        scheduleTimeout: (callback, delay) => {
            const timer = ++nextTimer
            timers.set(timer, { callback, delay })
            onSchedule?.(coordinator)
            return timer
        },
        cancelTimeout: timer => timers.delete(timer),
    })
    const reply = (message, success = true, extra = {}) => ({
        requestID: message.requestID, sectionId: message.sectionId, success,
        manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: message.manualReadPendingObservationToken,
        manualReadPendingState: 'finished', stateSnapshotSequence: 2,
        ...(!success ? { errorCode: 'cancelled' } : {}), ...extra,
    })
    const unavailable = message => ({
        requestID: message.requestID, manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: message.manualReadPendingObservationToken,
        manualReadPendingState: 'unavailable', manualReadPendingHistoryRecovery: true,
        manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false,
        errorCode: 'outcomeUnavailable',
    })
    return {
        coordinator, state, messages, controls, notices, queries, timers, reply, unavailable,
        get queryCalls() { return queryCalls },
        request(desiredState = 'marked', sectionID = 'page', extra = {}) {
            return coordinator.request({ sectionID, owner: {}, context: { scope }, message: {
                topWindowURL: 'ebook://fixture/book.epub', documentStartedAtMs: 11,
                stableIdentityVersion: 1, nativeSidecarContentFingerprint: 'native',
                stableSegmentIDs: ['segment'], sentenceIdentifiers: [], desiredState,
                ...extra,
            } })
        },
        hide() { lifecycle.dispatchEvent(new Event('pagehide')) },
        show() { lifecycle.dispatchEvent(new Event('pageshow')) },
        retire() { current = false; coordinator.retireHistoryRecoveries() },
        tick() {
            const entry = timers.entries().next().value
            assert.ok(entry, 'The existing observation must survive until native recovery admission')
            timers.delete(entry[0])
            entry[1].callback()
        },
        proof(message) { return { requestID: message.requestID,
            observationToken: message.manualReadPendingObservationToken } },
        applyRecovery(proof) {
            const request = queries.at(-1)
            assert.deepEqual(request.historyRecoveryObservation, proof)
            return state.apply(request.requestID, { ...sample(2, proof),
                location: { ...state.location, locationRevision: state.locationRevision } })
        },
    }
}

for (const desiredState of ['marked', 'unmarked']) {
    for (const cancelled of [false, true]) {
        for (const success of [false, true]) {
            test(`${desiredState}: Cancel=${cancelled}, native success=${success}, expiry after departure`, async t => {
                const f = fixture()
                t.after(() => f.coordinator.close())
                const completion = f.request(desiredState), message = f.messages[0]
                if (cancelled) assert.equal(f.coordinator.cancel(message.requestID), true)
                f.hide()
                const controlCount = f.controls.length
                assert.equal(f.coordinator.settle(f.reply(message, success)), true)
                const outcome = await completion
                assert.equal(outcome.success, success, 'Cancel cannot falsify a native commit')
                assert.equal(outcome.outcomeKnown, true)
                assert.equal(outcome.cancellationRequested, cancelled,
                    'Optional movement must retain the original cancellation intent')
                assert.equal(outcome.presentationAllowed, false)
                assert.equal(f.controls.length, controlCount, 'Hidden terminal does not post recovery status')
                f.show()
                f.tick()
                const status = f.controls.at(-1)
                assert.equal(status.manualReadPendingOperation, 'status')
                assert.equal(status.manualReadPendingHistoryRecovery, true)
                assert.equal(status.requestID, message.requestID)
                assert.equal(status.manualReadPendingObservationToken, message.manualReadPendingObservationToken)
                assert.equal(f.coordinator.settle(f.unavailable(message)), true,
                    'Native retention expiry may acknowledge the exact retained recovery')
                const proof = f.proof(message)
                const recovered = f.coordinator.recoverHistoryReadingStatus(proof)
                await drain()
                assert.equal(f.queryCalls, 1)
                assert.equal(f.applyRecovery(proof), true)
                assert.equal(await recovered, true)
                assert.equal(await f.coordinator.recoverHistoryReadingStatus(proof), false,
                    'Completed recovery cannot dispatch another sample')
                assert.equal(f.queryCalls, 1)
                assert.equal(f.timers.size, 0)
                assert.equal(f.messages.length, 1, 'Returning and status recovery never replay the mutation')
                assert.equal(outcome.success, success)
                assert.equal(outcome.cancellationRequested, cancelled)
                assert.equal(f.state.ready, true)
            })
        }
    }
}

for (const desiredState of ['marked', 'unmarked']) {
    test(`${desiredState}: committed result stays displayable when Cancel loses before departure`, async t => {
        const f = fixture()
        t.after(() => f.coordinator.close())
        const completion = f.request(desiredState), message = f.messages[0]
        f.coordinator.cancel(message.requestID)
        assert.equal(f.coordinator.settle(f.reply(message)), true)
        const outcome = await completion
        assert.equal(outcome.success, true)
        assert.equal(outcome.presentationAllowed, true)
        assert.equal(outcome.cancellationRequested, true)
        assert.equal(f.coordinator.pendingCount, 0)
        assert.equal(f.timers.size, 0)
    })
}

test('a synchronous Cancel reply retains cancellation intent before cancel returns', async t => {
    const f = fixture({ onControl(body, coordinator) {
        if (body.manualReadPendingOperation === 'cancel') coordinator.settle(f.reply(f.messages[0]))
    } })
    t.after(() => f.coordinator.close())
    const completion = f.request()
    assert.equal(f.coordinator.cancel(f.messages[0].requestID), true)
    const outcome = await completion
    assert.equal(outcome.success, true)
    assert.equal(outcome.cancellationRequested, true)
    assert.equal(f.timers.size, 0)
})

test('local failed posting during departure creates no recovery and permits a fresh request', async t => {
    let fail = true
    const f = fixture({ onPost(_body, coordinator) {
        if (fail) { coordinator.pause(); throw new Error('not dispatched') }
    } })
    t.after(() => f.coordinator.close())
    const completion = f.request()
    assert.equal(f.coordinator.pendingCount, 0)
    const outcome = await completion
    assert.equal(outcome.outcomeKnown, true)
    assert.equal(outcome.success, false)
    assert.equal(f.timers.size, 0)
    f.show()
    assert.equal(f.timers.size, 0)
    fail = false
    const next = f.request(), message = f.messages.at(-1)
    assert.equal(f.messages.length, 2)
    f.coordinator.settle(f.reply(message))
    assert.equal((await next).success, true)
})

test('retired first admission never hands a mutation to native', async t => {
    const f = fixture({ onSchedule(coordinator) { coordinator?.pause() } })
    t.after(() => f.coordinator.close())
    const completion = f.request()
    assert.equal(f.messages.length, 0)
    assert.equal(f.coordinator.pendingCount, 0)
    const outcome = await completion
    assert.equal(outcome.success, false)
    assert.equal(outcome.outcomeKnown, true)
    assert.equal(outcome.errorCode, 'requestInvalidatedBeforeSubmission')
    assert.equal(f.messages.length, 0)
    assert.equal(f.timers.size, 0)
})

test('throwing diagnostic formatting still settles a failed initial post', async t => {
    const f = fixture({ onPost() { throw { get message() { throw new Error('formatting') } } } })
    t.after(() => f.coordinator.close())
    const completion = f.request()
    assert.equal(f.coordinator.pendingCount, 0)
    assert.equal((await completion).outcomeKnown, true)
    assert.equal(f.timers.size, 0)
})

test('caller toJSON runs once and cannot replace correlation or coalescing intent', async t => {
    const f = fixture()
    t.after(() => f.coordinator.close())
    let calls = 0
    const completion = f.request('marked', 'page', { toJSON() {
        calls += 1
        return { desiredState: calls === 1 ? 'marked' : 'unmarked', stableSegmentIDs: ['segment'] }
    } })
    const message = f.messages[0]
    assert.equal(calls, 1)
    assert.equal(message.desiredState, 'marked')
    assert.equal(typeof message.requestID, 'string')
    assert.equal(message.manualReadPendingObservationToken.length, 32)
    f.coordinator.settle(f.reply(message))
    assert.equal((await completion).success, true)
})

test('Cancel All does not cancel a callback-created successor for the same section', async t => {
    let successor
    const f = fixture({ onControl(body, coordinator) {
        if (body.manualReadPendingOperation !== 'cancel' || successor) return
        coordinator.settle(f.reply(f.messages[0]))
        successor = f.request('marked')
    } })
    t.after(() => f.coordinator.close())
    const original = f.request()
    f.coordinator.cancelAll()
    assert.equal((await original).cancellationRequested, true)
    const nextMessage = f.messages.at(-1)
    assert.notEqual(nextMessage.requestID, f.messages[0].requestID)
    assert.deepEqual(f.controls.map(body => body.requestID), [f.messages[0].requestID])
    f.coordinator.settle(f.reply(nextMessage))
    assert.equal((await successor).cancellationRequested, false)
})

for (const prepareAccepted of [false, true]) {
    test(`failed recovery settles without replay or automatic retry (preparation=${prepareAccepted})`, async t => {
        const f = fixture({ prepareAccepted, queryAccepted: false })
        t.after(() => f.coordinator.close())
        const completion = f.request(), message = f.messages[0]
        f.coordinator.cancel(message.requestID)
        f.hide()
        f.coordinator.settle(f.reply(message))
        const outcome = await completion
        f.show(); f.tick()
        assert.equal(f.coordinator.settle(f.unavailable(message)), true)
        const proof = f.proof(message)
        assert.equal(await f.coordinator.recoverHistoryReadingStatus(proof), false)
        assert.equal(f.queryCalls, prepareAccepted ? 1 : 0)
        assert.equal(f.notices.at(-1).phase, 'recovery-failed')
        f.hide(); f.show()
        assert.equal(f.timers.size, 0)
        assert.equal(await f.coordinator.recoverHistoryReadingStatus(proof), false)
        assert.equal(f.queryCalls, prepareAccepted ? 1 : 0)
        assert.equal(outcome.success, true)
        assert.equal(outcome.cancellationRequested, true)
        assert.equal(f.messages.length, 1)
    })
}

test('foreign or enriched unavailable packets cannot claim a cancelled recovery', async t => {
    const f = fixture()
    t.after(() => f.coordinator.close())
    const completion = f.request(), message = f.messages[0]
    f.coordinator.cancel(message.requestID)
    f.hide(); f.coordinator.settle(f.reply(message)); await completion
    f.show(); f.tick()
    for (const extra of [{ manualReadPendingObservationToken: 'foreign' },
        { requestID: 'foreign' }, { success: true }, { errorCode: 'other' }]) {
        assert.equal(f.coordinator.settle({ ...f.unavailable(message), ...extra }), false)
    }
    f.retire()
    assert.equal(f.timers.size, 0)
    assert.equal(f.coordinator.settle(f.unavailable(message)), false)
    assert.equal(f.queryCalls, 0)
})
