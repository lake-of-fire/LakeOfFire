# Owned async cache: one producer, one settlement

`owned-async-cache.js` is used by the EPUB shell's processed-text cache and raw
section writing-direction cache. It is a derived-data cache, not reading
progress authority, a native command queue, or an Undo owner.

## Contract

Concurrent callers for a key join one settlement promise, covering the factory,
retention decision and owned cleanup. A synchronous retention error rejects all
of those callers consistently and leaves the key retryable. Returning false
from `shouldRemember` is different: callers receive the successful value, but
later calls create a new value.

`clear()` drops resolved values, retires the existing in-flight entries, then
aborts their producers. A producer still queued for its first microtask must
not start after that retirement: its existing shared settlement rejects with
the controller's abort reason, or a named `AbortError` when no controller is
available. This pre-start decision uses the original in-flight entry identity,
not a later same-key entry or a new cancellation generation.

Already-running producers which ignore cancellation may still resolve the
original callers. They must not publish into the cache or remove a newer
producer for the same key. This does not promise cancellation of arbitrary
caller code; its own presentation owner still decides whether a returned value
can be used.

The retention callback is a callout. The operation must still own its key both
before that call and immediately before retention. The EPUB processing callback
reads `result.isAuthoritativelyProcessed`; even a property read can be a callout
when the result has an accessor.

## Failure schedules prevented

1. A producer resolves; its retention callback clears the cache, optionally
   creating a replacement for the same key; the old callback returns true.
   Checking only before the callback would reinsert the retired value. A new
   caller would see that value instead of joining the replacement.
2. Two callers join a producer; its factory resolves, but retention throws.
   Joining only the raw factory promise lets the follower succeed while the
   original caller fails. Both now join the same complete settlement.
3. A call reserves its producer; `clear()` runs synchronously before the queued
   factory microtask. Calling the retired factory would start unwanted work
   with an already-aborted signal. A producer that installs an abort listener
   at entry misses that earlier event and can leave every joined waiter pending.
   Reject the unstarted operation instead, without invoking its factory or
   retention policy. A replacement admitted before old cleanup keeps its own
   slot, signal and result.

No generation counter, persistent flag, retry timer or additional cache is
needed. The existing in-flight entry identity owns retention and cleanup.

## Focused regression command

```sh
node --test --test-reporter=tap \
  Tests/JavaScript/owned-async-cache.test.mjs \
  Tests/JavaScript/owned-async-cache-settlement.test.mjs
```

The tests import the complete production module and control only factories,
retention callbacks and promise completion order. They cover invalidation,
replacement, failure agreement, retry, abort signalling, coalescing, disabled
retention, LRU eviction and undefined values. The controlled callback schedules
are cache-contract regressions, not evidence of an observed customer Unmark
incident. Browser/native processing and the assembled Reader are separate
integration checks. `LAKE_OWNED_ASYNC_CACHE_SOURCE` can select an unchanged
baseline module for a before/after run.

## Pre-start retirement follow-up: 21 October 2026

The initial #212 revision `6b910bb6c814b1daa0fc58096be10ec4b131b328` already
fixed retention reentry and shared settlement, but still invoked a queued
factory after `clear()`. This follow-up retains those repairs and adds the
entry check immediately before the existing factory invocation. Its production
delta is nine added lines and one removed line; there is no new queue, timer,
state field, native command or reading/Undo permission.

All twelve existing settlement cases remain. The existing "late rejection"
fixture now explicitly yields until its factory has entered before clearing;
otherwise it exercised queued work despite claiming to test a running producer.
Its rejection and replacement assertions are unchanged. Eight new cases cover
pre-start clear, the missed abort event, coalesced rejection, same-key retry,
mixed running/queued work, a successor created by a real abort event, missing
AbortController, disabled retention and repeated clears.

Executed with Node 22.16.0 on Linux using the complete module:

| Selection | Prior #212 source | Corrected source |
| --- | --- | --- |
| Expanded settlement suite, same 20 cases | 12 pass / 8 fail | 20 pass / 0 fail |
| Above plus unchanged seven-case original suite | Not rerun together | 27 pass / 0 fail |

Before extending the suite, the original twelve cases also passed against the
exact prior #212 production and test blobs. All final Node cases executed;
none were skipped or cancelled. Source/test syntax and whitespace checks pass.

A separate temporary Chromium 144.0.7559.96 check imported the complete module
and used real browser microtasks, AbortController/AbortSignal and event turns.
The same six checks produced 2 pass / 4 fail on prior #212 and 6 pass / 0 fail
on the correction, with no unexpected page errors. The browser reproduced the
missed-abort pending waiter and preserved both an already-running abort-aware
producer and a non-cooperative producer's original result. The fixture releases
its intentionally stuck baseline producer before asserting; it does not leave
an orphaned test promise. These six checks are a separate component lane, not
additional assembled-app tests. The temporary driver/logs are not new CI.

Input Git blobs verified before editing: production
`83e2bc886af0f07a4de662bbd2ea583c09e8450d`, settlement tests
`49197482bd13cac6f1238092b281b2dcf7c52306`, unchanged original tests
`1b502b79c8874c92fa960f65f1127747b48de582`.

Neither lane opens a real EPUB, runs native processing, boots the full viewer,
or exercises Realm, WKWebView or an Apple application. This demonstrates the
cache lifecycle contract, not customer incidence or durable reading-data loss.
Keep the PR draft pending actual EPUB close/reopen and processing cancellation
qualification. No shipping branch, dependency pin or workflow is changed.
