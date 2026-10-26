import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import vm from 'node:vm'
import { processedSectionURLForHref } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-direct-section.js'

const resources = new URL('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/', import.meta.url)
const cacheSource = await readFile(new URL('owned-async-cache.js', resources), 'utf8')
const { createOwnedAsyncCache } = await import(`data:text/javascript;base64,${Buffer.from(cacheSource).toString('base64')}`)
const viewerURL = new URL('ebook-viewer.js', resources)
const source = await readFile(viewerURL, 'utf8')
const declaration = (start, end) => {
    const first = source.indexOf(start), last = source.indexOf(end, first + start.length)
    if (first < 0 || last < 0) throw new Error(`Missing viewer fixture boundary: ${start}`)
    return source.slice(first, last)
}
const declarations = [
    declaration('const resolveEpubRelativePath =', 'const debounce ='),
    declaration('const normalizedComputedWritingMode =', 'const normalizedComputedDirection ='),
].join('\n')
const deferred = () => {
    let resolve
    const promise = new Promise(yes => { resolve = yes })
    return { promise, resolve }
}
const nextTurn = () => new Promise(resolve => setImmediate(resolve))
const startedWithinTurn = promise => Promise.race([
    promise,
    nextTurn().then(() => { throw new Error('Expected raw source read by the next event-loop turn') }),
])

// Only the outer URL-probe DOM is controlled. The real producer/cache/owner
// declarations execute unchanged; these tests make no browser CSS/layout claim.
// DOMParser is deliberately unavailable, so a current raw-text miss proceeds to
// the real URL-probe path, whose load event/computed style are controlled here.
const makeViewer = () => {
    const frames = [], published = []
    const document = {
        createElement: tag => {
            assert.equal(tag, 'iframe')
            const listeners = new Map()
            const frame = {
                style: {},
                removed: false,
                contentDocument: { body: {}, documentElement: {} },
                contentWindow: { getComputedStyle: () => ({ writingMode: 'vertical-rl' }) },
                addEventListener: (name, callback) => listeners.set(name, callback),
                remove: () => { frame.removed = true },
                set src(value) {
                    frame.url = value
                    queueMicrotask(() => listeners.get('load')?.())
                },
            }
            frames.push(frame)
            return frame
        },
        documentElement: { appendChild: frame => { frame.appended = true } },
    }
    const context = {
        createOwnedAsyncCache,
        processedSectionURLForHref,
        AbortController,
        URL,
        document,
        setTimeout,
        clearTimeout,
        manabiTimelineMark: () => {},
        manabi_recordLiveProcessedSection: href => published.push(href),
    }
    context.window = context
    const api = vm.runInNewContext(`${declarations}\n({ makeReplaceURL })`, context, { filename: viewerURL.pathname, timeout: 1000 })
    return { frames, published, makeOwner: (loadText, options) => api.makeReplaceURL('ebook://book/source.epub', loadText, options) }
}
const replace = owner => owner('chapter.xhtml', 'application/xhtml+xml')
const assertCurrentURL = url => {
    const parsed = new URL(url)
    assert.equal(parsed.searchParams.get('subpath'), 'chapter.xhtml')
    assert.equal(parsed.searchParams.get('mnbWritingDirection'), 'vertical')
    assert.equal(parsed.searchParams.get('mnbWritingMode'), 'vertical-rl')
}

test('queued direction destroy rejects all waiters without creating an iframe or reading the old archive', async () => {
    const viewer = makeViewer()
    let oldReads = 0, newReads = 0
    const owner = viewer.makeOwner(async () => { oldReads++; return '<html />' })
    const settled = Promise.allSettled([replace(owner), replace(owner)])
    assert.equal(owner.destroy(), true)
    assert.equal(owner.destroy(), false)
    const results = await settled
    assert.equal(oldReads, 0)
    assert.equal(viewer.frames.length, 0)
    assert.deepEqual(viewer.published, [])
    assert.ok(results.every(result => result.status === 'rejected' && result.reason?.name === 'AbortError'))
    assert.equal(results[0].reason, results[1].reason)
    assert.equal(await replace(owner), null)
    const successor = viewer.makeOwner(async () => { newReads++; return '<html />' })
    const fresh = await replace(successor)
    assertCurrentURL(fresh)
    assert.equal(await replace(successor), fresh)
    assert.equal(newReads, 1)
    assert.equal(viewer.frames.length, 1)
    assert.equal(viewer.frames[0].removed, true)
    successor.destroy()
})

test('late abort-ignoring direction source cannot publish after destroy and leaves its successor usable', async () => {
    const viewer = makeViewer(), started = deferred(), oldSource = deferred()
    let oldSignal, newReads = 0
    const owner = viewer.makeOwner((_href, { signal }) => {
        oldSignal = signal
        started.resolve()
        return oldSource.promise
    })
    const pending = replace(owner)
    await startedWithinTurn(started.promise)
    owner.destroy()
    const successor = viewer.makeOwner(async () => { newReads++; return '<html />' })
    const freshPending = replace(successor)
    oldSource.resolve('<html><body style="writing-mode: horizontal-tb" /></html>')
    const [old, fresh] = await Promise.all([pending, freshPending])
    await nextTurn()
    assert.equal(old, null)
    assert.equal(oldSignal.aborted, true)
    assertCurrentURL(fresh)
    assert.equal(await replace(successor), fresh)
    assert.equal(newReads, 1)
    assert.equal(viewer.frames.length, 2, 'Only the running old probe and current successor may allocate frames')
    assert.ok(viewer.frames.every(frame => frame.removed))
    assert.deepEqual(viewer.published, ['chapter.xhtml', 'chapter.xhtml'])
    successor.destroy()
})
