const doc = document;
const capture = doc.__manabiTranscriptCapture;
const isCurrent = value => document === doc && value && value.documentID === expectedDocumentID
  && value.mediaIdentity === expectedMediaIdentity && value.documentURL === expectedDocumentURL;
const snapshot = capture?.();
if (!isCurrent(snapshot)) return null;
if (snapshot.webVTT) return snapshot.webVTT;
if (!snapshot.captionURL) return null;
const url = new URL(snapshot.captionURL);
if (!['http:', 'https:'].includes(url.protocol)) return null;
const controller = new AbortController();
const timer = setTimeout(() => controller.abort(), 10000);
try {
  const response = await fetch(url.href, { credentials: 'same-origin', signal: controller.signal });
  if (!response.ok || !isCurrent(capture?.())) return null;
  const text = await response.text();
  if (!isCurrent(capture?.()) || !/^\uFEFF?WEBVTT(?:\s|$)/.test(text)) return null;
  return text;
} catch (_) {
  return null;
} finally {
  clearTimeout(timer);
}
