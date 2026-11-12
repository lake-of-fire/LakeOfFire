import assert from 'node:assert/strict'
import test from 'node:test'

globalThis.DOMParser ??= class DOMParser {}
const { EPUB } = await import('../../Sources/LakeOfFireReader/Resources/foliate-js/epub.js')

// Exercise the actual detached document producer used by search/navigation.
// These parser doubles assert processing order, source ownership and exact
// inputs; they do not substitute a copied implementation of EPUB.
const makeSource = destroy => ({
    loadText: async () => null,
    loadBlob: async () => null,
    getSize: () => 0,
    replaceText: (_href, text) => text,
    replaceURL: value => value,
    destroy,
})

test('detached EPUB documents use the same invalid-XHTML fallback as rendering', async () => {
    const originalDOMParser = globalThis.DOMParser
    const originalWarn = console.warn
    const calls = []
    const htmlDocument = {body:{textContent:'searchable & text'}}
    globalThis.DOMParser = class {
        parseFromString(source, mediaType) {
            calls.push({source,mediaType})
            return mediaType === 'application/xhtml+xml'
                ? {querySelector:()=>({innerText:'unescaped ampersand'})}
                : htmlDocument
        }
    }
    console.warn = () => {}
    const source = '<html><body>searchable & text</body></html>'
    const item = {href:'OPS/unvisited.xhtml',mediaType:'application/xhtml+xml'}
    const book = new EPUB({...makeSource(()=>{}),loadText:async href=>{
        assert.equal(href,item.href)
        return source
    }})
    try {
        assert.equal(await book.loadDocument(item), htmlDocument)
        assert.deepEqual(calls,[{source,mediaType:'application/xhtml+xml'},{source,mediaType:'text/html'}])
        // Detached parsing must not change manifest publication metadata.
        assert.equal(item.mediaType,'application/xhtml+xml')
    } finally {
        book.destroy()
        globalThis.DOMParser = originalDOMParser
        console.warn = originalWarn
    }
})

for (const mediaType of ['application/xhtml+xml','image/svg+xml']) {
    test(`detached EPUB documents preserve successful ${mediaType} parsing`, async () => {
        const originalDOMParser = globalThis.DOMParser
        const calls = []
        const parsed = {querySelector:()=>null}
        globalThis.DOMParser = class {parseFromString(source,type){calls.push(type);return parsed}}
        const book = new EPUB({...makeSource(()=>{}),loadText:async()=>'<root/>'})
        try {
            assert.equal(await book.loadDocument({href:'OPS/source',mediaType}),parsed)
            assert.deepEqual(calls,[mediaType])
        } finally {
            book.destroy()
            globalThis.DOMParser = originalDOMParser
        }
    })
}


for (const mediaType of ['application/xhtml+xml', 'text/html']) {
    test('detached ' + mediaType + ' processing keeps its search context and transformed structure', async () => {
        const originalDOMParser = globalThis.DOMParser
        const raw = '<html><body>raw chapter</body></html>'
        const processed = '<html><body><m-s>processed chapter</m-s></body></html>'
        const events = []
        const parsed = { querySelector: () => null }
        globalThis.DOMParser = class { parseFromString(text, type) {
            events.push(['parse', text, type])
            return parsed
        } }
        const book = new EPUB({ ...makeSource(() => {}),
            loadText: async href => { events.push(['read', href]); return raw },
            replaceText: async (href, text, type, options) => {
                events.push(['process', href, text, type, options])
                return processed
            },
        })
        try {
            assert.equal(await book.loadDocument({ href: 'OPS/chapter', mediaType }), parsed)
            assert.deepEqual(events, [
                ['read', 'OPS/chapter'],
                ['process', 'OPS/chapter', raw, mediaType, { forSearch: true }],
                ['parse', processed, mediaType],
            ])
        } finally { book.destroy(); globalThis.DOMParser = originalDOMParser }
    })
}

test('destruction while chapter processing waits prevents detached parsing', async () => {
    const originalDOMParser = globalThis.DOMParser
    let release, entered
    const started = new Promise(resolve=>{entered=resolve})
    let parses=0
    globalThis.DOMParser = class {parseFromString(){parses++;throw new Error('retired document parsed')}}
    const book = new EPUB({...makeSource(()=>{}),loadText:async()=>'<html/>',
        replaceText:()=>{entered();return new Promise(resolve=>{release=resolve})}})
    try {
        const load = book.loadDocument({href:'OPS/chapter.xhtml',mediaType:'application/xhtml+xml'})
        await started
        book.destroy()
        release('<html/>')
        await assert.rejects(load,error=>error?.name==='AbortError')
        assert.equal(parses,0)
    } finally {book.destroy();globalThis.DOMParser=originalDOMParser}
})


for (const outcome of ['missing', 'rejected']) {
    test(`detached processing ${outcome} never parses raw fallback structure`, async () => {
        const originalDOMParser = globalThis.DOMParser
        let parses = 0
        globalThis.DOMParser = class { parseFromString() { parses++; throw new Error('unexpected parsing') } }
        const failure = new Error('processing unavailable')
        const book = new EPUB({...makeSource(()=>{}), loadText:async()=>'<html><body>raw</body></html>',
            replaceText:async()=>{ if (outcome === 'rejected') throw failure; return null }})
        try {
            await assert.rejects(book.loadDocument({href:'OPS/chapter.xhtml',mediaType:'application/xhtml+xml'}),
                error => outcome === 'rejected' ? error === failure : /Failed to load section document/.test(error.message))
            assert.equal(parses, 0)
        } finally { book.destroy(); globalThis.DOMParser = originalDOMParser }
    })
}
