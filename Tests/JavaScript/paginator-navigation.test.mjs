import assert from 'node:assert/strict'
import test from 'node:test'

class FakeClassList {
    add() {}
    remove() {}
    contains() { return false }
    toggle() {}
}

class FakeNode extends EventTarget {
    constructor() {
        super()
        this.listeners = new Map()
        this.style = { setProperty() {} }
        this.classList = new FakeClassList()
        this.children = []
        this.dataset = {}
        this.scrollLeft = 0
        this.scrollTop = 0
    }

    addEventListener(type, listener, options) {
        super.addEventListener(type, listener, options)
        const listeners = this.listeners.get(type) ?? new Set()
        listeners.add(listener)
        this.listeners.set(type, listeners)
    }
    removeEventListener(type, listener, options) {
        super.removeEventListener(type, listener, options)
        this.listeners.get(type)?.delete(listener)
    }
    listenerCount(type) { return this.listeners.get(type)?.size ?? 0 }

    append(...nodes) { this.children.push(...nodes) }
    appendChild(node) { this.children.push(node); return node }
    prepend(node) { this.children.unshift(node); return node }
    remove() {}
    querySelector() { return null }
    querySelectorAll() { return [] }
    getBoundingClientRect() {
        return { width: 800, height: 1000, top: 0, left: 0 }
    }
}

class FakeShadowRoot extends FakeNode {
    constructor() {
        super()
        this.nodes = new Map([
            ['top', new FakeNode()],
            ['container', new FakeNode()],
            ['header', new FakeNode()],
            ['footer', new FakeNode()],
        ])
    }

    set innerHTML(_value) {}
    getElementById(id) { return this.nodes.get(id) ?? null }
}

class FakeHTMLElement extends FakeNode {
    constructor() {
        super()
        this.attributes = new Map()
    }

    attachShadow() {
        this.shadowRoot = new FakeShadowRoot()
        return this.shadowRoot
    }
    setAttribute(name, value) { this.attributes.set(name, String(value)) }
    getAttribute(name) { return this.attributes.get(name) ?? null }
    hasAttribute(name) { return this.attributes.has(name) }
    removeAttribute(name) { this.attributes.delete(name) }
}

globalThis.NodeFilter = {
    SHOW_ELEMENT: 1,
    SHOW_TEXT: 4,
    SHOW_CDATA_SECTION: 8,
    FILTER_ACCEPT: 1,
    FILTER_REJECT: 2,
    FILTER_SKIP: 3,
}
globalThis.Range = class {}
globalThis.HTMLElement = FakeHTMLElement
const resizeObservers = []
globalThis.ResizeObserver = class {
    constructor(callback) {
        this.callback = callback
        this.observed = new Set()
        this.unobserved = []
        resizeObservers.push(this)
    }
    observe(target) { this.observed.add(target) }
    unobserve(target) {
        this.unobserved.push(target)
        this.observed.delete(target)
    }
    disconnect() { this.observed.clear() }
}
globalThis.IntersectionObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
}
globalThis.MutationObserver = class {
    observe() {}
    disconnect() {}
}
globalThis.customElements = { define() {} }
globalThis.document = Object.assign(new EventTarget(), {
    createElement: () => new FakeNode(),
    createRange: () => ({}),
    implementation: { createHTMLDocument: () => ({}) },
    documentElement: new FakeNode(),
    visibilityState: 'visible',
})
globalThis.window = globalThis
globalThis.getComputedStyle = () => ({
    getPropertyValue: () => '',
    direction: 'ltr',
    writingMode: 'horizontal-tb',
})
globalThis.requestAnimationFrame = callback =>
    setTimeout(() => callback(performance.now()), 0)
globalThis.cancelAnimationFrame = clearTimeout
globalThis.CSS = { escape: value => String(value) }

const {
    Paginator,
    manabiAnimate,
    manabiCommitPaginatorDocumentState,
    manabiRunAnimationFrameOperation,
} = await import(
    '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/paginator.js'
)

test('animation-frame operations reject instead of stranding their caller', async () => {
    const failure = new Error('frame operation failed')
    await assert.rejects(
        manabiRunAnimationFrameOperation(() => { throw failure }),
        failure
    )
})

test('animated operations reject when a render step throws', async () => {
    const failure = new Error('animated render failed')
    await assert.rejects(
        manabiAnimate(0, 1, 0, value => value, () => { throw failure }),
        failure
    )
})

test('document commit revalidates ownership before provisional relocation', () => {
    const state = { committed: false }
    let current = true
    let pendingRelocationReads = 0
    const publications = []

    assert.throws(() => manabiCommitPaginatorDocumentState({
        state,
        publishCommit: () => {
            publications.push('commit')
            current = false
        },
        requireCurrent: () => {
            if (!current) throw new Error('document commit superseded')
        },
        takePendingRelocation: () => {
            pendingRelocationReads += 1
            return { index: 1 }
        },
        publishRelocation: () => publications.push('relocation'),
    }), /document commit superseded/)

    assert.equal(state.committed, true)
    assert.equal(pendingRelocationReads, 1)
    assert.deepEqual(publications, ['commit'])
})

test('destroy releases the exact container scroll and resize lifecycle', () => {
    const paginator = new Paginator()
    const container = paginator.shadowRoot.nodes.get('container')
    const observer = resizeObservers.at(-1)
    let scrollEvents = 0
    paginator.addEventListener('scroll', () => { scrollEvents += 1 })
    const originalSetTimeout = globalThis.setTimeout
    const originalClearTimeout = globalThis.clearTimeout
    const scheduled = []
    const cleared = []
    globalThis.setTimeout = (callback, delay) => {
        const token = { callback, delay }
        scheduled.push(token)
        return token
    }
    globalThis.clearTimeout = token => { cleared.push(token) }

    try {
        assert.equal(container.listenerCount('scroll'), 3)
        assert.equal(observer.observed.has(container), true)
        container.dispatchEvent(new Event('scroll'))
        container.dispatchEvent(new Event('scroll'))
        assert.equal(scrollEvents, 2)
        assert.deepEqual(scheduled.map(({ delay }) => delay), [450, 450])

        paginator.destroy()

        assert.equal(container.listenerCount('scroll'), 0)
        assert.equal(observer.observed.has(container), false)
        assert.deepEqual(observer.unobserved, [container])
        assert.deepEqual(cleared.filter(Boolean), scheduled)
        container.dispatchEvent(new Event('scroll'))
        assert.equal(scrollEvents, 2)

        paginator.open({ dir: 'ltr', sections: [] }, true)
        assert.equal(container.listenerCount('scroll'), 3)
        assert.equal(observer.observed.has(container), true)
        paginator.destroy()
    } finally {
        globalThis.setTimeout = originalSetTimeout
        globalThis.clearTimeout = originalClearTimeout
    }
})

test('destroy and reopen own one exact host input lifecycle', () => {
    const paginator = new Paginator()
    const book = { dir: 'ltr', sections: [] }
    const inputTypes = ['touchstart', 'touchmove', 'touchend', 'load', 'wheel']

    paginator.open(book)
    for (const type of inputTypes) assert.equal(paginator.listenerCount(type), 1, type)

    paginator.destroy()
    for (const type of inputTypes) assert.equal(paginator.listenerCount(type), 0, type)

    paginator.open(book)
    for (const type of inputTypes) assert.equal(paginator.listenerCount(type), 1, type)
    paginator.destroy()
})

test('destroy cancels the wheel cooldown owned by the outgoing lifecycle', async () => {
    const paginator = new Paginator()
    paginator.open({ dir: 'ltr', sections: [] })
    paginator.pageMetrics = () => { throw new Error('no metrics') }

    const originalSetTimeout = globalThis.setTimeout
    const originalClearTimeout = globalThis.clearTimeout
    const scheduled = []
    const cleared = []
    globalThis.setTimeout = (callback, delay) => {
        const token = { callback, delay }
        scheduled.push(token)
        return token
    }
    globalThis.clearTimeout = token => { cleared.push(token) }

    try {
        const wheel = new Event('wheel', { cancelable: true })
        Object.defineProperties(wheel, {
            deltaX: { value: -20 },
            deltaY: { value: 0 },
        })
        paginator.dispatchEvent(wheel)
        await new Promise(resolve => setImmediate(resolve))

        const cooldown = scheduled.find(({ delay }) => delay === 100)
        assert.ok(cooldown)
        paginator.destroy()
        assert.equal(cleared.includes(cooldown), true)
    } finally {
        globalThis.setTimeout = originalSetTimeout
        globalThis.clearTimeout = originalClearTimeout
        paginator.destroy()
    }
})

test('synchronous initial metrics failure releases physical-turn ownership', async () => {
    const paginator = new Paginator()
    paginator.sections = []

    let metricsCalls = 0
    paginator.pageMetrics = () => {
        metricsCalls += 1
        throw new Error('synchronous metrics failure')
    }

    assert.equal(await paginator.next(null, {
        ignoreIfPageTurnInFlight: true,
    }), false)
    assert.equal(paginator.navigationInFlight, false)

    assert.equal(await paginator.prev(null, {
        ignoreIfPageTurnInFlight: true,
    }), false)
    assert.equal(paginator.navigationInFlight, false)
    assert.equal(metricsCalls, 2)
})

test('direct navigation ownership refuses a physical turn without queueing it', async () => {
    const paginator = new Paginator()
    paginator.sections = []

    let resolveTarget
    const directNavigation = paginator.goTo(new Promise(resolve => {
        resolveTarget = resolve
    }), { relocationID: 'paginator-direct-owner' })
    await Promise.resolve()

    assert.equal(paginator.navigationInFlight, true)
    assert.deepEqual(await paginator.next(null, {
        ignoreIfPageTurnInFlight: true,
    }), {
        ignored: true,
        reason: 'rendererNavigationInFlight',
    })

    resolveTarget({ index: -1 })
    assert.equal(await directNavigation, false)
    assert.equal(paginator.navigationInFlight, false)
})

test('a newer direct navigation promptly supersedes an unresolved older target', async () => {
    const paginator = new Paginator()
    paginator.sections = []

    let resolveOlder
    const older = paginator.goTo(new Promise(resolve => {
        resolveOlder = resolve
    }), { relocationID: 'older' })
    await Promise.resolve()

    const newer = paginator.goTo({ index: -1 }, { relocationID: 'newer' })
    assert.deepEqual(await older, {
        ignored: true,
        reason: 'rendererNavigationSuperseded',
    })
    assert.equal(await newer, false)
    assert.equal(paginator.navigationInFlight, false)

    resolveOlder({ index: -1 })
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(paginator.navigationInFlight, false)
})

test('ignore-if-in-flight refuses without superseding the active direct navigation', async () => {
    const paginator = new Paginator()
    paginator.sections = []

    let resolveOwner
    const owner = paginator.goTo(new Promise(resolve => {
        resolveOwner = resolve
    }), { relocationID: 'owner' })
    await Promise.resolve()

    assert.deepEqual(await paginator.goTo({ index: -1 }, {
        relocationID: 'refused',
        ignoreIfNavigationInFlight: true,
    }), {
        ignored: true,
        reason: 'rendererNavigationInFlight',
    })

    resolveOwner({ index: -1 })
    assert.equal(await owner, false)
    assert.equal(paginator.navigationInFlight, false)
})

test('superseding a suspended section load releases the late section reference', async () => {
    const paginator = new Paginator()
    let resolveSection
    let loadCount = 0
    let unloadCount = 0
    paginator.sections = [{
        id: 'chapter.xhtml',
        linear: 'yes',
        load() {
            loadCount += 1
            return new Promise(resolve => { resolveSection = resolve })
        },
        unload() { unloadCount += 1 },
    }]

    const older = paginator.goTo({ index: 0 }, { relocationID: 'older-load' })
    while (!resolveSection) await new Promise(resolve => setImmediate(resolve))
    assert.equal(loadCount, 1)

    const newer = paginator.goTo({ index: -1 }, { relocationID: 'newer-load' })
    assert.deepEqual(await older, {
        ignored: true,
        reason: 'rendererNavigationSuperseded',
    })
    assert.equal(await newer, false)

    resolveSection('late-section-url')
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(unloadCount, 1)
    assert.equal(paginator.navigationInFlight, false)
})

test('destroying a paginator settles suspended direct navigation and releases its late section reference', async () => {
    const paginator = new Paginator()
    let resolveSection
    let unloadCount = 0
    paginator.sections = [{
        id: 'destroyed-chapter.xhtml',
        linear: 'yes',
        load() {
            return new Promise(resolve => { resolveSection = resolve })
        },
        unload() { unloadCount += 1 },
    }]

    const navigation = paginator.goTo({ index: 0 }, {
        relocationID: 'destroyed-navigation',
    })
    while (!resolveSection) await new Promise(resolve => setImmediate(resolve))

    paginator.destroy()
    assert.deepEqual(await navigation, {
        ignored: true,
        reason: 'rendererDestroyed',
    })
    assert.equal(paginator.navigationInFlight, false)

    resolveSection('late-destroyed-section-url')
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(unloadCount, 1)
})

test('destroying a paginator promptly settles physical navigation suspended in metrics', async () => {
    const paginator = new Paginator()
    paginator.sections = []

    let resolveMetrics
    paginator.pageMetrics = () => new Promise(resolve => {
        resolveMetrics = resolve
    })

    const navigation = paginator.next(null, {
        ignoreIfPageTurnInFlight: true,
    })
    while (!resolveMetrics) await new Promise(resolve => setImmediate(resolve))
    assert.equal(paginator.navigationInFlight, true)

    paginator.destroy()
    assert.deepEqual(await navigation, {
        ignored: true,
        reason: 'rendererDestroyed',
    })
    assert.equal(paginator.navigationInFlight, false)

    resolveMetrics({
        page: 1,
        pages: 3,
        start: 0,
        size: 100,
        viewSize: 100,
        end: 100,
    })
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(paginator.navigationInFlight, false)
})

test('destroying a paginator promptly settles physical navigation suspended in section loading', async () => {
    const paginator = new Paginator()
    let resolveSection
    let unloadCount = 0
    paginator.sections = [{
        id: 'physical-destroyed-chapter.xhtml',
        linear: 'yes',
        load() {
            return new Promise(resolve => { resolveSection = resolve })
        },
        unload() { unloadCount += 1 },
    }]
    paginator.pageMetrics = async () => ({
        page: 1,
        pages: 3,
        start: 0,
        size: 100,
        viewSize: 100,
        end: 100,
    })

    const navigation = paginator.next(null, {
        ignoreIfPageTurnInFlight: true,
    })
    while (!resolveSection) await new Promise(resolve => setImmediate(resolve))
    assert.equal(paginator.navigationInFlight, true)

    paginator.destroy()
    assert.deepEqual(await navigation, {
        ignored: true,
        reason: 'rendererDestroyed',
    })
    assert.equal(paginator.navigationInFlight, false)

    resolveSection('late-physical-section-url')
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(unloadCount, 1)
    assert.equal(paginator.navigationInFlight, false)
})

test('superseded direct navigation cannot resume mutation-capable scroll work', async () => {
    const paginator = new Paginator()
    paginator.open({
        dir: 'ltr',
        sections: [{
            id: 'chapter.xhtml',
            linear: 'yes',
            load: async () => null,
            unload() {},
        }],
    })

    let resolveOlderScroll
    let scrollCalls = 0
    const mutations = []
    paginator.scrollToAnchor = async (_anchor, _select, requireCurrent) => {
        scrollCalls += 1
        if (scrollCalls === 1) {
            await new Promise(resolve => { resolveOlderScroll = resolve })
            requireCurrent?.()
            mutations.push('older')
            return
        }
        requireCurrent?.()
        mutations.push('newer')
    }

    const older = paginator.goTo({ index: 0, anchor: 0 }, {
        relocationID: 'older-scroll',
    })
    while (!resolveOlderScroll) await new Promise(resolve => setImmediate(resolve))

    const newer = paginator.goTo({ index: 0, anchor: 0.5 }, {
        relocationID: 'newer-scroll',
    })
    assert.deepEqual(await older, {
        ignored: true,
        reason: 'rendererNavigationSuperseded',
    })
    assert.equal(await newer, true)
    assert.deepEqual(mutations, ['newer'])

    resolveOlderScroll()
    await new Promise(resolve => setImmediate(resolve))
    assert.deepEqual(mutations, ['newer'])
    paginator.destroy()
})

test('deferred past-content correction cannot observe a newer same-section navigation', async () => {
    const originalRequestAnimationFrame = globalThis.requestAnimationFrame
    const scheduledFrames = []
    globalThis.requestAnimationFrame = callback => {
        scheduledFrames.push(callback)
        return scheduledFrames.length
    }

    const paginator = new Paginator()
    paginator.open({
        dir: 'ltr',
        sections: [{
            id: 'chapter.xhtml',
            linear: 'yes',
            load: async () => null,
            unload() {},
        }],
    })
    paginator.scrollToAnchor = async (_anchor, _select, requireCurrent) => {
        requireCurrent?.()
    }
    let metricsCalls = 0
    paginator.pageMetrics = async () => {
        metricsCalls += 1
        return {
            index: 0,
            page: 1,
            pages: 3,
            start: 0,
            size: 100,
            viewSize: 100,
            end: 100,
            scrolled: false,
            vertical: false,
            rtl: false,
        }
    }

    try {
        assert.equal(await paginator.goTo({ index: 0, anchor: 0 }, {
            relocationID: 'older-anchor',
        }), true)
        assert.equal(scheduledFrames.length, 1)

        assert.equal(await paginator.goTo({ index: 0, anchor: 0.5 }, {
            relocationID: 'newer-anchor',
        }), true)
        assert.equal(scheduledFrames.length, 2)
        metricsCalls = 0

        const olderOuterFrame = scheduledFrames.shift()
        olderOuterFrame(performance.now())
        const olderInnerFrame = scheduledFrames.pop()
        olderInnerFrame(performance.now())
        await new Promise(resolve => setImmediate(resolve))
        assert.equal(metricsCalls, 0)
    } finally {
        globalThis.requestAnimationFrame = originalRequestAnimationFrame
        paginator.destroy()
    }
})

test('an admitted physical turn invalidates an older deferred past-content correction', async () => {
    const originalRequestAnimationFrame = globalThis.requestAnimationFrame
    const scheduledFrames = []
    globalThis.requestAnimationFrame = callback => {
        scheduledFrames.push(callback)
        return scheduledFrames.length
    }

    const paginator = new Paginator()
    paginator.open({
        dir: 'ltr',
        sections: [{
            id: 'chapter.xhtml',
            linear: 'yes',
            load: async () => null,
            unload() {},
        }],
    })
    paginator.scrollToAnchor = async (_anchor, _select, requireCurrent) => {
        requireCurrent?.()
    }
    let metricsCalls = 0
    paginator.pageMetrics = async () => {
        metricsCalls += 1
        return {
            index: 0,
            page: 1,
            pages: 3,
            start: 100,
            size: 100,
            viewSize: 100,
            end: 200,
            scrolled: false,
            vertical: false,
            rtl: false,
        }
    }

    try {
        assert.equal(await paginator.goTo({ index: 0, anchor: 0 }, {
            relocationID: 'anchor-before-turn',
        }), true)
        assert.equal(scheduledFrames.length, 1)

        assert.equal(await paginator.next(), false)
        metricsCalls = 0

        scheduledFrames.shift()(performance.now())
        scheduledFrames.shift()(performance.now())
        await new Promise(resolve => setImmediate(resolve))
        assert.equal(metricsCalls, 0)
    } finally {
        globalThis.requestAnimationFrame = originalRequestAnimationFrame
        paginator.destroy()
    }
})
