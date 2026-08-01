import assert from 'node:assert/strict'
import test from 'node:test'

class FakeElement extends EventTarget {
    constructor() {
        super()
        this.style = {}
        this.dataset = {}
        this.children = []
        this.parentElement = null
    }
    append(child) {
        child.parentElement = this
        this.children.push(child)
    }
    setAttribute() {}
    getBoundingClientRect() { return { width: 800, height: 1000 } }
}

class FakeShadowRoot extends FakeElement {
    replaceChildren(...children) {
        this.children = children
        for (const child of children) child.parentElement = this
    }
    querySelectorAll(selector) {
        if (selector !== 'iframe') return []
        return this.children.flatMap(element => element.children.filter(child => child instanceof FakeIFrame))
    }
}

class FakeIFrame extends FakeElement {
    constructor() {
        super()
        this.contentDocument = {}
    }
}

globalThis.HTMLElement = class extends FakeElement {
    attachShadow() { return new FakeShadowRoot() }
}
globalThis.ResizeObserver = class { observe() {} }
globalThis.CSSStyleSheet = class { replaceSync() {} }
globalThis.document = {
    createElement(name) { return name === 'iframe' ? new FakeIFrame() : new FakeElement() },
}
globalThis.customElements = { define() {} }

const { FixedLayout } = await import('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/fixed-layout.js')

test('fixed layout reports the selected page when relocating within an existing spread', async () => {
    const sections = [
        { linear: 'yes', load: async () => null },
        { linear: 'yes', load: async () => null },
    ]
    const layout = new FixedLayout()
    const relocations = []
    layout.addEventListener('relocate', event => relocations.push(event.detail))
    layout.open({ dir: 'ltr', rendition: {}, sections })

    await layout.goTo({ index: 0 })
    assert.equal(layout.index, 0)
    assert.equal(relocations.length, 1)

    await layout.goTo({ index: 1 })

    assert.equal(layout.index, 1)
    assert.equal(layout.currentIndex, 1)
    assert.equal(layout.getContents().find(content => content.index === 1)?.index, 1)
    assert.equal(layout.getContents().find(content => content.index === 0)?.element.style.display, 'none')
    assert.equal(layout.getContents().find(content => content.index === 1)?.element.style.display, 'block')
    assert.equal(relocations.at(-1)?.index, 1)
    assert.equal(relocations.length, 2)

    await layout.goTo({ index: 1 })
    assert.equal(relocations.length, 2)
})
