import assert from 'node:assert/strict'
import test from 'node:test'

const bubbleFocus = (target, type, relatedTarget) => {
    for (let node = target; node; node = node.parentNode) {
        const event = new Event(type)
        Object.defineProperties(event, {
            target: { value: target },
            relatedTarget: { value: relatedTarget },
        })
        node.dispatchEvent(event)
    }
}

class Element extends EventTarget {
    constructor(name) {
        super()
        this.localName = name
        this.children = []
        this.attributes = new Map()
        this.style = {}
        this.tabIndex = -1
    }
    append(...children) {
        for (const child of children) {
            child.parentNode = this
            this.children.push(child)
        }
    }
    prepend(child) {
        child.parentNode = this
        this.children.unshift(child)
    }
    replaceChildren(...children) {
        for (const child of this.children) child.parentNode = null
        this.children = []
        this.append(...children)
    }
    get firstElementChild() { return this.children[0] ?? null }
    get previousElementSibling() {
        const siblings = this.parentNode?.children ?? []
        return siblings[siblings.indexOf(this) - 1] ?? null
    }
    contains(target) {
        for (let node = target; node; node = node.parentNode)
            if (node === this) return true
        return false
    }
    get offsetParent() {
        if (!document.body.contains(this)) return null
        for (let node = this; node; node = node.parentNode) {
            if (node.attributes.has('hidden')) return null
            if (node.getAttribute('role') === 'group'
                && node.previousElementSibling?.getAttribute('aria-expanded') === 'false')
                return null
        }
        return document.body
    }
    setAttribute(name, value) { this.attributes.set(name, String(value)) }
    getAttribute(name) { return this.attributes.get(name) ?? null }
    removeAttribute(name) { this.attributes.delete(name) }
    scrollIntoView() {}
    click() { this.onclick?.(new Event('click', { cancelable: true })) }
    focus() {
        const previous = document.activeElement
        if (previous === this) return
        document.activeElement = this
        bubbleFocus(previous, 'focusout', this)
        bubbleFocus(this, 'focusin', previous)
    }
}

const descendants = element => element.children.flatMap(child => [child, ...descendants(child)])

globalThis.NodeFilter = { FILTER_ACCEPT: 1, FILTER_SKIP: 3 }
globalThis.document = {
    body: new Element('body'),
    createElement: name => new Element(name),
    createElementNS: (_namespace, name) => new Element(name),
    createTreeWalker: (root, _whatToShow, { acceptNode }) => ({
        currentNode: root,
        nextNode() {
            const all = descendants(root)
            const next = all.slice(all.indexOf(this.currentNode) + 1)
                .find(node => acceptNode(node) === NodeFilter.FILTER_ACCEPT)
            if (next) this.currentNode = next
            return next ?? null
        },
        previousNode() {
            const all = descendants(root)
            const previous = all.slice(0, all.indexOf(this.currentNode)).reverse()
                .find(node => acceptNode(node) === NodeFilter.FILTER_ACCEPT)
            if (previous) this.currentNode = previous
            return previous ?? null
        },
    }),
}
document.activeElement = document.body
const { createTOCView } = await import('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ui/tree.js')

const mountTOC = (items, onclick = () => {}) => {
    document.activeElement = document.body
    const toc = createTOCView(items, onclick)
    document.body.replaceChildren(toc.element)
    return toc
}
const rows = toc => descendants(toc.element).filter(item => item.getAttribute('role') === 'treeitem')
const tabStops = toc => rows(toc).filter(item => item.tabIndex === 0)
const currentRows = toc => rows(toc).filter(item => item.getAttribute('aria-current') === 'page')
const press = (item, key) => {
    const event = new Event('keydown', { cancelable: true })
    Object.defineProperty(event, 'key', { value: key })
    item.dispatchEvent(event)
    assert.equal(event.defaultPrevented, true)
}
const nestedTOC = () => mountTOC([
    { label: 'Part One', subitems: [
        { href: 'one.xhtml', label: 'One' },
        { label: 'Part Two', subitems: [{ href: 'two.xhtml', label: 'Two' }] },
    ] },
    { href: 'three.xhtml', label: 'Three' },
])

test('an empty TOC can receive repeated current-location updates', () => {
    const toc = mountTOC([], () => assert.fail('Empty TOC navigated'))
    for (const href of ['chapter.xhtml', null, undefined, 'another.xhtml']) {
        assert.doesNotThrow(() => toc.setCurrentHref(href))
        assert.equal(toc.element.children.length, 0)
        assert.deepEqual(tabStops(toc), [])
    }
})

test('a nonempty TOC starts with one keyboard entry point before any location update', () => {
    const toc = nestedTOC()
    assert.deepEqual(tabStops(toc), [rows(toc)[0]])
    assert.deepEqual(currentRows(toc), [])
})

test('a nonempty TOC keeps current-item and missing-target focus behavior', () => {
    const toc = mountTOC([{ href: 'one.xhtml', label: 'One' }])
    const [item] = rows(toc)
    toc.setCurrentHref('one.xhtml')
    assert.deepEqual(currentRows(toc), [item])
    assert.deepEqual(tabStops(toc), [item])
    toc.setCurrentHref('missing.xhtml')
    assert.deepEqual(currentRows(toc), [])
    assert.deepEqual(tabStops(toc), [item])
})

test('the current chapter expands its ancestors and becomes the only tab stop', () => {
    const toc = nestedTOC()
    const [partOne, , partTwo, two] = rows(toc)
    toc.setCurrentHref('two.xhtml')
    assert.equal(partOne.getAttribute('aria-expanded'), 'true')
    assert.equal(partTwo.getAttribute('aria-expanded'), 'true')
    assert.deepEqual(currentRows(toc), [two])
    assert.deepEqual(tabStops(toc), [two])
    assert.equal(document.activeElement, document.body)
})

test('collapsing a branch without focusout moves the tab stop to its visible ancestor', () => {
    const toc = nestedTOC()
    const [partOne, , partTwo, two] = rows(toc)
    toc.setCurrentHref('two.xhtml')
    partTwo.firstElementChild.click()
    assert.equal(two.offsetParent, null)
    assert.deepEqual(tabStops(toc), [partTwo])
    partOne.firstElementChild.click()
    assert.deepEqual(tabStops(toc), [partOne])
    assert.deepEqual(currentRows(toc), [two])
})

test('collapsing a focused descendant returns focus to its visible ancestor', () => {
    const toc = nestedTOC()
    const [partOne, , partTwo, two] = rows(toc)
    toc.setCurrentHref('two.xhtml')
    two.focus()
    partTwo.firstElementChild.click()
    assert.equal(document.activeElement, partTwo)
    assert.deepEqual(tabStops(toc), [partTwo])
    partOne.firstElementChild.click()
    assert.equal(document.activeElement, partOne)
    assert.deepEqual(tabStops(toc), [partOne])
    assert.deepEqual(currentRows(toc), [two])
})

test('reselecting a chapter clears a previous collapsed-parent tab stop', () => {
    const toc = nestedTOC()
    const [partOne, , , two, three] = rows(toc)
    toc.setCurrentHref('two.xhtml')
    partOne.firstElementChild.click()
    toc.setCurrentHref('two.xhtml')
    assert.deepEqual(tabStops(toc), [two])
    partOne.firstElementChild.click()
    toc.setCurrentHref('three.xhtml')
    assert.deepEqual(tabStops(toc), [three])
    assert.deepEqual(currentRows(toc), [three])
})

test('keyboard focus moves the tab stop without changing the reading chapter', () => {
    const toc = nestedTOC()
    const [, one, partTwo, two] = rows(toc)
    toc.setCurrentHref('two.xhtml')
    two.focus()
    press(two, 'ArrowUp')
    assert.equal(document.activeElement, partTwo)
    assert.deepEqual(tabStops(toc), [partTwo])
    press(partTwo, 'ArrowUp')
    assert.equal(document.activeElement, one)
    assert.deepEqual(tabStops(toc), [one])
    assert.deepEqual(currentRows(toc), [two])
    document.body.focus()
    assert.deepEqual(tabStops(toc), [two])
})

test('keyboard collapse and expansion preserve the focused row as the single tab stop', () => {
    const toc = nestedTOC()
    const [partOne, , , two] = rows(toc)
    toc.setCurrentHref('two.xhtml')
    partOne.focus()
    press(partOne, 'ArrowLeft')
    assert.equal(partOne.getAttribute('aria-expanded'), 'false')
    assert.deepEqual(tabStops(toc), [partOne])
    assert.deepEqual(currentRows(toc), [two])
    press(partOne, 'ArrowRight')
    assert.equal(partOne.getAttribute('aria-expanded'), 'true')
    assert.deepEqual(tabStops(toc), [partOne])
    document.body.focus()
    assert.deepEqual(tabStops(toc), [two])
})

test('location updates preserve keyboard focus while updating the current chapter', () => {
    const toc = nestedTOC()
    const [, one, , , three] = rows(toc)
    toc.setCurrentHref('one.xhtml')
    one.focus()
    toc.setCurrentHref('three.xhtml')
    assert.equal(document.activeElement, one)
    assert.deepEqual(tabStops(toc), [one])
    assert.deepEqual(currentRows(toc), [three])
    document.body.focus()
    assert.deepEqual(tabStops(toc), [three])
})

test('hidden and unmatched locations retain a first-row entry point without a stale marker', () => {
    const toc = nestedTOC()
    const [first, , , two] = rows(toc)
    toc.setCurrentHref('two.xhtml')
    toc.element.setAttribute('hidden', '')
    toc.setCurrentHref('two.xhtml')
    assert.deepEqual(tabStops(toc), [first])
    assert.deepEqual(currentRows(toc), [two])
    toc.element.removeAttribute('hidden')
    toc.setCurrentHref('two.xhtml')
    assert.deepEqual(tabStops(toc), [two])
    for (const href of ['missing.xhtml', null, undefined]) {
        toc.setCurrentHref(href)
        assert.deepEqual(tabStops(toc), [first])
        assert.deepEqual(currentRows(toc), [])
    }
})

test('keyboard activation still navigates through the original callback', () => {
    const navigations = []
    const toc = mountTOC([{ href: 'one.xhtml', label: 'One' }], href => navigations.push(href))
    const [one] = rows(toc)
    one.focus()
    press(one, 'Enter')
    press(one, ' ')
    assert.deepEqual(navigations, ['one.xhtml', 'one.xhtml'])
})
