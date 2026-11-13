import assert from 'node:assert/strict'
import test from 'node:test'

import {
    isRestoreTransactionSupersededError,
    makeInitialRestoreTerminalResult,
    makeSyntheticRestoreLocator,
    normalizeInitialRestoreRequest,
    parseSyntheticRestoreLocator,
    restoreLocatorKind,
    runLocatorWithFractionFallback,
    runRequiredRestoreNavigation,
    shouldSkipScheduledReaderFractionGoTo,
    shouldSkipVisibleRendererGoTo,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-restore-coordination.js'

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
        positionMode: null,
        firstPageGeometry: null,
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

test('renderer and resolved view locator success receipts preserve the saved locator', async () => {
    for (const receipt of [true, { index: 0, anchor: () => 0 }]) {
        let fractionCalls = 0
        assert.equal(await runLocatorWithFractionFallback({
            navigateLocator: async () => receipt,
            navigateFraction: async () => { fractionCalls += 1; return true },
            isCurrent: () => true,
        }), true)
        assert.equal(fractionCalls, 0)
    }
})

test('a busy locator attempt uses at most one fraction fallback and keeps its failure', async () => {
    for (const fallbackReceipt of [true, false, { ignored: true, reason: 'rendererNavigationInFlight' }]) {
        let fractionCalls = 0
        assert.equal(await runLocatorWithFractionFallback({
            navigateLocator: async () => ({ ignored: true, reason: 'rendererNavigationInFlight' }),
            navigateFraction: async () => { fractionCalls += 1; return fallbackReceipt },
            isCurrent: () => true,
        }), fallbackReceipt === true)
        assert.equal(fractionCalls, 1)
    }
})

test('a busy locator attempt without a fraction fallback fails restoration', async () => {
    await assert.rejects(runLocatorWithFractionFallback({
        navigateLocator: async () => ({ ignored: true, reason: 'rendererNavigationInFlight' }),
        navigateFraction: null,
        isCurrent: () => true,
    }), /Saved locator was not accepted/)
})

test('a successful locator completion cannot satisfy a superseded restore', async () => {
    for (const receipt of [true, { index: 0, anchor: () => 0 }]) {
        let current = true
        let fractionCalls = 0
        await assert.rejects(runLocatorWithFractionFallback({
            navigateLocator: async () => { current = false; return receipt },
            navigateFraction: async () => { fractionCalls += 1; return true },
            isCurrent: () => current,
        }), isRestoreTransactionSupersededError)
        assert.equal(fractionCalls, 0)
    }
})

test('renderer ownership loss cannot start a fraction fallback even while the restore is current', async () => {
    for (const receipt of [
        { ignored: true, reason: 'rendererNavigationSuperseded' },
        { ignored: true, superseded: true, reason: 'fixedLayoutNavigationSuperseded' },
        { ignored: true, reason: 'rendererDestroyed' },
    ]) {
        let fractionCalls = 0
        await assert.rejects(runLocatorWithFractionFallback({
            navigateLocator: async () => receipt,
            navigateFraction: async () => { fractionCalls += 1; return true },
            isCurrent: () => true,
        }), isRestoreTransactionSupersededError)
        assert.equal(fractionCalls, 0)
    }
})

test('fallback callbacks cannot launch navigation after retiring their restore', async () => {
    let current = true
    let fractionCalls = 0
    await assert.rejects(runLocatorWithFractionFallback({
        navigateLocator: async () => ({ ignored: true, reason: 'rendererNavigationInFlight' }),
        navigateFraction: async () => { fractionCalls += 1; return true },
        onFallback: () => { current = false },
        isCurrent: () => current,
    }), isRestoreTransactionSupersededError)
    assert.equal(fractionCalls, 0)
})

test('a successful fraction fallback cannot satisfy a superseded restore', async () => {
    let current = true
    await assert.rejects(runLocatorWithFractionFallback({
        navigateLocator: async () => false,
        navigateFraction: async () => { current = false; return true },
        isCurrent: () => current,
    }), isRestoreTransactionSupersededError)
})

