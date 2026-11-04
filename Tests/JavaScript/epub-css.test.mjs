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

test('layout adaptation respects declaration and dimension token boundaries', async () => {
    const css = `.page-break-before, .-epub-marker, .size10vw {
  --label: page-break-before;
  --size: size10vw;
  --unit: 10vwx;
  width: -10vw; height: +10vh; margin: 1e-1vw;
  -epub-writing-mode: vertical-rl; page-break-inside: avoid;
}`
    await withStylesheet(css, [], output => {
        assert.equal(output, css
            .replace('width: -10vw; height: +10vh; margin: 1e-1vw;', 'width: -80px; height: 60px; margin: 0.8px;')
            .replace('-epub-writing-mode:', 'writing-mode:')
            .replace('page-break-inside:', '-webkit-column-break-inside:'))
    })
})

test('CSS URL imports retain layer, supports and media conditions', async () => {
    await withStylesheet('@import url("theme.css?edition=2#part") layer(book) supports(display: grid) print;', [
        { href: 'OPS/theme.css', mediaType: 'text/css' },
    ], async css => {
        const match = css.match(/^@import url\("(blob:[^"]+#part)"\) layer\(book\) supports\(display: grid\) print;$/)
        assert.ok(match, css)
        assert.equal(await (await fetch(match[1])).text(), 'p { color: green; }')
    })
})

test('CSS local fragments and unresolved query references preserve authored spelling', async () => {
    const css = String.raw`p { filter: url(#shade); background: url("missing\(1\).png?v=2#part"); }`
    await withStylesheet(css, [], output => assert.equal(output, css))
})

test('escaped newlines in strings and unterminated comments protect authored text', async () => {
    const css = 'p::after { content: "10vw\\\n-epub-page-break-before"; } /* 10vw url("images/cover.png")'
    await withStylesheet(css, [image('images/cover.png')], (output, loaded) => {
        assert.equal(output, css)
        assert.deepEqual(loaded, [])
    })
})

for (const gap of ['/**/', ' /* one */\t/**/\n /* two */ ']) {
    test(`comment-separated declaration names adapt through the shipping Loader: ${JSON.stringify(gap)}`, async () => {
        const css = `p { page-break-before${gap}: always; -epub-writing-mode${gap}: vertical-rl; -epub-page-break-inside${gap}: avoid; }`
        await withStylesheet(css, [], output => {
            assert.equal(output, `p { -webkit-column-break-before${gap}: always; writing-mode${gap}: vertical-rl; -webkit-column-break-inside${gap}: avoid; }`)
        })
    })
}

test('earlier protected tokens retain declaration context across comments', async () => {
    const css = `@import /* keep */ "https://example.com/book.css" layer(book) screen;
p { content: "keep; { 10vw" /* keep */ page-break-before/**/: sentinel;
  --image: url("https://example.com/10vw") /* keep */ -epub-writing-mode/**/: sentinel;
  /* lead */ page-break-after /* gap */ : always;
  content: "-epub-writing-mode/**/: 10vw";
  background: url("https://example.com/page-break-before/**/:10vw");
  -epub-writing-mode/**/: vertical-rl; width: -1e1vw;
}`
    await withStylesheet(css, [], output => {
        assert.equal(output, css
            .replace('page-break-after /* gap */ :', '-webkit-column-break-after /* gap */ :')
            .replace('-epub-writing-mode/**/: vertical-rl', 'writing-mode/**/: vertical-rl')
            .replace('width: -1e1vw', 'width: -80px'))
    })
})

test('comment-separated selector and value identifiers retain their spelling', async () => {
    const css = `page-break-before/**/:hover, -epub-writing-mode/**/:focus {
  --label: page-break-before/**/:value;
  --another: -epub-writing-mode/**/:value;
  page-break-inside/**/: avoid;
}`
    await withStylesheet(css, [], output => {
        assert.equal(output, css.replace('page-break-inside/**/: avoid', '-webkit-column-break-inside/**/: avoid'))
    })
})


test('escaped brace custom-property values retain writing-mode adaptation', async () => {
    const css = String.raw`p { --mode\{: vertical-rl; -epub-writing-mode: var(--mode\{); }`
    await withStylesheet(css, [], output => {
        assert.equal(output, String.raw`p { --mode\{: vertical-rl; writing-mode: var(--mode\{); }`)
    })
})

for (const identifier of [String.raw`--mode\{`, String.raw`--mode\7b `,
    String.raw`--mode\00007b`, String.raw`--mode\7b` + '\r\n',
    String.raw`--mode\\\{`, String.raw`--mode\5c \{`]) {
    test(`ordinary and hex escaped braces preserve declarations: ${JSON.stringify(identifier)}`, async () => {
        const breakIdentifier = identifier.replace('--mode', '--break')
        const css = `p { ${identifier}: vertical-rl; ${breakIdentifier}: always; -epub-writing-mode/**/: var(${identifier}); page-break-before /*keep*/ : var(${breakIdentifier}); }`
        await withStylesheet(css, [], output => {
            assert.equal(output, css
                .replace('-epub-writing-mode/**/:', 'writing-mode/**/:')
                .replace('page-break-before /*keep*/ :', '-webkit-column-break-before /*keep*/ :'))
        })
    })
}

test('escaped backslashes leave actual selector braces structural', async () => {
    const css = String.raw`page-break-before:hover.tail\\{ -epub-writing-mode/**/: vertical-rl; }
-epub-writing-mode:hover.tail\5c { page-break-before/**/: always; }`
    await withStylesheet(css, [], output => {
        assert.equal(output, String.raw`page-break-before:hover.tail\\{ writing-mode/**/: vertical-rl; }
-epub-writing-mode:hover.tail\5c { -webkit-column-break-before/**/: always; }`)
    })
})

test('unprefixed writing-mode and escaped custom variables remain authored', async () => {
    const css = String.raw`p { --mode\{: vertical-rl; writing-mode/**/: var(--mode\{); }`
    await withStylesheet(css, [], output => assert.equal(output, css))
})
