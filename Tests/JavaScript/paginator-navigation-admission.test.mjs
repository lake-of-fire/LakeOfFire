import assert from 'node:assert/strict'
import test from 'node:test'

// Only browser hosting is doubled. Admission and page-turn locking execute the
// production Paginator; these cases make no DOM/layout correctness claim.
class Element extends EventTarget {
    style = {}
    classList = { add() {}, remove() {} }
    attributes = new Map()
    getAttribute(name) { return this.attributes.get(name) ?? null }
    hasAttribute(name) { return this.attributes.has(name) }
    setAttribute(name, value) {
        const oldValue = this.getAttribute(name)
        this.attributes.set(name, String(value))
        if (this.constructor.observedAttributes?.includes(name)) {
            this.attributeChangedCallback(name, oldValue, String(value))
        }
    }
}
globalThis.HTMLElement = class extends Element {
    attachShadow() {
        const elements = new Map()
        return {
            innerHTML: '',
            getElementById(id) {
                if (!elements.has(id)) elements.set(id, new Element())
                return elements.get(id)
            },
        }
    }
}
globalThis.NodeFilter = {
    SHOW_ELEMENT: 1, SHOW_TEXT: 4, SHOW_CDATA_SECTION: 8,
    FILTER_ACCEPT: 1, FILTER_REJECT: 2, FILTER_SKIP: 3,
}
globalThis.ResizeObserver = class { observe() {} unobserve() {} }
globalThis.Range = class {}
globalThis.customElements = { define() {} }

const { Paginator } = await import(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/paginator.js'
)
const { runRequiredRestoreNavigation } = await import(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-restore-coordination.js'
)

const deferred = () => {
    let resolve
    const promise = new Promise(yes => { resolve = yes })
    return { promise, resolve }
}
const fixture = () => {
    const renderer = new Paginator()
    const failure = new Error('intentional section-load failure')
    let loads = 0
    renderer.open({
        dir: 'ltr',
        sections: [{ load: async () => { loads += 1; throw failure } }],
    }, true)
    return { renderer, failure, get loads() { return loads } }
}

test('invalid paginator targets explicitly reject required restore without section loading', async () => {
    const f = fixture()
    for (const target of [null, undefined, {}, ...[-1, 1, 0.5, NaN, Infinity, '0'].map(index => ({ index }))]) {
        const result = await runRequiredRestoreNavigation(() => f.renderer.goTo(target))
        assert.equal(result.ok, false)
        assert.equal(result.value, null)
    }
    assert.equal(f.loads, 0)
    f.renderer.destroy()
})

test('paginator admits a valid target and preserves its actual section-load error', async () => {
    const f = fixture()
    await assert.rejects(f.renderer.goTo({ index: 0 }), error => error === f.failure)
    assert.equal(f.loads, 1)
    f.renderer.destroy()
})

test('a live page-turn lock explicitly rejects target navigation', async () => {
    const f = fixture(), metrics = deferred()
    f.renderer.pageMetrics = () => metrics.promise
    const turn = f.renderer.next()
    const settled = assert.rejects(turn, error => error === f.failure)
    try {
        const result = await runRequiredRestoreNavigation(() => f.renderer.goTo({ index: 0 }))
        assert.equal(result.ok, false)
        assert.equal(result.value, null)
        assert.equal(f.loads, 0)
    } finally {
        metrics.resolve({ page: 0, pages: 2 })
        await settled
        f.renderer.destroy()
    }
})

test('target resolution rechecks a page-turn lock acquired after admission', async () => {
    const f = fixture(), target = deferred(), metrics = deferred()
    const navigation = f.renderer.goTo(target.promise)
    f.renderer.pageMetrics = () => metrics.promise
    const turn = f.renderer.next()
    const settled = assert.rejects(turn, error => error === f.failure)
    try {
        target.resolve({ index: 0 })
        assert.equal(await navigation, null)
        assert.equal(f.loads, 0)
    } finally {
        metrics.resolve({ page: 0, pages: 2 })
        await settled
        f.renderer.destroy()
    }
})


test('older asynchronous target never adopts a newer renderer command', async () => {
    const f = fixture(), target = deferred()
    const old = f.renderer.goTo(target.promise, { requiresPositionReceipt: true })
    await assert.rejects(f.renderer.goTo({ index: 0 }), error => error === f.failure)
    target.resolve({ index: 0, anchor: 0 })
    assert.equal(await old, null)
    assert.equal(f.loads, 1)
    f.renderer.destroy()
})

test('synchronous goTo observer replacement prevents the old section load', async () => {
    const f = fixture()
    let replacement
    f.renderer.addEventListener('goTo', () => {
        replacement = f.renderer.goTo({ index: -1 })
    }, { once: true })
    assert.equal(await f.renderer.goTo({ index: 0, anchor: 0 }, { requiresPositionReceipt: true }), null)
    assert.equal(await replacement, null)
    assert.equal(f.loads, 0)
    f.renderer.destroy()
})

test('destroy during asynchronous target resolution rejects before section loading', async () => {
    const f = fixture(), target = deferred()
    const pending = f.renderer.goTo(target.promise, { requiresPositionReceipt: true })
    f.renderer.destroy()
    target.resolve({ index: 0, anchor: 0 })
    assert.equal(await pending, null)
    assert.equal(f.loads, 0)
    assert.equal(f.renderer.capturePositionProof({ index: 0, anchor: 0 }), null)
    assert.equal(f.renderer.isPositionProofCurrent({}), false)
})

test('a failed opted-in navigation does not prevent a later admitted command', async () => {
    const f = fixture()
    for (let index = 0; index < 2; index++) {
        await assert.rejects(f.renderer.goTo({ index: 0, anchor: 0 }, { requiresPositionReceipt: true }),
            error => error === f.failure)
    }
    assert.equal(f.loads, 2)
    f.renderer.destroy()
})


test('wheel foreground callback supersession stops the original page-turn handler', async () => {
    const renderer = new Paginator()
    renderer.open({ dir: 'ltr', sections: [] }, false)
    let turns = 0
    let activity = 0
    let successor
    renderer.prev = renderer.next = async () => { turns += 1 }
    renderer.addEventListener('foregroundPageTurnActivity', () => {
        activity += 1
        successor = renderer.goTo({ index: -1 })
    })
    const wheel = new Event('wheel', { cancelable: true })
    Object.assign(wheel, { deltaX: 20, deltaY: 0 })
    renderer.dispatchEvent(wheel)
    await successor
    assert.equal(activity, 1)
    assert.equal(turns, 0)
    renderer.destroy()
})
