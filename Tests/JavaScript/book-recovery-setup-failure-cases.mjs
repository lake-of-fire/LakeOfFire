import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'
import { createNativeMarkReadRequestCoordinator } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

// Complete production controllers run in Node and Chromium. Only native reply
// delivery and optional presentation callbacks are controlled by this fixture.
const equal = (value, expected, message) => {
    if (!Object.is(value, expected)) throw new Error(`${message}: expected ${String(expected)}, got ${String(value)}`)
}
const turn = () => new Promise(resolve => {
    const channel = new MessageChannel()
    channel.port1.onmessage = () => { channel.port1.close(); channel.port2.close(); resolve() }
    channel.port2.postMessage(null)
})
const watch = promise => {
    const receipt = { settled: false }
    promise.then(value => Object.assign(receipt, { settled: true, value }),
        error => Object.assign(receipt, { settled: true, error }))
    return receipt
}
const answered = (receipt, value, message) => {
    equal(receipt.settled, true, `${message} settled`)
    equal(receipt.error, undefined, `${message} did not reject`)
    equal(receipt.value, value, message)
}
const proof = suffix => ({ requestID: `unmark-${suffix}`, observationToken: suffix.repeat(32) })

function fixture() {
    const requests = [], publications = []
    let nextID = 0
    const scope = { articleProgressID: 'book', articleEpochID: null,
        chapterKey: 'a'.repeat(64), chapterEpochID: null }
    const state = new BookReadingStateController({
        postMessage: message => requests.push(message),
        documentStartedAtMs: 42, topWindowURL: 'ebook://book/viewer',
        makeRequestID: () => `state-${++nextID}`, requiresAccountPresentation: true,
        onState: sample => publications.push(sample),
    })
    const reply = (request, revision, ok = true) => ({
        ok, accountPresentation: state.accountPresentation,
        location: { sectionURL: request.sectionURL, isEndPage: false,
            locationRevision: request.locationRevision },
        ...(request.historyRecoveryObservation ? { historyRecoveryObservation: request.historyRecoveryObservation } : {}),
        state: { articleProgressID: scope.articleProgressID, articleEpochID: null, scope,
            revision, finished: false, bookReadPresence: 'present', chapterReadPresence: 'present',
            readSegmentIdentifiers: [`read-${revision}`], sentenceIdentifiersRead: [] },
        context: { contextID: `context-${revision}`, isEndPage: false,
            sectionLocation: request.sectionURL, articleProgressID: scope.articleProgressID,
            articleEpochID: null, scope },
    })
    state.setAccountPresentation('1:1')
    state.relocate({ sectionURL: 'chapter.xhtml' })
    equal(state.apply(requests[0].requestID, reply(requests[0], 1)), true, 'initial snapshot accepted')
    const begin = (observation = proof('a')) => {
        equal(state.beginHistoryReadingStatusRecovery(observation, scope), true, 'original recovery prepared')
        return observation
    }
    const failPost = () => { throw new Error('Native read handoff unavailable') }
    return { state, requests, publications, scope, reply, begin, failPost,
        cleanup: () => { state.onInvalidate = () => {}; state.close() } }
}
export const bookRecoverySetupFailureCases = []
const add = (name, run) => bookRecoverySetupFailureCases.push([name, async () => {
    const f = fixture()
    try { await run(f) } finally { f.cleanup() }
}])

for (const cleanup of ['normal', 'throws', 'joins-then-throws']) {
    add(`failed native read with ${cleanup} cleanup releases the exact original completion`, async f => {
        const observation = f.begin()
        let joined
        f.state.postMessage = f.failPost
        f.state.onInvalidate = () => {
            if (cleanup === 'joins-then-throws') joined = watch(f.state.recoverHistoryReadingStatus(observation))
            if (cleanup !== 'normal') throw new Error('Renderer invalidation failed')
        }
        const completion = f.state.recoverHistoryReadingStatus(observation)
        const original = watch(completion)
        await turn()
        answered(original, false, 'failed read')
        if (joined) answered(joined, false, 'joined observer')
        equal(f.state.ready, false, 'failed read did not publish readiness')
        equal(f.publications.length, 1, 'no failed sample published')
        // The controller retains its existing explicit retry API. The outer
        // coordinator (covered below) still forbids an automatic retry.
        f.state.onInvalidate = () => {}
        f.state.postMessage = message => f.requests.push(message)
        const retry = f.state.recoverHistoryReadingStatus(observation)
        const request = f.requests.at(-1)
        equal(f.state.apply(request.requestID, f.reply(request, 2)), true, 'explicit retry uses its own sample')
        equal(await retry, true, 'explicit retry can complete after cleanup failure')
    })
}

for (const replacement of ['close', 'account']) {
    add(`${replacement} during failed-read cleanup cannot throw from an already released resolver`, async f => {
        const observation = f.begin()
        f.state.postMessage = f.failPost
        f.state.onInvalidate = () => {
            f.state.onInvalidate = () => {}
            if (replacement === 'close') f.state.close()
            else f.state.setAccountPresentation('2:1')
        }
        const original = watch(f.state.recoverHistoryReadingStatus(observation))
        await turn()
        answered(original, false, 'retired original observer')
        equal(f.state.ready, false, 'retirement never restores an old context')
        equal(f.state.accountPresentation, replacement === 'close' ? '1:1' : '2:1', 'selected account retained')
        equal(await f.state.recoverHistoryReadingStatus(observation), false, 'old proof cannot restart')
    })
}

for (const sameProof of [false, true]) {
    add(`cleanup replacement preserves a newer ${sameProof ? 'same-proof' : 'different-proof'} recovery`, async f => {
        const observation = f.begin(), nextProof = sameProof ? observation : proof('b')
        let successor, successorPromise
        f.state.postMessage = f.failPost
        f.state.onInvalidate = () => {
            f.state.onInvalidate = () => {}
            f.state.postMessage = request => f.requests.push(request)
            f.begin(nextProof)
            successorPromise = f.state.recoverHistoryReadingStatus(nextProof)
            successor = watch(successorPromise)
            throw new Error('Obsolete cleanup failed after replacement')
        }
        const original = watch(f.state.recoverHistoryReadingStatus(observation))
        await turn()
        answered(original, false, 'original recovery')
        equal(successor.settled, false, 'successor waits for its own reply')
        equal(f.state.recoverHistoryReadingStatus(nextProof), successorPromise, 'successor completion identity preserved')
        equal(f.requests.length, 2, 'only initial state and successor native read were sent')
        const request = f.requests.at(-1)
        equal(f.state.apply(request.requestID, f.reply(request, 2)), true, 'successor sample accepted')
        await turn()
        answered(successor, true, 'successor recovery')
        equal(f.state.ready, true, 'successor remains ready')
        equal(f.state.reacknowledgeHistoryReadingStatus(nextProof), true, 'successor proof retained')
    })
}

add('native rejection during request-ID generation settles without dispatch or a null-resolver throw', async f => {
    const observation = f.begin()
    f.state.makeRequestID = () => {
        equal(f.state.failHistoryReadingStatusRecovery(observation), true, 'original read rejected')
        return 'never-dispatched'
    }
    const original = watch(f.state.recoverHistoryReadingStatus(observation))
    await turn()
    answered(original, false, 'rejected preparation')
    equal(f.requests.length, 1, 'rejected preparation sent no read')
})

for (const accepted of [false, true]) {
    add(`synchronous ${accepted ? 'accepted' : 'rejected'} sample followed by bridge throw preserves its delivered result`, async f => {
        const observation = f.begin()
        f.state.postMessage = request => {
            f.requests.push(request)
            equal(f.state.apply(request.requestID, f.reply(request, 2, accepted)), accepted, 'sample accepted as intended')
            throw new Error('Wrapper failed after native delivery')
        }
        const original = watch(f.state.recoverHistoryReadingStatus(observation))
        await turn()
        answered(original, accepted, 'already delivered sample')
        equal(f.state.ready, accepted, 'publication status matches sample')
        equal(f.publications.length, accepted ? 2 : 1, 'no duplicate publication')
    })
}

add('a newer ordinary publication during failed cleanup retains its context and revision', async f => {
    const observation = f.begin()
    f.state.postMessage = f.failPost
    f.state.onInvalidate = () => {
        f.state.onInvalidate = () => {}
        f.state.postMessage = request => f.requests.push(request)
        f.state.relocate({ sectionURL: 'replacement.xhtml' })
        const request = f.requests.at(-1)
        equal(f.state.apply(request.requestID, f.reply(request, 3)), true, 'replacement published')
        throw new Error('Retired renderer cleanup failed')
    }
    const original = watch(f.state.recoverHistoryReadingStatus(observation))
    await turn()
    answered(original, false, 'original recovery')
    equal(f.state.ready, true, 'new document remains ready')
    equal(f.state.context.contextID, 'context-3', 'new native context retained')
    equal(f.state.state.revision, 3, 'new snapshot retained')
    equal(f.requests.length, 2, 'no extra retry or query')
})

for (const accepted of [false, true]) {
    add(`ordinary asynchronous recovery ${accepted ? 'success' : 'failure'} and duplicate coalescing are unchanged`, async f => {
        const observation = f.begin()
        const completion = f.state.recoverHistoryReadingStatus(observation)
        equal(f.state.recoverHistoryReadingStatus(observation), completion, 'duplicate joins exact promise')
        const original = watch(completion)
        await turn()
        equal(original.settled, false, 'native reply still required')
        equal(f.requests.length, 2, 'only one recovery query')
        const request = f.requests.at(-1)
        equal(f.state.apply(request.requestID, f.reply(request, 2, accepted)), accepted, 'native result accepted')
        await turn()
        answered(original, accepted, 'asynchronous completion')
        equal(f.state.ready, accepted, 'correct readiness')
    })
}

add('wrong recovery proof cannot invoke the bridge or alter the real observer', async f => {
    const observation = f.begin()
    equal(await f.state.recoverHistoryReadingStatus(proof('b')), false, 'wrong proof rejected')
    equal(f.requests.length, 1, 'wrong proof did not query')
    const completion = f.state.recoverHistoryReadingStatus(observation)
    const request = f.requests.at(-1)
    equal(f.state.apply(request.requestID, f.reply(request, 2)), true, 'correct sample accepted')
    equal(await completion, true, 'correct proof remains usable')
})

for (const outcome of ['success', 'cancelled', 'unavailable']) {
    add(`coordinator retains native ${outcome} and never replays a read after failed cleanup`, async f => {
        const commands = [], controls = [], notices = [], timers = new Map()
        let nextTimer = 0
        const coordinator = createNativeMarkReadRequestCoordinator({
            postMessage: message => commands.push(message), postControlMessage: message => controls.push(message),
            makeRequestID: () => 'setup-failure', lifecycleTarget: new EventTarget(),
            scheduleTimeout: callback => { timers.set(++nextTimer, callback); return nextTimer },
            cancelTimeout: timer => timers.delete(timer), onPending: state => notices.push(state),
            onRecovery: ({ observation, isCurrent }) => f.state.beginHistoryReadingStatusRecovery(observation, f.scope, isCurrent),
            onRecoveryQuery: observation => f.state.recoverHistoryReadingStatus(observation),
        })
        try {
            const command = coordinator.request({ sectionID: 'section-a', message: { desiredState: 'unmarked' } })
            const packet = commands[0]
            const observation = { requestID: packet.requestID, observationToken: packet.manualReadPendingObservationToken }
            equal(coordinator.settle({ requestID: packet.requestID, manualReadPendingProtocol: 1,
                manualReadPendingObservationToken: observation.observationToken,
                manualReadPendingHistoryRecovery: true, manualReadPendingOutcomeOnly: true,
                manualReadPendingPresentationAllowed: false,
                ...(outcome === 'unavailable' ? { manualReadPendingState: 'unavailable', errorCode: 'outcomeUnavailable' }
                    : { manualReadPendingState: 'finished', sectionId: 'section-a', success: outcome === 'success',
                        ...(outcome === 'cancelled' ? { errorCode: 'cancelled' } : {}) }),
            }), true, 'native command result accepted')
            const originalOutcome = await command
            let joined, reads = 0
            const invalidation = () => {
                // Native has already authorized this one read. A second local
                // observer joins it while renderer cleanup is failing.
                joined = watch(f.state.recoverHistoryReadingStatus(observation))
                throw new Error('Renderer cleanup unavailable')
            }
            // Recovery preparation also invalidates once. Arm the failing
            // callback only after that preparation, at native dispatch itself.
            f.state.onInvalidate = () => {}
            f.state.postMessage = () => { reads++; f.state.onInvalidate = invalidation; throw new Error('Native query unavailable') }
            equal(await coordinator.recoverHistoryReadingStatus(observation), false, 'coordinator reports failed refresh')
            await turn()
            answered(joined, false, 'joined Book observer')
            equal(await coordinator.recoverHistoryReadingStatus(observation), false, 'duplicate observes same failed attempt')
            equal(reads, 1, 'no query retry')
            equal(commands.length, 1, 'no native mutation replay')
            equal(controls.length, 0, 'no Cancel on committed/recovered command')
            equal(notices.at(-1).phase, 'recovery-failed', 'failure remains visible')
            equal(await command, originalOutcome, 'original command result identity retained')
            equal(originalOutcome.outcomeKnown, outcome !== 'unavailable', 'native knowledge retained')
            equal(originalOutcome.success, outcome === 'unavailable' ? undefined : outcome === 'success', 'native outcome retained')
        } finally { coordinator.close() }
        equal(timers.size, 0, 'coordinator timers released')
    })
}
