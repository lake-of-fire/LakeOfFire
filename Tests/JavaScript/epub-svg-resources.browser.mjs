import { Loader } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/epub.js'

const check = (condition, message) => { if (!condition) throw new Error(message) }

// Run in a browser: parsing, XML serialization, blob fetching and image decoding
// use the real platform. Only archive reads are controlled.
export async function runSVGResourceReferences() {
    const svgNS = 'http://www.w3.org/2000/svg'
    const source = `<svg xmlns="${svgNS}" xmlns:xlink="http://www.w3.org/1999/xlink">
      <image id="modern" href="pixel.svg"/>
      <image id="legacy" xlink:href="pixel.svg"/>
      <image id="precedence" href="pixel.svg" xlink:href="missing.svg"/>
      <use id="external" href="sprite.svg#shape"/>
      <use id="local" href="#shape"/>
      <filter id="filter"><feImage id="filterImage" href="pixel.svg"/></filter>
      <a id="navigation" href="chapter.xhtml#target"><text>Next</text></a>
      <g id="shape"><rect width="1" height="1"/></g>
    </svg>`
    const pixels = `<svg xmlns="${svgNS}" width="1" height="1"><rect width="1" height="1" fill="red"/></svg>`
    const texts = new Map([
        ['OPS/art.svg', source],
        ['OPS/pixel.svg', pixels],
        ['OPS/sprite.svg', `<svg xmlns="${svgNS}"><g id="shape"><rect width="1" height="1"/></g></svg>`],
    ])
    const reads = []
    const loader = new Loader({
        resources: { manifest: [...texts.keys()].map(href => ({ href, mediaType: 'image/svg+xml' })) },
        loadText: async href => { reads.push(href); return texts.get(href) },
        loadBlob: async () => { throw new Error('Unexpected binary archive read') },
    })
    try {
        const url = await loader.loadItem({ href: 'OPS/art.svg', mediaType: 'image/svg+xml' })
        const output = await (await fetch(url)).text()
        const doc = new DOMParser().parseFromString(output, 'image/svg+xml')
        check(!doc.querySelector('parsererror'), 'Rewritten SVG remains valid XML')
        const href = id => doc.getElementById(id).getAttribute('href')
        check(href('modern')?.startsWith('blob:'), 'SVG image href must resolve from the archive')
        check(href('precedence') === href('modern'), 'Modern href takes precedence over legacy xlink')
        check(href('filterImage') === href('modern'), 'Filter image href must share the packaged resource')
        check(href('external')?.startsWith('blob:') && href('external').endsWith('#shape'),
            'External SVG use resolves the archive resource and preserves its fragment')
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
        return { passed: true, reads }
    } finally { loader.destroy() }
}

