// Complete runtime/endcap/bridge/controller composition. Only native response
// delivery, Core producer/frame projection, and paginator interfaces are inputs.
window.makeBookActionSettlementFixture = async () => {
    const stage = document.createElement('main')
    stage.id = 'reader-stage'
    const view = document.createElement('div')
    const frame = document.createElement('iframe')
    frame.srcdoc = '<!doctype html><body><p>Chapter</p></body>'
    const loaded = new Promise(resolve => { frame.onload = resolve })
    view.append(frame); stage.append(view); document.body.append(stage)
    await loaded
    const doc = frame.contentDocument
    const nativeSet = window.setTimeout.bind(window), nativeClear = window.clearTimeout.bind(window)
    const handles = new Set(), commands = [], requests = [], outcomes = [], hooks = {}
    let serial = 0, runtime
    window.setTimeout = (fn, delay, ...args) => {
        if (delay !== 15000) return nativeSet(fn, delay, ...args)
        if (hooks.install) return hooks.install(fn)
        const handle = nativeSet(fn, 80, ...args)
        handles.add(handle)
        return handle
    }
    window.clearTimeout = handle => {
        if (hooks.clear) return hooks.clear(handle)
        nativeClear(handle)
        handles.delete(handle)
    }
    crypto.randomUUID = () => '00000000-0000-4000-8000-' + String(++serial).padStart(12, '0')
    const owner = Object.freeze({ token: 'native-test-owner', frameURL: location.href, documentStartedAtMs: 100 })
    window.manabiArticleProducer = {
        captureIfReady: () => hooks.capture ? hooks.capture() : owner,
        own: (payload, candidate) => hooks.carry ? hooks.carry(payload, candidate)
            : candidate === owner ? { ...payload, readerArticleProducer: owner } : null,
    }
    window.webkit = { messageHandlers: {
        ebookBookReadingState: { postMessage: value => requests.push(value) },
        ebookBookAction: { postMessage: value => { commands.push(value); hooks.post?.(value) } },
    } }
    doc.defaultView.manabi_invalidateBookReadingScope = () => { doc.defaultView.manabi_bookReadingScope = null }
    doc.defaultView.manabi_applyBookReadingPresentation = () => true
    view.renderer = { currentIndex: 0, getContents: () => [{ index: 0, doc, isDisplayed: true }] }
    view.book = { sections: [{ id: 'chapter.xhtml', linear: 'yes' }] }
    runtime = BookStateTestModules.installBookReadingRuntime({
        reader: { view }, view, document, window, documentStartedAtMs: 100,
        applyProjection: () => {}, invalidateProjection: () => {}, onVisibility: () => {},
    })
    runtime.state.makeRequestID = () => 'state-' + ++serial
    runtime.updateLocation()
    runtime.endcap.enter()
    const publish = (finished = false, stamp = '1:1') => {
        runtime.state.refresh()
        return runtime.state.apply(requests.at(-1).requestID, {
        ok: true, accountPresentation: stamp,
        state: { revision: 1, articleProgressID: 'book', articleEpochID: 'pass', scope: null, finished,
            bookReadPresence: 'present', chapterReadPresence: 'empty',
            readSegmentIdentifiers: [], sentenceIdentifiersRead: [] },
        context: { contextID: 'context', articleProgressID: 'book', articleEpochID: 'pass', scope: null,
            isEndPage: true, sectionLocation: null },
        })
    }
    publish()
    const track = promise => {
        promise.then(value => outcomes.push({ ok: true, value }), error => outcomes.push({ ok: false, message: error.message }))
        return promise
    }
    runtime.endcap.performAction = action => track(runtime.bridge.perform(action))
    runtime.endcap.recoverAction = info => track(runtime.bridge.recover(info))
    const reply = (body = commands.at(-1), extra = {}) => ({ requestID: body.requestID,
        accountPresentation: runtime.state.accountPresentation, ok: true, committed: true,
        navigation: { status: 'completed' }, ...extra })
    const ack = (body = commands.at(-1), extra = {}) => runtime.bridge.acknowledge(body.deliveryID, reply(body, extra))
    const tick = async () => { for (let n = 0; n < 8; n++) await Promise.resolve() }
    const click = () => runtime.endcap.button.click()
    const state = () => ({ busy: runtime.endcap.busy, disabled: runtime.endcap.button.disabled,
        label: runtime.endcap.button.textContent, kinds: commands.map(value => value.kind) })
    return { runtime, doc, view, commands, requests, hooks, outcomes, publish, reply, ack, tick, click, state,
        wait: delay => new Promise(resolve => nativeSet(resolve, delay)),
        setNativeTimer: callback => { const handle = nativeSet(callback, 80); handles.add(handle); return handle },
        close() {
            hooks.clear = null; hooks.install = null
            runtime.close()
            for (const handle of handles) nativeClear(handle)
            window.setTimeout = nativeSet; window.clearTimeout = nativeClear
        } }
}
