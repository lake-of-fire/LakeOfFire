import assert from 'node:assert/strict'
import test from 'node:test'
import { pathToFileURL } from 'node:url'
const moduleURL = process.env.LAKE_RUNTIME_SOURCE
    ? pathToFileURL(process.env.LAKE_RUNTIME_SOURCE)
    : new URL('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-runtime.js', import.meta.url)
const { installBookReadingRuntime } = await import(moduleURL)

class Element extends EventTarget {
    attributes = new Map()
    children = []
    classes = new Set()
    classList = { add: x => this.classes.add(x), remove: x => this.classes.delete(x) }
    isConnected = true
    inert = false
    hidden = false
    append(node) { this.children.push(node) }
    setAttribute(name, value) { this.attributes.set(name, String(value)) }
    getAttribute(name) { return this.attributes.get(name) ?? null }
    removeAttribute(name) { this.attributes.delete(name) }
    querySelector(selector) {
        this.nodes ??= new Map()
        if (!this.nodes.has(selector)) this.nodes.set(selector, new Element())
        return this.nodes.get(selector)
    }
    focus() {}
    remove() { this.isConnected = false }
}
const drain = async () => { for (let i = 0; i < 10; i++) await Promise.resolve() }
function fixture(t) {
    const requests = [], commands = [], projections = [], invalidations = [], visibility = []
    const hooks = {}, timers = new Map()
    let serial = 0, runtime
    const makeDocument = name => {
        const win = { manabi_bookReadingScope: null, reads: [], clears: 0 }
        win.manabi_invalidateBookReadingScope = () => {
            win.clears++
            win.manabi_bookReadingScope = null
            win.reads = []
        }
        win.manabi_applyBookReadingPresentation = p => { win.reads = [...p.readSegmentIdentifiers]; return true }
        return { location: { href: `ebook://ebook/processed-section?subpath=${name}` }, defaultView: win }
    }
    const a = makeDocument('a.xhtml'), b = makeDocument('b.xhtml')
    const renderer = { displayedIndex: 0, getContents: () => [{ index: 1, doc: b }, { index: 0, doc: a }] }
    const view = new Element()
    view.renderer = renderer
    view.book = { sections: [{ id: 'a.xhtml', linear: 'yes' }, { id: 'b.xhtml', linear: 'yes' }] }
    const reader = { view }, host = new Element()
    const document = { createElement: () => new Element(), activeElement: new Element(), getElementById: () => host }
    const window = { location: { href: 'ebook://ebook/load/book.epub' }, webkit: { messageHandlers: {
        ebookBookReadingState: { postMessage: message => { requests.push(message); hooks.statePost?.(message) } },
        ebookBookAction: { postMessage: message => { commands.push(message); hooks.commandPost?.(message) } },
    } } }
    // The complete production bridge captures controlled host timer callbacks
    // at installation. No timer or native writer actually runs in this fixture.
    const set = globalThis.setTimeout, clear = globalThis.clearTimeout
    globalThis.setTimeout = fn => { timers.set(++serial, fn); return serial }
    globalThis.clearTimeout = id => { timers.delete(id); hooks.timerClear?.(id) }
    try {
        runtime = installBookReadingRuntime({ reader, view, document, window, documentStartedAtMs: 1,
            applyProjection: (p, d) => { projections.push(p); hooks.projection?.(p, d) },
            invalidateProjection: () => { invalidations.push(true); hooks.invalidate?.() },
            onVisibility: value => { visibility.push(value); hooks.visibility?.(value) },
        })
    } finally { globalThis.setTimeout = set; globalThis.clearTimeout = clear }
    runtime.state.makeRequestID = () => `read-${++serial}`
    runtime.updateLocation()
    const response = (revision = 1, stamp = '1:1', finished = false) => {
        const end = runtime.state.location.isEndPage
        const key = renderer.displayedIndex === 0 ? 'a' : 'b'
        const scope = end ? null : { articleProgressID: 'book', articleEpochID: 'pass',
            chapterKey: key.repeat(64), chapterEpochID: null }
        return { ok: true, accountPresentation: stamp,
            state: { revision, articleProgressID: 'book', articleEpochID: 'pass', scope, finished,
                bookReadPresence: 'present', chapterReadPresence: end ? 'empty' : 'present',
                readSegmentIdentifiers: end ? [] : [`read-${revision}`], sentenceIdentifiersRead: [] },
            context: { contextID: `context-${stamp}-${revision}`, articleProgressID: 'book', articleEpochID: 'pass',
                scope, sectionLocation: end ? null : `${key}.xhtml`, isEndPage: end } }
    }
    const publish = (revision = 1, stamp = '1:1', finished = false) => runtime.state.apply(requests.at(-1).requestID, response(revision, stamp, finished))
    t.after(() => {
        for (const key of Object.keys(hooks)) delete hooks[key]
        for (const doc of [a, b]) doc.defaultView.manabi_invalidateBookReadingScope = () => { doc.defaultView.manabi_bookReadingScope = null }
        try { runtime.close() } catch (_) {}
    })
    return { runtime, reader, view, host, renderer, document, a, b, requests, commands, projections,
        invalidations, visibility, timers, hooks, publish, response }
}

for (const phase of ['invalidate', 'publication', 'close']) {
    test(`one broken hidden frame cannot block ${phase} of the displayed end page`, t => {
        const f = fixture(t)
        f.runtime.endcap.enter()
        assert.equal(f.publish(1), true)
        f.b.defaultView.manabi_invalidateBookReadingScope = () => { throw new Error('hidden frame projection unavailable') }
        if (phase === 'invalidate') {
            const before = f.a.defaultView.clears
            f.runtime.state.refresh()
            assert.doesNotThrow(() => f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' }))
            assert.ok(f.a.defaultView.clears > before, 'Other frames must still be invalidated')
            assert.equal(f.runtime.endcap.button.disabled, true)
            assert.ok(f.invalidations.length > 0)
        } else if (phase === 'publication') {
            f.runtime.state.refresh()
            assert.doesNotThrow(() => assert.equal(f.publish(2, '1:1', true), true))
            assert.equal(f.runtime.endcap.button.textContent, 'Start Book Over')
            assert.equal(f.runtime.endcap.button.disabled, false)
            assert.equal(f.projections.at(-1).revision, 2)
        } else {
            assert.doesNotThrow(() => f.runtime.close())
            assert.equal(f.runtime.endcap.element.isConnected, false)
            assert.equal(f.view.inert, false)
            assert.equal(f.runtime.state.ready, false)
        }
    })
}

test('a broken hidden frame cannot prevent ordinary chapter hydration', t => {
    const f = fixture(t)
    assert.equal(f.publish(1), true)
    f.b.defaultView.manabi_invalidateBookReadingScope = () => { throw new Error('hidden') }
    f.runtime.state.refresh()
    assert.doesNotThrow(() => assert.equal(f.publish(2), true))
    assert.deepEqual(f.a.defaultView.reads, ['read-2'])
    assert.equal(f.projections.at(-1).revision, 2)
})

test('close restores the publication even if the optional shell invalidator throws', t => {
    const f = fixture(t)
    f.runtime.endcap.enter()
    assert.equal(f.publish(1), true)
    f.hooks.invalidate = () => { throw new Error('shell unmounted') }
    assert.doesNotThrow(() => f.runtime.close())
    assert.equal(f.runtime.endcap.element.isConnected, false)
    assert.equal(f.view.inert, false)
    assert.equal(f.runtime.state.ready, false)
    assert.doesNotThrow(() => f.runtime.close())
})

test('replacement document still relocates after outgoing frame cleanup fails', t => {
    const f = fixture(t)
    assert.equal(f.publish(1), true)
    const oldEvent = f.runtime.captureEvent(f.a)
    f.a.defaultView.manabi_invalidateBookReadingScope = () => { throw new Error('outgoing') }
    f.renderer.displayedIndex = 1
    assert.doesNotThrow(() => f.runtime.updateLocation(true))
    assert.equal(f.runtime.state.location.sectionURL, f.b.location.href)
    assert.equal(f.runtime.isEventCurrent(oldEvent), false)
    assert.doesNotThrow(() => assert.equal(f.publish(2), true))
    assert.ok(f.runtime.captureEvent(f.b))
})

test('account handoff retires old activation before bridge cleanup publishes fresh state', async t => {
    const f = fixture(t)
    f.runtime.endcap.enter()
    assert.equal(f.publish(1), true)
    const first = f.runtime.endcap.activate()
    assert.equal(f.commands.length, 1)
    f.hooks.timerClear = () => {
        delete f.hooks.timerClear
        f.runtime.state.refresh()
        assert.equal(f.publish(1, '2:1', true), true)
    }
    f.runtime.accountDidChange('2:1')
    await first
    await drain()
    assert.equal(f.runtime.state.accountPresentation, '2:1')
    assert.equal(f.runtime.state.ready, true)
    assert.equal(f.runtime.endcap.button.disabled, false)
    assert.equal(f.runtime.endcap.button.textContent, 'Start Book Over')
    assert.equal(f.runtime.endcap.error.hidden, true)
    assert.equal(f.runtime.bridge.recoveryInfo, null)
    assert.equal(f.commands.length, 1, 'Account handoff cannot replay the original mutation')
})

test('close does not leave one inaccessible frame scope active after enumeration throws', t => {
    const f = fixture(t)
    assert.equal(f.publish(1), true)
    assert.ok(f.a.defaultView.manabi_bookReadingScope)
    f.renderer.getContents = () => { throw new Error('renderer unmounted') }
    assert.doesNotThrow(() => f.runtime.close())
    assert.equal(f.a.defaultView.manabi_bookReadingScope, null)
    assert.equal(f.runtime.endcap.element.isConnected, false)
})

test('a hidden-frame callback cannot invalidate a newer accepted projection after throwing', t => {
    const f = fixture(t)
    f.runtime.endcap.enter()
    assert.equal(f.publish(1), true)
    const invalidate = f.b.defaultView.manabi_invalidateBookReadingScope
    f.b.defaultView.manabi_invalidateBookReadingScope = () => {
        f.b.defaultView.manabi_invalidateBookReadingScope = invalidate
        f.runtime.state.refresh()
        assert.equal(f.publish(2, '1:1', true), true)
        throw new Error('older cleanup after successor publication')
    }
    f.runtime.state.refresh()
    assert.doesNotThrow(() => f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' }))
    assert.equal(f.runtime.endcap.button.disabled, false)
    assert.equal(f.runtime.endcap.finished, true)
    assert.equal(f.runtime.state.state.revision, 2)
})

for (const seam of ['lookup', 'scope-assignment']) {
    test(`active-frame ${seam} cannot repaint a reentrant successor projection`, t => {
        const f = fixture(t)
        assert.equal(f.publish(1), true)
        let oldProjections = 0
        const original = f.a.defaultView.manabi_applyBookReadingPresentation
        const reenter = () => {
            f.runtime.state.refresh()
            assert.equal(f.publish(3), true)
        }
        if (seam === 'lookup') {
            Object.defineProperty(f.a.defaultView, 'manabi_applyBookReadingPresentation', {
                configurable: true,
                get() {
                    Object.defineProperty(this, 'manabi_applyBookReadingPresentation', { configurable: true, writable: true, value: original })
                    reenter()
                    return p => { oldProjections++; original(p) }
                },
            })
        } else {
            Object.defineProperty(f.a.defaultView, 'manabi_bookReadingScope', {
                configurable: true,
                set(value) {
                    Object.defineProperty(this, 'manabi_bookReadingScope', { configurable: true, writable: true, value })
                    reenter()
                },
            })
            f.a.defaultView.manabi_applyBookReadingPresentation = p => { if (p.revision === 2) oldProjections++; original(p) }
        }
        f.runtime.state.refresh()
        assert.equal(f.publish(2), false)
        assert.equal(oldProjections, 0, 'No stale projector can run after its scope was replaced')
        assert.deepEqual(f.a.defaultView.reads, ['read-3'])
        assert.equal(f.runtime.state.state.revision, 3)
    })
}

test('an invalidator lookup cannot erase a reentrantly recovered active frame', t => {
    const f = fixture(t)
    assert.equal(f.publish(1), true)
    let staleClears = 0
    const oldClear = f.a.defaultView.manabi_invalidateBookReadingScope
    Object.defineProperty(f.a.defaultView, 'manabi_invalidateBookReadingScope', { configurable: true,
        get() {
            Object.defineProperty(this, 'manabi_invalidateBookReadingScope', { configurable: true, writable: true, value: oldClear })
            f.runtime.state.refresh()
            assert.equal(f.publish(2), true)
            return () => { staleClears++; oldClear() }
        },
    })
    f.runtime.state.refresh()
    f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' })
    assert.equal(staleClears, 0)
    assert.deepEqual(f.a.defaultView.reads, ['read-2'])
    assert.ok(f.runtime.captureEvent(f.a))
})

test('a failed original frame invalidator still withdraws its unchanged exposed scope', t => {
    const f = fixture(t)
    assert.equal(f.publish(1), true)
    assert.ok(f.a.defaultView.manabi_bookReadingScope)
    f.a.defaultView.manabi_invalidateBookReadingScope = () => { throw new Error('could not enter Core cleanup') }
    f.runtime.state.refresh()
    f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' })
    assert.equal(f.a.defaultView.manabi_bookReadingScope, null)
    assert.equal(f.runtime.captureScope(f.a), null)
})

test('outgoing cleanup cannot overwrite the observation installed by nested relocation', t => {
    const f = fixture(t)
    assert.equal(f.publish(1), true)
    let entered = false
    const original = f.a.defaultView.manabi_invalidateBookReadingScope
    f.a.defaultView.manabi_invalidateBookReadingScope = () => {
        original()
        if (entered) return
        entered = true
        f.a.defaultView.manabi_invalidateBookReadingScope = original
        f.renderer.displayedIndex = 0
        f.runtime.updateLocation(true)
        assert.equal(f.publish(3), true)
    }
    f.renderer.displayedIndex = 1
    assert.equal(f.runtime.updateLocation(true), false)
    assert.equal(f.runtime.state.location.sectionURL, f.a.location.href)
    assert.equal(f.runtime.state.ready, true)
    assert.ok(f.runtime.captureEvent(f.a))
    assert.equal(f.runtime.captureEvent(f.b), null)
})

for (const operation of ['scope-check', 'scope-capture']) {
    test(`${operation} cannot borrow equal-scope recovery triggered during renderer lookup`, t => {
        const f = fixture(t)
        assert.equal(f.publish(1), true)
        const old = f.runtime.captureScope(f.a)
        const contents = f.renderer.getContents
        f.renderer.getContents = () => {
            f.renderer.getContents = contents
            f.runtime.state.refresh()
            f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' })
            f.runtime.state.refresh()
            assert.equal(f.publish(2), true)
            return contents()
        }
        if (operation === 'scope-check') assert.equal(f.runtime.isScopeCurrent(old, f.a), false)
        else assert.equal(f.runtime.captureScope(f.a), null)
        assert.equal(f.runtime.isScopeCurrent(old, f.a), false)
        assert.ok(f.runtime.captureScope(f.a), 'A later deliberate capture uses the recovered state')
    })
}

test('editing a scope copy cannot grant an earlier event the successor pass', t => {
    const f = fixture(t)
    assert.equal(f.publish(1), true)
    const old = f.runtime.captureScope(f.a)
    f.runtime.state.refresh()
    const next = f.response(2)
    next.state.scope.chapterEpochID = 'b'.repeat(64)
    assert.equal(f.runtime.state.apply(f.requests.at(-1).requestID, next), true)
    assert.equal(f.runtime.isScopeCurrent(old, f.a), false)
    // captureScope continues to return a defensive wire-shaped copy; mutation
    // of that copy is allowed, but cannot change its private admission receipt.
    old.chapterEpochID = next.state.scope.chapterEpochID
    assert.equal(f.runtime.isScopeCurrent(old, f.a), false)
    assert.equal(f.runtime.isScopeCurrent(f.runtime.captureScope(f.a), f.a), true)
})

test('successful same-pass refresh preserves a genuine scope receipt', t => {
    const f = fixture(t)
    assert.equal(f.publish(1), true)
    const captured = f.runtime.captureScope(f.a)
    f.runtime.state.refresh()
    assert.equal(f.publish(2), true)
    assert.equal(f.runtime.isScopeCurrent(captured, f.a), true)
    assert.equal(f.runtime.isScopeCurrent({ ...captured }, f.a), false)
})

test('required active-frame projection failure is not relabelled as native acknowledgement', t => {
    const f = fixture(t)
    assert.equal(f.publish(1), true)
    f.a.defaultView.manabi_applyBookReadingPresentation = () => { throw new Error('required active projection') }
    f.runtime.state.refresh()
    assert.throws(() => f.publish(2), /required active projection/)
    assert.equal(f.projections.at(-1).revision, 1)
})

test('closure during location posting suppresses its stale visibility notification', t => {
    const f = fixture(t)
    assert.equal(f.publish(1), true)
    const before = f.visibility.length
    f.hooks.statePost = () => { delete f.hooks.statePost; f.runtime.close() }
    f.runtime.endcap.enter()
    assert.equal(f.runtime.endcap.visible, false)
    assert.equal(f.visibility.length, before)
})

test('a failed frame invalidator cannot erase a scope installed by a newer native callback', t => {
    const f = fixture(t)
    assert.equal(f.publish(1), true)
    const newer = { ...f.a.defaultView.manabi_bookReadingScope, chapterEpochID: 'c'.repeat(64) }
    f.a.defaultView.manabi_invalidateBookReadingScope = () => {
        f.a.defaultView.manabi_bookReadingScope = newer
        throw new Error('callback published before failing')
    }
    f.runtime.state.refresh()
    f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' })
    assert.equal(f.a.defaultView.manabi_bookReadingScope, newer)
})

for (const seam of ['initial-renderer', 'location-url']) {
    test(`${seam} preparation cannot adopt a nested relocation's observation`, t => {
        const f = fixture(t)
        assert.equal(f.publish(1), true)
        const revision = f.runtime.state.locationRevision, count = f.requests.length
        if (seam === 'initial-renderer') {
            const contents = f.renderer.getContents
            f.renderer.getContents = () => {
                f.renderer.getContents = contents
                f.runtime.updateLocation(true)
                assert.equal(f.publish(2), true)
                return contents()
            }
        } else {
            f.renderer.displayedIndex = 1
            const href = f.b.location.href
            Object.defineProperty(f.b.location, 'href', { configurable: true, get() {
                Object.defineProperty(f.b.location, 'href', { configurable: true, writable: true, value: href })
                f.renderer.displayedIndex = 0
                f.runtime.updateLocation(true)
                assert.equal(f.publish(2), true)
                return href
            } })
        }
        assert.equal(f.runtime.updateLocation(true), false)
        assert.equal(f.runtime.state.location.sectionURL, f.a.location.href)
        assert.equal(f.runtime.state.locationRevision, revision + 1)
        assert.equal(f.requests.length, count + 1, 'Outer preparation replaced the nested request')
        assert.equal(f.runtime.state.ready, true)
    })
}

const { createBookActionBridge } = await import(new URL('./book-action-bridge.js', moduleURL))
for (const boundary of ['ordinary', 'throwing-observer', 'reentrant-next-account', 'new-command']) {
    test(`bridge account observer ordering preserves settlement (${boundary})`, async t => {
        const messages = [], timers = new Map(), callbacks = [], hooks = {}
        let id = 0, timer = 0, bridge, replacement
        bridge = createBookActionBridge({
            postMessage: value => messages.push(value), documentStartedAtMs: 1, topWindowURL: 'ebook://book',
            captureContext: () => ({ contextID: 'native-context' }),
            makeRequestID: () => `00000000-0000-4000-8000-${String(++id).padStart(12, '0')}`,
            setTimer: fn => { timers.set(++timer, fn); return timer },
            clearTimer: handle => { timers.delete(handle); hooks.clear?.() },
            onAccountChange: stamp => {
                callbacks.push(stamp)
                if (stamp !== '2:1') return
                if (boundary === 'throwing-observer') throw new Error('optional observer')
                if (boundary === 'reentrant-next-account') bridge.setAccountPresentation('3:1')
                if (boundary === 'new-command') replacement = bridge.perform('finishBook')
            },
        })
        t.after(() => { delete hooks.clear; bridge.close() })
        bridge.setAccountPresentation('1:1')
        const old = bridge.perform('finishBook')
        const rejected = assert.rejects(old, error => error.outcomeUnknown && error.presentationSuperseded)
        let atCleanup
        hooks.clear = () => { atCleanup = [...callbacks] }
        assert.equal(bridge.setAccountPresentation('2:1'), true)
        await rejected
        assert.deepEqual(atCleanup, boundary === 'reentrant-next-account' ? ['1:1', '2:1', '3:1'] : ['1:1', '2:1'])
        assert.equal(bridge.setAccountPresentation('2:1'), false)
        assert.equal(bridge.acknowledge(messages[0].deliveryID, { requestID: messages[0].requestID, accountPresentation: '1:1', ok: true, committed: true }), false)
        if (boundary === 'new-command') {
            const message = messages[1]
            assert.equal(timers.size, 1, 'Old cleanup retired the observer-created delivery')
            assert.equal(bridge.acknowledge(message.deliveryID, { requestID: message.requestID, accountPresentation: '2:1', ok: true, committed: true }), true)
            assert.equal((await replacement).committed, true)
        } else assert.equal(messages.length, 1)
        assert.equal(timers.size, 0)
    })
}

for (const timing of ['synchronous', 'retained']) {
    test(`${timing} frame projection edits cannot rewrite shell or exposed scope`, t => {
        const f = fixture(t)
        let received
        const mutate = p => {
            p.finished = true
            p.readSegmentIdentifiers.length = 0
            p.sentenceIdentifiersRead.push('not-native')
            p.scope.articleProgressID = 'not-the-book'
        }
        f.a.defaultView.manabi_applyBookReadingPresentation = p => {
            received = p
            if (timing === 'synchronous') mutate(p)
            return true
        }
        assert.equal(f.publish(1), true)
        if (timing === 'retained') mutate(received)
        assert.equal(f.runtime.endcap.finished, false)
        assert.equal(f.projections.at(-1).finished, false)
        assert.deepEqual(f.projections.at(-1).readSegmentIdentifiers, ['read-1'])
        assert.deepEqual(f.projections.at(-1).sentenceIdentifiersRead, [])
        assert.equal(f.projections.at(-1).scope.articleProgressID, 'book')
        assert.equal(f.a.defaultView.manabi_bookReadingScope.articleProgressID, 'book')
        assert.equal(f.runtime.state.state.finished, false)
    })
}
