"""SVG spine resources through the shipped EPUB loader and Chromium XML DOM."""
import unittest

import test_book_endcap_shell as shell


FIXTURE = r'''async () => {
    const { EPUB } = await import('/load/viewer-assets/foliate-js/epub.js')
    window.checkSVG = (condition, message) => {
        if (!condition) throw new Error(message)
    }
    window.makeSVGBook = async source => {
        const reads = []
        const directReads = []
        const symbol = '<svg xmlns="http://www.w3.org/2000/svg"><defs>'
            + '<g id="shape"><rect width="23" height="17"/></g>'
            + '</defs></svg>'
        const texts = {
            'META-INF/container.xml': '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
                + '<rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/>'
                + '</rootfiles></container>',
            'OPS/book.opf': '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">'
                + '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">svg-resources</dc:identifier>'
                + '<dc:title>SVG Resources</dc:title><dc:language>en</dc:language></metadata><manifest>'
                + '<item id="svg" href="page.svg" media-type="image/svg+xml"/>'
                + '<item id="html" href="native.xhtml" media-type="application/xhtml+xml"/>'
                + '<item id="image" href="pictures/pixel%20%26%20one.png" media-type="image/png"/>'
                + '<item id="other" href="other.png" media-type="image/png"/>'
                + '<item id="decoy" href="decoy.png" media-type="image/png"/>'
                + '<item id="symbols" href="symbols.svg" media-type="image/svg+xml"/>'
                + '<item id="script" href="script.js" media-type="text/javascript"/>'
                + '</manifest><spine><itemref idref="svg"/><itemref idref="html"/></spine></package>',
            'OPS/page.svg': source,
            'OPS/symbols.svg': symbol,
        }
        const png = Uint8Array.from(atob(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='
        ), value => value.charCodeAt(0))
        let failOther = false
        const book = new EPUB({
            loadText: async href => {
                reads.push(href)
                if (href === 'META-INF/encryption.xml') return null
                if (!(href in texts)) throw new Error(`unexpected text read: ${href}`)
                return texts[href]
            },
            loadBlob: async href => {
                reads.push(href)
                if (href === 'OPS/other.png' && failOther) throw new Error('controlled SVG resource failure')
                if (!['OPS/pictures/pixel & one.png', 'OPS/other.png', 'OPS/decoy.png'].includes(href))
                    throw new Error(`unexpected blob read: ${href}`)
                return new Blob([png], { type: 'image/png' })
            },
            getSize: () => 100,
            replaceURL: async (href, mediaType) => {
                directReads.push([href, mediaType])
                checkSVG(href === 'OPS/native.xhtml', 'only HTML uses native direct sections')
                return 'data:application/xhtml+xml,<html xmlns="http://www.w3.org/1999/xhtml"/>'
            },
        })
        await book.init()
        checkSVG(book.sections.length === 2, 'actual EPUB spine was initialized')
        await book.sections[1].load()
        book.sections[1].unload()
        checkSVG(directReads.length === 1, 'native HTML direct URL callback is active')
        return { book, reads, directReads, failOther: value => { failOther = value } }
    }
    window.svgDocument = async url => {
        const source = await (await fetch(url)).text()
        const doc = new DOMParser().parseFromString(source, 'image/svg+xml')
        checkSVG(!doc.querySelector('parsererror'), 'rewritten SVG is valid XML')
        return doc
    }
    window.checkRevokedSVG = async urls => {
        for (const url of new Set(urls.map(value => value.split('#')[0]))) {
            checkSVG(!globalThis.__manabiBlobResourceMap?.has(url), 'released URL has no publication')
            let revoked = false
            try { await fetch(url) } catch (_) { revoked = true }
            checkSVG(revoked, 'released SVG dependency URL is revoked')
        }
    }
}'''


class EPUBSVGResourceTests(unittest.TestCase):
    setUpClass = classmethod(shell.BookEndcapShellTests.setUpClass.__func__)

    def new_fixture_page(self):
        page = self.browser.new_page()
        self.addCleanup(page.close)
        page.route('**/epub-svg-resources', lambda route: route.fulfill(
            status=200, content_type='text/html',
            body='<!doctype html><title>SVG resource fixture</title>'))
        page.goto(f'http://127.0.0.1:{self.server.server_port}/epub-svg-resources')
        page.evaluate(FIXTURE)
        return page

    def test_svg_spine_resolves_encoded_image_and_renders_external_use(self):
        page = self.new_fixture_page()
        result = page.evaluate(r'''async () => {
            const fixture = await makeSVGBook(`<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
                <image id="image" width="10" height="10" href="pictures/pixel%20%26%20one.png"/>
                <use id="use" href="symbols.svg#shape" x="20" y="20"/>
            </svg>`)
            const frame = document.createElement('iframe')
            try {
                const url = await fixture.book.sections[0].load()
                checkSVG(url.startsWith('blob:'), 'SVG spine uses Loader materialization')
                checkSVG(fixture.directReads.length === 1, 'SVG does not bypass resource rewriting')
                const doc = await svgDocument(url)
                const imageURL = doc.getElementById('image').getAttribute('href')
                const useURL = doc.getElementById('use').getAttribute('href')
                checkSVG(imageURL.startsWith('blob:'), 'encoded image path resolves to its manifest resource')
                checkSVG(useURL.startsWith('blob:') && useURL.endsWith('#shape'), 'external use fragment survives')
                checkSVG((await (await fetch(imageURL)).blob()).type === 'image/png', 'image payload is readable')
                checkSVG((await (await fetch(useURL)).text()).includes('width="23"'), 'symbol payload is readable')
                await new Promise((resolve, reject) => {
                    frame.onload = resolve
                    frame.onerror = () => reject(new Error('SVG frame failed to load'))
                    frame.src = url
                    document.body.append(frame)
                })
                const use = frame.contentDocument.getElementById('use')
                const bounds = use.getBBox()
                checkSVG(bounds.width === 23 && bounds.height === 17, 'external SVG use renders its referenced geometry')
                frame.remove()
                fixture.book.sections[0].unload()
                await checkRevokedSVG([url, imageURL, useURL])
                return { width: bounds.width, height: bounds.height, reads: fixture.reads }
            } finally {
                frame.remove()
                fixture.book.destroy()
            }
        }''')
        self.assertEqual((result['width'], result['height']), (23, 17))
        self.assertIn('OPS/pictures/pixel & one.png', result['reads'])

    def test_plain_href_precedence_and_nonresource_controls(self):
        page = self.new_fixture_page()
        result = page.evaluate(r'''async () => {
            const fixture = await makeSVGBook(`<svg xmlns="http://www.w3.org/2000/svg"
                xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:foreign="urn:foreign">
                <image id="both" href="other.png" xlink:href="decoy.png"/>
                <image id="empty" href="" xlink:href="decoy.png"/>
                <image id="legacy" xlink:href="pictures/pixel%20%26%20one.png"/>
                <use id="local" href="#local-shape"/>
                <image id="remote" href="https://example.invalid/image.png"/>
                <a id="anchor" href="decoy.png"><text>Link</text></a>
                <script id="script" href="script.js"/>
                <foreign:image id="foreign" href="decoy.png"/>
            </svg>`)
            try {
                const url = await fixture.book.sections[0].load()
                const doc = await svgDocument(url)
                const attr = id => doc.getElementById(id).getAttribute('href')
                const xlink = id => doc.getElementById(id).getAttributeNS('http://www.w3.org/1999/xlink', 'href')
                checkSVG(attr('both').startsWith('blob:'), 'plain href is materialized')
                checkSVG(xlink('both') === 'decoy.png', 'plain href retains precedence over xlink')
                checkSVG(attr('empty') === '' && xlink('empty') === 'decoy.png', 'empty plain href still suppresses fallback')
                checkSVG(xlink('legacy').startsWith('blob:'), 'legacy xlink reference remains supported')
                checkSVG(attr('local') === '#local-shape', 'local fragment is retained')
                checkSVG(attr('remote') === 'https://example.invalid/image.png', 'external resource stays external')
                checkSVG(attr('anchor') === 'decoy.png', 'navigation reference is retained')
                checkSVG(attr('script') === 'script.js', 'script reference is retained')
                checkSVG(attr('foreign') === 'decoy.png', 'foreign namespace is retained')
                checkSVG(!fixture.reads.includes('OPS/decoy.png'), 'fallback and nonresource controls do not load decoys')
                fixture.book.sections[0].unload()
                await checkRevokedSVG([url, attr('both'), xlink('legacy')])
                return fixture.directReads.length
            } finally { fixture.book.destroy() }
        }''')
        self.assertEqual(result, 1)

    def test_prefixed_svg_resource_elements_resolve_without_rewriting_navigation(self):
        page = self.new_fixture_page()
        result = page.evaluate(r'''async () => {
            const names = ['feImage', 'linearGradient', 'radialGradient', 'pattern', 'textPath', 'mpath']
            const fixture = await makeSVGBook(`<s:svg xmlns:s="http://www.w3.org/2000/svg">
                ${names.map(name => `<s:${name} id="${name}" href="symbols.svg#shape"/>`).join('')}
                <s:a id="link" href="symbols.svg#shape"/>
            </s:svg>`)
            try {
                const url = await fixture.book.sections[0].load()
                const doc = await svgDocument(url)
                const urls = names.map(name => doc.getElementById(name).getAttribute('href'))
                checkSVG(urls.every(value => value.startsWith('blob:') && value.endsWith('#shape')),
                    'every SVG resource element resolves in its namespace, including prefixed names')
                checkSVG(new Set(urls).size === 1, 'shared SVG dependencies retain one publication')
                checkSVG(doc.getElementById('link').getAttribute('href') === 'symbols.svg#shape', 'SVG navigation is untouched')
                fixture.book.sections[0].unload()
                await checkRevokedSVG([url, ...urls])
                return fixture.reads.filter(value => value === 'OPS/symbols.svg').length
            } finally { fixture.book.destroy() }
        }''')
        self.assertEqual(result, 1)

    def test_failed_resource_load_rolls_back_and_concurrent_retry_releases_on_last_unload(self):
        page = self.new_fixture_page()
        result = page.evaluate(r'''async () => {
            const fixture = await makeSVGBook(`<svg xmlns="http://www.w3.org/2000/svg">
                <image id="first" href="pictures/pixel%20%26%20one.png"/>
                <image id="second" href="other.png"/>
            </svg>`)
            try {
                fixture.failOther(true)
                let failed = false
                try { await fixture.book.sections[0].load() }
                catch (error) { failed = error.message === 'controlled SVG resource failure' }
                checkSVG(failed, 'resource failure reaches actual section caller')
                checkSVG((globalThis.__manabiBlobResourceMap?.size ?? 0) === 0, 'failed SVG releases preceding dependency')
                fixture.failOther(false)
                const [first, second] = await Promise.all([
                    fixture.book.sections[0].load(), fixture.book.sections[0].load(),
                ])
                checkSVG(first === second && first.startsWith('blob:'), 'retry consumers share one section publication')
                const doc = await svgDocument(first)
                const children = ['first', 'second'].map(id => doc.getElementById(id).getAttribute('href'))
                checkSVG(children.every(value => value.startsWith('blob:')), 'retry resolves both resources')
                fixture.book.sections[0].unload()
                for (const url of [first, ...children]) checkSVG((await fetch(url)).ok, 'remaining consumer retains dependency tree')
                fixture.book.sections[0].unload()
                await checkRevokedSVG([first, ...children])
                return fixture.reads.filter(value => value === 'OPS/other.png').length
            } finally { fixture.book.destroy() }
        }''')
        self.assertEqual(result, 2)


if __name__ == '__main__':
    unittest.main()
