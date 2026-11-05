import assert from 'node:assert/strict'
import test from 'node:test'

// Only browser hosting is doubled. Admission and page-turn locking execute the
// production Paginator; these cases make no DOM/layout correctness claim.
class Element extends EventTarget {
    style = {}
    classList = { add() {}, remove() {} }
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
