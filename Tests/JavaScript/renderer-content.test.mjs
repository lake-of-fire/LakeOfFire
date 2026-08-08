import assert from 'node:assert/strict'
import test from 'node:test'

import {
    activeRendererContentsForLookup,
    getCurrentRendererDocument,
    getPrimaryRendererContent,
    getPrimaryRendererContentIndex,
    getPrimaryRendererDocument,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/renderer-content.js'

const content = index => ({ index, doc: { URL: `ebook://book/${index}.xhtml` } })

test('currentIndex selects the visible fixed-layout document instead of DOM order', () => {
    const renderer = {
        currentIndex: 1,
        getContents: () => [content(0), content(1)],
    }
    assert.equal(getPrimaryRendererContent(renderer)?.index, 1)
    assert.equal(getPrimaryRendererContentIndex(renderer), 1)
    assert.deepEqual(activeRendererContentsForLookup(renderer).map(item => item.index), [1])
})

test('declared currentIndex never falls back to a stale first document', () => {
    const renderer = {
        currentIndex: 2,
        getContents: () => [content(0), content(1)],
    }
    assert.equal(getPrimaryRendererContent(renderer), null)
    assert.deepEqual(activeRendererContentsForLookup(renderer), [])
})

test('renderers without currentIndex retain first-content compatibility', () => {
    const renderer = { getContents: () => [content(3), content(4)] }
    assert.equal(getPrimaryRendererContent(renderer)?.index, 3)
    assert.equal(getPrimaryRendererContentIndex(renderer), 3)
    assert.deepEqual(activeRendererContentsForLookup(renderer).map(item => item.index), [3])
})

test('invalid or throwing currentIndex access does not hide otherwise usable content', () => {
    const invalidRenderer = {
        currentIndex: Number.NaN,
        getContents: () => [content(5)],
    }
    assert.equal(getPrimaryRendererContent(invalidRenderer)?.index, 5)
    assert.equal(getPrimaryRendererContentIndex(invalidRenderer), 5)

    const fractionalRenderer = {
        currentIndex: 5.5,
        getContents: () => [content(5)],
    }
    assert.equal(getPrimaryRendererContent(fractionalRenderer)?.index, 5)
    assert.equal(getPrimaryRendererContentIndex(fractionalRenderer), 5)

    const throwingRenderer = {
        get currentIndex() { throw new Error('unavailable') },
        getContents: () => [content(6)],
    }
    assert.equal(getPrimaryRendererContent(throwingRenderer)?.index, 6)
    assert.equal(getPrimaryRendererContentIndex(throwingRenderer), 6)
})


test('authoritative currentIndex excludes unindexed auxiliary or stale frame contents', () => {
    const unindexed = { doc: { URL: 'ebook://book/auxiliary.xhtml' } }
    const renderer = {
        currentIndex: 8,
        getContents: () => [unindexed, content(8), content(7)],
    }
    assert.equal(getPrimaryRendererContent(renderer)?.index, 8)
    assert.deepEqual(activeRendererContentsForLookup(renderer).map(item => item.index), [8])
})

test('an explicit document is accepted only while it remains the renderer primary document', () => {
    const left = content(10)
    const right = content(11)
    const renderer = {
        currentIndex: 11,
        getContents: () => [left, right],
    }

    assert.equal(getPrimaryRendererDocument(renderer), right.doc)
    assert.equal(getCurrentRendererDocument(renderer, right.doc), right.doc)
    assert.equal(getCurrentRendererDocument(renderer, left.doc), null)
    assert.equal(getCurrentRendererDocument(renderer), right.doc)
})
