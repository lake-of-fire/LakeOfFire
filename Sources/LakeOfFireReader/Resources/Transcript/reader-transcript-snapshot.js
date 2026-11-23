const doc = document;
if (!doc.__manabiTranscriptCapture) {
  const uuid = () => globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random()}`;
  const documentID = uuid();
  const identities = new WeakMap();
  const identity = value => {
    if (!value) return null;
    if (!identities.has(value)) identities.set(value, uuid());
    return identities.get(value);
  };
  const timestamp = seconds => {
    const ms = Math.round(Math.max(0, seconds) * 1000);
    return `${String(Math.floor(ms / 3600000)).padStart(2, '0')}:${String(Math.floor(ms / 60000) % 60).padStart(2, '0')}:${String(Math.floor(ms / 1000) % 60).padStart(2, '0')}.${String(ms % 1000).padStart(3, '0')}`;
  };
  const youtubeVideoID = view => {
    const url = new URL(view.location.href)
    const youtube = /(^|\.)youtube\.com$/.test(url.hostname)
    const privateEmbed = /(^|\.)youtube-nocookie\.com$/.test(url.hostname)
    if (!['https:', 'http:'].includes(url.protocol) || (!youtube && !privateEmbed)) return null
    if (youtube && /^\/watch\/?$/.test(url.pathname)) {
      const values = url.searchParams.getAll('v')
      return values.length === 1 && /^[A-Za-z0-9_-]+$/.test(values[0]) ? values[0] : null
    }
    // A path video is authoritative on embed/Shorts routes; a stray `v` query
    // must not select another video. Playlist-only embeds have no URL video ID.
    const match = url.pathname.match(/^\/(embed|shorts)\/([A-Za-z0-9_-]+)\/?$/)
    if (!match || (privateEmbed && match[1] !== 'embed')
        || (match[1] === 'embed' && match[2] === 'videoseries')) return null
    return match[2]
  }
  // Discover each document's light DOM and open shadow trees before its frames.
  // Only the actual root/host/frame ancestry grants access; slots do not create
  // another owner, and closed roots or inaccessible documents are not opened.
  const candidates = () => {
    const result = []
    const visited = new Set()
    const visit = (ownerDocument, path) => {
      if (visited.has(ownerDocument)) return
      const view = ownerDocument.defaultView
      if (!view || view.document !== ownerDocument || !ownerDocument.isConnected) return
      const documentPath = [...path, identity(ownerDocument), view.location.href]
      const frames = []
      const visitRoot = (root, rootPath) => {
        if (visited.has(root)) return
        visited.add(root)
        const belongsToRoot = node => node.isConnected && node.ownerDocument === ownerDocument
          && node.getRootNode() === root
        for (const node of root.querySelectorAll('video, audio')) {
          if (belongsToRoot(node)) {
            result.push({ node, ownerDocument, view, documentPath: rootPath })
          }
        }
        for (const element of root.querySelectorAll('*')) {
          if (!belongsToRoot(element)) continue
          if (element.localName === 'iframe') frames.push({ frame: element, path: rootPath })
          const shadow = element.shadowRoot
          if (shadow?.mode === 'open' && shadow.host === element && shadow.isConnected) {
            visitRoot(shadow, [...rootPath, identity(element), identity(shadow)])
          }
        }
      }
      visitRoot(ownerDocument, documentPath)
      for (const { frame, path: framePath } of frames) {
        if (!frame.isConnected || frame.ownerDocument !== ownerDocument) continue
        try {
          const child = frame.contentDocument
          if (child && child.defaultView?.frameElement === frame) {
            visit(child, [...framePath, identity(frame)])
          }
        } catch (_) { /* Inaccessible documents do not participate. */ }
      }
    }
    visit(doc, [])
    return result
  }
  const mediaSource = node => node.currentSrc || node.src || node.querySelector('source[src]')?.src || ''
  const capture = (withContext, ownedSelection) => {
    if (document !== doc) return null;
    const media = candidates();
    let selected
    if (ownedSelection) {
      const matches = media.filter(({ node, view }) =>
        view.__manabiReaderMediaDocumentID === ownedSelection.scriptDocumentID
          && node.__manabiReaderMediaTagID === ownedSelection.tagID
          && mediaSource(node) === ownedSelection.sourceURL)
      if (matches.length !== 1) return null
      selected = matches[0]
    } else {
      selected = media.find(value => !value.node.paused && !value.node.ended) || media[0]
    }
    if (!selected) return null;
    const { node, ownerDocument, view, documentPath } = selected;
    const source = mediaSource(node)
    const tracks = Array.from(node.textTracks || []).filter(track => ['captions', 'subtitles'].includes(track.kind));
    const languages = view.navigator.languages || [view.navigator.language || ''];
    const normalizeLanguage = value => (value || '').trim().toLowerCase().replace(/_/g, '-')
    const primaryLanguage = language => language.split('-')[0]
    const preferences = languages.map(normalizeLanguage).filter(Boolean)
    const languagePreferenceIndex = language => {
      const primary = primaryLanguage(language)
      return primary ? preferences.findIndex(value => primaryLanguage(value) === primary) : -1
    }
    const rank = track => {
      if (track.mode === 'showing') return -1
      const language = normalizeLanguage(track.language)
      const index = languagePreferenceIndex(language)
      if (index < 0) return preferences.length * 2
      return index * 2 + (language === preferences[index] ? 0 : 1)
    }
    tracks.sort((a, b) => rank(a) - rank(b))
    const track = tracks[0];
    const cues = Array.from(track?.cues || []).filter(cue => Number.isFinite(cue.startTime) && cue.startTime >= 0 && Number.isFinite(cue.endTime) && cue.endTime > cue.startTime && typeof cue.getCueAsHTML === 'function');
    const cueText = cue => cue.getCueAsHTML().textContent.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    const webVTT = cues.length ? 'WEBVTT\n\n' + cues.map(cue => `${timestamp(cue.startTime)} --> ${timestamp(cue.endTime)}\n${cueText(cue)}\n`).join('\n') : null;
    // A selected TextTrack cannot borrow another element's URL or language.
    const trackElement = track
      ? Array.from(node.querySelectorAll('track[src]')).find(element => element.track === track)
      : node.querySelector('track[kind="captions"][src], track[kind="subtitles"][src]');
    let captionURL = trackElement?.src || null;
    let languageCode = track?.language || trackElement?.srclang || null;
    let captionTrackIdentity = identity(track || trackElement);
    let stableProviderIdentity = null;
    // YouTube often exposes provider tracks rather than HTML textTracks.
    // A response from the previous SPA video must never supply captions.
    const videoID = youtubeVideoID(view)
    if (videoID) {
      let response = view.ytInitialPlayerResponse;
      if (!response) {
        const script = Array.from(ownerDocument.scripts).find(value => value.textContent.includes('ytInitialPlayerResponse ='));
        const match = script?.textContent.match(/ytInitialPlayerResponse\s*=\s*(\{.*?\});/s);
        try { if (match) response = JSON.parse(match[1]); } catch (_) {}
      }
      if (response?.videoDetails?.videoId === videoID) {
        stableProviderIdentity = `youtube:${videoID}`;
        const options = response.captions?.playerCaptionsTracklistRenderer?.captionTracks || [];
        const rankProviderTrack = track => {
          const language = normalizeLanguage(track.languageCode)
          const index = languagePreferenceIndex(language)
          if (index < 0) return preferences.length * 4
          const automatic = track.kind === 'asr' ? 2 : 0
          const primaryOnly = language === preferences[index] ? 0 : 1
          return index * 4 + automatic + primaryOnly
        }
        const preferred = options.filter(track => normalizeLanguage(track.languageCode)).sort((a, b) =>
          rankProviderTrack(a) - rankProviderTrack(b) ||
          normalizeLanguage(a.languageCode).localeCompare(normalizeLanguage(b.languageCode)))[0]
        if (!webVTT && !captionURL && preferred?.baseUrl) {
          const url = new URL(preferred.baseUrl, view.location.href);
          url.searchParams.set('fmt', 'vtt');
          captionURL = url.href;
          languageCode = preferred.languageCode || null;
          captionTrackIdentity = JSON.stringify(['youtube', videoID, preferred.vssId || null, preferred.kind || null]);
        }
      }
    }
    const snapshot = {
      documentURL: location.href, documentID, title: doc.title || '',
      mediaDocumentURL: view.location.href,
      mediaURL: source || null, mediaIdentity: JSON.stringify([...documentPath, identity(node), source]), stableProviderIdentity,
      duration: Number.isFinite(node.duration) && node.duration > 0 ? node.duration : null,
      languageCode, webVTT, captionURL,
      captionSelectionIdentity: JSON.stringify([captionTrackIdentity, captionURL, languageCode]),
      mimeType: node.getAttribute('type') || node.querySelector('source[type]')?.type || ''
    };
    // The optional synchronous callback receives this capture's context only;
    // no mutable selected-window slot survives between requests.
    return typeof withContext === 'function' ? withContext(snapshot, view) : snapshot;
  }
  doc.__manabiTranscriptCapture = withContext => capture(withContext)
  doc.__manabiTranscriptCaptureOwned = (selection, withContext) => {
    if (![selection?.scriptDocumentID, selection?.tagID, selection?.sourceURL]
      .every(value => typeof value === 'string' && value.length > 0)) return null
    return capture(withContext, selection)
  }
}
// WebKit invokes this body as an async function. Legacy capture passes no
// arguments and owned capture passes exactly one selector.
if (arguments.length === 0) return JSON.stringify(doc.__manabiTranscriptCapture())
if (arguments.length !== 1) return 'null'
return JSON.stringify(doc.__manabiTranscriptCaptureOwned?.(arguments[0]) ?? null)
