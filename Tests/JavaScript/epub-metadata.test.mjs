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
                element('title', dc, { id: 'fixture-title' }, [], 'Metadata fixture'),
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
const metadataProperty = (property, value, attributes = {}) =>
    element('meta', metadataNamespace.opf, { property, ...attributes }, [], value)
const refinement = (id, property, value, attributes = {}) =>
    metadataProperty(property, value, { refines: '#' + id, ...attributes })

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

test('EPUB attaches encoded creator and contributor refinements in package order', async () => {
    const japaneseID = '著者𠮷'
    const book = makeMetadataBook([
        metadataElement('publisher', { id: 'publisher' }, 'Original Press'),
        refinement('%70ublisher', 'file-as', 'Press, Original'),
        metadataElement('creator', { id: 'translator' }, 'First Translator'),
        refinement('%74ranslator', 'role', 'trl', { scheme: 'marc:relators' }),
        refinement('translator', 'role', 'edt', { scheme: 'marc:relators' }),
        refinement('trans%6cator', 'role', 'trl'),
        refinement('translat%6Fr', 'file-as', 'Translator, First'),
        metadataElement('creator', { id: 'fallback' }, 'Fallback Creator'),
        refinement('fallback', 'role', 'trl', { scheme: 'custom:role' }),
        metadataElement('contributor', { id: japaneseID }, '日本の著者'),
        refinement(encodeURIComponent(japaneseID), 'role', 'aut', { scheme: 'marc:relators' }),
        refinement(encodeURIComponent(japaneseID), 'file-as', '著者、日本の'),
        metadataElement('contributor', { id: 'digital-press' }, 'Digital Press'),
        refinement('digital%2Dpress', 'role', 'pbl', { scheme: 'marc:relators' }),
        refinement('digital%2Dpress', 'file-as', 'Press, Digital'),
    ])
    try {
        await book.init()
        assert.deepEqual(book.rawMetadata.creator[0].role.map(role => role.value), ['trl', 'edt', 'trl'])
        const translator = { name: 'First Translator', sortAs: 'Translator, First' }
        assert.deepEqual(book.metadata.translator, [translator])
        assert.deepEqual(book.metadata.editor, [translator])
        assert.deepEqual(book.metadata.author, [
            { name: 'Fallback Creator', sortAs: null },
            { name: '日本の著者', sortAs: '著者、日本の' },
        ])
        assert.deepEqual(book.metadata.publisher, [
            { name: 'Original Press', sortAs: 'Press, Original' },
            { name: 'Digital Press', sortAs: 'Press, Digital' },
        ])
    } finally {
        book.destroy()
    }
})

test('EPUB keeps its first title while attaching encoded title refinements', async () => {
    const book = makeMetadataBook([
        metadataElement('title', { id: 'main-title' }, 'Later main title'),
        metadataElement('title', { id: 'subtitle' }, 'A secondary title'),
        refinement('main-%74itle', 'title-type', 'main'),
        refinement('main-%74itle', 'display-seq', '1'),
        refinement('%73ubtitle', 'title-type', 'subtitle'),
        refinement('fixture-%74itle', 'display-seq', '2'),
        refinement('fixture-%74itle', 'file-as', 'Fixture, Metadata'),
    ])
    try {
        await book.init()
        assert.equal(book.metadata.title, 'Metadata fixture')
        assert.equal(book.metadata.subtitle, 'A secondary title')
        assert.equal(book.metadata.sortAs, 'Fixture, Metadata')
        assert.deepEqual(book.rawMetadata.title.map(title => title.displaySeq), ['2', '1', null])
    } finally {
        book.destroy()
    }
})

test('EPUB fragment decoding preserves percent, case and Unicode identifier identity', async () => {
    const book = makeMetadataBook([
        metadataElement('creator', { id: 'literal%61' }, 'Literal percent'),
        metadataElement('creator', { id: 'literala' }, 'Decoded letter'),
        metadataElement('creator', { id: 'Example' }, 'Uppercase identifier'),
        metadataElement('creator', { id: 'example' }, 'Lowercase identifier'),
        metadataElement('creator', { id: 'café' }, 'Composed identifier'),
        metadataElement('creator', { id: 'cafe\u0301' }, 'Decomposed identifier'),
        refinement('literal%2561', 'file-as', 'Percent escape decoded once'),
        refinement('literal%61', 'file-as', 'Letter escape decoded once'),
        refinement('%45xample', 'file-as', 'Uppercase match'),
        refinement('%65xample', 'file-as', 'Lowercase match'),
        refinement('caf%C3%A9', 'file-as', 'Composed match'),
        refinement('cafe%cc%81', 'file-as', 'Decomposed match'),
    ])
    try {
        await book.init()
        assert.deepEqual(book.metadata.author.map(author => author.sortAs), [
            'Percent escape decoded once', 'Letter escape decoded once', 'Uppercase match',
            'Lowercase match', 'Composed match', 'Decomposed match',
        ])
    } finally {
        book.destroy()
    }
})

test('EPUB ignores malformed, empty and nonlocal refinements and still opens the chapter', async () => {
    const invalidReferences = ['#bad%ZZ', '#broken%E3%81', '#', '', 'book.opf#local', 'https://example.com/book.opf#local']
    const book = makeMetadataBook([
        metadataElement('creator', { id: 'bad%ZZ' }, 'Malformed escape fallback'),
        metadataElement('creator', { id: 'broken%E3%81' }, 'Truncated UTF-8 fallback'),
        metadataElement('creator', { id: 'local' }, 'Local author'),
        ...invalidReferences.flatMap(refines => [
            metadataProperty('role', 'trl', { refines }),
            metadataProperty('belongs-to-collection', 'Unattached refinement', { refines }),
        ]),
        refinement('%6Cocal', 'file-as', 'Author, Local'),
    ])
    try {
        await book.init()
        assert.equal(book.metadata.translator, undefined)
        assert.deepEqual(book.metadata.author, [
            { name: 'Malformed escape fallback', sortAs: null },
            { name: 'Truncated UTF-8 fallback', sortAs: null },
            { name: 'Local author', sortAs: 'Author, Local' },
        ])
        assert.deepEqual(book.rawMetadata.belongsToCollection, [])
        assert.equal(book.sections.length, 1)
        assert.equal(book.sections[0].id, 'OPS/chapter.xhtml')
        assert.equal((await book.sections[0].createDocument()).documentElement.localName, 'html')
    } finally {
        book.destroy()
    }
})

test('EPUB collection refinements skip active element cycles and preserve usable paths', async () => {
    const property = 'belongs-to-collection'
    const book = makeMetadataBook([
        metadataProperty(property, 'Self-loop root', { id: 'self' }),
        refinement('s%65lf', property, 'Self-loop node', { id: 'self' }),
        metadataProperty(property, 'Two-node root', { id: 'loop-root' }),
        refinement('loop-%72oot', property, 'First loop node', { id: 'loop-node' }),
        refinement('loop-%6Eode', property, 'Second loop node', { id: 'loop-root' }),
        refinement('loop-%72oot', property, 'Usable candidate after the back-edge'),
        metadataProperty(property, 'Another expression of the same tree', { id: 'loop-root' }),
        metadataProperty(property, 'Independent root', { id: 'other' }),
        refinement('%6Fther', property, 'Independent leaf'),
    ])
    try {
        await book.init()
        const paths = [
            ['Self-loop root', 'Self-loop node'],
            ['Two-node root', 'First loop node', 'Second loop node', 'Usable candidate after the back-edge'],
            ['Another expression of the same tree', 'First loop node', 'Second loop node', 'Usable candidate after the back-edge'],
            ['Independent root', 'Independent leaf'],
        ]
        assert.equal(book.rawMetadata.belongsToCollection.length, paths.length)
        for (const [index, path] of paths.entries()) {
            let collection = book.rawMetadata.belongsToCollection[index]
            for (const value of path) {
                assert.equal(collection?.value, value)
                collection = collection.belongsToCollection
            }
            assert.equal(collection, null)
        }
    } finally {
        book.destroy()
    }
})
