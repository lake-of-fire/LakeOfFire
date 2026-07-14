import assert from 'node:assert/strict'
import test from 'node:test'

globalThis.document = { getElementById: () => null }
globalThis.requestAnimationFrame = callback => { callback(); return 0 }

const { NavigationHUD } = await import(
    '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-viewer-nav.js'
)

test('RTL paginator progress uses logical reading-order page numbers', () => {
    const hud = new NavigationHUD({
        getRenderer: () => ({ scrolled: false, bookDir: 'rtl' }),
    })
    hud.setIsRTL(true)
    const normalized = hud._normalizeRendererPageInfo(9, 13, {
        scrolled: false,
        bookDir: 'rtl',
    })
    hud.rendererPageSnapshot = normalized

    assert.equal(normalized.current, 3)
    assert.equal(normalized.total, 11)
    assert.equal(normalized.rawCurrent, 9)
    assert.equal(hud._fractionForPercent({ fraction: 0.8 }), 0.8)
})
