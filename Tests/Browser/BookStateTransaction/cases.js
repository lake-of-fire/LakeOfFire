const expect = (condition, message) => { if (!condition) throw new Error(message) }
window.bookStateTransactionCases = [
    { name: 'ordinary chapter publication owns an event receipt', run: async () => {
        const f = await makeBookStateRuntimeFixture()
        expect(f.apply(f.result()), 'initial publication must be accepted')
        expect(f.visible() === 'Revision 1', 'visible chapter was not updated')
        expect(f.runtime.isEventCurrent(f.runtime.captureEvent(f.doc)), 'current event must remain owned')
        f.close()
    } },
    { name: 'ordinary End of Book button dispatches exactly one native command', run: async () => {
        const f = await makeBookStateRuntimeFixture({ end: true })
        expect(f.apply(f.result()), 'end page publication rejected')
        expect(!f.runtime.endcap.button.disabled, 'Finish Book must be enabled')
        f.runtime.endcap.button.click()
        await f.tick()
        expect(f.commands.length === 1 && f.commands[0].action === 'finishBook', 'real button must dispatch once')
        expect(f.runtime.endcap.finished === false, 'command receipt must not select Finished')
        f.close()
    } },
    ...['state', 'context'].map(field => ({ name: field + ' copy failure leaves displayed state and original request intact', run: async () => {
        const f = await makeBookStateRuntimeFixture()
        f.apply(f.result())
        const event = f.runtime.captureEvent(f.doc)
        f.runtime.state.refresh()
        const bad = f.result(99)
        bad[field].toJSON = () => { throw new Error('serialization unavailable') }
        expect(f.apply(bad) === false, 'copy failure must be rejected without throwing')
        expect(f.visible() === 'Revision 1', 'failed copy changed the visible chapter')
        expect(f.runtime.isEventCurrent(event), 'failed copy retired a valid event')
        expect(f.apply(f.result(2)), 'same native request must accept an unpoisoned revision')
        expect(f.visible() === 'Revision 2', 'replacement reply was stranded')
        f.close()
    } })),
    ...['state', 'context'].map(field => ({ name: field + ' copying cannot repaint a successor publication', run: async () => {
        const f = await makeBookStateRuntimeFixture()
        f.apply(f.result())
        f.runtime.state.refresh()
        const old = f.result(10)
        old[field].toJSON = function () {
            delete this.toJSON
            expect(f.native(f.result(20)), 'nested current publication failed')
            return this
        }
        expect(f.apply(old) === false, 'older publication was acknowledged')
        expect(f.visible() === 'Revision 20' && f.runtime.state.state.revision === 20, 'old copy replaced successor state')
        f.close()
    } })),
    { name: 'post error after accepted End of Book reply does not disable Finish', run: async () => {
        const f = await makeBookStateRuntimeFixture({ end: true })
        f.apply(f.result())
        f.runtime.state.postMessage = packet => {
            f.requests.push(packet)
            expect(f.runtime.state.apply(packet.requestID, f.result(2)), 'synchronous native reply rejected')
            throw new Error('post wrapper failed after reply')
        }
        expect(f.runtime.state.refresh() === false, 'post failure not reported')
        expect(!f.runtime.endcap.button.disabled && f.runtime.state.ready, 'accepted Finish control was disabled')
        f.runtime.endcap.button.click()
        await f.tick()
        expect(f.commands.length === 1, 'real Finish click was stranded')
        f.close()
    } },
    { name: 'old failing post cannot consume a nested same-ID request', run: async () => {
        const f = await makeBookStateRuntimeFixture({ end: true })
        f.apply(f.result())
        f.runtime.state.makeRequestID = () => 'same-state-id'
        f.runtime.state.postMessage = packet => {
            f.requests.push(packet)
            f.runtime.state.postMessage = next => f.requests.push(next)
            f.runtime.state.refresh()
            throw new Error('old bridge failed')
        }
        expect(f.runtime.state.refresh() === false, 'old call should report post failure')
        expect(f.apply(f.result(2)), 'nested native reply was consumed')
        expect(!f.runtime.endcap.button.disabled, 'nested accepted reply did not enable Finish')
        f.close()
    } },
    { name: 'fresh account callback retains its actual runtime scope receipt', run: async () => {
        const f = await makeBookStateRuntimeFixture()
        f.apply(f.result())
        let captured = null
        const change = f.runtime.endcap.accountDidChange.bind(f.runtime.endcap)
        f.runtime.endcap.accountDidChange = () => {
            change()
            f.runtime.state.refresh()
            expect(f.apply(f.result(1, '2:1')), 'callback current-account reply rejected')
            captured = f.runtime.captureEvent(f.doc)
        }
        const admitted = f.runtime.accountDidChange('2:1')
        expect(captured && f.runtime.isEventCurrent(captured), 'older invalidation retired the new event receipt')
        expect(admitted === false, 'superseded account signal must not enqueue another request')
        expect(f.visible() === 'Revision 1', 'older invalidation cleared newly painted current account')
        f.close()
    } },
    { name: 'account callback queued request is retained after old scope invalidation', run: async () => {
        const f = await makeBookStateRuntimeFixture()
        f.apply(f.result())
        const old = f.runtime.captureEvent(f.doc)
        const change = f.runtime.endcap.accountDidChange.bind(f.runtime.endcap)
        f.runtime.endcap.accountDidChange = () => { change(); f.runtime.state.refresh() }
        const count = f.requests.length
        expect(f.runtime.accountDidChange('2:1') === false, 'callback already requested the new sample')
        expect(f.requests.length === count + 1, 'old account call duplicated the queued request')
        expect(!f.runtime.isEventCurrent(old) && !f.runtime.state.ready, 'old account scope was not invalidated')
        expect(f.apply(f.result(1, '2:1')), 'retained fresh account request rejected')
        f.close()
    } },
    { name: 'modern onState lookup cannot run its returned stale renderer', run: async () => {
        const f = await makeBookStateRuntimeFixture()
        f.apply(f.result())
        f.runtime.state.refresh()
        const original = f.runtime.state.onState
        let calls = 0
        Object.defineProperty(f.runtime.state, 'onState', { configurable: true, get() {
            Object.defineProperty(f.runtime.state, 'onState', { configurable: true, writable: true, value: original })
            expect(f.native(f.result(20)), 'nested publication rejected')
            return () => calls++
        } })
        expect(f.apply(f.result(10)) === false, 'stale publication should not acknowledge')
        expect(calls === 0 && f.visible() === 'Revision 20', 'stale renderer executed')
        f.close()
    } },
    { name: 'a queued read-only refresh does not withdraw accepted endcap presentation', run: async () => {
        const f = await makeBookStateRuntimeFixture({ end: true })
        const original = f.runtime.state.onState
        f.runtime.state.onState = (...args) => { Reflect.apply(original, f.runtime.state, args); f.runtime.state.refresh() }
        expect(f.apply(f.result()), 'queued refresh invalidated accepted state')
        expect(!f.runtime.endcap.button.disabled, 'accepted endcap is not ready')
        f.runtime.state.onState = original
        expect(f.apply(f.result(2)), 'queued refresh lost its original request')
        f.close()
    } },
    { name: 'a newer manual watermark prevents old native display acknowledgement', run: async () => {
        const f = await makeBookStateRuntimeFixture()
        const original = f.runtime.state.onState
        f.runtime.state.onState = (...args) => {
            Reflect.apply(original, f.runtime.state, args)
            f.runtime.state.noteManualReadSnapshot(20)
        }
        expect(f.apply(f.result(10)) === false, 'old native snapshot was acknowledged after newer Mark')
        expect(f.native(f.result(19)) === false, 'older follow-up bypassed the manual watermark')
        f.close()
    } },
    ...['post lookup', 'post error'].map(boundary => ({ name: boundary + ' releases only its own withdrawn read after a newer Mark', run: async () => {
        const f = await makeBookStateRuntimeFixture({ end: true })
        expect(f.apply(f.result()), 'initial endcap publication rejected')
        let withdrawnID = null
        const makeID = f.runtime.state.makeRequestID
        f.runtime.state.makeRequestID = () => (withdrawnID = makeID())
        const fail = () => {
            f.runtime.state.noteManualReadSnapshot(20)
            throw new Error('read failed')
        }
        if (boundary === 'post lookup') {
            const original = f.runtime.state.postMessage
            Object.defineProperty(f.runtime.state, 'postMessage', { configurable: true, get() {
                Object.defineProperty(f.runtime.state, 'postMessage', { configurable: true, writable: true, value: original })
                f.runtime.state.noteManualReadSnapshot(20)
                return () => { throw new Error('retired callback must not execute') }
            } })
        } else f.runtime.state.postMessage = fail
        expect(f.runtime.state.refresh() === false, 'withdrawn read was not rejected')
        expect(f.runtime.state.ready && !f.runtime.endcap.button.disabled, 'read failure disabled the newer display')
        expect(f.runtime.state.apply(withdrawnID, f.result(21)) === false, 'withdrawn read accepted a late reply')
        f.runtime.state.postMessage = packet => f.requests.push(packet)
        f.runtime.state.refresh()
        expect(f.apply(f.result(19)) === false, 'withdrawal erased the newer Mark ordering')
        expect(f.apply(f.result(21)), 'fresh request could not recover')
        f.runtime.endcap.button.click()
        await f.tick()
        expect(f.commands.length === 1, 'fresh End of Book control remained unclickable')
        f.close()
    } })),
    { name: 'closing during copy does not leave a resurrected context', run: async () => {
        const f = await makeBookStateRuntimeFixture()
        const packet = f.result()
        packet.context.toJSON = function () { delete this.toJSON; f.runtime.close(); return this }
        expect(f.apply(packet) === false, 'closed publication was acknowledged')
        expect(f.runtime.state.context === null && f.runtime.state.state === null, 'closed controller retained a resurrected result')
        expect(document.querySelector('.manabi-book-endcap') === null, 'endcap was not destroyed')
    } },
]
