import assert from 'node:assert/strict'
import test from 'node:test'

// View's browser host is minimal here; navigation/history/ownership are the
// actual production class. No DOM rendering or WebKit integration is claimed.
globalThis.HTMLElement = class extends EventTarget {
    attachShadow() {
        this.appendedRenderers = []
        return { append: renderer => { this.appendedRenderers.push(renderer) } }
    }
}
globalThis.customElements = { define() {} }
globalThis.document = { createElement() { throw new Error('Unexpected browser rendering') } }
const { View } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/view.js')
const { SectionProgress } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/progress.js')
const { runRequiredRestoreNavigation, makeInitialRestoreTerminalResult } = await import(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-restore-coordination.js'
)

const deferred = () => {
    let resolve, reject
    const promise = new Promise((yes, no) => { resolve = yes; reject = no })
    return { promise, resolve, reject }
}
const settle = async () => { for (let i = 0; i < 10; i++) await Promise.resolve() }

function fixture(operation = async () => undefined) {
    const calls = []
    const pushes = []
    const view = new View()
    view.book = {
        sections: [{ id: 'a', size: 100 }, { id: 'b', size: 100 }],
        resolveHref: value => value === 'missing' ? null : { index: 1, anchor: 0.25 },
    }
    view.renderer = {
        goTo: target => { calls.push(target); return operation(target) },
        prev: async () => undefined,
        next: async () => undefined,
        destroy() {}, remove() {},
    }
    const pushState = view.history.pushState.bind(view.history)
    view.history.pushState = target => { pushes.push(target); pushState(target) }
    return { view, calls, pushes }
}

// The private fraction resolver is normally installed by View.open (which
// loads a browser renderer). Supply the same public SectionProgress dependency
// to test navigation without opening iframes; all command code stays real.
function withFractionResolver(view) {
    const progress = new SectionProgress(view.book.sections, 1500, 1600)
    const resolve = view.resolveNavigation.bind(view)
    view.resolveNavigation = target => {
        if (typeof target?.fraction !== 'number') return resolve(target)
        const [index, anchor] = progress.getSection(target.fraction)
        return { index, anchor }
    }
}

test('a valid target publishes exactly one history entry after renderer completion', async () => {
    const gate = deferred()
    const { view, calls, pushes } = fixture(() => gate.promise)
    const pending = view.goTo('chapter')
    assert.equal(calls.length, 1)
    assert.deepEqual(pushes, [])
    gate.resolve()
    assert.deepEqual(await pending, { index: 1, anchor: 0.25 })
    assert.deepEqual(pushes, ['chapter'])
})

test('missing resolution is a failed required restore rather than fulfilled success', async () => {
    const { view, calls, pushes } = fixture()
    const navigation = await runRequiredRestoreNavigation(() => view.goTo('missing'))
    const terminal = makeInitialRestoreTerminalResult({
        request: { requestID: 'restore-a', requestedLocator: 'cfi' },
        snapshot: null, error: navigation.error,
    })
    assert.equal(navigation.ok, false)
    assert.equal(terminal.requestID, 'restore-a')
    assert.equal(terminal.restoreSatisfied, false)
    assert.equal(terminal.terminalState, 'failed')
    assert.deepEqual(calls, [])
    assert.deepEqual(pushes, [])
})

test('out-of-range or noninteger section targets never reach a renderer', async () => {
    const { view, calls, pushes } = fixture()
    for (const index of [-1, 2, 0.5, NaN, Infinity]) {
        assert.equal(await view.goTo(index), null)
        assert.equal(await view.select(index), false)
    }
    assert.deepEqual(calls, [])
    assert.deepEqual(pushes, [])
})

test('fractional navigation uses real section mapping and the common history path', async () => {
    const { view, calls, pushes } = fixture()
    withFractionResolver(view)
    assert.deepEqual(await view.goToFraction(0.75), { index: 1, anchor: 0.5 })
    assert.deepEqual(calls, [{ index: 1, anchor: 0.5 }])
    assert.deepEqual(pushes, [{ fraction: 0.75 }])
})

test('fraction endpoints remain valid while malformed fractions are rejected', async () => {
    const { view, calls } = fixture()
    withFractionResolver(view)
    for (const fraction of [-0.1, 1.1, NaN, Infinity, -Infinity, '0.5', null, undefined]) {
        assert.equal(await view.goToFraction(fraction), null)
    }
    assert.equal(calls.length, 0)
    assert.deepEqual(await view.goToFraction(0), { index: 0, anchor: 0 })
    assert.deepEqual(await view.goToFraction(1), { index: 1, anchor: 1 })
})

test('fractional completion cannot append history after renderer replacement', async () => {
    const gate = deferred()
    const { view, pushes } = fixture(() => gate.promise)
    withFractionResolver(view)
    const pending = view.goToFraction(0.75)
    view.renderer = { goTo: async () => undefined }
    gate.resolve()
    assert.equal(await pending, null)
    assert.deepEqual(pushes, [])
})

test('fractional failure from an obsolete renderer is suppressed', async () => {
    const gate = deferred()
    const { view, pushes } = fixture(() => gate.promise)
    withFractionResolver(view)
    const pending = view.goToFraction(0.5)
    view.renderer = { goTo: async () => undefined }
    gate.reject(new Error('old renderer'))
    assert.equal(await pending, null)
    assert.deepEqual(pushes, [])
})

test('closing and reusing the same renderer still invalidates an old command', async () => {
    const gate = deferred()
    const { view, pushes } = fixture(() => gate.promise)
    const renderer = view.renderer, book = view.book
    const pending = view.goTo('chapter')
    view.close()
    view.renderer = renderer
    view.book = book
    gate.resolve()
    assert.equal(await pending, null)
    assert.deepEqual(pushes, [])
    assert.equal(view.history.canGoBack, false)
})

test('a newer command on the same renderer owns history even if the old one finishes later', async () => {
    const first = deferred(), second = deferred()
    const { view, pushes } = fixture(({ index }) => index === 0 ? first.promise : second.promise)
    const old = view.goTo(0), current = view.goTo(1)
    second.resolve()
    assert.deepEqual(await current, { index: 1 })
    first.resolve()
    assert.equal(await old, null)
    assert.deepEqual(pushes, [1])
})

test('obsolete same-renderer errors cannot replace a newer successful command', async () => {
    const gate = deferred()
    const { view, pushes } = fixture(({ index }) => index === 0 ? gate.promise : undefined)
    const old = view.goTo(0)
    await view.goTo(1)
    gate.reject(new Error('obsolete command'))
    assert.equal(await old, null)
    assert.deepEqual(pushes, [1])
})

test('selection and navigation share command ownership', async () => {
    const gate = deferred()
    const { view, calls, pushes } = fixture(({ select }) => select ? undefined : gate.promise)
    const old = view.goTo(0)
    assert.equal(await view.select(1), true)
    gate.resolve()
    assert.equal(await old, null)
    assert.deepEqual(calls, [{ index: 0 }, { index: 1, select: true }])
    assert.deepEqual(pushes, [1])
})

test('older selection cannot publish after a newer navigation command', async () => {
    const gate = deferred()
    const { view, pushes } = fixture(({ select }) => select ? gate.promise : undefined)
    const old = view.select(0)
    await view.goTo(1)
    gate.resolve()
    assert.equal(await old, false)
    assert.deepEqual(pushes, [1])
})

test('relative page turns invalidate pending target-navigation publication', async () => {
    for (const turn of ['next', 'prev']) {
        const gate = deferred()
        const { view, pushes } = fixture(() => gate.promise)
        const old = view.goTo(1)
        await view[turn]()
        gate.resolve()
        assert.equal(await old, null)
        assert.deepEqual(pushes, [])
    }
})

test('initial saved-position navigation cannot repopulate history after close', async () => {
    const gate = deferred()
    const { view, pushes } = fixture(() => gate.promise)
    const old = view.init({ lastLocation: 'chapter', showTextStart: false })
    view.close()
    gate.resolve()
    await old
    assert.deepEqual(pushes, [])
})

test('history traversal invalidates pending commands without appending itself', async () => {
    const gate = deferred()
    const { view, calls, pushes } = fixture(({ index }) => index === 1 ? gate.promise : undefined)
    const old = view.goTo(1)
    view.history.dispatchEvent(new CustomEvent('popstate', { detail: { state: 0 } }))
    await settle()
    gate.resolve()
    assert.equal(await old, null)
    assert.deepEqual(calls, [{ index: 1 }, { index: 0 }])
    assert.deepEqual(pushes, [])
})

test('explicit renderer rejection is never pushed into navigation history', async () => {
    for (const outcome of [null, false, { ignored: true, reason: 'superseded' }]) {
        const { view, pushes } = fixture(async () => outcome)
        assert.equal(await view.goTo(0), null)
        assert.equal(await view.select(1), false)
        assert.deepEqual(pushes, [])
    }
})

test('required restore rejects superseded completion and retains its request identity', async () => {
    const gate = deferred()
    const { view } = fixture(() => gate.promise)
    const old = runRequiredRestoreNavigation(() => view.goTo(0))
    view.close()
    gate.resolve()
    const result = await old
    assert.equal(result.ok, false)
    assert.equal(result.value, null)
    assert.match(result.error.message, /not applied/)
})

test('required restore retains void success for legacy renderer contracts', async () => {
    assert.deepEqual(await runRequiredRestoreNavigation(async () => undefined), {
        ok: true, value: undefined, error: null,
    })
    assert.equal((await runRequiredRestoreNavigation(async () => false)).ok, false)
    assert.equal((await runRequiredRestoreNavigation(async () => ({ ignored: true }))).ok, false)
})

test('required restore preserves the actual current navigation exception', async () => {
    const failure = new Error('cannot render saved position')
    const result = await runRequiredRestoreNavigation(async () => { throw failure })
    assert.equal(result.ok, false)
    assert.equal(result.error, failure)
})

test('closed View rejects target navigation and selection without invoking a renderer', async () => {
    const { view, calls, pushes } = fixture()
    view.close()
    assert.equal(await view.goTo(0), null)
    assert.equal(await view.select(0), false)
    assert.equal(await view.goToFraction(0.5), null)
    assert.deepEqual(calls, [])
    assert.deepEqual(pushes, [])
})

test('current renderer failures remain errors while selection retains its false contract', async t => {
    t.mock.method(console, 'error', () => {})
    const failure = new Error('current renderer failure')
    const { view, pushes } = fixture(async () => { throw failure })
    await assert.rejects(view.goTo(0), error => error === failure)
    assert.equal(await view.select(1), false)
    assert.deepEqual(pushes, [])
})

test('a failing history event is consumed rather than becoming an unhandled rejection', async t => {
    const logged = []
    t.mock.method(console, 'error', error => { logged.push(error) })
    const failure = new Error('history target failed')
    const { view, pushes } = fixture(async () => { throw failure })
    view.history.dispatchEvent(new CustomEvent('popstate', { detail: { state: 0 } }))
    await settle()
    assert.deepEqual(logged, [failure])
    assert.deepEqual(pushes, [])
})

test('resolution that synchronously starts a newer command cannot dispatch the old command', async () => {
    const { view, calls, pushes } = fixture()
    const resolve = view.resolveNavigation.bind(view)
    let newer
    view.resolveNavigation = target => {
        if (target === 0) newer = view.goTo(1)
        return resolve(target)
    }
    assert.equal(await view.goTo(0), null)
    assert.deepEqual(await newer, { index: 1 })
    assert.deepEqual(calls, [{ index: 1 }])
    assert.deepEqual(pushes, [1])
})

function rendererFactory(t, onCreate = () => {}) {
    const created = []
    t.mock.method(document, 'createElement', name => {
        assert.equal(name, 'foliate-fxl')
        const renderer = new EventTarget()
        Object.assign(renderer, {
            calls: [], destroyed: 0, removed: 0,
            setAttribute() {},
            open(book) { this.book = book },
            goTo(target) { this.calls.push(target) },
            destroy() { this.destroyed += 1 },
            remove() { this.removed += 1 },
        })
        created.push(renderer)
        onCreate(renderer)
        return renderer
    })
    return created
}
const fixedBook = () => ({
    rendition: { layout: 'pre-paginated' },
    sections: [{ id: 'a', size: 100 }, { id: 'b', size: 100 }],
    splitTOCHref: href => [href, ''],
    getTOCFragment: () => null,
})

test('closing during renderer-module loading cannot resurrect the closed View', async t => {
    const created = rendererFactory(t)
    const view = new View()
    const pending = view.open(fixedBook(), false)
    view.close()
    await pending
    assert.equal(view.renderer, null)
    assert.equal(view.book, null)
    assert.deepEqual(created, [])
    assert.deepEqual(view.appendedRenderers, [])
})

test('only the latest overlapping open can install a renderer', async t => {
    const created = rendererFactory(t)
    const view = new View(), firstBook = fixedBook(), lastBook = fixedBook()
    const first = view.open(firstBook, false)
    const last = view.open(lastBook, false)
    await Promise.all([first, last])
    assert.equal(created.length, 1)
    assert.equal(view.renderer, created[0])
    assert.equal(view.renderer.book, lastBook)
    assert.deepEqual(view.appendedRenderers, created)
})

test('overlapping opens for the same book still require the exact open generation', async t => {
    const created = rendererFactory(t)
    const view = new View(), book = fixedBook()
    await Promise.all([view.open(book, false), view.open(book, false)])
    assert.equal(created.length, 1)
    assert.equal(view.renderer.book, book)
})

test('opening retires the old renderer before accepting commands for the new book', async t => {
    const created = rendererFactory(t)
    const view = new View()
    await view.open(fixedBook(), false)
    const old = view.renderer
    const next = view.open(fixedBook(), false)
    assert.equal(view.renderer, null)
    assert.equal(old.destroyed, 1)
    assert.equal(old.removed, 1)
    assert.equal(await view.goTo(0), null)
    await next
    assert.equal(created.length, 2)
    assert.equal(view.renderer, created[1])
    assert.deepEqual(old.calls, [])
})

test('actual open initializes fraction resolution used by guarded navigation', async t => {
    const created = rendererFactory(t)
    const view = new View()
    await view.open(fixedBook(), false)
    assert.deepEqual(await view.goToFraction(0.75), { index: 1, anchor: 0.5 })
    assert.deepEqual(created[0].calls, [{ index: 1, anchor: 0.5 }])
})

test('teardown reentered from renderer construction prevents publication', async t => {
    const view = new View()
    const created = rendererFactory(t, () => view.close())
    await view.open(fixedBook(), false)
    assert.equal(created.length, 1)
    assert.equal(created[0].destroyed, 1)
    assert.equal(created[0].removed, 1)
    assert.equal(view.renderer, null)
    assert.deepEqual(view.appendedRenderers, [])
})

test('reopening cannot reuse a previous book fraction map when the new book lacks one', async t => {
    t.mock.method(console, 'error', () => {})
    rendererFactory(t)
    const view = new View()
    await view.open(fixedBook(), false)
    const book = fixedBook()
    delete book.splitTOCHref
    delete book.getTOCFragment
    await view.open(book, false)
    assert.equal(await view.goToFraction(0.75), null)
    assert.deepEqual(view.renderer.calls, [])
})

test('a new book open clears navigation history from the previous book', async t => {
    rendererFactory(t)
    const view = new View()
    await view.open(fixedBook(), false)
    await view.goTo(0)
    await view.goTo(1)
    assert.equal(view.history.canGoBack, true)
    await view.open(fixedBook(), false)
    assert.equal(view.history.canGoBack, false)
    assert.equal(view.history.canGoForward, false)
})
