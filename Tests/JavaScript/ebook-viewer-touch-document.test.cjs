'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const test = require('node:test')

const source = fs.readFileSync(process.env.MANABI_EBOOK_VIEWER_SOURCE
    || path.resolve(__dirname, '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-viewer.js'), 'utf8')
const clockSource = fs.readFileSync(path.resolve(__dirname,
    '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/reader-document-clock.js'), 'utf8')
    .replace('export function readerDocumentStartedAtMs', 'function readerDocumentStartedAtMs')
function declaration(first, last) {
    const start = source.indexOf(first), end = source.indexOf(last, start)
    if (start < 0 || end <= start) throw new Error(`Missing production declaration ${first}`)
    return source.slice(start, end)
}
const posting = source.includes('const touchPostingDocument =')
    ? declaration('const touchPostingDocument =', 'const resetRestoreTransactionGlobals =')
    : ''
const motion = declaration('const requestLookupCloseForPageMotion =', 'const resolveFoliatePaginator =')
const main = declaration('        const postNoElementNavigationTouchStart =', '        const clearPendingMainDocumentBlankNavigationTouch =')
const content = declaration('            const postContentDocumentBlankPointerTap =', '            const handleBlankPointerTouchStart =')

function fixture() {
    const posts = [], document = { body: { classList: { contains: () => false } } }
    const childDocument = { body: { classList: { contains: () => false } } }
    const window = { document, performance: { timeOrigin: 12345 },
        webkit: { messageHandlers: { touchstartCallbackHandler: { postMessage: p => posts.push(p) } } } }
    const context = vm.createContext({ window, document, doc: childDocument, Date, Number,
        WeakSet, Object, Math, globalThis: window,
        lastPostedMainDocumentBlankTouchTap: null, lastPostedBlankTouchTap: null,
        shouldSuppressMainDocumentSyntheticMouseBlankTap: () => false,
        shouldSuppressSyntheticMouseBlankTap: () => false,
        manabiEventScreenPoint: event => event,
        touchPointForBlankPointer: event => event,
        segmentTargetForBlankPointerEvent: () => null })
    vm.runInContext(clockSource + posting + motion + main + content + `
        window.publishMotion = requestLookupCloseForPageMotion
        window.publishMain = postNoElementNavigationTouchStart
        window.publishContent = postContentDocumentBlankPointerTap`, context)
    return { posts, document, childDocument, window }
}

for (const route of ['Motion', 'Main', 'Content']) {
    function publish(f) {
        if (route === 'Motion') f.window.publishMotion('renderer.goTo')
        else f.window[`publish${route}`]({ type: 'mousedown', screenX: 4, screenY: 5,
            target: { nodeType: 1, closest: () => null } }, `test-${route}`, 100)
    }
    test(`${route} publisher carries its immutable posting-window clock`, () => {
        const f = fixture()
        publish(f)
        assert.equal(f.posts.length, 1)
        assert.equal(f.posts[0].documentStartedAtMs, 12345)
        assert.equal(f.posts[0].touchedEntryWithElementId, null)
        assert.equal(f.posts[0].wasAlreadySelected, false)
        assert.equal(f.childDocument.manabiDocumentStartedAtMs, undefined,
            'forwarded child events belong to the viewer native posting frame')
        const descriptor = Object.getOwnPropertyDescriptor(f.document, 'manabiDocumentStartedAtMs')
        assert.equal(descriptor.writable, false)
        assert.equal(descriptor.configurable, false)
    })
    test(`${route} retained publisher cannot borrow a replacement document clock`, () => {
        const f = fixture()
        f.window.document = {}
        f.window.performance = { timeOrigin: 67890 }
        publish(f)
        assert.equal(f.posts.length, 0)
        assert.equal(f.window.document.manabiDocumentStartedAtMs, undefined)
    })
}
