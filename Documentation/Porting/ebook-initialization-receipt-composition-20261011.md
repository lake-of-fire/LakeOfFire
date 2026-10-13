# eBook initialization receipt composition — 2026-10-11

Reviewed Lake #138 at 974f7015af39607ca97ae90ac7b7984077f384f2 against retained #50 at 47c3307ef93e91dd3295ab31704a5446705d43ed. The #138 handler registered its frame before admission, acknowledged with the current caller, awaited initial restore lookup, then loaded through the current caller again. It did not retain the message's immutable binding receipt across those suspensions.

## Focused composition

- Port ReaderEBookInitialization and its 18 behavioral XCTest methods from #50.
- Admit only a main-frame receipt whose canonical reader URL matches the requested book, then preserve the receipt binding through registration, acknowledgment, restore lookup and publication.
- Both JavaScript calls use evaluateJavaScript(requiring:). The helper checks cancellation and current binding before each next stage. A same-URL replacement cannot lend its binding to an earlier initialization.
- Preserve #138's presentation values, restore bridge and existing loadEBook argument contract. Preparation is a no-op in this composition: no owned package session, opening preparer, task-local opening context, Core hook, dependency pin or schema change is introduced.
- Verified the required WebViewMessage receipt fields, currentJavaScriptBindingToken and token-requiring JavaScript overload in the existing Reader #384 SwiftUIWebView pin 7c59736d60b4b209ced88f4668937e86f44540bd.

## Evidence and limits

This is source-correlated reconciliation, not a reproduced shipping-hotfix failure. The helper tests cover missing/stale/unbound/cross-window receipts, synchronous reentry, suspensions, cancellation, failure propagation, a fresh replacement, and saved zero. They do not exercise WKWebView or prove the real handler's frame/URL wiring. Swift has not been compiled and all tests remain UNRUN. No builds, native launches, generation or CI were requested.

The initial restore callback retains its existing behavior; this guard cannot undo any callback side effect already performed. Owned serving/package preparation and their deeper persistence fences remain separate unresolved ports. #50 is not fully superseded. Reader's explicit Tuist test source list must include ReaderEBookInitializationTests.swift before eventual qualification.

Next bounded action: compose owned serving and its matching Core opening hook only after tracing the current main package/cache architecture; do not substitute a stale package pin.
