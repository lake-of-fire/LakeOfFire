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

// The selected Reader has no displayInitialSection method. Exercise its actual
// renderer entry point and the same visible-page wrapper installed by Reader.
const syntheticSpec = (spec = {}) => ({
    ...spec,
    configureView(view, reader) {
        view.renderer.localName = spec.rendererName ?? 'foliate-paginator'
        view.renderer.scrolled = spec.scrolled ?? false
        installVisibleRendererGoToGuard({ renderer: view.renderer,
            getCurrentIndex: () => spec.currentSection ?? 0,
            getPageSnapshot: () => ({ current: spec.currentPage ?? 1, total: spec.pageCount ?? 3 }) })
        spec.configureView?.(view, reader)
    },
})

// Full loader/restore functions execute; only Reader/browser and native-message
// endpoints are doubles. No code-reading or source-shape assertions.
test('current CFI restore publishes its correlated receipt and clears only its work', async () => {
    const f = fixture()
    await f.loadEBook(request())
    assert.equal(f.messages[0].initialRestoreResult.requestID, 'A')
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, true)
    assert.equal(count(f.readers[0], 'complete'), 1)
    assert.deepEqual(f.effects, ['ready', 'probe', 'warm'])
    assert.equal(f.host.manabiLoadEBookReady, true)
    assert.equal(f.host.manabiLoadEBookInFlight, false)
    assert.equal(f.timers.size, 0)
})

test('identical in-flight delivery reuses the exact promise without replacing its request', async () => {
    const gate = deferred(), f = fixture([{ open: () => gate.promise }])
    const first = f.loadEBook(request())
    assert.equal(f.loadEBook(request()), first)
    assert.equal(f.readers.length, 1)
    gate.resolve()
    await first
    assert.equal(f.messages.length, 1)
})

test('different request at same URL replaces an in-flight restore rather than losing its locator', async () => {
    const gate = deferred(), f = fixture([{ goTo: () => gate.promise }])
    const first = f.loadEBook(request())
    await until(() => count(f.readers[0], 'goTo') === 1)
    const second = f.loadEBook(request('B', 'epubcfi(/6/4)'))
    await Promise.all([first, second]) // Need not await the retired renderer.
    assert.equal(f.messages.length, 1)
    assert.equal(f.messages[0].initialRestoreResult.requestID, 'B')
    gate.resolve()
    await until(() => f.timers.size === 0)
    assert.equal(f.host.manabiInitialRestoreResult.requestID, 'B')
    assert.equal(count(f.readers[0], 'complete'), 0)
    assert.deepEqual(f.ended, [1])
})

test('different request at same ready URL is not discarded as duplicate-ready', async () => {
    const f = fixture()
    await f.loadEBook(request())
    await f.loadEBook(request('B'))
    assert.equal(f.readers.length, 2)
    assert.deepEqual(f.messages.map(m => m.initialRestoreResult.requestID), ['A', 'B'])
})

test('identical ready request retains its reader', async () => {
    const f = fixture()
    await f.loadEBook(request())
    assert.equal(f.loadEBook(request()), undefined)
    assert.equal(f.readers.length, 1)
    assert.equal(f.messages.length, 1)
})

test('late old rejection cannot mark a newer restore attempted or clear its active flags', async () => {
    const a = deferred(), b = deferred(), f = fixture([{ goTo: () => a.promise }, { goTo: () => b.promise }])
    const first = f.loadEBook(request())
    await until(() => count(f.readers[0], 'goTo') === 1)
    const second = f.loadEBook({ ...request('B'), url: 'ebook://reader/second.epub' })
    await until(() => count(f.readers[1], 'goTo') === 1)
    a.reject(new Error('old renderer failure'))
    await first
    assert.equal(f.host.__manabiRestoreInProgress, true)
    assert.equal(count(f.readers[1], 'attempt'), 0)
    assert.equal(f.host.manabiLoadEBookPromise, second)
    assert.equal(f.host.manabiInitialRestoreResult, null)
    b.resolve()
    await second
})

test('superseded fetch is aborted and its late response is never read', async () => {
    const gate = deferred(), f = fixture()
    let signal, reads = 0
    f.host.fetch = (_url, options) => { signal = options.signal; return gate.promise }
    const first = f.loadEBook({ url: 'https://books.invalid/first.epub' })
    await until(() => signal)
    const second = f.loadEBook(request('B'))
    assert.equal(signal.aborted, true)
    await Promise.all([first, second])
    gate.resolve({ ok: true, blob: () => { reads++; return 'old' } })
    await until(() => f.messages.length === 1)
    for (let i = 0; i < 10; i++) await Promise.resolve()
    assert.equal(reads, 0)
    assert.equal(count(f.readers[0], 'open'), 0)
})

test('late response body cannot repopulate retired resources or open an old reader', async () => {
    const gate = deferred(), f = fixture()
    let bodyStarted = false
    f.host.fetch = async () => ({ ok: true, blob: () => { bodyStarted = true; return gate.promise } })
    const first = f.loadEBook({ url: 'https://books.invalid/first.epub' })
    await until(() => bodyStarted)
    await f.loadEBook(request('B'))
    gate.resolve('old blob')
    await first
    assert.equal(f.warmers[0].resources.diagnostics.hasRemoteBlob, false)
    assert.equal(count(f.readers[0], 'open'), 0)
})

test('close during open settles the public promise and releases only that load', async () => {
    const gate = deferred(), f = fixture([{ open: () => gate.promise }])
    const pending = f.loadEBook(request())
    await until(() => count(f.readers[0], 'open') === 1)
    f.readers[0].close('test')
    await pending
    assert.equal(f.host.manabiLoadEBookReady, false)
    assert.equal(f.host.manabiLoadEBookPromise, null)
    assert.equal(f.warmers[0].closed, true)
    assert.deepEqual(f.ended, [1])
    gate.resolve()
})

test('close during frame settling cancels frame and fallback handles without completion', async () => {
    const f = fixture()
    f.host.pauseFrames = true
    const pending = f.loadEBook(request())
    await until(() => f.frames.size === 1)
    f.readers[0].close('test')
    await pending
    assert.equal(f.frames.size, 0)
    assert.equal(f.timers.size, 0)
    assert.equal(count(f.readers[0], 'complete'), 0)
    assert.equal(f.messages.length, 0)
    assert.equal(f.host.__manabiRestoreInProgress, false)
})

test('same-reader newer restore owns flags and completion when older work finishes', async () => {
    const f = fixture()
    await f.loadEBook(request())
    const a = deferred(), b = deferred(), reader = f.readers[0]
    let calls = 0
    reader.spec.goTo = () => ++calls === 1 ? a.promise : b.promise
    const first = f.loadLastPosition({ cfi: 'first' })
    const rejection = assert.rejects(first, EbookLoadSupersededError)
    await until(() => calls === 1)
    const second = f.loadLastPosition({ cfi: 'second' })
    await until(() => calls === 2)
    a.resolve()
    await rejection
    assert.equal(f.host.__manabiRestoreInProgress, true)
    assert.equal(count(reader, 'complete'), 1)
    b.resolve()
    const result = await second
    assert.equal(result.handledCFI, 'second')
    assert.equal(count(reader, 'complete'), 2)
})

test('renderer replacement on the same reader rejects the old snapshot', async () => {
    const f = fixture(); await f.loadEBook(request())
    const gate = deferred(), reader = f.readers[0]
    reader.spec.goTo = () => gate.promise
    const pending = f.loadLastPosition({ cfi: 'again' })
    const rejected = assert.rejects(pending, EbookLoadSupersededError)
    await until(() => count(reader, 'goTo') === 2)
    reader.view.renderer = {}
    gate.resolve()
    await rejected
    assert.equal(count(reader, 'complete'), 1)
})

test('stale default navigation error never invokes fallback on a replacement reader', async () => {
    const gate = deferred(), f = fixture([{ next: () => gate.promise }])
    const first = f.loadEBook({ url: 'ebook://reader/a.epub' })
    await until(() => count(f.readers[0], 'next') === 1)
    const second = f.loadEBook(request('B'))
    gate.reject(new Error('old next failed'))
    await Promise.all([first, second])
    assert.equal(count(f.readers[0], 'nextSection'), 0)
    assert.equal(count(f.readers[1], 'nextSection'), 0)
})

test('current default-navigation error still uses its own section fallback', async () => {
    const f = fixture([{ next: () => { throw new Error('next failed') } }])
    await f.loadEBook({ url: 'ebook://reader/a.epub' })
    assert.equal(count(f.readers[0], 'nextSection'), 1)
    assert.equal(f.timers.size, 0)
    assert.equal(f.messages[0].initialRestoreResult.terminalState, 'noTarget')
})

test('successful default navigation clears its timeout and never runs fallback', async () => {
    const f = fixture()
    await f.loadEBook({ url: 'ebook://reader/a.epub' })
    assert.equal(count(f.readers[0], 'nextSection'), 0)
    assert.equal(f.timers.size, 0)
})

test('a current network error preserves the error and closes its resources', async () => {
    const f = fixture(), error = new Error('network unavailable')
    f.host.fetch = async () => { throw error }
    await assert.rejects(f.loadEBook({ url: 'https://books.invalid/a.epub' }), value => value === error)
    assert.equal(f.host.reader, null)
    assert.equal(f.host.manabiLoadEBookInFlight, false)
    assert.equal(f.warmers[0].closed, true)
    assert.deepEqual(f.ended, [1])
})

test('non-success HTTP response does not become a book source', async () => {
    const f = fixture(); let reads = 0
    f.host.fetch = async () => ({ ok: false, status: 403, blob: async () => { reads++; return 'html' } })
    await assert.rejects(f.loadEBook({ url: 'https://books.invalid/a.epub' }), /403/)
    assert.equal(reads, 0)
})

test('no URL finishes its foreground token and removes temporary resources', () => {
    const f = fixture()
    f.loadEBook({})
    assert.equal(f.host.manabiLoadEBookLastState, 'no-url')
    assert.equal(f.host.manabiLoadEBookInFlight, false)
    assert.equal(f.host.reader, null)
    assert.equal(f.host.cacheWarmer, null)
    assert.deepEqual(f.ended, [1])
})

test('invalid direct restore input does not revoke an already valid restore', async () => {
    const f = fixture(); await f.loadEBook(request())
    const gate = deferred(), reader = f.readers[0]
    reader.spec.goTo = () => gate.promise
    const pending = f.loadLastPosition({ cfi: 'valid' })
    await until(() => count(reader, 'goTo') === 2)
    for (const value of [NaN, Infinity, -1, 1.5, true, '0.5']) {
        await assert.rejects(f.loadLastPosition({ cfi: '', fractionalCompletion: value }), TypeError)
    }
    assert.equal(f.host.__manabiRestoreInProgress, true)
    gate.resolve()
    assert.equal((await pending).handledCFI, 'valid')
})

test('synthetic explicit non-applied result remains a failed restore', async () => {
    const f = fixture([syntheticSpec({ rendererGoTo: () => false })])
    await f.loadEBook(request('A', 'mnb-loc-v1:0:1:3', null))
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, false)
    assert.equal(count(f.readers[0], 'complete'), 0)
})

for (const [label, locator, sectionIndex, localPage, fraction] of [
    ['same-section page change', 'mnb-loc-v1:0:2:3', 0, 2, null],
    ['different section', 'mnb-loc-v1:2:1:3', 2, 1, 0.25],
    ['one-page section with CFI plus zero', 'mnb-loc-v1:0:0:1', 0, 0, 0],
]) {
    test(`synthetic ${label} reaches the selected renderer without a legacy Reader method`, async () => {
        const f = fixture([syntheticSpec({ pageCount: locator.endsWith(':1') ? 1 : 3 })])
        await f.loadEBook(request('synthetic', locator, fraction))
        const reader = f.readers[0]
        assert.equal(typeof reader.displayInitialSection, 'undefined')
        assert.deepEqual(reader.events.filter(event => event[0] === 'rendererGoTo'),
            [['rendererGoTo', { index: sectionIndex, localPage }]])
        assert.equal(count(reader, 'goToFraction'), 0)
        assert.equal(count(reader, 'goTo'), 0)
        const result = f.messages[0].initialRestoreResult
        assert.equal(result.restoreSatisfied, true)
        assert.equal(result.handledCFI, locator)
        assert.equal(count(reader, 'complete'), 1)
    })
}

test('dispatched synthetic navigation failure cannot authorize another fraction navigation', async () => {
    for (const outcome of [null, false, { ignored: true }, new Error('section unavailable')]) {
        const f = fixture([syntheticSpec({ rendererGoTo: () => {
            if (outcome instanceof Error) throw outcome
            return outcome
        }, fraction: () => ({ index: 0, anchor: 0.25 }) })])
        await f.loadEBook(request('fallback', 'mnb-loc-v1:8:1:3', 0.25))
        assert.equal(count(f.readers[0], 'rendererGoTo'), 1)
        assert.equal(count(f.readers[0], 'goToFraction'), 0)
        assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, false)
        assert.equal(f.messages[0].initialRestoreResult.handledCFI, null)
    }
})

for (const spec of [{ label: 'scrolled', scrolled: true }, { label: 'unsupported mode', rendererName: 'foliate-fxl' },
    { label: 'unavailable API', configureView: view => { delete view.renderer.goTo } }]) {
    test(`synthetic position with ${spec.label} uses a positive fraction without local-page navigation`, async () => {
        const f = fixture([syntheticSpec(spec)])
        await f.loadEBook(request('mode-fallback', 'mnb-loc-v1:0:2:3', 0.25))
        assert.equal(count(f.readers[0], 'rendererGoTo'), 0)
        assert.equal(count(f.readers[0], 'goToFraction'), 1)
        assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, true)
        assert.equal(f.messages[0].initialRestoreResult.handledCFI, null)
    })
}

test('synthetic missing-fraction and CFI-plus-zero requests cannot invent a fraction fallback', async () => {
    for (const fraction of [null, 0]) {
        for (const spec of [{ rendererGoTo: () => null }, { scrolled: true }, { rendererName: 'foliate-fxl' }]) {
            const f = fixture([syntheticSpec(spec)])
            await f.loadEBook(request('no-fallback', 'mnb-loc-v1:0:1:3', fraction))
            assert.equal(count(f.readers[0], 'goToFraction'), 0)
            assert.equal(count(f.readers[0], 'complete'), 0)
            assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, false)
            assert.equal(f.messages[0].initialRestoreResult.handledCFI, null)
        }
    }
})

test('accepted synthetic navigation with a mismatched measured fraction stays failed without fallback', async () => {
    const f = fixture([syntheticSpec({ landing: 0.75 })])
    await f.loadEBook(request('wrong-landing', 'mnb-loc-v1:0:1:3', 0.25))
    assert.equal(count(f.readers[0], 'rendererGoTo'), 1)
    assert.equal(count(f.readers[0], 'goToFraction'), 0)
    assert.equal(count(f.readers[0], 'complete'), 0)
    assert.equal(f.messages[0].initialRestoreResult.navigationOk, true)
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, false)
})

test('synthetic fraction fallback rejection or wrong landing cannot enable persistence', async () => {
    for (const spec of [{ fraction: () => null }, { landing: 0.75 }]) {
        const f = fixture([syntheticSpec({ scrolled: true, ...spec })])
        await f.loadEBook(request('failed-fallback', 'mnb-loc-v1:0:1:3', 0.25))
        assert.equal(count(f.readers[0], 'goToFraction'), 1)
        assert.equal(count(f.readers[0], 'complete'), 0)
        assert.equal(f.messages[0].initialRestoreResult.handledCFI, null)
        assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, false)
    }
})

test('a replaced synthetic operation cannot fallback or publish after its old renderer rejects', async () => {
    const gate = deferred(), f = fixture([syntheticSpec({ rendererGoTo: () => gate.promise }), {}])
    const old = f.loadEBook(request('old-synthetic', 'mnb-loc-v1:0:1:3', 0.25))
    await until(() => count(f.readers[0], 'rendererGoTo') === 1)
    await f.loadEBook(request('current-cfi'))
    await old
    gate.reject(new Error('retired renderer failure'))
    await until(() => f.timers.size === 0)
    assert.equal(count(f.readers[0], 'goToFraction'), 0)
    assert.equal(count(f.readers[0], 'complete'), 0)
    assert.deepEqual(f.messages.map(value => value.initialRestoreResult.requestID), ['current-cfi'])
})

test('closing a synthetic restore cancels its fallback and terminal publication', async () => {
    const gate = deferred(), f = fixture([syntheticSpec({ rendererGoTo: () => gate.promise })])
    const pending = f.loadEBook(request('closed-synthetic', 'mnb-loc-v1:0:1:3', 0.25))
    await until(() => count(f.readers[0], 'rendererGoTo') === 1)
    f.readers[0].close('closed while restoring')
    await pending
    gate.reject(new Error('late failure'))
    assert.equal(count(f.readers[0], 'goToFraction'), 0)
    assert.equal(f.messages.length, 0)
    assert.equal(f.host.__manabiRestoreInProgress, false)
})

test('a failed synthetic restore can retry through a fresh selected renderer', async () => {
    const f = fixture([syntheticSpec({ rendererGoTo: () => false }), syntheticSpec()])
    const args = request('retry-synthetic', 'mnb-loc-v1:0:1:3', 0.25)
    await f.loadEBook(args)
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, false)
    await f.loadEBook(args)
    assert.equal(f.readers.length, 2)
    assert.equal(f.readers[0].isClosed, true)
    assert.equal(f.messages[1].initialRestoreResult.restoreSatisfied, true)
    assert.equal(f.messages[1].initialRestoreResult.handledCFI, args.initialRestore.cfi)
})

test('ordinary CFI navigation failure keeps its existing behavior despite a positive fraction', async () => {
    const f = fixture([{ goTo: () => { throw new Error('invalid CFI') } }])
    await f.loadEBook(request())
    assert.equal(count(f.readers[0], 'goToFraction'), 0)
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, false)
})

test('reconciliation must acknowledge navigation instead of ignoring rejection', async () => {
    const f = fixture([{ landing: 0.1, fraction: () => null }])
    await f.loadEBook(request())
    assert.equal(f.messages[0].initialRestoreResult.navigationOk, false)
    assert.equal(count(f.readers[0], 'goToFraction'), 1)
    assert.equal(count(f.readers[0], 'complete'), 0)
})

test('stalled frame scheduler uses its bounded fallback then removes both handles', async () => {
    const f = fixture(); f.host.pauseFrames = true
    const pending = f.loadEBook(request())
    for (let i = 0; i < 2; i++) {
        await until(() => f.timers.size > 0)
        const timer = [...f.timers.values()][0]
        assert.equal(timer.milliseconds, 250)
        timer.callback()
    }
    await pending
    assert.equal(f.timers.size, 0)
    assert.equal(f.frames.size, 0)
    assert.equal(f.messages.length, 1)
})

test('reentrant probe replacement cannot post the old native completion', async () => {
    let second
    const f = fixture([{ probe: () => { second = f.loadEBook(request('B')) } }])
    await f.loadEBook(request())
    await second
    assert.deepEqual(f.messages.map(m => m.initialRestoreResult.requestID), ['B'])
})

test('reentrant completion cannot run lookup and readiness effects for a successor', async () => {
    let second
    const f = fixture([{ complete: () => { second = f.loadEBook(request('B')) } }])
    await f.loadEBook(request()); await second
    assert.equal(count(f.readers[0], 'lookup'), 0)
    assert.deepEqual(f.messages.map(m => m.initialRestoreResult.requestID), ['B'])
})

test('missing renderer is an error, not an acknowledged book open', async () => {
    const f = fixture([{ missingRenderer: true }])
    await assert.rejects(f.loadEBook(request()), /missing-renderer/)
    assert.equal(f.messages.length, 0)
    assert.equal(f.host.manabiLoadEBookReady, false)
})

test('closed ready reader cannot be reused, and release remains idempotent', async () => {
    const f = fixture(); await f.loadEBook(request())
    f.readers[0].close('test'); f.readers[0].close('test-again')
    assert.deepEqual(f.ended, [1])
    await f.loadEBook(request())
    assert.equal(f.readers.length, 2)
})

test('absent layout for a new book cannot inherit an old flow request', async () => {
    const f = fixture(); await f.loadEBook({ ...request(), layoutMode: 'paginated' })
    await f.loadEBook(request('B'))
    assert.equal(f.host.initialLayoutMode, undefined)
})

test('out-of-order intent completions neither clear newer work nor resurrect completed work', async () => {
    const host = {}, run = createNavigationIntentRunner(host), a = deferred(), b = deferred()
    const first = run({ source: 'A' }, () => a.promise)
    const second = run({ source: 'B' }, () => b.promise)
    a.resolve(); await first
    assert.equal(host.__manabiNavigationIntent?.source, 'B')
    b.resolve(); await second
    assert.equal(host.__manabiNavigationIntent, null)
})

test('nested current intent restores an actually pending predecessor', async () => {
    const host = {}, run = createNavigationIntentRunner(host), a = deferred()
    const first = run({ source: 'A' }, () => a.promise)
    await run({ source: 'B' }, async () => {})
    assert.equal(host.__manabiNavigationIntent.source, 'A')
    a.resolve(); await first
    assert.equal(host.__manabiNavigationIntent, null)
})

test('external intent replacement is not undone by an old finally', async () => {
    const host = {}, run = createNavigationIntentRunner(host), gate = deferred()
    const pending = run({ source: 'old' }, () => gate.promise)
    const external = { source: 'other owner' }; host.__manabiNavigationIntent = external
    gate.resolve(); await pending
    assert.equal(host.__manabiNavigationIntent, external)
})

test('replacement reentered during Reader construction cannot install the earlier candidate', async () => {
    let second
    const f = fixture([{ construct: () => { second = f.loadEBook(request('B')) } }])
    const first = f.loadEBook(request())
    await Promise.all([first, second])
    assert.equal(f.host.reader, f.readers[1])
    assert.equal(f.readers[0].isClosed, true)
    assert.deepEqual(f.messages.map(m => m.initialRestoreResult.requestID), ['B'])
})

test('replacement during cache-generation setup cannot resume the revoked setup', async () => {
    let firstCall = true, second
    const f = fixture([], { generation: () => {
        if (firstCall) { firstCall = false; second = f.loadEBook(request('B')) }
    } })
    await f.loadEBook(request()); await second
    assert.equal(f.readers.length, 1)
    assert.deepEqual(f.messages.map(m => m.initialRestoreResult.requestID), ['B'])
})

test('a newer request issued during foreground release outranks the calling replacement', async () => {
    let replacement, didReplace = false
    const f = fixture([], { finishForeground: () => {
        if (!didReplace) { didReplace = true; replacement = f.loadEBook(request('C')) }
    } })
    await f.loadEBook(request())
    await f.loadEBook(request('B')); await replacement
    assert.deepEqual(f.messages.map(m => m.initialRestoreResult.requestID), ['A', 'C'])
    assert.equal(f.host.manabiInitialRestoreResult.requestID, 'C')
})


test('wrong landing never unlocks saving or runs successful restoration effects', async () => {
    const f = fixture([{ landing: 0.1 }])
    await f.loadEBook(request())
    const result = f.messages[0].initialRestoreResult
    assert.equal(result.terminalState, 'failed')
    assert.equal(result.navigationOk, true)
    assert.equal(result.currentFractionalCompletion, 0.1)
    assert.equal(count(f.readers[0], 'complete'), 0)
    assert.equal(f.readers[0].hasLoadedLastPosition, false)
    assert.equal(count(f.readers[0], 'attempt'), 1)
    assert.deepEqual(f.effects, [])
    assert.equal(f.host.manabiLoadEBookReady, false)
    assert.equal(f.host.__manabiRestoreInProgress, false)
    assert.deepEqual(f.ended, [1])
})

test('an identical request retries a failed landing instead of reporting duplicate-ready', async () => {
    const f = fixture([{ landing: 0.1 }, { landing: 0.25 }])
    await f.loadEBook(request())
    await f.loadEBook(request())
    assert.equal(f.readers.length, 2)
    assert.deepEqual(f.messages.map(value => value.initialRestoreResult.terminalState), ['failed', 'satisfied'])
    assert.equal(f.readers[0].isClosed, true)
    assert.equal(f.readers[1].hasLoadedLastPosition, true)
    assert.deepEqual(f.ended, [1])
})

test('a direct failed restore rejects without claiming completion on the existing reader', async () => {
    const f = fixture(); await f.loadEBook(request())
    const reader = f.readers[0]
    reader.view.lastLocation.fraction = 0.1
    await assert.rejects(f.loadLastPosition({ cfi: 'new-cfi', fractionalCompletion: 0.8 }), error => {
        assert.equal(error.name, 'EbookRestoreValidationError')
        assert.equal(error.snapshot.currentFractionalCompletion, 0.1)
        return true
    })
    assert.equal(reader.hasLoadedLastPosition, false)
    assert.equal(count(reader, 'complete'), 1)
    assert.equal(count(reader, 'attempt'), 1)
    assert.deepEqual(f.effects, ['ready', 'probe', 'warm'])
})

test('a direct retry closes the previous success gate before awaiting navigation', async () => {
    const f = fixture(); await f.loadEBook(request())
    const reader = f.readers[0], gate = deferred()
    reader.spec.goTo = () => gate.promise
    const pending = f.loadLastPosition({ cfi: 'again' })
    await until(() => count(reader, 'goTo') === 2)
    assert.equal(reader.hasLoadedLastPosition, false)
    assert.equal(f.host.__manabiRestoreInProgress, true)
    gate.resolve(); await pending
    assert.equal(reader.hasLoadedLastPosition, true)
})

test('frame settling drift is checked before marking the reader restored', async () => {
    const f = fixture(); f.host.pauseFrames = true
    const pending = f.loadEBook(request())
    await until(() => f.frames.size === 1)
    f.readers[0].view.lastLocation.fraction = 0.9
    for (let index = 0; index < 4; index++) {
        await until(() => f.timers.size > 0)
        ;[...f.timers.values()][0].callback()
    }
    await pending
    assert.equal(count(f.readers[0], 'complete'), 0)
    assert.equal(f.messages[0].initialRestoreResult.navigationOk, true)
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, false)
})

test('malformed load requests cannot replace a ready reader or its published receipt', async () => {
    const f = fixture(); await f.loadEBook(request())
    const reader = f.host.reader, receipt = f.host.manabiInitialRestoreResult
    for (const initialRestore of [[], 'request', {}, { requestID: 'B' },
        { requestID: 'B', cfi: 4 }, { requestID: 'B', cfi: 'valid', fractionalCompletion: Infinity },
        { requestID: 'B', cfi: 'valid', fractionalCompletion: true }]) {
        await assert.rejects(Promise.resolve().then(() => f.loadEBook({ ...request(), initialRestore })), TypeError)
        assert.equal(f.host.reader, reader)
        assert.equal(f.host.manabiInitialRestoreResult, receipt)
        assert.equal(reader.isClosed, false)
    }
    assert.equal(f.readers.length, 1)
})

test('a malformed initial request cannot revoke a valid in-flight restore', async () => {
    const gate = deferred(), f = fixture([{ goTo: () => gate.promise }])
    const pending = f.loadEBook(request())
    await until(() => count(f.readers[0], 'goTo') === 1)
    await assert.rejects(Promise.resolve().then(() => f.loadEBook({
        ...request(), initialRestore: { requestID: 'bad', cfi: '', fractionalCompletion: -1 },
    })), TypeError)
    assert.equal(f.host.manabiLoadEBookPromise, pending)
    assert.equal(f.host.__manabiRestoreInProgress, true)
    assert.equal(f.readers[0].isClosed, false)
    gate.resolve(); await pending
    assert.deepEqual(f.messages.map(value => value.initialRestoreResult.requestID), ['A'])
})

test('an explicit zero-position request navigates to zero rather than the default next page', async () => {
    const f = fixture([{ landing: 0 }])
    await f.loadEBook(request('zero', '', 0))
    assert.equal(count(f.readers[0], 'goToFraction'), 1)
    assert.equal(count(f.readers[0], 'next'), 0)
    assert.equal(f.messages[0].initialRestoreResult.requestID, 'zero')
    assert.equal(f.messages[0].initialRestoreResult.terminalState, 'satisfied')
    assert.equal(f.messages[0].initialRestoreResult.currentFractionalCompletion, 0)
})

test('a direct zero restore is distinct from absent position information', async () => {
    const f = fixture([{ landing: 0 }]); await f.loadEBook({ url: 'ebook://reader/a.epub' })
    const reader = f.readers[0]
    assert.equal(count(reader, 'next'), 1)
    await f.loadLastPosition({ cfi: '', fractionalCompletion: 0 })
    assert.equal(count(reader, 'next'), 1)
    assert.equal(count(reader, 'goToFraction'), 1)
})

test('wrong landing from an explicit zero request is still a failed restore', async () => {
    const f = fixture([{ landing: 0.25 }])
    await f.loadEBook(request('zero', '', 0))
    assert.equal(f.messages[0].initialRestoreResult.terminalState, 'failed')
    assert.equal(f.messages[0].initialRestoreResult.requestID, 'zero')
    assert.equal(count(f.readers[0], 'complete'), 0)
})

test('an explicit non-applied default fallback cannot enable position saving', async () => {
    const f = fixture([{ next: () => false, nextSection: () => ({ ignored: true }) }])
    await f.loadEBook({ url: 'ebook://reader/a.epub' })
    assert.equal(count(f.readers[0], 'nextSection'), 1)
    assert.equal(count(f.readers[0], 'complete'), 0)
    assert.equal(f.messages[0].initialRestoreResult.navigationOk, false)
    assert.equal(f.host.manabiLoadEBookReady, false)
    assert.deepEqual(f.ended, [1])
})

test('a validated fraction reconciliation still completes normally', async () => {
    const f = fixture([{ landing: 0.1, fraction: (reader, value) => {
        reader.view.lastLocation.fraction = value
    } }])
    await f.loadEBook(request())
    assert.equal(count(f.readers[0], 'goToFraction'), 1)
    assert.equal(count(f.readers[0], 'complete'), 1)
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, true)
    assert.deepEqual(f.effects, ['ready', 'probe', 'warm'])
})

test('failure publication cannot release a reentrantly opened successor foreground token', async () => {
    let second
    const f = fixture([{ landing: 0.1 }])
    const post = f.host.webkit.messageHandlers.ebookViewerLoaded.postMessage
    f.host.webkit.messageHandlers.ebookViewerLoaded.postMessage = message => {
        post(message)
        if (message.initialRestoreResult.terminalState === 'failed') second = f.loadEBook(request('B'))
    }
    await f.loadEBook(request()); await second
    assert.equal(f.host.manabiInitialRestoreResult.requestID, 'B')
    assert.equal(f.host.manabiLoadEBookReady, true)
    assert.deepEqual(f.ended, [1])
})


test('direct restoration supersedes the initial request identity for later deduplication', async () => {
    const f = fixture(); await f.loadEBook(request())
    await f.loadLastPosition({ cfi: 'direct-location' })
    await f.loadEBook(request())
    assert.equal(f.readers.length, 2)
    assert.equal(f.messages.length, 2)
    assert.equal(f.readers[0].isClosed, true)
})

test('renderer replacement revokes navigation but still clears only the old attempt flags', async () => {
    const f = fixture(); await f.loadEBook(request())
    const gate = deferred(), reader = f.readers[0]
    reader.spec.goTo = () => gate.promise
    const pending = f.loadLastPosition({ cfi: 'again' })
    const rejected = assert.rejects(pending, EbookLoadSupersededError)
    await until(() => count(reader, 'goTo') === 2)
    reader.view.renderer = {}
    gate.resolve(); await rejected
    assert.equal(f.host.__manabiRestoreInProgress, false)
    assert.equal(reader.hasLoadedLastPosition, false)
    assert.equal(count(reader, 'complete'), 1)
})

test('new restore flags survive completion from a superseded renderer on the same reader', async () => {
    const f = fixture(); await f.loadEBook(request())
    const a = deferred(), b = deferred(), reader = f.readers[0]
    reader.spec.goTo = () => a.promise
    const old = f.loadLastPosition({ cfi: 'old' })
    const rejected = assert.rejects(old, EbookLoadSupersededError)
    await until(() => count(reader, 'goTo') === 2)
    reader.view.renderer = {}
    reader.spec.goTo = () => b.promise
    const next = f.loadLastPosition({ cfi: 'new' })
    await until(() => count(reader, 'goTo') === 3)
    a.resolve(); await rejected
    assert.equal(f.host.__manabiRestoreInProgress, true)
    b.resolve(); await next
    assert.equal(f.host.__manabiRestoreInProgress, false)
    assert.equal(reader.hasLoadedLastPosition, true)
})


test('top-level load identity distinguishes absent requests and echoes every terminal', async () => {
    const f = fixture()
    const args = { url: 'ebook://reader/book.epub', loadRequestID: 'absent-A' }
    await f.loadEBook(args)
    await f.loadEBook({ ...args, loadRequestID: 'absent-B' })
    assert.equal(f.readers.length, 2)
    assert.deepEqual(f.messages.map(m => m.initialRestoreResult.loadRequestID), ['absent-A', 'absent-B'])
    assert.ok(f.messages.every(m => m.initialRestoreResult.terminalState === 'noTarget'))
})

test('mismatched or malformed load identity cannot retire a valid request', async () => {
    const f = fixture()
    await f.loadEBook({ ...request(), loadRequestID: 'A' })
    for (const loadRequestID of ['B', '', 42, true]) {
        await assert.rejects(f.loadEBook({ ...request(), loadRequestID }), TypeError)
    }
    assert.equal(f.readers.length, 1)
    assert.equal(f.readers[0].isClosed, false)
})


const paginatedZeroSpec = overrides => {
    const progress = new SectionProgress([{ size: 100 }, { size: 100 }], 10, 10)
    const location = buildRelocateLocation({ index: 0, fraction: 0, size: 0.25 }, {
        sectionCount: 2, sectionProgress: progress,
    })
    const receipt = Object.freeze({ index: 0, anchor: 0 })
    let current = true
    const proof = Object.freeze({ positionMode: 'paginated',
        currentFractionalCompletion: location.fraction, handledFractionalCompletion: location.fraction,
        firstPageGeometry: Object.freeze({ kind: 'paginated-first-page-v1', targetSectionIndex: 0,
            targetAnchor: 0, ...location.firstPageGeometrySource }),
    })
    return {
        fraction: () => receipt,
        configureView(view, reader) {
            view.renderer.localName = 'foliate-paginator'
            view.renderer.scrolled = false
            view.lastLocation = location
            view.capturePositionProof = value => current && value === receipt ? proof : null
            view.isPositionProofCurrent = value => current && value === proof && view.lastLocation === location
                && !view.renderer.scrolled
            reader.retirePosition = () => { current = false }
        },
        ...overrides,
    }
}

test('production progress flows through owned zero restore without substituting requested zero', async () => {
    const f = fixture([paginatedZeroSpec()])
    await f.loadEBook({ ...request('zero', '', 0), loadRequestID: 'zero' })
    const result = f.messages[0].initialRestoreResult
    assert.equal(result.restoreSatisfied, true)
    assert.equal(result.positionMode, 'paginated')
    assert.equal(result.handledFractionalCompletion, 0.125)
    assert.equal(result.currentFractionalCompletion, 0.125)
    assert.equal(count(f.readers[0], 'complete'), 1)
    assert.equal(f.host.__manabiRestoreInProgress, false)
})

test('direct motion before settled proof cannot complete a zero restore', async () => {
    const f = fixture([paginatedZeroSpec()])
    f.host.pauseFrames = true
    const load = f.loadEBook(request('zero', '', 0))
    await until(() => f.frames.size > 0)
    f.readers[0].retirePosition()
    f.host.pauseFrames = false
    for (const [id, callback] of f.frames) { f.frames.delete(id); callback() }
    await load
    assert.equal(count(f.readers[0], 'complete'), 0)
    assert.equal(f.host.manabiLoadEBookReady, false)
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, false)
})

test('completion and outer probe keep persistence suppressed across synchronous position replacement', async () => {
    for (const stage of ['complete', 'probe']) {
        let f
        let saves = 0
        const mutate = reader => {
            // Same gate used by the real relocate persistence path.
            if (reader.hasLoadedLastPosition && !f.host.__manabiRestoreInProgress) saves++
            reader.retirePosition()
        }
        const spec = paginatedZeroSpec(stage === 'complete'
            ? { complete: reader => mutate(reader) }
            : { probe: () => mutate(f.readers[0]) })
        f = fixture([spec])
        await f.loadEBook(request('zero', '', 0))
        assert.equal(saves, 0)
        assert.equal(f.readers[0].hasLoadedLastPosition, false)
        assert.equal(f.host.manabiLoadEBookReady, false)
        assert.equal(f.messages.length, 0)
        assert.equal(f.host.__manabiRestoreInProgress, false)
        assert.deepEqual(f.ended, [1])
    }
})


test('zero scrolled completion cannot publish after a callback changes actual mode or snapshot', async () => {
    for (const stage of ['complete', 'probe']) for (const mutation of ['mode', 'snapshot']) {
        let f
        const mutate = () => {
            const view = f.readers[0].view
            if (mutation === 'mode') view.renderer.scrolled = false
            else view.lastLocation = { fraction: 0 }
        }
        f = fixture([{
            landing: 0,
            configureView(view) { view.renderer.localName = 'foliate-paginator'; view.renderer.scrolled = true },
            ...(stage === 'complete' ? { complete: mutate } : { probe: mutate }),
        }])
        await f.loadEBook(request('zero', '', 0))
        assert.equal(f.messages.length, 0)
        assert.equal(f.host.manabiLoadEBookReady, false)
        assert.equal(f.readers[0].hasLoadedLastPosition, false)
        assert.equal(f.host.__manabiRestoreInProgress, false)
    }
})

// The production load coordinator and View run together. The first three
// regressions preserve the independent finding's original failing probes.
// Only the browser host and renderer are controlled; SectionProgress supplies
// actual fraction mapping. No iframe, CSS layout or native execution is claimed.
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

test('review: CFI reconciliation cannot navigate over a newer completed manual command', async () => {
    const f = reviewNavigationFixture()
    f.host.pauseFrames = true
    const load = f.loadEBook(request('restore', 'epubcfi(/6/2)', 0.25))
    await until(() => f.frames.size === 1)
    const view = f.readers[0].view
    await manualFraction(f, 0.8)
    assert.equal(view.lastLocation.fraction, 0.8)
    f.host.pauseFrames = false
    for (const [id, callback] of f.frames) { f.frames.delete(id); callback() }
    await load
    assert.equal(view.lastLocation.fraction, 0.8, 'the newer manual navigation owns the current page')
    assert.equal(f.rendererCalls.length, 2, 'an obsolete restore cannot dispatch drift reconciliation')
    assert.equal(f.messages.some(message => message.initialRestoreResult.restoreSatisfied), false)
})

test('review: CFI-only completion cannot credit a position replaced before frame settlement', async () => {
    const f = reviewNavigationFixture()
    f.host.pauseFrames = true
    const load = f.loadEBook(request('restore', 'epubcfi(/6/2)', null))
    await until(() => f.frames.size === 1)
    const view = f.readers[0].view
    await manualFraction(f, 0.8)
    f.host.pauseFrames = false
    for (const [id, callback] of f.frames) { f.frames.delete(id); callback() }
    await load
    assert.equal(view.lastLocation.fraction, 0.8)
    assert.equal(f.messages.some(message => message.initialRestoreResult.restoreSatisfied), false,
        'the original CFI cannot be reported satisfied after newer navigation took ownership')
    assert.equal(f.readers[0].hasLoadedLastPosition, true,
        'the accepted manual command enables reading without crediting the interrupted CFI')
})

test('review: current CFI drift still reconciles without a newer navigation command', async () => {
    const f = reviewNavigationFixture({ cfiAnchor: 0.2 })
    await f.loadEBook(request('restore', 'epubcfi(/6/2)', 0.25))
    assert.equal(f.readers[0].view.lastLocation.fraction, 0.25)
    assert.equal(f.rendererCalls.length, 2)
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, true)
    assert.equal(f.readers[0].hasLoadedLastPosition, true)
})

const settleReviewFrames = f => {
    f.host.pauseFrames = false
    for (const [id, callback] of f.frames) { f.frames.delete(id); callback() }
}

for (const { label, cfi, fraction, target } of [
    { label: 'fraction', cfi: '', fraction: 0.25, target: { index: 0, anchor: 0.5 } },
    { label: 'synthetic', cfi: 'mnb-loc-v1:0:1:3', fraction: null, target: { index: 0, localPage: 1 } },
]) {
    test(`actual View: a newer command retires ${label} restore frame settlement`, async () => {
        const f = reviewNavigationFixture()
        f.host.pauseFrames = true
        const load = f.loadEBook(request('restore', cfi, fraction))
        await until(() => f.frames.size === 1)
        const view = f.readers[0].view
        assert.deepEqual(f.rendererCalls[0], target)
        await view.goToFraction(0.8)
        settleReviewFrames(f)
        await load
        assert.equal(view.lastLocation.fraction, 0.8)
        assert.equal(f.rendererCalls.length, 2)
        assert.equal(f.messages.length, 0)
        assert.equal(f.readers[0].hasLoadedLastPosition, false)
        assert.equal(f.host.__manabiRestoreInProgress, false)
        if (label === 'synthetic') {
            assert.equal(view.history.canGoBack, false, 'synthetic local-page restore does not add a history entry')
        }
    })
}

for (const newerCommand of ['invalid section', 'renderer rejection']) {
    test(`actual View: ${newerCommand} retires the old receipt and permits an explicit same-View retry`, async () => {
        const f = reviewNavigationFixture({ rendererGoTo: ({ target, publish }) =>
            target.index === 1 ? false : publish() })
        f.host.pauseFrames = true
        const load = f.loadEBook(request('restore', 'epubcfi(/6/2)', null))
        await until(() => f.frames.size === 1)
        const view = f.readers[0].view
        const result = newerCommand === 'invalid section'
            ? await view.goTo(-1) : await view.goToFraction(0.8)
        assert.equal(result, null)
        settleReviewFrames(f)
        await load
        assert.equal(view.lastLocation.fraction, 0.25, 'rejected newer commands need not move to retire the prior command')
        assert.equal(f.messages.length, 0)
        assert.equal(count(f.readers[0], 'complete'), 0)
        const retried = await f.loadLastPosition({ cfi: 'epubcfi(/6/2)' })
        assert.equal(retried.handledCFI, 'epubcfi(/6/2)')
        assert.equal(f.readers[0].view, view)
        assert.equal(f.readers[0].hasLoadedLastPosition, true)
        assert.equal(count(f.readers[0], 'complete'), 1)
        assert.equal(f.host.__manabiRestoreInProgress, false)
    })
}

test('actual View: malformed fraction input preserves the current accepted command', async () => {
    const f = reviewNavigationFixture()
    f.host.pauseFrames = true
    const load = f.loadEBook(request('restore', 'epubcfi(/6/2)', null))
    await until(() => f.frames.size === 1)
    assert.equal(await f.readers[0].view.goToFraction(NaN), null)
    settleReviewFrames(f)
    await load
    assert.equal(f.rendererCalls.length, 1)
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, true)
})

test('actual View: replacing the book on the same renderer retires the restore receipt', async () => {
    const f = reviewNavigationFixture()
    f.host.pauseFrames = true
    const load = f.loadEBook(request('restore', 'epubcfi(/6/2)', null))
    await until(() => f.frames.size === 1)
    const view = f.readers[0].view
    view.book = { ...view.book }
    settleReviewFrames(f)
    await load
    assert.equal(f.messages.length, 0)
    assert.equal(count(f.readers[0], 'complete'), 0)
    assert.equal(f.host.__manabiRestoreInProgress, false)
})

for (const stage of ['complete', 'probe']) {
    test(`actual View: ${stage} callback navigation revokes completion and terminal publication`, async () => {
        let f, manual
        let saves = 0
        const navigate = () => {
            const reader = f.readers[0]
            if (reader.hasLoadedLastPosition && !f.host.__manabiRestoreInProgress) saves++
            manual = reader.view.goToFraction(0.8)
        }
        f = reviewNavigationFixture({ specs: [stage === 'complete'
            ? { complete: navigate } : { probe: navigate }] })
        await f.loadEBook(request('restore', 'epubcfi(/6/2)', null))
        await manual
        assert.equal(f.readers[0].view.lastLocation.fraction, 0.8)
        assert.equal(saves, 0, 'position saving remains suppressed until terminal publication is admitted')
        assert.equal(f.messages.length, 0)
        assert.equal(f.readers[0].hasLoadedLastPosition, false)
        assert.equal(f.host.manabiLoadEBookReady, false)
        assert.equal(f.host.__manabiRestoreInProgress, false)
        if (stage === 'complete') assert.equal(count(f.readers[0], 'lookup'), 0)
    })
}

test('actual View: navigation during reconciliation intent publication wins before old dispatch', async () => {
    const f = reviewNavigationFixture({ cfiAnchor: 0.2 })
    let intent = null, manual
    Object.defineProperty(f.host, '__manabiNavigationIntent', {
        get: () => intent,
        set(value) {
            intent = value
            if (value?.source === 'restore.reconcile') manual = f.readers[0].view.goToFraction(0.8)
        },
    })
    await f.loadEBook(request('restore', 'epubcfi(/6/2)', 0.25))
    await manual
    assert.equal(f.readers[0].view.lastLocation.fraction, 0.8)
    assert.equal(f.rendererCalls.length, 2, 'the retired reconciliation never reaches the renderer')
    assert.equal(f.messages.length, 0)
    assert.equal(count(f.readers[0], 'complete'), 0)
})

test('actual View: a newer probe command suppresses a measured-failure terminal too', async () => {
    let f, manual
    let rejectLanding = true
    f = reviewNavigationFixture({
        rendererGoTo: ({ target, publish }) => {
            if (target.index === 1 && rejectLanding) { rejectLanding = false; return }
            return publish()
        },
        specs: [{ probe: () => { manual = f.readers[0].view.goToFraction(0.8) } }],
    })
    await f.loadEBook(request('restore', 'epubcfi(/6/2)', 0.75))
    await manual
    assert.equal(f.readers[0].view.lastLocation.fraction, 0.8)
    assert.equal(count(f.readers[0], 'attempt'), 1)
    assert.equal(count(f.readers[0], 'complete'), 0)
    assert.equal(f.messages.length, 0)
    assert.equal(f.host.manabiLoadEBookReady, false)
    assert.equal(f.host.__manabiRestoreInProgress, false)
})

test('actual View: renderer rejection keeps failure reporting and a fresh load can retry', async () => {
    const f = reviewNavigationFixture({ specs: [{ rendererGoTo: () => false }, {}] })
    const args = request('restore', 'epubcfi(/6/2)', null)
    await f.loadEBook(args)
    assert.equal(f.messages[0].initialRestoreResult.navigationOk, false)
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, false)
    assert.equal(count(f.readers[0], 'complete'), 0)
    await f.loadEBook(args)
    assert.equal(f.readers.length, 2)
    assert.equal(f.readers[0].isClosed, true)
    assert.equal(f.messages[1].initialRestoreResult.restoreSatisfied, true)
    assert.equal(f.readers[1].hasLoadedLastPosition, true)
})

test('actual View: closing a pending command rejects its late completion authority', async () => {
    const gate = deferred()
    let rendererResult
    const f = reviewNavigationFixture({ rendererGoTo: ({ publish }) => {
        rendererResult = gate.promise.then(publish)
        return rendererResult
    } })
    const load = f.loadEBook(request('restore', 'epubcfi(/6/2)', null))
    await until(() => f.rendererCalls.length === 1)
    f.readers[0].close('cancelled during renderer navigation')
    await load
    gate.resolve()
    await rendererResult
    assert.equal(f.messages.length, 0)
    assert.equal(count(f.readers[0], 'complete'), 0)
    assert.equal(f.timers.size, 0)
    assert.equal(f.frames.size, 0)
    assert.equal(f.host.__manabiRestoreInProgress, false)
})

test('actual View: fresh command receipts cannot re-authorize a reused resolver object', async () => {
    const f = reviewNavigationFixture()
    await f.loadEBook(request('restore', 'epubcfi(/6/2)', null))
    const view = f.readers[0].view
    const sharedTarget = { index: 0, anchor: 0.5 }
    view.book.resolveCFI = () => sharedTarget
    const first = await view.goTo('epubcfi(/6/2)', { requiresNavigationReceipt: true })
    const second = await view.goTo('epubcfi(/6/2)', { requiresNavigationReceipt: true })
    assert.notEqual(first, second)
    assert.equal(view.isNavigationReceiptCurrent(first), false)
    assert.equal(view.isNavigationReceiptCurrent(second), true)
    assert.equal(view.isNavigationReceiptCurrent({ ...second }), false)
    assert.equal(await view.goTo('epubcfi(/6/2)'), sharedTarget,
        'ordinary goTo preserves its selected resolved-target return contract')
    assert.equal(view.isNavigationReceiptCurrent(second), false)
})

const correlatedRequest = (id, cfi = 'epubcfi(/6/2)', fraction = 0.25) => ({
    ...request(id, cfi, fraction), loadRequestID: id,
})

test('manual handoff: accepted replacement enables subsequent progress without publishing the old location', async () => {
    const f = reviewNavigationFixture()
    f.host.pauseFrames = true
    const load = f.loadEBook(correlatedRequest('saved'))
    await until(() => f.frames.size === 1)
    assert.equal(f.publishProgress(0.25), false)
    const receipt = await manualFraction(f, 0.8)
    settleReviewFrames(f)
    await load
    const view = f.readers[0].view
    assert.equal(view.isNavigationReceiptCurrent(receipt), true)
    assert.equal(view.lastLocation.fraction, 0.8)
    assert.equal(f.rendererCalls.length, 2)
    assert.equal(f.readers[0].hasLoadedLastPosition, true)
    assert.equal(f.host.manabiLoadEBookReady, true)
    assert.equal(f.host.__manabiRestoreInProgress, false)
    assert.equal(f.messages.length, 1)
    const terminal = f.messages[0].initialRestoreResult
    assert.equal(terminal.loadRequestID, 'saved')
    assert.equal(terminal.requestID, 'saved')
    assert.equal(terminal.requestedLocator, 'cfi')
    assert.equal(terminal.terminalState, 'failed')
    assert.equal(terminal.navigationOk, false)
    assert.equal(terminal.restoreSatisfied, false)
    assert.equal(terminal.handledCFI, null)
    assert.equal(terminal.handledFractionalCompletion, null)
    assert.equal(terminal.currentFractionalCompletion, null)
    assert.equal(f.publishProgress(view.lastLocation.fraction), true)
    await view.goToFraction(0.85)
    assert.equal(f.publishProgress(view.lastLocation.fraction), true)
    assert.deepEqual(f.progressMessages, [{ fraction: 0.8, reason: 'page' }, { fraction: 0.85, reason: 'page' }])
})

test('manual handoff: a pending renderer command cannot grant progress before acceptance', async () => {
    const gate = deferred()
    const f = reviewNavigationFixture({ rendererGoTo: ({ target, publish }) =>
        target.index === 1 ? gate.promise.then(publish) : publish() })
    f.host.pauseFrames = true
    const load = f.loadEBook(correlatedRequest('saved', 'epubcfi(/6/2)', null))
    await until(() => f.frames.size === 1)
    const manual = manualFraction(f, 0.8)
    await until(() => f.rendererCalls.length === 2)
    settleReviewFrames(f)
    await load
    assert.equal(f.readers[0].hasLoadedLastPosition, false)
    assert.equal(f.host.manabiLoadEBookReady, false)
    assert.equal(f.publishProgress(0.25), false)
    gate.resolve()
    await manual
    assert.equal(f.readers[0].view.lastLocation.fraction, 0.8)
    assert.equal(f.host.manabiLoadEBookReady, true)
    assert.equal(f.publishProgress(0.8), true)
    assert.equal(f.messages.filter(message => message.initialRestoreResult.requestID === 'saved').length, 1)
    assert.equal(f.messages.some(message => message.initialRestoreResult.restoreSatisfied), false)
})

test('manual handoff: rejected replacement keeps progress closed and a fresh restore can retry', async () => {
    const f = reviewNavigationFixture({ specs: [{
        rendererGoTo: ({ target, publish }) => target.index === 1 ? false : publish(),
    }, {}] })
    f.host.pauseFrames = true
    const load = f.loadEBook(correlatedRequest('saved', 'epubcfi(/6/2)', null))
    await until(() => f.frames.size === 1)
    assert.equal(await manualFraction(f, 0.8), null)
    settleReviewFrames(f)
    await load
    assert.equal(f.host.manabiLoadEBookReady, false)
    assert.equal(f.readers[0].hasLoadedLastPosition, false)
    assert.equal(f.publishProgress(0.25), false)
    await f.loadEBook(correlatedRequest('retry', 'epubcfi(/6/2)', null))
    assert.equal(f.host.manabiLoadEBookReady, true)
    assert.equal(f.readers[1].hasLoadedLastPosition, true)
    assert.equal(f.messages.at(-1).initialRestoreResult.requestID, 'retry')
    assert.equal(f.messages.at(-1).initialRestoreResult.restoreSatisfied, true)
})

for (const replacementAccepted of [true, false]) {
    test(`manual handoff: late predecessor cannot override a ${replacementAccepted ? 'successful' : 'rejected'} successor`, async () => {
        const firstGate = deferred()
        let firstResult
        const f = reviewNavigationFixture({ rendererGoTo: ({ target, publish }) => {
            if (target.index !== 1) return publish()
            if (target.anchor > 0.5) {
                publish()
                firstResult = firstGate.promise
                return firstResult
            }
            return replacementAccepted ? publish() : false
        } })
        f.host.pauseFrames = true
        const load = f.loadEBook(correlatedRequest('saved', 'epubcfi(/6/2)', null))
        await until(() => f.frames.size === 1)
        const first = manualFraction(f, 0.8)
        await until(() => f.rendererCalls.length === 2)
        const second = await manualFraction(f, 0.6)
        settleReviewFrames(f)
        await load
        firstGate.resolve()
        await firstResult
        assert.equal(await first, null)
        assert.equal(f.host.manabiLoadEBookReady, replacementAccepted)
        assert.equal(f.readers[0].hasLoadedLastPosition, replacementAccepted)
        assert.equal(f.publishProgress(f.readers[0].view.lastLocation.fraction), replacementAccepted)
        if (replacementAccepted) {
            assert.equal(f.readers[0].view.isNavigationReceiptCurrent(second), true)
            assert.equal(f.readers[0].view.lastLocation.fraction, 0.6)
            assert.deepEqual(f.progressMessages, [{ fraction: 0.6, reason: 'page' }])
        } else {
            assert.equal(second, null)
            assert.deepEqual(f.progressMessages, [])
        }
        assert.equal(f.messages.some(message => message.initialRestoreResult.restoreSatisfied), false)
    })
}

test('manual handoff: late saved renderer completion cannot close the accepted manual progress gate', async () => {
    const savedGate = deferred()
    const f = reviewNavigationFixture({ rendererGoTo: ({ target, publish }) =>
        target.index === 0 ? savedGate.promise : publish() })
    const load = f.loadEBook(correlatedRequest('saved', 'epubcfi(/6/2)', null))
    await until(() => f.rendererCalls.length === 1)
    await manualFraction(f, 0.8)
    await load
    savedGate.resolve()
    await savedGate.promise
    assert.equal(f.readers[0].hasLoadedLastPosition, true)
    assert.equal(f.host.manabiLoadEBookReady, true)
    assert.equal(f.publishProgress(0.8), true)
    assert.equal(f.messages.length, 1)
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, false)
})

test('manual handoff: native terminal callback replacement preserves the successor load gate', async () => {
    const successorOpen = deferred()
    const f = reviewNavigationFixture({ specs: [{}, { open: () => successorOpen.promise }] })
    f.host.pauseFrames = true
    const load = f.loadEBook(correlatedRequest('saved', 'epubcfi(/6/2)', null))
    await until(() => f.frames.size === 1)
    const post = f.host.webkit.messageHandlers.ebookViewerLoaded.postMessage
    let successor
    f.host.webkit.messageHandlers.ebookViewerLoaded.postMessage = message => {
        post(message)
        if (message.initialRestoreResult.requestID === 'saved') {
            successor = f.loadEBook(correlatedRequest('successor', 'epubcfi(/6/2)', null))
        }
    }
    await manualFraction(f, 0.8)
    await load
    assert.equal(f.host.reader, f.readers[1])
    assert.equal(f.host.manabiLoadEBookReady, false)
    assert.notEqual(f.readers[1].hasLoadedLastPosition, true)
    assert.equal(f.publishProgress(0.8), false)
    settleReviewFrames(f)
    successorOpen.resolve()
    await successor
    assert.equal(f.host.manabiLoadEBookReady, true)
    assert.equal(f.readers[1].hasLoadedLastPosition, true)
    assert.deepEqual(f.messages.map(message => [message.initialRestoreResult.requestID,
        message.initialRestoreResult.restoreSatisfied]), [['saved', false], ['successor', true]])
})

test('manual handoff: replaced reader rejects late accepted results from its predecessor', async () => {
    const manualGate = deferred()
    const f = reviewNavigationFixture({ specs: [{
        rendererGoTo: ({ target, publish }) => target.index === 1 ? manualGate.promise : publish(),
    }, {}] })
    f.host.pauseFrames = true
    const load = f.loadEBook(correlatedRequest('saved', 'epubcfi(/6/2)', null))
    await until(() => f.frames.size === 1)
    const oldManual = manualFraction(f, 0.8)
    await until(() => f.rendererCalls.length === 2)
    settleReviewFrames(f)
    await f.loadEBook(correlatedRequest('successor', 'epubcfi(/6/2)', null))
    await load
    manualGate.resolve()
    assert.equal(await oldManual, null)
    assert.equal(f.host.reader, f.readers[1])
    assert.equal(f.host.manabiLoadEBookReady, true)
    assert.deepEqual(f.messages.map(message => message.initialRestoreResult.requestID), ['successor'])
})

test('manual handoff: ordinary navigation after published success does not republish the initial terminal', async () => {
    const f = reviewNavigationFixture()
    await f.loadEBook(correlatedRequest('saved', 'epubcfi(/6/2)', null))
    await manualFraction(f, 0.8)
    assert.equal(f.readers[0].view.lastLocation.fraction, 0.8)
    assert.equal(f.host.manabiLoadEBookReady, true)
    assert.equal(f.readers[0].hasLoadedLastPosition, true)
    assert.equal(f.messages.length, 1)
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, true)
})

test('manual handoff: accepted manual retry recovers a reported restore failure without another terminal', async () => {
    const f = reviewNavigationFixture({ rendererGoTo: ({ target, publish }) =>
        target.index === 0 ? false : publish() })
    await f.loadEBook(correlatedRequest('saved', 'epubcfi(/6/2)', null))
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, false)
    assert.equal(f.host.manabiLoadEBookReady, false)
    assert.equal(f.publishProgress(0.25), false)
    await manualFraction(f, 0.8)
    assert.equal(f.readers[0].view.lastLocation.fraction, 0.8)
    assert.equal(f.host.manabiLoadEBookReady, true)
    assert.equal(f.publishProgress(0.8), true)
    assert.equal(f.messages.length, 1)
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, false)
})

test('manual handoff: production relocation policy retains anchor and settle suppression', () => {
    const ready = { hasLoadedLastPosition: true, restoreInProgress: false,
        suppressNextRestoreRelocateSave: false, requireUserInputBeforePositionSave: false }
    assert.deepEqual(ebookRelocatePersistenceDecision({ ...ready, reason: 'page' }),
        { shouldPersist: true, clearSuppression: false })
    assert.deepEqual(ebookRelocatePersistenceDecision({ ...ready, reason: ' ANCHOR ' }),
        { shouldPersist: false, clearSuppression: false })
    assert.deepEqual(ebookRelocatePersistenceDecision({ ...ready, reason: 'page', suppressNextRestoreRelocateSave: true }),
        { shouldPersist: false, clearSuppression: true })
    assert.deepEqual(ebookRelocatePersistenceDecision({ ...ready, reason: 'page', requireUserInputBeforePositionSave: true }),
        { shouldPersist: false, clearSuppression: false })
    assert.deepEqual(ebookRelocatePersistenceDecision({ ...ready, reason: 'page', restoreInProgress: true,
        suppressNextRestoreRelocateSave: true }), { shouldPersist: false, clearSuppression: false })
    assert.deepEqual(ebookRelocatePersistenceDecision({ ...ready, reason: 'page', hasLoadedLastPosition: false }),
        { shouldPersist: false, clearSuppression: false })
})

for (const replacementStage of ['before invocation', 'during intent publication']) {
    test(`manual handoff: retained caller cannot adopt the successor ${replacementStage}`, async () => {
        const f = reviewNavigationFixture({ specs: [{}, {}] })
        await f.loadEBook(correlatedRequest('original', 'epubcfi(/6/2)', null))
        const originalReader = f.readers[0]
        const originalView = originalReader.view
        const originalCalls = f.rendererCalls.length
        let successor
        if (replacementStage === 'before invocation') {
            successor = f.loadEBook(correlatedRequest('successor', 'epubcfi(/6/2)', null))
            await successor
        } else {
            let intent = null
            Object.defineProperty(f.host, '__manabiNavigationIntent', {
                get: () => intent,
                set(value) {
                    intent = value
                    if (value?.source === 'retained-reader-command') {
                        successor = f.loadEBook(correlatedRequest('successor', 'epubcfi(/6/2)', null))
                    }
                },
            })
        }
        let dispatched = 0
        const result = await f.runManualNavigation({ source: 'retained-reader-command' },
            (view, options) => { dispatched++; return view.goToFraction(0.8, options) },
            { reader: originalReader, view: originalView })
        await successor
        assert.equal(result, null)
        assert.equal(dispatched, 0)
        assert.equal(f.rendererCalls.length, originalCalls + 1, 'only the successor restore reaches its renderer')
        assert.equal(f.host.reader, f.readers[1])
        assert.equal(f.readers[1].view.lastLocation.fraction, 0.25)
        assert.equal(f.host.manabiLoadEBookReady, true)
        assert.equal(f.readers[1].hasLoadedLastPosition, true)
        assert.deepEqual(f.messages.map(message => [message.initialRestoreResult.requestID,
            message.initialRestoreResult.restoreSatisfied]), [['original', true], ['successor', true]])
    })
}

test('manual handoff: same-visible-page navigation obtains an actual renderer receipt through the guard', async () => {
    const f = reviewNavigationFixture({ specs: [{ configureView(view) {
        const renderer = view.renderer
        const goTo = renderer.goTo.bind(renderer)
        const receipts = new WeakSet()
        renderer.goTo = (target, options) => {
            goTo(target, options)
            const receipt = Object.freeze({ ...target })
            receipts.add(receipt)
            return receipt
        }
        renderer.isNavigationReceiptCurrent = receipt => receipts.has(receipt)
        installVisibleRendererGoToGuard({ renderer, getCurrentIndex: () => 0,
            getPageSnapshot: () => ({ current: 2, total: 3 }) })
    } }] })
    f.host.pauseFrames = true
    const load = f.loadEBook(correlatedRequest('saved', 'epubcfi(/6/2)', null))
    await until(() => f.frames.size === 1)
    assert.equal(f.publishProgress(0.25), false)
    const receipt = await manualFraction(f, 0.25)
    settleReviewFrames(f)
    await load
    assert.equal(f.rendererCalls.length, 2, 'the visible-page shortcut cannot invent a command receipt')
    assert.equal(f.readers[0].view.isNavigationReceiptCurrent(receipt), true)
    assert.equal(f.host.manabiLoadEBookReady, true)
    assert.equal(f.publishProgress(0.25), true)
    assert.equal(f.messages.length, 1)
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, false)
})

const manuallyReadyFixture = async () => {
    const f = reviewNavigationFixture({ specs: [{}, {}] })
    f.host.pauseFrames = true
    const load = f.loadEBook(correlatedRequest('saved', 'epubcfi(/6/2)', null))
    await until(() => f.frames.size === 1)
    await manualFraction(f, 0.8)
    settleReviewFrames(f)
    await load
    assert.equal(f.host.manabiLoadEBookReady, true)
    return f
}

const captureRelocate = (f, detail = f.host.reader.view.lastLocation) => captureEbookRelocatePublication({
    reader: f.host.reader, view: f.host.reader.view, detail, getCurrentReader: () => f.host.reader,
})

test('relocate publication: a held older detail cannot publish after a newer manual command', async () => {
    const f = await manuallyReadyFixture()
    const detail = f.host.reader.view.lastLocation
    const owner = captureRelocate(f, detail)
    const hud = deferred()
    // The actual Reader has a HUD suspension before queueing progress. This
    // controlled continuation executes the production publication admission.
    const held = hud.promise.then(() => owner.publishIfCurrent(() => f.publishProgress(detail.fraction)))
    await manualFraction(f, 0.6)
    hud.resolve()
    assert.equal(await held, false)
    assert.deepEqual(f.progressMessages, [])
    const current = f.host.reader.view.lastLocation
    const currentOwner = captureRelocate(f, current)
    assert.equal(currentOwner.publishIfCurrent(() => f.publishProgress(current.fraction)), true)
    assert.deepEqual(f.progressMessages, [{ fraction: 0.6, reason: 'page' }])
})

test('relocate publication: delayed delivery rejects changed detail and reader ownership', async () => {
    for (const replacement of ['detail', 'same-fraction detail', 'reader', 'view', 'renderer', 'book', 'closed reader']) {
        const f = await manuallyReadyFixture()
        const reader = f.host.reader, view = reader.view, detail = view.lastLocation
        const owner = captureRelocate(f, detail)
        // A saved debounce callback carries the captured production handle; it
        // does not resolve a new reader or location when delivery finally runs.
        const deliver = () => owner.publishIfCurrent(() => f.publishProgress(detail.fraction))
        if (replacement === 'detail') await view.goToFraction(0.6)
        else if (replacement === 'same-fraction detail') await view.goToFraction(0.8)
        else if (replacement === 'reader') {
            await f.loadEBook(correlatedRequest('successor', 'epubcfi(/6/2)', null))
        } else if (replacement === 'view') {
            const successor = new ReviewView()
            successor.book = view.book
            successor.renderer = view.renderer
            successor.lastLocation = detail
            reader.view = successor
        } else if (replacement === 'renderer') view.renderer = { ...view.renderer }
        else if (replacement === 'book') view.book = { ...view.book }
        else reader.isClosed = true
        assert.equal(owner.isCurrent(), false, replacement)
        assert.equal(deliver(), false, replacement)
        assert.deepEqual(f.progressMessages, [], replacement)
    }
})

test('relocate publication: only the exact current detail is admitted and current publication succeeds', async () => {
    const f = await manuallyReadyFixture()
    const reader = f.host.reader, view = reader.view, detail = view.lastLocation
    assert.equal(captureRelocate(f, { ...detail }), null)
    const owner = captureRelocate(f, detail)
    assert.equal(owner.renderer, view.renderer)
    assert.equal(owner.isCurrent(), true)
    assert.equal(owner.publishIfCurrent(() => f.publishProgress(detail.fraction)), true)
    assert.deepEqual(f.progressMessages, [{ fraction: 0.8, reason: 'page' }])
    await view.goToFraction(0.8)
    assert.equal(captureRelocate(f, detail), null, 'equal fraction cannot admit a predecessor relocation object')
})

test('manual handoff: actual View foreground wiring requires the accepted current activity receipt', async t => {
    const view = new ReviewView()
    const sections = [{ id: 'one', size: 100 }, { id: 'two', size: 100 }]
    const progress = new SectionProgress(sections, 10, 10)
    const renderer = new EventTarget()
    const accepted = new WeakSet()
    Object.assign(renderer, {
        localName: 'foliate-paginator', scrolled: false,
        setAttribute() {}, open() {}, destroy() {}, remove() {},
        isNavigationReceiptCurrent: receipt => accepted.has(receipt),
        goTo(target) {
            view.lastLocation = buildRelocateLocation({ index: target.index, fraction: target.anchor ?? 0, size: 0 },
                { sectionCount: sections.length, sectionProgress: progress })
            const receipt = Object.freeze({ ...target })
            accepted.add(receipt)
            return receipt
        },
    })
    const previousCreateElement = document.createElement
    const previousNodeFilter = globalThis.NodeFilter
    document.createElement = name => {
        assert.equal(name, 'foliate-paginator')
        return renderer
    }
    globalThis.NodeFilter = { SHOW_ELEMENT: 1, SHOW_TEXT: 4, SHOW_CDATA_SECTION: 8,
        FILTER_ACCEPT: 1, FILTER_REJECT: 2, FILTER_SKIP: 3 }
    try {
        await view.open({ sections, resolveCFI: () => ({ index: 0, anchor: 0.5 }) }, true)
    } finally {
        document.createElement = previousCreateElement
        if (previousNodeFilter === undefined) delete globalThis.NodeFilter
        else globalThis.NodeFilter = previousNodeFilter
    }
    t.after(() => view.close())
    const f = fixture([{ configureView(_unused, reader) { reader.view = view } }])
    f.host.pauseFrames = true
    const load = f.loadEBook(correlatedRequest('saved', 'epubcfi(/6/2)', null))
    await until(() => f.frames.size === 1)
    const oldActivity = {}, currentActivity = {}
    const oldReceipt = Object.freeze({ index: 1 }), currentReceipt = Object.freeze({ index: 1 })
    accepted.add(oldReceipt)
    accepted.add(currentReceipt)
    const emit = (name, detail) => renderer.dispatchEvent(new CustomEvent(name, { detail }))
    emit('foregroundPageTurnActivity', { activity: oldActivity })
    emit('foregroundPageTurnActivity', { activity: currentActivity })
    emit('foregroundNavigationAccepted', { activity: oldActivity, receipt: oldReceipt })
    emit('foregroundNavigationAccepted', { activity: currentActivity, receipt: { index: 1 } })
    assert.equal(f.host.manabiLoadEBookReady, false)
    assert.equal(f.publishProgress(0.25), false)
    assert.equal(f.messages.length, 0)
    view.lastLocation = buildRelocateLocation({ index: 1, fraction: 0.6, size: 0 },
        { sectionCount: sections.length, sectionProgress: progress })
    emit('foregroundNavigationAccepted', { activity: currentActivity, receipt: currentReceipt })
    settleReviewFrames(f)
    await load
    assert.equal(f.host.manabiLoadEBookReady, true)
    assert.equal(f.readers[0].hasLoadedLastPosition, true)
    assert.equal(f.publishProgress(view.lastLocation.fraction), true)
    assert.deepEqual(f.progressMessages, [{ fraction: 0.8, reason: 'page' }])
    assert.equal(f.messages.length, 1)
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, false)

    // Foreground activity also retains the restore owner from onset. An event
    // completing after a fresh restore begins cannot adopt that successor.
    f.host.pauseFrames = true
    const lateActivity = {}, lateReceipt = Object.freeze({ index: 1 })
    accepted.add(lateReceipt)
    emit('foregroundPageTurnActivity', { activity: lateActivity })
    const retry = f.loadLastPosition({ cfi: 'epubcfi(/6/4)' })
    void retry.catch(() => {})
    emit('foregroundNavigationAccepted', { activity: lateActivity, receipt: lateReceipt })
    assert.equal(f.readers[0].hasLoadedLastPosition, false)
    assert.equal(f.host.__manabiRestoreInProgress, true)
    await until(() => f.frames.size === 1)
    settleReviewFrames(f)
    assert.equal((await retry).handledCFI, 'epubcfi(/6/4)')
    assert.equal(view.lastLocation.fraction, 0.25)
    assert.equal(f.messages.length, 1)
})

test('manual handoff: a pending command cannot adopt a freshly begun restore before its first dispatch', async () => {
    const gate = deferred()
    const f = reviewNavigationFixture({ rendererGoTo: ({ target, publish }) =>
        target.index === 1 ? gate.promise.then(publish) : publish() })
    f.host.pauseFrames = true
    const initial = f.loadEBook(correlatedRequest('saved', 'epubcfi(/6/2)', null))
    await until(() => f.frames.size === 1)
    const reader = f.host.reader, view = reader.view
    let newer
    const manual = f.runManualNavigation({ source: 'goToPercent' }, (capturedView, options) => {
        const navigation = capturedView.goToFraction(0.8, options)
        // Register before the runner awaits this same promise. This callback
        // begins B before the runner consumes A's accepted renderer receipt;
        // B's first View dispatch is still a queued coordinator continuation.
        navigation.then(() => {
            newer = f.loadLastPosition({ cfi: 'epubcfi(/6/4)' })
            void newer.catch(() => {})
        })
        return navigation
    }, { reader, view })
    await until(() => f.rendererCalls.length === 2)
    gate.resolve()
    assert.equal(await manual, null, 'the old caller cannot report success after its restore admission retires')
    await initial
    assert.equal(reader.hasLoadedLastPosition, false)
    assert.equal(f.host.manabiLoadEBookReady, false)
    assert.equal(f.publishProgress(0.8), false)
    assert.equal(f.messages.length, 0)
    await until(() => f.frames.size === 1)
    settleReviewFrames(f)
    const restored = await newer
    assert.equal(restored.handledCFI, 'epubcfi(/6/4)')
    assert.equal(view.lastLocation.fraction, 0.25)
    assert.equal(reader.hasLoadedLastPosition, true)
})

test('manual handoff: same-Reader restore replacement at intent publication requires a fresh manual admission', async () => {
    const f = reviewNavigationFixture()
    f.host.pauseFrames = true
    const initial = f.loadEBook(correlatedRequest('saved', 'epubcfi(/6/2)', null))
    await until(() => f.frames.size === 1)
    let intent = null, newer
    Object.defineProperty(f.host, '__manabiNavigationIntent', {
        get: () => intent,
        set(value) {
            intent = value
            if (value?.source === 'retired-restore-command') {
                newer = f.loadLastPosition({ cfi: 'epubcfi(/6/4)' })
                void newer.catch(() => {})
            }
        },
    })
    assert.equal(await manualFraction(f, 0.8, 'retired-restore-command'), null)
    await initial
    await until(() => f.frames.size === 1)
    assert.equal(f.rendererCalls.length, 2, 'only the two saved restore commands reached the renderer')
    assert.equal(f.host.reader.hasLoadedLastPosition, false)
    assert.equal(f.publishProgress(0.8), false)
    settleReviewFrames(f)
    assert.equal((await newer).handledCFI, 'epubcfi(/6/4)')
    assert.equal(f.host.reader.view.lastLocation.fraction, 0.25)
    await manualFraction(f, 0.8)
    assert.equal(f.host.manabiLoadEBookReady, true)
    assert.equal(f.publishProgress(0.8), true)
    assert.equal(f.messages.length, 1)
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, false)
})

test('manual handoff: missing or denied owner admission never dispatches a command', async () => {
    const f = await manuallyReadyFixture()
    const reader = f.host.reader, view = reader.view
    const calls = f.rendererCalls.length
    for (const captureOwner of [undefined, () => null]) {
        let dispatched = 0
        const denied = createManualNavigationRunner({ host: f.host,
            runWithNavigationIntent: createNavigationIntentRunner(f.host), captureOwner,
            onAccepted: () => assert.fail('denied admission cannot publish acceptance') })
        const command = denied({ source: 'goToPercent' }, (capturedView, options) => {
            dispatched++
            return capturedView.goToFraction(0.6, options)
        }, { reader, view })
        if (captureOwner == null) await assert.rejects(command, TypeError)
        else assert.equal(await command, null)
        assert.equal(dispatched, 0)
    }
    assert.equal(f.rendererCalls.length, calls)
    assert.equal(view.lastLocation.fraction, 0.8)
    assert.equal(f.host.manabiLoadEBookReady, true)
})
