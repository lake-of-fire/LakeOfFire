import assert from 'node:assert/strict'
import test from 'node:test'

import {
    buildRelocateLocation,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/relocate-location.js'

test('uses one bounded section identity for every relocation projection', () => {
    const receivedIndexes = []
    const range = { id: 'visible-range' }
    const location = buildRelocateLocation({
        reason: 'page',
        range,
        index: 99,
        fraction: 0.25,
        size: 0.5,
        pageTurnDirection: 'next',
    }, {
        sectionCount: 3,
        sectionProgress: {
            getProgress(index, fraction, size) {
                receivedIndexes.push(['progress', index, fraction, size])
                return { fraction: 0.75 }
            },
        },
        tocProgress: {
            getProgress(index, receivedRange) {
                receivedIndexes.push(['toc', index, receivedRange])
                return { href: 'chapter-3.xhtml' }
            },
        },
        pageProgress: {
            getProgress(index, receivedRange) {
                receivedIndexes.push(['page', index, receivedRange])
                return { label: '3' }
            },
        },
        cfiProvider: {
            getCFI(index, receivedRange) {
                receivedIndexes.push(['cfi', index, receivedRange])
                return 'epubcfi(/6/6)'
            },
        },
    })

    assert.deepEqual(receivedIndexes, [
        ['progress', 2, 0.25, 0.5],
        ['toc', 2, range],
        ['page', 2, range],
        ['cfi', 2, range],
    ])
    assert.deepEqual(location, {
        fraction: 0.75,
        index: 2,
        sectionIndex: 2,
        tocItem: { href: 'chapter-3.xhtml' },
        pageItem: { label: '3' },
        cfi: 'epubcfi(/6/6)',
        range,
        reason: 'page',
        pageTurnDirection: 'next',
    })
})

test('uses deterministic endpoints for malformed relocation identities', () => {
    const build = (index, sectionCount = 3) => buildRelocateLocation(
        { index },
        { sectionCount },
    )

    assert.equal(build(-1).index, 0)
    assert.equal(build(Number.NaN).index, 0)
    assert.equal(build(1.5).index, 0)
    assert.equal(build(Number.POSITIVE_INFINITY).index, 2)
    assert.equal(build(20).index, 2)
    assert.equal(build(20, 0).index, 0)
})


test('retains raw page geometry separately from measured page-end progress', async () => {
    const { SectionProgress } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/progress.js')
    for (const sections of [
        [{ size: 100 }, { size: 100 }],
        [{ size: 0 }, { size: 50, linear: 'no' }, { size: 100 }, { size: 100 }],
    ]) {
        const sectionProgress = new SectionProgress(sections, 10, 10)
        const [index, fraction] = sectionProgress.getSection(0)
        const location = buildRelocateLocation({ index, fraction, size: 0.25 }, {
            sectionCount: sections.length, sectionProgress,
        })
        assert.equal(location.fraction, 0.125)
        assert.deepEqual(location.firstPageGeometrySource, {
            sectionIndex: index, fractionInSection: 0, pageFraction: 0.25,
        })
    }
})

test('preserves contradictory valid geometry for the restore consumer to reject', () => {
    const location = buildRelocateLocation({ index: 1, fraction: 0.001, size: 1 }, { sectionCount: 2 })
    assert.deepEqual(location.firstPageGeometrySource, {
        sectionIndex: 1, fractionInSection: 0.001, pageFraction: 1,
    })
})

test('does not manufacture raw geometry from normalized malformed inputs', () => {
    const valid = { index: 0, fraction: 0, size: 0.25 }
    const invalid = [
        ...[-1, 2, 0.5, NaN, Infinity, '0', true].map(index => ({ index })),
        ...[-1, 1.01, NaN, Infinity, '0', false, undefined].map(fraction => ({ fraction })),
        ...[-1, 0, 1.01, NaN, Infinity, '0.25', true, undefined].map(size => ({ size })),
    ]
    for (const change of invalid) {
        const location = buildRelocateLocation({ ...valid, ...change }, { sectionCount: 2 })
        assert.equal(Object.hasOwn(location, 'firstPageGeometrySource'), false)
    }
    assert.equal(Object.hasOwn(buildRelocateLocation(valid, { sectionCount: 0 }),
        'firstPageGeometrySource'), false)
})
