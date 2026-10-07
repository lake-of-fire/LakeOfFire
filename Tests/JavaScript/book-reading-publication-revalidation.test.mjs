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
