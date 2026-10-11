# Native saved-position admission stage — 2026-10-11

## Exact source comparison
Current composition: Lake #138 a7ec1327cd952c04b4785e26a4ee70704625d3c4.
Reference: #41 af14b895d9d3e1a1fe8c3a00e52c158d6eae211e, retained identically in #50 642250f9dee22b0460871006e803ae57151f5c12 for the Foundation policy/value/bridge.

## Bounded source changes
Extract the public saved-position value into its owning Content module and the native bridge into its owning Reader module. Preserve the unchecked public initializer for source compatibility; add the older validating initializer and always revalidate at the bridge. An explicit zero is present, malformed fractions throw even with CFI, and CFI text is preserved exactly.

The existing ebookViewerInitialized callback now awaits acknowledgment and saved-position preparation in its own task. Failed reads are no longer swallowed as absence and a second unstructured handler task is removed. Cancellation is checked before and after the provider, including a noncooperative provider returning nil. Other current-main handler logic is untouched.

Four Foundation regression files carry 27 methods. All UNCOMPILED/UNRUN. No generation, builds, native hosts, tests, CI dispatch or dependency changes. Historical #41 passes are not current-head qualification.

## Deliberately incomplete end-to-end composition
This stage does NOT claim working end-to-end zero restore yet:
- Current Core #545 1a058890f6c6adcee088747f1a1e2f2c819903e7 startup still filters fraction > 0 and uses an unstructured Realm task. #183 e71646312b548e694dd878ffc79410f063347f4f carries the awaited/validating producer.
- Current JS normalizeInitialRestoreRequest and loadLastPosition still treat zero as absent; absent default opening currently supplies zero. Those must be distinguished together.
- Current JS completion/saving effects precede full target verification. The retained load/restore modules carry the stronger ordering and ownership.
- Full immutable receipt/binding/owned-serving admission requires the paired contracts and must not be inferred from this value validation.

Do not select a release dependency tuple on the strength of this stage. No media/transcript feature was activated.

## Next bounded action
Compose the JS request/default-opening/restore-finalization path and Core saved-position producer as a compatible unit, preserving current main's viewer and startup refinements; then qualify the assembled graph only when native execution is authorized.
