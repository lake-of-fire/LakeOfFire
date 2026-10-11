import assert from 'node:assert/strict'
import test from 'node:test'

import { copyCustomReaderFontStyleToDocument } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-font-forwarding.js'

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
