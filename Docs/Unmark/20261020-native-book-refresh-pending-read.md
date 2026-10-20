# Preserve pending chapter reads across native post-commit publication

## Scope

LakeOfFire `v3-hotfix` at `997c442ebdaa53c7c18fc8e75fa33e105e4242bf`.
The baseline `book-reading-state.js` blob is
`4eac31cbaca11b62d4b685eba562467abbd14340`.

## Failure

The native `ReaderBookReadingState.refreshAfterMutation` path reuses its
`lastRequest` and calls `receive(..., nativeRefresh: true)`. Independently,
Book/catalog/read-publication notifications and renderer location observations
can ask the JavaScript controller to issue another chapter-state query in the
same location revision. The native publication may arrive after that new query
was posted, before its response.

`BookReadingStateController.#apply` correctly accepts a native refresh by its
account, location, and native snapshot sequence rather than requiring it to
match the pending query. However, both its success and failure paths then cleared
`#pending` unconditionally. They consumed a different query's response slot.
The eventual matching reply was rejected before native sequence comparison.

This can leave an older Read projection visible after an Unmark, or leave Book
Actions unavailable after the unrelated native publication failed. Recovery
would require another read even though one was already in flight.

A concrete order, with one account and unchanged chapter/location revision:

1. Read query A publishes marked coverage at native sequence 10.
2. Read query B is issued while a native post-commit publication still names A.
3. Native publication A arrives with sequence 11, or with a read failure.
4. B returns post-Unmark coverage at sequence 12.
5. Baseline rejects B because A cleared B's pending slot.

## Change

Compute whether the delivery's request ID matches the captured pending read.
Only that delivery may consume its slot. An unrelated native refresh may still
publish its ordered snapshot, or withdraw its failed presentation, without
consuming the in-flight query. No extra query, retry, or mutation is introduced.

Existing account changes, chapter/location replacement, history-recovery
correlation, native sequence ordering, and same-request terminal consumption
retain their own admission rules. A replacement account still discards the old
query; a newer callback-issued query still supersedes its predecessor.

## Focused evidence

The tests import the complete production controller and UUID utility. Their
baseline bytes were verified against the Git blobs before execution. Native
payloads and arrival order are controlled collaborators, not a Realm writer or
WKWebView simulation.

`node --test Tests/JavaScript/book-native-refresh-pending-read.test.mjs`

- Unchanged baseline: 4 passed, 6 failed; exit 1.
- Patched source: 10 passed, 0 failed; exit 0 (Node 22.16.0).
- `node --check` on the changed production module: exit 0.

Coverage includes native success, native failure, declined and throwing
projection, unsolicited publication, exact-query consumption, old sequence
rejection, callback-issued query supersession, account replacement, and
location mismatch. These assertions establish the JavaScript correlation bug;
they do not establish native timing frequency or full application acceptance.

Full JavaScript suite, Swift/XCTest, Realm, and real WebKit are deferred. No
application dependency pin or native mutation code is changed by this patch.
