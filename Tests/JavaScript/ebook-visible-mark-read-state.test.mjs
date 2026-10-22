import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'
import { visibleMarkReadSidecarSelection } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-visible-mark-read-selection.js'

// Execute the complete production page-state builder. Visibility and the native
// sidecar are explicit inputs; no second read-coverage algorithm is modeled.
const source = readFileSync(new URL(
    '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-viewer.js', import.meta.url
), 'utf8')
const normalizationStart = source.indexOf('const normalizeArticleReadingProgress = ')
const normalizationEnd = source.indexOf('const sentenceIdentifierForNode = ', normalizationStart)
const builderStart = source.indexOf('const buildVisiblePageTrackingStates = ')
const builderEnd = source.indexOf('const isZip = ', builderStart)
if (normalizationStart < 0 || normalizationEnd < 0 || builderStart < 0 || builderEnd < 0) {
    throw new Error('Missing production page-state declarations')
}
const buildStates = vm.runInNewContext(
    source.slice(normalizationStart, normalizationEnd)
        + source.slice(builderStart, builderEnd)
        + '\nbuildVisiblePageTrackingStates', {
        visibleMarkReadSidecarSelection,
        stableEbookSegmentIdentityVersion: 1,
        segmentEntryIDsForMetadata: (metadata, lexicon) =>
            lexicon === 'jmdict' ? metadata.j : metadata.n,
        collectVisibleSegmentNodesFromRange() { throw new Error('Unexpected DOM visibility scan') },
        segmentMetadataBootstrap() { throw new Error('Unexpected sidecar reconstruction') },
    }
)

const nameA = { i: 'runtime-a', sid: 'stable-a', sentenceID: 'sentence-name', j: [], n: [456], ns: '名前', x: '名前' }
const nameB = { i: 'runtime-b', sid: 'stable-b', sentenceID: 'sentence-name', j: [], n: [789], ns: '氏名', x: '氏名' }
const word = { i: 'runtime-c', sid: 'stable-c', sentenceID: 'sentence-word', j: [123], n: [], s: '言葉', x: '言葉' }

function page(visibleMetadata, progress, { renderedSentenceID = null } = {}) {
    const metadata = [nameA, nameB, word]
    const bootstrap = {
        byID: new Map(metadata.flatMap(item => [[item.i, item], [item.sid, item]])),
        segmentIDsBySentenceID: new Map([
            ['sentence-name', [nameA.i, nameB.i]],
            ['sentence-word', [word.i]],
        ]),
        sentenceArchive: new Map(),
    }
    const doc = { body: { dataset: { mnbNativeSidecarContentFingerprint: 'native-fingerprint' } },
        location: { href: 'ebook://fixture/chapter.xhtml' } }
    return buildStates(doc, progress, null, {
        segmentMetadataBootstrap: bootstrap,
        visibleSegments: visibleMetadata.map(item => ({
            segmentIdentifier: item.sid,
            segmentIdentifierAliases: [item.sid, item.i],
            sentenceIdentifier: renderedSentenceID ?? item.sentenceID,
        })),
        viewportWidth: 600, viewportHeight: 800,
        totalSegmentCount: metadata.length, hiddenTooltipCount: 0,
        missingIdentifierCount: 0, outOfViewportCount: 0,
    }).states[0]
}

test('native sentence-only name support presents Read without inventing segment support', () => {
    // The native Book presentation intentionally publishes this shape after a
    // format-1 JMnedict-only Mark: sentence support with no vocabulary segments.
    const progress = { readSegmentIdentifiers: [], sentenceIdentifiersRead: ['sentence-name'] }
    const state = page([nameA, nameB], progress)
    assert.equal(state.isRead, true)
    assert.equal(state.shortLabel, 'Read')
    assert.equal(state.unreadVisibleSegmentCount, 0)
    assert.equal(state.hasAnyMarkedReadContent, true)
    assert.equal(state.payload.segments.length, 0)
    assert.equal(state.payload.sentenceIdentifiers.length, 0)
    assert.deepEqual(progress.readSegmentIdentifiers, [])
})

test('sentence and segment support jointly cover the visible page', () => {
    const state = page([nameA, word], {
        readSegmentIdentifiers: [word.sid], sentenceIdentifiersRead: ['sentence-name'],
    })
    assert.equal(state.isRead, true)
    assert.equal(state.unreadVisibleSegmentCount, 0)
})

test('a split sentence remains Read on either page fragment', () => {
    const progress = { readSegmentIdentifiers: [], sentenceIdentifiersRead: ['sentence-name'] }
    for (const fragment of [[nameA], [nameB]]) {
        const state = page(fragment, progress)
        assert.equal(state.isRead, true)
        assert.equal(state.visibleSegmentCount, 1)
        assert.equal(state.payload.segments.length, 0)
    }
})

test('unrelated sentence support cannot mark the visible sentence read', () => {
    const state = page([nameA], {
        readSegmentIdentifiers: [], sentenceIdentifiersRead: ['sentence-word'],
    })
    assert.equal(state.isRead, false)
    assert.equal(state.unreadVisibleSegmentCount, 1)
    assert.deepEqual(Array.from(state.payload.segments, segment => segment.stableSegmentID), [nameA.sid])
    assert.equal(state.payload.sentenceIdentifiers.length, 0)
})

test('native sidecar sentence identity owns coverage rather than rendered sentence attributes', () => {
    const progress = { readSegmentIdentifiers: [], sentenceIdentifiersRead: ['sentence-name'] }
    assert.equal(page([nameA], progress, { renderedSentenceID: 'unrelated-rendered-sentence' }).isRead, true)
    assert.equal(page([word], progress, { renderedSentenceID: 'sentence-name' }).isRead, false)
})

test('a read segment does not invent completion for the unseen sentence remainder', () => {
    const progress = { readSegmentIdentifiers: [nameA.sid], sentenceIdentifiersRead: [] }
    assert.equal(page([nameA], progress).isRead, true)
    const remainder = page([nameB], progress)
    assert.equal(remainder.isRead, false)
    assert.deepEqual(Array.from(remainder.payload.segments, segment => segment.stableSegmentID), [nameB.sid])
    assert.equal(remainder.payload.sentenceIdentifiers.length, 0)
})

test('withdrawn sentence support restores Mark Read on the next native projection', () => {
    const marked = page([nameA], { readSegmentIdentifiers: [], sentenceIdentifiersRead: ['sentence-name'] })
    assert.equal(marked.isRead, true)
    const unmarked = page([nameA], { readSegmentIdentifiers: [], sentenceIdentifiersRead: [] })
    assert.equal(unmarked.isRead, false)
    assert.equal(unmarked.shortLabel, 'Mark Read')
    assert.equal(unmarked.hasAnyMarkedReadContent, false)
    assert.equal(unmarked.payload.segments.length, 1)
})
