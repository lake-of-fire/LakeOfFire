import assert from 'node:assert/strict'
import test from 'node:test'

class Element extends EventTarget {
    constructor(name) { super(); this.localName = name; this.children = []; this.attributes = new Map(); this.style = {} }
    append(...children) { for (const child of children) { child.parentNode = this; this.children.push(child) } }
    replaceChildren(...children) { this.children = []; this.append(...children) }
    setAttribute(name, value) { this.attributes.set(name, String(value)) }
    getAttribute(name) { return this.attributes.get(name) ?? null }
    removeAttribute(name) { this.attributes.delete(name) }
    scrollIntoView() {}
}
globalThis.document = {
    createElement: name => new Element(name),
    createElementNS: (_namespace, name) => new Element(name),
    createTreeWalker: () => ({ currentNode: null }),
}
const { createTOCView } = await import('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ui/tree.js')

test('an empty TOC can receive repeated current-location updates', () => {
    const toc = createTOCView([], () => assert.fail('Empty TOC navigated'))
    for (const href of ['chapter.xhtml', null, undefined, 'another.xhtml']) {
        assert.doesNotThrow(() => toc.setCurrentHref(href))
        assert.equal(toc.element.children.length, 0)
    }
})

test('a nonempty TOC keeps current-item and missing-target focus behavior', () => {
    const toc = createTOCView([{ href: 'one.xhtml', label: 'One' }], () => {})
    const item = toc.element.children[0].children[0]
    toc.setCurrentHref('one.xhtml')
    assert.equal(item.getAttribute('aria-current'), 'page')
    assert.equal(item.tabIndex, 0)
    toc.setCurrentHref('missing.xhtml')
    assert.equal(item.getAttribute('aria-current'), null)
    assert.equal(item.tabIndex, 0)
})
