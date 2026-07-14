import assert from 'node:assert/strict'
import test from 'node:test'

import { copyCustomReaderFontStyleToDocument } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-font-forwarding.js'

const families = {
    manabiHorizontalFontFamilyName: 'YuKyokasho Yoko',
    manabiVerticalFontFamilyName: 'YuKyokasho',
}

const makeElement = tagName => ({
    tagName: tagName.toUpperCase(),
    dataset: {},
    textContent: '',
    rel: '',
    href: '',
    remove() {},
})

const makeDocument = direction => {
    const elements = new Map()
    const documentElement = makeElement('html')
    const head = {
        appendChild(element) {
            elements.set(element.id, element)
        },
    }
    return {
        body: {
            dataset: direction ? { mnbWritingDirection: direction } : {},
            classList: { contains: () => false },
        },
        documentElement,
        head,
        getElementById: id => elements.get(id) || null,
        createElement: makeElement,
    }
}

const sourceFontStyle = () => ({
    tagName: 'LINK',
    rel: 'stylesheet',
    href: 'ebook://ebook/load/manabi-fonts.css?family=YuKyokasho',
    dataset: { mnbInjectedFontFamily: 'Fallback Family', assetRevision: '7' },
})

test('selects vertical and horizontal families while retaining one stylesheet URL', () => {
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

test('uses horizontal family when direction metadata is absent', () => {
    const document = makeDocument(null)

    copyCustomReaderFontStyleToDocument(sourceFontStyle(), document, 'test', families)

    assert.equal(document.documentElement.dataset.mnbInjectedFontFamily, 'YuKyokasho Yoko')
})

test('repeated forwarding is a no-op and direction changes update only family metadata', () => {
    const document = makeDocument('horizontal')
    const source = sourceFontStyle()

    assert.equal(copyCustomReaderFontStyleToDocument(source, document, 'test', families), true)
    assert.equal(copyCustomReaderFontStyleToDocument(source, document, 'test', families), false)
    const originalHref = document.getElementById('mnb-custom-fonts-inline').href

    document.body.dataset.mnbWritingDirection = 'vertical'
    assert.equal(copyCustomReaderFontStyleToDocument(source, document, 'test', families), true)
    assert.equal(document.documentElement.dataset.mnbInjectedFontFamily, 'YuKyokasho')
    assert.equal(document.getElementById('mnb-custom-fonts-inline').href, originalHref)
})
