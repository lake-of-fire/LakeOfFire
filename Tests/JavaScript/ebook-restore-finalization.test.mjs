import assert from 'node:assert/strict'
import test from 'node:test'
import { createEbookLoadHandlers, createNavigationIntentRunner } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-load-coordinator.js'

// A minimal browser boundary for the two caller-specific completion contracts.
// Navigation and finalization run through the actual production coordinator.
const harness = () => {
    const calls = [], ended = [], messages = []
    let navigate = () => undefined
    const host = {
        document: {}, location: { href: 'https://reader.invalid/' },
        setTimeout, clearTimeout,
        requestAnimationFrame: callback => setTimeout(callback, 0),
        cancelAnimationFrame: clearTimeout,
        webkit: { messageHandlers: { ebookViewerLoaded: { postMessage: value => messages.push(value) } } },
    }
    class Reader {
        async open() {
            this.view = {
                lastLocation: { fraction: 0.25 }, renderer: {},
                goTo: cfi => { calls.push(['cfi', cfi]); return navigate(cfi) },
                goToFraction: value => { calls.push(['fraction', value]) },
            }
        }
        completeLastPositionLoad() { this.hasLoadedLastPosition = true; calls.push(['complete']) }
        completeLastPositionLoadAttempt() { calls.push(['attempt']) }
        close() { this.isClosed = true; this.onLoadClosed?.() }
    }
    const handlers = createEbookLoadHandlers({ host, Reader,
        CacheWarmer: class { destroy() {} },
        makeNativeSource: url => ({ kind: 'native', url }),
        makeFileSource: () => { throw new Error('Unexpected nonnative source') },
        installReaderPresentationState() {}, beginReplaceTextCacheGeneration() {},
        beginForegroundCriticalSection: () => 1,
        finishForegroundCriticalSection: token => ended.push(token),
        ensureRestorePositionSaveUserInputTracking() {},
        runWithNavigationIntent: createNavigationIntentRunner(host),
        markReaderRenderReady() {}, postLandscapeInsetRestoreProbe() {}, scheduleDeferredCacheWarmerOpen() {},
    })
    return { ...handlers, host, calls, ended, messages, setNavigation(value) { navigate = value } }
}
const request = fraction => ({ url: 'ebook://reader/book.epub',
    initialRestore: { requestID: 'initial', cfi: 'epubcfi(/6/2)', fractionalCompletion: fraction } })

test('a historical zero alongside a CFI never substitutes the beginning for the authoritative CFI', async () => {
    const f = harness()
    await f.loadEBook(request(0))
    assert.equal(f.calls.filter(value => value[0] === 'fraction').length, 0)
    assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, true)
    await f.loadLastPosition({ cfi: 'epubcfi(/6/4)', fractionalCompletion: 0 })
    assert.deepEqual(f.calls.filter(value => value[0] === 'cfi').map(value => value[1]),
        ['epubcfi(/6/2)', 'epubcfi(/6/4)'])
    assert.equal(f.calls.filter(value => value[0] === 'fraction').length, 0)
    assert.equal(f.calls.filter(value => value[0] === 'complete').length, 2)
})

test('failed direct restoration superseding initialization releases its own foreground admission', async () => {
    const f = harness()
    let releaseFirst, didNavigate
    const firstGate = new Promise(resolve => { releaseFirst = resolve })
    const navigationStarted = new Promise(resolve => { didNavigate = resolve })
    f.setNavigation(() => { didNavigate(); return firstGate })
    const first = f.loadEBook(request(0.25))
    await navigationStarted
    f.setNavigation(() => { throw new Error('direct failure') })
    await assert.rejects(f.loadLastPosition({ cfi: 'direct' }), /direct failure/)
    await first
    assert.equal(f.messages.length, 0)
    assert.deepEqual(f.ended, [1])
    assert.equal(f.host.reader.hasLoadedLastPosition, false)
    releaseFirst()
})
