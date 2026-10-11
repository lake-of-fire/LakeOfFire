import assert from 'node:assert/strict'
import test from 'node:test'
import { makeNativeEbookSource } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-native-source-request.js'
import { createEbookLoadHandlers, createNavigationIntentRunner, EbookLoadSupersededError } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-load-coordinator.js'

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
    const readers = [], warmers = [], messages = [], effects = [], timers = new Map(), frames = new Map()
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
            this.view = {
                lastLocation: { fraction: this.spec.landing ?? 0.25 },
                renderer: {
                    next: () => { this.events.push(['next']); return this.spec.next?.(this) },
                    nextSection: () => { this.events.push(['nextSection']); return this.spec.nextSection?.(this) },
                },
                goTo: cfi => { this.events.push(['goTo', cfi]); return this.spec.goTo?.(this, cfi) },
                goToFraction: fraction => { this.events.push(['goToFraction', fraction]); return this.spec.fraction?.(this, fraction) },
            }
        }
        close(reason) {
            if (this.isClosed) return false
            this.isClosed = true
            this.events.push(['close', reason])
            this.onLoadClosed?.()
            this.view = null
            return true
        }
        displayInitialSection(...args) { this.events.push(['synthetic']); return this.spec.synthetic?.(this, ...args) }
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
    const handlers = createEbookLoadHandlers({ host, Reader, CacheWarmer,
        makeNativeSource: hooks.makeNativeSource ?? (url => ({ kind: 'native', url })),
        makeFileSource: file => ({ kind: 'file', file }),
        installReaderPresentationState: () => {}, beginReplaceTextCacheGeneration: () => hooks.generation?.(),
        beginForegroundCriticalSection: () => ++criticalID,
        finishForegroundCriticalSection: token => { ended.push(token); hooks.finishForeground?.() },
        ensureRestorePositionSaveUserInputTracking: () => {},
        runWithNavigationIntent: createNavigationIntentRunner(host),
        markReaderRenderReady: () => effects.push('ready'),
        postLandscapeInsetRestoreProbe: () => effects.push('probe'),
        scheduleDeferredCacheWarmerOpen: () => effects.push('warm'),
    })
    return { ...handlers, host, readers, warmers, messages, effects, ended, timers, frames }
}
const count = (reader, name) => reader.events.filter(event => event[0] === name).length

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
    const f = fixture([{ synthetic: () => false }])
    await f.loadEBook(request('A', 'mnb-loc-v1:0:1:3', null))
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, false)
    assert.equal(count(f.readers[0], 'complete'), 0)
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


const sessionA = '00000000-0000-0000-0000-000000000001'
const sessionB = '00000000-0000-0000-0000-000000000002'
const boundRequest = (packageSessionID = sessionA) => ({ ...request(),
    url: 'ebook://ebook/load/local/book.epub', packageSessionID })

test('an unsupported package session is rejected before replacing a working legacy reader', async () => {
    const f = fixture(); await f.loadEBook(request())
    const reader = f.host.reader, receipt = f.host.manabiInitialRestoreResult
    await assert.rejects(f.loadEBook(boundRequest()), /session was not preserved/)
    assert.equal(f.host.reader, reader)
    assert.equal(f.host.manabiInitialRestoreResult, receipt)
    assert.equal(reader.isClosed, false)
    assert.equal(f.readers.length, 1)
})

test('actual companion source descriptors retain the selected package session through opening and warming', async () => {
    const f = fixture([], { makeNativeSource: makeNativeEbookSource })
    await f.loadEBook(boundRequest())
    const source = f.readers[0].events.find(value => value[0] === 'open')[1]
    assert.equal(source.packageSessionID, sessionA)
    assert.equal(Object.isFrozen(source), true)
    assert.equal(f.warmers[0].resources.makeReusableSource(), source)
    assert.equal(f.host.manabiLoadEBookPackageSessionID, sessionA)
})

test('same URL and restore with different package sessions are different loads', async () => {
    const f = fixture([], { makeNativeSource: makeNativeEbookSource })
    await f.loadEBook(boundRequest(sessionA))
    await f.loadEBook(boundRequest(sessionB))
    assert.equal(f.readers.length, 2)
    assert.equal(f.readers[0].isClosed, true)
    assert.equal(f.host.manabiLoadEBookPackageSessionID, sessionB)
    assert.equal(f.readers[1].events.find(value => value[0] === 'open')[1].packageSessionID, sessionB)
})

test('an identical bound request reuses the same in-flight load and ready reader', async () => {
    const gate = deferred(), f = fixture([{ open: () => gate.promise }], { makeNativeSource: makeNativeEbookSource })
    const pending = f.loadEBook(boundRequest())
    assert.equal(f.loadEBook(boundRequest()), pending)
    gate.resolve(); await pending
    assert.equal(f.loadEBook(boundRequest()), undefined)
    assert.equal(f.readers.length, 1)
})

test('malformed package tokens and nonnative bound URLs never change an active load', async () => {
    const f = fixture([], { makeNativeSource: makeNativeEbookSource })
    await f.loadEBook(boundRequest())
    const reader = f.host.reader
    for (const packageSessionID of ['', true, 1, {}, 'not-a-session', sessionA.toUpperCase().replace('0', 'A')]) {
        await assert.rejects(Promise.resolve().then(() => f.loadEBook(boundRequest(packageSessionID))), TypeError)
        assert.equal(f.host.reader, reader)
        assert.equal(reader.isClosed, false)
    }
    await assert.rejects(f.loadEBook({ ...boundRequest(), url: 'https://books.invalid/a.epub' }), TypeError)
    assert.equal(f.host.reader, reader)
    assert.equal(f.readers.length, 1)
})

test('a factory returning a different native capability cannot replace the current reader', async () => {
    let substitute = false
    const f = fixture([], { makeNativeSource: (url, sessionID) =>
        makeNativeEbookSource(url, substitute ? sessionB : sessionID) })
    await f.loadEBook(boundRequest())
    substitute = true
    await assert.rejects(f.loadEBook(boundRequest()), /session was not preserved/)
    assert.equal(f.readers.length, 1)
    assert.equal(f.readers[0].isClosed, false)
})
