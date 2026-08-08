import assert from 'node:assert/strict'
import test from 'node:test'

import { applyObservedWritingDirectionToDocument } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/paginator-writing-direction.js'

const makeClassList = initial => {
    const values = new Set(initial)
    return {
        add: value => values.add(value),
        contains: value => values.has(value),
    }
}

const makeDocument = ({ direction = null, verticalClass = false } = {}) => {
    const attributes = new Map()
    if (direction) attributes.set('data-mnb-writing-direction', direction)
    const body = {
        dataset: direction ? { mnbWritingDirection: direction } : {},
        classList: makeClassList(verticalClass ? ['reader-vertical-writing'] : []),
        getAttribute: name => attributes.get(name) ?? null,
    }
    const documentElement = {
        classList: makeClassList([]),
        getAttribute: () => null,
    }
    return { body, documentElement, getElementById: () => null }
}

test('preserves an explicit document writing direction', () => {
    const document = makeDocument({ direction: 'vertical', verticalClass: true })
    const applied = applyObservedWritingDirectionToDocument(document, {
        __manabiObservedBookWritingDirection: 'horizontal',
    })

    assert.equal(applied, false)
    assert.equal(document.body.dataset.mnbWritingDirection, 'vertical')
    assert.equal(document.body.classList.contains('reader-vertical-writing'), true)
})

test('applies an observed vertical direction only when the document has no local signal', () => {
    const document = makeDocument()
    const applied = applyObservedWritingDirectionToDocument(document, {
        __manabiObservedBookWritingDirection: 'vertical',
        __manabiObservedBookWritingMode: 'vertical-rl',
    })

    assert.equal(applied, true)
    assert.equal(document.body.dataset.mnbFoliateWritingDirection, 'vertical')
    assert.equal(document.body.dataset.mnbFoliateWritingMode, 'vertical-rl')
    assert.equal(document.body.classList.contains('reader-vertical-writing'), true)
    assert.equal(document.documentElement.classList.contains('vrtl'), true)
})
