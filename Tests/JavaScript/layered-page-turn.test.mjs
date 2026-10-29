import assert from 'node:assert/strict'
import test from 'node:test'
import { LayeredPageTurnController, slideGeometry, wheelPageDistance } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/layered-page-turn.js'

function fixture({ reduced = false, deferred = false } = {}) {
    let now = 0
    let id = 0
    const frames = new Map()
    const timers = new Map()
    const doc = Object.assign(new EventTarget(), {
        nodeType: 9, documentElement: { style: {} }, getSelection: () => ({ toString: () => '' }),
    })
    const env = Object.assign(new EventTarget(), {
        document: Object.assign(new EventTarget(), { hidden: false }),
        performance: { now: () => now },
        matchMedia: () => ({ matches: reduced }),
        requestAnimationFrame: callback => { frames.set(++id, callback); return id },
        cancelAnimationFrame: id => frames.delete(id),
        setTimeout: callback => { timers.set(++id, callback); return id },
        clearTimeout: id => timers.delete(id),
    })
    const turns = []
    const captures = new Set()
    let release
    const renderer = Object.assign(new EventTarget(), {
        setPointerCapture: id => captures.add(id),
        hasPointerCapture: id => captures.has(id),
        releasePointerCapture: id => captures.delete(id),
        pageTurnDirection: 'ltr', getBoundingClientRect: () => ({ width: 800 }),
        getContents: () => [{ doc }], cancelPageTurn() { turns.at(-1)?.cancel() },
        preparePageTurn(direction) {
            const turn = { direction, updates: [], commits: [], cancelled: false,
                update(progress) { if (!this.cancelled) this.updates.push(progress) },
                commit(options) { this.commits.push(options); return true },
                cancel() { this.cancelled = true },
            }
            turns.push(turn)
            return deferred ? new Promise(resolve => { release = () => resolve(turn) }) : Promise.resolve(turn)
        },
    })
    const controller = new LayeredPageTurnController(renderer, env)
    async function flush() { for (let i = 0; i < 8; i++) await Promise.resolve() }
    async function frame(ms = 220) {
        now += ms
        const work = [...frames.values()]
        frames.clear()
        await Promise.all(work.map(callback => callback(now)))
        await flush()
    }
    function pointer(type, x, y = 0, extra = {}) {
        const event = new Event(type, { cancelable: true })
        Object.assign(event, { pointerId: 1, pointerType: 'touch', button: 0, isPrimary: true,
            clientX: x, clientY: y, ...extra })
        renderer.dispatchEvent(event)
        return event
    }
    function wheel(x, y) {
        const event = new Event('wheel', { cancelable: true })
        Object.assign(event, { deltaX: x, deltaY: y, deltaMode: 0 })
        renderer.dispatchEvent(event)
        return event
    }
    return { controller, renderer, doc, env, turns, captures, frame, flush, pointer, wheel, release: () => release?.() }
}

test('losing the active pointer capture cancels paint and permits a fresh drag', async () => {
    const f = fixture()
    f.pointer('pointerdown', 700)
    f.pointer('pointermove', 100)
    await f.flush()
    f.captures.delete(1)
    f.pointer('lostpointercapture', 100)
    assert.equal(f.controller.active, false)
    assert.equal(f.turns[0].cancelled, true)
    assert.equal(f.turns[0].commits.length, 0)
    f.pointer('pointerdown', 700)
    f.pointer('pointermove', 100)
    await f.flush()
    f.pointer('pointerup', 100)
    await f.flush()
    await f.frame()
    assert.equal(f.turns[1].commits.length, 1)
    f.controller.destroy()
})

test('capture loss fences late preparation without waiting for pointerup', async () => {
    const f = fixture({ deferred: true })
    f.pointer('pointerdown', 700)
    f.pointer('pointermove', 100)
    f.captures.delete(1)
    f.pointer('lostpointercapture', 100)
    f.release()
    await f.flush()
    assert.equal(f.controller.active, false)
    assert.equal(f.turns[0].cancelled, true)
    assert.deepEqual(f.turns[0].updates, [])
    assert.equal(f.turns[0].commits.length, 0)
    f.controller.destroy()
})

test('implicit touch capture handoff preserves the capture held by the current target', async () => {
    const f = fixture()
    f.pointer('pointerdown', 700)
    f.pointer('pointermove', 100)
    await f.flush()
    assert.equal(f.captures.has(1), true)
    // A bubbling loss from the old implicit target can be retargeted to the
    // same shadow host that now owns explicit capture.
    f.pointer('lostpointercapture', 100)
    assert.equal(f.controller.active, true)
    assert.equal(f.turns[0].cancelled, false)
    f.pointer('pointerup', 100)
    await f.flush()
    await f.frame()
    assert.equal(f.turns[0].commits.length, 1)
    f.controller.destroy()
})

test('blur and destruction release owned pointer capture', async () => {
    for (const action of ['blur', 'destroy']) {
        const f = fixture()
        f.pointer('pointerdown', 700)
        f.pointer('pointermove', 100)
        await f.flush()
        assert.equal(f.captures.has(1), true)
        if (action === 'blur') f.env.dispatchEvent(new Event('blur'))
        else f.controller.destroy()
        assert.equal(f.captures.has(1), false)
        assert.equal(f.controller.active, false)
        f.controller.destroy()
    }
})

test('other pointer cancellation cannot cancel the current drag', async () => {
    const f = fixture()
    f.pointer('pointerdown', 700)
    f.pointer('pointermove', 100)
    await f.flush()
    f.pointer('pointercancel', 100, 0, { pointerId: 2 })
    f.pointer('lostpointercapture', 100, 0, { pointerId: 2 })
    assert.equal(f.controller.active, true)
    assert.equal(f.turns[0].cancelled, false)
    f.pointer('pointerup', 100)
    await f.flush()
    // Normal implicit capture loss follows pointerup and must not stop settle.
    f.pointer('lostpointercapture', 100)
    await f.frame()
    assert.equal(f.turns[0].commits.length, 1)
    f.controller.destroy()
})

test('forward and backward sheet poses mirror for RTL at quarter, half and three-quarter displacement', () => {
    for (const progress of [0, .25, .5, .75, 1]) {
        for (const direction of [-1, 1]) {
            const ltr = slideGeometry(progress, direction, 'ltr', 800)
            const rtl = slideGeometry(progress, direction, 'rtl', 800)
            assert.equal(rtl.currentX, -ltr.currentX)
            assert.equal(rtl.neighborX, -ltr.neighborX)
            assert.equal(ltr.currentShade, direction < 0 ? .24 * progress : 0)
            assert.equal(ltr.neighborShade, direction > 0 ? .24 * (1 - progress) : 0)
        }
    }
    assert.equal(slideGeometry(.5, 1, 'ltr', 800).neighborX, 60)
    assert.equal(slideGeometry(.5, -1, 'ltr', 800).currentX, 60)
    assert.equal(slideGeometry(NaN, 1, 'ltr', 800).progress, 0)
    assert.equal(slideGeometry(2, 1, 'ltr', 800).progress, 1)
})

test('wheel distance handles line/page units and reverses only horizontal RTL input', () => {
    assert.equal(wheelPageDistance(3, 0, 1, 800, 'ltr'), 48)
    assert.equal(wheelPageDistance(1, 0, 2, 800, 'rtl'), -800)
    assert.equal(wheelPageDistance(0, 10, 0, 800, 'rtl'), 10)
})

test('held drag paints without committing, short drag returns to origin', async () => {
    const f = fixture()
    f.pointer('pointerdown', 500)
    f.pointer('pointermove', 300)
    await f.flush()
    assert.deepEqual(f.turns[0].updates, [.25])
    assert.equal(f.turns[0].commits.length, 0)
    f.pointer('pointerup', 300)
    await f.flush()
    await f.frame()
    assert.equal(f.turns[0].commits.length, 0)
    assert.equal(f.turns[0].updates.at(-1), 0)
    assert.equal(f.controller.active, false)
    f.controller.destroy()
})

test('drag commits exactly once after settling and suppresses its following click', async () => {
    const f = fixture()
    f.pointer('pointerdown', 700)
    f.pointer('pointermove', 100)
    await f.flush()
    f.pointer('pointerup', 100)
    await f.flush()
    assert.equal(f.turns[0].commits.length, 0)
    await f.frame()
    assert.equal(f.turns[0].commits.length, 1)
    const click = new Event('click', { cancelable: true })
    f.renderer.dispatchEvent(click)
    assert.equal(click.defaultPrevented, true)
    f.controller.destroy()
})

test('catching a settling slide preserves its pose and can reverse into a cancelled turn', async () => {
    const f = fixture()
    f.pointer('pointerdown', 700)
    f.pointer('pointermove', 100)
    await f.flush()
    f.pointer('pointerup', 100)
    await f.flush()
    await f.frame(60)
    const held = f.controller.progress
    assert.ok(held > .75 && held < 1)
    f.pointer('pointerdown', 100)
    assert.equal(f.controller.progress, held)
    f.pointer('pointermove', 100 + held * 800 - 100)
    await f.flush()
    assert.ok(Math.abs(f.controller.progress - .125) < .001)
    f.pointer('pointerup', 100 + held * 800 - 100)
    await f.flush()
    await f.frame()
    assert.equal(f.turns[0].commits.length, 0)
    f.controller.destroy()
})

test('reversing across the origin retires the old preparation', async () => {
    const f = fixture()
    f.controller.move(.6)
    await f.flush()
    f.controller.move(-.3)
    await f.flush()
    assert.equal(f.turns[0].cancelled, true)
    assert.equal(f.turns[1].direction, -1)
    assert.deepEqual(f.turns[1].updates, [.3])
    f.controller.destroy()
})

test('late preparations cannot paint or commit after cancellation/destruction', async () => {
    const f = fixture({ deferred: true })
    f.controller.move(.8)
    const finished = f.controller.finish(true)
    f.controller.destroy()
    f.release()
    await f.flush()
    assert.equal(await finished, false)
    assert.equal(f.turns[0].cancelled, true)
    assert.deepEqual(f.turns[0].updates, [])
    assert.equal(f.turns[0].commits.length, 0)
    f.pointer('pointerdown', 700)
    f.pointer('pointermove', 0)
    assert.equal(f.turns.length, 1)
})

test('reduced motion commits without intermediate animation and returns the renderer result', async () => {
    const f = fixture({ reduced: true })
    const result = f.controller.turn(-1, { allowBookEndcap: false })
    await f.flush()
    await f.frame(1)
    assert.equal(await result, true)
    assert.deepEqual(f.turns[0].commits, [{ allowBookEndcap: false }])
    assert.equal(f.turns[0].updates.at(-1), 1)
    f.controller.destroy()
})

test('an explicit turn can navigate with selected text without clearing it during preparation', async () => {
    const f = fixture()
    f.doc.getSelection = () => ({ toString: () => 'selected text' })
    const result = f.controller.turn(1, { allowBookEndcap: false })
    await f.flush()
    assert.equal(f.turns.length, 1)
    assert.equal(f.doc.getSelection().toString(), 'selected text')
    assert.equal(f.turns[0].commits.length, 0)
    await f.frame()
    assert.equal(await result, true)
    assert.deepEqual(f.turns[0].commits, [{ allowBookEndcap: false }])
    f.controller.destroy()
})

test('vertical gestures, selections, controls and pinch do not claim a page drag', async () => {
    const f = fixture()
    f.pointer('pointerdown', 400)
    assert.equal(f.pointer('pointermove', 410, 100).defaultPrevented, false)
    f.pointer('pointerup', 410)
    f.doc.getSelection = () => ({ toString: () => 'selected text' })
    f.pointer('pointerdown', 700)
    f.pointer('pointermove', 0)
    assert.equal(f.turns.length, 0)
    f.doc.getSelection = () => ({ toString: () => '' })
    f.env.visualViewport = { scale: 2 }
    f.pointer('pointerdown', 700)
    f.pointer('pointermove', 0)
    assert.equal(f.turns.length, 0)
    f.controller.destroy()
})


test('cancelling a finish waiting on a stalled preparation releases its caller immediately', async () => {
    const f = fixture({ deferred: true })
    f.controller.move(.8)
    const finished = f.controller.finish(true)
    f.controller.cancel()
    assert.equal(await finished, false)
    f.release()
    await f.flush()
    assert.equal(f.turns[0].commits.length, 0)
    f.controller.destroy()
})


test('a superseded wait cannot strand a newer finish during slow chapter preparation', async () => {
    const f = fixture({ deferred: true })
    f.controller.move(.8)
    const older = f.controller.finish(true)
    f.controller.interrupt()
    const newer = f.controller.finish(false)
    await f.flush()
    f.controller.cancel()
    assert.equal(await older, false)
    assert.equal(await newer, false)
    f.release()
    await f.flush()
    assert.equal(f.turns[0].commits.length, 0)
    f.controller.destroy()
})

test('release samples the final position even without a final pointermove', async () => {
    for (const [moveX, releaseX, commits] of [[400, 200, 1], [100, 500, 0]]) {
        const f = fixture()
        f.pointer('pointerdown', 700)
        f.pointer('pointermove', moveX)
        await f.flush()
        f.pointer('pointerup', releaseX)
        await f.flush()
        await f.frame()
        assert.equal(f.turns[0].commits.length, commits)
        f.controller.destroy()
    }
})

test('a fresh tap after a drag is not swallowed as its compatibility click', async () => {
    const f = fixture()
    f.pointer('pointerdown', 700)
    f.pointer('pointermove', 100)
    await f.flush()
    f.pointer('pointerup', 100)
    await f.flush()
    await f.frame()
    f.pointer('pointerdown', 100)
    f.pointer('pointerup', 100)
    const click = new Event('click', { cancelable: true })
    f.renderer.dispatchEvent(click)
    assert.equal(click.defaultPrevented, false)
    f.controller.destroy()
})

test('releasing an unclaimed margin press elsewhere cannot strand explicit navigation', async () => {
    const f = fixture()
    try {
        f.pointer('pointerdown', 700)
        const release = new Event('pointerup')
        Object.assign(release, { pointerId: 1 })
        f.env.document.dispatchEvent(release)
        const finished = f.controller.turn(1)
        await f.flush()
        assert.equal(f.turns.length, 1)
        await f.frame()
        assert.equal(await finished, true)
    } finally { f.controller.destroy() }
})

test('an outside release for another pointer cannot discard the current press', async () => {
    const f = fixture()
    try {
        f.pointer('pointerdown', 700)
        const release = new Event('pointerup')
        Object.assign(release, { pointerId: 2 })
        f.env.document.dispatchEvent(release)
        assert.equal(f.controller.pointer.id, 1)
        f.pointer('pointermove', 100)
        await f.flush()
        f.pointer('pointerup', 100)
        await f.flush()
        await f.frame()
        assert.equal(f.turns[0].commits.length, 1)
    } finally { f.controller.destroy() }
})

test('zero or nonfinite wheel input does not start a preview', () => {
    const f = fixture()
    assert.equal(f.wheel(0, 0).defaultPrevented, false)
    assert.equal(f.wheel(NaN, NaN).defaultPrevented, false)
    assert.equal(f.turns.length, 0)
    f.controller.destroy()
})

test('settling paint failures settle the caller, report the error and release the turn', async () => {
    const f = fixture()
    const errors = []
    f.renderer.addEventListener('pageturnerror', e => errors.push(e.detail))
    f.controller.move(.7)
    await f.flush()
    const failure = new Error('Paint failed')
    f.turns[0].update = () => { throw failure }
    const finished = f.controller.finish(true)
    await f.flush()
    await f.frame()
    assert.equal(await finished, false)
    assert.deepEqual(errors, [failure])
    assert.equal(f.turns[0].commits.length, 0)
    assert.equal(f.controller.active, false)
    f.controller.destroy()
})

test('an invalidated preview cannot commit when its next paint is refused', async () => {
    const f = fixture()
    f.controller.move(.7)
    await f.flush()
    f.turns[0].update = () => false
    const finished = f.controller.finish(true)
    await f.flush()
    await f.frame()
    assert.equal(await finished, false)
    assert.equal(f.turns[0].commits.length, 0)
    assert.equal(f.controller.active, false)
    f.controller.destroy()
})

test('cancelling visual motion during an admitted commit preserves its actual movement receipt', async () => {
    const f = fixture()
    f.controller.move(.7)
    await f.flush()
    let complete
    f.turns[0].commit = () => new Promise(resolve => { complete = resolve })
    const finished = f.controller.finish(true)
    let settled = false
    finished.then(() => { settled = true })
    await f.flush()
    const frame = f.frame()
    await f.flush()
    assert.equal(f.controller.committing, true)
    f.controller.cancel()
    await f.flush()
    assert.equal(settled, false)
    complete(true)
    await frame
    assert.equal(await finished, true)
    f.controller.destroy()
})

test('a commit error reaches the explicit caller even if it cancels visual motion', async () => {
    const f = fixture()
    const failure = new Error('Commit failed after possible movement')
    f.controller.move(.7)
    await f.flush()
    let fail
    f.turns[0].commit = () => new Promise((_, reject) => { fail = reject })
    const finished = f.controller.finish(true)
    const rejected = assert.rejects(finished, failure)
    await f.flush()
    const frame = f.frame()
    await f.flush()
    f.controller.cancel()
    fail(failure)
    await frame
    await rejected
    f.controller.destroy()
})


test('an instant renderer fallback commits without a settling delay', async () => {
    const f = fixture()
    const prepare = f.renderer.preparePageTurn
    f.renderer.preparePageTurn = async direction => {
        const turn = await prepare(direction)
        turn.instant = true
        return turn
    }
    const result = f.controller.turn(1)
    await f.flush()
    await f.frame(0)
    assert.equal(await result, true)
    assert.equal(f.turns[0].commits.length, 1)
    f.controller.destroy()
})
