import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import vm from 'node:vm'
import { classifyEbookRenderReadiness } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-render-readiness.js'
import {
    boundedRenderabilityAnchorSegment,
    visibleSegmentProbeAcceptsIdentity,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-renderability-segment-probe.js'
import {
    collectSegmentNodesInVisibleRange,
    collectViewportSampleSegmentNodes,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/visible-segment-collection.js'

// Exercise the actual viewer collector and its real geometry/range helpers.
// Only browser layout inputs and unused semantic sidecar access are substituted.
// No copied collector, source-string behavior assertion or standalone runner.
const source = await readFile(new URL(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-viewer.js', import.meta.url
), 'utf8')
const sourceBlock = (startMarker, endMarker) => {
    const start = source.indexOf(startMarker)
    const end = source.indexOf(endMarker, start + startMarker.length)
    assert.ok(start >= 0 && end > start, 'Viewer declaration boundaries must remain discoverable')
    return source.slice(start, end)
}
const collectorSource = [
    sourceBlock('const isDocumentLike =', '// Sidecar parsing stays'),
    sourceBlock('const rectHasPositiveFiniteSize =', 'const visibleSegmentCollectionDocumentIdentity ='),
    'collectVisibleSegmentNodesFromRange',
].join('\n')
const collect = vm.runInNewContext(collectorSource, {
    performance,
    Node: { ELEMENT_NODE: 1 },
    HTMLIFrameElement: class {},
    boundedRenderabilityAnchorSegment,
    visibleSegmentProbeAcceptsIdentity,
    collectSegmentNodesInVisibleRange,
    collectViewportSampleSegmentNodes,
    segmentIdentifierForNode: () => { throw new Error('Readiness must not load semantic identity') },
    segmentIdentifierAliasesForNode: () => { throw new Error('Readiness must not load aliases') },
    sentenceIdentifierForNode: () => null,
})

const rect = (left, top, width, height) => ({
    left, top, width, height, right: left + width, bottom: top + height,
})
const fixture = (geometry, intersects = true) => {
    const counts = { samples: 0, anchors: 0, ranges: 0, measurements: 0 }
    const segment = {
        nodeType: 1,
        textContent: '短い一文。',
        getAttribute: () => null,
        closest: () => null,
        getBoundingClientRect: () => { counts.measurements += 1; return geometry },
        getClientRects: () => [geometry],
    }
    const doc = {
        nodeType: 9,
        readyState: 'complete',
        URL: 'ebook://test/chapter.xhtml',
        documentElement: { clientWidth: 390, clientHeight: 844 },
        querySelectorAll: () => { throw new Error('Minimal probe must not scan the document') },
        elementFromPoint: () => { counts.samples += 1; return null },
    }
    doc.body = {
        nodeType: 1,
        ownerDocument: doc,
        closest: () => null,
        classList: { contains: () => false },
        querySelector: selector => {
            if (selector !== 'm-m') return null
            counts.anchors += 1
            return segment
        },
    }
    segment.ownerDocument = doc
    const range = {
        collapsed: false,
        commonAncestorContainer: doc.body,
        startContainer: doc.body,
        endContainer: doc.body,
        intersectsNode: () => { counts.ranges += 1; return intersects },
    }
    return { doc, range, counts, segment }
}
const run = (f, includeSegmentMetadata = false) => collect(f.doc, f.range, {
    viewportSampleDensity: 'minimal',
    includeSegmentMetadata,
})

for (const [name, geometry] of [
    ['zero-size', rect(10, 10, 0, 0)],
    ['offscreen', rect(500, 10, 20, 20)],
    ['non-finite', rect(Number.NaN, 10, 20, 20)],
]) {
    test('actual collector rejects ' + name + ' anchor despite broad range intersection', () => {
        const f = fixture(geometry)
        const result = run(f)
        assert.equal(result.segmentCandidateSource, 'minimal-anchor-probe')
        assert.equal(result.visibleSegments.length, 0)
        assert.equal(result.outOfViewportCount, 1)
        assert.equal(classifyEbookRenderReadiness(f.doc, result).outcome, 'empty')
        assert.equal(f.counts.samples, 9)
        assert.equal(f.counts.anchors, 1)
        assert.equal(f.counts.measurements, 1)
        assert.equal(f.counts.ranges, 0)
    })
}

test('actual collector accepts a visible unidentified anchor without sidecar lookup', () => {
    const f = fixture(rect(12, 12, 30, 18))
    const result = run(f)
    assert.equal(result.segmentCandidateSource, 'minimal-anchor-probe')
    assert.equal(result.visibleSegments.length, 1)
    assert.equal(result.visibleSegments[0].node, f.segment)
    assert.equal(result.visibleSegments[0].segmentIdentifier, null)
    assert.equal(classifyEbookRenderReadiness(f.doc, result).outcome, 'ready')
    assert.equal(f.counts.samples, 9)
    assert.equal(f.counts.anchors, 1)
    assert.equal(f.counts.ranges, 1)
})

test('actual collector still rejects visible anchor outside the admitted range', () => {
    const f = fixture(rect(12, 12, 30, 18), false)
    const result = run(f)
    assert.equal(result.visibleSegments.length, 0)
    assert.equal(result.outOfViewportCount, 1)
    assert.equal(f.counts.ranges, 1)
})

test('actual collector does not add an unidentified fallback to semantic collection', () => {
    const f = fixture(rect(12, 12, 30, 18))
    const result = run(f, true)
    assert.equal(result.visibleSegments.length, 0)
    assert.equal(f.counts.samples, 9)
    assert.equal(f.counts.anchors, 0)
    assert.equal(f.counts.measurements, 0)
})
