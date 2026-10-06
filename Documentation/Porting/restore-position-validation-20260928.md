# Porting work: restore outcome and reader-position payload validation

## Provenance and destination

This increment builds on Lake port PR #41 at `dcc01a57d052da853b5f757aeb65cf9d5a57921c`. Keep its newer renderer/book/command ownership changes and 240 JavaScript cases. It is not a replacement of main's viewer or a transplant of the native Core restore coordinator.

Two hotfix contracts are adapted:

- Core `cb0a57d8f57767bff805e470b166b8b76c6291c9`, `Reader/EBookInitialRestoreCoordinator.swift` (blob `40ecfb670b36984654b6c3a7a5113ae48daae01e`), and the matching-fraction, wrong-landing and CFI-only cases from its tests (blob `66869c63b8657e3c68884baee89d237321603a2b`).
- Lake `10fdf15c8ce4550b4e7900830843c1c8f2ac9f98`, `Reader/ReaderJavascriptMessages.swift` (blob `e59540e2172e00cead5b69b605af13bf4210a088`): bounded FractionalCompletionMessage payloads, finite fractions/timestamps and non-trapping optional integer parsing.

Only the contracts are adapted from private Core; no private source file is copied into this public repository. The saved-position validation is a new implementation in main's existing JavaScript helper.

## Runtime changes

### A completed navigation is not necessarily a completed restore

`makeInitialRestoreTerminalResult` now compares its requested and observed positions. For a saved positive fraction, both handled and current fractions must be finite, within [0, 1], and within the hotfix's 0.003 tolerance. As in hotfix, those fraction matches can satisfy a request whose reported CFI differs. Without an applicable saved fraction, require a matching nonempty handled CFI. Missing or invalid observations do not become successful acknowledgements.

Keep `navigationOk` distinct from `restoreSatisfied`. A navigation can finish without throwing and still miss its target; that is now a failed restore receipt with an explicit error. Preserve the original navigation error, request identity, existing wire fields, noTarget behavior and previously repaired required-navigation wrapper. Void-returning renderers remain supported, but their terminal snapshots still need validation.

The validator handles an explicitly supplied fraction-zero request. **This does not enable saved-zero opening across the stack**: main's existing request normalization/routing still needs the separately coordinated zero-locator work. Numeric endpoint preservation is not that larger feature.

### Native payload admission

The existing FractionalCompletionMessage entry points now use hotfix-derived admission: finite fractions in [0, 1], CFI <= 64 KiB UTF-8, reason <= 512 bytes, URL <= 16 KiB, and finite optional document timestamp. Invalid required values reject the message. Invalid optional page/section/count values become nil rather than trapping. Preserve valid integer strings, native integer extremes and historical truncation semantics.

Numeric 0 and 1 are not booleans. Core Foundation runtime type identity distinguishes actual JSON/NSNumber booleans from numbers, preventing the old restore parser from dropping endpoints and preventing a Boolean progress value from being treated as 0/1. True Boolean flags are retained; numeric substitutes are not accepted as flags.

The restore decoder also rejects contradictory terminal acknowledgements: failed/noTarget cannot claim restoreSatisfied, and satisfied cannot carry a navigation failure or error. Request correlation and document/write authorization remain the consumer's responsibility.

### Ownership and code placement

The two value payloads move to `ReaderPositionMessagePayloads.swift` in the **same LakeOfFireReader module**. Their public names and initializer entry points remain. The WebView message adapter stays in ReaderJavascriptMessages.swift and delegates to the same body decoder. Other message types are unchanged. The package's existing reader directory discovery includes the new file; the generated app/Tuist graph still needs regeneration and test discovery verification.

This split permits execution of complete production payload declarations using Foundation/CoreFoundation without a fake Realm, WebViewMessage, or native message decoder. The new timestamp field is parsed provenance only; it is not an admission fence and no existing caller is claimed to consume it as one.

## Verification

Before publication, the actual prior PR JavaScript artifact was SHA-256 verified (`131a30159840191b4d72eb381342c6b09f103f0b4ec79bc2faeb96308a68956d`) and used as the test baseline. Its restore-helper blob was `3f2ae9c8f1fd5909bf2fea8bf322dbe231ce35f8`. The native message file matched main/PR blob `15580109bf06be014e0e05cd45d923b22e96e530`.

Local runs passed all **253 JavaScript cases** (240 retained + 13 new) and **21 Swift cases in both Debug and Release** (18 new + three unchanged restore-decoding cases). The Swift runner uses actual complete value types, not source-text assertions or a translated model. Tests exercise actual JSON serialization, endpoint preservation, limits, invalid numbers, optional integer compatibility and receipt consistency.

Three negative controls failed against the original production implementations with assertion failures, not compiler failures: a missed saved fraction was reported satisfied, infinite progress was accepted, and numeric endpoint 1 was discarded during restore receipt decoding. The repaired implementations pass those behavioral requirements.

Commands:

```sh
node --test Tests/JavaScript/*.test.mjs
bash Tools/test-position-payloads.sh -c debug
bash Tools/test-position-payloads.sh -c release
```

The new macOS/Linux Debug/Release workflow retains exact source, manifest, toolchain and logs. Its execution status must be read from GitHub, not inferred from these local results. Existing JavaScript/package-import workflows remain intact and rerun independently.

## Remaining integration gates

This is payload/terminal-result validation, not a complete restoration or lifecycle port. It does not cancel stale top-level loadLastPosition continuations, correlate native frame receipts, authorize Realm writes, repair renderer layout, retry a failed restore, or add native recovery UI. Existing global loading flags and position-save gating are unchanged. A CFI acknowledgement without a fraction is not independently re-derived from DOM layout.

Validate real reflowable/fixed-layout EPUBs, rounding near the tolerance boundary, WebKit envelope delivery, failed-restore presentation, saved-zero routing and persisted progress with Core/Common. Keep #37's identity/snapshot and locator changes during composition; no combined-PR qualification is claimed. Complete full SwiftUI/WebKit/native target and root test-plan discovery before advancing app gitlinks.

No original EPUBs, persisted primary keys, schemas, app gitlinks, signing settings, dependency requirements, rollout flags or production CloudKit state are changed. Other message-decoder force casts remain outside this bounded port and must not be described as audited/fixed by its tests.
