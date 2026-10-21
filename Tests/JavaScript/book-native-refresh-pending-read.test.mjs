import assert from 'node:assert/strict'
import test from 'node:test'
import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'

// Import the complete production controller and UUID utility. Native snapshots
// and their delivery order are explicit collaborators; no native write is run.
const chapter = 'ebook://book/OPS/chapter.xhtml'
const account = '7:1'
const scope = Object.freeze({ articleProgressID: 'book', articleEpochID: 'article-pass',
    chapterKey: 'a'.repeat(64), chapterEpochID: null })

function sample(sequence, marked = true) {
    return { ok: true, accountPresentation: account,
        state: { revision: sequence, articleProgressID: scope.articleProgressID,
            articleEpochID: scope.articleEpochID, scope: { ...scope }, finished: false,
            bookReadPresence: marked ? 'present' : 'empty',
            chapterReadPresence: marked ? 'present' : 'empty',
            readSegmentIdentifiers: marked ? ['word'] : [],
            sentenceIdentifiersRead: marked ? ['sentence'] : [],
            ownedManualSegmentIDs: marked ? ['word'] : [],
            ownedManualSentenceIDs: marked ? ['sentence'] : [],
            manualSupportRevision: marked ? 'mark-revision' : null,
            manualOverlayUnmarkEnabled: true },
        context: { contextID: 'native-context', articleProgressID: scope.articleProgressID,
            articleEpochID: scope.articleEpochID, scope: { ...scope },
            sectionLocation: 'OPS/chapter.xhtml', isEndPage: false } }
}
function fixture() {
    const messages = [], updates = []
    let counter = 0, invalidations = 0
    const state = new BookReadingStateController({
        documentStartedAtMs: 1, topWindowURL: 'ebook://book',
        requiresAccountPresentation: true, makeRequestID: () => `read-${++counter}`,
        postMessage: message => messages.push(message),
        onState: value => updates.push(value), onInvalidate: () => { invalidations++ },
    })
    state.relocate({ sectionURL: chapter })
    const original = messages.at(-1)
    assert.equal(state.apply(original.requestID, sample(10)), true)
    const refresh = () => {
        assert.equal(state.refresh(), true)
        return messages.at(-1)
    }
    const native = payload => ({ ...payload, nativeRefresh: true,
        location: { sectionURL: chapter, isEndPage: false,
            locationRevision: state.locationRevision } })
    return { state, original, refresh, native, messages, updates,
        invalidations: () => invalidations }
}

for (const outcome of ['snapshot', 'failure', 'declined projection', 'throwing projection']) {
    test(`post-commit native ${outcome} does not consume a different pending chapter read`, () => {
        const f = fixture(), pending = f.refresh()
        // The post-commit native publisher still carries the earlier request's
        // identity. A newer JS query has already been posted in this location.
        const publish = f.state.onState
        if (outcome === 'declined projection') f.state.onState = () => false
        if (outcome === 'throwing projection') f.state.onState = () => { throw new Error('projection failed') }
        const packet = f.native(outcome === 'failure'
            ? { ok: false, accountPresentation: account } : sample(11))
        if (outcome === 'throwing projection') {
            assert.throws(() => f.state.apply(f.original.requestID, packet), /projection failed/)
        } else {
            assert.equal(f.state.apply(f.original.requestID, packet), outcome === 'snapshot')
        }
        assert.equal(f.state.ready, outcome === 'snapshot')
        f.state.onState = publish
        // Native later answers the already-issued query with post-Unmark
        // coverage. No replay or third query should be necessary to show it.
        assert.equal(f.state.apply(pending.requestID, sample(12, false)), true,
            'a native publication must not steal another query\'s response slot')
        assert.equal(f.state.ready, true)
        assert.deepEqual(f.state.state.sentenceIdentifiersRead, [])
        assert.deepEqual(f.state.state.ownedManualSentenceIDs, [])
        assert.equal(f.state.state.manualSupportRevision, null)
        assert.equal(f.messages.length, 2, 'reconciliation must not issue extra native work')
        assert.equal(f.state.apply(pending.requestID, sample(13)), false,
            'the matching query still settles only once')
    })
}

test('an unsolicited native sample retains the same-account pending query', () => {
    const f = fixture(), pending = f.refresh()
    assert.equal(f.state.apply(null, f.native(sample(11))), true)
    assert.equal(f.state.apply(pending.requestID, sample(12, false)), true)
    assert.equal(f.messages.length, 2)
})

test('a native sample correlated to the pending query consumes that exact query', () => {
    const f = fixture(), pending = f.refresh()
    assert.equal(f.state.apply(pending.requestID, f.native(sample(12, false))), true)
    assert.equal(f.state.apply(pending.requestID, sample(13)), false)
    assert.deepEqual(f.state.state.sentenceIdentifiersRead, [])
})

test('native snapshot order still rejects an older answer without losing its current query', () => {
    const f = fixture(), pending = f.refresh()
    assert.equal(f.state.apply(f.original.requestID, f.native(sample(20, false))), true)
    assert.equal(f.state.apply(pending.requestID, sample(19)), false)
    assert.deepEqual(f.state.state.sentenceIdentifiersRead, [])
    assert.equal(f.state.apply(pending.requestID, sample(21, false)), true)
})

test('a query created by native projection supersedes the prior pending query', () => {
    const f = fixture(), previous = f.refresh()
    let successor
    f.state.onState = () => {
        f.state.onState = () => {}
        successor = f.refresh()
    }
    assert.equal(f.state.apply(f.original.requestID, f.native(sample(11))), true)
    assert.notEqual(successor.requestID, previous.requestID)
    assert.equal(f.state.apply(previous.requestID, sample(12)), false)
    assert.equal(f.state.apply(successor.requestID, sample(13, false)), true)
})

test('a replacement account publication does not retain the old account query', () => {
    const f = fixture(), previous = f.refresh()
    assert.equal(f.state.apply(f.original.requestID,
        { ...f.native(sample(1, false)), accountPresentation: '8:1' }), true)
    assert.equal(f.state.apply(previous.requestID, sample(22)), false)
    assert.equal(f.state.accountPresentation, '8:1')
    assert.deepEqual(f.state.state.sentenceIdentifiersRead, [])
})

test('native location mismatch does not consume the current chapter query', () => {
    const f = fixture(), pending = f.refresh()
    const packet = f.native(sample(20))
    packet.location.locationRevision++
    assert.equal(f.state.apply(f.original.requestID, packet), false)
    assert.equal(f.state.apply(pending.requestID, sample(21, false)), true)
})

for (const outcome of ['failure', 'declined projection']) {
    test(`unrelated native ${outcome} with throwing cleanup preserves the pending read`, () => {
        const f = fixture(), pending = f.refresh()
        const publish = f.state.onState
        f.state.onInvalidate = () => { throw new Error('Outgoing cleanup failed') }
        if (outcome === 'declined projection') f.state.onState = () => false
        const packet = f.native(outcome === 'failure'
            ? { ok: false, accountPresentation: account } : sample(11))
        assert.equal(f.state.apply(f.original.requestID, packet), false)
        assert.equal(f.state.ready, false)
        f.state.onState = publish
        assert.equal(f.state.apply(pending.requestID, sample(12, false)), true)
        assert.deepEqual(f.state.state.readSegmentIdentifiers, [])
        assert.equal(f.state.state.manualSupportRevision, null)
        assert.equal(f.messages.length, 2, 'Composition cannot add a recovery loop')
        assert.equal(f.state.apply(pending.requestID, sample(13)), false)
    })
}
