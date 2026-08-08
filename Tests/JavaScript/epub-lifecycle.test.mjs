import assert from 'node:assert/strict'
import test from 'node:test'

globalThis.DOMParser = class {}

const { EPUB, Loader } = await import(
    '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/epub.js'
)

const makeSource = destroy => ({
    loadText: async () => null,
    loadBlob: async () => null,
    getSize: () => 0,
    replaceText: value => value,
    replaceURL: value => value,
    destroy,
})

test('EPUB destroy releases its source owner exactly once before initialization', async () => {
    let destroyCount = 0
    const book = new EPUB(makeSource(() => { destroyCount += 1 }))

    assert.equal(book.destroy(), true)
    await Promise.resolve()
    assert.equal(destroyCount, 1)
    assert.equal(book.destroy(), false)
    await Promise.resolve()
    assert.equal(destroyCount, 1)
})

test('EPUB destroy isolates a rejected asynchronous source cleanup', async () => {
    let destroyCount = 0
    const book = new EPUB(makeSource(async () => {
        destroyCount += 1
        throw new Error('cleanup failed')
    }))

    assert.equal(book.destroy(), true)
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(destroyCount, 1)
    assert.equal(book.destroy(), false)
})

test('EPUB initialization after destruction refuses before reading the source', async () => {
    let loadTextCount = 0
    const book = new EPUB({
        ...makeSource(() => {}),
        loadText: async () => {
            loadTextCount += 1
            return null
        },
    })

    assert.equal(book.destroy(), true)
    await assert.rejects(
        book.init(),
        error => error?.name === 'AbortError' && /destroyed/.test(error.message)
    )
    assert.equal(loadTextCount, 0)
})

test('EPUB destruction while container loading is suspended prevents parsing and initialization', async () => {
    const originalDOMParser = globalThis.DOMParser
    let resolveContainer
    let parseCount = 0
    let sourceDestroyCount = 0
    globalThis.DOMParser = class {
        parseFromString() {
            parseCount += 1
            return null
        }
    }

    try {
        const book = new EPUB({
            ...makeSource(() => { sourceDestroyCount += 1 }),
            loadText: uri => {
                assert.equal(uri, 'META-INF/container.xml')
                return new Promise(resolve => { resolveContainer = resolve })
            },
        })
        const initialization = book.init()
        await Promise.resolve()

        assert.equal(book.destroy(), true)
        resolveContainer('<container/>')

        await assert.rejects(
            initialization,
            error => error?.name === 'AbortError' && /destroyed/.test(error.message)
        )
        assert.equal(parseCount, 0)
        assert.equal(sourceDestroyCount, 1)
    } finally {
        globalThis.DOMParser = originalDOMParser
    }
})

test('EPUB destruction prevents a suspended document load from parsing stale content', async () => {
    const originalDOMParser = globalThis.DOMParser
    let resolveDocument
    let parseCount = 0
    globalThis.DOMParser = class {
        parseFromString() {
            parseCount += 1
            return null
        }
    }

    try {
        const book = new EPUB({
            ...makeSource(() => {}),
            loadText: () => new Promise(resolve => { resolveDocument = resolve }),
        })
        const documentLoad = book.loadDocument({
            href: 'chapter.xhtml',
            mediaType: 'application/xhtml+xml',
        })
        await Promise.resolve()

        assert.equal(book.destroy(), true)
        resolveDocument('<html/>')

        await assert.rejects(
            documentLoad,
            error => error?.name === 'AbortError' && /destroyed/.test(error.message)
        )
        assert.equal(parseCount, 0)
    } finally {
        globalThis.DOMParser = originalDOMParser
    }
})

test('loader destroy revokes owned URLs, clears publication records, and is idempotent', () => {
    const originalURL = globalThis.URL
    const originalBlobMap = globalThis.__manabiBlobResourceMap
    const revoked = []
    let nextURL = 0
    globalThis.URL = {
        createObjectURL: () => `blob:test-${++nextURL}`,
        revokeObjectURL: url => revoked.push(url),
    }
    globalThis.__manabiBlobResourceMap = new Map()

    try {
        const loader = new Loader({
            loadText: async () => null,
            loadBlob: async () => null,
            resources: { manifest: [] },
        })
        const blobURL = loader.createURL('chapter.xhtml', '<p>chapter</p>', 'text/html')
        const directURL = loader.createDirectURL('processed.xhtml', 'manabi-reader://processed')

        assert.equal(globalThis.__manabiBlobResourceMap.has(blobURL), true)
        assert.equal(loader.destroy(), true)
        assert.deepEqual(revoked, [blobURL])
        assert.equal(globalThis.__manabiBlobResourceMap.has(blobURL), false)
        assert.equal(loader.createURL('late.xhtml', 'late', 'text/html'), '')
        assert.equal(loader.createDirectURL('late-direct.xhtml', directURL), '')
        assert.equal(loader.destroy(), false)
    } finally {
        globalThis.URL = originalURL
        globalThis.__manabiBlobResourceMap = originalBlobMap
    }
})

test('loader destruction prevents late asynchronous resource publication', async () => {
    const originalURL = globalThis.URL
    let createCount = 0
    globalThis.URL = {
        createObjectURL: () => {
            createCount += 1
            return `blob:late-${createCount}`
        },
        revokeObjectURL() {},
    }

    let resolveBlob
    try {
        const item = { href: 'image.png', mediaType: 'image/png' }
        const loader = new Loader({
            loadText: async () => null,
            loadBlob: () => new Promise(resolve => { resolveBlob = resolve }),
            resources: { manifest: [item] },
        })
        const load = loader.loadItem(item)
        await Promise.resolve()
        assert.equal(loader.destroy(), true)
        resolveBlob(new Uint8Array([1, 2, 3]))

        assert.equal(await load, null)
        assert.equal(createCount, 0)
        assert.equal(await loader.loadItem(item), null)
    } finally {
        globalThis.URL = originalURL
    }
})


test('concurrent loads for one item share one cache publication and independent references', async () => {
    const originalURL = globalThis.URL
    const originalBlobMap = globalThis.__manabiBlobResourceMap
    const created = []
    const revoked = []
    globalThis.URL = {
        createObjectURL: () => {
            const url = `blob:shared-${created.length + 1}`
            created.push(url)
            return url
        },
        revokeObjectURL: url => revoked.push(url),
    }
    globalThis.__manabiBlobResourceMap = new Map()

    let resolveBlob
    let blobLoadCount = 0
    try {
        const item = { href: 'image.png', mediaType: 'image/png' }
        const loader = new Loader({
            loadText: async () => null,
            loadBlob: () => {
                blobLoadCount += 1
                return new Promise(resolve => { resolveBlob = resolve })
            },
            resources: { manifest: [item] },
        })

        const first = loader.loadItem(item)
        const second = loader.loadItem(item)
        await Promise.resolve()
        assert.equal(blobLoadCount, 1)

        resolveBlob(new TextEncoder().encode('<html/>'))
        const [firstURL, secondURL] = await Promise.all([first, second])
        assert.equal(firstURL, secondURL)
        assert.deepEqual(created, ['blob:shared-1'])

        loader.unloadItem(item)
        assert.deepEqual(revoked, [])
        loader.unloadItem(item)
        assert.deepEqual(revoked, ['blob:shared-1'])
        assert.equal(globalThis.__manabiBlobResourceMap.has(firstURL), false)
    } finally {
        globalThis.URL = originalURL
        globalThis.__manabiBlobResourceMap = originalBlobMap
    }
})

test('loader destruction releases replacement owners exactly once', () => {
    let replaceTextDestroyCount = 0
    let replaceURLDestroyCount = 0
    const replaceText = async (_href, text) => text
    replaceText.destroy = () => {
        replaceTextDestroyCount += 1
        return replaceTextDestroyCount === 1
    }
    const replaceURL = async () => 'ebook://ebook/processed-section'
    replaceURL.destroy = () => {
        replaceURLDestroyCount += 1
        return replaceURLDestroyCount === 1
    }
    const loader = new Loader({
        loadText: async () => null,
        loadBlob: async () => null,
        resources: { manifest: [] },
        replaceText,
        replaceURL,
    })

    assert.equal(loader.destroy(), true)
    assert.equal(loader.destroy(), false)
    assert.equal(replaceTextDestroyCount, 1)
    assert.equal(replaceURLDestroyCount, 1)
})

test('destroyed loader does not enter replacement after suspended text loading resumes', async () => {
    let releaseText
    let replaceTextCount = 0
    const item = { href: 'chapter.xhtml', mediaType: 'application/xhtml+xml' }
    const loader = new Loader({
        loadText: () => new Promise(resolve => { releaseText = resolve }),
        loadBlob: async () => null,
        resources: { manifest: [item] },
        replaceText: async (_href, text) => {
            replaceTextCount += 1
            return text
        },
    })

    const pendingLoad = loader.loadItem(item)
    await Promise.resolve()
    assert.equal(loader.destroy(), true)
    releaseText('<html><body>stale</body></html>')

    assert.equal(await pendingLoad, null)
    assert.equal(replaceTextCount, 0)
})

test('destroyed loader invalidates a suspended direct replacement owner before its side effect', async () => {
    let releaseReplacement
    let active = true
    let livePublicationCount = 0
    let destroyCount = 0
    const replaceURL = async () => {
        await new Promise(resolve => { releaseReplacement = resolve })
        if (!active) return null
        livePublicationCount += 1
        return 'ebook://ebook/processed-section?sourceURL=old-book'
    }
    replaceURL.destroy = () => {
        if (!active) return false
        active = false
        destroyCount += 1
        return true
    }
    const item = { href: 'chapter.xhtml', mediaType: 'application/xhtml+xml' }
    const loader = new Loader({
        loadText: async () => null,
        loadBlob: async () => null,
        resources: { manifest: [item] },
        replaceURL,
    })

    const pendingLoad = loader.loadItem(item)
    await Promise.resolve()
    assert.equal(loader.destroy(), true)
    releaseReplacement()

    assert.equal(await pendingLoad, null)
    assert.equal(destroyCount, 1)
    assert.equal(livePublicationCount, 0)
})

test('recursive replacement resources do not overwrite or outlive the outer href publication', async () => {
    const originalCreateObjectURL = globalThis.URL.createObjectURL
    const originalRevokeObjectURL = globalThis.URL.revokeObjectURL
    const originalWindow = globalThis.window
    const originalBlobMap = globalThis.__manabiBlobResourceMap
    const created = []
    const revoked = []
    globalThis.URL.createObjectURL = () => {
        const url = `blob:recursive-${created.length + 1}`
        created.push(url)
        return url
    }
    globalThis.URL.revokeObjectURL = url => revoked.push(url)
    globalThis.window = { innerWidth: 800, innerHeight: 600 }
    globalThis.__manabiBlobResourceMap = new Map()

    try {
        const item = { href: 'styles/book.css', mediaType: 'text/css' }
        const loader = new Loader({
            loadText: async href => {
                assert.equal(href, item.href)
                return '@import "book.css"; body { color: black; }'
            },
            loadBlob: async href => {
                assert.equal(href, item.href)
                return new TextEncoder().encode('body { color: black; }')
            },
            resources: { manifest: [item] },
        })

        const outerURL = await loader.loadItem(item)
        assert.equal(outerURL, 'blob:recursive-2')
        assert.deepEqual(created, ['blob:recursive-1', 'blob:recursive-2'])
        assert.equal(globalThis.__manabiBlobResourceMap.size, 2)

        loader.unloadItem(item)

        assert.deepEqual(revoked, ['blob:recursive-2', 'blob:recursive-1'])
        assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
    } finally {
        globalThis.URL.createObjectURL = originalCreateObjectURL
        globalThis.URL.revokeObjectURL = originalRevokeObjectURL
        globalThis.window = originalWindow
        globalThis.__manabiBlobResourceMap = originalBlobMap
    }
})

test('failed parent replacement rolls back child resources created before commit', async () => {
    const originalCreateObjectURL = globalThis.URL.createObjectURL
    const originalRevokeObjectURL = globalThis.URL.revokeObjectURL
    const originalWindow = globalThis.window
    const originalBlobMap = globalThis.__manabiBlobResourceMap
    const created = []
    const revoked = []
    globalThis.URL.createObjectURL = () => {
        if (created.length === 1) throw new Error('parent publication failed')
        const url = `blob:rollback-${created.length + 1}`
        created.push(url)
        return url
    }
    globalThis.URL.revokeObjectURL = url => revoked.push(url)
    globalThis.window = { innerWidth: 800, innerHeight: 600 }
    globalThis.__manabiBlobResourceMap = new Map()

    try {
        const parent = { href: 'styles/book.css', mediaType: 'text/css' }
        const child = { href: 'images/background.png', mediaType: 'image/png' }
        const loader = new Loader({
            loadText: async href => {
                assert.equal(href, parent.href)
                return '@import "../images/background.png";'
            },
            loadBlob: async href => {
                assert.equal(href, child.href)
                return new Uint8Array([1, 2, 3])
            },
            resources: { manifest: [parent, child] },
        })

        await assert.rejects(loader.loadItem(parent), /parent publication failed/)
        assert.deepEqual(created, ['blob:rollback-1'])
        assert.deepEqual(revoked, ['blob:rollback-1'])
        assert.equal(globalThis.__manabiBlobResourceMap.size, 0)
    } finally {
        globalThis.URL.createObjectURL = originalCreateObjectURL
        globalThis.URL.revokeObjectURL = originalRevokeObjectURL
        globalThis.window = originalWindow
        globalThis.__manabiBlobResourceMap = originalBlobMap
    }
})

test('invalid XHTML fallback commits its media type only after successful publication', async () => {
    const originalDOMParser = globalThis.DOMParser
    const originalProcessingInstruction = globalThis.ProcessingInstruction
    const originalXMLSerializer = globalThis.XMLSerializer
    const originalCreateObjectURL = globalThis.URL.createObjectURL
    const originalRevokeObjectURL = globalThis.URL.revokeObjectURL
    const originalBlobMap = globalThis.__manabiBlobResourceMap
    const originalWarn = console.warn
    let shouldFailSerialization = true
    let publishedBlob = null

    const makeDocument = hasParserError => ({
        firstChild: null,
        querySelector: selector => selector === 'parsererror' && hasParserError
            ? { innerText: 'invalid XHTML' }
            : null,
        querySelectorAll: () => [],
        getElementsByTagName: () => [],
    })

    globalThis.DOMParser = class {
        parseFromString(_source, mediaType) {
            return makeDocument(mediaType === 'application/xhtml+xml')
        }
    }
    globalThis.ProcessingInstruction = class {}
    globalThis.XMLSerializer = class {
        serializeToString() {
            if (shouldFailSerialization) throw new Error('serialization failed')
            return '<html><body>fallback</body></html>'
        }
    }
    globalThis.URL.createObjectURL = blob => {
        publishedBlob = blob
        return 'blob:xhtml-fallback'
    }
    globalThis.URL.revokeObjectURL = () => {}
    globalThis.__manabiBlobResourceMap = new Map()
    console.warn = () => {}

    try {
        const item = {
            href: 'chapter.xhtml',
            mediaType: 'application/xhtml+xml',
        }
        const loader = new Loader({
            loadText: async () => '<html><body>fallback</body></html>',
            loadBlob: async () => null,
            resources: { manifest: [item] },
        })

        await assert.rejects(loader.loadItem(item), /serialization failed/)
        assert.equal(item.mediaType, 'application/xhtml+xml')

        shouldFailSerialization = false
        assert.equal(await loader.loadItem(item), 'blob:xhtml-fallback')
        assert.equal(item.mediaType, 'text/html')
        assert.equal(publishedBlob.type, 'text/html')
    } finally {
        globalThis.DOMParser = originalDOMParser
        globalThis.ProcessingInstruction = originalProcessingInstruction
        globalThis.XMLSerializer = originalXMLSerializer
        globalThis.URL.createObjectURL = originalCreateObjectURL
        globalThis.URL.revokeObjectURL = originalRevokeObjectURL
        globalThis.__manabiBlobResourceMap = originalBlobMap
        console.warn = originalWarn
    }
})

test('script replacement resolves root-relative asset references through the exact manifest key', async () => {
    const originalCreateObjectURL = globalThis.URL.createObjectURL
    const originalRevokeObjectURL = globalThis.URL.revokeObjectURL
    const originalBlobMap = globalThis.__manabiBlobResourceMap
    const createdBlobs = []
    const revoked = []

    globalThis.URL.createObjectURL = blob => {
        createdBlobs.push(blob)
        return `blob:root-relative-${createdBlobs.length}`
    }
    globalThis.URL.revokeObjectURL = url => revoked.push(url)
    globalThis.__manabiBlobResourceMap = new Map()

    try {
        const script = {
            href: 'OPS/scripts/app.js',
            mediaType: 'application/javascript',
        }
        const image = {
            href: 'OPS/images/cover.png',
            mediaType: 'image/png',
        }
        const loader = new Loader({
            loadText: async href => {
                assert.equal(href, script.href)
                return 'const cover = "/OPS/images/cover.png";'
            },
            loadBlob: async href => {
                assert.equal(href, image.href)
                return new Uint8Array([1, 2, 3])
            },
            resources: { manifest: [script, image] },
        })
        loader.allowScript = true

        assert.equal(await loader.loadItem(script), 'blob:root-relative-2')
        assert.equal(
            await createdBlobs[1].text(),
            'const cover = "blob:root-relative-1";'
        )

        loader.unloadItem(script)
        assert.deepEqual(revoked, [
            'blob:root-relative-2',
            'blob:root-relative-1',
        ])
    } finally {
        globalThis.URL.createObjectURL = originalCreateObjectURL
        globalThis.URL.revokeObjectURL = originalRevokeObjectURL
        globalThis.__manabiBlobResourceMap = originalBlobMap
    }
})

test('script replacement respects exact path boundaries and keeps the first manifest identity', async () => {
    const originalCreateObjectURL = globalThis.URL.createObjectURL
    const originalRevokeObjectURL = globalThis.URL.revokeObjectURL
    const originalBlobMap = globalThis.__manabiBlobResourceMap
    const createdBlobs = []
    const loadedAssets = []

    globalThis.URL.createObjectURL = blob => {
        createdBlobs.push(blob)
        return `blob:bounded-${createdBlobs.length}`
    }
    globalThis.URL.revokeObjectURL = () => {}
    globalThis.__manabiBlobResourceMap = new Map()

    try {
        const script = {
            href: 'OPS/scripts/app.js',
            mediaType: 'application/javascript',
        }
        const cover = {
            href: 'OPS/images/cover.png',
            mediaType: 'image/png',
        }
        const shorter = {
            href: 'OPS/assets/font',
            mediaType: 'application/octet-stream',
        }
        const firstFont = {
            href: 'OPS/assets/font.woff',
            mediaType: 'font/woff',
        }
        const duplicateFont = {
            href: 'OPS/assets/font.woff',
            mediaType: 'application/octet-stream',
        }
        const loader = new Loader({
            loadText: async href => {
                assert.equal(href, script.href)
                return [
                    'const external = "https://example.com/OPS/images/cover.png";',
                    'const larger = "../assets/font.woff2";',
                    'const exact = "../assets/font.woff?version=1#main";',
                ].join('\n')
            },
            loadBlob: async href => {
                loadedAssets.push(href)
                return new Uint8Array([1, 2, 3])
            },
            resources: {
                manifest: [script, cover, shorter, firstFont, duplicateFont],
            },
        })
        loader.allowScript = true

        assert.equal(await loader.loadItem(script), 'blob:bounded-2')
        assert.equal(
            await createdBlobs[1].text(),
            [
                'const external = "https://example.com/OPS/images/cover.png";',
                'const larger = "../assets/font.woff2";',
                'const exact = "blob:bounded-1#main";',
            ].join('\n')
        )
        assert.deepEqual(loadedAssets, [firstFont.href])
        assert.equal(createdBlobs[0].type, firstFont.mediaType)
    } finally {
        globalThis.URL.createObjectURL = originalCreateObjectURL
        globalThis.URL.revokeObjectURL = originalRevokeObjectURL
        globalThis.__manabiBlobResourceMap = originalBlobMap
    }
})

test('script replacement recognizes single-quoted relative asset tokens', async () => {
    const originalCreateObjectURL = globalThis.URL.createObjectURL
    const originalRevokeObjectURL = globalThis.URL.revokeObjectURL
    const originalBlobMap = globalThis.__manabiBlobResourceMap
    const createdBlobs = []

    globalThis.URL.createObjectURL = blob => {
        createdBlobs.push(blob)
        return `blob:single-quoted-${createdBlobs.length}`
    }
    globalThis.URL.revokeObjectURL = () => {}
    globalThis.__manabiBlobResourceMap = new Map()

    try {
        const script = {
            href: 'OPS/scripts/app.js',
            mediaType: 'application/javascript',
        }
        const image = {
            href: 'OPS/images/cover.png',
            mediaType: 'image/png',
        }
        const loader = new Loader({
            loadText: async href => {
                assert.equal(href, script.href)
                return "const cover = '../images/cover.png';"
            },
            loadBlob: async href => {
                assert.equal(href, image.href)
                return new Uint8Array([1, 2, 3])
            },
            resources: { manifest: [script, image] },
        })
        loader.allowScript = true

        assert.equal(await loader.loadItem(script), 'blob:single-quoted-2')
        assert.equal(
            await createdBlobs[1].text(),
            "const cover = 'blob:single-quoted-1';"
        )
    } finally {
        globalThis.URL.createObjectURL = originalCreateObjectURL
        globalThis.URL.revokeObjectURL = originalRevokeObjectURL
        globalThis.__manabiBlobResourceMap = originalBlobMap
    }
})

test('fragment-bearing asset references preserve the fragment on the published resource URL', async () => {
    const originalCreateObjectURL = globalThis.URL.createObjectURL
    const originalRevokeObjectURL = globalThis.URL.revokeObjectURL
    const originalBlobMap = globalThis.__manabiBlobResourceMap

    globalThis.URL.createObjectURL = () => 'blob:external-symbols'
    globalThis.URL.revokeObjectURL = () => {}
    globalThis.__manabiBlobResourceMap = new Map()

    try {
        const chapter = {
            href: 'OPS/chapter.svg',
            mediaType: 'image/svg+xml',
        }
        const symbols = {
            href: 'OPS/images/symbols.svg',
            mediaType: 'application/octet-stream',
        }
        const loader = new Loader({
            loadText: async () => null,
            loadBlob: async href => {
                assert.equal(href, symbols.href)
                return new TextEncoder().encode('<svg/>')
            },
            resources: { manifest: [chapter, symbols] },
        })

        assert.equal(
            await loader.loadHref('images/symbols.svg#checkmark', chapter.href),
            'blob:external-symbols#checkmark'
        )
        assert.equal(
            await loader.loadHref('images/symbols.svg?version=1#query-checkmark', chapter.href),
            'blob:external-symbols#query-checkmark'
        )
        assert.equal(
            await loader.loadHref('#local-symbol', chapter.href),
            '#local-symbol'
        )
        assert.equal(
            await loader.loadHref('?version=1#local-symbol', chapter.href),
            '?version=1#local-symbol'
        )
    } finally {
        globalThis.URL.createObjectURL = originalCreateObjectURL
        globalThis.URL.revokeObjectURL = originalRevokeObjectURL
        globalThis.__manabiBlobResourceMap = originalBlobMap
    }
})

test('empty text resources still publish exact loader-owned blob URLs', async () => {
    const originalCreateObjectURL = globalThis.URL.createObjectURL
    const originalRevokeObjectURL = globalThis.URL.revokeObjectURL
    const originalBlobMap = globalThis.__manabiBlobResourceMap
    const createdBlobs = []

    globalThis.URL.createObjectURL = blob => {
        createdBlobs.push(blob)
        return `blob:empty-${createdBlobs.length}`
    }
    globalThis.URL.revokeObjectURL = () => {}
    globalThis.__manabiBlobResourceMap = new Map()

    try {
        const stylesheet = {
            href: 'OPS/styles/empty.css',
            mediaType: 'text/css',
        }
        const script = {
            href: 'OPS/scripts/empty.js',
            mediaType: 'application/javascript',
        }
        const loader = new Loader({
            loadText: async () => '',
            loadBlob: async () => null,
            resources: { manifest: [stylesheet, script] },
        })
        loader.allowScript = true

        assert.equal(await loader.loadItem(stylesheet), 'blob:empty-1')
        assert.equal(await loader.loadItem(script), 'blob:empty-2')
        assert.equal(await createdBlobs[0].text(), '')
        assert.equal(await createdBlobs[1].text(), '')
        assert.equal(createdBlobs[0].type, stylesheet.mediaType)
        assert.equal(createdBlobs[1].type, script.mediaType)
    } finally {
        globalThis.URL.createObjectURL = originalCreateObjectURL
        globalThis.URL.revokeObjectURL = originalRevokeObjectURL
        globalThis.__manabiBlobResourceMap = originalBlobMap
    }
})
