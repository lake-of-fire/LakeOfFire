import assert from 'node:assert/strict'
import test from 'node:test'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { JSDOM } = require(process.env.JSDOM_MODULE ?? 'jsdom')
const html = '<!doctype html><html><body data-mnb-writing-direction="horizontal"><p><reader-sentinel id="page-start"></reader-sentinel>Readable text for the live paginator host.</p></body></html>'
const dom = new JSDOM('<!doctype html><html><body></body></html>', { pretendToBeVisual: true, url: 'https://reader.invalid/' })
const frames = []
let nextSidecars = []
const rect = (width = 600, height = 800) => ({ x: 0, y: 0, top: 0, left: 0, right: width, bottom: height, width, height, toJSON() { return this } })
const installGeometry = window => {
    Object.defineProperties(window.HTMLElement.prototype, {
        clientWidth: { get() { return this.style.width?.endsWith('px') ? parseFloat(this.style.width) : 600 } },
        clientHeight: { get() { return this.style.height?.endsWith('px') ? parseFloat(this.style.height) : 800 } },
    })
    window.HTMLElement.prototype.getBoundingClientRect = function () { return rect(this.clientWidth, this.clientHeight) }
    window.Range.prototype.getBoundingClientRect = () => rect(1200, 400)
    window.Range.prototype.getClientRects = () => [rect(1200, 400)]
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
const fixture = (sectionCount = 2) => {
    const renderer = new Paginator()
    document.body.append(renderer)
    renderer.open({ dir: 'ltr', sections: Array.from({ length: sectionCount }, (_, index) => ({
        id: `section-${index}`, load: async () => `fixture:${index}`, unload() {},
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

test.after(() => dom.window.close())
