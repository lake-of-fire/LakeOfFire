import assert from 'node:assert/strict'
import test from 'node:test'
import { BookReadingStateController, bookScopeKey } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'
import {
    createNativeMarkReadRequestCoordinator,
    refreshCommittedVisibleMarkReadState,
    committedVisibleMarkReadStateIsPresented,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

const sectionURL = 'https://reader.invalid/chapter.xhtml'
const scope = { articleProgressID: 'book', articleEpochID: 'pass',
    chapterKey: 'a'.repeat(64), chapterEpochID: null }
const subjects = ['page-word-a', 'page-word-b']

function fixture(t) {
    const reads = [], commands = [], timers = new Map()
    let serial = 0, timer = 0, publicationSequence = 0, visible = true
    const state = new BookReadingStateController({
        topWindowURL: 'ebook://book', documentStartedAtMs: 123,
        makeRequestID: () => `read-${++serial}`,
        postMessage: message => reads.push(message),
        onState: value => { publicationSequence = value.revision },
    })
    const response = (revision, ids = subjects) => ({
        ok: true, accountPresentation: '1:1',
        location: { ...state.location, locationRevision: state.locationRevision },
        state: { revision, articleProgressID: scope.articleProgressID,
            articleEpochID: scope.articleEpochID, scope, finished: false,
            bookReadPresence: 'present', chapterReadPresence: 'present',
            readSegmentIdentifiers: [...ids], sentenceIdentifiersRead: [] },
        context: { contextID: 'chapter-context', articleProgressID: scope.articleProgressID,
            articleEpochID: scope.articleEpochID, scope, sectionLocation: 'chapter.xhtml', isEndPage: false },
    })
    state.relocate({ sectionURL })
    assert.equal(state.apply(reads.at(-1).requestID, response(1, ['previous'])), true)
    const locationRevision = state.locationRevision
    // The caller owns the original document/account/pass independently of
    // publication order. A full same-pass refresh is not a new user intent.
    const ownerCurrent = () => visible && state.accountPresentation === '1:1'
        && state.locationRevision === locationRevision
        && bookScopeKey(state.context?.scope) === bookScopeKey(scope)
    const coordinator = createNativeMarkReadRequestCoordinator({
        makeRequestID: () => 'snapshot-first-mark', lifecycleTarget: new EventTarget(),
        postMessage: message => commands.push(message), postControlMessage: () => {},
        scheduleTimeout: callback => { timers.set(++timer, callback); return timer },
        cancelTimeout: id => timers.delete(id), isOwnerCurrent: ownerCurrent,
    })
    t.after(() => { coordinator.close(); state.close() })
    const completion = coordinator.request({ sectionID: 'visible-page', owner: {},
        message: { desiredState: 'marked', stableSegmentIDs: subjects, sentenceIdentifiers: [] } })
    const message = commands[0]
    const acknowledge = async (sequence = 2, extra = {}) => {
        assert.equal(coordinator.settle({ requestID: message.requestID, sectionId: message.sectionId,
            manualReadPendingProtocol: 1,
            manualReadPendingObservationToken: message.manualReadPendingObservationToken,
            manualReadPendingState: 'finished', success: true, stateSnapshotSequence: sequence,
            ...extra }), true)
        return completion
    }
    const publish = (revision, ids = subjects, nativeRefresh = false) => {
        if (!nativeRefresh) assert.equal(state.refresh(), true)
        const result = response(revision, ids)
        if (nativeRefresh) result.nativeRefresh = true
        return state.apply(nativeRefresh ? 'native-observer' : reads.at(-1).requestID, result)
    }
    const prepare = outcome => refreshCommittedVisibleMarkReadState({ outcome, state, isOwnerCurrent: ownerCurrent })
    const presented = (minimum = 2, successfulPublicationSequence = publicationSequence) => committedVisibleMarkReadStateIsPresented({
        state, minimumSnapshotSequence: minimum, stableSegmentIDs: subjects, successfulPublicationSequence,
    })
    return { state, reads, commands, completion, acknowledge, publish, prepare, presented, response,
        retire: () => { visible = false } }
}

for (const nativeRefresh of [false, true]) {
    test(`newer full ${nativeRefresh ? 'native refresh' : 'queried snapshot'} before Mark reply preserves advance eligibility`, async t => {
        const f = fixture(t)
        assert.equal(f.publish(3, ['previous', ...subjects], nativeRefresh), true)
        const before = f.state.state
        const reads = f.reads.length
        const outcome = await f.acknowledge()
        assert.equal(outcome.success, true)
        assert.equal(f.prepare(outcome), true, 'A newer accepted full snapshot already covers this committed cut')
        assert.equal(f.reads.length, reads, 'Do not replace another pending read with a redundant query')
        assert.equal(f.presented(), true, 'Actual publication and every selected subject are still required')
        assert.deepEqual(f.state.state, before, 'The older reply cannot repaint or roll back native state')
        assert.equal(f.state.noteManualReadSnapshot(2), false, 'The newer ordering watermark is retained')
        assert.equal(f.commands.length, 1)
    })
}

test('a newer full Unmark snapshot still prevents advance from the older successful Mark', async t => {
    const f = fixture(t)
    assert.equal(f.publish(3, [subjects[0]]), true)
    const outcome = await f.acknowledge()
    assert.equal(f.prepare(outcome), true, 'The current snapshot is available, not necessarily read')
    assert.equal(f.presented(), false, 'Withdrawn submitted subjects must not be inferred from Mark success')
    assert.deepEqual(f.state.state.readSegmentIdentifiers, [subjects[0]])
    assert.equal(f.commands.length, 1)
})

test('newer partial Unmark receipt cannot lend an obsolete full snapshot to an older Mark', async t => {
    const f = fixture(t)
    assert.equal(f.publish(3), true)
    assert.equal(f.state.noteManualReadSnapshot(4), true)
    const count = f.reads.length
    assert.equal(f.prepare(await f.acknowledge()), false)
    assert.equal(f.reads.length, count)
    assert.equal(f.state.noteManualReadSnapshot(3), false, 'A cached full snapshot cannot lower the partial-reply watermark')
})

test('a sequence-only observation is not a full publication', async t => {
    const f = fixture(t)
    assert.equal(f.state.noteManualReadSnapshot(3), true)
    assert.equal(f.prepare(await f.acknowledge()), false)
    assert.equal(f.presented(), false)
    assert.deepEqual(f.state.state.readSegmentIdentifiers, ['previous'])
    assert.equal(f.reads.length, 1)
})

test('already accepted state does not consume an independently queued newer read', async t => {
    const f = fixture(t)
    assert.equal(f.publish(3), true)
    assert.equal(f.state.refresh(), true)
    const pending = f.reads.at(-1), count = f.reads.length
    assert.equal(f.prepare(await f.acknowledge()), true)
    assert.equal(f.reads.length, count)
    assert.equal(f.state.apply(pending.requestID, f.response(4, [])), true)
    assert.equal(f.presented(), false)
    assert.deepEqual(f.state.state.readSegmentIdentifiers, [])
})

test('a refused full publication cannot authorize the fallback', async t => {
    const f = fixture(t)
    const outcome = await f.acknowledge()
    f.state.onState = () => false
    assert.equal(f.publish(3), false)
    assert.equal(f.state.ready, false)
    assert.equal(f.prepare(outcome), false)
    assert.equal(f.presented(), false)
})

test('withdrawn context cannot use its retained full state as a publication', async t => {
    const f = fixture(t)
    assert.equal(f.publish(3), true)
    const outcome = await f.acknowledge()
    assert.equal(f.state.refresh(), true)
    assert.equal(f.state.apply(f.reads.at(-1).requestID, { ok: false, accountPresentation: '1:1' }), false)
    assert.equal(f.state.state.revision, 3)
    assert.equal(f.state.ready, false)
    assert.equal(f.prepare(outcome), false)
})

for (const retirement of ['owner', 'account', 'chapter', 'close']) {
    test(`${retirement} retirement still refuses an older Mark's follow-up`, async t => {
        const f = fixture(t)
        assert.equal(f.publish(3), true)
        const outcome = await f.acknowledge()
        if (retirement === 'owner') f.retire()
        if (retirement === 'account') f.state.setAccountPresentation('2:1')
        if (retirement === 'chapter') f.state.relocate({ sectionURL: 'https://reader.invalid/other.xhtml' })
        if (retirement === 'close') f.state.close()
        const count = f.reads.length
        assert.equal(f.prepare(outcome), false)
        assert.equal(f.reads.length, count)
    })
}

test('invalid commit sequences cannot borrow a newer accepted snapshot', async t => {
    for (const sequence of [0, -1, null, undefined, NaN, Infinity, '2', 2.5, Number.MAX_SAFE_INTEGER + 1]) {
        const f = fixture(t)
        assert.equal(f.publish(3), true)
        const outcome = await f.acknowledge(sequence)
        // acknowledge's default parameter supplies 2 for undefined; explicitly
        // remove it to exercise a missing field rather than a valid default.
        if (sequence === undefined) delete outcome.nativeResult.stateSnapshotSequence
        assert.equal(f.prepare(outcome), false, `Invalid native sequence: ${String(sequence)}`)
        assert.equal(f.state.state.revision, 3)
    }
})

test('failed or presentation-withheld outcomes cannot borrow accepted full state', async t => {
    for (const extra of [{ success: false }, { manualReadPendingPresentationAllowed: false }]) {
        const f = fixture(t)
        assert.equal(f.publish(3), true)
        assert.equal(f.prepare(await f.acknowledge(2, extra)), false)
    }
})

test('reply-first ordering retains the existing read request and publication gate', async t => {
    const f = fixture(t)
    assert.equal(f.prepare(await f.acknowledge()), true)
    assert.equal(f.reads.length, 2)
    assert.equal(f.presented(), false)
    const pending = f.reads.at(-1)
    assert.equal(f.state.apply(pending.requestID, f.response(1)), false)
    assert.equal(f.state.apply(pending.requestID, f.response(2)), true)
    assert.equal(f.presented(), true)
})

test('a newer controller snapshot alone does not bypass the actual renderer publication marker', async t => {
    const f = fixture(t)
    assert.equal(f.publish(3), true)
    assert.equal(f.prepare(await f.acknowledge()), true)
    assert.equal(f.presented(2, 1), false)
    assert.equal(f.presented(2, 3), true)
})

test('a partial receipt after full publication withdraws the cached snapshot from the final advance check', async t => {
    const f = fixture(t)
    assert.equal(f.prepare(await f.acknowledge()), true)
    assert.equal(f.publish(3), true)
    assert.equal(f.presented(), true)
    const before = f.state.state, reads = f.reads.length
    // Core's completed manual-reply handoff advances this exact controller
    // clock without supplying a full chapter projection to the shell.
    assert.equal(f.state.noteManualReadSnapshot(4), true)
    assert.equal(f.state.ready, true, 'Context readiness alone is not current full-read evidence')
    assert.equal(f.presented(), false, 'A newer partial receipt supersedes the cached full snapshot')
    assert.deepEqual(f.state.state, before, 'The eligibility check cannot fabricate a replacement projection')
    assert.equal(f.reads.length, reads, 'Final admission must not start another query')
    assert.equal(f.state.noteManualReadSnapshot(3), false, 'The ordering watermark cannot be rolled back')
})

test('a later complete publication restores advance evidence after a partial receipt', async t => {
    const f = fixture(t)
    assert.equal(f.prepare(await f.acknowledge()), true)
    assert.equal(f.publish(3), true)
    assert.equal(f.state.noteManualReadSnapshot(4), true)
    assert.equal(f.presented(), false)
    assert.equal(f.publish(4), true)
    assert.equal(f.presented(), true, 'Equal-cut full publication covers the known partial receipt')
    assert.equal(f.state.noteManualReadSnapshot(5), true)
    assert.equal(f.presented(), false)
    assert.equal(f.publish(6), true)
    assert.equal(f.presented(), true)
    assert.equal(f.commands.length, 1)
})

test('checking an overtaken full snapshot preserves an independently pending chapter read', async t => {
    const f = fixture(t)
    assert.equal(f.prepare(await f.acknowledge()), true)
    assert.equal(f.publish(3), true)
    assert.equal(f.state.noteManualReadSnapshot(4), true)
    assert.equal(f.state.refresh(), true)
    const pending = f.reads.at(-1), count = f.reads.length
    assert.equal(f.presented(), false)
    assert.equal(f.reads.length, count)
    assert.equal(f.state.apply(pending.requestID, f.response(4)), true)
    assert.equal(f.presented(), true)
})

test('a full Unmark publication after its partial receipt keeps the page advance blocked', async t => {
    const f = fixture(t)
    assert.equal(f.prepare(await f.acknowledge()), true)
    assert.equal(f.publish(3), true)
    assert.equal(f.state.noteManualReadSnapshot(4), true)
    assert.equal(f.presented(), false)
    assert.equal(f.publish(4, [subjects[0]]), true)
    assert.equal(f.presented(), false, 'Current full state still has to include every originally submitted subject')
    assert.deepEqual(f.state.state.readSegmentIdentifiers, [subjects[0]])
})

test('equal or rejected older partial receipts do not invalidate a current full publication', async t => {
    const f = fixture(t)
    assert.equal(f.prepare(await f.acknowledge()), true)
    assert.equal(f.publish(3), true)
    assert.equal(f.state.noteManualReadSnapshot(2), false)
    assert.equal(f.presented(), true)
    assert.equal(f.state.noteManualReadSnapshot(3), true)
    assert.equal(f.presented(), true)
    assert.equal(f.state.noteManualReadSnapshot(2), false)
})
