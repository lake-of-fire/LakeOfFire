import assert from 'node:assert/strict'
import test from 'node:test'

import {
    installVisibleRendererGoToGuard,
    makeInitialRestoreTerminalResult,
    makeSyntheticRestoreLocator,
    normalizeInitialRestoreRequest,
    parseSyntheticRestoreLocator,
    restoreLocatorKind,
    runRequiredRestoreNavigation,
    shouldSkipScheduledReaderFractionGoTo,
    shouldSkipVisibleRendererGoTo,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-restore-coordination.js'

test('normalized saved command cannot be changed through a published diagnostic alias', () => {
    const input = { requestID: 'immutable', cfi: '', fractionalCompletion: 0 }
    const request = normalizeInitialRestoreRequest(input)
    input.fractionalCompletion = 0.5
    assert.equal(Object.isFrozen(request), true)
    assert.throws(() => { request.fractionalCompletion = 0.5 }, TypeError)
    assert.equal(request.fractionalCompletion, 0)
})

test('installed visible-page wrapper reaches the actual renderer for a required position receipt', async () => {
    const receipt = Object.freeze({ index: 0, anchor: 0 })
    let calls = 0, receivedThis, receivedOptions
    const renderer = { goTo(target, options) {
        calls += 1; receivedThis = this; receivedOptions = options
        assert.deepEqual(target, { index: 0, anchor: 0 })
        return Promise.resolve(receipt)
    } }
    installVisibleRendererGoToGuard({ renderer,
        getCurrentIndex: () => 0, getPageSnapshot: () => ({ current: 1, total: 4 }) })
    const options = { requiresPositionReceipt: true }
    assert.equal(await renderer.goTo({ index: 0, anchor: 0 }, options), receipt)
    assert.equal(calls, 1)
    assert.equal(receivedThis, renderer)
    assert.equal(receivedOptions, options)
})

test('installed wrapper preserves ordinary visible-page skipping and synthetic local-page dispatch', async () => {
    const calls = []
    const renderer = { goTo: target => { calls.push(target); return Promise.resolve('applied') } }
    const configuration = { renderer, getCurrentIndex: () => 0,
        getPageSnapshot: () => ({ current: 1, total: 4 }) }
    assert.equal(installVisibleRendererGoToGuard(configuration), true)
    const wrapper = renderer.goTo
    assert.equal(installVisibleRendererGoToGuard(configuration), false)
    assert.equal(renderer.goTo, wrapper)
    assert.equal(await renderer.goTo({ index: 0, anchor: 0 }), undefined)
    assert.equal(await renderer.goTo({ index: 0, localPage: 0 }), 'applied')
    assert.equal(await renderer.goTo({ index: 0, anchor: 0.7 }), 'applied')
    assert.equal(calls.length, 2)
})

test('initial restore requests derive locator identity from validated content', () => {
    assert.deepEqual(normalizeInitialRestoreRequest({
        requestID: ' request-1 ',
        requestedLocator: 'fraction',
        cfi: 'epubcfi(/6/14!)',
        fractionalCompletion: 0.7,
    }), {
        requestID: 'request-1',
        requestedLocator: 'cfi',
        cfi: 'epubcfi(/6/14!)',
        fractionalCompletion: 0.7,
    })
    assert.equal(normalizeInitialRestoreRequest({ requestID: '', cfi: 'epubcfi(/6/14!)' }), null)
    assert.deepEqual(normalizeInitialRestoreRequest({
        requestID: 'request-zero',
        cfi: '',
        fractionalCompletion: 0,
    }), {
        requestID: 'request-zero',
        requestedLocator: 'fraction',
        cfi: '',
        fractionalCompletion: 0,
    })
    assert.equal(normalizeInitialRestoreRequest({ requestID: 'request-2', cfi: '', fractionalCompletion: 2 }), null)
    assert.equal(normalizeInitialRestoreRequest({
        requestID: 'request-invalid-with-cfi',
        cfi: 'epubcfi(/6/14!)',
        fractionalCompletion: -0.1,
    }), null)
    assert.equal(normalizeInitialRestoreRequest({
        requestID: 'request-nan-with-cfi',
        cfi: 'epubcfi(/6/14!)',
        fractionalCompletion: Number.NaN,
    }), null)
})

test('initial restore terminal results retain request correlation and snapshot', () => {
    const request = normalizeInitialRestoreRequest({
        requestID: 'request-3',
        cfi: '',
        fractionalCompletion: 0.4,
    })
    assert.deepEqual(makeInitialRestoreTerminalResult({
        request,
        snapshot: {
            handledFractionalCompletion: 0.4,
            currentFractionalCompletion: 0.4,
            handledCFI: null,
        },
    }), {
        requestID: 'request-3',
        requestedLocator: 'fraction',
        terminalState: 'satisfied',
        navigationOk: true,
        restoreSatisfied: true,
        handledFractionalCompletion: 0.4,
        currentFractionalCompletion: 0.4,
        handledCFI: null,
        error: null,
    })
})

test('initial restore terminal results preserve navigation failures', () => {
    const request = normalizeInitialRestoreRequest({
        requestID: 'request-4',
        cfi: 'epubcfi(/6/14!)',
    })
    const result = makeInitialRestoreTerminalResult({
        request,
        snapshot: null,
        error: new Error('invalid saved CFI'),
    })

    assert.equal(result.terminalState, 'failed')
    assert.equal(result.navigationOk, false)
    assert.equal(result.restoreSatisfied, false)
    assert.equal(result.error, 'invalid saved CFI')
})

test('default opening reports no requested restore without promoting it to success', () => {
    const result = makeInitialRestoreTerminalResult({
        request: null,
        snapshot: { currentFractionalCompletion: 0 },
    })

    assert.equal(result.terminalState, 'noTarget')
    assert.equal(result.navigationOk, true)
    assert.equal(result.restoreSatisfied, false)
    assert.equal(result.currentFractionalCompletion, 0)
})

test('synthetic restore locators round trip normalized section state', () => {
    const locator = makeSyntheticRestoreLocator({
        sectionIndex: 7,
        localSectionIndex: 2,
        rendererTotal: 5,
    })

    assert.equal(locator, 'mnb-loc-v1:7:2:5')
    assert.deepEqual(parseSyntheticRestoreLocator(locator), {
        sectionIndex: 7,
        localSectionIndex: 2,
        rendererTotal: 5,
        fractionInSection: 0.5,
    })
    assert.equal(restoreLocatorKind({ cfi: locator, fractionalCompletion: 0.7 }), 'synthetic')
})

test('synthetic restore locators clamp persisted page coordinates', () => {
    const locator = makeSyntheticRestoreLocator({
        sectionIndex: -2,
        localSectionIndex: 99,
        rendererTotal: 4,
    })

    assert.equal(locator, 'mnb-loc-v1:0:3:4')
    assert.deepEqual(parseSyntheticRestoreLocator(locator), {
        sectionIndex: 0,
        localSectionIndex: 3,
        rendererTotal: 4,
        fractionInSection: 1,
    })
    assert.equal(parseSyntheticRestoreLocator('epubcfi(/6/14!)'), null)
    assert.equal(makeSyntheticRestoreLocator({ sectionIndex: 1, localSectionIndex: 0 }), null)
})

test('restore routing gives explicit locators priority over fractional completion', () => {
    assert.equal(restoreLocatorKind({ cfi: 'mnb-loc-v1:7:2:5', fractionalCompletion: 0.7 }), 'synthetic')
    assert.equal(restoreLocatorKind({ cfi: 'epubcfi(/6/14!)', fractionalCompletion: 0.7 }), 'cfi')
    assert.equal(restoreLocatorKind({ cfi: '', fractionalCompletion: 0.7 }), 'fraction')
    assert.equal(restoreLocatorKind({ cfi: '', fractionalCompletion: 0 }), 'fraction')
    assert.equal(restoreLocatorKind({ cfi: '', fractionalCompletion: 1 }), 'fraction')
    assert.equal(restoreLocatorKind({ cfi: '', fractionalCompletion: -0.01 }), 'none')
    assert.equal(restoreLocatorKind({ cfi: '', fractionalCompletion: 1.01 }), 'none')
})

test('scheduled fractional navigation waits for restore settling until user input', () => {
    assert.equal(shouldSkipScheduledReaderFractionGoTo({
        requiresUserInputBeforePositionSave: true,
        restoreSettlingMs: 2_000,
    }), true)
    assert.equal(shouldSkipScheduledReaderFractionGoTo({
        requiresUserInputBeforePositionSave: false,
        restoreSettlingMs: 2_000,
    }), false)
    assert.equal(shouldSkipScheduledReaderFractionGoTo({
        requiresUserInputBeforePositionSave: true,
        restoreSettlingMs: 0,
    }), false)
})

test('required restore navigation preserves failure instead of promoting a fallback', async () => {
    const failure = new Error('saved locator is invalid')
    const result = await runRequiredRestoreNavigation(async () => {
        throw failure
    })

    assert.equal(result.ok, false)
    assert.equal(result.value, null)
    assert.equal(result.error, failure)
})

test('required restore navigation returns the successful terminal value', async () => {
    const value = { sectionIndex: 4, fraction: 0.5 }
    const result = await runRequiredRestoreNavigation(async () => value)

    assert.deepEqual(result, {
        ok: true,
        value,
        error: null,
    })
})

test('same-section synthetic restore must reach the renderer for every finite local page', () => {
    for (const localPage of [0, 1, 3, -1, 1.5]) {
        assert.equal(shouldSkipVisibleRendererGoTo({
            target: {index: 2, localPage}, currentIndex: 2, currentPage: 1, totalPages: 5,
        }), false)
    }
    // Explicit page intent must win even if an anchor happens to match the HUD.
    assert.equal(shouldSkipVisibleRendererGoTo({
        target: {index: 2, localPage: 3, anchor: 0}, currentIndex: 2, currentPage: 1, totalPages: 5,
    }), false)
})

test('ordinary same-visible-page and section navigation retain existing decisions', () => {
    const current = {currentIndex: 2, currentPage: 3, totalPages: 5}
    assert.equal(shouldSkipVisibleRendererGoTo({...current, target: {index: 2, anchor: 0.5}}), true)
    assert.equal(shouldSkipVisibleRendererGoTo({...current, target: {index: 2, anchor: 0}}), false)
    assert.equal(shouldSkipVisibleRendererGoTo({...current, target: {index: 3, anchor: 0.5}}), false)
    assert.equal(shouldSkipVisibleRendererGoTo({...current, target: {index: 2}}), true)
    assert.equal(shouldSkipVisibleRendererGoTo({...current, target: null}), false)
})

test('nonfinite and absent local pages do not invent a synthetic restore intent', () => {
    for (const localPage of [undefined, null, NaN, Infinity, -Infinity, '3']) {
        assert.equal(shouldSkipVisibleRendererGoTo({
            target: {index: 2, localPage}, currentIndex: 2, currentPage: 1, totalPages: 5,
        }), true)
    }
})


test('paginated pure zero uses strict raw geometry while preserving measured completion', () => {
    const request = { requestID: 'zero', requestedLocator: 'fraction', cfi: '', fractionalCompletion: 0 }
    const geometry = { kind: 'paginated-first-page-v1', targetSectionIndex: 2,
        targetAnchor: 0, sectionIndex: 2, fractionInSection: 0, pageFraction: 0.25 }
    const snapshot = { positionMode: 'paginated', firstPageGeometry: geometry,
        handledFractionalCompletion: 0.125, currentFractionalCompletion: 0.125 }
    const result = makeInitialRestoreTerminalResult({ request, snapshot, loadRequestID: 'zero' })
    assert.equal(result.restoreSatisfied, true)
    assert.equal(result.handledFractionalCompletion, 0.125)
    assert.equal(result.currentFractionalCompletion, 0.125)
    assert.equal(result.loadRequestID, 'zero')
    assert.deepEqual(result.firstPageGeometry, geometry)
    for (const change of [
        { sectionIndex: 1 }, { fractionInSection: 0.001 }, { targetAnchor: 0.001 },
        { sectionIndex: true }, { targetSectionIndex: 2.5 }, { pageFraction: 0 },
        { pageFraction: Infinity }, { kind: 'unknown' },
    ]) {
        assert.equal(makeInitialRestoreTerminalResult({ request, snapshot: {
            ...snapshot, handledFractionalCompletion: 0.001, currentFractionalCompletion: 0.001,
            firstPageGeometry: { ...geometry, ...change },
        } }).restoreSatisfied, false)
    }
    for (const firstPageGeometry of [null, undefined, {}, false]) {
        assert.equal(makeInitialRestoreTerminalResult({ request, snapshot: {
            ...snapshot, handledFractionalCompletion: 0, currentFractionalCompletion: 0, firstPageGeometry,
        } }).restoreSatisfied, false)
    }
    for (const positionMode of [undefined, null, 'unknown']) {
        assert.equal(makeInitialRestoreTerminalResult({ request, snapshot: {
            ...snapshot, positionMode,
        } }).restoreSatisfied, false)
    }
    for (const positionMode of ['scrolled', 'other']) {
        assert.equal(makeInitialRestoreTerminalResult({ request, snapshot: {
            ...snapshot, positionMode, firstPageGeometry: undefined,
            handledFractionalCompletion: 0.001, currentFractionalCompletion: 0.001,
        } }).restoreSatisfied, true)
    }
})
