// Run with Node's test runner and jsdom 26.1.0 available through NODE_PATH.
// This evaluates the complete shipping script with a real DOM/CSSOM. Image
// dimensions, load delivery, and the debounce clock are controlled collaborators.
const assert = require('node:assert/strict')
const { readFileSync } = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const { JSDOM, VirtualConsole } = require('jsdom')

const sourcePath = process.env.MANABI_READABILITY_IMAGES_SOURCE || path.resolve(
    __dirname,
    '../../Sources/LakeOfFireContent/Resources/User Scripts/readability_images.js'
)
const source = readFileSync(sourcePath, 'utf8')

function fixture(t, { content = '<p id="wrapper"><img id="image" style="color:red;margin-left:7px"></p>', loaded = false, vertical = false, beforeInstall } = {}) {
    const errors = []
    const virtualConsole = new VirtualConsole()
    virtualConsole.on('jsdomError', error => errors.push(error))
    const dom = new JSDOM(`<!doctype html><html><body class="readability-mode"><div id="reader-content">${content}</div></body></html>`, {
        url: 'https://reader.example/article',
        runScripts: 'outside-only',
        virtualConsole
    })
    const { window } = dom
    const { document } = window
    Object.defineProperty(document, 'readyState', { configurable: true, value: 'complete' })
    if (vertical) document.body.dataset.mnbWritingDirection = 'vertical'
    const state = { contentWidth: 800 }
    const installContentWidth = element => Object.defineProperty(element, 'offsetWidth', {
        configurable: true,
        get: () => state.contentWidth
    })
    installContentWidth(document.getElementById('reader-content'))
    const dimensions = new WeakMap()
    function imageDimensions(image, initial = loaded) {
        const value = { loaded: initial, width: 300, height: 200 }
        dimensions.set(image, value)
        for (const [name, dimension] of [['width', 'width'], ['naturalWidth', 'width'], ['naturalHeight', 'height']]) {
            Object.defineProperty(image, name, {
                configurable: true,
                get: () => value.loaded ? value[dimension] : 0
            })
        }
        return value
    }
    for (const image of document.images) imageDimensions(image)
    let nextTimer = 0
    const timers = new Map()
    window.setTimeout = (callback, delay, ...args) => {
        const id = ++nextTimer
        timers.set(id, { callback, delay, args })
        return id
    }
    window.clearTimeout = id => timers.delete(id)
    function flushTimers() {
        const pending = [...timers]
        for (const [id, timer] of pending) {
            if (!timers.delete(id)) continue
            timer.callback(...timer.args)
        }
    }
    async function settleMutations() {
        await new Promise(resolve => setImmediate(resolve))
    }
    function load(image) {
        dimensions.get(image).loaded = true
        image.dispatchEvent(new window.Event('load'))
    }
    beforeInstall?.({ window, document })
    window.eval(source)
    t.after(() => {
        dom.window.close()
        assert.deepEqual(errors, [], 'production script must not raise DOM errors')
    })
    return { window, document, state, timers, flushTimers, settleMutations, imageDimensions, installContentWidth, load }
}

function assertUnrelatedStyles(image) {
    assert.equal(image.style.color, 'red')
    assert.equal(image.style.marginLeft, '7px')
}

function assertManaged(image) {
    assert.equal(image.dataset.manabiManagedReaderImageSizing, '1')
    assert.notEqual(image.style.maxWidth, '')
    assert.equal(image.style.getPropertyPriority('max-width'), 'important')
}

test('a current horizontal load sizes the image and preserves unrelated styles', t => {
    const f = fixture(t)
    const image = f.document.getElementById('image')
    f.load(image)
    assertManaged(image)
    assert.equal(image.style.getPropertyPriority('width'), 'important')
    assertUnrelatedStyles(image)
})

test('a late load after vertical switching cannot restore horizontal sizing', t => {
    const f = fixture(t)
    const image = f.document.getElementById('image')
    f.document.body.dataset.mnbWritingDirection = 'vertical'
    f.window.manabiUpdateReadabilityImageMargins()
    f.load(image)
    assert.equal(image.style.width, '')
    assert.equal(image.style.maxWidth, '')
    assert.equal(image.style.borderRadius, '6px')
    assert.equal(f.document.getElementById('wrapper').classList.contains('mnb-vertical-inline-image-wrapper'), true)
    assertUnrelatedStyles(image)
})

test('a late load after leaving reader mode does not start sizing', t => {
    const f = fixture(t)
    const image = f.document.getElementById('image')
    f.document.body.classList.remove('readability-mode')
    f.load(image)
    assert.equal(image.style.width, '')
    assert.equal(image.style.maxWidth, '')
    assert.equal(image.dataset.manabiManagedReaderImageSizing, undefined)
    assertUnrelatedStyles(image)
})

test('a late load uses the current content width', t => {
    const f = fixture(t)
    const image = f.document.getElementById('image')
    f.state.contentWidth = 400
    f.load(image)
    assertManaged(image)
    assert.equal(image.style.width, image.style.maxWidth)
    assertUnrelatedStyles(image)
})

test('a late load cannot mutate a detached image', t => {
    const f = fixture(t)
    const image = f.document.getElementById('image')
    image.remove()
    f.load(image)
    assert.equal(image.style.width, '')
    assert.equal(image.style.maxWidth, '')
    assertUnrelatedStyles(image)
})

test('a late load cannot size a connected image moved outside reader content', t => {
    const f = fixture(t)
    const image = f.document.getElementById('image')
    f.document.body.append(image)
    f.load(image)
    assert.equal(image.style.width, '')
    assert.equal(image.style.maxWidth, '')
    assertUnrelatedStyles(image)
})

test('a late load cannot size an image that lost block-image eligibility', t => {
    const f = fixture(t)
    const image = f.document.getElementById('image')
    f.document.getElementById('wrapper').append(f.document.createElement('span'))
    f.load(image)
    assert.equal(image.style.width, '')
    assert.equal(image.style.maxWidth, '')
    assertUnrelatedStyles(image)
})

test('a replaced reader-content root retires the old image load', t => {
    const f = fixture(t)
    const oldImage = f.document.getElementById('image')
    const next = f.document.createElement('div')
    next.id = 'reader-content'
    next.innerHTML = '<p><img id="next"></p>'
    f.installContentWidth(next)
    const nextImage = next.querySelector('img')
    f.imageDimensions(nextImage, true)
    f.document.getElementById('reader-content').replaceWith(next)
    f.load(oldImage)
    assert.equal(oldImage.style.width, '')
    assert.equal(oldImage.style.maxWidth, '')
    assertManaged(nextImage)
})

test('a directly appended image retains existing insertion behavior', async t => {
    const f = fixture(t, { content: '' })
    const image = f.document.createElement('img')
    f.imageDimensions(image, true)
    f.document.getElementById('reader-content').append(image)
    await f.settleMutations()
    f.flushTimers()
    assertManaged(image)
})

test('an inserted wrapper containing a loaded image receives Reader sizing', async t => {
    const f = fixture(t, { content: '' })
    const wrapper = f.document.createElement('p')
    wrapper.innerHTML = '<a><img></a>'
    const image = wrapper.querySelector('img')
    f.imageDimensions(image, true)
    f.document.getElementById('reader-content').append(wrapper)
    await f.settleMutations()
    f.flushTimers()
    assertManaged(image)
})

test('a replacement content subtree receives vertical image presentation', async t => {
    const f = fixture(t, { content: '', vertical: true })
    const next = f.document.createElement('div')
    next.id = 'reader-content'
    next.innerHTML = '<p id="new-wrapper"><picture><img></picture></p>'
    f.installContentWidth(next)
    const image = next.querySelector('img')
    f.imageDimensions(image, true)
    f.document.getElementById('reader-content').replaceWith(next)
    await f.settleMutations()
    f.flushTimers()
    assert.equal(image.style.borderRadius, '6px')
    assert.equal(next.querySelector('picture').style.overflow, 'hidden')
    assert.equal(next.querySelector('p').classList.contains('mnb-vertical-inline-image-wrapper'), true)
})

test('Reader initialization preserves a page-owned image load callback', t => {
    let calls = 0
    const pageLoad = () => { calls += 1 }
    const f = fixture(t, { beforeInstall: ({ document }) => {
        document.getElementById('image').onload = pageLoad
    } })
    const image = f.document.getElementById('image')
    f.load(image)
    assert.equal(image.onload, pageLoad)
    assert.equal(calls, 1)
    assertManaged(image)
})

test('a later restoration callback cannot remove Reader image sizing', t => {
    const f = fixture(t)
    const image = f.document.getElementById('image')
    let restored = 0
    image.onload = () => { restored += 1 }
    f.load(image)
    assert.equal(restored, 1)
    assertManaged(image)
})

test('refresh while restoration waits preserves its load callback', t => {
    const f = fixture(t)
    const image = f.document.getElementById('image')
    let restored = 0
    image.onload = () => { restored += 1 }
    f.window.manabiUpdateReadabilityImageMargins()
    f.window.manabiUpdateReadabilityImageMargins()
    f.load(image)
    assert.equal(restored, 1)
    assertManaged(image)
})

test('repeated refreshes register one load listener and a later source can load again', t => {
    const f = fixture(t)
    const image = f.document.getElementById('image')
    let writes = 0
    const setProperty = image.style.setProperty.bind(image.style)
    image.style.setProperty = (...args) => {
        if (args[0] === 'max-width') writes += 1
        return setProperty(...args)
    }
    for (let i = 0; i < 5; i += 1) f.window.manabiUpdateReadabilityImageMargins()
    f.load(image)
    assert.equal(writes, 1, 'one refresh must handle the delivered load')
    f.load(image)
    assert.equal(writes, 2, 'the same element can deliver a later source load')
})

test('an image failure preserves error settlement and a later successful load still sizes', t => {
    let failed = 0
    const f = fixture(t, { beforeInstall: ({ document }) => {
        document.getElementById('image').onerror = () => { failed += 1 }
    } })
    const image = f.document.getElementById('image')
    image.dispatchEvent(new f.window.Event('error'))
    assert.equal(failed, 1)
    assert.equal(image.style.maxWidth, '')
    f.load(image)
    assertManaged(image)
})

test('images inserted as a DocumentFragment are refreshed in one debounced pass', async t => {
    const f = fixture(t, { content: '' })
    const fragment = f.document.createDocumentFragment()
    for (let i = 0; i < 3; i += 1) {
        const wrapper = f.document.createElement('figure')
        const image = f.document.createElement('img')
        f.imageDimensions(image, true)
        wrapper.append(image)
        fragment.append(wrapper)
    }
    f.document.getElementById('reader-content').append(fragment)
    await f.settleMutations()
    assert.equal(f.timers.size, 1)
    f.flushTimers()
    for (const image of f.document.images) assertManaged(image)
})

test('an inserted subtree removed before debounce cannot be mutated', async t => {
    const f = fixture(t, { content: '' })
    const wrapper = f.document.createElement('p')
    wrapper.innerHTML = '<img>'
    const image = wrapper.querySelector('img')
    f.imageDimensions(image, true)
    f.document.getElementById('reader-content').append(wrapper)
    await f.settleMutations()
    wrapper.remove()
    f.flushTimers()
    assert.equal(image.style.maxWidth, '')
    assert.equal(image.dataset.manabiManagedReaderImageSizing, undefined)
})

test('unrelated inserted text and controls do not request an image refresh', async t => {
    const f = fixture(t, { content: '' })
    const root = f.document.getElementById('reader-content')
    root.append('A sentence', f.document.createComment('image'), f.document.createElement('button'))
    await f.settleMutations()
    assert.equal(f.timers.size, 0)
})
