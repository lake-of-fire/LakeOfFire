import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import test from 'node:test'
import { element, xmlDocument } from './xml-fixture.mjs'

globalThis.DOMParser = class {}
const { EPUB } = await import('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/epub.js')

const ns = {
    opf: 'http://www.idpf.org/2007/opf', dc: 'http://purl.org/dc/elements/1.1/',
    enc: 'http://www.w3.org/2001/04/xmlenc#', xhtml: 'http://www.w3.org/1999/xhtml',
    container: 'urn:oasis:names:tc:opendocument:xmlns:container',
}
const idpf = 'http://www.idpf.org/2008/embedding'
const adobe = 'http://ns.adobe.com/pdf/enc#RC'
const originalFont = Uint8Array.from({ length: 1300 }, (_, index) => index % 251)

const makeFixture = ({ algorithm = idpf, identifier = 'urn:uuid:12345678-abcd-4321-abcd-0123456789ab',
    filename = 'My Font.otf', loadBlob = null, referenceURI = null } = {}) => {
    const encodedFont = filename.split('/').map(encodeURIComponent).join('/')
    const literalPath = `OPS/fonts/${filename}`
    const link = element('link', ns.xhtml, { href: 'style.css' })
    const docs = new Map([
        ['container', xmlDocument(element('container', ns.container, {}, [
            element('rootfile', ns.container, { 'full-path': 'OPS/book.opf', 'media-type': 'application/oebps-package+xml' }),
        ]))],
        ['package', xmlDocument(element('package', ns.opf, { 'unique-identifier': 'uid' }, [
            element('metadata', ns.opf, {}, [element('identifier', ns.dc, { id: 'uid' }, [], identifier)]),
            element('manifest', ns.opf, {}, [
                element('item', ns.opf, { id: 'chapter', href: 'chapter.xhtml', 'media-type': 'application/xhtml+xml' }),
                element('item', ns.opf, { id: 'style', href: 'style.css', 'media-type': 'text/css' }),
                element('item', ns.opf, { id: 'font', href: `fonts/${encodedFont}`, 'media-type': 'font/otf' }),
            ]),
            element('spine', ns.opf, {}, [element('itemref', ns.opf, { idref: 'chapter' })]),
        ]))],
        ['encryption', xmlDocument(element('encryption', ns.enc, {}, [
            element('EncryptedData', ns.enc, {}, [
                element('EncryptionMethod', ns.enc, { Algorithm: algorithm }),
                element('CipherData', ns.enc, {}, [element('CipherReference', ns.enc, { URI: referenceURI ?? `OPS/fonts/${encodedFont}` })]),
            ]),
        ]))],
        ['chapter', xmlDocument(element('html', ns.xhtml, {}, [element('head', ns.xhtml, {}, [link]), element('body', ns.xhtml)]))],
    ])
    const globals = {
        DOMParser: globalThis.DOMParser, XMLSerializer: globalThis.XMLSerializer,
        ProcessingInstruction: globalThis.ProcessingInstruction, window: globalThis.window,
    }
    globalThis.DOMParser = class { parseFromString(text) { assert.ok(docs.has(text), text); return docs.get(text) } }
    globalThis.XMLSerializer = class {
        serializeToString() { return `<html><head><link href="${link.getAttribute('href')}"></head><body>Chapter</body></html>` }
    }
    globalThis.ProcessingInstruction = class {}
    globalThis.window ??= { innerWidth: 800, innerHeight: 600 }
    const key = algorithm === idpf
        ? createHash('sha1').update(identifier.replace(/[\u0020\u0009\u000d\u000a]/g, '')).digest()
        : Buffer.from(identifier.split(':').at(-1).replaceAll('-', ''), 'hex')
    const encoded = originalFont.map((byte, index) => index < (algorithm === idpf ? 1040 : 1024)
        ? byte ^ key[index % key.length] : byte)
    const texts = new Map([
        ['META-INF/container.xml', 'container'], ['OPS/book.opf', 'package'],
        ['META-INF/encryption.xml', 'encryption'], ['OPS/chapter.xhtml', 'chapter'],
        ['OPS/style.css', `@font-face { font-family: fixture; src: url("fonts/${encodedFont}"); }`],
    ])
    const book = new EPUB({
        loadText: async href => texts.get(href) ?? null,
        loadBlob: async href => {
            assert.equal(href, literalPath)
            return loadBlob ? await loadBlob() : new Blob([encoded])
        },
        getSize: () => 0,
        sha1: async value => new Uint8Array(createHash('sha1').update(value).digest()),
    })
    return {
        book,
        close() {
            book.destroy()
            Object.assign(globalThis, globals)
        },
    }
}

for (const referenceURI of ['OPS/fonts/bad%zz.otf', 'OPS/fonts/a%2Ffont.otf',
    'OPS/fonts/a%5Cfont.otf', 'OPS/fonts/a%2F..%2Ffont.otf']) {
    test(`invalid optional encryption reference leaves chapter loading available: ${referenceURI}`, async () => {
        const fixture = makeFixture({ filename: 'Font.otf', referenceURI })
        try {
            await fixture.book.init()
            const doc = await fixture.book.sections[0].createDocument()
            assert.equal(doc.documentElement.localName, 'html')
            assert.equal(fixture.book.sections[0].id, 'OPS/chapter.xhtml')
        } finally { fixture.close() }
    })
}

for (const filename of ['Font.otf', 'My Font.otf', '日本語.otf', 'literal%2F.otf', '100%.otf', 'Font#?.otf', '100%/Font#?.otf']) {
    test(`IDPF font decoding preserves the archive path ${filename}`, async () => {
        const fixture = makeFixture({ filename })
        try {
            await fixture.book.init()
            const chapterURL = await fixture.book.sections[0].load()
            const chapter = await (await fetch(chapterURL)).text()
            const styleURL = chapter.match(/href="([^"]+)"/)[1]
            const css = await (await fetch(styleURL)).text()
            const fontURL = css.match(/url\("([^"]+)"\)/)[1]
            assert.deepEqual(new Uint8Array(await (await fetch(fontURL)).arrayBuffer()), originalFont)
        } finally { fixture.close() }
    })
}

for (const identifier of ['urn:uuid:12345678-abcd-4321-abcd-0123456789ab', 'urn:uuid:12345678-ABCD-4321-ABCD-0123456789AB']) {
    test(`Adobe font decoding accepts UUID ${identifier}`, async () => {
        const fixture = makeFixture({ algorithm: adobe, identifier, filename: 'Font.otf' })
        try {
            await fixture.book.init()
            const chapter = await (await fetch(await fixture.book.sections[0].load())).text()
            const css = await (await fetch(chapter.match(/href="([^"]+)"/)[1])).text()
            const data = await (await fetch(css.match(/url\("([^"]+)"\)/)[1])).arrayBuffer()
            assert.deepEqual(new Uint8Array(data), originalFont)
        } finally { fixture.close() }
    })
}

test('retiring a book while an encrypted source read is held does not decode absent bytes', { timeout: 2000 }, async () => {
    const createObjectURL = URL.createObjectURL
    let publicationCount = 0
    URL.createObjectURL = (...args) => {
        publicationCount++
        return createObjectURL.call(URL, ...args)
    }
    let release
    let started
    const reading = new Promise(resolve => { started = resolve })
    const fixture = makeFixture({ filename: 'Font.otf', loadBlob: () => {
        started()
        return new Promise(resolve => { release = resolve })
    } })
    try {
        await fixture.book.init()
        const load = fixture.book.sections[0].load()
        await reading
        fixture.book.destroy()
        release(null)
        assert.equal(Boolean(await load), false)
        assert.equal(publicationCount, 0)
    } finally {
        release?.(null)
        fixture.close()
        URL.createObjectURL = createObjectURL
    }
})
