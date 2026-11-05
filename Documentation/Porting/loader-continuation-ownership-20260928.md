# Porting work: top-level EPUB load and restore ownership

This continues the v3-hotfix lifecycle forward-port in Lake main's existing reader architecture. It follows the package/import, renderer-navigation and restore-validation work in PR #41; it does not replace the source-authority or owned-package composition tracked by Common/Core and Lake #37.

## Provenance and actual integration

Base: PR #41 head `dd63fd7d031096bdd95137499e178e22322c6922`, based on main `ac5894d936a15b9d305dafdaeac7afac5a0366dd`. Original hotfix-selected Lake revision: `10fdf15c8ce4550b4e7900830843c1c8f2ac9f98`. This increment adapts the lifecycle invariant to main rather than copying the old Core native coordinator or overwriting the newer request-correlated protocol.

The complete current viewer originally had blob `89b52d3a470fab257950b581497fa4c5606155f6`. Its two top-level handlers repeatedly looked up globalThis.reader after awaiting, and the restore catch/finally unconditionally changed global state. The outer load also published the old restore result after its await without validating ownership at that point. A same-URL request could replace a pending locator too late to be consumed, or be discarded as duplicate-ready.

The implementation factors the two actual window handlers into ebook-load-coordinator.js. ebook-viewer imports and installs those functions, shares the corrected navigation-intent runner with its existing callers, and notifies the load owner from Reader.close. The old handler bodies are removed; this is not an uncalled helper or a wrapper around the unsafe original implementation.

Exact runtime/test blobs:

- Viewer: `cf8c66e1f65aa48bdab0cf741bec5a14b530fc76`
- Loader/restore coordinator: `3e4b2b935ee3c26a4673d8f89b1356fd5043e59e`
- Behavioral tests: `c497cf4831b19357f7e386f1e3adb53d39080a3d`

All other viewer code remains byte-for-byte unchanged. Unused moved imports are removed. No package dependency, Swift declaration, persisted schema, original EPUB, root gitlink or signing setting changes.

## Ownership and compatibility

Each load owns its reader, source resources, fetch cancellation, cache warmer, foreground token and request. Each restore additionally captures the exact view and renderer. Checks surround awaited navigation, source/body reads, frame settling, snapshots, completion callbacks and native receipt publication. An old catch or finally cannot mark a successor attempted, clear its flags, erase its promise, publish a stale receipt, or schedule its warm-up work.

Closing/replacement aborts pending waits, cancels fetch through AbortSignal, releases the corresponding resource owner, and finishes only that foreground token. Underlying promises remain observed so late rejection does not become unhandled. Frame waits reuse the existing timeout-fallback scheduler and cancel both handles; default-navigation timeout handles are cleared on completion. Cancellation is not authority to run nextSection on the replacement renderer.

Exact request retransmissions reuse the in-flight promise or ready reader. A different request ID, locator, URL or layout is a different request and starts a new load; it is not silently lost under same-URL deduplication. This may perform another open for a genuinely new request at the same physical URL. That deliberate correctness choice does not turn URL equality into persistent content identity.

Synthetic and reconciliation navigation must report an applied result using the existing required-navigation policy; missing/explicitly rejected targets cannot report success. Legitimate void-returning renderers remain compatible. Current network/restore errors retain their error/result semantics. HTTP error responses are rejected before constructing a book from their body. Unknown layout no longer inherits an earlier request's layout override.

Navigation intents are owned independently of completion order. A late finally cannot clear another intent, and finishing a newer intent cannot resurrect an already-completed predecessor. Setup and completion tests also cover synchronous replacement callbacks.

## Executed tests

33 new behavioral cases run the production handler/coordinator module with Reader construction, browser scheduling and native-message endpoints as doubles. They cover current success/error behavior, in-flight/ready retransmissions, same-URL changed requests, fetch/body/open/restore replacement, direct close, same-reader restore replacement, renderer replacement, frame cancellation/fallback, default-navigation fallback, synthetic/reconciliation rejection, request publication, setup reentrancy and intent completion order.

The entire JavaScript suite passed locally: **286 cases, zero failures/cancellations/skips** (253 retained + 33 new), Node 22.16.0. Five selected requirements were also run against the exact original handler/intent function bodies in a temporary dependency adapter; all five failed with AssertionError, then passed with the new implementation: same-ready-URL request loss, stale restore clearing newer flags, ignored reconciliation rejection, out-of-order intent cleanup and external-intent restoration. These are behavior assertions, not source-text checks or compiler failures.

A temporary stage run applied a hash-checked transformation of the complete viewer and ran all 286 tests successfully on GitHub Ubuntu/Node 22. It retained only the independently verified immutable public viewer blob; it never moved a ref. Run: https://github.com/lake-of-fire/LakeOfFire/actions/runs/36459303445. Artifact 10986573789 was downloaded and SHA-256 verified: `a8224cd7f74a5fc87a4a288c46009e5997f27927c6f3e0bb2b3cfd4addf60541`. All 97 retained source/test files match the local final bytes. The stage's script and workflow are removed by the runtime commit. Permanent CI remains contents:read and reruns the complete suite plus syntax checks at the committed tree on macOS/Ubuntu.

Check the live PR for final committed-tree CI outcomes; stage success is not automatically a current-head macOS result. Repeated platforms/configurations are not additional unique tests.

## Remaining integration gates

This does not execute the actual WebKit DOM, Reader constructor/open/close internals, native message delivery or Realm persistence. The viewer glue is syntax-checked and byte-verified; real reflowable/fixed-layout, rapid close/reopen, hidden-frame scheduling, native error UI and exact dependency composition remain necessary. Aborting a wrapper wait does not cancel every uncooperative renderer-internal DOM operation; the separately implemented renderer ownership checks still matter.

Retain/reconcile Lake #37's serving-session inputs and exact native initialization binding. The two PRs are not qualified together by these tests. Saved-zero normalization/opening, retry UI, current-document/Article receipt admission and final durable-write/lifecycle gates remain the responsibility of the coordinated identity/authority ports. This change does not silently enable those features or claim the Common/Core migration is complete.

The existing package/import and Foundation-position implementations are unchanged. Their prior passes remain evidence for those exact implementations; the permanent checks should be reviewed again at the final composition before root pins advance. Keep PR #41 draft pending the real host boundaries.
