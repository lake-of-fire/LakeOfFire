import assert from 'node:assert/strict'
import test from 'node:test'

import { EPUB, Loader } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/epub.js'

const deferred = () => {
    let resolve
    let reject
    const promise = new Promise((resolvePromise, rejectPromise) => {
        resolve = resolvePromise
        reject = rejectPromise
    })
    return { promise, resolve, reject }
}

const installObjectURLHarness = t => {
    const originalCreateObjectURL = URL.createObjectURL
    const originalRevokeObjectURL = URL.revokeObjectURL
    const originalResourceMap = globalThis.__manabiBlobResourceMap
    const created = []
    const revoked = []
    const blobs = new Map()
    URL.createObjectURL = blob => {
        const url = `blob:test-${created.length + 1}`
        created.push(url)
        blobs.set(url, blob)
        return url
    }
    URL.revokeObjectURL = url => revoked.push(url)
    globalThis.__manabiBlobResourceMap = new Map()
    t.after(() => {
        URL.createObjectURL = originalCreateObjectURL
        URL.revokeObjectURL = originalRevokeObjectURL
        if (originalResourceMap === undefined) {
            delete globalThis.__manabiBlobResourceMap
        } else {
            globalThis.__manabiBlobResourceMap = originalResourceMap
        }
    })
    return { created, revoked, blobs }
}

const makeLoader = ({ item, loadBlob }) => new Loader({
    loadText: async () => '',
    loadBlob,
    resources: { manifest: [item] },
})

const installMinimalEPUBPackageDOMHarness = (t, {
    rootfilePath = 'OPS/package.opf',
    itemHref = 'chapter.xhtml',
    itemMediaType = 'application/xhtml+xml',
    encryptionURI = null,
} = {}) => {
    const originalDOMParser = globalThis.DOMParser
    const CONTAINER = 'urn:oasis:names:tc:opendocument:xmlns:container'
    const OPF = 'http://www.idpf.org/2007/opf'
    const DC = 'http://purl.org/dc/elements/1.1/'
    const ENC = 'http://www.w3.org/2001/04/xmlenc#'

    class FakeElement {
        nodeType = 1
        constructor(namespaceURI, localName, attributes = {}, children = []) {
            this.namespaceURI = namespaceURI
            this.localName = localName
            this.attributes = new Map(Object.entries(attributes))
            this.childNodes = children
            this.textContent = ''
            for (const child of children) child.parentNode = this
        }
        get children() { return this.childNodes.filter(node => node.nodeType === 1) }
        get id() { return this.getAttribute('id') ?? '' }
        getAttribute(name) { return this.attributes.get(name) ?? null }
        getAttributeNS(_namespace, name) { return this.getAttribute(name) }
        getElementsByTagNameNS(namespace, name) {
            return this.#descendants().filter(element => (
                element.namespaceURI === namespace && element.localName === name
            ))
        }
        getElementsByTagName(name) {
            return this.#descendants().filter(element => element.localName === name)
        }
        #descendants() {
            return this.children.flatMap(child => [child, ...child.#descendants()])
        }
    }

    class FakeDocument {
        nodeType = 9
        constructor(documentElement, defaultNamespace) {
            this.documentElement = documentElement
            this.defaultNamespace = defaultNamespace
            this.childNodes = [documentElement]
            documentElement.parentNode = this
            this.#installOwner(documentElement)
        }
        #installOwner(element) {
            element.ownerDocument = this
            for (const child of element.children) this.#installOwner(child)
        }
        lookupNamespaceURI(prefix) {
            return prefix == null ? this.defaultNamespace : null
        }
        lookupPrefix() { return null }
        querySelector() { return null }
        getElementsByTagNameNS(namespace, name) {
            const root = this.documentElement
            return [root, ...root.getElementsByTagNameNS(namespace, name)]
                .filter(element => (
                    element.namespaceURI === namespace && element.localName === name
                ))
        }
        getElementsByTagName(name) {
            const root = this.documentElement
            return [root, ...root.getElementsByTagName(name)]
                .filter(element => element.localName === name)
        }
        getElementById(id) {
            if (!id) return null
            return this.getElementsByTagName('*')
                .find(element => element.id === id) ?? null
        }
    }

    const element = (namespace, name, attributes = {}, children = []) => (
        new FakeElement(namespace, name, attributes, children)
    )
    const identifier = element(DC, 'identifier', { id: 'uid' })
    identifier.textContent = 'book-id'
    const packageDocument = new FakeDocument(
        element(OPF, 'package', { 'unique-identifier': 'uid' }, [
            element(OPF, 'metadata', {}, [identifier]),
            element(OPF, 'manifest', {}, [
                element(OPF, 'item', {
                    id: 'chapter',
                    href: itemHref,
                    'media-type': itemMediaType,
                }),
            ]),
            element(OPF, 'spine', {}, [
                element(OPF, 'itemref', { idref: 'chapter' }),
            ]),
        ]),
        OPF,
    )
    const containerDocument = new FakeDocument(
        element(CONTAINER, 'container', {}, [
            element(CONTAINER, 'rootfiles', {}, [
                element(CONTAINER, 'rootfile', {
                    'full-path': rootfilePath,
                    'media-type': 'application/oebps-package+xml',
                }),
            ]),
        ]),
        CONTAINER,
    )
    const documents = new Map([
        ['minimal-container', containerDocument],
        ['minimal-package', packageDocument],
    ])
    if (encryptionURI) {
        documents.set('minimal-encryption', new FakeDocument(
            element(ENC, 'encryption', {}, [
                element(ENC, 'EncryptedData', {}, [
                    element(ENC, 'EncryptionMethod', {
                        Algorithm: 'http://www.idpf.org/2008/embedding',
                    }),
                    element(ENC, 'CipherReference', { URI: encryptionURI }),
                ]),
            ]),
            ENC,
        ))
    }

    globalThis.DOMParser = class {
        parseFromString(source) {
            const document = documents.get(source)
            if (!document) throw new Error(`unexpected XML source: ${source}`)
            return document
        }
    }
    t.after(() => {
        if (originalDOMParser === undefined) delete globalThis.DOMParser
        else globalThis.DOMParser = originalDOMParser
    })
}

const installReplacementDOMHarness = (t, elements) => {
    const originals = {
        DOMParser: globalThis.DOMParser,
        XMLSerializer: globalThis.XMLSerializer,
        ProcessingInstruction: globalThis.ProcessingInstruction,
        window: globalThis.window,
    }
    const restore = (name, value) => {
        if (value === undefined) delete globalThis[name]
        else globalThis[name] = value
    }

    class FakeElement {
        constructor(
            localName,
            attributes = {},
            namespaceURI = null,
            namespacedAttributes = {},
        ) {
            this.localName = localName
            this.namespaceURI = namespaceURI
            this.attributes = new Map(Object.entries(attributes))
            this.namespacedAttributes = new Map(Object.entries(namespacedAttributes))
            this.textContent = ''
        }
        getAttribute(name) { return this.attributes.get(name) ?? null }
        setAttribute(name, value) { this.attributes.set(name, String(value)) }
        hasAttribute(name) { return this.attributes.has(name) }
        #namespacedKey(namespace, name) { return `${namespace}|${name}` }
        hasAttributeNS(namespace, name) {
            return this.namespacedAttributes.has(this.#namespacedKey(namespace, name))
        }
        getAttributeNS(namespace, name) {
            return this.namespacedAttributes.get(this.#namespacedKey(namespace, name)) ?? null
        }
        setAttributeNS(namespace, name, value) {
            this.namespacedAttributes.set(
                this.#namespacedKey(namespace, name),
                String(value),
            )
        }
    }

    class FakeProcessingInstruction {
        constructor(target, data) {
            this.target = target
            this.data = data
        }
        replaceWith(replacement) {
            this.target = replacement.target
            this.data = replacement.data
        }
    }

    const documentElement = new FakeElement(
        'svg',
        {},
        'http://www.w3.org/2000/svg',
    )
    const document = {
        documentElement,
        childNodes: [],
        firstChild: null,
        querySelector: () => null,
        querySelectorAll: selector => {
            const match = /^(?:([a-z]+))?\[([a-z]+)\]$/.exec(selector)
            if (!match) return []
            const [, localName, attribute] = match
            return elements.filter(element => (
                (!localName || element.localName === localName)
                && element.hasAttribute(attribute)
            ))
        },
        getElementsByTagName: name => name === '*' ? elements : [],
        createProcessingInstruction: (target, data) => (
            new FakeProcessingInstruction(target, data)
        ),
    }

    globalThis.DOMParser = class {
        parseFromString() { return document }
    }
    globalThis.XMLSerializer = class {
        serializeToString() {
            return elements
                .map(element => `${element.localName}:${
                    element.getAttribute('href')
                    ?? element.getAttributeNS(
                        'http://www.w3.org/1999/xlink',
                        'href',
                    )
                    ?? ''
                }`)
                .join('|')
        }
    }
    globalThis.ProcessingInstruction = FakeProcessingInstruction
    globalThis.window = { innerWidth: 800, innerHeight: 600 }
    t.after(() => {
        for (const [name, value] of Object.entries(originals)) restore(name, value)
    })
    return { FakeElement, FakeProcessingInstruction, document }
}

test('EPUB loader coalesces concurrent same-resource commits into one ref-counted URL', async t => {
    const { created, revoked } = installObjectURLHarness(t)
    const blob = deferred()
    let markLoadStarted
    let loadCount = 0
    const loadStarted = new Promise(resolve => { markLoadStarted = resolve })
    const item = { href: 'OPS/image.png', mediaType: 'image/png' }
    const loader = makeLoader({
        item,
        loadBlob: async () => {
            loadCount += 1
            markLoadStarted()
            return await blob.promise
        },
    })

    const first = loader.loadItem(item)
    const second = loader.loadItem(item)
    await loadStarted
    assert.equal(loadCount, 1)

    blob.resolve(new Uint8Array([1, 2, 3]))
    const [firstURL, secondURL] = await Promise.all([first, second])

    assert.equal(firstURL, secondURL)
    assert.deepEqual(created, [firstURL])
    assert.equal(globalThis.__manabiBlobResourceMap.has(firstURL), true)

    loader.unloadItem(item)
    assert.deepEqual(revoked, [])
    loader.unloadItem(item)
    assert.deepEqual(revoked, [firstURL])
    assert.equal(globalThis.__manabiBlobResourceMap.has(firstURL), false)
})

test('EPUB loader settles an in-flight and later load as null after terminal destruction', async t => {
    const { created, revoked } = installObjectURLHarness(t)
    const blob = deferred()
    const item = { href: 'OPS/image.png', mediaType: 'image/png' }
    const loader = makeLoader({ item, loadBlob: async () => await blob.promise })

    const inFlight = loader.loadItem(item)
    assert.equal(loader.destroy(), true)
    blob.resolve(new Uint8Array([1, 2, 3]))

    assert.equal(await inFlight, null)
    assert.equal(await loader.loadItem(item), null)
    assert.deepEqual(created, [])
    assert.deepEqual(revoked, [])
})

test('EPUB loader returns null when a URL is revoked between worker commit and caller resumption', async t => {
    const { created, revoked } = installObjectURLHarness(t)
    const createObjectURL = URL.createObjectURL
    const item = { href: 'OPS/image.png', mediaType: 'image/png' }
    let loader = null
    URL.createObjectURL = value => {
        const url = createObjectURL(value)
        // Model teardown already queued behind the uncached worker but ahead of
        // the initiating loadItem continuation. The committed URL is revoked by
        // destroy and must never escape as a successful load result.
        queueMicrotask(() => loader.destroy())
        return url
    }
    loader = makeLoader({
        item,
        loadBlob: async () => new Uint8Array([1, 2, 3]),
    })

    assert.equal(await loader.loadItem(item), null)
    assert.equal(created.length, 1)
    assert.deepEqual(revoked, created)
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})

test('EPUB loader destruction revokes and forgets committed resources exactly once', async t => {
    const { created, revoked } = installObjectURLHarness(t)
    const item = { href: 'OPS/image.png', mediaType: 'image/png' }
    const loader = makeLoader({
        item,
        loadBlob: async () => new Uint8Array([1, 2, 3]),
    })

    const url = await loader.loadItem(item)
    assert.deepEqual(created, [url])
    assert.equal(globalThis.__manabiBlobResourceMap.has(url), true)

    loader.destroy()
    loader.destroy()
    loader.unloadItem(item)

    assert.deepEqual(revoked, [url])
    assert.equal(globalThis.__manabiBlobResourceMap.has(url), false)
})

test('EPUB loader releases child resources when a replaced parent fails', async t => {
    const { created, revoked } = installObjectURLHarness(t)
    const originalWindow = globalThis.window
    globalThis.window = { innerWidth: 800, innerHeight: 600 }
    t.after(() => {
        if (originalWindow === undefined) delete globalThis.window
        else globalThis.window = originalWindow
    })

    const parent = { href: 'OPS/styles.css', mediaType: 'text/css' }
    const child = { href: 'OPS/child.png', mediaType: 'image/png' }
    const loader = new Loader({
        loadText: async href => {
            assert.equal(href, parent.href)
            return 'body { background: url("child.png"); }'
        },
        loadBlob: async href => {
            assert.equal(href, child.href)
            return new Uint8Array([1, 2, 3])
        },
        resources: { manifest: [parent, child] },
    })

    const originalCreateObjectURL = URL.createObjectURL
    URL.createObjectURL = value => {
        if (created.length === 0) return originalCreateObjectURL(value)
        throw new Error('parent object URL creation failed')
    }

    await assert.rejects(loader.loadItem(parent), /parent object URL creation failed/)
    assert.equal(created.length, 1)
    assert.deepEqual(revoked, [created[0]])
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)

    loader.unloadItem(parent)
    assert.deepEqual(revoked, [created[0]])
})

test('EPUB loader preserves valid zero-length text resources', async t => {
    const { blobs, revoked } = installObjectURLHarness(t)
    const item = { href: 'OPS/empty.js', mediaType: 'text/javascript' }
    const loader = new Loader({
        loadText: async href => {
            assert.equal(href, item.href)
            return ''
        },
        loadBlob: async () => {
            throw new Error('zero-length script must use the text loader')
        },
        resources: { manifest: [item] },
    })
    loader.allowScript = true

    const url = await loader.loadItem(item)
    assert.match(url, /^blob:test-\d+$/)
    assert.equal(await blobs.get(url).text(), '')

    loader.unloadItem(item)
    assert.deepEqual(revoked, [url])
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})

test('EPUB loader breaks circular replacement ownership without retaining a ref-count cycle', async t => {
    const { created, revoked } = installObjectURLHarness(t)
    const originalWindow = globalThis.window
    globalThis.window = { innerWidth: 800, innerHeight: 600 }
    t.after(() => {
        if (originalWindow === undefined) delete globalThis.window
        else globalThis.window = originalWindow
    })

    const item = { href: 'OPS/styles.css', mediaType: 'text/css' }
    let blobLoadCount = 0
    const loader = new Loader({
        loadText: async () => '@import "styles.css"; body { display: block; }',
        loadBlob: async href => {
            assert.equal(href, item.href)
            blobLoadCount += 1
            return new Uint8Array([1, 2, 3])
        },
        resources: { manifest: [item] },
    })

    const url = await loader.loadItem(item)
    assert.equal(blobLoadCount, 1)
    assert.equal(created.length, 2)
    assert.equal(url, created[1])
    assert.equal(globalThis.__manabiBlobResourceMap.size, 2)

    loader.unloadItem(item)
    assert.deepEqual(revoked, [created[1], created[0]])
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})

test('EPUB script replacement preserves and resolves exact root-relative asset references', async t => {
    const { blobs } = installObjectURLHarness(t)
    const parent = { href: 'OPS/app.js', mediaType: 'text/javascript' }
    const child = { href: 'OPS/image.png', mediaType: 'image/png' }
    const longerChild = { href: 'OPS/image.png.map', mediaType: 'application/json' }
    const loader = new Loader({
        loadText: async href => {
            assert.equal(href, parent.href)
            return [
                'const relative = "image.png";',
                'const explicitRelative = "./image.png";',
                'const root = "/OPS/image.png";',
                'const longer = "image.png.map";',
            ].join(' ')
        },
        loadBlob: async href => {
            assert.equal([child.href, longerChild.href].includes(href), true)
            return new Uint8Array([1, 2, 3])
        },
        resources: { manifest: [parent, child, longerChild] },
    })
    loader.allowScript = true

    const parentURL = await loader.loadItem(parent)
    const replaced = await blobs.get(parentURL).text()
    const childURL = [...globalThis.__manabiBlobResourceMap.entries()]
        .find(([, resource]) => resource.href === child.href)?.[0]
    const longerChildURL = [...globalThis.__manabiBlobResourceMap.entries()]
        .find(([, resource]) => resource.href === longerChild.href)?.[0]

    assert.equal(typeof childURL, 'string')
    assert.equal(typeof longerChildURL, 'string')
    assert.equal(
        replaced,
        [
            `const relative = "${childURL}";`,
            `const explicitRelative = "${childURL}";`,
            `const root = "${childURL}";`,
            `const longer = "${longerChildURL}";`,
        ].join(' ')
    )
    assert.equal(replaced.includes('"null"'), false)

    loader.unloadItem(parent)
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})

test('EPUB resolves the container rootfile as a one-pass package URL', async t => {
    installMinimalEPUBPackageDOMHarness(t, {
        rootfilePath: 'OPS/package%252Fname%20x.opf',
    })
    const requested = []
    const epub = new EPUB({
        loadText: async href => {
            requested.push(href)
            if (href === 'META-INF/container.xml') return 'minimal-container'
            if (href === 'OPS/package%2Fname x.opf') return 'minimal-package'
            if (href === 'META-INF/encryption.xml') return null
            return null
        },
        loadBlob: async () => new Uint8Array(),
        getSize: () => 1,
    })

    await epub.init()

    assert.equal(epub.sections.length, 1)
    assert.equal(requested.includes('OPS/package%2Fname x.opf'), true)
    assert.equal(requested.includes('OPS/package%252Fname%20x.opf'), false)
})

test('EPUB rejects a container rootfile outside package URL space', async t => {
    installMinimalEPUBPackageDOMHarness(t, {
        rootfilePath: 'web+epub:external.opf',
    })
    const requested = []
    const epub = new EPUB({
        loadText: async href => {
            requested.push(href)
            return href === 'META-INF/container.xml' ? 'minimal-container' : null
        },
        loadBlob: async () => new Uint8Array(),
        getSize: () => 1,
    })

    await assert.rejects(epub.init(), /Invalid package document path/)
    assert.deepEqual(requested, ['META-INF/container.xml'])
})

test('EPUB resolves encryption references with the same one-pass package identity', async t => {
    const { blobs } = installObjectURLHarness(t)
    installMinimalEPUBPackageDOMHarness(t, {
        itemHref: 'image%20x.png',
        itemMediaType: 'image/png',
        encryptionURI: 'OPS/image%20x.png',
    })
    const loaded = []
    const epub = new EPUB({
        loadText: async href => {
            if (href === 'META-INF/container.xml') return 'minimal-container'
            if (href === 'OPS/package.opf') return 'minimal-package'
            if (href === 'META-INF/encryption.xml') return 'minimal-encryption'
            return null
        },
        loadBlob: async href => {
            loaded.push(href)
            return new Blob([new Uint8Array([0x40])], { type: 'image/png' })
        },
        getSize: () => 1,
        sha1: async () => new Uint8Array([0x01]),
    })

    await epub.init()
    const url = await epub.sections[0].load()
    const bytes = new Uint8Array(await blobs.get(url).arrayBuffer())

    assert.deepEqual(loaded, ['OPS/image x.png'])
    assert.deepEqual([...bytes], [0x41])
    epub.sections[0].unload()
    epub.destroy()
})

test('EPUB section resolution preserves outbound query strings while normalizing container resources', async t => {
    installMinimalEPUBPackageDOMHarness(t)
    const epub = new EPUB({
        loadText: async href => {
            if (href === 'META-INF/container.xml') return 'minimal-container'
            if (href === 'OPS/package.opf') return 'minimal-package'
            if (href === 'META-INF/encryption.xml') return null
            throw new Error(`unexpected EPUB resource: ${href}`)
        },
        loadBlob: async () => new Uint8Array(),
        getSize: () => 1,
    })
    await epub.init()

    const resolve = epub.sections[0].resolveHref
    assert.equal(
        resolve('https://example.com/read?token=abc#page'),
        'https://example.com/read?token=abc#page',
    )
    assert.equal(
        resolve('https://example.com/read?token=a%2520b&label=a%20b#page'),
        'https://example.com/read?token=a%2520b&label=a%20b#page',
    )
    assert.equal(
        resolve('//cdn.example/read?token=abc#page'),
        'https://cdn.example/read?token=abc#page',
    )
    assert.equal(
        resolve('  https://example.com/read?token=abc#page  '),
        'https://example.com/read?token=abc#page',
    )
    assert.equal(
        resolve('\t//cdn.example/read?token=abc#page\n'),
        'https://cdn.example/read?token=abc#page',
    )
    assert.equal(
        resolve('mailto:reader@example.com?subject=EPUB'),
        'mailto:reader@example.com?subject=EPUB',
    )
    assert.equal(
        resolve('./chapter.xhtml?cache=1#local'),
        'OPS/chapter.xhtml#local',
    )

    epub.destroy()
})

test('EPUB Loader preserves non-ASCII edge whitespace in package resource names', async t => {
    installObjectURLHarness(t)
    const exact = {
        href: 'OPS/\u00A0image.png\u00A0',
        mediaType: 'image/png',
    }
    const trimmedSibling = {
        href: 'OPS/image.png',
        mediaType: 'image/png',
    }
    const self = {
        href: 'OPS/\u00A0art.svg\u00A0',
        mediaType: 'image/svg+xml',
    }
    const ASCIITrimmedBaseTarget = {
        href: 'OPS/base-image.png',
        mediaType: 'image/png',
    }
    const loaded = []
    const loader = new Loader({
        loadText: async () => '',
        loadBlob: async href => {
            loaded.push(href)
            return new Uint8Array([1, 2, 3])
        },
        resources: {
            manifest: [exact, trimmedSibling, self, ASCIITrimmedBaseTarget],
        },
    })

    const exactURL = await loader.loadHref(
        '\u00A0image.png\u00A0',
        'OPS/chapter.xhtml',
    )
    assert.match(exactURL, /^blob:test-\d+$/)
    assert.deepEqual(loaded, [exact.href])
    assert.equal(
        await loader.loadHref('./\u00A0art.svg\u00A0#paint', self.href),
        '#paint',
    )

    const siblingURL = await loader.loadHref(
        ' image.png ',
        'OPS/chapter.xhtml',
    )
    assert.match(siblingURL, /^blob:test-\d+$/)
    assert.deepEqual(loaded, [exact.href, trimmedSibling.href])

    const ASCIIBaseURL = await loader.loadHref(
        'base-image.png',
        ' \tOPS/chapter.xhtml\r\n',
    )
    assert.match(ASCIIBaseURL, /^blob:test-\d+$/)
    assert.deepEqual(loaded, [
        exact.href,
        trimmedSibling.href,
        ASCIITrimmedBaseTarget.href,
    ])

    loader.unloadItem(exact)
    loader.unloadItem(trimmedSibling)
    loader.unloadItem(ASCIITrimmedBaseTarget)
    loader.destroy()
})

test('EPUB Loader resolves remote fallbacks without inventing missing package assets', async () => {
    const loader = new Loader({
        loadText: async () => '',
        loadBlob: async () => new Uint8Array(),
        resources: { manifest: [] },
    })

    assert.equal(
        await loader.loadHref(
            '//cdn.example/assets/image.png?revision=2#hero',
            'OPS/chapter.xhtml',
        ),
        'https://cdn.example/assets/image.png?revision=2#hero',
    )
    assert.equal(
        await loader.loadHref(
            './fonts/reader.woff2?revision=2#font',
            'https://cdn.example/styles/book.css',
        ),
        'https://cdn.example/styles/fonts/reader.woff2?revision=2#font',
    )
    assert.equal(
        await loader.loadHref('./missing.png?revision=2#local', 'OPS/chapter.xhtml'),
        './missing.png?revision=2#local',
    )

    loader.destroy()
})

test('EPUB Loader keeps current-document fragments local without transient self copies', async t => {
    const { created } = installObjectURLHarness(t)
    let blobLoadCount = 0
    const item = {
        href: 'OPS/art.svg',
        mediaType: 'image/svg+xml',
    }
    const loader = new Loader({
        loadText: async () => '<svg/>',
        loadBlob: async () => {
            blobLoadCount += 1
            return new Uint8Array([1, 2, 3])
        },
        resources: { manifest: [item] },
    })

    assert.equal(await loader.loadHref('#paint', item.href), '#paint')
    assert.equal(await loader.loadHref(' #paint ', item.href), '#paint')
    assert.equal(await loader.loadHref('./art.svg#paint', item.href), '#paint')
    assert.equal(
        await loader.loadHref('art.svg?revision=2#paint', item.href),
        '#paint',
    )
    assert.equal(await loader.loadHref('   ', item.href), '')
    assert.equal(blobLoadCount, 0)
    assert.deepEqual(created, [])

    loader.destroy()
})

test('EPUB href resolution distinguishes URI schemes from colons in package paths', async t => {
    installObjectURLHarness(t)
    const local = {
        href: 'OPS/chapter:one/image.png',
        mediaType: 'image/png',
    }
    const remote = {
        href: 'https://example.com/OPS/remote.png',
        mediaType: 'image/png',
    }
    const network = {
        href: 'https://cdn.example/OPS/network.png',
        mediaType: 'image/png',
    }
    const loaded = []
    const loader = new Loader({
        loadText: async () => '',
        loadBlob: async href => {
            loaded.push(href)
            return new Uint8Array([1, 2, 3])
        },
        resources: { manifest: [local, remote, network] },
    })

    const localURL = await loader.loadHref(
        './image.png?revision=2#local',
        'OPS/chapter:one/styles.css',
    )
    const remoteURL = await loader.loadHref(
        'remote.png#remote',
        'https://example.com/OPS/styles.css',
    )
    const networkURL = await loader.loadHref(
        'network.png#network',
        '//cdn.example/OPS/styles.css',
    )

    assert.match(localURL, /^blob:test-\d+#local$/)
    assert.match(remoteURL, /^blob:test-\d+#remote$/)
    assert.match(networkURL, /^blob:test-\d+#network$/)
    assert.deepEqual(loaded, [local.href, remote.href, network.href])
    assert.equal(
        await loader.loadHref('web+epub:external', local.href),
        'web+epub:external',
    )
    assert.equal(
        await loader.loadHref('  https://example.com/a b?x=1#p  ', local.href),
        'https://example.com/a%20b?x=1#p',
    )

    loader.unloadItem(local)
    loader.unloadItem(remote)
    loader.unloadItem(network)
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})

test('EPUB script replacement does not hijack external or longer URL tokens', async t => {
    const { blobs } = installObjectURLHarness(t)
    const parent = { href: 'OPS/app.js', mediaType: 'text/javascript' }
    const child = { href: 'OPS/image.png', mediaType: 'image/png' }
    const original = [
        'const local = "image.png#local";',
        "const singleQuoted = 'image.png';",
        'const template = `image.png`;',
        'const root = "/OPS/image.png?cache=1#root";',
        'const external = "https://cdn.example/OPS/image.png";',
        'const externalQuery = "https://cdn.example/fetch?fallback=/OPS/image.png";',
        'const nested = "dir/image.png";',
        'const prefixed = "prefiximage.png";',
        'const unicodePrefixed = "猫image.png";',
        'const suffixed = "image.png.map";',
    ]
    const loader = new Loader({
        loadText: async href => {
            assert.equal(href, parent.href)
            return original.join(' ')
        },
        loadBlob: async href => {
            assert.equal(href, child.href)
            return new Uint8Array([1, 2, 3])
        },
        resources: { manifest: [parent, child] },
    })
    loader.allowScript = true

    const parentURL = await loader.loadItem(parent)
    const replaced = await blobs.get(parentURL).text()
    const childURL = [...globalThis.__manabiBlobResourceMap.entries()]
        .find(([, resource]) => resource.href === child.href)?.[0]

    assert.equal(typeof childURL, 'string')
    assert.equal(replaced, [
        `const local = "${childURL}#local";`,
        `const singleQuoted = '${childURL}';`,
        `const template = \`${childURL}\`;`,
        `const root = "${childURL}#root";`,
        ...original.slice(4),
    ].join(' '))

    loader.unloadItem(parent)
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})

test('EPUB CSS replacement preserves local anchors and attaches external fragments to object URLs', async t => {
    const { blobs } = installObjectURLHarness(t)
    const originalWindow = globalThis.window
    globalThis.window = { innerWidth: 800, innerHeight: 600 }
    t.after(() => {
        if (originalWindow === undefined) delete globalThis.window
        else globalThis.window = originalWindow
    })

    const parent = { href: 'OPS/styles.css', mediaType: 'text/css' }
    const child = { href: 'OPS/icons.bin', mediaType: 'application/octet-stream' }
    const loader = new Loader({
        loadText: async href => {
            assert.equal(href, parent.href)
            return 'body { mask: url("icons.bin#mask"); filter: url("#local"); }'
        },
        loadBlob: async href => {
            assert.equal(href, child.href)
            return new Uint8Array([1, 2, 3])
        },
        resources: { manifest: [parent, child] },
    })

    const parentURL = await loader.loadItem(parent)
    const replaced = await blobs.get(parentURL).text()
    const childURL = [...globalThis.__manabiBlobResourceMap.entries()]
        .find(([, resource]) => resource.href === child.href)?.[0]

    assert.equal(typeof childURL, 'string')
    assert.equal(
        replaced,
        `body { mask: url("${childURL}#mask"); filter: url("#local"); }`
    )

    loader.unloadItem(parent)
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})

test('EPUB CSS URL replacement preserves lexical boundaries and quoted parentheses', async t => {
    const { blobs } = installObjectURLHarness(t)
    const originalWindow = globalThis.window
    globalThis.window = { innerWidth: 800, innerHeight: 600 }
    t.after(() => {
        if (originalWindow === undefined) delete globalThis.window
        else globalThis.window = originalWindow
    })

    const parent = { href: 'OPS/styles.css', mediaType: 'text/css' }
    const child = { href: 'OPS/image(1).png', mediaType: 'image/png' }
    const external = '.external { background: url("https://example.com/100vw/a(b)-epub-page-break-after.png"); }'
    const data = ".data { background: url('data:image/svg+xml,<svg><text>100vw (x)</text></svg>'); }"
    const literal = '.literal::before { content: "url(image(1).png) 100vw -epub- page-break-after"; }'
    const comment = '/* url(image(1).png) 100vw -epub- page-break-after */'
    const empty = '.empty { background: url(); }'
    const original = [
        '.local { background: url("image(1).png#crop"); }',
        '.escaped { background: url(image\\(1\\).png); }',
        '.hex { background: url(image\\28 1\\29 .png); }',
        '.hex-crlf { background: url(image\\28' + '\r\n' + '1\\29 .png); }',
        '.continued { background: url(image\\' + '\r\n' + '\\(1\\).png); }',
        external,
        data,
        literal,
        comment,
        empty,
        '.selector-100vw.page-break-after.-epub-marker { width: 50vw; height: -25vh; -epub-writing-mode: vertical-rl; page-break-after: always; }',
    ].join('\n')
    const loadedResources = []
    const loader = new Loader({
        loadText: async href => {
            assert.equal(href, parent.href)
            return original
        },
        loadBlob: async href => {
            loadedResources.push(href)
            return new Uint8Array([1, 2, 3])
        },
        resources: { manifest: [parent, child] },
    })

    const parentURL = await loader.loadItem(parent)
    const replaced = await blobs.get(parentURL).text()
    const childURL = [...globalThis.__manabiBlobResourceMap.entries()]
        .find(([, resource]) => resource.href === child.href)?.[0]

    assert.equal(typeof childURL, 'string')
    assert.equal(replaced, [
        `.local { background: url("${childURL}#crop"); }`,
        `.escaped { background: url("${childURL}"); }`,
        `.hex { background: url("${childURL}"); }`,
        `.hex-crlf { background: url("${childURL}"); }`,
        `.continued { background: url("${childURL}"); }`,
        external,
        data,
        literal,
        comment,
        empty,
        '.selector-100vw.page-break-after.-epub-marker { width: 400px; height: -150px; writing-mode: vertical-rl; -webkit-column-break-after: always; }',
    ].join('\n'))
    assert.deepEqual(loadedResources, [child.href])

    loader.unloadItem(parent)
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})

test('EPUB image-set string sources are rewritten without touching nested metadata or literals', async t => {
    const { blobs } = installObjectURLHarness(t)
    const originalWindow = globalThis.window
    globalThis.window = { innerWidth: 800, innerHeight: 600 }
    t.after(() => {
        if (originalWindow === undefined) delete globalThis.window
        else globalThis.window = originalWindow
    })

    const parent = { href: 'OPS/styles.css', mediaType: 'text/css' }
    const small = { href: 'OPS/small.png', mediaType: 'image/png' }
    const large = { href: 'OPS/large.png', mediaType: 'image/png' }
    const typeDecoy = { href: 'OPS/image/png', mediaType: 'application/octet-stream' }
    const source = [
        '.modern { background-image: image-set(',
        '  "small.png" 1x,',
        '  "large.png#crop" 2x type("image/png"),',
        '  linear-gradient(red, blue) 3x',
        '); }',
        '.webkit { background-image: -webkit-image-set(',
        "  'small.png' 1x,",
        '  url("large.png") 2x',
        '); }',
        '.literal::before { content: \'image-set("small.png" 1x)\'; }',
        '/* image-set("small.png" 1x) */',
        '.missing { background-image: image-set("missing.png" 1x); }',
    ].join('\n')
    const loaded = []
    const loader = new Loader({
        loadText: async href => {
            assert.equal(href, parent.href)
            return source
        },
        loadBlob: async href => {
            loaded.push(href)
            return new Uint8Array([1, 2, 3])
        },
        resources: { manifest: [parent, small, large, typeDecoy] },
    })

    const parentURL = await loader.loadItem(parent)
    const replaced = await blobs.get(parentURL).text()
    const resourceURLs = new Map(
        [...globalThis.__manabiBlobResourceMap.entries()]
            .map(([url, resource]) => [resource.href, url]),
    )
    const smallURL = resourceURLs.get(small.href)
    const largeURL = resourceURLs.get(large.href)

    assert.equal(typeof smallURL, 'string')
    assert.equal(typeof largeURL, 'string')
    assert.equal(replaced, [
        '.modern { background-image: image-set(',
        `  "${smallURL}" 1x,`,
        `  "${largeURL}#crop" 2x type("image/png"),`,
        '  linear-gradient(red, blue) 3x',
        '); }',
        '.webkit { background-image: -webkit-image-set(',
        `  '${smallURL}' 1x,`,
        `  url("${largeURL}") 2x`,
        '); }',
        source.split('\n')[9],
        source.split('\n')[10],
        source.split('\n')[11],
    ].join('\n'))
    assert.deepEqual(loaded.sort(), [large.href, small.href].sort())

    loader.unloadItem(parent)
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})

test('EPUB CSS rewriting recognizes escaped resource-bearing identifiers', async t => {
    const { blobs } = installObjectURLHarness(t)
    const originalWindow = globalThis.window
    globalThis.window = { innerWidth: 800, innerHeight: 600 }
    t.after(() => {
        if (originalWindow === undefined) delete globalThis.window
        else globalThis.window = originalWindow
    })

    const parent = { href: 'OPS/styles.css', mediaType: 'text/css' }
    const image = { href: 'OPS/image.png', mediaType: 'image/png' }
    const child = { href: 'OPS/child.css', mediaType: 'text/css' }
    const source = [
        String.raw`a { background: u\72l("image.png#one"); }`,
        String.raw`b { background: \75rl(image.png); }`,
        String.raw`c { background: image\2d set("image.png" 1x); }`,
        String.raw`d { background: -webkit-image\2d set('image.png' 2x); }`,
        String.raw`@\69mport "child.css";`,
        String.raw`.longer { background: u\72l-extra("image.png"); }`,
        String.raw`.separated { background: u/**/rl("image.png"); }`,
        String.raw`.literal::before { content: 'u\72l("image.png")'; }`,
        String.raw`/* image\2d set("image.png" 1x) */`,
    ].join('\n')
    const loaded = []
    const loader = new Loader({
        loadText: async href => {
            if (href === parent.href) return source
            if (href === child.href) return 'body {}'
            throw new Error(`unexpected text resource: ${href}`)
        },
        loadBlob: async href => {
            loaded.push(href)
            return new Uint8Array([1, 2, 3])
        },
        resources: { manifest: [parent, image, child] },
    })

    const parentURL = await loader.loadItem(parent)
    const replaced = await blobs.get(parentURL).text()
    const resourceURLs = new Map(
        [...globalThis.__manabiBlobResourceMap.entries()]
            .map(([url, resource]) => [resource.href, url]),
    )
    const imageURL = resourceURLs.get(image.href)
    const childURL = resourceURLs.get(child.href)

    assert.equal(typeof imageURL, 'string')
    assert.equal(typeof childURL, 'string')
    assert.equal(replaced, [
        `a { background: url("${imageURL}#one"); }`,
        `b { background: url("${imageURL}"); }`,
        `c { background: image\\2d set("${imageURL}" 1x); }`,
        `d { background: -webkit-image\\2d set('${imageURL}' 2x); }`,
        `@\\69mport "${childURL}";`,
        '.longer { background: u\\72l-extra("image.png"); }',
        '.separated { background: u/**/rl("image.png"); }',
        `.literal::before { content: 'u\\72l("image.png")'; }`,
        '/* image\\2d set("image.png" 1x) */',
    ].join('\n'))
    assert.deepEqual(loaded, [image.href])

    loader.unloadItem(parent)
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})

test('EPUB quoted imports are rewritten only in active import rules', async t => {
    const { blobs } = installObjectURLHarness(t)
    const originalWindow = globalThis.window
    globalThis.window = { innerWidth: 800, innerHeight: 600 }
    t.after(() => {
        if (originalWindow === undefined) delete globalThis.window
        else globalThis.window = originalWindow
    })

    const parent = { href: 'OPS/styles.css', mediaType: 'text/css' }
    const child = { href: 'OPS/child.css', mediaType: 'text/css' }
    const parentText = [
        '@import "child.css";',
        "@import/**/'child.css' screen;",
        '.literal::before { content: \'@import "child.css"\'; }',
        '/* @import "child.css"; */',
    ].join('\n')
    const loader = new Loader({
        loadText: async href => href === parent.href ? parentText : '',
        loadBlob: async () => new Uint8Array(),
        resources: { manifest: [parent, child] },
    })

    const parentURL = await loader.loadItem(parent)
    const replaced = await blobs.get(parentURL).text()
    const childURL = [...globalThis.__manabiBlobResourceMap.entries()]
        .find(([, resource]) => resource.href === child.href)?.[0]

    assert.equal(typeof childURL, 'string')
    assert.equal(replaced, [
        `@import "${childURL}";`,
        `@import/**/'${childURL}' screen;`,
        parentText.split('\n')[2],
        parentText.split('\n')[3],
    ].join('\n'))

    loader.unloadItem(parent)
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})

test('EPUB parsed SVG replacement resolves modern resource hrefs without rewriting navigation anchors', async t => {
    const { blobs } = installObjectURLHarness(t)
    const svgNamespace = 'http://www.w3.org/2000/svg'
    const xlinkNamespace = 'http://www.w3.org/1999/xlink'
    const elements = []
    const { FakeElement } = installReplacementDOMHarness(t, elements)
    const image = new FakeElement('image', { href: 'image.png#crop' }, svgNamespace)
    const use = new FakeElement('use', { href: '#local-symbol' }, svgNamespace)
    const anchor = new FakeElement('a', { href: 'next.xhtml' }, svgNamespace)
    const htmlHref = new FakeElement(
        'span',
        { href: 'image.png' },
        'http://www.w3.org/1999/xhtml',
    )
    const legacyImage = new FakeElement('image', {}, svgNamespace, {
        [`${xlinkNamespace}|href`]: 'image.png#legacy',
    })
    const legacyAnchor = new FakeElement('a', {}, svgNamespace, {
        [`${xlinkNamespace}|href`]: 'next.xhtml',
    })
    elements.push(image, use, anchor, htmlHref, legacyImage, legacyAnchor)

    const parent = { href: 'OPS/chapter.xhtml', mediaType: 'application/xhtml+xml' }
    const child = { href: 'OPS/image.png', mediaType: 'image/png' }
    const chapter = { href: 'OPS/next.xhtml', mediaType: 'application/xhtml+xml' }
    const loadedResources = []
    const loader = new Loader({
        loadText: async href => {
            assert.equal(href, parent.href)
            return '<html/>'
        },
        loadBlob: async href => {
            loadedResources.push(href)
            return new Uint8Array([1, 2, 3])
        },
        resources: { manifest: [parent, child, chapter] },
    })

    const parentURL = await loader.loadItem(parent)
    const replaced = await blobs.get(parentURL).text()
    const childURL = [...globalThis.__manabiBlobResourceMap.entries()]
        .find(([, resource]) => resource.href === child.href)?.[0]

    assert.equal(typeof childURL, 'string')
    assert.equal(
        replaced,
        [
            `image:${childURL}#crop`,
            'use:#local-symbol',
            'a:next.xhtml',
            'span:image.png',
            `image:${childURL}#legacy`,
            'a:next.xhtml',
        ].join('|'),
    )
    assert.deepEqual(loadedResources, [child.href])

    loader.unloadItem(parent)
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})

test('standalone SVG rewriting stays confined to the SVG namespace', async t => {
    installObjectURLHarness(t)
    const svgNamespace = 'http://www.w3.org/2000/svg'
    const htmlNamespace = 'http://www.w3.org/1999/xhtml'
    const elements = []
    const { FakeElement } = installReplacementDOMHarness(t, elements)
    const image = new FakeElement('image', {
        href: 'image.png#crop',
    }, svgNamespace)
    const painted = new FakeElement('rect', {
        fill: 'url(paint.svg#gradient)',
    }, svgNamespace)
    const foreignArea = new FakeElement('area', {
        href: 'next.xhtml',
    }, htmlNamespace)
    const foreignMetadata = new FakeElement('span', {
        fill: 'url(paint.svg#metadata)',
    }, htmlNamespace)
    elements.push(image, painted, foreignArea, foreignMetadata)

    const parent = { href: 'OPS/figure.svg', mediaType: 'image/svg+xml' }
    const imageResource = { href: 'OPS/image.png', mediaType: 'image/png' }
    const paint = { href: 'OPS/paint.svg', mediaType: 'application/octet-stream' }
    const chapter = { href: 'OPS/next.xhtml', mediaType: 'application/octet-stream' }
    const loaded = []
    const loader = new Loader({
        loadText: async href => {
            assert.equal(href, parent.href)
            return '<svg/>'
        },
        loadBlob: async href => {
            loaded.push(href)
            return new Uint8Array([1, 2, 3])
        },
        resources: { manifest: [parent, imageResource, paint, chapter] },
    })

    await loader.loadItem(parent)
    const resourceURL = href => [...globalThis.__manabiBlobResourceMap.entries()]
        .find(([, resource]) => resource.href === href)?.[0]
    const imageURL = resourceURL(imageResource.href)
    const paintURL = resourceURL(paint.href)

    assert.equal(image.getAttribute('href'), `${imageURL}#crop`)
    assert.equal(foreignArea.getAttribute('href'), 'next.xhtml')
    assert.equal(foreignMetadata.getAttribute('fill'), 'url(paint.svg#metadata)')
    assert.equal(painted.getAttribute('fill'), `url("${paintURL}#gradient")`)
    assert.deepEqual(loaded.sort(), [imageResource.href, paint.href].sort())

    loader.unloadItem(parent)
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})

test('namespace-prefixed XML style elements rewrite package resources', async t => {
    installObjectURLHarness(t)
    const svgNamespace = 'http://www.w3.org/2000/svg'
    const elements = []
    const { FakeElement } = installReplacementDOMHarness(t, elements)
    const style = new FakeElement('style', {}, svgNamespace)
    style.textContent = 'rect { fill: url(paint.svg#gradient); }'
    elements.push(style)

    const parent = { href: 'OPS/figure.svg', mediaType: 'image/svg+xml' }
    const paint = { href: 'OPS/paint.svg', mediaType: 'application/octet-stream' }
    const loaded = []
    const loader = new Loader({
        loadText: async href => {
            assert.equal(href, parent.href)
            return '<svg:svg xmlns:svg="http://www.w3.org/2000/svg"/>'
        },
        loadBlob: async href => {
            loaded.push(href)
            return new Uint8Array([1, 2, 3])
        },
        resources: { manifest: [parent, paint] },
    })

    await loader.loadItem(parent)
    const paintURL = [...globalThis.__manabiBlobResourceMap.entries()]
        .find(([, resource]) => resource.href === paint.href)?.[0]

    assert.equal(typeof paintURL, 'string')
    assert.equal(
        style.textContent,
        `rect { fill: url("${paintURL}#gradient"); }`,
    )
    assert.deepEqual(loaded, [paint.href])

    loader.unloadItem(parent)
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})

test('EPUB parsed documents rewrite SVG paint resources and legacy background URLs', async t => {
    installObjectURLHarness(t)
    const svgNamespace = 'http://www.w3.org/2000/svg'
    const htmlNamespace = 'http://www.w3.org/1999/xhtml'
    const elements = []
    const { FakeElement } = installReplacementDOMHarness(t, elements)
    const painted = new FakeElement('rect', {
        fill: 'url("paint.svg#gradient") red',
        filter: 'url(filters.svg#blur)',
        stroke: 'url(paint.svg#stroke)',
        cursor: 'url(cursor.png), auto',
        'data-note': 'url(paint.svg#metadata)',
    }, svgNamespace)
    const localPaint = new FakeElement('path', {
        fill: 'url(#local-gradient)',
    }, svgNamespace)
    const body = new FakeElement('body', {
        background: 'background.png',
    }, htmlNamespace)
    const htmlMetadata = new FakeElement('span', {
        fill: 'url(paint.svg#not-css)',
    }, htmlNamespace)
    elements.push(painted, localPaint, body, htmlMetadata)

    const parent = {
        href: 'OPS/chapter.xhtml',
        mediaType: 'application/xhtml+xml',
    }
    const paint = { href: 'OPS/paint.svg', mediaType: 'application/octet-stream' }
    const filter = { href: 'OPS/filters.svg', mediaType: 'application/octet-stream' }
    const cursor = { href: 'OPS/cursor.png', mediaType: 'image/png' }
    const background = { href: 'OPS/background.png', mediaType: 'image/png' }
    const loaded = []
    const loader = new Loader({
        loadText: async href => {
            assert.equal(href, parent.href)
            return '<html/>'
        },
        loadBlob: async href => {
            loaded.push(href)
            return new Uint8Array([1, 2, 3])
        },
        resources: { manifest: [parent, paint, filter, cursor, background] },
    })

    await loader.loadItem(parent)
    const resourceURL = href => [...globalThis.__manabiBlobResourceMap.entries()]
        .find(([, resource]) => resource.href === href)?.[0]
    const paintURL = resourceURL(paint.href)
    const filterURL = resourceURL(filter.href)
    const cursorURL = resourceURL(cursor.href)
    const backgroundURL = resourceURL(background.href)

    assert.equal(painted.getAttribute('fill'), `url("${paintURL}#gradient") red`)
    assert.equal(painted.getAttribute('filter'), `url("${filterURL}#blur")`)
    assert.equal(painted.getAttribute('stroke'), `url("${paintURL}#stroke")`)
    assert.equal(painted.getAttribute('cursor'), `url("${cursorURL}"), auto`)
    assert.equal(painted.getAttribute('data-note'), 'url(paint.svg#metadata)')
    assert.equal(localPaint.getAttribute('fill'), 'url(#local-gradient)')
    assert.equal(body.getAttribute('background'), backgroundURL)
    assert.equal(htmlMetadata.getAttribute('fill'), 'url(paint.svg#not-css)')
    assert.deepEqual(loaded.sort(), [
        background.href,
        cursor.href,
        filter.href,
        paint.href,
    ].sort())

    loader.unloadItem(parent)
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})

test('EPUB parsed links rewrite resource relations but preserve navigation relations', async t => {
    installObjectURLHarness(t)
    const elements = []
    const { FakeElement } = installReplacementDOMHarness(t, elements)
    const stylesheet = new FakeElement('link', {
        rel: 'stylesheet',
        href: 'asset.bin',
    })
    const preload = new FakeElement('link', {
        rel: 'preload',
        href: 'asset.bin',
    })
    const next = new FakeElement('link', {
        rel: 'next',
        href: 'next.xhtml',
    })
    const canonical = new FakeElement('link', {
        rel: 'canonical',
        href: 'next.xhtml',
    })
    elements.push(stylesheet, preload, next, canonical)

    const parent = { href: 'OPS/chapter.xhtml', mediaType: 'application/xhtml+xml' }
    const asset = { href: 'OPS/asset.bin', mediaType: 'application/octet-stream' }
    const chapter = { href: 'OPS/next.xhtml', mediaType: 'application/xhtml+xml' }
    const loaded = []
    const loader = new Loader({
        loadText: async href => {
            assert.equal(href, parent.href)
            return '<html/>'
        },
        loadBlob: async href => {
            loaded.push(href)
            return new Uint8Array([1, 2, 3])
        },
        resources: { manifest: [parent, asset, chapter] },
    })

    await loader.loadItem(parent)
    const assetURL = [...globalThis.__manabiBlobResourceMap.entries()]
        .find(([, resource]) => resource.href === asset.href)?.[0]

    assert.equal(stylesheet.getAttribute('href'), assetURL)
    assert.equal(preload.getAttribute('href'), assetURL)
    assert.equal(next.getAttribute('href'), 'next.xhtml')
    assert.equal(canonical.getAttribute('href'), 'next.xhtml')
    assert.deepEqual(loaded, [asset.href])

    loader.unloadItem(parent)
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})

test('EPUB parsed XML rewrites stylesheet processing instructions after comments', async t => {
    installObjectURLHarness(t)
    const elements = []
    const {
        FakeProcessingInstruction,
        document,
    } = installReplacementDOMHarness(t, elements)
    const customInstruction = new FakeProcessingInstruction(
        'reader-extension',
        'href="styles.css"',
    )
    const instruction = new FakeProcessingInstruction(
        'xml-stylesheet',
        'type="text/css" href="styles.css"',
    )
    document.childNodes.push({ nodeType: 8 }, customInstruction, instruction)
    document.firstChild = document.childNodes[0]

    const parent = { href: 'OPS/chapter.xhtml', mediaType: 'application/xhtml+xml' }
    const stylesheet = { href: 'OPS/styles.css', mediaType: 'text/css' }
    const loader = new Loader({
        loadText: async href => {
            if (href === parent.href) return '<html/>'
            if (href === stylesheet.href) return 'body { display: block; }'
            throw new Error(`unexpected text resource: ${href}`)
        },
        loadBlob: async () => {
            throw new Error('processing-instruction stylesheet must use the text loader')
        },
        resources: { manifest: [parent, stylesheet] },
    })

    await loader.loadItem(parent)
    const stylesheetURL = [...globalThis.__manabiBlobResourceMap.entries()]
        .find(([, resource]) => resource.href === stylesheet.href)?.[0]

    assert.equal(customInstruction.data, 'href="styles.css"')
    assert.equal(
        instruction.data,
        `type="text/css" href="${stylesheetURL}"`,
    )

    loader.unloadItem(parent)
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})

test('EPUB responsive image replacement preserves data URLs and rewrites each local candidate', async t => {
    installObjectURLHarness(t)
    const elements = []
    const { FakeElement } = installReplacementDOMHarness(t, elements)
    const source = new FakeElement('source', {
        srcset: [
            'data:image/png;base64,AAAA 1x',
            './small.png 2x',
            'large.png 640w',
        ].join(', '),
    })
    const preload = new FakeElement('link', {
        imagesrcset: 'small.png 1x, large.png 2x',
    })
    elements.push(source, preload)

    const parent = {
        href: 'OPS/chapter.xhtml',
        mediaType: 'application/xhtml+xml',
    }
    const small = { href: 'OPS/small.png', mediaType: 'image/png' }
    const large = { href: 'OPS/large.png', mediaType: 'image/png' }
    const loaded = []
    const loader = new Loader({
        loadText: async href => {
            assert.equal(href, parent.href)
            return '<html/>'
        },
        loadBlob: async href => {
            loaded.push(href)
            return new Uint8Array([1, 2, 3])
        },
        resources: { manifest: [parent, small, large] },
    })

    await loader.loadItem(parent)
    const resourceURL = href => [...globalThis.__manabiBlobResourceMap.entries()]
        .find(([, resource]) => resource.href === href)?.[0]
    const smallURL = resourceURL(small.href)
    const largeURL = resourceURL(large.href)

    assert.equal(source.getAttribute('srcset'), [
        'data:image/png;base64,AAAA 1x',
        `${smallURL} 2x`,
        `${largeURL} 640w`,
    ].join(', '))
    assert.equal(
        preload.getAttribute('imagesrcset'),
        `${smallURL} 1x, ${largeURL} 2x`,
    )
    assert.deepEqual(loaded, [small.href, large.href])

    loader.unloadItem(parent)
    assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
})
