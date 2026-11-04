import assert from 'node:assert/strict'
import test from 'node:test'

globalThis.DOMParser = class {}
globalThis.window = { innerWidth: 800, innerHeight: 600 }

const { Loader } = await import(
    '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/epub.js'
)

const withStylesheet = async (css, assets, check) => {
    const stylesheet = { href: 'OPS/book.css', mediaType: 'text/css' }
    const loaded = []
    const loader = new Loader({
        resources: { manifest: [stylesheet, ...assets] },
        loadText: async href => href === stylesheet.href ? css : 'p { color: green; }',
        loadBlob: async href => {
            loaded.push(href)
            return new Blob(['image bytes'])
        },
    })
    try {
        const url = await loader.loadItem(stylesheet)
        const output = await (await fetch(url)).text()
        await check(output, loaded)
    } finally {
        loader.destroy()
    }
}

const image = href => ({ href: `OPS/${href}`, mediaType: 'image/png' })

for (const [name, source, path] of [
    ['parentheses', '"images/cover(1).png"', 'images/cover(1).png'],
    ['opposite quote', `"images/cover's.png"`, "images/cover's.png"],
    ['escaped parentheses', String.raw`images/cover\(1\).png`, 'images/cover(1).png'],
    ['hex escape', String.raw`"images/\63 over.png"`, 'images/cover.png'],
    ['unquoted hex escape', String.raw`images/\63 over.png`, 'images/cover.png'],
    ['escaped quote', String.raw`"images/cover\"draft.png"`, 'images/cover"draft.png'],
    ['ordinary unquoted path', 'images/cover.png', 'images/cover.png'],
]) {
    test(`stylesheet URLs resolve filenames containing ${name}`, async () => {
        await withStylesheet(`p { background: url(${source}); }`, [image(path)], async (css, loaded) => {
            assert.deepEqual(loaded, [`OPS/${path}`])
            const match = css.match(/^p \{ background: url\("(blob:[^"]+)"\); \}$/)
            assert.ok(match, css)
            assert.equal(await (await fetch(match[1])).text(), 'image bytes')
        })
    })
}

test('stylesheet rewriting preserves comments and authored strings', async () => {
    const css = `/* url("images/sample.png") @import "theme.css"; 10vw -epub-page-break-before */
p::after { content: "url('images/sample.png') 10vw -epub-page-break-before"; }
p { width: 10vw; height: 10vh; -epub-writing-mode: vertical-rl; page-break-before: always; }`
    await withStylesheet(css, [image('images/sample.png'), { href: 'OPS/theme.css', mediaType: 'text/css' }], (output, loaded) => {
        assert.deepEqual(loaded, [])
        assert.equal(output, css.replace(
            'width: 10vw; height: 10vh; -epub-writing-mode: vertical-rl; page-break-before: always;',
            'width: 80px; height: 60px; writing-mode: vertical-rl; -webkit-column-break-before: always;'
        ))
    })
})

test('stylesheet rewriting preserves external URL text during layout adaptation', async () => {
    const css = 'p { background: url("https://cdn.example/10vw/-epub-page-break-before.png"); width: 10vw; }'
    await withStylesheet(css, [], (output, loaded) => {
        assert.deepEqual(loaded, [])
        assert.equal(output, css.replace('width: 10vw', 'width: 80px'))
    })
})

test('stylesheet string imports decode escapes and retain media conditions', async () => {
    await withStylesheet(String.raw`@import 'theme\(draft\).css' screen;`, [
        { href: 'OPS/theme(draft).css', mediaType: 'text/css' },
    ], async (css, loaded) => {
        assert.deepEqual(loaded, [])
        const match = css.match(/^@import "(blob:[^"]+)" screen;$/)
        assert.ok(match, css)
        assert.equal(await (await fetch(match[1])).text(), 'p { color: green; }')
    })
})

test('stylesheet imports preserve intervening comments and URL fragments', async () => {
    await withStylesheet('@import /* keep */ "theme.css#chapter" print;', [
        { href: 'OPS/theme.css', mediaType: 'text/css' },
    ], async (css, loaded) => {
        assert.deepEqual(loaded, [])
        const match = css.match(/^@import \/\* keep \*\/ "(blob:[^"]+#chapter)" print;$/)
        assert.ok(match, css)
        assert.equal(await (await fetch(match[1])).text(), 'p { color: green; }')
    })
})

test('stylesheet rewriting leaves unresolved URLs and other function names intact', async () => {
    const css = 'p { background: url("missing(1).png"); --sample: my-url("images/cover.png"); }'
    await withStylesheet(css, [image('images/cover.png')], (output, loaded) => {
        assert.deepEqual(loaded, [])
        assert.equal(output, css)
    })
})
