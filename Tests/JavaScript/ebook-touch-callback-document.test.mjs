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
const childGestureBlock = source.slice(childStart,
    source.indexOf('\n        }\n        const restorePositionTrackingCleanup', childStart))
const documentLikeStart = source.indexOf('const isDocumentLike =')
const documentLike = source.slice(documentLikeStart,
    source.indexOf('const visibleRangeForNavigationHUDDocument =', documentLikeStart))
const posterStart = source.indexOf('this.#postTouchstartCallback = createReaderTouchstartPoster(')
if (posterStart < 0) throw new Error('Missing production Reader poster assignment')
const posterAssignment = source.slice(posterStart, source.indexOf(';', posterStart) + 1)

const thresholdStart = source.indexOf('const manabiSyntheticTouchMouseDistanceThreshold =')
const syntheticThreshold = source.slice(thresholdStart, source.indexOf(';', thresholdStart) + 1)
const moveThresholdStart = source.indexOf('const manabiBlankNavigationMoveThreshold =')
const moveThreshold = source.slice(moveThresholdStart, source.indexOf(';', moveThresholdStart) + 1)

const wrapper = `
${declaration('manabiEventScreenPoint')}
${syntheticThreshold}
${moveThreshold}
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
    ${method('listenInDocumentScope')}
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
    childGestures(doc) {
        const scope = this.#beginDocumentScope({doc});
        ${childGestureBlock}
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

// Supply only the event target surface. Registration, gesture state, movement
// checks, admission and suppression all execute the shipping child code above.
function gestureFixture() {
    const f = fixture()
    const listeners = new Map()
    f.child.addEventListener = (type, listener, options) => {
        const registrations = listeners.get(type) ?? []
        registrations.push({ listener, options })
        listeners.set(type, registrations)
    }
    f.child.removeEventListener = (type, listener) => {
        listeners.set(type, (listeners.get(type) ?? []).filter(entry => entry.listener !== listener))
    }
    let now = 1000
    f.context.Date = { now: () => ++now }
    const wrapperProducer = f.reader.childGestures(f.child)
    const targets = Object.fromEntries(['blank', 'excluded', 'segment'].map(kind => {
        const target = { nodeType: 1, closest(selector) {
            if (kind === 'segment' && (selector === 'm-m, .m-m' || selector.startsWith('a, button,'))) return target
            if (kind === 'excluded' && selector.startsWith('a, button,')) return target
            return null
        } }
        return [kind, target]
    }))
    const event = (type, { target = 'blank', x = 10, y = 20, client = false } = {}) => {
        const point = client ? { clientX: x, clientY: y } : { screenX: x, screenY: y }
        return { type, target: targets[target], composedPath: () => [],
            ...(type.startsWith('touch') ? { changedTouches: [point] } : point) }
    }
    const dispatch = event => {
        for (const { listener } of [...(listeners.get(event.type) ?? [])]) listener(event)
    }
    return { ...f, listeners, wrapperProducer, gestureEvent: event, dispatch,
        send(type, options) { dispatch(event(type, options)) },
    }
}

for (const target of ['excluded', 'segment']) {
    test(`shipping child wrappers suppress one retargeted blank mouse after ${target} touchend`, () => {
        const f = gestureFixture()
        f.send('touchstart', { target: target === 'segment' ? 'segment' : 'blank' })
        f.send('touchend', { target })
        assert.equal(f.messages.length, 0, 'the original target does not publish a blank touch')
        f.send('mousedown')
        assert.equal(f.messages.length, 0, 'the matching retargeted mouse is suppressed')
        f.send('mousedown')
        assert.equal(f.messages.length, 1, 'suppression is consumed exactly once')
        assert.equal(f.messages[0].source, 'content-document.blank.mouse')
        assert.equal(f.messages[0].touchstartEventType, 'mousedown')
        assert.equal(f.messages[0].documentStartedAtMs, 101)
    })
}

test('shipping child registrations retain a normal blank touch and suppress its mouse once', () => {
    const f = gestureFixture()
    assert.deepEqual([...f.listeners.keys()], ['touchstart', 'touchmove', 'touchend', 'touchcancel', 'mousedown'])
    for (const registrations of f.listeners.values()) {
        assert.equal(registrations.length, 1)
        assert.equal(registrations[0].options.capture, true)
        assert.equal(registrations[0].options.passive, true)
    }
    f.send('touchstart')
    f.send('touchend')
    assert.equal(f.messages.length, 1)
    assert.equal(f.messages[0].source, 'content-document.blank')
    assert.equal(f.messages[0].touchstartEventType, 'touchend')
    f.send('mousedown')
    assert.equal(f.messages.length, 1)
    f.send('mousedown')
    assert.equal(f.messages.length, 2)
    assert.equal(f.messages[1].touchstartEventType, 'mousedown')
})

for (const ending of ['move', 'end-moved', 'cancel', 'excluded-start']) {
    test(`shipping child ${ending} gesture does not suppress a subsequent blank mouse`, () => {
        const f = gestureFixture()
        f.send('touchstart', { target: ending === 'excluded-start' ? 'excluded' : 'blank' })
        if (ending === 'move') f.send('touchmove', { x: 100, y: 100 })
        f.send(ending === 'cancel' ? 'touchcancel' : 'touchend', {
            target: 'excluded', ...(ending === 'end-moved' ? { x: 100, y: 100 } : {}),
        })
        assert.equal(f.messages.length, 0)
        f.send('mousedown')
        assert.equal(f.messages.length, 1, 'an uncompleted tap cannot arm synthetic-mouse suppression')
    })
}

test('shipping child fallback admits a far mouse and consumes the prior touch receipt', () => {
    const f = gestureFixture()
    f.send('touchstart')
    f.send('touchend', { target: 'excluded' })
    f.send('mousedown', { x: 100, y: 100 })
    assert.equal(f.messages.length, 1, 'a distant mouse is valid input')
    f.send('mousedown')
    assert.equal(f.messages.length, 2, 'the admitted far mouse consumed the old fallback')
})

for (const target of ['excluded', 'segment']) {
    test(`shipping child latest ${target} gesture supersedes an older posted blank-touch receipt`, () => {
        const f = gestureFixture()
        f.send('touchstart')
        f.send('touchend')
        assert.equal(f.messages.length, 1)
        const laterPoint = { x: 90, y: 91 }
        f.send('touchstart', { ...laterPoint, target: target === 'segment' ? 'segment' : 'blank' })
        f.send('touchend', { ...laterPoint, target })
        assert.equal(f.messages.length, 1, 'the later target does not publish a blank touch')
        f.send('mousedown', laterPoint)
        assert.equal(f.messages.length, 1, 'the latest physical gesture supplies the matching suppression point')
        f.send('mousedown', laterPoint)
        assert.equal(f.messages.length, 2, 'the latest receipt is consumed exactly once')
    })
}

test('shipping child wrappers use client coordinates when touch screen coordinates are absent', () => {
    const f = gestureFixture()
    f.send('touchstart', { client: true })
    f.send('touchend', { target: 'excluded', client: true })
    f.send('mousedown', { client: true })
    assert.equal(f.messages.length, 0, 'client-coordinate fallback suppresses the matching mouse')
    f.send('mousedown', { client: true })
    assert.equal(f.messages.length, 1)
})

for (const replacement of ['parent', 'child', 'reader']) {
    test(`shipping child rejected wrapper touchend cannot arm suppression across ${replacement} replacement`, () => {
        const f = gestureFixture()
        f.send('touchstart')
        if (replacement === 'parent') f.window.document = makeDocument()
        else if (replacement === 'child') f.childWindow.document = makeDocument()
        else f.context.reader = {}
        f.send('touchend', { target: 'excluded' })
        assert.equal(f.messages.length, 0)
        f.window.document = f.document
        f.childWindow.document = f.child
        f.context.reader = f.reader
        f.send('mousedown')
        assert.equal(f.messages.length, 1, 'the rejected wrapper did not create a future suppression receipt')
    })
}

for (const replacement of ['parent', 'child', 'scope', 'reader', 'closed']) {
    test(`shipping child touchend coordinate reentry rejects ${replacement} retirement before fallback commit`, () => {
        const f = gestureFixture()
        f.send('touchstart')
        const end = f.gestureEvent('touchend', { target: 'excluded' })
        const retainedMouse = f.listeners.get('mousedown')[0].listener
        let retired = false
        Object.defineProperty(end.changedTouches[0], 'screenX', {
            get() {
                retired = true
                if (replacement === 'parent') f.window.document = makeDocument()
                else if (replacement === 'child') f.childWindow.document = makeDocument()
                else if (replacement === 'scope') f.reader.retireChild(f.child)
                else if (replacement === 'reader') f.context.reader = {}
                else f.reader.closeOwner()
                return 10
            },
        })
        f.dispatch(end)
        assert.equal(retired, true, 'the shipping coordinate helper crossed the getter')
        assert.equal(f.messages.length, 0)
        if (replacement === 'closed' || replacement === 'scope') {
            // Retained listeners must still fail closed after removal/closure.
            retainedMouse(f.gestureEvent('mousedown'))
            assert.equal(f.messages.length, 0)
        } else {
            f.window.document = f.document
            f.childWindow.document = f.child
            f.context.reader = f.reader
            f.send('mousedown')
            assert.equal(f.messages.length, 1, 'retirement during point extraction did not poison a later valid mouse')
        }
    })
}

test('shipping child scope cleanup removes registrations and retained old wrappers cannot affect the successor', () => {
    const f = gestureFixture()
    f.send('touchstart')
    const oldEnd = f.listeners.get('touchend')[0].listener
    f.reader.retireChild(f.child)
    for (const registrations of f.listeners.values()) assert.equal(registrations.length, 0)
    f.reader.childGestures(f.child)
    oldEnd(f.gestureEvent('touchend', { target: 'excluded' }))
    f.send('mousedown')
    assert.equal(f.messages.length, 1, 'a retired registration cannot suppress successor input')
})

for (const replacement of ['parent', 'child', 'reader']) {
    test(`shipping child rejected start neither seeds nor erases a gesture across ${replacement} replacement`, () => {
        for (const hasPending of [false, true]) {
            const f = gestureFixture()
            if (hasPending) f.send('touchstart')
            if (replacement === 'parent') f.window.document = makeDocument()
            else if (replacement === 'child') f.childWindow.document = makeDocument()
            else f.context.reader = {}
            f.send('touchstart', { x: 90, y: 91 })
            f.window.document = f.document
            f.childWindow.document = f.child
            f.context.reader = f.reader
            f.send('touchend', { target: 'segment', ...(hasPending ? {} : { x: 90, y: 91 }) })
            f.send('mousedown', hasPending ? {} : { x: 90, y: 91 })
            assert.equal(f.messages.length, hasPending ? 0 : 1,
                `a rejected start ${hasPending ? 'preserved the original' : 'did not seed a'} pending gesture`)
        }
    })
    for (const type of ['touchmove', 'touchcancel']) {
        test(`shipping child rejected ${type} preserves the pending gesture across ${replacement} replacement`, () => {
            const f = gestureFixture()
            f.send('touchstart')
            if (replacement === 'parent') f.window.document = makeDocument()
            else if (replacement === 'child') f.childWindow.document = makeDocument()
            else f.context.reader = {}
            f.send(type, { x: 100, y: 100 })
            f.window.document = f.document
            f.childWindow.document = f.child
            f.context.reader = f.reader
            f.send('touchend', { target: 'segment' })
            f.send('mousedown')
            assert.equal(f.messages.length, 0, 'the rejected callback did not erase the owned pending gesture')
            f.send('mousedown')
            assert.equal(f.messages.length, 1)
        })
    }
}

for (const boundary of ['target', 'coordinate', 'throw']) {
    test(`shipping child nested start survives an older start ${boundary} getter`, () => {
        const f = gestureFixture()
        const olderStart = f.gestureEvent('touchstart')
        let recursed = false
        const replace = () => {
            if (!recursed) {
                recursed = true
                f.send('touchstart', { x: 90, y: 91 })
            }
        }
        if (boundary === 'target') {
            olderStart.target = { nodeType: 1, closest() { replace(); return null } }
        } else {
            Object.defineProperty(olderStart.changedTouches[0], 'screenX', {
                get() { replace(); if (boundary === 'throw') throw new Error('aborted older start'); return 10 },
            })
        }
        f.dispatch(olderStart)
        assert.equal(recursed, true)
        f.send('touchend', { target: 'segment', x: 90, y: 91 })
        f.send('mousedown', { x: 90, y: 91 })
        assert.equal(f.messages.length, 0, 'the outer start did not replace or erase the nested pending gesture')
        f.send('mousedown', { x: 90, y: 91 })
        assert.equal(f.messages.length, 1)
    })
}

for (const boundary of ['coordinate', 'target', 'handler']) {
    test(`shipping child newer completed touch survives an older touchend ${boundary} getter`, () => {
        const f = gestureFixture()
        f.send('touchstart')
        const olderEnd = f.gestureEvent('touchend')
        let recursed = false
        const replace = () => {
            if (!recursed) {
                recursed = true
                f.send('touchstart', { x: 90, y: 91 })
                f.send('touchend', { target: 'segment', x: 90, y: 91 })
            }
        }
        if (boundary === 'coordinate') {
            Object.defineProperty(olderEnd.changedTouches[0], 'screenX', {
                get() { replace(); return 10 },
            })
        } else if (boundary === 'target') {
            olderEnd.target = { nodeType: 1, closest() { replace(); return null } }
        } else {
            const handlers = f.window.webkit.messageHandlers
            const handler = handlers.touchstartCallbackHandler
            Object.defineProperty(handlers, 'touchstartCallbackHandler', {
                get() { replace(); return handler },
            })
        }
        f.dispatch(olderEnd)
        assert.equal(recursed, true)
        assert.equal(f.messages.length, 0, 'the superseded blank touch did not publish')
        f.send('mousedown', { x: 90, y: 91 })
        assert.equal(f.messages.length, 0, 'the newer completed touch retained its fallback receipt')
        f.send('mousedown', { x: 90, y: 91 })
        assert.equal(f.messages.length, 1)
    })
}

for (const type of ['touchmove', 'touchcancel']) {
    test(`shipping child nested start survives an older ${type} getter`, () => {
        const f = gestureFixture()
        f.send('touchstart')
        const event = f.gestureEvent(type, { x: 100, y: 100 })
        let recursed = false
        const replace = () => {
            if (!recursed) {
                recursed = true
                f.send('touchstart', { x: 90, y: 91 })
            }
        }
        if (type === 'touchmove') {
            Object.defineProperty(event.changedTouches[0], 'screenX', {
                get() { replace(); return 100 },
            })
        } else {
            Object.defineProperty(event, 'type', { get() { replace(); return type } })
        }
        // Invoke the actual retained callback directly so the dispatcher's type
        // lookup does not trigger the cancellation getter before entry.
        f.listeners.get(type)[0].listener(event)
        assert.equal(recursed, true)
        f.send('touchend', { target: 'segment', x: 90, y: 91 })
        f.send('mousedown', { x: 90, y: 91 })
        assert.equal(f.messages.length, 0, 'the older callback did not clear the nested pending gesture')
        f.send('mousedown', { x: 90, y: 91 })
        assert.equal(f.messages.length, 1)
    })
}

for (const type of ['touchstart', 'touchmove', 'touchend']) {
    test(`shipping child malformed ${type} aborts only its pending gesture`, () => {
        const f = gestureFixture()
        if (type !== 'touchstart') f.send('touchstart')
        const event = f.gestureEvent(type)
        Object.defineProperty(event.changedTouches[0], 'screenX', {
            get() { throw new Error('malformed touch coordinates') },
        })
        assert.doesNotThrow(() => f.dispatch(event))
        f.send('touchend', { target: 'segment' })
        f.send('mousedown')
        assert.equal(f.messages.length, 1, 'an aborted gesture did not leave a usable pending tap')
    })
}

for (const type of ['touchstart', 'touchmove', 'touchend']) {
    test(`shipping child nested start during ${type} entry ownership check retains its pending gesture`, () => {
        const f = gestureFixture()
        f.send('touchstart')
        let recursed = false
        Object.defineProperty(f.context, 'reader', {
            configurable: true,
            get() {
                if (!recursed) {
                    recursed = true
                    f.send('touchstart', { x: 90, y: 91 })
                }
                return f.reader
            },
        })
        f.send(type, type === 'touchmove' ? { x: 100, y: 100 } : {})
        assert.equal(recursed, true, 'the actual ownership check crossed the Reader getter')
        assert.equal(f.messages.length, 0, 'the older event did not complete the nested gesture')
        f.send('touchend', { target: 'segment', x: 90, y: 91 })
        f.send('mousedown', { x: 90, y: 91 })
        assert.equal(f.messages.length, 0, 'the nested gesture retained its pending coordinates')
        f.send('mousedown', { x: 90, y: 91 })
        assert.equal(f.messages.length, 1)
    })
}

test('shipping child commit ownership getter cannot overwrite a newer completed gesture receipt', () => {
    const f = gestureFixture()
    let key
    let armed = false
    let recursed = false
    Object.defineProperty(f.child, '__manabiLastBlankPointerPostKey', {
        configurable: true,
        get() { return key },
        set(value) {
            key = value
            if (!recursed) armed = true
        },
    })
    Object.defineProperty(f.context, 'reader', {
        configurable: true,
        get() {
            if (armed && !recursed) {
                armed = false
                recursed = true
                f.send('touchstart', { x: 90, y: 91 })
                f.send('touchend', { x: 90, y: 91 })
            }
            return f.reader
        },
    })
    f.send('touchstart')
    f.send('touchend')
    assert.equal(recursed, true, 'the commit key setter armed the subsequent ownership getter')
    assert.equal(f.messages.length, 1, 'only the newer completed touch published')
    assert.equal(f.messages[0].touchstartEventType, 'touchend')
    const echo = f.context.__manabiPendingContentDocumentBlankNavigationEcho
    assert.equal(echo?.x, 90, 'the old commit preserved the newer navigation echo')
    assert.equal(echo?.y, 91)
    f.send('mousedown', { x: 90, y: 91 })
    assert.equal(f.messages.length, 1, 'the old commit preserved the newer matching suppression receipt')
    f.send('mousedown', { x: 90, y: 91 })
    assert.equal(f.messages.length, 2)
})

test('child producer final private gesture check preserves a newer wrapper touch after ownership getter reentry', () => {
    const f = gestureFixture()
    let key
    let commitStage = false
    let armReader = false
    let recursed = false
    let outerGestureCurrent = true
    Object.defineProperty(f.child, '__manabiLastBlankPointerPostKey', {
        configurable: true,
        get() { return key },
        set(value) {
            key = value
            if (!recursed) commitStage = true
        },
    })
    Object.defineProperty(f.context, 'reader', {
        configurable: true,
        get() {
            if (armReader && !recursed) {
                armReader = false
                recursed = true
                f.send('touchstart', { x: 90, y: 91 })
                f.send('touchend', { x: 90, y: 91 })
                outerGestureCurrent = false
            }
            return f.reader
        },
    })
    // Use the producer's internal gesture-admission seam to arm the final
    // posting-owner getter after the key setter, without counting getter reads.
    // The newer touch itself uses the actual registered shipping wrappers.
    const isOuterGestureCurrent = () => {
        if (commitStage && !recursed) armReader = true
        return outerGestureCurrent
    }
    f.wrapperProducer(f.gestureEvent('touchend'), 'content-document.blank', 777,
        isOuterGestureCurrent)
    assert.equal(recursed, true, 'the final posting-owner getter completed the newer wrapper touch')
    assert.equal(outerGestureCurrent, false)
    assert.equal(f.messages.length, 1, 'only the newer wrapper touch published')
    assert.equal(f.messages[0].touchstartEventType, 'touchend')
    const echo = f.context.__manabiPendingContentDocumentBlankNavigationEcho
    assert.equal(echo?.x, 90, 'the superseded producer did not overwrite the newer echo')
    assert.equal(echo?.y, 91)
    f.send('mousedown', { x: 90, y: 91 })
    assert.equal(f.messages.length, 1, 'the newer matching suppression receipt survived the old commit')
    f.send('mousedown', { x: 90, y: 91 })
    assert.equal(f.messages.length, 2, 'the newer receipt was consumed exactly once')
})

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

for (const replacement of ['scope', 'reader']) {
    test(`child commit key setter cannot overwrite ${replacement} successor echo`, () => {
        const f = fixture()
        const content = f.makeChildProducer()
        const successorEcho = { x: 90, y: 91, source: 'successor' }
        let key = 'previous-key'
        let setterCalls = 0
        Object.defineProperty(f.child, '__manabiLastBlankPointerPostKey', {
            configurable: true,
            get() { return key },
            set() {
                setterCalls++
                if (replacement === 'scope') f.reader.retireChild(f.child)
                else f.context.reader = {}
                key = 'successor-key'
                f.context.__manabiPendingContentDocumentBlankNavigationEcho = successorEcho
            },
        })
        content({ ...f.event(), type: 'touchend' }, 'content-document.blank', 77)
        assert.equal(setterCalls, 1, 'the actual commit crossed the page-visible setter')
        assert.equal(f.messages.length, 0, 'retired owner did not reach the native bridge')
        assert.equal(f.child.__manabiLastBlankPointerPostKey, 'successor-key')
        assert.equal(f.context.__manabiPendingContentDocumentBlankNavigationEcho, successorEcho,
            'old commit did not overwrite successor echo')
    })
}

test('an admitted child touchend suppresses its matching mouse callback once', () => {
    const f = fixture()
    const content = f.makeChildProducer()
    content({ ...f.event(), type: 'touchend' }, 'content-document.blank', 77)
    assert.equal(f.messages.length, 1)
    content(f.event(), 'content-document.blank', 78)
    assert.equal(f.messages.length, 1)
    content(f.event(), 'content-document.blank', 79)
    assert.equal(f.messages.length, 2)
    assert.equal(f.messages[1].touchstartEventType, 'mousedown')
})

for (const producer of ['main', 'child']) {
    test(`${producer} coordinate getter retirement preserves prior touch suppression`, () => {
        const f = fixture()
        const content = producer === 'child' ? f.makeChildProducer() : f.main
        const source = producer === 'child' ? 'content-document.blank' : 'main-document.blank'
        content({ ...f.event(), type: 'touchend' }, source, 77)
        assert.equal(f.messages.length, 1)
        const rejectedMouse = f.event()
        Object.defineProperty(rejectedMouse, 'screenX', {
            get() {
                if (producer === 'child') f.childWindow.document = makeDocument()
                else f.window.document = makeDocument()
                return 10
            },
        })
        content(rejectedMouse, source, 78)
        assert.equal(f.messages.length, 1)
        f.window.document = f.document
        f.childWindow.document = f.child
        content(f.event(), source, 79)
        assert.equal(f.messages.length, 1)
        content(f.event(), source, 80)
        assert.equal(f.messages.length, 2)
    })
}

for (const producer of ['main', 'child']) {
    test(`${producer} later hidden-state getter retirement preserves unconsumed touch suppression`, () => {
        const f = fixture()
        const content = producer === 'child' ? f.makeChildProducer() : f.main
        const source = producer === 'child' ? 'content-document.blank' : 'main-document.blank'
        const postingDocument = producer === 'child' ? f.child : f.document
        content({ ...f.event(), type: 'touchend' }, source, 77)
        assert.equal(f.messages.length, 1)
        postingDocument.body.classList.contains = () => {
            if (producer === 'child') f.childWindow.document = makeDocument()
            else f.window.document = makeDocument()
            return false
        }
        content({ ...f.event(), screenX: 100, screenY: 100 }, source, 78)
        assert.equal(f.messages.length, 1, 'later reentry rejects the far mouse')
        f.window.document = f.document
        f.childWindow.document = f.child
        postingDocument.body.classList.contains = () => false
        content(f.event(), source, 79)
        assert.equal(f.messages.length, 1, 'rejected far mouse did not consume the original tap')
        content(f.event(), source, 80)
        assert.equal(f.messages.length, 2, 'first owned matching mouse consumed suppression once')
    })
}

test('explicit touch-capability mouse retains main suppression but consumes child suppression', () => {
    for (const producer of ['main', 'child']) {
        const f = fixture()
        const content = producer === 'child' ? f.makeChildProducer() : f.main
        const source = producer === 'child' ? 'content-document.blank' : 'main-document.blank'
        content({ ...f.event(), type: 'touchend' }, source, 77)
        assert.equal(f.messages.length, 1)
        content({ ...f.event(), sourceCapabilities: { firesTouchEvents: true } }, source, 78)
        assert.equal(f.messages.length, 1)
        content(f.event(), source, 79)
        assert.equal(f.messages.length, producer === 'child' ? 2 : 1)
        content(f.event(), source, 80)
        assert.equal(f.messages.length, producer === 'child' ? 3 : 2)
    }
})

// Append unchanged to ebook-touch-callback-document.test.mjs so these cases
// execute its actual shipping producers, scope guards and point helpers.
for (const producer of ['main', 'child']) {
    test(`${producer} coordinate reentry preserves a newer current touch suppression receipt`, () => {
        const f = fixture()
        const post = producer === 'main' ? f.main : f.makeChildProducer()
        const source = producer === 'main' ? 'main-document.blank' : 'content-document.blank'
        post({ ...f.event(), type: 'touchend' }, source, 1)
        assert.equal(f.messages.length, 1)

        let recursed = false
        const olderMouse = f.event()
        Object.defineProperty(olderMouse, 'screenX', {
            get() {
                if (!recursed) {
                    recursed = true
                    post({ ...f.event(), type: 'touchend', screenX: 90, screenY: 91 }, source, 3)
                }
                return 10
            },
        })
        post(olderMouse, source, 2)
        assert.equal(recursed, true, 'the actual coordinate helper invoked the getter')
        assert.equal(f.messages.length, 2, 'both touches posted and the older matching mouse was suppressed')
        assert.deepEqual(f.messages.map(message => message.touchstartAtMs), [1, 3])

        post({ ...f.event(), screenX: 90, screenY: 91 }, source, 4)
        assert.equal(f.messages.length, 2, 'the newer touch must retain suppression for its own matching mouse')
        post({ ...f.event(), screenX: 90, screenY: 91 }, source, 5)
        assert.equal(f.messages.length, 3, 'the newer matching mouse suppression is consumed exactly once')
        assert.equal(f.messages[2].touchstartAtMs, 5)
        assert.equal(f.messages[2].touchstartEventType, 'mousedown')
        assert.equal(f.messages[2].documentStartedAtMs, 101)
    })
}

for (const producer of ['main', 'child']) {
    test(`${producer} admitted far mouse preserves a newer current touch suppression receipt`, () => {
        const f = fixture()
        const post = producer === 'main' ? f.main : f.makeChildProducer()
        const source = producer === 'main' ? 'main-document.blank' : 'content-document.blank'
        post({ ...f.event(), type: 'touchend' }, source, 1)
        assert.equal(f.messages.length, 1)

        let recursed = false
        const olderFarMouse = { ...f.event(), screenY: 100 }
        Object.defineProperty(olderFarMouse, 'screenX', {
            get() {
                if (!recursed) {
                    recursed = true
                    post({ ...f.event(), type: 'touchend', screenX: 90, screenY: 91 }, source, 3)
                }
                return 100
            },
        })
        post(olderFarMouse, source, 2)
        assert.equal(recursed, true, 'the actual coordinate helper invoked the getter')
        assert.equal(f.messages.length, 3, 'both touches and the still-current far mouse must post')
        assert.deepEqual(f.messages.map(message => message.touchstartAtMs), [1, 3, 2])
        assert.equal(f.messages[2].touchstartEventType, 'mousedown')
        if (producer === 'child') {
            assert.equal(f.child.__manabiLastBlankPointerPostKey, `${source}:mousedown:2:100:100`)
            assert.equal(f.context.__manabiPendingContentDocumentBlankNavigationEcho, null)
        }

        post({ ...f.event(), screenX: 90, screenY: 91 }, source, 4)
        assert.equal(f.messages.length, 3, 'admitting the far mouse must preserve the newer touch suppression')
        post({ ...f.event(), screenX: 90, screenY: 91 }, source, 5)
        assert.equal(f.messages.length, 4, 'the newer matching mouse suppression is consumed exactly once')
        assert.equal(f.messages[3].touchstartAtMs, 5)
        assert.equal(f.messages[3].touchstartEventType, 'mousedown')
        assert.equal(f.messages[3].documentStartedAtMs, 101)
    })
}
