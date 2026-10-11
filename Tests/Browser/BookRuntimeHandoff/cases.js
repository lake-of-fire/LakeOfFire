const require = (condition, message) => { if (!condition) throw new Error(message) }
const publishChapter = (f, revision = 2, chapterEpochID = null) => {
    f.runtime.state.refresh()
    const scope = { articleProgressID: 'book', articleEpochID: 'pass', chapterKey: 'a'.repeat(64), chapterEpochID }
    return f.runtime.state.apply(f.requests.at(-1).requestID, { ok: true, accountPresentation: f.runtime.state.accountPresentation,
        state: { revision, articleProgressID: 'book', articleEpochID: 'pass', scope, finished: false,
            bookReadPresence: 'present', chapterReadPresence: 'present', readSegmentIdentifiers: [`read-${revision}`], sentenceIdentifiersRead: [] },
        context: { contextID: `chapter-${revision}`, articleProgressID: 'book', articleEpochID: 'pass', scope,
            isEndPage: false, sectionLocation: 'chapter.xhtml' } })
}
const addHiddenFrame = async f => {
    const frame = document.createElement('iframe')
    frame.srcdoc = '<!doctype html><body>Preloaded chapter</body>'
    const loaded = new Promise(resolve => frame.onload = resolve)
    f.view.append(frame)
    await loaded
    const doc = frame.contentDocument
    const clear = () => { doc.defaultView.manabi_bookReadingScope = null }
    doc.defaultView.manabi_invalidateBookReadingScope = clear
    f.view.renderer.getContents = () => [{ index: 1, doc, isDisplayed: false }, { index: 0, doc: f.doc, isDisplayed: true }]
    return { frame, doc, clear }
}
window.bookRuntimeHandoffCases = []
const add = (name, run) => bookRuntimeHandoffCases.push({ name, run })
for (const phase of ['invalidate', 'publish', 'close']) {
    add(`hidden iframe failure does not block ${phase}`, async () => {
        const f = await makeBookActionSettlementFixture()
        const hidden = await addHiddenFrame(f)
        try {
            hidden.doc.defaultView.manabi_invalidateBookReadingScope = () => { throw new Error('hidden Core callback failed') }
            if (phase === 'invalidate') {
                let clears = 0
                f.doc.defaultView.manabi_invalidateBookReadingScope = () => { clears++; f.doc.defaultView.manabi_bookReadingScope = null }
                f.runtime.state.refresh()
                f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' })
                require(clears > 0, 'A hidden-frame exception prevented active-frame invalidation')
                require(f.runtime.endcap.button.disabled, 'Invalidated End of Book remained actionable')
                f.click()
                require(f.commands.length === 0, 'A disabled invalidated control posted a mutation')
            } else if (phase === 'publish') {
                require(f.publish(true), 'End-page publication was not acknowledged')
                require(f.runtime.endcap.button.textContent === 'Start Book Over', 'Finished chrome was stranded')
                f.click()
                require(f.commands.length === 1 && f.commands[0].action === 'startBookOver', 'Current real button did not dispatch selected action')
                f.ack(); await f.tick()
                require(!f.runtime.endcap.busy, 'Accepted result did not release busy state')
            } else {
                f.runtime.close()
                require(!f.runtime.endcap.element.isConnected && !f.view.inert, 'Teardown left publication inaccessible')
                require(!f.runtime.state.ready, 'Closed state remains ready')
            }
        } finally { hidden.doc.defaultView.manabi_invalidateBookReadingScope = hidden.clear; f.close() }
    })
}
add('ordinary chapter hydration survives hidden iframe failure', async () => {
    const f = await makeBookActionSettlementFixture(), hidden = await addHiddenFrame(f)
    try {
        f.runtime.endcap.leave()
        let read = null
        f.doc.defaultView.manabi_applyBookReadingPresentation = state => { read = state.readSegmentIdentifiers[0]; return true }
        hidden.doc.defaultView.manabi_invalidateBookReadingScope = () => { throw new Error('detached hidden projection') }
        require(publishChapter(f, 2), 'Chapter publication failed')
        require(read === 'read-2', 'Visible chapter did not receive native read state')
        require(f.runtime.captureEvent(f.doc) !== null, 'Current chapter did not receive event scope')
    } finally { hidden.doc.defaultView.manabi_invalidateBookReadingScope = hidden.clear; f.close() }
})
add('teardown finds the observed iframe after renderer enumeration disappears', async () => {
    const f = await makeBookActionSettlementFixture()
    try {
        f.runtime.endcap.leave()
        require(publishChapter(f), 'Initial publication failed')
        require(f.doc.defaultView.manabi_bookReadingScope, 'No original scope')
        f.view.renderer.getContents = () => { throw new Error('renderer contents unavailable') }
        f.runtime.close()
        require(f.doc.defaultView.manabi_bookReadingScope === null, 'Original frame retained a stale exposed scope')
        require(!f.runtime.endcap.element.isConnected, 'Endcap teardown was skipped')
    } finally { f.close() }
})
add('account cleanup publication remains current and actionable', async () => {
    const nativeClear = window.clearTimeout.bind(window)
    const f = await makeBookActionSettlementFixture()
    try {
        f.click()
        require(f.commands.length === 1, 'No original command')
        f.hooks.clear = handle => {
            nativeClear(handle)
            f.hooks.clear = null
            require(f.publish(true, '2:1'), 'Fresh account state was rejected')
        }
        f.runtime.accountDidChange('2:1')
        await f.tick()
        require(f.runtime.state.ready, 'Fresh account publication disappeared')
        require(!f.runtime.endcap.button.disabled && f.runtime.endcap.button.textContent === 'Start Book Over', 'Old handoff disabled fresh account')
        require(f.runtime.endcap.error.hidden, 'Old activation published a recovery notice in the successor account')
        f.click()
        require(f.commands.length === 2 && f.commands[1].action === 'startBookOver', 'Successor button not actionable')
        f.ack(); await f.tick()
        require(f.outcomes[0].ok === false && f.outcomes[1].ok === true, 'Old and new outcomes did not remain independent')
    } finally { f.close() }
})
for (const seam of ['lookup', 'assignment']) {
    add(`active projector ${seam} cannot overwrite its successor`, async () => {
        const f = await makeBookActionSettlementFixture()
        try {
            f.runtime.endcap.leave()
            let latest = null
            const project = state => { latest = state.revision; return true }
            f.doc.defaultView.manabi_applyBookReadingPresentation = project
            require(publishChapter(f, 2), 'Initial chapter did not publish')
            if (seam === 'lookup') {
                Object.defineProperty(f.doc.defaultView, 'manabi_applyBookReadingPresentation', { configurable: true,
                    get() {
                        Object.defineProperty(this, 'manabi_applyBookReadingPresentation', { configurable: true, writable: true, value: project })
                        require(publishChapter(f, 4), 'Successor projection failed')
                        return project
                    } })
            } else {
                Object.defineProperty(f.doc.defaultView, 'manabi_bookReadingScope', { configurable: true,
                    set(value) {
                        Object.defineProperty(this, 'manabi_bookReadingScope', { configurable: true, writable: true, value })
                        require(publishChapter(f, 4), 'Successor projection failed')
                    } })
            }
            require(!publishChapter(f, 3), 'Old projection was acknowledged')
            require(latest === 4 && f.runtime.state.state.revision === 4, 'Old frame painting overwrote fresh publication')
        } finally { f.close() }
    })
}
for (const operation of ['check', 'capture']) {
    add(`scope ${operation} cannot borrow equal recovery inside renderer lookup`, async () => {
        const f = await makeBookActionSettlementFixture()
        try {
            f.runtime.endcap.leave()
            require(publishChapter(f, 2), 'Initial publication failed')
            const old = f.runtime.captureScope(f.doc), contents = f.view.renderer.getContents
            f.view.renderer.getContents = () => {
                f.view.renderer.getContents = contents
                f.runtime.state.refresh()
                f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' })
                require(publishChapter(f, 3), 'Recovery failed')
                return contents()
            }
            const result = operation === 'check' ? f.runtime.isScopeCurrent(old, f.doc) : f.runtime.captureScope(f.doc)
            require(operation === 'check' ? result === false : result === null, 'Earlier capture acquired recovered ownership')
            require(!f.runtime.isScopeCurrent(old, f.doc), 'Old receipt became valid')
            require(f.runtime.isScopeCurrent(f.runtime.captureScope(f.doc), f.doc), 'Fresh receipt should be valid')
        } finally { f.close() }
    })
}
add('editing a scope copy cannot retarget it to a new chapter pass', async () => {
    const f = await makeBookActionSettlementFixture()
    try {
        f.runtime.endcap.leave()
        require(publishChapter(f, 2), 'Initial chapter failed')
        const old = f.runtime.captureScope(f.doc)
        require(publishChapter(f, 3, 'b'.repeat(64)), 'New pass failed')
        old.chapterEpochID = 'b'.repeat(64)
        require(!f.runtime.isScopeCurrent(old, f.doc), 'Edited old receipt acquired new pass')
        require(f.runtime.isScopeCurrent(f.runtime.captureScope(f.doc), f.doc), 'Fresh pass receipt rejected')
    } finally { f.close() }
})
add('genuine same-pass receipt survives an ordinary successful refresh', async () => {
    const f = await makeBookActionSettlementFixture()
    try {
        f.runtime.endcap.leave()
        require(publishChapter(f, 2), 'Initial chapter failed')
        const old = f.runtime.captureScope(f.doc)
        require(publishChapter(f, 3), 'Refresh failed')
        require(f.runtime.isScopeCurrent(old, f.doc), 'Successful same-pass refresh unnecessarily retired receipt')
    } finally { f.close() }
})
add('failed frame cleanup cannot overwrite a new exposed native scope', async () => {
    const f = await makeBookActionSettlementFixture()
    const original = f.doc.defaultView.manabi_invalidateBookReadingScope
    try {
        f.runtime.endcap.leave(); require(publishChapter(f, 2), 'Initial chapter failed')
        const next = { ...f.doc.defaultView.manabi_bookReadingScope, chapterEpochID: 'c'.repeat(64) }
        f.doc.defaultView.manabi_invalidateBookReadingScope = () => { f.doc.defaultView.manabi_bookReadingScope = next; throw new Error('after new frame scope') }
        f.runtime.state.refresh()
        f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' })
        require(f.doc.defaultView.manabi_bookReadingScope === next, 'Fallback cleared a replacement scope')
    } finally { f.doc.defaultView.manabi_invalidateBookReadingScope = original; f.close() }
})
add('a frame adapter cannot promote shell Finished by editing its input', async () => {
    const f = await makeBookActionSettlementFixture()
    try {
        f.runtime.endcap.leave()
        f.doc.defaultView.manabi_applyBookReadingPresentation = state => {
            state.finished = true
            state.scope.articleProgressID = 'retargeted'
            state.readSegmentIdentifiers.length = 0
            return true
        }
        require(publishChapter(f, 2), 'Native chapter publication was rejected')
        require(!f.runtime.endcap.finished, 'Frame adapter promoted shell Finished without native authority')
        require(f.doc.defaultView.manabi_bookReadingScope.articleProgressID === 'book', 'Frame input aliased the exposed scope')
        require(!f.runtime.state.state.finished && f.commands.length === 0, 'Projection authored a native action')
    } finally { f.close() }
})
