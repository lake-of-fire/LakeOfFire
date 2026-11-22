import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import { runInNewContext } from 'node:vm'

const scriptURL = new URL(
    '../../Sources/LakeOfFireContent/Resources/User Scripts/readability_images.js',
    import.meta.url
)
const script = readFileSync(scriptURL, 'utf8')

function image(width = 0) {
    // The image fires capture listeners before ordinary listeners, even at the target.
    const captureListeners = new EventTarget()
    const ordinaryListeners = new EventTarget()
    let onload
    const invokeOnload = event => onload?.call(target, event)
    const target = {
        tagName: 'IMG',
        width,
        naturalWidth: width,
        naturalHeight: width,
        dataset: {},
        style: { cssText: '' },
        get onload() { return onload },
        set onload(callback) {
            if (!onload && callback) ordinaryListeners.addEventListener('load', invokeOnload)
            if (onload && !callback) ordinaryListeners.removeEventListener('load', invokeOnload)
            onload = callback
        },
        addEventListener(type, listener, capture = false) {
            const listeners = capture ? captureListeners : ordinaryListeners
            listeners.addEventListener(type, listener)
        },
        dispatchLoad() {
            const event = new Event('load')
            Object.defineProperty(event, 'target', { value: target })
            target.dispatchDocumentCapture?.(event)
            captureListeners.dispatchEvent(event)
            ordinaryListeners.dispatchEvent(event)
        }
    }
    return target
}

function loadImage(target, width, renderedWidth = width) {
    target.naturalWidth = target.naturalHeight = width
    target.width = renderedWidth
    target.dispatchLoad()
}

function mount(images) {
    const content = { offsetWidth: 1000 }
    const candidates = [...images]
    let onMutation
    let layoutPasses = 0
    let timer
    let readerMode = true
    const capturedLoads = new EventTarget()
    const document = {
        body: { classList: { contains: name => readerMode && name === 'readability-mode' } },
        documentElement: {},
        readyState: 'complete',
        addEventListener(type, listener, capture) {
            if (capture) capturedLoads.addEventListener(type, listener)
        },
        getElementById: id => id === 'reader-content' ? content : null,
        getElementsByTagName: () => candidates,
        querySelectorAll() {
            layoutPasses += 1
            return candidates
        }
    }
    const window = Object.assign(new EventTarget(), {
        top: { location: { origin: 'https://example.test' } }
    })
    function connect(target) {
        target.dispatchDocumentCapture = event => capturedLoads.dispatchEvent(event)
        target.matches = () => candidates.includes(target)
    }
    candidates.forEach(connect)
    runInNewContext(script, {
        document,
        window,
        MutationObserver: class {
            constructor(callback) { onMutation = callback }
            observe() {}
        },
        setTimeout(callback) { timer = callback; return 1 },
        clearTimeout() { timer = undefined }
    }, { filename: scriptURL.pathname })

    function flushLayout() {
        const callback = timer
        timer = undefined
        callback?.()
    }
    return {
        content,
        get layoutPasses() { return layoutPasses },
        resize() {
            window.dispatchEvent(new Event('resize'))
            flushLayout()
        },
        insertWrappedImage(target) {
            candidates.push(target)
            connect(target)
            const wrapper = { tagName: 'DIV', querySelector: name => name === 'img' ? target : null }
            onMutation([{ addedNodes: [wrapper] }])
        },
        flushLayout,
        leaveReaderMode() { readerMode = false }
    }
}

test('image layout precedes recall callbacks installed before or after it', () => {
    for (const installBeforeLayout of [true, false]) {
        const target = image()
        const recallStyles = []
        const recall = () => recallStyles.push(target.style.cssText)
        if (installBeforeLayout) target.onload = recall
        mount([target])
        if (!installBeforeLayout) target.onload = recall

        assert.equal(target.onload, recall)
        loadImage(target, 150)

        assert.equal(recallStyles.length, 1)
        assert.match(recallStyles[0], /width: min\(850px, 45%, 195px\) !important/)
    }
})

test('a late image load uses the current layout once after repeated scans', () => {
    const target = image()
    const reader = mount([target])
    reader.resize()
    reader.resize()
    const earlierPasses = reader.layoutPasses
    reader.content.offsetWidth = 600

    loadImage(target, 150)

    assert.equal(reader.layoutPasses, earlierPasses + 1)
    assert.match(target.style.cssText, /width: min\(600px, 850px, 300px\) !important/)
})

test('a load after leaving Reader Mode does not apply stale image styles', () => {
    const target = image()
    const reader = mount([target])
    reader.leaveReaderMode()

    loadImage(target, 150)

    assert.equal(target.style.cssText, '')
})

test('loading replaces declared image dimensions with the decoded dimensions', () => {
    const target = image()
    target.width = target.offsetWidth = target.offsetHeight = 50
    mount([target])
    assert.match(target.style.cssText, /width: min\(850px, 45%, 65px\) !important/)

    loadImage(target, 250)

    assert.match(target.style.cssText, /width: min\(1000px, 850px, 500px\) !important/)
})

test('inserting a wrapper lays out its already decoded image', () => {
    const reader = mount([])
    const target = image(150)

    reader.insertWrappedImage(target)
    reader.flushLayout()

    assert.match(target.style.cssText, /width: min\(850px, 45%, 195px\) !important/)
})

test('a decoded load can size its zero-width image while other pending images wait', () => {
    const target = image()
    const waiting = image()
    mount([target, waiting])

    loadImage(target, 150, 0)

    assert.match(target.style.cssText, /width: min\(850px, 45%, 195px\) !important/)
    assert.equal(waiting.style.cssText, '')
})

test('a wrapped image loading before the observer timer is sized before recall', () => {
    const reader = mount([])
    const target = image()
    let styleAtRecall
    target.onload = () => { styleAtRecall = target.style.cssText }

    reader.insertWrappedImage(target)
    loadImage(target, 150)

    assert.match(styleAtRecall, /width: min\(850px, 45%, 195px\) !important/)
})
