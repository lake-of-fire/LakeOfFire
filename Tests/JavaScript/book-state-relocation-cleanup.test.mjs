import assert from 'node:assert/strict'
import { test } from 'node:test'
import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'

const chapter = name => `https://reader.invalid/${name}.xhtml`
const failure = () => { throw new Error('Outgoing presentation cleanup failed') }

// Complete production controller. Native responses, projection callbacks and
// location observations are controlled; no writer, renderer or WebKit is faked
// into an end-to-end acceptance claim.
function fixture() {
    const requests = [], projections = []
    let sequence = 0
    const state = new BookReadingStateController({
        postMessage: message => requests.push(message),
        documentStartedAtMs: 100,
        topWindowURL: 'ebook://ebook/load/local/book.epub',
        requiresAccountPresentation: true,
        makeRequestID: () => `request-${++sequence}`,
        onState: value => projections.push(value),
    })
    assert.equal(state.setAccountPresentation('1:0'), true)
    function response(request, revision = 1) {
        const scope = request.isEndPage ? null : {
            articleProgressID: 'article', articleEpochID: 'epoch',
            chapterKey: 'a'.repeat(64), chapterEpochID: null,
        }
        return {
            ok: true, accountPresentation: state.accountPresentation,
            state: { revision, articleProgressID: 'article', articleEpochID: 'epoch',
                scope, finished: false, bookReadPresence: 'present', chapterReadPresence: 'present',
                readSegmentIdentifiers: [], sentenceIdentifiersRead: [] },
            context: { contextID: `context-${request.requestID}`, articleProgressID: 'article',
                articleEpochID: 'epoch', scope, isEndPage: request.isEndPage,
                sectionLocation: request.sectionURL },
        }
    }
    function accept(request = requests.at(-1), revision = 1) {
        assert.ok(request, 'Relocation must send its read-only native refresh')
        assert.equal(state.apply(request.requestID, response(request, revision)), true)
        assert.equal(state.ready, true)
    }
    const move = (location, options) => {
        try { return { result: state.relocate(location, options) } }
        catch (error) { return { error } }
    }
    return { state, requests, projections, accept, response, move }
}

for (const kind of ['callback', 'getter']) {
    test(`first relocation still requests native state after a failing cleanup ${kind}`, () => {
        const f = fixture()
        if (kind === 'callback') f.state.onInvalidate = failure
        else Object.defineProperty(f.state, 'onInvalidate', { configurable: true, get: failure })
        const result = f.move({ sectionURL: chapter('one') })
        assert.equal(f.requests.length, 1, 'The already-selected location must not be stranded without a request')
        assert.equal(result.error, undefined)
        assert.equal(result.result, true)
        assert.equal(f.state.ready, false, 'A request alone is not native delivery')
        f.accept()
        assert.equal(f.state.captureContext().sectionLocation, chapter('one'))
        assert.equal(f.state.relocate({ sectionURL: chapter('one') }), false)
        assert.equal(f.requests.length, 1, 'An unchanged location is not an automatic retry loop')
    })
}

test('same-URL physical replacement still refreshes and rejects the predecessor reply', () => {
    const f = fixture()
    f.state.relocate({ sectionURL: chapter('same') })
    const oldRequest = f.requests[0]
    f.accept(oldRequest)
    f.state.onInvalidate = failure
    f.move({ sectionURL: chapter('same') }, { replaced: true })
    assert.equal(f.requests.length, 2)
    assert.equal(f.state.ready, false)
    assert.equal(f.state.apply(oldRequest.requestID, f.response(oldRequest, 2)), false)
    f.accept(f.requests[1], 2)
})

test('entering End of Book is not stranded by outgoing cleanup failure', () => {
    const f = fixture()
    f.state.relocate({ sectionURL: chapter('last') })
    f.accept()
    f.state.onInvalidate = failure
    f.move({ isEndPage: true })
    assert.equal(f.requests.length, 2)
    assert.equal(f.requests[1].isEndPage, true)
    assert.equal(f.requests[1].sectionURL, null)
    assert.equal(f.state.ready, false)
    f.accept(f.requests[1], 2)
    assert.equal(f.state.captureContext().isEndPage, true)
    assert.equal(f.state.captureScope(chapter('last')), null)
})

test('throwing cleanup cannot dispatch over its nested newer relocation', () => {
    const f = fixture()
    f.state.onInvalidate = () => {
        f.state.onInvalidate = () => {}
        f.state.relocate({ sectionURL: chapter('newer') })
        failure()
    }
    f.move({ sectionURL: chapter('older') })
    assert.equal(f.requests.length, 1)
    assert.equal(f.requests[0].sectionURL, chapter('newer'))
    f.accept()
})

test('a nested refresh keeps its exact reply slot after cleanup throws', () => {
    const f = fixture()
    f.state.onInvalidate = () => {
        assert.equal(f.state.refresh(), true)
        failure()
    }
    f.move({ sectionURL: chapter('one') })
    assert.equal(f.requests.length, 1, 'The outer relocation must not replace the nested pending read')
    f.accept()
})

test('closing during failing cleanup cannot produce a native refresh', () => {
    const f = fixture()
    f.state.onInvalidate = () => {
        f.state.onInvalidate = () => {}
        f.state.close()
        failure()
    }
    f.move({ sectionURL: chapter('one') })
    assert.equal(f.requests.length, 0)
    assert.equal(f.state.ready, false)
    assert.equal(f.state.refresh(), false)
})

test('relocation retires an old Unmark recovery even when its outgoing cleanup fails', async () => {
    const f = fixture()
    f.state.relocate({ sectionURL: chapter('one') })
    f.accept()
    const proof = { requestID: 'unmark', observationToken: 'observation' }
    const scope = f.state.captureScope(chapter('one'))
    assert.equal(f.state.beginHistoryReadingStatusRecovery(proof, scope), true)
    const completion = f.state.recoverHistoryReadingStatus(proof)
    const recoveryRequest = f.requests.at(-1)
    f.state.onInvalidate = failure
    f.move({ sectionURL: chapter('two') })
    assert.equal(await completion, false)
    assert.equal(f.requests.length, 3, 'The new chapter must get its own non-recovery refresh')
    const current = f.requests.at(-1)
    assert.equal(current.sectionURL, chapter('two'))
    assert.equal(current.historyRecoveryObservation, undefined)
    assert.equal(f.state.apply(recoveryRequest.requestID, {
        ...f.response(recoveryRequest, 2), historyRecoveryObservation: proof,
        location: { sectionURL: chapter('one'), isEndPage: false,
            locationRevision: recoveryRequest.locationRevision },
    }), false)
    f.accept(current, 3)
})

test('a throwing projection is still rejected rather than treated as successful delivery', () => {
    const f = fixture()
    f.state.relocate({ sectionURL: chapter('one') })
    f.state.onState = failure
    assert.throws(() => f.state.apply(f.requests[0].requestID, f.response(f.requests[0])),
        /Outgoing presentation cleanup failed/)
    assert.equal(f.state.ready, false)
    f.state.onState = () => {}
    assert.equal(f.state.refresh(), true)
    f.accept(f.requests.at(-1), 2)
})
