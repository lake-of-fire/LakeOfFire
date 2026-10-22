import {
    createNativeMarkReadRequestCoordinator,
    refreshNativeMarkReadBookStateForRecovery,
    presentNativeMarkReadPending,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'
import { BookReadingStateController, bookScopeKey }
    from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'

const check = (condition, message) => { if (!condition) throw new Error(message) }
const scope = chapter => ({ articleProgressID: 'article', articleEpochID: 'pass',
    chapterKey: chapter.repeat(64), chapterEpochID: null })
const url = chapter => `https://reader.invalid/${chapter}.xhtml`
const flush = async () => { for (let i = 0; i < 12; ++i) await Promise.resolve() }

// Real DOM and the complete production notice presenter, coordinator and Book
// controller. The native transport, ownership inputs and timers are controlled.
// Synthetic lifecycle events are not a BFCache or native WebKit reproduction.
function fixture() {
    const messages = [], controls = [], reads = [], timers = new Map()
    const events = new EventTarget()
    let coordinator, serial = 0, timer = 0, chapter = 'a', visible = true
    const state = new BookReadingStateController({
        postMessage: value => reads.push(value), makeRequestID: () => `state-${++serial}`,
        topWindowURL: 'ebook://ebook/load/local/book.epub', documentStartedAtMs: 100,
        requiresAccountPresentation: true,
        onInvalidate: () => coordinator?.cancelAll(),
    })
    const runtime = { state }
    const owns = ({ owner, context, message }) => owner.current
        && context.runtime === runtime && context.account === state.accountPresentation
        && message.pageURL === state.location?.sectionURL
        && (context.revision === undefined || context.revision === state.locationRevision)
        && (!state.context || bookScopeKey(state.context.scope) === bookScopeKey(owner.scope))
    let query = proof => state.recoverHistoryReadingStatus(proof), queries = 0
    coordinator = createNativeMarkReadRequestCoordinator({
        postMessage: value => messages.push(value), postControlMessage: value => controls.push(value),
        lifecycleTarget: events, onPending: presentNativeMarkReadPending,
        isOwnerCurrent: owner => visible && owner.current,
        scheduleTimeout: callback => { timers.set(++timer, callback); return timer },
        cancelTimeout: handle => timers.delete(handle),
        onRecoveryIsCurrent: owns,
        onRecovery: args => {
            if (!owns(args)) return false
            args.context.revision ??= state.locationRevision
            return refreshNativeMarkReadBookStateForRecovery(runtime, args.owner.scope,
                () => args.isCurrent() && owns(args), args.observation)
        },
        onRecoveryQuery: proof => { queries += 1; return query(proof) },
    })
    const notice = () => document.querySelector('.mnb-native-mark-pending')
    const accept = (revision = 1) => {
        const request = reads.at(-1)
        return state.apply(request.requestID, {
            ok: true, accountPresentation: state.accountPresentation,
            state: { revision, articleProgressID: 'article', articleEpochID: 'pass', scope: scope(chapter),
                finished: false, bookReadPresence: 'present', chapterReadPresence: 'present',
                readSegmentIdentifiers: ['segment'], sentenceIdentifiersRead: [] },
            context: { contextID: request.requestID, articleProgressID: 'article', articleEpochID: 'pass',
                scope: scope(chapter), isEndPage: false, sectionLocation: request.sectionURL },
            ...(request.historyRecoveryObservation ? {
                historyRecoveryObservation: request.historyRecoveryObservation,
                location: { sectionURL: request.sectionURL, isEndPage: false,
                    locationRevision: request.locationRevision },
            } : {}),
        })
    }
    state.setAccountPresentation('1:1')
    state.relocate({ sectionURL: url(chapter) })
    check(accept(), 'Initial native sample rejected')
    const start = () => {
        const completion = coordinator.request({ sectionID: `section-${messages.length}`,
            owner: { current: true, scope: scope(chapter) },
            context: { runtime, account: state.accountPresentation },
            message: { desiredState: 'unmarked', stableSegmentIDs: ['segment'], sentenceIdentifiers: [],
                pageURL: url(chapter), topWindowURL: 'ebook://ebook/load/local/book.epub',
                documentStartedAtMs: 100, bookReadingScope: scope(chapter) },
        })
        return { completion, message: messages.at(-1) }
    }
    const terminal = (message, success = true) => ({ requestID: message.requestID,
        sectionId: message.sectionId, manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: message.manualReadPendingObservationToken,
        manualReadPendingState: 'finished', success, ...(success ? {} : { errorCode: 'cancelled' }) })
    const hide = () => { visible = false; events.dispatchEvent(new Event('pagehide')) }
    const show = () => { visible = true; events.dispatchEvent(new Event('pageshow')) }
    const finishHidden = async success => {
        const request = start()
        hide()
        coordinator.settle(terminal(request.message, success))
        request.outcome = await request.completion
        show()
        check(notice()?.textContent.includes(success ? 'was saved' : 'wasn’t saved'), 'Native outcome is not displayed')
        check(notice().querySelector('button').hidden, 'Recovery must hide Cancel')
        return request
    }
    const proof = request => ({ requestID: request.message.requestID,
        observationToken: request.message.manualReadPendingObservationToken })
    return { coordinator, state, messages, controls, reads, timers, notice, accept, start, terminal,
        finishHidden, proof,
        setQuery: value => { query = value }, queryCount: () => queries,
        move: next => { chapter = next; state.relocate({ sectionURL: url(chapter) }, { moved: true }) },
        tick: () => { for (const [id, callback] of [...timers]) if (timers.delete(id)) callback() },
        cleanup: () => { coordinator.close(); state.close(); check(!notice(), 'Fixture leaked a notice') },
    }
}

const scenario = run => async () => {
    const f = fixture()
    try { await run(f) } finally { f.cleanup() }
}

export const recoveryLifetimeCases = [
    ...[true, false].map(success => [`real notice leaves with chapter after native ${success ? 'success' : 'failure'}`, scenario(async f => {
        const request = await f.finishHidden(success)
        const controls = f.controls.length
        f.move('b')
        check(!f.notice(), 'Obsolete recovery notice remained in the destination DOM')
        check(f.controls.length === controls && f.messages.length === 1, 'Retirement sent a control or mutation')
        check(f.timers.size === 0, 'Retired status timer survived')
        check(await request.completion === request.outcome, 'Native outcome was replaced')
        check(f.accept(2), 'Destination sample lost its request')
    })]),
    ['account replacement removes the old failure notice', scenario(async f => {
        const request = await f.finishHidden(false)
        f.state.setAccountPresentation('2:1')
        check(!f.notice(), 'Old-account notice remained in DOM')
        check(request.outcome.errorCode === 'cancelled', 'Native failure changed')
        check(f.messages.length === 1 && f.queryCount() === 0, 'Account cleanup replayed work')
    })],
    ['same-chapter movement cleans the notice through the existing status poll', scenario(async f => {
        await f.finishHidden(true)
        f.move('a')
        const controls = f.controls.length
        f.tick()
        check(!f.notice(), 'Old-page notice remained after ownership observation')
        check(f.controls.length === controls && f.timers.size === 0, 'Obsolete observation continued')
    })],
    ['a failed recovery notice disappears on departure without retry', scenario(async f => {
        const request = await f.finishHidden(true)
        f.setQuery(async () => false)
        check(await f.coordinator.recoverHistoryReadingStatus(f.proof(request)) === false, 'Failure acknowledged success')
        check(f.notice()?.textContent.includes('couldn’t be refreshed'), 'Failure notice missing')
        f.move('b')
        check(!f.notice(), 'Failed recovery notice survived chapter departure')
        f.tick()
        check(f.queryCount() === 1 && f.messages.length === 1, 'Failed recovery was retried')
    })],
    ['current empty-context recovery remains visible and accepts one fresh sample', scenario(async f => {
        const request = await f.finishHidden(true)
        f.coordinator.cancelAll()
        check(!!f.notice(), 'Current recovery was removed with its temporarily empty context')
        const completion = f.coordinator.recoverHistoryReadingStatus(f.proof(request))
        await flush()
        check(f.accept(2), 'Current recovery sample rejected')
        check(await completion === true, 'Current recovery was not acknowledged')
        check(!f.notice() && f.state.ready && f.messages.length === 1, 'Successful recovery left stale DOM or replayed')
    })],
    ['the real Cancel button still cancels only a pending native command', scenario(async f => {
        const request = f.start()
        f.tick()
        const button = f.notice()?.querySelector('button')
        check(button && !button.hidden && !button.disabled, 'Pending command has no usable Cancel button')
        button.click()
        check(f.controls.at(-1)?.manualReadPendingOperation === 'cancel', 'Cancel did not use native control')
        f.coordinator.settle(f.terminal(request.message, false))
        check((await request.completion).success === false && !f.notice(), 'Cancel outcome/notice did not settle')
    })],
    ['late read completion cannot restore a retired DOM notice', scenario(async f => {
        const request = await f.finishHidden(true)
        let release
        f.setQuery(() => new Promise(resolve => { release = resolve }))
        const completion = f.coordinator.recoverHistoryReadingStatus(f.proof(request))
        let observed = 'pending'
        completion.then(value => { observed = value })
        await flush()
        f.move('b')
        await flush()
        const early = observed
        release(true)
        await completion
        check(early === false, 'Retired UI caller still waited for native transport')
        check(!f.notice() && f.messages.length === 1, 'Late read restored notice or replayed mutation')
    })],
]
