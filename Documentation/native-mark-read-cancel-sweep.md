# Native Mark/Unmark bulk cancellation scope

## Failure schedule

The EPUB viewer uses `nativeMarkReadRequestCoordinator.cancelAll` while applying a changed chapter pass. The coordinator previously iterated its pending-request Map directly. Each `cancel` call can invoke the owner predicate, pending-notice callback, control transport and timer cleanup before the loop continues.

If one of those synchronous collaborators admits a new command, the live Map iterator visits that new request too. An older cancellation therefore acquires a newer user intent. A terminal cancellation response can also remove the first request and admit a new request for the same section; the older sweep must not follow that replacement.

This is a reproduced coordinator contract. The tests control synchronous callback reentry; they do not establish that normal WebKit transport replies synchronously, measure customer incidence, or demonstrate a durable native reading mutation.

## Correction

Snapshot the request IDs once at bulk-cancellation entry. Keep `cancel(requestID)` unchanged so every original candidate still checks its current pending identity, observing state and original owner. IDs are already unique within the coordinator. A settled original is ignored, not replaced by another request for the same section.

A later explicit invocation may cancel newer requests. Native commit success can still win despite an earlier Cancel request. Departure never gains Cancel permission, and closing retains the existing unknown-outcome disposal policy.

No additional queue, clock, generation, timeout, native payload, Undo permission, retry or mutation replay is introduced. The entry roster is a short-lived array, not a retained authority registry.

## Regression coverage

```sh
node --test --test-reporter=tap Tests/JavaScript/native-mark-read-cancel-sweep.test.mjs
```

The ten cases import the complete production coordinator and its normal producer, Book state and UUID modules. Controlled lifecycle, transport, timer and notice collaborators exercise reentry at all four callback boundaries, same-section replacement, sibling settlement, a later deliberate sweep, normal cancellation with commit-winning truth, departure and close.

With the same cases under Node 22.16.0, the unchanged source passes three and fails seven; the corrected source passes all ten, with no skips or cancellations. The failures are unexpected Cancel IDs, not module-loading errors. Full JavaScript workflow, real browser/BFCache, assembled Reader, native writer and WKWebView/device acceptance remain separate and unrun.

Other pending coordinator changes for initial dispatch, recovery preparation and restored terminal observation affect separate boundaries. Preserve those changes when composing this entry-roster correction.
