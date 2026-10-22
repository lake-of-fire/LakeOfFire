import assert from 'node:assert/strict'
import test from 'node:test'
import { BookEndcap, createBookActionBridge } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-endcap.js'

// Complete production Endcap, action bridge and producer adapters. DOM
// allocation, producer admission, native replies and timer delivery are
// controlled collaborators, not real browser or native mutation evidence.
class Element extends EventTarget {
    attributes = new Map()
    children = []
    classes = new Set()
    classList = { add: value => this.classes.add(value), remove: value => this.classes.delete(value) }
    isConnected = true
    inert = false
    hidden = false
    disabled = false
    textContent = ''
    nodes = new Map()

    append(value) { this.children.push(value) }
    setAttribute(key, value) { this.attributes.set(key, String(value)) }
    getAttribute(key) { return this.attributes.get(key) ?? null }
    removeAttribute(key) { this.attributes.delete(key) }
    querySelector(key) {
        if (!this.nodes.has(key)) this.nodes.set(key, new Element())
        return this.nodes.get(key)
    }
    focus() { this.focused = true }
    remove() { this.isConnected = false }
}

function fixture(t, { finished = false } = {}) {
    const originalProducer = Object.getOwnPropertyDescriptor(globalThis, 'manabiArticleProducer')
    const messages = [], timers = new Map(), carriedOwners = []
    let sequence = 0, timerSequence = 0, endcap
    let account = '1:1'
    const owner = Object.freeze({ token: 'original-producer',
        frameURL: 'ebook://ebook/load/book.epub', documentStartedAtMs: 123 })
    const behavior = {
        capture: () => owner,
        own: (body, admitted) => ({ ...body, readerArticleProducer: { ...admitted } }),
        post: () => {},
        installTimer: () => {},
    }
    globalThis.manabiArticleProducer = {
        captureIfReady: () => behavior.capture(),
        own: (body, admitted) => {
            carriedOwners.push(admitted)
            return behavior.own(body, admitted)
        },
        ready: () => Promise.resolve(),
    }
    const context = {
        contextID: 'end-page-context', articleProgressID: 'article', articleEpochID: 'epoch',
        scope: null, isEndPage: true, sectionLocation: null, locationRevision: 1,
    }
    const bridge = createBookActionBridge({
        topWindowURL: owner.frameURL, documentStartedAtMs: owner.documentStartedAtMs,
        captureContext: () => ({ ...context }),
        makeRequestID: () => `11111111-1111-4111-8111-${String(++sequence).padStart(12, '0')}`,
        setTimer: callback => {
            behavior.installTimer()
            timers.set(++timerSequence, callback)
            return timerSequence
        },
        clearTimer: id => timers.delete(id),
        onAccountChange: () => endcap?.accountDidChange(),
        postMessage: packet => {
            messages.push(packet)
            behavior.post(packet)
        },
    })
    const document = { createElement: () => new Element(), activeElement: new Element() }
    const publication = new Element()
    endcap = new BookEndcap({
        document, host: new Element(), publication,
        performAction: action => bridge.perform(action),
        recoverAction: recovery => bridge.recover(recovery),
    })
    assert.equal(bridge.setAccountPresentation(account), true)
    endcap.setFinished(finished)
    endcap.setReady(true)
    assert.equal(endcap.enter(), true)
    const acknowledge = (packet, result) => bridge.acknowledge(packet.deliveryID, {
        requestID: packet.requestID, accountPresentation: account, ...result,
    })
    const succeed = packet => acknowledge(packet, { ok: true, committed: true,
        ...(packet.action === 'finishBook' ? {} : { navigation: { status: 'completed' } }) })
    const expire = () => {
        assert.equal(timers.size, 1)
        Array.from(timers.values())[0]()
    }
    t.after(() => {
        bridge.close()
        endcap.destroy()
        if (originalProducer) Object.defineProperty(globalThis, 'manabiArticleProducer', originalProducer)
        else delete globalThis.manabiArticleProducer
        assert.equal(timers.size, 0)
    })
    return { bridge, endcap, messages, timers, behavior, owner, carriedOwners,
        acknowledge, succeed, expire,
        changeAccount: stamp => { account = stamp; return bridge.setAccountPresentation(stamp) },
    }
}

for (const finished of [false, true]) {
    for (const refusal of ['null', 'throw']) {
        test(`${finished ? 'Start Book Over' : 'Finish Book'} retains explicit retry after producer ${refusal}`, async t => {
            const f = fixture(t, { finished })
            const action = finished ? 'startBookOver' : 'finishBook'
            const label = finished ? 'Start Book Over' : 'Finish Book'
            const ordinaryOwn = f.behavior.own
            f.behavior.own = () => {
                if (refusal === 'throw') throw new Error('Original producer retired')
                return null
            }
            assert.equal(await f.endcap.activate(), false)
            assert.equal(f.messages.length, 0, 'No semantic command reached transport')
            assert.equal(f.endcap.button.textContent, label,
                'An unsent command cannot strand the caller on Check Status')
            assert.equal(f.endcap.button.disabled, false)
            assert.equal(f.endcap.busy, false)
            assert.equal(f.endcap.finished, finished)
            assert.equal(f.bridge.recoveryInfo, null)
            assert.equal(f.timers.size, 0)
            f.behavior.own = ordinaryOwn
            f.behavior.post = packet => assert.equal(f.succeed(packet), true)
            assert.equal(await f.endcap.activate(), true)
            assert.deepEqual(f.messages.map(packet => [packet.kind, packet.action]), [['command', action]])
            assert.ok(f.carriedOwners.every(admitted => admitted === f.owner))
            assert.equal(f.endcap.finished, finished, 'A historical reply cannot replace ordered native Finished state')
        })
    }
}

for (const finished of [false, true]) {
    test(`timer installation failure does not fabricate ${finished ? 'restart' : 'Finish'} recovery`, async t => {
        const f = fixture(t, { finished })
        f.behavior.installTimer = () => { throw new Error('Timer unavailable') }
        assert.equal(await f.endcap.activate(), false)
        assert.equal(f.messages.length, 0)
        assert.equal(f.bridge.recoveryInfo, null)
        assert.equal(f.endcap.button.textContent, finished ? 'Start Book Over' : 'Finish Book')
        assert.equal(f.endcap.button.disabled, false)
        f.behavior.installTimer = () => {}
        f.behavior.post = packet => assert.equal(f.succeed(packet), true)
        assert.equal(await f.endcap.activate(), true)
        assert.equal(f.messages.length, 1)
        assert.equal(f.messages[0].kind, 'command')
    })
}

test('a producer adapter cannot change Finish into reset or leave false recovery', async t => {
    const f = fixture(t)
    const ordinaryOwn = f.behavior.own
    f.behavior.own = (body, owner) => ({ ...ordinaryOwn(body, owner), action: 'startBookOver' })
    assert.equal(await f.endcap.activate(), false)
    assert.equal(f.messages.length, 0)
    assert.equal(f.endcap.button.textContent, 'Finish Book')
    assert.equal(f.bridge.recoveryInfo, null)
    f.behavior.own = ordinaryOwn
    f.behavior.post = packet => assert.equal(f.succeed(packet), true)
    assert.equal(await f.endcap.activate(), true)
    assert.equal(f.messages[0].action, 'finishBook')
})

for (const finished of [false, true]) {
    test(`lost posted ${finished ? 'restart' : 'Finish'} reply remains status-only recovery`, async t => {
        const f = fixture(t, { finished })
        const first = f.endcap.activate()
        assert.equal(f.messages.length, 1)
        assert.equal(f.endcap.busy, true)
        f.expire()
        assert.equal(await first, false)
        assert.equal(f.endcap.button.textContent, 'Check Status')
        const requestID = f.messages[0].requestID
        const recovery = f.endcap.activate()
        assert.equal(f.messages.length, 2)
        assert.equal(f.messages[1].requestID, requestID)
        assert.equal(f.messages[1].kind, 'status')
        assert.equal(f.succeed(f.messages[1]), true)
        assert.equal(await recovery, true)
        assert.equal(f.bridge.recoveryInfo, null)
        assert.equal(f.messages.filter(packet => packet.kind === 'command').length, 1)
        assert.equal(f.endcap.finished, finished)
    })
}

test('a transport throw after post entry cannot enable a second semantic reset', async t => {
    const f = fixture(t, { finished: true })
    f.behavior.post = () => { throw new Error('Reply channel lost after handoff') }
    assert.equal(await f.endcap.activate(), false)
    assert.equal(f.messages.length, 1)
    assert.equal(f.endcap.button.textContent, 'Check Status')
    f.behavior.post = packet => assert.equal(f.succeed(packet), true)
    assert.equal(await f.endcap.activate(), true)
    assert.deepEqual(f.messages.map(packet => packet.kind), ['command', 'status'])
    assert.equal(f.messages[0].requestID, f.messages[1].requestID)
})

test('received success wins over a later transport wrapper throw in the actual caller', async t => {
    const f = fixture(t)
    f.behavior.post = packet => {
        assert.equal(f.succeed(packet), true)
        throw new Error('Wrapper failed after native reply')
    }
    assert.equal(await f.endcap.activate(), true)
    assert.equal(f.endcap.error.hidden, true)
    assert.equal(f.bridge.recoveryInfo, null)
    assert.equal(f.endcap.finished, false)
    assert.equal(f.endcap.button.textContent, 'Finish Book')
})

test('failed navigation retries movement under the original committed reset', async t => {
    const f = fixture(t, { finished: true })
    const first = f.endcap.activate()
    const command = f.messages[0]
    assert.equal(f.acknowledge(command, { ok: true, committed: true,
        navigation: { status: 'failed', message: 'Saved; movement failed' } }), true)
    assert.equal(await first, true)
    assert.equal(f.endcap.button.textContent, 'Go to Beginning')
    const movement = f.endcap.activate()
    const navigate = f.messages[1]
    assert.equal(navigate.kind, 'navigate')
    assert.equal(navigate.requestID, command.requestID)
    f.expire()
    assert.equal(await movement, false)
    assert.equal(f.endcap.button.textContent, 'Check Status')
    const status = f.endcap.activate()
    assert.equal(f.messages[2].kind, 'status')
    assert.equal(f.messages[2].requestID, command.requestID)
    assert.equal(f.succeed(f.messages[2]), true)
    assert.equal(await status, true)
    assert.deepEqual(f.messages.map(packet => packet.kind), ['command', 'navigate', 'status'])
})

test('account replacement clears old recovery UI before its rejected promise settles', async t => {
    const f = fixture(t, { finished: true })
    const first = f.endcap.activate()
    const old = f.messages[0]
    assert.equal(f.changeAccount('2:1'), true)
    assert.equal(await first, false)
    assert.equal(f.endcap.button.disabled, true)
    assert.equal(f.endcap.button.textContent, 'Finish Book')
    assert.equal(f.endcap.error.hidden, true)
    assert.equal(f.bridge.recoveryInfo, null)
    assert.equal(f.acknowledge(old, { ok: true, committed: true, navigation: { status: 'failed' } }), false)
    f.endcap.setReady(true)
    f.behavior.post = packet => assert.equal(f.succeed(packet), true)
    assert.equal(await f.endcap.activate(), true)
    assert.equal(f.messages[1].action, 'finishBook')
    assert.notEqual(f.messages[1].requestID, old.requestID)
})

test('destroying the caller while a submitted command waits does not issue recovery', async t => {
    const f = fixture(t)
    const task = f.endcap.activate()
    f.endcap.destroy()
    f.bridge.close()
    assert.equal(await task, false)
    assert.equal(f.endcap.visible, false)
    assert.equal(f.endcap.enter(), false)
    assert.equal(await f.endcap.activate(), false)
    assert.equal(f.messages.length, 1)
    assert.equal(f.timers.size, 0)
})

test('a definitive native rejection permits a new explicit command, not status replay', async t => {
    const f = fixture(t, { finished: true })
    const first = f.endcap.activate()
    assert.equal(f.acknowledge(f.messages[0], { ok: false, error: 'Original pass changed' }), true)
    assert.equal(await first, false)
    assert.equal(f.endcap.button.textContent, 'Start Book Over')
    assert.equal(f.bridge.recoveryInfo, null)
    f.behavior.post = packet => assert.equal(f.succeed(packet), true)
    assert.equal(await f.endcap.activate(), true)
    assert.deepEqual(f.messages.map(packet => packet.kind), ['command', 'command'])
    assert.notEqual(f.messages[0].requestID, f.messages[1].requestID)
})
