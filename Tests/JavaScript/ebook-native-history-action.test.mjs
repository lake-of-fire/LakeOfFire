import assert from 'node:assert/strict'
import test from 'node:test'
import { readFile } from 'node:fs/promises'
import vm from 'node:vm'
import { NavigationHUD } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-viewer-nav.js'
import { captureEbookHistoryActionContext, ebookHistoryActionContextIsCurrent } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-native-history-action.js'
import { createManualNavigationRunner, createNavigationIntentRunner } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-load-coordinator.js'

// Execute the production context helper, HUD producer/history, shipping bridge
// and Reader adapter declarations, View receipts and manual-navigation runner.
// Chrome, renderer outcomes and the load-admission endpoint are controlled.
// This does not run the Reader constructor, native message delivery or WebKit.
globalThis.HTMLElement = class extends EventTarget {
    attachShadow() { return { append() {} } }
}
globalThis.customElements = { define() {} }
globalThis.document = {
    body: { style: {} }, documentElement: { style: {} }, getElementById: () => null,
}
globalThis.requestAnimationFrame = () => 1
globalThis.cancelAnimationFrame = () => {}
const { View } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/view.js')
const viewer = await readFile(new URL(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-viewer.js', import.meta.url,
), 'utf8')
const adapterStart = viewer.indexOf('    async _goToDescriptor(descriptor) {')
const adapterEnd = viewer.indexOf('    async goToHref(', adapterStart)
const bridgeStart = viewer.indexOf('window.manabiTriggerReaderRelocateJump =')
const bridgeEnd = viewer.indexOf('window.manabiScheduleReaderPercentGoTo =', bridgeStart)
if (adapterStart < 0 || adapterEnd <= adapterStart || bridgeStart < 0 || bridgeEnd <= bridgeStart) {
    throw new Error('Shipping Reader adapter/bridge declarations unavailable')
}
const adapter = viewer.slice(adapterStart, adapterEnd)
const bridge = viewer.slice(bridgeStart, bridgeEnd)
const nativeAction = await readFile(new URL(
    '../../Sources/LakeOfFireReader/Reader/ReaderEBookHistoryAction.swift', import.meta.url,
), 'utf8')
const nativeEvaluation = nativeAction.match(
    /let result = try await caller\.evaluateJavaScript\(\s*"""\n([\s\S]*?)\n\s*""",/,
)?.[1]
if (!nativeEvaluation) throw new Error('Shipping native history evaluation literal unavailable')
const bookA = 'ebook://reader/load/local/book-a.epub'
const bookB = 'ebook://reader/load/local/book-b.epub'

function deferred() {
    let resolve, reject
    const promise = new Promise((yes, no) => { resolve = yes; reject = no })
    return { promise, resolve, reject }
}

function environment() {
    const messages = [], errors = [], readers = []
    globalThis.window = {
        webkit: { messageHandlers: { ebookNativeOverlayState: { postMessage: value => messages.push(value) } } },
    }
    const host = vm.createContext({
        window: {}, manabiLoadEBookToken: 1, manabiLoadEBookURL: bookA,
        ebookHistoryActionContextIsCurrent,
    })
    vm.runInContext(bridge, host)
    return {
        host, messages, errors, readers,
        request: (...args) => host.window.manabiTriggerReaderRelocateJump(...args),
        close() { for (const reader of readers) reader.navHUD?.destroy() },
    }
}

async function installReader(env, { operation, install = true, contextual = true, direction = 'back' } = {}) {
    const calls = [], admissions = [], receipt = Object.freeze({ index: 0 })
    const view = new View()
    view.book = { sections: [{ id: 'a' }, { id: 'b' }, { id: 'c' }] }
    view.renderer = {
        goTo: async (target, options) => {
            calls.push({ target, options })
            return operation ? operation(receipt, target) : receipt
        },
        isNavigationReceiptCurrent: value => value === receipt,
    }
    const run = createManualNavigationRunner({
        host: env.host, runWithNavigationIntent: createNavigationIntentRunner(env.host),
        // The already-admitted load endpoint is controlled. The runner's
        // Reader/View/renderer checks and actual View receipts remain intact.
        captureOwner: () => ({ isCurrent: () => true }),
        onAccepted: value => admissions.push(value),
    })
    const Adapter = new Function('runManualNavigation', 'console',
        `return class { constructor(view) { this.view = view; this.isClosed = false; }\n${adapter}\n}`,
    )(run, { error: (...values) => env.errors.push(values) })
    const reader = new Adapter(view)
    const hud = new NavigationHUD({
        onJumpRequest: descriptor => reader._goToDescriptor(descriptor),
        isJumpRequestCurrent: value => env.host.reader === reader && !reader.isClosed
            && reader.view?.isNavigationReceiptCurrent(value) === true,
        getRenderer: () => reader.view?.renderer,
        ...(contextual ? { getHistoryActionContext: ownerHUD =>
            captureEbookHistoryActionContext(env.host, reader, ownerHUD) } : {}),
    })
    // Drain the constructor's real label update before installing this Reader.
    // Later section metrics are outside the history/context contract.
    await hud._updateSectionProgress({ source: 'fixture.before-installation' })
    hud._updateSectionProgress = async () => {}
    reader.navHUD = hud
    env.readers.push(reader)
    hud.currentLocationDescriptor = { sectionIndex: 2, fraction: 0.8 }
    hud.relocateStacks[direction].push({
        sectionIndex: 0, localSectionIndex: 0, rendererTotal: 5, fraction: 0.1,
    })
    if (install) {
        env.host.reader = reader
        hud._updateRelocateButtons('fixture.installed')
    }
    return { reader, hud, view, receipt, calls, admissions,
        context: () => captureEbookHistoryActionContext(env.host, reader, hud) }
}

test('capture produces an immutable versioned context with a canonical string token', async () => {
    const env = environment(), f = await installReader(env)
    try {
        assert.deepEqual(f.context(), { kind: 'ebook-history-action-v1', loadToken: '1', loadURL: bookA })
        assert.equal(Object.isFrozen(f.context()), true)
        const captured = f.context()
        env.host.manabiLoadEBookToken = 2
        env.host.manabiLoadEBookURL = bookB
        assert.equal(captured.loadToken, '1')
        assert.equal(captured.loadURL, bookA)
    } finally { env.close() }
})

test('the actual native evaluation literal dispatches exact current contexts and rejects stale or missing bridges', async () => {
    // Execute the shipping Swift multiline JS body with its real argument names.
    // JSONEncoder, native transport and WK frame dispatch remain unexecuted.
    for (const direction of ['back', 'forward']) {
        const env = environment(), f = await installReader(env, { direction })
        const evaluate = vm.runInContext(
            `(async function(direction, historyActionContextJSON) {\n${nativeEvaluation}\n})`, env.host,
        )
        const contextJSON = JSON.stringify(f.context())
        try {
            assert.equal(await evaluate(direction, contextJSON), true)
            assert.equal(f.calls.length, 1)
            assert.equal(f.calls[0].options.requiresNavigationReceipt, true)
            assert.equal(f.admissions.length, 1)
            assert.equal(f.hud.relocateStacks[direction].length, 0)
            const opposite = direction === 'back' ? 'forward' : 'back'
            assert.equal(f.hud.relocateStacks[opposite].length, 1)

            env.host.manabiLoadEBookToken = 2
            const current = await installReader(env, { direction })
            assert.equal(await evaluate(direction, contextJSON), false)
            assert.deepEqual(current.calls, [])
            assert.equal(current.hud.relocateStacks[direction].length, 1)

            delete env.host.window.manabiTriggerReaderRelocateJump
            assert.equal(await evaluate(direction, JSON.stringify(current.context())), false)
            assert.deepEqual(current.calls, [])
            assert.equal(f.calls.length, 1)
        } finally { env.close() }
    }
})

test('capture rejects invalid load tokens and absent URL without coercion', async () => {
    const env = environment(), f = await installReader(env)
    try {
        for (const token of [undefined, null, 0, -1, 1.5, NaN, Infinity, '1', true, Number.MAX_SAFE_INTEGER + 1]) {
            env.host.manabiLoadEBookToken = token
            assert.equal(f.context(), null)
        }
        env.host.manabiLoadEBookToken = Number.MAX_SAFE_INTEGER
        assert.equal(f.context().loadToken, String(Number.MAX_SAFE_INTEGER))
        env.host.manabiLoadEBookToken = 1
        for (const url of [undefined, null, '', 12]) {
            env.host.manabiLoadEBookURL = url
            assert.equal(f.context(), null)
        }
    } finally { env.close() }
})

test('the actual HUD constructor cannot publish before Reader installation, then publishes normally', async () => {
    const env = environment(), f = await installReader(env, { install: false })
    try {
        assert.deepEqual(env.messages, [])
        f.hud._postNativeOverlayState('still-uninstalled')
        assert.deepEqual(env.messages, [])
        env.host.reader = f.reader
        f.hud._updateRelocateButtons('now-installed')
        assert.deepEqual(env.messages.at(-1).historyActionContext, f.context())
        assert.equal(env.messages.at(-1).relocateBackEnabled, true)
    } finally { env.close() }
})

test('a replaced live HUD cannot borrow the new token or clear the successor overlay', async () => {
    const env = environment(), old = await installReader(env)
    env.host.manabiLoadEBookToken = 2
    env.host.manabiLoadEBookURL = bookB
    const current = await installReader(env)
    try {
        assert.equal(old.hud.destroyed, false)
        assert.equal(old.context(), null)
        const before = [...env.messages]
        old.hud._postNativeOverlayState('late-old-hud')
        old.hud._updateRelocateButtons('late-old-buttons')
        assert.deepEqual(env.messages, before)
        assert.deepEqual(env.messages.at(-1).historyActionContext, current.context())
    } finally { env.close() }
})

test('destroyed HUDs cannot publish after their callback has been detached', async () => {
    const env = environment(), f = await installReader(env)
    try {
        f.hud.destroy()
        const before = [...env.messages]
        f.hud._postNativeOverlayState('after-destroy')
        assert.deepEqual(env.messages, before)
        assert.equal(f.context(), null)
    } finally { env.close() }
})

test('legacy HUD without the new callback retains presentation fields and publishes null context', async () => {
    const env = environment(), f = await installReader(env, { contextual: false })
    try {
        assert.equal(env.messages.at(-1).historyActionContext, null)
        assert.equal(env.messages.at(-1).relocateBackEnabled, true)
        assert.equal(env.messages.at(-1).relocateForwardEnabled, false)
    } finally { env.close() }
})

test('repeated current HUD updates keep the same action context while presentation changes', async () => {
    const env = environment(), f = await installReader(env)
    try {
        const original = env.messages.at(-1).historyActionContext
        f.hud.bookTitle = 'A new label'
        f.hud._postNativeOverlayState('new-label')
        assert.deepEqual(env.messages.at(-1).historyActionContext, original)
        assert.equal(env.messages.at(-1).bookTitleLabel, 'A new label')
    } finally { env.close() }
})

for (const direction of ['back', 'forward']) {
    test(direction + ': current native context reaches the actual receipt and publishes opposite history', async () => {
        const gate = deferred(), env = environment()
        const f = await installReader(env, { direction, operation: () => gate.promise })
        const context = env.messages.at(-1).historyActionContext
        const work = env.request(direction, context)
        try {
            assert.equal(env.messages.at(-1).relocateBackEnabled, false)
            assert.equal(env.messages.at(-1).relocateForwardEnabled, false)
            assert.equal(f.hud.relocateStacks[direction].length, 1)
            assert.equal(f.calls[0].options.requiresNavigationReceipt, true)
            gate.resolve(f.receipt)
            assert.equal(await work, true)
            assert.equal(f.calls.length, 1)
            assert.equal(f.admissions.length, 1)
            assert.equal(f.hud.relocateStacks[direction].length, 0)
            const opposite = direction === 'back' ? 'forward' : 'back'
            assert.equal(f.hud.relocateStacks[opposite].length, 1)
            assert.equal(env.messages.at(-1)[opposite === 'back' ? 'relocateBackEnabled' : 'relocateForwardEnabled'], true)
            assert.deepEqual(env.messages.at(-1).historyActionContext, context)
        } finally { gate.resolve(null); await work; env.close() }
    })
}

test('same-URL reload rejects the old native context and accepts the new one', async () => {
    const env = environment(), old = await installReader(env), context = old.context()
    env.host.manabiLoadEBookToken = 2
    const current = await installReader(env)
    try {
        const before = [...env.messages]
        assert.equal(await env.request('back', context), false)
        assert.deepEqual(current.calls, [])
        assert.deepEqual(old.calls, [])
        assert.deepEqual(env.messages, before)
        assert.equal(await env.request('back', current.context()), true)
        assert.equal(current.calls.length, 1)
    } finally { env.close() }
})

test('A-to-B-to-A load replacement cannot revive a native action from the first A', async () => {
    const env = environment(), old = await installReader(env), context = old.context()
    env.host.manabiLoadEBookToken = 2
    env.host.manabiLoadEBookURL = bookB
    await installReader(env)
    env.host.manabiLoadEBookToken = 3
    env.host.manabiLoadEBookURL = bookA
    const current = await installReader(env)
    try {
        assert.equal(await env.request('back', context), false)
        assert.deepEqual(current.calls, [])
        assert.equal(ebookHistoryActionContextIsCurrent(context, env.host, current.reader, current.hud), false)
        assert.equal(await env.request('back', current.context()), true)
    } finally { env.close() }
})

test('a changed exact load URL rejects a retained action even with an equal token', async () => {
    const env = environment(), f = await installReader(env), context = f.context()
    try {
        env.host.manabiLoadEBookURL = bookB
        assert.equal(await env.request('back', context), false)
        assert.deepEqual(f.calls, [])
        assert.equal(f.hud.relocateStacks.back.length, 1)
    } finally { env.close() }
})

test('malformed, mixed-version and noncanonical native contexts cannot dispatch', async () => {
    const env = environment(), f = await installReader(env), context = f.context()
    try {
        const before = [...env.messages]
        const invalid = [null, undefined, false, '', [], {},
            { ...context, kind: 'ebook-history' }, { ...context, kind: 'ebook-history-action-v2' },
            { ...context, loadToken: 1 }, { ...context, loadToken: true },
            { ...context, loadToken: '01' }, { ...context, loadToken: '+1' },
            { ...context, loadToken: '1.0' }, { ...context, loadToken: '0' },
            { ...context, loadURL: '' }, { ...context, loadURL: null },
            { kind: context.kind, loadToken: context.loadToken, ebookURL: bookA },
        ]
        for (const value of invalid) assert.equal(await env.request('back', value), false)
        assert.deepEqual(f.calls, [])
        assert.deepEqual(env.messages, before)
        assert.equal(f.hud.relocateStacks.back.length, 1)
    } finally { env.close() }
})

test('a producer without context cannot authorize the contextual native bridge', async () => {
    const env = environment(), f = await installReader(env, { contextual: false })
    try {
        assert.equal(await env.request('back', env.messages.at(-1).historyActionContext), false)
        assert.equal(await env.request('back', undefined), false)
        assert.deepEqual(f.calls, [])
    } finally { env.close() }
})

test('missing HUD, View, renderer and closed ownership reject before history entry', async () => {
    const env = environment(), f = await installReader(env), context = f.context()
    try {
        const view = f.reader.view, renderer = view.renderer
        f.reader.navHUD = null
        assert.equal(await env.request('back', context), false)
        f.reader.navHUD = f.hud
        f.reader.view = null
        assert.equal(await env.request('back', context), false)
        f.reader.view = view
        view.renderer = null
        assert.equal(await env.request('back', context), false)
        view.renderer = renderer
        f.reader.isClosed = true
        assert.equal(await env.request('back', context), false)
        f.reader.isClosed = false
        f.hud.destroy()
        assert.equal(await env.request('back', context), false)
        assert.deepEqual(f.calls, [])
    } finally { env.close() }
})

test('the one-argument trusted bridge remains available while explicit null rejects', async () => {
    const env = environment(), f = await installReader(env)
    try {
        assert.equal(await env.request('back', null), false)
        assert.deepEqual(f.calls, [])
        assert.equal(await env.request('back'), true)
        assert.equal(f.calls.length, 1)
        assert.equal(f.hud.relocateStacks.back.length, 0)
    } finally { env.close() }
})

test('invalid directions cannot dispatch with either contextual or trusted calls', async () => {
    const env = environment(), f = await installReader(env)
    try {
        for (const direction of ['', 'Back', 'left', null, false]) {
            assert.equal(await env.request(direction, f.context()), false)
            assert.equal(await env.request(direction), false)
        }
        assert.deepEqual(f.calls, [])
    } finally { env.close() }
})

test('a rejected renderer receipt preserves history and contextual retry succeeds', async () => {
    let succeeds = false
    const env = environment(), f = await installReader(env, { operation: receipt => succeeds ? receipt : null })
    try {
        await env.request('back', f.context())
        assert.equal(f.hud.relocateStacks.back.length, 1)
        assert.equal(f.hud.relocateStacks.forward.length, 0)
        assert.equal(f.hud.isProcessingRelocateJump, false)
        assert.equal(env.messages.at(-1).relocateBackEnabled, true)
        assert.equal(f.admissions.length, 0)
        succeeds = true
        await env.request('back', f.context())
        assert.equal(f.hud.relocateStacks.back.length, 0)
        assert.equal(f.admissions.length, 1)
    } finally { env.close() }
})

test('a controlled cancellation error releases current native controls without consuming history', async () => {
    const failure = new Error('controlled renderer cancellation')
    failure.name = 'AbortError'
    const env = environment(), f = await installReader(env, { operation: async () => { throw failure } })
    const originalError = console.error
    console.error = (...values) => env.errors.push(values)
    try {
        await env.request('back', f.context())
        assert.equal(f.hud.pendingRelocateJump, null)
        assert.equal(f.hud.isProcessingRelocateJump, false)
        assert.equal(f.hud.relocateStacks.back.length, 1)
        assert.equal(f.hud.relocateStacks.forward.length, 0)
        assert.equal(env.messages.at(-1).relocateBackEnabled, true)
        assert.equal(f.admissions.length, 0)
        assert.equal(env.errors.some(values => values.includes(failure)), true)
    } finally { console.error = originalError; env.close() }
})

test('replacement after dispatch rejects the old receipt and suppresses late overlay publication', async () => {
    const gate = deferred(), env = environment()
    const old = await installReader(env, { operation: () => gate.promise })
    const work = env.request('back', old.context())
    env.host.manabiLoadEBookToken = 2
    env.host.manabiLoadEBookURL = bookB
    const current = await installReader(env)
    const before = [...env.messages]
    gate.resolve(old.receipt)
    try {
        await work
        assert.equal(old.hud.relocateStacks.back.length, 1)
        assert.equal(old.hud.relocateStacks.forward.length, 0)
        assert.equal(old.admissions.length, 0)
        assert.deepEqual(current.calls, [])
        assert.deepEqual(env.messages, before)
        assert.equal(env.messages.at(-1).relocateBackEnabled, true)
    } finally { gate.resolve(null); await work; env.close() }
})

test('a newer View command invalidates a held contextual history receipt', async () => {
    const gate = deferred(), env = environment()
    const f = await installReader(env, { operation: (receipt, target) => target.index === 0 ? gate.promise : receipt })
    const work = env.request('back', f.context())
    await f.view.goTo(1, { requiresNavigationReceipt: true })
    gate.resolve(f.receipt)
    try {
        await work
        assert.equal(f.hud.relocateStacks.back.length, 1)
        assert.equal(f.hud.relocateStacks.forward.length, 0)
        assert.equal(f.admissions.length, 0)
        assert.equal(env.messages.at(-1).relocateBackEnabled, true)
    } finally { gate.resolve(null); await work; env.close() }
})
