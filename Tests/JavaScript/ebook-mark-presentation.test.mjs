import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import { createNativeMarkReadRequestCoordinator } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'
import { getCurrentRendererDocument, getPrimaryRendererContent } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/renderer-content.js'
import { stableEbookSegmentIdentityVersion } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-segment-identity.js'

// Execute the actual viewer methods with a controlled renderer and bridge. This
// harness supplies browser IO only; all request, permission and delay decisions
// below come from the shipping viewer source, not duplicated decision logic.
const source = readFileSync(new URL('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-viewer.js', import.meta.url), 'utf8')
const between = (start, end) => source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start)))
const methods = between('    #markReadOwner({', '    applyMarkSectionAsReadResult(result)')
    + between('    async markAllSectionsAsRead() {', '    async #markPageClusterAsRead(stateID)')
    + between('    async #advanceAfterMarkRead(owner) {', '    #releaseSideNavChevronHoverSuppression(key)')
const globals = between('const normalizeArticleReadingProgress =', 'const sentenceIdentifierForNode =')
    + between('const isDocumentLike =', 'const visibleRangeForNavigationHUDDocument =')

function harness() {
    const posted = [], delays = []
    const doc = { nodeType: 9, documentElement: {}, querySelectorAll: () => [], location: { href: 'https://fixture.invalid/chapter' } }
    const renderer = { currentIndex: 0, getContents: () => [{ index: 0, doc }] }
    const context = vm.createContext({
        getCurrentRendererDocument, getPrimaryRendererContent, stableEbookSegmentIdentityVersion,
        window: { top: { location: { href: 'ebook://fixture/book' }, performance: { timeOrigin: 1 } } },
        readerDocumentStartedAtMs: () => 1,
        setTimeout: callback => { delays.push(callback) },
    })
    const Reader = vm.runInContext(`${globals}\n(class {
        #lifecycleGeneration = 1;
        #isRendererLifecycleCurrent(generation, renderer) { return generation === this.#lifecycleGeneration && renderer === this.view.renderer; }
        ${methods}
        replaceVisit() { this.#lifecycleGeneration += 1; }
        submit(payload) { return this.#submitMarkReadPayload(payload, {sectionID: 'section', owner: this.#markReadOwner({document: this.doc, requireVisibleGeneration: true}), reason: 'test'}); }
        advance(outcome) { return this.#advanceAfterMarkRead({...this.#markReadOwner({document: this.doc}), presentation: outcome.presentation, permitsAutoAdvance: outcome.permitsAutoAdvance}); }
    })`, context)
    const reader = new Reader()
    reader.doc = doc
    reader.visiblePageCollectionGeneration = 1
    reader.pageTrackingAnimateReadStateIDs = new Set()
    reader.articleReadingProgress = {}
    reader.repaints = 0
    reader.moves = 0
    reader.view = { renderer, goRight: async () => { reader.moves++; return true } }
    reader.applyBookReadingProgress = value => { reader.articleReadingProgress = value; reader.repaints++ }
    reader.buildMarkAllSectionsAsReadPayload = () => payload
    let sequence = 0
    reader.nativeMarkReadRequestCoordinator = createNativeMarkReadRequestCoordinator({
        postMessage: message => posted.push(message),
        makeRequestID: () => `request-${++sequence}`,
        scheduleTimeout: () => null,
        isOwnerCurrent: owner => owner.renderer === reader.view.renderer,
    })
    function reply(index, overrides = {}) {
        const message = posted[index]
        reader.nativeMarkReadRequestCoordinator.settle({
            requestID: message.requestID, sectionId: message.sectionId, success: true,
            permitsPresentation: true, permitsAutoAdvance: true, isMarked: true,
            stateSnapshotSequence: index + 1,
            displayEffectiveStableSegmentIDs: ['segment'], displayEffectiveStableSentenceIDs: ['sentence'],
            ...overrides,
        })
    }
    return { reader, posted, delays, reply }
}
const payload = {
    stableIdentityVersion: stableEbookSegmentIdentityVersion,
    segments: [{ stableSegmentID: 'segment', jmdictEntryIds: [1], jmnedictEntryIds: [], searchString: '語', displayText: '語' }],
    sentenceIdentifiers: ['sentence'],
}

test('request identity exists before native reply so fast cancellation suppresses repaint', async () => {
    const h = harness()
    const pending = h.reader.submit(payload)
    assert.equal(h.reader.pendingMarkReadPresentation.requestID, h.posted[0].requestID)
    assert.equal(h.reader.cancelPendingMarkReadPresentation(h.posted[0].requestID), true)
    h.reply(0)
    const result = await pending
    assert.equal(result.success, true)
    assert.equal(result.permitsAutoAdvance, false)
    assert.equal(h.reader.repaints, 0)
})

test('old cancellation and old reply cannot affect a superseding request', async () => {
    const h = harness()
    const older = h.reader.submit(payload)
    const newer = h.reader.submit(payload)
    assert.equal(h.reader.cancelPendingMarkReadPresentation(h.posted[0].requestID), false)
    h.reply(0)
    assert.equal((await older).permitsAutoAdvance, false)
    assert.equal(h.reader.repaints, 0)
    h.reply(1)
    assert.equal((await newer).permitsAutoAdvance, true)
    assert.equal(h.reader.repaints, 1)
})

for (const change of ['undo', 'visit', 'newRequest']) {
    test(`delayed EPUB advance rejects ${change} after committed repaint`, async () => {
        const h = harness()
        const pending = h.reader.submit(payload)
        h.reply(0)
        const result = await pending
        const advance = h.reader.advance(result)
        let newer
        if (change === 'undo') h.reader.cancelPendingMarkReadPresentation(h.posted[0].requestID)
        if (change === 'visit') h.reader.replaceVisit()
        if (change === 'newRequest') newer = h.reader.submit(payload)
        h.delays.shift()()
        assert.equal(await advance, false)
        assert.equal(h.reader.moves, 0)
        if (newer) { h.reply(1); await newer }
    })
}

test('old committed response after visit replacement cannot repaint', async () => {
    const h = harness()
    const pending = h.reader.submit(payload)
    h.reader.replaceVisit()
    h.reply(0)
    assert.equal((await pending).success, true)
    assert.equal(h.reader.repaints, 0)
})

test('Mark All resolves durable success independently from presentation permission', async () => {
    const h = harness()
    const pending = h.reader.markAllSectionsAsRead()
    h.reply(0, { permitsPresentation: false, permitsAutoAdvance: false })
    assert.equal(await pending, 1)
    assert.equal(h.reader.repaints, 0)
    assert.equal(h.reader.moves, 0)
})

test('Mark All fails for unavailable payload and failed native commit', async () => {
    const h = harness()
    h.reader.buildMarkAllSectionsAsReadPayload = () => null
    await assert.rejects(h.reader.markAllSectionsAsRead(), /unavailable/)
    h.reader.buildMarkAllSectionsAsReadPayload = () => payload
    const pending = h.reader.markAllSectionsAsRead()
    h.reply(0, { success: false })
    await assert.rejects(pending, /did not commit/)
    assert.equal(h.reader.repaints, 0)
    assert.equal(h.reader.moves, 0)
})
