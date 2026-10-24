import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import test from 'node:test'

const { JSDOM, VirtualConsole } = createRequire(import.meta.url)('jsdom')
const scriptPath = process.env.READER_CAROUSEL_SCRIPT ?? new URL(
    '../../Sources/LakeOfFireContent/Resources/User Scripts/readability_reader_mode.js',
    import.meta.url,
)
const script = readFileSync(scriptPath, 'utf8')

// Execute the complete production script with jsdom's DOM and MutationObserver.
// Only layout, scrolling and animation-frame delivery are controlled: jsdom does
// not render. These checks do not qualify WebKit layout or native scrolling.
const scenarios = [
    { name: 'already active reader mode', readyState: 'complete', active: true },
    { name: 'DOMContentLoaded activation', readyState: 'loading', active: true },
    { name: 'later reader-mode activation', readyState: 'complete', active: false },
]

async function exerciseScenario({ readyState, active }) {
    const diagnostics = { console: [], nativePrint: [] }
    const errors = []
    const virtualConsole = new VirtualConsole()
    for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        virtualConsole.on(level, (...arguments_) => {
            diagnostics.console.push({ level, arguments: arguments_ })
        })
    }
    virtualConsole.on('jsdomError', error => errors.push(error.message))

    const dom = new JSDOM(
        '<!doctype html><body><header id="reader-header"></header><main id="reader-content"></main></body>',
        {
            url: 'https://reader.example.test/article',
            runScripts: 'outside-only',
            virtualConsole,
        },
    )
    const { window } = dom
    const { document } = window
    try {
        // Finish jsdom's initial document events before controlling the one
        // production installation and, where relevant, its DOMContentLoaded.
        await new Promise(resolve => {
            if (document.readyState === 'complete') resolve()
            else window.addEventListener('load', resolve, { once: true })
        })
        Object.defineProperty(document, 'readyState', {
            configurable: true,
            get: () => readyState,
        })
        if (active) document.body.classList.add('readability-mode')

        window.webkit = {
            messageHandlers: {
                print: { postMessage: message => diagnostics.nativePrint.push(message) },
            },
        }
        const frames = new Map()
        let nextFrame = 0
        window.requestAnimationFrame = callback => {
            frames.set(++nextFrame, callback)
            return nextFrame
        }
        window.cancelAnimationFrame = identifier => frames.delete(identifier)
        const settle = async () => {
            await new Promise(resolve => setImmediate(resolve))
            const pending = [...frames.values()]
            frames.clear()
            for (const callback of pending) callback(16)
            await new Promise(resolve => setImmediate(resolve))
        }

        const createCarousel = identifier => {
            const carousel = document.createElement('section')
            carousel.dataset.readabilityCarousel = 'true'
            const track = document.createElement('div')
            track.setAttribute('data-readability-carousel-track', '')
            track.getBoundingClientRect = () => new window.DOMRect(0, 0, 100, 80)
            const destinations = []
            const scrollCalls = []
            for (let index = 0; index < 3; index += 1) {
                const slide = document.createElement('figure')
                slide.setAttribute('data-readability-carousel-slide', '')
                const link = document.createElement('a')
                link.href = `https://images.example.test/${identifier}/${index + 1}.jpg`
                link.textContent = `Image ${index + 1}`
                destinations.push(link.href)
                slide.append(link)
                slide.getBoundingClientRect = () => new window.DOMRect(
                    index * 100 - track.scrollLeft, 0, 100, 80,
                )
                slide.scrollIntoView = options => {
                    scrollCalls.push({ destination: link.href, options: { ...options } })
                    track.scrollLeft = index * 100
                    track.dispatchEvent(new window.Event('scroll'))
                }
                track.append(slide)
            }
            carousel.append(track)
            return { carousel, track, destinations, scrollCalls }
        }

        const content = document.getElementById('reader-content')
        const existing = createCarousel('existing')
        content.append(existing.carousel)
        const missingTrack = document.createElement('section')
        missingTrack.dataset.readabilityCarousel = 'true'
        missingTrack.textContent = 'Article material must not be sent to diagnostics'
        document.getElementById('reader-header').append(missingTrack)
        const singleSlide = document.createElement('section')
        singleSlide.dataset.readabilityCarousel = 'true'
        singleSlide.innerHTML = '<div data-readability-carousel-track><figure data-readability-carousel-slide></figure></div>'
        content.append(singleSlide)

        window.eval(script)
        await settle()
        if (readyState !== 'complete' || !active) {
            assert.equal(document.querySelectorAll('[data-readability-carousel-controls]').length, 0)
        }
        if (readyState !== 'complete') {
            readyState = 'interactive'
            document.dispatchEvent(new window.Event('DOMContentLoaded'))
            await settle()
        }
        if (!active) {
            document.body.classList.add('readability-mode')
            await settle()
        }

        const exerciseControls = async ({ carousel, track, destinations, scrollCalls }) => {
            assert.equal(carousel.querySelectorAll('[data-readability-carousel-controls]').length, 1)
            const previous = carousel.querySelector('[data-readability-carousel-button="previous"]')
            const next = carousel.querySelector('[data-readability-carousel-button="next"]')
            const status = carousel.querySelector('[data-readability-carousel-status]')
            assert.equal(previous.type, 'button')
            assert.equal(next.type, 'button')
            assert.equal(previous.getAttribute('aria-label'), 'Previous image')
            assert.equal(next.getAttribute('aria-label'), 'Next image')
            assert.equal(status.getAttribute('aria-live'), 'polite')
            assert.equal(status.textContent, '1 / 3')
            assert.equal(previous.disabled, true)
            assert.equal(next.disabled, false)

            previous.click()
            assert.equal(scrollCalls.length, 0)
            next.click()
            await settle()
            assert.deepEqual(scrollCalls.at(-1), {
                destination: destinations[1],
                options: { behavior: 'smooth', block: 'nearest', inline: 'center' },
            })
            assert.equal(status.textContent, '2 / 3')
            assert.equal(previous.disabled, false)
            assert.equal(next.disabled, false)

            next.click()
            await settle()
            assert.equal(scrollCalls.at(-1).destination, destinations[2])
            assert.equal(status.textContent, '3 / 3')
            assert.equal(next.disabled, true)
            const endCount = scrollCalls.length
            next.click()
            assert.equal(scrollCalls.length, endCount)
            previous.click()
            await settle()
            assert.equal(scrollCalls.at(-1).destination, destinations[1])
            assert.equal(status.textContent, '2 / 3')

            track.scrollLeft = 0
            track.dispatchEvent(new window.Event('scroll'))
            await settle()
            assert.equal(status.textContent, '1 / 3')
            assert.equal(previous.disabled, true)
            assert.equal(next.disabled, false)
            assert.deepEqual([...track.querySelectorAll('a')].map(link => link.href), destinations)
        }

        await exerciseControls(existing)
        const inserted = createCarousel('inserted')
        const wrapper = document.createElement('article')
        wrapper.append(inserted.carousel)
        content.append(wrapper)
        await settle()
        await exerciseControls(inserted)

        existing.carousel.remove()
        await settle()
        content.append(existing.carousel)
        await settle()
        assert.equal(existing.carousel.querySelectorAll('[data-readability-carousel-controls]').length, 1)
        const countBeforeReinsertedClick = existing.scrollCalls.length
        existing.carousel.querySelector('[data-readability-carousel-button="next"]').click()
        await settle()
        assert.equal(existing.scrollCalls.length, countBeforeReinsertedClick + 1)
        assert.equal(existing.scrollCalls.at(-1).destination, existing.destinations[1])
        assert.equal(existing.carousel.querySelector('[data-readability-carousel-status]').textContent, '2 / 3')

        assert.equal(missingTrack.querySelector('[data-readability-carousel-controls]'), null)
        assert.equal(singleSlide.querySelector('[data-readability-carousel-controls]'), null)
        assert.deepEqual(errors, [])
        return { console: diagnostics.console.length, nativePrint: diagnostics.nativePrint.length }
    } finally {
        window.close()
    }
}

// Keep behavioral preservation and diagnostic removal as separate results while
// executing each scenario once. The exact unmodified parent passes preservation
// and fails only the zero-diagnostics assertion.
const outcomes = new Map()
const outcomeFor = scenario => {
    if (!outcomes.has(scenario.name)) outcomes.set(scenario.name, exerciseScenario(scenario))
    return outcomes.get(scenario.name)
}

for (const scenario of scenarios) {
    test(`${scenario.name}: controls, status, image links and mutation insertion`, async () => {
        await outcomeFor(scenario)
    })
    test(`${scenario.name}: no console or native-print diagnostics`, async () => {
        assert.deepEqual(await outcomeFor(scenario), { console: 0, nativePrint: 0 })
    })
}
