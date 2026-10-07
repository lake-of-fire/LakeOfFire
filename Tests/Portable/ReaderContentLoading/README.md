# Reader content load ownership and retry — October 6, 2026

## Confirmed failures

The existing `ReaderContent.load` had three related admission/lifetime gaps:

1. Cached and preloaded fast paths did not withdraw an unrelated in-flight load.
   After selecting B, a delayed A resolver could assign `content = A` while the
   displayed `pageURL` remained B. The stale assignment also emitted A's title
   and could return A to an already-waiting `getContent()` call.
2. A resolver error bypassed slot cleanup. A later explicit same-URL retry joined
   the retained failed task instead of loading again. Cleanup only in the original
   caller's continuation is insufficient: coalesced waiters can receive the error
   and retry before that original continuation resumes.
3. An already-cancelled load could consume preloaded content or displace another
   load before reaching the inner task's cancellation check.

These failures were reproduced with the complete original production class.
They are upstream of consumers that independently read `content` and `pageURL`,
including manual-read resolution. No claim is made that the historical Unmark
archive crash or a particular customer incident used these paths.

## Repair

Retain the existing task, URL and UUID ownership fields. Every non-coalesced,
non-suppressed load reserves its new identity and withdraws the previous slot
before cancellation or display publication. Fast paths use the same retirement
boundary as an ordinary load. Exact-ID cleanup runs inside the task before its
result wakes waiters, and also on synchronous fast-path exits. A predecessor's
success or error cannot clear a successor's slot.

The public method keeps the original native loader, URL, history-visit flag and
source label. A per-call internal resolver overload makes the real owner testable
without installing a global production hook. The overload has no separate state
machine. Unused diagnostic-only locals are removed. No new runtime type, lock,
queue, timer, retry loop, persisted field, Realm write or mutation authority.

Same-URL in-flight work still coalesces. Cancellation of an individual waiter
already attached to shared work does not cancel that work. Resolver errors still
reach the original/coalesced callers; no automatic retry is introduced. Suppressed
transient blank navigation, accepted content reuse, section-index behavior and
mismatch/nil-result rejection remain intact. This does not make direct arbitrary
external edits of every published property an atomic navigation transaction.

## Executed component verification

Reviewed full source: `Sources/LakeOfFireContent/Reader/ReaderContent.swift`,
blob `aa7669bb09906e74df1e767dd353d54effdb538b`, 9,680 bytes, at Reader-selected
Lake `fca4e8b570a978918b4d31770d4bf36de8735e68`.

Swift 6.2.1/Linux, Swift 5 package language mode, complete concurrency checking.
The repaired source builds with warnings as errors. The original has unused
logging variables, so its comparison run deliberately allows those warnings.
The same final 25 named XCTest methods execute in every row:

| Configuration | Passed | Failed |
| --- | ---: | ---: |
| Original complete class, public entry, optimized | 11 | 14 |
| Repaired class, public entry, Debug | 25 | 0 |
| Repaired class, public entry, optimized | 25 | 0 |
| Repaired class, direct resolver overload, optimized | 25 | 0 |
| Repaired class, public entry, ThreadSanitizer | 25 | 0 |

ThreadSanitizer emitted no race diagnostics. Tests use entry/release handshakes,
not sleep-based ordering. The 32-waiter test verifies immediate retry after a
shared failure. Five incorrect implementations produce runtime failures:
missing fast-path retirement (6), absent completion cleanup (7), initiator-only
late cleanup (1), unscoped cleanup (3), and missing entry cancellation (2).
Repeated configurations and failing schedules are not additional defect counts.

Nine runner contracts verify exact method accounting, contradictory statuses,
retained output and timeout cleanup of a separately grouped child. Zero tests,
skips, missing/duplicate/unexpected methods and build failures never count as
successful behavioral runs. Every command's status and per-method receipts are
retained. An early scaffold lacked Sendable on its actor-confined model interface;
an intermediate refactor also needed an explicit Task result type. Those failed
compilation attempts are retained separately, not counted in the table.

## What executes and what does not

The complete production `ReaderContent.swift`, its public wrapper, coalescing,
preload consumption, task publication and cleanup execute unchanged. The test
file in `Tests/LakeOfFireTests` uses unmanaged real HistoryRecord models and the
internal resolver overload in a native build. Those native tests have not been
compiled or executed on Apple platforms in this review.

The portable flag uses the same test histories via the public entry and a
controlled default loader. Linux supplies minimal SwiftUI/Combine interfaces and
an actor-confined content model; Foundation, Swift Tasks, Dispatch and XCTest are
real. A second portable run executes the direct-resolver branch of the authored
test file. The URL leaf supports ordinary exact HTTP(S) fixture URLs only, not the
production snippet/reader/EPUB alias contract. No native Session, Realm, history
persistence, provider, WebKit or Reader application is simulated or qualified.
On macOS the runner uses system SwiftUI/Combine, but still controls models/loaders.

## Reproduce

From LakeOfFire's root:

```sh
python3 Tests/Portable/ReaderContentLoading/run.py --output /tmp/content-load-debug
python3 Tests/Portable/ReaderContentLoading/run.py --optimized --output /tmp/content-load-release
python3 Tests/Portable/ReaderContentLoading/run.py --optimized --direct-resolver --output /tmp/content-load-direct
python3 Tests/Portable/ReaderContentLoading/run.py --thread-sanitizer --output /tmp/content-load-tsan
(cd Tests/Portable/ReaderContentLoading && python3 -m unittest -v)
```

Outputs must be new directories. `--source` accepts the complete original or a
mutated class; use `--allow-warnings` only for the unchanged original. Source/test
hashes, generated component package, compiler/command output and `RESULTS.json`
are retained. The POSIX runner terminates attached descendants on interruption;
it is not a general supervisor for arbitrary detached daemons.

## Integration

This focused change is stacked on Lake's Reader-selected inventory branch so
that its existing deletion/journal repair is retained without being rewritten.
The parent branch and protected targets are not changed. Root Reader #286 must
select a descendant and register `ReaderContentLoadingOwnershipTests.swift` and
its 25 methods (exact roster in `expected-tests.json`) at its coordinated source
and native-test boundary. Lake's package already depends on LakeOfFireContent
in its owning test target. Registration is not native execution.

No original book, user database, credentials, generated Xcode output, production
CloudKit state, root dependency pin or qualification flag was changed. Keep draft
until actual Apple compilation/discovery and the affected navigation/manual-read
journeys execute on the selected application graph.
