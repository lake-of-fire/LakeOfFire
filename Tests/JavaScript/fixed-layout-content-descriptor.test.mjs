import assert from 'node:assert/strict'
import test from 'node:test'

const pendingIframes = []

class FakeShadowRoot {
    adoptedStyleSheets = []
    children = []

    append(element) {
        element.parent = this
        this.children.push(element)
    }

    replaceChildren() {
        for (const child of this.children) child.parent = null
        this.children = []
    }
}

globalThis.HTMLElement = class {
    events = []

    attachShadow() {
        this.shadowRootForTesting = new FakeShadowRoot()
        return this.shadowRootForTesting
    }

    dispatchEvent(event) {
        this.events.push(event)
    }

    getBoundingClientRect() {
        return this.boundsForTesting ?? { width: 1_200, height: 800 }
    }
}
globalThis.CSSStyleSheet = class {
    replaceSync() {}
}
globalThis.CustomEvent = class {
    constructor(type, options) {
        this.type = type
        this.detail = options?.detail
    }
}
globalThis.ResizeObserver = class {
    observe() {}
    unobserve() {}
}
globalThis.customElements = { define() {} }
globalThis.document = {
    createElement(tagName) {
        if (tagName === 'div') {
            return {
                parent: null,
                style: {},
                append(iframe) {
                    this.iframe = iframe
                },
                remove() {
                    if (!this.parent) return
                    this.parent.children = this.parent.children.filter(child => child !== this)
                    this.parent = null
                },
            }
        }
        if (tagName === 'iframe') {
            const listeners = new Map()
            return {
                contentDocument: null,
                style: {},
                addEventListener(name, listener) {
                    listeners.set(name, listener)
                },
                removeEventListener(name) {
                    listeners.delete(name)
                },
                setAttribute() {},
                set src(value) {
                    this.source = value
                    pendingIframes.push(this)
                },
                finishLoading(document) {
                    this.contentDocument = document
                    listeners.get('load')?.()
                },
            }
        }
        throw new Error(`Unexpected element ${tagName}`)
    },
}

const { FixedLayout, fixedLayoutContentDescriptor } = await import(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/fixed-layout.js'
)

const fixedLayoutDocument = title => ({
    title,
    documentElement: { nodeName: 'html' },
    querySelector: () => null,
})

const nextPendingIframe = async source => {
    for (let attempt = 0; attempt < 100; attempt += 1) {
        const index = pendingIframes.findIndex(iframe => iframe.source === source)
        if (index >= 0) return pendingIframes.splice(index, 1)[0]
        await new Promise(resolve => setImmediate(resolve))
    }
    throw new Error(`Timed out waiting for ${source}`)
}

test('preserves fixed-layout frame ownership and identity', () => {
    const doc = { title: 'page' }
    const iframe = { contentDocument: doc }
    const element = { id: 'frame-wrapper' }
    const descriptor = fixedLayoutContentDescriptor({
        index: 4,
        generation: 7,
        iframe,
        element,
    })

    assert.deepEqual(descriptor, {
        index: 4,
        generation: 7,
        doc,
        iframe,
        element,
    })
})

test('reads the live document from the owned iframe', () => {
    const firstDocument = { title: 'first' }
    const secondDocument = { title: 'second' }
    const iframe = { contentDocument: firstDocument }
    const frame = { index: 2, generation: 3, iframe, element: {} }

    assert.equal(fixedLayoutContentDescriptor(frame).doc, firstDocument)
    iframe.contentDocument = secondDocument
    assert.equal(fixedLayoutContentDescriptor(frame).doc, secondDocument)
})

test('rejects records without an owned iframe', () => {
    assert.equal(fixedLayoutContentDescriptor(null), null)
    assert.equal(fixedLayoutContentDescriptor({ element: {} }), null)
})

test('rejects an older section load that resumes after replacement navigation', async () => {
    let releaseOriginalSection
    let markOriginalSectionLoadStarted
    const originalSectionSource = new Promise(resolve => {
        releaseOriginalSection = resolve
    })
    const originalSectionLoadStarted = new Promise(resolve => {
        markOriginalSectionLoadStarted = resolve
    })
    const sections = [
        {
            load: () => {
                markOriginalSectionLoadStarted()
                return originalSectionSource
            },
        },
        {
            load: async () => 'replacement.xhtml',
        },
    ]
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: {
            spread: 'none',
            viewport: { width: 600, height: 800 },
        },
        sections,
    })

    const originalNavigation = layout.goTo({ index: 0 })
    await originalSectionLoadStarted
    const replacementNavigation = layout.goTo({ index: 1 })
    const replacementIframe = await nextPendingIframe('replacement.xhtml')
    replacementIframe.finishLoading(fixedLayoutDocument('replacement'))
    await replacementNavigation

    releaseOriginalSection('original.xhtml')
    await originalNavigation
    assert.equal(
        pendingIframes.some(iframe => iframe.source === 'original.xhtml'),
        false,
    )

    assert.deepEqual(
        layout.getContents().map(content => ({
            index: content.index,
            title: content.doc.title,
        })),
        [{ index: 1, title: 'replacement' }],
    )
})

test('settles a detached frame load when replacement navigation takes ownership', async () => {
    const sections = [
        {
            load: async () => 'original-frame.xhtml',
        },
        {
            load: async () => 'replacement-frame.xhtml',
        },
    ]
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: {
            spread: 'none',
            viewport: { width: 600, height: 800 },
        },
        sections,
    })

    const originalNavigation = layout.goTo({ index: 0 })
    await nextPendingIframe('original-frame.xhtml')
    const replacementNavigation = layout.goTo({ index: 1 })
    const replacementIframe = await nextPendingIframe('replacement-frame.xhtml')
    replacementIframe.finishLoading(fixedLayoutDocument('replacement'))
    await replacementNavigation

    const originalNavigationState = await Promise.race([
        originalNavigation.then(() => 'settled'),
        new Promise(resolve => setTimeout(() => resolve('pending'), 20)),
    ])
    assert.equal(originalNavigationState, 'settled')
    assert.deepEqual(
        layout.getContents().map(content => ({
            index: content.index,
            title: content.doc.title,
        })),
        [{ index: 1, title: 'replacement' }],
    )
})

test('reports the displayed portrait-spread side as the current section index', async () => {
    const sections = [
        {
            load: async () => 'left-page.xhtml',
        },
        {
            load: async () => 'right-page.xhtml',
        },
    ]
    const layout = new FixedLayout()
    layout.boundsForTesting = { width: 600, height: 800 }
    layout.open({
        dir: 'ltr',
        rendition: {
            viewport: { width: 600, height: 800 },
        },
        sections,
    })

    const navigation = layout.goTo({ index: 0 })
    const [leftIframe, rightIframe] = await Promise.all([
        nextPendingIframe('left-page.xhtml'),
        nextPendingIframe('right-page.xhtml'),
    ])
    leftIframe.finishLoading(fixedLayoutDocument('left'))
    rightIframe.finishLoading(fixedLayoutDocument('right'))
    await navigation

    assert.equal(layout.index, 0)
    await layout.goTo({ index: 1 })
    assert.equal(layout.index, 1)
})

test('rejects a delayed target resolved after a replacement book opens', async () => {
    let resolveTarget
    const target = new Promise(resolve => {
        resolveTarget = resolve
    })
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: { spread: 'none' },
        sections: [{ load: async () => 'original-book.xhtml' }],
    })
    const navigation = layout.goTo(target)

    layout.open({
        dir: 'ltr',
        rendition: { spread: 'none' },
        sections: [{ load: async () => 'replacement-book.xhtml' }],
    })
    resolveTarget({ index: 0 })

    await assert.doesNotReject(navigation)
    assert.deepEqual(layout.getContents(), [])
})

test('rejects an older delayed target after newer same-book navigation', async () => {
    let resolveOriginalTarget
    const originalTarget = new Promise(resolve => {
        resolveOriginalTarget = resolve
    })
    const sections = [
        { load: async () => 'delayed-target.xhtml' },
        { load: async () => 'current-target.xhtml' },
    ]
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: {
            spread: 'none',
            viewport: { width: 600, height: 800 },
        },
        sections,
    })
    const originalNavigation = layout.goTo(originalTarget)

    const currentNavigation = layout.goTo({ index: 1 })
    const currentIframe = await nextPendingIframe('current-target.xhtml')
    currentIframe.finishLoading(fixedLayoutDocument('current target'))
    await currentNavigation

    resolveOriginalTarget({ index: 0 })
    await originalNavigation
    assert.equal(
        pendingIframes.some(iframe => iframe.source === 'delayed-target.xhtml'),
        false,
    )
    assert.deepEqual(
        layout.getContents().map(content => content.doc.title),
        ['current target'],
    )
})

test('suppresses an older target failure after newer same-book navigation', async () => {
    let rejectOriginalTarget
    const originalTarget = new Promise((_, reject) => {
        rejectOriginalTarget = reject
    })
    const sections = [
        { load: async () => 'failed-delayed-target.xhtml' },
        { load: async () => 'current-after-target-failure.xhtml' },
    ]
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: {
            spread: 'none',
            viewport: { width: 600, height: 800 },
        },
        sections,
    })
    const originalNavigation = layout.goTo(originalTarget)

    const currentNavigation = layout.goTo({ index: 1 })
    const currentIframe = await nextPendingIframe('current-after-target-failure.xhtml')
    currentIframe.finishLoading(fixedLayoutDocument('current after target failure'))
    await currentNavigation

    rejectOriginalTarget(new Error('obsolete target failed'))
    await assert.doesNotReject(originalNavigation)
    assert.deepEqual(
        layout.getContents().map(content => content.doc.title),
        ['current after target failure'],
    )
})

test('suppresses an older section-load failure after replacement navigation', async () => {
    let rejectOriginalSection
    let markOriginalSectionLoadStarted
    const originalSectionSource = new Promise((_, reject) => {
        rejectOriginalSection = reject
    })
    const originalSectionLoadStarted = new Promise(resolve => {
        markOriginalSectionLoadStarted = resolve
    })
    const sections = [
        {
            load: () => {
                markOriginalSectionLoadStarted()
                return originalSectionSource
            },
        },
        { load: async () => 'current-after-section-failure.xhtml' },
    ]
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: {
            spread: 'none',
            viewport: { width: 600, height: 800 },
        },
        sections,
    })

    const originalNavigation = layout.goTo({ index: 0 })
    await originalSectionLoadStarted
    const currentNavigation = layout.goTo({ index: 1 })
    const currentIframe = await nextPendingIframe('current-after-section-failure.xhtml')
    currentIframe.finishLoading(fixedLayoutDocument('current after section failure'))
    await currentNavigation

    rejectOriginalSection(new Error('obsolete section failed'))
    await assert.doesNotReject(originalNavigation)
    assert.deepEqual(
        layout.getContents().map(content => content.doc.title),
        ['current after section failure'],
    )
})

test('propagates failures owned by the current target and section generation', async () => {
    const targetLayout = new FixedLayout()
    targetLayout.open({
        dir: 'ltr',
        rendition: { spread: 'none' },
        sections: [{ load: async () => 'unused.xhtml' }],
    })
    await assert.rejects(
        targetLayout.goTo(Promise.reject(new Error('current target failed'))),
        /current target failed/,
    )

    const sectionLayout = new FixedLayout()
    sectionLayout.open({
        dir: 'ltr',
        rendition: { spread: 'none' },
        sections: [{
            load: async () => {
                throw new Error('current section failed')
            },
        }],
    })
    await assert.rejects(
        sectionLayout.goTo({ index: 0 }),
        /current section failed/,
    )
})

test('normalizes a string rendition viewport before fixed-layout scaling', async () => {
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: {
            spread: 'none',
            viewport: 'width=600,height=800',
        },
        sections: [{ load: async () => 'string-viewport.xhtml' }],
    })

    const navigation = layout.goTo({ index: 0 })
    const iframe = await nextPendingIframe('string-viewport.xhtml')
    iframe.finishLoading(fixedLayoutDocument('string viewport'))
    await navigation

    const [content] = layout.getContents()
    assert.equal(content.iframe.style.width, '600px')
    assert.equal(content.iframe.style.height, '800px')
    assert.equal(content.iframe.style.transform.includes('NaN'), false)
})

test('parses SVG viewBox dimensions with repeated whitespace', async () => {
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: { spread: 'none' },
        sections: [{ load: async () => 'svg-viewbox.xhtml' }],
    })

    const navigation = layout.goTo({ index: 0 })
    const iframe = await nextPendingIframe('svg-viewbox.xhtml')
    iframe.finishLoading({
        documentElement: {
            nodeName: 'svg',
            getAttribute: name => name === 'viewBox' ? '0   0 600   800' : null,
        },
        querySelector: () => null,
    })
    await navigation

    const [content] = layout.getContents()
    assert.equal(content.iframe.style.width, '600px')
    assert.equal(content.iframe.style.height, '800px')
})

test('falls through empty viewport metadata to the book viewport', async () => {
    const layout = new FixedLayout()
    layout.open({
        dir: 'ltr',
        rendition: {
            spread: 'none',
            viewport: { width: 600, height: 800 },
        },
        sections: [{ load: async () => 'empty-meta-viewport.xhtml' }],
    })

    const navigation = layout.goTo({ index: 0 })
    const iframe = await nextPendingIframe('empty-meta-viewport.xhtml')
    iframe.finishLoading({
        documentElement: { nodeName: 'html' },
        querySelector: selector => selector === 'meta[name="viewport"]'
            ? { getAttribute: () => '' }
            : null,
    })
    await navigation

    const [content] = layout.getContents()
    assert.equal(content.iframe.style.width, '600px')
    assert.equal(content.iframe.style.height, '800px')
})
