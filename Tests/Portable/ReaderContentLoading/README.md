# Completed Reader content delivery — October 7, 2026

## Current finding

The prior load-ownership repair protects the producer before it publishes, but
`getContent()` still returns the value of its captured task without revalidating
it after the await. A completed task can have consumers queued to resume after a
new selection has already won. That is a separate boundary from the producer's
successful assignment to `content`.

Three failing histories reproduce against the complete PR #114 class:

- A publishes, an observer schedules the real public preload/load path for B,
  and queued readers then receive A although B is displayed.
- A title subscriber replaces the displayed content before waiting readers
  resume. This includes a different object with the same URL.
- A publishes, navigation goes A -> B -> A using the exact original A object,
  and an old reader receives A from the retired first selection.

These are schedules of one completed-result ownership defect, not three new
persistence bugs. Core's current manual-read resolver captures the original
page before calling this accessor and uses that page for a cache-miss fallback.
The repair must return nil for a displaced result, never adopt today's content.
It neither changes that fallback nor replaces downstream mutation admission.

## Repair and reassessment

The existing `loadingID` becomes `selectionID` and remains the last admitted
selection after its loading slot is cleared. This retains the already-existing
UUID instead of adding another token or counter. `getContent()` captures it
before waiting and checks both its identity and the exact displayed object after
receiving the result. Completion cleanup still releases task/URL state before
coalesced waiters wake and cannot erase a successor's task.

A no-op load of the already displayed content with no pending task does not
rotate selection identity. This distinction was verified during iteration:
the first fix suppressed a valid pending read on harmless content reuse; the
final version preserves that positive case. An unrelated active loader is still
retired, including through the existing-content fast path.

One production file changes, 26 additions and 9 deletions. No new runtime field,
class, lock, queue, timer, retry mechanism, writer, journal or schema is added.
Existing loader arguments, alias policy, error propagation, individual waiter
cancellation and public method signatures remain. This is not a claim that all
arbitrary external edits to published properties form an atomic transaction.

## Exact source and integration boundary

Target repository: `lake-of-fire/LakeOfFire`, PR #114, branch
`codex/reader-content-load-ownership-20261006`.
The checked live head remained `43db952704bacc9945eb6e5001e3ad9cef5d7ba1`.
Baseline `ReaderContent.swift` blob: `f8d42476af0356207a66d18d3c2cafe93e0969b9`.
Repaired blob: `e7d50ac057a69561cc62d6fc810b2238c5f7097e`.

Reader root `ee3138a48fd34b9186d9a52574becef030308eb1` selects that exact
Lake baseline, so the previous repair is now in the selected composition.
Core's captured-page resolver was rechecked at
`a7a09cf34e3856e4a4e629a09f35dde0247a23ed`, unchanged owning-file blob
`53b23c641b2305f9c650793cfcd4e1370f129af8`.

This increment is local/unpublished. The current GitHub action set exposes reads,
not commit/ref/comment writes, and terminal Git's remote query fails with
`Could not resolve host: github.com`. No branch, PR comment, root pin, inventory,
qualification flag, workflow or deployment was changed. The local Git directory
used for generating a diff is a component fixture, not an upstream checkout;
its synthetic commit is not a publishable parent.

## Executed final-source verification

Swift 6.2.1/Linux, Swift 5 package language mode, complete concurrency checking,
warnings as errors. All 25 prior tests are unchanged; six methods were added to
the same test class. The same final 31-method file executes in these runs:

| Execution | Passed | Failed |
| --- | ---: | ---: |
| Original complete class, optimized | 28 | 3 |
| Repaired public entry, Debug | 31 | 0 |
| Repaired public entry, optimized | 31 | 0 |
| Repaired internal resolver entry, optimized | 31 | 0 |
| Repaired public entry, ThreadSanitizer | 31 | 0 |
| Remove selection identity check | 30 | 1 |
| Remove displayed-object identity check | 30 | 1 |
| Remove harmless-reuse early return | 30 | 1 |

ThreadSanitizer emits no race diagnostic. Ten further executions of each verified
optimized binary reproduce the same result: original 28/3, repaired 31/0 on every
run. These are repeated schedules, not 310 distinct tests. The multi-waiter cases
use 32 waiting tasks and priorities to widen the late-consumer window; they do
not assert portable FIFO scheduling. Assertions allow reads returned before the
transition, and reject a displaced result afterward. Synchronous title-observer
replacement supplies the independent reentrant case, including equal URLs.

Nine unchanged runner contract tests also pass. Raw method outcomes, exact
compiled inputs and driver statuses are retained. A combined verification tool
call was interrupted after the Debug XCTest process printed success but before
its driver wrote a receipt. It is excluded from accepted evidence; a new,
independent final Debug execution completed with status 0. An unsupported
streaming-session attempt started no command. Neither is counted as a pass.

## Native scope and reproduction

The complete production class and its actual Tasks, preloads, coalescing,
publication and result-delivery implementation execute. Linux supplies explicit
model, Combine/SwiftUI, loader and URL-alias leaves. This does not qualify actual
Combine, managed Realm objects/history, production URL aliases, providers,
WKWebView, the native menu/handler or an assembled Reader application. The
native-intended branch uses unmanaged HistoryRecord fixtures and the existing
per-call resolver, but Apple compilation/execution remains unperformed here.

Use the existing `Tests/Portable/ReaderContentLoading/run.py` with a fresh output
directory, adding `--optimized`, `--direct-resolver`, or `--thread-sanitizer` for
the corresponding lane. `--source` accepts the complete baseline or a mutated
source. The runner and platform collaborators are unchanged by this increment.

At publication, apply the four-file patch to a verified descendant of #114,
preserve concurrent work, use a normal guarded fast-forward and `[skip ci]`, and
retain draft status. Reader integration should keep the existing native test file
registered and add the six names in `new-native-methods.json` to both inventories
when selecting the resulting Lake revision. No source can be pinned to an
unpublished or fabricated commit. Historical first-Mark/startup, saved-position,
archive-crash and full JavaScript/application qualification remain separate.

---

## Earlier load-lifetime repair (historical evidence at 43db9527)

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
