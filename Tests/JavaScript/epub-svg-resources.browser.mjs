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

export async function runSVGStylesheetInstructions() {
    const svgNS = 'http://www.w3.org/2000/svg'
    const externalHref = '//invalid.invalid/OPS/ignored.css?sig=a%2Bb&amp;v=1#part'
    const source = `<?xml version="1.0"?>
<?xml-stylesheet type="text/css"  href="first.css" media="screen"?>
<!-- between stylesheet instructions -->
<?custom href="ignored.css"?>
<!DOCTYPE svg>
<?xml-stylesheet title="Literal href='ignored.css'" href='second%23%3F%252F.css?rev=2' type='text/css'?>
<?xml-stylesheet href="#within"?>
<?xml-stylesheet href="${externalHref}"?>
<?XML-stylesheet href="ignored.css"?>
<svg xmlns="${svgNS}"><?xml-stylesheet href="ignored.css"?><rect width="1" height="1"/></svg>
<?xml-stylesheet href="ignored.css"?>`
    const firstCSS = 'rect { fill: red }'
    const secondCSS = 'rect { stroke: blue }'
    const secondPath = 'OPS/second#?%2F.css'
    const entries = new Map([
        ['OPS/art.svg', source],
        ['OPS/first.css', firstCSS],
        [secondPath, secondCSS],
        ['OPS/ignored.css', 'rect { fill: green }'],
    ])
    const reads = []
    const manifest = [...entries.keys()].map(href => ({
        href, mediaType: href.endsWith('.svg') ? 'image/svg+xml' : 'text/css',
    }))
    const loader = new Loader({
        resources: { manifest },
        loadText: async href => { reads.push(href); return entries.get(href) },
        loadBlob: async () => { throw new Error('Unexpected binary archive read') },
    })
    try {
        const url = await loader.loadItem(manifest[0])
        const output = await (await fetch(url)).text()
        const doc = new DOMParser().parseFromString(output, 'image/svg+xml')
        check(!doc.querySelector('parsererror'), 'Rewritten SVG with stylesheet instructions remains valid XML')
        const children = Array.from(doc.childNodes)
        const prolog = children.slice(0, children.indexOf(doc.documentElement))
        const instructions = prolog.filter(node => node instanceof ProcessingInstruction)
        check(instructions.map(node => node.target).join(' ')
            === 'xml-stylesheet custom xml-stylesheet xml-stylesheet xml-stylesheet XML-stylesheet',
        'Prolog instruction order and target spellings are preserved')
        check(prolog.some(node => node.nodeType === Node.COMMENT_NODE) && doc.doctype?.name === 'svg',
            'Comment and doctype remain in the prolog')
        const first = instructions[0].data.match(/^type="text\/css"  href="(blob:[^"]+)" media="screen"$/)?.[1]
        const second = instructions[2].data.match(/^title="Literal href='ignored\.css'" href='(blob:[^']+)' type='text\/css'$/)?.[1]
        check(first, 'The first stylesheet resolves without changing pseudo-attribute whitespace or quotes')
        check(second, 'The second stylesheet resolves after other prolog nodes without changing its title')
        check(await (await fetch(first)).text() === firstCSS, 'The first stylesheet blob has the first archive member')
        check(await (await fetch(second)).text() === secondCSS, 'The second stylesheet blob has the exact escaped archive member')
        check(instructions[1].data === 'href="ignored.css"', 'Unrelated processing instructions remain authored')
        check(instructions[3].data === 'href="#within"', 'Same-document stylesheet references remain authored')
        check(instructions[4].data === `href="https:${externalHref}"`, 'External stylesheet query, escapes and fragment are preserved')
        check(instructions[5].data === 'href="ignored.css"', 'A differently cased target remains authored')
        check(doc.documentElement.firstChild?.data === 'href="ignored.css"', 'Nested processing instructions remain authored')
        check(doc.documentElement.nextSibling?.data === 'href="ignored.css"', 'Post-root processing instructions remain authored')
        check(reads.join(' ') === `OPS/art.svg OPS/first.css ${secondPath}`, 'Only the two packaged stylesheets are read')
        return { passed: true, reads }
    } finally { loader.destroy() }
}

