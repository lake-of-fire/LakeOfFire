import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import test from 'node:test'

const require = createRequire(import.meta.url)
const { JSDOM, VirtualConsole } = require('jsdom')
const production = name => new URL('../../Sources/LakeOfFireReader/' + name, import.meta.url)
const swift = readFileSync(process.env.MANABI_DOC_STATE_SOURCE
    ?? production('Reader/ReaderDocStateUserScript.swift'), 'utf8')
const source = swift.split('let contents = """')[1]?.split('"""')[0]
if (!source) throw new Error('Missing production document-state script')
const viewer = readFileSync(production('Resources/foliate-js/ebook-viewer.js'), 'utf8')
const fontInjector = readFileSync(production('Reader/ReaderModeViewModel.swift'), 'utf8')
const block = (text, startMarker, endMarker, from = 0) => {
    const start = text.indexOf(startMarker, from)
    const end = text.indexOf(endMarker, start + startMarker.length)
    if (start < 0 || end < 0) throw new Error('Missing production declaration: ' + startMarker)
    return text.slice(start, end)
}
const renderer = block(viewer, 'const markReaderRenderReady =', 'const roundedDisplayPercent =')
const firstSetter = fontInjector.indexOf('const setFontPendingState =')
const fontSetters = {
    'local-scheme': block(fontInjector, 'const setFontPendingState =', 'const resolveStylesheetURL ='),
    blob: block(fontInjector, 'const setFontPendingState =', 'const replaceFontBlob =', firstSetter + 1),
}

const fixture = (t, {
    mode = 'local-scheme', ebook = true, bodyEbook = false, article = false,
    host = true, pending = true, visibility = 'visible', articleMarker = false,
} = {}) => {
    const errors = []
    const virtualConsole = new VirtualConsole()
    virtualConsole.on('jsdomError', error => errors.push(error.message))
    const dom = new JSDOM(
        '<!doctype html><html><head></head><body>'
        + (host ? '<foliate-view></foliate-view>' : '')
        + (article ? '<div id="reader-content"><p>Article</p></div>' : '')
        + '</body></html>',
        {
            url: ebook ? 'ebook://fixture/book/index.html' : 'https://example.invalid/article',
            runScripts: 'outside-only', pretendToBeVisual: true, virtualConsole,
        },
    )
    t.after(() => {
        dom.window.close()
        assert.deepEqual(errors, [], 'Production script must not throw during actual DOM delivery')
    })
    const { window } = dom
    const { document } = window
    const messages = []
    const diagnostics = []
    const snapshot = value => JSON.parse(JSON.stringify(value))
    window.webkit = { messageHandlers: {
        readerDocState: { postMessage: value => messages.push(snapshot(value)) },
        print: { postMessage: value => diagnostics.push(snapshot(value)) },
    } }
    window.postLog = () => {}
    document.documentElement.dataset.mnbReaderRenderGeneration = '12345678-1234-1234-1234-123456789abc'
    if (pending) document.documentElement.dataset.mnbFontPending = '1'
    if (bodyEbook) document.body.dataset.isEbook = 'true'
    if (articleMarker) document.documentElement.dataset.mnbReaderRenderReady = '1'
    document.body.style.visibility = visibility
    document.body.style.display = 'block'
    document.body.style.opacity = '1'
    window.eval(source)
    window.eval(renderer + '\nwindow.publishRendererReady = markReaderRenderReady')
    window.eval(fontSetters[mode] + '\nwindow.publishFontPending = setFontPendingState')
    const flush = () => new Promise(resolve => window.queueMicrotask(resolve))
    return { window, document, messages, diagnostics, flush }
}

for (const mode of Object.keys(fontSetters)) {
    test('real DOM ' + mode + ' font completion publishes ready and disconnects one-shot observation', async t => {
        const f = fixture(t, { mode })
        f.window.publishRendererReady('pending-font')
        assert.equal(f.messages.at(-1).hasReaderRenderReady, false)
        const before = f.messages.length
        f.window.publishFontPending(false)
        assert.equal(f.messages.length, before, 'Mutation delivery must be asynchronous')
        await f.flush()
        assert.equal(f.messages.length, before + 1)
        assert.equal(f.messages.at(-1).hasReaderContent, true)
        assert.equal(f.messages.at(-1).hasReaderRenderReady, true)
        assert.equal(f.messages.at(-1).reason, 'font-state')
        assert.equal(f.messages.at(-1).href, 'ebook://fixture/book/index.html')
        assert.equal(f.messages.at(-1).readerRenderGeneration, '12345678-1234-1234-1234-123456789abc')
        assert.equal(f.diagnostics.at(-1).state.hasReaderContent, true)
        assert.equal(f.diagnostics.at(-1).settings.readerRenderReady, '1')
        const settledCount = f.messages.length
        f.window.publishFontPending(true)
        f.window.publishFontPending(false)
        await f.flush()
        assert.equal(f.messages.length, settledCount)
    })
}

test('batched root gate clearance and reassertion cannot publish readiness between mutations', async t => {
    const f = fixture(t)
    f.window.publishRendererReady('pending-font')
    f.window.publishFontPending(false)
    f.window.publishFontPending(true)
    await f.flush()
    assert.equal(f.messages.at(-1).hasReaderRenderReady, false)
    assert.equal(f.messages.some(message => message.hasReaderRenderReady), false)
    f.window.publishFontPending(false)
    await f.flush()
    assert.equal(f.messages.at(-1).hasReaderRenderReady, true)
})

test('descendant font changes cannot clear the root gate or trigger EPUB state publication', async t => {
    const f = fixture(t)
    f.window.publishRendererReady('pending-root-font')
    const before = f.messages.length
    const child = f.document.createElement('div')
    f.document.body.append(child)
    child.dataset.mnbFontPending = '1'
    delete child.dataset.mnbFontPending
    f.document.body.dataset.mnbFontPending = '1'
    delete f.document.body.dataset.mnbFontPending
    await f.flush()
    assert.equal(f.messages.length, before)
    assert.equal(f.messages.at(-1).hasReaderRenderReady, false)
    f.window.publishFontPending(false)
    await f.flush()
    assert.equal(f.messages.at(-1).hasReaderRenderReady, true)
})

test('removed EPUB host cannot be admitted by later font completion and a new renderer may retry', async t => {
    const f = fixture(t)
    f.window.publishRendererReady('old-host')
    f.document.querySelector('foliate-view').remove()
    f.window.publishFontPending(false)
    await f.flush()
    assert.equal(f.messages.at(-1).hasReaderContent, false)
    assert.equal(f.messages.at(-1).hasReaderRenderReady, false)
    f.document.body.append(f.document.createElement('foliate-view'))
    f.window.publishRendererReady('replacement-host')
    assert.equal(f.messages.at(-1).hasReaderContent, true)
    assert.equal(f.messages.at(-1).hasReaderRenderReady, true)
    assert.equal(f.messages.at(-1).reason, 'renderReady.replacement-host')
})

test('actual computed hidden-body style rejects font completion and accepts an explicit visible retry', async t => {
    const f = fixture(t, { visibility: 'hidden' })
    f.window.publishRendererReady('hidden')
    f.window.publishFontPending(false)
    await f.flush()
    assert.equal(f.messages.at(-1).hasReaderRenderReady, false)
    f.document.body.style.visibility = 'visible'
    f.window.publishRendererReady('visible-retry')
    assert.equal(f.messages.at(-1).hasReaderRenderReady, true)
})

test('font completion before renderer settlement remains false until the actual renderer callback', async t => {
    const f = fixture(t)
    f.window.publishFontPending(false)
    await f.flush()
    assert.equal(f.messages.at(-1).hasReaderRenderReady, false)
    assert.equal(f.document.documentElement.dataset.manabiReaderRenderReady, undefined)
    f.window.publishRendererReady('after-font')
    assert.equal(f.messages.at(-1).hasReaderRenderReady, true)
})

test('real body EPUB namespace uses the EPUB marker while preserving the document href', async t => {
    const f = fixture(t, { ebook: false, bodyEbook: true })
    f.window.publishRendererReady('body-ebook')
    assert.equal(f.messages.at(-1).hasReaderRenderReady, false)
    f.window.publishFontPending(false)
    await f.flush()
    assert.equal(f.messages.at(-1).hasReaderRenderReady, true)
    assert.equal(f.messages.at(-1).href, 'https://example.invalid/article')
})

test('ordinary article readiness still settles through the real root mutation observer', async t => {
    const f = fixture(t, { ebook: false, article: true, host: false, articleMarker: true })
    assert.equal(f.messages.at(-1).hasReaderContent, true)
    assert.equal(f.messages.at(-1).hasReaderRenderReady, false)
    if (f.document.readyState !== 'complete') {
        await new Promise(resolve => f.window.addEventListener('load', resolve, { once: true }))
    }
    f.window.publishFontPending(false)
    await f.flush()
    assert.equal(f.messages.at(-1).hasReaderRenderReady, true)
    assert.equal(f.messages.at(-1).reason, 'mutation')
})
