import assert from 'node:assert/strict'
import test from 'node:test'

import {
    copyCustomReaderFontStyleToDocument,
    forwardCustomReaderFontStyleToDocuments,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-font-forwarding.js'

const families = {
    manabiHorizontalFontFamilyName: 'YuKyokasho Yoko',
    manabiVerticalFontFamilyName: 'YuKyokasho',
}
const makeStyle = () => {
    const values = new Map()
    return {
        getPropertyValue: name => values.get(name) || '',
        setProperty: (name, value) => values.set(name, value),
    }
}
const makeElement = tagName => {
    const listeners = new Map()
    return {
        tagName: tagName.toUpperCase(), dataset: {}, style: makeStyle(), textContent: '', rel: '', href: '', remove() {},
        addEventListener(type, callback, options) {
            const callbacks = listeners.get(type) || []
            callbacks.push({ callback, once: options?.once })
            listeners.set(type, callbacks)
        },
        removeEventListener(type, callback) {
            listeners.set(type, (listeners.get(type) || []).filter(entry => entry.callback !== callback))
        },
        dispatchEvent(event) {
            const callbacks = listeners.get(event.type) || []
            listeners.set(event.type, callbacks.filter(entry => !entry.once))
            for (const entry of callbacks) entry.callback(event)
        },
    }
}
const makeDocument = direction => {
    const elements = new Map()
    const documentElement = makeElement('html')
    return {
        body: {
            style: makeStyle(),
            dataset: direction ? { mnbWritingDirection: direction } : {},
            classList: { contains: () => false },
        },
        documentElement,
        head: { appendChild: element => elements.set(element.id, element) },
        getElementById: id => elements.get(id) || null,
        createElement: makeElement,
    }
}
const sourceFontStyle = () => ({
    tagName: 'LINK',
    rel: 'stylesheet',
    href: 'internal://local/manabi-fonts.css?family=YuKyokasho',
    dataset: { mnbInjectedFontFamily: 'Fallback Family', assetRevision: '7' },
})

const deferred = () => {
    let resolve, reject
    const promise = new Promise((success, failure) => { resolve = success; reject = failure })
    return { promise, resolve, reject }
}

// Use the production viewer forwarding entry point and its existing invalidation
// binding. DOM and the owner's snapshot storage are doubles; forwarding, readiness,
// and owner admission run in the imported production module.
const viewerFixture = () => {
    const doc = makeDocument('horizontal')
    doc.documentElement.isConnected = true
    doc.defaultView = {
        document: doc,
        frameElement: { isConnected: true },
        Event: class { constructor(type) { this.type = type } },
        dispatchEvent: () => {},
    }
    const initialReady = deferred()
    doc.fonts = { ready: initialReady.promise }
    let contents = [{ doc, index: 0 }]
    const renderer = { getContents: () => contents, displayedIndex: 0, currentIndex: 0 }
    const reader = {
        view: { renderer }, isClosed: false,
        visiblePageSegmentSnapshot: null,
        visiblePageCollectionGeneration: 0,
    }
    const viewer = {
        ...families, reader,
        manabiInvalidateVisiblePageSegmentSnapshot: reason => {
            assert.equal(reason, 'font-family-change-child')
            reader.visiblePageCollectionGeneration++
            reader.visiblePageSegmentSnapshot = null
        },
    }
    const source = sourceFontStyle()
    return {
        doc, reader, renderer, viewer, source, initialReady,
        forward: () => forwardCustomReaderFontStyleToDocuments(source, [doc], 'downloaded', viewer),
        mount: docs => { contents = docs.map((doc, index) => ({ doc, index })) },
        rebuild: () => {
            const snapshot = { doc, generation: reader.visiblePageCollectionGeneration }
            reader.visiblePageSegmentSnapshot = snapshot
            return snapshot
        },
    }
}

test('viewer forwarding invalidates snapshots rebuilt before delayed stylesheet and font readiness', async () => {
    const f = viewerFixture()
    assert.equal(f.forward(), 1)
    const beforeLoad = f.rebuild()
    const loadedReady = deferred()
    f.doc.fonts.ready = loadedReady.promise
    f.doc.getElementById('mnb-custom-fonts-inline').dispatchEvent({ type: 'load' })
    assert.equal(f.reader.visiblePageSegmentSnapshot, null)
    assert.ok(f.reader.visiblePageCollectionGeneration > beforeLoad.generation)

    const beforeFonts = f.rebuild()
    loadedReady.resolve()
    await Promise.resolve()
    assert.equal(f.reader.visiblePageSegmentSnapshot, null)
    assert.ok(f.reader.visiblePageCollectionGeneration > beforeFonts.generation)
    assert.equal(f.forward(), 0, 'An unchanged forwarding call does not invalidate again')
})

test('superseded stylesheet readiness preserves the intermediate current viewer snapshot', async () => {
    const f = viewerFixture()
    f.forward()
    const oldStyle = f.doc.getElementById('mnb-custom-fonts-inline')
    const replacementReady = deferred()
    f.doc.fonts.ready = replacementReady.promise
    f.source.href += '&revision=2'
    f.forward()
    const currentSnapshot = f.rebuild()
    f.initialReady.resolve()
    await Promise.resolve()
    assert.equal(f.reader.visiblePageSegmentSnapshot, currentSnapshot)
    // The retained node has a new revision; its current load still reaches the owner.
    oldStyle.dispatchEvent({ type: 'load' })
    assert.equal(f.reader.visiblePageSegmentSnapshot, null)
    const beforeReady = f.rebuild()
    replacementReady.resolve()
    await Promise.resolve()
    assert.equal(f.reader.visiblePageSegmentSnapshot, null)
    assert.ok(f.reader.visiblePageCollectionGeneration > beforeReady.generation)
})

for (const boundary of ['unmounted', 'nonprimary', 'hidden', 'window-document', 'root', 'style', 'detached-frame', 'detached-root', 'renderer', 'reader', 'binding', 'unbound', 'closed', 'disposed']) {
    test(`late chapter readiness cannot invalidate a replacement snapshot after ${boundary}`, async () => {
        const f = viewerFixture()
        f.forward()
        const style = f.doc.getElementById('mnb-custom-fonts-inline')
        const replacement = makeDocument('vertical')
        const replacementReader = {
            view: { renderer: { getContents: () => [{ doc: replacement }] } },
            isClosed: false,
            visiblePageSegmentSnapshot: { doc: replacement },
        }
        let replacementInvalidations = 0
        const replacementBinding = () => {
            replacementInvalidations++
            replacementReader.visiblePageSegmentSnapshot = null
        }
        if (boundary === 'unmounted') f.mount([replacement])
        if (boundary === 'nonprimary') {
            f.mount([f.doc, replacement])
            f.renderer.displayedIndex = 1
        }
        if (boundary === 'hidden') f.renderer.getContents = () => [{ doc: f.doc, index: 0, isDisplayed: false }]
        if (boundary === 'window-document') f.doc.defaultView.document = replacement
        if (boundary === 'root') f.doc.documentElement = makeElement('html')
        if (boundary === 'style') f.doc.head.appendChild({ ...makeElement('link'), id: style.id, href: style.href })
        if (boundary === 'detached-frame') f.doc.defaultView.frameElement.isConnected = false
        if (boundary === 'detached-root') f.doc.documentElement.isConnected = false
        if (boundary === 'renderer') f.reader.view.renderer = replacementReader.view.renderer
        if (boundary === 'reader') f.viewer.reader = replacementReader
        if (boundary === 'binding') f.viewer.manabiInvalidateVisiblePageSegmentSnapshot = replacementBinding
        if (boundary === 'unbound') delete f.viewer.manabiInvalidateVisiblePageSegmentSnapshot
        if (boundary === 'closed') f.reader.isClosed = true
        if (boundary === 'disposed') {
            f.reader.isClosed = true
            f.viewer.reader = replacementReader
            f.viewer.manabiInvalidateVisiblePageSegmentSnapshot = replacementBinding
        }
        const snapshot = f.rebuild()
        const generation = f.reader.visiblePageCollectionGeneration
        style.dispatchEvent({ type: 'load' })
        f.initialReady.resolve()
        await Promise.resolve()
        assert.equal(f.reader.visiblePageSegmentSnapshot, snapshot)
        assert.equal(f.reader.visiblePageCollectionGeneration, generation)
        assert.equal(replacementInvalidations, 0)
        assert.notEqual(replacementReader.visiblePageSegmentSnapshot, null)
    })
}

test('chapter resize reentry cannot lend its pending callback to a replacement viewer', async () => {
    const f = viewerFixture()
    f.forward()
    const snapshot = f.rebuild()
    const generation = f.reader.visiblePageCollectionGeneration
    let successorInvalidations = 0
    f.doc.defaultView.dispatchEvent = () => {
        f.reader.isClosed = true
        f.viewer.manabiInvalidateVisiblePageSegmentSnapshot = () => { successorInvalidations++ }
    }
    f.initialReady.resolve()
    await Promise.resolve()
    assert.equal(f.reader.visiblePageSegmentSnapshot, snapshot)
    assert.equal(f.reader.visiblePageCollectionGeneration, generation)
    assert.equal(successorInvalidations, 0)
})

test('renderer membership reentry cannot invalidate a retired viewer', async () => {
    const f = viewerFixture()
    f.forward()
    const snapshot = f.rebuild()
    const generation = f.reader.visiblePageCollectionGeneration
    f.renderer.getContents = () => {
        f.reader.isClosed = true
        return [{ doc: f.doc, index: 0 }]
    }
    f.initialReady.resolve()
    await Promise.resolve()
    assert.equal(f.reader.visiblePageSegmentSnapshot, snapshot)
    assert.equal(f.reader.visiblePageCollectionGeneration, generation)
})

test('late readiness follows the displayed chapter while navigation is ahead of its commit', async () => {
    const f = viewerFixture()
    f.forward()
    f.mount([f.doc, makeDocument('vertical')])
    f.renderer.currentIndex = 1
    const snapshot = f.rebuild()
    f.initialReady.resolve()
    await Promise.resolve()
    assert.equal(f.reader.visiblePageSegmentSnapshot, null)
    assert.ok(f.reader.visiblePageCollectionGeneration > snapshot.generation)
})

test('rejected font readiness preserves the viewer snapshot rebuilt after forwarding', async () => {
    const f = viewerFixture()
    f.forward()
    const snapshot = f.rebuild()
    f.initialReady.reject(new Error('Font readiness unavailable'))
    await Promise.resolve()
    await Promise.resolve()
    assert.equal(f.reader.visiblePageSegmentSnapshot, snapshot)
})

test('late stylesheet and font readiness resize the current chapter without another forwarding call', () => {
    const doc = makeDocument('horizontal')
    let resizeCount = 0
    doc.defaultView = {
        document: doc,
        Event: class { constructor(type) { this.type = type } },
        dispatchEvent: event => { assert.equal(event.type, 'resize'); resizeCount++ },
    }
    const fontReadyCallbacks = []
    doc.fonts = { ready: { then: callback => {
        fontReadyCallbacks.push(callback)
        return { catch() {} }
    } } }
    const source = sourceFontStyle()
    assert.equal(copyCustomReaderFontStyleToDocument(source, doc, 'downloaded', families), true)
    assert.equal(resizeCount, 1)
    const style = doc.getElementById('mnb-custom-fonts-inline')
    style.dispatchEvent({ type: 'load' })
    assert.equal(resizeCount, 2)
    assert.equal(fontReadyCallbacks.length, 2)
    for (const callback of fontReadyCallbacks) callback()
    assert.equal(resizeCount, 4)
    style.dispatchEvent({ type: 'load' })
    assert.equal(resizeCount, 4)
    assert.equal(copyCustomReaderFontStyleToDocument(source, doc, 'repeat', families), false)
})

test('late readiness discards replaced stylesheet revisions and navigated chapter windows', () => {
    const doc = makeDocument('horizontal')
    let resizeCount = 0
    doc.defaultView = {
        document: doc,
        Event: class { constructor(type) { this.type = type } },
        dispatchEvent: () => { resizeCount++ },
    }
    const fontReadyCallbacks = []
    doc.fonts = { ready: { then: callback => {
        fontReadyCallbacks.push(callback)
        return { catch() {} }
    } } }
    const source = sourceFontStyle()
    copyCustomReaderFontStyleToDocument(source, doc, 'initial', families)
    source.href += '&revision=2'
    copyCustomReaderFontStyleToDocument(source, doc, 'replacement', families)
    assert.equal(resizeCount, 2)
    fontReadyCallbacks[0]()
    assert.equal(resizeCount, 2)
    doc.getElementById('mnb-custom-fonts-inline').dispatchEvent({ type: 'load' })
    assert.equal(resizeCount, 3)
    doc.defaultView.document = makeDocument('vertical')
    for (const callback of fontReadyCallbacks) callback()
    assert.equal(resizeCount, 3)
})

test('a later direction change with the same stylesheet replaces pending chapter readiness callbacks', () => {
    const doc = makeDocument('horizontal')
    let resizeCount = 0
    doc.defaultView = {
        document: doc,
        Event: class { constructor(type) { this.type = type } },
        dispatchEvent: () => { resizeCount++ },
    }
    const fontReadyCallbacks = []
    doc.fonts = { ready: { then: callback => {
        fontReadyCallbacks.push(callback)
        return { catch() {} }
    } } }
    const source = sourceFontStyle()
    copyCustomReaderFontStyleToDocument(source, doc, 'initial', families)
    doc.body.dataset.mnbWritingDirection = 'vertical'
    copyCustomReaderFontStyleToDocument(source, doc, 'direction', families)
    assert.equal(resizeCount, 2)
    fontReadyCallbacks[0]()
    assert.equal(resizeCount, 2)
    doc.getElementById('mnb-custom-fonts-inline').dispatchEvent({ type: 'load' })
    assert.equal(resizeCount, 3)
    assert.equal(fontReadyCallbacks.length, 3)
    fontReadyCallbacks[1]()
    fontReadyCallbacks[2]()
    assert.equal(resizeCount, 5)
})

test('replacing a linked stylesheet with an empty inline style still refreshes geometry', () => {
    const doc = makeDocument('horizontal')
    let resizeCount = 0
    doc.defaultView = {
        Event: class { constructor(type) { this.type = type } },
        dispatchEvent: () => { resizeCount++ },
    }
    copyCustomReaderFontStyleToDocument(sourceFontStyle(), doc, 'initial', {})
    const inlineStyle = { tagName: 'STYLE', textContent: '', dataset: {} }
    assert.equal(copyCustomReaderFontStyleToDocument(inlineStyle, doc, 'inline', {}), true)
    assert.equal(doc.getElementById('mnb-custom-fonts-inline').tagName, 'STYLE')
    assert.equal(resizeCount, 2)
    assert.equal(copyCustomReaderFontStyleToDocument(inlineStyle, doc, 'repeat', {}), false)
})

test('selects directional families while retaining one stylesheet URL', () => {
    const verticalDocument = makeDocument('vertical')
    const horizontalDocument = makeDocument('horizontal')

    assert.equal(copyCustomReaderFontStyleToDocument(sourceFontStyle(), verticalDocument, 'test', families), true)
    assert.equal(copyCustomReaderFontStyleToDocument(sourceFontStyle(), horizontalDocument, 'test', families), true)
    assert.equal(verticalDocument.documentElement.dataset.mnbInjectedFontFamily, 'YuKyokasho')
    assert.equal(horizontalDocument.documentElement.dataset.mnbInjectedFontFamily, 'YuKyokasho Yoko')
    assert.equal(
        verticalDocument.getElementById('mnb-custom-fonts-inline').href,
        horizontalDocument.getElementById('mnb-custom-fonts-inline').href,
    )
})

test('repeated forwarding is a no-op and direction changes only update metadata', () => {
    const document = makeDocument('horizontal')
    const source = sourceFontStyle()
    assert.equal(copyCustomReaderFontStyleToDocument(source, document, 'test', families), true)
    assert.equal(copyCustomReaderFontStyleToDocument(source, document, 'test', families), false)
    const href = document.getElementById('mnb-custom-fonts-inline').href

    document.body.dataset.mnbWritingDirection = 'vertical'
    assert.equal(copyCustomReaderFontStyleToDocument(source, document, 'test', families), true)
    assert.equal(document.documentElement.dataset.mnbInjectedFontFamily, 'YuKyokasho')
    assert.equal(document.getElementById('mnb-custom-fonts-inline').href, href)
})


test('download completion carries resolved faces and new stylesheet revision to every child without reloading', () => {
    const source = sourceFontStyle()
    source.dataset.mnbHorizontalFontCSSValue = 'system-ui'
    source.dataset.mnbVerticalFontCSSValue = 'system-ui'
    const docs = [makeDocument('horizontal'), makeDocument('vertical')]
    let resizeCount = 0
    for (const doc of docs) {
        doc.defaultView = {
            Event: class { constructor(type) { this.type = type } },
            dispatchEvent: event => { assert.equal(event.type, 'resize'); resizeCount++ },
        }
        assert.equal(copyCustomReaderFontStyleToDocument(source, doc, 'initial', families), true)
        assert.equal(doc.body.style.getPropertyValue('--mnb-content-font'), 'system-ui')
    }
    source.href += '&revision=1'
    source.dataset.mnbHorizontalFontCSSValue = "'YuKyo-Medium', system-ui"
    source.dataset.mnbVerticalFontCSSValue = "'YuKyo_Yoko-Medium', system-ui"
    for (const doc of docs) {
        assert.equal(copyCustomReaderFontStyleToDocument(source, doc, 'downloaded', families), true)
        assert.equal(doc.getElementById('mnb-custom-fonts-inline').href, source.href)
        assert.equal(doc.documentElement.style.getPropertyValue('--mnb-content-font'), "'YuKyo-Medium', system-ui")
        assert.equal(doc.body.style.getPropertyValue('--mnb-content-vertical-font'), "'YuKyo_Yoko-Medium', system-ui")
        assert.equal(copyCustomReaderFontStyleToDocument(source, doc, 'repeat', families), false)
    }
    assert.equal(resizeCount, 4)
    const laterDoc = makeDocument('vertical')
    copyCustomReaderFontStyleToDocument(source, laterDoc, 'later-chapter', families)
    assert.equal(laterDoc.body.style.getPropertyValue('--mnb-content-vertical-font'), "'YuKyo_Yoko-Medium', system-ui")
    source.dataset.mnbHorizontalFontCSSValue = "'Hiragino Mincho ProN', system-ui"
    copyCustomReaderFontStyleToDocument(source, docs[0], 'explicit-selection', families)
    assert.equal(docs[0].body.style.getPropertyValue('--mnb-content-font'), "'Hiragino Mincho ProN', system-ui")
})
