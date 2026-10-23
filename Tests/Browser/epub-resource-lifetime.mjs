import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { readFile, realpath, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'
import { dirname, resolve, sep } from 'node:path'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_MODULE ?? 'playwright')
const root = await realpath(resolve(dirname(fileURLToPath(import.meta.url)), '../..'))
const sourceRoot = resolve(root, 'Sources/LakeOfFireReader/Resources/foliate-js')
const reportPath = process.argv[2]
if (reportPath) assert.equal(await realpath(dirname(reportPath)), dirname(reportPath))
const server = createServer(async (request,response) => {
    try {
        const path = new URL(request.url,'http://localhost').pathname
        if (path === '/') { response.setHeader('Content-Type','text/html'); response.end('<!doctype html><title>EPUB resource lifetime</title>'); return }
        if (path === '/held-resource') {
            if (new URL(request.url, 'http://localhost').searchParams.get('phase') === 'body') {
                response.setHeader('Content-Type', 'text/plain')
                response.writeHead(200)
                response.flushHeaders()
                response.write('partial ')
            }
            return
        }
        const file = await realpath(resolve(sourceRoot,'.'+path))
        assert.ok(file.startsWith(sourceRoot+sep))
        response.setHeader('Content-Type','text/javascript')
        response.end(await readFile(file))
    } catch { response.statusCode=404; response.end() }
})
let browser, context, deadline
try {
    await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve))
    browser = await chromium.launch({headless:true,args:['--disable-features=MacAppCodeSignClone']})
    context = await browser.newContext()
    const page = await context.newPage()
    const errors=[]
    page.on('pageerror',error=>errors.push(String(error)))
    await page.goto(`http://127.0.0.1:${server.address().port}/`)
    const results = await Promise.race([page.evaluate(async () => {
        const { EPUB } = await import('/epub.js')
        const { createNativeEpubLoader } = await import('/ebook-native-loader.js')
        const check=(ok,message)=>{if(!ok) throw new Error(message)}
        const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve}}
        const source = () => new Map([
            ['META-INF/container.xml','<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'],
            ['book.opf','<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">fixture</dc:identifier><dc:title>Fixture</dc:title><dc:language>en</dc:language></metadata><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="b" href="b.xhtml" media-type="application/xhtml+xml"/><item id="image" href="image.png" media-type="image/png"/></manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>'],
            ['a.xhtml','<html xmlns="http://www.w3.org/1999/xhtml"><head><title>A</title></head><body><img src="image.png"/></body></html>'],
            ['b.xhtml','<html xmlns="http://www.w3.org/1999/xhtml"><head><title>B</title></head><body><img src="image.png"/></body></html>'],
        ])
        const results=[]
        {
            const files=source(), gate=deferred(), entered=deferred();let loads=0
            const book=await new EPUB({loadText:async path=>files.get(path)??null,loadBlob:async()=>{loads++;entered.resolve();await gate.promise;return new Uint8Array([1,2,3])},getSize:()=>100}).init()
            try {
                const first=book.sections[0].load(),second=book.sections[1].load()
                await entered.promise;gate.resolve()
                const urls=await Promise.all([first,second])
                const documents=await Promise.all(urls.map(async url=>new DOMParser().parseFromString(await (await fetch(url)).text(),'application/xhtml+xml')))
                const images=documents.map(doc=>doc.querySelector('img').getAttribute('src'))
                check(loads===1,'shared asset fetched more than once')
                check(images[0]===images[1]&&images[0].startsWith('blob:'),'sections did not share image publication')
                book.sections[0].unload()
                check((await (await fetch(images[0])).arrayBuffer()).byteLength===3,'first unload retired peer image')
                book.sections[1].unload()
                let retired=false;try{await fetch(images[0])}catch{retired=true}
                check(retired,'last unload leaked shared image')
                results.push({name:'two actual parsed chapters share and release one asset',status:'passed',loads})
            } finally {book.destroy()}
        }
        {
            const files=source(), gate=deferred(),entered=deferred();let sourceCloses=0
            const book=await new EPUB({loadText:async path=>files.get(path)??null,loadBlob:async()=>{entered.resolve();await gate.promise;return new Uint8Array([1])},getSize:()=>100,destroy:()=>sourceCloses++}).init()
            const pending=book.sections[0].load()
            await entered.promise;book.destroy();gate.resolve()
            check(!await pending,'destroyed EPUB published a chapter blob')
            check(sourceCloses===1,'source not closed once')
            results.push({name:'close during actual chapter asset load prevents publication',status:'passed'})
        }
        {
            const files=source(),gate=deferred(),entered=deferred();let calls=0,ownerCloses=0
            const replaceURL=async()=>{calls++;entered.resolve();await gate.promise;return 'manabi-ebook://fixture/a.xhtml'}
            replaceURL.destroy=()=>ownerCloses++
            const book=await new EPUB({loadText:async path=>files.get(path)??null,loadBlob:async()=>{throw new Error('native section must not use raw loader')},getSize:()=>100,replaceURL}).init()
            const first=book.sections[0].load(),second=book.sections[0].load()
            await entered.promise;book.destroy();gate.resolve()
            const values=await Promise.all([first,second])
            check(values.every(value=>!value),'retired native section published')
            check(calls===1&&ownerCloses===1,'native replacement ownership not coalesced/retired')
            results.push({name:'native direct section stays on its route and retires once',status:'passed',calls,ownerCloses})
        }
        {
            const files = source()
            files.set('book.opf', files.get('book.opf').replace('</manifest>',
                '<item id="icons" href="icons.svg" media-type="image/svg+xml"/><item id="empty" href="empty.css" media-type="text/css"/></manifest>'))
            files.set('icons.svg', '<svg xmlns="http://www.w3.org/2000/svg"><symbol id="shape"><rect width="4" height="4"/></symbol></svg>')
            files.set('empty.css', '')
            files.set('a.xhtml', '<html><head><link rel="stylesheet" href="empty.css"></head><body><p>fallback<img src="icons.svg?v=2#shape"></body></html>')
            const reads = []
            const book = await new EPUB({loadText:async path=>{reads.push(path);return files.get(path)??null},
                loadBlob:async()=>new Uint8Array([1]),getSize:()=>100}).init()
            try {
                const url = await book.sections[0].load()
                const response = await fetch(url)
                check(response.headers.get('content-type') === 'text/html', 'fallback MIME not published as HTML')
                const document = new DOMParser().parseFromString(await response.text(), 'text/html')
                const image = document.querySelector('img').getAttribute('src')
                const stylesheet = document.querySelector('link').getAttribute('href')
                check(image.startsWith('blob:') && image.endsWith('#shape'), 'SVG fragment not attached to owned resource')
                const svg = new DOMParser().parseFromString(await (await fetch(image)).text(), 'image/svg+xml')
                check(svg.getElementById('shape')?.localName === 'symbol', 'rewritten SVG target missing')
                check(stylesheet.startsWith('blob:'), 'empty stylesheet missing owned URL')
                check(await (await fetch(stylesheet)).text() === '', 'empty stylesheet content changed')
                check(reads.includes('icons.svg') && reads.includes('empty.css'), 'manifest resource reads missing')
                const recreated = await book.sections[0].createDocument()
                check(recreated.contentType === 'text/html', 'successful fallback MIME not retained for document loading')
                results.push({name:'actual parsed chapter preserves SVG fragment, empty CSS and HTML fallback MIME',status:'passed'})
            } finally {book.destroy()}
        }
        for (const stage of ['chapter', 'stylesheet', 'import']) {
            for (const phase of ['response', 'body']) {
                const files = source(), entered = deferred()
                const pendingPath = stage === 'chapter' ? 'a.xhtml' : stage === 'stylesheet' ? 'style.css' : 'imported.css'
                files.set('a.xhtml', '<html><head><link rel="stylesheet" href="style.css"></head><body>本文</body></html>')
                files.set('style.css', '@import "imported.css";')
                files.set('imported.css', 'body { writing-mode: vertical-rl; }')
                const requests = []
                let observedSignal
                const native = await createNativeEpubLoader({url:'ebook://ebook/load/local/book.epub',
                    packageSessionID:'371cf379-d180-449d-bca2-13b902c3634d'}, false, {
                    makeReplaceText: () => async (_href, text) => text,
                    fetch: async (url, options) => {
                        const request = new URL(url)
                        if (request.pathname === '/entries') return new Response(JSON.stringify({
                            entries:[...files.keys()].map(path => ({path})), packageDocumentPath:'book.opf',
                        }))
                        requests.push(options.headers)
                        const path = request.searchParams.get('subpath')
                        if (path !== pendingPath) return new Response(files.get(path) ?? '')
                        observedSignal = options.signal
                        if (phase === 'response') entered.resolve()
                        const response = await fetch(`/held-resource?phase=${phase}`, {signal:observedSignal})
                        const read = response.arrayBuffer.bind(response)
                        response.arrayBuffer = () => {
                            const pending = read()
                            entered.resolve()
                            return pending
                        }
                        return response
                    },
                })
                const book = await new EPUB(native).init()
                const retainedSection = book.sections[0]
                const pending = retainedSection.load().then(value => ({value}), error => ({error:error.name}))
                try {
                    await entered.promise
                    check(book.destroy() === true, 'first EPUB destroy failed')
                    check(observedSignal?.aborted === true, `${stage}/${phase} did not abort browser fetch`)
                    const outcome = await pending
                    if (stage === 'chapter') check(outcome.error === 'AbortError', 'chapter abort was not propagated')
                    else check(outcome.value === null, 'optional CSS abort published a section')
                    check(await retainedSection.load() === null, 'retained section revived closed source')
                    check(book.destroy() === false && native.destroy() === false, 'source teardown was not idempotent')
                    check(requests.every(headers => headers['X-Ebook-Package-Session'] === '371cf379-d180-449d-bca2-13b902c3634d'), 'source capability changed')
                    results.push({name:`EPUB teardown aborts ${stage} browser fetch during ${phase}`,status:'passed'})
                } finally { book.destroy() }
            }
        }
        {
            const { hydratePackageMedia } = await import('/ebook-package-media.js')
            const mediaURL = `ebook://ebook/entry-session/source/g1-${'b'.repeat(64)}/371cf379-d180-449d-bca2-13b902c3634d/OPS/Media/voice.m4a`
            const fixture = () => {
                const host = document.createElement('div')
                const audio = document.createElement('audio')
                audio.preload = 'none'
                let loads = 0
                audio.load = () => { loads++ }
                host.append(audio)
                document.body.append(host)
                return { host, audio, loadCount: () => loads }
            }
            const canFetch = async url => {
                try { await fetch(url); return true } catch { return false }
            }
            {
                const { host, audio, loadCount } = fixture()
                const nested = document.createElement('source')
                audio.src = `${mediaURL}#t=1`
                nested.src = `${mediaURL}#t=2`
                audio.append(nested)
                const requests = [], owned = [], revoked = []
                try {
                    const outcomes = await hydratePackageMedia({
                        document,
                        fetch: async url => { requests.push(url); return new Response(new Blob(['media'])) },
                        createObjectURL: blob => { const url = URL.createObjectURL(blob); owned.push(url); return url },
                        revokeObjectURL: url => { revoked.push(url); URL.revokeObjectURL(url) },
                    })
                    check(outcomes.length === 2 && outcomes.every(Boolean), 'connected package media did not hydrate')
                    check(requests.length === 1 && requests[0] === mediaURL, 'session capability changed or shared fetch duplicated')
                    check(owned.length === 1, 'fragment peers did not share one Blob URL')
                    check(audio.src === `${owned[0]}#t=1` && nested.src === `${owned[0]}#t=2`, 'media fragments changed')
                    check(loadCount() === 1, 'owning media reloaded more than once')
                    check(await (await fetch(owned[0])).text() === 'media', 'published media blob inaccessible')
                    window.dispatchEvent(new PageTransitionEvent('pagehide'))
                    check(revoked.length === 1 && revoked[0] === owned[0], 'pagehide did not retire shared media once')
                    check(!await canFetch(owned[0]), 'pagehide left media URL live')
                    results.push({name:'connected media shares exact native session URL and preserves per-source fragments',status:'passed'})
                } finally {
                    window.dispatchEvent(new PageTransitionEvent('pagehide'))
                    for (const url of owned) URL.revokeObjectURL(url)
                    host.remove()
                }
            }
            for (const phase of ['response', 'blob']) {
                const { host, audio, loadCount } = fixture()
                const gate = deferred(), entered = deferred()
                audio.src = mediaURL
                let created = 0
                try {
                    const pending = hydratePackageMedia({
                        document,
                        fetch: async url => {
                            check(url === mediaURL, 'held media capability changed')
                            if (phase === 'response') { entered.resolve(); await gate.promise }
                            return { ok: true, blob: async () => {
                                if (phase === 'blob') { entered.resolve(); await gate.promise }
                                return new Blob(['late media'])
                            } }
                        },
                        createObjectURL: blob => { created++; return URL.createObjectURL(blob) },
                    })
                    await entered.promise
                    window.dispatchEvent(new PageTransitionEvent('pagehide'))
                    gate.resolve()
                    check(JSON.stringify(await pending) === '[false]', 'closed page accepted late media')
                    check(created === 0 && loadCount() === 0 && audio.src === mediaURL, 'closed page published late media')
                    results.push({name:`package media pagehide during held ${phase} prevents Blob publication`,status:'passed'})
                } finally { gate.resolve(); host.remove() }
            }
            for (const change of ['disconnect', 'replace']) {
                const { host, audio, loadCount } = fixture()
                const gate = deferred(), entered = deferred(), owned = [], revoked = []
                audio.src = mediaURL
                try {
                    const pending = hydratePackageMedia({
                        document,
                        fetch: async () => { entered.resolve(); await gate.promise; return new Response(new Blob(['stale media'])) },
                        createObjectURL: blob => { const url = URL.createObjectURL(blob); owned.push(url); return url },
                        revokeObjectURL: url => { revoked.push(url); URL.revokeObjectURL(url) },
                    })
                    await entered.promise
                    if (change === 'disconnect') audio.remove()
                    else audio.src = 'https://example.invalid/replacement.m4a'
                    const retainedSource = audio.src
                    gate.resolve()
                    check(JSON.stringify(await pending) === '[false]', 'retired media source accepted stale response')
                    check(audio.src === retainedSource && loadCount() === 0, 'late media overwrote or reloaded retired source')
                    window.dispatchEvent(new PageTransitionEvent('pagehide'))
                    check(owned.length === 1 && revoked.length === 1 && revoked[0] === owned[0], 'retired source blob cleanup incorrect')
                    check(!await canFetch(owned[0]), 'retired source leaked media Blob URL')
                    results.push({name:`late package media response preserves ${change === 'disconnect' ? 'disconnected' : 'replaced'} DOM source`,status:'passed'})
                } finally {
                    gate.resolve()
                    window.dispatchEvent(new PageTransitionEvent('pagehide'))
                    for (const url of owned) URL.revokeObjectURL(url)
                    host.remove()
                }
            }
        }
        return results
    }), new Promise((_, reject) => {
        deadline = setTimeout(() => reject(new Error('EPUB resource fixture timed out')), 15000)
    })])
    assert.deepEqual(errors,[])
    const report={cases:results,errors,browser:browser.version(),scope:'Actual EPUB init, XML/HTML parser, section loading, browser Blob URL lifetime; native endpoint adapted to held HTTP fetch for cancellation; no WKWebView/native storage.'}
    if(reportPath) await writeFile(reportPath,JSON.stringify(report,null,2)+'\n',{flag:'wx'})
    console.log(JSON.stringify(report))
} finally {
    clearTimeout(deadline)
    try {await context?.close()} finally {
        try {await browser?.close()} finally {await new Promise(resolve=>server.close(resolve))}
    }
}
