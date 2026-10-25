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
