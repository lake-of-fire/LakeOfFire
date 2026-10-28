import assert from 'node:assert/strict'
import test from 'node:test'
import { Loader } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/epub.js'

// This collaborator models top-level DOM nodes, including detachment. It does
// not establish browser XML parsing or stylesheet application behavior.
class XMLNode {
    constructor(nodeType, raw = '') {
        this.nodeType = nodeType
        this.raw = raw
        this.parentNode = null
    }
    get nextSibling() {
        const siblings = this.parentNode?.childNodes
        return siblings?.[siblings.indexOf(this) + 1] ?? null
    }
    replaceWith(replacement) {
        const parent = this.parentNode
        if (!parent) return
        const index = parent.childNodes.indexOf(this)
        parent.childNodes.splice(index, 1, replacement)
        replacement.parentNode = parent
        this.parentNode = null
    }
}

class XMLProcessingInstruction extends XMLNode {
    constructor(target, data) {
        super(7)
        this.target = target
        this.data = data
    }
}

class XMLDocument {
    constructor(source) {
        this.childNodes = []
        // Fixtures contain no internal DTD subset or nested processing
        // instructions. Preserve every intervening node and its sibling order.
        const tokens = source.match(/<!--[\s\S]*?-->|<!DOCTYPE[^>]*>|<\?[\s\S]*?\?>|[^<]+|<[\s\S]*?>/g) ?? []
        for (const token of tokens) {
            const instruction = /^<\?([^\s?]+)(?:\s+([\s\S]*?))?\?>$/.exec(token)
            const node = instruction
                ? new XMLProcessingInstruction(instruction[1], instruction[2] ?? '')
                : new XMLNode(token.startsWith('<!--') ? 8
                    : token.startsWith('<!DOCTYPE') ? 10 : token.startsWith('<') ? 1 : 3, token)
            node.parentNode = this
            this.childNodes.push(node)
        }
    }
    get firstChild() { return this.childNodes[0] ?? null }
    get documentElement() { return this.childNodes.find(node => node.nodeType === 1) ?? null }
    createProcessingInstruction(target, data) { return new XMLProcessingInstruction(target, data) }
    querySelector() { return null }
    querySelectorAll() { return [] }
    getElementsByTagName() { return [] }
}

const svgItem = { href: 'OPS/cover.svg', mediaType: 'image/svg+xml' }
const stylesheet = name => ({ href: `OPS/${name}`, mediaType: 'text/css' })
const serialize = doc => doc.childNodes.map(node => node.nodeType === 7
    ? `<?${node.target}${node.data ? ` ${node.data}` : ''}?>`
    : node.raw).join('')

async function withFixture(source, names, operation, { loadStylesheet } = {}) {
    const globals = ['DOMParser', 'ProcessingInstruction', 'XMLSerializer', 'window', '__manabiBlobResourceMap']
    const descriptors = new Map(globals.map(name => [name, Object.getOwnPropertyDescriptor(globalThis, name)]))
    const originalCreate = URL.createObjectURL
    const originalRevoke = URL.revokeObjectURL
    const blobs = new Map()
    const revoked = []
    const reads = []
    let serial = 0
    let loader
    try {
        globalThis.DOMParser = class {
            parseFromString(text, type) {
                assert.equal(type, 'image/svg+xml')
                return new XMLDocument(text)
            }
        }
        globalThis.ProcessingInstruction = XMLProcessingInstruction
        globalThis.XMLSerializer = class { serializeToString(doc) { return serialize(doc) } }
        globalThis.window = { innerWidth: 800, innerHeight: 600 }
        globalThis.__manabiBlobResourceMap = new Map()
        URL.createObjectURL = blob => {
            const url = `blob:stylesheet-${++serial}`
            blobs.set(url, blob)
            return url
        }
        URL.revokeObjectURL = url => { revoked.push(url) }
        loader = new Loader({
            resources: { manifest: [svgItem, ...names.map(stylesheet)] },
            loadText: async href => {
                reads.push(href)
                if (href === svgItem.href) return source
                return loadStylesheet ? loadStylesheet(href) : 'svg { fill: blue }'
            },
            loadBlob: async href => { throw new Error(`Unexpected raw resource: ${href}`) },
        })
        await operation({ loader, reads, revoked, blobs, text: url => blobs.get(url).text() })
    } finally {
        loader?.destroy()
        URL.createObjectURL = originalCreate
        URL.revokeObjectURL = originalRevoke
        for (const [name, descriptor] of descriptors) {
            if (descriptor) Object.defineProperty(globalThis, name, descriptor)
            else delete globalThis[name]
        }
    }
}

test('SVG stylesheet processing traverses comments, doctype and every instruction', async () => {
    const source = '<!--cover--><!DOCTYPE svg><?xml-stylesheet type="text/css" href="one.css"?>'
        + '<?xml-stylesheet href=\'two.css\' media="print"?><svg/>'
    await withFixture(source, ['one.css', 'two.css'], async ({ loader, reads, text, revoked }) => {
        const url = await loader.loadItem(svgItem)
        assert.deepEqual(reads, ['OPS/cover.svg', 'OPS/one.css', 'OPS/two.css'])
        assert.equal(await text(url), '<!--cover--><!DOCTYPE svg>'
            + '<?xml-stylesheet type="text/css" href="blob:stylesheet-1"?>'
            + '<?xml-stylesheet href=\'blob:stylesheet-2\' media="print"?><svg/>')
        loader.unloadItem(svgItem)
        assert.equal(new Set(revoked).size, 3)
        assert.deepEqual(new Set(revoked), new Set(['blob:stylesheet-1', 'blob:stylesheet-2', url]))
        assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
    })
})

test('stylesheet href rewriting preserves pseudoattribute whitespace and ignores decoys inside names and values', async () => {
    const source = '<?xml-stylesheet type="text/css"\tmedia="screen" '
        + 'data-href="wrong.css" title="preview href=\'quoted.css\'"  href = \'real.css\'?><svg/>'
    await withFixture(source, ['wrong.css', 'quoted.css', 'real.css'], async ({ loader, reads, text }) => {
        const url = await loader.loadItem(svgItem)
        assert.deepEqual(reads, ['OPS/cover.svg', 'OPS/real.css'])
        assert.equal(await text(url), '<?xml-stylesheet type="text/css"\tmedia="screen" '
            + 'data-href="wrong.css" title="preview href=\'quoted.css\'"  href = \'blob:stylesheet-1\'?><svg/>')
    })
})

test('single and double quoted href values both resolve without altering their quotes', async () => {
    for (const quote of ['"', "'"]) {
        const source = `<?xml-stylesheet href=${quote}one.css${quote} type="text/css"?><svg/>`
        await withFixture(source, ['one.css'], async ({ loader, reads, text }) => {
            const url = await loader.loadItem(svgItem)
            assert.equal(await text(url), `<?xml-stylesheet href=${quote}blob:stylesheet-1${quote} type="text/css"?><svg/>`)
            assert.deepEqual(reads, ['OPS/cover.svg', 'OPS/one.css'])
        })
    }
})

test('only stylesheet instructions in the prolog can introduce resource dependencies', async () => {
    const source = '<!--creator--><?editor href="editor.css"?>'
        + '<?xml-stylesheet HREF="uppercase.css"?>'
        + '<?xml-stylesheet href="real.css"?><svg/>'
        + '<?xml-stylesheet href="trailing.css"?>'
    await withFixture(source, ['editor.css', 'uppercase.css', 'real.css', 'trailing.css'],
        async ({ loader, reads, text }) => {
            const url = await loader.loadItem(svgItem)
            assert.deepEqual(reads, ['OPS/cover.svg', 'OPS/real.css'])
            assert.equal(await text(url), '<!--creator--><?editor href="editor.css"?>'
                + '<?xml-stylesheet HREF="uppercase.css"?>'
                + '<?xml-stylesheet href="blob:stylesheet-1"?><svg/>'
                + '<?xml-stylesheet href="trailing.css"?>')
        }, {
            loadStylesheet: href => {
                assert.equal(href, 'OPS/real.css', 'non-stylesheet metadata must not request resources')
                return 'svg { fill: blue }'
            },
        })
})

test('stylesheet href references decode once before exact manifest lookup and fragment splitting', async t => {
    const cases = [
        ['theme&amp;night.css', 'theme&night.css', ''],
        ['reader&apos;s.css', "reader's.css", ''],
        ['theme&#46;css', 'theme.css', ''],
        ['theme&#x2E;css', 'theme.css', ''],
        ['flower&#x1F338;.css', 'flower🌸.css', ''],
        ['one.css&#35;chapter', 'one.css', '#chapter'],
        ['literal&amp;amp;.css', 'literal&amp;.css', ''],
    ]
    for (const [encoded, filename, fragment] of cases) {
        await t.test(encoded, async () => {
            const source = `<?xml-stylesheet href="${encoded}" type="text/css"?><svg/>`
            // A wrong split at the '#' inside a numeric reference must not select
            // the deliberately competing theme& / one.css& manifest resources.
            await withFixture(source, [filename, 'theme&', 'one.css&'],
                async ({ loader, reads, text, revoked, blobs }) => {
                    const url = await loader.loadItem(svgItem)
                    assert.deepEqual(reads, ['OPS/cover.svg', `OPS/${filename}`], encoded)
                    assert.equal(await text(url), `<?xml-stylesheet href="blob:stylesheet-1${fragment}" type="text/css"?><svg/>`, encoded)
                    loader.unloadItem(svgItem)
                    assert.deepEqual(new Set(revoked), new Set(blobs.keys()), encoded)
                    assert.equal(revoked.length, 2, encoded)
                    assert.equal(globalThis.__manabiBlobResourceMap.size, 0, encoded)
                })
        })
    }
})

test('rewritten href fragments retain valid XML quoting and ampersand escaping', async t => {
    const cases = [
        ["'", 'reader&apos;s&amp;page', 'reader&apos;s&amp;page'],
        ['"', 'reader&quot;s&amp;page', 'reader&quot;s&amp;page'],
        ['"', 'reader&apos;s&amp;page', "reader's&amp;page"],
        ["'", 'reader&quot;s&amp;page', 'reader"s&amp;page'],
        ['"', 'chapter&#38;part', 'chapter&amp;part'],
        ['"', 'tail?&gt;next', 'tail?&gt;next'],
    ]
    for (const [quote, encoded, escaped] of cases) {
        await t.test(`${quote} ${encoded}`, async () => {
            const source = `<?xml-stylesheet href=${quote}one.css#${encoded}${quote}?><svg/>`
            await withFixture(source, ['one.css'], async ({ loader, reads, text }) => {
                const url = await loader.loadItem(svgItem)
                assert.deepEqual(reads, ['OPS/cover.svg', 'OPS/one.css'])
                // Both spellings represent the same value. Do not require cosmetic
                // canonicalization of an opposite quote or an XML reference.
                const validOutputs = [escaped, encoded].map(fragment =>
                    `<?xml-stylesheet href=${quote}blob:stylesheet-1#${fragment}${quote}?><svg/>`)
                assert.ok(validOutputs.includes(await text(url)))
            })
        })
    }
})

test('unknown or invalid XML references and unchanged hrefs preserve their original lexical form', async t => {
    const values = [
        'https://example.test/theme.css?a=1&amp;b=2',
        '&#x68;ttps://example.test/theme.css',
        'missing&amp;theme.css',
        '#reader&apos;s&amp;page',
        'bad&custom;.css',
        'bad&#0;.css',
        'bad&#xD800;.css',
        'bad&#x110000;.css',
        'bad&#xFFFE;.css',
        'bad&#X2E;.css',
    ]
    for (const value of values) {
        await t.test(value, async () => {
            const source = `<?xml-stylesheet href="${value}" title="literal &amp; metadata"?><svg/>`
            // These trap resources would be selected by partial/invalid decoding or
            // by treating the raw invalid href as a valid package resource.
            await withFixture(source, ['bad&custom;.css', 'bad&', 'bad\uFFFD.css'],
                async ({ loader, reads, text }) => {
                    const url = await loader.loadItem(svgItem)
                    assert.deepEqual(reads, ['OPS/cover.svg'], value)
                    assert.equal(await text(url), source, value)
                })
        })
    }
})

test('a suspended second stylesheet failure rolls back earlier children and permits a fresh complete retry', async () => {
    let failSecond = true
    let rejectSecond
    let signalSecondStarted
    const secondStarted = new Promise(resolve => { signalSecondStarted = resolve })
    const source = '<?xml-stylesheet href="one.css"?><?xml-stylesheet href="two.css"?><svg/>'
    await withFixture(source, ['one.css', 'two.css'], async ({ loader, reads, revoked, text }) => {
        const firstLoad = loader.loadItem(svgItem)
        // A traversal regression must fail promptly rather than leave this test
        // suspended forever waiting for an instruction that was skipped.
        await Promise.race([
            secondStarted,
            firstLoad.then(() => assert.fail('SVG published before loading its second stylesheet')),
        ])
        // Install the rejection assertion before releasing the deferred failure.
        const failedLoad = assert.rejects(firstLoad, /stylesheet unavailable/)
        assert.deepEqual(revoked, [])
        rejectSecond(new Error('stylesheet unavailable'))
        await failedLoad
        assert.deepEqual(revoked, ['blob:stylesheet-1'])
        assert.equal(globalThis.__manabiBlobResourceMap.size, 0)

        failSecond = false
        const retryURL = await loader.loadItem(svgItem)
        assert.equal(await text(retryURL), '<?xml-stylesheet href="blob:stylesheet-2"?>'
            + '<?xml-stylesheet href="blob:stylesheet-3"?><svg/>')
        assert.deepEqual(reads, ['OPS/cover.svg', 'OPS/one.css', 'OPS/two.css',
            'OPS/cover.svg', 'OPS/one.css', 'OPS/two.css'])
        loader.unloadItem(svgItem)
        assert.deepEqual(new Set(revoked), new Set(['blob:stylesheet-1', 'blob:stylesheet-2', 'blob:stylesheet-3', retryURL]))
        assert.equal(revoked.length, 4)
        assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
    }, {
        loadStylesheet: href => {
            if (href === 'OPS/two.css' && failSecond) {
                signalSecondStarted()
                return new Promise((_resolve, reject) => { rejectSecond = reject })
            }
            return 'svg { fill: blue }'
        },
    })
})

test('concurrent SVG loads coalesce publication and retain exact stylesheet ownership until final unload', async () => {
    const source = '<?xml-stylesheet href="one.css"?><?xml-stylesheet href="two.css"?><svg/>'
    await withFixture(source, ['one.css', 'two.css'], async ({ loader, reads, revoked, blobs }) => {
        const [first, second] = await Promise.all([loader.loadItem(svgItem), loader.loadItem(svgItem)])
        assert.equal(first, second)
        assert.equal(blobs.size, 3)
        assert.deepEqual(reads, ['OPS/cover.svg', 'OPS/one.css', 'OPS/two.css'])
        loader.unloadItem(svgItem)
        assert.deepEqual(revoked, [])
        loader.unloadItem(svgItem)
        assert.deepEqual(new Set(revoked), new Set(blobs.keys()))
        assert.equal(revoked.length, 3)
        assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
        assert.equal(loader.destroy(), true)
        assert.equal(loader.destroy(), false)
        assert.equal(revoked.length, 3)
    })
})

test('destroy releases the SVG and all PI children exactly once while references remain', async () => {
    const source = '<?xml-stylesheet href="one.css"?><?xml-stylesheet href="two.css"?><svg/>'
    await withFixture(source, ['one.css', 'two.css'], async ({ loader, revoked, blobs }) => {
        await Promise.all([loader.loadItem(svgItem), loader.loadItem(svgItem)])
        assert.equal(loader.destroy(), true)
        assert.deepEqual(new Set(revoked), new Set(blobs.keys()))
        assert.equal(revoked.length, 3)
        assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
        loader.unloadItem(svgItem)
        assert.equal(await loader.loadItem(svgItem), null)
        assert.equal(loader.destroy(), false)
        assert.equal(revoked.length, 3)
    })
})

test('destroy during a suspended PI stylesheet retires both callers without late publication', { timeout: 5000 }, async () => {
    for (const rejects of [false, true]) {
        let resolveSecond
        let rejectSecond
        let signalSecondStarted
        const secondStarted = new Promise(resolve => { signalSecondStarted = resolve })
        const source = '<?xml-stylesheet href="one.css"?><?xml-stylesheet href="two.css"?><svg/>'
        await withFixture(source, ['one.css', 'two.css'], async ({ loader, reads, revoked, blobs }) => {
            const first = loader.loadItem(svgItem)
            const joined = loader.loadItem(svgItem)
            // Observe both rejections before releasing the suspended child.
            const terminal = Promise.allSettled([first, joined])
            await Promise.race([
                secondStarted,
                terminal.then(() => assert.fail('SVG settled before its second stylesheet started')),
            ])
            assert.deepEqual([...blobs.keys()], ['blob:stylesheet-1'])
            assert.deepEqual(revoked, [])
            assert.equal(globalThis.__manabiBlobResourceMap.size, 1)
            assert.equal(loader.destroy(), true)
            assert.deepEqual(revoked, ['blob:stylesheet-1'])
            assert.equal(globalThis.__manabiBlobResourceMap.size, 0)

            const failure = new Error('late stylesheet failure')
            if (rejects) rejectSecond(failure)
            else resolveSecond('svg { fill: blue }')
            for (const result of await terminal) {
                if (rejects) {
                    assert.equal(result.status, 'rejected')
                    assert.equal(result.reason, failure)
                } else {
                    assert.equal(result.status, 'fulfilled')
                    assert.ok(!result.value, 'a retired caller must not receive a resource URL')
                }
            }
            assert.deepEqual(reads, ['OPS/cover.svg', 'OPS/one.css', 'OPS/two.css'])
            assert.deepEqual([...blobs.keys()], ['blob:stylesheet-1'], 'no child or parent publishes after destroy')
            assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
            loader.unloadItem(svgItem)
            assert.equal(await loader.loadItem(svgItem), null)
            assert.equal(loader.destroy(), false)
            assert.deepEqual(revoked, ['blob:stylesheet-1'], 'the first child is revoked exactly once')
        }, {
            loadStylesheet: href => {
                if (href !== 'OPS/two.css') return 'svg { fill: blue }'
                return new Promise((resolve, reject) => {
                    resolveSecond = resolve
                    rejectSecond = reject
                    signalSecondStarted()
                })
            },
        })
    }
})
