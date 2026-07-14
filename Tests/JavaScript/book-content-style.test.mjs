import assert from 'node:assert/strict'
import test from 'node:test'

import {
    BOOK_CONTENT_STYLE_ID,
    installBookContentStyles,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/book-content-style.js'

const makeDocument = () => {
    const elements = new Map()
    let prependCount = 0
    const head = {
        prepend(element) {
            prependCount += 1
            elements.set(element.id, element)
        },
    }
    return {
        head,
        createElement: localName => ({ id: '', localName, textContent: '', remove() {} }),
        getElementById: id => elements.get(id) || null,
        get prependCount() { return prependCount },
    }
}

test('installs one identified style and reuses the same in-flight installation', async () => {
    const document = makeDocument()
    let resolveStyles
    const stylesPromise = new Promise(resolve => { resolveStyles = resolve })

    const first = installBookContentStyles(document, stylesPromise)
    const repeated = installBookContentStyles(document, stylesPromise)
    resolveStyles('mnb-sen { display: contents; }')

    assert.equal(await first, true)
    assert.equal(await repeated, true)
    assert.equal(document.prependCount, 1)
    assert.equal(document.getElementById(BOOK_CONTENT_STYLE_ID).textContent, 'mnb-sen { display: contents; }')
})

test('updates the existing style for a new resource revision without inserting another element', async () => {
    const document = makeDocument()

    assert.equal(await installBookContentStyles(document, Promise.resolve('first')), true)
    assert.equal(await installBookContentStyles(document, Promise.resolve('second')), true)
    assert.equal(document.prependCount, 1)
    assert.equal(document.getElementById(BOOK_CONTENT_STYLE_ID).textContent, 'second')
})

test('a stale resource revision cannot overwrite a newer installation', async () => {
    const document = makeDocument()
    let resolveStaleStyles
    const stalePromise = new Promise(resolve => { resolveStaleStyles = resolve })
    const staleInstallation = installBookContentStyles(document, stalePromise)

    assert.equal(await installBookContentStyles(document, Promise.resolve('current')), true)
    resolveStaleStyles('stale')

    assert.equal(await staleInstallation, false)
    assert.equal(document.prependCount, 1)
    assert.equal(document.getElementById(BOOK_CONTENT_STYLE_ID).textContent, 'current')
})

test('does not install into documents without a head', async () => {
    assert.equal(await installBookContentStyles({}, Promise.resolve('styles')), false)
})
