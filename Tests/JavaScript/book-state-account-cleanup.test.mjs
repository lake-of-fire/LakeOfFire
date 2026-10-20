import assert from 'node:assert/strict'
import { test } from 'node:test'
import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'

const chapter = 'https://reader.invalid/chapter.xhtml'
const failCleanup = () => { throw new Error('Outgoing account presentation cleanup failed') }

function fixture({ endPage = false } = {}) {
    const requests = [], published = [], accounts = []
    let requestSequence = 0
    const state = new BookReadingStateController({
        postMessage: message => requests.push(message),
        topWindowURL: 'ebook://ebook/load/local/book.epub', documentStartedAtMs: 100,
        requiresAccountPresentation: true,
        makeRequestID: () => `request-${++requestSequence}`,
        onState: projection => published.push(projection),
        onAccountChange: stamp => accounts.push(stamp),
    })
    const response = (account, revision = 1, request = requests.at(-1)) => {
        const articleProgressID = `article-${account}`
        const scope = request.isEndPage ? null : {
            articleProgressID, articleEpochID: null,
            chapterKey: 'a'.repeat(64), chapterEpochID: null,
        }
        return {
            ok: true, accountPresentation: account,
            state: { revision, articleProgressID, articleEpochID: null, scope,
                finished: false, bookReadPresence: 'empty', chapterReadPresence: 'empty',
                readSegmentIdentifiers: [], sentenceIdentifiersRead: [] },
            context: { contextID: `context-${account}-${revision}`, articleProgressID,
                articleEpochID: null, scope, isEndPage: request.isEndPage,
                sectionLocation: request.sectionURL },
        }
    }
    assert.equal(state.setAccountPresentation('1:0'), true)
    state.relocate(endPage ? { isEndPage: true } : { sectionURL: chapter })
    assert.equal(state.apply(requests[0].requestID, response('1:0', 50)), true)
    return { state, requests, published, accounts, response }
}

for (const endPage of [false, true]) {
    test(`a correlated new-account reply survives outgoing cleanup failure (endPage=${endPage})`, () => {
        const f = fixture({ endPage })
        assert.equal(f.state.refresh(), true)
        const request = f.requests.at(-1)
        f.state.onInvalidate = failCleanup
        let accepted, error
        try { accepted = f.state.apply(request.requestID, f.response('2:0')) }
        catch (caught) { error = caught }
        assert.equal(f.state.ready, true, 'The correlated current-account sample must remain deliverable')
        assert.equal(error, undefined)
        assert.equal(accepted, true)
        assert.equal(f.state.accountPresentation, '2:0')
        assert.equal(f.state.state.revision, 1, 'The new account owns a fresh snapshot sequence')
        assert.equal(f.state.captureContext().articleProgressID, 'article-2:0')
        assert.deepEqual(f.accounts, ['1:0', '2:0'])
        assert.equal(f.requests.length, 2, 'Cleanup failure must not issue extra reads or mutations')
        assert.equal(f.state.apply(request.requestID, f.response('2:0')), false)
    })
}

test('a failing invalidation getter cannot consume new-account reply admission', () => {
    const f = fixture()
    f.state.refresh()
    Object.defineProperty(f.state, 'onInvalidate', { configurable: true, get: failCleanup })
    let accepted = false
    try { accepted = f.state.apply(f.requests.at(-1).requestID, f.response('2:0')) } catch (_) {}
    assert.equal(accepted, true)
    assert.equal(f.state.ready, true)
    assert.equal(f.state.captureContext().articleProgressID, 'article-2:0')
})

test('direct account notification remains admitted for the runtime-owned refresh', () => {
    const f = fixture()
    f.state.onInvalidate = failCleanup
    let changed
    try { changed = f.state.setAccountPresentation('2:0') } catch (_) {}
    assert.equal(changed, true, 'The runtime refresh is conditional on this returned admission')
    assert.equal(f.state.ready, false, 'Account notification alone is not a native sample')
    assert.equal(f.requests.length, 1)
    assert.equal(f.state.refresh(), true)
    assert.equal(f.state.apply(f.requests.at(-1).requestID, f.response('2:0')), true)
})

test('a nested replacement read retains its reply slot when cleanup throws', () => {
    const f = fixture()
    f.state.refresh()
    const old = f.requests.at(-1)
    f.state.onInvalidate = () => {
        f.state.refresh()
        failCleanup()
    }
    let accepted = false
    try { accepted = f.state.apply(old.requestID, f.response('2:0')) } catch (_) {}
    assert.equal(accepted, false)
    assert.equal(f.state.ready, false)
    assert.equal(f.requests.length, 3)
    const next = f.requests.at(-1)
    assert.equal(f.state.apply(next.requestID, f.response('2:0')), true)
    assert.equal(f.state.apply(old.requestID, f.response('2:0', 2)), false)
})

test('a newer account published during failing cleanup cannot be overwritten', () => {
    const f = fixture()
    f.state.refresh()
    const old = f.requests.at(-1)
    f.state.onInvalidate = () => {
        f.state.onInvalidate = () => {}
        f.state.setAccountPresentation('3:0')
        f.state.refresh()
        const next = f.requests.at(-1)
        assert.equal(f.state.apply(next.requestID, f.response('3:0')), true)
        failCleanup()
    }
    let accepted = false
    try { accepted = f.state.apply(old.requestID, f.response('2:0')) } catch (_) {}
    assert.equal(accepted, false)
    assert.equal(f.state.accountPresentation, '3:0')
    assert.equal(f.state.ready, true)
    assert.equal(f.state.captureContext().articleProgressID, 'article-3:0')
    assert.deepEqual(f.published.map(value => value.articleProgressID), ['article-1:0', 'article-3:0'])
})

test('closing during failing cleanup cannot restore the new-account reply', () => {
    const f = fixture()
    f.state.refresh()
    f.state.onInvalidate = () => {
        f.state.onInvalidate = () => {}
        f.state.close()
        failCleanup()
    }
    let accepted = false
    try { accepted = f.state.apply(f.requests.at(-1).requestID, f.response('2:0')) } catch (_) {}
    assert.equal(accepted, false)
    assert.equal(f.state.ready, false)
    assert.equal(f.state.state, null)
    assert.equal(f.state.refresh(), false)
    assert.equal(f.requests.length, 2)
})

test('cleanup tolerance does not accept a refused new-account projection', () => {
    const f = fixture()
    f.state.refresh()
    f.state.onInvalidate = failCleanup
    f.state.onState = () => false
    let accepted = false
    try { accepted = f.state.apply(f.requests.at(-1).requestID, f.response('2:0')) } catch (_) {}
    assert.equal(accepted, false)
    assert.equal(f.state.ready, false)
    assert.equal(f.state.state, null)
    f.state.onState = projection => f.published.push(projection)
    assert.equal(f.state.refresh(), true)
    assert.equal(f.state.apply(f.requests.at(-1).requestID, f.response('2:0', 2)), true)
})
