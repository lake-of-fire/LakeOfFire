import assert from 'node:assert/strict'
import test from 'node:test'

import {
    applyPaginatorWritingDirectionOverride,
    paginatorDirectionFromDocument,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-paginator-writing-direction.js'

const makeDocument = ({
    bodyHTMLDirection = '',
    bodyStyle = '',
    bodyVerticalClass = false,
    rootDirection = '',
    rootStyle = '',
    bootstrapStyle = '',
    foliateWritingDirection = null,
    foliateWritingMode = null,
    writingDirection = null,
    writingMode = null,
} = {}) => {
    const attributes = new Map()
    const elementsByIdentifier = new Map()
    if (writingDirection != null) {
        attributes.set('data-mnb-writing-direction', writingDirection)
    }
    if (writingMode != null) {
        attributes.set('data-mnb-writing-mode', writingMode)
    }
    if (foliateWritingDirection != null) {
        attributes.set('data-mnb-foliate-writing-direction', foliateWritingDirection)
    }
    if (foliateWritingMode != null) {
        attributes.set('data-mnb-foliate-writing-mode', foliateWritingMode)
    }
    const document = {
        body: {
            classList: {
                contains: value => value === 'reader-vertical-writing' && bodyVerticalClass,
            },
            dir: bodyHTMLDirection,
            getAttribute: name => {
                if (name === 'style') return bodyStyle
                return attributes.get(name) ?? null
            },
            removeAttribute: name => attributes.delete(name),
            setAttribute: (name, value) => attributes.set(name, value),
        },
        documentElement: {
            dir: rootDirection,
            getAttribute: name => name === 'style' ? rootStyle : null,
            appendChild: element => elementsByIdentifier.set(element.id, element),
        },
        createElement: () => ({
            id: '',
            remove() {
                elementsByIdentifier.delete(this.id)
            },
            textContent: '',
        }),
        getElementById: identifier => {
            if (identifier === 'mnb-writing-direction-bootstrap' && bootstrapStyle) {
                return { textContent: bootstrapStyle }
            }
            return elementsByIdentifier.get(identifier) ?? null
        },
    }
    return document
}

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
    assert.equal(
        paginatorDirectionFromDocument(makeDocument({
            writingDirection: 'vertical',
            writingMode: 'vertical-lr',
        }))?.writingMode,
        'vertical-lr',
    )
})

test('gives an explicit horizontal reader override precedence over authored vertical style', () => {
    assert.deepEqual(
        paginatorDirectionFromDocument(makeDocument({
            bodyStyle: 'writing-mode: vertical-rl',
            writingDirection: 'horizontal',
        })),
        {
            vertical: false,
            verticalRTL: false,
            rtl: false,
            writingMode: 'horizontal-tb',
            direction: null,
        },
    )
})

test('restores the immutable source direction after clearing a reader override', () => {
    const document = makeDocument({
        foliateWritingDirection: 'vertical',
        foliateWritingMode: 'vertical-lr',
        writingDirection: 'vertical',
    })

    assert.equal(applyPaginatorWritingDirectionOverride(document, 'horizontal'), 'horizontal')
    assert.equal(document.body.getAttribute('data-mnb-writing-direction'), 'horizontal')
    document.body.setAttribute('data-mnb-foliate-writing-direction', 'horizontal')
    document.body.setAttribute('data-mnb-foliate-writing-mode', 'horizontal-tb')
    assert.equal(
        document.getElementById('mnb-paginator-writing-direction-override')?.textContent,
        'html, body { writing-mode: horizontal-tb !important; }',
    )
    assert.equal(applyPaginatorWritingDirectionOverride(document, 'original'), 'original')
    assert.equal(document.body.getAttribute('data-mnb-writing-direction'), 'vertical')
    assert.equal(document.body.getAttribute('data-mnb-foliate-writing-direction'), 'vertical')
    assert.equal(document.body.getAttribute('data-mnb-foliate-writing-mode'), 'vertical-lr')
    assert.equal(
        document.getElementById('mnb-paginator-writing-direction-override'),
        null,
    )

    const documentWithoutSourceHint = makeDocument()
    applyPaginatorWritingDirectionOverride(documentWithoutSourceHint, 'vertical')
    applyPaginatorWritingDirectionOverride(documentWithoutSourceHint, 'invalid')
    assert.equal(
        documentWithoutSourceHint.body.getAttribute('data-mnb-writing-direction'),
        null,
    )
})

test('returns null when the document has no local direction signal', () => {
    assert.equal(paginatorDirectionFromDocument(makeDocument()), null)
})
