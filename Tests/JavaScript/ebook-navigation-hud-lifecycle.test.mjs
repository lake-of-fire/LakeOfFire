import assert from 'node:assert/strict'
import test from 'node:test'

import { NavigationHUD } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-viewer-nav.js'

test('destroy cancels scheduled HUD work and severs Reader callbacks', () => {
    const originalDocument = globalThis.document
    const originalRequestAnimationFrame = globalThis.requestAnimationFrame
    const originalCancelAnimationFrame = globalThis.cancelAnimationFrame
    const scheduledFrames = new Map()
    const cancelledFrames = []
    let nextFrame = 0

    globalThis.document = {
        body: { style: {} },
        documentElement: { style: {} },
        getElementById: () => null,
    }
    globalThis.requestAnimationFrame = callback => {
        const handle = ++nextFrame
        scheduledFrames.set(handle, callback)
        return handle
    }
    globalThis.cancelAnimationFrame = handle => {
        cancelledFrames.push(handle)
        scheduledFrames.delete(handle)
    }

    try {
        const hud = new NavigationHUD({
            onJumpRequest: () => {},
            getRenderer: () => null,
            onHideNavigationDueToScrollChange: () => {},
        })
        assert.equal(scheduledFrames.size, 1)

        assert.equal(hud.destroy(), true)
        assert.equal(hud.destroy(), false)
        assert.deepEqual(cancelledFrames, [1])
        assert.equal(scheduledFrames.size, 0)
        assert.equal(hud.onJumpRequest, null)
        assert.equal(hud.getRenderer, null)
        assert.equal(hud.onHideNavigationDueToScrollChange, null)
    } finally {
        globalThis.document = originalDocument
        globalThis.requestAnimationFrame = originalRequestAnimationFrame
        globalThis.cancelAnimationFrame = originalCancelAnimationFrame
    }
})
