// Focused real-browser qualification of the production View/getView boundary.
// PLAYWRIGHT_MODULE may point to an existing playwright-core ESM entry; this
// script never installs tools or downloads a browser. Chrome is task-isolated.
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { readFile, realpath } from 'node:fs/promises'
import { dirname, extname, resolve, sep } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const root = await realpath(resolve(dirname(fileURLToPath(import.meta.url)), '../..'))
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE
    ? pathToFileURL(process.env.PLAYWRIGHT_MODULE).href : 'playwright-core')
const mime = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.html': 'text/html' }
const server = createServer(async (request, response) => {
    try {
        const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname)
        if (pathname === '/') {
            response.writeHead(200, { 'Content-Type': 'text/html' })
            response.end('<!doctype html><html><body><div id="reader-stage"></div></body></html>')
            return
        }
        const path = await realpath(resolve(root, '.' + pathname))
        if (!path.startsWith(root + sep)) throw new Error('outside repository')
        response.writeHead(200, { 'Content-Type': mime[extname(path)] ?? 'application/octet-stream', 'Cache-Control': 'no-store' })
        response.end(await readFile(path))
    } catch (_) { response.writeHead(404); response.end('not found') }
})
let browser, context
try {
    await new Promise((yes, no) => { server.once('error', no); server.listen(0, '127.0.0.1', yes) })
    const { port } = server.address()
    browser = await chromium.launch({
        executablePath: process.env.CHROME_EXECUTABLE ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        headless: true,
        args: ['--disable-features=MacAppCodeSignClone'],
    })
    context = await browser.newContext()
    const page = await context.newPage()
    const errors = []
    page.on('pageerror', error => errors.push(error.message))
    await page.goto(`http://127.0.0.1:${port}/`)
    const results = await page.evaluate(async () => {
        const base = '/Sources/LakeOfFireReader/Resources/foliate-js/'
        const { View } = await import(base + 'view.js')
        const outcomes = []
        const check = (condition, label) => { if (!condition) throw new Error(label) }
        const makeBook = () => ({
            rendition: { layout: 'pre-paginated', spread: 'none', viewport: { width: 600, height: 800 } },
            metadata: {}, dir: 'ltr', destroyed: 0,
            sections: [{ id: 'chapter', index: 0, linear: 'yes',
                load: async () => URL.createObjectURL(new Blob([
                    '<!doctype html><html><head><meta name="viewport" content="width=600,height=800"></head><body><p>猫と犬</p></body></html>',
                ], { type: 'text/html' })), unload() {} }],
            destroy() { ++this.destroyed },
        })
        {
            const view = document.createElement('foliate-view'), book = makeBook()
            document.body.append(view)
            const pending = view.open(book, false)
            view.close()
            check(await pending === false, 'closed import returned success')
            check(view.renderer === null && view.book === null, 'closed View resurrected')
            check(book.destroyed === 1, 'closed book not retired exactly once')
            view.remove(); outcomes.push('close during actual module loading')
        }
        {
            const view = document.createElement('foliate-view'), first = makeBook(), last = makeBook()
            document.body.append(view)
            const a = view.open(first, false), b = view.open(last, true)
            check(await a === false && await b === true, 'overlapping real renderer opens')
            check(view.renderer instanceof HTMLElement && view.renderer.isConnected, 'real renderer not mounted')
            check(view.renderer.localName === 'foliate-fxl' && view.book === last, 'wrong real renderer/book')
            check(first.destroyed === 1 && last.destroyed === 0, 'wrong book retirement')
            view.close(); view.remove(); outcomes.push('latest real fixed-layout renderer mounts')
        }
        {
            const view = document.createElement('foliate-view'), book = makeBook()
            document.body.append(view)
            const old = view.beginOpen(book, false)
            const next = view.beginOpen(book, true)
            check(await old.completion === false && await next.completion === true, 'same-book open generation')
            check(old.retire() === false && book.destroyed === 0, 'old caller destroyed same-book successor')
            check(view.renderer?.isConnected === true, 'successor detached')
            let released = 0
            const release = view.registerCleanup(() => ++released)
            release(); release(); view.close(); view.close()
            check(released === 1 && book.destroyed === 1, 'cleanup not idempotent')
            view.remove(); outcomes.push('same-book successor and cleanup on real elements')
        }
        // Complete production getView runs with the real View/renderer/DOM.
        // Native EPUB loading alone is controlled because this browser has no
        // app scheme handler. No production method or ownership check is copied.
        const source = await (await fetch(base + 'ebook-viewer.js')).text()
        const start = source.indexOf('const getView = async ')
        const end = source.indexOf('\nconst getCSSForBookContent', start)
        check(start >= 0 && end > start, 'getView declaration missing')
        const declaration = source.slice(start, end).replaceAll("await import('./epub.js')", 'epubModule')
        const load = book => new Function('epubModule', 'makeNativeEpubLoader', 'initializeEPUBBook',
            'readerOpenSupersededError', 'postReaderVisibilityProbe', 'forwardShadowErrors', 'resolveFoliatePaginator',
            declaration + '; return getView')({ EPUB: class {} }, async () => ({}), async () => book,
            () => Object.assign(new Error('superseded'), { code: 'reader-open-superseded' }),
            () => {}, () => {}, view => view.renderer?.localName === 'foliate-paginator' ? view.renderer : null)
        for (const cacheWarmer of [false, true]) {
            const book = makeBook(), delivery = await load(book)({ kind: 'native', url: 'ebook://test/' }, cacheWarmer)
            check(delivery.isCurrent() && delivery.view.book === book && delivery.view.renderer.isConnected, 'actual getView admission')
            const original = delivery.view
            const nextBook = makeBook(), next = original.beginOpen(nextBook, false)
            check(await next.completion === true, 'same-host successor failed')
            check(!delivery.isCurrent(), 'old getView delivery remained current')
            delivery.retire()
            check(original.isConnected && original.book === nextBook && nextBook.destroyed === 0, 'stale getView retirement destroyed successor')
            check(next.retire() === true, 'current owner cannot retire host')
            original.remove(); outcomes.push(`actual getView delivery and retirement cache=${cacheWarmer}`)
        }
        return outcomes
    })
    assert.equal(results.length, 5)
    assert.deepEqual(errors, [])
    process.stdout.write(JSON.stringify({ browser: await browser.version(), passed: results.length,
        cases: results, limits: 'Chromium real DOM/modules; native EPUB loading controlled; no WebKit/native/device claim.' }, null, 2) + '\n')
} finally {
    try {
        if (context) await context.close()
    } finally {
        try {
            if (browser) await browser.close()
        } finally {
            await new Promise(resolve => server.close(resolve))
        }
    }
}
