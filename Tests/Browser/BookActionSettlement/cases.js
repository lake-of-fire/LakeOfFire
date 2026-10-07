// The real bridge and End of Book control run with actual DOM, clicks, promises
// and timers. Native replies and exceptional host callbacks are controlled.
const requireResult = (condition, message) => { if (!condition) throw new Error(message) }
const ticks = async () => { for (let index = 0; index < 12; index++) await Promise.resolve() }
const watch = promise => {
    const value = { status: 'pending' }
    promise.then(result => Object.assign(value, { status: 'fulfilled', result }),
        error => Object.assign(value, { status: 'rejected', error }))
    return value
}
const makeActionFixture = () => {
    const stage = document.createElement('main'), publication = document.createElement('article')
    publication.textContent = 'Original book contents'
    stage.append(publication)
    document.body.append(stage)
    const hooks = {}, timers = new Map(), posts = [], timerErrors = []
    let sequence = 0, cap
    const bridge = BookActionTestModules.createBookActionBridge({
        postMessage: message => { posts.push(message); hooks.post?.(message) },
        documentStartedAtMs: 1, topWindowURL: 'ebook://book',
        captureContext: () => {
            hooks.capture?.()
            return hooks.contextValue ?? { contextID: 'context', locationRevision: 1, scope: { chapterEpochID: null } }
        },
        captureProducerOwner: () => ({ token: 'native-producer' }),
        carryProducerOwner: (body, owner) => { hooks.carry?.(); return { ...body, readerArticleProducer: owner } },
        makeRequestID: () => `00000000-0000-4000-8000-${String(++sequence).padStart(12, '0')}`,
        timeoutMilliseconds: 40,
        setTimer: (callback, delay) => {
            const id = setTimeout(() => {
                timers.delete(id)
                try { callback() } catch (error) { timerErrors.push(String(error)) }
            }, delay)
            timers.set(id, callback)
            hooks.install?.(id, callback)
            return id
        },
        clearTimer: id => { clearTimeout(id); timers.delete(id); hooks.clear?.(id) },
    })
    bridge.setAccountPresentation('1:1')
    cap = new BookActionTestModules.BookEndcap({ document, host: stage, publication,
        performAction: action => bridge.perform(action), recoverAction: recovery => bridge.recover(recovery) })
    cap.enter()
    cap.setReady(true)
    const packet = (message, extra = {}) => ({ requestID: message.requestID,
        accountPresentation: '1:1', ok: true, committed: true,
        ...(message.action === 'finishBook' ? {} : { navigation: { status: 'completed' } }), ...extra })
    const ack = (message, extra) => bridge.acknowledge(message.deliveryID, packet(message, extra))
    return { hooks, posts, timers, timerErrors, bridge, cap, packet, ack,
        waitForTimeout: () => new Promise(resolve => setTimeout(resolve, 70)),
        close() {
            for (const name of Object.keys(hooks)) delete hooks[name]
            bridge.close()
            for (const id of timers.keys()) clearTimeout(id)
            cap.destroy()
            stage.remove()
        } }
}
const scenario = (name, run) => ({ name, async run() {
    const f = makeActionFixture()
    try { await run(f) } finally { f.close() }
} })
window.bookActionSettlementCases = [
    ...[null, []].map(value => scenario(`invalid copied context (${value === null ? 'null' : 'array'}) does not strand real Finish`, async f => {
        f.hooks.contextValue = { toJSON: () => value }
        f.cap.button.click()
        await ticks()
        requireResult(f.posts.length === 0 && f.bridge.recoveryInfo === null, 'invalid copy reserved a native request')
        requireResult(!f.cap.busy && !f.cap.button.disabled, 'rejected preparation stranded Finish')
        delete f.hooks.contextValue
        f.cap.button.click()
        requireResult(f.posts.length === 1, 'valid deliberate retry was blocked by preparation')
        f.ack(f.posts[0])
        await ticks()
        requireResult(!f.cap.busy, 'accepted deliberate retry did not settle')
    })),
    scenario('ordinary Finish click retains ordered-state semantics', async f => {
        f.cap.button.click()
        requireResult(f.posts.length === 1 && f.posts[0].action === 'finishBook', 'one native command required')
        requireResult(f.cap.busy && f.cap.button.disabled, 'pending native operation must disable its control')
        requireResult(f.ack(f.posts[0]), 'valid native reply rejected')
        await ticks()
        requireResult(!f.cap.busy && !f.cap.button.disabled, 'terminal promise did not release the real control')
        requireResult(!f.cap.finished, 'command reply must not select current Finished state')
    }),
    ...['success', 'rejection', 'pending'].map(outcome => scenario(`real endcap releases after ${outcome} despite timer cleanup failure`, async f => {
        f.cap.button.click()
        f.hooks.clear = () => { throw new Error('cleanup fault') }
        const extra = outcome === 'rejection' ? { ok: false, committed: false, error: 'Native rejection' }
            : outcome === 'pending' ? { pending: true } : {}
        requireResult(f.ack(f.posts[0], extra), 'native reply not accepted')
        await ticks()
        requireResult(!f.cap.busy && !f.cap.button.disabled, 'native result left End of Book permanently busy')
        requireResult(f.timers.size === 0, 'timer was retained after terminal settlement')
        if (outcome === 'pending') requireResult(f.cap.button.textContent === 'Check Status', 'pending reply lost recovery')
    })),
    scenario('real timeout reaches Check Status despite cleanup failure', async f => {
        f.hooks.clear = () => { throw new Error('cleanup fault') }
        f.cap.button.click()
        await f.waitForTimeout()
        requireResult(!f.cap.busy && f.cap.button.textContent === 'Check Status', 'timeout did not settle activation')
        requireResult(!f.cap.button.disabled && f.timerErrors.length === 0, 'timeout cleanup threw or left control disabled')
        delete f.hooks.clear
        f.cap.button.click()
        requireResult(f.posts.length === 2 && f.posts[1].kind === 'status', 'recovery replayed a semantic command')
        requireResult(f.ack(f.posts[0]), 'late original native result was lost')
        await ticks()
        requireResult(!f.cap.busy && f.bridge.recoveryInfo === null, 'late result did not settle active status')
    }),
    scenario('account replacement closes old activation even when timer cleanup throws', async f => {
        f.cap.button.click()
        f.hooks.clear = () => { throw new Error('cleanup fault') }
        requireResult(f.bridge.setAccountPresentation('2:1'), 'account transition rejected')
        f.cap.accountDidChange()
        f.cap.setReady(true)
        await ticks()
        requireResult(!f.cap.busy && !f.cap.button.disabled, 'old operation stranded new account control')
        requireResult(f.bridge.recoveryInfo === null && f.timers.size === 0, 'old account operation survived')
        requireResult(f.posts.length === 1, 'account handoff replayed a command')
    }),
    scenario('removed endcap and closed bridge settle the original promise despite cleanup fault', async f => {
        const result = watch(f.bridge.perform('finishBook'))
        f.hooks.clear = () => { throw new Error('cleanup fault') }
        f.cap.destroy()
        f.bridge.close()
        await ticks()
        requireResult(result.status === 'rejected' && result.error.outcomeUnknown, 'closure stranded the original promise')
        requireResult(!f.cap.element.isConnected && f.timers.size === 0, 'detached UI retained active timer')
    }),
    scenario('malformed copy does not consume a valid reply for the busy button', async f => {
        f.cap.button.click()
        const message = f.posts[0], bad = f.packet(message)
        bad.extra = bad
        requireResult(f.bridge.acknowledge(message.deliveryID, bad) === false, 'cyclic reply accepted')
        requireResult(f.cap.busy && f.timers.size === 1, 'malformed reply consumed delivery')
        requireResult(f.ack(message), 'corrected same-delivery reply cannot be retried')
        await ticks()
        requireResult(!f.cap.busy && !f.cap.button.disabled, 'corrected reply did not release End of Book')
    }),
    scenario('serialized cross-account reply is rejected without consuming the native delivery', async f => {
        f.cap.button.click()
        const message = f.posts[0], original = f.packet(message)
        original.toJSON = () => ({ ...f.packet(message), accountPresentation: '2:1' })
        requireResult(!f.bridge.acknowledge(message.deliveryID, original), 'copy changed correlation after admission')
        requireResult(f.ack(message), 'valid account reply was consumed')
        await ticks()
        requireResult(!f.cap.busy, 'corrected reply is stuck')
    }),
    scenario('changing a returned result cannot alter navigation-only recovery', async f => {
        const initial = f.bridge.perform('startBookOver'), message = f.posts[0]
        f.ack(message, { navigation: { status: 'failed' } })
        const result = await initial
        result.navigation.status = 'completed'
        requireResult(f.bridge.recoveryInfo.kind === 'navigate', 'consumer rewrote the bridge recovery cache')
        const retry = f.bridge.recover()
        requireResult(f.posts.length === 2 && f.posts[1].kind === 'navigate', 'original navigation retry was skipped')
        f.ack(f.posts[1])
        await retry
        requireResult(f.bridge.recoveryInfo === null, 'navigation recovery did not finish')
    }),
    scenario('capture-time account handoff cannot post a command using the old context', async f => {
        f.hooks.capture = () => { f.bridge.setAccountPresentation('2:1'); f.cap.accountDidChange(); f.cap.setReady(true) }
        f.cap.button.click()
        await ticks()
        requireResult(f.posts.length === 0, 'old context was submitted for the successor account')
        requireResult(f.bridge.recoveryInfo === null && !f.cap.busy, 'unsent action left a phantom recovery request')
    }),
    scenario('producer wrapping cannot dispatch after the bridge closes', async f => {
        f.hooks.carry = () => f.bridge.close()
        f.cap.button.click()
        await ticks()
        requireResult(f.posts.length === 0, 'original delivery dispatched after close')
        requireResult(!f.cap.busy && f.timers.size === 0, 'retired delivery did not settle')
    }),
    scenario('reentrant context capture admits only one semantic action', async f => {
        let nested
        f.hooks.capture = () => { delete f.hooks.capture; nested = watch(f.bridge.perform('finishBook')) }
        f.cap.button.click()
        await ticks()
        requireResult(f.posts.length === 1 && nested.status === 'rejected', 'nested activation posted another command')
        f.ack(f.posts[0])
        await ticks()
        requireResult(!f.cap.busy, 'original activation did not retain its own promise')
    }),
    scenario('timer returned after account retirement is disposed without sending', async f => {
        f.hooks.install = () => { f.bridge.setAccountPresentation('2:1'); f.cap.accountDidChange() }
        f.cap.button.click()
        await ticks()
        requireResult(f.posts.length === 0, 'timer callback retirement did not stop dispatch')
        requireResult(f.timers.size === 0 && !f.cap.busy, 'returned timer was orphaned')
    }),
    scenario('synchronous accepted native reply followed by post failure stays accepted', async f => {
        f.hooks.post = message => { f.ack(message); throw new Error('wrapper failed after acceptance') }
        f.cap.button.click()
        await ticks()
        requireResult(f.posts.length === 1 && !f.cap.busy, 'accepted reply was replaced by wrapper failure')
        requireResult(f.bridge.recoveryInfo === null && f.cap.error.hidden, 'accepted success became uncertain')
    }),
    scenario('ordinary timeout and late reply preserve one mutation across status recovery', async f => {
        f.cap.button.click()
        await f.waitForTimeout()
        requireResult(f.cap.button.textContent === 'Check Status' && !f.cap.busy, 'timeout recovery missing')
        f.cap.button.click()
        requireResult(f.posts.length === 2 && f.posts[1].kind === 'status', 'status click repeated mutation')
        requireResult(f.ack(f.posts[0]), 'late original reply not accepted')
        await ticks()
        requireResult(!f.cap.busy && f.timers.size === 0 && f.bridge.recoveryInfo === null, 'late reply failed to release active delivery')
    }),
]
