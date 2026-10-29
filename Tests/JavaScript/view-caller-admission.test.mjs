import assert from 'node:assert/strict'
import test from 'node:test'
import { readFile } from 'node:fs/promises'
import { OwnedAsyncResource } from '../../Sources/LakeOfFireReader/Resources/foliate-js/owned-async-resource.js'
import { OwnedEventBindings } from '../../Sources/LakeOfFireReader/Resources/foliate-js/owned-event-bindings.js'
import { CacheWarmerPrecedingSections } from '../../Sources/LakeOfFireReader/Resources/foliate-js/cache-warmer-preceding-sections.js'
import { DeferredOpenWorkCoordinator } from '../../Sources/LakeOfFireReader/Resources/foliate-js/deferred-open-work.js'
import { EbookRenderReadinessCoordinator } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-render-readiness.js'

// Execute the complete production getView declaration. Only its external EPUB
// import/loader and browser collaborators are controlled; assertions concern
// returned Views, error outcomes, setup calls and actual event listener lifetime.
const source = await readFile(new URL('../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-viewer.js', import.meta.url), 'utf8')
const start = source.indexOf('const getView = async ')
const end = source.indexOf('\nconst getCSSForBookContent', start)
if (start < 0 || end < start) throw new Error('Cannot locate production getView declaration')
const declaration = source.slice(start, end)
    .replaceAll("await import('./epub.js')", 'epubModule')
const deferred = () => {
    let resolve, reject
    const promise = new Promise((yes, no) => { resolve = yes; reject = no })
    return { promise, resolve, reject }
}
function fixture(t, { opened = true, missingRenderer = false, wrongBook = false,
                       direction = async () => {}, styleFailure = null } = {}) {
    let current = true
    const listeners = new Set(), cleanup = new Set(), events = [], widths = []
    const window = new EventTarget()
    const add = window.addEventListener.bind(window), remove = window.removeEventListener.bind(window)
    window.addEventListener = (type, fn) => { listeners.add(fn); add(type, fn) }
    window.removeEventListener = (type, fn) => { listeners.delete(fn); remove(type, fn) }
    const book = { sections: [], dir: 'ltr' }
    const renderer = {
        localName: 'foliate-paginator',
        shadowRoot: { appendChild() { if (styleFailure) throw styleFailure } },
        setWritingDirectionOverride: async value => { events.push(['direction', value]); await direction() },
        setSideNavWidth: width => widths.push(width),
    }
    const view = {
        dataset: {}, style: { setProperty() {} }, shadowRoot: null,
        book: null, renderer: null, closed: 0, removed: 0,
        async open(content, isCacheWarmer) {
            events.push(['open', content, isCacheWarmer])
            this.book = wrongBook ? {} : content
            this.renderer = missingRenderer ? null : renderer
            return opened
        },
        beginOpen(content, isCacheWarmer) {
            const completion = this.open(content, isCacheWarmer)
            return {
                completion,
                isCurrent: () => !wrongBook && this.book === content,
                retire: () => {
                    if (wrongBook) return false // A successor now owns this host.
                    this.close()
                    return true
                },
            }
        },
        registerCleanup(fn) { cleanup.add(fn) },
        close() { ++this.closed; this.book = this.renderer = null; for (const fn of cleanup) fn(); cleanup.clear() },
        remove() { ++this.removed },
    }
    t.after(() => view.close())
    const stage = { append() { events.push(['append']) } }
    const document = {
        body: stage, documentElement: { style: { setProperty() {} } },
        getElementById: () => stage,
        createElement: name => name === 'foliate-view' ? view : {},
    }
    const environment = {
        document, window, globalThis: { manabiEbookViewerWritingDirection: 'horizontal' },
        epubModule: { EPUB: class {} },
        makeNativeEpubLoader: async () => ({}), initializeEPUBBook: async () => book,
        readerOpenSupersededError: () => Object.assign(new Error('superseded'), { code: 'reader-open-superseded' }),
        postReaderVisibilityProbe: name => events.push([name]), forwardShadowErrors() {},
        resolveFoliatePaginator: candidate => candidate.renderer,
        getComputedStyle: () => ({ getPropertyValue: () => '24px' }),
    }
    const getView = new Function(...Object.keys(environment), declaration + '; return getView')(...Object.values(environment))
    return { view, book, renderer, window, listeners, events, widths,
        replace: () => { current = false },
        open: (cacheWarmer = false) => getView({ kind: 'native', url: 'ebook://original/' }, cacheWarmer, { isCurrent: () => current }),
    }
}
for (const cacheWarmer of [false, true]) {
    test(`current ${cacheWarmer ? 'cache' : 'visible'} opening remains usable`, async t => {
        const h = fixture(t)
        const delivery = await h.open(cacheWarmer)
        assert.equal(delivery.view, h.view)
        assert.equal(delivery.isCurrent(), true)
        assert.deepEqual(h.events.find(event => event[0] === 'open'), ['open', h.book, cacheWarmer])
        assert.equal(h.events.filter(event => event[0] === 'direction').length, cacheWarmer ? 0 : 1)
        assert.equal(h.view.closed, 0)
        assert.deepEqual(h.widths, ['24px'])
    })
}
for (const options of [{ opened: false }, { missingRenderer: true }, { wrongBook: true }]) {
    test(`incomplete View opening is rejected (${JSON.stringify(options)})`, async t => {
        const h = fixture(t, options)
        await assert.rejects(h.open(), error => error.code === 'reader-open-superseded')
        assert.equal(h.view.closed, options.wrongBook ? 0 : 1)
        assert.equal(h.view.removed, options.wrongBook ? 0 : 1)
        assert.equal(h.events.some(event => event[0] === 'getView:opened'), false)
        assert.equal(h.events.some(event => event[0] === 'direction'), false)
    })
}
test('replacement during writing-direction setup rejects and disposes original View', async t => {
    const gate = deferred(), h = fixture(t, { direction: () => gate.promise })
    const pending = h.open()
    while (!h.events.some(event => event[0] === 'direction')) await new Promise(resolve => setImmediate(resolve))
    h.replace()
    gate.resolve()
    await assert.rejects(pending, error => error.code === 'reader-open-superseded')
    assert.equal(h.view.closed, 1)
    assert.equal(h.view.removed, 1)
    assert.equal(h.listeners.size, 0)
    assert.equal(h.events.some(event => event[0] === 'getView:opened'), false)
})
test('writing-direction failure keeps its original error and retires the View', async t => {
    const failure = new Error('direction failed'), h = fixture(t, { direction: async () => { throw failure } })
    await assert.rejects(h.open(), error => error === failure)
    assert.equal(h.view.closed, 1)
    assert.equal(h.view.removed, 1)
    assert.equal(h.listeners.size, 0)
})
test('resize listener is released when the opened View closes', async t => {
    const h = fixture(t)
    await h.open()
    assert.equal(h.listeners.size, 1)
    h.window.dispatchEvent(new Event('resize'))
    assert.deepEqual(h.widths, ['24px', '24px'])
    h.view.close()
    assert.equal(h.listeners.size, 0)
    h.window.dispatchEvent(new Event('resize'))
    assert.deepEqual(h.widths, ['24px', '24px'])
})
test('retired opening cannot update side-nav layout before View teardown', async t => {
    const h = fixture(t)
    await h.open()
    h.replace()
    h.window.dispatchEvent(new Event('resize'))
    assert.deepEqual(h.widths, ['24px'])
})
test('post-open DOM setup failure also retires the original View', async t => {
    const failure = new Error('style insertion failed'), h = fixture(t, { styleFailure: failure })
    await assert.rejects(h.open(), error => error === failure)
    assert.equal(h.view.closed, 1)
    assert.equal(h.view.removed, 1)
    assert.equal(h.listeners.size, 0)
})


test('Reader admission rejects an older View delivered after a new opening begins', async t => {
    // Execute the complete real Reader.open method with its real generation
    // coordinator. The browser probe deliberately stops the accepted path
    // immediately after assignment, before unrelated navigation UI setup.
    const methodStart = source.indexOf('    async open(file) {', source.indexOf('class Reader {'))
    const methodEnd = source.indexOf('\n    #schedulePostInitialOpenWork(', methodStart)
    if (methodStart < 0 || methodEnd < methodStart) throw new Error('Cannot locate Reader.open')
    const method = source.slice(methodStart, methodEnd)
    const privateNames = [...new Set([...method.matchAll(/this\.(#[A-Za-z_$][\w$]*)/g)].map(match => match[1]))]
    const declarations = privateNames.map(name => {
        if (name === '#closed') return '#closed = false;'
        if (name === '#deferredOpenWork') return '#deferredOpenWork = new DeferredOpenWorkCoordinator();'
        if (name === '#renderReadiness') return '#renderReadiness = new EbookRenderReadinessCoordinator();'
        if (name === '#openedView') return '#openedView = null;'
        return `${name} = () => {};`
    }).join('\n')
    const first = deferred(), second = deferred(), reachedAdmission = new Error('accepted path observed')
    const oldView = { closed: 0, removed: 0, close() { ++this.closed }, remove() { ++this.removed } }
    const newView = { closed: 0, removed: 0, close() { ++this.closed }, remove() { ++this.removed } }
    const delivery = view => ({ view, isCurrent: () => true, retire() { view.close(); view.remove() } })
    const assignments = []
    const Reader = new Function('DeferredOpenWorkCoordinator', 'EbookRenderReadinessCoordinator',
        'getView', 'postReaderVisibilityProbe', `return class {
            ${declarations}
            unstableCFIs = new Set(); initialPaginatorSettleHandle = null;
            setLoadingIndicator() {}
            ${method}
        }`)(DeferredOpenWorkCoordinator, EbookRenderReadinessCoordinator,
        file => file === 'old' ? first.promise : second.promise,
        (_name, view) => { assignments.push(view); throw reachedAdmission })
    const reader = new Reader(), previous = {}
    reader.view = previous
    let newer
    // Register this reaction before Reader awaits the old result. It creates
    // the actual delivery-window ordering rather than replacing getView's
    // already-tested internal ownership predicate.
    first.promise.then(() => {
        newer = reader.open('new')
        newer.catch(() => {})
    })
    const older = reader.open('old')
    older.catch(() => {})
    t.after(async () => {
        first.resolve(delivery(oldView)); second.resolve(delivery(newView))
        await Promise.allSettled([older, newer])
    })
    first.resolve(delivery(oldView))
    await assert.rejects(older, error => error.message === 'reader-open-superseded')
    assert.equal(reader.view, previous)
    assert.deepEqual(assignments, [])
    assert.equal(oldView.closed, 1)
    assert.equal(oldView.removed, 1)
    second.resolve(delivery(newView))
    await assert.rejects(newer, error => error === reachedAdmission)
    assert.equal(reader.view, newView)
    assert.deepEqual(assignments, [newView])
    assert.equal(newView.closed, 0)
    assert.equal(newView.removed, 0)
})


test('Reader rejects a stale opening capability without closing its reused host', async t => {
    const methodStart = source.indexOf('    async open(file) {', source.indexOf('class Reader {'))
    const methodEnd = source.indexOf('\n    #schedulePostInitialOpenWork(', methodStart)
    if (methodStart < 0 || methodEnd < methodStart) throw new Error('Cannot locate Reader.open')
    const method = source.slice(methodStart, methodEnd)
    const privateNames = [...new Set([...method.matchAll(/this\.(#[A-Za-z_$][\w$]*)/g)].map(match => match[1]))]
    const declarations = privateNames.map(name => {
        if (name === '#closed') return '#closed = false;'
        if (name === '#deferredOpenWork') return '#deferredOpenWork = new DeferredOpenWorkCoordinator();'
        if (name === '#renderReadiness') return '#renderReadiness = new EbookRenderReadinessCoordinator();'
        if (name === '#openedView') return '#openedView = null;'
        return `${name} = () => {};`
    }).join('\n')
    const first = deferred(), reachedAdmission = new Error('unexpected admission')
    const host = { closed: 0, removed: 0, close() { ++this.closed }, remove() { ++this.removed } }
    let current = true, retired = 0
    const opened = {
        view: host, isCurrent: () => current,
        retire() { ++retired; if (current) { host.close(); host.remove() } },
    }
    const Reader = new Function('DeferredOpenWorkCoordinator', 'EbookRenderReadinessCoordinator',
        'getView', 'postReaderVisibilityProbe', `return class {
            ${declarations}
            unstableCFIs = new Set(); initialPaginatorSettleHandle = null;
            setLoadingIndicator() {}
            ${method}
        }`)(DeferredOpenWorkCoordinator, EbookRenderReadinessCoordinator,
        () => first.promise,
        () => { throw reachedAdmission })
    const reader = new Reader(), previous = {}
    reader.view = previous
    // This reaction starts a successor on the same host before the Reader
    // continuation. Retirement belongs to the original capability only.
    first.promise.then(() => { current = false })
    const pending = reader.open('old')
    pending.catch(() => {})
    first.resolve(opened)
    await assert.rejects(pending, error => error.message === 'reader-open-superseded')
    assert.equal(reader.view, previous)
    assert.equal(retired, 1)
    assert.equal(host.closed, 0)
    assert.equal(host.removed, 0)
})


for (const phase of ['current', 'retired-delivery', 'retired-setup']) {
    const stale = phase !== 'current'
    test(`cache-warmer admits only its delivered opening (${phase})`, async () => {
        const methodStart = source.indexOf('    async open(file) {', source.indexOf('class CacheWarmer {'))
        const methodEnd = source.indexOf('\n    #finalizeSectionAdvance(', methodStart)
        if (methodStart < 0 || methodEnd < methodStart) throw new Error('Cannot locate CacheWarmer.open')
        const method = source.slice(methodStart, methodEnd)
        const original = deferred(), rendered = []
        const host = { renderer: { setAttribute: (...args) => rendered.push(args) }, book: {} }
        let current = true, retirements = 0
        const opened = { view: host, isCurrent: () => current, retire() { ++retirements } }
        const window = {}, shared = {}
        const CacheWarmer = new Function('OwnedAsyncResource', 'OwnedEventBindings', 'CacheWarmerPrecedingSections',
            'getView', 'window', 'globalThis', 'invalidateCacheWarmerWork', 'settleSection', `return class {
                #closed = false;
                #precedingSections = new CacheWarmerPrecedingSections();
                #eventBindings = null;
                #viewOwner = new OwnedAsyncResource(openedView => openedView.retire());
                #isCurrentGeneration() { return true }
                #onLoad() {}
                async #openFirstUnsettledSection() { return await settleSection() }
                ${method}
            }`)(OwnedAsyncResource, OwnedEventBindings, CacheWarmerPrecedingSections,
            () => original.promise, window, shared, () => 1, async () => {
                if (phase === 'retired-setup') current = false
                return true
            })
        const warmer = new CacheWarmer()
        window.cacheWarmer = warmer
        if (phase === 'retired-delivery') original.promise.then(() => { current = false })
        // This global generation is a controlled browser collaborator; the
        // actual cache resource token/disposer and complete open method run.
        try {
            const pending = warmer.open('book')
            original.resolve(opened)
            assert.equal(await pending, !stale)
            assert.equal(warmer.view, stale ? null : host)
            assert.equal(retirements, stale ? 1 : 0)
            assert.deepEqual(rendered, phase === 'retired-delivery' ? [] : [['flow', 'paginated']])
            assert.equal(shared.__manabiCacheWarmerReady, !stale)
        } finally {
            // No timers or browser globals were installed by this fixture.
        }
    })
}
