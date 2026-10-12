import assert from 'node:assert/strict';
import { test } from 'node:test';
import { visibleMarkReadSidecarSelection } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-visible-mark-read-selection.js';

const a = { i: 'mnb-s1', sid: 'S:A', sentenceID: 'S', j: [123], n: [], s: 'word' };
const b = { i: 'mnb-s2', sid: 'S:B', sentenceID: 'S', j: [], n: [456], ns: 'name' };
const c = { i: 'mnb-s3', sid: 'T:C', sentenceID: 'T', j: [], n: [], x: '。' };
const fixture = (options = {}) => ({
    visibleSegmentIdentifiers: [a.sid],
    segmentIDsBySentenceID: new Map([['S', [a.i, b.i]], ['T', [c.i]]]),
    metadataByID: new Map([a, b, c].flatMap(metadata => [[metadata.i, metadata], [metadata.sid, metadata]])),
    ...options,
});

test('partial sentence selects only visible content, regardless of hidden read state', () => {
    for (const hiddenRead of [false, true]) {
        const metadataByID = fixture().metadataByID;
        metadataByID.set(b.sid, { ...b, isRead: hiddenRead });
        assert.deepEqual(visibleMarkReadSidecarSelection(fixture({ metadataByID })), [a]);
    }
});

test('fully visible sentence includes all visible word and name subjects', () => {
    assert.deepEqual(visibleMarkReadSidecarSelection(fixture({ visibleSegmentIdentifiers: [a.sid, b.sid] })), [a, b]);
});

test('runtime and stable aliases resolve to one durable sidecar subject', () => {
    assert.deepEqual(visibleMarkReadSidecarSelection(fixture({ visibleSegmentIdentifiers: [a.i, a.sid, b.i] })), [a, b]);
    assert.deepEqual(visibleMarkReadSidecarSelection(fixture({
        segmentIDsBySentenceID: new Map([['S', [a.sid, b.sid]]]),
    })), [a]);
});

test('selected subjects may span sentences without adding either hidden remainder', () => {
    assert.deepEqual(visibleMarkReadSidecarSelection(fixture({ visibleSegmentIdentifiers: [a.sid, c.sid] })), [a, c]);
});

test('missing sidecar, unknown identities and missing or malformed membership fail closed', () => {
    for (const override of [
        { metadataByID: undefined }, { metadataByID: new Map() },
        { visibleSegmentIdentifiers: ['missing'] }, { visibleSegmentIdentifiers: [null] },
        { segmentIDsBySentenceID: undefined }, { segmentIDsBySentenceID: new Map() },
        { segmentIDsBySentenceID: new Map([['S', []]]) },
        { segmentIDsBySentenceID: new Map([['S', 'not-an-array']]) },
        { segmentIDsBySentenceID: new Map([['S', [b.i]]]) },
    ]) assert.equal(visibleMarkReadSidecarSelection(fixture(override)), null);
});

test('malformed identity and sentence facts cannot infer membership from a DOM node', () => {
    const node = new Proxy({}, { get() { throw new Error('DOM consulted'); } });
    for (const metadata of [{ ...a, sid: '' }, { ...a, sentenceID: '' }, { ...a, sid: b.sid, i: b.i }]) {
        assert.equal(visibleMarkReadSidecarSelection(fixture({
            metadataByID: new Map([[a.sid, { ...metadata, node }]]),
        })), null);
    }
    const authoritative = { ...a, node };
    assert.deepEqual(visibleMarkReadSidecarSelection(fixture({ metadataByID: new Map([[a.sid, authoritative]]) })), [authoritative]);
});

test('selection never materializes hidden sidecar metadata', () => {
    const requested = [];
    const metadataByID = { get(identifier) {
        requested.push(identifier);
        assert.equal(identifier, a.sid);
        return a;
    } };
    assert.deepEqual(visibleMarkReadSidecarSelection(fixture({ metadataByID })), [a]);
    assert.deepEqual(requested, [a.sid]);
});

test('empty visible selection remains empty', () => {
    assert.deepEqual(visibleMarkReadSidecarSelection(fixture({ visibleSegmentIdentifiers: [] })), []);
});
