import assert from 'node:assert/strict'
import test from 'node:test'

globalThis.HTMLElement = class {}
globalThis.customElements = { define() {} }

const { fixedLayoutContentDescriptor } = await import(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/fixed-layout.js'
)

test('preserves fixed-layout frame ownership and identity', () => {
    const doc = { title: 'page' }
    const iframe = { contentDocument: doc }
    const element = { id: 'frame-wrapper' }
    const descriptor = fixedLayoutContentDescriptor({
        index: 4,
        generation: 7,
        iframe,
        element,
    })

    assert.deepEqual(descriptor, {
        index: 4,
        generation: 7,
        doc,
        iframe,
        element,
    })
})

test('reads the live document from the owned iframe', () => {
    const firstDocument = { title: 'first' }
    const secondDocument = { title: 'second' }
    const iframe = { contentDocument: firstDocument }
    const frame = { index: 2, generation: 3, iframe, element: {} }

    assert.equal(fixedLayoutContentDescriptor(frame).doc, firstDocument)
    iframe.contentDocument = secondDocument
    assert.equal(fixedLayoutContentDescriptor(frame).doc, secondDocument)
})

test('rejects records without an owned iframe', () => {
    assert.equal(fixedLayoutContentDescriptor(null), null)
    assert.equal(fixedLayoutContentDescriptor({ element: {} }), null)
})
