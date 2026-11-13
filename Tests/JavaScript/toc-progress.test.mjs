import assert from 'node:assert/strict'
import test from 'node:test'
import { TOCProgress } from '../../Sources/LakeOfFireReader/Resources/foliate-js/progress.js'

const makeProgress = (toc, ids, getFragment = () => null) => new TOCProgress({
    toc, ids, getFragment,
    splitHref: href => href?.split('#') ?? [],
})

test('unlisted sections retain the final preceding TOC item until the next listed section', () => {
    const toc = [
        { label: 'Chapter one', href: 'one.xhtml#chapter', subitems: [
            { label: 'First part', href: 'one.xhtml#first' },
            { label: 'Final part', href: 'one.xhtml#last' },
        ] },
        { label: 'Chapter four', href: 'four.xhtml#chapter' },
    ]
    const progress = makeProgress(toc, ['one.xhtml', 'two.xhtml', 'three.xhtml', 'four.xhtml'])

    assert.equal(progress.getProgress(0), toc[0])
    assert.equal(progress.getProgress(1), toc[0].subitems[1])
    assert.equal(progress.getProgress(2), toc[0].subitems[1])
    assert.equal(progress.getProgress(3), toc[1])
})

test('fragment IDs in an unlisted document cannot select the previous document\'s headings', () => {
    const toc = [
        { label: 'First heading', href: 'one.xhtml#first' },
        { label: 'Final heading', href: 'one.xhtml#last' },
    ]
    const doc = { fragments: new Map([
        ['first', { position: 20 }],
        ['last', { position: 40 }],
    ]) }
    let lookups = 0
    const progress = makeProgress(toc, ['one.xhtml', 'two.xhtml'], (document, id) => {
        assert.equal(document, doc)
        lookups++
        return document.fragments.get(id)
    })
    // Only the DOM boundary is supplied here; TOC grouping and selection run
    // through the production object. Both current-document IDs are later.
    const range = {
        startContainer: { getRootNode: () => doc },
        comparePoint: element => Math.sign(element.position - 10),
    }

    assert.equal(progress.getProgress(1, range), toc[1])
    assert.equal(lookups, 0)
})

test('listed sections still select their own fragments and preceding TOC item', () => {
    const toc = [
        { label: 'First chapter', href: 'one.xhtml#chapter' },
        { label: 'Second chapter start', href: 'two.xhtml#first' },
        { label: 'Second chapter end', href: 'two.xhtml#last' },
    ]
    const doc = { fragments: new Map([
        ['first', { position: 10 }],
        ['last', { position: 30 }],
    ]) }
    const progress = makeProgress(toc, ['one.xhtml', 'two.xhtml'],
        (document, id) => document.fragments.get(id))
    const at = position => ({
        startContainer: { getRootNode: () => doc },
        comparePoint: element => Math.sign(element.position - position),
    })

    assert.equal(progress.getProgress(1, at(0)), toc[0])
    assert.equal(progress.getProgress(1, at(20)), toc[1])
    assert.equal(progress.getProgress(1, at(40)), toc[2])
})

test('sections before the first listed item and empty navigation have no preceding item', () => {
    const toc = [{ label: 'Later chapter', href: 'three.xhtml#chapter' }]
    const progress = makeProgress(toc, ['one.xhtml', 'two.xhtml', 'three.xhtml'])

    assert.equal(progress.getProgress(0), null)
    assert.equal(progress.getProgress(1), null)
    assert.equal(progress.getProgress(2), toc[0])
    assert.equal(makeProgress([], ['one.xhtml']).getProgress(0), null)
})
