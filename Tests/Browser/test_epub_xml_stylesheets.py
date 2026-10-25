"""Exercise shipped EPUB resource rewriting with the browser's real XML DOM.

Run alongside the existing loopback browser suite. No source extraction or DOM
substitute is used; Node collaborator tests cover additional ownership failures.
"""
import unittest

import test_book_endcap_shell as shell


class EPUBXMLStylesheetTests(unittest.TestCase):
    setUpClass = classmethod(shell.BookEndcapShellTests.setUpClass.__func__)

    def new_fixture_page(self):
        page = self.browser.new_page()
        self.addCleanup(page.close)
        page.route(
            "**/epub-xml-stylesheets",
            lambda route: route.fulfill(
                status=200,
                content_type="text/html",
                body="<!doctype html><title>EPUB resource fixture</title>",
            ),
        )
        page.goto(
            f"http://127.0.0.1:{self.server.server_port}/epub-xml-stylesheets"
        )
        return page

    def test_multiple_stylesheets_preserve_pseudoattributes_and_release_resources(self):
        page = self.new_fixture_page()
        result = page.evaluate(r'''async () => {
            const { Loader } = await import(
                '/load/viewer-assets/foliate-js/epub.js'
            )
            const check = (value, message) => {
                if (!value) throw new Error(message)
            }
            const image = { href: 'OPS/image.svg', mediaType: 'image/svg+xml' }
            const first = { href: 'OPS/first.css', mediaType: 'text/css' }
            const second = { href: 'OPS/second.css', mediaType: 'text/css' }
            const decoy = { href: 'OPS/decoy.css', mediaType: 'text/css' }
            const source = `<!-- leading comment -->
                <!DOCTYPE svg>
                <?xml-stylesheet type="text/css" href="first.css" media="all"?>
                <!-- between stylesheets -->
                <?xml-stylesheet data-href="decoy.css" title="href='decoy.css'" href='second.css'?>
                <svg xmlns="http://www.w3.org/2000/svg"><rect width="10" height="10"/></svg>`
            const reads = []
            const loader = new Loader({
                resources: { manifest: [image, first, second, decoy] },
                loadText: async href => {
                    reads.push(href)
                    return href === image.href ? source : 'rect { fill: green }'
                },
                loadBlob: async () => { throw new Error('unexpected raw load') },
            })
            try {
                const imageURL = await loader.loadItem(image)
                const text = await (await fetch(imageURL)).text()
                const doc = new DOMParser().parseFromString(text, 'image/svg+xml')
                check(!doc.querySelector('parsererror'), 'rewritten SVG must remain XML')
                const instructions = [...doc.childNodes].filter(node =>
                    node.nodeType === Node.PROCESSING_INSTRUCTION_NODE
                )
                check(instructions.length === 2, 'both stylesheet instructions survive')
                const attributes = instructions.map(instruction => {
                    const parsed = new DOMParser().parseFromString(
                        `<attributes ${instruction.data}/>`, 'application/xml'
                    )
                    check(!parsed.querySelector('parsererror'), 'pseudoattributes remain separated')
                    return parsed.documentElement
                })
                check(attributes[0].getAttribute('type') === 'text/css', 'type survives')
                check(attributes[0].getAttribute('media') === 'all', 'media survives')
                check(attributes[1].getAttribute('data-href') === 'decoy.css', 'data-href survives')
                check(attributes[1].getAttribute('title') === "href='decoy.css'", 'quoted decoy survives')
                const styles = attributes.map(value => value.getAttribute('href'))
                check(styles.every(url => url.startsWith('blob:')), 'both package styles are resolved')
                check(styles[0] !== styles[1], 'distinct manifest resources retain distinct URLs')
                for (const url of styles) {
                    check((await (await fetch(url)).text()).includes('fill: green'), 'stylesheet is readable')
                }
                check(!reads.includes(decoy.href), 'non-href values never request resources')
                loader.unloadItem(image)
                for (const url of [imageURL, ...styles]) {
                    check(!globalThis.__manabiBlobResourceMap?.has(url), 'resource publication is released')
                    let revoked = false
                    try { await fetch(url) } catch (_) { revoked = true }
                    check(revoked, 'released object URL is revoked')
                }
                return { instructions: instructions.length, reads }
            } finally {
                loader.destroy()
            }
        }''')
        self.assertEqual(result["instructions"], 2)
        self.assertEqual(
            result["reads"], ["OPS/image.svg", "OPS/first.css", "OPS/second.css"]
        )

    def test_failed_stylesheet_load_rolls_back_and_can_retry(self):
        page = self.new_fixture_page()
        result = page.evaluate(r'''async () => {
            const { Loader } = await import(
                '/load/viewer-assets/foliate-js/epub.js'
            )
            const check = (value, message) => {
                if (!value) throw new Error(message)
            }
            const image = { href: 'image.svg', mediaType: 'image/svg+xml' }
            const styles = ['one.css', 'two.css'].map(href => ({ href, mediaType: 'text/css' }))
            let refuseSecond = true
            const reads = []
            const loader = new Loader({
                resources: { manifest: [image, ...styles] },
                loadText: async href => {
                    reads.push(href)
                    if (href === image.href) return `<?xml-stylesheet href="one.css"?>
                        <?xml-stylesheet href="two.css"?>
                        <svg xmlns="http://www.w3.org/2000/svg"/>`
                    if (href === 'two.css' && refuseSecond) throw new Error('controlled read failure')
                    return 'svg { color: black }'
                },
                loadBlob: async () => null,
            })
            try {
                let failed = false
                try { await loader.loadItem(image) }
                catch (error) { failed = error.message === 'controlled read failure' }
                check(failed, 'second stylesheet failure reaches the caller')
                check((globalThis.__manabiBlobResourceMap?.size ?? 0) === 0, 'failed parent releases first child')
                refuseSecond = false
                const [first, second] = await Promise.all([
                    loader.loadItem(image), loader.loadItem(image),
                ])
                check(first === second && first.startsWith('blob:'), 'retry consumers share the committed resource')
                loader.unloadItem(image)
                check(globalThis.__manabiBlobResourceMap?.size === 3, 'remaining reader retains parent and children')
                loader.unloadItem(image)
                check(globalThis.__manabiBlobResourceMap?.size === 0, 'last reader releases the full dependency tree')
                return reads
            } finally {
                loader.destroy()
            }
        }''')
        self.assertEqual(
            result,
            ["image.svg", "one.css", "two.css", "image.svg", "one.css", "two.css"],
        )

    def test_encoded_stylesheet_references_round_trip_through_native_xml_and_apply(self):
        page = self.new_fixture_page()
        result = page.evaluate(r'''async () => {
            const { Loader } = await import('/load/viewer-assets/foliate-js/epub.js')
            const check = (value, message) => {
                if (!value) throw new Error(message)
            }
            const parser = new DOMParser()
            const image = { href: 'OPS/image.svg', mediaType: 'image/svg+xml' }
            // Actual XML attributes decode references when constructing the
            // manifest; PI.data retains their spelling until our Loader runs.
            const opf = parser.parseFromString(`<manifest>
                <item href="theme&amp;night.css"/>
                <item href="other&#46;css"/>
                <item href="other&amp;"/>
            </manifest>`, 'application/xml')
            const styles = [...opf.querySelectorAll('item')].map(item => ({
                href: `OPS/${item.getAttribute('href')}`, mediaType: 'text/css',
            }))
            check(styles[0].href === 'OPS/theme&night.css', 'manifest ampersand is decoded')
            check(styles[1].href === 'OPS/other.css', 'manifest numeric reference is decoded')
            const source = `<?xml-stylesheet type="text/css" href='theme&amp;night.css#reader&apos;s&amp;page'?>
                <?xml-stylesheet type="text/css" href="other&#46;css&#35;part"?>
                <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
                    <rect id="sample" width="10" height="10"/>
                </svg>`
            const original = parser.parseFromString(source, 'image/svg+xml')
            const instructions = document => [...document.childNodes].filter(node =>
                node.nodeType === Node.PROCESSING_INSTRUCTION_NODE)
            check(instructions(original)[0].data.includes('&amp;'), 'native PI data remains encoded')
            check(instructions(original)[1].data.includes('&#46;'), 'native PI numeric spelling is retained')
            const reads = []
            const loader = new Loader({
                resources: { manifest: [image, ...styles] },
                loadText: async href => {
                    reads.push(href)
                    if (href === image.href) return source
                    if (href === styles[0].href) return 'rect { fill: rgb(4, 5, 6); stroke: rgb(7, 8, 9) }'
                    if (href === styles[1].href) return 'rect { fill: rgb(1, 2, 3) }'
                    throw new Error(`wrong manifest resource loaded: ${href}`)
                },
                loadBlob: async () => { throw new Error('unexpected raw resource') },
            })
            const frame = document.createElement('iframe')
            try {
                const imageURL = await loader.loadItem(image)
                const serialized = await (await fetch(imageURL)).text()
                const rewritten = parser.parseFromString(serialized, 'image/svg+xml')
                check(!rewritten.querySelector('parsererror'), 'rewritten SVG remains XML')
                const values = instructions(rewritten).map(instruction => {
                    const attributes = parser.parseFromString(
                        `<attributes ${instruction.data}/>`, 'application/xml')
                    check(!attributes.querySelector('parsererror'), 'href keeps valid pseudoattribute quoting')
                    return attributes.documentElement.getAttribute('href')
                })
                check(values[0].startsWith('blob:') && values[0].endsWith("#reader's&page"),
                    'ampersand and quote survive the pseudoattribute round trip')
                check(values[1].startsWith('blob:') && values[1].endsWith('#part'),
                    'numeric fragment separator is decoded before URL resolution')
                // Load completion, rather than a sleep, waits for the SVG and
                // its stylesheet resources before inspecting visible styling.
                await new Promise((resolve, reject) => {
                    frame.onload = resolve
                    frame.onerror = () => reject(new Error('rewritten SVG failed to load'))
                    frame.src = imageURL
                    document.body.append(frame)
                })
                const rect = frame.contentDocument.getElementById('sample')
                const computedStyle = frame.contentWindow.getComputedStyle(rect)
                const fill = computedStyle.fill
                const stroke = computedStyle.stroke
                check(fill === 'rgb(1, 2, 3)', 'resolved stylesheets apply in document order')
                check(stroke === 'rgb(7, 8, 9)', 'first resolved stylesheet applies independently of the later fill override')
                frame.remove()
                loader.unloadItem(image)
                for (const url of [imageURL, ...values.map(value => value.split('#')[0])]) {
                    check(!globalThis.__manabiBlobResourceMap?.has(url), 'decoded resource ownership is released')
                    let revoked = false
                    try { await fetch(url) } catch (_) { revoked = true }
                    check(revoked, 'decoded resource URL is revoked')
                }
                return { reads, fill, stroke }
            } finally {
                frame.remove()
                loader.destroy()
            }
        }''')
        self.assertEqual(result["reads"], ["OPS/image.svg", "OPS/theme&night.css", "OPS/other.css"])
        self.assertEqual(result["fill"], "rgb(1, 2, 3)")
        self.assertEqual(result["stroke"], "rgb(7, 8, 9)")

    def test_nonstylesheet_and_trailing_instructions_never_load_dependencies(self):
        page = self.new_fixture_page()
        result = page.evaluate(r'''async () => {
            const { Loader } = await import('/load/viewer-assets/foliate-js/epub.js')
            const image = { href: 'image.svg', mediaType: 'image/svg+xml' }
            const source = `<!--generated--><?editor href="editor.css"?>
                <?xml-stylesheet HREF="uppercase.css"?>
                <svg xmlns="http://www.w3.org/2000/svg"/>
                <?xml-stylesheet href="trailing.css"?>`
            const reads = []
            const loader = new Loader({
                resources: { manifest: [image, ...['editor.css', 'uppercase.css', 'trailing.css']
                    .map(href => ({ href, mediaType: 'text/css' }))] },
                loadText: async href => {
                    reads.push(href)
                    if (href !== image.href) throw new Error('unrelated PI resource was loaded')
                    return source
                },
                loadBlob: async () => null,
            })
            try {
                const text = await (await fetch(await loader.loadItem(image))).text()
                const doc = new DOMParser().parseFromString(text, 'image/svg+xml')
                return {
                    reads,
                    instructions: [...doc.childNodes]
                        .filter(node => node.nodeType === Node.PROCESSING_INSTRUCTION_NODE)
                        .map(node => [node.target, node.data]),
                }
            } finally {
                loader.destroy()
            }
        }''')
        self.assertEqual(result["reads"], ["image.svg"])
        self.assertEqual(result["instructions"], [
            ["editor", 'href="editor.css"'],
            ["xml-stylesheet", 'HREF="uppercase.css"'],
            ["xml-stylesheet", 'href="trailing.css"'],
        ])


if __name__ == "__main__":
    unittest.main(verbosity=2)
