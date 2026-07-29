import test from 'node:test'
import assert from 'node:assert/strict'

import {
    applyReaderPresentationStateToDocument,
    installReaderPresentationState,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-reader-presentation.js'

const makeStyle = () => {
    const values = new Map()
    return {
        setProperty: (key, value) => values.set(key, value),
        removeProperty: key => values.delete(key),
        getPropertyValue: key => values.get(key) ?? '',
    }
}

const makeDocument = () => ({
    documentElement: { style: makeStyle() },
    body: {
        dataset: {},
        style: makeStyle(),
    },
})

test('installs initial presentation before applying it to an ebook child', () => {
    const globalObject = {}
    const outerDocument = makeDocument()
    const childDocument = makeDocument()
    const settings = {
        colorScheme: 'dark',
        lightModeTheme: 'white',
        darkModeTheme: 'black',
        readerFontSize: 23,
        readerContentRTSize: 10.58,
        readerBoldText: true,
        maxWidthOverride: '48rem',
        writingDirection: 'vertical',
    }

    const normalized = installReaderPresentationState(
        globalObject,
        outerDocument,
        settings,
        'loadEBook',
    )
    assert.equal(
        applyReaderPresentationStateToDocument(childDocument, normalized, 'document-load'),
        true,
    )
    assert.equal(globalObject.manabiEbookViewerWritingDirection, 'vertical')
    assert.equal(childDocument.body.dataset.mnbColorScheme, 'dark')
    assert.equal(childDocument.body.style.getPropertyValue('font-size'), '23px')
    assert.equal(childDocument.body.style.getPropertyValue('font-weight'), '600')
    assert.equal(
        childDocument.body.style.getPropertyValue('--mnb-reader-max-width-override'),
        '48rem',
    )
})

test('normalizes invalid values and makes repeated child application a no-op', () => {
    const document = makeDocument()
    const settings = {
        readerFontSize: -1,
        readerContentRTSize: Number.NaN,
        readerBoldText: false,
        writingDirection: 'sideways',
    }

    assert.equal(applyReaderPresentationStateToDocument(document, settings, 'first'), true)
    assert.equal(applyReaderPresentationStateToDocument(document, settings, 'second'), false)
    assert.equal(document.body.style.getPropertyValue('font-size'), '')
    assert.equal(document.body.style.getPropertyValue('font-weight'), '')
})
