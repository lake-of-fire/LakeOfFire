import assert from 'node:assert/strict'
import test from 'node:test'
import {
    makeInitialRestoreTerminalResult,
    normalizeInitialRestoreRequest,
    restoreFractionValidationTolerance,
    runRequiredRestoreNavigation,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-restore-coordination.js'

const cfi = 'epubcfi(/6/10)'
const request = normalizeInitialRestoreRequest({ requestID: 'restore-current', cfi, fractionalCompletion: 0.25 })
const snapshot = { handledFractionalCompletion: 0.25, currentFractionalCompletion: 0.25, handledCFI: cfi }
const result = (overrides = {}, target = request, error = null) => makeInitialRestoreTerminalResult({
    request: target, snapshot: { ...snapshot, ...overrides }, error,
})

test('hotfix matching fractions tolerate a different renderer CFI', () => {
    const restored = result({ handledFractionalCompletion: 0.251, currentFractionalCompletion: 0.249, handledCFI: 'different-cfi' })
    assert.equal(restored.terminalState, 'satisfied')
    assert.equal(restored.restoreSatisfied, true)
    assert.equal(restored.error, null)
    assert.equal(restored.requestID, request.requestID)
})

test('a no-throw navigation landing at the beginning is not a successful restore', () => {
    const restored = result({ handledFractionalCompletion: 0, currentFractionalCompletion: 0 })
    assert.equal(restored.navigationOk, true)
    assert.equal(restored.terminalState, 'failed')
    assert.equal(restored.restoreSatisfied, false)
    assert.equal(restored.error, 'Saved restore position was not reached')
    assert.equal(restored.handledCFI, cfi)
})

test('both the handled and final fraction must match the saved target', () => {
    for (const field of ['handledFractionalCompletion', 'currentFractionalCompletion']) {
        const restored = result({ [field]: 0.75 })
        assert.equal(restored.restoreSatisfied, false, field)
        assert.equal(restored.terminalState, 'failed', field)
    }
})

test('missing, non-finite, boolean and out-of-range snapshots cannot acknowledge saved progress', () => {
    for (const value of [null, undefined, NaN, Infinity, -Infinity, true, false, '0.25', -0.1, 1.1]) {
        for (const field of ['handledFractionalCompletion', 'currentFractionalCompletion']) {
            const restored = result({ [field]: value })
            assert.equal(restored.restoreSatisfied, false, `${field}:${value}`)
            assert.equal(restored[field], null)
        }
    }
})

test('the hotfix tolerance is inclusive with a distinguishable outside value', () => {
    assert.equal(restoreFractionValidationTolerance, 0.003)
    const target = { requestID: 'explicit-zero', requestedLocator: 'fraction', cfi: '', fractionalCompletion: 0 }
    assert.equal(result({ handledFractionalCompletion: 0.003, currentFractionalCompletion: 0.003 }, target).restoreSatisfied, true)
    assert.equal(result({ currentFractionalCompletion: 0.003001, handledFractionalCompletion: 0 }, target).restoreSatisfied, false)
})

test('CFI-only restore requires the matching handled CFI without fabricating fractions', () => {
    const target = normalizeInitialRestoreRequest({ requestID: 'cfi-only', cfi })
    const restored = result({ handledFractionalCompletion: null, currentFractionalCompletion: null }, target)
    assert.equal(restored.restoreSatisfied, true)
    for (const handledCFI of [null, undefined, '', 'another-cfi']) {
        assert.equal(result({ handledCFI }, target).restoreSatisfied, false)
    }
})

test('synthetic locator validation retains the existing CFI-shaped wire contract', () => {
    const target = normalizeInitialRestoreRequest({ requestID: 'synthetic', cfi: 'mnb-loc-v1:7:2:5' })
    assert.equal(target.requestedLocator, 'cfi')
    assert.equal(result({ handledCFI: target.cfi }, target).restoreSatisfied, true)
    assert.equal(result({ handledCFI: cfi }, target).restoreSatisfied, false)
})

test('matching snapshots never override the original navigation exception', async () => {
    const failure = new Error('renderer failed after locating target')
    const navigation = await runRequiredRestoreNavigation(async () => { throw failure })
    const restored = result({}, request, navigation.error)
    assert.equal(navigation.error, failure)
    assert.equal(restored.navigationOk, false)
    assert.equal(restored.restoreSatisfied, false)
    assert.equal(restored.error, failure.message)
})

test('a null snapshot cannot acknowledge an otherwise valid saved request', () => {
    const restored = makeInitialRestoreTerminalResult({ request, snapshot: null })
    assert.equal(restored.terminalState, 'failed')
    assert.equal(restored.restoreSatisfied, false)
})

test('the final-page fraction is a valid restoration endpoint', () => {
    const target = normalizeInitialRestoreRequest({ requestID: 'end', cfi: '', fractionalCompletion: 1 })
    assert.equal(result({ handledFractionalCompletion: 1, currentFractionalCompletion: 1 }, target).restoreSatisfied, true)
    assert.equal(result({}, target).restoreSatisfied, false)
})

test('unrequested initial navigation retains noTarget semantics on success and failure', () => {
    for (const error of [null, new Error('default open failed')]) {
        const restored = makeInitialRestoreTerminalResult({ request: null, snapshot, error })
        assert.equal(restored.terminalState, 'noTarget')
        assert.equal(restored.restoreSatisfied, false)
        assert.equal(restored.requestID, null)
        assert.equal(restored.error, error?.message ?? null)
    }
})

test('fulfilled void renderer success still requires a matching terminal snapshot', async () => {
    const navigation = await runRequiredRestoreNavigation(async () => {})
    assert.equal(navigation.ok, true)
    assert.equal(result({}, request, navigation.error).restoreSatisfied, true)
    assert.equal(result({ currentFractionalCompletion: 0 }, request, navigation.error).restoreSatisfied, false)
})

test('terminal results cross the real JSON wire without altering correlation or endpoints', () => {
    const target = { requestID: 'wire-zero', requestedLocator: 'fraction', cfi: '', fractionalCompletion: 0 }
    const restored = result({ handledFractionalCompletion: 0, currentFractionalCompletion: 0, handledCFI: null }, target)
    assert.deepEqual(JSON.parse(JSON.stringify(restored)), restored)
    assert.equal(restored.requestID, 'wire-zero')
    assert.equal(restored.currentFractionalCompletion, 0)
    assert.equal(restored.restoreSatisfied, true)
})
