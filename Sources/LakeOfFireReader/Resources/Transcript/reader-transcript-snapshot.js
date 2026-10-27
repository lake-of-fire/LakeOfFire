const doc = document;
if (!doc.__manabiTranscriptCapture) {
  const uuid = () => globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random()}`;
  const documentID = uuid();
  const identities = new WeakMap();
  const timestamp = seconds => {
    const ms = Math.round(Math.max(0, seconds) * 1000);
    return `${String(Math.floor(ms / 3600000)).padStart(2, '0')}:${String(Math.floor(ms / 60000) % 60).padStart(2, '0')}:${String(Math.floor(ms / 1000) % 60).padStart(2, '0')}.${String(ms % 1000).padStart(3, '0')}`;
  };
  doc.__manabiTranscriptCapture = () => {
    if (document !== doc) return null;
    const media = Array.from(doc.querySelectorAll('video, audio'));
    const node = media.find(value => !value.paused && !value.ended) || media[0];
    if (!node) return null;
    if (!identities.has(node)) identities.set(node, uuid());
    const source = node.currentSrc || node.src || node.querySelector('source[src]')?.src || '';
    const tracks = Array.from(node.textTracks || []).filter(track => ['captions', 'subtitles'].includes(track.kind));
    const languages = navigator.languages || [navigator.language || ''];
    const rank = track => track.mode === 'showing' ? -1 : languages.findIndex(language => language.split('-')[0] === (track.language || '').split('-')[0]);
    tracks.sort((a, b) => (rank(a) < 0 && a.mode !== 'showing' ? 100 : rank(a)) - (rank(b) < 0 && b.mode !== 'showing' ? 100 : rank(b)));
    const track = tracks[0];
    const cues = Array.from(track?.cues || []).filter(cue => Number.isFinite(cue.startTime) && cue.startTime >= 0 && Number.isFinite(cue.endTime) && cue.endTime > cue.startTime && typeof cue.getCueAsHTML === 'function');
    const cueText = cue => cue.getCueAsHTML().textContent.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    const webVTT = cues.length ? 'WEBVTT\n\n' + cues.map(cue => `${timestamp(cue.startTime)} --> ${timestamp(cue.endTime)}\n${cueText(cue)}\n`).join('\n') : null;
    const trackElement = Array.from(node.querySelectorAll('track[src]')).find(element => element.track === track)
      || node.querySelector('track[kind="captions"][src], track[kind="subtitles"][src]');
    let captionURL = trackElement?.src || null;
    let languageCode = track?.language || trackElement?.srclang || null;
    let stableProviderIdentity = null;
    // YouTube often exposes provider tracks rather than HTML textTracks.
    // A response from the previous SPA video must never supply captions.
    if (/(^|\.)youtube\.com$/.test(location.hostname)) {
      let response = globalThis.ytInitialPlayerResponse;
      if (!response) {
        const script = Array.from(doc.scripts).find(value => value.textContent.includes('ytInitialPlayerResponse ='));
        const match = script?.textContent.match(/ytInitialPlayerResponse\s*=\s*(\{.*?\});/s);
        try { if (match) response = JSON.parse(match[1]); } catch (_) {}
      }
      const videoID = new URL(location.href).searchParams.get('v');
      if (videoID && response?.videoDetails?.videoId === videoID) {
        stableProviderIdentity = `youtube:${videoID}`;
        const options = response.captions?.playerCaptionsTracklistRenderer?.captionTracks || [];
        const preferred = options.find(value => value.languageCode?.split('-')[0] === languages[0]?.split('-')[0] && value.kind !== 'asr')
          || options.find(value => value.kind !== 'asr') || options[0];
        if (!captionURL && preferred?.baseUrl) {
          const url = new URL(preferred.baseUrl, location.href);
          url.searchParams.set('fmt', 'vtt');
          captionURL = url.href;
          languageCode = preferred.languageCode || null;
        }
      }
    }
    return {
      documentURL: location.href, documentID, title: doc.title || '',
      mediaURL: source || null, mediaIdentity: `${identities.get(node)}:${source}`, stableProviderIdentity,
      duration: Number.isFinite(node.duration) && node.duration > 0 ? node.duration : null,
      languageCode, webVTT, captionURL,
      mimeType: node.getAttribute('type') || node.querySelector('source[type]')?.type || ''
    };
  };
}
return JSON.stringify(doc.__manabiTranscriptCapture());
