import assert from 'node:assert/strict'
import test from 'node:test'

import {
    boundedRenderabilityAnchorSegment,
    visibleSegmentProbeAcceptsIdentity,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-renderability-segment-probe.js'

test('semantic visible-segment probes require stable identity while geometry-only probes do not', () => {
    assert.equal(visibleSegmentProbeAcceptsIdentity({
        includeSegmentMetadata: true,
        segmentIdentifier: null,
    }), false)
    assert.equal(visibleSegmentProbeAcceptsIdentity({
        includeSegmentMetadata: true,
        segmentIdentifier: 'stable-segment',
    }), true)
    assert.equal(visibleSegmentProbeAcceptsIdentity({
        includeSegmentMetadata: false,
        segmentIdentifier: null,
    }), true)
})

test('bounded renderability anchor prefers the visible-range segment without a document scan', () => {
    const direct = { id: 'direct' }
    let bodyQueries = 0
    const startElement = {
        nodeType: 1,
        closest: selector => selector === 'm-m' ? direct : null,
        querySelector: () => {
            throw new Error('descendant query should not run')
        },
    }
    const doc = {
        body: {
            querySelector() {
                bodyQueries += 1
                return { id: 'body' }
            },
        },
    }

    assert.equal(
        boundedRenderabilityAnchorSegment(doc, { startContainer: startElement }),
        direct
    )
    assert.equal(bodyQueries, 0)
})

test('bounded renderability anchor falls back to one descendant or one body candidate', () => {
    const descendant = { id: 'descendant' }
    const body = { id: 'body' }

    assert.equal(
        boundedRenderabilityAnchorSegment(
            { body: { querySelector: () => body } },
            {
                startContainer: {
                    nodeType: 1,
                    closest: () => null,
                    querySelector: selector => selector === 'm-m' ? descendant : null,
                },
            }
        ),
        descendant
    )

    assert.equal(
        boundedRenderabilityAnchorSegment(
            { body: { querySelector: selector => selector === 'm-m' ? body : null } },
            { startContainer: { nodeType: 1, closest: () => null, querySelector: () => null } }
        ),
        body
    )

    assert.equal(
        boundedRenderabilityAnchorSegment(
            { body: { querySelector: () => null } },
            null
        ),
        null
    )
})
