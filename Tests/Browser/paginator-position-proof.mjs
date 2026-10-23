import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { readFile, realpath, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { dirname, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_MODULE
    ?? 'playwright')
const repository = await realpath(resolve(dirname(fileURLToPath(import.meta.url)), '../..'))
const output = process.argv[2]
assert.ok(output, 'Pass an external result JSON path')
assert.equal(await realpath(dirname(output)), dirname(output), 'Resolve the report directory before writing')
const tests = [], errors = []
const report = { command: process.argv.join(' '), repository,
    launchArguments: ['--disable-features=MacAppCodeSignClone'], tests, errors,
    fixture: 'Actual exported View/Paginator, real iframe HTML, two same-size local HTTP spine sections. Coordinator subset uses doubled Reader/bridge endpoints; no WKWebView or native persistence.',
    startedAt: new Date().toISOString() }
const sourceRoot = resolve(repository, 'Sources/LakeOfFireReader/Resources/foliate-js')
const server = createServer(async (request, response) => {
    try {
        const url = new URL(request.url, 'http://localhost')
        if (url.pathname === '/') {
            response.setHeader('Content-Type', 'text/html')
            response.end(`<!doctype html><html><head><style>
                html,body { margin:0; width:100%; height:100%; overflow:hidden }
                foliate-view { display:block; width:600px; height:800px }
            </style></head><body></body></html>`)
            return
        }
        if (url.pathname.startsWith('/section/')) {
            const mode = url.searchParams.get('mode') ?? 'horizontal'
            const vertical = mode === 'vertical'
            const rtl = mode === 'rtl'
            const text = vertical ? '日本語の本を読む練習です。今日も静かな図書館で物語を読みます。' :
                'A quiet reader follows the story across each page. This paragraph gives the renderer actual text to lay out. '
            response.setHeader('Content-Type', 'text/html; charset=utf-8')
            response.end(`<!doctype html><html lang="${vertical ? 'ja' : 'en'}" dir="${rtl ? 'rtl' : 'ltr'}"><head><style>
                html { writing-mode:${vertical ? 'vertical-rl' : 'horizontal-tb'} }
                body { margin:0; font:20px/1.5 serif; }
                p { margin:0 0 1em; }
                reader-sentinel { display:inline-block; width:1px; height:1px; }
            </style></head><body data-mnb-writing-direction="${vertical ? 'vertical' : 'horizontal'}"><main id="reader-content">${Array.from({ length: 35 }, (_, i) => `<p>${mode === 'plain' ? '' : `<reader-sentinel id="s-${i}"></reader-sentinel>`}${i + 1}. ${text.repeat(3)}</p>`).join('')}</main></body></html>`)
            return
        }
        const candidate = resolve(sourceRoot, '.' + url.pathname)
        if (!candidate.startsWith(sourceRoot + sep)) throw new Error('Path outside source root')
        const path = await realpath(candidate)
        if (!path.startsWith(sourceRoot + sep)) throw new Error('Symlink outside source root')
        response.setHeader('Content-Type', path.endsWith('.js') ? 'text/javascript' : 'application/octet-stream')
        response.end(await readFile(path))
    } catch (error) {
        response.statusCode = 404
        response.end(String(error))
    }
})
let browser, context
try {
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
    report.origin = `http://127.0.0.1:${server.address().port}`
    browser = await chromium.launch({ headless: true, args: report.launchArguments })
    report.browserVersion = browser.version()
    context = await browser.newContext({ viewport: { width: 900, height: 1000 } })
    const page = await context.newPage()
    page.on('pageerror', error => errors.push(error.stack ?? String(error)))
    await page.goto(report.origin)
    await page.evaluate(async () => {
        const { View } = await import('/view.js')
        const { Paginator } = await import('/paginator.js')
        window.productionClasses = { View, Paginator }
        window.frames = async (count = 2) => {
            for (let i = 0; i < count; i++) await new Promise(requestAnimationFrame)
        }
        window.openFixture = async (mode, navigate = true) => {
            window.view?.close()
            window.view?.remove()
            const view = window.view = new View()
            document.body.append(view)
            const sections = [0, 1].map(index => ({
                id: `section-${index}`, size: 100, linear: 'yes',
                load: async () => `/section/${index}?mode=${mode}`, unload() {},
            }))
            await view.open({ sections, dir: mode === 'rtl' ? 'rtl' : 'ltr',
                metadata: { language: mode === 'vertical' ? 'ja' : 'en' }, toc: [], pageList: [],
                splitTOCHref: href => [href, null], getTOCFragment: doc => doc.body,
            }, false)
            window.relocations = []
            view.addEventListener('relocate', event => window.relocations.push({
                fraction: event.detail.fraction, sectionIndex: event.detail.sectionIndex,
                geometry: event.detail.firstPageGeometrySource,
            }))
            if (!navigate) return view
            const receipt = window.receipt = await Promise.race([
                view.goToFraction(0, { requiresPositionReceipt: true }),
                new Promise((_, reject) => setTimeout(() => reject(new Error('zero navigation timed out')), 10000)),
            ])
            await window.frames(2)
            const proof = window.proof = view.capturePositionProof(receipt)
            return { actualView: view instanceof View, actualPaginator: view.renderer instanceof Paginator,
                receipt, proof, metrics: await view.renderer.pageMetrics(),
                location: { fraction: view.lastLocation?.fraction, geometry: view.lastLocation?.firstPageGeometrySource },
                relocationCount: window.relocations.length,
                frameCount: view.renderer.getContents().length,
                iframeTextLength: view.renderer.getContents()[0]?.doc?.body?.textContent.length,
            }
        }
    })
    const run = async (name, operation) => {
        const entry = { name, status: 'running' }
        tests.push(entry)
        try { entry.evidence = await operation(); entry.status = 'passed' }
        catch (error) { entry.status = 'failed'; entry.error = error.stack ?? String(error); throw error }
    }
    await run('ordinary section without sentinels completes navigation', async () => {
        const result = await page.evaluate(() => window.openFixture('plain'))
        assert.ok(result.receipt)
        assert.ok(result.proof)
        assert.ok(result.proof.currentFractionalCompletion > 0)
        return result
    })
    for (const mode of ['horizontal', 'vertical', 'rtl']) {
        await run(`${mode}: actual zero navigation settles its own rendering`, async () => {
            const result = await page.evaluate(mode => window.openFixture(mode), mode)
            assert.equal(result.actualView, true)
            assert.equal(result.actualPaginator, true)
            assert.equal(result.metrics.vertical, mode === 'vertical')
            assert.equal(result.metrics.rtl, mode === 'rtl')
            assert.equal(result.frameCount, 1)
            assert.ok(result.iframeTextLength > 1000)
            assert.ok(result.receipt)
            assert.ok(result.proof, `No proof: ${JSON.stringify(result)}`)
            assert.equal(result.proof.positionMode, 'paginated')
            assert.ok(result.proof.currentFractionalCompletion > 0)
            assert.equal(result.proof.currentFractionalCompletion, result.location.fraction)
            assert.equal(result.proof.handledFractionalCompletion, result.location.fraction)
            assert.equal(result.proof.firstPageGeometry.fractionInSection, 0)
            return result
        })
        await run(`${mode}: unchanged proof remains current`, async () => {
            const result = await page.evaluate(async () => {
                await window.frames(2)
                return { current: window.view.isPositionProofCurrent(window.proof),
                    fraction: window.view.lastLocation.fraction }
            })
            assert.equal(result.current, true)
            return result
        })
        await run(`${mode}: actual mode ABA invalidates before relocation`, async () => {
            const result = await page.evaluate(() => {
                const { view, proof } = window
                const old = view.lastLocation
                const flow = view.renderer.getAttribute('flow')
                view.renderer.setAttribute('flow', 'scrolled')
                const during = view.isPositionProofCurrent(proof)
                if (flow === null) view.renderer.removeAttribute('flow')
                else view.renderer.setAttribute('flow', flow)
                return { during, after: view.isPositionProofCurrent(proof), unchangedLocation: view.lastLocation === old }
            })
            assert.equal(result.during, false)
            assert.equal(result.after, false)
            assert.equal(result.unchangedLocation, true)
            return result
        })
        await page.evaluate(mode => window.openFixture(mode), mode)
        await run(`${mode}: direct turn invalidates before relocate`, async () => {
            const result = await page.evaluate(async () => {
                const { view, proof } = window
                const old = view.lastLocation
                const turn = view.renderer.next()
                const before = { current: view.isPositionProofCurrent(proof), unchangedLocation: view.lastLocation === old }
                await turn
                return { ...before, finalMetrics: await view.renderer.pageMetrics() }
            })
            assert.equal(result.current, false)
            assert.equal(result.unchangedLocation, true)
            return result
        })
    }
    for (const mode of ['horizontal', 'vertical', 'rtl']) {
        await run(`${mode}: actual coordinator and renderer publish measured zero restore`, async () => {
            const result = await page.evaluate(async mode => {
                const { createEbookLoadHandlers, createNavigationIntentRunner } = await import('/ebook-load-coordinator.js')
                const messages = [], effects = []
                const host = { document, location, setTimeout: window.setTimeout.bind(window),
                    clearTimeout: window.clearTimeout.bind(window),
                    requestAnimationFrame: window.requestAnimationFrame.bind(window),
                    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
                    webkit: { messageHandlers: { ebookViewerLoaded: { postMessage: message => messages.push(message) } } } }
                class Reader {
                    async open() { this.view = await window.openFixture(mode, false) }
                    close() { this.isClosed = true; this.onLoadClosed?.(); this.view?.close() }
                    completeLastPositionLoad() { this.hasLoadedLastPosition = true; effects.push('complete') }
                    completeLastPositionLoadAttempt() { effects.push('attempt') }
                    collectLayoutGapProbe() { return null }
                }
                const handlers = createEbookLoadHandlers({ host, Reader,
                    CacheWarmer: class { destroy() {} },
                    makeNativeSource: url => ({ kind: 'native', url }),
                    makeFileSource: () => { throw new Error('Unexpected file source') },
                    installReaderPresentationState() {}, beginReplaceTextCacheGeneration() {},
                    beginForegroundCriticalSection: () => 1, finishForegroundCriticalSection() {},
                    ensureRestorePositionSaveUserInputTracking() {},
                    runWithNavigationIntent: createNavigationIntentRunner(host),
                    markReaderRenderReady() { effects.push('ready') },
                    postLandscapeInsetRestoreProbe() {}, scheduleDeferredCacheWarmerOpen() {},
                })
                await handlers.loadEBook({ url: 'ebook://reader/book.epub', loadRequestID: 'paired-zero',
                    initialRestore: { requestID: 'paired-zero', cfi: '', fractionalCompletion: 0 }, layoutMode: 'paginated' })
                const result = { messages, effects, ready: host.manabiLoadEBookReady,
                    saving: host.reader.hasLoadedLastPosition, suppression: host.__manabiRestoreInProgress,
                    measured: host.reader.view.lastLocation.fraction }
                host.reader.close()
                return result
            }, mode)
            assert.equal(result.messages.length, 1)
            const terminal = result.messages[0].initialRestoreResult
            assert.equal(terminal.loadRequestID, 'paired-zero')
            assert.equal(terminal.restoreSatisfied, true, JSON.stringify(result))
            assert.equal(terminal.positionMode, 'paginated')
            assert.equal(terminal.currentFractionalCompletion, result.measured)
            assert.ok(result.measured > 0)
            assert.equal(result.ready, true)
            assert.equal(result.saving, true)
            assert.equal(result.suppression, false)
            assert.equal(result.effects.filter(x => x === 'complete').length, 1)
            return result
        })
    }
    for (const operation of ['render', 'renderIfTypographyChanged']) {
        await run(`${operation}: destroy while dimensions are pending retires the continuation`, async () => {
            const result = await page.evaluate(async operation => {
                await window.openFixture('horizontal')
                const { view, proof } = window
                const renderer = view.renderer
                const sizes = renderer.sizes.bind(renderer)
                const measurements = await sizes()
                let release, entered
                const gate = new Promise(resolve => { release = resolve })
                const started = new Promise(resolve => { entered = resolve })
                renderer.sizes = () => { entered(); return gate }
                try {
                    const pending = renderer[operation]()
                    await started
                    const relocationCount = window.relocations.length
                    view.close()
                    release(measurements)
                    const outcome = await Promise.race([
                        pending.then(value => ({ settled: true, value })),
                        new Promise((_, reject) => setTimeout(() => reject(new Error('retired render did not settle')), 2000)),
                    ])
                    await window.frames(2)
                    return { ...outcome, proofCurrent: view.isPositionProofCurrent(proof),
                        relocatedAfterClose: window.relocations.length !== relocationCount }
                } finally {
                    release(measurements)
                    renderer.sizes = sizes
                }
            }, operation)
            assert.equal(result.settled, true)
            assert.equal(result.proofCurrent, false)
            assert.equal(result.relocatedAfterClose, false)
            if (operation === 'renderIfTypographyChanged') {
                assert.deepEqual(result.value, { rendered: false, reason: 'replaced' })
            }
            return result
        })
    }
    // Let existing debounced callbacks observe the final teardown before accepting an error-free run.
    await page.waitForTimeout(500)
    assert.deepEqual(errors, [])
} catch (error) {
    report.failure = error.stack ?? String(error)
} finally {
    try { await context?.close() } finally {
        try { await browser?.close() } finally {
            server.closeAllConnections()
            await new Promise(resolve => server.close(resolve))
        }
    }
    report.finishedAt = new Date().toISOString()
    report.counts = { executed: tests.length, passed: tests.filter(x => x.status === 'passed').length,
        failed: tests.filter(x => x.status === 'failed').length }
    report.resourcesClosed = true
    await writeFile(output, JSON.stringify(report, null, 2) + '\n', { flag: 'wx' })
    console.log(JSON.stringify({ output, counts: report.counts, failure: report.failure ?? null }))
    if (report.failure) process.exitCode = 1
}
