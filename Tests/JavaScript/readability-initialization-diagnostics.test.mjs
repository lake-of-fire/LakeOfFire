// Requires jsdom 26.1.0: npm install --prefix /tmp/lake-js-tests --ignore-scripts jsdom@26.1.0
// NODE_PATH=/tmp/lake-js-tests/node_modules node --test --test-isolation=none Tests/JavaScript/readability-initialization-diagnostics.test.mjs
// Optional READABILITY_TEMPLATE selects an exact baseline template for the negative control.
// Optional READABILITY_REFERENCE_TEMPLATE executes that template too and compares functional results.
// The real bundled parser, sanitizer, template, CSS and embedded scripts are assembled as in
// ReadabilityScript.swift. Output HTML is parsed inertly; WebKit/native execution is not modeled.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import test from 'node:test'

const require = createRequire(import.meta.url)
const { JSDOM, VirtualConsole } = require('jsdom')
const resources = new URL('../../Sources/LakeOfFireContent/Resources/', import.meta.url)
const resource = path => readFileSync(new URL(path, resources), 'utf8')
const template = process.env.READABILITY_TEMPLATE
    ? readFileSync(process.env.READABILITY_TEMPLATE, 'utf8')
    : resource('User Scripts/readability_initialization.template.js')
const referenceTemplate = process.env.READABILITY_REFERENCE_TEMPLATE
    ? readFileSync(process.env.READABILITY_REFERENCE_TEMPLATE, 'utf8')
    : null
const parserAndSanitizer = resource('User Scripts/Readability.js') + resource('User Scripts/dompurify.min.js')
const css = resource('CSS/Reader.css') + resource('CSS/SwiftReadability.css')
const embeddedScripts = [
    resource('User Scripts/readability_view_original.js'),
    resource('User Scripts/readability_reader_mode.js')
].join('\n;\n')

function assembledSource(sourceTemplate) {
    return parserAndSanitizer + sourceTemplate
        .replaceAll('##CHAR_THRESHOLD##', () => '1')
        .replaceAll('##CSS##', () => css)
        .replaceAll('##SCRIPT##', () => embeddedScripts)
}

const articleHTML = `<!DOCTYPE html><html><head>
    <title>A quiet reading session</title>
    <meta name="author" content="Reader &amp; Writer">
    <meta property="article:published_time" content="2026-10-24">
    </head><body><main><article><h1>A quiet reading session</h1>
    ${Array.from({ length: 4 }, () => `<p>Reading preserves the meaning of every paragraph, including
        punctuation, links and useful context. This article supplies enough connected prose for the
        bundled parser to extract its actual content. We read <ruby><rb>日本語</rb><rp>(</rp><rt>にほんご</rt><rp>)</rp></ruby>
        and then follow <a href="/another-article">another article</a> to continue learning.</p>`).join('')}
    </article></main></body></html>`

function makeHarness(sourceTemplate, options = {}) {
    const messages = []
    const consoleMessages = []
    const errors = []
    const virtualConsole = new VirtualConsole()
    virtualConsole.on('jsdomError', error => errors.push(error.message))
    const dom = new JSDOM(options.html ?? articleHTML, {
        url: options.url ?? 'https://example.com/article',
        runScripts: 'outside-only',
        virtualConsole
    })
    const { window } = dom
    Object.defineProperty(window.document, 'readyState', { value: 'complete', configurable: true })
    for (const method of ['log', 'warn', 'error', 'debug']) {
        window.console[method] = (...values) => consoleMessages.push({ method, values: values.map(String) })
    }

    let now = 0
    let identifier = 0
    const timers = new Map()
    window.setTimeout = (callback, delay = 0, ...arguments_) => {
        const id = ++identifier
        timers.set(id, { callback, arguments_, at: now + Number(delay) })
        return id
    }
    window.clearTimeout = id => timers.delete(id)
    // These main-frame fixtures must never start frame-ping intervals.
    window.setInterval = () => { throw new Error('Unexpected main-frame interval') }

    const handlers = {}
    for (const name of ['print', 'readabilityNeedsUpdate', 'readabilityParsed', 'readabilityModeUnavailable', 'readabilityFramePing']) {
        if (name === 'print' && options.print === 'missing') continue
        handlers[name] = {
            postMessage(payload) {
                messages.push({ handler: name, payload: JSON.parse(JSON.stringify(payload)) })
                if (name === options.throwingHandler || name === 'print' && options.print === 'throwing') {
                    throw new Error(`Controlled ${name} failure`)
                }
            }
        }
    }
    window.webkit = { messageHandlers: handlers }
    Object.assign(window.document.body?.dataset ?? {}, options.dataset)
    window.eval(assembledSource(sourceTemplate))

    if (options.parserResult) {
        // Only the sanitized-empty and malformed-field branches use a controlled parser result.
        // All normal, null, navigation and mutation cases run the complete bundled parser.
        window.Readability = class {
            parse() { return options.parserResult }
        }
    }

    return {
        window,
        messages,
        consoleMessages,
        errors,
        reconfigureURL: url => dom.reconfigure({ url }),
        async flushMutations() { await Promise.resolve() },
        advance(milliseconds) {
            const end = now + milliseconds
            let count = 0
            while (true) {
                const next = [...timers.entries()]
                    .filter(([, timer]) => timer.at <= end)
                    .sort(([, left], [, right]) => left.at - right.at)[0]
                if (!next) break
                assert.ok(++count < 100, 'Timer scheduling must remain bounded')
                const [id, timer] = next
                timers.delete(id)
                now = timer.at
                timer.callback(...timer.arguments_)
            }
            now = end
        },
        snapshot() {
            return {
                messages: messages.filter(message => message.handler !== 'print'),
                dataset: { ...window.document.body?.dataset }
            }
        },
        close: () => window.close()
    }
}

async function exercise(t, options, action) {
    const candidate = makeHarness(template, options)
    try {
        await action(candidate)
        assert.deepEqual(candidate.errors, [])
        const snapshot = candidate.snapshot()
        if (referenceTemplate) {
            const reference = makeHarness(referenceTemplate, options)
            try {
                await action(reference)
                assert.deepEqual(reference.errors, [])
                assert.deepEqual(snapshot, reference.snapshot(), 'All functional messages, payloads and availability must be unchanged')
                t.diagnostic(`reference print payloads: ${reference.messages.filter(message => message.handler === 'print').length}`)
            } finally {
                reference.close()
            }
        }
        assert.equal(candidate.messages.filter(message => message.handler === 'print').length, 0,
            'Readability initialization and extraction must not emit diagnostic bridge messages')
        assert.deepEqual(candidate.consoleMessages, [], 'Diagnostic bridge failures must not produce console traffic')
        return snapshot
    } finally {
        candidate.close()
    }
}

function messagesNamed(harness, name) {
    return harness.messages.filter(message => message.handler === name)
}

test('real extraction preserves metadata, normalized ruby, payload HTML and availability without diagnostics', async t => {
    await exercise(t, {}, harness => {
        const { window } = harness
        window.manabi_readability()
        const parsed = messagesNamed(harness, 'readabilityParsed')
        assert.equal(parsed.length, 1)
        const payload = parsed[0].payload
        assert.equal(payload.windowURL, 'https://example.com/article')
        assert.equal(payload.pageURL, 'https://example.com/article')
        assert.equal(typeof payload.publishedTime, 'string')
        assert.equal(typeof payload.inputHTML, 'string')
        assert.equal(typeof payload.content, 'string')
        assert.equal(payload.readabilityContainerSelector, null)
        const output = new window.DOMParser().parseFromString(payload.outputHTML, 'text/html')
        assert.equal(output.getElementById('reader-title').textContent, 'A quiet reading session')
        assert.equal(output.getElementById('reader-byline').textContent, 'Reader & Writer')
        assert.equal(output.getElementById('reader-publication-date').textContent, payload.publishedTime)
        assert.equal(output.querySelectorAll('ruby rp, ruby rb').length, 0)
        assert.ok(output.getElementById('reader-content').textContent.includes('日本語'))
        assert.equal(window.document.body.dataset.mnbReaderModeAvailable, 'true')
        assert.equal(window.document.body.dataset.mnbReaderModeAvailableFor, payload.windowURL)
        assert.equal(messagesNamed(harness, 'readabilityModeUnavailable').length, 0)
    })
})

test('real null parse clears the stale availability cache and leaves native next-load ownership unchanged', async t => {
    await exercise(t, {
        html: '<!DOCTYPE html><html><head><title>Empty page</title></head><body></body></html>',
        dataset: { mnbReaderModeAvailable: 'true', mnbReaderModeAvailableFor: 'https://example.com/old', isNextLoadInReaderMode: 'true' }
    }, harness => {
        harness.window.manabi_readability()
        assert.equal(messagesNamed(harness, 'readabilityParsed').length, 0)
        assert.equal(messagesNamed(harness, 'readabilityModeUnavailable').length, 1)
        assert.equal(harness.window.document.body.dataset.mnbReaderModeAvailable, 'false')
        assert.equal(harness.window.document.body.dataset.mnbReaderModeAvailableFor, undefined)
        assert.equal(harness.window.document.body.dataset.isNextLoadInReaderMode, 'true')
    })
})

test('sanitized-empty parser output remains unavailable and clears the stale cache', async t => {
    await exercise(t, {
        parserResult: { title: 'Empty result', byline: '', content: '<script>window.unexpected = true</script>' },
        dataset: { mnbReaderModeAvailable: 'true', mnbReaderModeAvailableFor: 'https://example.com/old' }
    }, harness => {
        harness.window.manabi_readability()
        assert.equal(messagesNamed(harness, 'readabilityParsed').length, 0)
        assert.equal(messagesNamed(harness, 'readabilityModeUnavailable').length, 1)
        assert.equal(harness.window.document.body.dataset.mnbReaderModeAvailable, 'false')
        assert.equal(harness.window.document.body.dataset.mnbReaderModeAvailableFor, undefined)
        assert.equal(harness.window.unexpected, undefined)
    })
})

test('typed parser-field guards remain distinct from diagnostic removal', async t => {
    await exercise(t, {
        parserResult: { title: 42, byline: { text: 'Unexpected object' }, publishedTime: false, content: '<p>Valid body</p>' }
    }, harness => {
        harness.window.manabi_readability()
        const payload = messagesNamed(harness, 'readabilityParsed')[0].payload
        assert.equal(payload.title, '')
        assert.equal(payload.byline, '')
        assert.equal(payload.publishedTime, null)
        assert.equal(new harness.window.DOMParser().parseFromString(payload.outputHTML, 'text/html')
            .getElementById('reader-content').textContent.trim(), 'Valid body')
    })
})

test('already rendered Reader documents stay idempotent', async t => {
    await exercise(t, {
        html: '<!DOCTYPE html><html><body class="readability-mode"><div id="reader-content"><p>Already rendered</p></div></body></html>',
        dataset: { mnbReaderModeAvailable: 'true' }
    }, harness => {
        harness.window.manabi_readability()
        assert.equal(messagesNamed(harness, 'readabilityParsed').length, 0)
        assert.equal(messagesNamed(harness, 'readabilityModeUnavailable').length, 0)
        assert.equal(harness.window.document.getElementById('reader-content').textContent, 'Already rendered')
    })
})

test('excluded HTTPS hosts preserve the native unavailable result', async t => {
    await exercise(t, { url: 'https://x.com/article' }, harness => {
        harness.window.manabi_readability()
        assert.equal(messagesNamed(harness, 'readabilityParsed').length, 0)
        assert.deepEqual(messagesNamed(harness, 'readabilityModeUnavailable'), [{
            handler: 'readabilityModeUnavailable',
            payload: { pageURL: 'https://x.com/article', windowURL: 'https://x.com/article' }
        }])
    })
})

for (const method of ['pushState', 'replaceState', 'popstate']) {
    test(`${method} retains location invalidation and settled automatic requests`, async t => {
        await exercise(t, {}, async harness => {
            const { window } = harness
            window.manabi_readability()
            if (method === 'popstate') {
                harness.reconfigureURL('https://example.com/next')
                window.dispatchEvent(new window.PopStateEvent('popstate'))
            } else {
                window.history[method]({}, '', '/next')
            }
            harness.advance(0)
            assert.equal(window.document.body.dataset.mnbReaderModeAvailable, 'false')
            assert.equal(window.document.body.dataset.mnbReaderModeAvailableFor, undefined)
            assert.equal(window.document.body.dataset.isNextLoadInReaderMode, 'false')
            harness.advance(500)
            harness.advance(1000)
            const reasons = messagesNamed(harness, 'readabilityNeedsUpdate').map(message => message.payload.reason)
            assert.deepEqual(reasons, ['page-load', method, `${method}-settled`, `${method}-late`])
            const event = new window.Event('pageshow')
            Object.defineProperty(event, 'persisted', { value: true })
            window.dispatchEvent(event)
            assert.equal(messagesNamed(harness, 'readabilityNeedsUpdate').at(-1).payload.reason, 'page-show-persisted')
            await harness.flushMutations()
        })
    })
}

test('actual document-child mutation retains functional behavior without serializing diagnostic summaries', async t => {
    await exercise(t, {}, async harness => {
        harness.window.manabi_readability()
        const before = harness.snapshot()
        const document = harness.window.document
        document.replaceChild(document.documentElement.cloneNode(true), document.documentElement)
        await harness.flushMutations()
        harness.advance(6000)
        assert.deepEqual(harness.snapshot(), before)
    })
})

for (const print of ['missing', 'throwing']) {
    test(`${print} diagnostic sink leaves actual extraction functional`, async t => {
        await exercise(t, { print }, harness => {
            harness.window.manabi_readability()
            assert.equal(messagesNamed(harness, 'readabilityParsed').length, 1)
            assert.equal(harness.window.document.body.dataset.mnbReaderModeAvailable, 'true')
        })
    })
}

test('required parsed-result publication failure remains visible to its caller', async t => {
    await exercise(t, { throwingHandler: 'readabilityParsed' }, harness => {
        assert.throws(() => harness.window.manabi_readability(), /Controlled readabilityParsed failure/)
        assert.equal(messagesNamed(harness, 'readabilityParsed').length, 1)
    })
})

test('optional automatic-request publication failure does not prevent extraction', async t => {
    await exercise(t, { throwingHandler: 'readabilityNeedsUpdate' }, harness => {
        harness.window.manabi_readability()
        assert.equal(messagesNamed(harness, 'readabilityParsed').length, 1)
    })
})

test('about documents retain their skipped automatic initialization', async t => {
    await exercise(t, { url: 'about:blank' }, harness => {
        assert.deepEqual(harness.messages, [])
    })
})
