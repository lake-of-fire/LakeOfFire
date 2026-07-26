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
