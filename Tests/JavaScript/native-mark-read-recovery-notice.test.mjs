import assert from 'node:assert/strict'
import test from 'node:test'
import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'
import {
    createNativeMarkReadRequestCoordinator,
    presentNativeMarkReadPending,
    refreshNativeMarkReadBookStateForRecovery,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

// The complete production coordinator, native-state projection and presenter
// execute. Only DOM allocation, timers and delivery of native replies are fakes.
function fixture(t) {
    const previousDocument = globalThis.document
    const element = () => ({
        children: [], attributes: {}, listeners: {}, parent: null,
        append(...children) {
            for (const child of children) { child.parent = this; this.children.push(child) }
        },
        setAttribute(name, value) { this.attributes[name] = value },
        addEventListener(name, callback) { this.listeners[name] = callback },
        remove() {
            if (this.parent) this.parent.children = this.parent.children.filter(child => child !== this)
            this.parent = null
        },
        get firstElementChild() { return this.children[0] },
        get lastElementChild() { return this.children.at(-1) },
    })
    const body = element()
    globalThis.document = { body, createElement: element }
    const commands = [], controls = [], reads = [], timers = new Map()
    let serial = 0
    const scope = { articleProgressID: 'book', articleEpochID: 'pass',
        chapterKey: 'a'.repeat(64), chapterEpochID: null }
    const state = new BookReadingStateController({
        documentStartedAtMs: 42, topWindowURL: 'ebook://fixture/book',
        makeRequestID: () => `state-${++serial}`, postMessage: message => reads.push(message),
        requiresAccountPresentation: true,
    })
    const publish = (revision, ok = true) => {
        const request = reads.at(-1)
        return state.apply(request.requestID, {
            ok, accountPresentation: '0:1',
            location: { sectionURL: 'chapter.xhtml', isEndPage: false, locationRevision: state.locationRevision },
            ...(request.historyRecoveryObservation ? { historyRecoveryObservation: request.historyRecoveryObservation } : {}),
            state: { revision, articleProgressID: 'book', articleEpochID: 'pass', scope,
                finished: false, bookReadPresence: 'present', chapterReadPresence: 'present',
                readSegmentIdentifiers: [], sentenceIdentifiersRead: [] },
            context: { contextID: `context-${revision}`, articleProgressID: 'book', articleEpochID: 'pass',
                scope, sectionLocation: 'chapter.xhtml', isEndPage: false },
        })
    }
    assert.equal(state.relocate({ sectionURL: 'chapter.xhtml' }), true)
    assert.equal(publish(1), true)
    const coordinator = createNativeMarkReadRequestCoordinator({
        postMessage: message => commands.push(message), postControlMessage: message => controls.push(message),
        makeRequestID: () => 'notice', scheduleTimeout: callback => { const id = ++serial; timers.set(id, callback); return id },
        cancelTimeout: id => timers.delete(id), onPending: presentNativeMarkReadPending,
        onRecovery: ({ observation, isCurrent }) =>
            refreshNativeMarkReadBookStateForRecovery({ state }, scope, isCurrent, observation),
        onRecoveryQuery: observation => state.recoverHistoryReadingStatus(observation),
    })
    t.after(() => {
        coordinator.close()
        state.close()
        globalThis.document = previousDocument
    })
    const start = desiredState => coordinator.request({ sectionID: 'page', message: {
        desiredState, topWindowURL: 'ebook://fixture/book', documentStartedAtMs: 42,
    } })
    const outcome = (kind, history = true) => {
        const command = commands.at(-1)
        return {
            requestID: command.requestID, sectionId: command.sectionId,
            manualReadPendingProtocol: 1,
            manualReadPendingObservationToken: command.manualReadPendingObservationToken,
            ...(history ? { manualReadPendingHistoryRecovery: true,
                manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false } : {}),
            ...(kind === 'unavailable'
                ? { sectionId: undefined, manualReadPendingState: 'unavailable', errorCode: 'outcomeUnavailable' }
                : { manualReadPendingState: 'finished', success: kind === 'success',
                    ...(kind === 'failure' ? { errorCode: 'cancelled' } : {}) }),
        }
    }
    const terminal = kind => {
        const result = outcome(kind)
        if (kind === 'unavailable') delete result.sectionId
        return result
    }
    return { body, commands, controls, reads, timers, coordinator, state, start, publish, outcome, terminal,
        notice: () => body.children[0],
        proof: () => ({ requestID: commands.at(-1).requestID,
            observationToken: commands.at(-1).manualReadPendingObservationToken }),
    }
}

const flush = () => new Promise(resolve => setImmediate(resolve))
const prefixes = {
    success: 'The reading change was saved.',
    failure: 'The reading change wasn’t saved.',
    unavailable: 'The reading change’s outcome is unavailable.',
}

for (const desiredState of ['marked', 'unmarked']) {
    for (const kind of Object.keys(prefixes)) {
        test(`${desiredState}: ${kind} is shown while the authorized status refresh is pending`, async t => {
            const f = fixture(t)
            const completion = f.start(desiredState)
            f.coordinator.pause(); f.coordinator.resume()
            const originalNotice = f.notice()
            assert.match(originalNotice.firstElementChild.textContent, /Waiting for its outcome/)
            assert.equal(f.coordinator.settle(f.terminal(kind)), true)
            const result = await completion
            assert.equal(result.outcomeKnown, kind !== 'unavailable')
            assert.equal(result.success, kind === 'unavailable' ? undefined : kind === 'success')
            assert.equal(f.notice(), originalNotice, 'Keep the same accessible status region')
            assert.ok(f.notice().firstElementChild.textContent.startsWith(prefixes[kind]))
            assert.match(f.notice().firstElementChild.textContent, /Refreshing reading status/)
            assert.doesNotMatch(f.notice().firstElementChild.textContent, /Waiting for its outcome|Still saving/)
            assert.equal(f.notice().lastElementChild.hidden, true)
            assert.equal(f.notice().lastElementChild.disabled, true)
            assert.equal(f.coordinator.cancel(f.commands[0].requestID), false)
            assert.equal(f.state.ready, false)
            assert.equal(f.reads.length, 1, 'Terminal delivery cannot authorize its own state query')
            const recovered = f.coordinator.recoverHistoryReadingStatus(f.proof())
            await flush()
            assert.equal(f.reads.length, 2)
            assert.ok(f.notice().firstElementChild.textContent.startsWith(prefixes[kind]))
            assert.equal(f.publish(2), true)
            assert.equal(await recovered, true)
            assert.equal(f.body.children.length, 0)
            assert.equal(f.state.ready, true)
            assert.equal(f.commands.length, 1, 'Status recovery must never replay Mark/Unmark')
            assert.equal(f.controls.length, 0, 'No Cancel was sent during recovery')
        })
    }
}

test('ordinary slow and cancelling commands still wait for the real native outcome', async t => {
    const f = fixture(t)
    const completion = f.start('unmarked')
    const callback = [...f.timers.values()][0]
    callback()
    assert.match(f.notice().firstElementChild.textContent, /Still saving/)
    assert.equal(f.notice().lastElementChild.disabled, false)
    f.notice().lastElementChild.listeners.click()
    assert.match(f.notice().firstElementChild.textContent, /Cancelling.*Waiting for its outcome/)
    assert.equal(f.notice().lastElementChild.disabled, true)
    assert.equal(f.controls.at(-1).manualReadPendingOperation, 'cancel')
    assert.equal(f.coordinator.settle(f.outcome('failure', false)), true)
    assert.equal((await completion).success, false)
    assert.equal(f.body.children.length, 0)
})

for (const kind of Object.keys(prefixes)) {
    test(`${kind}: failed status refresh retains the original outcome and recovery guidance`, async t => {
        const f = fixture(t)
        const completion = f.start('unmarked')
        f.coordinator.pause(); f.coordinator.resume()
        assert.equal(f.coordinator.settle(f.terminal(kind)), true)
        const original = await completion
        const recovered = f.coordinator.recoverHistoryReadingStatus(f.proof())
        await flush()
        assert.equal(f.publish(2, false), false)
        assert.equal(await recovered, false)
        assert.ok(f.notice().firstElementChild.textContent.startsWith(prefixes[kind]))
        assert.match(f.notice().firstElementChild.textContent, /Close and reopen this book/)
        assert.equal(await completion, original)
        assert.equal(f.notice().lastElementChild.hidden, true)
        assert.equal(f.notice().lastElementChild.disabled, true)
        assert.equal(f.commands.length, 1)
        assert.equal(f.controls.length, 0)
    })
}
