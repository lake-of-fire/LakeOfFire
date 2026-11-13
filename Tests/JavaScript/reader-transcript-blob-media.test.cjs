const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const { randomUUID } = require('node:crypto')
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
const source = fs.readFileSync(path.join(__dirname, '../../Sources/LakeOfFireReader/Resources/Transcript/reader-transcript-blob-media.js'), 'utf8')
const names = ['document', 'operation', 'transferID', 'expectedDocumentID', 'expectedMediaIdentity', 'expectedDocumentURL', 'expectedMediaURL', 'offset', 'maximumByteCount', 'chunkByteCount']
const evaluate = new AsyncFunction(...names, source)
const gate = () => {
  let resolve
  const promise = new Promise(done => { resolve = done })
  return { promise, resolve }
}
class ObservedWindow extends EventTarget {
  constructor() { super(); this.pagehideListeners = new Set() }
  addEventListener(type, listener, options) {
    super.addEventListener(type, listener, options)
    if (type === 'pagehide') this.pagehideListeners.add(listener)
  }
  removeEventListener(type, listener, options) {
    super.removeEventListener(type, listener, options)
    if (type === 'pagehide') this.pagehideListeners.delete(listener)
  }
}
function fixture(fetcher = async () => new Response(new Blob(['audio bytes'], { type: 'audio/wav' }))) {
  const snapshot = { documentID: 'physical-document', mediaIdentity: 'physical-frame-node-source', documentURL: 'https://article.example/read', mediaURL: 'blob:https://child.example/media' }
  const owner = Object.assign(new ObservedWindow(), { fetch: fetcher })
  const doc = { defaultView: new ObservedWindow(), __manabiTranscriptCapture: callback => typeof callback === 'function' ? callback({ ...snapshot }, owner) : { ...snapshot } }
  const expected = { ...snapshot }
  const call = (operation, id, extra = {}) => evaluate(doc, operation, id,
    extra.expectedDocumentID ?? expected.documentID, extra.expectedMediaIdentity ?? expected.mediaIdentity,
    extra.expectedDocumentURL ?? expected.documentURL, extra.expectedMediaURL ?? expected.mediaURL,
    extra.offset ?? 0, extra.maximumByteCount ?? 536870912, extra.chunkByteCount ?? 4).then(JSON.parse)
  return { doc, snapshot, owner, call }
}
async function collect(f, id, options = {}) {
  const parts = []
  let offset = 0
  for (;;) {
    const result = await f.call('read', id, { ...options, offset })
    assert.equal(result.status, 'ok', JSON.stringify(result))
    assert.equal(result.transferID, id)
    assert.equal(result.offset, offset)
    const bytes = Buffer.from(result.base64, 'base64')
    assert.ok(bytes.length <= (options.chunkByteCount ?? 4))
    parts.push(bytes)
    offset += bytes.length
    if (result.done) return Buffer.concat(parts)
  }
}

test('actual Blob bytes cross bounded chunks and EOF exactly, without object URL revocation', async () => {
  const bytes = Uint8Array.from({ length: 257 }, (_, i) => i % 256)
  let requested
  const blobURL = URL.createObjectURL(new Blob([bytes], { type: 'audio/wav' }))
  const f = fixture(async (url, options) => { requested = url; return fetch(url, options) })
  f.snapshot.mediaURL = blobURL
  // Expected selection is frozen by fixture creation, so use explicit URL on every call.
  const id = randomUUID()
  const options = { expectedMediaURL: blobURL, chunkByteCount: 17 }
  assert.equal((await f.call('open', id, options)).status, 'ok')
  const parts = []
  let offset = 0
  for (;;) {
    const r = await f.call('read', id, { ...options, offset })
    assert.equal(r.status, 'ok')
    assert.equal(r.offset, offset)
    const part = Buffer.from(r.base64, 'base64')
    assert.ok(part.length <= 17)
    parts.push(part)
    offset += part.length
    if (r.done) break
  }
  assert.deepEqual(Buffer.concat(parts), Buffer.from(bytes))
  assert.equal(requested, blobURL)
  assert.equal((await f.call('close', id)).status, 'ok')
  assert.deepEqual(Buffer.from(await (await fetch(blobURL)).arrayBuffer()), Buffer.from(bytes))
  URL.revokeObjectURL(blobURL)
})

test('selected owning child window is the fetch receiver', async () => {
  let receiver
  const f = fixture(async function () { receiver = this; return new Response(new Blob(['child'], { type: 'audio/ogg' })) })
  const id = randomUUID()
  assert.equal((await f.call('open', id)).mimeType, 'audio/ogg')
  assert.equal(receiver, f.owner)
  assert.equal((await collect(f, id)).toString(), 'child')
})

test('declared length is checked against actual EOF and exact positive control', async () => {
  for (const [declared, expected] of [['3', 'incompleteMedia'], ['9', 'incompleteMedia'], ['0', 'emptyMedia'], ['bad', 'unreadableMedia'], ['4', null]]) {
    const f = fixture(async () => new Response('1234', { headers: { 'Content-Length': declared } }))
    const id = randomUUID()
    const opened = await f.call('open', id)
    if (['0', 'bad'].includes(declared)) { assert.equal(opened.error, expected); continue }
    assert.equal(opened.byteLength, Number(declared))
    const first = await f.call('read', id)
    if (declared === '3') assert.equal(first.error, expected)
    else {
      assert.equal(first.status, 'ok')
      const end = await f.call('read', id, { offset: 4 })
      if (expected) assert.equal(end.error, expected)
      else assert.deepEqual(end, { status: 'ok', transferID: id, offset: 4, base64: '', done: true })
    }
    await f.call('close', id)
  }
})

test('empty unknown-length stream and declared/streamed size limits reject', async () => {
  for (const [body, headers, maximumByteCount, error] of [['', {}, 8, 'emptyMedia'], ['123456789', {}, 8, 'tooLarge'], ['1', { 'Content-Length': '9' }, 8, 'tooLarge']]) {
    const f = fixture(async () => new Response(body, { headers }))
    const id = randomUUID()
    const opened = await f.call('open', id, { maximumByteCount })
    const result = opened.status === 'error' ? opened : await f.call('read', id, { maximumByteCount })
    assert.equal(result.error, error)
    assert.equal(f.doc.__manabiTranscriptBlobTransfers.size, 0)
  }
})

test('revoked/unreadable blob, bad status and absent bodies fail, allowing fresh retry', async () => {
  for (const fetcher of [async () => { throw new TypeError('revoked') }, async () => new Response('denied', { status: 404 }), async () => new Response(null)]) {
    const f = fixture(fetcher)
    assert.equal((await f.call('open', randomUUID())).error, 'unreadableMedia')
    f.owner.fetch = async () => new Response(new Blob(['fresh']))
    const next = randomUUID()
    assert.equal((await f.call('open', next)).status, 'ok')
    assert.equal((await collect(f, next)).toString(), 'fresh')
  }
})

test('source replacement while headers are held cancels the unread response body', async () => {
  const headers = gate()
  const started = gate()
  let cancelled = 0
  const f = fixture(async () => { started.resolve(); await headers.promise; return new Response(new ReadableStream({ cancel() { cancelled++ } })) })
  const id = randomUUID()
  const opening = f.call('open', id)
  await started.promise
  f.snapshot.mediaIdentity = 'replacement'
  headers.resolve()
  assert.equal((await opening).error, 'staleSelection')
  assert.equal(cancelled, 1)
  assert.equal(f.doc.__manabiTranscriptBlobTransfers.size, 0)
})

test('replacement during pending stream read rejects bytes and joins cancellation', async () => {
  let streamController
  let cancelled = 0
  const f = fixture(async () => new Response(new ReadableStream({ start(c) { streamController = c }, cancel() { cancelled++ } })))
  const id = randomUUID()
  await f.call('open', id)
  const reading = f.call('read', id)
  f.snapshot.mediaURL = 'blob:https://child.example/replaced'
  streamController.enqueue(new Uint8Array([1, 2]))
  assert.equal((await reading).error, 'staleSelection')
  assert.equal(cancelled, 1)
})

test('close joins pending read and its held underlying cancellation', async () => {
  const cancellation = gate()
  const cancelled = gate()
  const f = fixture(async () => new Response(new ReadableStream({ cancel() { cancelled.resolve(); return cancellation.promise } })))
  const id = randomUUID()
  await f.call('open', id)
  const reading = f.call('read', id)
  let finished = false
  const closing = f.call('close', id).then(value => { finished = true; return value })
  await cancelled.promise
  assert.equal(finished, false)
  cancellation.resolve()
  assert.equal((await reading).error, 'cancelled')
  assert.equal((await closing).status, 'ok')
  assert.equal(f.doc.__manabiTranscriptBlobTransfers.size, 0)
})

test('close joins late headers even when the fetch implementation ignores abort', async () => {
  const headers = gate()
  const started = gate()
  let cancelled = 0
  const f = fixture(async () => { started.resolve(); await headers.promise; return new Response(new ReadableStream({ cancel() { cancelled++ } })) })
  const id = randomUUID()
  const opening = f.call('open', id)
  await started.promise
  let finished = false
  const closing = f.call('close', id).then(value => { finished = true; return value })
  await Promise.resolve()
  assert.equal(finished, false)
  headers.resolve()
  assert.equal((await opening).error, 'cancelled')
  await closing
  assert.equal(cancelled, 1)
})

test('close before open tombstones a token; duplicate close remains harmless', async () => {
  let fetched = 0
  const f = fixture(async () => { fetched++; return new Response('wrong') })
  const id = randomUUID()
  await f.call('close', id)
  await f.call('close', id)
  assert.equal((await f.call('open', id)).error, 'cancelled')
  assert.equal((await f.call('read', id)).error, 'cancelled')
  assert.equal(fetched, 0)
})

test('bounded tombstones seal admission rather than evict obsolete-token fences', async () => {
  const f = fixture()
  const first = randomUUID()
  await f.call('close', first)
  for (let i = 0; i < 1024; i++) await f.call('close', randomUUID())
  assert.equal(f.doc.__manabiTranscriptBlobClosed.size, 1024)
  assert.equal((await f.call('open', first)).error, 'cancelled')
  assert.equal((await f.call('open', randomUUID())).error, 'busy')
})

test('closing an obsolete transfer cannot cancel its concurrent successor', async () => {
  const f = fixture()
  const old = randomUUID()
  const next = randomUUID()
  await f.call('open', old)
  await f.call('open', next)
  await f.call('close', old)
  assert.equal((await collect(f, next)).toString(), 'audio bytes')
})

test('overlapping reads are busy; offsets and per-transfer parameters are exact', async () => {
  let controller
  const f = fixture(async () => new Response(new ReadableStream({ start(c) { controller = c } })))
  const id = randomUUID()
  await f.call('open', id)
  assert.equal((await f.call('read', id, { offset: 1 })).error, 'invalidRequest')
  assert.equal((await f.call('read', id, { chunkByteCount: 8 })).error, 'invalidRequest')
  const reading = f.call('read', id)
  assert.equal((await f.call('read', id)).error, 'busy')
  controller.enqueue(new Uint8Array([1, 2, 3, 4]))
  assert.equal((await reading).base64, 'AQIDBA==')
  await f.call('close', id)
})

test('cross-realm byte chunks are accepted without weakening byte-array validation', async () => {
  const bytes = vm.runInNewContext('new Uint8Array([1, 2, 3])')
  const f = fixture(async () => new Response(new ReadableStream({ start(c) { c.enqueue(bytes); c.close() } })))
  const id = randomUUID()
  await f.call('open', id)
  assert.deepEqual(await collect(f, id), Buffer.from([1, 2, 3]))
})

test('invalid requests, nonblob sources, and stale selection do not dispatch fetch', async () => {
  let fetched = 0
  const f = fixture(async () => { fetched++; return new Response('no') })
  assert.equal((await f.call('open', 'not-a-uuid')).error, 'invalidRequest')
  assert.equal((await f.call('open', randomUUID(), { maximumByteCount: 536870913 })).error, 'invalidRequest')
  assert.equal((await f.call('open', randomUUID(), { chunkByteCount: 262145 })).error, 'invalidRequest')
  assert.equal((await f.call('open', randomUUID(), { expectedMediaIdentity: 'old' })).error, 'staleSelection')
  f.snapshot.mediaURL = 'https://child.example/audio.wav'
  assert.equal((await f.call('open', randomUUID(), { expectedMediaURL: f.snapshot.mediaURL })).error, 'unsupportedSource')
  assert.equal(fetched, 0)
})

test('close needs only operation and token arguments, including before capture exists', async () => {
  const closeOnly = new AsyncFunction('document', 'operation', 'transferID', source)
  const doc = {}
  const id = randomUUID()
  assert.deepEqual(JSON.parse(await closeOnly(doc, 'close', id)), { status: 'ok', transferID: id })
  assert.ok(doc.__manabiTranscriptBlobClosed.has(id))
})

for (const surface of ['root', 'child']) {
  test(`${surface} pagehide retires pending headers and joins late response cleanup`, async () => {
    const headers = gate()
    const started = gate()
    const cancellation = gate()
    const cancelled = gate()
    let signal
    const f = fixture(async (_url, options) => {
      signal = options.signal
      started.resolve()
      await headers.promise
      return new Response(new ReadableStream({ cancel() { cancelled.resolve(); return cancellation.promise } }))
    })
    const id = randomUUID()
    const opening = f.call('open', id)
    await started.promise
    const record = f.doc.__manabiTranscriptBlobTransfers.get(id)
    assert.equal(f.owner.pagehideListeners.size, 1)
    assert.equal(f.doc.defaultView.pagehideListeners.size, 1)
    const view = surface === 'root' ? f.doc.defaultView : f.owner
    view.dispatchEvent(new Event('pagehide'))
    assert.equal(signal.aborted, true)
    assert.equal(record.closed, true)
    assert.ok(f.doc.__manabiTranscriptBlobClosed.has(id))
    assert.equal(f.owner.pagehideListeners.size, 0)
    assert.equal(f.doc.defaultView.pagehideListeners.size, 0)
    let joined = false
    record.lifecycleCompletion.then(() => { joined = true })
    headers.resolve()
    await cancelled.promise
    assert.equal(joined, false)
    cancellation.resolve()
    assert.equal((await opening).error, 'cancelled')
    await record.lifecycleCompletion
    assert.equal(f.doc.__manabiTranscriptBlobTransfers.size, 0)
    assert.equal((await f.call('open', id)).error, 'cancelled')
    f.owner.fetch = async () => new Response(new Blob(['retry']))
    const next = randomUUID()
    assert.equal((await f.call('open', next)).status, 'ok')
    assert.equal((await collect(f, next)).toString(), 'retry')
    assert.equal(f.owner.pagehideListeners.size, 0)
    assert.equal(f.doc.defaultView.pagehideListeners.size, 0)
  })

  test(`${surface} pagehide retires a pending read without native close`, async () => {
    const cancellation = gate()
    const cancelled = gate()
    const f = fixture(async () => new Response(new ReadableStream({ cancel() { cancelled.resolve(); return cancellation.promise } })))
    const id = randomUUID()
    await f.call('open', id)
    const record = f.doc.__manabiTranscriptBlobTransfers.get(id)
    const reading = f.call('read', id)
    const view = surface === 'root' ? f.doc.defaultView : f.owner
    view.dispatchEvent(new Event('pagehide'))
    await cancelled.promise
    let joined = false
    record.lifecycleCompletion.then(() => { joined = true })
    assert.equal(joined, false)
    cancellation.resolve()
    assert.equal((await reading).error, 'cancelled')
    await record.lifecycleCompletion
    assert.equal(f.doc.__manabiTranscriptBlobTransfers.size, 0)
    assert.equal(f.owner.pagehideListeners.size, 0)
    assert.equal(f.doc.defaultView.pagehideListeners.size, 0)
  })
}

test('predecessor child pagehide cannot retire a successor owned by another child', async () => {
  const headers = gate()
  const started = gate()
  const f = fixture(async () => { started.resolve(); await headers.promise; return new Response('old') })
  const old = randomUUID()
  const opening = f.call('open', old)
  await started.promise
  const oldRecord = f.doc.__manabiTranscriptBlobTransfers.get(old)
  const nextOwner = Object.assign(new ObservedWindow(), { fetch: async () => new Response(new Blob(['successor'])) })
  f.snapshot.mediaIdentity = 'successor-physical-child'
  f.doc.__manabiTranscriptCapture = callback => typeof callback === 'function' ? callback({ ...f.snapshot }, nextOwner) : { ...f.snapshot }
  const next = randomUUID()
  const options = { expectedMediaIdentity: f.snapshot.mediaIdentity }
  assert.equal((await f.call('open', next, options)).status, 'ok')
  f.owner.dispatchEvent(new Event('pagehide'))
  headers.resolve()
  assert.equal((await opening).error, 'cancelled')
  await oldRecord.lifecycleCompletion
  f.owner.dispatchEvent(new Event('pagehide'))
  assert.equal((await collect(f, next, options)).toString(), 'successor')
  assert.equal(nextOwner.pagehideListeners.size, 0)
  assert.equal(f.doc.defaultView.pagehideListeners.size, 0)
})

test('all terminal paths remove pagehide listeners, with root/owner deduplication', async () => {
  for (const outcome of ['eof', 'close', 'error']) {
    const f = fixture(async () => new Response('bytes', { headers: outcome === 'error' ? { 'Content-Length': '0' } : {} }))
    f.doc.defaultView = f.owner
    const id = randomUUID()
    const opened = await f.call('open', id)
    if (outcome === 'error') assert.equal(opened.error, 'emptyMedia')
    else {
      assert.equal(f.owner.pagehideListeners.size, 1)
      if (outcome === 'eof') await collect(f, id)
      else await f.call('close', id)
    }
    assert.equal(f.owner.pagehideListeners.size, 0)
    assert.equal(f.doc.__manabiTranscriptBlobTransfers.size, 0)
  }
})

test('pagehide releases an idle opened transfer without a later native invocation', async () => {
  let cancelled = 0
  const f = fixture(async () => new Response(new ReadableStream({ cancel() { cancelled++ } })))
  const id = randomUUID()
  await f.call('open', id)
  const record = f.doc.__manabiTranscriptBlobTransfers.get(id)
  f.owner.dispatchEvent(new Event('pagehide'))
  assert.equal(record.closed, true)
  await record.lifecycleCompletion
  assert.equal(cancelled, 1)
  assert.equal(f.doc.__manabiTranscriptBlobTransfers.size, 0)
  assert.equal(f.owner.pagehideListeners.size, 0)
  assert.equal(f.doc.defaultView.pagehideListeners.size, 0)
})
