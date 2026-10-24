import assert from 'node:assert/strict'
import test from 'node:test'
import { SectionProgress } from '../../Sources/LakeOfFireReader/Resources/foliate-js/progress.js'
import { buildRelocateLocation } from '../../Sources/LakeOfFireReader/Resources/foliate-js/relocate-location.js'
import { createEbookLoadHandlers, createNavigationIntentRunner, createManualNavigationRunner, EbookLoadSupersededError } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-load-coordinator.js'
import { installVisibleRendererGoToGuard } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-restore-coordination.js'
import { captureEbookRelocatePublication, ebookRelocatePersistenceDecision } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-reading-progress.js'

const deferred = () => {
    let resolve, reject
    const promise = new Promise((a, b) => { resolve = a; reject = b })
    return { promise, resolve, reject }
}
const until = async predicate => {
    for (let i = 0; i < 100; i++) {
        if (predicate()) return
        await Promise.resolve()
    }
    assert.fail('Expected stage was not reached')
}
const request = (id = 'A', cfi = 'epubcfi(/6/2)', fraction = 0.25) => ({
    url: 'ebook://reader/book.epub', initialRestore: { requestID: id, cfi, fractionalCompletion: fraction },
})

const fixture = (specs = [], hooks = {}) => {
    const readers = [], warmers = [], messages = [], effects = [], progressMessages = [], timers = new Map(), frames = new Map()
    let timerID = 0, frameID = 0, criticalID = 0
    const ended = []
    const host = {
        document: {}, location: { href: 'https://reader.invalid/viewer' },
        File: class { constructor(parts, name) { this.parts = parts; this.name = name } },
        setTimeout(callback, milliseconds) { const id = ++timerID; timers.set(id, { callback, milliseconds }); return id },
        clearTimeout(id) { timers.delete(id) },
        requestAnimationFrame(callback) {
            const id = ++frameID; frames.set(id, callback)
            if (!host.pauseFrames) queueMicrotask(() => { if (frames.delete(id)) callback() })
            return id
        },
        cancelAnimationFrame(id) { frames.delete(id) },
        fetch: async () => ({ ok: true, blob: async () => 'blob' }),
        webkit: { messageHandlers: { ebookViewerLoaded: { postMessage: message => messages.push(message) } } },
    }
    class Reader {
        constructor() {
            this.spec = specs.shift() ?? {}
            this.events = []
            this.isClosed = false
            this.bookDir = 'ltr'
            this.navHUD = this.spec.navHUD
            readers.push(this)
            this.spec.construct?.()
        }
        async open(source) {
            this.events.push(['open', source])
            await this.spec.open?.(this, source)
            if (this.isClosed || this.spec.missingRenderer) return
            // These endpoint doubles acknowledge accepted commands only. The
            // real View tests below exercise command retirement and identity.
            const receipts = new WeakSet()
            const acknowledge = async operation => {
                const value = await operation()
                if (value === null || value === false || value?.ignored === true) return value
                const receipt = value && typeof value === 'object' ? value : Object.freeze({})
                receipts.add(receipt)
                return receipt
            }
            this.view = {
                lastLocation: { fraction: this.spec.landing ?? 0.25 },
                renderer: {
                    goTo: target => { this.events.push(['rendererGoTo', target]); return this.spec.rendererGoTo?.(this, target) },
                    next: () => { this.events.push(['next']); return this.spec.next?.(this) },
                    nextSection: () => { this.events.push(['nextSection']); return this.spec.nextSection?.(this) },
                },
                goTo: (target, options) => acknowledge(() => {
                    if (typeof target === 'number') {
                        return this.view.renderer.goTo({ index: target, localPage: options?.localPage })
                    }
                    this.events.push(['goTo', target])
                    return this.spec.goTo?.(this, target)
                }),
                goToFraction: fraction => acknowledge(() => {
                    this.events.push(['goToFraction', fraction])
                    return this.spec.fraction?.(this, fraction)
                }),
                isNavigationReceiptCurrent: receipt => receipts.has(receipt),
            }
            this.spec.configureView?.(this.view, this)
        }
        close(reason) {
            if (this.isClosed) return false
            this.isClosed = true
            this.events.push(['close', reason])
            this.onLoadClosed?.()
            this.view = null
            return true
        }
        completeLastPositionLoad() { this.events.push(['complete']); this.hasLoadedLastPosition = true; this.spec.complete?.(this) }
        completeLastPositionLoadAttempt() { this.events.push(['attempt']) }
        refreshNativeLookupHitTargets() { this.events.push(['lookup']) }
        maybeFlashInitialForwardSideNavChevron() { this.events.push(['flash']) }
        collectLayoutGapProbe() { this.spec.probe?.(); return { book: readers.indexOf(this) } }
    }
    class CacheWarmer {
        constructor({ loadResources }) { this.resources = loadResources; this.closed = false; warmers.push(this) }
        destroy() { this.closed = true; this.resources.close() }
    }
    const runWithNavigationIntent = createNavigationIntentRunner(host)
    const handlers = createEbookLoadHandlers({ host, Reader, CacheWarmer,
        makeNativeSource: hooks.makeNativeSource ?? (url => ({ kind: 'native', url })),
        makeFileSource: file => ({ kind: 'file', file }),
        installReaderPresentationState: () => {}, beginReplaceTextCacheGeneration: () => hooks.generation?.(),
        beginForegroundCriticalSection: () => ++criticalID,
        finishForegroundCriticalSection: token => { ended.push(token); hooks.finishForeground?.() },
        ensureRestorePositionSaveUserInputTracking: () => {},
        runWithNavigationIntent,
        markReaderRenderReady: () => effects.push('ready'),
        postLandscapeInsetRestoreProbe: () => effects.push('probe'),
        scheduleDeferredCacheWarmerOpen: () => effects.push('warm'),
    })
    const runManualNavigation = createManualNavigationRunner({
        host, runWithNavigationIntent, captureOwner: handlers.captureManualNavigation,
        onAccepted: handlers.acceptManualNavigation,
    })
    // Exercise the same production decision consumed by Reader.relocate. Only
    // the final native publication endpoint is controlled in this Node host.
    const publishProgress = (fraction, reason = 'page') => {
        const decision = ebookRelocatePersistenceDecision({
            hasLoadedLastPosition: host.reader?.hasLoadedLastPosition,
            restoreInProgress: host.__manabiRestoreInProgress,
            suppressNextRestoreRelocateSave: host.__manabiSuppressNextRestoreRelocateSave,
            requireUserInputBeforePositionSave: host.__manabiRequireUserInputBeforePositionSave,
            reason,
        })
        if (decision.clearSuppression) host.__manabiSuppressNextRestoreRelocateSave = false
        if (decision.shouldPersist) progressMessages.push({ fraction, reason })
        return decision.shouldPersist
    }
    return { ...handlers, host, readers, warmers, messages, effects, ended, timers, frames,
        runManualNavigation, publishProgress, progressMessages }
}
const count = (reader, name) => reader.events.filter(event => event[0] === name).length

globalThis.HTMLElement = class extends EventTarget {
    attachShadow() { return { append() {} } }
}
globalThis.customElements = { define() {} }
globalThis.document = { createElement() { throw new Error('Unexpected browser rendering') } }
const { View: ReviewView } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/view.js')

const reviewNavigationFixture = ({ cfiAnchor = 0.5, specs = [{}], rendererGoTo } = {}) => {
    const rendererCalls = []
    const f = fixture(specs.map(spec => ({
        ...spec,
        configureView(_unused, reader) {
            const view = new ReviewView()
            const sections = [{ id: 'one', size: 100 }, { id: 'two', size: 100 }]
            const progress = new SectionProgress(sections, 10, 10)
            view.book = {
                sections,
                resolveCFI: () => ({ index: 0, anchor: cfiAnchor }),
            }
            const resolve = view.resolveNavigation.bind(view)
            view.resolveNavigation = target => {
                if (typeof target?.fraction !== 'number') return resolve(target)
                const [index, anchor] = progress.getSection(target.fraction)
                return { index, anchor }
            }
            view.renderer = {
                localName: 'foliate-paginator', scrolled: false,
                goTo(target, options) {
                    rendererCalls.push(target)
                    const publish = () => { view.lastLocation = buildRelocateLocation({
                        index: target.index, fraction: target.anchor ?? 0, size: 0,
                    }, { sectionCount: sections.length, sectionProgress: progress }) }
                    const operation = spec.rendererGoTo ?? rendererGoTo
                    return operation ? operation({ target, options, view, reader, publish }) : publish()
                },
                destroy() {}, remove() {},
            }
            reader.view = view
            spec.configureView?.(view, reader)
        },
    })))
    return { ...f, rendererCalls }
}

const manualFraction = (f, fraction, source = 'goToPercent') => {
    const reader = f.host.reader
    const view = reader?.view
    return f.runManualNavigation({ source, target: 'view.goToFraction', fraction },
        (capturedView, options) => capturedView.goToFraction(fraction, options), { reader, view })
}

// Independent review probes for exact Lake #313 cba181b664ae8f2d9b528ec23470ecb06773a3aa.
// Reuse its endpoint fixture, actual View/History and actual load coordinator.
// No rendered iframe/layout, native bridge or Swift qualification is implied.

const startHeldDirectRestore = async f => {
    f.host.pauseFrames = true
    const pending = f.loadLastPosition({ cfi: 'epubcfi(/6/4)', fractionalCompletion: 0.25 })
    const retired = assert.rejects(pending, EbookLoadSupersededError)
    // Observe assertion rejection even if a fixture setup assertion fails;
    // each test still awaits retired and cleanup closes the active load.
    void retired.catch(() => {})
    await until(() => f.frames.size === 1)
    return { pending, retired }
}

test('independent: real History back accepts the prior position and retires a held direct restore', async t => {
    const f = reviewNavigationFixture()
    t.after(() => f.host.reader?.close('independent-review-cleanup'))
    await f.loadEBook(request('history'))
    await manualFraction(f, 0.8)
    const reader = f.host.reader, view = reader.view
    const completions = count(reader, 'complete')
    const { retired } = await startHeldDirectRestore(f)
    assert.equal(reader.hasLoadedLastPosition, false)
    assert.equal(view.history.canGoBack, true)
    view.history.back()
    await until(() => reader.hasLoadedLastPosition === true)
    await retired
    assert.equal(view.lastLocation.fraction, 0.8)
    assert.equal(count(reader, 'complete'), completions + 1)
    assert.equal(f.host.__manabiRestoreInProgress, false)
    assert.equal(f.host.__manabiRequireUserInputBeforePositionSave, false)
    assert.equal(f.publishProgress(0.8), true)
    assert.equal(f.messages.length, 1, 'a direct retry does not republish the initial native terminal')
    assert.equal(f.frames.size, 0)
    assert.equal(f.timers.size, 0)
    assert.equal(view.history.canGoForward, true, 'back navigation must not append history')
    view.history.forward()
    await until(() => view.lastLocation.fraction === 0.25)
    await until(() => f.host.__manabiRestoreInProgress === false)
    assert.equal(view.history.canGoForward, false)
    assert.equal(f.messages.length, 1)
    assert.equal(f.publishProgress(0.25), true)
})

test('independent: a rejected real History back cannot enable persistence and a fresh explicit command can recover', async t => {
    let rejectHistory = false
    const f = reviewNavigationFixture({ rendererGoTo: ({ target, publish }) => {
        if (rejectHistory && target.index === 1) return null
        return publish()
    } })
    t.after(() => f.host.reader?.close('independent-review-cleanup'))
    await f.loadEBook(request('rejected-history'))
    await manualFraction(f, 0.8)
    const reader = f.host.reader, view = reader.view
    const { retired } = await startHeldDirectRestore(f)
    rejectHistory = true
    view.history.back()
    // The direct restore is still waiting in a frame. A failed user command
    // does not abort it through a successful manual handoff; let it observe
    // the actual View command retirement on its next scheduled frame.
    await until(() => f.rendererCalls.length === 4)
    f.host.pauseFrames = false
    for (const [id, callback] of f.frames) { f.frames.delete(id); callback() }
    await retired
    assert.equal(reader.hasLoadedLastPosition, false)
    assert.equal(f.publishProgress(0.25), false)
    assert.equal(f.messages.length, 1)
    rejectHistory = false
    const receipt = await manualFraction(f, 0.7)
    assert.equal(view.isNavigationReceiptCurrent(receipt), true)
    assert.equal(reader.hasLoadedLastPosition, true)
    assert.equal(f.publishProgress(0.7), true)
    assert.equal(f.messages.length, 1)
    assert.equal(f.frames.size, 0)
})

test('independent: real History completion after reader replacement cannot open the new reader progress gate', async t => {
    const held = deferred()
    let holdHistory = false
    const f = reviewNavigationFixture({ specs: [{}, {}], rendererGoTo: ({ target, publish }) => {
        if (holdHistory && target.index === 1) return held.promise.then(publish)
        return publish()
    } })
    t.after(async () => {
        held.resolve()
        f.host.reader?.close('independent-review-cleanup')
        for (let i = 0; i < 25; i++) await Promise.resolve()
    })
    await f.loadEBook(request('old-history'))
    await manualFraction(f, 0.8)
    const oldReader = f.host.reader, oldView = oldReader.view
    const { retired } = await startHeldDirectRestore(f)
    holdHistory = true
    oldView.history.back()
    await until(() => f.rendererCalls.length === 4)
    const successor = f.loadEBook(request('successor'))
    await retired
    await until(() => f.frames.size === 1)
    const currentReader = f.host.reader
    assert.notEqual(currentReader, oldReader)
    held.resolve()
    for (let i = 0; i < 25; i++) await Promise.resolve()
    assert.notEqual(currentReader.hasLoadedLastPosition, true)
    assert.equal(f.host.__manabiRestoreInProgress, true)
    assert.equal(f.publishProgress(0.8), false)
    assert.equal(f.messages.length, 1)
    f.host.pauseFrames = false
    for (const [id, callback] of f.frames) { f.frames.delete(id); callback() }
    await successor
    assert.equal(currentReader.hasLoadedLastPosition, true)
    assert.deepEqual(f.messages.map(m => m.initialRestoreResult.requestID), ['old-history', 'successor'])
    assert.equal(f.frames.size, 0)
    assert.equal(f.timers.size, 0)
})
