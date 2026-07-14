import assert from 'node:assert/strict'
import test from 'node:test'

import { ebookProgressFractionForRelocate } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-reading-progress.js'

test('persists the exact relocate fraction instead of rounded display progress', () => {
    assert.equal(ebookProgressFractionForRelocate({
        relocateFraction: 0.42,
        authoritativeFraction: 0.012963,
    }), 0.42)
})

test('falls back to authoritative progress and clamps the storage domain', () => {
    assert.equal(ebookProgressFractionForRelocate({
        relocateFraction: Number.NaN,
        authoritativeFraction: 0.25,
    }), 0.25)
    assert.equal(ebookProgressFractionForRelocate({
        relocateFraction: -0.2,
        authoritativeFraction: 0.5,
    }), 0)
    assert.equal(ebookProgressFractionForRelocate({
        relocateFraction: 1.2,
        authoritativeFraction: 0.5,
    }), 1)
})
