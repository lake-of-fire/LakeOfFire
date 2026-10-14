import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'
import { createNativeMarkReadRequestCoordinator, presentNativeMarkReadPending } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

// Shared by Node and the offline browser runner. Native command results,
// renderer ownership and read-only refresh completion are explicit collaborators.
const equal = (actual, expected, label) => {
    if (!Object.is(actual, expected)) throw new Error(`${label}: expected ${String(expected)}, got ${String(actual)}`)
}
const turn = () => new Promise(resolve => {
    const channel = new MessageChannel()
    channel.port1.onmessage = () => { channel.port1.close(); channel.port2.close(); resolve() }
    channel.port2.postMessage(null)
})
const watch = completion => {
    const state = { settled: false }
    completion.then(value => Object.assign(state, { settled: true, value }),
        error => Object.assign(state, { settled: true, error }))
    return state
}
const isFalse = (state, label) => {
    equal(state.settled, true, `${label} settled before the retired query returned`)
    equal(state.error, undefined, `${label} did not reject`)
    equal(state.value, false, `${label} denied stale presentation`)
}

function harness() {
    let nextTimer = 0
    const held = [], timers = new Map()
    const h = { messages: [], controls: [], notices: [], queries: [], preparations: [], cleanupEffects: [],
        query: () => true, prepare: () => true, recoveryCurrent: () => true,
        pendingEffect: () => {}, ownerCurrent: () => true }
    h.hold = () => {
        let resolve, reject
        const promise = new Promise((done, fail) => { resolve = done; reject = fail })
        const gate = { promise, resolve, reject }
        held.push(gate)
        return gate
    }
    h.coordinator = createNativeMarkReadRequestCoordinator({
        makeRequestID: () => 'recovery-lifetime',
        postMessage: message => h.messages.push(message),
        postControlMessage: message => h.controls.push(message),
        scheduleTimeout: callback => { const id = ++nextTimer; timers.set(id, callback); return id },
        cancelTimeout: id => timers.delete(id),
        lifecycleTarget: new EventTarget(),
        isOwnerCurrent: owner => h.ownerCurrent(owner),
        onPending: state => {
            h.notices.push({ ...state })
            if (globalThis.document?.body) presentNativeMarkReadPending(state)
            h.pendingEffect(state)
        },
        onRecovery: state => { h.preparations.push(state.observation); return h.prepare(state) },
        onRecoveryQuery: proof => { h.queries.push(proof.requestID); return h.query(proof) },
        onRecoveryIsCurrent: ({ owner }) => h.recoveryCurrent(owner),
    })
    h.begin = (owner = 'chapter-a') => {
        const completion = h.coordinator.request({ sectionID: owner, owner,
            context: { owner }, message: { desiredState: 'unmarked',
                topWindowURL: 'file:///book.epub', documentStartedAtMs: 42 } })
        const message = h.messages.at(-1)
        return { completion, message, proof: { requestID: message.requestID,
            observationToken: message.manualReadPendingObservationToken } }
    }
    h.finish = (request, { history = true, success = true, unavailable = false } = {}) => {
        const envelope = { requestID: request.message.requestID, manualReadPendingProtocol: 1,
            manualReadPendingObservationToken: request.proof.observationToken,
            manualReadPendingState: unavailable ? 'unavailable' : 'finished',
            ...(history ? { manualReadPendingHistoryRecovery: true,
                manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false } : {}) }
        return h.coordinator.settle(unavailable
            ? { ...envelope, errorCode: 'outcomeUnavailable' }
            : { ...envelope, sectionId: request.message.sectionId, success,
                ...(success ? {} : { errorCode: 'cancelled' }) })
    }
    h.recovery = async (owner, options) => {
        const request = h.begin(owner)
        equal(h.finish(request, options), true, 'native history terminal admitted')
        request.outcome = await request.completion
        return request
    }
    h.observe = request => watch(h.coordinator.recoverHistoryReadingStatus(request.proof))
    h.cleanup = async () => {
        for (const gate of held) gate.resolve(false)
        h.coordinator.close()
        for (const cleanup of h.cleanupEffects) cleanup()
        await turn()
        equal(timers.size, 0, 'owned timers cleaned up')
        if (globalThis.document?.body) equal(document.querySelectorAll('.mnb-native-mark-pending').length,
            0, 'production pending notices cleaned up')
    }
    return h
}
const scenario = run => async () => {
    const h = harness()
    try { await run(h) } finally { await h.cleanup() }
}
export const recoveryLifetimeCases = []
const add = (name, run) => recoveryLifetimeCases.push([name, scenario(run)])

for (const retirement of ['close', 'retireHistoryRecoveries']) {
    for (const outcome of ['success', 'cancelled', 'unavailable']) {
        add(`${retirement}: held refresh releases all callers and preserves native ${outcome}`, async h => {
            const gate = h.hold()
            h.query = () => gate.promise
            const request = await h.recovery('chapter-a', { success: outcome === 'success',
                unavailable: outcome === 'unavailable' })
            const first = h.observe(request), joined = h.observe(request)
            await turn()
            equal(h.queries.length, 1, 'duplicate callers share one refresh')
            h.coordinator[retirement]()
            const noticeCount = h.notices.length
            await turn()
            isFalse(first, 'original caller'); isFalse(joined, 'joined caller')
            equal(h.coordinator.ownsHistoryReadingStatusRecovery(request.proof), false, 'old proof retired')
            equal(h.controls.length, 0, 'retirement did not send Cancel or replay')
            equal(h.messages.length, 1, 'exactly one original mutation')
            equal(request.outcome.outcomeKnown, outcome !== 'unavailable', 'native outcome knowledge preserved')
            equal(request.outcome.success, outcome === 'unavailable' ? undefined : outcome === 'success', 'native success preserved')
            gate.resolve(true)
            await turn()
            equal(h.notices.length, noticeCount, 'late refresh cannot repaint')
            equal(h.coordinator.failHistoryReadingStatusRecovery(request.proof), false, 'late failure cannot resurrect proof')
        })
    }
    add(`${retirement}: queued recoveries settle without dispatch behind a held refresh`, async h => {
        const gate = h.hold()
        h.query = () => gate.promise
        const a = h.begin('a'), b = h.begin('b')
        h.finish(a); h.finish(b)
        await Promise.all([a.completion, b.completion])
        const first = h.observe(a), queued = h.observe(b)
        await turn()
        equal(h.queries.length, 1, 'second query waits for first')
        h.coordinator[retirement]()
        await turn()
        isFalse(first, 'active caller'); isFalse(queued, 'queued caller')
        equal(h.queries.length, 1, 'retired queued refresh was not dispatched')
    })
    add(`${retirement}: retirement before dispatch refuses the queued query`, async h => {
        const request = await h.recovery('a')
        const observer = h.observe(request)
        h.coordinator[retirement]()
        await turn()
        isFalse(observer, 'queued caller')
        equal(h.queries.length, 0, 'no dispatch after retirement')
    })
    add(`${retirement}: waiting for an ordinary sibling does not delay retirement`, async h => {
        const a = h.begin('a'), b = h.begin('b')
        h.finish(a)
        await a.completion
        const observer = h.observe(a), sibling = watch(b.completion)
        await turn()
        equal(h.queries.length, 0, 'ordinary sibling gates recovery')
        h.coordinator[retirement]()
        await turn()
        isFalse(observer, 'waiting caller')
        if (retirement === 'retireHistoryRecoveries') {
            equal(sibling.settled, false, 'ordinary sibling still owns its outcome')
            h.finish(b, { history: false })
            equal((await b.completion).success, true, 'sibling native success preserved')
        } else {
            equal(sibling.error?.code, 'readerClosed', 'close rejects only unknown ordinary outcome')
        }
        equal(h.queries.length, 0, 'retired query cannot restart when sibling leaves')
    })
}

add('retiring a held refresh allows a new chapter recovery before the old query returns', async h => {
    const old = h.hold(), next = h.hold()
    const a = await h.recovery('a')
    h.query = proof => proof.requestID === a.proof.requestID ? old.promise : next.promise
    const first = h.observe(a)
    await turn()
    h.coordinator.retireHistoryRecoveries()
    const b = await h.recovery('b'), second = h.observe(b)
    await turn()
    isFalse(first, 'old caller')
    equal(h.queries.length, 2, 'new chapter not blocked by retired query')
    equal(second.settled, false, 'new chapter waits for its own refresh')
    old.resolve(true)
    await turn()
    equal(second.settled, false, 'old success cannot acknowledge new query')
    next.resolve(true)
    await turn()
    equal(second.value, true, 'new chapter acknowledged its own sample')
    equal(h.coordinator.ownsHistoryReadingStatusRecovery(b.proof), true, 'new proof retained')
})

add('a new command pruning an obsolete chapter releases that chapter refresh waiters', async h => {
    const gate = h.hold(), a = await h.recovery('a')
    h.query = proof => proof.requestID === a.proof.requestID ? gate.promise : true
    const old = h.observe(a)
    await turn()
    h.recoveryCurrent = owner => owner !== 'a'
    const b = await h.recovery('b'), current = h.observe(b)
    await turn()
    isFalse(old, 'pruned caller')
    equal(h.queries.length, 2, 'replacement chapter query dispatched')
    equal(current.value, true, 'replacement chapter acknowledged')
    gate.reject(new Error('obsolete query failed'))
    await turn()
    equal(h.coordinator.ownsHistoryReadingStatusRecovery(b.proof), true, 'late rejection preserves new proof')
})

add('retirement cleanup reentry preserves a successor recovery and its queue', async h => {
    const gate = h.hold(), a = await h.recovery('a')
    h.query = proof => proof.requestID === a.proof.requestID ? gate.promise : true
    const old = h.observe(a)
    await turn()
    let replacement, successor
    h.pendingEffect = state => {
        if (state.phase !== 'finished' || state.requestID !== a.proof.requestID || replacement) return
        replacement = h.begin('b')
        h.finish(replacement)
        successor = h.observe(replacement)
    }
    h.coordinator.retireHistoryRecoveries()
    await turn()
    isFalse(old, 'retired caller')
    equal(h.queries.length, 2, 'reentrant successor query dispatched')
    equal(successor?.value, true, 'reentrant successor acknowledged')
    equal(h.coordinator.ownsHistoryReadingStatusRecovery(replacement.proof), true, 'successor proof preserved')
})

add('retirement inside query dispatch releases the caller even if the query never answers', async h => {
    const gate = h.hold(), a = await h.recovery('a')
    h.query = () => { h.coordinator.close(); return gate.promise }
    const observer = h.observe(a)
    await turn()
    isFalse(observer, 'dispatch caller')
    equal(h.queries.length, 1, 'one admitted query')
    equal(a.outcome.success, true, 'native success unchanged')
})

add('live recoveries remain serialized and duplicate callers join the actual result', async h => {
    const gate = h.hold(), a = h.begin('a'), b = h.begin('b')
    h.finish(a); h.finish(b)
    await Promise.all([a.completion, b.completion])
    h.query = proof => proof.requestID === a.proof.requestID ? gate.promise : true
    const first = h.observe(a), joined = h.observe(a), second = h.observe(b)
    await turn()
    equal(h.queries.length, 1, 'only first query dispatched')
    equal(first.settled, false, 'original caller waits')
    equal(second.settled, false, 'second caller waits')
    gate.resolve(true)
    await turn()
    equal(first.value, true, 'first accepted'); equal(joined.value, true, 'joined accepted')
    equal(second.value, true, 'second accepted')
    equal(h.queries.length, 2, 'one query per proof')
})

for (const response of ['false', 'throw', 'reject']) {
    add(`live query ${response} retains existing failure and no-retry behavior`, async h => {
        const a = await h.recovery('a')
        h.query = () => {
            if (response === 'throw') throw new Error('query failed')
            if (response === 'reject') return Promise.reject(new Error('query failed'))
            return false
        }
        equal(await h.coordinator.recoverHistoryReadingStatus(a.proof), false, 'failure is not acknowledgement')
        equal(h.notices.at(-1).phase, 'recovery-failed', 'failure remains visible')
        equal(await h.coordinator.recoverHistoryReadingStatus(a.proof), false, 'duplicate observes original failure')
        equal(h.queries.length, 1, 'failure does not replay query')
        equal(a.outcome.success, true, 'native success retained')
    })
}

add('invalid proof does not join or retire a live recovery', async h => {
    const gate = h.hold(), a = await h.recovery('a')
    h.query = () => gate.promise
    const original = h.observe(a)
    await turn()
    equal(await h.coordinator.recoverHistoryReadingStatus({ ...a.proof, observationToken: 'wrong' }), false, 'wrong token rejected')
    equal(await h.coordinator.recoverHistoryReadingStatus({ ...a.proof, extra: true }), false, 'extra proof field rejected')
    equal(original.settled, false, 'valid original still waits')
    gate.resolve(true)
    await turn()
    equal(original.value, true, 'valid original succeeds')
    equal(h.queries.length, 1, 'only authenticated query dispatched')
})

add('pause and resume alone do not retire an admitted recovery', async h => {
    const gate = h.hold(), request = await h.recovery('a')
    h.query = () => gate.promise
    const observer = h.observe(request)
    await turn()
    h.coordinator.pause(); h.coordinator.resume()
    await turn()
    equal(observer.settled, false, 'restorable observation still waits')
    equal(h.queries.length, 1, 'resume did not duplicate query')
    gate.resolve(true)
    await turn()
    equal(observer.value, true, 'same recovery can still succeed')
})

add('preparation failure settles without a query and keeps original failure semantics', async h => {
    h.prepare = () => false
    const request = await h.recovery('a')
    equal(await h.coordinator.recoverHistoryReadingStatus(request.proof), false, 'failed preparation rejected')
    equal(h.queries.length, 0, 'failed preparation cannot query')
    equal(h.notices.at(-1).phase, 'recovery-failed', 'original recovery failure retained')
    h.coordinator.retireHistoryRecoveries()
    equal(h.coordinator.ownsHistoryReadingStatusRecovery(request.proof), false, 'failed proof retired')
    equal(request.outcome.success, true, 'native outcome still successful')
})

add('throwing notice cleanup cannot prevent retirement of active and queued waiters', async h => {
    const gate = h.hold(), a = h.begin('a'), b = h.begin('b')
    h.finish(a); h.finish(b)
    await Promise.all([a.completion, b.completion])
    h.query = () => gate.promise
    const first = h.observe(a), second = h.observe(b)
    await turn()
    h.pendingEffect = () => { throw new Error('notice cleanup failed') }
    h.coordinator.retireHistoryRecoveries()
    await turn()
    isFalse(first, 'active caller'); isFalse(second, 'queued caller')
    equal(h.queries.length, 1, 'queued query stayed retired')
})

add('already completed proof is retired without changing the delivered result', async h => {
    const request = await h.recovery('a')
    const result = await h.coordinator.recoverHistoryReadingStatus(request.proof)
    equal(result, true, 'sample was acknowledged')
    h.coordinator.retireHistoryRecoveries()
    equal(result, true, 'already delivered acknowledgement remains truthful')
    equal(h.coordinator.ownsHistoryReadingStatusRecovery(request.proof), false, 'completed proof cleared')
    equal(h.coordinator.failHistoryReadingStatusRecovery(request.proof), false, 'completed proof cannot be restored')
    equal(h.messages.length, 1, 'no command replay')
})

add('repeated chapter replacement releases each generation without borrowing the final acknowledgement', async h => {
    const generations = []
    for (let index = 0; index < 24; index++) {
        const gate = h.hold(), request = await h.recovery(`chapter-${index}`)
        h.query = () => gate.promise
        const observer = h.observe(request)
        await turn()
        equal(h.queries.length, index + 1, 'current generation can query before obsolete queries answer')
        h.coordinator.retireHistoryRecoveries()
        await turn()
        isFalse(observer, 'replaced generation')
        generations.push({ gate, request, observer })
    }
    h.query = () => true
    const final = await h.recovery('final')
    equal(await h.coordinator.recoverHistoryReadingStatus(final.proof), true, 'final generation acknowledged')
    const noticeCount = h.notices.length
    for (const [index, { gate }] of generations.reverse().entries()) {
        if (index % 2) gate.reject(new Error('old query rejected'))
        else gate.resolve(true)
    }
    await turn()
    equal(h.notices.length, noticeCount, 'old settlements cannot publish')
    equal(h.coordinator.ownsHistoryReadingStatusRecovery(final.proof), true, 'final proof retained')
    equal(h.queries.length, 25, 'exactly one query per generation')
    equal(h.controls.length, 0, 'no cancellation or retry traffic')
})

add('retirement releases a query returning a pending thenable without reentering it', async h => {
    const gate = h.hold(), request = await h.recovery('a')
    let entries = 0
    h.query = () => ({ then(resolve, reject) { entries++; gate.promise.then(resolve, reject) } })
    const observer = h.observe(request)
    await turn()
    h.coordinator.close()
    await turn()
    isFalse(observer, 'thenable caller')
    equal(entries, 1, 'one thenable adoption')
    gate.reject(new Error('late thenable rejection'))
    await turn()
    equal(entries, 1, 'no thenable replay')
})

add('pruning a held recovery does not settle the newly admitted ordinary command', async h => {
    const gate = h.hold(), old = await h.recovery('old')
    h.query = () => gate.promise
    const observer = h.observe(old)
    await turn()
    h.recoveryCurrent = owner => owner !== 'old'
    const fresh = h.begin('fresh'), freshResult = watch(fresh.completion)
    await turn()
    isFalse(observer, 'old refresh')
    equal(freshResult.settled, false, 'new native command still pending')
    equal(h.coordinator.pendingCount, 1, 'new command is retained')
    h.finish(fresh, { history: false })
    const outcome = await fresh.completion
    equal(outcome.success, true, 'new native success delivered')
    equal(outcome.presentationAllowed, true, 'old recovery did not revoke current presentation')
    gate.resolve(true)
    await turn()
    equal(h.coordinator.pendingCount, 0, 'old query did not recreate a pending command')
})

// Compose the complete production Book controller too. Only its native sample
// transport is held; no substitute controller or copied recovery method is used.
function installBookController(h) {
    const samples = [], publications = []
    const scope = { articleProgressID: 'article', articleEpochID: null,
        chapterKey: 'a'.repeat(64), chapterEpochID: null }
    const sectionURL = 'ebook://book/chapter.xhtml'
    const state = new BookReadingStateController({
        documentStartedAtMs: 42, topWindowURL: 'file:///book.epub',
        requiresAccountPresentation: true,
        postMessage: message => samples.push(message),
        onState: projection => publications.push(projection),
    })
    h.cleanupEffects.push(() => state.close())
    state.setAccountPresentation('1:1')
    state.relocate({ sectionURL, isEndPage: false })
    const reply = (request, revision) => ({ ok: true, accountPresentation: '1:1',
        location: { sectionURL, isEndPage: false, locationRevision: request.locationRevision },
        ...(request.historyRecoveryObservation
            ? { historyRecoveryObservation: request.historyRecoveryObservation } : {}),
        state: { articleProgressID: scope.articleProgressID, articleEpochID: null, scope,
            revision, finished: false, bookReadPresence: 'present', chapterReadPresence: 'present',
            readSegmentIdentifiers: ['word'], sentenceIdentifiersRead: [] },
        context: { contextID: `context-${revision}`, isEndPage: false, sectionLocation: sectionURL,
            articleProgressID: scope.articleProgressID, articleEpochID: null, scope },
    })
    equal(state.apply(samples[0].requestID, reply(samples[0], 1)), true, 'initial native Book sample accepted')
    h.prepare = ({ observation, isCurrent }) => state.beginHistoryReadingStatusRecovery(observation, scope, isCurrent)
    h.query = proof => state.recoverHistoryReadingStatus(proof)
    return { state, samples, publications, reply }
}

add('coordinator retirement releases a real Book query before the Book controller is cleaned up', async h => {
    const book = installBookController(h), request = await h.recovery('a')
    const observer = h.observe(request)
    await turn()
    equal(book.samples.length, 2, 'exactly one real recovery sample requested')
    const sample = book.samples[1]
    h.coordinator.retireHistoryRecoveries()
    await turn()
    isFalse(observer, 'coordinator caller')
    equal(book.state.ready, false, 'retirement does not manufacture ready Book state')
    equal(book.state.apply(sample.requestID, book.reply(sample, 2)), false, 'late real Book sample rejected')
    await turn()
    equal(book.publications.length, 1, 'only initial native sample published')
    equal(request.outcome.success, true, 'original native inverse remains successful')
})

add('replacement recovery reaches the real Book controller without an old native reply', async h => {
    const book = installBookController(h), old = await h.recovery('old')
    const first = h.observe(old)
    await turn()
    const oldSample = book.samples[1]
    h.coordinator.retireHistoryRecoveries()
    const fresh = await h.recovery('fresh'), second = h.observe(fresh)
    await turn()
    isFalse(first, 'original real Book caller')
    equal(book.samples.length, 3, 'successor sample dispatch is not blocked by old native read')
    equal(second.settled, false, 'successor still needs its own native sample')
    equal(book.state.apply(oldSample.requestID, book.reply(oldSample, 2)), false, 'old response cannot take successor slot')
    const freshSample = book.samples[2]
    equal(book.state.apply(freshSample.requestID, book.reply(freshSample, 3)), true, 'successor native sample accepted')
    await turn()
    equal(second.value, true, 'successor recovery acknowledged')
    equal(book.state.state.revision, 3, 'successor revision retained')
    equal(book.state.ready, true, 'real Book readiness restored')
    equal(h.coordinator.ownsHistoryReadingStatusRecovery(fresh.proof), true, 'successor coordinator proof retained')
    equal(book.state.reacknowledgeHistoryReadingStatus(fresh.proof), true, 'successor Book acknowledgement retained')
    equal(h.messages.length, 2, 'each originating command submitted only once')
    equal(h.controls.length, 0, 'no mutation replay or Cancel')
})

add('ordinary Book-controller relocation retains its existing recovery-release behavior', async h => {
    const book = installBookController(h), request = await h.recovery('a')
    const observer = h.observe(request)
    await turn()
    book.state.relocate({ sectionURL: 'ebook://book/next.xhtml', isEndPage: false })
    await turn()
    isFalse(observer, 'relocated Book caller')
    equal(book.state.ready, false, 'next location still awaits its own native sample')
    equal(book.publications.length, 1, 'relocation does not reuse old projection')
    equal(request.outcome.success, true, 'original command outcome unchanged')
})

// Pruning may remove only a queued obsolete chapter while an earlier query is
// still current. Retirement releases callers, not that live predecessor's turn.
for (const queuedBeforePruning of [true, false]) {
    for (let mask = 1; mask < 8; mask++) {
        add(`selective retirement mask ${mask}, queued before pruning ${queuedBeforePruning}: retain every live predecessor`, async h => {
            const requests = ['a', 'b', 'c', 'd', 'e'].map(owner => h.begin(owner))
            for (const request of requests) h.finish(request)
            const outcomes = await Promise.all(requests.map(request => request.completion))
            const gates = requests.map(() => h.hold())
            h.query = proof => gates[requests.findIndex(request => request.proof.requestID === proof.requestID)].promise
            const observers = [h.observe(requests[0])]
            await turn()
            // Queue B in either ordering. C/D may be enqueued before or after
            // request() prunes their stale owners. E always arrives afterward.
            observers[1] = h.observe(requests[1])
            if (queuedBeforePruning) {
                observers[2] = h.observe(requests[2]); observers[3] = h.observe(requests[3])
            }
            const retired = new Set(['b', 'c', 'd'].filter((_, index) => mask & (1 << index)))
            h.recoveryCurrent = owner => !retired.has(owner)
            const refused = await h.coordinator.request({ sectionID: 'unadmitted', message: { desiredState: 'marked' } })
            equal(refused.errorCode, 'pendingCapacityExceeded', 'live recoveries continue to gate new commands')
            if (!queuedBeforePruning) {
                observers[2] = h.observe(requests[2]); observers[3] = h.observe(requests[3])
            }
            observers[4] = h.observe(requests[4])
            await turn()
            for (let index = 1; index < 4; index++) {
                if (retired.has(['a', 'b', 'c', 'd', 'e'][index])) isFalse(observers[index], 'pruned queued caller')
            }
            equal(h.queries.join(','), requests[0].proof.requestID,
                'pruning a queued recovery cannot dispatch past the still-live first query')
            const live = [0, ...[1, 2, 3].filter(index => !(mask & (1 << (index - 1)))), 4]
            for (const [position, index] of live.entries()) {
                equal(h.queries.length, position + 1, 'only one live query dispatched at a time')
                equal(h.queries[position], requests[index].proof.requestID, 'live queries preserve submission order')
                equal(observers[index].settled, false, 'current query still needs its own native reply')
                gates[index].resolve(true)
                await turn()
                equal(observers[index].value, true, 'matching native sample acknowledged')
            }
            equal(h.queries.length, live.length, 'retired queued queries never reached native')
            equal(outcomes.every(outcome => outcome.success && outcome.outcomeKnown), true,
                'all original native command results remain successful')
            equal(h.messages.length, 5, 'pruning and recovery cannot replay a mutation')
            equal(h.controls.length, 0, 'no cancellation or retry traffic')
        })
    }
}

add('selective queued retirement preserves the first real Book sample until its acknowledgement', async h => {
    const book = installBookController(h)
    const a = h.begin('current-a'), b = h.begin('obsolete-b'), c = h.begin('current-c')
    h.finish(a); h.finish(b); h.finish(c)
    const outcomes = await Promise.all([a.completion, b.completion, c.completion])
    const first = h.observe(a)
    await turn()
    const firstSample = book.samples[1]
    equal(book.samples.length, 2, 'first recovery reached the real Book controller')
    const retired = h.observe(b)
    h.recoveryCurrent = owner => owner !== 'obsolete-b'
    const refused = await h.coordinator.request({ sectionID: 'unadmitted', message: {} })
    equal(refused.errorCode, 'pendingCapacityExceeded', 'current recovery still gates command admission')
    const last = h.observe(c)
    await turn()
    isFalse(retired, 'obsolete queued caller')
    const sampleCountBeforeReply = book.samples.length, firstWasPending = !first.settled
    equal(book.state.apply(firstSample.requestID, book.reply(firstSample, 2)), true,
        'first correlated native Book sample remains admissible')
    equal(sampleCountBeforeReply, 2, 'later recovery did not replace the first Book request')
    equal(firstWasPending, true, 'first Book recovery still waited for its own sample')
    await turn()
    equal(first.value, true, 'first sample is acknowledged before later preparation')
    equal(book.samples.length, 3, 'later Book recovery starts after first acknowledgement')
    const lastSample = book.samples[2]
    equal(lastSample.historyRecoveryObservation.requestID, c.proof.requestID, 'later sample belongs to C, not B')
    equal(book.state.apply(lastSample.requestID, book.reply(lastSample, 3)), true, 'C sample accepted')
    await turn()
    equal(last.value, true, 'C acknowledged its own sample')
    equal(book.publications.map(value => value.revision).join(','), '1,2,3', 'both live samples published in order')
    equal(book.state.ready, true, 'Book controls are ready after the final recovery')
    equal(outcomes.every(value => value.success && value.outcomeKnown), true, 'original mutations remain successful')
    equal(h.messages.length, 3, 'no additional mutation')
    equal(h.controls.length, 0, 'no Cancel or retry')
})

add('selectively retiring the active query still releases a live queued successor immediately', async h => {
    const a = h.begin('obsolete-a'), b = h.begin('current-b')
    h.finish(a); h.finish(b)
    await Promise.all([a.completion, b.completion])
    const gate = h.hold()
    h.query = proof => proof.requestID === a.proof.requestID ? gate.promise : true
    const first = h.observe(a)
    await turn()
    const second = h.observe(b)
    h.recoveryCurrent = owner => owner !== 'obsolete-a'
    await h.coordinator.request({ sectionID: 'unadmitted', message: {} })
    await turn()
    isFalse(first, 'retired active caller')
    equal(second.value, true, 'live successor does not wait for the obsolete read')
    equal(h.queries.join(','), [a, b].map(value => value.proof.requestID).join(','), 'one query per proof')
    const notices = h.notices.length
    gate.resolve(true)
    await turn()
    equal(h.notices.length, notices, 'late retired success cannot repaint')
    equal(h.coordinator.ownsHistoryReadingStatusRecovery(b.proof), true, 'live successor proof remains valid')
})

add('recovery queued during pruning cleanup cannot bypass a live predecessor', async h => {
    const a = h.begin('a'), b = h.begin('b'), c = h.begin('c')
    h.finish(a); h.finish(b); h.finish(c)
    await Promise.all([a.completion, b.completion, c.completion])
    const gate = h.hold()
    h.query = proof => proof.requestID === a.proof.requestID ? gate.promise : true
    const first = h.observe(a)
    await turn()
    const retired = h.observe(b)
    let last
    h.pendingEffect = state => {
        if (state.requestID === b.proof.requestID && state.phase === 'finished') last ??= h.observe(c)
    }
    h.recoveryCurrent = owner => owner !== 'b'
    await h.coordinator.request({ sectionID: 'unadmitted', message: {} })
    await turn()
    isFalse(retired, 'retired queued caller')
    equal(last?.settled, false, 'reentrant successor remains behind first recovery')
    equal(h.queries.length, 1, 'cleanup did not dispatch out of order')
    gate.resolve(true)
    await turn()
    equal(first.value, true, 'first query acknowledged')
    equal(last.value, true, 'reentrant successor acknowledged afterward')
    equal(h.queries.join(','), [a, c].map(value => value.proof.requestID).join(','), 'live queue order retained')
})

add('a live predecessor rejection releases later work only after that rejection', async h => {
    const a = h.begin('a'), b = h.begin('b'), c = h.begin('c')
    h.finish(a); h.finish(b); h.finish(c)
    const outcomes = await Promise.all([a.completion, b.completion, c.completion])
    const gate = h.hold()
    h.query = proof => proof.requestID === a.proof.requestID ? gate.promise : true
    const first = h.observe(a)
    await turn()
    const retired = h.observe(b)
    h.recoveryCurrent = owner => owner !== 'b'
    await h.coordinator.request({ sectionID: 'unadmitted', message: {} })
    const last = h.observe(c)
    await turn()
    isFalse(retired, 'pruned caller')
    equal(h.queries.length, 1, 'later query waits for first failure or success')
    gate.reject(new Error('first native sample failed'))
    await turn()
    equal(first.value, false, 'first query preserves failure result')
    equal(last.value, true, 'later query can recover after first failure')
    equal(outcomes.every(value => value.success), true, 'read-only failure cannot rewrite committed native outcomes')
    equal(h.queries.length, 2, 'no duplicate recovery attempt')
})
