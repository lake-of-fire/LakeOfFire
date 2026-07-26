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
