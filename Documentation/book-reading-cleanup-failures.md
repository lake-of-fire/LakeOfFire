# Book reading-state cleanup failures

## Relocation

The state controller installs a new location and revision before invalidating outgoing presentation. That invalidation must not prevent the new location's existing read-only refresh from being requested. Otherwise the controller has already forgotten the previous context, has no pending query, and treats the next same-location observation as a no-op.

This affects first admission, a new chapter, same-URL document replacement and End of Book. Relocation also retires an earlier Unmark History recovery; failed outgoing cleanup must not leave the destination without its own state query.

## Account replacement

`setAccountPresentation` similarly installs the newer account stamp, retires old History recovery and clears old context and pending state before invoking outgoing cleanup. If the presentation invalidator throws, the ordinary new-account notification cannot return admission to the runtime's refresh. When a correlated native response introduced the new account, the exception also prevents that response from restoring its pending slot and publishing. Repeating the stamp cannot repair it: the stamp is already installed, and the original response no longer owns a pending request.

After the existing account-change callback succeeds, tolerate failure of the outgoing presentation invalidator and retain the final exact-publication/pending checks. This does not suppress failure of the account-change callback itself or weaken new-projection acknowledgement.

## Invariants

The failure handler performs no native mutation, replay, automatic retry loop, new timer or ownership recapture. A callback-selected newer account, location, query or closed controller wins. Sending or admitting a read does not make Book actions ready; only an accepted native state and successful `onState` publication do. Explicit projection refusal and exceptions remain unsuccessful delivery.

The native account stamp distinguishes transition (`generation:0`) from settlement (`generation:1`). A transition notification clears the old context; it does not supply a ready replacement. The current account's accepted state restores availability. An earlier transition cannot replace an already-settled stamp, and the prior account's pending reply cannot be revived by the cleanup tolerance.

## Focused regressions

The two Node suites import the complete production state module and its real UUID module, with native responses and callback errors controlled at their public seams:

```sh
node --test Tests/JavaScript/book-state-relocation-cleanup.test.mjs \
  Tests/JavaScript/book-state-account-cleanup.test.mjs
```

The ten-case account suite reproduces five assertion failures on the preceding source and passes all ten after the account fix. It includes settled-account chapter/end-page admission, a failing callback getter, notification-driven refresh, preservation of nested queries and newer accounts, closing, refusal of a new projection, the two-phase native account protocol, and continued rejection when the account-change callback itself fails. Together with the unchanged nine relocation cases, the final focused run passes 19 cases with no failures, skips or cancellations.

Native writer, actual renderer, browser/WKWebView, account transitions and complete app acceptance are separate qualification. Controlled callback failure is not an observed customer incident or a claim of native data corruption.
