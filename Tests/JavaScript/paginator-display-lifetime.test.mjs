import assert from 'node:assert/strict'
import test from 'node:test'

// Browser hosting and page metrics are controlled. Section admission, display,
// retirement and loading-class changes execute the actual Paginator. Success
// sources are real data URLs; the parser endpoint is controlled. No iframe
// rendering or page geometry is qualified.
class Element extends EventTarget {
    style = {}
    attributes = new Map()
    classes = new Set()
    classList = {
        add: name => this.classes.add(name),
        remove: name => this.classes.delete(name),
        contains: name => this.classes.has(name),
    }
    getAttribute(name) { return this.attributes.get(name) ?? null }
    hasAttribute(name) { return this.attributes.has(name) }
    setAttribute(name, value) { this.attributes.set(name, String(value)) }
}
globalThis.HTMLElement = class extends Element {
    attachShadow() {
        this.hostedElements = new Map()
        return {
            innerHTML: '',
            getElementById: id => {
                if (!this.hostedElements.has(id)) this.hostedElements.set(id, new Element())
                return this.hostedElements.get(id)
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
const sourceURL = 'data:application/xhtml+xml,%3Chtml%3Efixture%3C%2Fhtml%3E'
globalThis.DOMParser = class {
    parseFromString(text) {
        assert.equal(text, '<html>fixture</html>')
        return { location: { href: sourceURL } }
    }
}

const { Paginator } = await import(process.env.PAGINATOR_MODULE ?? new URL(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/paginator.js', import.meta.url,
))

const deferred = () => {
    let resolve, reject
    const promise = new Promise((yes, no) => { resolve = yes; reject = no })
    return { promise, resolve, reject }
}
const heldSource = () => {
    const source = deferred()
    const entered = deferred()
    return { ...source, entered: entered.promise, load() { entered.resolve(); return source.promise } }
}
const observeSettlement = operation => operation.then(
    value => ({ value }), error => ({ error }),
)
const fixture = loaders => {
    const renderer = new Paginator()
    renderer.open({ dir: 'ltr', sections: loaders.map(load => ({ load })) }, true)
    renderer.pageMetrics = async () => ({ pages: 0 })
    let displays = 0
    renderer.addEventListener('didDisplay', () => { displays += 1 })
    return {
        renderer,
        loading: () => renderer.hostedElements.get('top').classList.contains('reader-loading'),
        get displays() { return displays },
        goTo: index => renderer.goTo({ index, anchor: 0 }, { requiresPositionReceipt: true }),
    }
}

test('a replaced section source cannot redisplay over the successor section', async t => {
    const source = heldSource()
    const f = fixture([source.load, async () => sourceURL])
    t.after(() => { source.resolve(sourceURL); f.renderer.destroy() })
    const old = observeSettlement(f.goTo(0))
    await source.entered
    const successor = await f.goTo(1)
    assert.equal(successor.index, 1)
    assert.equal(f.renderer.getHasPrevSection(), true)
    assert.equal(f.renderer.getHasNextSection(), false)
    assert.equal(f.displays, 1)

    source.resolve(sourceURL)
    const result = await old
    assert.equal(result.value, null)
    assert.equal(f.renderer.getHasPrevSection(), true)
    assert.equal(f.renderer.getHasNextSection(), false)
    assert.equal(f.displays, 1)
    assert.equal(f.renderer.isPositionReceiptCurrent(successor), true)
    assert.equal(f.loading(), false)
})

for (const failure of [false, true]) {
    test(`old source ${failure ? 'failure' : 'completion'} cannot clear a successor's loading state`, async t => {
        const oldSource = heldSource()
        const newSource = heldSource()
        const f = fixture([oldSource.load, newSource.load])
        t.after(() => { oldSource.resolve(sourceURL); newSource.resolve(sourceURL); f.renderer.destroy() })
        const old = observeSettlement(f.goTo(0))
        await oldSource.entered
        const successor = f.goTo(1)
        await newSource.entered
        assert.equal(f.loading(), true)
        if (failure) oldSource.reject(new Error('obsolete source failure'))
        else oldSource.resolve(sourceURL)
        await old
        assert.equal(f.loading(), true)
        assert.equal(f.displays, 0)

        newSource.resolve(sourceURL)
        const receipt = await successor
        assert.equal(receipt.index, 1)
        assert.equal(f.displays, 1)
        assert.equal(f.loading(), false)
    })
}

test('destroy while a section source is held prevents late display and preserves cleared loading', async t => {
    const source = heldSource()
    const f = fixture([source.load, async () => sourceURL])
    t.after(() => { source.resolve(sourceURL); f.renderer.destroy() })
    await f.goTo(1)
    const pending = observeSettlement(f.goTo(0))
    await source.entered
    assert.equal(f.loading(), true)
    f.renderer.destroy()
    assert.equal(f.loading(), false)

    source.resolve(sourceURL)
    const result = await pending
    assert.equal(result.value, null)
    assert.equal(f.renderer.getHasPrevSection(), true)
    assert.equal(f.renderer.getHasNextSection(), false)
    assert.equal(f.displays, 1)
    assert.equal(f.loading(), false)
    assert.equal(await f.goTo(0), null)
})

test('a current source failure settles loading and allows a successful retry', async t => {
    const failure = new Error('source failed')
    let attempts = 0
    const f = fixture([async () => {
        attempts += 1
        if (attempts === 1) throw failure
        return sourceURL
    }])
    t.after(() => f.renderer.destroy())
    await assert.rejects(f.goTo(0), error => error === failure)
    assert.equal(f.loading(), false)
    assert.equal(f.displays, 0)

    const retry = await f.goTo(0)
    assert.equal(retry.index, 0)
    assert.equal(attempts, 2)
    assert.equal(f.displays, 1)
    assert.equal(f.loading(), false)
})

test('a section loader that synchronously starts a successor still observes its own rejection', async t => {
    const failure = new Error('obsolete source rejected after reentrant navigation')
    const unhandled = []
    const onUnhandled = error => { unhandled.push(error) }
    process.on('unhandledRejection', onUnhandled)
    let successor
    const f = fixture([() => {
        successor = f.goTo(1)
        return Promise.reject(failure)
    }, async () => sourceURL])
    t.after(() => {
        process.removeListener('unhandledRejection', onUnhandled)
        f.renderer.destroy()
    })

    assert.equal(await f.goTo(0), null)
    const receipt = await successor
    await new Promise(resolve => setImmediate(resolve))
    assert.deepEqual(unhandled, [])
    assert.equal(receipt.index, 1)
    assert.equal(f.renderer.isPositionReceiptCurrent(receipt), true)
    assert.equal(f.renderer.getHasNextSection(), false)
    assert.equal(f.displays, 1)
    assert.equal(f.loading(), false)
})

test('nextSection rejects a held page-turn lock and succeeds after the failed turn releases it', async t => {
    const source = heldSource()
    const failure = new Error('pending page-turn source failed')
    let attempts = 0
    const f = fixture([() => {
        attempts += 1
        return attempts === 1 ? source.load() : Promise.resolve(sourceURL)
    }, async () => sourceURL])
    t.after(() => { source.resolve(sourceURL); f.renderer.destroy() })
    const turn = observeSettlement(f.renderer.next())
    await source.entered

    // A default-restore timeout does not cancel next(). Its nextSection()
    // fallback must reject the active lock without issuing another load.
    assert.equal(await f.renderer.nextSection(), null)
    assert.equal(attempts, 1)
    assert.equal(f.loading(), true)
    assert.equal(f.displays, 0)

    source.reject(failure)
    assert.equal((await turn).error, failure)
    assert.equal(f.loading(), false)
    assert.equal(await f.renderer.nextSection(), undefined)
    assert.equal(attempts, 2)
    assert.equal(f.displays, 1)
    assert.equal(f.renderer.getHasPrevSection(), false)
    assert.equal(f.renderer.getHasNextSection(), true)
    assert.equal(f.loading(), false)
})
