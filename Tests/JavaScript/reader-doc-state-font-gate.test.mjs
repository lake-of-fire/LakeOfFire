import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'

// Evaluate the actual injected source, rather than a duplicate readiness model.
const swift = readFileSync(new URL('../../Sources/LakeOfFireReader/Reader/ReaderDocStateUserScript.swift', import.meta.url), 'utf8')
const source = swift.split('let contents = """')[1]?.split('"""')[0]
assert.ok(source, 'ReaderDocStateUserScript must expose its injected source')

function fixture({ ebook = true, article = false, host = true, marker = true, pending = true, visible = true } = {}) {
    const messages = []
    const observers = []
    const timers = []
    const html = { dataset: { mnbFontPending: pending ? '1' : '0' } }
    const body = { dataset: {}, style: { visibility: visible ? 'visible' : 'hidden', display: 'block', opacity: '1' } }
    if (marker) html.dataset[ebook ? 'manabiReaderRenderReady' : 'mnbReaderRenderReady'] = '1'
    const document = {
        documentElement: html, body, readyState: 'complete',
        getElementById: id => id === 'reader-content' && article ? {} : null,
        querySelector: name => name === 'foliate-view' && host ? {} : null,
        addEventListener() {},
    }
    const window = {
        location: { href: ebook ? 'ebook://book/index.html' : 'https://example.com/article' },
        webkit: { messageHandlers: { readerDocState: { postMessage: value => messages.push(value) } } },
        getComputedStyle: node => node.style,
        addEventListener() {},
    }
    class MutationObserver {
        constructor(callback) { this.callback = callback; this.connected = false; observers.push(this) }
        observe(target, options) { this.target = target; this.options = options; this.connected = true }
        disconnect() { this.connected = false }
    }
    runInNewContext(source, {
        window, document, MutationObserver,
        requestAnimationFrame: callback => { timers.push(callback); return timers.length },
        setTimeout: callback => { timers.push(callback); return timers.length },
        cancelAnimationFrame() {}, clearTimeout() {},
    })
    return { messages, observers, timers, html, body, window }
}

test('EPUB font clearance reposts readiness without another renderer event', () => {
    const f = fixture()
    assert.equal(f.messages.length, 0)
    assert.equal(f.window.__manabiPostReaderDocStateEvent('renderer'), false)
    assert.equal(f.messages.at(-1).hasReaderRenderReady, false)
    const observer = f.observers.find(item => item.connected)
    assert.equal(observer.target, f.html)
    assert.equal(observer.options.attributes, true)
    assert.deepEqual(Array.from(observer.options.attributeFilter), ['data-mnb-font-pending'])
    assert.equal(observer.options.subtree, undefined)
    assert.equal(observer.options.childList, undefined)
    assert.equal(f.timers.length, 0)
    delete f.html.dataset.mnbFontPending
    observer.callback()
    assert.equal(f.messages.at(-1).reason, 'font-state')
    assert.equal(f.messages.at(-1).hasReaderContent, true)
    assert.equal(f.messages.at(-1).hasReaderRenderReady, true)
    assert.equal(observer.connected, false)
    assert.equal(f.timers.length, 0)
})

test('EPUB readiness still requires content, a marker and visible body', () => {
    for (const options of [{ host: false }, { marker: false }, { visible: false }]) {
        const f = fixture({ pending: false, ...options })
        assert.equal(f.window.__manabiPostReaderDocStateEvent('renderer'), false)
        assert.equal(f.messages.at(-1).hasReaderRenderReady, false)
    }
})

test('article readiness retains its marker and reader-content contract', () => {
    const ready = fixture({ ebook: false, article: true, pending: false })
    assert.equal(ready.messages.at(-1).hasReaderRenderReady, true)
    assert.equal(ready.timers.length, 0)
    const wrongHost = fixture({ ebook: false, article: false, pending: false })
    assert.equal(wrongHost.messages.at(-1).hasReaderContent, false)
    assert.equal(wrongHost.messages.at(-1).hasReaderRenderReady, false)
    assert.equal(wrongHost.observers.find(item => item.connected).options.subtree, true)
    assert.equal(wrongHost.timers.length, 1)
    const wrongMarker = fixture({ ebook: false, article: true, marker: false, pending: false })
    wrongMarker.html.dataset.manabiReaderRenderReady = '1'
    assert.equal(wrongMarker.window.__manabiPostReaderDocStateEvent('renderer'), false)
})

// This fixture tests only the JavaScript bridge. URL/generation admission and
// native loading-overlay behavior require separate integration qualification.
