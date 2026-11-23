import { Loader } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/epub.js'

const check = (condition, message) => { if (!condition) throw new Error(message) }

async function checkDefinitionReadOwnership(makeLoader, texts, section, definitionPath) {
    const existingURLs = new Set(globalThis.__manabiBlobResourceMap?.keys())
    const newURLs = () =>
        [...(globalThis.__manabiBlobResourceMap?.keys() ?? [])].filter(url => !existingURLs.has(url))
    const checkRevoked = async (urls, message) => {
        const results = await Promise.allSettled(urls.map(url => fetch(url)))
        check(results.every(result => result.status === 'rejected'), message)
    }
    const readFailure = new Error('Controlled SVG definition read failure')
    let definitionReads = 0
    let beforeFailure = []
    const retrying = makeLoader(async href => {
        if (href === definitionPath && ++definitionReads === 1) {
            beforeFailure = newURLs()
            throw readFailure
        }
        return texts.get(href)
    })
    try {
        const [failed] = await Promise.allSettled([retrying.loadItem(section)])
        check(failed.status === 'rejected' && failed.reason === readFailure,
            'A failed packaged definition reaches the section caller')
        check(beforeFailure.length > 0, 'The section publishes earlier SVG resources before the controlled failure')
        await checkRevoked(beforeFailure, 'A failed section revokes its earlier SVG resources')
        check(newURLs().length === 0, 'A failed section leaves no SVG resource publications')

        const [first, second] = await Promise.all([retrying.loadItem(section), retrying.loadItem(section)])
        check(first?.startsWith('blob:') && first === second && definitionReads === 2,
            'Concurrent retry callers share the section and its retried definition')
        const retrySource = await (await fetch(first)).text()
        const retryDoc = new DOMParser().parseFromString(retrySource, 'image/svg+xml')
        const definitionHref = retryDoc.getElementById('linear')?.getAttribute('href')
        check(definitionHref?.startsWith('blob:') && definitionHref.endsWith('#linearSource'),
            'The retried section references its packaged SVG definition Blob')
        const sharedURLs = [second, definitionHref.split('#')[0]]
        retrying.unloadItem(section)
        const retained = await Promise.all(sharedURLs.map(url => fetch(url)))
        check(retained.every(response => response.ok),
            'The remaining retry caller retains the section and its definition')
        retrying.unloadItem(section)
        await checkRevoked(sharedURLs, 'The last retry caller revokes the section and its definition')
        check(newURLs().length === 0, 'The last retry caller leaves no SVG resource publications')
    } finally { retrying.destroy() }

    let beginDefinition
    let finishDefinition
    const started = new Promise(resolve => { beginDefinition = resolve })
    const heldDefinition = new Promise(resolve => { finishDefinition = resolve })
    const retiring = makeLoader(async href => {
        if (href !== definitionPath) return texts.get(href)
        beginDefinition(newURLs())
        return heldDefinition
    })
    try {
        const pending = retiring.loadItem(section)
        const beforeDestroy = await Promise.race([started, pending.then(() => null)])
        check(beforeDestroy !== null,
            'The section is still loading when it reaches the held SVG definition')
        check(beforeDestroy.length > 0, 'The held section has already published earlier SVG resources')
        retiring.destroy()
        finishDefinition(texts.get(definitionPath))
        check(!await pending && newURLs().length === 0,
            'A retired section cannot publish its held SVG definition or retain earlier resources')
        await checkRevoked(beforeDestroy, 'Destroying a held section revokes its earlier SVG resources')
    } finally {
        retiring.destroy()
        finishDefinition(texts.get(definitionPath))
    }
}

// Run in a browser: parsing, XML serialization, blob fetching and image decoding
// use the real platform. Archive reads and the native URL callback are controlled.
export async function runSVGResourceReferences() {
    const svgNS = 'http://www.w3.org/2000/svg'
    const definitionsPath = 'assets/paint%20and%20motion.svg'
    const source = `<svg xmlns="${svgNS}" xmlns:s="${svgNS}" xmlns:xlink="http://www.w3.org/1999/xlink"
      xmlns:foreign="urn:test:foreign">
      <image id="modern" href="pixel.svg"/>
      <image id="legacy" xlink:href="pixel.svg"/>
      <image id="precedence" href="pixel.svg" xlink:href="missing.svg"/>
      <use id="external" href="sprite.svg#shape"/>
      <use id="local" href="#shape"/>
      <filter id="filter"><feImage id="filterImage" href="pixel.svg"/></filter>
      <defs>
        <s:linearGradient id="linear" href="${definitionsPath}#linearSource" xlink:href="decoy.svg"/>
        <radialGradient id="radial" href="${definitionsPath}#radialSource"/>
        <radialGradient id="remoteGradient" href="https://example.invalid/paint.svg#gradient"/>
        <pattern id="pattern" href="${definitionsPath}#patternSource"/>
        <pattern id="localPattern" href="#pattern"/>
        <pattern id="emptyPattern" href="" xlink:href="decoy.svg"/>
      </defs>
      <text><textPath id="textPath" href="${definitionsPath}#motion">Text</textPath></text>
      <animateMotion><mpath id="motionPath" href="${definitionsPath}#motion"/></animateMotion>
      <foreign:pattern id="foreignPattern" href="decoy.svg"/>
      <script id="script" href="decoy.svg"/>
      <a id="navigation" href="chapter.xhtml#target"><text>Next</text></a>
      <g id="shape"><rect width="1" height="1"/></g>
    </svg>`
    const pixels = `<svg xmlns="${svgNS}" width="1" height="1"><rect width="1" height="1" fill="red"/></svg>`
    const texts = new Map([
        ['OPS/art.svg', source],
        ['OPS/pixel.svg', pixels],
        ['OPS/decoy.svg', pixels],
        ['OPS/sprite.svg', `<svg xmlns="${svgNS}"><g id="shape"><rect width="1" height="1"/></g></svg>`],
        ['OPS/assets/paint and motion.svg', `<svg xmlns="${svgNS}"><defs>
          <linearGradient id="linearSource"><stop stop-color="red"/></linearGradient>
          <radialGradient id="radialSource"><stop stop-color="blue"/></radialGradient>
          <pattern id="patternSource" width="1" height="1"><rect width="1" height="1"/></pattern>
          <path id="motion" d="M0 0L10 10"/>
        </defs></svg>`],
    ])
    const reads = []
    const directReads = []
    const directURL = 'ebook://ebook/processed-section?subpath=OPS%2Fnative.xhtml'
    const makeLoader = loadText => new Loader({
        resources: { manifest: [...texts.keys()].map(href => ({ href, mediaType: 'image/svg+xml' })) },
        loadText,
        loadBlob: async () => { throw new Error('Unexpected binary archive read') },
        replaceURL: async href => { directReads.push(href); return directURL },
    })
    const loader = makeLoader(async href => { reads.push(href); return texts.get(href) })
    const section = { href: 'OPS/art.svg', mediaType: 'image/svg+xml' }
    try {
        const nativeSection = await loader.loadItem({ href: 'OPS/native.xhtml', mediaType: 'application/xhtml+xml' })
        check(nativeSection === directURL, 'Native XHTML sections take the direct URL path')
        const url = await loader.loadItem(section)
        check(url?.startsWith('blob:'), 'Native SVG sections materialize through the Loader')
        check(directReads.length === 1 && directReads[0] === 'OPS/native.xhtml',
            'SVG sections and their dependencies bypass the direct XHTML URL callback')
        const output = await (await fetch(url)).text()
        const doc = new DOMParser().parseFromString(output, 'image/svg+xml')
        check(!doc.querySelector('parsererror'), 'Rewritten SVG remains valid XML')
        const href = id => doc.getElementById(id).getAttribute('href')
        check(href('modern')?.startsWith('blob:'), 'SVG image href must resolve from the archive')
        check(href('precedence') === href('modern'), 'Modern href takes precedence over legacy xlink')
        check(href('filterImage') === href('modern'), 'Filter image href must share the packaged resource')
        check(href('external')?.startsWith('blob:') && href('external').endsWith('#shape'),
            'External SVG use resolves the archive resource and preserves its fragment')
        const definitionURLs = [
            ['linear', 'linearSource'], ['radial', 'radialSource'], ['pattern', 'patternSource'],
            ['textPath', 'motion'], ['motionPath', 'motion'],
        ].map(([id, fragment]) => {
            const value = href(id)
            const suffix = `#${fragment}`
            check(value?.startsWith('blob:') && value.endsWith(suffix),
                `SVG ${id} resolves the packaged definition with its fragment`)
            return value.slice(0, -suffix.length)
        })
        check(new Set(definitionURLs).size === 1, 'SVG definitions share one materialized resource')
        check(reads.filter(path => path === 'OPS/assets/paint and motion.svg').length === 1,
            'The shared definition uses one exact archive read')
        check((await (await fetch(definitionURLs[0])).text()).includes('id="linearSource"'),
            'The shared Blob serves the packaged definitions')
        check(href('localPattern') === '#pattern' && href('emptyPattern') === '',
            'Same-document and empty modern references remain authored')
        check(href('remoteGradient') === 'https://example.invalid/paint.svg#gradient',
            'Remote SVG references remain authored')
        check(href('foreignPattern') === 'decoy.svg' && href('script') === 'decoy.svg',
            'Foreign namespace and script links remain authored')
        for (const id of ['linear', 'emptyPattern']) {
            check(doc.getElementById(id).getAttributeNS('http://www.w3.org/1999/xlink', 'href') === 'decoy.svg',
                'A present modern href prevents legacy rewriting')
        }
        check(!reads.includes('OPS/decoy.svg'), 'Foreign and ignored legacy references never load the packaged decoy')
        check(href('local') === '#shape', 'Local fragment references remain local')
        check(href('navigation') === 'chapter.xhtml#target', 'SVG navigation links remain authored')
        check(doc.getElementById('legacy').getAttributeNS('http://www.w3.org/1999/xlink', 'href')
            === href('modern'), 'Legacy resource links continue to resolve')
        check(reads.filter(path => path === 'OPS/pixel.svg').length === 1, 'Repeated resources share one cached URL')
        check(!reads.includes('OPS/missing.svg'), 'Ignored legacy href must not load')
        const image = new Image()
        image.src = href('modern')
        await image.decode()
        check(image.naturalWidth === 1 && image.naturalHeight === 1, 'Rewritten image bytes decode')
        loader.unloadItem(section)
        const retired = await Promise.allSettled([fetch(url), fetch(definitionURLs[0])])
        check(retired.every(result => result.status === 'rejected'),
            'Unloading the section revokes its SVG and shared definition URLs')
        await checkDefinitionReadOwnership(makeLoader, texts, section, 'OPS/assets/paint and motion.svg')
        return { passed: true, reads }
    } finally { loader.destroy() }
}

