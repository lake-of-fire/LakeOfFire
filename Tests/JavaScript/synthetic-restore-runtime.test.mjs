import assert from 'node:assert/strict'
import test from 'node:test'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
const require = createRequire(import.meta.url)
const { JSDOM } = require(process.env.JSDOM_MODULE ?? 'jsdom')
const html = '<!doctype html><html><body data-mnb-writing-direction="horizontal"><p><reader-sentinel id="page-start"></reader-sentinel>Readable text for the live paginator host.</p></body></html>'
const dom = new JSDOM('<!doctype html><html><body></body></html>', { pretendToBeVisual: true, url: 'https://reader.invalid/' })
const frames = []
let nextSidecars = []
let textWidth = 1200
const rect = (width = 600, height = 800) => ({ x: 0, y: 0, top: 0, left: 0, right: width, bottom: height, width, height, toJSON() { return this } })
const installGeometry = (window, width = 1200) => {
    window.fixtureContentWidth = width
    Object.defineProperties(window.HTMLElement.prototype, {
        clientWidth: { get() { return this.style.width?.endsWith('px') ? parseFloat(this.style.width) : 600 } },
        clientHeight: { get() { return this.style.height?.endsWith('px') ? parseFloat(this.style.height) : 800 } },
    })
    window.HTMLElement.prototype.getBoundingClientRect = function () { return rect(this.clientWidth, this.clientHeight) }
    window.Range.prototype.getBoundingClientRect = function () {
        const owner = this.commonAncestorContainer?.ownerDocument?.defaultView
        return rect(owner?.fixtureContentWidth ?? width, 400)
    }
    window.Range.prototype.getClientRects = function () { return [this.getBoundingClientRect()] }
    window.HTMLElement.prototype.scrollTo = function ({ left = this.scrollLeft, top = this.scrollTop }) { this.scrollLeft = left; this.scrollTop = top }
    window.HTMLElement.prototype.scrollBy = function ({ left = 0, top = 0 }) { this.scrollLeft += left; this.scrollTop += top }
}
installGeometry(dom.window)
const window = dom.window
const document = window.document
const createElement = document.createElement.bind(document)
document.createElement = function (name, options) {
    const element = createElement(name, options)
    if (name.toLowerCase() === 'iframe') {
        const section = new JSDOM(html, { pretendToBeVisual: true, url: 'https://reader.invalid/section' })
        installGeometry(section.window, textWidth)
        section.window.manabi_waitForExternalSegmentSidecar = nextSidecars.shift()
        frames.push(section)
        Object.defineProperties(element, {
            contentDocument: { get: () => section.window.document },
            contentWindow: { get: () => section.window },
            src: { set(value) { this.setAttribute('data-fixture-src', value); queueMicrotask(() => this.dispatchEvent(new window.Event('load'))) } },
        })
    }
    return element
}
Object.assign(globalThis, {
    window, document,
    HTMLElement: window.HTMLElement, customElements: window.customElements,
    Event: window.Event, CustomEvent: window.CustomEvent,
    Range: window.Range, Node: window.Node, NodeFilter: window.NodeFilter,
    CSS: { escape: value => value }, // The fixture only uses the plain "page-start" identifier.
    getComputedStyle: element => element.ownerDocument.defaultView.getComputedStyle(element),
    requestAnimationFrame: callback => setTimeout(() => callback(performance.now()), 0),
    cancelAnimationFrame: clearTimeout,
    ResizeObserver: class { observe() {} unobserve() {} disconnect() {} },
    IntersectionObserver: class {
        constructor(callback) { this.callback = callback }
        observe(target) { queueMicrotask(() => this.callback([{ target, isIntersecting: true, intersectionRatio: 1 }])) }
        unobserve() {} disconnect() {}
    },
})
const resourceBase = process.env.FOLIATE_MODULE_DIR
    ? pathToFileURL(`${process.env.FOLIATE_MODULE_DIR}/`)
    : new URL('../../Sources/LakeOfFireReader/Resources/foliate-js/', import.meta.url)
// Bind the production history EventTarget to its browser Event realm while
// leaving Node's runner EventTarget available outside the module import.
const nodeEventTarget = globalThis.EventTarget
globalThis.EventTarget = window.EventTarget
await import(new URL('view-history.js', resourceBase))
globalThis.EventTarget = nodeEventTarget
const { View } = await import(new URL('view.js', resourceBase))
const { createEbookLoadHandlers, createNavigationIntentRunner } = await import(new URL('ebook-load-coordinator.js', resourceBase))
const { installVisibleRendererGoToGuard } = await import(new URL('ebook-restore-coordination.js', resourceBase))

// Production View, Paginator, visible-page wrapper and restore entry point run
// together. Only iframe loading/geometry and Reader/native host endpoints are
// controlled. This does not qualify CSS layout or WKWebView.
const bounded = async operation => {
    let timer
    try {
        return await Promise.race([operation, new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error('Production restore did not settle')), 1500)
        })])
    } finally { clearTimeout(timer) }
}
const fixture = async ({ width = 1200, scrolled = false } = {}) => {
    textWidth = width
    const view = new View()
    document.body.append(view)
    await view.open({ dir: 'ltr', toc: [], pageList: [],
        splitTOCHref: href => [href], getTOCFragment: (doc, id) => doc.getElementById(id),
        sections: [0, 1].map(index => ({ id: `section-${index}`, size: 100,
            load: async () => `fixture:${index}`, unload() {} })),
    }, false)
    const renderer = view.renderer
    if (scrolled) renderer.setAttribute('flow', 'scrolled')
    await bounded(renderer.goTo({ index: 0, anchor: 0 }))
    const initialMetrics = await renderer.pageMetrics()
    let snapshot = { current: initialMetrics.page, total: Math.max(1, initialMetrics.pages - 2) }
    installVisibleRendererGoToGuard({ renderer,
        getCurrentIndex: () => renderer.getContents()[0]?.index,
        getPageSnapshot: () => snapshot,
    })
    const targets = []
    const guardedGoTo = renderer.goTo
    renderer.goTo = function (target, ...options) {
        targets.push(target)
        return guardedGoTo.call(this, target, ...options)
    }
    let completions = 0, attempts = 0
    const reader = { view, isClosed: false, hasLoadedLastPosition: false,
        completeLastPositionLoad() { completions += 1; this.hasLoadedLastPosition = true },
        completeLastPositionLoadAttempt() { attempts += 1 },
    }
    const host = { reader, document, manabiLoadEBookToken: 1,
        setTimeout, clearTimeout, requestAnimationFrame: globalThis.requestAnimationFrame,
        cancelAnimationFrame: globalThis.cancelAnimationFrame,
    }
    const { loadLastPosition } = createEbookLoadHandlers({ host,
        ensureRestorePositionSaveUserInputTracking() {},
        runWithNavigationIntent: createNavigationIntentRunner(host),
        markReaderRenderReady() {}, postLandscapeInsetRestoreProbe() {}, scheduleDeferredCacheWarmerOpen() {},
    })
    return { reader, view, renderer, targets, initialMetrics,
        get completions() { return completions }, get attempts() { return attempts },
        restore: position => bounded(loadLastPosition(position)),
        async refreshSnapshot() {
            const metrics = await renderer.pageMetrics()
            snapshot = { current: metrics.page, total: Math.max(1, metrics.pages - 2) }
        },
        close() {
            reader.isClosed = true
            view.close()
            view.remove()
            for (const frame of frames.splice(0)) frame.window.close()
            textWidth = 1200
        },
    }
}

test('synthetic restore crosses pages in an already visible section through the installed wrapper', async () => {
    const f = await fixture()
    try {
        const result = await f.restore({ cfi: 'mnb-loc-v1:0:1:2', fractionalCompletion: 0.5 })
        assert.equal((await f.renderer.pageMetrics()).page, 2)
        assert.equal(f.view.lastLocation.fraction, 0.5)
        assert.equal(result.handledCFI, 'mnb-loc-v1:0:1:2')
        assert.deepEqual(f.targets, [{ index: 0, localPage: 1 }])
        await f.refreshSnapshot()

        const first = await f.restore({ cfi: 'mnb-loc-v1:0:0:2', fractionalCompletion: 0.25 })
        assert.equal((await f.renderer.pageMetrics()).page, 1)
        assert.equal(f.view.lastLocation.fraction, 0.25)
        assert.equal(first.handledCFI, 'mnb-loc-v1:0:0:2')
        assert.equal(f.completions, 2)
        assert.equal(f.attempts, 0)
    } finally { f.close() }
})

test('a one-page synthetic locator reaches the actual paginator without a Reader displayInitialSection method', async () => {
    const f = await fixture({ width: 600 })
    try {
        assert.equal(f.initialMetrics.pages, 3)
        const result = await f.restore({ cfi: 'mnb-loc-v1:0:0:1', fractionalCompletion: 0.5 })
        assert.equal((await f.renderer.pageMetrics()).page, 1)
        assert.equal(result.handledCFI, 'mnb-loc-v1:0:0:1')
        assert.deepEqual(f.targets, [{ index: 0, localPage: 0 }])
        assert.equal(f.completions, 1)
    } finally { f.close() }
})

test('a scrolled renderer restores a positive saved fraction without acknowledging an unapplied synthetic page', async () => {
    const f = await fixture({ scrolled: true })
    try {
        const result = await f.restore({ cfi: 'mnb-loc-v1:0:1:2', fractionalCompletion: 0.25 })
        assert.equal(result.handledCFI, null)
        assert.equal(result.currentFractionalCompletion, 0.25)
        assert.deepEqual(f.targets, [{ index: 0, anchor: 0.5 }])
        assert.equal(f.completions, 1)
        assert.equal(f.attempts, 0)
    } finally { f.close() }
})

for (const fractionalCompletion of [null, 0]) {
    test(`a scrolled renderer cannot acknowledge a synthetic page with saved fraction ${fractionalCompletion}`, async () => {
        const f = await fixture({ scrolled: true })
        try {
            await assert.rejects(f.restore({ cfi: 'mnb-loc-v1:0:1:2', fractionalCompletion }))
            assert.deepEqual(f.targets, [])
            assert.equal(f.reader.hasLoadedLastPosition, false)
            assert.equal(f.completions, 0)
            assert.equal(f.attempts, 1)
        } finally { f.close() }
    })
}

test('a superseded synthetic source cannot fall back over a newer navigation on the same renderer', async () => {
    const f = await fixture()
    let release, admitted
    const source = new Promise(resolve => { release = resolve })
    const entered = new Promise(resolve => { admitted = resolve })
    let held = true
    f.view.book.sections[1].load = () => {
        if (!held) return Promise.resolve('fixture:1')
        held = false
        admitted()
        return source
    }
    const old = f.restore({ cfi: 'mnb-loc-v1:1:1:2', fractionalCompletion: 1 })
        .then(value => ({ value }), error => ({ error }))
    try {
        await bounded(entered)
        await bounded(f.renderer.goTo({ index: 0, localPage: 1 }))
        assert.equal(f.renderer.getContents()[0].index, 0)
        assert.equal((await f.renderer.pageMetrics()).page, 2)

        release('fixture:1')
        const result = await old
        assert.equal(f.renderer.getContents()[0].index, 0)
        assert.equal((await f.renderer.pageMetrics()).page, 2)
        assert.ok(result.error)
        assert.equal(f.completions, 0)
        assert.deepEqual(f.targets, [
            { index: 1, localPage: 1 },
            { index: 0, localPage: 1 },
        ])
    } finally {
        release('fixture:1')
        await old
        f.close()
    }
})

test.after(() => dom.window.close())
