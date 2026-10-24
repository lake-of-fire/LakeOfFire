import assert from 'node:assert/strict'
import test from 'node:test'
import { NavigationHUD } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-viewer-nav.js'
import { createManualNavigationRunner, createNavigationIntentRunner } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-load-coordinator.js'

// Chrome, loading and renderer endpoints are controlled. HUD history, View
// command receipts and the Reader's production manual-navigation runner are real.
globalThis.HTMLElement = class extends EventTarget {
    attachShadow() { return { append() {} } }
}
globalThis.customElements = { define() {} }
globalThis.document = {
    body: { style: {} }, documentElement: { style: {} },
    getElementById: () => null,
}
globalThis.requestAnimationFrame = () => 1
globalThis.cancelAnimationFrame = () => {}
const { View } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/view.js')

const deferred = () => {
    let resolve, reject
    const promise = new Promise((yes, no) => { resolve = yes; reject = no })
    return { promise, resolve, reject }
}

function fixture({ operation = async () => accepted, beforeDeliver } = {}) {
    const view = new View()
    view.book = { sections: [{ id: 'a' }, { id: 'b' }, { id: 'c' }] }
    const calls = [], admissions = [], receipts = [], errors = []
    view.renderer = {
        goTo: (target, options) => { calls.push({ target, options }); return operation(target, options) },
        isNavigationReceiptCurrent: receipt => receipt === accepted,
        destroy() {}, remove() {},
    }
    const reader = { view, isClosed: false }
    const host = { reader }
    const run = createManualNavigationRunner({
        host,
        runWithNavigationIntent: createNavigationIntentRunner(host),
        // This callback supplies the already admitted load endpoint. The
        // runner's Reader/View/renderer checks and View's receipts stay real.
        captureOwner: () => ({ isCurrent: () => true }),
        onAccepted: value => { admissions.push(value) },
    })
    const request = async descriptor => {
        const receipt = await run({ source: 'goToDescriptor' },
            (currentView, options) => currentView.goTo(descriptor.sectionIndex, {
                ...options, recordHistory: false,
            }), { reader, view: reader.view })
        receipts.push(receipt)
        await beforeDeliver?.(receipt, { view, reader, host })
        return receipt
    }
    const hud = new NavigationHUD({
        onJumpRequest: request,
        isJumpRequestCurrent: receipt => host.reader === reader && !reader.isClosed
            && reader.view?.isNavigationReceiptCurrent?.(receipt) === true,
        getRenderer: () => reader.view?.renderer,
    })
    hud._applyPageTurnNavigationVisibility = () => {}
    hud._updatePrimaryLine = () => {}
    hud._toggleCompletionStack = () => {}
    hud._updateSectionProgress = async () => {}
    hud._updateRelocateButtons = () => {}
    hud._updateRendererSnapshotFromDetail = () => null
    hud._refreshRendererSnapshot = async () => null
    const current = { sectionIndex: 2, fraction: 0.8, cfi: 'current' }
    const target = { sectionIndex: 0, fraction: 0.1, cfi: 'target' }
    hud.currentLocationDescriptor = current
    return { hud, host, reader, view, current, target, calls, admissions, receipts, errors, request }
}
const accepted = Object.freeze({ index: 0 })

function seed(f, direction = 'back') {
    f.hud.relocateStacks[direction].push(f.target)
}
function assertPending(f, pending, direction = 'back') {
    assert.equal(f.hud.pendingRelocateJump, pending)
    assert.equal(f.hud.isProcessingRelocateJump, true)
    assert.deepEqual(f.hud.relocateStacks[direction], [f.target])
    assert.deepEqual(f.hud.relocateStacks[direction === 'back' ? 'forward' : 'back'], [])
}
function assertRetired(f, direction = 'back') {
    assert.equal(f.hud.pendingRelocateJump, null)
    assert.equal(f.hud.isProcessingRelocateJump, false)
    assert.deepEqual(f.hud.relocateStacks[direction], [f.target])
    assert.deepEqual(f.hud.relocateStacks[direction === 'back' ? 'forward' : 'back'], [])
}

for (const direction of ['back', 'forward']) {
    test(direction + ': resize relocation cannot consume history before its command receipt', async () => {
        const gate = deferred(), f = fixture({ operation: () => gate.promise })
        seed(f, direction)
        const jump = f.hud._handleRelocateJump(direction)
        const pending = f.hud.pendingRelocateJump
        try {
            // Old visible chapter and target-looking layout events are both
            // insufficient; the latter also exercises the separate prune path.
            for (const detail of [f.current, f.target]) {
                await f.hud.handleRelocate({ ...detail, reason: 'anchor' })
                assertPending(f, pending, direction)
            }
            gate.resolve(accepted)
            await jump
            assert.equal(f.admissions.length, 1)
            assert.equal(f.view.isNavigationReceiptCurrent(f.receipts[0]), true)
            assert.equal(f.hud.pendingRelocateJump, null)
            assert.equal(f.hud.isProcessingRelocateJump, false)
            assert.deepEqual(f.hud.relocateStacks[direction], [])
            const opposite = f.hud.relocateStacks[direction === 'back' ? 'forward' : 'back']
            assert.equal(opposite.length, 1)
            assert.equal(opposite[0].sectionIndex, f.current.sectionIndex)
            assert.equal(opposite[0].fraction, f.current.fraction)
            assert.equal(opposite[0].cfi, null)
        } finally { gate.resolve(null); await jump; f.hud.destroy() }
    })
}

test('a relocation already waiting for metrics cannot confirm a later rejected jump', async () => {
    const navigation = deferred(), snapshot = deferred(), started = deferred()
    const f = fixture({ operation: () => navigation.promise })
    seed(f)
    f.hud._refreshRendererSnapshot = async () => { started.resolve(); await snapshot.promise }
    const olderRelocation = f.hud.handleRelocate({ ...f.current, reason: 'anchor' })
    await started.promise
    const jump = f.hud._handleRelocateJump('back')
    const pending = f.hud.pendingRelocateJump
    try {
        snapshot.resolve()
        await olderRelocation
        assertPending(f, pending)
        navigation.resolve(null)
        await jump
        assertRetired(f)
        assert.deepEqual(f.admissions, [])
    } finally { snapshot.resolve(); navigation.resolve(null); await jump; f.hud.destroy() }
})

for (const [label, result] of [
    ['null', null], ['false', false], ['ignored', { ignored: true }],
    ['unissued receipt', {}],
]) {
    test(label + ' renderer outcome preserves both stacks and permits a retry', async () => {
        let outcome = result
        const f = fixture({ operation: async () => outcome })
        seed(f)
        try {
            await f.hud._handleRelocateJump('back')
            assertRetired(f)
            assert.deepEqual(f.admissions, [])
            outcome = accepted
            await f.hud._handleRelocateJump('back')
            assert.equal(f.calls.length, 2)
            assert.equal(f.admissions.length, 1)
            assert.deepEqual(f.hud.relocateStacks.back, [])
            assert.equal(f.hud.relocateStacks.forward.length, 1)
            assert.equal(f.hud.isProcessingRelocateJump, false)
        } finally { f.hud.destroy() }
    })
}

test('current renderer rejection releases pending state without consuming history', async () => {
    const failure = new Error('chapter load failed')
    const f = fixture({ operation: async () => { throw failure } })
    seed(f)
    const originalError = console.error
    const errors = []
    console.error = (...values) => errors.push(values)
    try {
        await f.hud._handleRelocateJump('back')
        assertRetired(f)
        assert.deepEqual(f.admissions, [])
        assert.ok(errors.some(values => values.includes(failure)))
    } finally { console.error = originalError; f.hud.destroy() }
})

test('a newer View command cancels an unfinished history jump without deleting its target', async () => {
    const gate = deferred()
    const f = fixture({ operation: target => target.index === 0 ? gate.promise : accepted })
    seed(f)
    const jump = f.hud._handleRelocateJump('back')
    await f.view.goTo(1, { requiresNavigationReceipt: true })
    gate.resolve(accepted)
    try {
        await jump
        assertRetired(f)
        assert.equal(f.receipts[0], null)
        assert.deepEqual(f.admissions, [])
    } finally { f.hud.destroy() }
})

test('HUD rechecks an issued receipt after delivery is suspended and another command completes', async () => {
    const gate = deferred(), started = deferred()
    const f = fixture({ beforeDeliver: async receipt => {
        assert.ok(receipt)
        started.resolve()
        await gate.promise
    } })
    seed(f)
    const jump = f.hud._handleRelocateJump('back')
    await started.promise
    await f.view.goTo(1, { requiresNavigationReceipt: true })
    gate.resolve()
    try {
        await jump
        assert.equal(f.admissions.length, 1)
        assert.equal(f.view.isNavigationReceiptCurrent(f.receipts[0]), false)
        assertRetired(f)
    } finally { f.hud.destroy() }
})

for (const replacement of ['Reader', 'View', 'renderer', 'close']) {
    test(replacement + ' retirement prevents an unfinished history result from consuming the stack', async () => {
        const gate = deferred()
        const f = fixture({ operation: () => gate.promise })
        seed(f)
        const jump = f.hud._handleRelocateJump('back')
        if (replacement === 'Reader') f.host.reader = { view: f.view }
        if (replacement === 'View') f.reader.view = new View()
        if (replacement === 'renderer') f.view.renderer = { goTo: async () => accepted }
        if (replacement === 'close') f.reader.isClosed = true
        gate.resolve(accepted)
        try {
            await jump
            assertRetired(f)
            assert.equal(f.receipts[0], null)
            assert.deepEqual(f.admissions, [])
        } finally { f.hud.destroy() }
    })
}

test('destroy severs receipt validation and rejects late completion and later clicks', async () => {
    const gate = deferred()
    const f = fixture({ operation: () => gate.promise })
    seed(f)
    const jump = f.hud._handleRelocateJump('back')
    let buttonUpdates = 0
    f.hud._updateRelocateButtons = () => { buttonUpdates += 1 }
    f.hud.destroy()
    gate.resolve(accepted)
    await jump
    assert.equal(f.hud.isJumpRequestCurrent, null)
    assertRetired(f)
    assert.equal(buttonUpdates, 0)
    await f.hud._handleRelocateJump('back')
    assert.equal(f.calls.length, 1)
    assert.equal(buttonUpdates, 0)
})

test('a same-target command settles from its receipt even without a relocation event', async () => {
    const f = fixture()
    f.target = { ...f.current }
    seed(f)
    try {
        await f.hud._handleRelocateJump('back')
        assert.equal(f.admissions.length, 1)
        assert.equal(f.hud.pendingRelocateJump, null)
        assert.equal(f.hud.isProcessingRelocateJump, false)
        assert.deepEqual(f.hud.relocateStacks.back, [])
        assert.equal(f.hud.relocateStacks.forward.length, 1)
        assert.equal(f.hud.relocateStacks.forward[0].fraction, f.current.fraction)
    } finally { f.hud.destroy() }
})

test('duplicate history clicks share the pending command and consume one entry', async () => {
    const gate = deferred(), f = fixture({ operation: () => gate.promise })
    seed(f)
    const first = f.hud._handleRelocateJump('back')
    await f.hud._handleRelocateJump('back')
    await f.hud._handleRelocateJump('forward')
    assert.equal(f.calls.length, 1)
    gate.resolve(accepted)
    try {
        await first
        assert.deepEqual(f.hud.relocateStacks.back, [])
        assert.equal(f.hud.relocateStacks.forward.length, 1)
    } finally { f.hud.destroy() }
})

test('a command cannot consume a different history entry that replaced its original target', async () => {
    const gate = deferred(), f = fixture({ operation: () => gate.promise })
    seed(f)
    const jump = f.hud._handleRelocateJump('back')
    const replacement = { sectionIndex: 1, fraction: 0.4, cfi: 'new target' }
    f.hud.relocateStacks.back.splice(0, 1, replacement)
    gate.resolve(accepted)
    try {
        await jump
        assert.deepEqual(f.hud.relocateStacks.back, [replacement])
        assert.deepEqual(f.hud.relocateStacks.forward, [])
        assert.equal(f.hud.pendingRelocateJump, null)
        assert.equal(f.hud.isProcessingRelocateJump, false)
    } finally { f.hud.destroy() }
})

test('failed history does not leave an explicit mutation marker for the next page turn', async () => {
    const f = fixture({ operation: async () => null })
    seed(f)
    try {
        await f.hud._handleRelocateJump('back')
        await f.hud.handleRelocate({ sectionIndex: 2, fraction: 0.9, cfi: 'next page', reason: 'page' })
        assertRetired(f)
        assert.equal(f.hud.currentLocationDescriptor.fraction, 0.9)
    } finally { f.hud.destroy() }
})

test('receipt validator destruction cannot publish history or update retired controls', async () => {
    const f = fixture()
    seed(f)
    let updatedAfterDestroy = false
    const update = f.hud._updateRelocateButtons
    f.hud._updateRelocateButtons = () => {
        if (f.hud.destroyed) updatedAfterDestroy = true
        return update()
    }
    f.hud.isJumpRequestCurrent = receipt => {
        assert.equal(f.view.isNavigationReceiptCurrent(receipt), true)
        f.hud.destroy()
        return true
    }
    await f.hud._handleRelocateJump('back')
    assertRetired(f)
    assert.equal(updatedAfterDestroy, false)
})

test('receipt validator reentry cannot finish or clear a replacement pending owner', async () => {
    const f = fixture()
    seed(f)
    const replacement = { direction: 'forward' }
    f.hud.isJumpRequestCurrent = receipt => {
        assert.equal(f.view.isNavigationReceiptCurrent(receipt), true)
        f.hud.pendingRelocateJump = replacement
        return true
    }
    try {
        await f.hud._handleRelocateJump('back')
        assert.equal(f.hud.pendingRelocateJump, replacement)
        assert.equal(f.hud.isProcessingRelocateJump, true)
        assert.deepEqual(f.hud.relocateStacks.back, [f.target])
        assert.deepEqual(f.hud.relocateStacks.forward, [])
    } finally { f.hud.destroy() }
})
