import assert from 'node:assert/strict'
import { readFile, realpath } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_MODULE ?? 'playwright')
// Exercise the production CFI module against actual browser DOM/Range objects.
// Upstream generated IDs use mnb-s; authored IDs may resemble donor _m IDs.
const source = fileURLToPath(new URL(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/epubcfi.js', import.meta.url))
assert.equal(await realpath(source), source)
const moduleURL = 'data:text/javascript;base64,' + Buffer.from(await readFile(source)).toString('base64')
let browser, context
const results = []
try {
    browser = await chromium.launch({headless: true, args: ['--disable-features=MacAppCodeSignClone']})
    context = await browser.newContext()
    const page = await context.newPage()
    const errors = []
    page.on('pageerror', error => errors.push(String(error)))
    const cases = await page.evaluate(async moduleURL => {
        const cfi = await import(moduleURL)
        const doc = html => new DOMParser().parseFromString(html, 'text/html')
        const makeRange = (document, start, end = start) => {
            const range = document.createRange()
            const node = document.querySelector('span').firstChild
            range.setStart(node, start); range.setEnd(node, end)
            return range
        }
        const encoded = []
        const original = doc('<main id="chapter"><span id="mnb-sABC">Japanese reading</span></main>')
        const regenerated = doc('<main id="chapter"><span id="mnb-sXYZ">Japanese reading</span></main>')
        for (const [name, start, end] of [['collapsed', 4, 4], ['text selection', 2, 8]]) {
            const oldCFI = cfi.fromRange(makeRange(original, start, end))
            const newCFI = cfi.fromRange(makeRange(regenerated, start, end))
            const restored = cfi.toRange(regenerated, cfi.parse(oldCFI))
            encoded.push({name, oldCFI, newCFI, offsets: [restored.startOffset, restored.endOffset], expectedOffsets: [start,end], text: restored.toString(), expectedText: 'Japanese reading'.slice(start,end)})
        }
        const sentinel = doc('<main id="chapter"><reader-sentinel></reader-sentinel><span id="mnb-sABC">Japanese reading</span><reader-sentinel></reader-sentinel></main>')
        encoded.push({name: 'sentinels preserve address', actual: cfi.fromRange(makeRange(sentinel,2,8)), expected: cfi.fromRange(makeRange(original,2,8))})
        const authored = doc('<main id="chapter"><span id="_m1x2">Japanese reading</span></main>')
        const authoredRange = authored.createRange()
        authoredRange.setStart(authored.querySelector('span'),0)
        authoredRange.collapse(true)
        const authoredCFI = cfi.fromRange(authoredRange)
        encoded.push({name:'authored compact-looking ID remains an assertion', id: cfi.parse(authoredCFI)[0].at(-1).id, expected:'_m1x2'})
        const opf = new DOMParser().parseFromString('<package><spine><itemref id="chapter-one"/><itemref id="_m1x2"/></spine></package>', 'application/xml')
        const itemrefs = [...opf.querySelectorAll('itemref')]
        const addresses = cfi.fromElements(itemrefs)
        encoded.push({name:'OPF spine assertions retained', ids: addresses.map(value => cfi.parse(value)[0].at(-1).id), expected:['chapter-one','_m1x2']})
        return encoded
    }, moduleURL)
    for (const entry of cases) {
        if ('oldCFI' in entry) {
            assert.equal(entry.oldCFI, entry.newCFI)
            assert.deepEqual(entry.offsets, entry.expectedOffsets)
            assert.equal(entry.text, entry.expectedText)
        } else if ('actual' in entry) assert.equal(entry.actual,entry.expected)
        else if ('ids' in entry) assert.deepEqual(entry.ids, entry.expected)
        else assert.equal(entry.id,entry.expected)
        results.push({...entry, status:'passed'})
    }
    assert.deepEqual(errors,[])
    console.log(JSON.stringify({passed:results.length,pageerrors:errors.length,browser:browser.version()}))
} finally {
    try { await context?.close() }
    finally { await browser?.close() }
}
