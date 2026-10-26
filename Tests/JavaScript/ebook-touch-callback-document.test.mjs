import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import { readerDocumentStartedAtMs } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/reader-document-clock.js'

const source = readFileSync(new URL(
    '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-viewer.js', import.meta.url
), 'utf8')

// Execute the shipping producers and their private scope guards together. The
// wrapper supplies only state controls and unrelated geometry collaborators.
function blockEnd(opening) {
    let depth = 0
    let quote = null
    let lineComment = false
    let blockComment = false
    for (let index = opening; index < source.length; index++) {
        const char = source[index]
        const next = source[index + 1]
        if (lineComment) {
            if (char === '\n') lineComment = false
        } else if (blockComment) {
            if (char === '*' && next === '/') { blockComment = false; index++ }
        } else if (quote) {
            if (char === '\\') index++
            else if (char === quote) quote = null
        } else if (char === '/' && next === '/') {
            lineComment = true
            index++
        } else if (char === '/' && next === '*') {
            blockComment = true
            index++
        } else if (char === '"' || char === "'" || char === '`') {
            quote = char
        } else if (char === '{') {
            depth++
        } else if (char === '}' && --depth === 0) {
            return index + 1
        }
    }
    throw new Error('Unterminated production declaration')
}

function declaration(name) {
    const start = source.indexOf(`const ${name} =`)
    if (start < 0) throw new Error(`Missing production declaration ${name}`)
    const opening = source.indexOf('=> {', start) + 3
    return source.slice(start, blockEnd(opening)) + ';'
}

function method(name) {
    const start = source.indexOf(`    #${name}(`)
    if (start < 0) throw new Error(`Missing production method ${name}`)
    let depth = 0
    let closing = source.indexOf('(', start)
    for (; closing < source.length; closing++) {
        if (source[closing] === '(') depth++
        if (source[closing] === ')' && --depth === 0) break
    }
    return source.slice(start, blockEnd(source.indexOf('{', closing)))
}

const mainStart = source.indexOf('        let pendingMainDocumentBlankNavigationTouch =')
const mainProducer = declaration('postNoElementNavigationTouchStart')
const mainBlock = source.slice(mainStart, source.indexOf(mainProducer.slice(0, -1), mainStart)
    + mainProducer.length)
const childStart = source.indexOf('            let pendingBlankPointerTap =')
const childProducer = declaration('postContentDocumentBlankPointerTap')
const childBlock = source.slice(childStart, source.indexOf(childProducer.slice(0, -1), childStart)
    + childProducer.length)
const documentLikeStart = source.indexOf('const isDocumentLike =')
const documentLike = source.slice(documentLikeStart,
    source.indexOf('const visibleRangeForNavigationHUDDocument =', documentLikeStart))
const posterStart = source.indexOf('this.#postTouchstartCallback = createReaderTouchstartPoster(')
if (posterStart < 0) throw new Error('Missing production Reader poster assignment')
const posterAssignment = source.slice(posterStart, source.indexOf(';', posterStart) + 1)

const thresholdStart = source.indexOf('const manabiSyntheticTouchMouseDistanceThreshold =')
const syntheticThreshold = source.slice(thresholdStart, source.indexOf(';', thresholdStart) + 1)

const wrapper = `
${declaration('manabiEventScreenPoint')}
${syntheticThreshold}
${declaration('createReaderTouchstartPoster')}
${declaration('requestLookupCloseForPageMotion')}
${documentLike}
class ReaderProducerFixture {
    #closed = false;
    #lifecycleGeneration = 0;
    #documentScopes = new Map();
    #documentScopeSequence = 0;
    #postTouchstartCallback;
    #didDisplaySequence = 0;
    constructor() { ${posterAssignment} }
    ${method('isLifecycleCurrent')}
    ${method('beginDocumentScope')}
    ${method('isDocumentScopeCurrent')}
    ${method('releaseDocumentScope')}
    ${method('onGoTo')}
    #clearVisiblePageReadChrome() { this.beforePageMotionPost?.(); }
    #invalidateVisiblePageSegmentSnapshot() {}
    setLoadingIndicator() {}
    pageMotion() { this.#onGoTo({detail: {willLoadNewIndex: true}}); }
    mainProducer() {
        ${mainBlock}
        return postNoElementNavigationTouchStart;
    }
    childProducer(doc) {
        const scope = this.#beginDocumentScope({doc});
        ${childBlock}
        return postContentDocumentBlankPointerTap;
    }
    retireChild(doc) { this.#releaseDocumentScope(doc); }
    closeOwner() { this.#closed = true; }
}
globalThis.ReaderProducerFixture = ReaderProducerFixture;
`

function makeDocument() {
    return {
        nodeType: 9,
        querySelectorAll: () => [],
        documentElement: {},
        body: { classList: { contains: () => false } },
        location: { href: 'ebook://ebook/section.xhtml' },
    }
}

function fixture({ origin = 101 } = {}) {
    const document = makeDocument()
    const messages = []
    let currentOrigin = origin
    const window = {
        document,
        performance: { get timeOrigin() { return currentOrigin } },
        webkit: { messageHandlers: { touchstartCallbackHandler: {
            postMessage: message => messages.push(message),
        } } },
    }
    const context = vm.createContext({ window, document, readerDocumentStartedAtMs,
        cancelAnimationFrame() {},
    })
    vm.runInContext(wrapper, context, { filename: 'actual-ebook-viewer-producers.js' })
    const reader = new context.ReaderProducerFixture()
    context.reader = reader
    const child = makeDocument()
    const childWindow = { document: child, performance: { timeOrigin: 303 } }
    child.defaultView = childWindow
    const main = reader.mainProducer()
    const content = reader.childProducer(child)
    let sequence = 0
    const event = () => ({ type: 'mousedown', target: { nodeType: 1, closest: () => null },
        screenX: 10, screenY: 20, composedPath: () => [] })
    const invoke = {
        motion: () => reader.pageMotion(),
        main: () => main(event(), 'main-document.blank', ++sequence),
        child: () => content(event(), 'content-document.blank', ++sequence),
    }
    return { document, window, context, reader, child, childWindow, messages, invoke, main,
        setOrigin(value) { currentOrigin = value },
        makeChildProducer() { return reader.childProducer(child) },
        event,
    }
}

for (const producer of ['motion', 'main', 'child']) {
    test(`${producer} touch producer sends the canonical posting-document stamp after origin drift`, () => {
        const f = fixture()
        f.invoke[producer]()
        assert.equal(f.messages.at(-1)?.documentStartedAtMs, 101)
        f.setOrigin(202)
        f.invoke[producer]()
        assert.equal(f.messages.length, 2)
        assert.equal(f.messages.at(-1).documentStartedAtMs, 101)
        assert.notEqual(f.messages.at(-1).documentStartedAtMs, f.childWindow.performance.timeOrigin)
    })

    test(`${producer} retained callback rejects a replacement parent and permits the original Document to return`, () => {
        const f = fixture()
        assert.equal(readerDocumentStartedAtMs(f.window), 101)
        f.window.document = makeDocument()
        f.setOrigin(202)
        f.invoke[producer]()
        assert.equal(f.messages.length, 0)
        f.window.document = f.document
        f.invoke[producer]()
        assert.equal(f.messages.at(-1)?.documentStartedAtMs, 101)
    })

    test(`${producer} same-document retry accepts a Core stamp established after missing origin`, () => {
        const f = fixture({ origin: Number.NaN })
        f.invoke[producer]()
        assert.equal(f.messages.at(-1)?.documentStartedAtMs, null)
        Object.defineProperty(f.document, 'manabiDocumentStartedAtMs', { value: 404 })
        f.invoke[producer]()
        assert.equal(f.messages.at(-1)?.documentStartedAtMs, 404)
    })
}

test('child producer rejects physical replacement, scope retirement and scope reuse before a fresh registration', () => {
    const f = fixture()
    f.childWindow.document = makeDocument()
    f.invoke.child()
    assert.equal(f.messages.length, 0)
    f.childWindow.document = f.child
    f.reader.retireChild(f.child)
    f.invoke.child()
    assert.equal(f.messages.length, 0)
    const current = f.makeChildProducer()
    f.invoke.child()
    assert.equal(f.messages.length, 0)
    current(f.event(), 'content-document.blank', 999)
    assert.equal(f.messages.at(-1)?.documentStartedAtMs, 101)
})

test('closed or replaced Reader owners cannot publish retained touch callbacks', () => {
    for (const replacement of ['closed', 'reader']) {
        const f = fixture()
        if (replacement === 'closed') f.reader.closeOwner()
        else f.context.reader = {}
        for (const invoke of Object.values(f.invoke)) invoke()
        assert.equal(f.messages.length, 0)
    }
})

test('native handler and postMessage getters cannot relabel callbacks during synchronous reentry', () => {
    for (const producer of ['motion', 'main', 'child']) {
        for (const boundary of ['handler', 'postMessage']) {
            const f = fixture()
            const handler = f.window.webkit.messageHandlers.touchstartCallbackHandler
            if (boundary === 'handler') {
                Object.defineProperty(f.window.webkit.messageHandlers, 'touchstartCallbackHandler', {
                    get() { f.window.document = makeDocument(); return handler },
                })
            } else {
                const postMessage = handler.postMessage
                Object.defineProperty(handler, 'postMessage', {
                    get() { f.window.document = makeDocument(); return postMessage },
                })
            }
            f.invoke[producer]()
            assert.equal(f.messages.length, 0, `${producer} admitted after ${boundary} reentry`)
        }
    }
})

test('conflicting mutable clock properties fail closed for every producer', () => {
    const f = fixture()
    Object.defineProperty(f.document, 'manabiDocumentStartedAtMs', {
        value: 505, writable: true,
    })
    for (const invoke of Object.values(f.invoke)) invoke()
    assert.equal(f.messages.length, 0)
})

test('child source admission is checked again after native bridge getters', () => {
    for (const replacement of ['document', 'scope']) {
        const f = fixture()
        const handlers = f.window.webkit.messageHandlers
        const handler = handlers.touchstartCallbackHandler
        Object.defineProperty(handlers, 'touchstartCallbackHandler', {
            get() {
                if (replacement === 'document') f.childWindow.document = makeDocument()
                else f.reader.retireChild(f.child)
                return handler
            },
        })
        f.invoke.child()
        assert.equal(f.messages.length, 0)
    }
})

test('page-motion chrome reentry cannot publish after its Reader or parent Document retires', () => {
    for (const replacement of ['closed', 'reader', 'document']) {
        const f = fixture()
        f.reader.beforePageMotionPost = () => {
            if (replacement === 'closed') f.reader.closeOwner()
            else if (replacement === 'reader') f.context.reader = {}
            else f.window.document = makeDocument()
        }
        f.invoke.motion()
        assert.equal(f.messages.length, 0)
    }
})

test('retired child callbacks preserve the successor navigation echo and document deduplication key', () => {
    for (const boundary of ['initial', 'closest', 'composedPath', 'body', 'handler', 'postMessage']) {
        for (const replacement of ['closed', 'reader', 'document', 'child', 'scope']) {
            const f = fixture()
            const content = f.makeChildProducer()
            const successorEcho = { x: 90, y: 91, source: 'successor' }
            f.context.__manabiPendingContentDocumentBlankNavigationEcho = successorEcho
            f.child.__manabiLastBlankPointerPostKey = 'successor-key'
            const retire = () => {
                if (replacement === 'closed') f.reader.closeOwner()
                else if (replacement === 'reader') f.context.reader = {}
                else if (replacement === 'document') f.window.document = makeDocument()
                else if (replacement === 'child') f.childWindow.document = makeDocument()
                else f.reader.retireChild(f.child)
            }
            const event = f.event()
            if (boundary === 'initial') retire()
            else if (boundary === 'closest') event.target.closest = () => { retire(); return null }
            else if (boundary === 'composedPath') event.composedPath = () => { retire(); return [] }
            else if (boundary === 'body') f.child.body.classList.contains = () => { retire(); return false }
            else {
                const handlers = f.window.webkit.messageHandlers
                const handler = handlers.touchstartCallbackHandler
                if (boundary === 'handler') {
                    Object.defineProperty(handlers, 'touchstartCallbackHandler', {
                        get() { retire(); return handler },
                    })
                } else {
                    const postMessage = handler.postMessage
                    Object.defineProperty(handler, 'postMessage', {
                        get() { retire(); return postMessage },
                    })
                }
            }
            content(event, 'content-document.blank', 1234)
            assert.equal(f.messages.length, 0, `${boundary}/${replacement} posted`)
            assert.equal(f.child.__manabiLastBlankPointerPostKey, 'successor-key', `${boundary}/${replacement} changed key`)
            assert.equal(f.context.__manabiPendingContentDocumentBlankNavigationEcho, successorEcho,
                `${boundary}/${replacement} changed echo`)
        }
    }
})

test('an admitted child touch commits its deduplication key and navigation echo once', () => {
    const f = fixture()
    const content = f.makeChildProducer()
    const event = { ...f.event(), type: 'touchend' }
    content(event, 'content-document.blank', 77)
    assert.equal(f.messages.length, 1)
    assert.equal(f.child.__manabiLastBlankPointerPostKey, 'content-document.blank:touchend:77:10:20')
    assert.deepEqual(JSON.parse(JSON.stringify(f.context.__manabiPendingContentDocumentBlankNavigationEcho)), {
        x: 10, y: 20, source: 'content-document.blank', touchstartAtMs: 77,
    })
    content(event, 'content-document.blank', 77)
    assert.equal(f.messages.length, 1)
})


test('a rejected main touchend cannot suppress the first mouse retry after its original Document returns', () => {
    const f = fixture()
    f.document.body.classList.contains = () => { f.window.document = makeDocument(); return false }
    f.main({ ...f.event(), type: 'touchend' }, 'main-document.blank', 1)
    assert.equal(f.messages.length, 0)
    f.window.document = f.document
    f.document.body.classList.contains = () => false
    f.main(f.event(), 'main-document.blank', 2)
    assert.equal(f.messages.length, 1)
    assert.equal(f.messages[0].touchstartEventType, 'mousedown')
    assert.equal(f.messages[0].documentStartedAtMs, 101)
})

test('an admitted main touchend still suppresses its matching synthetic mouse event once', () => {
    const f = fixture()
    f.main({ ...f.event(), type: 'touchend' }, 'main-document.blank', 1)
    assert.equal(f.messages.length, 1)
    f.main(f.event(), 'main-document.blank', 2)
    assert.equal(f.messages.length, 1)
    f.main(f.event(), 'main-document.blank', 3)
    assert.equal(f.messages.length, 2)
    assert.equal(f.messages[1].touchstartEventType, 'mousedown')
})
// Append these focused cases to the canonical ebook-touch-callback-document.test.mjs
// in the executor's scratch staging tree; reuse its shipping-production fixture.
// The scope is never released, and the physical original Document is restored.
for (const replacement of ['parent', 'child']) {
    test(`rejected child mouse callback preserves suppression after ${replacement} Document replacement`, () => {
        const f = fixture()
        const content = f.makeChildProducer()
        content({ ...f.event(), type: 'touchend' }, 'content-document.blank', 77)
        assert.equal(f.messages.length, 1)
        const rejectedMouse = f.event()
        Object.defineProperty(rejectedMouse, 'sourceCapabilities', {
            get() {
                if (replacement === 'parent') f.window.document = makeDocument()
                else f.childWindow.document = makeDocument()
                return null
            },
        })
        content(rejectedMouse, 'content-document.blank', 78)
        assert.equal(f.messages.length, 1)
        f.window.document = f.document
        f.childWindow.document = f.child
        content(f.event(), 'content-document.blank', 79)
        assert.equal(f.messages.length, 1,
            `${replacement}: rejected callback must not consume prior touch suppression`)
        content(f.event(), 'content-document.blank', 80)
        assert.equal(f.messages.length, 2,
            `${replacement}: admitted synthetic suppression is consumed exactly once`)
    })
}

test('rejected main mouse callback preserves suppression from an admitted touchend', () => {
    const f = fixture()
    f.main({ ...f.event(), type: 'touchend' }, 'main-document.blank', 77)
    assert.equal(f.messages.length, 1)
    const rejectedMouse = f.event()
    Object.defineProperty(rejectedMouse, 'sourceCapabilities', {
        get() {
            f.window.document = makeDocument()
            return null
        },
    })
    f.main(rejectedMouse, 'main-document.blank', 78)
    assert.equal(f.messages.length, 1)
    f.window.document = f.document
    f.main(f.event(), 'main-document.blank', 79)
    assert.equal(f.messages.length, 1,
        'rejected callback must not consume prior touch suppression')
    f.main(f.event(), 'main-document.blank', 80)
    assert.equal(f.messages.length, 2,
        'admitted synthetic suppression is consumed exactly once')
})
