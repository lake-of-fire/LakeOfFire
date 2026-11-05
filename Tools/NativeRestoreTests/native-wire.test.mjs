import assert from 'node:assert/strict'
import test from 'node:test'
import { readFileSync } from 'node:fs'
import { createEbookLoadHandlers, createNavigationIntentRunner } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-load-coordinator.js'
import { makeNativeEbookSource } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-native-source-request.js'

// This file reads *generated wire data*, never repository implementation text.
// The runner exports it with the actual Swift value and native bridge first.
const records = JSON.parse(readFileSync(process.env.NATIVE_RESTORE_WIRE_FIXTURES, 'utf8'))
const record = name => {
    const found = records.find(value => value.name === name)
    assert.ok(found, `Missing native fixture ${name}`)
    return found
}
const sourceURL = 'ebook://ebook/load/local/Books/native-restore-fixture.epub'

const fixture = t => {
    const events = [], messages = []
    let nextFrame = 0
    const frames = new Map()
    const host = {
        document: {}, location: { href: 'https://reader.invalid/viewer' },
        setTimeout, clearTimeout,
        requestAnimationFrame(callback) {
            const id = ++nextFrame
            frames.set(id, callback)
            queueMicrotask(() => { if (frames.delete(id)) callback() })
            return id
        },
        cancelAnimationFrame(id) { frames.delete(id) },
        webkit: { messageHandlers: { ebookViewerLoaded: { postMessage: value => messages.push(value) } } },
    }
    class Reader {
        open(source) {
            this.source = source
            this.view = {
                lastLocation: { fraction: 0.6 },
                renderer: {
                    next: () => { events.push(['next']); this.view.lastLocation.fraction = 0.1 },
                    nextSection: () => { events.push(['nextSection']) },
                },
                goTo: cfi => { events.push(['cfi', cfi]) },
                goToFraction: fraction => { events.push(['fraction', fraction]); this.view.lastLocation.fraction = fraction },
            }
        }
        completeLastPositionLoad() { this.hasLoadedLastPosition = true; events.push(['complete']) }
        completeLastPositionLoadAttempt() { events.push(['attempt']) }
        close() { this.isClosed = true; this.onLoadClosed?.(); this.view = null }
    }
    class CacheWarmer {
        constructor({ loadResources }) { this.resources = loadResources }
        destroy() { this.resources.close() }
    }
    const handlers = createEbookLoadHandlers({
        host, Reader, CacheWarmer, makeNativeSource: makeNativeEbookSource,
        makeFileSource: () => { assert.fail('This fixture must not switch to a remote file') },
        installReaderPresentationState() {}, beginReplaceTextCacheGeneration() {},
        beginForegroundCriticalSection: () => 1, finishForegroundCriticalSection() {},
        ensureRestorePositionSaveUserInputTracking() {},
        runWithNavigationIntent: createNavigationIntentRunner(host),
        markReaderRenderReady() {}, postLandscapeInsetRestoreProbe() {}, scheduleDeferredCacheWarmerOpen() {},
    })
    t.after(() => host.reader?.close())
    return { ...handlers, host, events, messages }
}

for (const name of ['zero', 'negativeZero', 'end', 'fraction']) {
    test(`native ${name} payload reaches fraction navigation, not default opening`, async t => {
        const wire = record(name)
        assert.equal(wire.rejected, false)
        assert.equal(typeof wire.initialRestore.fractionalCompletion, 'number')
        const f = fixture(t)
        await f.loadEBook({ url: sourceURL, initialRestore: wire.initialRestore })
        assert.deepEqual(f.events.filter(event => event[0] === 'fraction'), [['fraction', wire.initialRestore.fractionalCompletion]])
        assert.equal(f.events.some(event => event[0] === 'next' || event[0] === 'nextSection'), false)
        assert.equal(f.messages.length, 1)
        assert.equal(f.messages[0].initialRestoreResult.requestID, wire.initialRestore.requestID)
        assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, true)
        assert.equal(f.messages[0].initialRestoreResult.terminalState, 'satisfied')
    })
}

for (const name of ['cfiOnly', 'cfiHistoricalZero']) {
    test(`native ${name} payload preserves exact CFI and CFI precedence`, async t => {
        const wire = record(name)
        const f = fixture(t)
        await f.loadEBook({ url: sourceURL, initialRestore: wire.initialRestore })
        assert.deepEqual(f.events.filter(event => event[0] === 'cfi'), [['cfi', wire.initialRestore.cfi]])
        assert.equal(f.events.some(event => ['fraction', 'next', 'nextSection'].includes(event[0])), false)
        assert.equal(f.messages[0].initialRestoreResult.requestID, wire.initialRestore.requestID)
        assert.equal(f.messages[0].initialRestoreResult.restoreSatisfied, true)
    })
}

test('native absent locator is still a legitimate default opening', async t => {
    const wire = record('missing')
    assert.equal(wire.rejected, false)
    assert.equal(wire.initialRestore, null)
    const f = fixture(t)
    await f.loadEBook({ url: sourceURL, initialRestore: wire.initialRestore })
    assert.deepEqual(f.events.filter(event => event[0] === 'next'), [['next']])
    assert.equal(f.messages[0].initialRestoreResult.terminalState, 'noTarget')
})

test('invalid native saved data is an error, not a serialized no-target request', () => {
    for (const name of ['invalidWithCFI', 'invalidWithoutCFI']) {
        const wire = record(name)
        assert.equal(wire.rejected, true)
        assert.equal(Object.hasOwn(wire, 'initialRestore'), false)
    }
    assert.equal(Object.hasOwn(record('missing'), 'initialRestore'), true)
})
