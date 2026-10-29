import assert from 'node:assert/strict';
import test from 'node:test';
import { createReaderProgressScrubController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/reader-progress-scrub.js';

globalThis.document = { getElementById: () => null };
globalThis.requestAnimationFrame = callback => { callback(); return 0 };
globalThis.cancelAnimationFrame = () => {};
const { NavigationHUD } = await import('../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-viewer-nav.js');

const fixture = () => {
    const hud = new NavigationHUD();
    hud.currentLocationDescriptor = { fraction: 0.1 };
    const scheduled = [];
    let cancellations = 0;
    const scheduleGoToFraction = (...args) => scheduled.push(args);
    scheduleGoToFraction.cancel = () => { cancellations += 1 };
    const reader = { navHUD: hud, view: {}, scheduleGoToFraction };
    let currentReader = reader;
    const navigations = [];
    const controller = createReaderProgressScrubController({
        getReader: () => currentReader,
        navigate: (_reader, fraction) => new Promise((resolve, reject) => {
            navigations.push({ fraction, resolve, reject });
        }),
    });
    return { controller, hud, reader, scheduled, navigations,
        cancellations: () => cancellations,
        replaceReader: value => { currentReader = value },
    };
};

test('retirement cancels an admitted preview and clears its authentic HUD scrub session', () => {
    const f = fixture();
    assert.equal(f.controller.schedule('sheet', 'first', 0.4), true);
    assert.deepEqual(f.scheduled, [[0.4, 'first']]);
    assert.equal(f.hud.scrubSession.active, true);
    assert.equal(f.controller.retire(['first']), true);
    assert.equal(f.cancellations(), 1);
    assert.equal(f.hud.scrubSession, null);
    assert.equal(f.controller.owns('first'), false);
    assert.equal(f.controller.schedule('sheet', 'first', 0.5), false);
    assert.equal(f.scheduled.length, 1);
});

test('a retired suspended release cannot finalize a newer scrub', async () => {
    const f = fixture();
    f.controller.schedule('sheet', 'first', 0.4);
    const release = f.controller.end('sheet', 'first', 0.4);
    f.controller.retire(['first']);
    f.controller.schedule('sheet', 'second', 0.7);
    const successor = f.hud.scrubSession;
    f.navigations[0].resolve(true);
    assert.equal(await release, false);
    assert.equal(f.hud.scrubSession, successor);
    assert.equal(f.controller.owns('second'), true);
});

test('late retirement only cancels the exact captured owners', () => {
    const f = fixture();
    f.controller.schedule('sheet', 'first', 0.4);
    f.controller.schedule('sheet', 'second', 0.7);
    const successor = f.hud.scrubSession;
    const cancellationCount = f.cancellations();
    assert.equal(f.controller.retire(['first']), false);
    assert.equal(f.cancellations(), cancellationCount);
    assert.equal(f.hud.scrubSession, successor);
    assert.equal(f.controller.owns('second'), true);
});

test('retirement before a queued preview prevents that owner from being revived', () => {
    const f = fixture();
    f.controller.retire(['queued']);
    assert.equal(f.controller.begin('sheet', 'queued'), false);
    assert.equal(f.controller.schedule('sheet', 'queued', 0.8), false);
    assert.equal(f.hud.scrubSession, null);
    assert.equal(f.scheduled.length, 0);
});

test('changed late release keeps the owner but supersedes the earlier completion', async () => {
    const f = fixture();
    f.controller.schedule('sheet', 'first', 0.4);
    const earlier = f.controller.end('sheet', 'first', 0.4);
    assert.equal(f.controller.schedule('sheet', 'first', 0.3), false);
    const latest = f.controller.end('sheet', 'first', 0.3);
    const active = f.hud.scrubSession;
    f.navigations[0].resolve(true);
    assert.equal(await earlier, false);
    assert.equal(f.hud.scrubSession, active);
    f.navigations[1].resolve(true);
    assert.equal(await latest, true);
    assert.equal(f.hud.scrubSession, null);
});

test('release with no dispatched preview still establishes and ends its HUD session', async () => {
    const f = fixture();
    const release = f.controller.end('sheet', 'release-only', 0.4);
    assert.equal(f.hud.scrubSession.active, true);
    f.navigations[0].resolve(true);
    assert.equal(await release, true);
    assert.equal(f.hud.scrubSession, null);
});

test('document replacement fences a suspended release and retirement', async () => {
    const f = fixture();
    const release = f.controller.end('old-sheet', 'old', 0.4);
    const newerHUD = new NavigationHUD();
    newerHUD.currentLocationDescriptor = { fraction: 0.5 };
    f.replaceReader({ navHUD: newerHUD, view: {}, scheduleGoToFraction() {} });
    f.controller.begin('new-sheet', 'new');
    const successor = newerHUD.scrubSession;
    assert.equal(f.controller.retire(['old']), false);
    f.navigations[0].resolve(true);
    assert.equal(await release, false);
    assert.equal(newerHUD.scrubSession, successor);
});

test('document replacement rejects a queued preview held by the retired reader', () => {
    const f = fixture();
    f.controller.schedule('old-sheet', 'old', 0.4);
    assert.equal(f.controller.owns('old', f.reader), true);
    const newerHUD = new NavigationHUD();
    const newerReader = { navHUD: newerHUD, view: {}, scheduleGoToFraction() {} };
    f.replaceReader(newerReader);
    f.controller.begin('new-sheet', 'new');
    assert.equal(f.controller.owns('old', f.reader), false);
    assert.equal(f.controller.owns('new', newerReader), true);
});

test('failure from a retired release leaves a newer HUD session intact', async () => {
    const f = fixture();
    const release = f.controller.end('sheet', 'old', 0.4);
    f.controller.schedule('sheet', 'new', 0.8);
    const successor = f.hud.scrubSession;
    f.navigations[0].reject(new Error('retired renderer failed'));
    await assert.rejects(release, /retired renderer failed/);
    assert.equal(f.hud.scrubSession, successor);
});
