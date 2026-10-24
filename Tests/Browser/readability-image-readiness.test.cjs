const assert = require('node:assert/strict')
const test = require('node:test')
const { readFileSync } = require('node:fs')
const { JSDOM, VirtualConsole } = require('jsdom')

const path = require('node:path')
const imageSource = readFileSync(path.resolve(__dirname, '../../Sources/LakeOfFireContent/Resources/User Scripts/readability_images.js'), 'utf8')
// Review tuple: Core #868, 0da16e8b82ed94073469335c65bd1aca2f70f45f.
// Supply its exact production manabi_reader.js; only the actual helper is evaluated.
if (!process.env.MANABI_CORE_READER_SOURCE) throw new Error('Set MANABI_CORE_READER_SOURCE to the selected Core manabi_reader.js')
const coreSource = readFileSync(process.env.MANABI_CORE_READER_SOURCE, 'utf8')
const start = coreSource.indexOf('window.manabi_scrollToNodeAfterPrecedingImagesLoad = function')
const end = coreSource.indexOf('window.manabi_refreshArticleReadingProgress = function', start)
if (start < 0 || end < 0) throw new Error('Actual Core helper is unavailable')
const coreHelper = coreSource.slice(start, end)

async function fixture(runBeforeReady) {
    const errors = []
    const virtualConsole = new VirtualConsole()
    virtualConsole.on('jsdomError', error => errors.push(error))
    const dom = new JSDOM('<!doctype html><html><head></head><body></body></html>', {
        url: 'https://reader.example/article',
        runScripts: 'outside-only',
        virtualConsole
    })
    const { window } = dom
    try {
        assert.equal(window.document.readyState, 'loading')
        window.document.body.remove()
        window.eval(imageSource)
        window.eval(coreHelper)
        const body = window.document.createElement('body')
        body.className = 'readability-mode'
        body.innerHTML = '<div id="reader-content"><p><img src="pending"></p><section id="target">Saved place</section></div>'
        window.document.documentElement.append(body)
        const root = window.document.getElementById('reader-content')
        const image = root.querySelector('img')
        const target = window.document.getElementById('target')
        const state = { loaded: false, scrolls: 0, styledWhenScrolled: false }
        Object.defineProperty(root, 'offsetWidth', { get: () => 800 })
        for (const name of ['width', 'naturalWidth']) {
            Object.defineProperty(image, name, { get: () => state.loaded ? 300 : 0 })
        }
        Object.defineProperty(image, 'naturalHeight', { get: () => state.loaded ? 200 : 0 })
        Object.defineProperty(image, 'complete', { get: () => state.loaded })
        target.scrollIntoView = () => {
            state.scrolls++
            state.styledWhenScrolled = image.dataset.manabiManagedReaderImageSizing === '1'
        }
        const ready = new Promise(resolve => window.document.addEventListener('DOMContentLoaded', resolve, { once: true }))
        await runBeforeReady({ window, image, target, state, ready })
        assert.deepEqual(errors, [])
    } finally {
        window.close()
    }
}

test('document-start installation preserves a Core waiter registered before DOMContentLoaded', async () => {
    await fixture(async ({ window, image, target, state, ready }) => {
        window.manabi_scrollToNodeAfterPrecedingImagesLoad(target)
        const resolver = image.onload
        await ready
        assert.equal(image.onload, resolver)
        state.loaded = true
        image.dispatchEvent(new window.Event('load'))
        await Promise.resolve()
        await Promise.resolve()
        assert.equal(state.scrolls, 1)
        assert.equal(state.styledWhenScrolled, true)
    })
})

test('an image loaded before DOMContentLoaded is sized during actual readiness', async () => {
    await fixture(async ({ window, image, target, state, ready }) => {
        let pageCalls = 0
        const pageLoad = () => pageCalls++
        image.onload = pageLoad
        state.loaded = true
        image.dispatchEvent(new window.Event('load'))
        assert.equal(image.dataset.manabiManagedReaderImageSizing, undefined)
        await ready
        assert.equal(image.onload, pageLoad)
        assert.equal(pageCalls, 1)
        assert.equal(image.dataset.manabiManagedReaderImageSizing, '1')
        window.manabi_scrollToNodeAfterPrecedingImagesLoad(target)
        await Promise.resolve()
        await Promise.resolve()
        assert.equal(state.scrolls, 1)
        assert.equal(state.styledWhenScrolled, true)
    })
})

test('error settlement still releases a pre-readiness Core waiter without applying sizing', async () => {
    await fixture(async ({ window, image, target, state, ready }) => {
        window.manabi_scrollToNodeAfterPrecedingImagesLoad(target)
        const resolver = image.onerror
        await ready
        assert.equal(image.onerror, resolver)
        image.dispatchEvent(new window.Event('error'))
        await Promise.resolve()
        await Promise.resolve()
        assert.equal(state.scrolls, 1)
        assert.equal(image.dataset.manabiManagedReaderImageSizing, undefined)
    })
})

test('a page load callback adding a caption before sizing retains vertical paragraph flow', async () => {
    await fixture(async ({ window, image, state, ready }) => {
        window.document.body.dataset.mnbWritingDirection = 'vertical'
        const wrapper = image.parentElement
        image.onload = () => wrapper.prepend('A photograph caption ')
        await ready
        assert.equal(wrapper.classList.contains('mnb-vertical-inline-image-wrapper'), true)
        // Register the production delayed-load listener in a horizontal pass,
        // then return to vertical mode while that load remains pending.
        window.document.body.dataset.mnbWritingDirection = 'horizontal'
        window.manabiUpdateReadabilityImageMargins()
        window.document.body.dataset.mnbWritingDirection = 'vertical'
        state.loaded = true
        image.dispatchEvent(new window.Event('load'))
        assert.equal(wrapper.textContent, 'A photograph caption ')
        assert.equal(wrapper.classList.contains('mnb-vertical-inline-image-wrapper'), false)
        assert.equal(image.style.borderRadius, '6px')
        assert.equal(image.style.maxWidth, '')
    })
})
