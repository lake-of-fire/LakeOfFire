import { EbookLoadResources } from './ebook-load-resources.js'
import {
    makeInitialRestoreTerminalResult,
    normalizeInitialRestoreRequest,
    parseSyntheticRestoreLocator,
    runRequiredRestoreNavigation,
} from './ebook-restore-coordination.js'
import { scheduleFrameWithTimeoutFallback } from './frame-timeout-scheduler.js'

export class EbookLoadSupersededError extends Error {
    constructor() {
        super('Ebook load or restore was superseded')
        this.name = 'EbookLoadSupersededError'
    }
}

// A late finally must neither clear a newer intent nor restore an already
// completed predecessor when overlapping operations settle out of order.
export const createNavigationIntentRunner = (host = globalThis) => {
    const entries = new WeakMap()
    return async (intent, operation) => {
        const value = { timestamp: Date.now(), ...intent }
        const entry = { previous: host.__manabiNavigationIntent ?? null, pending: true }
        entries.set(value, entry)
        host.__manabiNavigationIntent = value
        try {
            return await operation()
        } finally {
            entry.pending = false
            if (host.__manabiNavigationIntent === value) {
                let previous = entry.previous
                while (previous && entries.get(previous)?.pending === false) {
                    previous = entries.get(previous).previous
                }
                host.__manabiNavigationIntent = previous
            }
        }
    }
}

const sameRestore = (left, right) => left === right || (left != null && right != null
    && left.requestID === right.requestID && left.cfi === right.cfi
    && left.fractionalCompletion === right.fractionalCompletion
    && left.requestedLocator === right.requestedLocator)

// These are the actual window entry points. Browser/Reader construction is
// injected once by ebook-viewer; there is no second implementation for tests.
export const createEbookLoadHandlers = ({
    host = globalThis,
    Reader,
    CacheWarmer,
    makeNativeSource,
    makeFileSource,
    installReaderPresentationState,
    beginReplaceTextCacheGeneration,
    beginForegroundCriticalSection,
    finishForegroundCriticalSection,
    ensureRestorePositionSaveUserInputTracking,
    runWithNavigationIntent,
    markReaderRenderReady,
    postLandscapeInsetRestoreProbe,
    scheduleDeferredCacheWarmerOpen,
}) => {
    let currentLoad = null
    let loadInvocation = 0
    let currentRestore = null
    const ownsLoad = load => currentLoad === load
        && host.manabiLoadEBookToken === load.token
    const liveLoad = load => ownsLoad(load) && !load.retired
        && host.reader === load.reader && load.reader?.isClosed !== true
    const assertCurrent = operation => {
        if (operation.controller.signal.aborted || !operation.isCurrent()) {
            throw new EbookLoadSupersededError()
        }
    }

    // Always observe the underlying promise after invalidation. A renderer may
    // not cancel its own work; it must not publish a late result or rejection.
    const waitFor = (operation, work, timeoutMilliseconds = null) => {
        assertCurrent(operation)
        return new Promise((resolve, reject) => {
            const signal = operation.controller.signal
            let timer = null
            const cleanup = () => {
                signal.removeEventListener('abort', onAbort)
                if (timer != null) host.clearTimeout(timer)
            }
            const onAbort = () => { cleanup(); reject(new EbookLoadSupersededError()) }
            signal.addEventListener('abort', onAbort, { once: true })
            if (timeoutMilliseconds != null) {
                timer = host.setTimeout(() => {
                    cleanup()
                    reject(new Error(`Timed out after ${timeoutMilliseconds}ms`))
                }, timeoutMilliseconds)
            }
            Promise.resolve().then(() => {
                assertCurrent(operation)
                return work()
            }).then(value => {
                try { assertCurrent(operation); cleanup(); resolve(value) }
                catch (error) { cleanup(); reject(error) }
            }, error => {
                cleanup()
                reject(signal.aborted || !operation.isCurrent()
                    ? new EbookLoadSupersededError() : error)
            })
        })
    }

    const clearRestoreFlags = () => {
        host.__manabiRestoreInProgress = false
        host.__manabiSuppressNextRestoreRelocateSave = false
        host.__manabiRequireUserInputBeforePositionSave = true
    }
    const finishForeground = load => {
        if (load.foregroundToken != null) {
            const token = load.foregroundToken
            load.foregroundToken = null
            finishForegroundCriticalSection(token)
        }
        if (host.__manabiFinishInitialForegroundCriticalSection === load.finishForeground) {
            host.__manabiFinishInitialForegroundCriticalSection = null
        }
    }
    const retireLoad = load => {
        if (!load || load.retired) return
        load.retired = true
        if (currentRestore && currentRestore.reader === load.reader) {
            const restore = currentRestore
            currentRestore = null
            restore.controller.abort()
        }
        if (ownsLoad(load)) {
            clearRestoreFlags()
            host.__manabiNavigationIntent = null
            host.manabiLoadEBookReady = false
            host.manabiLoadEBookInFlight = false
            host.manabiLoadEBookPromise = null
            host.manabiPendingInitialRestoreRequest = null
            host.manabiPendingLoadEBookArgs = null
        }
        load.controller.abort()
        finishForeground(load)
        load.cacheWarmer?.destroy?.()
        load.resources?.close()
        if (host.cacheWarmer === load.cacheWarmer) host.cacheWarmer = null
    }
    const closeLoad = (load, reason) => {
        retireLoad(load)
        load?.reader?.close?.(reason)
    }

    const beginRestore = () => {
        const reader = host.reader
        const view = reader?.view
        const renderer = view?.renderer
        const loadToken = host.manabiLoadEBookToken
        if (!reader || reader.isClosed === true || !renderer) throw new EbookLoadSupersededError()
        currentRestore?.controller.abort()
        const restore = { reader, view, renderer, controller: new AbortController() }
        restore.isCurrent = () => currentRestore === restore && host.reader === reader
            && reader.isClosed !== true && reader.view === view && view.renderer === renderer
            && host.manabiLoadEBookToken === loadToken
        currentRestore = restore
        return restore
    }

    const performRestore = async (restore, { cfi = '', fractionalCompletion = null } = {}) => {
        const { reader, view, renderer } = restore
        const check = () => assertCurrent(restore)
        const effect = operation => { check(); const result = operation(); check(); return result }
        const waitForFrames = async (count = 2) => {
            for (let index = 0; index < count; index += 1) {
                let scheduled
                try {
                    await waitFor(restore, () => new Promise(resolve => {
                        scheduled = scheduleFrameWithTimeoutFallback({ callback: resolve,
                            requestFrame: host.requestAnimationFrame?.bind(host),
                            cancelFrame: host.cancelAnimationFrame?.bind(host),
                            setTimer: host.setTimeout.bind(host), clearTimer: host.clearTimeout.bind(host) })
                    }))
                } finally { scheduled?.cancel() }
            }
        }
        const captureState = () => {
            check()
            const detail = view.lastLocation ?? null
            return {
                detail,
                currentFraction: Number.isFinite(detail?.fraction) ? detail.fraction : null,
                locationCurrent: detail?.location?.current ?? null,
                locationTotal: detail?.location?.total ?? null,
                sectionIndex: detail?.section?.current ?? detail?.sectionIndex ?? null,
            }
        }
        const navigate = async (intent, action) => {
            const result = await waitFor(restore, () => runRequiredRestoreNavigation(
                () => runWithNavigationIntent(intent, () => effect(action))))
            if (!result.ok) throw result.error
        }
        const validFraction = Number.isFinite(fractionalCompletion)
            && fractionalCompletion >= 0 && fractionalCompletion <= 1
        if (typeof cfi !== 'string' || (fractionalCompletion != null && !validFraction)) {
            throw new TypeError('Invalid saved ebook position')
        }
        effect(ensureRestorePositionSaveUserInputTracking)
        host.__manabiRequestedRestoreFraction = validFraction ? fractionalCompletion : null
        host.__manabiRestoreInProgress = true
        // Retain main's existing no-target/zero opening behavior; the separately
        // reviewed saved-zero route is not silently changed by a lifetime port.
        const hasFraction = validFraction && fractionalCompletion > 0
        let handledCFI = null
        try {
            if (parseSyntheticRestoreLocator(cfi)) {
                if (typeof reader.displayInitialSection !== 'function') {
                    throw new Error('Synthetic restore navigation is unavailable')
                }
                await navigate({ source: 'restore.synthetic', target: 'displayInitialSection' },
                    () => reader.displayInitialSection('loadLastPosition.synthetic-locator', { cfi, fractionalCompletion }))
                handledCFI = cfi
                await waitForFrames()
            } else if (cfi.length > 0) {
                await navigate({ source: 'restore.cfi', target: 'view.goTo', cfiLength: cfi.length,
                    fraction: hasFraction ? fractionalCompletion : null }, () => view.goTo(cfi))
                handledCFI = cfi
                await waitForFrames()
                const state = captureState()
                if (hasFraction && Number.isFinite(state.currentFraction)) {
                    const delta = Math.abs(state.currentFraction - fractionalCompletion)
                    const percentChanged = Math.round(state.currentFraction * 100) !== Math.round(fractionalCompletion * 100)
                    const pages = reader.navHUD?.rendererPageSnapshot
                    const targetPage = Number.isFinite(pages?.total) && pages.total > 1
                        ? Math.max(1, Math.min(pages.total, Math.round(fractionalCompletion * (pages.total - 1)) + 1)) : null
                    if ((delta > 0.003 || percentChanged) && !(targetPage != null && pages?.current === targetPage)) {
                        await navigate({ source: 'restore.reconcile', reason: 'cfi-fraction-drift',
                            target: 'view.goToFraction', fraction: fractionalCompletion,
                            stageOnReconcile: 'after-cfi-fraction-reconcile' }, () => view.goToFraction(fractionalCompletion))
                        await waitForFrames()
                    }
                }
            } else if (hasFraction) {
                await navigate({ source: 'restore.fraction', target: 'view.goToFraction', fraction: fractionalCompletion },
                    () => view.goToFraction(fractionalCompletion))
                await waitForFrames()
            } else {
                try { await waitFor(restore, () => renderer.next(), 1500) }
                catch (error) {
                    check() // Cancellation/replacement is never fallback authority.
                    await waitFor(restore, () => renderer.nextSection())
                }
                await waitForFrames()
            }
            effect(() => reader.completeLastPositionLoad())
            effect(() => reader.refreshNativeLookupHitTargets?.('load-last-position-done'))
            const doneState = captureState()
            effect(() => reader.maybeFlashInitialForwardSideNavChevron?.(doneState))
            effect(() => markReaderRenderReady('loadLastPosition.done'))
            effect(() => postLandscapeInsetRestoreProbe('done', doneState, {
                hasCFI: cfi.length > 0,
                requestedFraction: validFraction ? Number(fractionalCompletion.toFixed(6)) : null,
            }))
            effect(() => scheduleDeferredCacheWarmerOpen('load-last-position-done', 2200))
            return { handledFractionalCompletion: doneState.currentFraction,
                currentFractionalCompletion: doneState.currentFraction, handledCFI }
        } catch (error) {
            if (restore.isCurrent()) {
                reader.hasLoadedLastPosition = false
                reader.completeLastPositionLoadAttempt()
            }
            throw error
        } finally {
            if (restore.isCurrent()) clearRestoreFlags()
        }
    }

    const loadLastPosition = (position = {}) => {
        const { cfi = '', fractionalCompletion = null } = position
        if (typeof cfi !== 'string' || (fractionalCompletion != null
            && !(Number.isFinite(fractionalCompletion) && fractionalCompletion >= 0 && fractionalCompletion <= 1))) {
            return Promise.reject(new TypeError('Invalid saved ebook position'))
        }
        return performRestore(beginRestore(), { cfi, fractionalCompletion })
    }

    const runLoad = async load => {
        try {
            assertCurrent(load)
            const { reader, url, layoutMode } = load
            host.manabiLoadEBookLastState = 'source-start'
            let source = load.nativeSource
            if (!source) {
                const response = await waitFor(load, () => host.fetch(url, {
                    headers: { 'IS-SWIFTUIWEBVIEW-VIEWER-FILE-REQUEST': 'true' },
                    signal: load.controller.signal,
                }))
                if (!response.ok) throw new Error(`Unable to load ebook (${response.status})`)
                const blob = await waitFor(load, () => response.blob())
                if (!load.resources.setRemoteBlob(blob)) throw new EbookLoadSupersededError()
                source = makeFileSource(new host.File([blob], load.sourcePath))
                assertCurrent(load)
            }
            host.manabiLoadEBookLastState = 'source-ready'
            host.manabiPendingLoadEBookArgs = null
            // Unknown layout must not inherit the previous book's request.
            if (layoutMode) host.initialLayoutMode = layoutMode
            else delete host.initialLayoutMode
            host.manabiLoadEBookLastState = 'reader-open-dispatch'
            await waitFor(load, () => reader.open(source))
            if (!reader.view?.renderer) throw new Error('reader-open-missing-renderer')
            host.manabiPendingInitialRestoreRequest = null
            const restore = beginRestore()
            let snapshot = null
            let error = null
            try { snapshot = await performRestore(restore, load.request ?? { cfi: '', fractionalCompletion: 0 }) }
            catch (failure) { error = failure }
            // A separate restore on this same reader supersedes the receipt too.
            assertCurrent(load)
            assertCurrent(restore)
            const result = makeInitialRestoreTerminalResult({ request: load.request, snapshot, error })
            host.manabiInitialRestoreResult = result
            host.manabiLoadEBookReady = true
            host.manabiLoadEBookLastState = 'reader-open-resolved'
            const probe = reader.collectLayoutGapProbe?.('ebookViewerLoaded', {
                bookDir: reader.bookDir || null, isRTL: !!reader.isRTL,
            }) ?? null
            assertCurrent(load)
            assertCurrent(restore)
            host.webkit.messageHandlers.ebookViewerLoaded.postMessage({ probe, initialRestoreResult: result })
        } catch (error) {
            if (!liveLoad(load) || error instanceof EbookLoadSupersededError) return
            host.manabiLoadEBookLastState = `open-error:${error?.message || String(error)}`
            closeLoad(load, 'loadEBook.error')
            if (host.reader === load.reader) host.reader = null
            throw error
        } finally {
            if (ownsLoad(load)) {
                host.manabiLoadEBookInFlight = false
                if (host.manabiLoadEBookPromise === load.promise) host.manabiLoadEBookPromise = null
            }
        }
    }

    const loadEBook = ({ url, layoutMode, initialRestore, readerPresentationState } = {}) => {
        const invocation = ++loadInvocation
        installReaderPresentationState(host, host.document, readerPresentationState, 'loadEBook')
        if (invocation !== loadInvocation) return host.manabiLoadEBookPromise
        const requestedURL = typeof url === 'string' ? url : ''
        const request = normalizeInitialRestoreRequest(initialRestore)
        const previous = currentLoad
        if (previous && liveLoad(previous) && requestedURL.length > 0 && previous.url === requestedURL
            && previous.layoutMode === layoutMode && sameRestore(previous.request, request)) {
            const age = Date.now() - host.manabiLoadEBookStartedAt
            if (host.manabiLoadEBookInFlight && (previous.reader.view?.renderer || age < 2500)) {
                host.manabiLoadEBookLastState = 'duplicate-inflight'
                return previous.promise
            }
            if (host.manabiLoadEBookReady && previous.reader.view?.renderer) {
                finishForeground(previous)
                host.manabiLoadEBookLastState = 'duplicate-ready'
                return
            }
        }
        // A different restore request, even at the same URL, is not a retry of
        // the old request. Restart instead of silently dropping its locator/ID.
        closeLoad(previous, 'loadEBook.replace')
        if (!previous) {
            const oldReader = host.reader
            const oldWarmer = host.cacheWarmer
            host.__manabiFinishInitialForegroundCriticalSection?.('loadEBook.replace')
            oldReader?.close?.('loadEBook.replace')
            oldWarmer?.destroy?.()
        }
        if (invocation !== loadInvocation) return host.manabiLoadEBookPromise
        const load = { url: requestedURL, layoutMode, request, retired: false,
            token: (host.manabiLoadEBookToken ?? 0) + 1, controller: new AbortController() }
        currentLoad = load
        load.isCurrent = () => liveLoad(load)
        host.manabiLoadEBookToken = load.token
        host.manabiLoadEBookURL = requestedURL
        host.manabiLoadEBookInFlight = true
        host.manabiLoadEBookStarted = true
        host.manabiLoadEBookStartedAt = Date.now()
        host.manabiLoadEBookReady = false
        host.manabiLoadEBookLastState = 'start'
        host.manabiInitialRestoreResult = null
        host.manabiPendingInitialRestoreRequest = request
        host.manabiPendingLoadEBookArgs = { hasURL: requestedURL.length > 0, layoutMode: layoutMode || null }
        host.__manabiNavigationIntent = null
        clearRestoreFlags()
        beginReplaceTextCacheGeneration()
        if (!ownsLoad(load) || load.retired) return host.manabiLoadEBookPromise
        load.foregroundToken = beginForegroundCriticalSection()
        if (!ownsLoad(load) || load.retired) { finishForeground(load); return host.manabiLoadEBookPromise }
        load.finishForeground = () => finishForeground(load)
        host.__manabiFinishInitialForegroundCriticalSection = load.finishForeground
        host.__manabiLiveProcessedSectionHrefs = new Set()
        host.__manabiLiveSettledSectionHrefs = new Set()
        host.__manabiFirstLiveSectionHref = null
        host.__manabiFinishEPUBLoadWatchdogs = null
        try {
            load.reader = new Reader()
            if (!ownsLoad(load) || load.retired) {
                load.reader.close('loadEBook.superseded-setup')
                return host.manabiLoadEBookPromise
            }
            host.reader = load.reader
            load.reader.onLoadClosed = () => retireLoad(load)
            load.nativeSource = requestedURL.startsWith('ebook://') ? makeNativeSource(requestedURL) : null
            assertCurrent(load)
            load.sourcePath = requestedURL ? new URL(requestedURL, host.location.href).pathname : 'book.epub'
            load.resources = new EbookLoadResources({ nativeSource: load.nativeSource, sourcePath: load.sourcePath })
            load.cacheWarmer = new CacheWarmer({ loadResources: load.resources })
            if (!liveLoad(load)) {
                load.cacheWarmer.destroy()
                load.resources.close()
                return host.manabiLoadEBookPromise
            }
            host.cacheWarmer = load.cacheWarmer
            if (!requestedURL) {
                host.manabiLoadEBookLastState = 'no-url'
                closeLoad(load, 'loadEBook.no-url')
                if (host.reader === load.reader) host.reader = null
                return
            }
            load.promise = Promise.resolve().then(() => runLoad(load))
            host.manabiLoadEBookPromise = load.promise
            return load.promise
        } catch (error) {
            closeLoad(load, 'loadEBook.setup-error')
            if (host.reader === load.reader) host.reader = null
            throw error
        }
    }
    return { loadEBook, loadLastPosition }
}
