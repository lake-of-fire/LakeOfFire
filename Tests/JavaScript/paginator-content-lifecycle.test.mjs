import assert from 'node:assert/strict'
import nodeTest from 'node:test'

class Element extends EventTarget {
    constructor(name) {
        super(); this.name = name; this.children = []; this.style = makeStyle(); this.counts = new Map();
        this.listenerWrappers = new Map()
        this.isConnected = true; this.attributes = new Map(); this.dataset = {};
        this.classList = { toggle() {}, add() {}, remove() {} };
    }
    append(...children) { this.children.push(...children) }
    setAttribute(name, value) { this.attributes.set(name, String(value)) }
    getAttribute(name) { return this.attributes.get(name) ?? null }
    removeAttribute(name) { this.attributes.delete(name) }
    hasAttribute(name) { return this.attributes.has(name) }
    attachShadow() {
        const nodes = new Map(['top', 'container', 'header', 'footer'].map(name => [name, new Element(name)]))
        this.shadowNodes = nodes
        return { getElementById: name => nodes.get(name) }
    }
    addEventListener(type, listener, options) {
        const listeners = this.counts.get(type) ?? new Set()
        listeners.add(listener); this.counts.set(type, listeners)
        const wrappers = this.listenerWrappers.get(type) ?? new Map()
        this.listenerWrappers.set(type, wrappers)
        const callback = options?.once ? (...args) => {
            listeners.delete(listener)
            wrappers.delete(listener)
            listener.apply(this, args)
        } : listener
        wrappers.set(listener, callback)
        super.addEventListener(type, callback, options)
    }
    removeEventListener(type, listener, options) {
        const wrappers = this.listenerWrappers.get(type)
        super.removeEventListener(type, wrappers?.get(listener) ?? listener, options)
        wrappers?.delete(listener)
        this.counts.get(type)?.delete(listener)
    }
}
const makeStyle = () => {
    const values = new Map(), priorities = new Map(), writes = []
    return {
        writes,
        getPropertyValue: name => values.get(name) ?? '',
        getPropertyPriority: name => priorities.get(name) ?? '',
        setProperty(name, value, priority = '') {
            writes.push([name, value]); values.set(name, value); priorities.set(name, priority)
        },
    }
}
const observers = []
const iframeWaiters = []
globalThis.NodeFilter = { SHOW_ELEMENT: 1, SHOW_TEXT: 4, SHOW_CDATA_SECTION: 8, FILTER_ACCEPT: 1, FILTER_REJECT: 2, FILTER_SKIP: 3 }
globalThis.Range = class {}
globalThis.CustomEvent = class extends Event {
    constructor(type, options = {}) { super(type, options); this.detail = options.detail }
}
globalThis.HTMLElement = Element
globalThis.ResizeObserver = class {
    constructor(callback) { this.callback = callback; observers.push(this) }
    observe() {} unobserve() {} disconnect() {}
}
globalThis.customElements = { define() {} }
globalThis.document = {
    createElement: name => {
        const element = new Element(name)
        if (name === 'iframe') iframeWaiters.splice(0).forEach(resolve => resolve(element))
        return element
    },
    createRange: () => ({ selectNodeContents() {}, getBoundingClientRect: () => ({ width: 500, height: 700, left: 0, right: 500 }) }),
}
const frameRequests = []
const frameWaiters = []
globalThis.requestAnimationFrame = callback => {
    frameRequests.push(callback)
    frameWaiters.splice(0).forEach(resolve => resolve(callback))
    return frameRequests.length
}
const nextFrame = () => new Promise(resolve => { frameWaiters.push(resolve) })
// Browser events and frame delivery are controlled; the actual production View
// and Paginator own every pending operation. No CSS layout or WKWebView execution
// is qualified here. PAGINATOR_MODULE permits an exact-parent negative control.
const { Paginator, PaginatorContentView } = await import(process.env.PAGINATOR_MODULE ?? new URL(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/paginator.js', import.meta.url,
))
const activeViews = new Set()
const test = (name, body) => nodeTest(name, { timeout: 1200 }, async t => {
    t.after(() => {
        for (const content of activeViews) content.destroy()
        activeViews.clear()
        frameRequests.length = 0
        frameWaiters.length = 0
    })
    await body(t)
})
const view = (callbacks = {}) => {
    let activities = 0
    const content = new PaginatorContentView({
        container: {}, onBeforeExpand() {}, onExpand() {},
        beginPositionActivity: () => {
            activities += 1
            let finished = false
            return () => { if (!finished) { finished = true; activities -= 1 } }
        },
        ...callbacks,
    })
    content.activeActivities = () => activities
    activeViews.add(content)
    return content
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
            timer = setTimeout(() => reject(new Error('Production operation did not settle')), 400)
        })])
    } finally { clearTimeout(timer) }
}


test('destroy cancels a load waiting for an iframe event and removes both callbacks', async () => {
    const content = view()
    const frame = content.element.children[0]
    const pending = content.load('ebook://ebook/chapter.xhtml')
    const rejected = assert.rejects(pending, error => error.name === 'AbortError')
    content.destroy()
    await bounded(rejected)
    assert.equal(frame.counts.get('load').size, 0)
    assert.equal(frame.counts.get('error').size, 0)
    content.destroy()
})

test('retired load cannot continue after its document callback resumes', async () => {
    let release, entered
    const started = new Promise(resolve => { entered = resolve })
    const gate = new Promise(resolve => { release = resolve })
    const content = view()
    const frame = content.element.children[0]
    const { doc } = makeDocument()
    frame.contentDocument = doc
    let layouts = 0
    const pending = content.load('ebook://ebook/chapter.xhtml', async () => { entered(); await gate },
                                () => { layouts += 1; return {} })
    frame.dispatchEvent(new Event('load'))
    await started
    const rejected = assert.rejects(pending, error => error.name === 'AbortError')
    content.destroy()
    release()
    await bounded(rejected)
    await Promise.resolve()
    assert.equal(layouts, 0)
    assert.equal(frame.counts.get('load').size, 0)
})

test('a failed iframe load removes its success callback', async () => {
    const content = view()
    const frame = content.element.children[0]
    const pending = content.load('ebook://ebook/chapter.xhtml')
    const error = new Event('error')
    const rejected = assert.rejects(pending, value => value === error)
    frame.dispatchEvent(error)
    await bounded(rejected)
    assert.equal(frame.counts.get('load').size, 0)
    assert.equal(frame.counts.get('error').size, 0)
    content.destroy()
})

const makeDocument = () => {
    const root = new Element('html'), body = new Element('body')
    let reads = 0
    root.getBoundingClientRect = () => { reads += 1; return { width: 500, height: 700, left: 0, right: 500 } }
    body.querySelectorAll = () => []
    body.matches = () => false
    body.setAttribute('data-mnb-writing-direction', 'horizontal')
    const doc = { documentElement: root, body, defaultView: {}, location: { href: 'ebook://ebook/chapter.xhtml' },
        getElementById: () => null, querySelector: () => null, addEventListener() {} }
    return { doc, reads: () => reads }
}
const horizontal = { vertical: false, verticalRTL: false, rtl: false }
const layout = { flow: 'paginated', width: 320, height: 480, gap: 12, columnWidth: 220, divisor: 1 }

test('destroy settles expansion suspended in its before callback', async () => {
    let release, entered
    const started = new Promise(resolve => { entered = resolve })
    const gate = new Promise(resolve => { release = resolve })
    let expanded = 0
    const content = view({ onBeforeExpand: async () => { entered(); await gate }, onExpand: () => { expanded += 1 } })
    const { doc, reads } = makeDocument()
    content.element.children[0].contentDocument = doc
    const pending = content.expand()
    await started
    content.destroy()
    await bounded(pending)
    assert.equal(content.activeActivities(), 0)
    release()
    await Promise.resolve()
    assert.equal(expanded, 0)
    assert.equal(reads(), 0)
})

test('a retired expansion frame cannot read geometry or mutate a successor document', async () => {
    const content = view()
    const original = makeDocument(), successor = makeDocument()
    const frame = content.element.children[0]
    frame.contentDocument = original.doc
    const scheduled = nextFrame()
    const pending = content.expand()
    const staleFrame = await scheduled
    const replacement = content.load('ebook://ebook/new.xhtml')
    const rejected = assert.rejects(replacement, error => error.type === 'error')
    frame.contentDocument = successor.doc
    frame.dispatchEvent(new Event('error'))
    await bounded(pending)
    await bounded(rejected)
    const previousWidth = content.element.style.width
    await staleFrame()
    assert.equal(original.reads(), 0)
    assert.equal(successor.reads(), 0)
    assert.equal(content.element.style.width, previousWidth)
    content.destroy()
})

for (const method of ['render', 'scrolled', 'columnize']) {
    test(`a ${method} awaiting direction cannot overwrite a newer layout`, async () => {
        const content = view()
        const { doc } = makeDocument()
        content.element.children[0].contentDocument = doc
        const obsolete = content[method]({ ...layout, columnWidth: 111 })
        // Start the operation's direction await; this is one explicit turn, not readiness polling.
        await Promise.resolve()
        const scheduled = nextFrame()
        const current = content.render(layout)
        content.setDirection(horizontal)
        await bounded(obsolete)
        const draw = await scheduled
        assert.ok(content.activeActivities() > 0, 'the successor still owns position activity')
        await draw()
        await bounded(current)
        assert.equal(content.activeActivities(), 0)
        assert.equal(doc.documentElement.style.getPropertyValue('column-width'), '220px')
        assert.equal(doc.documentElement.style.writes.some(([name, value]) => name === 'column-width' && value === '111px'), false)
        assert.equal(content.element.style.width, '1280px')
        content.destroy()
    })
}

test('destroy settles a layout waiting for direction without a frame', async () => {
    const content = view()
    const { doc } = makeDocument()
    content.element.children[0].contentDocument = doc
    const pending = content.render(layout)
    await Promise.resolve()
    content.destroy()
    await bounded(pending)
    assert.equal(content.activeActivities(), 0)
    assert.equal(doc.documentElement.style.writes.length, 0)
})

test('an expansion awaiting its completion callback settles when destroyed', async () => {
    let entered, release
    const started = new Promise(resolve => { entered = resolve })
    const gate = new Promise(resolve => { release = resolve })
    const content = view({ onExpand: async () => { entered(); await gate } })
    const { doc } = makeDocument()
    content.element.children[0].contentDocument = doc
    content.setDirection(horizontal)
    const scheduled = nextFrame()
    const pending = content.render(layout)
    const draw = await scheduled
    const drawing = draw()
    await started
    content.destroy()
    await bounded(pending)
    release()
    await drawing
})

test('invalidating a pending container frame settles it without clearing its successor', async () => {
    const paginator = new Paginator()
    paginator.open({ dir: 'ltr', sections: [] }, false)
    const container = paginator.shadowNodes.get('container')
    container.clientWidth = 320; container.clientHeight = 480
    const observer = observers.at(-1)
    const scheduled = nextFrame()
    const previous = paginator.sizes()
    const staleFrame = await scheduled
    observer.callback([{ contentRect: { width: 640, height: 480, top: 0, left: 0 } }])
    assert.equal(await bounded(previous), null)
    container.clientWidth = 640
    const nextScheduled = nextFrame()
    const successor = paginator.sizes()
    const currentFrame = await nextScheduled
    await staleFrame()
    const count = frameRequests.length
    const joined = paginator.sizes()
    assert.equal(frameRequests.length, count)
    await currentFrame()
    assert.deepEqual(await successor, { width: 640, height: 480 })
    assert.deepEqual(await joined, { width: 640, height: 480 })
    paginator.destroy()
})

test('destroy settles pending container dimensions and direction-based view dimensions', async () => {
    const paginator = new Paginator()
    paginator.open({ dir: 'ltr', sections: [] }, false)
    const scheduled = nextFrame()
    const dimensions = paginator.sizes()
    const staleFrame = await scheduled
    const viewDimensions = paginator.viewSize()
    paginator.destroy()
    assert.equal(await bounded(dimensions), null)
    assert.equal(await bounded(viewDimensions), 0)
    await staleFrame()
    assert.equal(await paginator.sizes(), null)
})

test('changing writing direction retires a queued expansion from the previous geometry', async () => {
    const content = view()
    const { doc } = makeDocument()
    content.element.children[0].contentDocument = doc
    content.setDirection(horizontal)
    const scheduled = nextFrame()
    const pending = content.render(layout)
    const staleFrame = await scheduled
    const width = content.element.style.width
    content.setDirection({ vertical: true, verticalRTL: true, rtl: false })
    await bounded(pending)
    await staleFrame()
    assert.equal(content.element.style.width, width)
    content.destroy()
})

test('an iframe error retires document preparation before it can resume layout', async t => {
    const entered = deferred(), gate = deferred()
    t.after(() => gate.resolve())
    const content = view()
    const frame = content.element.children[0]
    const { doc } = makeDocument()
    frame.contentDocument = doc
    let layouts = 0
    const pending = content.load('ebook://ebook/chapter.xhtml', async () => {
        entered.resolve()
        await gate.promise
    }, () => { layouts += 1 })
    const error = new Event('error')
    const rejected = assert.rejects(pending, value => value === error)
    frame.dispatchEvent(new Event('load'))
    await entered.promise
    frame.dispatchEvent(error)
    await bounded(rejected)
    gate.resolve()
    await new Promise(setImmediate)
    assert.equal(layouts, 0)
    assert.equal(doc.documentElement.style.writes.length, 0)
    assert.equal(frame.counts.get('load').size, 0)
    assert.equal(frame.counts.get('error').size, 0)
})

test('a new load settles an old suspended load and keeps only the new document current', async t => {
    const entered = deferred(), gate = deferred()
    t.after(() => gate.resolve())
    const content = view()
    const frame = content.element.children[0]
    const original = makeDocument(), successor = makeDocument()
    frame.contentDocument = original.doc
    let oldLayouts = 0, currentLayouts = 0
    const previous = content.load('ebook://ebook/old.xhtml', async () => {
        entered.resolve()
        await gate.promise
    }, () => { oldLayouts += 1 })
    const rejected = assert.rejects(previous, error => error.name === 'AbortError')
    frame.dispatchEvent(new Event('load'))
    await entered.promise
    const current = content.load('ebook://ebook/current.xhtml', null, () => { currentLayouts += 1 })
    frame.contentDocument = successor.doc
    frame.dispatchEvent(new Event('load'))
    await bounded(Promise.all([rejected, current]))
    gate.resolve()
    await new Promise(setImmediate)
    assert.equal(oldLayouts, 0)
    assert.equal(currentLayouts, 1)
    assert.equal(content.document, successor.doc)
    assert.equal(frame.counts.get('load').size, 0)
    assert.equal(frame.counts.get('error').size, 0)
})

test('a failed load can retry on the same View and complete its current callback', async () => {
    const content = view()
    const frame = content.element.children[0]
    const failed = content.load('ebook://ebook/missing.xhtml')
    const error = new Event('error')
    const rejected = assert.rejects(failed, value => value === error)
    frame.dispatchEvent(error)
    await bounded(rejected)
    const { doc } = makeDocument()
    frame.contentDocument = doc
    let prepared = 0
    const retry = content.load('ebook://ebook/retry.xhtml', () => { prepared += 1 })
    frame.dispatchEvent(new Event('load'))
    await bounded(retry)
    assert.equal(prepared, 1)
    assert.equal(content.document, doc)
    assert.equal(frame.counts.get('load').size, 0)
    assert.equal(frame.counts.get('error').size, 0)
})

test('fonts completing after destroy cannot schedule another expansion', async () => {
    const fonts = deferred()
    const content = view()
    const frame = content.element.children[0]
    const { doc, reads } = makeDocument()
    doc.fonts = { ready: fonts.promise }
    frame.contentDocument = doc
    const pending = content.load('ebook://ebook/chapter.xhtml')
    frame.dispatchEvent(new Event('load'))
    await bounded(pending)
    content.destroy()
    fonts.resolve()
    await new Promise(setImmediate)
    assert.equal(frameRequests.length, 0)
    assert.equal(reads(), 0)
    assert.equal(content.activeActivities(), 0)
})

test('current expansion failure releases position activity and permits a real retry', async () => {
    const failure = new Error('Controlled current callback failure')
    const content = view({ onBeforeExpand: () => { throw failure } })
    const { doc } = makeDocument()
    content.element.children[0].contentDocument = doc
    content.setDirection(horizontal)
    await assert.rejects(content.expand(), error => error === failure)
    assert.equal(content.activeActivities(), 0)
    content.onBeforeExpand = () => {}
    const scheduled = nextFrame()
    const retry = content.render(layout)
    await (await scheduled)()
    await bounded(retry)
    assert.equal(content.element.style.width, '1280px')
    assert.equal(content.activeActivities(), 0)
})

test('a loaded production paginator retires its pending view measurement on destroy', async t => {
    let entered, release
    const started = new Promise(resolve => { entered = resolve })
    const gate = new Promise(resolve => { release = resolve })
    const { doc } = makeDocument()
    doc.defaultView.manabi_waitForExternalSegmentSidecar = async () => { entered(); await gate }
    const paginator = new Paginator()
    paginator.open({ dir: 'ltr', sections: [{ load: async () => 'ebook://ebook/chapter.xhtml', unload() {} }] }, false)
    t.after(() => { release(); paginator.destroy() })
    const created = new Promise(resolve => { iframeWaiters.push(resolve) })
    const opening = paginator.goTo({ index: 0 })
    const frame = await created
    frame.contentDocument = doc
    frame.dispatchEvent(new Event('load'))
    await started
    const layoutScheduled = nextFrame()
    const direction = paginator.setWritingDirectionOverride('horizontal')
    const obsoleteLayoutFrame = await layoutScheduled
    const element = paginator.shadowNodes.get('container').children[0]
    let reads = 0
    Object.defineProperty(element, 'clientWidth', { get() { reads += 1; return 900 } })
    element.clientHeight = 480
    const viewScheduled = nextFrame()
    const measured = paginator.viewSize()
    const obsoleteViewFrame = await viewScheduled
    paginator.destroy()
    assert.equal(await bounded(measured), 0)
    assert.equal(await bounded(opening), null)
    await bounded(direction)
    await obsoleteViewFrame()
    await obsoleteLayoutFrame()
    assert.equal(reads, 0)
    release()
})
