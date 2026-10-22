import assert from 'node:assert/strict'
import test from 'node:test'
import { createNativeMarkReadRequestCoordinator } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

// Complete coordinator; native transport, timer installation and ownership
// callbacks are controlled collaborators. No browser lifecycle is simulated
// by a copied implementation, and these tests do not claim native commits.
function fixture({ onSchedule, onRegistration, onOwner, onPost, onClear } = {}) {
    const h = { commands: [], controls: [], notices: [], timers: new Map(),
        ownerCurrent: true, recoveryCalls: 0, queryCalls: 0, clock: 0 }
    const lifecycleTarget = new class extends EventTarget {
        addEventListener(type, callback, options) {
            super.addEventListener(type, callback, options)
            onRegistration?.(h, type)
        }
    }()
    h.lifecycleTarget = lifecycleTarget
    h.coordinator = createNativeMarkReadRequestCoordinator({
        lifecycleTarget,
        makeRequestID: () => 'native-pre-dispatch',
        isOwnerCurrent: owner => onOwner ? onOwner(h, owner) : h.ownerCurrent,
        postMessage: message => { h.commands.push(message); onPost?.(h, message) },
        postControlMessage: message => h.controls.push(message),
        scheduleTimeout: (callback, delay) => {
            const id = ++h.clock
            h.timers.set(id, { callback, delay })
            onSchedule?.(h, id)
            return id
        },
        cancelTimeout: id => { h.timers.delete(id); onClear?.(h, id) },
        onPending: state => h.notices.push(state),
        onRecovery: () => { h.recoveryCalls++; return true },
        onRecoveryQuery: () => { h.queryCalls++; return Promise.resolve(true) },
    })
    h.request = (desiredState = 'marked') => h.coordinator.request({
        sectionID: 'chapter-page', owner: { chapter: 'original' }, context: { page: 1 },
        message: { topWindowURL: 'ebook://ebook/load/local/book.epub',
            documentStartedAtMs: 42, stableSegmentIDs: ['word'],
            sentenceIdentifiers: ['sentence'], desiredState,
            ...(desiredState === 'unmarked' ? { expectedManualSupportRevision: 'revision' } : {}),
        },
    })
    h.reply = (message, extra = {}) => h.coordinator.settle({
        requestID: message.requestID, sectionId: message.sectionId,
        manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: message.manualReadPendingObservationToken,
        manualReadPendingState: 'finished', success: true, ...extra,
    })
    return h
}

async function assertNotSubmitted(h, completion) {
    // Fail before awaiting on the negative control, whose old request is
    // incorrectly submitted and would remain pending until a native reply.
    assert.equal(h.commands.length, 0, 'retired preparation must never enter the native mutation callback')
    const result = await completion
    assert.equal(result.success, false)
    assert.equal(result.outcomeKnown, true, 'no transport entry is known local non-submission')
    assert.equal(result.presentationAllowed, false)
    assert.equal(result.errorCode, 'requestInvalidatedBeforeSubmission')
    assert.equal(h.coordinator.pendingCount, 0)
    assert.equal(h.timers.size, 0)
    assert.equal(h.recoveryCalls, 0, 'an unsent command needs no native History reconciliation')
    assert.equal(h.queryCalls, 0)
    assert.equal(h.notices.at(-1).phase, 'finished')
    return result
}

for (const desiredState of ['marked', 'unmarked']) {
    test(`${desiredState}: stale initial owner cannot dispatch`, async () => {
        const h = fixture()
        h.ownerCurrent = false
        await assertNotSubmitted(h, h.request(desiredState))
    })

    test(`${desiredState}: pagehide during timer setup prevents initial submission`, async () => {
        let once = true
        const h = fixture({ onSchedule(h) {
            if (!once) return
            once = false
            h.lifecycleTarget.dispatchEvent(new Event('pagehide'))
        } })
        const completion = h.request(desiredState)
        await assertNotSubmitted(h, completion)
        h.lifecycleTarget.dispatchEvent(new Event('pageshow'))
        assert.equal(h.commands.length, 0)
        assert.equal(h.controls.length, 0)
        const fresh = h.request(desiredState)
        assert.equal(h.commands.length, 1, 'a deliberate new request after returning remains usable')
        assert.equal(h.reply(h.commands[0]), true)
        assert.equal((await fresh).success, true)
    })

    test(`${desiredState}: immediate pause/resume cannot revive old preparation`, async () => {
        let once = true
        const h = fixture({ onSchedule(h) {
            if (!once) return
            once = false
            h.coordinator.pause()
            h.coordinator.resume()
        } })
        await assertNotSubmitted(h, h.request(desiredState))
        assert.equal(h.controls.length, 0)
    })
}

test('pagehide during lifecycle registration cannot dispatch', async () => {
    let once = true
    const h = fixture({ onRegistration(h, type) {
        if (!once || type !== 'pagehide') return
        once = false
        h.lifecycleTarget.dispatchEvent(new Event('pagehide'))
    } })
    await assertNotSubmitted(h, h.request())
})

test('owner predicate cannot pause then lend its returned true to the old dispatch', async () => {
    let once = true
    const h = fixture({ onOwner(h) {
        if (once) { once = false; h.coordinator.pause() }
        return true
    } })
    await assertNotSubmitted(h, h.request())
})

test('owner predicate failure releases unsent request for explicit retry', async () => {
    let fails = true
    const h = fixture({ onOwner() {
        if (fails) throw new Error('chapter ownership unavailable')
        return true
    } })
    await assertNotSubmitted(h, h.request('unmarked'))
    fails = false
    const fresh = h.request('unmarked')
    assert.equal(h.commands.length, 1)
    h.reply(h.commands[0])
    assert.equal((await fresh).success, true)
})

test('cancel during setup withdraws the initial mutation before native submission', async () => {
    let once = true
    const h = fixture({ onSchedule(h) {
        if (!once) return
        once = false
        h.coordinator.cancelAll()
    } })
    await assertNotSubmitted(h, h.request('unmarked'))
    // Existing pre-admission Cancel observation is not a mutation replay.
    assert.equal(h.controls.length, 1)
    assert.equal(h.controls[0].manualReadPendingOperation, 'cancel')
})

test('unsent cleanup cannot remove a same-section reentrant successor', async () => {
    let stopFirst = true, startReplacement = true, successor
    const h = fixture({
        onOwner() { if (stopFirst) { stopFirst = false; return false }; return true },
        onClear(h) {
            if (!startReplacement) return
            startReplacement = false
            successor = h.request()
        },
    })
    const first = h.request('unmarked')
    assert.equal(h.commands.length, 1, 'only the cleanup-created successor is dispatched')
    assert.equal(h.commands[0].desiredState, 'marked')
    assert.equal((await first).success, false)
    assert.equal(h.coordinator.pendingCount, 1)
    assert.equal(h.reply(h.commands[0]), true)
    assert.equal((await successor).success, true)
    assert.equal(h.coordinator.pendingCount, 0)
})

test('ordinary current request still coalesces and waits for native outcome', async () => {
    const h = fixture()
    const first = h.request(), second = h.request()
    assert.equal(first, second)
    assert.equal(h.commands.length, 1)
    assert.equal(h.coordinator.pendingCount, 1)
    assert.equal(h.reply(h.commands[0], { success: false, errorCode: 'nativeRejected' }), true,
        'Book shell acceptance stays distinct from command success')
    assert.equal((await first).success, false)
    assert.equal((await second).errorCode, 'nativeRejected')
    assert.equal(h.timers.size, 0)
})

test('ownership loss after transport entry cannot rewrite native committed success', async () => {
    const h = fixture()
    const completion = h.request()
    h.ownerCurrent = false
    assert.equal(h.reply(h.commands[0]), true)
    const result = await completion
    assert.equal(result.success, true)
    assert.equal(result.stale, true)
    assert.equal(result.presentationAllowed, false)
})

test('submitted request still permits read-only History recovery after pause', async () => {
    const h = fixture()
    const completion = h.request('unmarked'), message = h.commands[0]
    h.coordinator.pause()
    h.coordinator.resume()
    assert.equal(h.reply(message, { manualReadPendingHistoryRecovery: true,
        manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false,
    }), true)
    assert.equal((await completion).success, true)
    assert.equal(await h.coordinator.recoverHistoryReadingStatus({
        requestID: message.requestID, observationToken: message.manualReadPendingObservationToken,
    }), true)
    assert.equal(h.queryCalls, 1)
    assert.equal(h.commands.length, 1)
})

test('synchronous native success survives a subsequent transport-wrapper exception', async () => {
    const h = fixture({ onPost(h, message) {
        h.reply(message)
        throw new Error('wrapper failed after native completion')
    } })
    assert.equal((await h.request()).success, true)
    assert.equal(h.commands.length, 1)
    assert.equal(h.coordinator.pendingCount, 0)
})

test('close inside initial transport still reports unknown native outcome', async () => {
    const h = fixture({ onPost(h) { h.coordinator.close() } })
    await assert.rejects(h.request(), error => error.code === 'readerClosed' && error.outcomeUnknown === true)
    assert.equal(h.commands.length, 1)
    assert.equal(h.controls.length, 1)
    assert.equal(h.controls[0].manualReadPendingOperation, 'cancel')
})
