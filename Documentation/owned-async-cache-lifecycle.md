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
aborts their producers. Producers which ignore cancellation may still resolve
the original callers. They must not publish into the cache or remove a newer
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

No generation counter, persistent flag, retry timer or additional cache is
needed. The existing in-flight entry identity owns retention and cleanup.

## Focused regression command

```sh
node --test Tests/JavaScript/owned-async-cache-settlement.test.mjs
```

The tests import the complete production module and control only factories,
retention callbacks and promise completion order. They cover invalidation,
replacement, failure agreement, retry, abort signalling, coalescing, disabled
retention, LRU eviction and undefined values. The controlled callback schedules
are cache-contract regressions, not evidence of an observed customer Unmark
incident. Browser/native processing and the assembled Reader are separate
integration checks. `LAKE_OWNED_ASYNC_CACHE_SOURCE` can select an unchanged
baseline module for a before/after run.
