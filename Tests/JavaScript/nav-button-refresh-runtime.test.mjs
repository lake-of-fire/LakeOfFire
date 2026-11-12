import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import vm from 'node:vm'

import { OwnedEventBindings, OwnedEventBindingScopes } from '../../Sources/LakeOfFireReader/Resources/foliate-js/owned-event-bindings.js'
import { beginOwnedElementOperation, finishOwnedElementOperation } from '../../Sources/LakeOfFireReader/Resources/foliate-js/owned-element-operation.js'
import { OwnedObjectURL } from '../../Sources/LakeOfFireReader/Resources/foliate-js/owned-object-url.js'
import { DeferredOpenWorkCoordinator } from '../../Sources/LakeOfFireReader/Resources/foliate-js/deferred-open-work.js'
import { EbookRenderReadinessCoordinator } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-render-readiness.js'
import { createManualNavigationRunner } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-load-coordinator.js'
import { navButtonRefreshIsCurrent } from '../../Sources/LakeOfFireReader/Resources/foliate-js/nav-button-refresh-ownership.js'

const source = await readFile(process.env.MANABI_NAV_BUTTON_VIEWER_SOURCE
    ?? new URL('../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-viewer.js', import.meta.url), 'utf8')

const between = (text, start, end) => {
    const from = text.indexOf(start)
    const to = text.indexOf(end, from + start.length)
    if (from < 0 || to < 0) throw new Error(`Unable to load production Reader boundary: ${start}`)
    return text.slice(from, to)
}

// Execute the complete shipping class, field initializers and methods. Only
// constructor UI/bootstrap work is omitted; these adapters invoke the actual
// private event handlers. DOM and renderer endpoints below are controlled, so
// this covers Reader behavior, not browser layout or WebKit integration.
const readerClass = between(source, 'class Reader {', '\nconst canUseNativeCacheWarmerPrewarm')
const constructorStart = readerClass.indexOf('    constructor() {')
const constructorEnd = readerClass.indexOf('    #invalidateVisiblePageSegmentSnapshot(', constructorStart)
if (constructorStart < 0 || constructorEnd < 0) throw new Error('Unable to isolate Reader UI bootstrap')
const readerRuntime = readerClass.slice(0, constructorStart)
    + readerClass.slice(constructorEnd).replace(/\n}\s*$/, `
    testChapterClick(button) { return this.#onNavButtonClick({ currentTarget: button }) }
    testInvalidateVisiblePage() { this.#invalidateVisiblePageSegmentSnapshot('test.relocate') }
}
globalThis.Reader = Reader;
`)
const utilities = between(source, 'const debounce =', 'const visibleJapaneseTextStateForVisibleSegmentsResult')
    + between(source, 'const normalizeArticleReadingProgress =', 'const sentenceIdentifierForNode =')

const deferred = () => {
    let resolve
    let reject
    const promise = new Promise((yes, no) => { resolve = yes; reject = no })
    return { promise, resolve, reject }
}

class Element {
    constructor(tagName, className = '') {
        Object.assign(this, { tagName, className, style: {}, dataset: {}, children: [], parent: null, hidden: false, disabled: false })
    }
    get isConnected() { return this.connected === true || this.parent?.isConnected === true }
    get offsetParent() { return this.isConnected ? this.parent ?? this : null }
    matches(selector) {
        return selector.startsWith('.')
            ? selector.slice(1).split('.').every(name => this.className.split(' ').includes(name))
            : this.tagName === selector
    }
    querySelectorAll(selector) { return this.children.flatMap(child => [...(child.matches(selector) ? [child] : []), ...child.querySelectorAll(selector)]) }
    querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null }
    closest(selector) { return this.matches(selector) ? this : this.parent?.closest(selector) ?? null }
    appendChild(child) { child.remove(); this.children.push(child); child.parent = this; return child }
    remove() {
        if (this.parent) this.parent.children.splice(this.parent.children.indexOf(this), 1)
        this.parent = null
    }
    replaceWith(other) {
        const parent = this.parent
        if (!parent) return
        other.remove()
        parent.children.splice(parent.children.indexOf(this), 1, other)
        other.parent = parent
        this.parent = null
    }
    after(other) {
        other.remove()
        this.parent.children.splice(this.parent.children.indexOf(this) + 1, 0, other)
        other.parent = this.parent
    }
    cloneNode() { return new Element(this.tagName, this.className) }
}

const oldMetrics = { isAtSectionStart: true, isAtSectionEnd: false, getHasPrevSection: true, getHasNextSection: true }
const newMetrics = { isAtSectionStart: false, isAtSectionEnd: true, getHasPrevSection: true, getHasNextSection: false }

const makeRenderer = (initial = oldMetrics) => {
    const renderer = { currentIndex: 1, values: { ...initial }, calls: [], hold: null }
    for (const name of Object.keys(initial)) renderer[name] = () => {
        renderer.calls.push(name)
        const value = renderer.values[name]
        if (renderer.hold?.name === name) {
            const hold = renderer.hold
            renderer.hold = null
            hold.started.resolve()
            return hold.release.promise.then(() => value)
        }
        return value
    }
    renderer.pause = name => {
        const hold = { name, started: deferred(), release: deferred() }
        renderer.hold = hold
        return hold
    }
    return renderer
}

const makeFixture = () => {
    const ids = new Map()
    for (const direction of ['prev', 'next']) {
        const button = new Element('button')
        button.connected = true
        button.dataset.buttonType = direction
        button.appendChild(new Element('svg'))
        button.appendChild(new Element('span', 'button-label'))
        ids.set(`btn-${direction}-chapter`, button)
    }
    for (const direction of ['left', 'right']) ids.set(`btn-scroll-${direction}`, new Element('button'))
    const bodyClasses = new Set()
    const timers = new Map()
    let nextTimer = 0
    const errors = []
    const context = {
        OwnedEventBindings, OwnedEventBindingScopes, beginOwnedElementOperation, finishOwnedElementOperation,
        OwnedObjectURL, DeferredOpenWorkCoordinator, EbookRenderReadinessCoordinator, navButtonRefreshIsCurrent,
        Map, Set, URL, performance,
        document: {
            body: { classList: {
                contains: value => bodyClasses.has(value),
                add: value => bodyClasses.add(value),
                remove: value => bodyClasses.delete(value),
                toggle: (value, active) => active ? bodyClasses.add(value) : bodyClasses.delete(value),
            } },
            documentElement: { clientWidth: 1024, clientHeight: 768 },
            getElementById: id => ids.get(id) ?? null,
            createElement: tag => new Element(tag),
            querySelectorAll: selector => [...ids.values()].flatMap(element => element.querySelectorAll(selector)),
        },
        setTimeout: (callback, delay) => { const id = ++nextTimer; timers.set(id, { callback, delay }); return id },
        clearTimeout: id => timers.delete(id),
        requestAnimationFrame: callback => { const id = ++nextTimer; timers.set(id, { callback, delay: 'frame' }); return id },
        cancelAnimationFrame: id => timers.delete(id),
        console: { error: error => errors.push(error) },
        $: () => null,
        captureNavVisibilityState: () => ({}),
        isLikelyMetadataSectionHref: () => false,
        isCompactNavigationSheetSidePaginationDisabled: () => false,
        markRestorePositionSaveUserInput: () => {},
        getComputedStyle: element => ({ display: 'block', visibility: element.style.visibility ?? 'visible' }),
        navSpinnerMaximumMs: 1200,
        loadingVisualDelayMs: 200,
        loadingVisualMaximumMs: 3500,
    }
    context.window = context
    let accepted = 0
    context.runManualNavigation = createManualNavigationRunner({
        host: context,
        captureOwner: () => ({ isCurrent: () => true }),
        onAccepted: () => { accepted += 1 },
        runWithNavigationIntent: (_intent, operation) => operation(),
    })
    vm.createContext(context)
    vm.runInContext(utilities + readerRuntime, context, { filename: 'ebook-viewer.Reader.runtime.js' })
    const readers = []
    const attachReader = (renderer = makeRenderer()) => {
        const reader = new context.Reader()
        const publications = []
        let waiting = null
        let receipt = null
        const view = {
            renderer,
            book: { sections: [{ id: 'one.xhtml' }, { id: 'two.xhtml' }] },
            close() {}, remove() {},
            async nextSection(options) {
                assert.equal(options.requiresNavigationReceipt, true)
                await view.navigate?.()
                receipt = {}
                return receipt
            },
            isNavigationReceiptCurrent: value => value != null && value === receipt,
        }
        view.prevSection = view.nextSection
        reader.view = view
        reader.buttons = { prev: ids.get('btn-prev-chapter'), next: ids.get('btn-next-chapter') }
        reader.isRTL = false
        reader.navHUD = {
            setNavContext(value) { publications.push(value); waiting?.resolve(value); waiting = null },
            _toggleCompletionStack() {}, destroy() {},
        }
        context.reader = reader
        readers.push(reader)
        return {
            reader, view, renderer, publications,
            nextPublication() { assert.equal(waiting, null); waiting = deferred(); return waiting.promise },
        }
    }
    const current = attachReader()
    return {
        ...current, context, ids, timers, errors, attachReader,
        get accepted() { return accepted },
        snapshot() {
            return Object.fromEntries([...ids].map(([id, element]) => [id, {
                hidden: element.hidden, visibility: element.style.visibility, disabled: element.disabled,
            }]))
        },
        close() { for (const reader of readers) reader.close('test-teardown') },
    }
}

test('current Reader refresh publishes chapter controls and keeps manual navigation receipt admission', async t => {
    const fixture = makeFixture()
    t.after(() => fixture.close())
    await fixture.reader.updateNavButtons()
    assert.equal(fixture.reader.buttons.prev.hidden, false)
    assert.equal(fixture.reader.buttons.next.hidden, true)
    const publication = fixture.nextPublication()
    await fixture.reader.testChapterClick(fixture.reader.buttons.next)
    await publication
    assert.equal(fixture.accepted, 1)
    assert.equal(fixture.errors.length, 0)
})

for (const metric of Object.keys(oldMetrics)) test(`a completed chapter operation supersedes a refresh paused in ${metric}`, async t => {
    const fixture = makeFixture()
    t.after(() => fixture.close())
    const hold = fixture.renderer.pause(metric)
    const stale = fixture.reader.updateNavButtons()
    await hold.started.promise
    fixture.renderer.values = { ...newMetrics }
    const publication = fixture.nextPublication()
    await fixture.reader.testChapterClick(fixture.reader.buttons.next)
    await publication
    const committed = fixture.snapshot()
    hold.release.resolve()
    await stale
    assert.deepEqual(fixture.snapshot(), committed)
    assert.equal(fixture.publications.length, 1)
    assert.equal(fixture.accepted, 1)
})

test('an active chapter operation keeps its label and spinner until its actual cleanup', async t => {
    const fixture = makeFixture()
    t.after(() => fixture.close())
    const navigation = deferred()
    const started = deferred()
    fixture.view.navigate = () => { started.resolve(); return navigation.promise }
    const click = fixture.reader.testChapterClick(fixture.reader.buttons.next)
    await started.promise
    const label = fixture.reader.buttons.next.querySelector('.button-label')
    const spinner = fixture.reader.buttons.next.querySelector('.nav-spinner')
    assert.equal(label.style.visibility, 'hidden')
    assert.equal(spinner.isConnected, true)
    await fixture.reader.updateNavButtons()
    assert.equal(label.style.visibility, 'hidden')
    assert.equal(spinner.isConnected, true)
    assert.equal(fixture.renderer.calls.length, 0)
    const publication = fixture.nextPublication()
    navigation.resolve()
    await click
    await publication
    assert.equal(label.style.visibility, '')
    assert.equal(spinner.isConnected, false)
    assert.equal(fixture.errors.length, 0)
})

test('replacing the exact renderer rejects a suspended old refresh', async t => {
    const fixture = makeFixture()
    t.after(() => fixture.close())
    const hold = fixture.renderer.pause('isAtSectionStart')
    const stale = fixture.reader.updateNavButtons()
    await hold.started.promise
    fixture.view.renderer = makeRenderer(newMetrics)
    await fixture.reader.updateNavButtons()
    const committed = fixture.snapshot()
    hold.release.resolve()
    await stale
    assert.deepEqual(fixture.snapshot(), committed)
    assert.equal(fixture.publications.length, 1)
})

test('Reader.close prevents old work from rewriting a replacement Reader sharing the same controls', async t => {
    const fixture = makeFixture()
    t.after(() => fixture.close())
    const hold = fixture.renderer.pause('isAtSectionStart')
    const stale = fixture.reader.updateNavButtons()
    await hold.started.promise
    assert.equal(fixture.reader.close('replaced'), true)
    const replacement = fixture.attachReader(makeRenderer(newMetrics))
    await replacement.reader.updateNavButtons()
    const committed = fixture.snapshot()
    hold.release.resolve()
    await stale
    assert.deepEqual(fixture.snapshot(), committed)
    assert.equal(fixture.publications.length, 0)
    assert.equal(replacement.publications.length, 1)
})

test('actual visible-page invalidation rejects an older refresh and permits the current retry', async t => {
    const fixture = makeFixture()
    t.after(() => fixture.close())
    const hold = fixture.renderer.pause('isAtSectionStart')
    const stale = fixture.reader.updateNavButtons()
    await hold.started.promise
    fixture.reader.testInvalidateVisiblePage()
    fixture.renderer.values = { ...newMetrics }
    await fixture.reader.updateNavButtons()
    const committed = fixture.snapshot()
    hold.release.resolve()
    await stale
    assert.deepEqual(fixture.snapshot(), committed)
    assert.equal(fixture.publications.length, 1)
})

test('failed chapter navigation releases operation ownership and allows a subsequent refresh', async t => {
    const fixture = makeFixture()
    t.after(() => fixture.close())
    const failure = new Error('controlled renderer failure')
    fixture.view.navigate = async () => { throw failure }
    const publication = fixture.nextPublication()
    await fixture.reader.testChapterClick(fixture.reader.buttons.next)
    await publication
    assert.deepEqual(fixture.errors, [failure])
    assert.equal(fixture.accepted, 0)
    assert.equal(fixture.reader.buttons.next.querySelector('.button-label').style.visibility, '')
    assert.equal(fixture.reader.buttons.next.querySelector('.nav-spinner'), null)
    fixture.view.navigate = null
    const retryPublication = fixture.nextPublication()
    await fixture.reader.testChapterClick(fixture.reader.buttons.next)
    await retryPublication
    assert.equal(fixture.accepted, 1)
    assert.equal(fixture.publications.length, 2)
})

test('closing during actual chapter navigation cleans up once and cannot refresh replacement controls', async t => {
    const fixture = makeFixture()
    t.after(() => fixture.close())
    const navigation = deferred()
    const started = deferred()
    fixture.view.navigate = () => { started.resolve(); return navigation.promise }
    const click = fixture.reader.testChapterClick(fixture.reader.buttons.next)
    await started.promise
    assert.equal(fixture.reader.buttons.next.querySelector('.button-label').style.visibility, 'hidden')
    fixture.reader.close('navigation-cancelled-by-replacement')
    const replacement = fixture.attachReader(makeRenderer(newMetrics))
    await replacement.reader.updateNavButtons()
    const committed = fixture.snapshot()
    navigation.resolve()
    await click
    assert.deepEqual(fixture.snapshot(), committed)
    assert.equal(fixture.reader.buttons.next.querySelector('.button-label').style.visibility, '')
    assert.equal(fixture.reader.buttons.next.querySelector('.nav-spinner'), null)
    assert.equal(fixture.publications.length, 0)
    assert.equal(replacement.publications.length, 1)
    assert.equal(fixture.accepted, 0)
    assert.equal(fixture.errors.length, 0)
})

test('spinner timeout cleanup cannot revive a refresh from before the chapter operation', async t => {
    const fixture = makeFixture()
    t.after(() => fixture.close())
    const hold = fixture.renderer.pause('isAtSectionStart')
    const stale = fixture.reader.updateNavButtons()
    await hold.started.promise
    fixture.renderer.values = { ...newMetrics }
    const navigation = deferred()
    const started = deferred()
    fixture.view.navigate = () => { started.resolve(); return navigation.promise }
    const click = fixture.reader.testChapterClick(fixture.reader.buttons.next)
    await started.promise
    const fallback = [...fixture.timers.values()].find(timer => timer.delay === 1200)
    assert.ok(fallback)
    const publication = fixture.nextPublication()
    fallback.callback()
    await publication
    assert.equal(fixture.reader.buttons.next.querySelector('.button-label').style.visibility, '')
    assert.equal(fixture.reader.buttons.next.querySelector('.nav-spinner'), null)
    const committed = fixture.snapshot()
    hold.release.resolve()
    await stale
    assert.deepEqual(fixture.snapshot(), committed)
    assert.equal(fixture.publications.length, 1)
    navigation.resolve()
    await click
    assert.equal(fixture.publications.length, 1)
    assert.equal(fixture.accepted, 1)
    assert.equal(fixture.errors.length, 0)
})
