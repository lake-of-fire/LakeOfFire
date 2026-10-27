const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// Execute the same resource bodies loaded by ReaderTranscriptMediaBridge.
const resourceRoot = path.join(__dirname, '../../Sources/LakeOfFireReader/Resources/Transcript');
const snapshotSource = fs.readFileSync(path.join(resourceRoot, 'reader-transcript-snapshot.js'), 'utf8');
const captionsSource = fs.readFileSync(path.join(resourceRoot, 'reader-transcript-captions.js'), 'utf8');
let nextUUID = 0;

function fixture({ cues = [], captionURL = null, pageURL = 'https://example.com/watch' } = {}) {
  const track = { kind: 'subtitles', language: 'en', mode: 'showing', cues };
  const trackElement = captionURL ? { track, src: captionURL, srclang: 'en' } : null;
  const media = { currentSrc: 'https://example.com/video.mp4', src: '', duration: 90,
    paused: true, ended: false, textTracks: [track], getAttribute: () => null,
    querySelector: selector => selector.startsWith('track') ? trackElement : null,
    querySelectorAll: selector => selector === 'track[src]' && trackElement ? [trackElement] : [] };
  const frames = [];
  const document = { title: 'Page title', scripts: [], isConnected: true,
    querySelectorAll: selector => selector === 'iframe' ? frames : [media] };
  let fetches = 0;
  const context = vm.createContext({ document, location: new URL(pageURL), navigator: { languages: ['en-US'] },
    URL, setTimeout, clearTimeout, AbortController,
    crypto: { randomUUID: () => `uuid-${++nextUUID}` },
    fetch: async () => { fetches++; return { ok: true, text: async () => 'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nCaption\n' }; } });
  document.defaultView = context;
  Object.defineProperties(media, {
    ownerDocument: { configurable: true, enumerable: true, get: () => context.document },
    isConnected: { configurable: true, enumerable: true, value: true, writable: true }
  });
  const run = source => new vm.Script(`(async function() {\n${source}\n}).call(globalThis)`).runInContext(context);
  const capture = async () => JSON.parse(await run(snapshotSource));
  const captions = async snapshot => {
    context.expectedDocumentID = snapshot.documentID;
    context.expectedMediaIdentity = snapshot.mediaIdentity;
    context.expectedDocumentURL = snapshot.documentURL;
    context.expectedCaptionSelectionIdentity = snapshot.captionSelectionIdentity;
    return run(captionsSource);
  };
  return { context, document, media, track, frames, capture, captions, fetches: () => fetches };
}

test('capture selects loaded cues without fetching and preserves source identity', async () => {
  const f = fixture({ cues: [{ startTime: 1.25, endTime: 2.5,
    getCueAsHTML: () => ({ textContent: 'Hello world & <name>' }) }] });
  const first = await f.capture();
  const second = await f.capture();
  assert.equal(first.documentID, second.documentID);
  assert.equal(first.mediaIdentity, second.mediaIdentity);
  assert.equal(first.webVTT, 'WEBVTT\n\n00:00:01.250 --> 00:00:02.500\nHello world &amp; &lt;name&gt;\n');
  assert.equal(await f.captions(first), first.webVTT);
  assert.equal(f.fetches(), 0);
});

test('saved-first capture leaves remote captions unfetched until requested', async () => {
  const f = fixture({ captionURL: 'https://example.com/captions.vtt' });
  const snapshot = await f.capture();
  assert.equal(snapshot.webVTT, null);
  assert.equal(f.fetches(), 0);
  assert.match(await f.captions(snapshot), /^WEBVTT/);
  assert.equal(f.fetches(), 1);
});

test('same URL document replacement rejects a previous caption request', async () => {
  const f = fixture({ captionURL: 'https://example.com/captions.vtt' });
  const old = await f.capture();
  f.context.document = { ...f.document, __manabiTranscriptCapture: undefined };
  const current = await f.capture();
  assert.notEqual(current.documentID, old.documentID);
  assert.equal(await f.captions(old), null);
  assert.equal(f.fetches(), 0);
});

test('physical media replacement at the same source rejects the old selection', async () => {
  const f = fixture({ captionURL: 'https://example.com/captions.vtt' });
  const old = await f.capture();
  f.document.querySelectorAll = () => [{ ...f.media }];
  assert.equal(await f.captions(old), null);
  assert.equal(f.fetches(), 0);
});

test('SPA URL change and media source change each reject before fetch', async () => {
  const f = fixture({ captionURL: 'https://example.com/captions.vtt' });
  const snapshot = await f.capture();
  f.context.location = new URL('https://example.com/other');
  assert.equal(await f.captions(snapshot), null);
  f.context.location = new URL(snapshot.documentURL);
  f.media.currentSrc = 'https://example.com/other.mp4';
  assert.equal(await f.captions(snapshot), null);
  assert.equal(f.fetches(), 0);
});

test('late response cannot cross a media source change; fresh retry succeeds', async () => {
  const f = fixture({ captionURL: 'https://example.com/captions.vtt' });
  const old = await f.capture();
  let release;
  f.context.fetch = async (_url, options) => {
    assert.equal(options.credentials, 'same-origin');
    await new Promise(resolve => { release = resolve; });
    return { ok: true, text: async () => 'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nFresh\n' };
  };
  const pending = f.captions(old);
  f.media.currentSrc = 'https://example.com/new.mp4';
  release();
  assert.equal(await pending, null);
  const current = await f.capture();
  const retry = f.captions(current);
  release();
  assert.match(await retry, /Fresh/);
});

test('caption failures and non-WebVTT responses remain a generation fallback', async () => {
  const f = fixture({ captionURL: 'https://example.com/captions.vtt' });
  const snapshot = await f.capture();
  f.context.fetch = async () => ({ ok: false });
  assert.equal(await f.captions(snapshot), null);
  f.context.fetch = async () => ({ ok: true, text: async () => '<html>Sign in</html>' });
  assert.equal(await f.captions(snapshot), null);
  f.context.fetch = async () => { throw new Error('CORS'); };
  assert.equal(await f.captions(snapshot), null);
});

test('same URL document teardown while reading caption text discards the response', async () => {
  const f = fixture({ captionURL: 'https://example.com/captions.vtt' });
  const old = await f.capture();
  let release;
  let reading;
  const started = new Promise(resolve => { reading = resolve; });
  f.context.fetch = async () => ({ ok: true, text: async () => {
    reading();
    await new Promise(resolve => { release = resolve; });
    return 'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nOld document\n';
  } });
  const pending = f.captions(old);
  await started;
  f.context.document = { ...f.document, __manabiTranscriptCapture: undefined };
  release();
  assert.equal(await pending, null);
  const current = await f.capture();
  assert.notEqual(current.documentID, old.documentID);
});

test('YouTube captions require the player response for the current video', async () => {
  const f = fixture({ pageURL: 'https://www.youtube.com/watch?v=current' });
  f.context.ytInitialPlayerResponse = { videoDetails: { videoId: 'previous' },
    captions: { playerCaptionsTracklistRenderer: { captionTracks: [
      { languageCode: 'en', baseUrl: 'https://www.youtube.com/api/timedtext?v=current' }
    ] } } };
  assert.equal((await f.capture()).captionURL, null);
  assert.equal((await f.capture()).stableProviderIdentity, null);
  f.context.ytInitialPlayerResponse.videoDetails.videoId = 'current';
  assert.equal((await f.capture()).captionURL, 'https://www.youtube.com/api/timedtext?v=current&fmt=vtt');
  assert.equal((await f.capture()).stableProviderIdentity, 'youtube:current');
  assert.equal(f.fetches(), 0);
});

test('same provider video has durable identity across documents with different blob URLs', async () => {
  const first = fixture({ pageURL: 'https://www.youtube.com/watch?v=videoA' });
  const next = fixture({ pageURL: 'https://www.youtube.com/watch?v=videoA' });
  first.media.currentSrc = 'blob:https://www.youtube.com/old';
  next.media.currentSrc = 'blob:https://www.youtube.com/new';
  first.context.ytInitialPlayerResponse = next.context.ytInitialPlayerResponse = { videoDetails: { videoId: 'videoA' } };
  const a = await first.capture();
  const b = await next.capture();
  assert.notEqual(a.documentID, b.documentID);
  assert.notEqual(a.mediaIdentity, b.mediaIdentity);
  assert.equal(a.stableProviderIdentity, 'youtube:videoA');
  assert.equal(b.stableProviderIdentity, a.stableProviderIdentity);
  next.context.location = new URL('https://www.youtube.com/watch?v=videoB');
  assert.equal((await next.capture()).stableProviderIdentity, null);
  next.context.ytInitialPlayerResponse = { videoDetails: { videoId: 'videoB' } };
  assert.equal((await next.capture()).stableProviderIdentity, 'youtube:videoB');
  const unknown = fixture();
  unknown.media.currentSrc = 'blob:https://example.com/unknown';
  assert.equal((await unknown.capture()).stableProviderIdentity, null);
});

test('loaded cues reject negative, reversed and nonfinite timing', async () => {
  const cue = (startTime, endTime) => ({ startTime, endTime, getCueAsHTML: () => ({ textContent: 'Words' }) });
  const f = fixture({ cues: [cue(-1, 1), cue(2, 1), cue(1, 1), cue(1, Infinity), cue(1, 2)] });
  assert.equal((await f.capture()).webVTT, 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nWords\n');
  f.track.cues = [cue(-1, 1)];
  assert.equal((await f.capture()).webVTT, null);
});

const captionCue = text => ({ startTime: 0, endTime: 1, getCueAsHTML: () => ({ textContent: text }) });
const captionText = text => `WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n${text}\n`;

for (const remote of [false, true]) {
  test(`${remote ? 'remote' : 'loaded'} replacement after saved lookup rejects old language; fresh request works`, async () => {
    const f = fixture({ captionURL: 'https://example.com/en.vtt' });
    const english = await f.capture();
    const japanese = { ...f.track, language: 'ja', cues: remote ? [] : [captionCue('日本語')] };
    const element = { track: japanese, src: 'https://example.com/ja.vtt', srclang: 'ja' };
    f.media.textTracks = [japanese];
    f.media.querySelectorAll = () => [element];
    const urls = [];
    f.context.fetch = async url => { urls.push(url); return new Response(captionText('日本語')); };
    assert.equal(await f.captions(english), null);
    assert.deepEqual(urls, []);
    const fresh = await f.capture();
    assert.equal(fresh.languageCode, 'ja');
    assert.match(await f.captions(fresh), /日本語/);
    assert.deepEqual(urls, remote ? [element.src] : []);
  });
}

test('same-language replacement has distinct selection identity even with identical URL', async () => {
  const f = fixture({ captionURL: 'https://example.com/en.vtt' });
  const old = await f.capture();
  const replacement = { ...f.track, cues: [captionCue('Replacement')] };
  f.media.textTracks = [replacement];
  f.media.querySelectorAll = () => [{ track: replacement, src: old.captionURL, srclang: 'en' }];
  const fresh = await f.capture();
  assert.equal(fresh.languageCode, old.languageCode);
  assert.notEqual(fresh.captionSelectionIdentity, old.captionSelectionIdentity);
  assert.equal(await f.captions(old), null);
  assert.match(await f.captions(fresh), /Replacement/);
});

for (const changeAt of ['headers', 'body']) {
  test(`track replacement during ${changeAt} await rejects response and allows fresh retry`, async () => {
    const f = fixture({ captionURL: 'https://example.com/en.vtt' });
    const old = await f.capture();
    let release, started;
    const waiting = new Promise(resolve => { started = resolve; });
    f.context.fetch = async () => {
      if (changeAt === 'headers') { started(); await new Promise(resolve => { release = resolve; }); }
      return { ok: true, text: async () => {
        if (changeAt === 'body') { started(); await new Promise(resolve => { release = resolve; }); }
        return captionText('Old English');
      } };
    };
    const pending = f.captions(old);
    await waiting;
    f.track.language = 'ja';
    release();
    assert.equal(await pending, null);
    f.context.fetch = async () => new Response(captionText('日本語'));
    assert.match(await f.captions(await f.capture()), /日本語/);
  });
}

for (const failure of ['status', 'ownership']) {
  test(`unread body after ${failure} rejection is cancelled or aborted; fresh retry reads body`, async () => {
    const f = fixture({ captionURL: 'https://example.com/en.vtt' });
    const snapshot = await f.capture();
    let cancelled = false, signal;
    const body = new ReadableStream({ cancel() { cancelled = true; } });
    const response = new Response(body, { status: failure === 'status' ? 503 : 200 });
    f.context.fetch = async (_url, options) => {
      signal = options.signal;
      if (failure === 'ownership') f.media.currentSrc = 'https://example.com/new.mp4';
      return response;
    };
    assert.equal(await f.captions(snapshot), null);
    assert.ok(cancelled || signal.aborted);
    f.context.fetch = async () => new Response(captionText('Retry'));
    assert.match(await f.captions(await f.capture()), /Retry/);
  });
}

test('YouTube ranks matching manual, matching ASR, then unmatched language fallback', async () => {
  const f = fixture({ pageURL: 'https://www.youtube.com/watch?v=current' });
  f.media.textTracks = [];
  const options = [
    { languageCode: 'ja', baseUrl: 'https://www.youtube.com/ja' },
    { languageCode: 'en', kind: 'asr', baseUrl: 'https://www.youtube.com/en-asr' }
  ];
  f.context.ytInitialPlayerResponse = { videoDetails: { videoId: 'current' },
    captions: { playerCaptionsTracklistRenderer: { captionTracks: options } } };
  assert.match((await f.capture()).captionURL, /en-asr/);
  options.push({ languageCode: 'en-GB', baseUrl: 'https://www.youtube.com/en-manual' });
  assert.match((await f.capture()).captionURL, /en-manual/);
  options.push({ languageCode: 'en-US', baseUrl: 'https://www.youtube.com/en-exact' });
  assert.match((await f.capture()).captionURL, /en-exact/);
  options.splice(1);
  const fallback = await f.capture();
  assert.equal(fallback.languageCode, 'ja');
  assert.match(fallback.captionURL, /\/ja\?/);
});

test('unassociated HTML fallback cannot pair Japanese URL with selected English language', async () => {
  const f = fixture({ captionURL: 'https://example.com/en.vtt' });
  assert.equal((await f.capture()).languageCode, 'en');
  const japanese = { track: { language: 'ja' }, src: 'https://example.com/ja.vtt', srclang: 'ja' };
  f.media.querySelectorAll = () => [japanese];
  f.media.querySelector = () => japanese;
  const selected = await f.capture();
  assert.equal(selected.captionURL, null);
  assert.equal(selected.languageCode, 'en');
  f.media.textTracks = [];
  const fallback = await f.capture();
  assert.equal(fallback.captionURL, japanese.src);
  assert.equal(fallback.languageCode, 'ja');
});

async function captureMedia(f) {
  const snapshot = await f.capture();
  assert.notEqual(snapshot, null, 'Expected a discoverable media selection');
  return snapshot;
}

function frameFixture(f, { parent = f.document, url = 'https://example.com/embedded',
                            cues = [], captionURL = null } = {}) {
  const frames = [];
  const track = { kind: 'subtitles', language: 'en', mode: 'showing', cues };
  const element = captionURL ? { track, src: captionURL, srclang: 'en' } : null;
  const doc = { title: 'Embedded title', scripts: [], isConnected: true };
  const media = { ...f.media, ownerDocument: doc, textTracks: [track],
    querySelector: selector => selector.startsWith('track') ? element : null,
    querySelectorAll: selector => selector === 'track[src]' && element ? [element] : [] };
  const nodes = [media];
  doc.querySelectorAll = selector => selector === 'iframe' ? frames : nodes;
  const frame = { ownerDocument: parent, isConnected: true, contentDocument: doc };
  const view = { document: doc, frameElement: frame, location: new URL(url),
    navigator: { languages: ['en-US'] }, fetch: (...args) => f.context.fetch(...args) };
  doc.defaultView = view;
  return { doc, media, nodes, frames, frame, view, track };
}

function iframeOnly(f, options) {
  f.document.querySelectorAll = selector => selector === 'iframe' ? f.frames : [];
  const child = frameFixture(f, options);
  f.frames.push(child.frame);
  return child;
}

test('iframe loaded captions preserve article identity and capture owning document without fetch', async () => {
  const f = fixture();
  const child = iframeOnly(f, { cues: [captionCue('Child words')] });
  const snapshot = await captureMedia(f);
  assert.equal(snapshot.documentURL, f.context.location.href);
  assert.equal(snapshot.title, 'Page title');
  assert.equal(snapshot.mediaDocumentURL, child.view.location.href);
  assert.match(await f.captions(snapshot), /Child words/);
  assert.equal(f.fetches(), 0);
});

test('iframe remote captions use the owning window fetch and selected language after saved lookup', async () => {
  const f = fixture();
  const child = iframeOnly(f, { captionURL: 'https://example.com/child.vtt' });
  child.track.language = 'ja';
  let childFetches = 0;
  child.view.fetch = async function(url, options) {
    assert.equal(this, child.view);
    assert.equal(url, 'https://example.com/child.vtt');
    assert.equal(options.credentials, 'same-origin');
    childFetches++;
    return new Response(captionText('日本語'));
  };
  const snapshot = await captureMedia(f);
  assert.equal(childFetches, 0);
  assert.equal(snapshot.languageCode, 'ja');
  assert.match(await f.captions(snapshot), /日本語/);
  assert.equal(childFetches, 1);
  assert.equal(f.fetches(), 0);
});

test('nested accessible frames participate; inaccessible and detached frames are skipped', async () => {
  const f = fixture();
  const outer = iframeOnly(f);
  outer.nodes.length = 0;
  const inner = frameFixture(f, { parent: outer.doc, cues: [captionCue('Nested')] });
  outer.frames.push(inner.frame);
  const inaccessible = { ownerDocument: f.document, isConnected: true,
    get contentDocument() { throw new Error('SecurityError'); } };
  const detached = frameFixture(f, { cues: [captionCue('Detached')] });
  detached.frame.isConnected = false;
  f.frames.unshift(inaccessible, detached.frame);
  const snapshot = await captureMedia(f);
  assert.match(await f.captions(snapshot), /Nested/);
  inner.doc.isConnected = false;
  assert.equal(await f.capture(), null);
});

test('candidate order is main then frames in DOM order, with playing media preferred', async () => {
  const f = fixture({ cues: [captionCue('Main')] });
  const first = frameFixture(f, { cues: [captionCue('First child')] });
  const second = frameFixture(f, { cues: [captionCue('Second child')] });
  f.frames.push(first.frame, second.frame);
  assert.match((await captureMedia(f)).webVTT, /Main/);
  second.media.paused = false;
  assert.match((await captureMedia(f)).webVTT, /Second child/);
  first.media.paused = false;
  assert.match((await captureMedia(f)).webVTT, /First child/);
  f.media.paused = false;
  assert.match((await captureMedia(f)).webVTT, /Main/);
});

test('same-URL child replacement preserves root document but rejects old capture and accepts fresh', async () => {
  const f = fixture();
  const oldChild = iframeOnly(f, { cues: [captionCue('Old')] });
  const old = await captureMedia(f);
  const replacement = frameFixture(f, { cues: [captionCue('Fresh')] });
  replacement.view.frameElement = oldChild.frame;
  oldChild.frame.contentDocument = replacement.doc;
  const fresh = await captureMedia(f);
  assert.equal(fresh.documentID, old.documentID);
  assert.equal(fresh.mediaDocumentURL, old.mediaDocumentURL);
  assert.notEqual(fresh.mediaIdentity, old.mediaIdentity);
  assert.equal(await f.captions(old), null);
  assert.match(await f.captions(fresh), /Fresh/);
});

test('detached frame and replaced ancestor cannot retain ownership of a reachable old document', async () => {
  const f = fixture();
  const outer = iframeOnly(f);
  outer.nodes.length = 0;
  const inner = frameFixture(f, { parent: outer.doc, cues: [captionCue('Inner')] });
  outer.frames.push(inner.frame);
  const old = await captureMedia(f);
  outer.frame.isConnected = false;
  assert.equal(await f.captions(old), null);
  outer.frame.isConnected = true;
  const replacement = frameFixture(f);
  replacement.nodes.length = 0;
  replacement.view.frameElement = outer.frame;
  outer.frame.contentDocument = replacement.doc;
  assert.equal(await f.captions(old), null);
});

test('adopting the identical node into a sibling document changes ownership identity', async () => {
  const f = fixture();
  const first = iframeOnly(f, { cues: [captionCue('Adopted')] });
  const second = frameFixture(f);
  second.nodes.length = 0;
  f.frames.push(second.frame);
  const old = await captureMedia(f);
  first.nodes.length = 0;
  first.media.ownerDocument = second.doc;
  second.nodes.push(first.media);
  const fresh = await captureMedia(f);
  assert.notEqual(old.mediaIdentity, fresh.mediaIdentity);
  assert.equal(await f.captions(old), null);
  assert.match(await f.captions(fresh), /Adopted/);
});

test('child URL, source and same-language track replacements invalidate captured ownership', async () => {
  const f = fixture();
  const child = iframeOnly(f, { cues: [captionCue('Child')] });
  let old = await captureMedia(f);
  child.view.location = new URL('https://example.com/new-child');
  assert.equal(await f.captions(old), null);
  old = await captureMedia(f);
  child.media.currentSrc = 'https://example.com/new.mp4';
  assert.equal(await f.captions(old), null);
  old = await captureMedia(f);
  child.media.textTracks = [{ ...child.track }];
  assert.equal(await f.captions(old), null);
  assert.match(await f.captions(await captureMedia(f)), /Child/);
});

for (const at of ['headers', 'body']) {
  test(`iframe replacement during ${at} await aborts old request; fresh child retry succeeds`, async () => {
    const f = fixture();
    const child = iframeOnly(f, { captionURL: 'https://example.com/child.vtt' });
    const old = await captureMedia(f);
    let release, started, signal;
    const waiting = new Promise(resolve => { started = resolve; });
    child.view.fetch = async (_url, options) => {
      signal = options.signal;
      if (at === 'headers') { started(); await new Promise(resolve => { release = resolve; }); }
      return { ok: true, text: async () => {
        if (at === 'body') { started(); await new Promise(resolve => { release = resolve; }); }
        return captionText('Stale child');
      } };
    };
    const pending = f.captions(old);
    await waiting;
    const replacement = frameFixture(f, { captionURL: 'https://example.com/fresh.vtt' });
    replacement.view.frameElement = child.frame;
    child.frame.contentDocument = replacement.doc;
    release();
    assert.equal(await pending, null);
    assert.equal(signal.aborted, true);
    replacement.view.fetch = async () => new Response(captionText('Fresh child'));
    assert.match(await f.captions(await captureMedia(f)), /Fresh child/);
  });
}

test('child provider uses its own URL and globals and rejects a previous video response', async () => {
  const f = fixture({ pageURL: 'https://www.youtube.com/article' });
  const child = iframeOnly(f, { url: 'https://www.youtube.com/watch?v=child' });
  child.media.textTracks = [];
  f.context.ytInitialPlayerResponse = { videoDetails: { videoId: 'child' },
    captions: { playerCaptionsTracklistRenderer: { captionTracks: [
      { languageCode: 'ja', baseUrl: '/wrong-parent' }
    ] } } };
  assert.equal((await captureMedia(f)).captionURL, null);
  child.view.ytInitialPlayerResponse = { videoDetails: { videoId: 'previous' },
    captions: { playerCaptionsTracklistRenderer: { captionTracks: [
      { languageCode: 'en', baseUrl: '/api/timedtext?v=child' }
    ] } } };
  assert.equal((await captureMedia(f)).captionURL, null);
  child.view.ytInitialPlayerResponse.videoDetails.videoId = 'child';
  const snapshot = await captureMedia(f);
  assert.equal(snapshot.captionURL, 'https://www.youtube.com/api/timedtext?v=child&fmt=vtt');
  assert.equal(snapshot.stableProviderIdentity, 'youtube:child');
  assert.equal(snapshot.documentURL, 'https://www.youtube.com/article');
  assert.equal(snapshot.mediaDocumentURL, child.view.location.href);
});
