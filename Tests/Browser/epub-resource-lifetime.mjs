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
        return results
    }), new Promise((_, reject) => {
        deadline = setTimeout(() => reject(new Error('EPUB resource fixture timed out')), 15000)
    })])
    assert.deepEqual(errors,[])
    const report={cases:results,errors,browser:browser.version(),scope:'Actual EPUB init, XML/HTML parser, section loading, browser Blob URL lifetime; native section endpoint controlled; no WKWebView/native storage.'}
    if(reportPath) await writeFile(reportPath,JSON.stringify(report,null,2)+'\n',{flag:'wx'})
    console.log(JSON.stringify(report))
} finally {
    clearTimeout(deadline)
    try {await context?.close()} finally {
        try {await browser?.close()} finally {await new Promise(resolve=>server.close(resolve))}
    }
}
