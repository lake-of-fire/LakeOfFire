import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import { fileURLToPath } from 'node:url'

const filename = fileURLToPath(new URL(
    '../../Sources/LakeOfFireReader/Resources/Resources/reader-frame-replacement-guard.js', import.meta.url))
const source = fs.readFileSync(filename, 'utf8')
const attribute = 'data-reader-frame-replacement-token'

function element() {
    const attributes = new Map()
    return {
        getAttribute: name => attributes.get(name) ?? null,
        setAttribute: (name, value) => attributes.set(name, String(value)),
        removeAttribute: name => attributes.delete(name),
    }
}
function document() {
    return {
        documentElement: element(),
        location: { href: 'https://reader.test/chapter' },
        manabiDocumentStartedAtMs: 100,
    }
}
function world(doc) {
    const context = vm.createContext({ document: doc, performance: { timeOrigin: 100 } })
    const guard = vm.runInContext(source, context, { filename })
    return { context, guard }
}

// Execute the complete shipping helper in two contexts sharing a minimal DOM
// attribute collaborator. Document/root replacements are explicit inputs;
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
