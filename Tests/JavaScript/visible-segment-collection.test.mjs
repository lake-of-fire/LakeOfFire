import test from 'node:test'
import assert from 'node:assert/strict'

import {
    collectSegmentNodesInVisibleRange,
    collectViewportSampleSegmentNodes,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/visible-segment-collection.js'

const makeSegment = (id, order) => ({
    id,
    nodeType: 1,
    matches: selector => selector === 'mnb-seg',
    closest(selector) {
        if (selector === 'mnb-seg') return this
        if (selector === 'mnb-sen') return this.sentence ?? null
        return null
    },
    compareDocumentPosition(other) {
        return order < other.order ? 4 : (order > other.order ? 2 : 0)
    },
    order,
})

test('range traversal returns only intersecting Yomitan segments without a document query', () => {
    const segments = Array.from({ length: 11 }, (_, index) => makeSegment(`segment-${index}`, index))
    let documentQueryCount = 0
    const doc = {
        querySelectorAll() {
            documentQueryCount += 1
            return []
        },
        createTreeWalker(_root, _whatToShow, filter) {
            const accepted = segments.filter(node => filter.acceptNode(node) === 1)
            let index = 0
            return { nextNode: () => accepted[index++] ?? null }
        },
    }
    const root = { nodeType: 1, ownerDocument: doc, matches: () => false }
    const range = {
        commonAncestorContainer: root,
        intersectsNode: node => node.order >= 3 && node.order <= 7,
    }

    assert.deepEqual(collectSegmentNodesInVisibleRange(range).map(node => node.id), [
        'segment-3',
        'segment-4',
        'segment-5',
        'segment-6',
        'segment-7',
    ])
    assert.equal(documentQueryCount, 0)
})

test('normal viewport sampling includes nearby tiny segments in document order', () => {
    const segments = Array.from({ length: 10 }, (_, index) => makeSegment(`segment-${index}`, index))
    const sentence = { children: segments }
    for (const segment of segments) segment.sentence = sentence
    let sampleCount = 0
    const doc = {
        elementFromPoint() {
            sampleCount += 1
            return segments[5]
        },
    }

    const result = collectViewportSampleSegmentNodes(doc, {
        left: 0,
        top: 0,
        right: 390,
        bottom: 844,
    })

    assert.equal(sampleCount, 42)
    assert.deepEqual(result.map(node => node.id), segments.slice(1).map(node => node.id))
})

test('minimal viewport sampling has a fixed nine-point and eight-candidate budget', () => {
    const segments = Array.from({ length: 9 }, (_, index) => makeSegment(`segment-${index}`, index))
    let sampleCount = 0
    const doc = {
        elementFromPoint() {
            return segments[sampleCount++]
        },
    }

    const result = collectViewportSampleSegmentNodes(doc, {
        left: 0,
        top: 0,
        right: 390,
        bottom: 844,
    }, { sampleDensity: 'minimal' })

    assert.equal(sampleCount, 9)
    assert.deepEqual(result.map(node => node.id), segments.slice(0, 8).map(node => node.id))
})

test('viewport sampling resolves text beneath a non-segment overlay through the caret', () => {
    const segment = makeSegment('segment-under-overlay', 0)
    const textNode = { nodeType: 3, parentElement: segment }
    const doc = {
        elementFromPoint: () => ({ matches: () => false, closest: () => null }),
        caretPositionFromPoint: () => ({ offsetNode: textNode }),
    }

    const result = collectViewportSampleSegmentNodes(doc, {
        left: 0,
        top: 0,
        right: 390,
        bottom: 844,
    }, { sampleDensity: 'minimal' })

    assert.deepEqual(result.map(node => node.id), ['segment-under-overlay'])
})
