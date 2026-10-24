import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'

// Execute the actual injected document-state script, actual Viewer readiness
// publisher and both embedded native font-pending setters. DOM/MutationObserver
// delivery and the bridge sink are controlled; no Swift or WebKit is executed.
const swift = readFileSync(process.env.MANABI_DOC_STATE_SOURCE
    ?? new URL('../../Sources/LakeOfFireReader/Reader/ReaderDocStateUserScript.swift', import.meta.url), 'utf8')
const source = swift.split('let contents = """')[1]?.split('"""')[0]
if (!source) throw new Error('Unable to load the injected document-state script')
const viewer = readFileSync(new URL('../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-viewer.js', import.meta.url), 'utf8')
const fontInjector = readFileSync(new URL('../../Sources/LakeOfFireReader/Reader/ReaderModeViewModel.swift', import.meta.url), 'utf8')
const sourceBlock = (text, startMarker, endMarker, from = 0) => {
    const start = text.indexOf(startMarker, from)
    const end = text.indexOf(endMarker, start + startMarker.length)
    if (start < 0 || end < 0) throw new Error(`Unable to load production declaration: ${startMarker}`)
    return text.slice(start, end)
}
const rendererPublisher = sourceBlock(viewer, 'const markReaderRenderReady =', 'const roundedDisplayPercent =')
const firstFontSetter = fontInjector.indexOf('const setFontPendingState =')
const fontSetters = {
    'local-scheme': sourceBlock(fontInjector, 'const setFontPendingState =', 'const resolveStylesheetURL ='),
    blob: sourceBlock(fontInjector, 'const setFontPendingState =', 'const replaceFontBlob =', firstFontSetter + 1),
}

const fixture = ({
    mode = 'local-scheme', ebook = true, bodyEbook = false, article = false, host = true,
    pending = true, marker = false, visibility = 'visible', display = 'block', opacity = '1',
    generation = '12345678-1234-1234-1234-123456789abc',
} = {}) => {
    const messages = []
    const observers = []
    const mutationRecords = []
    const timers = new Map()
    let nextTimer = 0
    const rawDataset = { mnbReaderRenderGeneration: generation }
    if (pending) rawDataset.mnbFontPending = '1'
    if (marker) rawDataset[ebook || bodyEbook ? 'manabiReaderRenderReady' : 'mnbReaderRenderReady'] = '1'
    const html = {}
    const attributeName = key => 'data-' + key.replace(/[A-Z]/g, value => '-' + value.toLowerCase())
    html.dataset = new Proxy(rawDataset, {
        set(target, key, value) {
            const changed = target[key] !== value
            target[key] = value
            if (changed) mutationRecords.push({ type: 'attributes', target: html, attributeName: attributeName(key) })
            return true
        },
        deleteProperty(target, key) {
            const existed = Object.hasOwn(target, key)
            delete target[key]
            if (existed) mutationRecords.push({ type: 'attributes', target: html, attributeName: attributeName(key) })
            return true
        },
    })
    const body = { dataset: bodyEbook ? { isEbook: 'true' } : {}, style: { visibility, display, opacity } }
    const document = {
        documentElement: html, body, readyState: 'complete',
        fonts: { status: 'loaded' },
        getElementById: id => id === 'reader-content' && article ? {} : null,
        querySelector: name => name === 'foliate-view' && host ? {} : null,
        addEventListener() {},
    }
    class MutationObserver {
        constructor(callback) { this.callback = callback; this.connected = false; observers.push(this) }
        observe(target, options) { this.target = target; this.options = options; this.connected = true }
        disconnect() { this.connected = false }
    }
    const context = {
        document, MutationObserver,
        location: { href: ebook ? 'ebook://book/index.html' : 'https://example.com/article' },
        webkit: { messageHandlers: { readerDocState: { postMessage: value => messages.push(value) } } },
        getComputedStyle: element => element.style,
        addEventListener() {},
        postLog() {},
        requestAnimationFrame: callback => { const id = ++nextTimer; timers.set(id, callback); return id },
        setTimeout: callback => { const id = ++nextTimer; timers.set(id, callback); return id },
        cancelAnimationFrame: id => timers.delete(id),
        clearTimeout: id => timers.delete(id),
    }
    context.window = context
    vm.createContext(context)
    vm.runInContext(source, context, { filename: 'ReaderDocStateUserScript.injected.js' })
    vm.runInContext(rendererPublisher + '\nglobalThis.publishRendererReady = markReaderRenderReady;', context)
    vm.runInContext(fontSetters[mode] + '\nglobalThis.publishFontPending = setFontPendingState;', context)
    const flushMutations = () => {
        const pendingRecords = mutationRecords.splice(0)
        for (const observer of observers) {
            if (!observer.connected) continue
            const matching = pendingRecords.filter(record => record.target === observer.target
                && observer.options.attributes === true
                && (!observer.options.attributeFilter || observer.options.attributeFilter.includes(record.attributeName)))
            if (matching.length) observer.callback(matching)
        }
    }
    return { messages, observers, timers, html, body, context, flushMutations }
}

test('the actual EPUB renderer publisher reports its own host and readiness marker', () => {
    const f = fixture({ pending: false })
    f.context.publishRendererReady('controlled-display')
    assert.equal(f.messages.at(-1).hasReaderContent, true)
    assert.equal(f.messages.at(-1).hasReaderRenderReady, true)
    assert.equal(f.messages.at(-1).reason, 'renderReady.controlled-display')
    assert.equal(f.messages.at(-1).readerRenderGeneration, '12345678-1234-1234-1234-123456789abc')
    assert.equal(f.messages.at(-1).href, 'ebook://book/index.html')
})

for (const mode of Object.keys(fontSetters)) test(`actual ${mode} font clearance reposts EPUB readiness after the renderer event`, () => {
    const f = fixture({ mode })
    assert.equal(f.messages.length, 0)
    f.context.publishRendererReady('before-font-completion')
    assert.equal(f.messages.at(-1).hasReaderRenderReady, false)
    const beforeCompletion = f.messages.length
    f.context.publishFontPending(false)
    f.flushMutations()
    assert.equal(f.messages.length, beforeCompletion + 1)
    assert.equal(f.messages.at(-1).reason, 'font-state')
    assert.equal(f.messages.at(-1).hasReaderContent, true)
    assert.equal(f.messages.at(-1).hasReaderRenderReady, true)
    assert.equal(f.observers.filter(observer => observer.connected).length, 0)
    assert.equal(f.timers.size, 0)
})

test('EPUB observation is restricted to the root font gate and stops after readiness', () => {
    const f = fixture()
    const observer = f.observers.find(item => item.connected)
    assert.ok(observer)
    assert.equal(observer.target, f.html)
    assert.equal(observer.options.attributes, true)
    assert.deepEqual(Array.from(observer.options.attributeFilter), ['data-mnb-font-pending'])
    assert.equal(observer.options.subtree, undefined)
    assert.equal(observer.options.childList, undefined)
    f.html.dataset.unrelated = 'changed'
    f.flushMutations()
    assert.equal(f.messages.length, 0)
    f.context.publishRendererReady('ready')
    f.context.publishFontPending(false)
    f.flushMutations()
    const finishedCount = f.messages.length
    f.context.publishFontPending(true)
    f.flushMutations()
    f.context.publishFontPending(false)
    f.flushMutations()
    assert.equal(f.messages.length, finishedCount)
    assert.equal(f.timers.size, 0)
})

for (const [name, options] of [
    ['content host', { host: false }],
    ['visible body', { visibility: 'hidden' }],
    ['displayed body', { display: 'none' }],
    ['opaque body', { opacity: '0' }],
]) test(`EPUB readiness preserves the ${name} requirement`, () => {
    const f = fixture({ pending: false, ...options })
    f.context.publishRendererReady('not-ready')
    assert.equal(f.messages.at(-1).hasReaderRenderReady, false)
})

test('font completion alone cannot manufacture a renderer readiness marker', () => {
    const f = fixture()
    f.context.__manabiPostReaderDocStateEvent('before-render')
    f.context.publishFontPending(false)
    f.flushMutations()
    assert.equal(f.messages.at(-1).hasReaderRenderReady, false)
    assert.equal(f.html.dataset.manabiReaderRenderReady, undefined)
})

test('the existing body EPUB namespace admits the same actual renderer producer', () => {
    const f = fixture({ ebook: false, bodyEbook: true, pending: false })
    f.context.publishRendererReady('body-ebook')
    assert.equal(f.messages.at(-1).hasReaderContent, true)
    assert.equal(f.messages.at(-1).hasReaderRenderReady, true)
})

test('article readiness retains its own marker, content and font completion contract', () => {
    const ready = fixture({ ebook: false, article: true, pending: false, marker: true })
    assert.equal(ready.messages.at(-1).hasReaderRenderReady, true)
    assert.equal(ready.timers.size, 0)
    const waiting = fixture({ ebook: false, article: true, marker: true })
    assert.equal(waiting.messages.at(-1).hasReaderRenderReady, false)
    assert.equal(waiting.observers.find(item => item.connected).options.subtree, true)
    waiting.context.publishFontPending(false)
    waiting.flushMutations()
    assert.equal(waiting.messages.at(-1).hasReaderRenderReady, true)
    assert.equal(waiting.timers.size, 0)
})

test('an article cannot borrow the EPUB host or renderer-only marker', () => {
    const wrongHost = fixture({ ebook: false, article: false, pending: false, marker: true })
    assert.equal(wrongHost.messages.at(-1).hasReaderContent, false)
    assert.equal(wrongHost.messages.at(-1).hasReaderRenderReady, false)
    const wrongMarker = fixture({ ebook: false, article: true, pending: false })
    wrongMarker.context.publishRendererReady('epub-marker-on-article')
    assert.equal(wrongMarker.messages.at(-1).hasReaderRenderReady, false)
})

test('a rejected hidden EPUB stays observable and accepts a current visible renderer retry', () => {
    const f = fixture({ visibility: 'hidden' })
    f.context.publishRendererReady('hidden-display')
    assert.equal(f.messages.at(-1).hasReaderRenderReady, false)
    f.context.publishFontPending(false)
    f.flushMutations()
    assert.equal(f.messages.at(-1).hasReaderRenderReady, false)
    assert.equal(f.observers.filter(observer => observer.connected).length, 1)
    f.body.style.visibility = 'visible'
    f.context.publishRendererReady('visible-retry')
    assert.equal(f.messages.at(-1).hasReaderRenderReady, true)
    assert.equal(f.messages.at(-1).reason, 'renderReady.visible-retry')
    assert.equal(f.observers.filter(observer => observer.connected).length, 0)
    assert.equal(f.timers.size, 0)
})

// Native URL/generation admission, complete font injection, mounted browser
// observation and the Core loading overlay remain integration qualifications.
