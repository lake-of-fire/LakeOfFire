import assert from 'node:assert/strict'
import test from 'node:test'
import { element, xmlDocument } from './xml-fixture.mjs'

globalThis.DOMParser = class {}

const { EPUB } = await import(
    '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/epub.js'
)

const makeBook = loadText => new EPUB({
    loadText,
    loadBlob: async () => null,
    getSize: () => 0,
})

const encodedBookmarks = bookmarks => 'encoding=json+base64:'
    + Buffer.from(JSON.stringify(bookmarks), 'utf8').toString('base64')

for (const [label, note] of [
    ['Japanese and supplementary characters', '日本語の注釈。📖𠮷'],
    ['combining characters and quotes', 'cafe\u0301 "citation" — naïve'],
    ['ASCII', 'A plain note.'],
]) {
    test(`Calibre annotations preserve ${label}`, async () => {
        const bookmarks = [{ type: 'highlight', notes: note, spine_index: 2 }]
        const book = makeBook(async path => {
            assert.equal(path, 'META-INF/calibre_bookmarks.txt')
            return encodedBookmarks(bookmarks)
        })
        try {
            assert.deepEqual(await book.getCalibreBookmarks(), bookmarks)
        } finally {
            book.destroy()
        }
    })
}

test('absent or unsupported Calibre bookmark payloads remain absent', async () => {
    for (const text of [null, '', 'unsupported bookmark format']) {
        const book = makeBook(async () => text)
        try {
            assert.equal(await book.getCalibreBookmarks(), undefined)
        } finally {
            book.destroy()
        }
    }
})

test('malformed Calibre base64 and JSON are rejected', async () => {
    for (const suffix of ['#', Buffer.from('{').toString('base64')]) {
        const book = makeBook(async () => 'encoding=json+base64:' + suffix)
        try {
            await assert.rejects(book.getCalibreBookmarks())
        } finally {
            book.destroy()
        }
    }
})

const smilNamespace = 'http://www.w3.org/ns/SMIL'
const smilElement = (localName, attributes) => ({
    localName,
    namespaceURI: smilNamespace,
    getAttribute: name => attributes[name] ?? null,
})

for (const [label, begin, end, expectedBegin, expectedEnd] of [
    ['milliseconds', '250ms', '1250ms', 0.25, 1.25],
    ['minutes', '1.5min', '2min', 90, 120],
    ['seconds', '1s', '2.5s', 1, 2.5],
    ['hours', '1h', '1.5h', 3600, 5400],
    ['full clocks', '00:02:03.5', '01:00:00', 123.5, 3600],
    ['partial clocks', '02:03.5', '03:00', 123.5, 180],
    ['unitless seconds', '1.25', '3', 1.25, 3],
]) {
    test(`media-overlay clip boundaries interpret ${label}`, async () => {
        const book = makeBook(async path => {
            assert.equal(path, 'OPS/media/chapter.smil')
            return '<smil/>'
        })
        const par = {
            children: [
                smilElement('text', { src: '../chapter.xhtml#sentence-1' }),
                smilElement('audio', { src: '../audio/chapter.mp3', clipBegin: begin, clipEnd: end }),
            ],
        }
        // The parser boundary supplies a SMIL document; production traversal,
        // relative URL resolution and clock conversion run unchanged.
        book.parser = {
            parseFromString: (text, mediaType) => {
                assert.equal(text, '<smil/>')
                assert.equal(mediaType, 'application/xml')
                return {
                    lookupNamespaceURI: () => smilNamespace,
                    querySelector: () => null,
                    getElementsByTagNameNS: (namespace, name) => {
                        assert.equal(namespace, smilNamespace)
                        return name === 'par' ? [par] : []
                    },
                }
            },
        }
        book.resources = {
            getItemByID: id => {
                assert.equal(id, 'overlay')
                return { href: 'OPS/media/chapter.smil' }
            },
        }
        try {
            assert.deepEqual(await book.loadMediaOverlay({ mediaOverlay: 'overlay' }), [{
                id: 'sentence-1',
                audio: { src: 'OPS/audio/chapter.mp3', clipBegin: expectedBegin, clipEnd: expectedEnd },
            }])
        } finally {
            book.destroy()
        }
    })
}

const metadataNamespace = {
    opf: 'http://www.idpf.org/2007/opf',
    dc: 'http://purl.org/dc/elements/1.1/',
    container: 'urn:oasis:names:tc:opendocument:xmlns:container',
    xhtml: 'http://www.w3.org/1999/xhtml',
}

const makeMetadataBook = metadata => {
    const { opf, dc, container, xhtml } = metadataNamespace
    const documents = new Map([
        ['META-INF/container.xml', xmlDocument(element('container', container, {}, [
            element('rootfile', container, {
                'full-path': 'OPS/book.opf',
                'media-type': 'application/oebps-package+xml',
            }),
        ]))],
        ['OPS/book.opf', xmlDocument(element('package', opf, { 'unique-identifier': 'uid' }, [
            element('metadata', opf, {}, [
                element('identifier', dc, { id: 'uid' }, [], 'urn:metadata-fixture'),
                element('title', dc, {}, [], 'Metadata fixture'),
                element('language', dc, {}, [], 'en'),
                ...metadata,
            ]),
            element('manifest', opf, {}, [
                element('item', opf, {
                    id: 'chapter', href: 'chapter.xhtml',
                    'media-type': 'application/xhtml+xml',
                }),
            ]),
            element('spine', opf, {}, [element('itemref', opf, { idref: 'chapter' })]),
        ]))],
        ['OPS/chapter.xhtml', xmlDocument(element('html', xhtml, {}, [
            element('head', xhtml), element('body', xhtml, {}, [], 'Chapter'),
        ]))],
    ])
    const book = makeBook(async path => documents.has(path) ? path : null)
    // The maintained XML fixture supplies parser output; EPUB.init performs
    // the production metadata traversal, role mapping and section creation.
    book.parser = { parseFromString: text => documents.get(text) }
    return book
}

const metadataElement = (name, attributes, value) =>
    element(name, metadataNamespace.dc, attributes, [], value)
const refinement = (id, property, value, attributes = {}) =>
    element('meta', metadataNamespace.opf, {
        refines: '#' + id, property, ...attributes,
    }, [], value)

for (const name of ['creator', 'contributor']) {
    test('EPUB opens with a DC publisher and publisher-role ' + name, async () => {
        const book = makeMetadataBook([
            metadataElement('publisher', { id: 'publisher' }, 'Original Press'),
            refinement('publisher', 'file-as', 'Press, Original'),
            metadataElement(name, { id: 'role-publisher' }, 'Digital Press'),
            refinement('role-publisher', 'role', 'pbl', { scheme: 'marc:relators' }),
            refinement('role-publisher', 'file-as', 'Press, Digital'),
        ])
        try {
            await book.init()
            assert.deepEqual(book.metadata.publisher, [
                { name: 'Original Press', sortAs: 'Press, Original' },
                { name: 'Digital Press', sortAs: 'Press, Digital' },
            ])
            assert.equal(book.metadata.title, 'Metadata fixture')
            assert.equal(book.sections.length, 1)
            assert.equal((await book.sections[0].createDocument()).documentElement.localName, 'html')
        } finally {
            book.destroy()
        }
    })
}

test('EPUB keeps multiple publisher roles and other contributor roles in order', async () => {
    const book = makeMetadataBook([
        metadataElement('publisher', {}, 'Original Press'),
        metadataElement('creator', { id: 'first' }, 'Author and Publisher'),
        refinement('first', 'role', 'aut', { scheme: 'marc:relators' }),
        refinement('first', 'role', 'pbl', { scheme: 'marc:relators' }),
        refinement('first', 'role', 'pbl', { scheme: 'marc:relators' }),
        metadataElement('contributor', { id: 'second' }, 'Second Publisher'),
        refinement('second', 'role', 'pbl', { scheme: 'marc:relators' }),
    ])
    try {
        await book.init()
        assert.deepEqual(book.metadata.publisher, [
            { name: 'Original Press', sortAs: null },
            { name: 'Author and Publisher', sortAs: null },
            { name: 'Second Publisher', sortAs: null },
        ])
        assert.deepEqual(book.metadata.author, [{ name: 'Author and Publisher', sortAs: null }])
    } finally {
        book.destroy()
    }
})

test('EPUB preserves the existing plain publisher and role-only metadata forms', async () => {
    for (const [metadata, expected] of [
        [[metadataElement('publisher', {}, 'Plain Publisher')], 'Plain Publisher'],
        [[
            metadataElement('contributor', { id: 'only' }, 'Role Publisher'),
            refinement('only', 'role', 'pbl', { scheme: 'marc:relators' }),
        ], [{ name: 'Role Publisher', sortAs: null }]],
        [[
            metadataElement('publisher', {}, ''),
            metadataElement('contributor', { id: 'only' }, 'Role Publisher'),
            refinement('only', 'role', 'pbl', { scheme: 'marc:relators' }),
        ], [{ name: 'Role Publisher', sortAs: null }]],
    ]) {
        const book = makeMetadataBook(metadata)
        try {
            await book.init()
            assert.deepEqual(book.metadata.publisher, expected)
        } finally {
            book.destroy()
        }
    }
})
