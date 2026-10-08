import assert from 'node:assert/strict';
import test from 'node:test';
import { createBookActionBridge } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-action-bridge.js';

const requestID = '11111111-1111-4111-8111-111111111111';
function fixture(action = 'startChapterOver') {
    const messages = [], timers = new Map();
    let nextTimer = 0;
    const bridge = createBookActionBridge({
        postMessage: value => messages.push(value), makeRequestID: () => requestID,
        documentStartedAtMs: 123, topWindowURL: 'ebook://ebook/load/book.epub',
        captureContext: () => ({contextID: 'context', locationRevision: 1}),
        setTimer: callback => { timers.set(++nextTimer, callback); return nextTimer; },
        clearTimer: token => timers.delete(token),
    });
    const acknowledge = (message, body) => bridge.acknowledge(message.deliveryID, {requestID, ...body});
    return {bridge, messages, timers, acknowledge, action};
}
for (const navigation of [undefined, {status:'pending'}]) {
    test(`committed reset is still pending until navigation resolves (${navigation?.status ?? 'absent'})`, async () => {
        const f = fixture();
        const promise = f.bridge.perform(f.action);
        f.acknowledge(f.messages[0], {ok:true, committed:true, navigation});
        assert.equal((await promise).pending, true);
        assert.equal(f.bridge.recoveryInfo.kind, 'status');
        await assert.rejects(f.bridge.perform(f.action), error => error.outcomeUnknown === true);
        const status = f.bridge.recover();
        assert.equal(f.messages.at(-1).kind, 'status');
        f.acknowledge(f.messages.at(-1), {ok:true, committed:true, navigation:{status:'failed',message:'Could not move'}});
        assert.equal((await status).navigation.status, 'failed');
        assert.equal(f.bridge.recoveryInfo.kind, 'navigate');
        const retry = f.bridge.recover();
        const secondRetry = f.bridge.recover();
        assert.equal(retry, secondRetry);
        assert.equal(f.messages.at(-1).kind, 'navigate');
        f.acknowledge(f.messages.at(-1), {ok:true, committed:true, navigation:{status:'completed'}});
        await retry;
        assert.equal(f.bridge.recoveryInfo, null);
        assert.deepEqual(f.messages.map(x => x.kind), ['command','status','navigate']);
        assert.equal(f.timers.size, 0);
    });
}
test('Finish remains terminal without a navigation result', async () => {
    const f = fixture('finishBook');
    const promise = f.bridge.perform(f.action);
    f.acknowledge(f.messages[0], {ok:true, committed:true});
    assert.equal((await promise).ok, true);
    assert.equal(f.bridge.recoveryInfo, null);
    assert.equal(f.timers.size, 0);
});
test('correlated rejection settles immediately instead of timing out unknown', async () => {
    const f = fixture();
    const promise = f.bridge.perform(f.action);
    f.acknowledge(f.messages[0], {ok:false,error:'Chapter changed'});
    assert.equal((await promise).error, 'Chapter changed');
    assert.equal(f.bridge.recoveryInfo, null);
    assert.equal(f.timers.size, 0);
});
test('mismatched reply cannot complete another request', async () => {
    const f = fixture();
    const promise = f.bridge.perform(f.action);
    assert.equal(f.bridge.acknowledge(f.messages[0].deliveryID, {requestID:'wrong',ok:false}), false);
    assert.equal(f.bridge.recoveryInfo.requestID, requestID);
    f.acknowledge(f.messages[0], {ok:false,error:'Rejected'});
    await promise;
});
test('pending status never drops a later command navigation failure', async () => {
    const f = fixture();
    const original = f.bridge.perform(f.action);
    const timeout = [...f.timers.values()][0]; timeout();
    await assert.rejects(original, e => e.outcomeUnknown === true);
    const status = f.bridge.recover();
    f.acknowledge(f.messages[1], {pending:true,committed:true});
    assert.equal((await status).pending, true);
    const status2 = f.bridge.recover();
    f.acknowledge(f.messages[0], {ok:true,committed:true,navigation:{status:'failed'}});
    assert.equal((await status2).navigation.status, 'failed');
    assert.equal(f.bridge.recoveryInfo.kind, 'navigate');
    f.bridge.close();
});
test('duplicate navigation delivery is coalesced while pending', async () => {
    const f = fixture();
    const original = f.bridge.perform(f.action);
    f.acknowledge(f.messages[0], {ok:true,committed:true,navigation:{status:'failed'}});
    await original;
    const retry = f.bridge.recover();
    assert.equal(f.bridge.recover(), retry);
    assert.equal(f.messages.length, 2);
    f.acknowledge(f.messages[1], {ok:true,committed:true,navigation:{status:'superseded'}});
    assert.equal((await retry).navigation.status, 'superseded');
    assert.equal(f.bridge.recoveryInfo, null);
});
test('lost navigation acknowledgement asks native status instead of returning cached failure', async () => {
    const f = fixture();
    const original = f.bridge.perform(f.action);
    f.acknowledge(f.messages[0], {ok:true,committed:true,navigation:{status:'failed'}});
    await original;
    const retry = f.bridge.recover();
    [...f.timers.values()][0]();
    await assert.rejects(retry, e => e.outcomeUnknown === true);
    assert.equal(f.bridge.recoveryInfo.kind, 'status');
    const status = f.bridge.recover();
    assert.equal(f.messages.at(-1).kind, 'status');
    f.acknowledge(f.messages.at(-1), {ok:true,committed:true,navigation:{status:'completed'}});
    assert.equal((await status).navigation.status, 'completed');
    assert.deepEqual(f.messages.map(x => x.kind), ['command','navigate','status']);
});
