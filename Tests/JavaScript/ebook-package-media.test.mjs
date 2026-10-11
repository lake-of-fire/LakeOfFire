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
