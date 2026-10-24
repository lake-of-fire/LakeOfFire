import assert from 'node:assert/strict'
import test from 'node:test'
import { createRequire } from 'node:module'
import { hydratePackageMedia, isPackageMediaURL } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-package-media.js'

// Run with node; JSDOM_MODULE may point to an existing jsdom installation.
const require = createRequire(import.meta.url)
const { JSDOM } = require(process.env.JSDOM_MODULE ?? 'jsdom')
// Match the selected native producer's source token and generation-bound base.
const packageSourceURL = 'ebook://ebook/load/media%20owner.epub'
const packageSourceToken = Buffer.from(packageSourceURL, 'utf8').toString('base64url')
const packageURL = name =>
    `ebook://ebook/entry-source/${packageSourceToken}/g1-${'b'.repeat(64)}/OPS/${name}`

const deferred = () => {
    let resolve
    const promise = new Promise(value => { resolve = value })
    return { promise, resolve }
}

const makeFixture = t => {
    const first = new JSDOM('<!doctype html><body></body>', { url: 'https://reader.example/' })
    const second = new JSDOM('<!doctype html><body></body>', { url: 'https://reader.example/next' })
    const document = first.window.document
    const replacementDocument = second.window.document
    const requests = new Map()
    const revoked = []
    const hides = []
    let nextObjectURL = 0
    t.after(() => {
        hides.forEach(hide => hide())
        first.window.close()
        second.window.close()
    })
    const makeAudio = (name, ownerDocument = document) => {
        const audio = ownerDocument.createElement('audio')
        audio.preload = 'none'
        if (name) audio.src = packageURL(name)
        audio.loadCount = 0
        audio.load = () => { audio.loadCount += 1 }
        ownerDocument.body.append(audio)
        return audio
    }
    const makeSource = (media, name) => {
        const source = media.ownerDocument.createElement('source')
        source.src = packageURL(name)
        media.append(source)
        return source
    }
    const hydrate = () => hydratePackageMedia({
        document,
        fetch: url => {
            const request = deferred()
            requests.set(url, request)
            return request.promise
        },
        createObjectURL: () => `blob:media-owner-${++nextObjectURL}`,
        revokeObjectURL: url => revoked.push(url),
        addPageHideListener: hide => hides.push(hide),
    })
    const release = (name, ok = true) => {
        const request = requests.get(packageURL(name))
        assert.ok(request, `request ${name} must have started before release`)
        request.resolve({ ok, status: ok ? 200 : 404, blob: async () => new Blob(['media']) })
    }
    const published = element => {
        const result = deferred()
        const observer = new first.window.MutationObserver(() => {
            if (!element.src.startsWith('blob:')) return
            observer.disconnect()
            result.resolve(element.src)
        })
        observer.observe(element, { attributes: true, attributeFilter: ['src'] })
        t.after(() => observer.disconnect())
        return result.promise
    }
    return { document, replacementDocument, makeAudio, makeSource, hydrate, release, published, revoked }
}

test('pending media cannot publish into another connected document', async t => {
    const fixture = makeFixture(t)
    const audio = fixture.makeAudio('voice.m4a')
    const originalSource = audio.src
    const pending = fixture.hydrate()
    fixture.replacementDocument.body.append(audio)
    assert.equal(audio.isConnected, true)
    assert.equal(audio.ownerDocument, fixture.replacementDocument)
    fixture.release('voice.m4a')
    assert.deepEqual(await pending, [false])
    assert.equal(audio.src, originalSource)
    assert.equal(audio.loadCount, 0)
})

test('pending source cannot publish after moving to another media owner', async t => {
    const fixture = makeFixture(t)
    const original = fixture.makeAudio()
    const replacement = fixture.makeAudio()
    const source = fixture.makeSource(original, 'voice.m4a')
    const originalSource = source.src
    const pending = fixture.hydrate()
    replacement.append(source)
    fixture.release('voice.m4a')
    assert.deepEqual(await pending, [false])
    assert.equal(source.src, originalSource)
    assert.equal(original.loadCount, 0)
    assert.equal(replacement.loadCount, 0)
})

test('source A to B to A retires the pending publication but permits a fresh attempt', async t => {
    const fixture = makeFixture(t)
    const audio = fixture.makeAudio('voice.m4a')
    const originalSource = audio.src
    const pending = fixture.hydrate()
    audio.src = packageURL('replacement.m4a')
    audio.src = originalSource
    fixture.release('voice.m4a')
    assert.deepEqual(await pending, [false])
    assert.equal(audio.src, originalSource)
    assert.equal(audio.loadCount, 0)

    const retry = fixture.hydrate()
    fixture.release('voice.m4a')
    assert.deepEqual(await retry, [true])
    assert.match(audio.src, /^blob:/)
    assert.equal(audio.loadCount, 1)
})

for (const change of ['adopt', 'reparent', 'source-aba']) {
    test(`completed media publication cannot reload a retired owner after ${change} while a peer waits`, async t => {
        const fixture = makeFixture(t)
        const original = fixture.makeAudio()
        const source = fixture.makeSource(original, 'voice.m4a')
        const peer = fixture.makeAudio('peer.m4a')
        const firstPublished = fixture.published(source)
        const pending = fixture.hydrate()
        fixture.release('voice.m4a')
        const publishedSource = await firstPublished
        assert.equal(original.loadCount, 0)
        let replacement
        if (change === 'adopt') fixture.replacementDocument.body.append(original)
        if (change === 'reparent') {
            replacement = fixture.makeAudio()
            replacement.append(source)
        }
        if (change === 'source-aba') {
            source.src = packageURL('replacement.m4a')
            source.src = publishedSource
        }
        fixture.release('peer.m4a')
        assert.deepEqual(await pending, [true, true])
        assert.equal(original.loadCount, 0)
        assert.equal(replacement?.loadCount ?? 0, 0)
        assert.equal(peer.loadCount, 1)
    })
}

test('moving an unchanged media element inside its document preserves its pending publication', async t => {
    const fixture = makeFixture(t)
    const audio = fixture.makeAudio('voice.m4a')
    const pending = fixture.hydrate()
    const wrapper = fixture.document.createElement('section')
    fixture.document.body.append(wrapper)
    wrapper.append(audio)
    audio.setAttribute('aria-label', 'Narration')
    fixture.release('voice.m4a')
    assert.deepEqual(await pending, [true])
    assert.equal(audio.loadCount, 1)
})

test('shared resource peers retain independent source ownership and one accepted media load', async t => {
    const fixture = makeFixture(t)
    const audio = fixture.makeAudio()
    const first = fixture.makeSource(audio, 'voice.m4a')
    const second = fixture.makeSource(audio, 'voice.m4a')
    first.src += '#t=1'
    second.src += '#t=2'
    const pending = fixture.hydrate()
    const originalFirst = first.src
    first.src = packageURL('replacement.m4a')
    first.src = originalFirst
    fixture.release('voice.m4a')
    assert.deepEqual(await pending, [false, true])
    assert.equal(first.src, originalFirst)
    assert.match(second.src, /^blob:.*#t=2$/)
    assert.equal(audio.loadCount, 1)
})

test('a direct media publication preserves its own nested-source peers', async t => {
    const fixture = makeFixture(t)
    const audio = fixture.makeAudio('voice.m4a')
    const source = fixture.makeSource(audio, 'voice.m4a')
    audio.src += '#t=1'
    source.src += '#t=2'
    const pending = fixture.hydrate()
    fixture.release('voice.m4a')
    assert.deepEqual(await pending, [true, true])
    assert.equal(audio.src.split('#')[0], source.src.split('#')[0])
    assert.match(audio.src, /#t=1$/)
    assert.match(source.src, /#t=2$/)
    assert.equal(audio.loadCount, 1)
})

test('a failed peer does not release source ownership before the remaining fetch settles', async t => {
    const fixture = makeFixture(t)
    fixture.makeAudio('missing.m4a')
    const audio = fixture.makeAudio('voice.m4a')
    const originalSource = audio.src
    const pending = fixture.hydrate()
    fixture.release('missing.m4a', false)
    await assert.rejects(pending, /Failed to load ebook media: 404/)
    audio.src = packageURL('replacement.m4a')
    audio.src = originalSource
    fixture.release('voice.m4a')
    // All released response/blob promises finish in the current microtask turn.
    await new Promise(setImmediate)
    assert.equal(audio.src, originalSource)
    assert.equal(audio.loadCount, 0)
})

for (const phase of ['pending', 'published']) {
    for (const restore of [false, true]) {
        test(`parent media src ${restore ? 'ABA' : 'replacement'} retires a ${phase} nested source`, async t => {
            const fixture = makeFixture(t)
            const audio = fixture.makeAudio()
            const source = fixture.makeSource(audio, 'voice.m4a')
            const originalSource = source.src
            const peer = fixture.makeAudio('peer.m4a')
            const firstPublished = phase === 'published' ? fixture.published(source) : null
            const pending = fixture.hydrate()
            if (phase === 'published') {
                fixture.release('voice.m4a')
                await firstPublished
            }
            audio.src = 'https://example.com/replacement.m4a'
            if (restore) audio.removeAttribute('src')
            if (phase === 'pending') fixture.release('voice.m4a')
            fixture.release('peer.m4a')
            assert.deepEqual(await pending, [phase === 'published', true])
            if (phase === 'pending') assert.equal(source.src, originalSource)
            assert.equal(audio.loadCount, 0)
            assert.equal(peer.loadCount, 1)
        })
    }
}

test('selected entry-source base resolves relative media without enabling session routes', async t => {
    const fixture = makeFixture(t)
    const base = fixture.document.createElement('base')
    base.href = packageURL('')
    fixture.document.head.append(base)
    const audio = fixture.makeAudio()
    const source = fixture.document.createElement('source')
    source.setAttribute('src', 'voice.m4a#t=4')
    audio.append(source)
    assert.equal(source.src, `${packageURL('voice.m4a')}#t=4`)
    assert.equal(isPackageMediaURL(source.src), true)
    assert.equal(isPackageMediaURL(source.src.replace('/entry-source/', '/entry-session/')), false)

    const pending = fixture.hydrate()
    fixture.release('voice.m4a')
    assert.deepEqual(await pending, [true])
    assert.match(source.src, /^blob:.*#t=4$/)
    assert.equal(audio.loadCount, 1)
})
