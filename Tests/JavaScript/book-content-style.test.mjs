import assert from 'node:assert/strict'
import test from 'node:test'

import {
    BOOK_CONTENT_STYLE_ID,
    installBookContentStyles,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-content-style.js'

const makeDocument = () => {
    const elements = new Map()
    let prependCount = 0
    return {
        head: {
            prepend(element) {
                prependCount += 1
                elements.set(element.id, element)
            },
        },
        createElement: localName => ({ id: '', localName, textContent: '', remove() {} }),
        getElementById: id => elements.get(id) || null,
        get prependCount() { return prependCount },
    }
}

test('reuses an in-flight style installation', async () => {
    const installations = new WeakMap()
    const document = makeDocument()
    let resolveStyles
    const stylesPromise = new Promise(resolve => { resolveStyles = resolve })

    const first = installBookContentStyles(installations, document, stylesPromise)
    const repeated = installBookContentStyles(installations, document, stylesPromise)
    resolveStyles('m-m { display: contents; }')

    assert.equal(await first, true)
    assert.equal(await repeated, true)
    assert.equal(document.prependCount, 1)
    assert.equal(document.getElementById(BOOK_CONTENT_STYLE_ID).textContent, 'm-m { display: contents; }')
})

test('a stale style revision cannot overwrite the current installation', async () => {
    const installations = new WeakMap()
    const document = makeDocument()
    let resolveStaleStyles
    const staleStyles = new Promise(resolve => { resolveStaleStyles = resolve })
    const staleInstallation = installBookContentStyles(installations, document, staleStyles)

    assert.equal(await installBookContentStyles(installations, document, Promise.resolve('current')), true)
    resolveStaleStyles('stale')

    assert.equal(await staleInstallation, false)
    assert.equal(document.prependCount, 1)
    assert.equal(document.getElementById(BOOK_CONTENT_STYLE_ID).textContent, 'current')
})
