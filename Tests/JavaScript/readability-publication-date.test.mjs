import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import test from 'node:test'

// Run with jsdom 26 available to Node (for example through NODE_PATH).
const { JSDOM } = createRequire(import.meta.url)('jsdom')
const resources = new URL('../../Sources/LakeOfFireContent/Resources/', import.meta.url)
const readResource = path => readFileSync(new URL(path, resources), 'utf8')

// Mirror ReadabilityScript.swift's complete resource composition, without
// replacing the parser, sanitizer, template, CSS or embedded reader scripts.
const scripts = [
    readResource('User Scripts/readability_view_original.js'),
    readResource('User Scripts/readability_reader_mode.js'),
].join('\n;\n')
const css = readResource('CSS/Reader.css') + readResource('CSS/SwiftReadability.css')
const source = readResource('User Scripts/Readability.js')
    + readResource('User Scripts/dompurify.min.js')
    + readResource('User Scripts/readability_initialization.template.js')
        .replaceAll('##CHAR_THRESHOLD##', '1')
        .replaceAll('##CSS##', () => css)
        .replaceAll('##SCRIPT##', () => scripts)

const articleURL = 'https://reader.example/article?x=one&quote=%22&tag=%3Cpart%3E'
const paragraph = '<p>A substantive article paragraph contains several sentences about reading. '
    + 'This paragraph has enough ordinary text for the real bundled parser to retain the article.</p>'
const fixture = '<!doctype html><html><head><title>Publication fixture</title></head><body>'
    + '<article><h1>Publication fixture</h1>' + paragraph.repeat(12) + '</article></body></html>'

async function withParsedDate(value, verify, { url = articleURL, canonicalURL = url } = {}) {
    const dom = new JSDOM(fixture, { url, runScripts: 'outside-only' })
    const { window } = dom
    try {
        if (window.document.readyState !== 'complete') {
            await new Promise(resolve => window.addEventListener('load', resolve, { once: true }))
        }
        if (value !== undefined) {
            const meta = window.document.createElement('meta')
            meta.setAttribute('property', 'article:published_time')
            meta.setAttribute('content', value)
            window.document.head.append(meta)
        }
        const parsed = []
        const unavailable = []
        window.webkit = { messageHandlers: {
            readabilityParsed: { postMessage: payload => parsed.push(payload) },
            readabilityModeUnavailable: { postMessage: payload => unavailable.push(payload) },
            readabilityNeedsUpdate: { postMessage() {} },
            readabilityFramePing: { postMessage() {} },
            print: { postMessage() {} },
        } }
        window.eval(source)
        window.manabi_readability()

        assert.equal(unavailable.length, 0)
        assert.equal(parsed.length, 1)
        const payload = parsed[0]
        assert.equal(payload.pageURL, url)
        assert.equal(payload.windowURL, canonicalURL)
        assert.equal(typeof payload.title, 'string')
        assert.equal(typeof payload.byline, 'string')
        assert.equal(typeof payload.content, 'string')
        assert.equal(typeof payload.inputHTML, 'string')
        assert.equal(typeof payload.outputHTML, 'string')
        assert.equal(window.document.body.dataset.mnbReaderModeAvailable, 'true')
        assert.equal(window.document.body.dataset.mnbReaderModeAvailableFor, canonicalURL)

        // Output is parsed inertly. This does not execute the native rebuild,
        // generated scripts, WebKit rendering, navigation or trusted clicks.
        const output = new window.DOMParser().parseFromString(payload.outputHTML, 'text/html')
        assert.equal(output.body.classList.contains('readability-mode'), true)
        assert.match(output.getElementById('reader-content').textContent, /substantive article paragraph/)
        verify({ window, payload, output, date: output.getElementById('reader-publication-date') })
    } finally {
        window.close()
    }
}

for (const value of [
    '<span id="date-injected">not a date</span>',
    '<img src="missing" onerror="dateProbe=1">invalid',
    'unknown & pending <time>',
]) {
    test('publication metadata is literal text: ' + value, async () => {
        await withParsedDate(value, ({ payload, output, date }) => {
            assert.equal(payload.publishedTime, value)
            assert.equal(date.textContent, value)
            assert.equal(date.children.length, 0)
            assert.equal(output.querySelectorAll('#date-injected,img[onerror]').length, 0)
        })
    })
}

test('a valid date retains the existing formatter and bridge value', async () => {
    await withParsedDate('2026-10-22', ({ window, payload, date }) => {
        const expected = new window.Intl.DateTimeFormat(undefined, { dateStyle: 'short' })
            .format(new window.Date('2026-10-22'))
        assert.equal(payload.publishedTime, expected)
        assert.equal(date.textContent, expected)
        assert.equal(date.children.length, 0)
    })
})

for (const value of ['', undefined]) {
    test(value === '' ? 'empty date retains a null payload' : 'missing date retains a null payload', async () => {
        await withParsedDate(value, ({ payload, output, date }) => {
            assert.equal(Object.hasOwn(payload, 'publishedTime'), true)
            assert.equal(payload.publishedTime, null)
            assert.equal(date, null)
            assert.equal(output.getElementById('reader-meta-line'), null)
        })
    })
}

test('internal content preserves date text and canonical identity', async () => {
    const value = 'unknown & pending <time>'
    await withParsedDate(value, ({ payload, output, date }) => {
        assert.equal(payload.publishedTime, value)
        assert.equal(date.textContent, value)
        assert.equal(date.children.length, 0)
        assert.equal(output.querySelectorAll('.reader-view-original').length, 0)
    }, { url: 'internal://local/snippet?key=publication-fixture' })
})

test('synthetic loader parsing retains the canonical article identity', async () => {
    // Controlled direct invocation only; a fixture at this URL does not prove
    // that native code admits extraction of a real loader document.
    const canonicalURL = 'https://reader.example/original?section=2'
    const url = 'internal://local/load/reader?reader-url=' + encodeURIComponent(canonicalURL)
    const value = '<span id="date-injected">not a date</span>'
    await withParsedDate(value, ({ payload, output, date }) => {
        assert.equal(payload.publishedTime, value)
        assert.equal(date.textContent, value)
        assert.equal(date.children.length, 0)
        assert.equal(output.querySelectorAll('#date-injected').length, 0)
    }, { url, canonicalURL })
})
