'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const { JSDOM } = require('jsdom')

// These are the actual two JavaScript literals sent by injectSharedFontIfNeeded.
// Decode Swift's escaped backslashes before executing them. No Swift compiler,
// native availability branch, URL handler, or WebKit font loader runs here.
const swift = fs.readFileSync(path.resolve(__dirname,
    '../../Sources/LakeOfFireReader/Reader/ReaderModeViewModel.swift'), 'utf8')
const method = swift.slice(swift.indexOf('func injectSharedFontIfNeeded('))
const scripts = [...method.matchAll(/let js = """\n([\s\S]*?)\n\s*"""/g)]
    .slice(0, 2).map(match => {
        if (match[1].includes('\\(')) throw new Error('Unexpected Swift interpolation in font fixture')
        return match[1].replace(/\\\\/g, '\\')
    })
if (scripts.length !== 2) throw new Error('Missing font injection scripts')
const css = "@font-face { font-family: 'YuKyokasho'; src: local('YuKyo-Medium'); }\n"
    + "@font-face { font-family: 'YuKyokasho Yoko'; src: local('YuKyo_Yoko-Medium'); }"

function deferred() {
    let resolve, reject
    const promise = new Promise((yes, no) => { resolve = yes; reject = no })
    return { promise, resolve, reject }
}

function fixture(t, { url = 'internal://local/article', selection = 'YuKyokasho Yoko' } = {}) {
    const dom = new JSDOM('<!doctype html><html><head></head><body>日本語</body></html>',
        { url, runScripts: 'outside-only' })
    const { window } = dom
    t.after(() => window.close())
    const { document } = window
    document.documentElement.dataset.mnbHorizontalFontFamily = selection
    const blobs = new Map()
    const revoked = []
    const timers = new Map()
    let timerID = 0
    window.setTimeout = callback => { timers.set(++timerID, callback); return timerID }
    window.clearTimeout = id => timers.delete(id)
    window.Blob = Blob
    window.URL.createObjectURL = blob => {
        const url = 'blob:https://example.com/font-' + blobs.size
        blobs.set(url, blob)
        return url
    }
    window.URL.revokeObjectURL = url => revoked.push(url)
    window.fontCSSBase64 = Buffer.from(css).toString('base64')
    window.fontHash = 'fixture-font-css'
    window.stylesheetURLTemplate = 'internal://local/manabi-fonts.css?family=__MANABI_FONT_FAMILY__'
    window.stylesheetFamilyName = 'YuKyokasho Yoko'
    const loads = []
    document.fonts = { ready: Promise.resolve(), load: async name => { loads.push(name); return [] } }
    return { window, document, blobs, revoked, timers, loads,
        run: mode => window.eval(scripts[mode === 'local' ? 0 : 1]),
        style: () => document.getElementById('mnb-custom-fonts-inline'),
    }
}

test('system asset route remains valid with an explicit installed-font choice', async t => {
    const f = fixture(t, { selection: 'Hiragino Mincho ProN' })
    await f.run('local')
    assert.equal(new URL(f.style().href).searchParams.get('family'), 'YuKyokasho Yoko')
    assert.equal(f.style().dataset.mnbInjectedFontFamily, 'Hiragino Mincho ProN')
    assert.equal(f.document.documentElement.dataset.mnbHorizontalFontFamily, 'Hiragino Mincho ProN')
    assert.deepEqual(f.loads, ["1em 'Hiragino Mincho ProN'"])
    assert.equal(f.timers.size, 0)
})

test('legacy file assets retain their requested stylesheet family', async t => {
    const f = fixture(t, { selection: 'Legacy Face' })
    f.window.stylesheetFamilyName = ''
    await f.run('local')
    assert.equal(new URL(f.style().href).searchParams.get('family'), 'Legacy Face')
})

for (const selection of ['YuKyokasho', 'YuKyokasho Yoko', 'Hiragino Mincho ProN']) {
    test('blob injection preserves both source faces for ' + selection, async t => {
        const f = fixture(t, { url: 'https://example.com/article', selection })
        await f.run('blob')
        assert.equal(await f.blobs.get(f.style().href).text(), css)
        assert.equal(f.style().dataset.mnbInjectedFontFamily, selection)
        assert.equal(f.document.documentElement.dataset.mnbHorizontalFontFamily, selection)
        assert.equal(f.document.documentElement.dataset.mnbFontPending, undefined)
        assert.equal(f.timers.size, 0)
    })
}

test('a replacement blob releases only the previous resource', async t => {
    const f = fixture(t, { url: 'https://example.com/article' })
    f.window.manabiReaderFontCSSBlobURL = 'blob:https://example.com/old-font'
    await f.run('blob')
    assert.deepEqual(f.revoked, ['blob:https://example.com/old-font'])
    assert.notEqual(f.style().href, f.revoked[0])
    assert.equal(await f.blobs.get(f.style().href).text(), css)
})

for (const mode of ['local', 'blob']) {
    test(mode + ' injection keeps its existing readiness gate until font settlement', async t => {
        const f = fixture(t)
        const ready = deferred()
        f.document.fonts.ready = ready.promise
        const result = f.run(mode)
        assert.equal(f.document.documentElement.dataset.mnbFontPending, '1')
        assert.equal(f.timers.size, 1)
        ready.resolve()
        await result
        assert.equal(f.document.documentElement.dataset.mnbFontPending, undefined)
        assert.equal(f.document.documentElement.dataset.mnbFontReady, '1')
        assert.equal(f.timers.size, 0)
    })
    test(mode + ' injection leaves loader shells untouched', async t => {
        const f = fixture(t, { url: 'internal://local/load/reader?url=article' })
        await f.run(mode)
        assert.equal(f.style(), null)
        assert.equal(f.blobs.size, 0)
        assert.equal(f.timers.size, 0)
        assert.equal(f.document.documentElement.dataset.mnbFontPending, undefined)
    })
}
