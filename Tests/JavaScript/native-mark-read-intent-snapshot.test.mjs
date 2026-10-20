import assert from 'node:assert/strict'
import test from 'node:test'
import { createNativeMarkReadRequestCoordinator } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

const ordinary = desiredState => ({ desiredState, stableSegmentIDs: ['original'],
    sentenceIdentifiers: [], topWindowURL: 'ebook://book/test.epub', documentStartedAtMs: 42 })
const terminal = message => ({ requestID: message.requestID, sectionId: message.sectionId,
    manualReadPendingProtocol: 1,
    manualReadPendingObservationToken: message.manualReadPendingObservationToken,
    manualReadPendingState: 'finished', success: true })

function fixture(t) {
    const posted = [], controls = [], timers = new Map()
    let timerSequence = 0
    const coordinator = createNativeMarkReadRequestCoordinator({
        makeRequestID: () => 'intent-snapshot', lifecycleTarget: new EventTarget(),
        postMessage: message => posted.push(message),
        postControlMessage: message => controls.push(message),
        scheduleTimeout: callback => { timers.set(++timerSequence, callback); return timerSequence },
        cancelTimeout: id => timers.delete(id),
    })
    t.after(() => coordinator.close())
    return { coordinator, posted, controls, timers,
        request: message => coordinator.request({ sectionID: 'page', message }) }
}

for (const initial of ['marked', 'unmarked']) {
    test(`a changing desired-state getter preserves its captured ${initial} intent`, async t => {
        const f = fixture(t)
        let reads = 0
        const message = ordinary(initial)
        Object.defineProperty(message, 'desiredState', { enumerable: true, get() {
            return ++reads === 1 ? initial : initial === 'marked' ? 'unmarked' : 'marked'
        } })
        const completion = f.request(message)
        assert.equal(f.posted.length, 1)
        assert.equal(f.posted[0].desiredState, initial)
        assert.equal(reads, 1, 'Native submission must reuse the one semantic snapshot')
        assert.strictEqual(f.request(ordinary(initial)), completion)
        const other = await f.request(ordinary(initial === 'marked' ? 'unmarked' : 'marked'))
        assert.equal(other.errorCode, 'pendingTargetBusy')
        assert.equal(f.coordinator.settle(terminal(f.posted[0])), true)
        assert.equal((await completion).success, true)
    })
}

test('an opposite-intent tap never joins the operation actually sent to native', async t => {
    const f = fixture(t)
    let reads = 0
    const message = ordinary('unmarked')
    Object.defineProperty(message, 'desiredState', { enumerable: true, get() {
        return ++reads === 1 ? 'unmarked' : 'marked'
    } })
    const original = f.request(message)
    const opposite = f.request({ ...f.posted[0],
        desiredState: f.posted[0].desiredState === 'marked' ? 'unmarked' : 'marked' })
    assert.notStrictEqual(opposite, original,
        'The fingerprint must describe the transmitted operation, not an earlier accessor result')
    assert.equal((await opposite).errorCode, 'pendingTargetBusy')
    f.coordinator.settle(terminal(f.posted[0]))
    await original
})

test('changing selected-subject getters cannot retarget the captured command', async t => {
    const f = fixture(t)
    let reads = 0
    const message = ordinary('unmarked')
    Object.defineProperty(message, 'stableSegmentIDs', { enumerable: true, get() {
        return ++reads === 1 ? ['original'] : ['replacement']
    } })
    const completion = f.request(message)
    assert.deepEqual(f.posted[0].stableSegmentIDs, ['original'])
    assert.equal(reads, 1)
    assert.strictEqual(f.request(ordinary('unmarked')), completion)
    f.coordinator.settle(terminal(f.posted[0]))
    await completion
})

test('a nested serializer cannot swap the captured chapter pass before transmission', async t => {
    const f = fixture(t)
    let reads = 0
    const scope = epoch => ({ articleProgressID: 'book', articleEpochID: 'article-pass',
        chapterKey: 'a'.repeat(64), chapterEpochID: epoch })
    const message = { ...ordinary('unmarked'), bookReadingScope: { toJSON() {
        return scope(++reads === 1 ? 'original-pass' : 'replacement-pass')
    } } }
    const completion = f.request(message)
    assert.equal(f.posted[0].bookReadingScope.chapterEpochID, 'original-pass')
    assert.equal(reads, 1)
    assert.strictEqual(f.request({ ...ordinary('unmarked'), bookReadingScope: scope('original-pass') }), completion)
    const denied = await f.request({ ...ordinary('unmarked'), bookReadingScope: scope('replacement-pass') })
    assert.equal(denied.errorCode, 'pendingTargetBusy')
    f.coordinator.settle(terminal(f.posted[0]))
    await completion
})

test('a root serializer cannot remove the coordinator-owned native reply capability', async t => {
    const f = fixture(t)
    let serializations = 0
    const message = { toJSON() {
        serializations += 1
        return { ...ordinary('unmarked'), requestID: 'forged', sectionId: 'other',
            manualReadPendingProtocol: 9, manualReadPendingObservationToken: 'forged-token' }
    } }
    const completion = f.request(message)
    const sent = f.posted[0]
    assert.equal(serializations, 1)
    assert.notEqual(sent.requestID, 'forged')
    assert.equal(sent.sectionId, 'page')
    assert.equal(sent.manualReadPendingProtocol, 1)
    assert.match(sent.manualReadPendingObservationToken, /^[a-f0-9]{32}$/)
    assert.strictEqual(f.request(ordinary('unmarked')), completion)
    assert.equal(f.coordinator.settle(terminal(sent)), true)
    assert.equal((await completion).success, true)
    assert.equal(f.timers.size, 0)
})

for (const [label, value] of [['null', null], ['scalar', 'not-a-command'], ['array', []]]) {
    test(`a ${label} serialization result is rejected before request admission`, async t => {
        const f = fixture(t)
        let completion
        assert.doesNotThrow(() => { completion = f.request({ toJSON: () => value }) })
        assert.equal(f.posted.length, 0, 'Invalid semantic snapshots must never reach native transport')
        assert.equal((await completion).errorCode, 'invalidMessage')
        assert.equal(f.coordinator.pendingCount, 0)
        assert.equal(f.timers.size, 0)
    })
}

test('caller mutation after capture cannot alter the sent subjects or exact coalescing', async t => {
    const f = fixture(t)
    const message = ordinary('unmarked')
    const completion = f.request(message)
    message.stableSegmentIDs.push('later')
    message.desiredState = 'marked'
    assert.equal(f.posted[0].desiredState, 'unmarked')
    assert.deepEqual(f.posted[0].stableSegmentIDs, ['original'])
    assert.ok(Object.isFrozen(f.posted[0]))
    assert.ok(Object.isFrozen(f.posted[0].stableSegmentIDs))
    assert.strictEqual(f.request(ordinary('unmarked')), completion)
    assert.equal((await f.request(message)).errorCode, 'pendingTargetBusy')
    f.coordinator.settle(terminal(f.posted[0]))
    await completion
})

test('JSON key order and caller-supplied correlation fields do not split equal intents', async t => {
    const f = fixture(t)
    const completion = f.request(ordinary('unmarked'))
    const same = { manualReadPendingObservationToken: 'discard-me', requestID: 'discard-me',
        documentStartedAtMs: 42, sentenceIdentifiers: [], topWindowURL: 'ebook://book/test.epub',
        manualReadPendingProtocol: 17, stableSegmentIDs: ['original'], desiredState: 'unmarked' }
    assert.strictEqual(f.request(same), completion)
    assert.equal(f.posted.length, 1)
    f.coordinator.settle(terminal(f.posted[0]))
    await completion
})

test('failed snapshot preparation leaves no request and permits an explicit later retry', async t => {
    const f = fixture(t)
    const rejected = await f.request({ toJSON() { throw new Error('serialization failed') } })
    assert.equal(rejected.errorCode, 'invalidMessage')
    assert.equal(f.coordinator.pendingCount, 0)
    assert.equal(f.timers.size, 0)
    assert.equal(f.posted.length, 0)
    const completion = f.request(ordinary('unmarked'))
    f.coordinator.settle(terminal(f.posted[0]))
    assert.equal((await completion).success, true)
})

test('snapshot preparation cannot admit work after a serializer closes the Reader', async t => {
    const f = fixture(t)
    const completion = f.request({ toJSON() {
        f.coordinator.close()
        return ordinary('unmarked')
    } })
    await assert.rejects(completion, error => error.code === 'readerClosed')
    assert.equal(f.posted.length, 0)
    assert.equal(f.coordinator.pendingCount, 0)
    assert.equal(f.timers.size, 0)
})
