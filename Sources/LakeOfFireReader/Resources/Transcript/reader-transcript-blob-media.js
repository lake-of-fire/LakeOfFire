const doc = document
const reply = value => JSON.stringify(value)
const failure = error => reply({ status: 'error', error })
const validID = typeof transferID === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(transferID)
if (!validID || !['open', 'read', 'close'].includes(operation)) return failure('invalidRequest')
if (!doc.__manabiTranscriptBlobTransfers) doc.__manabiTranscriptBlobTransfers = new Map()
const transfers = doc.__manabiTranscriptBlobTransfers
// Closed tokens cannot be reopened by an already queued native invocation.
// Retain at most 1024 identities per physical document, then seal admission
// rather than evicting a fence and permitting an obsolete open.
if (!doc.__manabiTranscriptBlobClosed) doc.__manabiTranscriptBlobClosed = new Set()
const closed = doc.__manabiTranscriptBlobClosed
const retire = () => {
  if (closed.size < 1024) closed.add(transferID)
  else doc.__manabiTranscriptBlobSealed = true
}
const capture = doc.__manabiTranscriptCapture
const expected = [
  typeof expectedDocumentID === 'string' ? expectedDocumentID : null,
  typeof expectedMediaIdentity === 'string' ? expectedMediaIdentity : null,
  typeof expectedDocumentURL === 'string' ? expectedDocumentURL : null,
  typeof expectedMediaURL === 'string' ? expectedMediaURL : null
]
const sameExpected = record => record.expected.every((value, index) => value === expected[index])
const current = value => document === doc && value && value.documentID === expectedDocumentID
  && value.mediaIdentity === expectedMediaIdentity && value.documentURL === expectedDocumentURL
  && value.mediaURL === expectedMediaURL
const dispose = async record => {
  record.closed = true
  record.controller.abort()
  for (const [view, listener] of record.listeners || []) view.removeEventListener('pagehide', listener)
  record.listeners = []
  if (!record.cleanup || record.cleanupReader !== record.reader) {
    record.cleanupReader = record.reader
    const reader = record.reader
    record.cleanup = (async () => {
    try { await reader?.cancel() } catch (_) {}
    try { reader?.releaseLock() } catch (_) {}
    record.pending = null
    })()
  }
  await record.cleanup
}
const stop = async record => {
  record.cancelled = true
  await dispose(record)
  try { await record.inFlight } catch (_) {}
  // Fetch can return headers after retirement but before observing abort.
  await dispose(record)
  if (transfers.get(transferID) === record) transfers.delete(transferID)
}
if (operation === 'close') {
  retire()
  const record = transfers.get(transferID)
  if (record) {
    await stop(record)
  }
  return reply({ status: 'ok', transferID })
}
if (!expected.every(value => typeof value === 'string' && value.length > 0)
    || !Number.isSafeInteger(maximumByteCount) || maximumByteCount <= 0 || maximumByteCount > 536870912
    || !Number.isSafeInteger(chunkByteCount) || chunkByteCount <= 0 || chunkByteCount > 262144) return failure('invalidRequest')
let record = transfers.get(transferID)
if (operation === 'open') {
  if (closed.has(transferID)) return failure('cancelled')
  if (doc.__manabiTranscriptBlobSealed || transfers.size >= 16 || record) return failure('busy')
  if (!current(capture?.())) return failure('staleSelection')
  let url
  try { url = new URL(expectedMediaURL) } catch (_) { return failure('unsupportedSource') }
  if (url.protocol !== 'blob:') return failure('unsupportedSource')
  record = { expected, controller: new AbortController(), closed: false, reader: null,
    offset: 0, received: 0, pending: null, length: null, maximumByteCount, chunkByteCount }
  transfers.set(transferID, record)
} else {
  if (!record || record.closed) return failure('cancelled')
  if (!sameExpected(record) || maximumByteCount !== record.maximumByteCount || chunkByteCount !== record.chunkByteCount
      || !Number.isSafeInteger(offset) || offset !== record.offset) return failure('invalidRequest')
  if (record.inFlight) return failure('busy')
}
const work = async () => {
  const check = () => {
    if (record.closed) throw 'cancelled'
    if (!current(capture?.())) throw 'staleSelection'
  }
  try {
    check()
    if (operation === 'open') {
      const response = await capture((snapshot, view) => {
        if (!current(snapshot)) return null
        const pageHidden = () => {
          if (transfers.get(transferID) !== record || record.closed) return
          retire()
          // Retirement/abort happen synchronously; the retained barrier joins
          // pending headers/read and late response cleanup without native JS.
          record.lifecycleCompletion = stop(record)
        }
        record.listeners = []
        for (const owner of new Set([doc.defaultView, view])) {
          if (typeof owner?.addEventListener === 'function') {
            owner.addEventListener('pagehide', pageHidden)
            record.listeners.push([owner, pageHidden])
          }
        }
        check()
        return view.fetch(expectedMediaURL, { signal: record.controller.signal, credentials: 'same-origin' })
      })
      if (!response) throw 'staleSelection'
      // Own the body before checking cancellation so even late headers are closed.
      if (response.body) record.reader = response.body.getReader()
      check()
      if (!response.ok || !record.reader) throw 'unreadableMedia'
      const declared = response.headers.get('Content-Length')
      if (declared !== null) {
        if (!/^\d+$/.test(declared) || !Number.isSafeInteger(Number(declared))) throw 'unreadableMedia'
        record.length = Number(declared)
        if (record.length > record.maximumByteCount) throw 'tooLarge'
        if (record.length === 0) throw 'emptyMedia'
      }
      const mimeType = (response.headers.get('Content-Type') || '').split(';')[0].trim().toLowerCase()
      return reply({ status: 'ok', transferID, mimeType, byteLength: record.length })
    }
    const start = record.offset
    const parts = []
    let count = 0
    let done = false
    while (count < record.chunkByteCount) {
      check()
      if (!record.pending?.byteLength) {
        const next = await record.reader.read()
        check()
        if (next.done) {
          if (record.received === 0) throw 'emptyMedia'
          if (record.length !== null && record.received !== record.length) throw 'incompleteMedia'
          done = true
          break
        }
        if (Object.prototype.toString.call(next.value) !== '[object Uint8Array]') throw 'unreadableMedia'
        record.received += next.value.byteLength
        if (record.received > record.maximumByteCount) throw 'tooLarge'
        if (record.length !== null && record.received > record.length) throw 'incompleteMedia'
        record.pending = next.value
        if (!record.pending.byteLength) continue
      }
      const take = Math.min(record.pending.byteLength, record.chunkByteCount - count)
      parts.push(record.pending.subarray(0, take))
      record.pending = record.pending.subarray(take)
      count += take
    }
    check()
    let binary = ''
    for (const part of parts) {
      for (const byte of part) binary += String.fromCharCode(byte)
    }
    record.offset += count
    if (done) {
      await dispose(record)
      checkCompleted()
      if (transfers.get(transferID) === record) transfers.delete(transferID)
    }
    return reply({ status: 'ok', transferID, offset: start, base64: btoa(binary), done })
  } catch (error) {
    const code = typeof error === 'string' ? error : record.cancelled ? 'cancelled' : 'unreadableMedia'
    await dispose(record)
    if (transfers.get(transferID) === record) transfers.delete(transferID)
    return failure(code)
  }
}
// Completion must validate selection after asynchronous reader cancellation too.
const checkCompleted = () => {
  if (record.cancelled) throw 'cancelled'
  if (!current(capture?.())) throw 'staleSelection'
}
const pending = work()
record.inFlight = pending
try { return await pending }
finally { if (record.inFlight === pending) record.inFlight = null }
