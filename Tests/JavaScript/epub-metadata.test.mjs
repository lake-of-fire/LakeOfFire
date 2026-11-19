import assert from 'node:assert/strict'
import test from 'node:test'

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
