import assert from 'node:assert/strict'
import test from 'node:test'

import {
    documentHasLocalWritingDirectionSignal,
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

test('local writing-direction compatibility helper reports only document-owned evidence', () => {
    const localHorizontal = makeDocument({
        bodyAttributes: { 'data-mnb-foliate-writing-direction': 'horizontal' },
    })
    assert.equal(documentHasLocalWritingDirectionSignal(localHorizontal), true)

    const localInline = makeDocument({
        bodyAttributes: { style: 'writing-mode: vertical-lr' },
    })
    assert.equal(documentHasLocalWritingDirectionSignal(localInline), true)

    const unsignalled = makeDocument()
    assert.equal(documentHasLocalWritingDirectionSignal(unsignalled), false)
    assert.deepEqual(unsignalled.body.dataset, {})
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
