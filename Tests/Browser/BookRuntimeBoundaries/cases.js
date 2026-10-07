// Actual runtime/state/endcap/bridge and DOM. Only native endpoints and the
// paginator interface are controlled. No test calls a native writer.
const expect = (condition, message) => { if (!condition) throw new Error(message) }
const cleanup = f => { try { f.close() } catch (_) {} }
const make = async options => {
    const f = await makeBookStateRuntimeFixture(options)
    expect(f.apply(f.result()), 'Initial native sample was not accepted')
    return f
}
const targetFor = f => ({ action: 'startBookOver', accountPresentation: f.runtime.state.accountPresentation,
    articleProgressID: 'book', articleEpochID: 'pass', locationRevision: f.runtime.state.locationRevision })
const makeChapter = async name => {
    const iframe = document.createElement('iframe')
    iframe.title = name
    iframe.srcdoc = '<!doctype html><p id="state">Loading</p>'
    const loaded = new Promise(resolve => iframe.onload = resolve)
    document.body.append(iframe)
    await loaded
    const doc = iframe.contentDocument
    doc.defaultView.manabi_invalidateBookReadingScope = () => {
        doc.defaultView.manabi_bookReadingScope = null
        doc.getElementById('state').textContent = 'Loading'
    }
    doc.defaultView.manabi_applyBookReadingPresentation = projection => {
        doc.getElementById('state').textContent = 'Revision ' + projection.revision
        return true
    }
    return doc
}
window.bookRuntimeBoundaryCases = []
const add = (name, run) => bookRuntimeBoundaryCases.push({ name, run })

for (const seam of ['frame', 'enumeration', 'shell']) {
    add(`close restores real publication accessibility despite ${seam} failure`, async () => {
        const f = await make({ end: true }), cap = f.runtime.endcap
        try {
            expect(f.view.inert, 'The endcap never made its publication inert')
            if (seam === 'frame') f.doc.defaultView.manabi_invalidateBookReadingScope = () => { throw new Error('retiring frame') }
            if (seam === 'enumeration') f.view.renderer.getContents = () => { throw new Error('retiring renderer') }
            if (seam === 'shell') f.runtime.state.onInvalidate = () => { throw new Error('retiring observer') }
            let failure
            try { f.close() } catch (error) { failure = error }
            expect(!failure, 'One cleanup failure escaped and interrupted teardown')
            expect(!f.view.inert && f.view.getAttribute('aria-hidden') === null, 'Closed reader retained inaccessible publication')
            expect(!cap.visible && !cap.element.isConnected, 'Endcap survived runtime closure')
            cap.button.click()
            await f.tick()
            expect(f.commands.length === 0, 'Detached old control still issued a command')
        } finally { cleanup(f) }
    })
}

add('a hidden iframe invalidation failure does not suppress the accepted visible projection', async () => {
    const f = await make(), hidden = await makeChapter('hidden')
    try {
        f.view.renderer.getContents = () => [{ index: 0, doc: f.doc }, { index: 1, doc: hidden, isDisplayed: false }]
        hidden.defaultView.manabi_invalidateBookReadingScope = () => { throw new Error('hidden frame') }
        f.runtime.state.refresh()
        expect(f.apply(f.result(2)), 'An unrelated frame prevented native acknowledgement')
        expect(f.visible() === 'Revision 2' && f.projections.at(-1).state.revision === 2, 'Visible and shell projections disagree')
    } finally { cleanup(f) }
})

for (const gap of ['empty', 'hidden', 'enumeration-error']) {
    add(`real missing-display ${gap} gap cannot expose previous chapter action context`, async () => {
        const f = await make()
        try {
            const renderer = f.view.renderer
            renderer.getContents = gap === 'empty' ? () => [] : gap === 'hidden'
                ? () => [{ index: 0, doc: f.doc, isDisplayed: false }]
                : () => { throw new Error('display not ready') }
            f.runtime.updateLocation()
            expect(!f.runtime.state.ready, 'No displayed chapter still exposed ready Book Actions')
            let rejected = false
            try { await f.runtime.bridge.perform('startBookOver') } catch (_) { rejected = true }
            expect(rejected && f.commands.length === 0, 'Missing display admitted an old chapter action')
            renderer.getContents = () => [{ index: 0, doc: f.doc }]
            f.runtime.updateLocation()
            expect(f.apply(f.result(3)), 'Displayed chapter did not recover normally')
            expect(f.runtime.state.ready, 'Restored document stayed unavailable')
        } finally { cleanup(f) }
    })
}

add('nested displayed iframe replacement retains the newest sample and event receipt', async () => {
    const f = await make(), second = await makeChapter('second'), third = await makeChapter('third')
    try {
        const clear = f.doc.defaultView.manabi_invalidateBookReadingScope
        f.doc.defaultView.manabi_invalidateBookReadingScope = () => {
            f.doc.defaultView.manabi_invalidateBookReadingScope = clear
            clear()
            f.view.renderer.getContents = () => [{ index: 0, doc: third }]
            f.runtime.updateLocation()
            expect(f.apply(f.result(3)), 'Nested displayed sample rejected')
        }
        f.view.renderer.getContents = () => [{ index: 0, doc: second }]
        f.runtime.updateLocation()
        expect(f.runtime.state.ready, 'Outer cleanup withdrew the nested sample')
        expect(third.getElementById('state').textContent === 'Revision 3', 'Outer cleanup repainted the replacement iframe')
        expect(!!f.runtime.captureEvent(third), 'The newest actual Document lost its receipt')
    } finally { cleanup(f) }
})

for (const seam of ['scope-setter', 'projector-lookup']) {
    add(`iframe ${seam} cannot repaint an older accepted native revision`, async () => {
        const f = await make(), frame = f.doc.defaultView
        try {
            const project = frame.manabi_applyBookReadingPresentation
            if (seam === 'scope-setter') {
                Object.defineProperty(frame, 'manabi_bookReadingScope', { configurable: true, set(value) {
                    Object.defineProperty(frame, 'manabi_bookReadingScope', { value, configurable: true, writable: true })
                    expect(f.native(f.result(3)), 'Newer native revision rejected')
                } })
            } else {
                Object.defineProperty(frame, 'manabi_applyBookReadingPresentation', { configurable: true, get() {
                    Object.defineProperty(frame, 'manabi_applyBookReadingPresentation', { value: project, configurable: true, writable: true })
                    expect(f.native(f.result(3)), 'Newer native revision rejected')
                    return project
                } })
            }
            expect(!f.native(f.result(2)), 'Old publication was acknowledged after replacement')
            expect(f.visible() === 'Revision 3', 'Actual chapter DOM regressed to older revision')
            expect(f.projections.at(-1).state.revision === 3, 'Shell did not keep its newer state')
        } finally { cleanup(f) }
    })
}

for (const failure of ['lookup', 'post-recovery-throw']) {
    add(`iframe invalidation ${failure} cannot remove a recovered native scope`, async () => {
        const f = await make(), frame = f.doc.defaultView
        try {
            const clear = frame.manabi_invalidateBookReadingScope
            const recover = () => {
                Object.defineProperty(frame, 'manabi_invalidateBookReadingScope', { value: clear, writable: true, configurable: true })
                f.runtime.state.refresh()
                expect(f.apply(f.result(2)), 'Fresh sample rejected')
                return clear
            }
            if (failure === 'lookup') Object.defineProperty(frame, 'manabi_invalidateBookReadingScope', { configurable: true, get: recover })
            else frame.manabi_invalidateBookReadingScope = () => { clear(); recover(); throw new Error('old wrapper') }
            f.runtime.state.refresh()
            f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' })
            expect(f.runtime.state.ready && !!frame.manabi_bookReadingScope, 'Recovery lost its physical frame scope')
            expect(f.visible() === 'Revision 2', 'Recovery DOM was cleared by older cleanup')
        } finally { cleanup(f) }
    })
}

for (const seam of ['spine', 'handler']) {
    for (const boundary of ['account', 'location', 'renderer', 'close']) {
        add(`navigation dispatch cannot cross ${boundary} in ${seam} lookup`, async () => {
            const f = await make(), renderer = f.view.renderer
            let moves = 0
            renderer.goTo = async () => { moves++; return true }
            try {
                const target = targetFor(f)
                const retire = () => {
                    if (boundary === 'account') f.runtime.accountDidChange('2:1')
                    if (boundary === 'location') f.runtime.updateLocation(true)
                    if (boundary === 'renderer') f.view.renderer = { currentIndex: 0, getContents: () => [] }
                    if (boundary === 'close') f.runtime.close()
                }
                if (seam === 'spine') Object.defineProperty(f.view.book.sections[0], 'linear', { get() { retire(); return 'yes' } })
                else {
                    const move = renderer.goTo
                    Object.defineProperty(renderer, 'goTo', { get() { retire(); return move } })
                }
                const result = await f.runtime.navigate(target)
                expect(result.status === 'superseded' && moves === 0, 'Retired action dispatched a physical navigation')
            } finally { cleanup(f) }
        })
    }
}

add('renderer supersession does not expose another Go to Beginning recovery', async () => {
    const f = await make({ end: true })
    try {
        f.view.renderer.goTo = async () => ({ superseded: true, ignored: true, reason: 'newer user navigation' })
        const result = await f.runtime.navigate(targetFor(f))
        expect(result.status === 'superseded', 'Newer navigation was relabeled as retryable failure')
        f.runtime.endcap.setFinished(true)
        f.runtime.endcap.performAction = async () => ({ ok: true, committed: true, requestID: 'original', navigation: result })
        f.runtime.endcap.button.click()
        await f.tick()
        expect(f.runtime.endcap.button.textContent !== 'Go to Beginning', 'Old movement offered another pull-back')
    } finally { cleanup(f) }
})

add('successful navigation may legitimately change the displayed document and revision', async () => {
    const f = await make(), next = await makeChapter('destination')
    try {
        f.view.renderer.goTo = async () => {
            f.view.renderer.getContents = () => [{ index: 0, doc: next }]
            f.runtime.updateLocation(true)
            expect(f.apply(f.result(2)), 'Destination publication rejected')
            return true
        }
        const result = await f.runtime.navigate(targetFor(f))
        expect(result.status === 'completed', 'The original dispatch guard rejected its own legitimate movement')
        expect(next.getElementById('state').textContent === 'Revision 2', 'Destination did not render')
    } finally { cleanup(f) }
})

for (const kind of ['scope', 'event']) {
    add(`a delayed ${kind} check cannot borrow equal recovered native pass values`, async () => {
        const f = await make(), renderer = f.view.renderer
        try {
            const receipt = kind === 'scope' ? f.runtime.captureScope(f.doc) : f.runtime.captureEvent(f.doc)
            const getContents = renderer.getContents
            renderer.getContents = () => {
                renderer.getContents = getContents
                f.runtime.state.refresh()
                f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' })
                f.runtime.state.refresh()
                expect(f.apply(f.result(2)), 'Recovered native display rejected')
                return getContents()
            }
            const permitted = kind === 'scope' ? f.runtime.isScopeCurrent(receipt, f.doc) : f.runtime.isEventCurrent(receipt)
            expect(!permitted, 'An old delayed operation was authorized with recovered scope values')
            expect(f.runtime.isEventCurrent(f.runtime.captureEvent(f.doc)), 'A genuinely new event was rejected')
            expect(f.commands.length === 0, 'Receipt validation caused native mutation')
        } finally { cleanup(f) }
    })
}

for (const boundary of ['invalidation', 'account', 'page-turn']) {
    add(`event capture retains its original ${boundary} boundary across renderer lookup`, async () => {
        const f = await make(), renderer = f.view.renderer
        try {
            const getContents = renderer.getContents
            renderer.getContents = () => {
                renderer.getContents = getContents
                if (boundary === 'invalidation') {
                    f.runtime.state.refresh()
                    f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' })
                    f.runtime.state.refresh()
                } else if (boundary === 'account') f.runtime.accountDidChange('2:1')
                else f.runtime.updateLocation(true)
                expect(f.apply(f.result(2)), 'New display rejected')
                return getContents()
            }
            expect(f.runtime.captureEvent(f.doc) === null, 'A capture adopted a successor that did not observe the event')
            expect(!!f.runtime.captureEvent(f.doc), 'A new event did not recover')
        } finally { cleanup(f) }
    })
}

add('ordinary same-pass refresh preserves the originally captured live event', async () => {
    const f = await make(), renderer = f.view.renderer
    try {
        const event = f.runtime.captureEvent(f.doc), getContents = renderer.getContents
        renderer.getContents = () => {
            renderer.getContents = getContents
            f.runtime.state.refresh()
            expect(f.apply(f.result(2)), 'Ordinary refresh rejected')
            return getContents()
        }
        expect(f.runtime.isEventCurrent(event), 'A routine same-pass refresh falsely retired an event')
        expect(f.visible() === 'Revision 2', 'Visible state did not refresh')
    } finally { cleanup(f) }
})

add('scope capture cannot acquire an account selected during the controller method lookup', async () => {
    const f = await make(), state = f.runtime.state
    try {
        const capture = state.captureScope
        Object.defineProperty(state, 'captureScope', { configurable: true, get() {
            Object.defineProperty(state, 'captureScope', { value: capture, configurable: true, writable: true })
            f.runtime.accountDidChange('2:1')
            expect(f.apply(f.result(2)), 'The successor native account sample was rejected')
            return capture
        } })
        expect(f.runtime.captureScope(f.doc) === null, 'The old capture borrowed new account state')
        expect(!!f.runtime.captureScope(f.doc), 'A new account capture stayed blocked')
    } finally { cleanup(f) }
})

add('scope comparison does not trust equal keys after a wrapped receipt retires itself', async () => {
    const f = await make()
    try {
        const scope = f.runtime.captureScope(f.doc), epoch = scope.articleEpochID
        Object.defineProperty(scope, 'articleEpochID', { configurable: true, get() {
            Object.defineProperty(scope, 'articleEpochID', { value: epoch, configurable: true, writable: true })
            f.runtime.state.refresh()
            f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' })
            f.runtime.state.refresh()
            expect(f.apply(f.result(2)), 'Recovered native sample was not accepted')
            return epoch
        } })
        expect(!f.runtime.isScopeCurrent(scope, f.doc), 'Equal scope values revived a retired wrapped receipt')
        expect(f.runtime.isEventCurrent(f.runtime.captureEvent(f.doc)), 'A newly observed event was rejected')
    } finally { cleanup(f) }
})
