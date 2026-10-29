import assert from 'node:assert/strict'
import test from 'node:test'

import { copyCustomReaderFontStyleToDocument } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-font-forwarding.js'

const families = {
    manabiHorizontalFontFamilyName: 'YuKyokasho Yoko',
    manabiVerticalFontFamilyName: 'YuKyokasho',
}
const makeElement = tagName => Object.assign(new EventTarget(), {
    tagName: tagName.toUpperCase(), dataset: {}, textContent: '', rel: '', href: '',
    disabled: false, isConnected: false, remove() {},
})
const makeDocument = direction => {
    const elements = new Map()
    const documentElement = makeElement('html')
    return {
        body: {
            dataset: direction ? { mnbWritingDirection: direction } : {},
            classList: { contains: () => false },
        },
        documentElement,
        head: { appendChild: element => {
            elements.set(element.id, element)
            element.isConnected = true
            element.remove = () => {
                if (elements.get(element.id) === element) elements.delete(element.id)
                element.isConnected = false
            }
            return element
        } },
        getElementById: id => elements.get(id) || null,
        createElement: makeElement,
    }
}
const sourceFontStyle = () => ({
    tagName: 'LINK',
    rel: 'stylesheet',
    href: 'internal://local/manabi-fonts.css?family=YuKyokasho',
    dataset: { mnbInjectedFontFamily: 'Fallback Family', assetRevision: '7' },
})

test('selects directional families while retaining one stylesheet URL', () => {
    const verticalDocument = makeDocument('vertical')
    const horizontalDocument = makeDocument('horizontal')

    assert.equal(copyCustomReaderFontStyleToDocument(sourceFontStyle(), verticalDocument, 'test', families), true)
    assert.equal(copyCustomReaderFontStyleToDocument(sourceFontStyle(), horizontalDocument, 'test', families), true)
    assert.equal(verticalDocument.documentElement.dataset.mnbInjectedFontFamily, 'YuKyokasho')
    assert.equal(horizontalDocument.documentElement.dataset.mnbInjectedFontFamily, 'YuKyokasho Yoko')
    assert.equal(
        verticalDocument.getElementById('mnb-custom-fonts-inline').href,
        horizontalDocument.getElementById('mnb-custom-fonts-inline').href,
    )
})

test('repeated forwarding is a no-op and direction changes only update metadata', () => {
    const document = makeDocument('horizontal')
    const source = sourceFontStyle()
    assert.equal(copyCustomReaderFontStyleToDocument(source, document, 'test', families), true)
    assert.equal(copyCustomReaderFontStyleToDocument(source, document, 'test', families), false)
    const href = document.getElementById('mnb-custom-fonts-inline').href

    document.body.dataset.mnbWritingDirection = 'vertical'
    assert.equal(copyCustomReaderFontStyleToDocument(source, document, 'test', families), true)
    assert.equal(document.documentElement.dataset.mnbInjectedFontFamily, 'YuKyokasho')
    assert.equal(document.getElementById('mnb-custom-fonts-inline').href, href)
})


test('forwarding preserves disabled fonts and does not revive a timed-out document', () => {
    const source = sourceFontStyle()
    source.disabled = true
    const document = makeDocument('horizontal')
    assert.equal(copyCustomReaderFontStyleToDocument(source, document, 'timeout', families), true)
    assert.equal(document.getElementById('mnb-custom-fonts-inline').disabled, true)
    assert.equal(copyCustomReaderFontStyleToDocument(source, document, 'timeout-replay', families), false)

    const timedOutDocument = makeDocument('horizontal')
    timedOutDocument.documentElement.dataset.mnbFontOutcome = 'timeout'
    source.disabled = false
    assert.equal(copyCustomReaderFontStyleToDocument(source, timedOutDocument, 'late-font', families), false)
    assert.equal(timedOutDocument.getElementById('mnb-custom-fonts-inline'), null)
})

for (const outcome of ['failed', 'unavailable', 'timeout']) {
    test(`forwarding cannot reactivate ${outcome} fallback`, () => {
        const document = makeDocument('horizontal')
        const source = sourceFontStyle()
        copyCustomReaderFontStyleToDocument(source, document, 'initial', families)
        const target = document.getElementById('mnb-custom-fonts-inline')
        target.disabled = true
        document.documentElement.dataset.mnbFontOutcome = outcome
        source.disabled = false

        assert.equal(copyCustomReaderFontStyleToDocument(source, document, 'late-replay', families), false)
        assert.equal(document.getElementById('mnb-custom-fonts-inline'), target)
        assert.equal(target.disabled, true)
    })
}

test('forwarding preserves inline local declarations without creating a link', () => {
    const source = {
        tagName: 'STYLE', disabled: false,
        textContent: "@font-face { font-family: 'YuKyokasho'; src: url('internal://local/manabi-fonts/YuKyokasho.woff2'); }",
        dataset: { mnbFontSource: 'local-scheme', mnbFontHash: 'local' },
    }
    const document = makeDocument('vertical')
    assert.equal(copyCustomReaderFontStyleToDocument(source, document, 'inline', families), true)
    const target = document.getElementById('mnb-custom-fonts-inline')
    assert.equal(target.tagName, 'STYLE')
    assert.equal(target.textContent, source.textContent)
    assert.equal(target.dataset.mnbFontSource, 'local-scheme')
    assert.equal(copyCustomReaderFontStyleToDocument(source, document, 'inline-replay', families), false)
})

const competingFontStyles = {
    'inline replacement': () => ({
        tagName: 'STYLE',
        textContent: "@font-face { font-family: 'YuKyokasho'; src: local('YuKyokasho'); }",
        dataset: { mnbFontSource: 'local-scheme', mnbFontHash: 'replacement' },
    }),
    'different link URL': () => ({
        ...sourceFontStyle(),
        href: 'internal://local/manabi-fonts.css?family=OtherFamily',
        dataset: { mnbInjectedFontFamily: 'OtherFamily', assetRevision: '8' },
    }),
    'disabled source': () => ({ ...sourceFontStyle(), disabled: true }),
}

for (const direction of ['horizontal', 'vertical']) {
    for (const [change, makeCompetingStyle] of Object.entries(competingFontStyles)) {
        for (const eventType of ['load', 'error']) {
            test(`pending ${direction} document retains ${eventType} events during ${change}`, async () => {
                const document = makeDocument(direction)
                copyCustomReaderFontStyleToDocument(sourceFontStyle(), document, 'initial', families)
                const target = document.getElementById('mnb-custom-fonts-inline')
                const initialHref = target.href
                const initialDataset = { ...target.dataset }
                const initialRootDataset = { ...document.documentElement.dataset }
                let observedOutcome = 'pending'
                const promise = new Promise(resolve => {
                    target.addEventListener('load', () => resolve('load'), { once: true })
                    target.addEventListener('error', () => resolve('error'), { once: true })
                })
                promise.then(outcome => { observedOutcome = outcome })
                document.defaultView = { manabiReaderFontLoad: { promise } }

                assert.equal(copyCustomReaderFontStyleToDocument(
                    makeCompetingStyle(), document, 'parent-refresh', families,
                ), false)
                const activeStyle = document.getElementById('mnb-custom-fonts-inline')
                assert.equal(activeStyle, target)
                assert.equal(target.isConnected, true)
                assert.equal(target.href, initialHref)
                assert.equal(target.textContent, '')
                assert.equal(target.disabled, false)
                assert.deepEqual(target.dataset, initialDataset)
                assert.deepEqual(document.documentElement.dataset, initialRootDataset)

                // Exercise the listener attached before forwarding, using the
                // currently installed node. Do not wait on the four-second gate.
                activeStyle.dispatchEvent(new Event(eventType))
                await Promise.resolve()
                assert.equal(observedOutcome, eventType)
            })
        }
    }
}

test('a settled document retains its own stylesheet and directional selection', async () => {
    const document = makeDocument('vertical')
    copyCustomReaderFontStyleToDocument(sourceFontStyle(), document, 'initial', families)
    const target = document.getElementById('mnb-custom-fonts-inline')
    const initialHref = target.href
    const promise = Promise.resolve('loaded')
    document.defaultView = { manabiReaderFontLoad: { promise } }
    await promise
    document.documentElement.dataset.mnbFontOutcome = 'loaded'
    // The destination owns direction updates even when its parent's metadata
    // still describes another direction or font selection.
    document.body.dataset.mnbWritingDirection = 'horizontal'
    target.dataset.mnbInjectedFontFamily = families.manabiHorizontalFontFamilyName
    document.documentElement.dataset.mnbInjectedFontFamily = families.manabiHorizontalFontFamilyName
    const initialDataset = { ...target.dataset }
    const initialRootDataset = { ...document.documentElement.dataset }

    for (const makeCompetingStyle of Object.values(competingFontStyles)) {
        assert.equal(copyCustomReaderFontStyleToDocument(
            makeCompetingStyle(), document, 'late-parent-refresh', families,
        ), false)
        assert.equal(document.getElementById('mnb-custom-fonts-inline'), target)
        assert.equal(target.href, initialHref)
        assert.equal(target.disabled, false)
        assert.deepEqual(target.dataset, initialDataset)
        assert.deepEqual(document.documentElement.dataset, initialRootDataset)
    }
})

for (const direction of ['horizontal', 'vertical']) {
    test(`forwarding can seed a missing initial stylesheet in a ${direction} document`, () => {
        const document = makeDocument(direction)
        document.defaultView = { manabiReaderFontLoad: { promise: new Promise(() => {}) } }
        const source = sourceFontStyle()

        assert.equal(copyCustomReaderFontStyleToDocument(source, document, 'startup', families), true)
        const target = document.getElementById('mnb-custom-fonts-inline')
        assert.equal(target.tagName, 'LINK')
        assert.equal(target.isConnected, true)
        assert.equal(target.href, source.href)
        assert.equal(document.documentElement.dataset.mnbInjectedFontFamily,
            direction === 'vertical' ? families.manabiVerticalFontFamilyName : families.manabiHorizontalFontFamilyName)
    })
}

for (const direction of ['horizontal', 'vertical']) {
    test(`pending ${direction} document retains its inline font declarations`, async () => {
        const document = makeDocument(direction)
        const source = {
            tagName: 'STYLE',
            textContent: "@font-face { font-family: 'YuKyokasho'; src: url('internal://local/manabi-fonts/YuKyokasho.woff2'); }",
            dataset: { mnbFontSource: 'local-scheme', mnbFontHash: 'local' },
        }
        copyCustomReaderFontStyleToDocument(source, document, 'initial', families)
        const target = document.getElementById('mnb-custom-fonts-inline')
        const initialDataset = { ...target.dataset }
        let completeFontLoad
        const promise = new Promise(resolve => { completeFontLoad = resolve })
        document.defaultView = { manabiReaderFontLoad: { promise } }

        for (const makeCompetingStyle of Object.values(competingFontStyles)) {
            assert.equal(copyCustomReaderFontStyleToDocument(
                makeCompetingStyle(), document, 'parent-refresh', families,
            ), false)
            assert.equal(document.getElementById('mnb-custom-fonts-inline'), target)
            assert.equal(target.isConnected, true)
            assert.equal(target.textContent, source.textContent)
            assert.equal(target.disabled, false)
            assert.deepEqual(target.dataset, initialDataset)
        }
        completeFontLoad('loaded')
        assert.equal(await promise, 'loaded')
    })
}

test('an incomplete ownership marker does not block compatibility forwarding', () => {
    const document = makeDocument('horizontal')
    copyCustomReaderFontStyleToDocument(sourceFontStyle(), document, 'initial', families)
    const oldTarget = document.getElementById('mnb-custom-fonts-inline')
    document.defaultView = { manabiReaderFontLoad: { promise: null } }
    document.documentElement.dataset.mnbFontPending = '1'
    const source = competingFontStyles['inline replacement']()

    assert.equal(copyCustomReaderFontStyleToDocument(source, document, 'compatibility', families), true)
    const newTarget = document.getElementById('mnb-custom-fonts-inline')
    assert.notEqual(newTarget, oldTarget)
    assert.equal(oldTarget.isConnected, false)
    assert.equal(newTarget.tagName, 'STYLE')
    assert.equal(newTarget.textContent, source.textContent)
})
