import assert from 'node:assert/strict';
import test from 'node:test';
import {
    hydratePackageMedia,
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
    assert.equal(isPackageMediaURL('https://example.com/voice.m4a'), false);
    assert.equal(isPackageMediaURL('not a URL'), false);
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
    assert.deepEqual(results, [true, true]);
    assert.equal(first.src, 'blob:media-1');
    assert.equal(second.src, 'blob:media-2');
    assert.deepEqual(loads, ['first']);
    assert.deepEqual(revoked, ['blob:media-1', 'blob:media-2']);
    hide();
    assert.deepEqual(revoked, ['blob:media-1', 'blob:media-2']);
});
