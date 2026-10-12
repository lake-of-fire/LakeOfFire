import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import { fileURLToPath } from 'node:url'

const filename = fileURLToPath(new URL(
    '../../Sources/LakeOfFireReader/Resources/Resources/reader-frame-replacement-guard.js', import.meta.url))
const source = fs.readFileSync(filename, 'utf8')
const attribute = 'data-reader-frame-replacement-token'

class DOMEvent {
    constructor(type, { cancelable = false } = {}) {
        this.type = type
        this.cancelable = cancelable
        this.defaultPrevented = false
        this.target = null
        this.currentTarget = null
    }
    preventDefault() {
        if (this.cancelable) this.defaultPrevented = true
    }
}
function element(copiedAttributes = []) {
    const attributes = new Map(copiedAttributes)
    const listeners = new Map()
    const root = {
        getAttribute: name => attributes.get(name) ?? null,
        setAttribute: (name, value) => attributes.set(name, String(value)),
        removeAttribute: name => attributes.delete(name),
        cloneNode: () => element(attributes),
        addEventListener(type, callback) {
            if (!listeners.has(type)) listeners.set(type, new Set())
            listeners.get(type).add(callback)
        },
        removeEventListener(type, callback) {
            listeners.get(type)?.delete(callback)
        },
        dispatchEvent(event) {
            event.target = root
            event.currentTarget = root
            for (const callback of [...(listeners.get(event.type) ?? [])]) callback(event)
            event.currentTarget = null
            return !event.defaultPrevented
        },
        listenerCount: () => [...listeners.values()].reduce((count, callbacks) => count + callbacks.size, 0),
    }
    return root
}
function document() {
    return {
        documentElement: element(),
        location: { href: 'https://reader.test/chapter' },
        manabiDocumentStartedAtMs: 100,
        importNode: root => root.cloneNode(true),
    }
}
function world(doc) {
    const context = vm.createContext({ document: doc, Event: DOMEvent, performance: { timeOrigin: 100 } })
    const guard = vm.runInContext(source, context, { filename })
    return { context, guard }
}

// Execute the complete shipping helper in two contexts sharing a minimal DOM
// attribute/event collaborator. Document/root replacements are explicit inputs;
// this suite does not qualify WKWebView or cross-content-world dispatch.
test('the original Document permits one page-world consumption despite origin drift', () => {
    const doc = document(), producer = world(doc), page = world(doc)
    assert.equal(producer.guard.capture('render-a'), true)
    producer.context.performance.timeOrigin = 101
    page.context.performance.timeOrigin = 102
    assert.equal(page.guard.consume('render-a'), true)
    assert.equal(doc.documentElement.getAttribute(attribute), null)
    assert.equal(page.guard.consume('render-a'), false)
    assert.equal(producer.guard.discard('render-a'), false)
})

test('a successor Document cannot receive an earlier prepared render', () => {
    const original = document(), successor = document()
    const producer = world(original), page = world(successor)
    assert.equal(producer.guard.capture('render-a'), true)
    assert.equal(page.guard.consume('render-a'), false)
    assert.equal(page.guard.discard('render-a'), false)
    assert.equal(successor.documentElement.getAttribute(attribute), null)
    assert.equal(original.documentElement.getAttribute(attribute), 'render-a')
})

test('same-URL reload in a surviving window does not borrow the old DOM token or clock', () => {
    const original = document(), replacement = document(), page = world(original)
    assert.equal(page.guard.capture('render-a'), true)
    assert.equal(replacement.location.href, original.location.href)
    assert.equal(replacement.manabiDocumentStartedAtMs, original.manabiDocumentStartedAtMs)
    page.context.document = replacement
    assert.equal(page.guard.consume('render-a'), false)
    assert.equal(page.guard.discard('render-a'), false)
    assert.equal(replacement.documentElement.getAttribute(attribute), null)
})

test('replacing the root withdraws the prepared effect even within the same Document', () => {
    const doc = document(), page = world(doc), originalRoot = doc.documentElement
    assert.equal(page.guard.capture('render-a'), true)
    doc.documentElement = element()
    assert.equal(page.guard.consume('render-a'), false)
    assert.equal(page.guard.discard('render-a'), false)
    assert.equal(originalRoot.getAttribute(attribute), 'render-a')
    assert.equal(doc.documentElement.getAttribute(attribute), null)
})

for (const imported of [false, true]) {
    test(`${imported ? 'importing' : 'cloning'} the root cannot copy its prepared render permission`, () => {
        const doc = document(), producer = world(doc), page = world(doc)
        assert.equal(producer.guard.capture('render-a'), true)
        const originalRoot = doc.documentElement
        doc.documentElement = imported ? doc.importNode(originalRoot, true) : originalRoot.cloneNode(true)
        assert.notEqual(doc.documentElement, originalRoot)
        assert.equal(doc.documentElement.getAttribute(attribute), 'render-a')
        assert.equal(page.guard.consume('render-a'), false)
        assert.equal(producer.guard.discard('render-a'), false)
        assert.equal(producer.guard.capture('render-b'), true)
        assert.equal(page.guard.consume('render-b'), true)
    })
}

test('a distinct Document importing the original token cannot acknowledge its preparation', () => {
    const original = document(), successor = document()
    const producer = world(original), page = world(successor)
    assert.equal(producer.guard.capture('render-a'), true)
    successor.documentElement = successor.importNode(original.documentElement, true)
    assert.equal(successor.documentElement.getAttribute(attribute), 'render-a')
    assert.equal(page.guard.consume('render-a'), false)
    assert.equal(page.guard.discard('render-a'), false)
    assert.equal(producer.guard.consume('render-a'), true)
})

test('later preparation survives cleanup and consumption attempted by its predecessor', () => {
    const doc = document(), producer = world(doc), page = world(doc)
    assert.equal(producer.guard.capture('render-a'), true)
    assert.equal(producer.guard.capture('render-b'), true)
    assert.equal(producer.guard.discard('render-a'), false)
    assert.equal(page.guard.consume('render-a'), false)
    assert.equal(doc.documentElement.getAttribute(attribute), 'render-b')
    assert.equal(page.guard.consume('render-b'), true)
    assert.equal(doc.documentElement.getAttribute(attribute), null)
})

test('discarding the original preparation prevents its later effect and permits a fresh preparation', () => {
    const doc = document(), producer = world(doc), page = world(doc)
    assert.equal(producer.guard.capture('render-a'), true)
    assert.equal(producer.guard.discard('render-a'), true)
    assert.equal(page.guard.consume('render-a'), false)
    assert.equal(producer.guard.discard('render-a'), false)
    assert.equal(producer.guard.capture('render-b'), true)
    assert.equal(page.guard.consume('render-b'), true)
})

test('consumption and discard remove their physical-root listener pair', () => {
    const doc = document(), producer = world(doc), page = world(doc)
    for (const operation of ['consume', 'discard']) {
        assert.equal(producer.guard.capture(operation), true)
        assert.equal(doc.documentElement.listenerCount(), 2)
        assert.equal(page.guard[operation](operation), true)
        assert.equal(doc.documentElement.listenerCount(), 0)
    }
})

test('superseding capture releases predecessor listeners even if its attribute was changed', () => {
    const doc = document(), producer = world(doc), page = world(doc)
    assert.equal(producer.guard.capture('render-a'), true)
    doc.documentElement.setAttribute(attribute, 'page-edited-token')
    assert.equal(producer.guard.capture('render-b'), true)
    assert.equal(doc.documentElement.listenerCount(), 2)
    assert.equal(producer.guard.discard('render-a'), false)
    assert.equal(page.guard.consume('render-b'), true)
    assert.equal(doc.documentElement.listenerCount(), 0)
})

test('a mismatched request cannot consume the listener or withdraw a later matching request', () => {
    const doc = document(), producer = world(doc), page = world(doc)
    assert.equal(producer.guard.capture('render-a'), true)
    doc.documentElement.setAttribute(attribute, 'page-edited-token')
    const event = new DOMEvent('reader-frame-replacement-request:render-a', { cancelable: true })
    assert.equal(doc.documentElement.dispatchEvent(event), true)
    assert.equal(doc.documentElement.listenerCount(), 2)
    doc.documentElement.setAttribute(attribute, 'render-a')
    assert.equal(page.guard.consume('render-a'), true)
    assert.equal(doc.documentElement.listenerCount(), 0)
})

for (const replaceDocument of [false, true]) {
    test(`${replaceDocument ? 'Document' : 'root'} replacement after acknowledgment rejects the spent render`, () => {
        const doc = document(), producer = world(doc), page = world(doc)
        assert.equal(producer.guard.capture('render-a'), true)
        const capturedRoot = doc.documentElement
        const replacement = document()
        const afterAcknowledgment = event => {
            assert.equal(event.defaultPrevented, true)
            if (replaceDocument) page.context.document = replacement
            else doc.documentElement = replacement.documentElement
        }
        capturedRoot.addEventListener('reader-frame-replacement-request:render-a', afterAcknowledgment)
        assert.equal(page.guard.consume('render-a'), false)
        assert.equal(capturedRoot.getAttribute(attribute), null)
        assert.equal(capturedRoot.listenerCount(), 1)
        capturedRoot.removeEventListener('reader-frame-replacement-request:render-a', afterAcknowledgment)
        assert.equal(capturedRoot.listenerCount(), 0)
        assert.equal(page.guard.consume('render-a'), false)
        assert.equal(page.guard.capture('render-b'), true)
        assert.equal(page.guard.consume('render-b'), true)
    })
}

test('a newer same-root capture during acknowledgment withdraws the predecessor render', () => {
    const doc = document(), producer = world(doc), page = world(doc)
    assert.equal(producer.guard.capture('render-a'), true)
    const afterAcknowledgment = event => {
        assert.equal(event.defaultPrevented, true)
        assert.equal(producer.guard.capture('render-b'), true)
    }
    doc.documentElement.addEventListener('reader-frame-replacement-request:render-a', afterAcknowledgment)
    assert.equal(page.guard.consume('render-a'), false)
    assert.equal(doc.documentElement.getAttribute(attribute), 'render-b')
    doc.documentElement.removeEventListener('reader-frame-replacement-request:render-a', afterAcknowledgment)
    assert.equal(doc.documentElement.listenerCount(), 2)
    assert.equal(producer.guard.discard('render-a'), false)
    assert.equal(page.guard.consume('render-b'), true)
    assert.equal(doc.documentElement.listenerCount(), 0)
})

test('same-URL sibling Documents cannot consume or discard each other\'s token', () => {
    const left = document(), right = document()
    const leftWorld = world(left), rightWorld = world(right)
    assert.equal(leftWorld.guard.capture('left-render'), true)
    assert.equal(rightWorld.guard.capture('right-render'), true)
    assert.equal(rightWorld.guard.consume('left-render'), false)
    assert.equal(leftWorld.guard.discard('right-render'), false)
    assert.equal(left.documentElement.getAttribute(attribute), 'left-render')
    assert.equal(right.documentElement.getAttribute(attribute), 'right-render')
    assert.equal(leftWorld.guard.consume('left-render'), true)
    assert.equal(rightWorld.guard.consume('right-render'), true)
})

for (const operation of ['capture', 'consume', 'discard']) {
    test(`${operation} requires a root and a nonempty string token`, () => {
        const doc = document(), { guard } = world(doc)
        for (const token of [undefined, null, '', 1, {}]) {
            assert.equal(guard[operation](token), false)
            assert.equal(doc.documentElement.getAttribute(attribute), null)
        }
        doc.documentElement = null
        assert.equal(guard[operation]('render-a'), false)
    })
}
