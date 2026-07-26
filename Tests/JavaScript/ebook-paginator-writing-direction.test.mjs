import assert from 'node:assert/strict'
import test from 'node:test'

import {
    paginatorDirectionFromDocument,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-paginator-writing-direction.js'

const makeDocument = ({
    bodyHTMLDirection = '',
    bodyStyle = '',
    bodyVerticalClass = false,
    rootDirection = '',
    rootStyle = '',
    bootstrapStyle = '',
    writingDirection = null,
} = {}) => ({
    body: {
        classList: {
            contains: value => value === 'reader-vertical-writing' && bodyVerticalClass,
        },
        dir: bodyHTMLDirection,
        getAttribute: name => {
            if (name === 'data-mnb-writing-direction') return writingDirection
            if (name === 'style') return bodyStyle
            return null
        },
    },
    documentElement: {
        dir: rootDirection,
        getAttribute: name => name === 'style' ? rootStyle : null,
    },
    getElementById: identifier => identifier === 'mnb-writing-direction-bootstrap' && bootstrapStyle
        ? { textContent: bootstrapStyle }
        : null,
})

test('reads authored vertical writing mode and RTL direction', () => {
    const result = paginatorDirectionFromDocument(makeDocument({
        bodyStyle: 'writing-mode: vertical-lr; direction: rtl',
    }))

    assert.deepEqual(result, {
        vertical: true,
        verticalRTL: false,
        rtl: true,
        writingMode: 'vertical-lr',
        direction: 'rtl',
    })
})

test('uses explicit direction and bootstrap style when authored inline styles are absent', () => {
    assert.deepEqual(
        paginatorDirectionFromDocument(makeDocument({ writingDirection: 'horizontal' })),
        {
            vertical: false,
            verticalRTL: false,
            rtl: false,
            writingMode: 'horizontal-tb',
            direction: null,
        },
    )
    assert.equal(
        paginatorDirectionFromDocument(makeDocument({
            bootstrapStyle: 'body { writing-mode: vertical-rl; }',
        }))?.writingMode,
        'vertical-rl',
    )
})

test('returns null when the document has no local direction signal', () => {
    assert.equal(paginatorDirectionFromDocument(makeDocument()), null)
})
