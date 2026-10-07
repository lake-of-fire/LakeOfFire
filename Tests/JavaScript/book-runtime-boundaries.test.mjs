import assert from 'node:assert/strict'
import test from 'node:test'
import { pathToFileURL } from 'node:url'
const source = process.env.LAKE_RUNTIME_SOURCE
    ? pathToFileURL(process.env.LAKE_RUNTIME_SOURCE)
    : new URL('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-runtime.js', import.meta.url)
const { installBookReadingRuntime } = await import(source)

class Element extends EventTarget {
    attributes = new Map()
    classList = { add() {}, remove() {} }
    isConnected = true
    inert = false
    hidden = false
    append() {}
    setAttribute(key, value) { this.attributes.set(key, value) }
    getAttribute(key) { return this.attributes.get(key) ?? null }
    removeAttribute(key) { this.attributes.delete(key) }
    querySelector(key) {
        this.nodes ??= new Map()
        if (!this.nodes.has(key)) this.nodes.set(key, new Element())
        return this.nodes.get(key)
    }
    focus() {}
    remove() { this.isConnected = false }
}
function fixture(t) {
    const requests = [], projections = [], visibility = [], invalidations = [], moves = []
    const makeDocument = name => {
        const frame = { manabi_bookReadingScope: null, applied: [], cleared: 0 }
        frame.manabi_invalidateBookReadingScope = () => { frame.cleared++; frame.manabi_bookReadingScope = null }
        frame.manabi_applyBookReadingPresentation = state => { frame.applied.push(state.revision); return true }
        return { location: { href: `ebook://section/${name}` }, defaultView: frame }
    }
    const a = makeDocument('a'), b = makeDocument('b'), c = makeDocument('c')
    let contents = [{ index: 0, doc: a }, { index: 1, doc: b }]
    const renderer = {
        displayedIndex: 0, getContents: () => contents,
        goTo: async target => { moves.push(target); renderer.displayedIndex = target.index; return true },
    }
    const view = new Element()
    view.renderer = renderer
    view.book = { sections: [{ id: 'a', linear: 'yes' }, { id: 'b', linear: 'yes' }] }
    const reader = { view }, document = { createElement: () => new Element(), getElementById: () => new Element(), activeElement: new Element() }
    const window = { location: { href: 'ebook://book' }, webkit: { messageHandlers: {
        ebookBookAction: { postMessage() {} }, ebookBookReadingState: { postMessage: packet => requests.push(packet) },
    } } }
    const runtime = installBookReadingRuntime({ reader, view, window, document, documentStartedAtMs: 1,
        applyProjection: state => projections.push(state.revision),
        invalidateProjection: () => invalidations.push(true), onVisibility: value => visibility.push(value) })
    let id = 0
    runtime.state.makeRequestID = () => String(++id)
    runtime.updateLocation()
    t.after(() => { try { runtime.close() } catch (_) {} })
    const response = (revision = 1, stamp = runtime.state.accountPresentation ?? '1:1') => {
        const isEndPage = runtime.state.location.isEndPage
        const scope = isEndPage ? null : { articleProgressID: 'book', articleEpochID: 'pass',
            chapterKey: 'a'.repeat(64), chapterEpochID: null }
        return { ok: true, accountPresentation: stamp,
            state: { revision, articleProgressID: 'book', articleEpochID: 'pass', scope, finished: false,
                readSegmentIdentifiers: ['s'], sentenceIdentifiersRead: ['t'], bookReadPresence: 'present',
                chapterReadPresence: isEndPage ? 'empty' : 'present' },
            context: { contextID: `context-${revision}`, articleProgressID: 'book', articleEpochID: 'pass', scope,
                isEndPage, sectionLocation: isEndPage ? null : 'a' } }
    }
    const publish = (revision = 1, stamp) => runtime.state.apply(requests.at(-1).requestID, response(revision, stamp))
    const native = revision => runtime.state.apply('native', { ...response(revision), nativeRefresh: true,
        location: { ...runtime.state.location, locationRevision: runtime.state.locationRevision } })
    const target = () => ({ action: 'startBookOver', accountPresentation: runtime.state.accountPresentation,
        articleProgressID: 'book', articleEpochID: 'pass', locationRevision: runtime.state.locationRevision })
    return { runtime, reader, view, renderer, window, a, b, c, projections, invalidations, visibility, moves, requests,
        response, publish, native, target, setContents: next => { contents = next } }
}

for (const seam of ['callback', 'lookup']) {
    test(`hidden frame ${seam} failure cannot strand active publication`, t => {
        const f = fixture(t)
        assert.equal(f.publish(), true)
        const fail = () => { throw new Error('retired frame') }
        if (seam === 'callback') f.b.defaultView.manabi_invalidateBookReadingScope = fail
        else Object.defineProperty(f.b.defaultView, 'manabi_invalidateBookReadingScope', { get: fail })
        f.runtime.state.refresh()
        assert.doesNotThrow(() => assert.equal(f.publish(2), true))
        assert.deepEqual(f.projections, [1, 2])
        assert.equal(f.runtime.state.ready, true)
        assert.equal(f.b.defaultView.manabi_bookReadingScope, null)
    })
}

for (const seam of ['frame', 'enumeration', 'shell']) {
    test(`close restores an inert publication despite ${seam} cleanup failure`, t => {
        const f = fixture(t)
        f.runtime.endcap.enter()
        assert.equal(f.publish(), true)
        assert.equal(f.view.inert, true)
        if (seam === 'frame') f.a.defaultView.manabi_invalidateBookReadingScope = () => { throw new Error('frame gone') }
        if (seam === 'enumeration') f.renderer.getContents = () => { throw new Error('renderer gone') }
        if (seam === 'shell') f.runtime.state.onInvalidate = () => { throw new Error('shell observer failed') }
        assert.doesNotThrow(() => f.runtime.close())
        assert.equal(f.view.inert, false)
        assert.equal(f.runtime.endcap.visible, false)
        assert.equal(f.runtime.endcap.element.isConnected, false)
        assert.equal(f.runtime.state.ready, false)
        assert.equal(f.runtime.captureEvent(f.a), null)
    })
}

test('one failed frame invalidation cannot leave sibling scopes or end-page readiness active', t => {
    const f = fixture(t)
    f.runtime.endcap.enter()
    assert.equal(f.publish(), true)
    f.a.defaultView.manabi_invalidateBookReadingScope = () => { throw new Error('frame failed') }
    f.a.defaultView.manabi_bookReadingScope = { stale: 'a' }
    f.b.defaultView.manabi_bookReadingScope = { stale: 'b' }
    f.runtime.state.refresh()
    assert.doesNotThrow(() => f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' }))
    assert.equal(f.runtime.endcap.button.disabled, true)
    assert.equal(f.a.defaultView.manabi_bookReadingScope, null)
    assert.equal(f.b.defaultView.manabi_bookReadingScope, null)
})

test('a failing outgoing frame does not block a newly displayed document', t => {
    const f = fixture(t)
    f.publish()
    f.a.defaultView.manabi_invalidateBookReadingScope = () => { throw new Error('outgoing frame failed') }
    f.setContents([{ index: 0, doc: f.c }])
    assert.doesNotThrow(() => f.runtime.updateLocation())
    assert.equal(f.publish(2), true)
    assert.ok(f.runtime.captureEvent(f.c))
})

test('nested document replacement wins over the original outgoing cleanup', t => {
    const f = fixture(t)
    f.publish()
    const clear = f.a.defaultView.manabi_invalidateBookReadingScope
    f.a.defaultView.manabi_invalidateBookReadingScope = () => {
        f.a.defaultView.manabi_invalidateBookReadingScope = clear
        clear()
        f.setContents([{ index: 0, doc: f.c }])
        f.runtime.updateLocation()
        assert.equal(f.publish(2), true)
    }
    f.setContents([{ index: 0, doc: f.b }])
    f.runtime.updateLocation()
    assert.equal(f.runtime.state.ready, true)
    assert.equal(f.runtime.state.context.contextID, 'context-2')
    assert.ok(f.runtime.captureEvent(f.c))
    assert.deepEqual(f.c.defaultView.applied, [2])
})

for (const seam of ['scope-setter', 'projector-lookup']) {
    for (const transition of ['new-publication', 'close']) {
        test(`${seam} ${transition} cannot invoke the older frame projector`, t => {
            const f = fixture(t)
            f.publish()
            const frame = f.a.defaultView, project = frame.manabi_applyBookReadingPresentation
            const reenter = () => {
                if (transition === 'close') f.runtime.close()
                else assert.equal(f.native(3), true)
            }
            if (seam === 'scope-setter') {
                Object.defineProperty(frame, 'manabi_bookReadingScope', { configurable: true, set(value) {
                    Object.defineProperty(frame, 'manabi_bookReadingScope', { value, writable: true, configurable: true })
                    reenter()
                } })
            } else {
                Object.defineProperty(frame, 'manabi_applyBookReadingPresentation', { configurable: true, get() {
                    Object.defineProperty(frame, 'manabi_applyBookReadingPresentation', { value: project, writable: true, configurable: true })
                    reenter()
                    return project
                } })
            }
            assert.equal(f.native(2), false)
            assert.deepEqual(frame.applied, transition === 'close' ? [1] : [1, 3])
            assert.deepEqual(f.projections, transition === 'close' ? [1] : [1, 3])
        })
    }
}

test('invalidation callback lookup cannot erase a reentrant recovered scope', t => {
    const f = fixture(t)
    f.publish()
    const frame = f.a.defaultView, clear = frame.manabi_invalidateBookReadingScope
    Object.defineProperty(frame, 'manabi_invalidateBookReadingScope', { configurable: true, get() {
        Object.defineProperty(frame, 'manabi_invalidateBookReadingScope', { value: clear, writable: true, configurable: true })
        f.runtime.state.refresh()
        assert.equal(f.publish(2), true)
        return clear
    } })
    f.runtime.state.refresh()
    f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' })
    assert.equal(f.runtime.state.ready, true)
    assert.ok(frame.manabi_bookReadingScope, 'Old callback erased the recovered frame scope')
    assert.ok(f.runtime.captureEvent(f.a))
})

for (const seam of ['spine', 'handler']) {
    for (const transition of ['account', 'location', 'renderer', 'close']) {
        test(`navigation rechecks ${transition} after ${seam} lookup`, async t => {
            const f = fixture(t)
            f.publish()
            const target = f.target()
            const retire = () => {
                if (transition === 'account') f.runtime.accountDidChange('2:1')
                if (transition === 'location') f.runtime.updateLocation(true)
                if (transition === 'renderer') f.view.renderer = { displayedIndex: 0, getContents: () => [] }
                if (transition === 'close') f.runtime.close()
            }
            if (seam === 'spine') Object.defineProperty(f.view.book.sections[0], 'linear', { get() { retire(); return 'yes' } })
            else {
                const goTo = f.renderer.goTo
                Object.defineProperty(f.renderer, 'goTo', { get() { retire(); return goTo } })
            }
            assert.deepEqual(await f.runtime.navigate(target), { status: 'superseded' })
            assert.deepEqual(f.moves, [], 'Retired native action still dispatched a physical navigation')
        })
    }
}

test('ordinary acknowledged navigation may move to a new document and location revision', async t => {
    const f = fixture(t)
    f.publish()
    f.renderer.goTo = async target => {
        f.moves.push(target)
        f.setContents([{ index: 0, doc: f.c }])
        f.runtime.updateLocation(true)
        f.publish(2)
        return true
    }
    assert.deepEqual(await f.runtime.navigate(f.target()), { status: 'completed' })
    assert.equal(f.moves.length, 1)
})

for (const gap of ['empty-contents', 'hidden-only', 'enumeration-error']) {
    test(`${gap} between chapters cannot expose the previous action context`, t => {
        const f = fixture(t)
        f.publish()
        const old = f.runtime.captureEvent(f.a)
        if (gap === 'empty-contents') f.setContents([])
        if (gap === 'hidden-only') f.setContents([{ index: 0, doc: f.a, isDisplayed: false }])
        if (gap === 'enumeration-error') f.renderer.getContents = () => { throw new Error('loading renderer') }
        assert.doesNotThrow(() => f.runtime.updateLocation())
        assert.equal(f.runtime.state.ready, false)
        assert.throws(() => f.runtime.state.captureContext())
        assert.equal(f.runtime.isEventCurrent(old), false)
        assert.equal(f.a.defaultView.manabi_bookReadingScope, null)
        assert.equal(f.native(2), false, 'A missing display cannot accept a native sample for the old chapter')
        f.renderer.getContents = () => [{ index: 0, doc: f.c }]
        f.runtime.updateLocation()
        assert.equal(f.publish(3), true)
        assert.ok(f.runtime.captureEvent(f.c))
    })
}

test('the end page remains a legitimate shell location without a chapter document', t => {
    const f = fixture(t)
    f.runtime.endcap.enter()
    f.setContents([])
    f.runtime.updateLocation()
    assert.equal(f.publish(), true)
    assert.equal(f.runtime.state.ready, true)
    assert.equal(f.runtime.endcap.button.disabled, false)
    assert.equal(f.runtime.state.context.isEndPage, true)
})

for (const receipt of [
    { ignored: true, superseded: true, reason: 'paginatorNavigationSuperseded' },
    { movementDisposition: 'not-owned', reason: 'rendererDestroyed' },
]) {
    test(`renderer ${receipt.reason} is not presented as retryable navigation failure`, async t => {
        const f = fixture(t)
        f.publish()
        f.renderer.goTo = async () => receipt
        assert.deepEqual(await f.runtime.navigate(f.target()), { status: 'superseded' })
        assert.deepEqual(f.moves, [])
    })
}

test('a genuine no-move result remains a retryable navigation failure', async t => {
    const f = fixture(t)
    f.publish()
    f.renderer.goTo = async () => false
    assert.deepEqual(await f.runtime.navigate(f.target()), { status: 'failed' })
})

test('completion index lookup cannot acknowledge a retired account', async t => {
    const f = fixture(t)
    f.publish()
    f.renderer.goTo = async () => {
        Object.defineProperty(f.renderer, 'displayedIndex', { configurable: true, get() {
            Object.defineProperty(f.renderer, 'displayedIndex', { value: 0, writable: true, configurable: true })
            f.runtime.accountDidChange('2:1')
            return 0
        } })
        return true
    }
    assert.deepEqual(await f.runtime.navigate(f.target()), { status: 'superseded' })
})

test('a throwing invalidator that recovers first cannot erase the newer scope through fallback', t => {
    const f = fixture(t)
    f.publish()
    const frame = f.a.defaultView, clear = frame.manabi_invalidateBookReadingScope
    frame.manabi_invalidateBookReadingScope = () => {
        frame.manabi_invalidateBookReadingScope = clear
        clear()
        f.runtime.state.refresh()
        assert.equal(f.publish(2), true)
        throw new Error('old wrapper failed after recovery')
    }
    f.runtime.state.refresh()
    assert.doesNotThrow(() => f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' }))
    assert.equal(f.runtime.state.ready, true)
    assert.ok(frame.manabi_bookReadingScope)
    assert.ok(f.runtime.captureEvent(f.a))
})

test('active projection failure is not silently reported as accepted rendering', t => {
    const f = fixture(t)
    f.publish()
    const project = f.a.defaultView.manabi_applyBookReadingPresentation
    f.a.defaultView.manabi_applyBookReadingPresentation = () => { throw new Error('active projection failed') }
    f.runtime.state.refresh()
    assert.throws(() => f.publish(2), /active projection failed/)
    assert.deepEqual(f.projections, [1])
    f.a.defaultView.manabi_applyBookReadingPresentation = project
    f.runtime.state.refresh()
    assert.equal(f.publish(3), true)
    assert.deepEqual(f.projections, [1, 3])
})

for (const entry of ['scope', 'event']) {
    test(`same-scope recovery during ${entry} validation cannot revive a retired receipt`, t => {
        const f = fixture(t)
        f.publish()
        const receipt = entry === 'scope' ? f.runtime.captureScope(f.a) : f.runtime.captureEvent(f.a)
        const getContents = f.renderer.getContents
        f.renderer.getContents = () => {
            f.renderer.getContents = getContents
            f.runtime.state.refresh()
            f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' })
            f.runtime.state.refresh()
            assert.equal(f.publish(2), true)
            return getContents()
        }
        assert.equal(entry === 'scope' ? f.runtime.isScopeCurrent(receipt, f.a) : f.runtime.isEventCurrent(receipt), false,
            'The guard sampled receipt ownership before reentry and returned successor approval')
        assert.equal(f.runtime.isEventCurrent(f.runtime.captureEvent(f.a)), true)
    })
}

for (const entry of ['scope', 'event']) {
    for (const boundary of ['invalidation', 'account', 'page-turn']) {
        test(`${entry} capture cannot adopt ${boundary} occurring during document lookup`, t => {
            const f = fixture(t)
            f.publish()
            const getContents = f.renderer.getContents
            f.renderer.getContents = () => {
                f.renderer.getContents = getContents
                if (boundary === 'invalidation') {
                    f.runtime.state.refresh()
                    f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' })
                    f.runtime.state.refresh()
                    assert.equal(f.publish(2), true)
                } else if (boundary === 'account') {
                    f.runtime.accountDidChange('2:1')
                    assert.equal(f.publish(2, '2:1'), true)
                } else {
                    f.runtime.updateLocation(true)
                    assert.equal(f.publish(2), true)
                }
                return getContents()
            }
            assert.equal(entry === 'scope' ? f.runtime.captureScope(f.a) : f.runtime.captureEvent(f.a), null,
                'Capture acquired the replacement account/page without a new originating event')
            assert.ok(f.runtime.captureEvent(f.a), 'A newly observed event must still be admissible')
        })
    }
}

test('same-pass successful background publication still preserves earlier scope and event receipts', t => {
    const f = fixture(t)
    f.publish()
    const scope = f.runtime.captureScope(f.a), event = f.runtime.captureEvent(f.a)
    const getContents = f.renderer.getContents
    f.renderer.getContents = () => {
        f.renderer.getContents = getContents
        f.runtime.state.refresh()
        assert.equal(f.publish(2), true)
        return getContents()
    }
    assert.equal(f.runtime.isScopeCurrent(scope, f.a), true)
    assert.equal(f.runtime.isEventCurrent(event), true)
})

for (const boundary of ['invalidation', 'account']) {
    test(`scope capture rechecks ${boundary} after its section URL accessor`, t => {
        const f = fixture(t)
        f.publish()
        const href = f.a.location.href
        Object.defineProperty(f.a.location, 'href', { configurable: true, get() {
            Object.defineProperty(f.a.location, 'href', { value: href, configurable: true, writable: true })
            if (boundary === 'account') f.runtime.accountDidChange('2:1')
            else {
                f.runtime.state.refresh()
                f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' })
                f.runtime.state.refresh()
            }
            assert.equal(f.publish(2), true)
            return href
        } })
        assert.equal(f.runtime.captureScope(f.a), null)
        assert.ok(f.runtime.captureScope(f.a))
    })
}

test('scope comparison revalidates the original receipt after a scope wrapper accessor', t => {
    const f = fixture(t)
    f.publish()
    const scope = f.runtime.captureScope(f.a), epoch = scope.articleEpochID
    Object.defineProperty(scope, 'articleEpochID', { configurable: true, get() {
        Object.defineProperty(scope, 'articleEpochID', { value: epoch, configurable: true, writable: true })
        f.runtime.state.refresh()
        f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' })
        f.runtime.state.refresh()
        assert.equal(f.publish(2), true)
        return epoch
    } })
    assert.equal(f.runtime.isScopeCurrent(scope, f.a), false,
        'An equal key is not permission to reacquire a retired scope receipt')
    assert.equal(f.runtime.isScopeCurrent(f.runtime.captureScope(f.a), f.a), true)
})

test('a non-callable installed projector remains an error, not a successful publication', t => {
    const f = fixture(t)
    f.publish()
    f.a.defaultView.manabi_applyBookReadingPresentation = 'invalid installed interface'
    f.runtime.state.refresh()
    assert.throws(() => f.publish(2), TypeError)
    assert.deepEqual(f.projections, [1])
})

// Additive close ownership checks; all donor assertions remain above.
test('close never enumerates a renderer installed by an earlier cleanup phase', t => {
    const f = fixture(t)
    f.publish()
    const successor = { successor: true }
    const close = f.runtime.bridge.close
    f.runtime.bridge.close = () => {
        close.call(f.runtime.bridge)
        f.c.defaultView.manabi_bookReadingScope = successor
        f.view.renderer = { displayedIndex: 0, getContents: () => [{ index: 0, doc: f.c }] }
    }
    f.runtime.close()
    assert.equal(f.c.defaultView.manabi_bookReadingScope, successor)
    assert.equal(f.c.defaultView.cleared, 0)
    assert.equal(f.a.defaultView.manabi_bookReadingScope, null)
})

test('close preserves a successor scope installed in a captured frame during teardown', t => {
    const f = fixture(t)
    f.publish()
    const successor = { successor: true }, close = f.runtime.bridge.close
    f.runtime.bridge.close = () => {
        close.call(f.runtime.bridge)
        f.a.defaultView.manabi_bookReadingScope = successor
    }
    const cleared = f.a.defaultView.cleared
    f.runtime.close()
    assert.equal(f.a.defaultView.manabi_bookReadingScope, successor)
    assert.equal(f.a.defaultView.cleared, cleared)
})

test('close invalidates each retiring document once even when observation repeats it', t => {
    const f = fixture(t)
    f.publish()
    const a = f.a.defaultView.cleared, b = f.b.defaultView.cleared
    f.runtime.close()
    assert.equal(f.a.defaultView.cleared, a + 1)
    assert.equal(f.b.defaultView.cleared, b + 1)
})

test('frame token replacement in callback lookup does not borrow an unchanged publication guard', t => {
    const f = fixture(t)
    f.publish()
    const frame = f.b.defaultView, successor = { successor: true }
    const clear = frame.manabi_invalidateBookReadingScope
    Object.defineProperty(frame, 'manabi_invalidateBookReadingScope', { configurable: true, get() {
        Object.defineProperty(frame, 'manabi_invalidateBookReadingScope', { value: clear, writable: true, configurable: true })
        frame.manabi_bookReadingScope = successor
        return clear
    } })
    f.runtime.state.refresh()
    assert.equal(f.publish(2), true)
    assert.equal(frame.manabi_bookReadingScope, successor)
})


test('close uses the captured retiring frame when document frame lookup is replaced', t => {
    const f = fixture(t)
    assert.equal(f.publish(), true)
    const outgoing = f.a.defaultView, cleared = outgoing.cleared
    const successor = { successor: true }
    const replacement = { manabi_bookReadingScope: successor, cleared: 0 }
    replacement.manabi_invalidateBookReadingScope = () => {
        replacement.cleared++
        replacement.manabi_bookReadingScope = null
    }
    const close = f.runtime.bridge.close
    f.runtime.bridge.close = () => {
        close.call(f.runtime.bridge)
        Object.defineProperty(f.a, 'defaultView', { configurable: true, get: () => replacement })
    }
    f.runtime.close()
    assert.equal(replacement.manabi_bookReadingScope, successor,
        'old close cannot borrow the replacement frame from a later document lookup')
    assert.equal(replacement.cleared, 0)
    assert.equal(outgoing.cleared, cleared + 1, 'the captured outgoing frame still receives cleanup')
    assert.equal(outgoing.manabi_bookReadingScope, null)
})
