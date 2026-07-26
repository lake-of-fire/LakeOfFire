import assert from 'node:assert/strict'
import test from 'node:test'

import {
    excludedEbookBlankPointerTarget,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-blank-pointer-target.js'

const targetInside = matchingSelector => {
    const matchedAncestor = { matchingSelector }
    return {
        closest(selectorList) {
            return selectorList
                .split(',')
                .map(selector => selector.trim())
                .includes(matchingSelector)
                ? matchedAncestor
                : null
        },
        matchedAncestor,
    }
}

test('compact sentence, segment, and text elements are not blank-page targets', () => {
    for (const selector of ['m-m', 'm-s', 'm-t']) {
        const target = targetInside(selector)
        assert.equal(
            excludedEbookBlankPointerTarget(target),
            target.matchedAncestor,
            selector,
        )
    }
})

test('interactive and ruby descendants are not blank-page targets', () => {
    for (const selector of ['a', 'button', '[role="button"]', '[contenteditable="true"]', 'ruby', 'rt']) {
        const target = targetInside(selector)
        assert.equal(
            excludedEbookBlankPointerTarget(target),
            target.matchedAncestor,
            selector,
        )
    }
})

test('ordinary content remains eligible for blank-page handling', () => {
    assert.equal(excludedEbookBlankPointerTarget(targetInside('p')), null)
    assert.equal(excludedEbookBlankPointerTarget(null), null)
})
