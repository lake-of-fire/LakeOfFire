import assert from 'node:assert/strict'
import test from 'node:test'

// The actual View, FixedLayout, manual-navigation runner and HUD execute below.
// Only DOM/frame transport and unrelated HUD paint hooks are controlled. This
// checks their command/result boundary; it does not claim browser geometry.
const pendingIframes = []

class ShadowRoot {
    adoptedStyleSheets = []
    children = []
    append(element) { element.parent = this; this.children.push(element) }
    replaceChildren() {
        for (const child of this.children) child.parent = null
        this.children = []
    }
}

globalThis.HTMLElement = class extends EventTarget {
    attachShadow() { return new ShadowRoot() }
    getBoundingClientRect() { return { width: 1_200, height: 800 } }
    remove() {}
}
globalThis.CSSStyleSheet = class { replaceSync() {} }
globalThis.CustomEvent = class extends Event {
    constructor(type, options) { super(type); this.detail = options?.detail }
}
globalThis.ResizeObserver = class { observe() {} unobserve() {} }
globalThis.customElements = { define() {} }
globalThis.requestAnimationFrame = () => 1
globalThis.cancelAnimationFrame = () => {}
globalThis.document = {
    body: { style: {} },
    documentElement: { style: {} },
    getElementById: () => null,
    createElement(tagName) {
        if (tagName === 'style') return { parent: null, textContent: '' }
        if (tagName === 'div') return {
            parent: null,
            style: {},
            append(iframe) { this.iframe = iframe },
            remove() {
                if (this.parent) this.parent.children = this.parent.children.filter(child => child !== this)
                this.parent = null
            },
        }
        if (tagName === 'iframe') {
            const listeners = new Map()
            return {
                contentDocument: null,
                style: {},
                addEventListener(name, listener) { listeners.set(name, listener) },
                removeEventListener(name) { listeners.delete(name) },
                setAttribute() {},
                set src(value) { this.source = value; pendingIframes.push(this) },
                finishLoading(document) { this.contentDocument = document; listeners.get('load')?.() },
                failLoading() { listeners.get('error')?.() },
            }
        }
        throw new Error(`Unexpected host element: ${tagName}`)
    },
}

const { FixedLayout } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/fixed-layout.js')
const { View } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/view.js')
const { NavigationHUD } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-viewer-nav.js')
const { createManualNavigationRunner, createNavigationIntentRunner } = await import(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-load-coordinator.js'
)

const chapterDocument = index => ({
    title: `chapter-${index}`,
    documentElement: { nodeName: 'html' },
    querySelector: () => null,
})

const nextFrame = async source => {
    for (let attempt = 0; attempt < 100; attempt += 1) {
        const index = pendingIframes.findIndex(frame => frame.source === source)
        if (index >= 0) return pendingIframes.splice(index, 1)[0]
        await new Promise(resolve => setImmediate(resolve))
    }
    throw new Error(`No frame acquired for ${source}`)
}

const fixture = t => {
    const sections = [0, 1, 2].map(index => ({ id: `chapter-${index}`, load: async () => `chapter-${index}.xhtml` }))
    const book = { dir: 'ltr', sections, rendition: { spread: 'none', viewport: { width: 600, height: 800 } } }
    const renderer = new FixedLayout()
    renderer.open(book)
    const view = new View()
    view.book = book
    view.renderer = renderer
    const reader = { view, isClosed: false }
    const host = { reader }
    const accepted = [], history = []
    const push = view.history.pushState.bind(view.history)
    view.history.pushState = value => { history.push(value); push(value) }
    const run = createManualNavigationRunner({
        host,
        runWithNavigationIntent: createNavigationIntentRunner(host),
        captureOwner: () => ({ isCurrent: () => true }),
        onAccepted: value => accepted.push(value),
    })
    const goTo = (index, extraOptions = {}) => run({ source: 'composition' },
        (currentView, options) => currentView.goTo(index, { ...options, ...extraOptions }), { reader, view })
    const previous = () => run(null, (currentView, options) => currentView.prev(undefined, options), { reader, view })
    const display = async index => {
        const command = goTo(index)
        const frame = await nextFrame(`chapter-${index}.xhtml`)
        frame.finishLoading(chapterDocument(index))
        return command
    }
    t.after(() => { renderer.destroy(); pendingIframes.length = 0 })
    return { renderer, view, reader, host, accepted, history, goTo, previous, display }
}

test('actual View and runner accept FXL void success, preserve failed spread, and admit retry', async t => {
    t.mock.method(console, 'error', () => {})
    const f = fixture(t)
    const firstReceipt = await f.display(0)
    assert.equal(typeof f.renderer.isNavigationReceiptCurrent, 'undefined')
    assert.equal(f.view.isNavigationReceiptCurrent(firstReceipt), true)
    assert.equal(f.accepted.length, 1)
    assert.deepEqual(f.history, [0])

    const failed = f.goTo(1)
    const rejected = assert.rejects(failed, /Failed to load fixed-layout frame/)
    const failedFrame = await nextFrame('chapter-1.xhtml')
    failedFrame.failLoading()
    await rejected
    assert.equal(f.accepted.length, 1)
    assert.deepEqual(f.history, [0])
    assert.deepEqual(f.renderer.getContents().map(content => content.index), [0])

    const retryReceipt = await f.display(1)
    assert.equal(f.view.isNavigationReceiptCurrent(retryReceipt), true)
    assert.equal(f.view.isNavigationReceiptCurrent(firstReceipt), false)
    assert.equal(f.accepted.length, 2)
    assert.deepEqual(f.history, [0, 1])
    assert.deepEqual(f.renderer.getContents().map(content => content.index), [1])

    const previous = f.previous()
    const previousFrame = await nextFrame('chapter-0.xhtml')
    previousFrame.finishLoading(chapterDocument(0))
    const previousReceipt = await previous
    assert.equal(f.view.isNavigationReceiptCurrent(previousReceipt), true)
    assert.equal(f.accepted.length, 3)
    assert.deepEqual(f.renderer.getContents().map(content => content.index), [0])
})

test('actual FXL retirement cannot turn its void result into a current View receipt', async t => {
    const f = fixture(t)
    await f.display(0)
    const oldCommand = f.goTo(1)
    const oldFrame = await nextFrame('chapter-1.xhtml')
    const currentReceipt = await f.goTo(0)
    assert.equal(await oldCommand, null)
    oldFrame.finishLoading(chapterDocument(1))
    assert.equal(f.view.isNavigationReceiptCurrent(currentReceipt), true)
    assert.deepEqual(f.renderer.getContents().map(content => content.index), [0])
    assert.equal(f.accepted.length, 2)
    assert.equal(f.history.includes(1), false)
})

test('actual HUD Back keeps its target through FXL frame failure and consumes only the retry receipt', async t => {
    t.mock.method(console, 'error', () => {})
    const f = fixture(t)
    await f.display(1)
    const current = { sectionIndex: 1, fraction: 0.5, cfi: 'current' }
    const target = { sectionIndex: 0, fraction: 0, cfi: 'target' }
    const hud = new NavigationHUD({
        onJumpRequest: descriptor => f.goTo(descriptor.sectionIndex, { recordHistory: false }),
        isJumpRequestCurrent: receipt => f.host.reader === f.reader && !f.reader.isClosed
            && f.view.isNavigationReceiptCurrent(receipt),
        getRenderer: () => f.renderer,
    })
    // Reuse the existing HUD fixture's paint/metrics collaborators. Command,
    // stack, pending-jump and receipt ownership remain the production methods.
    hud._applyPageTurnNavigationVisibility = () => {}
    hud._updatePrimaryLine = () => {}
    hud._toggleCompletionStack = () => {}
    hud._updateSectionProgress = async () => {}
    hud._updateRelocateButtons = () => {}
    hud._updateRendererSnapshotFromDetail = () => null
    hud._refreshRendererSnapshot = async () => null
    hud.currentLocationDescriptor = current
    hud.relocateStacks.back.push(target)
    t.after(() => hud.destroy())

    const failed = hud._handleRelocateJump('back')
    const pending = hud.pendingRelocateJump
    const failedFrame = await nextFrame('chapter-0.xhtml')
    await hud.handleRelocate({ ...current, reason: 'anchor' })
    assert.equal(hud.pendingRelocateJump, pending)
    assert.deepEqual(hud.relocateStacks.back, [target])
    failedFrame.failLoading()
    await failed
    assert.equal(hud.pendingRelocateJump, null)
    assert.equal(hud.isProcessingRelocateJump, false)
    assert.deepEqual(hud.relocateStacks.back, [target])
    assert.deepEqual(hud.relocateStacks.forward, [])
    assert.deepEqual(f.renderer.getContents().map(content => content.index), [1])
    assert.equal(f.accepted.length, 1)

    const retry = hud._handleRelocateJump('back')
    const retryFrame = await nextFrame('chapter-0.xhtml')
    retryFrame.finishLoading(chapterDocument(0))
    await retry
    assert.equal(hud.pendingRelocateJump, null)
    assert.equal(hud.isProcessingRelocateJump, false)
    assert.deepEqual(hud.relocateStacks.back, [])
    assert.equal(hud.relocateStacks.forward.length, 1)
    assert.equal(hud.relocateStacks.forward[0].sectionIndex, 1)
    assert.deepEqual(f.renderer.getContents().map(content => content.index), [0])
    assert.equal(f.accepted.length, 2)
})
