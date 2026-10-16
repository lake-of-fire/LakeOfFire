import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'
import { createNativeMarkReadRequestCoordinator, presentNativeMarkReadPending } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

// Complete production modules; controlled native replies and presentation faults.
const equal = (actual, expected, message) => {
    if (!Object.is(actual, expected)) throw new Error(`${message}: expected ${expected}, got ${actual}`)
}
const tick = () => new Promise(resolve => setTimeout(resolve, 0))
const proof = { requestID: 'original-unmark', observationToken: 'a'.repeat(32) }
function fixture() {
    const reads = [], publications = [], notices = [], commands = [], controls = []
    const scope = { articleProgressID: 'book', articleEpochID: 'pass', chapterKey: 'a'.repeat(64), chapterEpochID: null }
    let sequence = 0
    const state = new BookReadingStateController({
        postMessage: message => reads.push(message), makeRequestID: () => `sample-${++sequence}`,
        documentStartedAtMs: 42, topWindowURL: 'ebook://book', requiresAccountPresentation: true,
        onState: sample => publications.push(sample),
    })
    const response = (request, revision) => ({ ok: true, accountPresentation: state.accountPresentation,
        location: { sectionURL: request.sectionURL, isEndPage: false, locationRevision: request.locationRevision },
        ...(request.historyRecoveryObservation ? { historyRecoveryObservation: request.historyRecoveryObservation } : {}),
        state: { revision, scope, articleProgressID: 'book', articleEpochID: 'pass', finished: false,
            bookReadPresence: 'present', chapterReadPresence: 'present', readSegmentIdentifiers: [`segment-${revision}`], sentenceIdentifiersRead: [] },
        context: { contextID: `context-${revision}`, scope, articleProgressID: 'book', articleEpochID: 'pass',
            sectionLocation: request.sectionURL, isEndPage: false },
    })
    state.setAccountPresentation('1:1')
    state.relocate({ sectionURL: 'chapter.xhtml' })
    equal(state.apply(reads[0].requestID, response(reads[0], 1)), true, 'initial state accepted')
    const begin = observation => state.beginHistoryReadingStatusRecovery(observation, scope)
    const publish = revision => { const request = reads.at(-1); return state.apply(request.requestID, response(request, revision)) }
    const acknowledge = async (observation = proof) => {
        equal(begin(observation), true, 'recovery prepared')
        const completion = state.recoverHistoryReadingStatus(observation)
        equal(publish(2), true, 'matching recovery accepted')
        equal(await completion, true, 'matching recovery acknowledged')
    }
    let coordinator = null
    const pair = async (outcome = 'success') => {
        coordinator = createNativeMarkReadRequestCoordinator({
            postMessage: packet => commands.push(packet), postControlMessage: packet => controls.push(packet),
            lifecycleTarget: new EventTarget(), makeRequestID: () => 'withdrawal',
            onRecovery: ({ observation, isCurrent }) => state.beginHistoryReadingStatusRecovery(observation, scope, isCurrent),
            onRecoveryQuery: observation => state.recoverHistoryReadingStatus(observation),
            onPending: notice => { notices.push(notice); if (globalThis.document?.body) presentNativeMarkReadPending(notice) },
        })
        const completion = coordinator.request({ sectionID: 'section', message: { desiredState: 'unmarked' } })
        const packet = commands[0]
        const observation = { requestID: packet.requestID, observationToken: packet.manualReadPendingObservationToken }
        const envelope = { requestID: packet.requestID, manualReadPendingObservationToken: observation.observationToken,
            manualReadPendingProtocol: 1, manualReadPendingHistoryRecovery: true, manualReadPendingOutcomeOnly: true,
            manualReadPendingPresentationAllowed: false }
        equal(coordinator.settle(outcome === 'unavailable'
            ? { ...envelope, manualReadPendingState: 'unavailable', errorCode: 'outcomeUnavailable' }
            : { ...envelope, sectionId: 'section', manualReadPendingState: 'finished', success: outcome === 'success',
                ...(outcome === 'cancelled' ? { errorCode: 'cancelled' } : {}) }), true, 'native command outcome observed')
        const original = await completion
        const recovered = coordinator.recoverHistoryReadingStatus(observation)
        await tick()
        equal(publish(2), true, 'status sample accepted')
        equal(await recovered, true, 'coordinator acknowledged status')
        return { observation, original, completion, coordinator }
    }
    const cleanup = () => { state.onInvalidate = () => {}; coordinator?.close(); state.close() }
    return { state, reads, publications, notices, commands, controls, scope, begin, publish, acknowledge, pair, cleanup }
}
export const bookRecoveryFinalWithdrawalCases = []
const add = (name, run) => bookRecoveryFinalWithdrawalCases.push([name, async () => {
    const f = fixture()
    try { await run(f) } finally { f.cleanup() }
}])

for (const boundary of ['callback', 'callback lookup']) {
    add(`final publication withdrawal survives throwing ${boundary}`, async f => {
        await f.acknowledge()
        let invalidations = 0
        const fail = () => { invalidations++; throw new Error('Optional UI cleanup failed') }
        if (boundary === 'callback') f.state.onInvalidate = fail
        else Object.defineProperty(f.state, 'onInvalidate', { configurable: true, get: fail, set(value) {
            Object.defineProperty(this, 'onInvalidate', { configurable: true, writable: true, value })
        } })
        equal(f.state.failHistoryReadingStatusRecovery(proof), true, 'unchanged publication withdrawn despite failed optional paint')
        equal(f.state.ready, false, 'authoring readiness withdrawn')
        equal(f.state.context, null, 'old context cleared')
        equal(f.state.state, null, 'old sample cleared')
        equal(f.state.reacknowledgeHistoryReadingStatus(proof), false, 'old sample cannot reacknowledge')
        equal(f.state.refresh(), false, 'failed recovery does not authorize another query')
        equal(f.reads.length, 2, 'no extra query')
        equal(f.state.failHistoryReadingStatusRecovery(proof), true, 'repeated failure stays idempotent')
        equal(invalidations, 1, 'same failure does not repeatedly enter broken UI cleanup')
    })
}

for (const outcome of ['success', 'cancelled', 'unavailable']) {
    add(`${outcome}: throwing Book invalidation cannot block the coordinator failure notice`, async f => {
        const { observation, coordinator, original, completion } = await f.pair(outcome)
        f.state.onInvalidate = () => { throw new Error('Frame invalidation failed') }
        // The viewer gates coordinator failure on this Book withdrawal returning
        // true. Exercise both production owners in that order, without a copied
        // implementation of either owner or a second native mutation.
        equal(coordinator.ownsHistoryReadingStatusRecovery(observation), true, 'native failure owns its original proof')
        const withdrawn = f.state.failHistoryReadingStatusRecovery(observation)
        equal(withdrawn, true, 'Book failure returned its owned withdrawal')
        equal(withdrawn && coordinator.failHistoryReadingStatusRecovery(observation), true, 'failure reached coordinator')
        equal(await coordinator.recoverHistoryReadingStatus(observation), false, 'duplicate observes failed status, not cached success')
        equal(f.notices.at(-1).phase, 'recovery-failed', 'failure notice retained')
        equal(f.state.ready, false, 'Book remains unavailable')
        equal(await completion, original, 'original command result is unchanged')
        equal(original.outcomeKnown, outcome !== 'unavailable', 'original knowledge retained')
        equal(original.success, outcome === 'unavailable' ? undefined : outcome === 'success', 'original write outcome retained')
        equal(f.reads.length, 2, 'no status retry')
        equal(f.commands.length, 1, 'one original native mutation only')
        equal(f.controls.length, 0, 'no Cancel or replay')
        if (globalThis.document?.body) {
            const notice = document.querySelector('.mnb-native-mark-pending')
            equal(notice?.getAttribute('role'), 'status', 'accessible failure notice')
            equal(notice.firstElementChild.textContent.includes('Close and reopen'), true, 'actionable failure guidance')
            equal(notice.lastElementChild.disabled, true, 'Cancel remains disabled')
            equal(notice.lastElementChild.hidden, true, 'Cancel remains hidden')
            notice.lastElementChild.click()
            equal(f.controls.length, 0, 'hidden button cannot submit Cancel')
        }
    })
}

for (const replacement of ['close', 'account', 'location', 'same-proof recovery', 'different-proof recovery', 'published successor']) {
    add(`throwing withdrawal callback preserves ${replacement}`, async f => {
        await f.acknowledge()
        let successor, nextProof
        f.state.onInvalidate = () => {
            f.state.onInvalidate = () => {}
            if (replacement === 'close') f.state.close()
            if (replacement === 'account') f.state.setAccountPresentation('2:1')
            if (replacement === 'location') f.state.relocate({ sectionURL: 'next.xhtml' })
            if (replacement.endsWith('recovery')) {
                nextProof = replacement === 'same-proof recovery' ? proof : { ...proof, observationToken: 'b'.repeat(32) }
                equal(f.begin(nextProof), true, 'successor recovery prepared')
                successor = f.state.recoverHistoryReadingStatus(nextProof)
            }
            if (replacement === 'published successor') {
                f.state.relocate({ sectionURL: 'next.xhtml' })
                equal(f.publish(3), true, 'successor published')
            }
            throw new Error('Old cleanup threw after replacement')
        }
        equal(f.state.failHistoryReadingStatusRecovery(proof), false, 'old failure cannot own replacement')
        if (successor) {
            equal(f.state.recoverHistoryReadingStatus(nextProof), successor, 'successor promise identity retained')
            equal(f.publish(3), true, 'successor read still owns its pending slot')
            equal(await successor, true, 'successor result retained')
        }
        if (replacement === 'published successor') {
            equal(f.state.ready, true, 'published successor remains ready')
            equal(f.state.state.revision, 3, 'new revision preserved')
        }
        if (replacement === 'location') { equal(f.publish(3), true, 'replacement location still owns pending read') }
        if (replacement === 'account') equal(f.state.accountPresentation, '2:1', 'new account retained')
        if (replacement === 'close') equal(f.state.refresh(), false, 'close is terminal')
    })
}

add('ordinary successful final withdrawal and foreign-proof refusal are unchanged', async f => {
    await f.acknowledge()
    let calls = 0
    f.state.onInvalidate = () => { calls++ }
    equal(f.state.failHistoryReadingStatusRecovery({ ...proof, observationToken: 'foreign' }), false, 'foreign rejection refused')
    equal(f.state.ready, true, 'foreign failure leaves valid state alone')
    equal(calls, 0, 'foreign failure invokes no cleanup')
    equal(f.state.failHistoryReadingStatusRecovery(proof), true, 'exact failure withdrawn')
    equal(calls, 1, 'one legitimate invalidation')
    equal(f.state.ready, false, 'exact failure removes readiness')
})

add('ordinary still-pending failure releases its waiter without republishing or retrying', async f => {
    equal(f.begin(proof), true, 'prepared original')
    const completion = f.state.recoverHistoryReadingStatus(proof)
    f.state.onInvalidate = () => { throw new Error('Must not call completed-publication cleanup') }
    equal(f.state.failHistoryReadingStatusRecovery(proof), true, 'pending failure admitted')
    equal(await completion, false, 'pending observer released')
    equal(f.state.refresh(), false, 'no implicit retry')
    equal(f.reads.length, 2, 'only original read')
})
