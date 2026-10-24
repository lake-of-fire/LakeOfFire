import assert from 'node:assert/strict'
import test from 'node:test'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { JSDOM } = require(process.env.JSDOM_MODULE ?? 'jsdom')
const html = '<!doctype html><html><body data-mnb-writing-direction="horizontal"><p><reader-sentinel id="page-start"></reader-sentinel>Readable text for the live paginator host.</p></body></html>'
const dom = new JSDOM('<!doctype html><html><body></body></html>', { pretendToBeVisual: true, url: 'https://reader.invalid/' })
const frames = []
let nextSidecars = []
let fixtureTextWidth = 1200
const rect = (width = 600, height = 800) => ({ x: 0, y: 0, top: 0, left: 0, right: width, bottom: height, width, height, toJSON() { return this } })
const installGeometry = window => {
    Object.defineProperties(window.HTMLElement.prototype, {
        clientWidth: { get() { return this.style.width?.endsWith('px') ? parseFloat(this.style.width) : 600 } },
        clientHeight: { get() { return this.style.height?.endsWith('px') ? parseFloat(this.style.height) : 800 } },
    })
    window.HTMLElement.prototype.getBoundingClientRect = function () { return rect(this.clientWidth, this.clientHeight) }
    window.Range.prototype.getBoundingClientRect = () => rect(fixtureTextWidth, 400)
    window.Range.prototype.getClientRects = () => [rect(fixtureTextWidth, 400)]
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
        installGeometry(section.window)
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
const { Paginator } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/paginator.js')

// Full production rendering/navigation code executes with deterministic DOM
// geometry and browser host doubles. This suite does not verify CSS layout or
// WKWebView behavior. Supply JSDOM_MODULE when jsdom is installed externally.
const fixture = (sectionCount = 2, sectionOverrides = []) => {
    const renderer = new Paginator()
    document.body.append(renderer)
    renderer.open({ dir: 'ltr', sections: Array.from({ length: sectionCount }, (_, index) => ({
        id: `section-${index}`, load: async () => `fixture:${index}`, unload() {},
        ...sectionOverrides[index],
    })) }, false)
    return renderer
}
const deferred = () => {
    let resolve
    const promise = new Promise(yes => { resolve = yes })
    return { promise, resolve }
}
const bounded = async operation => {
    let timer
    try {
        return await Promise.race([operation, new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error('Production navigation did not settle')), 1500)
        })])
    } finally { clearTimeout(timer) }
}
const cleanup = renderer => {
    renderer.destroy()
    renderer.remove()
    for (const frame of frames.splice(0)) frame.window.close()
    nextSidecars = []
}

test('actual paginator renders first-page metrics and owns its measured proof without an injected feature flag', async () => {
    const renderer = fixture()
    try {
        const receipt = await bounded(renderer.goTo({ index: 0, anchor: 0 }, { requiresPositionReceipt: true }))
        const metrics = await renderer.pageMetrics()
        assert.equal(metrics.page, 1)
        assert.equal(metrics.pages, 4)
        const proof = renderer.capturePositionProof(receipt)
        assert.deepEqual(proof, { sectionIndex: 0, fractionInSection: 0, pageFraction: 0.5 })
        assert.equal(renderer.isPositionProofCurrent(proof), true)
        const replacement = await bounded(renderer.goTo({ index: 1, anchor: 0 }, { requiresPositionReceipt: true }))
        assert.equal(renderer.isPositionProofCurrent(proof), false)
        assert.equal(renderer.capturePositionProof(replacement).sectionIndex, 1)
    } finally { cleanup(renderer) }
})

for (const targetIndex of [0, 1]) {
    test(`held iframe sidecar cannot strand or republish over successor section ${targetIndex}`, async () => {
        const gate = deferred(), entered = deferred()
        nextSidecars = [() => { entered.resolve(); return gate.promise }]
        const renderer = fixture()
        let displays = 0
        renderer.addEventListener('didDisplay', () => { displays += 1 })
        const old = renderer.goTo({ index: 0, anchor: 0 }, { requiresPositionReceipt: true })
        try {
            await bounded(entered.promise)
            const newer = await bounded(renderer.goTo({ index: targetIndex, anchor: 0 }, { requiresPositionReceipt: true }))
            const activeDocument = renderer.getContents()[0].doc
            assert.equal(renderer.isPositionReceiptCurrent(newer), true)
            assert.equal(displays, 1)
            gate.resolve()
            assert.equal(await bounded(old), null)
            assert.equal(renderer.getContents()[0].doc, activeDocument)
            assert.equal(displays, 1)
            assert.equal(renderer.capturePositionProof(newer).sectionIndex, targetIndex)
        } finally {
            gate.resolve()
            await old.catch(() => {})
            cleanup(renderer)
        }
    })
}

test('a suspended snap cannot adopt a successor command and display its neighboring section', async () => {
    const renderer = fixture(3)
    const gate = deferred(), entered = deferred()
    try {
        await bounded(renderer.goTo({ index: 0, anchor: 1 }))
        const pageMetrics = renderer.pageMetrics.bind(renderer)
        const previousMetrics = await pageMetrics()
        renderer.pageMetrics = () => {
            renderer.pageMetrics = pageMetrics
            entered.resolve()
            return gate.promise
        }
        const old = renderer.snap(2, 0)
        await bounded(entered.promise)
        const current = await bounded(renderer.goTo({ index: 1, anchor: 0 }, { requiresPositionReceipt: true }))
        gate.resolve(previousMetrics)
        await bounded(old)
        assert.equal(renderer.getContents()[0].index, 1)
        assert.equal((await pageMetrics()).page, 1)
        assert.equal(renderer.isPositionReceiptCurrent(current), true)
    } finally {
        gate.resolve({})
        cleanup(renderer)
    }
})

test('a current snap crosses sections and the following ordinary page turn still completes', async () => {
    const renderer = fixture(3)
    try {
        await bounded(renderer.goTo({ index: 0, anchor: 1 }))
        await bounded(renderer.snap(2, 0))
        assert.equal(renderer.getContents()[0].index, 1)
        assert.equal((await renderer.pageMetrics()).page, 1)
        await bounded(renderer.next())
        assert.equal(renderer.getContents()[0].index, 1)
        assert.equal((await renderer.pageMetrics()).page, 2)
    } finally { cleanup(renderer) }
})

for (const suspension of ['frame', 'scroll-property']) {
    test(`a scrollBy suspended at ${suspension} cannot move the successor document`, async () => {
        const renderer = fixture()
        const gate = deferred(), entered = deferred()
        const requestFrame = globalThis.requestAnimationFrame
        try {
            await bounded(renderer.goTo({ index: 0, anchor: 0 }))
            if (suspension === 'frame') {
                globalThis.requestAnimationFrame = callback => {
                    globalThis.requestAnimationFrame = requestFrame
                    entered.resolve()
                    gate.promise.then(() => callback(performance.now()))
                    return -1
                }
            } else {
                const scrollProp = renderer.scrollProp.bind(renderer)
                renderer.scrollProp = () => {
                    renderer.scrollProp = scrollProp
                    entered.resolve()
                    return gate.promise.then(() => 'scrollLeft')
                }
            }
            const old = renderer.scrollBy(600, 0)
            await bounded(entered.promise)
            const current = await bounded(renderer.goTo({ index: 1, anchor: 0 }, { requiresPositionReceipt: true }))
            const before = await renderer.pageMetrics()
            gate.resolve()
            await bounded(old)
            assert.equal(renderer.getContents()[0].index, 1)
            assert.equal((await renderer.pageMetrics()).start, before.start)
            assert.equal(renderer.isPositionReceiptCurrent(current), true)
        } finally {
            globalThis.requestAnimationFrame = requestFrame
            gate.resolve()
            cleanup(renderer)
        }
    })
}

test('actual paginator navigation receipts distinguish completed movement and proven boundary no-ops', async () => {
    const renderer = fixture(1)
    try {
        await bounded(renderer.goTo({ index: 0, anchor: 0 }))
        const firstPage = await renderer.pageMetrics()
        const startBoundary = await bounded(renderer.prev(1, { requiresNavigationReceipt: true }))
        assert.equal(renderer.isNavigationReceiptCurrent(startBoundary), true)
        assert.equal(startBoundary.moved, false)
        assert.equal((await renderer.pageMetrics()).start, firstPage.start)
        const moved = await bounded(renderer.next(1, { requiresNavigationReceipt: true }))
        assert.equal(renderer.isNavigationReceiptCurrent(moved), true)
        assert.equal(moved.moved, true)
        assert.equal(renderer.isNavigationReceiptCurrent(startBoundary), false)
        const lastPage = await renderer.pageMetrics()
        assert.equal(lastPage.page, lastPage.pages - 2)
        const endBoundary = await bounded(renderer.next(1, { requiresNavigationReceipt: true }))
        assert.equal(renderer.isNavigationReceiptCurrent(endBoundary), true)
        assert.equal(endBoundary.moved, false)
        assert.equal((await renderer.pageMetrics()).start, lastPage.start)
        assert.equal(renderer.isNavigationReceiptCurrent(moved), false)
    } finally { cleanup(renderer) }
})

test('actual paginator queued replacement grants only the final accepted command a receipt', async () => {
    fixtureTextWidth = 2400
    const renderer = fixture(1), queued = deferred()
    let first, replaced, current
    try {
        await bounded(renderer.goTo({ index: 0, anchor: 0 }))
        assert.ok((await renderer.pageMetrics()).pages >= 5, 'controlled DOM geometry leaves room for a queued turn')
        renderer.addEventListener('relocate', () => {
            replaced = renderer.next(1, { requiresNavigationReceipt: true })
            current = renderer.next(1, { requiresNavigationReceipt: true })
            queued.resolve()
        }, { once: true })
        first = renderer.next(1, { requiresNavigationReceipt: true })
        await bounded(queued.promise)
        const [firstResult, replacedResult, currentReceipt] = await bounded(Promise.all([first, replaced, current]))
        assert.equal(firstResult, null)
        assert.equal(replacedResult.superseded, true)
        assert.equal(renderer.isNavigationReceiptCurrent(replacedResult), false)
        assert.equal(renderer.isNavigationReceiptCurrent(currentReceipt), true)
        assert.equal(currentReceipt.moved, true)
        assert.equal(renderer.getContents()[0].index, 0)
        assert.equal((await renderer.pageMetrics()).page, 3)
    } finally {
        fixtureTextWidth = 1200
        cleanup(renderer)
        await Promise.allSettled([first, replaced, current].filter(Boolean).map(operation => bounded(operation)))
    }
})

const acquisitionFixture = loaders => {
    const loads = [], unloads = []
    const renderer = fixture(loaders.length, loaders.map((load, index) => ({
        // Explicit navigation supports non-linear sections. Excluding these
        // from neighbor prefetch makes the producer schedules deterministic.
        linear: 'no',
        async load() { loads.push(index); return await load() },
        unload() { unloads.push(index) },
    })))
    const loaded = [], relocated = [], displayed = []
    renderer.addEventListener('load', event => loaded.push(event.detail.index))
    renderer.addEventListener('relocate', event => relocated.push(event.detail.index))
    renderer.addEventListener('didDisplay', () => displayed.push(renderer.getContents()[0]?.index))
    return { renderer, loads, unloads, loaded, relocated, displayed }
}

test('missing required source preserves the visible document, same-index reposition, and a later retry', async () => {
    let missing = true
    const state = acquisitionFixture([
        async () => 'fixture:original',
        async () => missing ? null : 'fixture:retry',
    ])
    const { renderer } = state
    try {
        await bounded(renderer.goTo({ index: 0, anchor: 0 }, { requiresNavigationReceipt: true }))
        const originalDocument = renderer.getContents()[0].doc
        const frameCount = frames.length
        assert.equal(renderer.style.visibility, 'visible')

        await assert.rejects(
            bounded(renderer.goTo({ index: 1, anchor: 0 }, { requiresNavigationReceipt: true })),
            /Missing paginator source for section 1/,
        )
        assert.equal(renderer.getContents()[0].index, 0)
        assert.equal(renderer.getContents()[0].doc, originalDocument)
        assert.equal(renderer.style.visibility, 'visible')
        assert.equal(frames.length, frameCount)
        assert.deepEqual(state.unloads, [])
        assert.deepEqual(state.loaded, [0])
        assert.deepEqual(state.displayed, [0])
        assert.equal(state.relocated.includes(1), false)

        const repositioned = await bounded(renderer.goTo(
            { index: 0, anchor: 1 }, { requiresNavigationReceipt: true },
        ))
        assert.equal(renderer.isNavigationReceiptCurrent(repositioned), true)
        assert.equal(renderer.getContents()[0].doc, originalDocument)
        assert.deepEqual(state.loads, [0, 1], 'same-index reposition must not reacquire the original section')
        assert.deepEqual(state.unloads, [])

        missing = false
        const retried = await bounded(renderer.goTo(
            { index: 1, anchor: 0 }, { requiresNavigationReceipt: true },
        ))
        assert.equal(renderer.isNavigationReceiptCurrent(retried), true)
        assert.equal(renderer.getContents()[0].index, 1)
        assert.notEqual(renderer.getContents()[0].doc, originalDocument)
        assert.equal(renderer.style.visibility, 'visible')
        assert.deepEqual(state.unloads, [0])
        assert.deepEqual(state.loaded, [0, 1])
        assert.equal(state.relocated.includes(1), true)
    } finally { cleanup(renderer) }
})

test('initial missing source publishes no rendered section and a valid retry remains possible', async () => {
    let missing = true
    const state = acquisitionFixture([async () => missing ? null : 'fixture:first-valid'])
    const { renderer } = state
    try {
        await assert.rejects(
            bounded(renderer.goTo({ index: 0, anchor: 0 }, { requiresPositionReceipt: true })),
            /Missing paginator source for section 0/,
        )
        assert.deepEqual(renderer.getContents(), [])
        assert.deepEqual(state.loaded, [])
        assert.deepEqual(state.relocated, [])
        assert.deepEqual(state.displayed, [])
        assert.deepEqual(state.unloads, [])

        missing = false
        const receipt = await bounded(renderer.goTo(
            { index: 0, anchor: 0 }, { requiresPositionReceipt: true },
        ))
        assert.equal(renderer.isPositionReceiptCurrent(receipt), true)
        assert.equal(renderer.getContents()[0].index, 0)
        assert.equal(renderer.style.visibility, 'visible')
        assert.deepEqual(state.loaded, [0])
        assert.deepEqual(state.displayed, [0])
        assert.equal(renderer.capturePositionProof(receipt).sectionIndex, 0)
    } finally { cleanup(renderer) }
})

for (const terminal of ['missing', 'rejected']) {
    test(`obsolete ${terminal} acquisition cannot change the successor's visible frame or publication`, async () => {
        const gate = deferred(), entered = deferred()
        const lateError = new Error('Obsolete section producer failed')
        const state = acquisitionFixture([
            async () => 'fixture:original',
            async () => {
                entered.resolve()
                await gate.promise
                if (terminal === 'rejected') throw lateError
                return null
            },
            async () => 'fixture:successor',
        ])
        const { renderer } = state
        let oldOutcome
        try {
            await bounded(renderer.goTo({ index: 0, anchor: 0 }))
            const originalDocument = renderer.getContents()[0].doc
            oldOutcome = renderer.goTo({ index: 1, anchor: 0 }, { requiresNavigationReceipt: true })
                .then(value => ({ value }), error => ({ error }))
            await bounded(entered.promise)
            assert.equal(renderer.getContents()[0].doc, originalDocument)
            assert.equal(renderer.style.visibility, 'visible', 'pending acquisition must keep the current page visible')

            const successor = await bounded(renderer.goTo(
                { index: 2, anchor: 0 }, { requiresNavigationReceipt: true },
            ))
            const successorDocument = renderer.getContents()[0].doc
            const successorMetrics = await renderer.pageMetrics()
            const published = {
                loaded: [...state.loaded], relocated: [...state.relocated],
                displayed: [...state.displayed], unloads: [...state.unloads],
            }
            gate.resolve()
            const outcome = await bounded(oldOutcome)
            if (terminal === 'rejected') assert.equal(outcome.error, lateError)
            else assert.equal(outcome.value, null)

            assert.equal(renderer.isNavigationReceiptCurrent(successor), true)
            assert.equal(renderer.getContents()[0].index, 2)
            assert.equal(renderer.getContents()[0].doc, successorDocument)
            assert.equal(renderer.style.visibility, 'visible')
            assert.equal((await renderer.pageMetrics()).start, successorMetrics.start)
            assert.deepEqual(state.loaded, published.loaded)
            assert.deepEqual(state.relocated, published.relocated)
            assert.deepEqual(state.displayed, published.displayed)
            assert.deepEqual(state.unloads, published.unloads)
            assert.equal(state.loaded.includes(1), false)
            assert.equal(state.relocated.includes(1), false)
        } finally {
            gate.resolve()
            try {
                if (oldOutcome) await bounded(oldOutcome)
            } finally { cleanup(renderer) }
        }
    })
}

test.after(() => dom.window.close())
