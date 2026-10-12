import assert from 'node:assert/strict'
import test from 'node:test'
import { readerDocumentStartedAtMs } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/reader-document-clock.js'

const owner = (initial) => {
    let origin = initial
    let reads = 0
    const view = {
        document: {},
        performance: { get timeOrigin() { reads++; return origin } },
    }
    return { view, setOrigin: value => { origin = value }, reads: () => reads }
}

const establishCoreStamp = (doc, value) => {
    // The public immutable Document contract established by Core bootstrap.
    Object.defineProperty(doc, 'manabiDocumentStartedAtMs', { value })
}

test('standalone Lake samples once and emits the exact captured value after drift', () => {
    const f = owner(944)
    assert.equal(readerDocumentStartedAtMs(f.view), 944)
    f.setOrigin(945)
    assert.equal(readerDocumentStartedAtMs(f.view), 944)
    assert.equal(f.reads(), 1)
    assert.equal(Reflect.set(f.view.document, 'manabiDocumentStartedAtMs', 945), false)
    assert.equal(Reflect.deleteProperty(f.view.document, 'manabiDocumentStartedAtMs'), false)
    assert.equal(readerDocumentStartedAtMs(f.view), 944)
})

test('a Core-established stamp is shared without touching the drifting getter', () => {
    const f = owner(945)
    establishCoreStamp(f.view.document, 944)
    assert.equal(readerDocumentStartedAtMs(f.view), 944)
    assert.equal(f.reads(), 0)
})

test('global, child and top owners retain independent document stamps', () => {
    const top = owner(100)
    const child = owner(200)
    child.view.top = top.view
    establishCoreStamp(top.view.document, 99)
    assert.equal(readerDocumentStartedAtMs(child.view), 200)
    assert.equal(readerDocumentStartedAtMs(child.view.top), 99)
    child.setOrigin(201)
    top.setOrigin(101)
    assert.equal(readerDocumentStartedAtMs(child.view), 200)
    assert.equal(readerDocumentStartedAtMs(child.view.top), 99)
    const saved = Object.getOwnPropertyDescriptor(globalThis, 'document')
    try {
        Object.defineProperty(globalThis, 'document', {
            configurable: true, value: top.view.document,
        })
        assert.equal(readerDocumentStartedAtMs(), 99)
    } finally {
        if (saved) Object.defineProperty(globalThis, 'document', saved)
        else Reflect.deleteProperty(globalThis, 'document')
    }
})

test('actual Document replacement at the same URL cannot reuse a window cache', () => {
    const f = owner(10)
    f.view.document.URL = 'ebook://book/chapter'
    assert.equal(readerDocumentStartedAtMs(f.view), 10)
    const predecessor = f.view.document
    f.view.manabiDocumentStartedAtMs = 10 // stale legacy window cache is ignored
    f.view.document = { URL: predecessor.URL }
    f.setOrigin(20)
    assert.equal(readerDocumentStartedAtMs(f.view), 20)
    f.setOrigin(21)
    assert.equal(readerDocumentStartedAtMs(f.view), 20)
    f.view.document = predecessor // restoring the actual Document retains identity
    assert.equal(readerDocumentStartedAtMs(f.view), 10)
    assert.equal(f.reads(), 2)
})

test('missing standalone origin stays null, with one sample per Document', () => {
    for (const value of [undefined, NaN, Infinity]) {
        const f = owner(value)
        assert.equal(readerDocumentStartedAtMs(f.view), null)
        f.setOrigin(30)
        assert.equal(readerDocumentStartedAtMs(f.view), null)
        assert.equal(f.reads(), 1)
        // Absence never blocks Core from installing its Date.now() fallback.
        establishCoreStamp(f.view.document, 40)
        assert.equal(readerDocumentStartedAtMs(f.view), 40)
        assert.equal(f.reads(), 1)
        f.view.document = {}
        assert.equal(readerDocumentStartedAtMs(f.view), 30)
        assert.equal(f.reads(), 2)
    }
    assert.equal(readerDocumentStartedAtMs({ document: {} }), null)
    assert.equal(readerDocumentStartedAtMs({}), null)
})

test('conflicting mutable document properties are rejected, never re-stamped', () => {
    const f = owner(2)
    f.view.document.manabiDocumentStartedAtMs = 1
    assert.throws(() => readerDocumentStartedAtMs(f.view), TypeError)
    assert.equal(f.view.document.manabiDocumentStartedAtMs, 1)
    assert.equal(f.reads(), 0)
})
