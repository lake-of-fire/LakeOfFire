import assert from 'node:assert/strict'
import test from 'node:test'

import {
    makeInitialRestoreTerminalResult,
    makeSyntheticRestoreLocator,
    normalizeInitialRestoreRequest,
    parseSyntheticRestoreLocator,
    restoreLocatorKind,
    runRequiredRestoreNavigation,
    shouldSkipScheduledReaderFractionGoTo,
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
    assert.equal(normalizeInitialRestoreRequest({ requestID: 'request-2', cfi: '', fractionalCompletion: 2 }), null)
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
    assert.equal(restoreLocatorKind({ cfi: '', fractionalCompletion: 0 }), 'none')
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
