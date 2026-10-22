import assert from 'node:assert/strict'
import test from 'node:test'
import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'

// Complete production controller and UUID dependency. Native delivery order
// and throwing UI callbacks are controlled collaborators, not a native writer.
const chapter = 'ebook://book/OPS/chapter.xhtml'
const account = '7:1'
const scope = Object.freeze({ articleProgressID: 'article', articleEpochID: 'pass',
    chapterKey: 'a'.repeat(64), chapterEpochID: null })
const proof = name => ({ requestID: `unmark-${name}`, observationToken: `observation-${name}` })
const failCleanup = () => { throw new Error('Outgoing display cleanup failed') }

function fixture() {
    const messages = [], updates = []
    let nextID = 0
    const state = new BookReadingStateController({
        documentStartedAtMs: 1, topWindowURL: 'ebook://book',
        requiresAccountPresentation: true,
        makeRequestID: () => `read-${++nextID}`,
        postMessage: message => messages.push(message),
        onState: value => updates.push(value),
    })
    state.setAccountPresentation(account)
    state.relocate({ sectionURL: chapter })
    const sample = (sequence, marked = false) => ({
        ok: true, accountPresentation: state.accountPresentation,
        state: { revision: sequence, articleProgressID: scope.articleProgressID,
            articleEpochID: scope.articleEpochID, scope: { ...scope }, finished: false,
            bookReadPresence: marked ? 'present' : 'empty',
            chapterReadPresence: marked ? 'present' : 'empty',
            readSegmentIdentifiers: marked ? ['word'] : [],
            sentenceIdentifiersRead: marked ? ['sentence'] : [] },
        context: { contextID: `context-${sequence}`, articleProgressID: scope.articleProgressID,
            articleEpochID: scope.articleEpochID, scope: { ...scope },
            sectionLocation: 'OPS/chapter.xhtml', isEndPage: false },
    })
    assert.equal(state.apply(messages[0].requestID, sample(1, true)), true)
    const reply = (request, sequence = 2) => ({ ...sample(sequence),
        ...(request.historyRecoveryObservation
            ? { historyRecoveryObservation: request.historyRecoveryObservation } : {}),
        location: { sectionURL: request.sectionURL, isEndPage: request.isEndPage,
            locationRevision: request.locationRevision },
    })
    const complete = (request = messages.at(-1), sequence = 2) => {
        assert.equal(state.apply(request.requestID, reply(request, sequence)), true)
    }
    return { state, messages, updates, sample, reply, complete }
}

for (const kind of ['callback', 'getter']) {
    test(`History recovery preparation survives a throwing cleanup ${kind}`, async () => {
        const f = fixture(), observation = proof(kind)
        if (kind === 'callback') f.state.onInvalidate = failCleanup
        else Object.defineProperty(f.state, 'onInvalidate', { configurable: true, get: failCleanup })
        assert.equal(f.state.beginHistoryReadingStatusRecovery(observation, scope), true)
        assert.equal(f.state.ready, false)
        assert.equal(f.state.captureScope(chapter), null)
        assert.equal(f.messages.length, 1, 'Preparation cannot issue its own native recovery attempt')
        assert.equal(f.state.refresh(), false, 'Ordinary reads cannot bypass the installed recovery barrier')
        assert.equal(await f.state.recoverHistoryReadingStatus(proof('wrong')), false)
        const completion = f.state.recoverHistoryReadingStatus(observation)
        assert.equal(f.messages.length, 2)
        assert.deepEqual(f.messages.at(-1).historyRecoveryObservation, observation)
        f.complete()
        assert.equal(await completion, true)
        assert.equal(f.state.ready, true)
        assert.deepEqual(f.state.state.readSegmentIdentifiers, [])
        assert.equal(f.state.reacknowledgeHistoryReadingStatus(observation), true)
        assert.equal(f.messages.length, 2)
    })
}

test('final caller validation cannot acknowledge recovery after retiring its account', async () => {
    const f = fixture(), observation = proof('old-account')
    let armed = false
    f.state.onInvalidate = () => { armed = true }
    const originalIsCurrent = () => {
        if (armed) {
            armed = false
            f.state.onInvalidate = () => {}
            f.state.setAccountPresentation('8:1')
        }
        return true
    }
    assert.equal(f.state.beginHistoryReadingStatusRecovery(observation, scope, originalIsCurrent), false)
    assert.equal(f.state.accountPresentation, '8:1')
    assert.equal(f.state.ready, false)
    assert.equal(await f.state.recoverHistoryReadingStatus(observation), false)
    assert.equal(f.messages.length, 1)
})

test('a same-valued successor recovery installed by failing cleanup retains its own proof', async () => {
    const f = fixture(), older = proof('older'), newer = proof('newer')
    f.state.onInvalidate = () => {
        f.state.onInvalidate = () => {}
        assert.equal(f.state.beginHistoryReadingStatusRecovery(newer, { ...scope }), true)
        failCleanup()
    }
    assert.equal(f.state.beginHistoryReadingStatusRecovery(older, scope), false)
    assert.equal(await f.state.recoverHistoryReadingStatus(older), false)
    const completion = f.state.recoverHistoryReadingStatus(newer)
    assert.deepEqual(f.messages.at(-1).historyRecoveryObservation, newer)
    f.complete()
    assert.equal(await completion, true)
    assert.equal(f.state.reacknowledgeHistoryReadingStatus(older), false)
    assert.equal(f.state.reacknowledgeHistoryReadingStatus(newer), true)
})

test('same-URL replacement during failing cleanup keeps the replacement chapter query', async () => {
    const f = fixture(), observation = proof('old-document')
    f.state.onInvalidate = () => {
        f.state.onInvalidate = () => {}
        f.state.relocate({ sectionURL: chapter }, { replaced: true })
        failCleanup()
    }
    assert.equal(f.state.beginHistoryReadingStatusRecovery(observation, scope), false)
    assert.equal(await f.state.recoverHistoryReadingStatus(observation), false)
    assert.equal(f.messages.length, 2)
    assert.equal(f.messages.at(-1).historyRecoveryObservation, undefined)
    f.complete()
    assert.equal(f.state.ready, true)
})

test('closing during failing recovery cleanup cannot restore the old barrier', async () => {
    const f = fixture(), observation = proof('closed')
    f.state.onInvalidate = () => {
        f.state.onInvalidate = () => {}
        f.state.close()
        failCleanup()
    }
    assert.equal(f.state.beginHistoryReadingStatusRecovery(observation, scope), false)
    assert.equal(await f.state.recoverHistoryReadingStatus(observation), false)
    assert.equal(f.state.refresh(), false)
    assert.equal(f.state.state, null)
    assert.equal(f.messages.length, 1)
})

test('a failed recovery reply settles despite failed cleanup and remains explicitly retryable', async () => {
    const f = fixture(), observation = proof('failed-read')
    assert.equal(f.state.beginHistoryReadingStatusRecovery(observation, scope), true)
    const first = f.state.recoverHistoryReadingStatus(observation)
    const request = f.messages.at(-1)
    f.state.onInvalidate = failCleanup
    assert.equal(f.state.apply(request.requestID, { ...f.reply(request), ok: false }), false)
    assert.equal(await first, false)
    assert.equal(f.state.ready, false)
    assert.equal(f.messages.length, 2, 'Failure cannot start an automatic retry')
    const second = f.state.recoverHistoryReadingStatus(observation)
    assert.equal(f.messages.length, 3)
    f.complete(undefined, 3)
    assert.equal(await second, true)
})

test('post failure and cleanup failure remain a failed read without a retry loop', () => {
    const f = fixture()
    f.state.postMessage = () => { throw new Error('Transport failed') }
    f.state.onInvalidate = failCleanup
    assert.equal(f.state.refresh(), false)
    assert.equal(f.state.ready, false)
    assert.equal(f.messages.length, 1)
    f.state.postMessage = message => f.messages.push(message)
    assert.equal(f.state.refresh(), true)
    f.complete()
    assert.equal(f.messages.length, 2)
})

test('failed-read cleanup cannot consume a callback-created replacement query', () => {
    const f = fixture()
    assert.equal(f.state.refresh(), true)
    const older = f.messages.at(-1)
    f.state.onInvalidate = () => {
        f.state.onInvalidate = () => {}
        f.state.refresh()
        failCleanup()
    }
    assert.equal(f.state.apply(older.requestID, { ...f.sample(2), ok: false }), false)
    const newer = f.messages.at(-1)
    assert.notEqual(newer.requestID, older.requestID)
    f.complete(newer, 3)
    assert.equal(f.state.apply(older.requestID, f.sample(4)), false)
    assert.equal(f.state.ready, true)
})

test('withdrawing an acknowledged recovery tolerates cleanup failure without acknowledging a new read', async () => {
    const f = fixture(), observation = proof('withdrawn')
    assert.equal(f.state.beginHistoryReadingStatusRecovery(observation, scope), true)
    const first = f.state.recoverHistoryReadingStatus(observation)
    f.complete()
    assert.equal(await first, true)
    f.state.onInvalidate = failCleanup
    assert.equal(f.state.failHistoryReadingStatusRecovery(observation), true)
    assert.equal(f.state.reacknowledgeHistoryReadingStatus(observation), false)
    assert.equal(f.state.ready, false)
    const second = f.state.recoverHistoryReadingStatus(observation)
    f.complete(undefined, 3)
    assert.equal(await second, true)
})

for (const outcome of ['declined', 'throwing']) {
    test(`cleanup tolerance cannot accept a ${outcome} replacement projection`, () => {
        const f = fixture()
        f.state.refresh()
        const request = f.messages.at(-1)
        f.state.onInvalidate = failCleanup
        f.state.onState = outcome === 'declined' ? () => false : () => { throw new Error('Projection failed') }
        if (outcome === 'throwing') {
            assert.throws(() => f.state.apply(request.requestID, f.sample(2)), /Projection failed/)
        } else {
            assert.equal(f.state.apply(request.requestID, f.sample(2)), false)
        }
        assert.equal(f.state.ready, false)
        assert.equal(f.state.state, null)
    })
}
