# Native page Mark/Unmark must retain admission until first dispatch

## Failure boundary

`createNativeMarkReadRequestCoordinator.request` reserves a request, installs
lifecycle listeners and its observation timer, then enters the native mutation
callback. Previously that final edge checked only whether the coordinator was
closed and the request was still indexed. It did not check the original owner,
paused observation, recovery-only state, or cancellation.

A lifecycle/timer collaborator can synchronously deliver pagehide or pause the
coordinator during setup. The request is then marked recovery-only but still
passes the old edge check and posts its first Mark/Unmark mutation. An immediate
resume does not restore that old admission. Likewise a false or unavailable
original-owner predicate was not consulted for an otherwise new request.

These are reproduced coordinator contracts with controlled callback reentry.
They are not a measured browser interruption frequency, a demonstrated native
write past Common's fences, or an observed customer data-loss incident.

## Correction

Require the exact original request to remain indexed, ordinary, uncancelled,
observing and owner-current immediately before the initial transport call.
Check local ownership both before and after the owner predicate because that
callback can itself retire the request.

When this pre-dispatch check fails, settle only that unsent local request as
`requestInvalidatedBeforeSubmission`, with `success: false`, known outcome and
no snapshot-presentation permission. Use existing terminal cleanup for its
timer and pending notice. It must not create a native History recovery barrier
for a command that was never submitted. Preserve any independent recovery
already waiting for ordinary work to drain and any successor created during
cleanup.

After initial transport entry, the existing native-outcome protocol remains
unchanged. A later owner change cannot turn committed success into local
failure. Native acceptance remains distinct from command success, including
failed commands, duplicate delivery and read-only History recovery. There is
no new timer, queue, mutation replay, native payload field or permission.

## Regression coverage

`Tests/JavaScript/native-mark-read-pre-dispatch.test.mjs` imports the complete
production coordinator module. Sixteen cases cover Mark and Unmark admission,
pagehide in lifecycle/timer setup, pause/resume, false/throwing/reentrant owner
predicates, pre-dispatch Cancel, deliberate retry, cleanup-created successors,
coalescing, submitted outcome retention, submitted History recovery and close.

On Linux Node 22.16.0, the original complete module produced 5 passing and 11
failing cases. The corrected module passes the same 16 cases with no skips or
cancellations. Failures are dispatch/ownership assertions, not timeout or
missing dependency errors.

The local component run used a temporary module loader for two unexercised
imports, `carryReaderArticleProducerOwner` and `bookScopeKey`. Their replacement
bodies throw if called; neither is used by the coordinator scenarios. This
isolates module loading only, not coordinator logic, and does not establish
producer-envelope or Book state-controller integration. The maintained test
imports the normal production path and needs no loader in the full repository:

```sh
node --test Tests/JavaScript/native-mark-read-pre-dispatch.test.mjs
```

Complete source/test bytes match uploaded Git blobs; production syntax and
`git diff --check` pass. Full JavaScript roster, actual browser pagehide,
WKWebView/native admission and assembled Reader UI qualification are deferred.
Before merge, include this suite with the existing native-mark request tests
and exercise visible-page Mark/Unmark with the actual owner predicate. Logs
and the local-only loader remain outside tracked source.
