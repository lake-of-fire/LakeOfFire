# Retire History recovery when moving within the same chapter

## Failure schedule

A completed Mark/Unmark can retain a separate History reading-status recovery.
The native request coordinator stops that record's status poll when native
admits its one read-only recovery query. A refused preparation or failed query
retains the failure notice and barrier, without automatically retrying.

`BookReadingStateController.relocate` already retires its History recovery on
any admitted movement, including a new physical location in the same chapter.
However, it called `onInvalidate` only for a different chapter/end-page location
or replaced physical document. On a same-chapter move the coordinator therefore
received no invalidation through Reader's existing `onInvalidate -> cancelAll`
connection. Its completed recovery is no longer in the pending-command map, and
an admitted/failed recovery has no observation timer left to discover departure.

The old failure notice can remain on the new page while the new native sample
is outstanding. A successful later full Viewer projection or an independent
admission/cleanup may eventually prune it, but that is not immediate retirement.
A separate held-query schedule also demonstrates delayed release of the old
local observer; this does not claim every real native query is non-cooperative.
The original saved/rejected command outcome is unchanged throughout.

## Correction

Before retiring the old recovery, capture whether this location transition
withdraws a projection: changed chapter/end page, replaced document, **or an
existing History recovery**. Reuse that decision for the existing context clear
and best-effort invalidation notification. The normal relocation read and its
post-callback ownership check stay unchanged.

This deliberately does not invalidate ordinary same-chapter cached state. A
successfully acknowledged recovery is no longer an active History recovery, so
its later ordinary same-chapter move also retains its accepted state. An
unchanged-location observation remains a no-op and cannot retry a failed sample.

The exact-recovery retirement from #230/#231, cancellation metadata and all other
#234 composition are retained. No new listener, timer, retry loop, coordinator,
request field, native permission, persistence or Undo-clock change is added.
No Cancel is sent for the completed command and no Mark/Unmark is replayed.

## Focused execution

The existing `native-mark-read-retired-recovery.test.mjs` retains its twelve
cases and adds nine. Tests import the complete production request coordinator,
Book state controller and recovery adapter with actual producer/UUID imports.
Native packets, EventTarget departure/return, ownership, notice and timer
callbacks are controlled collaborators. No production declaration extraction or
substitute module loader is used.

Node 22.16.0, identical final twenty-one-case selection:

| Source | Pass | Fail | Skipped/cancelled |
| --- | ---: | ---: | ---: |
| #234 before the correction | 15 | 6 | 0 |
| Corrected controller | 21 | 0 | 0 |

The six negative-control failures are stale-notice/wait/cleanup assertions for
one missing invalidation signal, not six independent product defects. The
expanded native-error cases actually send a negative reply through the real
Book controller. Other cases cover refused preparation, a held optional query,
pre-admission recovery, a cleanup-created replacement query, unchanged-location
failure preservation, ordinary cached-state preservation and successful recovery.

The final combined run with nineteen unchanged cancellation/recovery-composition
cases and twelve unchanged visible-Mark commit cases passes **52/52**, with no
failures, skips or cancellations. The twenty-one are included in fifty-two.

```sh
node --test --test-concurrency=1 \
  Tests/JavaScript/native-mark-read-retired-recovery.test.mjs \
  Tests/JavaScript/native-mark-read-cancel-recovery-integration.test.mjs \
  Tests/JavaScript/ebook-visible-mark-read-commit.test.mjs
```

Full changed JavaScript syntax and whitespace checks also pass. This is not a
full Viewer/browser/BFCache, native writer, Realm, Swift/XCTest, WKWebView or
device execution result. The held query and callback reentry are controlled
component schedules; customer incidence is not measured. Keep the PR draft for
an actual failed History refresh followed by a same-chapter page turn with the
replacement native read held.

## Source and integration

Base: Lake #234 `e1ad62c7eff6a136fd12b32cc4eb05bb66608a4d`.
Original controller: `b814b9818d2ca026ed8b0e5cd82589d6c68de0cf`.
Original regression owner: `6aba841963be22815a870a7cb406e356a6654be6`.
Unchanged request coordinator: `dfcccb13e68e68360916e6287937b2684014786b`.

Full original file bytes were checked against these Git blob identities before
editing. Only the existing controller, existing test file and this note change.
No existing integration head or app gitlink is moved, no shipping merge or
workflow dispatch occurs, and no schema or release setting changes.
