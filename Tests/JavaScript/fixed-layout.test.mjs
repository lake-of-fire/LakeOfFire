import assert from 'node:assert/strict'
import test from 'node:test'

class FakeElement extends EventTarget {
    constructor() {
        super()
        this.style = {}
        this.dataset = {}
        this.children = []
        this.parentElement = null
    }
    append(child) {
        child.parentElement = this
        this.children.push(child)
    }
    remove() {
        const parent = this.parentElement
        if (!parent) return
        parent.children = parent.children.filter(child => child !== this)
        this.parentElement = null
    }
    setAttribute() {}
    getBoundingClientRect() {
        return globalThis.__fixedLayoutBounds ?? { width: 800, height: 1000 }
    }
}

class FakeShadowRoot extends FakeElement {
    replaceChildren(...children) {
        this.children = children
        for (const child of children) child.parentElement = this
    }
    querySelectorAll(selector) {
        if (selector !== 'iframe') return []
        return this.children.flatMap(element => element.children.filter(child => child instanceof FakeIFrame))
    }
}

class FakeIFrame extends FakeElement {
    constructor() {
        super()
        this.contentDocument = {
            documentElement: { nodeName: 'html' },
            querySelector: selector => {
                if (selector !== 'meta[name="viewport"]') return null
                const content = globalThis.__fixedLayoutViewportBySource?.get?.(this._src)
                return content == null ? null : {
                    getAttribute: name => name === 'content' ? content : null,
                }
            },
        }
    }
    set src(value) {
        this._src = value
        const configuredDocument = globalThis.__fixedLayoutDocumentBySource?.get?.(value)
        if (configuredDocument) this.contentDocument = configuredDocument
        globalThis.__fixedLayoutOnFrameSource?.(value)
        if (globalThis.__fixedLayoutTriggerResizeDuringFrameLoad === true) {
            globalThis.__fixedLayoutResizeObserverCallback?.()
            globalThis.__fixedLayoutOnResizeDuringFrameLoad?.()
        }
        const behavior = globalThis.__fixedLayoutFrameLoadBehavior?.get?.(value) ?? 'load'
        if (behavior === 'pending') return
        if (behavior === 'missing-document') this.contentDocument = null
        queueMicrotask(() => this.dispatchEvent(new Event(behavior === 'error' ? 'error' : 'load')))
    }
    get src() { return this._src }
}

globalThis.HTMLElement = class extends FakeElement {
    attachShadow() { return new FakeShadowRoot() }
}
globalThis.ResizeObserver = class {
    constructor(callback) { globalThis.__fixedLayoutResizeObserverCallback = callback }
    observe() {}
    unobserve() {}
}
globalThis.CSSStyleSheet = class { replaceSync() {} }
globalThis.document = {
    createElement(name) { return name === 'iframe' ? new FakeIFrame() : new FakeElement() },
}
globalThis.customElements = { define() {} }

const { FixedLayout } = await import('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/fixed-layout.js')

test('fixed layout reports the selected page when relocating within an existing spread', async () => {
    const sections = [
        { linear: 'yes', load: async () => 'page-0' },
        { linear: 'yes', load: async () => 'page-1' },
    ]
    const layout = new FixedLayout()
    const relocations = []
    layout.addEventListener('relocate', event => relocations.push(event.detail))
    layout.open({
        dir: 'ltr',
        rendition: { viewport: { width: 1000, height: 1000 } },
        sections,
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    assert.equal(layout.index, 0)
    assert.equal(relocations.length, 1)

    assert.equal(await layout.goTo({ index: 1 }), true)

    assert.equal(layout.index, 1)
    assert.equal(layout.currentIndex, 1)
    assert.equal(layout.getContents().find(content => content.index === 1)?.index, 1)
    assert.equal(layout.getContents().find(content => content.index === 0)?.element.style.display, 'none')
    assert.equal(layout.getContents().find(content => content.index === 1)?.element.style.display, 'block')
    assert.equal(relocations.at(-1)?.index, 1)
    assert.equal(relocations.length, 2)

    assert.equal(await layout.goTo({ index: 1 }), false)
    assert.equal(relocations.length, 2)
})

test('fixed layout exposes the requested document identity during child load callbacks', async () => {
    const sections = [
        { linear: 'yes', load: async () => 'page-0' },
        { linear: 'yes', load: async () => 'page-1' },
        { linear: 'yes', load: async () => 'page-2' },
        { linear: 'yes', load: async () => 'page-3' },
    ]
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: { viewport: { width: 1000, height: 1000 } },
        sections,
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    const observations = []
    layout.addEventListener('load', event => {
        if (event.detail.index >= 2) {
            observations.push({
                loadedIndex: event.detail.index,
                currentIndex: layout.currentIndex,
            })
        }
    })

    assert.equal(await layout.goTo({ index: 3 }), true)
    assert.deepEqual(observations, [
        { loadedIndex: 2, currentIndex: 3 },
        { loadedIndex: 3, currentIndex: 3 },
    ])
    assert.equal(layout.currentIndex, 3)
})

test('fixed layout publishes exact document commit and unload ownership', async () => {
    const sections = [
        { linear: 'yes', load: async () => 'lifecycle-page-0' },
        { linear: 'yes', load: async () => 'lifecycle-page-1' },
    ]
    const layout = new FixedLayout()
    const events = []
    for (const type of ['load', 'document-committed', 'document-unload']) {
        layout.addEventListener(type, event => {
            events.push({
                type,
                index: event.detail.index,
                committed: event.detail.committed,
                reason: event.detail.reason,
            })
        })
    }
    layout.open({
        dir: 'ltr',
        rendition: { spread: 'none', viewport: { width: 1000, height: 1000 } },
        sections,
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    assert.equal(await layout.goTo({ index: 1 }), true)
    layout.destroy()

    assert.deepEqual(events, [
        { type: 'load', index: 0, committed: undefined, reason: undefined },
        { type: 'document-committed', index: 0, committed: undefined, reason: undefined },
        { type: 'document-unload', index: 0, committed: true, reason: 'fixed-layout.spread.replaced' },
        { type: 'load', index: 1, committed: undefined, reason: undefined },
        { type: 'document-committed', index: 1, committed: undefined, reason: undefined },
        { type: 'document-unload', index: 1, committed: true, reason: 'fixed-layout.destroy' },
    ])
})

test('fixed layout does not publish a failed staged document', async () => {
    globalThis.__fixedLayoutFrameLoadBehavior = new Map([
        ['failed-lifecycle-page', 'error'],
    ])
    const layout = new FixedLayout()
    const events = []
    for (const type of ['load', 'document-committed', 'document-unload']) {
        layout.addEventListener(type, event => {
            events.push([type, event.detail.index])
        })
    }
    layout.open({
        dir: 'ltr',
        rendition: { spread: 'none', viewport: { width: 1000, height: 1000 } },
        sections: [
            { linear: 'yes', load: async () => 'stable-lifecycle-page' },
            { linear: 'yes', load: async () => 'failed-lifecycle-page' },
        ],
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    assert.equal(await layout.goTo({ index: 1 }), false)
    assert.deepEqual(events, [
        ['load', 0],
        ['document-committed', 0],
    ])
    assert.equal(layout.currentIndex, 0)
    globalThis.__fixedLayoutFrameLoadBehavior = new Map()
})

test('fixed layout returns false without relocating at terminal edges', async () => {
    const sections = [{ linear: 'yes', load: async () => 'page-0' }]
    const layout = new FixedLayout()
    const relocations = []
    layout.addEventListener('relocate', event => relocations.push(event.detail))
    layout.open({
        dir: 'ltr',
        rendition: { spread: 'none', viewport: { width: 1000, height: 1000 } },
        sections,
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    assert.equal(await layout.next(), false)
    assert.equal(await layout.prev(), false)
    assert.deepEqual(relocations.map(event => event.index), [0])
})

for (const {
    direction,
    expectedNextIndex,
} of [
    { direction: 'ltr', expectedNextIndex: 1 },
    { direction: 'rtl', expectedNextIndex: 1 },
]) {
    test(`fixed layout ${direction} portrait navigation reports only real side changes`, async () => {
        const sections = [
            { linear: 'yes', load: async () => 'page-0' },
            { linear: 'yes', load: async () => 'page-1' },
        ]
        const layout = new FixedLayout()
        const relocations = []
        layout.addEventListener('relocate', event => relocations.push(event.detail))
        layout.open({
            dir: direction,
            rendition: { viewport: { width: 1000, height: 1000 } },
            sections,
        })

        assert.equal(await layout.goTo({ index: 0 }), true)
        assert.equal(await layout.next(), true)
        assert.equal(layout.index, expectedNextIndex)
        assert.equal(await layout.next(), false)
        assert.equal(await layout.prev(), true)
        assert.equal(layout.index, 0)
        assert.equal(await layout.prev(), false)
        assert.deepEqual(relocations.map(event => event.index), [0, 1, 0])
    })
}

test('fixed layout removes synthetic empty spreads at the real book edge', async () => {
    const sections = [
        { linear: 'yes', pageSpread: 'center', load: async () => 'page-0' },
    ]
    const layout = new FixedLayout()
    const relocations = []
    layout.addEventListener('relocate', event => relocations.push(event.detail))
    layout.open({
        dir: 'ltr',
        rendition: { viewport: { width: 1000, height: 1000 } },
        sections,
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    assert.equal(await layout.prev(), false)
    assert.equal(await layout.next(), false)
    assert.equal(layout.currentIndex, 0)
    assert.deepEqual(relocations.map(event => event.index), [0])
})

for (const {
    direction,
    trailingSide,
} of [
    { direction: 'ltr', trailingSide: 'right' },
    { direction: 'rtl', trailingSide: 'left' },
]) {
    test(`fixed layout ${direction} enters the real side of a one-sided spread`, async () => {
        const sections = [
            { linear: 'yes', pageSpread: 'center', load: async () => 'page-0' },
            { linear: 'yes', pageSpread: trailingSide, load: async () => 'page-1' },
        ]
        const layout = new FixedLayout()
        const relocations = []
        layout.addEventListener('relocate', event => relocations.push(event.detail))
        layout.open({
            dir: direction,
            rendition: { viewport: { width: 1000, height: 1000 } },
            sections,
        })

        assert.equal(await layout.goTo({ index: 0 }), true)
        assert.equal(await layout.next(), true)
        assert.equal(layout.currentIndex, 1)
        const destination = layout.getContents().find(content => content.index === 1)
        assert.equal(destination?.element.style.display, 'block')
        assert.equal(await layout.next(), false)
        assert.equal(await layout.prev(), true)
        assert.equal(layout.currentIndex, 0)
        assert.equal(await layout.prev(), false)
        assert.deepEqual(relocations.map(event => event.index), [0, 1, 0])
    })
}



test('fixed layout returns false for malformed, rejected, out-of-range, and unmapped targets', async () => {
    const sections = [
        { linear: 'yes', load: async () => 'page-0' },
        { linear: 'no', load: async () => 'non-linear' },
    ]
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: { viewport: { width: 1000, height: 1000 } },
        sections,
    })

    assert.equal(await layout.goTo(null), false)
    assert.equal(await layout.goTo(Promise.reject(new Error('bad target'))), false)
    assert.equal(await layout.goTo({ index: 0.5 }), false)
    assert.equal(await layout.goTo({ index: -1 }), false)
    assert.equal(await layout.goTo({ index: 2 }), false)
    assert.equal(await layout.goTo({ index: 1 }), false)
    assert.equal(await layout.goToSpread(Number.NaN, 'center'), false)
    assert.equal(await layout.goToSpread(0.5, 'center'), false)
})


test('fixed layout preserves spread-none explicit navigation to non-linear sections', async () => {
    const sections = [
        { linear: 'yes', load: async () => 'page-0' },
        { linear: 'no', load: async () => 'auxiliary-page' },
    ]
    const layout = new FixedLayout()
    const relocations = []
    layout.addEventListener('relocate', event => relocations.push(event.detail))
    layout.open({
        dir: 'ltr',
        rendition: { spread: 'none', viewport: { width: 1000, height: 1000 } },
        sections,
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    assert.equal(await layout.goTo({ index: 1 }), true)
    assert.equal(layout.currentIndex, 1)
    assert.deepEqual(relocations.map(event => event.index), [0, 1])
})

for (const direction of ['ltr', 'rtl']) {
    test(`fixed layout ${direction} physical navigation skips spread-none non-linear sections`, async () => {
        const nonLinearLoads = []
        const sections = [
            { linear: 'yes', load: async () => 'page-0' },
            {
                linear: 'no',
                load: async () => {
                    nonLinearLoads.push(1)
                    return 'auxiliary-page-1'
                },
            },
            {
                linear: 'no',
                load: async () => {
                    nonLinearLoads.push(2)
                    return 'auxiliary-page-2'
                },
            },
            { linear: 'yes', load: async () => 'page-3' },
        ]
        const layout = new FixedLayout()
        const relocations = []
        layout.addEventListener('relocate', event => {
            relocations.push(event.detail.index)
        })
        layout.open({
            dir: direction,
            rendition: { spread: 'none', viewport: { width: 1000, height: 1000 } },
            sections,
        })

        assert.equal(await layout.goTo({ index: 0 }), true)
        assert.equal(await layout.next(), true)
        assert.equal(layout.currentIndex, 3)
        assert.equal(await layout.next(), false)
        assert.deepEqual(nonLinearLoads, [])

        assert.equal(await layout.prev(), true)
        assert.equal(layout.currentIndex, 0)
        assert.equal(await layout.prev(), false)
        assert.deepEqual(nonLinearLoads, [])

        assert.equal(await layout.goTo({ index: 1 }), true)
        assert.equal(layout.currentIndex, 1)
        assert.equal(await layout.next(), true)
        assert.equal(layout.currentIndex, 3)

        assert.equal(await layout.goTo({ index: 2 }), true)
        assert.equal(layout.currentIndex, 2)
        assert.equal(await layout.prev(), true)
        assert.equal(layout.currentIndex, 0)

        assert.deepEqual(nonLinearLoads, [1, 2])
        assert.deepEqual(relocations, [0, 3, 0, 1, 3, 2, 0])
        layout.destroy()
    })
}

test('fixed layout treats a missing section source as a proved pre-mutation no-op', async () => {
    const sections = [
        { linear: 'yes', pageSpread: 'center', load: async () => 'page-0' },
        { linear: 'yes', pageSpread: 'center', load: async () => null },
    ]
    const layout = new FixedLayout()
    const relocations = []
    layout.addEventListener('relocate', event => relocations.push(event.detail))
    layout.open({
        dir: 'ltr',
        rendition: { viewport: { width: 1000, height: 1000 } },
        sections,
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    assert.equal(await layout.next(), false)
    assert.equal(layout.currentIndex, 0)
    assert.equal(layout.getContents().find(content => content.index === 0)?.element.style.display, 'block')
    assert.deepEqual(relocations.map(event => event.index), [0])
})

test('fixed layout direct spread navigation rejects a missing or mismatched side', async () => {
    const sections = [
        { linear: 'yes', pageSpread: 'center', load: async () => 'page-0' },
        { linear: 'yes', pageSpread: 'right', load: async () => 'page-1' },
    ]
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: { viewport: { width: 1000, height: 1000 } },
        sections,
    })

    assert.equal(await layout.goToSpread(0, 'left'), false)
    assert.equal(await layout.goToSpread(1, 'left'), false)
    assert.equal(await layout.goToSpread(1, 'right'), true)
    assert.equal(layout.currentIndex, 1)
})

test('fixed layout preserves visible and logical identity when destination loading fails before mutation', async () => {
    let successfulLoadUnloadCount = 0
    const sections = [
        { linear: 'yes', pageSpread: 'center', load: async () => 'page-0' },
        {
            linear: 'yes',
            pageSpread: 'left',
            load: async () => 'page-1',
            unload: () => { successfulLoadUnloadCount += 1 },
        },
        {
            linear: 'yes',
            pageSpread: 'right',
            load: async () => { throw new Error('load failed') },
        },
    ]
    const layout = new FixedLayout()
    const relocations = []
    layout.addEventListener('relocate', event => relocations.push(event.detail))
    layout.open({
        dir: 'ltr',
        rendition: { viewport: { width: 1000, height: 1000 } },
        sections,
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    assert.equal(await layout.next(), false)
    assert.equal(layout.currentIndex, 0)
    assert.equal(layout.getContents().find(content => content.index === 0)?.element.style.display, 'block')
    assert.deepEqual(relocations.map(event => event.index), [0])
    assert.equal(successfulLoadUnloadCount, 1)
})

test('fixed layout keeps a pre-mutation load failure authoritative when cleanup throws', async () => {
    const sections = [
        { linear: 'yes', pageSpread: 'center', load: async () => 'page-0' },
        {
            linear: 'yes',
            pageSpread: 'left',
            load: async () => 'page-1',
            unload: () => { throw new Error('cleanup failed') },
        },
        {
            linear: 'yes',
            pageSpread: 'right',
            load: async () => { throw new Error('load failed') },
        },
    ]
    const layout = new FixedLayout()
    const relocations = []
    layout.addEventListener('relocate', event => relocations.push(event.detail))
    layout.open({
        dir: 'ltr',
        rendition: { viewport: { width: 1000, height: 1000 } },
        sections,
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    assert.equal(await layout.next(), false)
    assert.equal(layout.currentIndex, 0)
    assert.equal(layout.getContents().find(content => content.index === 0)?.element.style.display, 'block')
    assert.deepEqual(relocations.map(event => event.index), [0])
})

test('fixed layout treats staged frame construction failure as authoritative no-move', async () => {
    globalThis.__fixedLayoutFrameLoadBehavior = new Map([
        ['missing-document', 'missing-document'],
    ])
    let activeUnloadCount = 0
    let failedDestinationUnloadCount = 0
    try {
        const sections = [
            {
                linear: 'yes',
                pageSpread: 'center',
                load: async () => 'page-0',
                unload: () => { activeUnloadCount += 1 },
            },
            {
                linear: 'yes',
                pageSpread: 'center',
                load: async () => 'missing-document',
                unload: () => { failedDestinationUnloadCount += 1 },
            },
        ]
        const layout = new FixedLayout()
        const relocations = []
        layout.addEventListener('relocate', event => relocations.push(event.detail))
        layout.open({
            dir: 'ltr',
            rendition: { viewport: { width: 1000, height: 1000 } },
            sections,
        })

        assert.equal(await layout.goTo({ index: 0 }), true)
        assert.equal(await layout.next(), false)
        assert.equal(layout.currentIndex, 0)
        assert.deepEqual(layout.getContents().map(content => content.index), [0])
        assert.equal(layout.getContents()[0]?.element.style.display, 'block')
        assert.deepEqual(relocations.map(event => event.index), [0])
        assert.equal(activeUnloadCount, 0)
        assert.equal(failedDestinationUnloadCount, 1)
    } finally {
        globalThis.__fixedLayoutFrameLoadBehavior = null
    }
})

test('fixed layout keeps resize observations scoped to the active spread while staging', async () => {
    const sections = [
        { linear: 'yes', pageSpread: 'center', load: async () => 'page-0' },
        { linear: 'yes', pageSpread: 'left', load: async () => 'page-1' },
        { linear: 'yes', pageSpread: 'right', load: async () => 'page-2' },
    ]
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: { viewport: { width: 1000, height: 1000 } },
        sections,
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    const stagingObservations = []
    globalThis.__fixedLayoutOnResizeDuringFrameLoad = () => {
        stagingObservations.push({
            currentIndex: layout.currentIndex,
            contentIndexes: layout.getContents().map(content => content.index),
        })
    }
    globalThis.__fixedLayoutTriggerResizeDuringFrameLoad = true
    try {
        assert.equal(await layout.next(), true)
        assert.deepEqual(stagingObservations, [
            { currentIndex: 0, contentIndexes: [0] },
            { currentIndex: 0, contentIndexes: [0] },
        ])
        assert.equal(layout.currentIndex, 1)
        assert.equal(layout.getContents().length, 2)
    } finally {
        globalThis.__fixedLayoutTriggerResizeDuringFrameLoad = false
        globalThis.__fixedLayoutOnResizeDuringFrameLoad = null
    }
})

test('fixed layout leaves the active spread intact when a later staged frame fails', async () => {
    globalThis.__fixedLayoutFrameLoadBehavior = new Map([
        ['frame-error-second', 'error'],
    ])
    const failedDestinationUnloadCounts = [0, 0]
    try {
        const sections = [
            { linear: 'yes', load: async () => 'page-0' },
            { linear: 'yes', load: async () => 'page-1' },
            {
                linear: 'yes',
                load: async () => 'page-2',
                unload: () => { failedDestinationUnloadCounts[0] += 1 },
            },
            {
                linear: 'yes',
                load: async () => 'frame-error-second',
                unload: () => { failedDestinationUnloadCounts[1] += 1 },
            },
        ]
        const layout = new FixedLayout()
        const relocations = []
        layout.addEventListener('relocate', event => relocations.push(event.detail))
        layout.open({
            dir: 'ltr',
            rendition: { viewport: { width: 1000, height: 1000 } },
            sections,
        })

        assert.equal(await layout.goTo({ index: 0 }), true)
        const publishedDestinationIndexes = []
        layout.addEventListener('load', event => {
            if (event.detail.index >= 2) publishedDestinationIndexes.push(event.detail.index)
        })

        assert.equal(await layout.goTo({ index: 3 }), false)
        assert.deepEqual(publishedDestinationIndexes, [])
        assert.equal(layout.currentIndex, 0)
        assert.deepEqual(layout.getContents().map(content => content.index), [0, 1])
        assert.deepEqual(relocations.map(event => event.index), [0])
        assert.deepEqual(failedDestinationUnloadCounts, [1, 1])
    } finally {
        globalThis.__fixedLayoutFrameLoadBehavior = null
    }
})

test('fixed layout converts staged iframe error events into truthful no-movement', async () => {
    globalThis.__fixedLayoutFrameLoadBehavior = new Map([
        ['frame-error', 'error'],
    ])
    try {
        const sections = [
            { linear: 'yes', pageSpread: 'center', load: async () => 'page-0' },
            { linear: 'yes', pageSpread: 'center', load: async () => 'frame-error' },
        ]
        const layout = new FixedLayout()
        layout.open({
            dir: 'ltr',
            rendition: { viewport: { width: 1000, height: 1000 } },
            sections,
        })

        assert.equal(await layout.goTo({ index: 0 }), true)
        assert.equal(await layout.next(), false)
        assert.equal(layout.currentIndex, 0)
        assert.deepEqual(layout.getContents().map(content => content.index), [0])
    } finally {
        globalThis.__fixedLayoutFrameLoadBehavior = null
    }
})


test('fixed layout ignores invalid document viewport metadata in favor of a valid rendition viewport', async () => {
    globalThis.__fixedLayoutBounds = { width: 600, height: 900 }
    globalThis.__fixedLayoutViewportBySource = new Map([
        ['page-invalid-meta', 'width=device-width,height=900'],
    ])
    try {
        const layout = new FixedLayout()
        layout.open({
            dir: 'ltr',
            rendition: {
                spread: 'none',
                viewport: 'width=1200,height=900',
            },
            sections: [
                { linear: 'yes', load: async () => 'page-invalid-meta' },
            ],
        })

        assert.equal(await layout.goTo({ index: 0 }), true)
        const content = layout.getContents()[0]
        assert.equal(content?.iframe.style.transform, 'scale(0.5)')
        assert.equal(content?.element.style.width, '600px')
        assert.equal(content?.element.style.height, '450px')
    } finally {
        globalThis.__fixedLayoutBounds = null
        globalThis.__fixedLayoutViewportBySource = null
    }
})

test('fixed layout parses a string rendition viewport when the document has no viewport metadata', async () => {
    globalThis.__fixedLayoutBounds = { width: 600, height: 900 }
    try {
        const layout = new FixedLayout()
        layout.open({
            dir: 'ltr',
            rendition: {
                spread: 'none',
                viewport: 'width=1200,height=900',
            },
            sections: [
                { linear: 'yes', load: async () => 'page-0' },
            ],
        })

        assert.equal(await layout.goTo({ index: 0 }), true)
        const content = layout.getContents()[0]
        assert.equal(content?.iframe.style.transform, 'scale(0.5)')
        assert.equal(content?.element.style.width, '600px')
        assert.equal(content?.element.style.height, '450px')
    } finally {
        globalThis.__fixedLayoutBounds = null
    }
})

test('fixed layout releases replaced and destroyed section load references', async () => {
    const unloadCounts = [0, 0]
    const sections = [
        {
            linear: 'yes',
            pageSpread: 'center',
            load: async () => 'page-0',
            unload: () => { unloadCounts[0] += 1 },
        },
        {
            linear: 'yes',
            pageSpread: 'center',
            load: async () => 'page-1',
            unload: () => { unloadCounts[1] += 1 },
        },
    ]
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: { viewport: { width: 1000, height: 1000 } },
        sections,
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    assert.deepEqual(unloadCounts, [0, 0])

    assert.equal(await layout.next(), true)
    assert.deepEqual(unloadCounts, [1, 0])

    layout.destroy()
    assert.deepEqual(unloadCounts, [1, 1])

    layout.destroy()
    assert.deepEqual(unloadCounts, [1, 1])
})

test('fixed layout portrait side navigation recomputes scale for the selected page viewport', async () => {
    globalThis.__fixedLayoutBounds = { width: 600, height: 900 }
    globalThis.__fixedLayoutViewportBySource = new Map([
        ['page-0', 'width=600,height=900'],
        ['page-1', 'width=1200,height=900'],
    ])
    try {
        const sections = [
            { linear: 'yes', load: async () => 'page-0' },
            { linear: 'yes', load: async () => 'page-1' },
        ]
        const layout = new FixedLayout()
        layout.open({
            dir: 'ltr',
            rendition: { viewport: { width: 1000, height: 1000 } },
            sections,
        })

        assert.equal(await layout.goTo({ index: 0 }), true)
        const left = layout.getContents().find(content => content.index === 0)
        const right = layout.getContents().find(content => content.index === 1)
        assert.equal(left?.element.style.display, 'block')
        assert.equal(right?.element.style.display, 'none')
        assert.equal(left?.iframe.style.transform, 'scale(1)')
        assert.equal(right?.iframe.style.transform, 'scale(1)')

        assert.equal(await layout.next(), true)
        assert.equal(layout.currentIndex, 1)
        assert.equal(left?.element.style.display, 'none')
        assert.equal(right?.element.style.display, 'block')
        assert.equal(left?.iframe.style.transform, 'scale(0.5)')
        assert.equal(right?.iframe.style.transform, 'scale(0.5)')
        assert.equal(right?.element.style.width, '600px')
    } finally {
        globalThis.__fixedLayoutBounds = null
        globalThis.__fixedLayoutViewportBySource = null
    }
})

test('fixed layout landscape turns operate on complete spreads without false side movement', async () => {
    globalThis.__fixedLayoutBounds = { width: 1200, height: 800 }
    try {
        const sections = [
            { linear: 'yes', load: async () => 'page-0' },
            { linear: 'yes', load: async () => 'page-1' },
        ]
        const layout = new FixedLayout()
        const relocations = []
        layout.addEventListener('relocate', event => relocations.push(event.detail))
        layout.open({
            dir: 'ltr',
            rendition: { viewport: { width: 1000, height: 1000 } },
            sections,
        })

        assert.equal(await layout.goTo({ index: 0 }), true)
        assert.deepEqual(
            layout.getContents().map(content => content.element.style.display),
            ['block', 'block']
        )
        assert.equal(await layout.next(), false)
        assert.equal(await layout.prev(), false)
        assert.deepEqual(relocations.map(event => event.index), [0])
    } finally {
        globalThis.__fixedLayoutBounds = null
    }
})


test('fixed layout prevents an older delayed navigation from replacing a newer destination', async () => {
    let resolveDelayedSource
    const delayedSource = new Promise(resolve => { resolveDelayedSource = resolve })
    let resolveDelayedLoadStarted
    const delayedLoadStarted = new Promise(resolve => { resolveDelayedLoadStarted = resolve })
    let delayedUnloadCount = 0
    const sections = [
        { linear: 'yes', load: async () => 'page-0' },
        {
            linear: 'yes',
            load: async () => {
                resolveDelayedLoadStarted()
                return await delayedSource
            },
            unload: () => { delayedUnloadCount += 1 },
        },
        { linear: 'yes', load: async () => 'page-2' },
    ]
    const layout = new FixedLayout()
    const relocations = []
    const publishedIndexes = []
    layout.addEventListener('relocate', event => relocations.push(event.detail.index))
    layout.addEventListener('load', event => publishedIndexes.push(event.detail.index))
    layout.open({
        dir: 'ltr',
        rendition: {
            spread: 'none',
            viewport: { width: 1000, height: 1000 },
        },
        sections,
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    const olderNavigation = layout.goTo({ index: 1 })
    await delayedLoadStarted

    assert.equal(await layout.goTo({ index: 2 }), true)
    const olderResult = await olderNavigation
    assert.equal(olderResult?.ignored, true)
    assert.equal(olderResult?.superseded, true)
    assert.equal(olderResult?.reason, 'fixedLayoutNavigationSuperseded')
    assert.equal(layout.currentIndex, 2)
    assert.deepEqual(relocations, [0, 2])
    assert.deepEqual(publishedIndexes, [0, 2])

    resolveDelayedSource('page-1')
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(delayedUnloadCount, 1)
    assert.equal(layout.currentIndex, 2)
    assert.deepEqual(relocations, [0, 2])
})

test('fixed layout supersession settles a staged iframe that never loads', async () => {
    globalThis.__fixedLayoutFrameLoadBehavior = new Map([
        ['pending-frame', 'pending'],
    ])
    let supersededUnloadCount = 0
    try {
        const sections = [
            { linear: 'yes', load: async () => 'page-0' },
            {
                linear: 'yes',
                load: async () => 'pending-frame',
                unload: () => { supersededUnloadCount += 1 },
            },
            { linear: 'yes', load: async () => 'page-2' },
        ]
        const layout = new FixedLayout()
        const relocations = []
        layout.addEventListener('relocate', event => relocations.push(event.detail.index))
        layout.open({
            dir: 'ltr',
            rendition: {
                spread: 'none',
                viewport: { width: 1000, height: 1000 },
            },
            sections,
        })

        assert.equal(await layout.goTo({ index: 0 }), true)
        let resolveFrameStarted
        const frameStarted = new Promise(resolve => { resolveFrameStarted = resolve })
        globalThis.__fixedLayoutOnFrameSource = source => {
            if (source === 'pending-frame') resolveFrameStarted()
        }
        const stagedNavigation = layout.goTo({ index: 1 })
        await frameStarted

        assert.equal(await layout.goTo({ index: 2 }), true)
        const stagedResult = await stagedNavigation
        assert.equal(stagedResult?.ignored, true)
        assert.equal(stagedResult?.reason, 'fixedLayoutNavigationSuperseded')
        assert.equal(supersededUnloadCount, 1)
        assert.equal(layout.currentIndex, 2)
        assert.deepEqual(relocations, [0, 2])
    } finally {
        globalThis.__fixedLayoutFrameLoadBehavior = null
        globalThis.__fixedLayoutOnFrameSource = null
    }
})

test('fixed layout destruction settles pending staged navigation and releases both owners', async () => {
    globalThis.__fixedLayoutFrameLoadBehavior = new Map([
        ['pending-frame-destroy', 'pending'],
    ])
    const unloadCounts = [0, 0]
    try {
        const sections = [
            {
                linear: 'yes',
                load: async () => 'page-0',
                unload: () => { unloadCounts[0] += 1 },
            },
            {
                linear: 'yes',
                load: async () => 'pending-frame-destroy',
                unload: () => { unloadCounts[1] += 1 },
            },
        ]
        const layout = new FixedLayout()
        layout.open({
            dir: 'ltr',
            rendition: {
                spread: 'none',
                viewport: { width: 1000, height: 1000 },
            },
            sections,
        })

        assert.equal(await layout.goTo({ index: 0 }), true)
        let resolveFrameStarted
        const frameStarted = new Promise(resolve => { resolveFrameStarted = resolve })
        globalThis.__fixedLayoutOnFrameSource = source => {
            if (source === 'pending-frame-destroy') resolveFrameStarted()
        }
        const pendingNavigation = layout.next()
        await frameStarted
        layout.destroy()

        const result = await pendingNavigation
        assert.equal(result?.ignored, true)
        assert.equal(result?.superseded, true)
        assert.equal(result?.reason, 'fixedLayoutDestroyed')
        assert.deepEqual(unloadCounts, [1, 1])
        assert.deepEqual(layout.getContents(), [])
    } finally {
        globalThis.__fixedLayoutFrameLoadBehavior = null
        globalThis.__fixedLayoutOnFrameSource = null
    }
})

test('fixed layout shares one section resource across superseded duplicate destinations', async () => {
    let resolveDestinationSource
    const destinationSource = new Promise(resolve => { resolveDestinationSource = resolve })
    let resolveLoadStarted
    const loadStarted = new Promise(resolve => { resolveLoadStarted = resolve })
    let destinationLoadCount = 0
    let destinationUnloadCount = 0
    const sections = [
        { linear: 'yes', load: async () => 'page-0' },
        {
            linear: 'yes',
            load: async () => {
                destinationLoadCount += 1
                resolveLoadStarted()
                return await destinationSource
            },
            unload: () => { destinationUnloadCount += 1 },
        },
    ]
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: {
            spread: 'none',
            viewport: { width: 1000, height: 1000 },
        },
        sections,
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    const olderNavigation = layout.goTo({ index: 1 })
    await loadStarted
    const newerNavigation = layout.goTo({ index: 1 })

    resolveDestinationSource('shared-destination')
    const [olderResult, newerResult] = await Promise.all([
        olderNavigation,
        newerNavigation,
    ])

    assert.equal(olderResult?.ignored, true)
    assert.equal(olderResult?.reason, 'fixedLayoutNavigationSuperseded')
    assert.equal(newerResult, true)
    assert.equal(destinationLoadCount, 1)
    assert.equal(destinationUnloadCount, 0)
    assert.equal(layout.currentIndex, 1)

    layout.destroy()
    assert.equal(destinationUnloadCount, 1)
})

test('fixed layout does not publish an obsolete relocation after a load observer navigates again', async () => {
    const sections = [
        { linear: 'yes', pageSpread: 'center', load: async () => 'page-0' },
        { linear: 'yes', pageSpread: 'left', load: async () => 'page-1' },
        { linear: 'yes', pageSpread: 'right', load: async () => 'page-2' },
    ]
    const layout = new FixedLayout()
    const relocations = []
    layout.addEventListener('relocate', event => relocations.push(event.detail.index))
    layout.open({
        dir: 'ltr',
        rendition: { viewport: { width: 1000, height: 1000 } },
        sections,
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    let reentered = false
    layout.addEventListener('load', event => {
        if (event.detail.index !== 1 || reentered) return
        reentered = true
        void layout.next()
    })

    assert.equal(await layout.goTo({ index: 1 }), true)
    assert.equal(layout.currentIndex, 2)
    assert.deepEqual(relocations, [0, 2])
})

test('fixed layout stops publishing committed frame loads after synchronous teardown', async () => {
    const sections = [
        { linear: 'yes', pageSpread: 'center', load: async () => 'page-0' },
        { linear: 'yes', pageSpread: 'left', load: async () => 'page-1' },
        { linear: 'yes', pageSpread: 'right', load: async () => 'page-2' },
    ]
    const layout = new FixedLayout()
    const relocations = []
    layout.addEventListener('relocate', event => relocations.push(event.detail.index))
    layout.open({
        dir: 'ltr',
        rendition: { viewport: { width: 1000, height: 1000 } },
        sections,
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    const loadedIndexes = []
    layout.addEventListener('load', event => {
        loadedIndexes.push(event.detail.index)
        if (event.detail.index === 1) layout.destroy()
    })

    assert.equal(await layout.goTo({ index: 1 }), true)
    assert.deepEqual(loadedIndexes, [1])
    assert.deepEqual(relocations, [0])
    assert.deepEqual(layout.getContents(), [])
})

test('fixed layout refuses a physical turn without superseding direct navigation ownership', async () => {
    let resolveDestination
    let markDestinationStarted
    const destinationStarted = new Promise(resolve => {
        markDestinationStarted = resolve
    })
    const destinationSource = new Promise(resolve => {
        resolveDestination = resolve
    })
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: {
            spread: 'none',
            viewport: { width: 1000, height: 1000 },
        },
        sections: [
            { linear: 'yes', load: async () => 'page-0' },
            {
                linear: 'yes',
                load: async () => {
                    markDestinationStarted()
                    return await destinationSource
                },
            },
        ],
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    const directNavigation = layout.goTo({ index: 1 }, {
        relocationID: 'direct-relocation',
    })
    await destinationStarted
    assert.equal(layout.navigationInFlight, true)

    const refusedTurn = await layout.prev(undefined, {
        ignoreIfNavigationInFlight: true,
    })
    assert.equal(refusedTurn?.ignored, true)
    assert.equal(refusedTurn?.superseded, undefined)
    assert.equal(refusedTurn?.reason, 'rendererNavigationInFlight')
    assert.equal(layout.navigationInFlight, true)

    resolveDestination('page-1')
    assert.equal(await directNavigation, true)
    assert.equal(layout.navigationInFlight, false)
    assert.equal(layout.currentIndex, 1)
})

test('fixed layout publishes the exact direct relocation identifier', async () => {
    const layout = new FixedLayout()
    const relocations = []
    layout.addEventListener('relocate', event => relocations.push(event.detail))
    layout.open({
        dir: 'ltr',
        rendition: {
            spread: 'none',
            viewport: { width: 1000, height: 1000 },
        },
        sections: [
            { linear: 'yes', load: async () => 'page-0' },
            { linear: 'yes', load: async () => 'page-1' },
        ],
    })

    assert.equal(await layout.goTo({ index: 0 }, {
        relocationID: 'relocation-zero',
    }), true)
    assert.equal(await layout.goTo({ index: 1 }, {
        relocationID: 'relocation-one',
    }), true)

    assert.deepEqual(relocations.map(detail => ({
        index: detail.index,
        relocationID: detail.relocationID,
    })), [
        { index: 0, relocationID: 'relocation-zero' },
        { index: 1, relocationID: 'relocation-one' },
    ])
})

test('fixed layout preserves first viewport declarations and numeric XHTML prefixes', async () => {
    globalThis.__fixedLayoutViewportBySource = new Map([
        ['numeric-viewport', 'width = 1200pxjunk; height=800.5suffix width=700 height=600'],
    ])
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: { spread: 'none', viewport: { width: 900, height: 700 } },
        sections: [{ linear: 'yes', load: async () => 'numeric-viewport' }],
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    const content = layout.getContents()[0]
    assert.equal(content.iframe.style.width, '1200px')
    assert.equal(content.iframe.style.height, '800.5px')
    globalThis.__fixedLayoutViewportBySource = new Map()
})

test('fixed layout uses strict SVG intrinsic fallback after an unusable viewBox', async () => {
    const svgRoot = {
        nodeName: 'svg:svg',
        localName: 'svg',
        getAttribute: name => ({
            viewBox: '0 0 0 500',
            width: '640px',
            height: '480',
        })[name] ?? null,
    }
    globalThis.__fixedLayoutDocumentBySource = new Map([
        ['strict-svg', {
            documentElement: svgRoot,
            querySelector: () => null,
        }],
    ])
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: { spread: 'none', viewport: { width: 900, height: 700 } },
        sections: [{ linear: 'yes', load: async () => 'strict-svg' }],
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    const content = layout.getContents()[0]
    assert.equal(content.iframe.style.width, '640px')
    assert.equal(content.iframe.style.height, '480px')
    globalThis.__fixedLayoutDocumentBySource = new Map()
})

test('fixed layout rejects relative SVG dimensions in favor of publication viewport', async () => {
    globalThis.__fixedLayoutDocumentBySource = new Map([
        ['relative-svg', {
            documentElement: {
                nodeName: 'svg',
                getAttribute: name => ({
                    viewBox: 'malformed',
                    width: '80%',
                    height: '50vh',
                })[name] ?? null,
            },
            querySelector: () => null,
        }],
    ])
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: { spread: 'none', viewport: { width: 900, height: 700 } },
        sections: [{ linear: 'yes', load: async () => 'relative-svg' }],
    })

    assert.equal(await layout.goTo({ index: 0 }), true)
    const content = layout.getContents()[0]
    assert.equal(content.iframe.style.width, '900px')
    assert.equal(content.iframe.style.height, '700px')
    globalThis.__fixedLayoutDocumentBySource = new Map()
})

test('fixed layout publishes only navigation-causal relocation metadata', async () => {
    const layout = new FixedLayout()
    const relocations = []
    layout.addEventListener('relocate', event => relocations.push(event.detail))
    layout.open({
        dir: 'ltr',
        rendition: { spread: 'none', viewport: { width: 1000, height: 1000 } },
        sections: [
            { linear: 'yes', load: async () => 'causal-0' },
            { linear: 'yes', load: async () => 'causal-1' },
        ],
    })

    assert.equal(await layout.goTo({ index: 0 }, {
        pageTurnAttemptID: 'attempt-a',
        navigationIntent: {
            motionStartedAtMs: 123,
            explicitRelocateHistorySource: 'goToHref',
            explicitRelocateHistoryMutationID: 'mutation-a',
            explicitRelocateHistoryRequestGeneration: 7,
        },
    }), true)
    assert.equal(await layout.goTo({ index: 1 }), true)

    assert.equal(relocations[0].sectionIndex, 0)
    assert.equal(relocations[0].pageTurnAttemptID, 'attempt-a')
    assert.equal(relocations[0].motionStartedAtMs, 123)
    assert.equal(relocations[0].explicitRelocateHistorySource, 'goToHref')
    assert.equal(relocations[0].explicitRelocateHistoryMutationID, 'mutation-a')
    assert.equal(relocations[0].explicitRelocateHistoryRequestGeneration, 7)
    assert.equal(relocations[1].sectionIndex, 1)
    assert.equal(relocations[1].explicitRelocateHistoryMutationID, undefined)
})

test('fixed layout orders the visible portrait side first and keeps destruction terminal', async () => {
    let loads = 0
    const sections = [
        { linear: 'yes', load: async () => { loads += 1; return 'visible-0' } },
        { linear: 'yes', load: async () => { loads += 1; return 'visible-1' } },
    ]
    const layout = new FixedLayout()
    assert.equal(layout.open({
        dir: 'ltr',
        rendition: { viewport: { width: 1000, height: 1000 } },
        sections,
    }), true)

    assert.equal(await layout.goTo({ index: 0 }), true)
    assert.equal(await layout.goTo({ index: 1 }), true)
    const contents = layout.getContents()
    assert.equal(contents[0].index, 1)
    assert.equal(contents[0].isVisible, true)
    assert.equal(contents[1].index, 0)
    assert.equal(contents[1].isVisible, false)

    layout.destroy()
    assert.deepEqual(layout.getContents(), [])
    assert.equal(layout.open({
        dir: 'ltr',
        rendition: { spread: 'none', viewport: { width: 1000, height: 1000 } },
        sections,
    }), false)
    const receipt = await layout.goTo({ index: 0 })
    assert.equal(receipt?.ignored, true)
    assert.equal(receipt?.reason, 'fixedLayoutDestroyed')
    assert.equal(loads, 2)
})
