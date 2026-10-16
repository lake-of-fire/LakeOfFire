import { installBookReadingRuntime } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-runtime.js'
import { createNativeMarkReadRequestCoordinator, refreshNativeMarkReadBookStateForRecovery } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

const equal = (actual, expected, message) => {
    if (!Object.is(actual, expected)) throw new Error(`${message}: expected ${String(expected)}, got ${String(actual)}`)
}
const turn = () => new Promise(resolve => {
    const channel = new MessageChannel()
    channel.port1.onmessage = () => { channel.port1.close(); channel.port2.close(); resolve() }
    channel.port2.postMessage(null)
})
class Element extends EventTarget {
    attributes = new Map(); children = []; nodes = new Map();
    classes = new Set(); hidden = false; inert = false; isConnected = true;
    classList = { add: value => this.classes.add(value), remove: value => this.classes.delete(value) };
    append(...children) { this.children.push(...children) }
    setAttribute(key, value) { this.attributes.set(key, value) }
    getAttribute(key) { return this.attributes.get(key) ?? null }
    removeAttribute(key) { this.attributes.delete(key) }
    querySelector(key) { if (!this.nodes.has(key)) this.nodes.set(key, new Element()); return this.nodes.get(key) }
    focus() {}
    remove() { this.isConnected = false }
}
function fixture() {
    // Node controls DOM allocation. The same cases use real elements and two
    // physical iframe Documents in Chromium; neither engine mocks a controller.
    const browser = !!globalThis.document?.createElement
    const root = browser ? document.createElement('div') : new Element()
    if (browser) document.body.append(root)
    const view = browser ? document.createElement('div') : new Element()
    root.append(view)
    const makeDocument = name => {
        if (!browser) return { location: { href: `ebook://fixture/${name}.xhtml` }, defaultView: {} }
        const iframe = document.createElement('iframe'); view.append(iframe)
        const doc = iframe.contentDocument
        doc.open(); doc.write('<!doctype html><body><p>Chapter text</p></body>'); doc.close()
        return doc
    }
    const a = makeDocument('a'), b = makeDocument('b')
    const requests = [], shell = [], mutations = [], controls = [], notices = [], timers = new Map()
    const rendered = []
    let handler = state => { rendered.push(state.revision); return true }, shellHandler = state => shell.push(state.revision)
    let invalidationHandler = () => {}
    a.defaultView.manabi_applyBookReadingPresentation = (...args) => handler(...args)
    a.defaultView.manabi_invalidateBookReadingScope = () => { a.defaultView.manabi_bookReadingScope = null }
    b.defaultView.manabi_invalidateBookReadingScope = () => { b.defaultView.manabi_bookReadingScope = null }
    view.renderer = { displayedIndex: 0, getContents: () => [{ index: 0, doc: a }, { index: 1, doc: b }] }
    view.book = { sections: [{ id: 'a.xhtml', linear: 'yes' }, { id: 'b.xhtml', linear: 'yes' }] }
    const reader = { view }
    const documentFixture = browser ? { createElement: name => document.createElement(name),
        getElementById: () => root, get activeElement() { return document.activeElement } }
        : { createElement: () => new Element(), getElementById: () => root, activeElement: new Element() }
    const windowFixture = { location: { href: 'ebook://fixture/book' }, webkit: { messageHandlers: {
        ebookBookAction: { postMessage: () => {} }, ebookBookReadingState: { postMessage: value => requests.push(value) },
    } } }
    const runtime = installBookReadingRuntime({ reader, view, document: documentFixture, window: windowFixture,
        documentStartedAtMs: 42, applyProjection: (...args) => shellHandler(...args),
        invalidateProjection: () => invalidationHandler(), onVisibility: () => {} })
    reader.bookReadingRuntime = runtime
    runtime.updateLocation()
    const scope = { articleProgressID: 'book', articleEpochID: 'pass', chapterKey: 'a'.repeat(64), chapterEpochID: null }
    const reply = (revision, request = requests.at(-1)) => ({ ok: true, accountPresentation: '1:1',
        location: { sectionURL: request.sectionURL, isEndPage: request.isEndPage, locationRevision: request.locationRevision },
        ...(request.historyRecoveryObservation ? { historyRecoveryObservation: request.historyRecoveryObservation } : {}),
        state: { revision, articleProgressID: 'book', articleEpochID: 'pass', scope: request.isEndPage ? null : scope,
            finished: false, bookReadPresence: 'present', chapterReadPresence: request.isEndPage ? 'empty' : 'present',
            readSegmentIdentifiers: request.isEndPage ? [] : [`segment-${revision}`], sentenceIdentifiersRead: [] },
        context: { contextID: `context-${revision}`, articleProgressID: 'book', articleEpochID: 'pass',
            scope: request.isEndPage ? null : scope, sectionLocation: request.isEndPage ? null : 'a.xhtml', isEndPage: request.isEndPage } })
    const publish = (revision, request = requests.at(-1)) => runtime.state.apply(request.requestID, reply(revision, request))
    equal(publish(1), true, 'initial native projection accepted')
    let timer = 0
    const coordinator = createNativeMarkReadRequestCoordinator({
        makeRequestID: () => 'delivery', lifecycleTarget: new EventTarget(),
        postMessage: value => mutations.push(value), postControlMessage: value => controls.push(value),
        scheduleTimeout: callback => { timers.set(++timer, callback); return timer },
        cancelTimeout: id => timers.delete(id), onPending: value => notices.push(value),
        onRecovery: ({ observation, isCurrent }) => refreshNativeMarkReadBookStateForRecovery(runtime, scope, isCurrent, observation),
        onRecoveryQuery: observation => runtime.state.recoverHistoryReadingStatus(observation),
    })
    const begin = async (kind = 'success', desiredState = 'unmarked') => {
        const completion = coordinator.request({ sectionID: 'section', message: { desiredState } })
        const packet = mutations.at(-1)
        const proof = { requestID: packet.requestID, observationToken: packet.manualReadPendingObservationToken }
        equal(coordinator.settle({ requestID: packet.requestID, manualReadPendingProtocol: 1,
            manualReadPendingObservationToken: proof.observationToken, manualReadPendingHistoryRecovery: true,
            manualReadPendingOutcomeOnly: true, manualReadPendingPresentationAllowed: false,
            ...(kind === 'unavailable' ? { manualReadPendingState: 'unavailable', errorCode: 'outcomeUnavailable' }
                : { sectionId: 'section', manualReadPendingState: 'finished', success: kind === 'success',
                    ...(kind === 'cancelled' ? { errorCode: 'cancelled' } : {}) }),
        }), true, 'original native outcome admitted')
        const outcome = await completion
        const recovery = coordinator.recoverHistoryReadingStatus(proof)
        await turn()
        equal(requests.length, 2, 'one authorized status read')
        return { completion, outcome, recovery, proof }
    }
    return { runtime, coordinator, a, b, view, requests, shell, rendered, mutations, controls, notices, scope, reply, publish, begin,
        setFrame: callback => { handler = callback }, setShell: callback => { shellHandler = callback },
        setInvalidation: callback => { invalidationHandler = callback },
        cleanup() { coordinator.close(); runtime.close(); root.remove(); equal(timers.size, 0, 'no retained timers') } }
}
export const bookReadingDeliveryCases = []
const add = (name, run) => bookReadingDeliveryCases.push([name, async () => {
    const f = fixture()
    try { await run(f) } finally { f.cleanup() }
}])

add('a declined frame projection cannot acknowledge successful Unmark recovery', async f => {
    const original = await f.begin()
    f.setFrame(() => false)
    equal(f.publish(2), false, 'declined frame publication is not acknowledged')
    equal(await original.recovery, false, 'read-only recovery fails')
    equal(f.runtime.state.ready, false, 'failed presentation cannot provide authoring context')
    equal(f.runtime.captureScope(f.a), null, 'failed frame receives no usable scope')
    equal(f.shell.join(','), '1', 'shell cannot claim that rejected frame was rendered')
    equal(original.outcome.success, true, 'native Unmark remains successful')
    equal(f.notices.at(-1).phase, 'recovery-failed', 'recovery guidance retained')
})

for (const desired of ['marked', 'unmarked']) {
    for (const kind of ['success', 'cancelled', 'unavailable']) {
        add(`${desired}: declined presentation preserves original native ${kind}`, async f => {
            const original = await f.begin(kind, desired)
            f.setFrame(() => false)
            equal(f.publish(2), false, 'failed frame cannot acknowledge')
            equal(await original.recovery, false, 'read-only recovery fails')
            equal(await f.coordinator.recoverHistoryReadingStatus(original.proof), false, 'duplicate cannot retry')
            equal(await original.completion, original.outcome, 'original outcome object retained')
            equal(original.outcome.outcomeKnown, kind !== 'unavailable', 'native outcome knowledge retained')
            equal(original.outcome.success, kind === 'unavailable' ? undefined : kind === 'success', 'native result retained')
            equal(f.runtime.state.reacknowledgeHistoryReadingStatus(original.proof), false, 'no false receiver acknowledgement')
            equal(f.requests.length, 2, 'no automatic status retry')
            equal(f.mutations.length, 1, 'no mutation replay')
            equal(f.controls.length, 0, 'no Cancel for joined native outcome')
        })
    }
}

for (const boundary of ['frame', 'shell']) {
    for (const failure of ['false', 'throw']) {
        add(`ordinary ${boundary} ${failure} withdraws only the failed publication`, async f => {
            const error = new Error('controlled publication failure')
            const reject = () => { if (failure === 'throw') throw error; return false }
            if (boundary === 'frame') f.setFrame(reject); else f.setShell(reject)
            f.runtime.state.refresh()
            const request = f.requests.at(-1)
            let accepted, thrown
            try { accepted = f.publish(2, request) } catch (value) { thrown = value }
            if (failure === 'throw') equal(thrown, error, 'original exception still propagates')
            else { equal(thrown, undefined, 'explicit false is not an exception'); equal(accepted, false, 'decline not acknowledged') }
            equal(f.runtime.state.ready, false, 'failed ordinary display cannot provide context')
            equal(f.runtime.state.state, null, 'failed cached projection withdrawn')
            equal(f.runtime.captureScope(f.a), null, 'no failed frame authoring scope')
            equal(f.a.defaultView.manabi_bookReadingScope, null, 'exposed scope withdrawn')
            equal(f.publish(9, request), false, 'failed request is not retained for late replies')
            f.setFrame(() => true); f.setShell(() => {})
            equal(f.runtime.state.refresh(), true, 'a new normal refresh remains supported')
            equal(f.publish(1), false, 'failed publication did not lower the native ordering floor')
            equal(f.publish(2), true, 'new request can publish the same native cut')
            equal(f.runtime.state.ready, true, 'readiness restored only by accepted delivery')
        })
    }
}

add('declined shell delivery keeps the original recovery barrier', async f => {
    const original = await f.begin()
    f.setShell(() => false)
    equal(f.publish(2), false, 'shell refusal propagated')
    equal(await original.recovery, false, 'original observer released')
    equal(f.runtime.state.ready, false, 'failed shell cannot provide action context')
    equal(f.runtime.state.refresh(), false, 'ordinary refresh cannot bypass the recovery barrier')
    equal(f.coordinator.ownsHistoryReadingStatusRecovery(original.proof), true, 'failed original proof remains owned')
    equal(f.requests.length, 2, 'no retry initiated by failure cleanup')
})

for (const failure of ['false', 'throw']) {
    add(`a newer publication survives the old frame's ${failure}`, async f => {
        const original = await f.begin()
        f.setFrame(() => {
            f.setFrame(() => true)
            f.runtime.state.refresh()
            equal(f.publish(3), true, 'new publication accepted inside old callback')
            if (failure === 'throw') throw new Error('old projection failed')
            return false
        })
        equal(f.publish(2, f.requests[1]), false, 'old callback cannot acknowledge the successor')
        equal(await original.recovery, false, 'old recovery denied')
        equal(f.runtime.state.ready, true, 'new native projection retained')
        equal(f.runtime.state.state.revision, 3, 'new snapshot preserved')
        equal(f.runtime.state.context.contextID, 'context-3', 'new context preserved')
        equal(f.shell.join(','), '1,3', 'only accepted successor reaches shell')
    })
}

add('a queued refresh cannot turn rejected recovery delivery into success', async f => {
    const original = await f.begin()
    let queued
    f.setFrame(() => {
        equal(f.runtime.state.refresh(), true, 'callback can queue an ordinary refresh')
        queued = f.requests.at(-1)
        return false
    })
    equal(f.publish(2, f.requests[1]), false, 'frame declined the original snapshot')
    equal(await original.recovery, false, 'original recovery rejected')
    equal(f.runtime.state.ready, false, 'queued read is not an accepted display')
    f.setFrame(() => true)
    equal(f.publish(3, queued), false, 'unqualified queued read cannot bypass restored recovery')
    equal(f.runtime.state.refresh(), false, 'recovery continues to require native authorization')
    equal(f.controls.length, 0, 'cleanup does not cancel a native mutation')
})

for (const value of ['true', 'void', 'missing']) {
    add(`${value} frame callback preserves compatible recovery delivery`, async f => {
        const original = await f.begin()
        if (value === 'missing') delete f.a.defaultView.manabi_applyBookReadingPresentation
        else f.setFrame(() => value === 'true' ? true : undefined)
        equal(f.publish(2), true, 'compatible callback admitted')
        equal(await original.recovery, true, 'matching native sample acknowledged')
        equal(f.runtime.state.ready, true, 'accepted context available')
        equal(f.shell.join(','), '1,2', 'accepted sample reaches shell')
        equal(f.notices.at(-1).phase, 'finished', 'recovery completes normally')
        equal(f.requests.length, 2, 'no unnecessary query')
    })
}

add('endcap publication does not ask a hidden chapter to accept its scope-less state', async f => {
    let calls = 0
    f.setFrame(() => { calls++; return false })
    equal(f.runtime.endcap.enter(), true, 'endcap entered')
    equal(f.publish(2), true, 'endcap has its own native context')
    equal(calls, 0, 'hidden chapter not used as endcap acknowledgement')
    equal(f.runtime.state.ready, true, 'terminal Book action context available')
    equal(f.runtime.state.context.scope, null, 'endcap does not inherit chapter scope')
    equal(f.runtime.endcap.button.disabled, false, 'accepted endcap action remains enabled')
})

add('endcap shell refusal disables its failed Book action context', async f => {
    f.runtime.endcap.enter()
    f.setShell(() => false)
    equal(f.publish(2), false, 'failed endcap publication declined')
    equal(f.runtime.state.ready, false, 'failed endcap context withdrawn')
    equal(f.runtime.endcap.button.disabled, true, 'Finish cannot use the failed context')
})

for (const failure of ['false', 'throw']) {
    add(`ordinary ${failure} preserves a queued fresh read while withdrawing failed context`, async f => {
        let queued
        const error = new Error('original ordinary projection failed')
        f.runtime.state.refresh()
        const original = f.requests.at(-1)
        f.setFrame(() => {
            f.runtime.state.refresh()
            queued = f.requests.at(-1)
            if (failure === 'throw') throw error
            return false
        })
        let accepted, thrown
        try { accepted = f.publish(2, original) } catch (caught) { thrown = caught }
        if (failure === 'throw') equal(thrown, error, 'original throw preserved')
        else equal(accepted, false, 'original refusal preserved')
        equal(f.runtime.state.ready, false, 'failed context withdrawn until new sample')
        f.setFrame(() => true)
        equal(f.publish(3, queued), true, 'ordinary queued read retains its own response slot')
        equal(f.runtime.state.ready, true, 'new sample restores readiness')
        equal(f.runtime.state.state.revision, 3, 'new native revision retained')
        equal(f.requests.length, 3, 'no extra read needed to recover ordinary presentation')
    })
}

import { bookRecoveryFinalWithdrawalCases } from './book-recovery-final-withdrawal-cases.mjs'
bookReadingDeliveryCases.push(...bookRecoveryFinalWithdrawalCases)

// Run final withdrawal through the actual runtime invalidation adapter, not
// only a replaced controller callback. Native final rejection is controlled;
// the real runtime retires its frame scopes and previously captured events.
for (const kind of ['success', 'cancelled', 'unavailable']) {
    add(`runtime final withdrawal survives shell cleanup failure after native ${kind}`, async f => {
        const original = await f.begin(kind)
        equal(f.publish(2), true, 'original status delivered through the real frame adapter')
        equal(await original.recovery, true, 'original recovery acknowledged')
        const oldEvent = f.runtime.captureEvent(f.a)
        equal(f.runtime.isEventCurrent(oldEvent), true, 'accepted frame event is initially current')
        let cleanups = 0
        f.setInvalidation(() => {
            cleanups++
            equal(f.runtime.state.context, null, 'private Book context is already withdrawn')
            equal(f.a.defaultView.manabi_bookReadingScope, null, 'real runtime retired the active frame scope')
            equal(f.runtime.isEventCurrent(oldEvent), false, 'real runtime retired the captured event')
            throw new Error('Final shell cleanup failed')
        })
        equal(f.coordinator.ownsHistoryReadingStatusRecovery(original.proof), true, 'original coordinator proof retained')
        const withdrawn = f.runtime.state.failHistoryReadingStatusRecovery(original.proof)
        equal(withdrawn, true, 'owned Book withdrawal survives the shell failure')
        equal(withdrawn && f.coordinator.failHistoryReadingStatusRecovery(original.proof), true, 'coordinator receives final failure')
        equal(await f.coordinator.recoverHistoryReadingStatus(original.proof), false, 'cached positive result stays rejected')
        equal(f.notices.at(-1).phase, 'recovery-failed', 'failure guidance remains selected')
        equal(f.runtime.state.ready, false, 'no failed Book action context')
        equal(f.runtime.captureScope(f.a), null, 'no new authoring scope')
        equal(await original.completion, original.outcome, 'original native command outcome object preserved')
        equal(original.outcome.outcomeKnown, kind !== 'unavailable', 'native knowledge retained')
        equal(original.outcome.success, kind === 'unavailable' ? undefined : kind === 'success', 'native truth retained')
        equal(f.runtime.state.failHistoryReadingStatusRecovery(original.proof), true, 'repeated Book withdrawal is idempotent')
        equal(cleanups, 1, 'broken shell cleanup is not retried')
        equal(f.requests.length, 2, 'no extra native read')
        equal(f.mutations.length, 1, 'no mutation replay')
        equal(f.controls.length, 0, 'no cancellation for observed outcome')
    })
}

for (const replacement of ['renderer publication', 'recovery query']) {
    add(`runtime final withdrawal preserves a ${replacement} created by throwing shell cleanup`, async f => {
        const original = await f.begin()
        equal(f.publish(2), true, 'original status accepted')
        equal(await original.recovery, true, 'original status acknowledged')
        const oldEvent = f.runtime.captureEvent(f.a)
        const nextProof = { requestID: 'replacement-status', observationToken: 'b'.repeat(32) }
        let successor = null, cleanups = 0
        f.setInvalidation(() => {
            cleanups++
            f.setInvalidation(() => {})
            if (replacement === 'renderer publication') {
                f.view.renderer = { ...f.view.renderer }
                equal(f.runtime.updateLocation(), true, 'real renderer replacement is observed')
                equal(f.publish(3), true, 'replacement renderer receives its own native sample')
            } else {
                equal(f.runtime.state.beginHistoryReadingStatusRecovery(nextProof, f.scope), true, 'new recovery prepared')
                successor = f.runtime.state.recoverHistoryReadingStatus(nextProof)
            }
            throw new Error('Retired shell cleanup failed after replacement')
        })
        equal(f.runtime.state.failHistoryReadingStatusRecovery(original.proof), false, 'old failure cannot acknowledge successor withdrawal')
        equal(cleanups, 1, 'one original failing cleanup')
        equal(f.runtime.isEventCurrent(oldEvent), false, 'old runtime event remains retired')
        if (successor) {
            equal(f.runtime.state.ready, false, 'new query still needs native state')
            equal(f.runtime.state.recoverHistoryReadingStatus(nextProof), successor, 'new query completion retained')
            equal(f.publish(3), true, 'new recovery sample accepted')
            equal(await successor, true, 'new recovery receives its own result')
        }
        equal(f.runtime.state.ready, true, 'new publication remains usable')
        equal(f.runtime.state.state.revision, 3, 'new revision preserved')
        equal(f.runtime.isEventCurrent(f.runtime.captureEvent(f.a)), true, 'newly captured runtime event is current')
        equal(f.requests.length, 3, 'only explicitly selected replacement read')
        equal(f.mutations.length, 1, 'no replay of original Unmark')
        equal(f.controls.length, 0, 'no spurious cancellation')
    })
}

// A minimum snapshot sequence is an ordering floor, not an accepted replacement
// publication. The actual frame/shell adapter can stop after that floor changes.
for (const boundary of ['frame', 'shell']) {
    for (const failure of ['false', 'throw', 'interrupted']) {
        add(`${boundary} ${failure} after a snapshot-floor advance withdraws Unmark recovery`, async f => {
            const original = await f.begin()
            const request = f.requests[1]
            let event, queued, invalidations = 0
            f.setInvalidation(() => { invalidations++ })
            const update = () => {
                event = f.runtime.captureEvent(f.a)
                equal(f.runtime.isEventCurrent(event), true, 'fixture captured the being-delivered state')
                equal(f.runtime.state.noteManualReadSnapshot(3), true, 'new native floor observed')
                equal(f.runtime.state.refresh(), true, 'read queued, not published')
                queued = f.requests.at(-1)
                if (failure === 'throw') throw new Error('old snapshot delivery failed')
                if (failure === 'false') return false
                // The real runtime/controller must detect interrupted delivery
                // even when this collaborator returns normally.
            }
            if (boundary === 'frame') f.setFrame(update); else f.setShell(update)
            equal(f.publish(2, request), false, 'old sample cannot acknowledge the newer floor')
            equal(await original.recovery, false, 'original recovery caller settles false')
            equal(f.runtime.state.ready, false, 'rejected sample cannot keep Book actions ready')
            equal(f.runtime.state.context, null, 'rejected context withdrawn')
            equal(f.runtime.state.state, null, 'rejected sample withdrawn')
            equal(f.a.defaultView.manabi_bookReadingScope, null, 'real frame scope withdrawn')
            equal(f.runtime.isEventCurrent(event), false, 'event from failed delivery retired')
            equal(f.runtime.captureEvent(f.a), null, 'no new event can borrow the failed context')
            equal(invalidations, 1, 'one failure invalidation')
            equal(f.runtime.state.refresh(), false, 'ordinary reads cannot bypass restored recovery')
            f.setFrame(() => true); f.setShell(() => {})
            equal(f.publish(3, queued), false, 'queued ordinary reply has no recovery permission')
            equal(f.runtime.state.failHistoryReadingStatusRecovery(original.proof), true, 'original recovery barrier remains')
            equal(f.notices.at(-1).phase, 'recovery-failed', 'failure remains visible')
            equal(await original.completion, original.outcome, 'original native result object preserved')
            equal(original.outcome.success, true, 'accepted Unmark is not reported as failed')
            equal(f.mutations.length, 1, 'no mutation replay')
            equal(f.controls.length, 0, 'no cancellation')
            // A genuine new renderer selection can resume normal hydration, but
            // cannot reuse a snapshot below the advanced native floor.
            f.view.renderer = { ...f.view.renderer }
            equal(f.runtime.updateLocation(), true, 'new renderer selection admitted')
            equal(f.publish(2), false, 'minimum native snapshot was not rolled back')
            equal(f.publish(3), true, 'new matching sample restores readiness')
            equal(f.runtime.state.ready, true, 'new renderer remains usable')
        })
    }
}

for (const boundary of ['frame', 'shell']) {
    for (const failure of ['false', 'throw', 'interrupted']) {
        add(`ordinary ${boundary} ${failure} after a snapshot-floor advance preserves the queued read`, async f => {
            f.runtime.state.refresh()
            const request = f.requests.at(-1), error = new Error('ordinary delivery failed')
            let queued
            const update = () => {
                equal(f.runtime.state.noteManualReadSnapshot(4), true, 'minimum cut advanced')
                equal(f.runtime.state.refresh(), true, 'fresh ordinary read queued')
                queued = f.requests.at(-1)
                if (failure === 'throw') throw error
                if (failure === 'false') return false
            }
            if (boundary === 'frame') f.setFrame(update); else f.setShell(update)
            let accepted, thrown
            try { accepted = f.publish(2, request) } catch (value) { thrown = value }
            if (failure === 'throw') equal(thrown, error, 'ordinary exception identity retained')
            else { equal(thrown, undefined, 'no manufactured exception'); equal(accepted, false, 'interrupted delivery rejected') }
            equal(f.runtime.state.ready, false, 'unacknowledged state unavailable')
            equal(f.runtime.captureScope(f.a), null, 'failed frame cannot supply action scope')
            equal(f.a.defaultView.manabi_bookReadingScope, null, 'failed frame paint withdrawn')
            f.setFrame(() => true); f.setShell(() => {})
            equal(f.publish(3, queued), false, 'queued reply below native floor rejected')
            equal(f.publish(4, queued), true, 'same queued read retains valid response admission')
            equal(f.runtime.state.ready, true, 'valid successor restores readiness')
            equal(f.runtime.state.state.revision, 4, 'successor native revision retained')
            equal(f.requests.length, 3, 'no extra recovery query or retry')
            equal(f.mutations.length, 0, 'ordinary publication cannot submit a mutation')
        })
    }
}

for (const kind of ['cancelled', 'unavailable']) {
    add(`snapshot-floor interruption preserves original native ${kind}`, async f => {
        const original = await f.begin(kind, 'marked')
        f.setFrame(() => { f.runtime.state.noteManualReadSnapshot(3) })
        equal(f.publish(2), false, 'obsolete read-only sample rejected')
        equal(await original.recovery, false, 'read-only caller released')
        equal(f.runtime.state.ready, false, 'interrupted delivery is not ready')
        equal(await original.completion, original.outcome, 'original command completion retained')
        equal(original.outcome.outcomeKnown, kind !== 'unavailable', 'original outcome knowledge retained')
        equal(original.outcome.success, kind === 'unavailable' ? undefined : false, 'no invented write outcome')
        equal(f.mutations.length, 1, 'no second command')
        equal(f.controls.length, 0, 'no cancellation')
    })
}

for (const revision of [2, 3]) {
    for (const failure of ['false', 'throw']) {
        add(`floor advancement and old ${failure} preserve an actually published revision ${revision}`, async f => {
            const original = await f.begin()
            f.setFrame(() => {
                f.setFrame(() => true)
                equal(f.runtime.state.refresh(), true, 'successor read queued')
                equal(f.publish(revision), true, 'distinct successor really published, even at equal values')
                equal(f.runtime.state.noteManualReadSnapshot(4), true, 'later floor update retained')
                if (failure === 'throw') throw new Error('retired frame callback failed')
                return false
            })
            equal(f.publish(2, f.requests[1]), false, 'old callback cannot acknowledge successor')
            equal(await original.recovery, false, 'original caller remains rejected')
            equal(f.runtime.state.ready, true, 'actually accepted successor not withdrawn')
            equal(f.runtime.state.state.revision, revision, 'successor sample retained')
            equal(f.runtime.state.context.contextID, `context-${revision}`, 'successor context retained')
            equal(f.runtime.state.failHistoryReadingStatusRecovery(original.proof), false, 'old recovery cannot return')
            equal(f.runtime.isEventCurrent(f.runtime.captureEvent(f.a)), true, 'new successor event is usable')
            equal(f.runtime.state.refresh(), true, 'successor can request its next cut')
            equal(f.publish(3), false, 'floor remains 4')
            equal(f.publish(4), true, 'next valid cut accepted')
        })
    }
}

for (const replacement of ['renderer', 'account', 'recovery']) {
    add(`snapshot-floor interruption preserves a pending ${replacement} replacement`, async f => {
        const original = await f.begin()
        const nextProof = { requestID: 'next-recovery', observationToken: 'c'.repeat(32) }
        let completion
        f.setFrame(() => {
            equal(f.runtime.state.noteManualReadSnapshot(3), true, 'old floor advanced')
            if (replacement === 'renderer') {
                f.view.renderer = { ...f.view.renderer }
                equal(f.runtime.updateLocation(), true, 'new renderer selected')
            } else if (replacement === 'account') {
                equal(f.runtime.accountDidChange('2:1'), true, 'new account selected')
            } else {
                equal(f.runtime.state.beginHistoryReadingStatusRecovery(nextProof, f.scope), true, 'new recovery selected')
                completion = f.runtime.state.recoverHistoryReadingStatus(nextProof)
            }
            return false
        })
        equal(f.publish(2, f.requests[1]), false, 'old delivery rejected')
        equal(await original.recovery, false, 'old caller rejected')
        equal(f.runtime.state.ready, false, 'replacement still needs its own sample')
        f.setFrame(() => true)
        const request = f.requests.at(-1), result = f.reply(replacement === 'account' ? 1 : 3, request)
        if (replacement === 'account') result.accountPresentation = '2:1'
        equal(f.runtime.state.apply(request.requestID, result), true, 'replacement pending slot preserved')
        if (completion) equal(await completion, true, 'new recovery completion preserved')
        equal(f.runtime.state.ready, true, 'replacement becomes ready normally')
        equal(f.mutations.length, 1, 'no additional mutation')
    })
}

add('an unchanged snapshot floor does not withdraw successfully delivered recovery', async f => {
    const original = await f.begin()
    f.setFrame(() => { equal(f.runtime.state.noteManualReadSnapshot(2), true, 'same cut accepted') })
    equal(f.publish(2), true, 'unchanged floor does not invalidate delivery')
    equal(await original.recovery, true, 'original sample acknowledged')
    equal(f.runtime.state.ready, true, 'successful state remains ready')
    equal(f.notices.at(-1).phase, 'finished', 'normal recovery completes')
})

add('a floor-only update outside delivery preserves an already accepted sample', async f => {
    const event = f.runtime.captureEvent(f.a)
    equal(f.runtime.state.noteManualReadSnapshot(5), true, 'minimum future cut advanced')
    equal(f.runtime.state.ready, true, 'existing successful publication is not a failed delivery')
    equal(f.runtime.isEventCurrent(event), true, 'existing accepted event remains scoped')
    equal(f.runtime.state.refresh(), true, 'future sample requested')
    equal(f.publish(4), false, 'older incoming sample rejected')
    equal(f.runtime.state.state.revision, 1, 'accepted display retained while waiting')
    equal(f.publish(5), true, 'matching future cut accepted')
})

add('snapshot-floor failure cleanup preserves a successor published by invalidation', async f => {
    const original = await f.begin()
    let cleanups = 0
    f.setFrame(() => { f.runtime.state.noteManualReadSnapshot(3); return false })
    f.setInvalidation(() => {
        cleanups++
        f.setInvalidation(() => {}); f.setFrame(() => true)
        f.view.renderer = { ...f.view.renderer }
        equal(f.runtime.updateLocation(), true, 'cleanup selects a new renderer')
        equal(f.publish(4), true, 'cleanup successor actually published')
    })
    equal(f.publish(2, f.requests[1]), false, 'old delivery cannot acknowledge cleanup successor')
    equal(await original.recovery, false, 'old recovery settles false')
    equal(cleanups, 1, 'failed delivery cleanup ran exactly once')
    equal(f.runtime.state.ready, true, 'new successful publication remains ready')
    equal(f.runtime.state.state.revision, 4, 'cleanup successor retained')
    equal(f.runtime.state.failHistoryReadingStatusRecovery(original.proof), false, 'old barrier cannot replace successor')
})
