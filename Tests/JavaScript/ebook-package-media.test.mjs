import assert from 'node:assert/strict';
import test from 'node:test';
import { setImmediate as nextTurn } from 'node:timers/promises'
import {
    hydratePackageMedia,
    installPackageMediaHydration,
    isPackageMediaURL,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-package-media.js';

const packageURL = suffix =>
    `ebook://ebook/entry-source/source/g1-${'a'.repeat(64)}/OPS/Media/${suffix}`;

const makeElement = (src, owningMedia = null) => ({
    src,
    matches: selector => selector === 'audio, video' && owningMedia === null,
    closest: () => owningMedia,
});

test('package media URL validation is strict', () => {
    assert.equal(isPackageMediaURL(packageURL('voice.m4a')), true);
    assert.equal(isPackageMediaURL('ebook://ebook/entry/voice.m4a'), false);
    assert.equal(isPackageMediaURL('ebook://ebook/entry-session/source/generation/session/voice.m4a'), false)
    assert.equal(isPackageMediaURL('https://example.com/voice.m4a'), false);
    assert.equal(isPackageMediaURL('not a URL'), false);
    assert.equal(isPackageMediaURL(packageURL('voice.m4a').replace('g1-', 'g2-')), false);
    assert.equal(isPackageMediaURL(packageURL('voice.m4a').replace('/entry-source/', '/entry-session/')), false);
    const sessionURL = packageURL('voice.m4a').replace('/entry-source/', '/entry-session/')
        .replace('/OPS/', '/371cf379-d180-449d-bca2-13b902c3634d/OPS/');
    assert.equal(isPackageMediaURL(sessionURL), true);
    assert.equal(isPackageMediaURL(sessionURL.replace('371cf379', '371CF379')), false);
});

test('media hydration coalesces fetches and retains fragments', async () => {
    const media = { loadCount: 0, load() { this.loadCount += 1; } };
    const audio = makeElement(`${packageURL('voice.m4a')}#t=1`, null);
    audio.load = media.load.bind(media);
    const source = makeElement(`${packageURL('voice.m4a')}#t=2`, audio);
    const fetches = [];
    const createdBlobs = [];
    const revokedBlobs = [];
    let pageHideListener;

    const results = await hydratePackageMedia({
        document: { querySelectorAll: () => [audio, source] },
        fetch: async url => {
            fetches.push(url);
            return {
                ok: true,
                blob: async () => ({ type: 'audio/mp4' }),
            };
        },
        createObjectURL: blob => {
            createdBlobs.push(blob);
            return 'blob:fixture';
        },
        revokeObjectURL: url => revokedBlobs.push(url),
        addPageHideListener: listener => { pageHideListener = listener; },
    });

    assert.deepEqual(results, [true, true]);
    assert.deepEqual(fetches, [packageURL('voice.m4a')]);
    assert.equal(createdBlobs.length, 1);
    assert.equal(audio.src, 'blob:fixture#t=1');
    assert.equal(source.src, 'blob:fixture#t=2');
    assert.equal(media.loadCount, 1);
    pageHideListener();
    assert.deepEqual(revokedBlobs, ['blob:fixture']);
});

test('media hydration ignores external sources', async () => {
    const audio = makeElement('https://example.com/voice.m4a');
    const results = await hydratePackageMedia({
        document: { querySelectorAll: () => [audio] },
        fetch: async () => {
            throw new Error('unexpected fetch');
        },
    });

    assert.deepEqual(results, [false]);
    assert.equal(audio.src, 'https://example.com/voice.m4a');
});

test('native source-backed media retains its exact generation URL during hydration', async () => {
    const audio = makeElement(`${packageURL('voice.m4a')}#t=3`);
    let requested;
    assert.equal(isPackageMediaURL(audio.src), true);
    const result = await hydratePackageMedia({
        document: { querySelectorAll: () => [audio] },
        fetch: async url => { requested = url; return { ok: true, blob: async () => ({}) }; },
        createObjectURL: () => 'blob:source',
    });
    assert.deepEqual(result, [true]);
    assert.equal(requested, packageURL('voice.m4a'));
    assert.equal(audio.src, 'blob:source#t=3');
});

test('package media does not borrow another native host or credential-bearing URL', () => {
    assert.equal(isPackageMediaURL(packageURL('voice.m4a').replace('ebook://ebook/', 'ebook://other/')), false);
    assert.equal(isPackageMediaURL(packageURL('voice.m4a').replace('ebook://ebook/', 'ebook://name@ebook/')), false);
});

test('page hide before a held media response cannot create or publish a leaked blob URL', async () => {
    const audio = makeElement(packageURL('voice.m4a'));
    let release, hide, created = 0, loaded = 0;
    audio.load = () => { loaded += 1; };
    const result = hydratePackageMedia({
        document: { querySelectorAll: () => [audio] },
        fetch: () => new Promise(resolve => { release = resolve; }),
        addPageHideListener: listener => { hide = listener; },
        createObjectURL: () => { created += 1; return 'blob:unexpected'; },
    });
    hide();
    release({ ok: true, blob: async () => ({}) });
    assert.deepEqual(await result, [false]);
    assert.equal(created, 0);
    assert.equal(loaded, 0);
    assert.equal(audio.src, packageURL('voice.m4a'));
});

test('late media response cannot overwrite an explicitly replaced source', async () => {
    const audio = makeElement(packageURL('voice.m4a'));
    let release, hide, loaded = 0;
    const revoked = [];
    audio.load = () => { loaded += 1; };
    const result = hydratePackageMedia({
        document: { querySelectorAll: () => [audio] },
        fetch: () => new Promise(resolve => { release = resolve; }),
        createObjectURL: () => 'blob:old-source',
        revokeObjectURL: url => revoked.push(url),
        addPageHideListener: listener => { hide = listener; },
    });
    audio.src = 'https://example.com/replacement.m4a';
    release({ ok: true, blob: async () => ({}) });
    assert.deepEqual(await result, [false]);
    assert.equal(audio.src, 'https://example.com/replacement.m4a');
    assert.equal(loaded, 0);
    hide();
    assert.deepEqual(revoked, ['blob:old-source']);
});

test('reentrant document closure during blob creation releases it without publishing', async () => {
    const audio = makeElement(packageURL('voice.m4a'));
    let hide;
    const revoked = [];
    const result = await hydratePackageMedia({
        document: { querySelectorAll: () => [audio] },
        fetch: async () => ({ ok: true, blob: async () => ({}) }),
        createObjectURL: () => { hide(); return 'blob:closing'; },
        revokeObjectURL: url => revoked.push(url),
        addPageHideListener: listener => { hide = listener; },
    });
    assert.deepEqual(result, [false]);
    assert.deepEqual(revoked, ['blob:closing']);
    assert.equal(audio.src, packageURL('voice.m4a'));
});

test('page hide while response blob is pending prevents late object URL creation', async () => {
    const audio = makeElement(packageURL('voice.m4a'));
    let hide, releaseBlob, enteredBlob;
    let created = 0, loaded = 0;
    const blob = new Promise(resolve => { releaseBlob = resolve; });
    const blobEntered = new Promise(resolve => { enteredBlob = resolve; });
    audio.load = () => { loaded += 1; };
    const result = hydratePackageMedia({
        document: { querySelectorAll: () => [audio] },
        fetch: async () => ({
            ok: true,
            blob: () => { enteredBlob(); return blob; },
        }),
        addPageHideListener: listener => { hide = listener; },
        createObjectURL: () => { created += 1; return 'blob:unexpected'; },
    });
    await blobEntered;
    hide();
    releaseBlob({});
    assert.deepEqual(await result, [false]);
    assert.equal(audio.src, packageURL('voice.m4a'));
    assert.equal(created, 0);
    assert.equal(loaded, 0);
});

test('late response cannot publish to a detached media element', async () => {
    const audio = makeElement(packageURL('voice.m4a'));
    let release, hide, loaded = 0;
    const revoked = [];
    audio.isConnected = true;
    audio.load = () => { loaded += 1; };
    const result = hydratePackageMedia({
        document: { querySelectorAll: () => [audio] },
        fetch: () => new Promise(resolve => { release = resolve; }),
        createObjectURL: () => 'blob:detached',
        revokeObjectURL: url => revoked.push(url),
        addPageHideListener: listener => { hide = listener; },
    });
    audio.isConnected = false;
    release({ ok: true, blob: async () => ({}) });
    assert.deepEqual(await result, [false]);
    assert.equal(audio.src, packageURL('voice.m4a'));
    assert.equal(loaded, 0);
    hide();
    assert.deepEqual(revoked, ['blob:detached']);
});

const deferred = () => {
    let resolve
    const promise = new Promise(settle => { resolve = settle })
    return { promise, resolve }
}

function mixedMediaFixture(failureStage, {
    install = false, sharedOwner = false, directValidSource = false,
} = {}) {
    const failedURL = packageURL('missing.m4a')
    const validURL = packageURL('voice.m4a')
    const failure = new Error(`controlled ${failureStage} failure`)
    const failGate = deferred()
    const validGate = deferred()
    const failedEntered = deferred()
    const validEntered = deferred()
    const failureReached = deferred()
    const validPublished = deferred()
    const created = []
    const revoked = []
    let validMedia = { loads: 0, load() { this.loads++ } }
    const makeSource = (initialURL, owner, onPublish) => {
        let currentURL = initialURL
        return {
            isConnected: true,
            get src() { return currentURL },
            set src(value) { currentURL = value; onPublish?.(value) },
            matches: () => false,
            closest: () => owner,
        }
    }
    const validSource = makeSource(validURL, validMedia, validPublished.resolve)
    if (directValidSource) {
        validSource.matches = () => true
        validSource.loads = 0
        validSource.load = function () { this.loads++ }
        validMedia = validSource
    }
    const failedMedia = sharedOwner ? validMedia : { loads: 0, load() { this.loads++ } }
    const failedSource = makeSource(failedURL, failedMedia)
    const document = {
        documentElement: { dataset: {} },
        querySelectorAll: () => [failedSource, validSource],
    }
    let hide
    const options = {
        document,
        fetch: async url => {
            if (url === validURL) {
                validEntered.resolve()
                await validGate.promise
                return { ok: true, blob: async () => ({ type: 'audio/mp4' }) }
            }
            assert.equal(url, failedURL)
            if (failureStage === 'body') {
                return {
                    ok: true,
                    blob: async () => {
                        failedEntered.resolve()
                        await failGate.promise
                        failureReached.resolve()
                        throw failure
                    },
                }
            }
            failedEntered.resolve()
            await failGate.promise
            failureReached.resolve()
            if (failureStage === 'fetch') throw failure
            return { ok: false, status: 404, blob() { assert.fail('404 body must not be consumed') } }
        },
        createObjectURL: blob => { created.push(blob); return 'blob:valid-media' },
        revokeObjectURL: url => revoked.push(url),
        addPageHideListener: listener => { hide = listener },
    }
    const pending = install
        ? installPackageMediaHydration(options)
        : hydratePackageMedia(options)
    // Observe rejection from the start, including before the independent
    // successful peer is released; never leave a rejection unhandled.
    const outcome = pending.then(
        value => ({ status: 'fulfilled', value }),
        error => ({ status: 'rejected', error }),
    )
    return {
        failedURL, validURL, failure, failGate, validGate,
        failedEntered, validEntered, failureReached, validPublished,
        created, revoked, validMedia, failedMedia, validSource, failedSource,
        document, outcome, hide: () => hide(),
    }
}

function assertOriginalFailure(outcome, fixture, stage) {
    assert.equal(outcome.status, 'rejected')
    if (stage === 'http') {
        assert.match(outcome.error.message, /^Failed to load ebook media: 404$/)
    } else {
        assert.equal(outcome.error, fixture.failure)
    }
}

for (const stage of ['fetch', 'http', 'body']) {
    for (const ordering of ['failure-first', 'success-first']) {
        test(`${stage} ${ordering}: successful nested-source peer still loads`, async () => {
            const fixture = mixedMediaFixture(stage)
            try {
                await Promise.all([fixture.failedEntered.promise, fixture.validEntered.promise])
                if (ordering === 'failure-first') {
                    fixture.failGate.resolve()
                    await fixture.failureReached.promise
                    await nextTurn()
                    fixture.validGate.resolve()
                    await fixture.validPublished.promise
                } else {
                    fixture.validGate.resolve()
                    await fixture.validPublished.promise
                    fixture.failGate.resolve()
                }
                const outcome = await fixture.outcome
                await nextTurn()
                assertOriginalFailure(outcome, fixture, stage)
                assert.equal(fixture.validSource.src, 'blob:valid-media')
                assert.equal(fixture.failedSource.src, fixture.failedURL)
                assert.equal(fixture.created.length, 1)
                assert.equal(fixture.failedMedia.loads, 0)
                assert.equal(fixture.validMedia.loads, 1,
                    'One failed package resource must not strand a successfully hydrated nested source')
            } finally {
                fixture.failGate.resolve()
                fixture.validGate.resolve()
                fixture.hide()
            }
        })
    }

    test(`${stage}: pagehide after a peer failure still blocks late successful publication`, async () => {
        const fixture = mixedMediaFixture(stage)
        try {
            await Promise.all([fixture.failedEntered.promise, fixture.validEntered.promise])
            fixture.failGate.resolve()
            await fixture.failureReached.promise
            await nextTurn()
            fixture.hide()
            fixture.validGate.resolve()
            const outcome = await fixture.outcome
            await nextTurn()
            assertOriginalFailure(outcome, fixture, stage)
            assert.equal(fixture.validSource.src, fixture.validURL)
            assert.equal(fixture.failedSource.src, fixture.failedURL)
            assert.equal(fixture.created.length, 0)
            assert.equal(fixture.validMedia.loads, 0)
            assert.equal(fixture.failedMedia.loads, 0)
            assert.deepEqual(fixture.revoked, [])
        } finally {
            fixture.failGate.resolve()
            fixture.validGate.resolve()
            fixture.hide()
        }
    })
}

test('installation retains error publication while loading a successful peer', async () => {
    const fixture = mixedMediaFixture('fetch', { install: true })
    try {
        assert.equal(fixture.document.documentElement.dataset.mnbPackageMediaState, 'loading')
        await Promise.all([fixture.failedEntered.promise, fixture.validEntered.promise])
        fixture.failGate.resolve()
        await fixture.failureReached.promise
        await nextTurn()
        fixture.validGate.resolve()
        await fixture.validPublished.promise
        assertOriginalFailure(await fixture.outcome, fixture, 'fetch')
        await nextTurn()
        assert.equal(fixture.document.documentElement.dataset.mnbPackageMediaState, 'error')
        assert.equal(fixture.validMedia.loads, 1)
    } finally {
        fixture.failGate.resolve()
        fixture.validGate.resolve()
        fixture.hide()
    }
})

for (const ordering of ['failure-first', 'success-first']) {
    test(`${ordering}: a failed alternate source still loads its shared media owner once`, async () => {
        const fixture = mixedMediaFixture('http', { sharedOwner: true })
        try {
            await Promise.all([fixture.failedEntered.promise, fixture.validEntered.promise])
            if (ordering === 'failure-first') {
                fixture.failGate.resolve()
                await fixture.failureReached.promise
                await nextTurn()
                fixture.validGate.resolve()
                await fixture.validPublished.promise
            } else {
                fixture.validGate.resolve()
                await fixture.validPublished.promise
                fixture.failGate.resolve()
            }
            assertOriginalFailure(await fixture.outcome, fixture, 'http')
            await nextTurn()
            assert.equal(fixture.validSource.src, 'blob:valid-media')
            assert.equal(fixture.failedSource.src, fixture.failedURL)
            assert.equal(fixture.validMedia.loads, 1)
        } finally {
            fixture.failGate.resolve()
            fixture.validGate.resolve()
            fixture.hide()
        }
    })
}

test('a failed source rejects promptly while an independent resource is still pending', async () => {
    const fixture = mixedMediaFixture('body')
    let observedOutcome
    fixture.outcome.then(value => { observedOutcome = value })
    try {
        await Promise.all([fixture.failedEntered.promise, fixture.validEntered.promise])
        fixture.failGate.resolve()
        await fixture.failureReached.promise
        await nextTurn()
        assert.notEqual(observedOutcome, undefined,
            'Failure reporting must not wait for an unrelated held media resource')
        assertOriginalFailure(observedOutcome, fixture, 'body')
        assert.equal(fixture.created.length, 0)
        assert.equal(fixture.validMedia.loads, 0)
        fixture.validGate.resolve()
        await fixture.validPublished.promise
        await nextTurn()
        assert.equal(fixture.validMedia.loads, 1)
    } finally {
        fixture.failGate.resolve()
        fixture.validGate.resolve()
        fixture.hide()
    }
})

for (const replacement of ['source-change', 'disconnect']) {
    test(`${replacement}: a successful peer response cannot publish to its retired source`, async () => {
        const fixture = mixedMediaFixture('fetch')
        try {
            await Promise.all([fixture.failedEntered.promise, fixture.validEntered.promise])
            fixture.failGate.resolve()
            await fixture.failureReached.promise
            await nextTurn()
            if (replacement === 'source-change') fixture.validSource.src = 'https://reader.test/replacement.m4a'
            else fixture.validSource.isConnected = false
            const retainedSource = fixture.validSource.src
            fixture.validGate.resolve()
            assertOriginalFailure(await fixture.outcome, fixture, 'fetch')
            await nextTurn()
            assert.equal(fixture.validSource.src, retainedSource)
            assert.equal(fixture.validMedia.loads, 0)
            fixture.hide()
            assert.deepEqual(fixture.revoked, ['blob:valid-media'])
        } finally {
            fixture.failGate.resolve()
            fixture.validGate.resolve()
            fixture.hide()
        }
    })
}

test('retry hydrates only the failed resource and preserves the successful peer', async () => {
    const retainedMedia = { loads: 0, load() { this.loads++ } }
    const retryMedia = { loads: 0, load() { this.loads++ } }
    const retainedSource = makeElement(packageURL('retained.m4a'), retainedMedia)
    const retrySource = makeElement(packageURL('retry.m4a'), retryMedia)
    const sources = [retainedSource, retrySource]
    const failure = new Error('first fetch failed')
    const listeners = []
    const revoked = []
    const requested = []
    let created = 0
    const options = {
        document: { querySelectorAll: () => sources },
        createObjectURL: () => `blob:hydrated-${++created}`,
        revokeObjectURL: url => revoked.push(url),
        addPageHideListener: listener => listeners.push(listener),
    }
    try {
        await assert.rejects(hydratePackageMedia({
            ...options,
            fetch: async url => {
                if (url === packageURL('retry.m4a')) throw failure
                return { ok: true, blob: async () => ({}) }
            },
        }), error => error === failure)
        await nextTurn()
        assert.equal(retainedMedia.loads, 1)
        assert.equal(retryMedia.loads, 0)
        assert.equal(retainedSource.src, 'blob:hydrated-1')
        const outcomes = await hydratePackageMedia({
            ...options,
            fetch: async url => {
                requested.push(url)
                return { ok: true, blob: async () => ({}) }
            },
        })
        assert.deepEqual(outcomes, [false, true])
        assert.deepEqual(requested, [packageURL('retry.m4a')])
        assert.equal(retainedSource.src, 'blob:hydrated-1')
        assert.equal(retrySource.src, 'blob:hydrated-2')
        assert.equal(retainedMedia.loads, 1)
        assert.equal(retryMedia.loads, 1)
        for (const listener of listeners) listener()
        assert.deepEqual(revoked, ['blob:hydrated-1', 'blob:hydrated-2'])
    } finally {
        for (const listener of listeners) listener()
    }
})

for (const { change, direct } of [
    { change: 'source-replacement', direct: true },
    { change: 'source-replacement', direct: false },
    { change: 'owner-source-replacement', direct: false },
    { change: 'owner-detachment', direct: false },
    { change: 'source-reparent', direct: false },
]) {
    test(`held alternate failure does not reload ${direct ? 'direct media' : 'nested media'} after ${change}`, async () => {
        const fixture = mixedMediaFixture('fetch', { sharedOwner: true, directValidSource: direct })
        const replacementMedia = { isConnected: true, loads: 0, load() { this.loads++ } }
        try {
            await Promise.all([fixture.failedEntered.promise, fixture.validEntered.promise])
            fixture.validGate.resolve()
            await fixture.validPublished.promise
            assert.equal(fixture.validMedia.loads, 0, 'The same owner still has a pending alternate')
            if (change === 'source-replacement') {
                fixture.validSource.src = 'https://reader.test/replacement.m4a'
            } else if (change === 'owner-source-replacement') {
                fixture.validMedia.src = 'https://reader.test/replacement.m4a'
            } else if (change === 'owner-detachment') {
                fixture.validMedia.isConnected = false
                fixture.validSource.isConnected = false
            } else {
                fixture.validSource.closest = () => replacementMedia
            }
            const retainedSource = fixture.validSource.src
            fixture.failGate.resolve()
            assertOriginalFailure(await fixture.outcome, fixture, 'fetch')
            await nextTurn()
            assert.equal(fixture.validSource.src, retainedSource)
            assert.equal(fixture.validMedia.loads, 0, 'A retired publication must not reload its replacement')
            assert.equal(replacementMedia.loads, 0)
            fixture.hide()
            assert.deepEqual(fixture.revoked, ['blob:valid-media'])
        } finally {
            fixture.failGate.resolve()
            fixture.validGate.resolve()
            fixture.hide()
        }
    })
}

const sessionURL = suffix =>
    `ebook://ebook/entry-session/source/g1-${'b'.repeat(64)}/371cf379-d180-449d-bca2-13b902c3634d/OPS/Media/${suffix}`;

test('native session-backed media retains its exact capability during hydration', async () => {
    const audio = makeElement(`${sessionURL('voice.m4a')}#t=3`);
    let requested;
    assert.equal(isPackageMediaURL(audio.src), true);
    const result = await hydratePackageMedia({
        document: { querySelectorAll: () => [audio] },
        fetch: async url => { requested = url; return { ok: true, blob: async () => ({}) }; },
        createObjectURL: () => 'blob:session',
    });
    assert.deepEqual(result, [true]);
    assert.equal(requested, sessionURL('voice.m4a'));
    assert.equal(audio.src, 'blob:session#t=3');
});

test('package media does not borrow another native host or credential-bearing URL', () => {
    assert.equal(isPackageMediaURL(sessionURL('voice.m4a').replace('ebook://ebook/', 'ebook://other/')), false);
    assert.equal(isPackageMediaURL(sessionURL('voice.m4a').replace('ebook://ebook/', 'ebook://name@ebook/')), false);
});

test('page hide before a held media response cannot create or publish a leaked blob URL', async () => {
    const audio = makeElement(sessionURL('voice.m4a'));
    let release, hide, created = 0, loaded = 0;
    audio.load = () => { loaded += 1; };
    const result = hydratePackageMedia({
        document: { querySelectorAll: () => [audio] },
        fetch: () => new Promise(resolve => { release = resolve; }),
        addPageHideListener: listener => { hide = listener; },
        createObjectURL: () => { created += 1; return 'blob:unexpected'; },
    });
    hide();
    release({ ok: true, blob: async () => ({}) });
    assert.deepEqual(await result, [false]);
    assert.equal(created, 0);
    assert.equal(loaded, 0);
    assert.equal(audio.src, sessionURL('voice.m4a'));
});

test('late media response cannot overwrite an explicitly replaced source', async () => {
    const audio = makeElement(sessionURL('voice.m4a'));
    let release, hide, loaded = 0;
    const revoked = [];
    audio.load = () => { loaded += 1; };
    const result = hydratePackageMedia({
        document: { querySelectorAll: () => [audio] },
        fetch: () => new Promise(resolve => { release = resolve; }),
        createObjectURL: () => 'blob:old-source',
        revokeObjectURL: url => revoked.push(url),
        addPageHideListener: listener => { hide = listener; },
    });
    audio.src = 'https://example.com/replacement.m4a';
    release({ ok: true, blob: async () => ({}) });
    assert.deepEqual(await result, [false]);
    assert.equal(audio.src, 'https://example.com/replacement.m4a');
    assert.equal(loaded, 0);
    hide();
    assert.deepEqual(revoked, ['blob:old-source']);
});

test('reentrant document closure during blob creation releases it without publishing', async () => {
    const audio = makeElement(sessionURL('voice.m4a'));
    let hide;
    const revoked = [];
    const result = await hydratePackageMedia({
        document: { querySelectorAll: () => [audio] },
        fetch: async () => ({ ok: true, blob: async () => ({}) }),
        createObjectURL: () => { hide(); return 'blob:closing'; },
        revokeObjectURL: url => revoked.push(url),
        addPageHideListener: listener => { hide = listener; },
    });
    assert.deepEqual(result, [false]);
    assert.deepEqual(revoked, ['blob:closing']);
    assert.equal(audio.src, sessionURL('voice.m4a'));
});

for (const failureStage of ['fetch', 'response', 'blob']) {
    test(`a ${failureStage} failure does not prevent a delayed valid media source from loading`, async () => {
        const media = { loadCount: 0, load() { this.loadCount += 1; } };
        const missing = makeElement(packageURL('missing.m4a'), media);
        const valid = makeElement(packageURL('valid.m4a'), media);
        const failure = new Error(`injected ${failureStage} failure`);
        let releaseValid;
        let sawFailure;
        const failedRequest = new Promise(resolve => { sawFailure = resolve; });
        const hydration = hydratePackageMedia({
            document: { querySelectorAll: () => [missing, valid] },
            fetch: async url => {
                if (url === missing.src) {
                    sawFailure();
                    if (failureStage === 'fetch') throw failure;
                    return {
                        ok: failureStage !== 'response', status: 404,
                        blob: async () => { throw failure; },
                    };
                }
                return new Promise(resolve => { releaseValid = resolve; });
            },
            createObjectURL: () => 'blob:valid',
        });
        const rejected = assert.rejects(hydration, failureStage === 'response'
            ? /Failed to load ebook media: 404/
            : error => error === failure);
        await failedRequest;
        // Let the failure settle before the second source becomes available.
        await new Promise(resolve => setImmediate(resolve));
        releaseValid({ ok: true, blob: async () => ({}) });
        await rejected;
        await new Promise(resolve => setImmediate(resolve));

        assert.equal(valid.src, 'blob:valid');
        assert.equal(missing.src, packageURL('missing.m4a'));
        assert.equal(media.loadCount, 1, 'The valid alternative must be offered to the media element');
    });
}

test('ready media loads before an unrelated resource settles', async () => {
    const ready = makeElement(packageURL('ready.m4a'));
    const delayed = makeElement(packageURL('delayed.m4a'));
    let readyLoads = 0, delayedLoads = 0;
    ready.load = () => { readyLoads += 1; };
    delayed.load = () => { delayedLoads += 1; };
    let releaseDelayed, createdReady;
    const readyBlobCreated = new Promise(resolve => { createdReady = resolve; });
    const hydration = hydratePackageMedia({
        document: { querySelectorAll: () => [ready, delayed] },
        fetch: async url => url === ready.src
            ? { ok: true, blob: async () => ({ ready: true }) }
            : new Promise(resolve => { releaseDelayed = resolve; }),
        createObjectURL: blob => {
            if (blob.ready) createdReady();
            return blob.ready ? 'blob:ready' : 'blob:delayed';
        },
    });
    await readyBlobCreated;
    await new Promise(resolve => setImmediate(resolve));
    try {
        assert.equal(readyLoads, 1, 'Unrelated network work must not block playable media');
        assert.equal(delayedLoads, 0);
    } finally {
        releaseDelayed({ ok: true, blob: async () => ({}) });
        assert.deepEqual(await hydration, [true, true]);
    }
    assert.equal(readyLoads, 1);
    assert.equal(delayedLoads, 1);
});


test('page hide while response blob is pending prevents late object URL creation', async () => {
    const audio = makeElement(packageURL('voice.m4a'));
    let hide, releaseBlob, enteredBlob;
    let created = 0, loaded = 0;
    const revoked = [];
    const blob = new Promise(resolve => { releaseBlob = resolve; });
    const blobEntered = new Promise(resolve => { enteredBlob = resolve; });
    audio.load = () => { loaded += 1; };
    const result = hydratePackageMedia({
        document: { querySelectorAll: () => [audio] },
        fetch: async () => ({
            ok: true,
            blob: () => { enteredBlob(); return blob; },
        }),
        addPageHideListener: listener => { hide = listener; },
        createObjectURL: () => { created += 1; return 'blob:unexpected'; },
        revokeObjectURL: url => revoked.push(url),
    });
    await blobEntered;
    hide();
    hide();
    releaseBlob({});
    assert.deepEqual(await result, [false]);
    assert.equal(audio.src, packageURL('voice.m4a'));
    assert.equal(created, 0);
    assert.equal(loaded, 0);
    assert.deepEqual(revoked, []);
});

test('late response cannot publish to a detached media element', async () => {
    const audio = makeElement(packageURL('voice.m4a'));
    let release, hide, enteredFetch, loaded = 0;
    const fetchEntered = new Promise(resolve => { enteredFetch = resolve; });
    const created = [], revoked = [];
    audio.isConnected = true;
    audio.load = () => { loaded += 1; };
    const result = hydratePackageMedia({
        document: { querySelectorAll: () => [audio] },
        fetch: () => new Promise(resolve => { release = resolve; enteredFetch(); }),
        createObjectURL: () => { created.push('blob:detached'); return 'blob:detached'; },
        revokeObjectURL: url => revoked.push(url),
        addPageHideListener: listener => { hide = listener; },
    });
    await fetchEntered;
    audio.isConnected = false;
    release({ ok: true, blob: async () => ({}) });
    assert.deepEqual(await result, [false]);
    assert.equal(audio.src, packageURL('voice.m4a'));
    assert.equal(loaded, 0);
    assert.deepEqual(created, ['blob:detached']);
    assert.deepEqual(revoked, []);
    hide();
    hide();
    assert.deepEqual(revoked, ['blob:detached']);
});

test('late response preserves a replacement media source without loading it', async () => {
    const audio = makeElement(packageURL('voice.m4a'));
    const replacement = 'https://example.com/replacement.m4a';
    let release, hide, enteredFetch, loaded = 0;
    const fetchEntered = new Promise(resolve => { enteredFetch = resolve; });
    const revoked = [];
    audio.load = () => { loaded += 1; };
    const result = hydratePackageMedia({
        document: { querySelectorAll: () => [audio] },
        fetch: () => new Promise(resolve => { release = resolve; enteredFetch(); }),
        createObjectURL: () => 'blob:replaced',
        revokeObjectURL: url => revoked.push(url),
        addPageHideListener: listener => { hide = listener; },
    });
    await fetchEntered;
    audio.src = replacement;
    release({ ok: true, blob: async () => ({}) });
    assert.deepEqual(await result, [false]);
    assert.equal(audio.src, replacement);
    assert.equal(loaded, 0);
    hide();
    assert.deepEqual(revoked, ['blob:replaced']);
});

test('reentrant page hide during object URL creation releases it exactly once', async () => {
    const audio = makeElement(`${packageURL('voice.m4a')}#t=1`);
    const originalSource = audio.src;
    let hide, created = 0, loaded = 0;
    const revoked = [];
    audio.load = () => { loaded += 1; };
    const results = await hydratePackageMedia({
        document: { querySelectorAll: () => [audio] },
        fetch: async () => ({ ok: true, blob: async () => ({}) }),
        createObjectURL: () => {
            created += 1;
            hide();
            return 'blob:closing';
        },
        revokeObjectURL: url => revoked.push(url),
        addPageHideListener: listener => { hide = listener; },
    });
    assert.deepEqual(results, [false]);
    assert.equal(audio.src, originalSource);
    assert.equal(created, 1);
    assert.equal(loaded, 0);
    assert.deepEqual(revoked, ['blob:closing']);
    hide();
    assert.deepEqual(revoked, ['blob:closing']);
});

test('page hide from the first media load prevents later media loads', async () => {
    const first = makeElement(packageURL('first.m4a'));
    const second = makeElement(packageURL('second.m4a'));
    let hide, created = 0;
    const loads = [], revoked = [];
    first.load = () => { loads.push('first'); hide(); };
    second.load = () => { loads.push('second'); };
    const results = await hydratePackageMedia({
        document: { querySelectorAll: () => [first, second] },
        fetch: async () => ({ ok: true, blob: async () => ({}) }),
        createObjectURL: () => `blob:media-${++created}`,
        revokeObjectURL: url => revoked.push(url),
        addPageHideListener: listener => { hide = listener; },
    });
    // Each media reloads independently. The first load closes the page before
    // the second source can publish, even though its object URL was acquired.
    assert.deepEqual(results, [true, false]);
    assert.equal(first.src, 'blob:media-1');
    assert.equal(second.src, packageURL('second.m4a'));
    assert.deepEqual(loads, ['first']);
    assert.deepEqual(revoked, ['blob:media-1', 'blob:media-2']);
    hide();
    assert.deepEqual(revoked, ['blob:media-1', 'blob:media-2']);
});
