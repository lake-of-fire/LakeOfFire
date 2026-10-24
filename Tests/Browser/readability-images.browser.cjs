#!/usr/bin/env node
// Real-browser checks for the complete Readability image script. Supply the
// exact Core source/CSS with --core-source and --core-css. Only Core's actual
// scroll-restoration helper is extracted; this is not full Reader assembly or
// WKWebView qualification. HTTP responses are gated, but image loading,
// decoding, events, CSS layout, timers, observers, and scrolling are native.
const assert = require('node:assert/strict')
const { createHash } = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')
const { parseArgs } = require('node:util')
const { chromium } = require('playwright')

const defaultSource = path.resolve(__dirname,
  '../../Sources/LakeOfFireContent/Resources/User Scripts/readability_images.js')
const blob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex')
const picture = '<svg xmlns="http://www.w3.org/2000/svg" width="300" height="150"><rect width="300" height="150" fill="teal"/></svg>'
const origin = 'https://reader-fixture.invalid'
const imageMarkup = '<p id="wrapper"><img id="image"></p>'
const scrollTarget = '<div style="height:2000px"></div><section id="target">Saved sentence</section><div style="height:800px"></div>'

function extractRestore(source) {
  const start = source.indexOf('window.manabi_scrollToNodeAfterPrecedingImagesLoad = function (node) {')
  const end = source.indexOf('window.manabi_refreshArticleReadingProgress = function', start)
  if (start < 0 || end < start) throw new Error('Selected Core restoration helper was not found')
  return source.slice(start, end)
}

async function settle(page) {
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
}

async function fixture(browser, inputs, markup = imageMarkup, vertical = false) {
  const context = await browser.newContext({ viewport: { width: 1100, height: 800 } })
  const page = await context.newPage()
  page.setDefaultTimeout(5000)
  const errors = []
  const gates = new Map()
  page.on('pageerror', error => errors.push(String(error)))
  await context.route('**/*', async route => {
    const url = new URL(route.request().url())
    if (url.origin === origin && url.pathname === '/article') {
      await route.fulfill({ contentType: 'text/html', body: `<!doctype html><html><head></head>
        <body class="readability-mode${vertical ? ' reader-vertical-writing' : ''}"
        data-is-ebook="false" data-mnb-writing-direction="${vertical ? 'vertical' : 'horizontal'}"
        data-mnb-settings-initialized="true" data-mnb-color-scheme="light"
        style="--mnb-reader-content-column-width:800px;--mnb-reader-safe-area-width-px:1100px;
        --mnb-reader-safe-area-height-px:800px;--mnb-content-font:sans-serif">
        <div id="reader-content">${markup}${scrollTarget}</div></body></html>` })
      return
    }
    const gate = gates.get(url.pathname)
    if (url.origin === origin && gate) {
      gate.requested()
      const response = await gate.response
      await route.fulfill(response)
      return
    }
    await route.abort()
  })
  await page.goto(`${origin}/article`)
  await page.addStyleTag({ content: inputs.css })
  await page.evaluate(() => {
    window.imageEvents = {}
    window.observeFixtureImage = image => {
      const record = window.imageEvents[image.id] = { loads: [], errors: [] }
      image.addEventListener('load', event => record.loads.push({
        trusted: event.isTrusted, width: image.naturalWidth, height: image.naturalHeight,
      }))
      image.addEventListener('error', event => record.errors.push({ trusted: event.isTrusted }))
    }
    for (const image of document.images) window.observeFixtureImage(image)
  })
  await page.addScriptTag({ content: inputs.restore })
  function gate(name) {
    const pathname = `/images/${name}.svg`
    let requested
    let release
    const started = new Promise(resolve => { requested = resolve })
    const response = new Promise(resolve => { release = resolve })
    gates.set(pathname, { requested, response, release })
    return {
      url: `${origin}${pathname}`,
      started,
      release: (success = true) => release(success
        ? { status: 200, contentType: 'image/svg+xml', body: picture }
        : { status: 404, contentType: 'text/plain', body: 'Image unavailable' }),
    }
  }
  async function start(id = 'image', name = id) {
    const request = gate(name)
    const pending = await page.evaluate(({ id, url }) => {
      const image = document.getElementById(id)
      image.src = url
      return { complete: image.complete, naturalWidth: image.naturalWidth, width: image.width }
    }, { id, url: request.url })
    await request.started
    assert.equal(pending.complete, false, 'the image request must genuinely be pending')
    assert.equal(pending.naturalWidth, 0)
    return request
  }
  async function loaded(id = 'image') {
    await page.waitForFunction(id => {
      const image = document.getElementById(id)
      return image.complete && image.naturalWidth === 300 && window.imageEvents[id].loads.length > 0
    }, id)
    await page.evaluate(id => document.getElementById(id).decode(), id)
    await settle(page)
  }
  return {
    page, errors, gate, start, loaded,
    install: () => page.addScriptTag({ content: inputs.images }),
    restore: () => page.evaluate(() => window.manabi_scrollToNodeAfterPrecedingImagesLoad(document.getElementById('target'))),
    close: async () => {
      for (const request of gates.values()) request.release({ status: 200, contentType: 'image/svg+xml', body: picture })
      await context.close()
    },
  }
}

async function snapshot(page, id = 'image') {
  return page.evaluate(id => {
    const image = document.getElementById(id)
    const style = getComputedStyle(image)
    const rect = image.getBoundingClientRect()
    const wrapper = document.getElementById('wrapper') || image.parentElement
    return {
      naturalWidth: image.naturalWidth, naturalHeight: image.naturalHeight, complete: image.complete,
      width: rect.width, height: rect.height, contentWidth: document.getElementById('reader-content').offsetWidth,
      managed: image.dataset.manabiManagedReaderImageSizing || null,
      inlineWidth: image.style.width, inlineMaxWidth: image.style.maxWidth,
      radius: style.borderRadius, writingMode: style.writingMode,
      wrapperInline: wrapper.classList.contains('mnb-vertical-inline-image-wrapper'),
      events: window.imageEvents[id], scrollY: window.scrollY,
      targetTop: document.getElementById('target').getBoundingClientRect().top,
    }
  }, id)
}

function verifyLoaded(value) {
  assert.equal(value.complete, true)
  assert.equal(value.naturalWidth, 300)
  assert.equal(value.naturalHeight, 150)
  assert.deepEqual(value.events.loads, [{ trusted: true, width: 300, height: 150 }])
}

function verifyHorizontal(value) {
  verifyLoaded(value)
  assert.equal(value.contentWidth, 800)
  assert.equal(value.managed, '1')
  assert.equal(value.width, 600)
  assert.equal(value.height, 300)
  assert.equal(value.radius, '6px')
}

function verifyRestore(value) {
  verifyHorizontal(value)
  assert.ok(value.scrollY > 1000, 'actual Core helper must perform native scrolling after load')
  assert.ok(Math.abs(value.targetTop) < 1, 'restored target must align with the viewport')
}

function cases() {
  const result = []
  for (const ordering of ['restore-before-images', 'images-before-restore', 'refresh-during-restore']) {
    result.push({ name: `pending/${ordering}`, run: async f => {
      const request = await f.start()
      assert.equal(await f.page.evaluate(() => document.getElementById('image').width), 0)
      if (ordering === 'restore-before-images') {
        await f.restore()
        await f.install()
      } else {
        await f.install()
        await f.restore()
        if (ordering === 'refresh-during-restore') await f.page.evaluate(() => window.manabiUpdateReadabilityImageMargins())
      }
      request.release()
      await f.loaded()
      return snapshot(f.page)
    }, verify: verifyRestore })
  }
  result.push({ name: 'inserted-subtree/pending-image', markup: '', run: async f => {
    await f.install()
    const request = f.gate('inserted-pending')
    await f.page.evaluate(url => {
      const wrapper = document.createElement('p')
      wrapper.id = 'wrapper'
      wrapper.innerHTML = '<a><img id="image"></a>'
      window.observeFixtureImage(wrapper.querySelector('img'))
      wrapper.querySelector('img').src = url
      document.getElementById('reader-content').prepend(wrapper)
    }, request.url)
    await request.started
    await f.page.waitForTimeout(300) // Let the production 250ms debounce run while the image is pending.
    assert.equal(await f.page.evaluate(() => document.getElementById('image').complete), false)
    request.release()
    await f.loaded()
    return snapshot(f.page)
  }, verify: verifyHorizontal })
  result.push({ name: 'inserted-subtree/already-decoded-image', markup: '', run: async f => {
    await f.install()
    const request = f.gate('inserted-decoded')
    await f.page.evaluate(url => {
      const wrapper = document.createElement('p')
      wrapper.id = 'wrapper'
      wrapper.innerHTML = '<a><img id="image"></a>'
      window.detachedWrapper = wrapper
      const image = wrapper.querySelector('img')
      window.observeFixtureImage(image)
      image.src = url
    }, request.url)
    await request.started
    request.release()
    await f.page.waitForFunction(() => window.detachedWrapper.querySelector('img').complete
      && window.imageEvents.image.loads.length === 1)
    await f.page.evaluate(async () => {
      await window.detachedWrapper.querySelector('img').decode()
      document.getElementById('reader-content').prepend(window.detachedWrapper)
    })
    await f.page.waitForTimeout(300)
    await settle(f.page)
    return snapshot(f.page)
  }, verify: verifyHorizontal })
  for (const nested of [false, true]) {
    const caption = nested ? '<a>Caption text <img id="caption-image"></a>' : 'Caption text <img id="caption-image">'
    result.push({ name: `vertical-caption/${nested ? 'inside-link' : 'beside-image'}`, vertical: true,
      markup: `<mnb-section><p id="caption">${caption}</p><p id="image-only"> \n<a><img id="image"></a> \n</p></mnb-section>`,
      run: async f => {
        await f.install()
        const requests = await Promise.all([f.start('caption-image'), f.start()])
        for (const request of requests) request.release()
        await Promise.all([f.loaded('caption-image'), f.loaded()])
        return f.page.evaluate(() => {
          const sample = id => {
            const element = document.getElementById(id)
            const style = getComputedStyle(element)
            return { display: style.display, marginStart: style.marginBlockStart, marginEnd: style.marginBlockEnd,
              writingMode: style.writingMode, text: element.textContent.trim(),
              height: element.getBoundingClientRect().height,
              inline: element.classList.contains('mnb-vertical-inline-image-wrapper') }
          }
          return { caption: sample('caption'), imageOnly: sample('image-only'), events: window.imageEvents }
        })
      }, verify: value => {
        assert.equal(value.caption.display, 'block')
        assert.equal(value.caption.inline, false)
        assert.equal(value.caption.writingMode, 'vertical-rl')
        assert.ok(parseFloat(value.caption.marginStart) > 0)
        assert.ok(parseFloat(value.caption.marginEnd) > 0)
        assert.equal(value.caption.text, 'Caption text')
        assert.ok(value.caption.height > 0)
        assert.equal(value.imageOnly.display, 'inline')
        assert.equal(value.imageOnly.inline, true)
        assert.equal(value.imageOnly.marginStart, '0px')
        assert.equal(value.imageOnly.marginEnd, '0px')
        for (const events of Object.values(value.events)) assert.deepEqual(events.loads, [{ trusted: true, width: 300, height: 150 }])
      } })
  }
  result.push({ name: 'direction-switch/before-decode', run: async f => {
    const request = await f.start()
    await f.install()
    await f.page.evaluate(() => {
      document.body.dataset.mnbWritingDirection = 'vertical'
      document.body.classList.add('reader-vertical-writing')
      window.manabiUpdateReadabilityImageMargins()
    })
    request.release()
    await f.loaded()
    return snapshot(f.page)
  }, verify: value => {
    verifyLoaded(value)
    assert.equal(value.managed, null)
    assert.equal(value.inlineWidth, '')
    assert.equal(value.inlineMaxWidth, '')
    assert.equal(value.wrapperInline, true)
    assert.equal(value.width, 300)
    assert.equal(value.height, 150)
    assert.equal(value.radius, '6px')
  } })
  result.push({ name: 'control/already-decoded-before-install', run: async f => {
    const request = await f.start()
    request.release()
    await f.loaded()
    await f.install()
    await f.restore()
    await settle(f.page)
    return snapshot(f.page)
  }, verify: verifyRestore })
  result.push({ name: 'failure/restore-settles-and-retry-loads', run: async f => {
    const failed = await f.start('image', 'failed')
    await f.install()
    await f.restore()
    failed.release(false)
    await f.page.waitForFunction(() => window.imageEvents.image.errors.length === 1)
    await settle(f.page)
    const failedState = await snapshot(f.page)
    const retry = await f.start('image', 'retry')
    retry.release()
    await f.loaded()
    return { failedState, retried: await snapshot(f.page) }
  }, verify: value => {
    assert.equal(value.failedState.naturalWidth, 0)
    assert.deepEqual(value.failedState.events.errors, [{ trusted: true }])
    assert.ok(value.failedState.scrollY > 1000, 'actual Core error callback must settle restoration')
    verifyHorizontal(value.retried)
    assert.deepEqual(value.retried.events.errors, [{ trusted: true }])
  } })
  return result
}

async function main() {
  const { values } = parseArgs({ options: {
    source: { type: 'string', default: process.env.MANABI_READABILITY_IMAGES_SOURCE || defaultSource },
    'core-source': { type: 'string' }, 'core-css': { type: 'string' },
    chromium: { type: 'string', default: process.env.CHROMIUM_PATH }, output: { type: 'string' },
  } })
  for (const required of ['core-source', 'core-css', 'output']) assert.ok(values[required], `Pass --${required}`)
  const output = path.resolve(values.output)
  assert.equal(fs.existsSync(output), false, 'Choose a fresh output path')
  const sourceBytes = fs.readFileSync(values.source)
  const coreBytes = fs.readFileSync(values['core-source'])
  const cssBytes = fs.readFileSync(values['core-css'])
  const inputs = { images: sourceBytes.toString('utf8'), css: cssBytes.toString('utf8'), restore: extractRestore(coreBytes.toString('utf8')) }
  const browser = await chromium.launch({ executablePath: values.chromium, headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-features=MacAppCodeSignClone'] })
  const version = browser.version()
  const results = []
  try {
    for (const test of cases()) {
      let f
      let observed
      let result
      try {
        f = await fixture(browser, inputs, test.markup, test.vertical)
        observed = await test.run(f)
        test.verify(observed)
        assert.deepEqual(f.errors, [])
        result = { name: test.name, passed: true, observed }
      } catch (error) {
        result = { name: test.name, passed: false, error: String(error), pageErrors: f?.errors, observed }
      } finally {
        await f?.close()
      }
      results.push(result)
      console.log(`${result.passed ? 'PASS' : 'FAIL'} ${test.name}`)
    }
  } finally {
    await browser.close()
  }
  const report = { node: process.version, playwright: require('playwright/package.json').version, browser: version,
    sourcePath: path.resolve(values.source), sourceBlob: blob(sourceBytes),
    corePath: path.resolve(values['core-source']), coreBlob: blob(coreBytes),
    cssPath: path.resolve(values['core-css']), cssBlob: blob(cssBytes),
    runnerBlob: blob(fs.readFileSync(__filename)),
    passed: results.filter(test => test.passed).length, failed: results.filter(test => !test.passed).length, cases: results }
  fs.mkdirSync(path.dirname(output), { recursive: true })
  fs.writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`, { flag: 'wx' })
  const { cases: _, ...summary } = report
  console.log(JSON.stringify(summary))
  return report.failed ? 1 : 0
}

main().then(code => { process.exitCode = code }).catch(error => { console.error(error); process.exitCode = 1 })
