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
  const media = { localName: 'video', getRootNode() { return this.ownerDocument }, currentSrc: 'https://example.com/video.mp4', src: '', duration: 90,
    paused: true, ended: false, textTracks: [track], getAttribute: () => null,
    querySelector: selector => selector.startsWith('track') ? trackElement : null,
    querySelectorAll: selector => selector === 'track[src]' && trackElement ? [trackElement] : [] };
  const frames = [];
  const document = { title: 'Page title', scripts: [], isConnected: true,
    querySelectorAll: selector => selector === 'iframe' ? frames : selector === '*' ? [media, ...frames] : [media] };
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
  // WK arguments are per invocation. A later request must not overwrite the
  // expected identities of a request that is still awaiting fetch or its body.
  const run = (source, args = {}) => {
    const evaluate = new vm.Script(`(async function(${Object.keys(args).join(',')}) {\n${source}\n})`).runInContext(context)
    return evaluate.call(context, ...Object.values(args))
  }
  const capture = async () => JSON.parse(await run(snapshotSource));
  const captions = snapshot => run(captionsSource, {
    expectedDocumentID: snapshot.documentID,
    expectedMediaIdentity: snapshot.mediaIdentity,
    expectedDocumentURL: snapshot.documentURL,
    expectedCaptionSelectionIdentity: snapshot.captionSelectionIdentity
  })
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
  const media = { ...f.media, ownerDocument: doc, isConnected: true,
    getRootNode() { return this.ownerDocument }, textTracks: [track],
    querySelector: selector => selector.startsWith('track') ? element : null,
    querySelectorAll: selector => selector === 'track[src]' && element ? [element] : [] };
  const nodes = [media];
  doc.querySelectorAll = selector => selector === 'iframe' ? frames : selector === '*' ? [...nodes, ...frames] : nodes;
  const frame = { localName: 'iframe', getRootNode() { return this.ownerDocument },
    ownerDocument: parent, isConnected: true, contentDocument: doc };
  const view = { document: doc, frameElement: frame, location: new URL(url),
    navigator: { languages: ['en-US'] }, fetch: (...args) => f.context.fetch(...args) };
  doc.defaultView = view;
  return { doc, media, nodes, frames, frame, view, track };
}

function iframeOnly(f, options) {
  f.document.querySelectorAll = selector => selector === 'iframe' || selector === '*' ? f.frames : [];
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
  const inaccessible = { localName: 'iframe', getRootNode() { return this.ownerDocument },
    ownerDocument: f.document, isConnected: true,
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

// Model physical tree roots, not the flattened slot tree. Every reparent updates
// getRootNode/ownerDocument/isConnected, just as the production discovery sees.
function installTreeRoot(root) {
  root.members = []
  root.querySelectorAll = selector => root.members.filter(node => selector === '*'
    || selector === 'video, audio' && ['video', 'audio'].includes(node.localName)
    || selector === 'iframe' && node.localName === 'iframe')
  return root
}

function mountInRoot(root, node) {
  const ownerDocument = root ? root.ownerDocument || root : node.ownerDocument
  if (node.mountRoot) {
    const index = node.mountRoot.members.indexOf(node)
    if (index !== -1) node.mountRoot.members.splice(index, 1)
  }
  node.mountRoot = root
  node.getRootNode = function() { return this.mountRoot || this }
  Object.defineProperties(node, {
    ownerDocument: { configurable: true, enumerable: true,
      get() { return this.mountRoot?.ownerDocument || this.mountRoot || ownerDocument } },
    isConnected: { configurable: true, enumerable: true,
      get() { return this.mountRoot?.isConnected === true } }
  })
  root?.members.push(node)
  return node
}

function attachShadowFixture(parent, mode = 'open') {
  const host = mountInRoot(parent, { localName: 'media-player' })
  const root = installTreeRoot({ host, mode,
    get ownerDocument() { return host.ownerDocument },
    get isConnected() { return host.isConnected } })
  host.shadowRoot = mode === 'open' ? root : null
  return { host, root }
}

function shadowFixture(options) {
  const f = fixture(options)
  installTreeRoot(f.document)
  const shadow = attachShadowFixture(f.document)
  mountInRoot(shadow.root, f.media)
  return { ...f, ...shadow }
}

test('open shadow media captures loaded captions without network and retains article identity', async () => {
  const f = shadowFixture({ cues: [captionCue('Shadow words & <literal>')] })
  const first = await captureMedia(f)
  const repeated = await captureMedia(f)
  assert.equal(first.documentURL, f.context.location.href)
  assert.equal(first.mediaDocumentURL, f.context.location.href)
  assert.equal(first.title, 'Page title')
  assert.equal(first.mediaURL, f.media.currentSrc)
  assert.equal(first.mediaIdentity, repeated.mediaIdentity)
  assert.equal(first.captionSelectionIdentity, repeated.captionSelectionIdentity)
  assert.match(await f.captions(first), /Shadow words &amp; &lt;literal&gt;/)
  assert.equal(f.fetches(), 0)
})

test('nested open roots are discovered, but closed and disconnected hosts are not', async () => {
  const f = shadowFixture({ cues: [captionCue('Nested shadow')] })
  const inner = attachShadowFixture(f.root)
  mountInRoot(inner.root, f.media)
  assert.match((await captureMedia(f)).webVTT, /Nested shadow/)
  mountInRoot(null, f.host)
  assert.equal(await f.capture(), null)
  mountInRoot(f.document, f.host)
  assert.match((await captureMedia(f)).webVTT, /Nested shadow/)
  const closed = attachShadowFixture(f.document, 'closed')
  mountInRoot(closed.root, f.media)
  assert.equal(await f.capture(), null)
  mountInRoot(inner.root, f.media)
  assert.match(await f.captions(await captureMedia(f)), /Nested shadow/)
})

test('shadow audio is discovered independently of video elements', async () => {
  const f = shadowFixture({ cues: [captionCue('Audio caption')] })
  f.media.localName = 'audio'
  assert.match(await f.captions(await captureMedia(f)), /Audio caption/)
})

test('local light media precedes shadow media, both precede frames, and playing media still wins', async () => {
  const f = shadowFixture({ cues: [captionCue('Shadow')] })
  const light = fixture({ cues: [captionCue('Light')] }).media
  mountInRoot(f.document, light)
  const child = frameFixture(f, { cues: [captionCue('Frame')] })
  mountInRoot(f.document, child.frame)
  assert.match((await captureMedia(f)).webVTT, /Light/)
  f.media.paused = false
  assert.match((await captureMedia(f)).webVTT, /Shadow/)
  child.media.paused = false
  assert.match((await captureMedia(f)).webVTT, /Shadow/)
  light.paused = false
  assert.match((await captureMedia(f)).webVTT, /Light/)
  mountInRoot(null, light)
  f.media.paused = true
  assert.match((await captureMedia(f)).webVTT, /Frame/)
  child.media.paused = true
  assert.match((await captureMedia(f)).webVTT, /Shadow/)
})

test('moving the identical media and track to a sibling shadow root retires the old capture', async () => {
  const f = shadowFixture({ cues: [captionCue('Same node and track')] })
  const old = await captureMedia(f)
  const other = attachShadowFixture(f.document)
  mountInRoot(other.root, f.media)
  const fresh = await captureMedia(f)
  assert.equal(fresh.documentID, old.documentID)
  assert.equal(fresh.mediaURL, old.mediaURL)
  assert.equal(fresh.captionSelectionIdentity, old.captionSelectionIdentity)
  assert.notEqual(fresh.mediaIdentity, old.mediaIdentity)
  assert.equal(await f.captions(old), null)
  assert.match(await f.captions(fresh), /Same node and track/)
})

test('moving an intact nested host changes its outer ownership without replacing media or inner root', async () => {
  const f = shadowFixture({ cues: [captionCue('Retained inner tree')] })
  const inner = attachShadowFixture(f.root)
  mountInRoot(inner.root, f.media)
  const old = await captureMedia(f)
  const other = attachShadowFixture(f.document)
  mountInRoot(other.root, inner.host)
  const fresh = await captureMedia(f)
  assert.equal(f.media.getRootNode(), inner.root)
  assert.equal(fresh.captionSelectionIdentity, old.captionSelectionIdentity)
  assert.notEqual(fresh.mediaIdentity, old.mediaIdentity)
  assert.equal(await f.captions(old), null)
  assert.match(await f.captions(fresh), /Retained inner tree/)
})

test('unrelated shadow hosts and slot distribution do not replace a light DOM media owner', async () => {
  const f = shadowFixture({ cues: [captionCue('Slotted light media')] })
  mountInRoot(f.document, f.media)
  const old = await captureMedia(f)
  mountInRoot(f.root, { localName: 'slot', assignedNodes() { throw new Error('not a physical owner') } })
  attachShadowFixture(f.document)
  const fresh = await captureMedia(f)
  assert.equal(fresh.mediaIdentity, old.mediaIdentity)
  assert.equal(fresh.captionSelectionIdentity, old.captionSelectionIdentity)
  assert.match(await f.captions(old), /Slotted light media/)
})

test('moving media from shadow into light DOM rejects a previously captured request', async () => {
  const f = shadowFixture({ cues: [captionCue('Moved to light')] })
  const old = await captureMedia(f)
  mountInRoot(f.document, f.media)
  assert.equal(await f.captions(old), null)
  assert.match(await f.captions(await captureMedia(f)), /Moved to light/)
})

test('same-source physical replacement inside a shadow root changes media identity', async () => {
  const f = shadowFixture({ cues: [captionCue('Original')] })
  const old = await captureMedia(f)
  const replacement = fixture({ cues: [captionCue('Replacement')] }).media
  mountInRoot(null, f.media)
  mountInRoot(f.root, replacement)
  const fresh = await captureMedia(f)
  assert.equal(fresh.mediaURL, old.mediaURL)
  assert.notEqual(fresh.mediaIdentity, old.mediaIdentity)
  assert.equal(await f.captions(old), null)
  assert.match(await f.captions(fresh), /Replacement/)
})

test('an iframe inside an open root uses its own fetch context and keeps article provenance', async () => {
  const f = shadowFixture()
  mountInRoot(null, f.media)
  const child = frameFixture(f, { captionURL: 'https://example.com/shadow-frame.vtt' })
  mountInRoot(f.root, child.frame)
  child.track.language = 'ja'
  let fetches = 0
  child.view.fetch = async function(url, options) {
    assert.equal(this, child.view)
    assert.equal(url, 'https://example.com/shadow-frame.vtt')
    assert.equal(options.credentials, 'same-origin')
    fetches++
    return new Response(captionText('Frame in shadow'))
  }
  const selected = await captureMedia(f)
  assert.equal(fetches, 0)
  assert.equal(selected.documentURL, f.context.location.href)
  assert.equal(selected.mediaDocumentURL, child.view.location.href)
  assert.equal(selected.languageCode, 'ja')
  assert.match(await f.captions(selected), /Frame in shadow/)
  assert.equal(fetches, 1)
  assert.equal(f.fetches(), 0)
  mountInRoot(null, f.host)
  assert.equal(await f.captions(selected), null)
  assert.equal(fetches, 1)
})

test('open roots in accessible child documents retain the complete iframe ancestry', async () => {
  const f = fixture()
  const child = iframeOnly(f, { cues: [captionCue('Child shadow')] })
  installTreeRoot(child.doc)
  const shadow = attachShadowFixture(child.doc)
  mountInRoot(shadow.root, child.media)
  const old = await captureMedia(f)
  assert.equal(old.mediaDocumentURL, child.view.location.href)
  assert.match(await f.captions(old), /Child shadow/)
  const replacement = frameFixture(f, { cues: [captionCue('New child shadow')] })
  installTreeRoot(replacement.doc)
  const newShadow = attachShadowFixture(replacement.doc)
  mountInRoot(newShadow.root, replacement.media)
  replacement.view.frameElement = child.frame
  child.frame.contentDocument = replacement.doc
  assert.equal(await f.captions(old), null)
  assert.match(await f.captions(await captureMedia(f)), /New child shadow/)
})

for (const at of ['headers', 'body']) {
  test(`shadow reparent during ${at} await retires response and aborts transport; fresh retry succeeds`, async () => {
    const f = shadowFixture({ captionURL: 'https://example.com/shadow.vtt' })
    const other = attachShadowFixture(f.document)
    const old = await captureMedia(f)
    let release, started, signal
    const entered = new Promise(resolve => { started = resolve })
    f.context.fetch = async (_url, options) => {
      signal = options.signal
      if (at === 'headers') { started(); await new Promise(resolve => { release = resolve }) }
      return { ok: true, text: async () => {
        if (at === 'body') { started(); await new Promise(resolve => { release = resolve }) }
        return captionText('Retired response')
      } }
    }
    const pending = f.captions(old)
    try {
      await entered
      mountInRoot(other.root, f.media)
    } finally {
      release?.()
    }
    assert.equal(await pending, null)
    assert.equal(signal.aborted, true)
    f.context.fetch = async () => new Response(captionText('Current shadow'))
    assert.match(await f.captions(await captureMedia(f)), /Current shadow/)
  })
}

test('moving the frame between shadow roots invalidates a suspended child request even with unchanged child document', async () => {
  const f = shadowFixture()
  mountInRoot(null, f.media)
  const child = frameFixture(f, { captionURL: 'https://example.com/child.vtt' })
  mountInRoot(f.root, child.frame)
  const old = await captureMedia(f)
  let release, started, signal
  const entered = new Promise(resolve => { started = resolve })
  child.view.fetch = async (_url, options) => {
    signal = options.signal
    started()
    await new Promise(resolve => { release = resolve })
    return new Response(captionText('Old parent root'))
  }
  const pending = f.captions(old)
  try {
    await entered
    const other = attachShadowFixture(f.document)
    mountInRoot(other.root, child.frame)
  } finally {
    release?.()
  }
  assert.equal(await pending, null)
  assert.equal(signal.aborted, true)
  child.view.fetch = async () => new Response(captionText('Fresh parent root'))
  const fresh = await captureMedia(f)
  assert.equal(fresh.mediaDocumentURL, old.mediaDocumentURL)
  assert.notEqual(fresh.mediaIdentity, old.mediaIdentity)
  assert.match(await f.captions(fresh), /Fresh parent root/)
})

for (const remote of [false, true]) {
  test(`shadow ${remote ? 'remote' : 'loaded'} captions cannot change language during saved lookup`, async () => {
    const f = shadowFixture({ captionURL: 'https://example.com/en.vtt' })
    const english = await captureMedia(f)
    const japanese = { ...f.track, language: 'ja', cues: remote ? [] : [captionCue('日本語')] }
    const element = { track: japanese, src: 'https://example.com/ja.vtt', srclang: 'ja' }
    f.media.textTracks = [japanese]
    f.media.querySelectorAll = () => [element]
    const urls = []
    f.context.fetch = async url => { urls.push(url); return new Response(captionText('日本語')) }
    assert.equal(await f.captions(english), null)
    assert.deepEqual(urls, [])
    const fresh = await captureMedia(f)
    assert.equal(fresh.languageCode, 'ja')
    assert.match(await f.captions(fresh), /日本語/)
    assert.deepEqual(urls, remote ? [element.src] : [])
  })
}

test('a fresh shadow request can finish before an older request without transferring its authority', async () => {
  const f = shadowFixture({ captionURL: 'https://example.com/shared.vtt' })
  const other = attachShadowFixture(f.document)
  const old = await captureMedia(f)
  let release, started, oldSignal, oldOutput
  const entered = new Promise(resolve => { started = resolve })
  f.context.fetch = async (_url, options) => {
    oldSignal = options.signal
    started()
    await new Promise(resolve => { release = resolve })
    return new Response(captionText('Old root response'))
  }
  const pending = f.captions(old)
  try {
    await entered
    mountInRoot(other.root, f.media)
    const fresh = await captureMedia(f)
    f.context.fetch = async () => new Response(captionText('Current root response'))
    assert.match(await f.captions(fresh), /Current root response/)
  } finally {
    release?.()
    oldOutput = await pending
  }
  assert.equal(oldOutput, null)
  assert.equal(oldSignal.aborted, true)
})
