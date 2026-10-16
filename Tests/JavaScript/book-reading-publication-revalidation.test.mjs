import assert from 'node:assert/strict';
import test from 'node:test';
import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js';

const response = (sequence = 1, stamp = '1:1') => {
    const scope = { articleProgressID: 'book', articleEpochID: 'E1',
        chapterKey: 'a'.repeat(64), chapterEpochID: null };
    return { ok: true, accountPresentation: stamp,
        state: { revision: sequence, articleProgressID: 'book', articleEpochID: 'E1',
            scope, finished: false, bookReadPresence: 'present', chapterReadPresence: 'present',
            readSegmentIdentifiers: [`segment-${sequence}`], sentenceIdentifiersRead: [] },
        context: { contextID: `context-${sequence}`, articleProgressID: 'book', articleEpochID: 'E1',
            scope, sectionLocation: 'chapter.xhtml', isEndPage: false } };
};
function fixture() {
    const messages = [];
    let sequence = 0;
    const state = new BookReadingStateController({
        postMessage: message => messages.push(message), documentStartedAtMs: 1,
        topWindowURL: 'ebook://ebook/load/book.epub', makeRequestID: () => String(++sequence),
        requiresAccountPresentation: true,
    });
    state.setAccountPresentation('1:1');
    state.relocate({ sectionURL: 'chapter' });
    return { state, messages, publish: value => state.apply(messages.at(-1).requestID, value) };
}

test('publication cannot acknowledge a controller closed by its projection callback', () => {
    const f = fixture();
    f.state.onState = () => f.state.close();
    assert.equal(f.publish(response()), false);
    assert.equal(f.state.ready, false);
});

test('publication cannot acknowledge a chapter relocated by its projection callback', () => {
    const f = fixture();
    f.state.onState = () => f.state.relocate({ sectionURL: 'next-chapter' });
    assert.equal(f.publish(response()), false);
    assert.equal(f.state.location.sectionURL, 'next-chapter');
    assert.equal(f.state.ready, false);
    f.state.onState = () => {};
    assert.equal(f.publish(response(2)), true, 'The old acknowledgement must not discard the successor request.');
});

test('publication cannot acknowledge the successor account from its projection callback', () => {
    const f = fixture();
    f.state.onState = () => f.state.setAccountPresentation('2:1');
    assert.equal(f.publish(response()), false);
    assert.equal(f.state.accountPresentation, '2:1');
    assert.equal(f.state.context, null);
    f.state.onState = () => {};
    f.state.refresh();
    assert.equal(f.publish(response(1, '2:1')), true);
});

test('a reentrant newer publication retains its own state and rejects the outer acknowledgement', () => {
    const f = fixture();
    f.state.onState = () => {
        f.state.onState = () => {};
        f.state.refresh();
        assert.equal(f.publish(response(2)), true);
    };
    assert.equal(f.publish(response(1)), false);
    assert.equal(f.state.context.contextID, 'context-2');
    assert.deepEqual(f.state.state.readSegmentIdentifiers, ['segment-2']);
});

test('equal-valued reentrant publication still owns a distinct acknowledgement', () => {
    const f = fixture();
    f.state.onState = () => {
        f.state.onState = () => {};
        f.state.refresh();
        assert.equal(f.publish(response(1)), true);
    };
    assert.equal(f.publish(response(1)), false);
    assert.equal(f.state.context.contextID, 'context-1');
    assert.equal(f.state.ready, true);
});

test('document replacement during projection is rechecked before native acknowledgement', () => {
    const f = fixture();
    let current = true;
    f.state.isLocationCurrent = () => current;
    f.state.onState = () => { current = false; };
    assert.equal(f.publish(response()), false);
    assert.equal(f.state.ready, false);
});

test('ordinary projection acknowledges and supplies defensive copies', () => {
    const f = fixture();
    f.state.onState = (state, context) => {
        state.readSegmentIdentifiers.length = 0;
        context.contextID = 'mutated callback copy';
    };
    assert.equal(f.publish(response()), true);
    assert.deepEqual(f.state.state.readSegmentIdentifiers, ['segment-1']);
    assert.equal(f.state.context.contextID, 'context-1');
});

test('a background refresh does not withdraw the still-current visible publication', () => {
    const f = fixture();
    f.state.onState = () => f.state.refresh();
    assert.equal(f.publish(response()), true);
    assert.equal(f.state.ready, true);
    f.state.onState = () => {};
    assert.equal(f.publish(response(2)), true);
});

test('rejected same-chapter repaint withdraws old Book action context but keeps new read', () => {
    const f=fixture(), old=f.messages[0];
    f.state.onState=()=>{ f.state.relocate({sectionURL:'chapter'},{moved:true}); return false; };
    assert.equal(f.state.apply(old.requestID,response(2)),false);
    assert.equal(f.messages.length,2);
    assert.equal(f.state.ready,false);
    assert.equal(f.state.context,null);
    assert.equal(f.state.captureScope('chapter'),null);
    assert.throws(()=>f.state.captureContext());
    f.state.onState=()=>{};
    assert.equal(f.state.apply(f.messages.at(-1).requestID,response(3)),true);
    assert.equal(f.state.context.contextID,'context-3');
});
test('void callback invalidated by same-chapter movement cannot cache rejected projection', () => {
    const f=fixture(), old=f.messages[0];
    f.state.onState=()=>{ f.state.relocate({sectionURL:'chapter'},{moved:true}); };
    assert.equal(f.state.apply(old.requestID,response(2)),false);
    assert.equal(f.state.ready,false);
    assert.equal(f.state.context,null);
    f.state.onState=()=>{};
    assert.equal(f.state.apply(f.messages.at(-1).requestID,response(3)),true);
});
test('throwing renderer callback after movement withdraws rejected state', () => {
    const f=fixture(), old=f.messages[0];
    f.state.onState=()=>{f.state.relocate({sectionURL:'chapter'},{moved:true});throw Error('display declined')};
    assert.throws(()=>f.state.apply(old.requestID,response(2)),/display declined/);
    assert.equal(f.state.ready,false);
    assert.equal(f.state.context,null);
    f.state.onState=()=>{};
    assert.equal(f.state.apply(f.messages.at(-1).requestID,response(3)),true);
});
test('same-chapter move and newer native sequence retain ordering and pending read', () => {
    const f=fixture(), old=f.messages[0];
    f.state.onState=()=>{assert.equal(f.state.noteManualReadSnapshot(9),true);
        f.state.relocate({sectionURL:'chapter'},{moved:true});return false;};
    assert.equal(f.state.apply(old.requestID,response(2)),false);
    assert.equal(f.state.ready,false);
    assert.equal(f.state.noteManualReadSnapshot(8),false);
    f.state.onState=()=>{};
    const pending=f.messages.at(-1);
    assert.equal(f.state.apply(pending.requestID,response(8)),false);
    assert.equal(f.state.apply(pending.requestID,response(10)),true);
    assert.equal(f.state.state.revision,10);
});
test('actual successor publication survives an older rejected repaint after movement', () => {
    const f=fixture(), old=f.messages[0];
    f.state.onState=()=>{f.state.onState=()=>{};f.state.relocate({sectionURL:'chapter'},{moved:true});
        assert.equal(f.state.apply(f.messages.at(-1).requestID,response(3)),true);return false;};
    assert.equal(f.state.apply(old.requestID,response(2)),false);
    assert.equal(f.state.ready,true);
    assert.equal(f.state.context.contextID,'context-3');
});
test('accepted prior Book state remains available during an ordinary movement', () => {
    const f=fixture();
    assert.equal(f.publish(response(1)),true);
    f.state.relocate({sectionURL:'chapter'},{moved:true});
    assert.equal(f.state.ready,true);
    assert.equal(f.state.context.contextID,'context-1');
    assert.equal(f.publish(response(2)),true);
});
test('rejected recovery after movement does not restore old History or block new native sample', async () => {
    const f=fixture();
    assert.equal(f.publish(response(1)),true);
    const proof={requestID:'unmark',observationToken:'proof'};
    const scope=f.state.captureScope('chapter');
    assert.equal(f.state.beginHistoryReadingStatusRecovery(proof,scope),true);
    const completion=f.state.recoverHistoryReadingStatus(proof), sample=f.messages.at(-1);
    f.state.onState=()=>{f.state.relocate({sectionURL:'chapter'},{moved:true});return false;};
    assert.equal(f.state.apply(sample.requestID,{...response(2),
        location:{sectionURL:sample.sectionURL,isEndPage:false,locationRevision:sample.locationRevision},
        historyRecoveryObservation:sample.historyRecoveryObservation}),false);
    assert.equal(await completion,false);
    assert.equal(f.state.ready,false);
    assert.equal(f.state.context,null);
    assert.equal(f.state.failHistoryReadingStatusRecovery(proof),false);
    assert.equal(f.messages.length,3);
    f.state.onState=()=>{};
    assert.equal(f.state.apply(f.messages.at(-1).requestID,response(3)),true);
    assert.equal(f.state.ready,true);
});
