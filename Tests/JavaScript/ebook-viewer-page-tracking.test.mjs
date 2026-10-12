import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'

// Evaluate the complete shipping Reader class. Only the module/startup adapter
// and DOM/native collaborators are replaced; no command or render method is
// copied into a second implementation.
const source = readFileSync(new URL(
    '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-viewer.js', import.meta.url
), 'utf8')
const classStart = source.indexOf('class Reader {')
const classEnd = source.indexOf('\n}\n', classStart)
const readerClass = source.slice(classStart, classEnd)

function fixture() {
    const packets = [], requests = [], attributes = new Map()
    const doc = { location: { href: 'ebook://fixture/chapter.xhtml' }, defaultView: {}, body: {} }
    const visibleRange = { collapsed: false }
    const producerOwner = { required: false }
    class Element {}
    const context = vm.createContext({
        console, Map, Set, Promise, HTMLElement: Element, Element,
        performance: { now: () => 0 },
        performanceNowMs: () => 0,
        document: {
            body: { dataset: {}, setAttribute: (key, value) => attributes.set(key, value) },
            getElementById: () => null, querySelector: () => null,
        },
        screen: { orientation: {} },
        $: () => null,
        normalizeArticleReadingProgress: value => value ?? {},
        debounce: callback => callback,
        applyStoredChromeInsets() {},
        NavigationHUD: class { refreshAuxiliaryLayout() {} },
        createNativeMarkReadRequestCoordinator: () => ({ request: async request => {
            requests.push(request)
            return { success: false, errorCode: 'fixture-rejection' }
        } }),
        presentNativeMarkReadPending() {},
        nativeMarkReadCommandMessage: (payload, identity) => ({ ...identity,
            stableSegmentIDs: payload.segments.map(segment => segment.stableSegmentID),
            sentenceIdentifiers: payload.sentenceIdentifiers }),
        stableEbookSegmentIdentityVersion: 1,
        readerDocumentStartedAtMs: () => 1,
        captureReaderArticleProducerOwner: () => producerOwner,
        readerArticleProducerOwnerIsCurrent: () => true,
        ignoreNextIncomingHideNavigation() {},
        ignoreNextIncomingRevealNavigation() {},
        isDocumentLike: value => value === doc,
        getCurrentRendererDocument: renderer => renderer?.getContents?.()[0]?.doc ?? null,
        getPrimaryRendererContent: renderer => renderer?.getContents?.()[0] ?? null,
        visibleRangeForNavigationHUDDocument: () => visibleRange,
        visiblePageSegmentCollectionOptions: (_mode, options) => options,
        visibleTrackingSignatureForResult: (_doc, result) => result.signature,
        buildVisiblePageTrackingStates: (_doc, _progress, _range, result) => ({
            states: result.states, diagnostics: {},
        }),
        shouldInvalidateVisibleSegmentGeometryForReason: () => true,
        MANABI_ENABLE_EBOOK_PAGE_TRACKING_BUTTONS: false,
        manabiTimelineMeasure() {}, cancelAnimationFrame() {}, clearTimeout() {},
    })
    context.window = context
    context.top = context
    context.location = { href: 'ebook://fixture/book.epub' }
    context.webkit = { messageHandlers: {
        ebookNativeMarkReadState: { postMessage: packet => packets.push(packet) },
        nativeLookupHitTargetsUpdated: { postMessage() {} },
    } }
    const Reader = vm.runInContext(`${readerClass}
        testRender(reason) { this.#renderPageTrackingButtons(reason) }
        testInvalidate() { this.#invalidateVisiblePageSegmentSnapshot('renderer.relocate') }
        testMarkCluster() { return this.#markPageClusterAsRead('visible-screen') }
    }; Reader`, context)
    const reader = new Reader()
    context.reader = reader
    reader.view = { renderer: { getContents: () => [{ doc }] } }
    const state = (sentence, isRead = false) => ({ id: 'visible-screen', isRead,
        payload: { stableIdentityVersion: 1, segments: [], sentenceIdentifiers: [sentence] } })
    const installPage = (sentence, isRead = false) => {
        const states = [state(sentence, isRead)]
        reader.visiblePageSegmentSnapshot = {
            doc, visibleRange, generation: reader.visiblePageCollectionGeneration,
            includeSegmentMetadata: true, includeClientRects: false,
            result: { signature: sentence, states, visibleSegments: [] },
        }
        return states
    }
    const seedPage = (sentence, isRead = false) => {
        reader.pageTrackingStates = installPage(sentence, isRead)
        reader.pageTrackingStatesGeneration = reader.visiblePageCollectionGeneration
        reader.testRender('fixture-current-page')
    }
    return { reader, packets, requests, attributes, seedPage, installPage, visibleRange }
}

test('invalidating a read page immediately withdraws native read controls and marker', () => {
    const f = fixture()
    f.seedPage('previous-page', true)
    assert.equal(f.packets.at(-1).isRead, true)
    f.reader.testInvalidate()
    assert.equal(f.packets.at(-1).available, false)
    assert.equal(f.packets.at(-1).isRead, false)
    assert.equal(f.attributes.get('data-page-read-marker-read'), 'false')
})

test('a Mark tap after invalidation hydrates the current page instead of posting previous subjects', async () => {
    const f = fixture()
    f.seedPage('previous-page')
    f.reader.testInvalidate()
    f.installPage('current-page')
    await f.reader.markVisiblePageAsRead()
    assert.equal(f.requests.length, 1)
    assert.deepEqual(Array.from(f.requests[0].message.sentenceIdentifiers), ['current-page'])
})

test('a Mark tap cannot report an invalidated read page as the current page when fresh geometry is unavailable', async () => {
    const f = fixture()
    f.seedPage('previous-page', true)
    f.reader.testInvalidate()
    f.visibleRange.collapsed = true
    assert.equal(await f.reader.markVisiblePageAsRead(), false)
    assert.equal(f.requests.length, 0)
})

test('late Mark completion cannot republish an invalidated page before its replacement sample', async () => {
    const f = fixture()
    f.seedPage('previous-page')
    let settle
    f.reader.nativeMarkReadRequestCoordinator.request = request => {
        f.requests.push(request)
        return new Promise(resolve => { settle = resolve })
    }
    const operation = f.reader.testMarkCluster()
    assert.equal(f.requests.length, 1)
    f.reader.testInvalidate()
    settle({ success: false, stale: true, errorCode: 'cancelled' })
    await operation
    assert.equal(f.packets.at(-1).available, false)
    assert.equal(f.packets.at(-1).isBusy, false)
    assert.equal(f.attributes.get('data-page-read-marker-read'), 'false')
})

test('a page turn during demand hydration cannot retarget the original tap to a populated successor page', async () => {
    const f = fixture()
    f.installPage('original-page')
    const operation = f.reader.markVisiblePageAsRead()
    // The demand read returned its original sample, but its async continuation
    // has not resumed. A same-chapter relocation retains producer/book scope.
    f.reader.testInvalidate()
    f.seedPage('successor-page')
    assert.equal(await operation, false)
    assert.equal(f.requests.length, 0)
})

test('a current page and independent completion action retain their presentation', async () => {
    const f = fixture()
    f.seedPage('current-page', true)
    assert.equal(await f.reader.markVisiblePageAsRead(), true)
    assert.equal(f.requests.length, 0)
    f.reader.completionAction = { type: 'finish', label: 'Finish' }
    f.reader.completionActionBusy = true
    f.reader.testInvalidate()
    f.reader.testRender('fixture-completion')
    assert.equal(f.packets.at(-1).available, true)
    assert.equal(f.packets.at(-1).stateID, 'completion-action:finish')
    assert.equal(f.packets.at(-1).isBusy, true)
})
