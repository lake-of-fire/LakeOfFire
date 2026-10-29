import assert from 'node:assert/strict'
import test from 'node:test'

// The real View and dynamically imported renderer modules run against these
// controlled browser collaborators; no layout/WebKit claim is made.
globalThis.HTMLElement = class extends EventTarget {
    attachShadow() {
        this.appended = []
        return { append: renderer => { this.appended.push(renderer) } }
    }
}
globalThis.customElements = { define() {} }
globalThis.document = { createElement() { throw new Error('Unconfigured renderer') } }
const { View } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/view.js')
const deferred = () => {
    let resolve, reject
    const promise = new Promise((yes, no) => { resolve = yes; reject = no })
    return { promise, resolve, reject }
}
const book = () => ({
    rendition: { layout: 'pre-paginated' }, metadata: {}, sections: [],
    destroyed: 0, destroy() { ++this.destroyed },
})
const factory = (t, onCreate = () => {}, open = () => {}) => {
    const created = []
    t.mock.method(document, 'createElement', name => {
        assert.equal(name, 'foliate-fxl')
        const renderer = new EventTarget()
        renderer.listenerTypes = new Set()
        const addListener = renderer.addEventListener.bind(renderer)
        renderer.addEventListener = (type, listener, options) => {
            renderer.listenerTypes.add(type)
            addListener(type, listener, options)
        }
        Object.assign(renderer, {
            destroyed: 0, removed: 0,
            setAttribute() {},
            open(...args) { this.openArgs = args; return open(this, ...args) },
            destroy() { ++this.destroyed }, remove() { ++this.removed },
        })
        created.push(renderer)
        onCreate(renderer)
        return renderer
    })
    return created
}

test('close during renderer module loading cannot resurrect a View', async t => {
    const created = factory(t), view = new View(), content = book()
    const pending = view.open(content, false)
    view.close()
    await pending
    assert.equal(view.renderer, null)
    assert.equal(view.book, null)
    assert.equal(created.length, 0)
    assert.deepEqual(view.appended, [])
    assert.equal(content.destroyed, 1)
})
for (const reuse of [false, true]) {
    test(`only the latest open installs a renderer (${reuse ? 'same' : 'different'} book)`, async t => {
        const created = factory(t), view = new View(), first = book(), last = reuse ? first : book()
        await Promise.all([view.open(first, false), view.open(last, true)])
        assert.equal(created.length, 1)
        assert.equal(view.renderer, created[0])
        assert.deepEqual(created[0].openArgs, [last, true])
        assert.deepEqual(view.appended, [created[0]])
        assert.equal(last.destroyed, 0, 'Reused/current book must remain usable')
        if (!reuse) assert.equal(first.destroyed, 1)
        view.close()
    })
}
test('replacement retires old renderer and bindings before module loading', async t => {
    const created = factory(t), view = new View(), first = book(), next = book()
    await view.open(first, false)
    let loads = 0
    view.addEventListener('load', () => ++loads)
    const pending = view.open(next, false)
    assert.equal(view.renderer, null)
    assert.equal(created[0].destroyed, 1)
    assert.equal(created[0].removed, 1)
    assert.equal(first.destroyed, 1)
    const stale = new Event('load')
    Object.defineProperty(stale, 'detail', { value: { doc: null } })
    created[0].dispatchEvent(stale)
    assert.equal(loads, 0)
    await pending
    assert.equal(view.renderer, created[1])
    view.close()
})
test('constructor reentry into close disposes the uninstalled renderer', async t => {
    const view = new View()
    const created = factory(t, () => view.close())
    await view.open(book(), false)
    assert.equal(view.renderer, null)
    assert.equal(created[0].destroyed, 1)
    assert.equal(created[0].removed, 1)
    assert.deepEqual(view.appended, [])
})
test('open waits for renderer initialization before publishing it', async t => {
    const gate = deferred(), view = new View()
    const created = factory(t, () => {}, () => gate.promise)
    let finished = false
    const pending = view.open(book(), true).then(() => { finished = true })
    // Module import necessarily yields; wait until the real View calls open.
    while (!created.length || !created[0].openArgs) await new Promise(resolve => setImmediate(resolve))
    assert.equal(finished, false)
    assert.deepEqual(view.appended, [])
    gate.resolve()
    await pending
    assert.deepEqual(view.appended, [created[0]])
    assert.equal(created[0].openArgs[1], true)
    view.close()
})
test('failed renderer initialization retires its book and permits retry', async t => {
    const gate = deferred(), view = new View(), first = book()
    const failure = new Error('renderer failed')
    const created = factory(t, () => {}, () => gate.promise)
    const pending = view.open(first, false)
    const rejection = assert.rejects(pending, error => error === failure)
    while (!created.length || !created[0].openArgs) await new Promise(resolve => setImmediate(resolve))
    gate.reject(failure)
    await rejection
    assert.equal(view.renderer, null)
    assert.equal(view.book, null)
    assert.equal(first.destroyed, 1)
    assert.equal(created[0].destroyed, 1)
    const retry = book()
    // The factory uses the now-rejected gate, so replace only its test collaborator.
    t.mock.restoreAll()
    const second = factory(t)
    await view.open(retry, false)
    assert.equal(view.renderer, second[0])
    assert.equal(retry.destroyed, 0)
    view.close()
})
test('retired renderer rejection cannot close its successor', async t => {
    const gate = deferred(), view = new View(), first = book(), next = book()
    const failure = new Error('retired renderer failed')
    const created = factory(t, () => {}, (_renderer, content) => content === first ? gate.promise : undefined)
    const pending = view.open(first, false)
    const rejection = assert.rejects(pending, error => error === failure)
    while (!created.length || !created[0].openArgs) await new Promise(resolve => setImmediate(resolve))
    await view.open(next, false)
    gate.reject(failure)
    await rejection
    assert.equal(view.renderer, created[1])
    assert.equal(view.book, next)
    assert.equal(next.destroyed, 0)
    assert.deepEqual(view.appended, [created[1]])
    assert.equal(created[0].destroyed, 1)
    view.close()
})


test('old renderer destruction can open a successor without being overwritten', async t => {
    const view = new View(), first = book(), superseded = book(), successor = book()
    const created = factory(t)
    await view.open(first, false)
    let next
    created[0].destroy = function () { ++this.destroyed; next = view.open(successor, true) }
    assert.equal(await view.open(superseded, false), false)
    await next
    assert.equal(view.book, successor)
    assert.equal(view.renderer, created[1])
    assert.equal(created[0].destroyed, 1)
    assert.equal(first.destroyed, 1)
    assert.equal(superseded.destroyed, 1)
    assert.equal(successor.destroyed, 0)
    view.close()
})
test('late initialization success cannot append or destroy a successor', async t => {
    const gate = deferred(), view = new View(), first = book(), next = book()
    const created = factory(t, () => {}, (_renderer, content) => content === first ? gate.promise : undefined)
    const pending = view.open(first, false)
    while (!created.length || !created[0].openArgs) await new Promise(resolve => setImmediate(resolve))
    await view.open(next, false)
    gate.resolve()
    assert.equal(await pending, false)
    assert.equal(view.renderer, created[1])
    assert.equal(view.book, next)
    assert.equal(created[0].destroyed, 1)
    assert.equal(next.destroyed, 0)
    assert.deepEqual(view.appended, [created[1]])
    view.close()
})
test('constructor failure cleans current ownership and keeps its original error', async t => {
    const view = new View(), content = book(), failure = new Error('constructor failed')
    factory(t, () => { throw failure })
    await assert.rejects(view.open(content, false), error => error === failure)
    assert.equal(view.book, null)
    assert.equal(view.renderer, null)
    assert.equal(content.destroyed, 1)
    assert.deepEqual(view.appended, [])
})
for (const cacheWarmer of [false, true]) {
    test(`cache-warmer ${cacheWarmer} preserves overlay registration`, async t => {
        const view = new View(), created = factory(t)
        await view.open(book(), cacheWarmer)
        assert.equal(created[0].listenerTypes.has('create-overlayer'), !cacheWarmer)
        assert.deepEqual(created[0].openArgs.slice(1), [cacheWarmer])
        view.close()
    })
}
