# Book reading-state cleanup failures

## Relocation

The state controller installs a new location and revision before invalidating outgoing presentation. That invalidation must not prevent the new location's existing read-only refresh from being requested. Otherwise the controller has already forgotten the previous context, has no pending query, and treats the next same-location observation as a no-op.

This affects first admission, a new chapter, same-URL document replacement and End of Book. Relocation also retires an earlier Unmark History recovery; failed outgoing cleanup must not leave the destination without its own state query.

## Account replacement

`setAccountPresentation` similarly installs the newer account stamp, retires old History recovery and clears old context and pending state before invoking outgoing cleanup. If the presentation invalidator throws, the ordinary new-account notification cannot return admission to the runtime's refresh. When a correlated native response introduced the new account, the exception also prevents that response from restoring its pending slot and publishing. Repeating the stamp cannot repair it: the stamp is already installed, and the original response no longer owns a pending request.

After the existing account-change callback succeeds, tolerate failure of the outgoing presentation invalidator and retain the final exact-publication/pending checks. This does not suppress failure of the account-change callback itself or weaken new-projection acknowledgement.

## History recovery and failed reads

`beginHistoryReadingStatusRecovery` installs its recovery observer and withdraws the old context before invoking outgoing cleanup. A throwing invalidator could abort its preparation response with the observer already installed. Ordinary refreshes are intentionally blocked by that observer until native admits its exact recovery proof. Optional paint failure must not interrupt that existing preparation protocol. The production runtime retires scope receipts before its final `invalidateProjection` call; that paint callback is separate from the required account bridge and accepted replacement projection.

The final caller-supplied ownership predicate is also a synchronous callout. It can change the account, close, or install a successor while returning true. Recheck the original admission after that predicate so a retired observer cannot be acknowledged. A callback-created same-valued successor retains its own proof and pending read.

A failed native reply or failed transport could likewise escape the controller's false-result contract when its subsequent cleanup threw. Preserve the failed result and exact-request retirement, without consuming a callback-created replacement query. A failed History read still settles false and permits a later explicitly admitted attempt; no automatic attempt is added.

## Shared cleanup boundary

`#invalidateRetiredProjection` is the one failure policy for outgoing invalidation after the controller has withdrawn or replaced a projection. It invokes the existing guarded notification, contains only its cleanup exception, and rechecks the same captured ownership predicate. Relocation, account replacement, recovery preparation/withdrawal, read failures and rejected-publication cleanup use this boundary rather than independent try/catch decisions.

The helper cannot make a native sample ready, issue a read, replace a receipt or acquire another account. Required `onAccountChange` errors are not routed through it. Explicit `onState` refusal and projection exceptions retain their existing unsuccessful-delivery behavior. Closing remains terminal; its runtime owner continues to isolate the separate teardown steps.

## Invariants

The failure handler performs no native mutation, replay, automatic retry loop, new timer or ownership recapture. A callback-selected newer account, location, query or closed controller wins. Sending or admitting a read does not make Book actions ready; only an accepted native state and successful `onState` publication do. Explicit projection refusal and exceptions remain unsuccessful delivery.

The native account stamp distinguishes transition (`generation:0`) from settlement (`generation:1`). A transition notification clears the old context; it does not supply a ready replacement. The current account's accepted state restores availability. An earlier transition cannot replace an already-settled stamp, and the prior account's pending reply cannot be revived by the cleanup tolerance.

## Focused regressions

The three Node suites import the complete production state module and its real UUID module, with native responses and callback errors controlled at their public seams:

```sh
node --test Tests/JavaScript/book-state-relocation-cleanup.test.mjs \
  Tests/JavaScript/book-state-account-cleanup.test.mjs \
  Tests/JavaScript/book-state-history-cleanup.test.mjs
```

The earlier ten-case account suite reproduced five assertion failures before its account fix and passed all ten afterward. Together with the nine relocation cases, these nineteen controls retain settled-account chapter/end-page admission, failed callback/getter cleanup, notification-driven refresh, nested queries and newer accounts, closing, projection refusal, the two-phase account protocol, and rejection of a failed required account callback.

The twelve History/failure cases on the preceding complete controller yielded **3 passing / 9 failing** tests. With the shared cleanup boundary and final admission recheck, they pass **12/12**. Combined with the unchanged nineteen controls, the focused Node 22.16.0 run passes **31/31**, with no skipped or cancelled cases. Production syntax and whitespace checks pass. Source and unchanged test bytes were checked against their Git blob identities; this is a minimal source fixture, not a complete application checkout.

Native writer, actual renderer, browser/WKWebView, account transitions and complete app acceptance are separate qualification. Controlled callback failure is not an observed customer incident or a claim of native data corruption.
