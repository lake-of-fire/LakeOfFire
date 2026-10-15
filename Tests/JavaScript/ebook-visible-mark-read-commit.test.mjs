import assert from 'node:assert/strict';
import { test } from 'node:test';
import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js';
import { createNativeMarkReadRequestCoordinator, nativeMarkReadCommandMessage, refreshCommittedVisibleMarkReadState, committedVisibleMarkReadStateIsPresented } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js';

const chapter = 'https://reader.invalid/chapter-one';
const scope = { articleProgressID: 'article', articleEpochID: null, chapterKey: 'a'.repeat(64), chapterEpochID: null };
const snapshot = (revision, segments = ['old'], sentences = []) => ({
    ok: true, accountPresentation: '1:0',
    state: { revision, articleProgressID: 'article', articleEpochID: null, finished: false,
        bookReadPresence: 'present', chapterReadPresence: 'present', scope,
        readSegmentIdentifiers: segments, sentenceIdentifiersRead: sentences },
    context: { contextID: 'context', articleProgressID: 'article', articleEpochID: null,
        isEndPage: false, sectionLocation: chapter, scope },
});
const setup = () => {
    const requests = [];
    let displayed, current = true, failRefresh = false, retireOnRefresh = false, failPublication = false, publicationSequence = 0;
    const state = new BookReadingStateController({
        postMessage: message => {
            if (failRefresh) throw new Error('transport unavailable');
            requests.push(message);
            if (retireOnRefresh) current = false;
        },
        documentStartedAtMs: 1, topWindowURL: 'https://reader.invalid',
        makeRequestID: () => `state-${requests.length + 1}`,
        onState: projection => {
            displayed = projection;
            if (failPublication) throw new Error('publication unavailable');
            publicationSequence = projection.revision;
        },
    });
    state.relocate({ sectionURL: chapter, isEndPage: false });
    assert.equal(state.apply(requests.at(-1).requestID, snapshot(1)), true);
    let posted;
    const coordinator = createNativeMarkReadRequestCoordinator({
        postMessage: message => { posted = message; }, postControlMessage: () => {},
        isOwnerCurrent: () => current, makeRequestID: () => 'mark',
        scheduleTimeout: () => 1, cancelTimeout: () => {}, lifecycleTarget: {},
    });
    const payload = { stableIdentityVersion: 1, nativeSidecarContentFingerprint: 'fingerprint',
        segments: [{ stableSegmentID: 'visible-name' }, { stableSegmentID: 'visible-punctuation' }], sentenceIdentifiers: [] };
    const completion = coordinator.request({ sectionID: 'visible', owner: {},
        context: { payload }, message: nativeMarkReadCommandMessage(payload) });
    const reply = (overrides = {}) => ({
        requestID: posted.requestID, sectionId: 'visible', success: true,
        manualReadPendingProtocol: 1, manualReadPendingObservationToken: posted.manualReadPendingObservationToken,
        manualReadPendingState: 'finished', stateSnapshotSequence: 2,
        // These are request-scoped and must not replace the chapter projection.
        displayEffectiveStableSegmentIDs: ['visible-name', 'visible-punctuation'],
        displayEffectiveStableSentenceIDs: [], ...overrides,
    });
    return { state, requests, coordinator, completion, reply,
        get displayed() { return displayed; }, get posted() { return posted; },
        get publicationSequence() { return publicationSequence; },
        isCurrent: () => current, retire: () => { current = false; },
        failRefresh: () => { failRefresh = true; },
        retireOnRefresh: () => { retireOnRefresh = true; },
        failPublication: () => { failPublication = true; } };
};

test('successful exact visible request refreshes and displays only the full native state', async () => {
    const fixture = setup();
    assert.deepEqual(fixture.posted.stableSegmentIDs, ['visible-name', 'visible-punctuation']);
    assert.deepEqual(fixture.posted.sentenceIdentifiers, []);
    assert.equal(fixture.coordinator.settle(fixture.reply()), true);
    const outcome = await fixture.completion;
    assert.equal(refreshCommittedVisibleMarkReadState({ outcome, state: fixture.state, isOwnerCurrent: fixture.isCurrent }), true);
    assert.deepEqual(fixture.displayed.readSegmentIdentifiers, ['old']);
    assert.deepEqual(fixture.displayed.sentenceIdentifiersRead, []);
    assert.equal(fixture.state.apply(fixture.requests.at(-1).requestID,
        snapshot(2, ['old', 'visible-name', 'visible-punctuation'], ['native-completed-sentence'])), true);
    assert.deepEqual(fixture.displayed.readSegmentIdentifiers, ['old', 'visible-name', 'visible-punctuation']);
    assert.deepEqual(fixture.displayed.sentenceIdentifiersRead, ['native-completed-sentence']);
    assert.equal(committedVisibleMarkReadStateIsPresented({ state: fixture.state,
        minimumSnapshotSequence: 2, stableSegmentIDs: ['visible-name', 'visible-punctuation'],
        successfulPublicationSequence: fixture.publicationSequence }), true);
});

test('native failure or stale owner never requests refresh or paints submitted IDs', async () => {
    for (const stale of [false, true]) {
        const fixture = setup();
        if (stale) fixture.retire();
        fixture.coordinator.settle(fixture.reply({ success: stale }));
        assert.equal(refreshCommittedVisibleMarkReadState({ outcome: await fixture.completion,
            state: fixture.state, isOwnerCurrent: fixture.isCurrent }), false);
        assert.equal(fixture.requests.length, 1);
        assert.deepEqual(fixture.displayed.readSegmentIdentifiers, ['old']);
    }
});

test('owner retirement after acknowledgement prevents refresh at its effect edge', async () => {
    const fixture = setup();
    fixture.coordinator.settle(fixture.reply());
    const outcome = await fixture.completion;
    fixture.retire();
    assert.equal(refreshCommittedVisibleMarkReadState({ outcome, state: fixture.state, isOwnerCurrent: fixture.isCurrent }), false);
    assert.equal(fixture.requests.length, 1);
});

test('failed refresh retains displayed progress and cannot infer submitted subjects', async () => {
    const fixture = setup();
    fixture.coordinator.settle(fixture.reply());
    fixture.failRefresh();
    assert.equal(refreshCommittedVisibleMarkReadState({ outcome: await fixture.completion,
        state: fixture.state, isOwnerCurrent: fixture.isCurrent }), false);
    assert.deepEqual(fixture.displayed.readSegmentIdentifiers, ['old']);
    assert.deepEqual(fixture.displayed.sentenceIdentifiersRead, []);
});

test('owner retirement while posting refresh prevents the subsequent presentation edge', async () => {
    const fixture = setup();
    fixture.coordinator.settle(fixture.reply());
    fixture.retireOnRefresh();
    assert.equal(refreshCommittedVisibleMarkReadState({ outcome: await fixture.completion,
        state: fixture.state, isOwnerCurrent: fixture.isCurrent }), false);
    assert.equal(fixture.requests.length, 2);
    assert.deepEqual(fixture.displayed.readSegmentIdentifiers, ['old']);
});

test('older native commit sequence cannot start a refresh over a newer projection', async () => {
    const fixture = setup();
    fixture.coordinator.settle(fixture.reply({ stateSnapshotSequence: 0 }));
    assert.equal(refreshCommittedVisibleMarkReadState({ outcome: await fixture.completion,
        state: fixture.state, isOwnerCurrent: fixture.isCurrent }), false);
    assert.equal(fixture.requests.length, 1);
    assert.deepEqual(fixture.displayed.readSegmentIdentifiers, ['old']);
});

test('late refresh after chapter or account changes cannot publish old read state', async () => {
    for (const changedAccount of [false, true]) {
        const fixture = setup();
        fixture.coordinator.settle(fixture.reply());
        assert.equal(refreshCommittedVisibleMarkReadState({ outcome: await fixture.completion,
            state: fixture.state, isOwnerCurrent: fixture.isCurrent }), true);
        const oldRequest = fixture.requests.at(-1).requestID;
        if (changedAccount) fixture.state.setAccountPresentation('2:0');
        else fixture.state.relocate({ sectionURL: 'https://reader.invalid/chapter-two', isEndPage: false });
        assert.equal(fixture.state.apply(oldRequest, snapshot(2, ['late-old-subject'])), false);
        assert.deepEqual(fixture.displayed.readSegmentIdentifiers, ['old']);
    }
});

test('wrong acknowledgement capability remains pending and cannot request state refresh', async () => {
    const fixture = setup();
    assert.equal(fixture.coordinator.settle(fixture.reply({ manualReadPendingObservationToken: 'wrong' })), false);
    assert.equal(fixture.coordinator.pendingCount, 1);
    assert.equal(fixture.requests.length, 1);
    fixture.coordinator.settle(fixture.reply({ success: false }));
    await fixture.completion;
});

test('an accepted async refresh does not authorize advance until its full state actually applies', async () => {
    const fixture = setup();
    fixture.coordinator.settle(fixture.reply());
    assert.equal(refreshCommittedVisibleMarkReadState({ outcome: await fixture.completion,
        state: fixture.state, isOwnerCurrent: fixture.isCurrent }), true);
    assert.equal(committedVisibleMarkReadStateIsPresented({ state: fixture.state,
        minimumSnapshotSequence: 2, stableSegmentIDs: ['visible-name', 'visible-punctuation'],
        successfulPublicationSequence: fixture.publicationSequence }), false);
    // A failed asynchronous response withdraws its context, retaining the
    // displayed progress rather than pretending the page subjects were read.
    assert.equal(fixture.state.apply(fixture.requests.at(-1).requestID, { ok: false, accountPresentation: '1:0' }), false);
    assert.equal(committedVisibleMarkReadStateIsPresented({ state: fixture.state,
        minimumSnapshotSequence: 2, stableSegmentIDs: ['visible-name', 'visible-punctuation'],
        successfulPublicationSequence: fixture.publicationSequence }), false);
    assert.deepEqual(fixture.displayed.readSegmentIdentifiers, ['old']);
});

test('a malformed or stale asynchronous refresh cannot authorize advance', async () => {
    for (const revision of [1, 2]) {
        const fixture = setup();
        fixture.coordinator.settle(fixture.reply());
        assert.equal(refreshCommittedVisibleMarkReadState({ outcome: await fixture.completion,
            state: fixture.state, isOwnerCurrent: fixture.isCurrent }), true);
        const response = snapshot(revision, ['old', 'visible-name', 'visible-punctuation']);
        if (revision === 2) response.context.scope = null;
        assert.equal(fixture.state.apply(fixture.requests.at(-1).requestID, response), false);
        assert.equal(committedVisibleMarkReadStateIsPresented({ state: fixture.state,
            minimumSnapshotSequence: 2, stableSegmentIDs: ['visible-name', 'visible-punctuation'],
            successfulPublicationSequence: fixture.publicationSequence }), false);
    }
});

test('a newer native snapshot that removed a selected subject prevents advance', async () => {
    const fixture = setup();
    fixture.coordinator.settle(fixture.reply());
    assert.equal(refreshCommittedVisibleMarkReadState({ outcome: await fixture.completion,
        state: fixture.state, isOwnerCurrent: fixture.isCurrent }), true);
    assert.equal(fixture.state.apply(fixture.requests.at(-1).requestID, snapshot(3, ['old', 'visible-name'])), true);
    assert.equal(committedVisibleMarkReadStateIsPresented({ state: fixture.state,
        minimumSnapshotSequence: 2, stableSegmentIDs: ['visible-name', 'visible-punctuation'],
        successfulPublicationSequence: fixture.publicationSequence }), false);
});

test('a failed native state publication cannot authorize advance from the controller snapshot alone', async () => {
    const fixture = setup();
    fixture.coordinator.settle(fixture.reply());
    assert.equal(refreshCommittedVisibleMarkReadState({ outcome: await fixture.completion,
        state: fixture.state, isOwnerCurrent: fixture.isCurrent }), true);
    fixture.failPublication();
    assert.throws(() => fixture.state.apply(fixture.requests.at(-1).requestID,
        snapshot(2, ['old', 'visible-name', 'visible-punctuation'])), /publication unavailable/);
    assert.equal(fixture.state.state.revision, 2);
    assert.equal(committedVisibleMarkReadStateIsPresented({ state: fixture.state,
        minimumSnapshotSequence: 2, stableSegmentIDs: ['visible-name', 'visible-punctuation'],
        successfulPublicationSequence: fixture.publicationSequence }), false);
});
