import assert from 'node:assert/strict'
import test from 'node:test'
import { makeInitialRestoreTerminalResult, normalizeInitialRestoreRequest, normalizeFirstPageGeometry }
    from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-restore-coordination.js'

const request = normalizeInitialRestoreRequest({ requestID: 'owned-zero', cfi: '', fractionalCompletion: 0 })
const geometry = { kind: 'paginated-first-page-v1', targetSectionIndex: 4, sectionIndex: 4,
    targetAnchor: 0, fractionInSection: 0, pageFraction: 0.25 }
const result = (positionMode = 'paginated', firstPageGeometry = geometry, fraction = 0.125, target = request) =>
    makeInitialRestoreTerminalResult({ request: target, snapshot: {
        handledFractionalCompletion: fraction, currentFractionalCompletion: fraction,
        positionMode, firstPageGeometry,
    } })

test('owned paginated first page accepts measured nonzero page-end completion', () => {
    assert.equal(result().restoreSatisfied, true)
    assert.equal(result('paginated', { ...geometry, pageFraction: 1 }, 0.5).restoreSatisfied, true)
})

test('paginated zero never falls back to a tiny global fraction', () => {
    for (const proof of [null, { ...geometry, sectionIndex: 5 },
        { ...geometry, targetAnchor: 0.001 }, { ...geometry, fractionInSection: 0.001 }]) {
        assert.equal(result('paginated', proof, 0.001).restoreSatisfied, false)
    }
    assert.equal(result(null, geometry, 0).restoreSatisfied, false)
    for (const fraction of [NaN, -0.01, 1.01, true, '0']) {
        assert.equal(result('paginated', geometry, fraction).restoreSatisfied, false)
    }
})

test('scrolled and other retain fraction tolerance and cannot use geometry to pass', () => {
    for (const mode of ['scrolled', 'other']) {
        assert.equal(result(mode, null, 0.001).restoreSatisfied, true)
        assert.equal(result(mode).restoreSatisfied, false)
    }
})

test('geometry wire decoder rejects booleans strings unsafe indices and invalid page fractions', () => {
    assert.deepEqual(normalizeFirstPageGeometry(geometry), geometry)
    for (const field of ['targetSectionIndex', 'sectionIndex', 'targetAnchor', 'fractionInSection', 'pageFraction']) {
        for (const value of [true, false, '0', NaN, Infinity, -1]) {
            assert.equal(normalizeFirstPageGeometry({ ...geometry, [field]: value }), null)
        }
    }
    for (const value of [0, 1.01]) assert.equal(normalizeFirstPageGeometry({ ...geometry, pageFraction: value }), null)
    for (const value of [0.5, Number.MAX_SAFE_INTEGER + 1]) {
        assert.equal(normalizeFirstPageGeometry({ ...geometry, sectionIndex: value }), null)
    }
})

test('geometry does not change positive fraction or CFI historical-zero rules', () => {
    const positive = { ...request, fractionalCompletion: 0.75 }
    assert.equal(result('paginated', geometry, 0.125, positive).restoreSatisfied, false)
    assert.equal(result('paginated', geometry, 0.75, positive).restoreSatisfied, true)
    const cfi = { ...request, cfi: 'epubcfi(/6/4)', requestedLocator: 'cfi' }
    const restored = makeInitialRestoreTerminalResult({ request: cfi, snapshot: {
        handledCFI: cfi.cfi, handledFractionalCompletion: 0.5, currentFractionalCompletion: 0.5,
        positionMode: 'paginated', firstPageGeometry: null,
    } })
    assert.equal(restored.restoreSatisfied, true)
})

test('explicit no-target requests keep unique correlation without claiming restore satisfaction', () => {
    const target = normalizeInitialRestoreRequest({ requestID: 'native-default', requestedLocator: 'none', cfi: '' })
    assert.equal(target.requestedLocator, 'none')
    const terminal = result('other', null, 0, target)
    assert.equal(terminal.requestID, 'native-default')
    assert.equal(terminal.terminalState, 'noTarget')
    assert.equal(terminal.restoreSatisfied, false)
    assert.equal(terminal.error, null)
    assert.equal(normalizeInitialRestoreRequest({ requestID: 'missing-locator', cfi: '' }), null)
})
