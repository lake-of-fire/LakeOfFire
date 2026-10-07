// Actual runtime, endcap, action bridge and state controller; only the native
// message endpoints, Core frame projector and paginator interface are controlled.
window.makeBookStateRuntimeFixture = async ({ end = false } = {}) => {
    const stage = document.createElement('main')
    stage.id = 'reader-stage'
    const view = document.createElement('div')
    const frame = document.createElement('iframe')
    frame.title = 'Test chapter'
    frame.srcdoc = '<!doctype html><body><p id="state">Loading</p></body>'
    const loaded = new Promise(resolve => { frame.onload = resolve })
    view.append(frame)
    stage.append(view)
    document.body.append(stage)
    await loaded
    const doc = frame.contentDocument
    const projections = [], requests = [], commands = [], invalidations = []
    const owner = Object.freeze({ token: 'test-producer', frameURL: location.href, documentStartedAtMs: 100 })
    window.manabiArticleProducer = {
        captureIfReady: () => owner,
        own: (payload, candidate) => candidate === owner ? { ...payload, readerArticleProducer: owner } : null,
    }
    let sequence = 0, runtime
    if (typeof crypto.randomUUID !== 'function') {
        crypto.randomUUID = () => '00000000-0000-4000-8000-' + String(++sequence).padStart(12, '0')
    }
    window.webkit = { messageHandlers: {
        ebookBookReadingState: { postMessage: payload => requests.push(payload) },
        ebookBookAction: { postMessage: payload => {
            commands.push(payload)
            queueMicrotask(() => runtime.bridge.acknowledge(payload.deliveryID, {
                requestID: payload.requestID, accountPresentation: runtime.state.accountPresentation,
                ok: true, committed: true, navigation: { status: 'completed' },
            }))
        } },
    } }
    doc.defaultView.manabi_applyBookReadingPresentation = projection => {
        doc.getElementById('state').textContent = 'Revision ' + projection.revision
        return true
    }
    doc.defaultView.manabi_invalidateBookReadingScope = () => {
        doc.defaultView.manabi_bookReadingScope = null
        doc.getElementById('state').textContent = 'Loading'
    }
    view.renderer = { currentIndex: 0, getContents: () => [{ index: 0, doc, isDisplayed: true }] }
    view.book = { sections: [{ id: 'chapter.xhtml', linear: 'yes' }] }
    const reader = { view }
    runtime = window.BookStateTestModules.installBookReadingRuntime({
        reader, view, document, window, documentStartedAtMs: 100,
        applyProjection: (state, details) => projections.push({ state, details }),
        invalidateProjection: () => invalidations.push(true), onVisibility: () => {},
    })
    runtime.state.makeRequestID = () => 'state-' + ++sequence
    runtime.updateLocation()
    if (end) runtime.endcap.enter()
    const result = (revision = 1, stamp = runtime.state.accountPresentation ?? '1:1') => {
        const endPage = runtime.state.location.isEndPage
        const scope = endPage ? null : { articleProgressID: 'book', articleEpochID: 'pass',
            chapterKey: 'a'.repeat(64), chapterEpochID: null }
        return { ok: true, accountPresentation: stamp,
            state: { revision, articleProgressID: 'book', articleEpochID: 'pass', scope, finished: false,
                bookReadPresence: 'present', chapterReadPresence: endPage ? 'empty' : 'present',
                readSegmentIdentifiers: ['segment-' + revision], sentenceIdentifiersRead: ['sentence-' + revision] },
            context: { contextID: 'context-' + revision, articleProgressID: 'book', articleEpochID: 'pass', scope,
                isEndPage: endPage, sectionLocation: endPage ? null : 'chapter.xhtml' } }
    }
    const apply = packet => runtime.state.apply(requests.at(-1).requestID, packet)
    const native = packet => runtime.state.apply('native', { ...packet, nativeRefresh: true,
        location: { ...runtime.state.location, locationRevision: runtime.state.locationRevision } })
    const tick = async () => { for (let n = 0; n < 6; ++n) await Promise.resolve() }
    return { runtime, doc, view, reader, projections, requests, commands, invalidations, result, apply, native, tick,
        visible: () => doc.getElementById('state').textContent,
        close: () => runtime.close() }
}
