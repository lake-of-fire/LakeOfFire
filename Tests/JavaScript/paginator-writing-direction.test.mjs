import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'

import {
    writingDirectionFromDocumentEvidence,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/paginator-writing-direction.js'

const makeClassList = initial => {
    const values = new Set(initial)
    return {
        add: value => values.add(value),
        contains: value => values.has(value),
    }
}

const makeElement = ({ classes = [], attributes = {} } = {}) => {
    const values = new Map(Object.entries(attributes))
    return {
        dataset: {},
        classList: makeClassList(classes),
        getAttribute: name => values.get(name) ?? null,
    }
}

const makeDocument = ({
    bodyClasses = [],
    rootClasses = [],
    bodyAttributes = {},
    rootAttributes = {},
    href = 'ebook://ebook/processed-section',
} = {}) => ({
    body: makeElement({ classes: bodyClasses, attributes: bodyAttributes }),
    documentElement: makeElement({ classes: rootClasses, attributes: rootAttributes }),
    getElementById: () => null,
    location: { href },
})

test('mixed vertical and horizontal chapters resolve from their own computed documents', () => {
    const vertical = makeDocument()
    const horizontal = makeDocument()

    assert.deepEqual(writingDirectionFromDocumentEvidence(vertical, {
        computedWritingMode: 'vertical-rl',
        computedDirection: 'rtl',
    }), {
        vertical: true,
        verticalRTL: true,
        rtl: true,
        writingMode: 'vertical-rl',
        direction: 'rtl',
        source: 'computed',
    })
    assert.deepEqual(writingDirectionFromDocumentEvidence(horizontal, {
        computedWritingMode: 'horizontal-tb',
        computedDirection: 'ltr',
    }), {
        vertical: false,
        verticalRTL: false,
        rtl: false,
        writingMode: 'horizontal-tb',
        direction: 'ltr',
        source: 'computed',
    })
})

test('the computed cascade wins over contradictory raw inline declaration text', () => {
    const document = makeDocument({
        bodyAttributes: {
            style: 'writing-mode: vertical-rl; direction: rtl',
        },
    })

    assert.deepEqual(writingDirectionFromDocumentEvidence(document, {
        computedWritingMode: 'horizontal-tb',
        computedDirection: 'ltr',
    }), {
        vertical: false,
        verticalRTL: false,
        rtl: false,
        writingMode: 'horizontal-tb',
        direction: 'ltr',
        source: 'computed',
    })
})

test('paginator does not mutate a section from publication-wide direction history', () => {
    const paginatorSource = readFileSync(new URL(
        '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/paginator.js',
        import.meta.url,
    ), 'utf8')

    assert.doesNotMatch(paginatorSource, /writingDirectionObservation/)
    assert.doesNotMatch(paginatorSource, /ApplyPreferredWritingDirection/)
    assert.doesNotMatch(paginatorSource, /RememberObservedWritingDirection/)
    assert.doesNotMatch(paginatorSource, /BodylessComputedStyle|bodylessStyle/)
})

test('shared document evidence ignores blank and invalid declarations before valid evidence', () => {
    const document = makeDocument({
        bodyAttributes: {
            'data-mnb-foliate-writing-mode': '',
            style: 'writing-mode: inherit',
        },
        rootAttributes: {
            'data-mnb-foliate-writing-mode': 'vertical-lr',
            dir: 'rtl',
        },
    })

    assert.deepEqual(writingDirectionFromDocumentEvidence(document, {
        computedWritingMode: 'vertical-rl',
        computedDirection: 'ltr',
    }), {
        vertical: true,
        verticalRTL: false,
        rtl: true,
        writingMode: 'vertical-lr',
        direction: 'ltr',
        source: 'attribute-mode',
    })
})

test('invalid inline writing mode falls through to computed vertical evidence', () => {
    const document = makeDocument({
        bodyAttributes: { style: 'writing-mode: inherit' },
    })

    assert.deepEqual(writingDirectionFromDocumentEvidence(document, {
        computedWritingMode: 'vertical-lr',
        computedDirection: 'rtl',
    }), {
        vertical: true,
        verticalRTL: false,
        rtl: true,
        writingMode: 'vertical-lr',
        direction: 'rtl',
        source: 'computed',
    })
    assert.deepEqual(writingDirectionFromDocumentEvidence(document, {
        computedWritingMode: 'horizontal-tb',
    }), {
        vertical: false,
        verticalRTL: false,
        rtl: false,
        writingMode: 'horizontal-tb',
        direction: null,
        source: 'computed',
    })
})
