import assert from 'node:assert/strict'
import test from 'node:test'

import { SectionProgress } from '../../Sources/LakeOfFireReader/Resources/foliate-js/progress.js'

const section = (size, linear = 'yes') => ({ size, linear })

test('maps exact boundaries to the following linear section', () => {
    const progress = new SectionProgress([section(100), section(100), section(200)], 10, 10)

    assert.deepEqual(progress.getSection(0), [0, 0])
    assert.deepEqual(progress.getSection(0.25), [1, 0])
    assert.deepEqual(progress.getSection(0.5), [2, 0])
    assert.deepEqual(progress.getSection(1), [2, 1])
})

test('skips repeated zero-sized and non-linear sections', () => {
    const progress = new SectionProgress([
        section(0),
        section(100),
        section(50, 'no'),
        section(0),
        section(100),
        section(0),
    ], 10, 10)

    assert.deepEqual(progress.getSection(0), [1, 0])
    assert.deepEqual(progress.getSection(0.5), [4, 0])
    assert.deepEqual(progress.getSection(1), [4, 1])
})

test('returns a deterministic neutral section for empty and all-zero spines', () => {
    const empty = new SectionProgress([], 10, 10)
    const allZero = new SectionProgress([
        section(0),
        section(-1),
        section(Number.NaN),
        section(Number.POSITIVE_INFINITY),
        section(100, 'no'),
    ], 10, 10)

    assert.deepEqual(empty.getSection(0.5), [0, 0])
    assert.deepEqual(allZero.getSection(0.5), [0, 0])
    assert.equal(empty.getProgress(0, 0).fraction, 0)
    assert.equal(allZero.getProgress(0, 0).fraction, 0)
})

test('clamps non-finite and out-of-range fractions', () => {
    const progress = new SectionProgress([section(0), section(100), section(100)], 10, 10)

    assert.deepEqual(progress.getSection(Number.NaN), [1, 0])
    assert.deepEqual(progress.getSection(Number.NEGATIVE_INFINITY), [1, 0])
    assert.deepEqual(progress.getSection(Number.POSITIVE_INFINITY), [2, 1])
    assert.deepEqual(progress.getSection(-10), [1, 0])
    assert.deepEqual(progress.getSection(10), [2, 1])
})

test('round trips monotonic progress across positive sections', () => {
    const progress = new SectionProgress([
        section(75),
        section(0),
        section(125),
        section(300),
    ], 10, 10)
    const samples = [
        [0, 0.2],
        [0, 0.8],
        [2, 0.25],
        [2, 0.75],
        [3, 0.1],
        [3, 0.9],
    ]

    let previousFraction = -1
    for (const [index, fractionInSection] of samples) {
        const fraction = progress.getProgress(index, fractionInSection).fraction
        assert.ok(fraction > previousFraction)
        previousFraction = fraction
        const [resolvedIndex, resolvedFraction] = progress.getSection(fraction)
        assert.equal(resolvedIndex, index)
        assert.ok(Math.abs(resolvedFraction - fractionInSection) < 1e-12)
    }
})
