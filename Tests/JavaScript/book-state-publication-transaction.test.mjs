import assert from 'node:assert/strict'
import test from 'node:test'
import { pathToFileURL } from 'node:url'
const source = process.env.LAKE_BOOK_STATE_SOURCE
    ? pathToFileURL(process.env.LAKE_BOOK_STATE_SOURCE).href
    : new URL('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js', import.meta.url).href
const { BookReadingStateController } = await import(source)

function response(revision = 1, stamp = undefined, end = false) {
    const scope = end ? null : { articleProgressID: 'book', articleEpochID: 'pass',
        chapterKey: 'a'.repeat(64), chapterEpochID: null }
    return { ok: true, ...(stamp === undefined ? {} : { accountPresentation: stamp }),
        state: { revision, articleProgressID: 'book', articleEpochID: 'pass', scope,
            finished: false, bookReadPresence: 'present', chapterReadPresence: end ? 'empty' : 'present',
            readSegmentIdentifiers: ['segment-' + revision], sentenceIdentifiersRead: ['sentence-' + revision] },
        context: { contextID: 'context-' + revision, articleProgressID: 'book', articleEpochID: 'pass', scope,
            isEndPage: end, sectionLocation: end ? null : 'chapter.xhtml' } }
}
function fixture() {
    const posts = [], paints = [], invalidations = []
    let serial = 0
    const controller = new BookReadingStateController({
        postMessage: packet => posts.push(packet), makeRequestID: () => 'request-' + ++serial,
        documentStartedAtMs: 100, topWindowURL: 'ebook://book',
        onState: (state, context, details, isCurrent) => paints.push({ state, context, details, isCurrent }),
        onInvalidate: () => invalidations.push(controller.context),
    })
    controller.relocate({ sectionURL: 'chapter.xhtml' })
    const apply = value => controller.apply(posts.at(-1).requestID, value)
    const native = value => controller.apply('native', { ...value, nativeRefresh: true,
        location: { ...controller.location, locationRevision: controller.locationRevision } })
    return { controller, posts, paints, invalidations, apply, native }
}
function oneShot(object, key, action, value) {
    Object.defineProperty(object, key, { configurable: true, get() {
        Object.defineProperty(object, key, { configurable: true, writable: true, value })
        action()
        return value
    } })
}

for (const field of ['state', 'context']) {
    test(`${field} copy failure leaves the original reply retryable and its watermark unconsumed`, () => {
        const f = fixture()
        assert.equal(f.apply(response()), true)
        f.controller.refresh()
        const request = f.posts.at(-1).requestID
        const previous = { state: f.controller.state, context: f.controller.context }
        const broken = response(100)
        broken[field].toJSON = () => { throw new Error('copy failed') }
        let result
        assert.doesNotThrow(() => { result = f.controller.apply(request, broken) })
        assert.equal(result, false)
        assert.deepEqual(f.controller.state, previous.state)
        assert.deepEqual(f.controller.context, previous.context)
        assert.equal(f.controller.apply(request, response(2)), true,
            'the failed preparation must not consume the pending ID or revision 100')
        assert.equal(f.paints.length, 2)
    })
    test(`${field} toJSON output is validated, not only its original properties`, () => {
        const f = fixture(), packet = response()
        packet[field].toJSON = () => field === 'state'
            ? { ...packet.state, revision: 0, toJSON: undefined }
            : { ...packet.context, contextID: '', toJSON: undefined }
        assert.equal(f.apply(packet), false)
        assert.equal(f.controller.ready, false)
        assert.equal(f.apply(response()), true)
    })
    for (const replacement of ['newer publication', 'new request', 'account', 'closed']) {
        test(`${field} serialization cannot replace ${replacement}`, () => {
            const f = fixture(), packet = response(10)
            let reentered = false
            packet[field].toJSON = function () {
                delete this.toJSON
                reentered = true
                if (replacement === 'newer publication') assert.equal(f.native(response(20)), true)
                if (replacement === 'new request') f.controller.refresh()
                if (replacement === 'account') f.controller.setAccountPresentation('2:1')
                if (replacement === 'closed') f.controller.close()
                return this
            }
            assert.equal(f.apply(packet), false)
            assert.equal(reentered, true)
            if (replacement === 'newer publication') {
                assert.equal(f.controller.state.revision, 20)
                assert.equal(f.paints.length, 1)
            } else {
                assert.equal(f.controller.context, null)
                assert.equal(f.controller.state, null)
                assert.equal(f.paints.length, 0)
                if (replacement === 'new request') assert.equal(f.apply(response(2)), true)
            }
        })
    }
}

test('a failed reply getter cannot invalidate the newer accepted context', () => {
    const f = fixture(), packet = {}
    oneShot(packet, 'ok', () => f.native(response(20)), false)
    assert.equal(f.apply(packet), false)
    assert.equal(f.controller.state.revision, 20)
    assert.equal(f.controller.context.contextID, 'context-20')
    assert.equal(f.controller.ready, true)
})
test('onState getter cannot invoke an old renderer after it publishes a successor', () => {
    const f = fixture(), original = f.controller.onState
    let staleCalls = 0
    Object.defineProperty(f.controller, 'onState', { configurable: true, get() {
        Object.defineProperty(f.controller, 'onState', { configurable: true, writable: true, value: original })
        assert.equal(f.native(response(20)), true)
        return () => staleCalls++
    } })
    assert.equal(f.apply(response(10)), false)
    assert.equal(staleCalls, 0)
    assert.equal(f.controller.state.revision, 20)
})
test('watermark advanced during publication prevents the older native acknowledgement', () => {
    const f = fixture()
    f.controller.onState = () => assert.equal(f.controller.noteManualReadSnapshot(20), true)
    assert.equal(f.apply(response(10)), false)
    assert.equal(f.native(response(19)), false)
})
test('a queued refresh alone does not withdraw the current publication acknowledgement', () => {
    const f = fixture()
    f.controller.onState = () => f.controller.refresh()
    assert.equal(f.apply(response(10)), true)
    assert.equal(f.controller.state.revision, 10)
    f.controller.onState = () => {}
    assert.equal(f.apply(response(11)), true)
})

for (const field of ['makeRequestID', 'topWindowURL', 'postMessage']) {
    test(`refresh does not adopt a nested request during ${field} lookup`, () => {
        const f = fixture(), original = f.controller[field]
        let stalePosts = 0
        const restored = field === 'postMessage' ? packet => f.posts.push(packet) : original
        Object.defineProperty(f.controller, field, { configurable: true, get() {
            Object.defineProperty(f.controller, field, { configurable: true, writable: true, value: restored })
            assert.equal(f.controller.refresh(), true)
            return field === 'postMessage' ? () => stalePosts++ : original
        } })
        assert.equal(f.controller.refresh(), false)
        assert.equal(stalePosts, 0)
        assert.equal(f.posts.length, 2, 'only the initial and nested current requests may post')
        assert.equal(f.apply(response(2)), true)
    })
}
for (const sameID of [false, true]) {
    test(`throwing old bridge preserves nested refresh (same request ID: ${sameID})`, () => {
        const f = fixture()
        f.apply(response())
        if (sameID) f.controller.makeRequestID = () => 'same-id'
        f.controller.postMessage = packet => {
            f.posts.push(packet)
            f.controller.postMessage = next => f.posts.push(next)
            f.controller.refresh()
            throw new Error('old post failed')
        }
        assert.equal(f.controller.refresh(), false)
        assert.equal(f.controller.ready, true, 'old failure cannot invalidate retained current state')
        assert.equal(f.apply(response(2)), true, 'the nested request must remain pending')
        assert.equal(f.controller.state.revision, 2)
    })
}
test('postMessage throwing after a synchronous accepted reply does not undo it', () => {
    const f = fixture(), invalidations = f.invalidations.length
    f.controller.postMessage = packet => {
        f.posts.push(packet)
        assert.equal(f.controller.apply(packet.requestID, response(2)), true)
        throw new Error('optional wrapper after delivery')
    }
    assert.equal(f.controller.refresh(), false)
    assert.equal(f.controller.ready, true)
    assert.equal(f.controller.context.contextID, 'context-2')
    assert.equal(f.invalidations.length, invalidations)
})
test('failed request ID preparation does not consume the existing pending request', () => {
    const f = fixture()
    f.controller.makeRequestID = () => { throw new Error('unavailable') }
    assert.equal(f.controller.refresh(), false)
    assert.equal(f.apply(response()), true)
})
test('an ordinary failed bridge invalidates readiness without creating a retry loop', () => {
    const f = fixture()
    f.apply(response())
    let attempts = 0
    f.controller.postMessage = () => { attempts++; throw new Error('not sent') }
    assert.equal(f.controller.refresh(), false)
    assert.equal(f.controller.ready, false)
    assert.equal(attempts, 1)
})

test('account callback publication is not followed by an obsolete invalidation', () => {
    const f = fixture()
    assert.equal(f.apply(response(10, '1:1')), true)
    const invalidations = f.invalidations.length
    f.controller.onAccountChange = stamp => {
        f.controller.refresh()
        assert.equal(f.apply(response(1, stamp)), true)
    }
    assert.equal(f.controller.setAccountPresentation('2:1'), false,
        'the callback already owns the successor; its caller must not request another sample')
    assert.equal(f.controller.ready, true)
    assert.equal(f.controller.state.revision, 1)
    assert.equal(f.invalidations.length, invalidations)
})
test('account callback queuing a request still invalidates old projection but preserves that request', () => {
    const f = fixture()
    assert.equal(f.apply(response(10, '1:1')), true)
    const before = f.invalidations.length
    f.controller.onAccountChange = () => f.controller.refresh()
    assert.equal(f.controller.setAccountPresentation('2:1'), false)
    assert.equal(f.invalidations.length, before + 1)
    assert.equal(f.controller.ready, false)
    assert.equal(f.apply(response(1, '2:1')), true)
})
test('relocation callback cannot cause the older relocation to refresh the successor twice', () => {
    const f = fixture()
    f.controller.onInvalidate = () => {
        f.controller.onInvalidate = () => {}
        f.controller.relocate({ sectionURL: 'successor.xhtml' })
    }
    f.controller.relocate({ sectionURL: 'interrupted.xhtml' })
    assert.equal(f.posts.length, 2)
    assert.equal(f.posts.at(-1).sectionURL, 'successor.xhtml')
    assert.equal(f.controller.locationRevision, 3)
})
test('location validation cannot return true after closing the original controller', () => {
    const f = fixture()
    f.controller.isLocationCurrent = () => { f.controller.close(); return true }
    assert.equal(f.apply(response()), false)
    assert.equal(f.controller.state, null)
    assert.equal(f.controller.context, null)
})
test('closed controllers reject late manual snapshot acknowledgements', () => {
    const f = fixture()
    f.controller.close()
    assert.equal(f.controller.noteManualReadSnapshot(99), false)
})
test('onState receives detached copies and one current snapshot', () => {
    const f = fixture()
    f.controller.onState = (state, context, details, current) => {
        assert.equal(current(), true)
        state.readSegmentIdentifiers.push('changed-by-renderer')
        context.contextID = 'changed-by-renderer'
        assert.equal(details.passChanged, true)
    }
    assert.equal(f.apply(response()), true)
    assert.deepEqual(f.controller.state.readSegmentIdentifiers, ['segment-1'])
    assert.equal(f.controller.context.contextID, 'context-1')
})

for (const boundary of ['post lookup', 'post error']) {
    test(`a withdrawn ${boundary} releases only its pending slot after a manual watermark change`, () => {
        const f = fixture()
        f.apply(response())
        let withdrawnID = null
        const captureID = f.controller.makeRequestID
        f.controller.makeRequestID = () => (withdrawnID = captureID())
        if (boundary === 'post lookup') {
            oneShot(f.controller, 'postMessage', () => f.controller.noteManualReadSnapshot(20),
                () => { throw new Error('the stale post callback must not run') })
        } else {
            f.controller.postMessage = () => {
                f.controller.noteManualReadSnapshot(20)
                throw new Error('post failed')
            }
        }
        assert.equal(f.controller.refresh(), false)
        assert.equal(f.controller.ready, true, 'newer reading presentation must not be invalidated')
        assert.equal(f.controller.apply(withdrawnID, response(21)), false,
            'a withdrawn request cannot retain a phantom pending slot')
        f.controller.postMessage = packet => f.posts.push(packet)
        assert.equal(f.controller.refresh(), true)
        assert.equal(f.apply(response(19)), false, 'withdrawal must not reset the newer manual watermark')
        assert.equal(f.apply(response(21)), true)
    })
}
